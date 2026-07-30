# Networking design

The engine does not pick a topology. A co-op dungeon crawler, a LAN party
shooter and a persistent server want different answers, so the dev chooses and
the engine makes every choice cheap.

The target: **one line to turn networking on**, and no rewrite when you change
your mind later.

```lua
-- Host and play, discoverable on the LAN:
MeatRay.net.host{ mode = 'listen', discovery = 'lan' }

-- Headless dedicated server, listed publicly:
MeatRay.net.host{ mode = 'dedicated', port = 6789, discovery = { 'lan', 'master' } }

-- Join: an address, or a server the browser found.
MeatRay.net.join('203.0.113.5:6789')
MeatRay.net.join(serverList[1])
```

Everything below is what those calls select between.

---

## Three axes, chosen independently

### 1. Mode — who simulates

| Mode | Simulates | Renders | For |
|---|---|---|---|
| `single` | local | yes | no networking; the default |
| `listen` | host's machine | yes | friends and LAN; host plays too |
| `dedicated` | headless server | no | persistent servers, competitive play |
| `client` | nobody (applies snapshots) | yes | joining either of the above |

A listen host and a dedicated server **run the same simulation code**. That falls
out of the headless rule: nothing under `meatray/sim/` touches `love.graphics`, so
the authoritative simulation has no idea whether a window exists. Moving a game
from listen to dedicated is a launch flag, not a port.

Dedicated servers run under headless LÖVE (`love . --server`), with `window` and
`graphics` disabled in `conf.lua`. `lua-enet` ships with LÖVE, so there is nothing
to compile — the thing that quietly stops people self-hosting.

### 2. Transport — how bytes move

Pluggable behind one interface, so a game can switch without touching gameplay
code:

- **`enet`** (default) — UDP with reliable and unreliable channels, bundled with
  LÖVE. Reliable for joins, chat and world mutation; unreliable for the snapshot
  stream, because a stale position is worthless and resending it costs latency.
- **`steam`** (planned) — Steam networking sockets and Steam Datagram Relay.
  Deliberately designed for now rather than bolted on later: SDR solves NAT
  outright and gives lobbies for free, and retrofitting a second transport into
  code that assumes ENet's API is the expensive version of this work.
- **`loopback`** — in-process, for tests. Lets the whole net stack be exercised
  headlessly with no sockets, which is how replication gets unit tests.

### 3. Discovery — how players find a server

Also pluggable, and combinable — pass a list and they all run:

- **`direct`** — paste `host:port`. Always available, needs nothing, cannot break.
  Every other method degrades to this.
- **`lan`** — the host beacons over UDP broadcast; clients listen and build a list.
  ENet cannot broadcast, so this uses LuaSocket UDP (also bundled with LÖVE).
  Zero configuration, works with the internet unplugged.
- **`master`** — hosts announce to a small registry; clients query it for a
  browsable list with name, map, player count and ping. The registry is a
  reference implementation you host yourself; the protocol is documented so anyone
  can run their own. **If it is down, `direct` and `lan` still work** — a registry
  outage must never mean the game cannot be played.
- **`steam`** (planned) — Steam lobbies, once the Steam transport lands.

---

## NAT traversal, in order

Most home hosts sit behind a router that drops unsolicited inbound packets. The
engine tries, in order, and tells the host the truth about what happened:

1. **Direct** — works when the port is forwarded, or on LAN, or for a VPS.
2. **UDP hole punching** — the master server introduces both peers, which send to
   each other simultaneously so both routers open a matching path. Handles a good
   majority of home NATs with no user action.
3. **Relay** (planned, and Steam Datagram Relay when the Steam transport lands) —
   forwards traffic when a direct path cannot be established.

**Diagnostics are part of the feature.** A host that nobody can reach must be told
so, precisely:

```
[net] listening on UDP 6789
[net] LAN beacon active - local players can join
[net] ! master server cannot reach you from outside
[net]   hole punch attempted, failed (symmetric NAT)
[net]   forward UDP 6789 to this machine, or use a dedicated server
```

