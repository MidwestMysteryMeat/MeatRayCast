# MeatRayCast roadmap

Ordered by dependency, not by appeal. Each phase lists what it needs from the
ones before it, because several of these systems are cheap in the right order and
expensive in the wrong one.

Status legend: **done** · **next** · planned

---

## Phase 1 — Simulation core · **done**

Entities with composed components, tile world, grid collision with wall slide and
hitscan, fixed 60 Hz tick, optional BSP worldgen, hand-authored map format.
831 headless assertions; no LÖVE dependency anywhere in `meatray/sim/`.

The two decisions everything downstream leans on:

- **Components declare their own `netFields`.** Snapshots derive from that
  declaration, so replication, save files and network messages all read the same
  source of truth. Adding a synced field is one edit, not three.
- **The headless rule.** `meatray/sim/*` never touches `love.graphics`, enforced
  by a test. This is what keeps a dedicated server a config change and keeps the
  simulation testable without a window.

## Phase 2 — Render layer · **next**

DDA wall renderer (carried from raycaster-core, BSD attribution in `NOTICE`),
procedural texture generation, theme palettes, and sprite billboards with 1..N
angle buckets, depth sorting and per-column z-buffer occlusion. Plus a demo that
proves it: two sprite kinds, a door, wall-slide movement, a hitscan weapon.

The four modules raycaster-core hard-required (`themes`, `doors`, `corruption`,
`atmosphere`) become injected or optional here — that coupling is the main thing
being fixed in the port, not just moved.

## Phase 3 — GUI toolkit + editor shell

`love . --editor` opens **one workspace** with dockable, tabbed panels: map
editor, code browser, asset browser, sprite painter, inspector and console. Full
design in [`EDITOR.md`](EDITOR.md).

**Build the GUI toolkit first and separately.** Four panels need it, and a toolkit
extracted after the first one is written ends up shaped by that caller and fits
the rest badly. Immediate-mode suits a raycaster: panels, docking, tabs, buttons,
sliders, scroll regions, text fields, a palette strip, and a nested clip stack —
`love.graphics.setScissor` has no stack, which is a real gap worth wrapping once.

The map editor panel authors tiles, doors, spawn, entity markers and theme —
exactly what the engine understands and nothing it doesn't — with a live
first-person preview beside the paint grid.

The **code browser** browses and views the project (including the engine's own
source), quick-edits with hot reload on save, and hands off to an external editor
for real work. Hot reload covers **data and definitions** — archetypes, sprite
defs, themes, maps, tuning tables — while live entities keep their state. Full
module reload with state migration is deliberately refused: it leaves closures
holding old upvalues and breaks metatable identity, producing bugs that exist only
after a reload and cannot be reproduced from a clean boot.

The **asset browser** browses, previews and imports: step a sheet through its
angle buckets, audition a sound, open a map. It is the front end for phase 4.

The whole editor must be strippable from a release build — one entry point a
shipped `main.lua` never calls.

## Phase 4 — Asset import + registry

Today the engine generates every texture and needs no files. That stays the
default, but importing is what makes it usable for a real game:

- **Images**: PNG sprite sheets and wall textures, sliced by a declared grid,
  registered under a name the `Billboard` component already refers to.
- **Audio**: WAV import (LÖVE decodes WAV natively, so no dependency), with a
  sound registry and positional playback.
- **An asset registry with procedural fallback.** Every lookup that misses falls
  back to a generated placeholder rather than erroring, so a project with no
  assets still runs and a project with half its assets shows which half.

Two lessons already paid for elsewhere and worth applying here: keep media out of
the repo (`.gitignore` blocks it by default), and make missing files a *documented
fallback* rather than a crash — a guarded load site is the difference between a
fresh clone that runs and one that dies on launch.

## Phase 5 — Save system

Serialise world state, entity state and progress to disk, and load it back.
This is mostly already designed: `netFields` snapshots are the same problem, so a
save is a snapshot written to a file with a version number. Needs a migration
path from the first version onward — a save format with no version field is a
save format you can never change.

## Phase 6 — Sprite painter

An in-engine pixel editor: canvas, palette, per-frame and per-angle-bucket
editing, export to a sheet the asset registry can import. Depends on the GUI
toolkit (phase 3) and the asset pipeline (phase 4) — building it earlier would
mean building both of those badly, inside it.

