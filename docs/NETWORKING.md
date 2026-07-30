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

  **The snapshot stream stops being unreliable once a snapshot exceeds one
  MTU**, and that constraint is why the snapshot codec exists. ENet decides how
  to deliver a fragmented packet by testing
  `(flags & UNRELIABLE_FRAGMENT) == UNRELIABLE_FRAGMENT`. Our unreliable send
  passes flags `0`, and that test is *false* for `0`, so a snapshot too large to
  fit in a single datagram falls through to reliable, acknowledged,
  retransmitted, head-of-line-blocked delivery — exactly the behaviour the
  unreliable channel exists to avoid. lua-enet exposes no string that maps to
  `ENET_PACKET_FLAG_UNRELIABLE_FRAGMENT`, so this cannot be opted out of from
  Lua, and the packet size is the only lever there is.

  The budget is **1364 bytes** (`protocol.MTU_SAFE_BYTES`): the default 1392 MTU
  less a 4-byte protocol header and a 24-byte fragment command header. ENet
  negotiates the *minimum* MTU of the two peers, so a peer that came up at 576
  drops everyone talking to it to about 548.

  All of the above used to be read off ENet's source and worked out with
  arithmetic. It has since been **observed on real UDP sockets**, by
  `scripts/netfrag.ps1`: a dedicated server, a relay that discards a fifth of
  the datagrams going downstream (`love . --netproxy`), and a probe that counts
  what arrives (`love . --netfrag`). Two runs on `maps/arena.map`, differing by
  two entities and 85 bytes of snapshot, and by nothing else:

  | | 26 entities | 28 entities |
  |---|---|---|
  | snapshot | 1349 bytes (under) | 1434 bytes (over) |
  | datagrams per second downstream | 20.6 | 43.0 |
  | of 500 snapshots the host sent | **396 arrived** | **502 arrived** |
  | snapshots skipped | **105** | **0** |
  | service drains carrying more than one | **0** | **30**, up to 7 at once |
  | inter-arrival p99 | 150 ms | 200 ms, max 367 ms |

  Under a fifth of the datagrams being destroyed, the 1349-byte stream loses a
  fifth of its snapshots and never stalls; the 1434-byte stream loses *none* of
  them and arrives in bursts. That is reliable, retransmitted, head-of-line
  blocked delivery, on a channel asked for unreliable, and 85 bytes is the whole
  difference. The relay's datagram histogram shows the mechanism directly: 776
  datagrams in the 1301–1364 bucket for the small case — one per snapshot — and
  917 at ~1400 plus 928 at ~90 bytes for the large one, which is a first
  fragment and a remainder.

  One number in the paragraph above is wrong on this build and worth knowing.
  The largest datagram ENet emitted was **1400 bytes, not 1392**, so the real
  single-datagram payload budget here is 1372. `MTU_SAFE_BYTES` at 1364 is under
  both, which is what a conservative constant is for, but do not treat 1392 as
  measured — it is the number in the header, and the header is not what shipped.

  Measured on a mixed scene (players carrying billboard/health/player/weapon,
  the rest carrying billboard/health, at coordinates a running game actually
  produces rather than round ones):

  | | text serializer | binary snapshot codec |
  |---|---|---|
  | bytes per entity | 141–181 | 28–47 |
  | first packet over 1364 | **8–10 entities** | **44 entities** |
  | first packet over 548 | 4 entities | 13 entities |

  So the ceiling moved by roughly 4–5×, and `tests/test_net_snapcodec.lua`
  asserts a 32-entity snapshot stays under 1364 rather than leaving it to be
  remembered. Snapshots are the only traffic that takes this path; everything
  else is reliable by intent, and fragmenting it is correct.
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

## The protocol contract

`meatray/net/protocol.lua` is the registry, and it is the *only* statement of
what travels where. Every tag carries a direction (`c2s`, `s2c`, or `both`) and a
documented payload per direction, and both sides dispatch through a table keyed
by tag rather than an `if/elseif` chain.

That shape exists so the contract can be tested against data instead of against
source text. `tests/test_net_contract.lua` reads `P.direction`, `Host.handlers`
and `Client.handlers` and asserts that:

- every `c2s` and `both` tag has a host handler, and every `s2c` and `both` tag
  has a client handler;
- neither side handles a tag that is not in the registry, or one that cannot
  legally travel towards it — a host with a `snapshot` handler is a host that
  acts on a client claiming to be the server;
- `P.names` and `P.direction` cover exactly the same tags;
- every tag round-trips through `P.pack`/`P.unpack` unchanged, including empty
  bodies, nested tables, floats at full precision, strings containing the wire
  format's own punctuation, and payloads large enough to exercise the length
  fields;
