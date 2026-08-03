# MeatRayCast — parity with marketed engines & what is left

**As of 2026-08-03.** This document answers two questions honestly: what does
MeatRayCast still lack that a shipped, marketed engine of its class has, and
what is left on the backlog to close those gaps. It is a companion to
`BACKLOG_SCHEDULE.md` (the ordered work queue); this file is the *why* — the
comparison against the engines a networked tile-raycast FPS is measured against.

## The comparison set

MeatRayCast is a **networked tile-raycast FPS engine** in Lua/LÖVE. Its peers
are not Unreal or Unity — different class entirely — but the lineage of shipped
raycast/BSP FPS engines and their toolchains:

- **GZDoom / Zandronum** — the Doom-lineage gold standard: automap, demos, ACS
  scripting, intermission, decals, hazards, a mature netcode, RCON, votes,
  spectator, DECORATE/ZScript modding.
- **EDuke32 / Build** — sectors, slopes, room-over-room, a shipped map editor.
- **Source engine (GoldSrc/Source)** — console + cvars, demo tools, centerprint,
  VGUI, a fused game runtime.
- **Modern indie FPS toolkits** — accessibility baselines, photo mode, one-click
  packaging, Steam integration, workshop-safe mod sandboxes.

Against that set, here is the domain-by-domain scorecard.

---

## Where MeatRayCast is already AT parity (or ahead)

These are done, tested, and in most cases hold their own against the reference
engines:

