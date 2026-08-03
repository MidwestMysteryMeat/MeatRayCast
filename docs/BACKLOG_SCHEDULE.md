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
| B10 | Trigger / MeatGraph plan UX | ✅ | `.map` `trigger` directive + `meatray.ui.map_triggers` edit model + editor tool (drag corners, graph picker, inspector) + load-time graph binding (resolve by id → harden → fire). `maps/triggers.map` demo. |
| B11 | Prefab rooms / entities | ✅ | `meatray.sim.prefab`: capture a rect as a stamp (tiles/doors/entities/heights), 4-way rotation (WxH→HxW, doors + entity facing turn with it), clipped paste, serialize round-trip, built-in kit (pillar/cross/guard/alcove); editor stamp tool + R to rotate |
| B12 | Map validation linter | ✅ | `meatray.sim.maplint`: flood-reachability (doors passable), spawn/exit/entity in-solid, lock-no-door, push-wall-blocked, key/stairs/link/box warnings; `scripts/maplint.lua` CLI (exit 1 on error); editor save surfaces it; suite lints every shipped map as an anti-rot gate |
| B13 | Asset pack format | ✅ | `meatray.game.pack`: `pack.json` manifest (id/version/depends/maps/graphs), path-traversal refused before any file opens, `Registry` mounts by dependency order, refuses id collisions atomically, resolves an asset id → file path. Demo scans `packs/` at boot (two-pass for dep order); `packs` + pack-aware `map <id>` console commands; ships `packs/example` (self-contained map) |
| B14 | Hot-reload map on host | ✅ | `HostMT:changeWorld` (adopt world, reseat baselines, re-home players) + `P.MAPCHANGE` full-world resync + client rebuild/rebind. Console/RCON/vote `map` swap live; `test_hot_reload` covers it end-to-end over loopback. |
| B15 | Localization strings table | ✅ | `meatray.game.i18n`: keyed lookup with param formatting, missing key returns the KEY (never blank), fallback-locale fills gaps in partial translations, bad format can't crash a frame, `missing()` to-do list, key=value file round-trip via storage backend. Infra only — owner authors the actual strings |

**Exit:** second person authors map+graph; dedicated server runs it unchanged.

---

## Wave C polish — presentation leftovers

| ID | Feature | Status | Notes |
|---|---|:---:|---|
| C16 | Inventory UX + pickup feedback | ✅ | `View.grid` layout helper (tested) + bag grid overlay (I toggles: slots/counts/equipped ring/stack bars); crystals are on-contact pickups (`stepPickups`, host-authoritative) granting ammo with a ticker line |
| C17 | Door auto-close + keyed kit (map headers) | 🔶 | logic partial |
| C18 | Mover ↔ host WORLD sync | 🔶 | movers snapshot exists; wire it |
| C19 | AI hear / investigate sound | ⬜ | beyond last-known visual |
| C20 | Dialogue / camera rails | ⬜ | campaign |
| C21 | MeatGraph stock event nodes | ✅ | `EventOnAllDead` / `EventOnTimer` / `EventOnSecret` + `pumpStockEvents` driver; sandbox-registered; `test_meatgraph_stock`. |
| C22 | Bot players | ✅ | `meatray.game.bot`: produces INPUT (not motion) through the same applyInput a human does — finds nearest player, fires+strafes in range, paths (doors-passable) + opens doors otherwise, wanders idle; engine-LCG deterministic. Demo `bot [n]` console command; bots are ordinary player entities (replicate, respawn, killfeed) |
| C23 | Meta progression unlocks | ⬜ | between campaigns |
| C27 | Particle / impact VFX kit | ✅ | `meatray.render.particles`: kinds-as-data (spark/blood/debris/smoke) sprayed off a surface normal, velocity/gravity/drag sim, floor rest, hard cap, tracers as segments; demo wires hitscan sparks+blood+tracer and explosion debris+smoke (host + client), z-tested billboards |
| C28 | Screen effects library | ✅ | `meatray.game.screenfx`: layered timed tints — flashes (ramp/hold/fade, priority-capped) and holds (condition tints kept up until released, id-deduped), fill or vignette style; demo wires hazard water/slime/lava wash (held while standing in it) + pickup blip |
| C30 | Footsteps / surface materials | ⬜ | tile tags |
| C31 | Ambient sound zones | ⬜ | room tones |
| C-map | Map headers for mask/anim/movers | ⬜ | authoring completeness |

---

## Wave D — Multiplayer product (P4)