- and a **vacuity floor**, because every assertion above is a loop over a
  registry and a loop over an empty registry passes.

The usual way to write this test is to grep the source for emits and listeners
and diff the two lists. It works until someone wraps a send in a helper, at which
point the emitter is invisible to the regex and lands in an allowlist of "false
positives" that then hides the real ones. There is no regex here because there is
nothing to grep for: a handler reached through any amount of indirection is still
a key in a table.

**`chat` travels both ways, and its payload differs by direction.** A client sends
`{ text }`; the host broadcasts `{ text, name }`. The name is the host's to
attach, because a client trusted to name the speaker could name anyone. This was
previously documented under a "client -> host" heading while the host broadcast
it and the client handled it — true and untrue at the same time, and a comment
heading has no room to say "both, and they differ". `P.shape` does, and the
contract test checks it.

---

## Validation, and what a `pcall` is not for

Every message is validated **whole, before any field is applied**, against a
per-tag schema in `P.schema`. Numbers must be finite: NaN is caught by `v ~= v`
and the infinities by comparison against `math.huge`, since `type(v) == 'number'`
excludes neither and the wire format carries both intact by design. Strings carry
length limits, and each client-to-host tag has a byte ceiling in `P.limits`
checked before anything is decoded.

The failure this prevents is not the sender's problem. A handler that assigns
fields as it inspects them leaves the first few applied when the fourth turns out
to be garbage, so one `1e999` in an aim value rides out in that player's snapshot,
to every other player, for the rest of the session. Validate first, assign after,
and a bad message costs exactly one drop.

**A parse failure and a handler failure are different events and are never
conflated.** `P.unpack` reports malformed input by returning `nil` plus a reason —
that is the only thing in the stack that means "malformed", and no `pcall`
anywhere is allowed to produce the same verdict. A handler that raises is caught
separately, counted separately, and always logged host-side with the name of the
tag that failed. One `try` around both the decode and the handler reports a server
exception to the player as a protocol error and logs the real stack trace nowhere,
which is a bug report about the wrong machine.

Game code has the same trap available to it and the engine cannot close it:
`if tonumber(body.angle) then` is **true for NaN**. `Rep.finite(v, min, max)` is
exported for exactly this, and the demo's `fire` command uses it.

---

## Flood control, in two tiers that must stay two

There are two kinds of "too many messages", and treating them as one kind is how a
server bans its own players.

| | Tier | Applies to | On excess |
|---|---|---|---|
| 1 | **Silent throttle** (`Access.throttle`) | the `input` stream | drop, record nothing |
| 2 | **Penalising window** (`Access.window`) | `join`, `command`, `chat`, `stats`, `ping`, `leave` | escalating mute, optional ban |

An input stream is not something a person did — it is the client's send rate, it
is *supposed* to arrive dozens of times a second, and a machine under load bunches
several into one frame. Run that through the penalising limiter and a burst of
legitimate packets earns an escalating mute and then a ban, and the player is
thrown out for having a bad connection. So the throttle drops the excess, records
nothing against the sender, and **can never be the reason anyone is muted or
banned**. Two objects, not one object with a flag, because one object with a flag
is one refactor from being one object without one.

The penalising tier escalates: `penalty * escalate^(strikes-1)`, capped at
`maxPenalty`. `banAfter` defaults to `nil` — the engine does not ban on its own,
because whether flooding deserves a ban is a policy decision and a default there
bans somebody's friend on a hotel connection. A game that wants it sets
`floodBan = true` and gets `onFlood(host, peer, tag, retryAfter, strikes)` either
way. `Access.window:check` also takes a `skipViolation` argument, for a caller that
knows a particular burst is legitimate but still wants it shaped.

Defaults, all overridable per message type through `Net.host{ flood = { chat = ... } }`:

| Message | Limit | Window | First mute |
|---|---|---|---|
| `input` | 120/s | — | none, ever |
| `command` | 60 | 5 s | 3 s |
| `chat` | 8 | 10 s | 5 s |
| `join` | 5 (by address) | 10 s | 10 s |
| `ping` | 20 | 5 s | 5 s |
| `stats` | 5 | 5 s | 5 s |
| `leave` | 3 | 5 s | 5 s |

The input interval must stay **above** whatever clients actually send at — the
point is to bound what an abusive peer can cost, not to police a normal one. Raise
`inputInterval` if a game raises the client's `inputRate` past 120 Hz.

---

## Liveness