An empty server list with no explanation is the single most common way
self-hosting silently defeats people.

---

## Access control

Configurable, because a LAN co-op game and a public competitive server have
opposite defaults:

- **Open** — anyone with the address joins. The default; right for LAN and friends.
- **Password** — a shared secret, shown as `[locked]` in the browser. Enough for
  a private game with no accounts to build or store.
- **Token / identity** — signed tokens from an auth service, enabling persistent
  bans, stats and cross-server progression. A whole subsystem, so it is a hook
  rather than a requirement: the engine calls `onAuthenticate(request, context)`
  with whatever the client sent and the game returns `true`, or `false` plus a
  reason. **The hook is implemented; no auth service is, and none will be — that is
  the game's to build.** A hook that errors refuses the join rather than taking the
  server down.

Host controls in all modes: `host:kick(peer, reason)` and `host:ban(peer, reason)`,
banning by address. Those need no identity system and stop the common case of one
person ruining a session. An address ban is defeated by a router reboot, which is
why the identity hook exists; it is still the right primitive to ship, because it
stops the person who is a problem right now.

Order of checks is deliberate: a banned address is refused before the password is
compared, so a ban cannot be used to probe for the password, and the game's hook
runs last so it only sees requests that already passed the cheap checks.

---

## Replication

Already designed, and the reason phase 1 was built the way it was.

Every component declares its own `netFields`; `entity:snapshot()` collects exactly
those and `entity:applySnapshot()` applies them back. So the wire format **derives
from data**. Adding synced state is one edit to a declaration, with no
per-type serialiser to update and forget.

What that means concretely:

- **Host → client**: snapshots on the unreliable channel at a lower rate than the
  simulation tick (say 20 Hz against 60 Hz), with clients interpolating between
  them. Entities already carry `prevX/prevY/prevAngle` and `:interpolated(alpha)`
  for exactly this.
- **Client → host**: inputs, not positions. A client that sent positions would be
  authoritative over its own movement, which is the same thing as trusting it.
- **World mutation** (doors now, destruction later) on the reliable channel.
  `world:snapshot()` already returns just the door state, because door state is the
  only mutable part of a world.
- **Local prediction** for the player's own movement, because input latency is felt
  where a foot of positional error is not. Predict movement; do not predict damage
  numbers — a health bar that flinches and then corrects itself is a lie the player
  can see.

Determinism matters where host and client both compute: the engine's own LCG
(`worldgen.rng`) rather than `math.random`, which differs across Lua builds. Two
peers generating a world from one seed must get identical geometry.

---

## What gets built, in order

1. **`loopback` transport + replication tests.** Snapshot round-trip, interpolation,
   join handshake — all headless, no sockets. Building this first means the
   replication layer is verified before a single networking bug can hide in it.
   **Done.**
2. **`enet` transport**, listen mode, `direct` discovery. Two processes on one
   machine, then two machines on a LAN. **Done.**
3. **`dedicated` mode** under headless LÖVE, plus `--server` flags. **Done.**
4. **`lan` discovery** over UDP broadcast, and a server browser UI (needs the GUI
   toolkit from roadmap phase 3). **Discovery done; the UI is still phase 3, so
   `love . --browse` prints the list instead.**
5. **`master` discovery**: announce/query protocol, reference registry.
   **Not implemented.** The diagnostics above, and access control, are done.
6. **Hole punching** through the master server. **Not implemented.**
7. **Steam transport** and SDR, behind the same interface. **Not implemented.**

Steps 1 to 3 make the thing work. Step 4 makes it pleasant. Steps 5 to 7 make
it work for players who cannot forward a port — which is most of them.

---

## Where the unbuilt parts plug in

None of the three remaining items needs a change to gameplay code, to the
replication layer, or to a server browser. That was the point of the interfaces.

