# MeatRayCast — the network trust boundary

**As of 2026-08-03.** This document states, plainly, what a MeatRayCast host
trusts and what it verifies. It is the companion to the netcode: the code
enforces the boundary, this explains where the boundary *is*, so a server
operator knows what a client can and cannot make the host do, and a contributor
knows which side of the line a new message falls on.

The one rule everything else follows: **the host is authoritative, and a client
is an untrusted source of requests.** A packet from a client is a request to be
validated, rate-limited and then acted on — never a fact to be believed.

---

## What arrives from a client, and what the host does with it

Every packet a joined client sends runs the same gauntlet, in this order
(`HostMT:onReceive`, `meatray/net/host.lua`). A packet that fails any stage is
counted and dropped; nothing is half-applied.

1. **Parse** (`P.unpack` with `P.limits`). Malformed, oversized, or unknown-tag
   packets are refused before a single field is read. A hostile packet returns a
   reason; it never raises into the service loop. → `malformed`
2. **Direction** (`P.travels(kind, C2S)`). A client sending a *server→client*
   tag (a SNAPSHOT, an ACCEPT, a MAPCHANGE) is claiming to be the server. There
   is no handler for it and there must never be one. → `wrongWay`
3. **Schema** (`P.check`). Whole-message field validation — types, finite
   numbers (NaN and ±inf are rejected), string lengths — before any handler sees
   a field. → `malformed`
4. **Handshake gate.** Everything but `JOIN` requires a completed handshake. A
   peer that skips the join and starts sending inputs gets nothing. → `dropped`
5. **Rate limit** (`HostMT:_permit`). Two tiers, below. → `throttled` / `limited`
6. **Handler.** Only now does the game logic run, and it may still refuse the
   request (bad RCON password, illegal request). → `rejected`

### The two rate-limit tiers

- **Silent throttle** — `INPUT` only. A minimum spacing (120/s, far above any
  client's send rate) with **no strike, no mute, no ban, ever**. An input stream
  that bunches up after a network stall is a laggy player, not an attacker;
  running it through the penalising limiter is how a server throws out its own
  players. Excess is dropped and forgotten. → `throttled`
- **Penalising window** — every other client-reachable tag
  (`Host.FLOOD`). Each has a human rate (a chat line is typed; a vote is called a
  handful of times a minute). Exceed it and the tag is muted for that peer for an
  escalating penalty; keep at it and, if `floodBan` is on, the peer is banned.
  → `limited`

`JOIN` is limited by **address**, not by connection, because a peer retrying the
handshake gets a new connection key each time; the others are limited per peer.

`RCON` and `VOTE` are in the penalising tier deliberately: `RCON` carries a
password guess, so the network limiter caps guess *throughput* before the
app-level lockout (`meatray/net/rcon.lua` — constant-time digest compare,
fail-closed with no secret, lockout after repeated failures) even runs; `VOTE`
is a griefer's spam button.

---

## What the host does NOT trust

- **Movement.** A client sends intent (`forward`, `strafe`, `angle`), never a
  position. The host simulates the move; there is no path from client input to
  an authoritative position, so a client cannot teleport by lying.
- **Aim, for damage.** Hitscan is resolved on the host against the host's world,
  with lag compensation the host bounds itself (it takes the round-trip from the
  transport, which measures it, and clamps the rewind window — it does not take
  the client's word for how far back to look).
- **Identity in chat.** A client sends only the text it typed; the host attaches
  the speaker name. A client trusted to name the speaker could name anyone.
- **The map.** Only the host chooses the level. A map change re-sends the whole
  world (`P.MAPCHANGE`); a client cannot induce one.
- **Effects and attributes.** `Effects.apply` refuses on a non-authoritative
  container, so damage cannot be predicted — even by accident — on a client.

## What a client legitimately owns

- **Its own view.** Pitch is presentation only and never goes on the wire.
- **Its own prediction.** A client predicts its own movement and reconciles
  against the host's snapshots; a mismatch corrects the client, never the host.

---

## Watching the boundary from a running server

`HostMT:securityStats()` returns the reject counters, and they ride in every
`statsReply` (the `security` block) so they can be read off a live server the
same place bandwidth is. The demo surfaces them in `stat net`:

```
refused: 3 malformed, 0 wrong-way, 12 flood, 0 throttled, 1 rejected, 0 bans
```

| Counter | Meaning |
|---|---|
| `malformed` | failed to parse or failed its schema |
| `wrongWay` | a client sent server→client traffic (claiming to be the server) |
| `limited` | refused by the penalising flood window |
| `throttled` | input dropped by the silent throttle (not abuse — lag) |
| `rejected` | a handler refused it (bad auth, illegal request) |
| `handlerErrors` | a handler raised (a host bug, always logged, never sent) |
| `bans` | addresses currently banned |

A healthy server shows small, stable numbers here. A climbing `limited` or
`malformed` from one peer is what abuse looks like before it is a problem;
`floodBan` turns the worst of it away automatically.

---

## Where the boundary is NOT yet complete

- **Mover replication (C18).** A lift authored in a `.map` animates floor heights
  locally; those heights are not yet in the world delta, so a lift does not
  replicate to clients. Single-player and listen-host-local only until C18.
- **Field validation under real NAT/loss (D37).** The boundary is tested
  headless and over loopback; a run on real hardware across real NATs is the one
  check no test substitutes for.

These are tracked in `docs/BACKLOG_SCHEDULE.md`; neither is a hole a client can
exploit for authority — they are gaps in *replication* and *coverage*, not in
the trust rule.
