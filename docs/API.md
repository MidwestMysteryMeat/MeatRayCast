# MeatRayCast API

Everything reachable through `require('meatray')`. Modules under `meatray/sim/`,
`meatray/net/` and `meatray/save/` need no LÖVE and can be used from a headless
process; `meatray/render/` and `meatray/ui/` need a graphics context and load
lazily, so requiring the facade under plain LuaJIT is safe.

```lua
local MeatRay = require('meatray')
```

| Field | Module | Headless |
|---|---|---|
| `MeatRay.entity` | `sim.entity` | yes |
| `MeatRay.components` | `sim.components` | yes |
| `MeatRay.world` | `sim.world` | yes |
| `MeatRay.collide` | `sim.collide` | yes |
| `MeatRay.tick` | `sim.tick` | yes |
| `MeatRay.billboard` | `sim.billboard` | yes |
| `MeatRay.worldgen` | `sim.worldgen` | yes |
| `MeatRay.map` | `sim.map` | yes |
| `MeatRay.net` | `net` | yes |
| `MeatRay.save` | `save` | yes |
| `MeatRay.asset` | `asset` | mixed |
| `MeatRay.raycaster` | `render.raycaster` | **no** |
| `MeatRay.sprites` | `render.sprites` | **no** |
| `MeatRay.textures` | `render.textures` | **no** |
| `MeatRay.themes` | `render.themes` | **no** |
| `MeatRay.lighting` | `render.lighting` | yes (maths only) |

`MeatRay.canRender()` answers whether a graphics context exists. A dedicated
server checks it rather than assuming.

---

## Entities and components

Entities are plain tables with an id and a transform. Behaviour is **composed**,
not inherited: an entity is whatever components it carries.

```lua
local Health = MeatRay.component('health', { 'hp', 'max' })   -- netFields
local e = MeatRay.entity.new{ x = 3.5, y = 4.5 }
e:add(Health{ hp = 30, max = 30 })
```

`MeatRay.component(name, netFields)` returns a constructor. **`netFields` is the
declaration everything else derives from** — network snapshots and save files both
read it, so adding synced state is one edit rather than three. Omit it for state
the owner can recompute (input, caches, pathfinding).

### Archetypes

Names a kind and describes how to build one. Reads like a class declaration,
composes like a component bag, so orthogonal traits attach without a hierarchy.

```lua
MeatRay.archetype('imp', function(e)
    e:add(Billboard{ sheet = 'imp' })
    e:add(Health{ hp = 30, max = 30 })
    e.radius = 0.28
end)

local imp = MeatRay.entity.spawn('imp', 12.5, 9.5)   -- nil, err if unknown
```

`Entity.hasArchetype(kind)` · `archetypeNames()` · `clearArchetypes()` ·
`captureArchetypes()` / `restoreArchetypes(t)` (used by hot reload, which restores
on failure so a broken definition file cannot half-apply).

### Entity methods

| Method | Notes |
|---|---|
| `:add(component)` `:get(name)` `:has(name)` `:remove(name)` | chainable `add` |
| `:snapPrevious()` | called once per tick before simulating |
| `:interpolated(alpha)` → `x, y, angle` | for rendering between ticks |
| `:snapshot()` | transform + every declared `netFields` value |
| `:applySnapshot(t)` | **ignores components the entity does not carry** — never fabricates |

---

## World

A tile grid plus door state. Any grid works, generated or hand-authored.

```lua
local world = MeatRay.world.new(grid)     -- grid[y][x], 1-based
```

**Coordinate convention:** tile `N` spans world `[N-1, N]`, so world `(3.5, 3.5)`
is the centre of tile `(4, 4)`.

Tiles: `0` empty · `1..9` wall (the number selects a texture) · `World.DOOR` (10) ·
`World.STAIRS_UP` (11) · `World.STAIRS_DOWN` (12). Out of bounds reads as solid.

`:tileAt(tx,ty)` · `:isSolid` · `:isWalkable` · `:inBounds` ·
`:addDoor(tx,ty,open)` · `:setDoorOpen` · `:toggleDoor` · `:doorAt` ·
`:update(dt, speed)` (animates `door.openness`) · `:snapshot()` / `:applySnapshot()`
(door state is the only mutable part of a world, so it is all the network and a
save need).

---

## Collision

