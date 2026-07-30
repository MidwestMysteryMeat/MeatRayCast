# MeatRayCast roadmap

Ordered by dependency, not by appeal. Each phase lists what it needs from the
ones before it, because several of these systems are cheap in the right order and
expensive in the wrong one.

Status legend: **done** · **next** · planned

---

## Phase 1 — Simulation core · **done**

Entities with composed components, tile world, grid collision with wall slide and
hitscan, fixed 60 Hz tick, optional BSP worldgen, hand-authored map format.
No LÖVE dependency anywhere in `meatray/sim/`. (2289 headless assertions now cover
the simulation, the net layer, the UI maths and the asset pipeline together, with
134 more in `love . --selftest` for the parts that need a real context.)

The two decisions everything downstream leans on:

- **Components declare their own `netFields`.** Snapshots derive from that
  declaration, so replication, save files and network messages all read the same
  source of truth. Adding a synced field is one edit, not three.
- **The headless rule.** `meatray/sim/*` never touches `love.graphics`, enforced
  by a test. This is what keeps a dedicated server a config change and keeps the
  simulation testable without a window.

## Phase 2 — Render layer · **done**

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

## Phase 4 — Asset import + registry · **done**

The engine generates every texture and needs no files. That is still the default;
importing layers on top of it rather than replacing it.

- **Images** (`meatray/asset/image.lua`): PNG sprite sheets and wall textures,
  sliced by a declared grid and registered under the name the `Billboard`
  component already refers to. A sheet whose dimensions do not divide evenly by
  its declared angle and frame counts is **refused with the remainder in the
  message**, not imported — that misconfiguration otherwise renders as sprites
  sliced half-off and reads as a renderer bug for as long as it takes to work out
  it is not one.
- **Audio** (`meatray/asset/sound.lua`): WAV import, since LÖVE decodes WAV
  natively and importing one therefore adds no dependency. Positional playback
  attenuates by distance and pans by the bearing between the listener's facing and
  the source, using the renderer's own definition of "right" so audio and video
  never disagree about which side something is on. Missing audio is silent, never
  an error. `conf.lua` now enables `love.audio`/`love.sound` for any run with a
  window and leaves them off for `--server`, `--nettest`, `--browse` and
  `--netcheck`: a dedicated server has no business opening an audio device.
- **An asset registry with procedural fallback** (`meatray/asset/registry.lua`):
  every lookup that misses falls back to a generated placeholder rather than
  erroring. There is exactly one load site and it is guarded, including against a
  loader that raises and against a placeholder producer that is itself broken.

The registry keeps four states, and the difference between the last two is the
point: `pending`, `file`, `generated` (no source path was ever given — procedural
by design, and fine) and `fallback` (a source path was given and did not load —
**missing**). `Asset.missing()` and `Asset.report()` answer "which half", and
resolve anything still pending first, because an asset whose absence is only
discovered on the frame that needs it is an asset discovered in front of a player.

Everything with an interesting failure mode is headless: grid arithmetic, name
resolution, resolution policy, and the falloff and pan curves are all asserted
under plain LuaJIT with no LÖVE (`tests/test_asset_*.lua`). The two modules that
genuinely need a decoder or an audio device are thin and covered by
`love . --selftest`, which encodes a PNG and writes a WAV at runtime rather than
shipping fixtures — the repository holds no media by policy.

The asset browser panel (`meatray/ui/panel_assets.lua`) is the front end: a
thumbnail grid by category, a preview that steps a sheet through its angle buckets
while animating it, auditions a sound with the distance and pan it would play at,
and shows a map's dimensions — and missing assets drawn distinctly rather than
omitted, since that is the single most useful thing the panel can tell you.

Two lessons already paid for elsewhere and applied here: keep media out of the
repo (`.gitignore` blocks it by default), and make missing files a *documented
fallback* rather than a crash — a guarded load site is the difference between a
fresh clone that runs and one that dies on launch.

## Phase 5 — Save system · **done**

World state, entity state and arbitrary game progress written to a versioned
file, and loaded back. It was mostly already designed, and the design held: a
save *is* a snapshot written to a file, so `meatray/save/` contains no serialiser
and no field list of its own. A world becomes the payload the replication layer
already builds for a joining client; an entity becomes the snapshot its
components already declare through `netFields`. Adding a synced field still means
one edit, and it now persists as well as replicates.

- **`meatray/save/format.lua`** — the envelope. A header line
  (`MEATRAYSAVE <metaBytes> <bodyBytes> <adler32>`) followed by a metadata
  section and a body section, both encoded with `meatray/net/serialize.lua`.
  Three properties fall out of that shape and each is a requirement: metadata
  reads without the body, truncation is arithmetic rather than guesswork, and a
  flipped byte that would still decode is caught by the checksum instead of
  loading as a lie. (Integrity, not security — saves are not a trust boundary;
  the network is.)
