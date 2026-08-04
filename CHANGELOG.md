# Changelog

Versioning is semantic from here: MAJOR for engine-API or wire/save format
breaks, MINOR for features, PATCH for fixes. The wire and save formats are
additionally guarded by the golden compat corpus (`tests/test_compat.lua`) —
a format change fails a test before it fails a player, tagged or not.

## v1.0.0 — 2026-08-04

The first versioned release. Everything below existed and was tested before
this tag; the tag is the promise that from here, changes are tracked.

### The engine
- Tile-raycast renderer: textured walls/floors/ceilings, pitch, sprites with
  angle buckets, lighting (static baked + dynamic per-frame), thin walls,
  free-angle segments, variable heights, multi-storey worlds, themes — all
  procedural, zero media required.
- Deterministic simulation: entity-component model, grid collision with
  sliding, AI (patrol/chase/investigate/hearing), pathfinding with stairs,
  projectiles/explosions/gas, doors/locks/push-walls/secrets, hazards,
  movers, triggers, per-second demo checksums naming the first divergent
  tick. Engine LCG only — no math.random anywhere in the sim.
- Networking: ENet-style UDP with dirty-flag snapshots, lag compensation,
  client prediction, LAN discovery, master-server registry, NAT hole
  punching, relay fallback, live map hot-swap (P.MAPCHANGE), RCON, votes,
  anti-cheat rate tiers with exposed reject counters.
- The game product layer: campaign, modes, HUD kit, menus, options + binds,
  accessibility (colourblind remap, flash/shake scales, subtitles flags),
  intermission, messages/killfeed, spectator/killcam, photo mode, meta
  progression, i18n scaffold, genre templates (fps/tdm/coop/crawler + rpg
  scaffolds), bots.
- Authoring: in-engine editor shell (map paint/elevation/entities/prefabs/
  trigger volumes with lint-on-save, live first-person preview, MeatGraph
  node editor, sprite painter, SFX synthesizer, asset browser, code browser
  with data hot-reload), text `.map` format, map linter, asset packs.
- Projects (the Godot split): a game is a folder — `project.json`, scanned
  `maps/`/`meatgraphs/`/`assets/`, `game.lua` gameplay entry. Play with
  `--project`, edit with `--editor --project`, ship with
  `scripts/package.ps1 -Project` (fused exe named and versioned from the
  project). `examples/hunted/` is the tracked demonstration.
- AI substrate: flow-field crowds with LOD, a pure-Lua neural-net module
  (backprop + neuroevolution, byte-stable `neural1` brains), neurobot
  players driven through the real input path, an evolution trainer, an
  imitation trainer over recorded demos, a Gym-style RL environment server
  for external trainers, and an MCP server exposing the authoring surface
  to AI agents.
- Discipline: ~8,300 assertions under both LuaJIT and Lua 5.4, packet
  fuzzing, a golden wire/save compat corpus, benchmark floors, luacheck
  zero-warning gate, CI (lint + suite + maplint + fuzz + walkthrough +
  imitation selfcheck + LÖVE selftest), one-script packaging with a smoke
  boot.

### Structure
- `main.lua` decomposed from 3,987 lines to a 526-line bootstrap over
  fifteen `app/` modules (console, args, menu, net, campaign, content,
  combat, world, demo, rules, draw, input, loop, boot).

### Known limits, stated plainly
- Field QA on real networks (D37) has not been executed — the runbook is
  `docs/FIELD_QA.md`; it needs two machines and a human.
- No sustained human playtest has occurred; the suite is thorough but
  self-authored.
- Build-style sector geometry, portals/mirrors, GPU rendering and built-in
  voice are deliberate non-goals (see `docs/BACKLOG_SCHEDULE.md`, Waves E/K).
