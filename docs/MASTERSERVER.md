# Master server and NAT traversal

The design for "players can set up a server anywhere". `docs/NETWORKING.md`
covers the three discovery backends and where this one sits among them; this
file is the protocol and the reasoning, at the level someone needs to implement
it or to run their own registry.

**Nothing here is built yet.** It is written before the code so the awkward
parts get argued about while they are still cheap.

## The one rule everything else serves

**A registry outage must never mean the game cannot be played.** `direct` and
`lan` do not depend on this service, the client treats every registry response
as advisory, and a client that cannot reach any registry says so and still offers
direct connect. A server browser that fails closed turns a hosting problem into
an "the game is down" problem.

That is also why the client ships with **two registry URLs**, tried in order.
One hard-coded URL is a single point of failure that only reveals itself the day
it goes down.

## Shape

Reference implementation to study: **Sauerbraten's master server**
(`src/engine/master.cpp`, zlib — the grant is in `src/readme_source.txt`, which
covers `src/` and explicitly excludes media). It is about 600 lines and was
written by ENet's own author, which is the closest thing to authoritative prior
art that exists under a usable licence. **Northstar** is worth reading for its
HTTP route layout and its reverse-probe.

Ours is HTTP + JSON rather than a custom TCP protocol. Not because it is
prettier — because anyone can run one behind an ordinary reverse proxy, debug it
with `curl`, and cache it at the edge. A custom protocol would need every host
to also be a sysadmin.

## Routes

```
POST /v1/announce      a host says it exists, and keeps saying so
GET  /v1/servers       a client asks what is out there
POST /v1/punch         both sides ask to be introduced
GET  /v1/health        is this registry alive
```

### `POST /v1/punch`

```json
{ "port": 62811, "address": "198.51.100.60", "hostPort": 6789 }
```

A joining client asks to be introduced to a listed host. `port` is the client's
**own UDP game port**, read from its transport (`transport:localPort()`); the
client's address, like a host's, comes from the source of the request and is
never taken from the body.

The answer is `{ address, port, sendNow: true }`, and `sendNow` is the whole
protocol: the client must already be connecting by the time it reads this. It is
returned so a reader of the protocol knows the rule, not so a client can wait for
permission — whichever side sends second is the side whose packet arrives at a
router that has not opened yet.

The host is told on the response to its next `POST /v1/announce` heartbeat, in a
`punches` array of `{ address, port }`. Collecting them is destructive; there are
no repeats.

**The nudge.** Heartbeats are ten seconds apart, so an introduction that only
rode the heartbeat would keep a client waiting an average of five seconds for the
host to hear about it at all. On accepting a punch the registry therefore sends
one UDP datagram — the literal string `meatray-punch-waiting`, no payload — to
the host's *challenge* port, and the host brings its next heartbeat forward. The
introduction itself still travels over HTTP on that heartbeat.

Three properties this shape has on purpose. It carries no client address, so a
forged nudge cannot make a host send packets at a third party — the worst it can
do is provoke one early heartbeat to a registry the host chose. Beacons rate-limit
nudges to one a second, so it cannot be used to amplify. And losing it costs
nothing: the heartbeat that was always going to happen still carries the punch.
Observed on loopback, the nudge turns a worst case of ten seconds into 17 ms.

**What a registry does not do here.** It does not relay, and it does not verify
that a punch worked. Only the two peers can know that, and neither of them is
told to report it — a registry that published punch outcomes would be publishing
a claim it cannot check.

### `POST /v1/announce`

```json
{ "name": "...", "map": "...", "players": 3, "maxPlayers": 8,
  "port": 6789, "protocol": 2, "locked": false }
```

**The host never sends its own address.** The registry binds the entry to the
source IP of the request. A host that could name its own address could list
someone else's, which turns the browser into a DDoS amplifier pointed at whoever
the attacker names.