| ID | Feature | Status | Notes |
|---|---|:---:|---|
| D32 | Server browser polish | 🔶 | filters, mode, map, ping |
| D33 | Dedicated console / RCON | ✅ | `meatray.net.rcon`: Source-model session auth (constant-time digest compare, fail-closed no-secret, lockout), commands status/say/kick/ban/map acting on the host; `P.RCON` protocol msg (contract-registered, size-limited), `host:attachRcon`, client `rconAuth`/`rcon`; dedicated server enables from `MEATRAY_RCON_SECRET`. Loopback-tested end to end |
| D34 | Anti-cheat boundaries | 🔶 | rate limits, reject metrics |
| D35 | Spectator + simple killcam | ✅ | `meatray.game.spectator`: eyes→killcam→spectate state machine producing a camera pose; killcam looks from the fall point toward the killer (tracks a moving one), expires into spectating a live player; cycle skips dead+self, drops a target that dies; demo swaps the render camera, click-to-cycle while down, mode label |
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
| F6 ✅ | **Centerprint / pickup ticker / message queue** | `meatray.game.messages`: exclusive priority-arbitrated centerprint, fading pickup/notify ticker (capped), structured killfeed (attacker/victim/cause, nil=environment); demo wires mission-name centerprint, secret pickups, kills (local + networked). Substrate for votes/killcam/pickups | Med |
| F7 ✅ | **MP vote system** | `meatray.game.vote`: one-at-a-time, one-ballot-per-peer, threshold of the ELECTORATE (silence=no), kick target struck from the roll, early pass/fail, cooldown; `P.VOTE` msg + host enact (kick/map/restart); demo `callvote`/`vote` console + centerprint tally. Loopback-tested | Med |
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
| G6 | Wire & save compatibility corpus | ✅ | `tests/fixtures/compat_corpus.lua` (hex, git-safe): ping/chat/accept packets, a 2-entity snapshot, a full save doc. `test_compat` decodes them every build (forward compat) + semantic re-encode drift check (text serializer is pairs-ordered, so byte-exact only for binary). `scripts/gen_corpus.lua` regenerates on a deliberate version bump. Both lanes decode identical bytes |
| G7 | Benchmark suite + budgets | ✅ | `meatray.dev.microbench` times snapshot encode/decode, worldgen, gas step, demo checksum; `bench_budget.lua` = committed floors (~45% of LuaJIT measured, so 2x trips); `scripts/bench_headless.lua` gates (LuaJIT only, off on PUC). Suite tests harness correctness — NO timing asserts (flaky). Renderer bench.lua unchanged |
| G8 | Release packaging | ✅ | `scripts/package.ps1`: stages game+engine (strips editor/tests/docs/dev-scripts/operator-programs), zips a `.love`, fuses onto love.exe, copies runtime DLLs, stamps `git describe` version, and boots the fused exe 5s failing if it does not reach the title. build/ gitignored, README documents it |
| G9 | CI workflows | ✅ | `.github/workflows/ci.yml`: must-pass headless job (both interpreters run tests/run_all.lua, then maplint on every shipped map, packet fuzz, bench budgets) + best-effort LÖVE selftest under xvfb. Runs on push/PR to main |

**Exit:** a stranger downloads a zip, double-clicks, and reaches the campaign
through menus; a fuzzer cannot crash a host; the next format change fails a
test instead of a player.

---

## Phase P — production & parity finish (added 2026-08-03)

Wave A, Wave F-high, Wave G, the G1 shell, the parity Tier-1/Tier-2 set, and the
genre templates are all done. What remains is the tail: the last parity items,
the authoring/content pipeline, production hardening, and the polish that a
shipped game wants. Grouped into four ordered sub-phases plus the one item only
a human with real hardware can close. See `docs/PARITY.md` for the reasoning.

### P1 — parity finish (close the marketed-engine checklist)

