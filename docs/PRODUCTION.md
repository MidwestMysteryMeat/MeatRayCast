# Production readiness — phase scorecard

**As of v1.0.0 (2026-08-04).** The quantified companion to `PARITY.md`
(feature comparison) and `BACKLOG_SCHEDULE.md` (work history). Percentages
are of *production quality for this engine's class* — a networked tile-
raycast engine with authoring tools — not of an imaginary Unreal. Deliberate
non-goals (Build sectors, GPU rendering, built-in voice, C ABI) are listed
per phase and excluded from the denominator; pretending to be 40% of a
different engine helps nobody.

**Overall: ~78% to production, with the remainder concentrated in two
places: default audio/content polish, and validation that only humans and
real networks can provide.**

| Phase | Score | One-line status |
|---|---:|---|
| 0 — Engine foundation | 100% | Deterministic sim, dual-interpreter suite, fuzzing, compat corpus, bench floors |
| 1 — Gameplay runtime | 95% | Every system shipped and tested; depth is demo-tier by design |
| 2 — Rendering & content | 80% | Visuals complete and procedural; default soundscape now synthesized (zero media) |
| 3 — Editor & authoring | 75% | Full tool shell + project workflow; zero second-user hours |
| 4 — Scripting & API | 65% | Three script surfaces; no curated stable API, no text-mod sandbox |
| 5 — Multiplayer maturity | 78% | Feature-complete netcode; no transport encryption, zero field hours |
| 6 — Persistence & replay | 85% | Saves, demos, compat-guarded formats; solo-only replay |
| 7 — Distribution & product | 70% | v1.0.0 released, fused exe, CI, docs; Windows-only artifacts |
| 8 — Validation | 10% | Mechanical loops green; human/field/external all zero |

---

## Phase 0 — Engine foundation: 100%

Simulation core (entities/components, collision with sliding, tick),
determinism discipline (engine LCG only, `%.17g` floats, per-tick
checksums), the platform seam (only `meatray/platform/` names the host,
test-enforced), 8,300 assertions on LuaJIT **and** Lua 5.4, packet fuzzing
(200k+ inputs), golden wire/save corpus, committed benchmark floors,
zero-warning luacheck gate, 9-step CI. Nothing open.

## Phase 1 — Gameplay runtime: 95%

**Done:** weapons (hitscan + projectile), damage as effects (armour/
resist/immunity compose), explosions, gas fields, AI (patrol/chase/
investigate/hearing), pathfinding incl. stairs, doors/locks/push-walls/
secrets, hazards & liquids, movers, triggers, campaign, modes (DM/TDM/
coop/SP), respawn + protection, bots, neural bots, crowds with LOD,
inventory/pickups, meta progression, session/pause policy.

**Left (5%):**
- Weapon/enemy variety is two guns and one monster — deliberate demo scope,
  but a shipped game on the engine will stress-test archetype breadth.
- Melee, alt-fires, status-effect variety: no engine blockers, no examples.

## Phase 2 — Rendering & content pipeline: 70%

**Done:** DDA renderer (textured walls/floors/ceilings, pitch, render-scale
canvas), sprites with angle buckets, lighting (baked static + free dynamic,
colour, occlusion), particles/decals/tracers, screen effects with
accessibility remap, themes/atmosphere, minimap + automap fog, procedural
textures and sprites for everything (zero-media law), photo mode, camera
rails.

**Done since v1.0.0: the default soundscape is synthesized.**
`Sound.declareSynth(name, presetOrParams)` registers a sound whose audio is
rendered from H3 synth params through the registry's fallback lane — the
audio half of the zero-media law, same posture as the procedural sprites,
overridden the moment an author declares the name with a real WAV. The demo
now ships audible: pistol crack, launcher thump, explosions, pickups,
doors, footsteps — all positional (the listener follows the player each
frame), all zero files, on host and client alike.

**Left (20%):**
- Ambient room-tone and music remain author content by design (a procedural
  soundtrack is a liability, not a feature).
- Hurt/kill feedback sounds are declared but not yet wired to the damage
  path.
- Fonts: LÖVE's default only; no font pipeline or size/DPI policy.
- Shaders: none — software renderer by design; a palette/CRT post pass is
  the only shader-shaped thing that would ever fit (unscheduled).
- SpriteBatch pass for many-billboard scenes (K2) — evidence-gated on a
  profile showing sprite-bound frames.
- Animation tooling: sprite sheets animate (fps/frames) but there is no
  animation *editor*; wall `anim` is a map directive.
- Import pipeline is drop-a-file: PNG sheets and WAVs only, no atlasing,
  no audio conversion.

**Non-goals:** GPU rendering (E43), true 3D models.

## Phase 3 — Editor & authoring: 75%

**Done:** docked tool shell; map editor (paint, elevation, ceilings, short
walls, entity palette from live archetypes, prefab stamps with rotation,
trigger volumes with graph picker, per-map theme, lint-on-save, live
first-person preview); MeatGraph node editor; sprite painter (brush/fill/
rect/pick, undo, export); SFX synthesizer panel; asset browser with
declared-vs-on-disk truth; code browser with data hot-reload; project
workflow (`--editor --project`: loads the start map, saves to the project,
scans its graphs, writes its sounds, Export button runs the packager);
map linter in editor, CLI and CI.

**Left (25%):**
- Map-editor undo: the sprite painter has it; the map panel does not — the
  single most requested editor feature the first real user will hit.