- **`meatray/save/storage.lua`** — three backends behind one interface: LÖVE's
  sandboxed filesystem, plain `io`/`os` for a dedicated server, and an in-memory
  one whose only purpose is to make the failures injectable.
- **`meatray/save/state.lua`** — capture and restore. Restore builds a new world
  and a new set of entities and hands them over only if all of it worked, so a
  save that turns out to be broken costs the load rather than the session.
- **`meatray/save/init.lua`** — slots, listing, metadata, delete.

**The version field exists from v1, and so does the migration path.** A format
with no version is a format that can never change, because the first change makes
every existing file indistinguishable from a corrupt one. The version lives in
exactly one place (inside the metadata section, so two copies can never
disagree), a save from a newer build is refused by name, and a save with no
version is refused rather than assumed to be v1 — that assumption is how a
version field becomes decorative on the day it starts to matter. There are no
migrations to ship yet, since v1 is the first version there has ever been, but
the mechanism is exercised: `tests/test_save_format.lua` writes a v0 file,
registers a v0 → v1 migration, and loads through it — along with a migration that
does not raise the version, one that raises, one that refuses and one that
returns nonsense, none of which may hang or escape the loader.

**Atomic writes, honestly described.** LÖVE's filesystem is PhysFS, and PhysFS
has no rename and no move: what a shipped game gets is `write`, `append`, `read`,
`remove`, `getInfo`, `createDirectory`, `getDirectoryItems` and file handles.
There is no atomic swap to call, so claiming one would be a lie. What the save
path does instead is write a temporary file, verify it by reading it back, write
the target, verify that, and remove the temporary file — with recovery from the
temporary file built into *reading*, not into a repair tool somebody has to be
told to run. The guarantee that buys is exact: **at every instant there is a
complete, valid save on disk**, the old one or the new one, and an interrupted
save is always detectable and always recoverable. The `io` backend does have
`os.rename` and uses it (genuinely atomic on POSIX; on Windows the destination
must be removed first, so the same recovery path still carries it).

**Listing does not open saves.** A browser showing ten slots reads the first
kilobyte of each file and stops, which is only possible because the metadata sits
in its own length-declared section ahead of the body. A slot that cannot be read
is still listed, carrying the reason — omitting it would hide a file that is
still occupying the slot the player is trying to use.

**What a load refuses to invent**, inherited deliberately from replication: an
archetype this build does not know becomes a positional ghost and is reported in
`state.unknown`, and component state with no component to receive it is reported
in `state.dropped`. Both are returned rather than printed, so they can be asserted
and so the caller decides whether a ghost is a broken save or a mod unloaded on
purpose.

359 headless assertions cover it (`tests/test_save_format.lua`,
`test_save_state.lua`, `test_save_slots.lua`), including every prefix of a valid
save, every single-byte corruption of its last two hundred bytes, and a real
save-and-load cycle through actual files in a temporary directory. 36 more in
`love . --selftest` do the whole cycle against `love.filesystem` itself, because
everything else runs against a filesystem that is a Lua table and would keep
passing if the real one did not work at all.

## Phase 6 — Sprite painter

An in-engine pixel editor: canvas, palette, per-frame and per-angle-bucket
editing, export to a sheet the asset registry can import. Depends on the GUI
toolkit (phase 3) and the asset pipeline (phase 4) — building it earlier would
mean building both of those badly, inside it.

## Phase 7 — Networking · **done, except master/hole-punch/Steam**

Built early, out of dependency order, and deliberately: every system built after
this point can be designed replicated from the start, which is far cheaper than
retrofitting replication onto a finished system. Phases 3 to 6 gained a constraint
by waiting — the server browser needs the phase 3 toolkit — and the gameplay phases
gained more than they lost.

Implemented: `single`/`listen`/`dedicated`/`client` modes chosen by the dev in one
line; `loopback` and `enet` transports behind one interface; host-authoritative
snapshots derived from `netFields` at 20 Hz against a 60 Hz tick, with clients
interpolating; inputs (never positions) from client to host, clamped on arrival;
world mutation replicated by diffing, so game code that toggles a door directly
still replicates; local-player movement prediction with smoothed and hard
correction, and no prediction of health or damage; LAN discovery over UDP
broadcast with measured ping; password access control, kick, ban by address, and
an `onAuthenticate` hook; and startup diagnostics that name the port to forward and
distinguish "LAN players can join" from "nobody can reach you".

Not implemented, and designed for rather than stubbed: master-server discovery,
UDP hole punching, the Steam transport. `docs/NETWORKING.md` records where each
plugs in — a transport or a discovery backend is one new file and one registration,
with no edit to gameplay code or to the browser.

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
invalidation. Needs networking (phase 7, now done — world mutation already
replicates, though only door state does today: a level *edit* is not yet on the
wire), and lighting (phase 11) to relight a room whose wall just went. This is last because it
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
