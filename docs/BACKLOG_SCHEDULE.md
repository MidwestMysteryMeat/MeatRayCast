# MeatRayCast — full backlog & completion schedule

Master queue for **all pending / unimplemented features** from `NEXT_FEATURES.md`,
plus **10 new researched features** (section F). Status reflects repo after
A1 campaign module.

**How work is scheduled:** Grok automations (and/or session agents) pick the
**lowest unfinished wave ID**, implement, test (`luajit tests/run_all.lua`),
commit without AI attribution trailers, push `main`, update this file’s status
column.

**Constraints (never violate):** headless sim, `netFields` for wire state, no
AI commit trailers, generated artifacts under `F:\` when outside repo, suite green
before push.

---

## Status legend

| Mark | Meaning |
|:---:|---|
| ✅ | Shipped in engine |
| 🔶 | Partial / API only |
| ⬜ | Not started |
| ⛔ | Deferred / research-only |

---

## Wave 0 — Already shipped (do not re-open)

| ID | Feature | Status |
|---|---|:---:|
| C11 | Sky gradient / outdoor wash | ✅ |
| C12 | Masked walls | ✅ |
| C13 | Elevators (`sim.movers`) | ✅ |
| C14 | Minimap (`render.minimap`) | ✅ |
| C15 | AI investigate / last-known | ✅ |
| E20 | Continuous slopes (`smoothFloors`) | ✅ |
| — | Multi-storey, MST worldgen, music, asset LRU, net stack | ✅ |

---

## Wave A — Ship a game (P0) · **COMPLETE** · next wave: F high (F1–F5)

| ID | Feature | Status | Notes |
|---|---|:---:|---|
| A1 | Campaign / mission flow | ✅ | `meatray.game.campaign`: map chain, exit vol, win/lose, credits, progress snap |
| A2 | Stock modes (DM / co-op / SP objectives) | ✅ | `meatray.game.modes`: DM/TDM/coop/SP, frag/time limits, teams, objectives |
| A3 | Input remapping + options menu | ✅ | `meatray.game.options`: binds file, sens, invertY, volume buses, menu rows |
| A4 | HUD / feedback kit | ✅ | `meatray.game.hud`: bars, damage/heal flash from pool deltas, hit marker, direction indicators, low-hp pulse; drawn in main.lua |
| A5 | Death, respawn, spawn-protect | ✅ | `meatray.game.respawn`: tick-driven wait, protection as an immunity effect, farthest-spawn pick; demo wires the local player (solo + hosted); remote peers connect via modes' onRequestRespawn → notifyDeath |
| A6 | Secrets, push-walls, key doors | ✅ | `meatray.game.secrets` + world locks/push-walls + `lock`/`pushwall`/`secret` map headers; residual: locks/push-wall state ride map headers, not the mid-session save payload |
| A7 | Graphics options persistence | ✅ | `options.graphics`: scale/fov/pitchLimit/floorCast/lightTexture + low\|medium\|high presets, `applyGraphics` to the renderer, demo renders through a scaled canvas (F2 quality, F3/F4 fov) and saves |
| A8 | Pause + MP disconnect policy | ✅ | `meatray.game.session`: role-based pause policy (solo pauses, client refused, host opt-in), menus separate from pauses, one-way ending that keeps the FIRST disconnect reason; demo gates the solo clock, overlays both states, P to pause/restart |

**Exit:** stranger finishes a 3-map campaign with their own keybinds.

---

## Wave B — Authoring (P1)

| ID | Feature | Status | Notes |
|---|---|:---:|---|
| B9 | Editor entity / spawn palette | ✅ | `meatray.ui.map_entities` (headless edit logic: replace-or-create, kept angles, wrapped rotate) + panel palette from Entity.archetypeNames, click-to-select, inspector rotate/delete. Known format limit, pinned by test: facing does not survive the text grid |
| B10 | Trigger / MeatGraph plan UX | ⬜ | volumes on plan, graph picker |
| B11 | Prefab rooms / entities | ⬜ | stamp kits |
| B12 | Map validation linter | ✅ | `meatray.sim.maplint`: flood-reachability (doors passable), spawn/exit/entity in-solid, lock-no-door, push-wall-blocked, key/stairs/link/box warnings; `scripts/maplint.lua` CLI (exit 1 on error); editor save surfaces it; suite lints every shipped map as an anti-rot gate |
| B13 | Asset pack format | ⬜ | dir/zip + `pack.json` |
| B14 | Hot-reload map on host | ⬜ | editor → play |
| B15 | Localization strings table | ⬜ | UI + mode text |

**Exit:** second person authors map+graph; dedicated server runs it unchanged.

---

## Wave C polish — presentation leftovers

| ID | Feature | Status | Notes |
|---|---|:---:|---|
| C16 | Inventory UX + pickup feedback | ⬜ | bag UI |
| C17 | Door auto-close + keyed kit (map headers) | 🔶 | logic partial |
| C18 | Mover ↔ host WORLD sync | 🔶 | movers snapshot exists; wire it |
| C19 | AI hear / investigate sound | ⬜ | beyond last-known visual |
| C20 | Dialogue / camera rails | ⬜ | campaign |
| C21 | MeatGraph stock event nodes | ⬜ | all-dead, timer wave |
| C22 | Bot players | ⬜ | fill lobbies / offline |
| C23 | Meta progression unlocks | ⬜ | between campaigns |
| C27 | Particle / impact VFX kit | ⬜ | tracers, sparks |
| C28 | Screen effects library | ⬜ | damage, underwater, flash |
| C30 | Footsteps / surface materials | ⬜ | tile tags |
| C31 | Ambient sound zones | ⬜ | room tones |
| C-map | Map headers for mask/anim/movers | ⬜ | authoring completeness |

---

## Wave D — Multiplayer product (P4)

| ID | Feature | Status | Notes |
|---|---|:---:|---|
| D32 | Server browser polish | 🔶 | filters, mode, map, ping |
| D33 | Dedicated console / RCON | ⬜ | kick, map, say, status |
| D34 | Anti-cheat boundaries | 🔶 | rate limits, reject metrics |
| D35 | Spectator + simple killcam | ⬜ | |
| D36 | Voice chat hook | ⛔ | prefer Steam/Discord |
| D37 | Field QA execution | ⬜ | `docs/FIELD_QA.md` on real hardware |

---

## Wave E — Geometry research (optional)

| ID | Feature | Status | Notes |
|---|---|:---:|---|
| E21 | Build-style sectors | ⛔ | different engine |
| E22 | Portal research prototype | ⛔ | throwaway only |
| E39 | Segments first-class for AI/doors | ⬜ | thin walls everywhere |
| E42 | Mirrors / recursive portals | ⛔ | no clean OSS path |
| E43 | GPU DDA | ⛔ | optional later |

---

## Wave F — 10 additional unique features (research 2026)

Features **not** already first-class on the prior list, chosen for a *networked
tile raycast engine* (gaps vs Doom/Build/Source ports + modern indie FPS).

| ID | Feature | Why unique / needed | Priority |
|---|---|---|:---:|
| F1 ✅ | **Deterministic demo record & playback** | `meatray.sim.demo`: delta-encoded input + tick-stamped events + %.17g floats, per-second checksums name the FIRST divergent tick; F6 record / F7 replay in the demo (solo loop). Residual: MeatGraphRay `Randi` without an injected rng is out-of-stream randomness | High |
| F2 ✅ | **Explored automap memory (fog of war)** | `meatray.game.automap`: LOS reveal (walls seen, rooms behind them dark), per-storey, shape-change re-look, capture/restore as strings; minimap fog hides tiles AND entities | High |
| F3 ✅ | **Dev console + cvars** | `meatray.game.console`: typed/clamped cvars with onChange, commands, history, tab completion, cheat gating as a question answered at execute time (client and running demos refuse); demo wires \` overlay + noclip/god/give/map/stat net/quit | High |
| F4 ✅ | **Intermission / end-level stats screen** | `meatray.game.intermission`: staged count-up rows (time vs par, kills/total, secrets %, automap coverage, deaths), two-press confirm; demo gains a real 3-mission campaign (console `campaign`) wired through it | High |
| F5 ✅ | **Hazard & liquid volumes** | `meatray.game.hazards`: kinds-as-data (water/slime/lava), accumulated graced bites through Damage.applyWith (armour/resist/god all compose), slow as a question movement multiplies by, `hazard` map header round-trips; slime strip in secrets.map | High |
| F6 | **Centerprint / pickup ticker / message queue** | Doom `HUDMessage`, Source `centerprint` — engine-owned, not ad-hoc notes. | Med |
| F7 | **MP vote system** | Map/kick/restart votes on dedicated — Zandronum/EDuke staple. | Med |
| F8 | **Accessibility suite** | Colorblind palettes, screen-shake scale, subtitle events, hold-to-toggle sprint. Modern ship bar. | Med |
| F9 | **MeatGraph sandbox ACL** | User/mod graphs: allowlist nodes, CPU budget, no host FS — required before workshop. | Med |
| F10 | **Photo / free-cam mode** | Detached camera, hide HUD, timed pause — trailers & level shots without cheats. | Low-Med |

## Wave G — hardening & ship (added 2026-08-03)

Two sources: the external repo audit (CI, fuzzing, compat tests, benchmarks,
packaging) and the residuals each shipped wave left behind, gathered here so
they stop living only in commit messages.

| ID | Feature | Status | Notes |
|---|---|:---:|---|
| G1 | **In-game shell: title, options, campaign, join screens** | ✅ | `meatray.game.menu` screen-stack model (all row kinds, bind/text capture, propose/dispose split); demo boots to title (args = intent, skip it), esc opens it in-game via session pause, options screen renders menuRows live with bind capture, join/host/campaign/roam/quit rows wired |
| G2 | Locks, push-walls, secrets, hazards, automap in save + join payload | ✅ | Rep.worldPayload/buildWorld carry locks, half-slid push-walls (current tile + distance left), secret + hazard boxes, both payload kinds; pre-G2 payloads still build; automap rides save meta (asserted through the full save document) |
| G3 | Remote-peer respawn | ✅ | Host ledger on the fixed tick + new P.RESPAWN tag (contract-registered); client rebinds by entityId off the next snapshot exactly as it bound off ACCEPT; onPeerRespawn hook applies the game's shield; `respawn = false` for elimination modes |
| G4 | MeatGraph deterministic rng | ✅ | math.random gone from both paths (proven by making it fatal in the test); apiFor derives an engine LCG from `seed`, bindMode memoizes ONE generator across per-event api rebuilds, injected rng still wins |
| G5 | Packet fuzzing harness | ✅ | `meatray.net.fuzz`: 5 parsers (protocol.unpack, snapcodec.decode, relaywire parse/ticket, masterserver request) × truncate/flip/splice/garbage, seeded LCG so failures replay, sanity floor (parsers accept own samples). Suite runs ~6k inputs; `scripts/fuzz.lua` deep. Verified clean over 200k inputs |
| G6 | Wire & save compatibility corpus | ⬜ | Golden files: packets and saves emitted by TODAY'S build, committed, decoded by every future build. The test that turns "we bumped the format" from a silent client kick into a failing diff. |
| G7 | Benchmark suite + budgets | ⬜ | bench.lua exists for the renderer A/B; extend to snapcodec encode/decode, worldgen, gas step, checksum. Record numbers in-repo; fail the lane on a gross (>2x) regression, warn on drift. |
| G8 | Release packaging | ⬜ | scripts/package.ps1: build .love, fuse win64 exe, strip editor + tests + docs/media, stamp version from git describe, smoke-boot the artifact. The audit's "release packaging" row. |
| G9 | CI workflows | ⛔ **blocked** | Files can be authored, but pushes touching .github/workflows/* are rejected until the owner runs `gh auth refresh -s workflow`. When unblocked: suite.ps1 both-lane job + selftest under xvfb-love + nettest. |

**Exit:** a stranger downloads a zip, double-clicks, and reaches the campaign
through menus; a fuzzer cannot crash a host; the next format change fails a
test instead of a player.

---

### Research sources (summary)

- Classic ports: automap, demos, intermission, secrets (Doom/Wolf).
- Multiplayer ports: votes, RCON, spectator (Zandronum, EDuke32).
- Source engine: demo tools, centerprint, cvars.
- Modern indie ship list: accessibility, photo mode, safe mod scripting.
- MeatRay-specific gap: strong net stack but thin **product chrome** and **repro tools**.

---

## Execution order (hard sequence)

```
Wave A ✅  →  F1–F2 ✅  →  F3 → F4 → F5          (finish F high)
  →  G2 → G3 → G4                                (close the residual debt while it is small)
  →  G1 shell                                    (the ship-blocker: menus over the finished models)
  →  B9 → B12 (editor palette + linter)          (authoring)
  →  G5 → G6 → G7 → G8                           (hardening: fuzz, compat corpus, budgets, packaging)
  →  B13–B15  →  Wave C polish  →  D32–D35, D37  →  F6–F10
  →  G9 the moment the workflow scope is granted →  E39 only if design requires