If the registry sits behind a proxy or CDN, the real client IP must come from a
trusted header (`X-Forwarded-For` and friends) **configured explicitly from day
one, with a trusted-proxy allowlist**. Trusting that header from an arbitrary
source is the same forgery bug wearing a different hat, and retrofitting it
later means every entry recorded before the fix is wrong.

Responses carry a token; subsequent heartbeats present it. **Entries expire 30
seconds after the last heartbeat.** A stale list is worse than a short one: a
server you cannot join is indistinguishable, from the player's side, from a game
that does not work.

### Challenge before listing

An announce is not listed until the registry has proven something is actually
listening at that address and port. It sends a nonce to the claimed UDP endpoint
and waits for it to come back.

This is the single most important anti-abuse measure and it is cheap. Without it
the registry will list anything anyone claims, including addresses chosen to
make clients attack a third party.

### `GET /v1/servers`

Returns the list, newest heartbeat first, with `ping` left for the client to
measure itself — a registry-measured ping is the distance from the *registry* to
the host, which is not the number the player cares about.

The response is cacheable for a few seconds. At any plausible scale this is a
static file regenerated on a timer, and saying so keeps anyone from building a
database they do not need.

## NAT traversal

Tried in order, and **the host is told the truth about which one it got**:

1. **Direct** — the port is forwarded, or it is a LAN game, or a VPS.
2. **Hole punch** — the registry introduces both peers; both send simultaneously
   so each router sees an outbound packet first and accepts the reply.
   **Implemented**, see `POST /v1/punch` above.
3. **Relay** — traffic is forwarded when no direct path exists. Costs bandwidth,
   so it is last. **Not implemented**, and read the next section before assuming
   that is fine.

### Expect 55–80% direct, not 90%

The commonly-quoted ~90% hole-punch success rate does not survive reading the
source it comes from. libp2p's headline figure of 70% ± 7.1% is a **per-network
mean conditional on reaching the punch stage at all**; pooled conditional success
is 57%, and end-to-end — counting the attempts that never got that far — is 40%.
The authors themselves note their measured population skews permissive. Tailscale
has never published a number.

So **the relay is not an optional extra for the last few percent.** It is load
bearing for something like a fifth to a half of hosts, and a design that treats
it as a rare fallback will be wrong about its own bandwidth bill.

### Symmetric NAT detection is a diagnostic, not a decision

Comparing the mapped address reported by two different STUN servers detects a
symmetric NAT well enough to *explain* a failure to a user. It is not reliable
enough to *skip* the punch attempt: RFC 5389 §2 explicitly declares the classic
NAT-type classification faulty, which is why it was removed from the spec.

Always attempt the punch. Use the detection only to write a better message when
it fails.

This is why the relay's absence is called out in the roadmap rather than filed
under polish, and why a failed punch in this engine ends in a stated reason and
an instruction (forward the port, or use a dedicated server) rather than in a
retry loop.

Watch for `100.64.0.0/10` (CGNAT). A host behind carrier-grade NAT has no
forwardable port at all, and telling it to forward one wastes an evening.

### Diagnostics are the feature

```
[net] listening on UDP 6789
[net] LAN beacon active - local players can join
[net] ! master server cannot reach you from outside
[net]   hole punch attempted, failed (symmetric NAT)
[net]   forward UDP 6789 to this machine, or use a dedicated server
```

An empty server list with no explanation is the most common way self-hosting
silently defeats people. The registry knows whether its challenge got a reply, so
the host can be told the moment it is unreachable rather than after nobody joins
for an hour.

## Protocol version is part of the listing

`protocol` is in the announce payload and shown in the browser. The snapshot
codec bumped `P.VERSION` to 2, and a v1 client joining a v2 host fails in the
worst available way — handshake succeeds, world builds, no entity ever appears.
A browser that shows the version turns that into a visible mismatch instead of a
game that looks broken.

## Running your own

The registry is a reference implementation, not a service. The protocol above is
the whole contract: anything answering those four routes is a valid registry, and
pointing a build at a different one is a config change. A game that wants a
private registry for a community should not have to fork the engine to get one.