- No in-editor light placement/tuning (lighting is themes + code policy).
- No animation editor, no audio-import conversion.
- Multi-storey editing is header-text, not painted per-layer in the UI.
- **Zero second-user hours** — the Wave B exit criterion ("a second person
  authors a map") remains unmet by a human.

## Phase 4 — Scripting & API: 65%

**Done:** Lua as the game language (H5 `game.lua` per project — full-trust,
Godot-script posture); MeatGraphRay visual scripting with a real sandbox
(33-kind allowlist, category policy, size caps, per-fire step budgets, no
FS by construction) and stock event nodes; MCP server exposing the
authoring surface to AI agents; Gym-style RL environment server; 531-line
API.md plus per-subsystem docs.

**Left (35%):**
- No **curated stable API**: `game.lua` receives raw engine facades, so
  every internal rename is a potential project break. A versioned
  `api.*` surface with a deprecation policy is the real 1.x commitment.
- No sandboxed **text** scripting for third-party mods (the ZScript/ACS
  role) — graphs are the only safe lane; anything more needs trusted Lua.
- API reference coverage is thin relative to ~100k lines of engine.
- **Non-goal:** C ABI / native plugins (pure-Lua determinism is load-bearing).

## Phase 5 — Multiplayer maturity: 78%

**Done:** UDP with dirty-flag snapshots and delta baselines, client
prediction + lag compensation, late join (full world payload incl. locks/
push-walls/secrets/hazards/movers), live map hot-swap mid-session, LAN
discovery + master-server registry + NAT hole punching + relay fallback
(with egress caps), RCON (constant-time auth, lockout), votes, anti-cheat
rate tiers with exposed reject counters, input sanitising (NaN/clamp),
protocol fuzzing, bandwidth measured and documented, deployment/systemd/
firewall docs.

**Left (22%):**
- **No transport encryption** — traffic is plaintext UDP; RCON auth is
  digest-based but game traffic is spoof-resistant only via session ids.
  Documented in SECURITY.md as a trust boundary, not yet closed (DTLS or a
  noise-style handshake is the shaped item).
- No accounts/identity — names are self-asserted; fine for LAN/friends,
  insufficient for public servers.
- No session resume: a dropped client rejoins as a new player.
- Scale untested beyond small lobbies (snapshot cost is measured, but no
  16-player soak has ever run).
- **D37: zero hours on a real network.** The runbook exists; execution is
  human-only and is the phase's true gate.
- **Non-goal:** built-in voice (D36 — Steam/Discord).

## Phase 6 — Persistence & replay: 85%

**Done:** atomic save slots (write-verify-recover, interrupted-write
tests), full world state in save + join payloads, automap memory in save
meta, options/binds/a11y/progression persisted, deterministic demos
(delta-encoded input, tick events, per-second checksums naming the first
divergent tick, in-game record/replay), golden compat corpus decoding
every build, versioned save documents.

**Left (15%):**
- Demos are **solo-only**: a hosted/network session cannot be recorded or
  replayed (snapshot streams are not captured).
- Mid-session save captures world + entities, not live graph/mode internal
  state — a loaded save restarts logic cleanly rather than mid-script.
- **Non-goal:** streamed/unbounded worlds (tile worlds are bounded by
  design; storeys and map links are the scale mechanism).

## Phase 7 — Distribution & product: 70%

**Done:** v1.0.0 tagged with CHANGELOG and semver policy (format breaks =
MAJOR and corpus-guarded); GitHub release with fused win64 zip +
`.love`; one-script packaging with smoke boot; project-aware packaging
(exe named/versioned from `project.json`); CI on every push incl. Linux
lanes; genre templates; `examples/hunted`; GETTING_STARTED tutorial;
deployment, security, field-QA, networking, editor, AI docs; MCP
registration one-liner.

**Left (30%):**
- Artifacts are **Windows-only**; the `.love` runs anywhere LÖVE 11 does,
  but there is no macOS/Linux packaging script, no signing/notarisation,
  no package-manager presence.
- One example project; the rpg/turnrpg/vn scaffold templates have no
  sample games proving them.
- No crash reporting/telemetry (a crash log tee exists via `--log`; nothing
  ships reports).
- No SECURITY.md disclosure policy at repo root (docs/SECURITY.md is a
  trust-boundary doc, not a reporting policy), no issue templates, no
  release cadence statement beyond "semver from v1.0.0".

## Phase 8 — Validation: 10%

**Done (the 10%):** the mechanical loops run continuously — CI walks
blank-folder→authored-project and trains an imitation brain on every push;
packaging boots what it built; nettest crosses three real processes over
real UDP on one machine.

**Left (90% — none of it automatable):**
- A human completes the campaign. A human spends an hour in the editor.
- D37 field QA: two machines, real NATs, the soak runbook.
- A real game ships on the engine (examples/hunted grown, or new).
- A second person — any second person — uses anything and files the first
  external bug.

---

## The shortest path up the scorecard

1. ~~Synth-backed default audio~~ — **done** (Phase 2 at 80).
2. **Map-editor undo** (Phase 3 → ~80): the sprite painter's undo model,
   applied to the map panel's edit ops.
3. **Curated `api.*` for game.lua** (Phase 4 → ~75): freeze a small
   documented surface; raw facades stay reachable but unpromised.
4. **Transport encryption + session resume** (Phase 5 → ~88): the two
   engineering items; D37 stays the human gate.
5. **macOS/Linux packaging** (Phase 7 → ~80): love-release-style staging;
   the `.love` already runs there.
6. **Everything in Phase 8** — which is a calendar and a second human, not
   a commit.
