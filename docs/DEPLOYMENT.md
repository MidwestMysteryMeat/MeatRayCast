# MeatRayCast — running it in production

**As of 2026-08-03.** This is the operational runbook: how to stand up a
dedicated game server, a master server (registry + NAT punch), and a relay for
the clients direct connection cannot reach; what ports to open; how to watch a
running server; and how to size bandwidth and cost before the bill arrives.

It is the operational companion to the two design docs — `NETWORKING.md` (how
the netcode works) and `MASTERSERVER.md` (the registry protocol and NAT
traversal) — and to `SECURITY.md` (the trust boundary you are exposing to the
internet). Read those for *why*; this is *how to run it*.

---

## The three processes, and which you actually need

| Process | Transport / port | Needed when |
|---|---|---|
| **Dedicated game server** | UDP **6789** (`Host.DEFAULT_PORT`) | always — this is the game |
| **Master server** (registry) | TCP **8080** + a challenge **UDP** port | you want a public server list + NAT punch |
| **Relay host** | UDP **6790** (`RelayHost.DEFAULT_PORT`) | some clients cannot be punched to a direct link |
| *(LAN discovery)* | UDP **27780** (`LAN.PORT`) | LAN only; no configuration, no server process |

The smallest real deployment is **one game server on UDP 6789** and nothing
else: players join by `IP:port`. The master server and relay are what turn that
into a discoverable, NAT-traversable service. They are independent — run either,
both, or neither.

---

## 1. The dedicated game server

Headless, no window, one map:

```
love . --server --port 6789 --map arena
```

Add discovery so it announces to a registry (and turns on hole punching):

```
love . --server --port 6789 --map arena \
    --registry http://your-registry:8080 --name "Frag House"
```

- `--server` runs the fixed-tick host loop with no graphics (see `NETWORKING.md`
  §"one step function").
- The RCON admin channel is **off** unless `MEATRAY_RCON_SECRET` is set in the
  environment (never on the command line — it would land in `ps` and shell
  history). With it set, `rcon` clients authenticate with a constant-time digest
  compare and a lockout; see `SECURITY.md`.
- Turn on automatic flood banning with the host option `floodBan = true` if the
  server is public and unattended.

### A systemd unit (the shape, not a copy-paste)

```ini
[Unit]
Description=MeatRayCast game server
After=network-online.target

[Service]
# Never run a public game server as root.
User=meatray
WorkingDirectory=/opt/meatraycast
Environment=MEATRAY_RCON_SECRET=%LOAD_FROM_A_SECRETS_FILE%
EnvironmentFile=/etc/meatraycast/server.env
ExecStart=/usr/bin/love . --server --port 6789 --map arena --registry http://127.0.0.1:8080
Restart=on-failure
RestartSec=5
# A crashed handler is logged and the server keeps running; a crashed PROCESS
# is what this restarts. Cap the churn so a boot-loop does not hammer the CPU.
StartLimitIntervalSec=60
StartLimitBurst=5

[Install]
WantedBy=multi-user.target
```

Put the RCON secret in `/etc/meatraycast/server.env` (mode `0600`, owned by the
service user), not in the unit file.

---

## 2. The master server (registry)

A reference registry ships in `masterserver/`. It answers the four routes
`MASTERSERVER.md` documents (`/v1/announce`, `/v1/servers`, `/v1/punch`, plus the
challenge) and owns **two** listeners:

```
love masterserver --port 8080
```

- **TCP 8080** — the HTTP registry (`Server.DEFAULT_PORT`). Announcements and
  listings.
- **A challenge UDP port** — the registry proves a game server's UDP port is
  actually open before it will list it (`portVerified`), because a TCP announce
  says nothing about whether the *game* port is reachable. Anything not ENet on
  the game port is dropped, so the challenge needs its own socket.

Behind a reverse proxy, set `--trusted-proxy <ip>` or **every server files under
the proxy's address** and the whole listing looks single-homed. If you terminate
TLS at the proxy, the registry still speaks plain HTTP behind it — the protocol
is `http:` only by design (`MASTERSERVER.md`).

The registry is a **reference implementation, not a hosted service**: anything
answering those routes is valid, and pointing a build at a different one is a
config change (`--registry`), never a fork. Run your own for a community.

---

## 3. The relay

Direct connection succeeds for most clients but not all — expect **55–80%
direct, not 90%** (`MASTERSERVER.md` §"Expect 55–80% direct"). A symmetric NAT on
either end defeats hole punching, and those players need a relay: a rendezvous
that both sides *can* reach, forwarding datagrams between them.

```
love relayserver --port 6790
love relayserver --port 6790 --secret my-community-secret
love relayserver --max-sessions 4 --session-kbps 128 --total-kbps 512
```

- **UDP 6790** (`RelayHost.DEFAULT_PORT`), a fixed number of sessions × slots.
- Frames are the wire format in `meatray/net/relaywire.lua`; the relay forwards,
  it does not inspect game state.