Movers are circles, walls are whole tiles.

```lua
local dist, blocked = MeatRay.collide.move(e, dx, dy, world, radius)
```

Per-axis resolution is what makes **wall sliding** fall out: a mover pressed
diagonally into a wall keeps the component that is still free.

| Function | Returns |
|---|---|
| `circleBlocked(world, x, y, r)` | boolean |
| `overlaps(a, b)` · `distance(a, b)` | |
| `query(entities, x, y, range, filter)` | nearest first, skips dead |
| `rayTile(world, x, y, dx, dy, maxDist)` | `dist, tx, ty` or nil |
| `hitscan(world, x, y, dx, dy, entities, opts)` | `{kind='wall'\|'entity', …}` — the wall is tested first, so shooting through a wall is impossible without the caller doing anything |
| `lineOfSight(world, ax, ay, bx, by)` | boolean |

---

## Fixed timestep

```lua
local clock = MeatRay.tick.new(60)          -- rate, [maxCatchUp]
local alpha = clock:advance(dt, function(step) simulate(step) end)
render(alpha)
```

The callback always receives `1/rate`, never the real frame delta. Catch-up is
capped (default 5 steps) and dropped time is **reported** via `clock.droppedTicks`
rather than hidden — a stalled process returning to a huge dt would otherwise try
to simulate every missed step at once and stall further.

`:alpha()` · `:time()` (whole ticks only — anything that must match across a
network reads this, not a wall clock) · `:reset()`.

---

## Worlds from either source

Procedural and hand-authored are equals; both produce the same `World`.

```lua
local world, rooms = MeatRay.worldgen.generate{ width=48, height=48, seed=7 }
local box = MeatRay.worldgen.box(20, 20)
```

The generator carries **its own RNG** (`Worldgen.rng(seed)` → `:next/:float/:int`)
rather than using `math.random`, which differs between Lua 5.1, 5.3 and LuaJIT. A
host and client generating a world from one seed must get identical geometry.

### Hand-authored maps

Readable text, so a level diffs in git and can be edited without the tool.

```lua
local map, errs = MeatRay.map.parse(text)      -- nil + error list on failure
local world, markers, spawn = MeatRay.map.toWorld(map)
local text = MeatRay.map.serialize(map)        -- stable across saves
```

`Map.blank(w,h)` · `Map.fromWorld(world, opts)` · `Map.charFor(map, kind)`.
Markers are handed back rather than spawned: the format knows nothing about
archetypes and must not.

---

## Rendering

```lua
MeatRay.raycaster.init{ width=, height=, theme= }
local view  = MeatRay.raycaster.view(x, y, angle)
local zbuf  = MeatRay.raycaster.render(view, world)
MeatRay.sprites.draw(entities, zbuf, view, opts)
```

`render` returns a **z-buffer** — perpendicular wall distance per screen column —
which is what lets sprites clip against walls. Also: `setTheme` · `getTheme` ·
`resize` · `setFog` · `setLighting` · `addCeilingZone` · `clearCeilingZones`.

### Sprites

```lua
MeatRay.sprites.define('imp', {
    angles = 8, frames = 4, fps = 8,
    anchor = 'feet',        -- or 'center'
    scale = 0.85, color = { 0.78, 0.24, 0.20 },
    image = nil,            -- nil generates a placeholder sheet
})
```

A sheet is **rows of angle buckets by columns of frames**. `angles = 1` always
faces the camera; `angles = 8` is Doom-style directional. Nothing assumes 8.

The generated placeholders are drawn so a facing bug is *visible* — two eyes
toward the viewer, one in profile, none from behind.

### Billboard maths (headless, tested)

`angleBucket(entityAngle, viewerToEntityAngle, angles)` — bucket 0 means facing
the viewer; the second argument is the bearing **from viewer to entity**.
`bearing` · `animFrame(time, frames, fps)` · `project(...)` · `screenRect(...)` ·
`sortByDepth` · `columnVisible` · `normalize`.

### Lighting (optional)

```lua
local grid = MeatRay.lighting.new{ world = world, baseLevel = 0.34 }
grid:addStatic{ x=, y=, radius=, color=, intensity=, shadows=true }
MeatRay.raycaster.setLighting(grid)
```

