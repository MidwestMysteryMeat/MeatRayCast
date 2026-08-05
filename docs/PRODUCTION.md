# Production readiness — phase scorecard

**As of v1.0.0 (2026-08-04).** The quantified companion to `PARITY.md`
(feature comparison) and `BACKLOG_SCHEDULE.md` (work history). Percentages
are of *production quality for this engine's class* — a networked tile-
raycast engine with authoring tools — not of an imaginary Unreal. Deliberate
non-goals are listed per phase and excluded from the denominator. That list
was re-judged honestly in `docs/FUTURE.md` — several early "non-goals" (GPU
rendering, mirrors, axis-aligned portals) turned out to be real feasible
projects, not architectural impossibilities, and are reclassified there. What
stays a genuine non-goal with a defence: Build-style sectors (a different
engine), voice chat (Steam/Discord solve it better), a C ABI (breaks the
pure-Lua guarantees), and arbitrary non-Euclidean portals (no clean path in a
tile-DDA renderer).

**Overall: ~78% to production, with the remainder concentrated in two
places: default audio/content polish, and validation that only humans and
real networks can provide.**

| Phase | Score | One-line status |
|---|---:|---|
| 0 — Engine foundation | 100% | Deterministic sim, dual-interpreter suite, fuzzing, compat corpus, bench floors |
| 1 — Gameplay runtime | 95% | Every system shipped and tested; depth is demo-tier by design |
| 2 — Rendering & content | 80% | Visuals complete and procedural; default soundscape now synthesized (zero media) |
| 3 — Editor & authoring | 80% | Full tool shell + project workflow + map undo; zero second-user hours |
| 4 — Scripting & API | 75% | Curated versioned game.lua API (test-enforced); no text-mod sandbox |
| 5 — Multiplayer maturity | 90% | Session resume + optional end-to-end sealing (direct & relay); only accounts + field hours open |
| 6 — Persistence & replay | 90% | Saves, compat-guarded formats, solo + networked demo recording |
| 7 — Distribution & product | 82% | v1.0.0; Win fuse + POSIX .love/.app packaging + bytecode/encrypt + crash reports |
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

**Reclassified (see FUTURE.md):** GPU rendering is NOT a non-goal — the
column loop is pure-CPU and batching it into a mesh (or a later shader
raycaster) is a real, feasible win. Mirrors and axis-aligned portals are
likewise feasible, unbuilt. True 3D models remain out (different renderer).

## Phase 3 — Editor & authoring: 80%

**Done:** docked tool shell; map editor (paint, elevation, ceilings, short
walls, entity palette from live archetypes, prefab stamps with rotation,
trigger volumes with graph picker, per-map theme, lint-on-save, live
first-person preview); MeatGraph node editor; sprite painter (brush/fill/
rect/pick, undo, export); SFX synthesizer panel; asset browser with
declared-vs-on-disk truth; code browser with data hot-reload; project
workflow (`--editor --project`: loads the start map, saves to the project,
scans its graphs, writes its sounds, Export button runs the packager);
map linter in editor, CLI and CI.

**Done since v1.0.0:** map-editor undo/redo — snapshot-based over the text
format (undo can never restore a state that would not save), one entry per
paint stroke, redo branch cleared by fresh edits, ctrl+Z/ctrl+Y plus
sidebar buttons with visible depth, capped history, file loads start fresh.
Headless-tested (26 assertions) including stroke coalescing and dangling-
selection clearing.