| ID | Feature | Status | Notes |
|---|---|:---:|---|
| F8 | Accessibility suite | ✅ | `meatray.game.a11y`: channel-shift daltonization (red/green→blue, yellow/blue→red so confusable colours separate), flash/shake intensity scalars (photosensitivity), subtitles + hold-to-toggle flags, file persistence + menu rows; demo runs every screen flash + HUD wash through the flash scale and colourblind remap, accessibility rows on the options screen |
| F9 | MeatGraph sandbox ACL | ✅ | `MeatGraphRay.validate/harden`: 33-kind categorised allowlist (event/data/action) refusing unknown/hostile/typo nodes + a category policy (display-only mods get event+data, no mutation) + size caps + per-fire step budget threaded through runExec/evalData (a graph cannot hang the host). No io/os/loadstring reachable — FS denied by construction. Demo hardens every loaded graph |
| B13 | Asset pack format | ✅ | `meatray.game.pack` — manifest parse+validate (path-safe), a mount `Registry` (dep order, atomic collision refusal), id→path resolve; demo scans `packs/`, `packs`/`map <id>` commands, `packs/example` shipped. |
| F10 | Photo / free-cam mode | ✅ | `meatray.game.photo`: detached free-fly camera (facing-relative pan, wall-free), clamped pitch + FOV, HUD hide, freezes the solo sim for a clean still. `O` toggles; renders over the D35 pose path; keyboard + mouselook fly it. |
| B10 | Editor trigger / graph plan UX | ✅ | Volumes placed on the plan, bound to a graph by id. `.map` `trigger` directive (round-trips), headless `meatray.ui.map_triggers`, editor tool + graph picker + inspector, and `main.lua` load-time binding (pack/loose resolve → F9 harden → installVolumes, ticks beside game.mode). |

**Exit:** the parity scorecard in PARITY.md has no open Tier-1/2/3 rows.

### P2 — authoring & content pipeline

| ID | Feature | Status | Notes |
|---|---|:---:|---|
| B14 | Hot-reload map on host | ✅ | Running host swaps the world live and re-syncs clients via `P.MAPCHANGE`. Console/RCON/vote `map` all route through it; a mid-session swap no longer strands the host on the old world. |
| C21 | MeatGraph stock event nodes | ✅ | `EventOnAllDead`, `EventOnTimer` (per-node countdown), `EventOnSecret` — driven by `MeatGraphRay.pumpStockEvents` each tick; the demo fires `secret` on the secret tracker. Substrate for the RPG/VN dialogue. |
| C20 | Dialogue / camera rails | ⬜ | Branching conversation + scripted camera beats. Closes the biggest scaffold `need` (rpg, turnrpg, vn). MeatGraphRay is the host. |
| C-map | Map headers for mask/anim/movers | ⬜ | Authoring completeness: the last world features that cannot yet be written in a `.map`. |

### P3 — production hardening (public-server readiness)

| ID | Feature | Status | Notes |
|---|---|:---:|---|
| D34 | Anti-cheat boundaries | 🔶 | Finish rate limits + reject metrics; document the trust boundary. Partial today. |
| D32 | Server browser polish | 🔶 | Filters (mode/map/ping/lock), in-shell. Partial today. |
| — | Operational deployment docs | ⬜ | Master-server + relay deploy scripts, monitoring, bandwidth/cost guidance. The "how to run it in production" gap. |
| D37 | Field QA execution | ⬜ **human** | `docs/FIELD_QA.md` on REAL hardware across REAL NATs. The one thing no test substitutes for; needs two machines. Sharpen the runbook first. |

### P4 — polish tail

| ID | Feature | Status | Notes |
|---|---|:---:|---|
| C17 | Door auto-close + keyed kit | 🔶 | Finish the partial logic. |
| C18 | Mover ↔ host WORLD sync | 🔶 | Wire the existing mover snapshot to the world sync. |
| C19 | AI hear / investigate sound | ⬜ | Beyond the last-known visual. |
| C30 | Footsteps / surface materials | ⬜ | Tile tags → footstep audio. |
| C31 | Ambient sound zones | ⬜ | Room tones. |
| C23 | Meta progression unlocks | ⬜ | Between-campaign persistence. |
| E39 | Segments first-class for AI/doors | ⬜ | Thin walls everywhere; optional, only if design needs it. |

**Order:** P1 (F8 → F9 → B13 → F10 → B10) → P2 → P3 code items → P4, with D37
running whenever real hardware is available. Deferred by design: E21/E22/E42/E43
(different architecture), D36 (voice — defer to Steam/Discord).

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
| ~~Run 9~~ | ~~B9 + B12 palette + linter~~ — done |
| ~~Run 10~~ | ~~G5–G6 fuzzing + compat corpus~~ — done |
| ~~Run 11~~ | ~~G7–G8 benchmarks + packaging~~ — done (**Wave G exit met: fused build boots to title**) |
| Run 12 · **next** | B10 trigger/graph plan UX, B11 prefabs, B13–B15 packs, hot-reload, i18n |
| Run 13 | C16–C23 gameplay polish + bots |
| Run 14 | C27–C31 VFX/audio presentation |
| Run 15 | D32–D35 multiplayer product |
| Run 16 | F6–F10 message queue, votes, a11y, sandbox, photo |
| Ongoing | D37 field QA (human); ~~G9 CI~~ done — CI runs the headless gates on every push; all local gates green before every push |

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