A connection can go half-open: the host's process gone, a NAT mapping dropped, a
cable out. No disconnect event arrives on either side — the socket is fine, the
peer is simply never heard from again. Left alone, a client renders a frozen world
and reports itself as connected, indefinitely.

Two mechanisms, and **both are honoured**, which is the entire point:

- **The transport is told to give up.** `transport:setTimeout(peer, limit, min, max)`
  is an optional method on the transport interface; the ENet backend implements it
  with `peer:timeout`, which has always been able to do this and simply has to be
  asked. Both the host and the client call it.
- **A watchdog on top.** The client tracks `silentFor()` and, past `timeout`,
  disconnects itself with a reason a player can act on. The host tracks
  `lastHeard` per peer and drops one that has said nothing for `peerTimeout`. This
  is the backstop for transports with no timeout of their own, and it is what the
  headless tests exercise.

| Option | Side | Default | Meaning |
|---|---|---|---|
| `timeout` | client | 15 s | silence before the client gives up on the server |
| `peerTimeout` | host | 30 s | silence before the host drops a peer |
| `timeoutLimit` | both | 32 | ENet retransmission factor |
| `timeoutMin` | both | 5000 ms | earliest ENet may give up |
| `timeoutMax` | both | derived | latest it may wait; defaults from the timeout above |

A joined session always has traffic in both directions — snapshots down at the
snapshot rate, inputs up at the input rate — so silence is unambiguous.

**Do not add a timeout option that nothing reads.** A `config.net.timeout` sitting
next to code that drops nobody is worse than no option: it documents behaviour the
server does not have, and the first person to find out is a player whose session
filled up with ghosts. `tests/test_net_hardening.lua` asserts each of these
settings is applied, not merely stored.

---

## Input is bounded by the tick, not by the send rate

Client input is **latched, not queued**. A packet replaces the pending intent;
`host:step` consumes at most one per tick. So a client sending at four times the
tick rate overwrites its own input three times and has exactly one applied, and
displacement follows the host's tick rate.

The failure mode this avoids is quiet. A server that applies input on arrival and
integrates each one by a constant tick duration gives a client sending at 4× a 4×
speed boost — server-authoritatively, with the cheater's own prediction agreeing,
so nothing rubber-bands to reveal it. A queue instead of a latch would be wrong in
the other direction twice over: a fast sender would bank movement, and a normal one
would accumulate latency behind its own backlog.

The latch persisting across ticks is deliberate — a key held down that produced no
packet this frame is still held. Superseded inputs are counted
(`host.stats.superseded`, `peer.inputsSuperseded`) so the property is visible
rather than incidental, and the test drives input at 4× the tick rate and asserts
the displacement matches the 1× run to nine decimal places.

---

## Replication

Already designed, and the reason phase 1 was built the way it was.

Every component declares its own `netFields`; `entity:snapshot()` collects exactly
those and `entity:applySnapshot()` applies them back. So the wire format **derives
from data**. Adding synced state is one edit to a declaration, with no
per-type serialiser to update and forget.

That stays true through the binary codec. `meatray/net/snapcodec.lua` names no
component and no field: it encodes whatever `netFields` produced, reads
`Entity.netFieldsFor` only to get a deterministic field *order*, and carries every
name in a per-packet string table so the format stays self-describing. A peer
whose declarations disagree with the sender's still decodes correctly; it just
pays a few more bytes.

Only the transform is quantised, to IEEE-754 binary32 — 24 significant bits, so
the error is relative: 6.1e-5 tiles at a coordinate of 1024, or 0.004 px at
64 px/tile. Component fields are not quantised at all; a whole number becomes a
varint and anything else picks the narrowest float that reproduces it exactly, so
an ammo count cannot drift. Angles are **not** wrapped on the wire, because the
client interpolates from the previous angle to this one and a wrap would spin
every remote player through a full turn; the cost is that binary32 resolution
decays as an angle accumulates, to about 0.12° after an hour of continuous
turning. That is the first place to look if a jitter report ever arrives.

The save format (`meatray/save/format.lua`) deliberately did **not** move. It
shares `meatray.net.serialize`, and a save file must not change shape because a
packet wanted to be smaller.

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

- **2289 headless assertions** under plain LuaJIT, no LÖVE and no sockets
  (`luajit tests/run_all.lua`). Six of the fourteen suites are networking: the
  wire format, the transport interface and loopback backend, replication end to
  end through a real host and a real client, access control plus diagnostics, the
  protocol contract, and hardening — liveness, flood control, input rate and
  validation. The headless rule is enforced over `meatray/net/` as well as
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