## Phase 7 — Networking

Host-authoritative listen server over `lua-enet` (bundled with LÖVE). Host
simulates and is authoritative; clients send inputs and receive snapshots derived
from `netFields`, with local-player prediction for feel. All authoritative state
stays in one serialisable place so host migration remains possible later.

Deliberately after the gameplay-free phases and before the gameplay-heavy ones:
every system built after this point can be designed replicated from the start,
which is far cheaper than retrofitting replication onto a finished system.

## Phase 8 — Weapons and inventory

Weapons: hitscan (collision already provides it), projectiles, ammo, reload,
recoil, and the sprite/animation hooks. Inventory: slots, stacks, pickup and drop
as world entities, equip affecting the weapon component. Inventory UI comes from
the phase 3 toolkit.

## Phase 9 — Abilities (GAS-style)

Modelled on Unreal's Gameplay Ability System, which is the right reference here
because it solves exactly this problem: attributes, effects, tags, and abilities
with costs and cooldowns, all replicated.

- **Attributes** — numeric stats with base and current values (health, armour,
  stamina), each a component so `netFields` replicates it for free.
- **Gameplay effects** — instant, duration-based, or infinite; additive and
  multiplicative modifiers; stacking rules. Damage becomes an effect rather than a
  function call, which is what makes resistances, shields and damage-over-time
  compose instead of special-casing each other.
- **Tags** — hierarchical string tags (`state.stunned`, `damage.type.fire`) for
  gating and querying, avoiding a boolean per condition.
- **Abilities** — activation, cost, cooldown, cast time, effects applied on hit.

Host-authoritative changes what is honest here: the host owns attributes and
effect application. Clients may *predict* an activation for responsiveness, but
the host's answer wins. Prediction on damage numbers is a lie worth avoiding.

## Phase 10 — Explosions and gas propagation

Radial damage with falloff and line-of-sight occlusion (collision already
answers "can this tile see that tile"), plus a tile-grid gas/fluid diffusion sim
for smoke, fire spread and toxic clouds.

One hard-won warning: a diffusion sim on a tile grid is easy to write and easy to
get catastrophically wrong. Two failure modes seen in practice — a sim that walks
every cell every tick whether or not anything changed (which turns into a
per-frame cost proportional to world size, not to activity), and a room model
whose exchange rules are wrong in a way nothing notices until something
suffocates. Wake cells on change, let settled cells sleep, and test the
conservation property directly.

## Phase 11 — Lighting

Per-tile light levels with falloff, coloured light sources, and sprite shading
that matches wall shading so entities sit in the scene rather than on it. Static
light baked at load, dynamic lights (muzzle flash, explosions, carried torches)
added per frame. Explicitly: keep explored-but-unlit areas readable — a fog
overlay heavy enough to hide the level is a worse problem than an unlit one.

## Phase 12 — Destruction

Destructible walls and props: tile state changes, debris entities, and renderer
invalidation. Needs networking (phase 7) to replicate world mutation, and lighting
(phase 11) to relight a room whose wall just went. This is last because it
touches every other system, not because it matters least.

---

## Standing constraints

1. **No assets required.** Every phase must leave the engine runnable with zero
   media files, via procedural generation or documented fallbacks.
2. **The headless rule.** Nothing in `meatray/sim/` may reach for
   `love.graphics`. New gameplay systems belong there, so they stay testable.
3. **Replication derives from declarations.** New synced state means a
   `netFields` entry, never a hand-written serialiser.
4. **Determinism where it is load-bearing.** Anything a host and client both
   compute uses the engine's own RNG, not `math.random`, which differs across Lua
   builds.
5. **Fixed tick.** Gameplay maths is per-tick, never per-frame.
6. **Licensing hygiene.** Third-party code is checked before use, not after:
   permissive with attribution, or reimplemented from the published algorithm.
   Two dungeon generators were reviewed for phase 2 and rejected as sources —
   one carries no license at all (all rights reserved by default), the other is
   CeCILL-C and incompatible with this project's Apache-2.0. Their *techniques*
   (separation steering, Delaunay triangulation, minimum spanning tree) are
   published algorithms and may be implemented independently.