**Left (20%):**
- No in-editor light placement/tuning (lighting is themes + code policy).
- No animation editor, no audio-import conversion.
- Multi-storey editing is header-text, not painted per-layer in the UI.
- **Zero second-user hours** — the Wave B exit criterion ("a second person
  authors a map") remains unmet by a human.

## Phase 4 — Scripting & API: 75%

**Done:** Lua as the game language (H5 `game.lua` per project — full-trust,
Godot-script posture); MeatGraphRay visual scripting with a real sandbox
(33-kind allowlist, category policy, size caps, per-fire step budgets, no
FS by construction) and stock event nodes; MCP server exposing the
authoring surface to AI agents; Gym-style RL environment server; 531-line
API.md plus per-subsystem docs.

**Done since v1.0.0:** the curated `game.lua` contract — `api.version = 1`
(`meatray.game.project_api`, `docs/GAME_API.md`): a named STABLE surface
(entities, data definitions, sound incl. synth, messages, deferred console
registration, the engine LCG) under the same semver promise the wire format
keeps, **enforced by a contract test** that asserts every promised name on
every push. Raw facades demoted to `api.raw` and explicitly unpromised;
`examples/hunted` rewritten against the stable surface and boot-verified.

**Left (25%):**
- No sandboxed **text** scripting for third-party mods (the ZScript/ACS
  role) — graphs are the only safe lane; anything more needs trusted Lua.
- API v2 candidates unbuilt: per-tick world queries, mode/rules hooks,
  campaign definition, HUD extension points.
- API reference coverage is thin relative to ~100k lines of engine.
- **Non-goal:** C ABI / native plugins (pure-Lua determinism is load-bearing).

## Phase 5 — Multiplayer maturity: 90%

**Done:** UDP with dirty-flag snapshots and delta baselines, client
prediction + lag compensation, late join (full world payload incl. locks/
push-walls/secrets/hazards/movers), live map hot-swap mid-session, LAN
discovery + master-server registry + NAT hole punching + relay fallback
(with egress caps), RCON (constant-time auth, lockout), votes, anti-cheat
rate tiers with exposed reject counters, input sanitising (NaN/clamp),
protocol fuzzing, bandwidth measured and documented, deployment/systemd/
firewall docs.

**Done since v1.0.0: session resume.** Every ACCEPT carries a single-use
token (OS-entropy DRBG; no entropy → no token, never a guessable one). An
UNEXPECTED disconnect parks the player in limbo — entity alive, peerId
reserved — for a grace window; a JOIN presenting the token reclaims the
same entity where it stood, tokens rotate on every ACCEPT, deliberate
LEAVEs forfeit, map changes void, expiry kills honestly. Loopback-tested
end to end (19 assertions) and surfaced in the demo as `reconnect`.

**Correction from the first scorecard:** a full seal/open construction
(encrypt-then-MAC over SHA-256, OS-entropy DRBG with a documented
no-silent-degrade rule) already exists in `meatray.net.crypto` and protects
the RELAY data path end to end. What remains open is the direct
host↔client path.

**Done since v1.0.0: end-to-end sealing on the direct path too.**
`meatray.net.transport.sealed` wraps ANY transport as a decorator and
encrypts every frame with a key derived from the server password
(`--sealed --password ...` on both ends). A plaintext or wrong-password
client is dropped at the transport — the parser only ever sees frames that
proved they know the password, and the password itself never crosses the
wire. A sealed host refuses to start without a password (no silent weak
key). Made affordable by the crypto fast path (~4,900 seals/s vs ~1,000
needed); loopback-tested (25 assertions) AND verified over real UDP
between two processes.

**Left (10%):**
- No accounts/identity — names are self-asserted; fine for LAN/friends,
  insufficient for public servers.
- Scale untested beyond small lobbies; **D37** field QA (real NATs, soak)
  remains the human gate.
- Scale untested beyond small lobbies (snapshot cost is measured, but no
  16-player soak has ever run).
- **D37: zero hours on a real network.** The runbook exists; execution is
  human-only and is the phase's true gate.
- **Non-goal:** built-in voice (D36 — Steam/Discord).

## Phase 6 — Persistence & replay: 90%

**Done:** atomic save slots (write-verify-recover, interrupted-write
tests), full world state in save + join payloads, automap memory in save
meta, options/binds/a11y/progression persisted, deterministic demos
(delta-encoded input, tick events, per-second checksums naming the first
divergent tick, in-game record/replay), golden compat corpus decoding
every build, versioned save documents.

**Done since v1.0.0:** **networked demo recording** (`meatray.net.netdemo`) —
a joined client records the authoritative snapshot stream it receives plus
the join world payload, and a replay feeds those snapshots back through the
identical `Rep.applyEntities` path with no socket, reconstructing the exact
entities at the exact positions the live client held (loopback-tested, 18
assertions, replayed mob within 0.01 of live). `netdemo record|stop` console
command. In-game visual playback of a networked demo is the remaining
follow-up; the recording itself is complete and replayable now.

**Left (10%):**
- Mid-session save captures world + entities, not live graph/mode internal
  state — a loaded save restarts logic cleanly rather than mid-script.
- **Non-goal:** streamed/unbounded worlds (tile worlds are bounded by
  design; storeys and map links are the scale mechanism).

## Phase 7 — Distribution & product: 82%

**Done:** v1.0.0 tagged with CHANGELOG and semver policy (format breaks =
MAJOR and corpus-guarded); GitHub release with fused win64 zip +
`.love`; one-script packaging with smoke boot; project-aware packaging
(exe named/versioned from `project.json`); CI on every push incl. Linux
lanes; genre templates; `examples/hunted`; GETTING_STARTED tutorial;
deployment, security, field-QA, networking, editor, AI docs; MCP
registration one-liner.

**Done since v1.0.0:** `scripts/package.sh` — the POSIX half of packaging:
same ship list and media scrub as the Windows script, project-aware, zips
the `.love` (the distributable on these platforms) with a launcher script,
and smoke-boots it headless through the dedicated server. Runs in CI on
every push: the suite job validates staging + archive, the LÖVE job runs
the real smoke boot.

**Done since v1.0.0 also:** shipped-source protection — `-Compile` ships
opaque bytecode, `-Encrypt` seals each module with the engine AEAD and
decrypts it in memory at load (a `conf.lua` bootstrap installs the loader;
the archive holds no readable-or-loadable source). Both smoke-verified to
still boot; `docs/SHIPPING_SECURITY.md` is the honest researched menu
(bytecode → encryption → the caveat that no client-side code is ever
secret → server authority as the only strong answer, which this engine is
already shaped for).

**Done since v1.0.0 also:** **crash reporting** (`app.crash`) — a
`love.errorhandler` writes a build-stamped report with traceback and recent
log to the save dir and stdout, then defers to LÖVE's error screen; formatter
headless-tested, no telemetry. And a **macOS `.app` bundle** assembler in
`package.sh` (`MACAPP=1`): Info.plist + the `.love` in Resources; runnable
when pointed at a macOS love binary, skeleton otherwise.

**Left (18%):**
- No signing/notarisation (needs your certs — steps planned in FUTURE.md),
  no package-manager presence.
- No source *protection* beyond bytecode (which is the honest ceiling for
  a shipped interpreted game; a native-code path is not a goal).
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
2. ~~Map-editor undo~~ — **done** (Phase 3 at 80).
3. ~~Curated `api.*` for game.lua~~ — **done** (Phase 4 at 75).
4. ~~Session resume~~ — **done** (Phase 5 at 84). Direct-path encryption
   remains: benchmark `crypto.seal` first, then design to the number.
5. ~~macOS/Linux packaging~~ — **done** (Phase 7 at 78; signing and
   store presence remain).
6. **Everything in Phase 8** — which is a calendar and a second human, not
   a commit.