```

Rationale for the two insertions: G2–G4 are small and get more expensive the
longer the systems above them keep moving, so they go before anything new is
stacked on top. G1 goes before authoring and polish because every wave after
it is invisible to a player until there are menus to reach it through.

### Suggested calendar (automation)

| When | Task focus |
|---|---|
| ~~Run 1~~ | ~~A1–A2 campaign + modes~~ — done |
| ~~Run 2~~ | ~~A3–A5 options, HUD, death/respawn~~ — done |
| ~~Run 3~~ | ~~A6–A8 secrets/keys, pause, graphics prefs~~ — done |
| ~~Run 4~~ | ~~F1 demo record/playback~~ — done |
| ~~Run 4b~~ | ~~F2 automap memory~~ — done (plus plain-Lua fixes + both-lane suite) |
| ~~Run 5~~ | ~~F3 dev console + cvars~~ — done |
| ~~Run 6~~ | ~~F4 intermission, F5 hazard volumes~~ — done (**Wave F high complete**) |
| ~~Run 7~~ | ~~G2–G4 residual debt~~ — done |
| ~~Run 8~~ | ~~G1 shell~~ — done |
| Run 9 · **next** | B9–B12 editor palette + linter |
| Run 10 | G5–G6 fuzzing + compat corpus |
| Run 11 | G7–G8 benchmarks + packaging |
| Run 12 | B13–B15 packs, hot-reload, i18n |
| Run 13 | C16–C23 gameplay polish + bots |
| Run 14 | C27–C31 VFX/audio presentation |
| Run 15 | D32–D35 multiplayer product |
| Run 16 | F6–F10 message queue, votes, a11y, sandbox, photo |
| Ongoing | D37 field QA (human); G9 CI the moment `gh auth refresh -s workflow` runs; all three gates green before every push |

---

## Agent prompt (paste into scheduled runs)

```
You are continuing MeatRayCast at F:\MeatRayCast.

1. Read docs/BACKLOG_SCHEDULE.md and docs/NEXT_FEATURES.md.
2. Find the first ⬜ or 🔶 item in execution order (F high, then G2–G4, then G1,
   then B, then G5–G8 — see the hard sequence above).
3. Implement that item (or a tight vertical slice of it) in engine code under meatray/.
4. Add/extend headless tests; run ALL gates: `powershell -File scripts/suite.ps1`
   (both interpreters), `love . --selftest`, `powershell -File scripts/nettest.ps1`
   when net-adjacent — every one 0 failed.
5. Update BACKLOG_SCHEDULE.md status for completed IDs.
6. Commit on main without AI attribution trailers; push origin main.
7. Stop after 1–2 IDs if the suite is large; leave a short note of next ID.

Rules: headless sim; netFields for wire; no Co-Authored-By; prefer F:\ only for
extra generated files outside the repo.
```

---

## Tracking

| Field | Value |
|---|---|
| Last backlog update | 2026-08-03 (Wave G added: hardening & ship; order re-derived) |
| Suite at schedule creation | 6275 passed (post A3) |
| Branch | `main` |
| Repo | MidwestMysteryMeat/MeatRayCast |

When an ID completes, set Status to ✅ and bump “Last backlog update”.