Ships **off**: with no grid every surface samples a flat 1.0 and output is
identical to before lighting existed. Per-frame cost is proportional to
**samples × dynamic lights**, with no term for world size or static light count.
`beginFrame()` · `addDynamic{}` · `sample(x,y)` · `invalidateTile/Rect/All` ·
`update()` (O(1) when clean) · `report()`.

`Lighting.MIN_VISIBILITY` is the readability floor — explored-but-unlit areas stay
navigable, because a level you cannot read is a worse problem than one that is
uniformly lit.

---

## Networking

The dev picks the topology; the engine does not choose.

```lua
MeatRay.net.host{ mode = 'listen', discovery = 'lan' }
MeatRay.net.host{ mode = 'dedicated', port = 6789, map = 'arena' }
MeatRay.net.join('203.0.113.5:6789', { name =, password = })
local browser = MeatRay.net.browse{ discovery = { 'lan' } }
```

Three independent axes: **mode** (`single`/`listen`/`dedicated`/`client`),
**transport** (`loopback`/`enet`, Steam shaped for), **discovery**
(`direct`/`lan`, master shaped for). A game that says nothing about networking is
in `single` mode and behaves exactly as before.

Host: `update/step/spawn/despawn/toggleDoor/event/chat/kick/ban/players/info`.
Client: `update/setInput/command/chat/requestStats/alpha/leave`.

Replication derives from `netFields`. Snapshots are unreliable-sequenced at 20 Hz
against a 60 Hz tick with clients interpolating; **inputs travel client→host, never
positions**; world mutation is reliable. Local movement is predicted, **damage is
never predicted**.

See [`NETWORKING.md`](NETWORKING.md). `love . --netcheck` answers "can this machine
do UDP at all" in five checks ending in a real two-peer handshake.

---

## Save

A save is a versioned snapshot on disk, deriving from the same `netFields`.

```lua
MeatRay.save.save(1, { world=, entities=, progress=, map=, playTime= })
local state = MeatRay.save.load(1)
-- state.world, state.entities, state.progress, state.meta, state.unknown, state.dropped
```

`list()` / `info(slot)` read metadata **without** deserialising the body, so a save
browser does not pay for every file it lists. Corrupt and truncated saves refuse
cleanly rather than half-loading. Entities whose archetype no longer exists come
back as positional ghosts listed in `unknown` — never fabricated.

---

## Assets

Optional by design. Every miss falls back to a generated placeholder, so a project
with no assets runs and one with half its assets shows which half.

```lua
MeatRay.asset.importSprite(name, path, { angles=, frames=, fps= })
MeatRay.asset.importSound(name, path, { volume=, ref=, max= })
MeatRay.asset.sprite(name)      -- never fails
MeatRay.asset.missing()         -- what did not resolve
MeatRay.asset.sound.setListener(x, y, angle)
MeatRay.asset.sound.playAt(name, x, y)
```

Names are namespaced **per kind**: `get/resolve/value` take `(name, kind)`, because
a sprite and a sound sharing a logical name silently replaced each other when the
map was flat.

---

## The convenience layer

Optional. Owns the loop so a game does not rewrite the accumulator.

```lua
local Engine = require('meatray.engine')
local app = Engine.new{ world = world, onTick = function(app, step) end }

function love.update(dt) app:update(dt) end
function love.draw()     app:draw()     end
```

`:step` · `:view` · `:spawn/remove/sweepDead` · `:setWorld` · `:loadMap` ·
`:look(dx)` · `:turn(a)`. `Engine.run{...}` installs the callbacks for you.

**It may only use the public API** — enforced by `tests/test_engine_layering.lua`.
Anything it can do you can do yourself, so dropping down to the library is never a
rewrite.

---

## Conventions worth knowing

1. **Fixed tick.** Gameplay maths is per-tick, never per-frame.
2. **Determinism where it is load-bearing.** Anything a host and client both
   compute uses the engine's RNG, not `math.random`.
3. **Replication derives from declarations.** New synced state is a `netFields`
   entry, never a hand-written serialiser.
4. **No assets required.** Every phase leaves the engine runnable with zero media.
5. **The headless rule.** Nothing under `meatray/sim/`, `meatray/net/`,
   `meatray/save/` or `meatray/game/` may touch `love.graphics` — enforced by a
   test that loads each module with no `love` global *and* scans the sources, so a
   reference on an unreached branch still fails.