| Domain | MeatRayCast | Reference |
|---|---|---|
| **Deterministic demos** | ✅ `meatray.sim.demo` — seed + input stream + per-tick divergence checksums naming the first bad tick | GZDoom `.lmp`, Source `.dem` |
| **Automap w/ fog** | ✅ `meatray.game.automap` — LOS reveal, per-storey, save-persisted, hides unseen entities | Doom automap (MeatRay's fog + entity-hide is *ahead* of vanilla) |
| **Dev console + cvars** | ✅ `meatray.game.console` — typed/clamped cvars, cheat gating by session role, history, completion | Source console |
| **Intermission** | ✅ `meatray.game.intermission` — staged tally, par, secrets %, coverage | Wolf/Doom intermission |
| **Hazard/liquid volumes** | ✅ `meatray.game.hazards` — damage floors, slime, lava, water-slow, all through the one damage path | Doom sector damage |
| **Secrets / keys / push-walls** | ✅ `meatray.game.secrets` + world locks/push-walls | Doom secrets, keyed doors, Wolf push-walls |
| **In-game shell** | ✅ `meatray.game.menu` — title/options/campaign/join, bind capture | Every shipped engine |
| **Net stack** | ✅ ENet + relay + Steam transports, dirty-flag snapshots, lag comp, hole punching, master server | Zandronum netcode (MeatRay's snapshot codec is competitive) |
| **Determinism discipline** | ✅ engine LCG only, no `math.random` in sim, both-interpreter test lane | Rare even among marketed engines |
| **Map editor** | ✅ in-engine: paint, elevation, entity palette, prefab stamps, live FP preview, lint-on-save | EDuke32 mapster, Doom Builder |
| **Map linter** | ✅ `meatray.sim.maplint` — reachability, spawn/exit/lock/push-wall sanity | *Ahead* — most engines have no built-in linter |
| **Packaging** | ✅ `scripts/package.ps1` — fused exe, version-stamped, smoke-booted | Source fused runtime |
| **Test discipline** | ✅ ~7,000 headless assertions both interpreters, fuzzing, golden compat corpus, benchmarks | *Far ahead* of the reference set |

---

## Gaps: what marketed engines have that MeatRayCast still lacks

Ordered by how conspicuous the gap is to a player or a modder, with the backlog
ID that closes it.

### Tier 1 — a player notices these missing immediately

| Gap | What the reference has | Backlog | Notes |
|---|---|---|---|
| ~~Engine-owned player messaging~~ ✅ | Doom `HUDMessage`, Source `centerprint` / pickup ticker | **F6 done** | `meatray.game.messages`: priority centerprint, pickup/notify ticker, structured killfeed. The substrate obituaries, votes and killcam sit on. |
| ~~Bot players~~ ✅ | Zandronum bots, every MP FPS | **C22 done** | `meatray.game.bot` plays through the same INPUT path a human does — fights, paths, opens doors, wanders — deterministic via engine LCG. `bot [n]` console command. The biggest single MP-parity gap, closed. |
| ~~Inventory / pickup UX~~ ✅ | Every FPS HUD | **C16 done** | Bag grid overlay (I), on-contact crystal pickups with ticker feedback. Weapon-wheel not built (1/2 keys suffice for two weapons). |
| ~~Impact/particle VFX~~ ✅ | Decals, tracers, sparks, blood | **C27 done** | `meatray.render.particles`: sparks, blood, debris, smoke, tracers — sprayed off surface normals, z-tested against the world. |
| ~~Screen effects~~ ✅ | Damage vignette, underwater tint, flashbang | **C28 done** | `meatray.game.screenfx`: layered flashes + condition-holds, fill/vignette; hazard washes + pickup blip wired. |

### Tier 2 — a modder or server op notices these

| Gap | What the reference has | Backlog | Notes |
|---|---|---|---|
| ~~Dedicated console / RCON~~ ✅ | Source RCON, Zandronum | **D33 done** | `meatray.net.rcon`: session auth (constant-time, fail-closed, lockout), status/say/kick/ban/map over `P.RCON`, loopback-tested. |
| ~~MP vote system~~ ✅ | Zandronum callvote, EDuke | **F7 done** | `meatray.game.vote`: map/kick/restart, electorate threshold, host-enacted over `P.VOTE`, loopback-tested. |
| ~~Spectator + killcam~~ ✅ | Every MP FPS | **D35 done** | `meatray.game.spectator`: killcam toward the killer, then first-person spectate cycling live players. |
| ~~Trigger/graph plan UX~~ ✅ | ACS in a map editor | **B10 done** | A `.map` `trigger` directive (named world-AABB → graph id, storey/once/filter), `meatray.ui.map_triggers` edit model (place/select/rebind/rename-unique/delete), editor tool (drag two corners, graph picker, inspector), and load-time binding in `main.lua` that resolves each graph by id (pack registry → loose folders), hardens it (F9), and fires the map-placed volumes. `maps/triggers.map` demos it. |
| ~~Stock event nodes~~ ✅ | ACS built-ins | **C21 done** | `EventOnAllDead` (once, when the last enemy falls), `EventOnTimer` (per-node countdown), `EventOnSecret` (name-carrying). A `pumpStockEvents` driver watches the conditions each tick; all three stay inside the F9 sandbox vocabulary. |
| ~~Asset pack format~~ ✅ | PK3/WAD, EDuke GRP | **B13 done** | `meatray.game.pack`: `pack.json` manifest (id/version/depends/maps/graphs), path-traversal refused, a registry that mounts by dependency order, refuses id collisions atomically, and resolves an asset id to its file path. Demo scans `packs/` at boot; `packs` + `map <id>` console commands; ships `packs/example`. |
| ~~Mod sandbox ACL~~ ✅ | ZScript sandbox, Lua sandboxes | **F9 done** | `MeatGraphRay.validate/harden`: categorised node allowlist, category policy, size caps, per-fire step budget; FS denied by construction. |

### Tier 3 — modern ship-bar, not classic-engine parity

| Gap | What modern engines ship | Backlog | Notes |
|---|---|---|---|
| ~~Accessibility suite~~ ✅ | Colorblind palettes, shake scale, subtitles, hold-to-toggle | **F8 done** | `meatray.game.a11y`: daltonization colour remap, flash/shake scalars, subtitles + hold-to-toggle, persisted, on the options screen. |
| ~~Photo / free-cam~~ ✅ | Detached cam, hide HUD, timed pause | **F10 done** | `meatray.game.photo`: a free-flying camera (fly relative to facing, free of walls), pitch/FOV clamped, HUD hide, and it freezes the solo sim so a still is a still. `O` toggles; wired over the D35 pose path in the renderer. |
| ~~Footsteps / surface materials~~ ✅ | Tile-tagged footstep sounds | **C30 done** | `WorldMT:setSurface`/`surfaceAt` + a `.map` `surface` directive tag tiles by material; `meatray.game.footsteps` emits a step per stride with the material under the feet (resolver-injected). Demo plays `footstep.<material>` positionally (silent until the owner adds the WAV). |
| **Ambient sound zones** | Room tones | **C31** | |
| ~~Dialogue / camera rails~~ ✅ | Scripted campaign beats | **C20 done** | `meatray.game.dialogue` — a branching conversation state machine (linear advance, flag-gated choices, side-effect flags, once-nodes, dangling-link validation); `meatray.game.rails` — a scripted camera glide over waypoints (travel/hold, short-way angles, easing, loop), rendered over the F10 pose seam with a `rail` console demo. Both headless & tested; content stays the author's. |
| **Meta progression** | Between-campaign unlocks | **C23** | |
| ~~Hot-reload map on host~~ ✅ | Live editor→play | **B14 done** | `HostMT:changeWorld` adopts a rebuilt world, reseats diff baselines, re-homes every player, and sends each client a full-world `P.MAPCHANGE` (the one mid-session message carrying a whole `worldPayload`); the client rebuilds and rebinds. Console/RCON/vote `map` now swap live. |
| **Real-world NAT + long-session QA** | — | **D37** | Needs humans on real hardware; only external validation left. |

### Deferred by design (not gaps to close)

- **Build-style sectors / room-over-room (E21)**, **portals/mirrors (E22, E42)**,
  **GPU DDA (E43)** — a different engine architecture; MeatRay's storeys cover
  the practical multi-level case. Marked ⛔ on purpose.
- **Voice chat (D36)** — defer to Steam/Discord rather than build.

---

## The honest bottom line

MeatRayCast is **at or ahead of parity on the engine core** — rendering,
determinism, netcode, editor, and especially test/build discipline, where it
exceeds the reference set. The gaps are almost entirely in **product chrome**
(messaging, bag UI, VFX, spectator) and **live-service tooling** (RCON, votes,
bots, mod sandbox). None require an architecture change; each is a bounded
module on foundations that already exist.

**Path to "feature-parity with a shipped Zandronum-class engine":**

```
F6 message system        (substrate for killfeed / votes / pickups)
  → C16 bag UI + pickups (the last obviously-missing HUD piece)
  → C22 bots             (the biggest MP-parity gap)
  → C27 + C28 VFX/screen (juice: tracers, sparks, damage/underwater)
  → D33 RCON + F7 votes  (dedicated-server product)
  → D35 spectator/killcam
  → B10 + C21 + B13 + F9 (authoring + mod pipeline)
  → F8 + F10             (accessibility + photo mode: the modern ship bar)
  → B14, C20, C23, C30/31 (polish tail)
```

Wave E stays deferred; D37 (field QA) is the one item only a human with real
hardware can close.

**Implementation begins at F6** — the message system, because bots, votes,
killcam and pickups all want to surface text through it, so building it first
means each of those lands with player-facing feedback already in place instead
of bolted on after.
