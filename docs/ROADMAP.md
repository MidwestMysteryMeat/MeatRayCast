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

## Phase 9 — Abilities (GAS-style) · **done**

Modelled on Unreal's Gameplay Ability System, which is the right reference here
because it solves exactly this problem: attributes, effects, tags, and abilities
with costs and cooldowns, all replicated. Four modules under `meatray/game/`,
none of which touches LÖVE.

They live in `meatray/game/` rather than `meatray/sim/` because they are rules
rather than physics — `meatray/sim/` answers "where is everything and what did
the ray hit", and a game that replaces every attribute and ability in here still
wants all of that. The headless rule follows them across the boundary regardless:
`tests/test_headless.lua` loads each of these with no `love` global present and
scans their sources the same way it scans the simulation's, because the reason
for the rule — a dedicated server runs the whole simulation with no graphics
context — applies to gameplay more strongly than to anything else.

- **Tags** (`meatray/game/tags.lua`) — hierarchical dotted strings
  (`state.stunned`, `damage.type.fire`, `ability.dash`) with matching that
  respects the hierarchy: a query for `damage.type` finds `damage.type.fire`,
  and a fire ward written today still covers `damage.type.fire.greek` invented
  next year. The near-miss is the part that has to be tested rather than
  assumed — a prefix comparison alone makes `damage.typeX` look like a child of
  `damage.type`, and the resistance that silently soaks it produces a number
  that is slightly wrong forever. Containers count grants rather than flagging
  them, so two stuns expiring one at a time do not clear each other.

- **Attributes** (`meatray/game/attributes.lua`) — `base` (what instant effects
  change) and `cur` (base folded with active modifiers, then clamped), both
  declared `netFields`, so an attribute replicates and saves with nothing added
  to either layer. **The existing `health` component was adopted, not
  duplicated**: `health.hp` is still the live pool and `health.max` is still the
  effective maximum, so every existing reader including the HUD is unchanged.
  One field is new — `health.maxBase`, the unbuffed maximum — added through
  `Attributes.declareField` rather than by editing `components.lua`, because a
  temporary +20 max health cannot be reverted correctly by subtracting what it
  added the moment anything else moves the base underneath it.

  **The modifier order is written down and enforced**, because
  additive-then-multiplicative and multiplicative-then-additive are different
  games and "whichever `pairs()` visited first" is a bug:

  ```
  cur = clamp( override  or  ((base + SUM(add)) * PRODUCT(mul)) )
  ```

  Additive first, so a multiplier is scale-free. The fold is independent of
  iteration order by construction — the two buckets commute, and the one
  operation that does not (`override`) is resolved by explicit priority and
  application order — and it sorts before folding so floating-point association
  is fixed too.

- **Gameplay effects** (`meatray/game/effects.lua`) — instant, duration-based or
  infinite, with periods for damage over time and regeneration, stacking by
  `independent` / `refresh` / `stack` with a cap, resistances that scale
  incoming effects by tag, immunity, and cleansing by tag query. **Damage is an
  effect**, which is what makes armour a shield without the damage path knowing
  armour exists: `health` declares `soak = 'armour'`, and melee, explosions and
  the fourth tick of a poison all get that behaviour for free.

- **Abilities** (`meatray/game/abilities.lua`) — activation with cost, cooldown,
  cast time, blocking and required tags, and effects applied to the activator or
  to targets on hit. Every refusal is a value: `'cooldown'`, `'cost'` naming the
  attribute that could not pay, `'blocked by tag: state.stunned'`, `'not
  granted'`, `'already casting'`. An ability that declines silently is the bug
  that reads as "the button does nothing sometimes". Cost and cooldown commit at
  activation, effects at cast completion — charging on completion means whoever
  interrupts every cast pays nothing.

Host-authoritative changes what is honest here, and the split is enforced rather
than documented. Attributes replicate as components. Effect instances, cooldowns
and pending casts live in an **unreplicated** `gas` component — host bookkeeping,
for the same reason `brain` has none — while the tags they grant *do* replicate,
as one sorted space-separated string, so a client can gate its own prediction
honestly. A string rather than a table because a table in a `netFields`
declaration is shared by reference into the snapshot, and a listen server would
then have its host and its local client holding the same one.

`Effects.apply` refuses on a container whose `authority` is false. That is the
whole of "damage is never predicted": there is no path from a client's key press
to an attribute, so a health bar cannot flinch and correct itself even by
accident. A client may call `Abilities.predict`, which runs the same gating and
starts a local cooldown and cast so the interface responds on the frame the
button was pressed — and pays no cost and applies no effect. `confirm` and
`reject` follow; a rejection restores exactly the cooldown and cast state that
existed before the prediction.

Durations tick in whole simulation steps and nothing reads a clock: a duration
that is an exact multiple of the step expires *on* that step, which an expiry
test written against `<= 0` gets right at 60 Hz and wrong at 120. Randomness
(proc chances) uses the engine's own LCG and **refuses** rather than falling back
to `math.random`, whose sequence differs between Lua builds and would desync a
host from a client that agreed about everything else. Every write is validated:
a NaN survives every comparison a naive clamp makes, so it would otherwise reach
the wire and then every other player.

378 headless assertions cover it (`tests/test_game_tags.lua`,
`test_game_attributes.lua`, `test_game_effects.lua`, `test_game_abilities.lua`,
plus the headless rule extended over `meatray/game/`), including the modifier
order under forty deterministic shuffles, expiry on the exact tick boundary in
both directions, every stacking policy, resistances through the tag hierarchy,
and a snapshot round-trip that carries every attribute with no serialiser
written for any of them.

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

## Phase 11 — Lighting · **done**

Per-tile light levels with falloff, coloured light sources, and sprite shading
that matches wall shading so entities sit in the scene rather than on it. Static
light baked at load, dynamic lights (muzzle flash, explosions, carried torches)
added per frame. Explicitly: keep explored-but-unlit areas readable — a fog
overlay heavy enough to hide the level is a worse problem than an unlit one.

`meatray/render/lighting.lua` holds all of it, and holds no LÖVE: 109 headless
assertions cover the falloff curves, colour accumulation, the readability floor,
shadowing and the dirty-region bookkeeping, and the suite asserts the module's
love-freedom the same way `tests/test_headless.lua` asserts the sim's. What needs
a GPU is in `love . --selftest`, which renders eleven reference frames and reads
pixels back out of them.

Two numbers are the load-bearing part.

- **`Lighting.MIN_VISIBILITY = 0.45`** — the floor no surface renders below,
  named and tunable in one place rather than clamped inside a shading
  expression. Set from looking at `shot_light_floor.png` (a room with no light in
  it at all), not from taste: at 0.35 a wall in that frame measures 0.085 and
  reads as a fault; at 0.45 it measures 0.13 and reads as darkness.
- **The per-frame cost is `O(samples × dynamic lights)`** — one sample per screen
  column plus one per visible sprite — with no term for world size, tile count or
  static light count. Static light is baked once; a change marks only the
  footprints of the lights that could see it; an unchanged world does no lighting
  work at all. `Grid:report()` counts cells baked and shadow tests run, so those
  are assertions rather than intentions.

The renderer ships with lighting **off**. With no grid attached every surface
samples a flat 1.0 and the output is identical to phase 2's, which is why the
editor preview and every existing caller needed no change.

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