- **Cap the bill at the tool, not on the invoice.** `--total-kbps` bounds total
  relay egress and `--session-kbps` bounds one session; `--max-sessions` bounds
  concurrency. The relay's own header states the arithmetic: at the engine's
  ceilings (snapshotRate 20, `MTU_SAFE_BYTES` 1364, inputRate 30) **one relayed
  client costs about 30 kB/s of relay egress** — set the caps knowing that.
- `--secret` restricts who may open a session (a community relay that is not an
  open one).
- `relaycheck` (and `scripts/relaycheck.ps1`) is the reachability probe — run it
  from a client network to confirm the relay is actually forwarding before
  blaming a join.

A relay carries **both directions of every relayed session**, so its bandwidth
is the sum of the game traffic it stands in for — size it against the *relayed
fraction* of your players, not all of them (see cost, below).

---

## 4. Firewall

Open only what a role needs:

| Role | Inbound |
|---|---|
| Game server | UDP 6789 |
| Master server | TCP 8080, plus its challenge UDP port |
| Relay host | UDP 6790 |
| LAN only | UDP 27780 (never needs to cross a router) |

Everything is UDP except the registry's HTTP. Outbound: a game server announcing
to a registry needs to reach the registry's TCP 8080.

---

## 5. Monitoring a running server

The host already counts everything worth watching; `SECURITY.md` lists the
trust-boundary counters. Two ways to read them off a live server:

- **`stat net`** in an attached console (or the demo's), which prints the
  connection line plus `refused: N malformed, N wrong-way, N flood, N throttled,
  N rejected, N bans`.
- **The stats reply** — every `statsReply` carries a `security` block
  (`HostMT:securityStats()`), so a monitoring client can poll it. It also carries
  the bandwidth counters (`snapshotByteTotal`, `keyframesSent`,
  `snapshotFallbacks`, `worldSyncs`) the codec's win is measured with.

What healthy looks like:

- `malformed` / `wrongWay` near zero and flat. A climbing count from one address
  is probing or a version mismatch.
- `limited` occasional and per-peer — a single flooder, handled. Broadly rising
  `limited` means your flood presets are tighter than real play (`Host.FLOOD`);
  loosen them before you mute your own players.
- `throttled` is **not** abuse — it is input bunching after a lag spike, dropped
  silently by design. Watch it for network health, not for cheating.
- `handlerErrors` should be **zero**. Any non-zero is a server bug, always logged
  with its tag; treat it as an alert, not a metric.

The master server logs each announce and challenge result; a server that
announces but never verifies is one whose UDP game port is firewalled.

---

## 6. Bandwidth and cost

The numbers are measured, not guessed (`NETWORKING.md` §"Transport"):

- Snapshots go out at the **snapshot rate (default 20/s)**, each capped at
  **`MTU_SAFE_BYTES` = 1364 bytes** so it stays a single unreliable datagram.
- A partial (dirty-flag) snapshot is **~28–47 bytes per moving entity**; a
  keyframe is **~141–181 bytes per entity**. The dirty-flag codec is the whole
  reason a busy server is affordable — a still entity costs nothing until it
  moves.

**Downstream, per player, rough:** `20 snapshots/s × (bytes/snapshot)`. With a
handful of moving entities a partial is well under 200 bytes, so a player costs
on the order of **~4 KB/s down (~32 kbit/s)** in ordinary play, spiking toward
the 1364-byte cap only when a keyframe or a busy scene lands. Upstream from a
player is tiny — input packets at the input rate (default 30/s), a few dozen
bytes each.

**Per game server:** downstream scales with players **and** with how much is
moving (dirty flags), not with player-count squared — the host sends each player
one tailored stream, not N copies of the world. Budget the cap as the ceiling:
`players × 20/s × 1364 bytes` is the worst case (all keyframes, full frames);
real traffic runs a fraction of it.

**Relay cost is the multiplier to watch.** A relayed session pays for *both*
directions through the relay, so relay egress ≈ the game traffic of the relayed
fraction, doubled. If 20% of players need a relay, budget the relay for ~40% of
one game server's player-bandwidth. This is why direct connection matters and
why the master server invests in punch success (`MASTERSERVER.md`): every
direct connection is a relay byte you do not pay for.

**Sizing rule of thumb:** metered egress is the cost that bites, and it is
dominated by *downstream snapshots × players*. A single small VPS comfortably
hosts a game server and a registry; a relay for a large public population is the
line item that grows, so scale relays horizontally (they are stateless between
sessions) and keep the direct-connection rate high.

---

## What is not yet here

- **Real-world NAT + long-session validation (D37):** this runbook is sound
  against the headless and loopback tests; the one thing no test substitutes for
  is a run on real hardware across real NATs. See `docs/FIELD_QA.md`.
