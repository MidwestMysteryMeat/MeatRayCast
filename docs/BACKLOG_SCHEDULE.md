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
| B9 | Editor entity / spawn palette | ⬜ | place + properties |
| B10 | Trigger / MeatGraph plan UX | ⬜ | volumes on plan, graph picker |
| B11 | Prefab rooms / entities | ⬜ | stamp kits |
| B12 | Map validation linter | ⬜ | CLI + CI, unreachable/spawn/stairs |
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
| F1 | **Deterministic demo record & playback** | Source `.dem` / GZDoom demos: bug repro, net desync forensics, trailers. Host-tick input log + fixed RNG seed. | High |
| F2 | **Explored automap memory (fog of war)** | Doom automap; minimap is live only. Persist visited tiles per player/save. | High |
| F3 | **Dev console + cvars** | Separate from RCON: `noclip`, `god`, `give`, `map`, `stat net` for single-player/dev. | High |
| F4 | **Intermission / end-level stats screen** | Wolf/Doom between maps: time, kills, secrets, par. Hooks campaign wave A. | High |
| F5 | **Hazard & liquid volumes** | Damage floors, slime, water (slow/swim flag), lava — common FPS, missing as kit. | High |
| F6 | **Centerprint / pickup ticker / message queue** | Doom `HUDMessage`, Source `centerprint` — engine-owned, not ad-hoc notes. | Med |
| F7 | **MP vote system** | Map/kick/restart votes on dedicated — Zandronum/EDuke staple. | Med |
| F8 | **Accessibility suite** | Colorblind palettes, screen-shake scale, subtitle events, hold-to-toggle sprint. Modern ship bar. | Med |
| F9 | **MeatGraph sandbox ACL** | User/mod graphs: allowlist nodes, CPU budget, no host FS — required before workshop. | Med |
| F10 | **Photo / free-cam mode** | Detached camera, hide HUD, timed pause — trailers & level shots without cheats. | Low-Med |

### Research sources (summary)

- Classic ports: automap, demos, intermission, secrets (Doom/Wolf).
- Multiplayer ports: votes, RCON, spectator (Zandronum, EDuke32).
- Source engine: demo tools, centerprint, cvars.
- Modern indie ship list: accessibility, photo mode, safe mod scripting.
- MeatRay-specific gap: strong net stack but thin **product chrome** and **repro tools**.

---

## Execution order (hard sequence)

```
Wave A (A1→A8)  →  Wave F high (F1–F5)  →  Wave B (B9→B15)
  →  Wave C polish  →  Wave D (D32–D35, D37)  →  Wave F med (F6–F10)
  →  Wave E only if design requires
```

### Suggested calendar (automation)

| When | Task focus |
|---|---|
| ~~Run 1~~ | ~~A1–A2 campaign + modes~~ — done |
| ~~Run 2~~ | ~~A3–A5 options, HUD, death/respawn~~ — done |
| ~~Run 3~~ | ~~A6–A8 secrets/keys, pause, graphics prefs~~ — done |
| Run 4 · **next** | F1 demo record/playback |
| Run 5 | F2–F4 automap memory, console, intermission |
| Run 6 | F5 hazard volumes |
| Run 7 | B9–B12 editor palette + linter |
| Run 8 | B13–B15 packs, hot-reload, i18n |
| Run 9 | C16–C23 gameplay polish + bots |
| Run 10 | C27–C31 VFX/audio presentation |
| Run 11 | D32–D35 multiplayer product |
| Run 12 | F6–F10 message queue, votes, a11y, sandbox, photo |
| Ongoing | D37 field QA (human); suite always green |

---

## Agent prompt (paste into scheduled runs)

```
You are continuing MeatRayCast at F:\MeatRayCast.

1. Read docs/BACKLOG_SCHEDULE.md and docs/NEXT_FEATURES.md.
2. Find the first ⬜ or 🔶 item in execution order (Wave A, then F high, then B…).
3. Implement that item (or a tight vertical slice of it) in engine code under meatray/.
4. Add/extend headless tests; run: luajit tests/run_all.lua — must be 0 failed.
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
| Last backlog update | 2026-08-02 (A4–A8; **Wave A complete**) |
| Suite at schedule creation | 6275 passed (post A3) |
| Branch | `main` |
| Repo | MidwestMysteryMeat/MeatRayCast |

When an ID completes, set Status to ✅ and bump “Last backlog update”.