| Unbuilt | Plugs into | What it needs |
|---|---|---|
| `master` discovery | `Discovery.register('master', { beacon = , browser = })` | one new file under `meatray/net/discovery/`. `Discovery.resolve` already returns a "planned, not implemented" message for the name, and `Discovery.beacon{'lan','master'}` already degrades to `lan` alone. |
| hole punching | `Diagnostics.classify` already accepts `external` and `holePunch` facts and prints their outcomes; the punch itself is a master-server-mediated exchange inside the `master` backend, which then reports through `host.report`. | the master server |
| `steam` transport | `Transport.register('steam', factory)` | one new file under `meatray/net/transport/`. It must implement the ten methods documented at the top of `meatray/net/transport.lua`; nothing above that file names ENet. `Transport.resolve('steam')` already answers with a roadmap message rather than "unknown transport". |

Two things were deliberately shaped now so those additions stay cheap. Peer
identity is `transport:key(peer)` and never an ENet peer object, so a Steam
`HSteamNetConnection` is a legal peer. And bans are by `transport:address(peer)`
rather than by key, so an identity system can replace addresses without touching
moderation.

---

## Running it

```
love .                                    single player, no networking
love . --host --map arena                 listen host: play and serve
love . --server --port 6789 --map arena   headless dedicated server
love . --connect 192.168.1.9:6789         join
love . --browse                           list LAN servers and exit
love . --netcheck                         can this machine do UDP at all?
```

Add `--name`, `--password`, `--no-lan`, and `--log PATH` as needed. A dedicated
server needs no window, no GPU and no display: `conf.lua` reads the command line
at config time and turns `window` and `graphics` off for `--server`, so
`love.graphics` is genuinely `nil` rather than merely unused.

## When it does not work

The engine tells the host the truth at startup, and there is a command for
everything it cannot determine on its own.

**Start with `love . --netcheck`.** Five checks, cheapest first: LuaSocket
present, lua-enet present, a UDP datagram across loopback, the game port binds,
and two ENet peers completing a real handshake in one process. It exits `0`, or
`4` for blocked UDP, `5` for an unbindable port, `6` for a missing library, `7`
for a transport that will not shake hands. If check 5 passes and a real join does
not, the fault is above the transport; if it fails, the fault is below it.

Two environmental failures are worth naming because both look like a bug in the
handshake and neither is:

- **Something is filtering UDP.** Endpoint protection, a VPN client with a
  filtering driver, or a firewall rule. The port binds, the server reports that it
  is listening, and no client can ever join. A host now runs a loopback UDP
  self-test at startup and says so explicitly, with the `New-NetFirewallRule`
  command that fixes it. Note that Windows Firewall does *not* filter traffic to
  `127.0.0.1`, so a failure on loopback points at a filtering driver rather than at
  a firewall rule.
- **A socket that came up IPv6 when it meant IPv4.** LuaSocket 3.0 resolves `'*'`
  to `::`, and an IPv6 socket cannot send to an IPv4 literal — every send fails
  with "No such host is known", including to `127.0.0.1`. LAN discovery binds
  `0.0.0.0` explicitly for exactly this reason. Any new UDP code here should too.

## How this was verified

- **1283 headless assertions** under plain LuaJIT, no LÖVE and no sockets
  (`luajit tests/run_all.lua`). Four of the eleven suites are networking:
  the wire format, the transport interface and loopback backend, replication end
  to end through a real host and a real client, and access control plus
  diagnostics. The headless rule is enforced over `meatray/net/` as well as
  `meatray/sim/`, including a check that `enet` and `socket` are required inside
  functions rather than at file scope.
- **A real three-process test over UDP** (`scripts/nettest.ps1`): a headless
  dedicated server plus two headless clients, asserting across the wire that both
  players exist on both sides *and* on the host, that a door one client opens
  reaches the other, that a hitscan the host resolves reaches both, and that the
  damaged client's health came down by exactly what the host said without ever
  having been predicted locally. `-Listen` runs the same assertions against a
  listen host. LAN discovery is verified in the same run by a fourth process
  finding the server by broadcast with nothing configured.
