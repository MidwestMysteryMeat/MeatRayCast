# Field QA runbooks

Engine code for these paths is implemented. Closing the items needs hardware,
accounts, or hosting money — not more Lua. Use this as the checklist.

**Before you start**, stand the processes up with `docs/DEPLOYMENT.md` (ports,
systemd, firewall) and know the trust boundary you are exposing
(`docs/SECURITY.md`). Every runbook below assumes the server is reachable and
monitored per those two docs.

## 1. Multi-NAT UDP hole punch

**Code:** `meatray/net` punch path, master-assisted intro, `tests/test_net_punch.lua`
(loopback only).

**What loopback cannot prove:** two real NATs, mapping behaviour (full-cone vs
symmetric), and that the master intro packet actually arrives at both hosts.

### Setup

1. Two machines on **different** residential (or mobile hotspot) networks.
2. One runs a master server both can reach (`docs/MASTERSERVER.md`,
   `docs/DEPLOYMENT.md` §2).
3. Host A: `love . --server --port <p> --registry http://<master>:8080`.
4. Host B: discover via the master browser (`love . --browse` filters, or the
   in-game browser), connect **by listing, not by A's LAN IP**.

### Pass criteria

- [ ] B joins without typing A’s public IP.
- [ ] Gameplay input works both ways for ≥ 2 minutes.
- [ ] Optional: both behind symmetric NATs → expect **relay fallback**, not a hang.
- [ ] Packet capture (Wireshark): STUN-like intro, then direct UDP, or relay only.

### Failure notes

Record NAT type (if known), master log lines for intro, and whether relay was
offered. File under issues with those three; the code path is already gated.

---

## 2. Public master + relay deployment

**Code:** `masterserver/`, `relayserver/`, docs in `docs/MASTERSERVER.md`.

**What remains:** choose a host, pay for bandwidth, put TLS/DNS in front if you
want a public URL, monitor disk/CPU.

### Minimal public deploy

1. VPS with a public IPv4 (and IPv6 if you care).
2. Run master on an open TCP port; relay on its documented UDP/TCP ports.
3. Point game clients at `https://your.master/…` (or plain HTTP for a private test).
4. Announce a test host; confirm a second client on another network sees it.

### Cost notes

Relay egress dominates (~30 kB/s per relayed client, both directions summed).
Bound it at the tool with `--total-kbps` / `--session-kbps` / `--max-sessions`
rather than on the invoice (`docs/DEPLOYMENT.md` §3, §6). Direct punch after
intro is free to you once it works — every point of punch-success rate is relay
bytes you do not pay for.

---

## 3. Steam two-account lobby QA

**Code:** Steam transport + discovery backend; unit coverage in
`tests/test_discovery_steam.lua` (mocked).

### Setup

1. Two Steam accounts, both own / have access to the build.
2. Steam client logged in on two machines (or two OS users).
3. Enable the Steam backend in the build you are testing.

### Pass criteria

- [ ] Host creates a lobby; second account sees it in the in-game browser.
- [ ] Join succeeds; entity snapshots arrive; input is authoritative-host correct.
- [ ] Leave / rejoin does not desync world seed or door state.
- [ ] Friend-only vs public lobby visibility matches the flags you set.

### Failure notes

Steamworks API return codes, lobby ID, and whether fallback LAN discovery still
works when Steam is offline.

---

## 4. Long-session soak (the one only real time closes)

**Code:** the whole host loop; `tests/` cover minutes over loopback, never hours
over a real link. This is the run that finds the slow leak, the counter that
only climbs, and the desync that needs a thousand door toggles to show.

### Setup

1. One dedicated server (`docs/DEPLOYMENT.md` §1), `floodBan = true`, RCON on via
   `MEATRAY_RCON_SECRET`.
2. Two+ clients on different networks, at least one across a NAT.
3. Start a demo recording on one client (`F6`) so any divergence names its first
   bad tick (`meatray.sim.demo`).

### Run it for hours, then check

- [ ] **No memory growth** on the server process over the session (watch RSS).
- [ ] **`stat net` counters stay sane** (`docs/SECURITY.md`): `handlerErrors`
      **0**; `malformed`/`wrongWay` flat; `limited` only ever a handled flooder;
      `throttled` tracks lag, not abuse.
- [ ] **Bandwidth holds** to the `NETWORKING.md` budget — `snapshotByteTotal` in
      the stats reply grows linearly, no runaway keyframes
      (`snapshotFallbacks` not climbing).
- [ ] **World state stays converged**: churn doors, push-walls, hazards, a
      `mover` lift (C-map), and a live `map` change (B14); the demo checksum
      reports no divergent tick.
- [ ] **Reconnect is clean**: kill a client's network, let it time out, rejoin —
      no desync of seed, doors, or entity ids; automap fog resets on a map
      change but not on a plain rejoin.
- [ ] **RCON survives**: `status`/`kick`/`map` still authenticate and act after
      hours; a wrong password still locks out.

### Failure notes

Capture the server log, the demo file (it names the first divergent tick), the
final `stat net` line, and the server RSS curve. A climbing counter or a growing
RSS is the whole finding — attach the number.

---

## 5. Not field-testable here

| Item | Status in engine |
|---|---|
| Music / richer audio | **Code done** — `meatray.asset.music` + SFX bus; needs real WAV content |
| Asset streaming / unload | **Code done** — `Registry.unload` / `evict` / `pin` / `preload` |
| Mirrors / portals | **Research only** — no clean tile-raycaster approach; see `docs/RESEARCH.md` |
