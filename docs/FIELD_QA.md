# Field QA runbooks

Engine code for these paths is implemented. Closing the items needs hardware,
accounts, or hosting money — not more Lua. Use this as the checklist.

## 1. Multi-NAT UDP hole punch

**Code:** `meatray/net` punch path, master-assisted intro, `tests/test_net_punch.lua`
(loopback only).

**What loopback cannot prove:** two real NATs, mapping behaviour (full-cone vs
symmetric), and that the master intro packet actually arrives at both hosts.

### Setup

1. Two machines on **different** residential (or mobile hotspot) networks.
2. One runs a master server the both can reach (`docs/MASTERSERVER.md`).
3. Host A: `love . --server --port <p> --announce <master-url>`.
4. Host B: discover via master browser, connect (not LAN IP).

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

Relay egress dominates. Cap concurrent relayed sessions if you are paying per GB.
Direct punch after intro is free to you once it works.

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

## 4. Not field-testable here

| Item | Status in engine |
|---|---|
| Music / richer audio | **Code done** — `meatray.asset.music` + SFX bus; needs real WAV content |
| Asset streaming / unload | **Code done** — `Registry.unload` / `evict` / `pin` / `preload` |
| Mirrors / portals | **Research only** — no clean tile-raycaster approach; see `docs/RESEARCH.md` |
