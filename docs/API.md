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
| `MeatRay.segments` | `sim.segments` | yes |
| `MeatRay.pathfind` | `sim.pathfind` | yes |
| `MeatRay.triggers` | `sim.triggers` | yes |
| `MeatRay.ai` | `sim.ai` | yes |
| `MeatRay.decals` | `sim.decals` | yes |
| `MeatRay.tick` | `sim.tick` | yes |
| `MeatRay.billboard` | `sim.billboard` | yes |
| `MeatRay.worldgen` | `sim.worldgen` | yes |
| `MeatRay.map` | `sim.map` | yes |
| `MeatRay.net` | `net` | yes |
| `MeatRay.game` | `game` (weapons, inventory, gas, **mode**, …) | yes |
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
| `:interpolated(alpha)` → `x, y, angle, z` | for rendering between ticks |
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
`World.STAIRS_UP` (11) · `World.STAIRS_DOWN` (12) · `World.RUBBLE` (13).
Out of bounds reads as solid.

`:tileAt(tx,ty)` · `:isSolid` · `:isWalkable` · `:inBounds` ·
`:addDoor(tx,ty,open)` · `:setDoorOpen` · `:toggleDoor` · `:doorAt` ·
`:update(dt, speed)` (animates `door.openness`) · `:snapshot()` / `:applySnapshot()`.

### Destruction

Walls are indestructible until something says otherwise. That is deliberate: the
common case in a level is a wall that must never come down, so a stray explosion
cannot perforate a map by accident.

```lua
world:setDestructible(tx, ty, hp)         -- false if the tile is not solid
local destroyed, left = world:damageTile(tx, ty, amount)
world:destroyTile(tx, ty)                 -- regardless of hp
world:repairTile(tx, ty, hp)              -- puts back the original tile code
```

`:damageTile` on a tile that was never made destructible does nothing and reports
nothing — an explosion asks every tile in its radius and most of them say no.

A destroyed tile becomes `World.RUBBLE`: walkable, and **not drawn**. Columns are
full height here, so there is no low wall to draw and the renderer casts straight
through — a destroyed wall reads as a hole. Floor debris is a billboard the game
spawns, via:

```lua
world.onDestroy = function(world, tx, ty, wasTile) ... end
```

It fires once, after the world is updated, and carries the tile code that was
there so a game can pick debris to match. It also fires on clients during a world
delta apply, which is the point: debris is cosmetic, so every machine spawning its
own from the same event costs no bandwidth and needs no replication.

**Replication and saves.** `:snapshot()` / `:applySnapshot()` carry door state;
`:tileSnapshot()` / `:applyTileSnapshot()` carry destruction. Both list only what
differs from the map as authored, and both are keyed `"x,y"`. A key *disappearing*
means "back to how it was authored", which is how a repair travels — there is no
repair packet.

**`world.revision`** increments whenever the grid changes shape. Anything holding
derived geometry — a lighting bake, a batched mesh, a navmesh — compares it against
what it last built from and rebuilds when they differ. It is a counter rather than
a callback list so each consumer notices on its own schedule; a callback firing
mid-apply would invalidate a cache halfway through a frame. The built-in lighting
grid already does this in `:beginFrame()`.

### Elevation

```lua
world:setFloorHeight(tx, ty, z)     -- walk surface; 0 / nil clears
world:floorHeightAt(tx, ty)         -- default 0
world:setCeilingHeight(tx, ty, z)   -- ceiling plane; 1 / nil clears
world:ceilingHeightAt(tx, ty)       -- default 1
world:floorHeightPlanes()           -- unique floor z, always includes 0
world:ceilingHeightPlanes()         -- unique ceiling z, always includes 1
world:rebuildFloorRisers()          -- auto segments on platform edges
```

Map header lines: `floor tx ty z`, `ceiling tx ty z`, `height tx ty h`,
`slab tx ty base h`, `link up|down path [x y [angle]]` (multi-map storeys).
Multiple `---` grids = in-world layers. See [`STOREYS.md`](STOREYS.md).

`world:storeyCount()` · `world:addStorey(grid)` · `world:tileAt(tx,ty,storey)` ·
`e.storey` · `Raycaster.view{ storey = n }`.

---

## Pathfinding

A* over walkable tiles. Host-only in multiplayer — clients that pathfind their
own enemies will disagree with the host about where they walk.

```lua
local path = MeatRay.pathfind.find(world, fromX, fromY, toX, toY)
-- { { x, y, tx, ty }, ... } tile centres start → goal, or nil + reason

path = MeatRay.pathfind.simplify(world, path)   -- drop LOS-redundant corners
local wx, wy, i = MeatRay.pathfind.nextWaypoint(path, e.x, e.y, 0.35, i)
```

`opts.diagonal`, `opts.walkable`, `opts.maxExpand`. Closed doors block via
`world:isWalkable`. Expansion is capped (`Pathfind.MAX_EXPANDED`) so a tick
cannot hang on a pathological map.

## Triggers

Axis-aligned volumes with enter / stay / exit callbacks. Run on the host after
movement.

```lua
local box = MeatRay.triggers.new()
box:add{
    name = 'exit',
    x1 = 10, y1 = 4, x2 = 12, y2 = 6,
    onEnter = function(e, vol) ... end,
    onExit  = function(e, vol, reason) ... end,  -- 'leave' or 'dead'
    onStay  = function(e, vol, dt) ... end,      -- optional
    filter  = function(e) return e.kind == 'player' end,
    once    = false,
}
box:addTiles{ name = 'cell', tx1 = 3, ty1 = 3, tx2 = 4, ty2 = 4, onEnter = ... }

-- once per tick, after Collide.move:
box:update(entities, dt)
```

## AI (host-side)

Patrol / chase / cover on top of pathfind. `Brain` is a local component (no
`netFields`); clients only see the resulting transform.

```lua
MeatRay.ai.attach(e, {
    state = 'patrol',          -- idle | patrol | chase | cover
    patrol = { {x=5.5,y=5.5}, {x=8.5,y=5.5} },
    alertRange = 9, loseRange = 14, speed = 2.4,
})
-- host tick only:
MeatRay.ai.stepAll(entities, dt, { world = world, target = player })
```

## Decals

Headless marks (scorch, bullet holes). Rendering is the game's choice.

```lua
local marks = MeatRay.decals.new{ max = 256 }
marks:add{ x = 4.2, y = 5.1, kind = 'scorch', life = 8 }
marks:addHit(hx, hy, nx, ny, { kind = 'bullet' })
marks:update(dt)
for _, d in ipairs(marks:all()) do
    local a = MeatRay.decals.alpha(d)   -- 0..1 fade
end
```

## Game mode template

Lifecycle glue for a host-authoritative ruleset — not a genre package.

```lua
local mode = MeatRay.game.mode.new{
    name = 'dm',
    onStart = function(m, world, entities) end,
    onTick  = function(m, dt, world, entities) end,
    onCommand = function(m, host, peer, name, body) return false end,
}
mode:start(world, entities)
mode:tick(dt, world, entities)
```

## MeatGraphRay

Host-side event/action graphs — the raycast sibling of MeatEngine’s **MeatGraph**
(not “blueprints”; that is Unreal’s name). See [`MEATGRAPH_RAY.md`](MEATGRAPH_RAY.md).

```lua
local MG = MeatRay.game.meatgraphRay
local g = MG.load(jsonText)   -- or MG.example()
local mode = MeatRay.game.mode.new{ name = g.name }
MG.bindMode(mode, g, { log = print, world = world, Entity = MeatRay.entity, triggers = true })
mode:start(world, entities)
```

Demo: `love . --meatgraph` loads `meatgraphs/demo.graph.json`.

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
-- Delaunay + MST corridors (loops via loopChance):
local mst = MeatRay.worldgen.generate{ width=48, height=48, seed=7, layout='mst' }
local box = MeatRay.worldgen.box(20, 20)

-- Graph helpers (deterministic, no grid):
local tris, edges = MeatRay.worldgen.delaunay{ {x=0,y=0}, {x=1,y=0}, {x=0,y=1} }
local tree = MeatRay.worldgen.mst(#points, edges)
```

The generator carries **its own RNG** (`Worldgen.rng(seed)` → `:next/:float/:int`)
rather than using `math.random`, which differs between Lua 5.1, 5.3 and LuaJIT. A
host and client generating a world from one seed must get identical geometry.

| `layout` | Behaviour |
|---|---|
| `'bsp'` (default) | Binary space partition + sequential L-corridors. **Seed-stable** with older maps. |
| `'mst'` | Scatter rooms, Delaunay of centres, Kruskal MST corridors, optional extra edges (`loopChance`, default 0.15). |

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

MeatRay.net.host{ discovery = { 'lan', 'master' }, registries = { url1, url2 } }
MeatRay.net.join(browser:servers()[1])       -- punches, if the row came from a registry
```

Three independent axes: **mode** (`single`/`listen`/`dedicated`/`client`),
**transport** (`loopback`/`enet`/`relay`/`steam`), **discovery**
(`direct`/`lan`/`master`, Steam lobbies shaped for). A game that says nothing
about networking is in `single` mode and behaves exactly as before.

`transport = 'steam'` dials a Steam account rather than an address —
`MeatRay.net.join('steam:76561197960287930', { transport = 'steam' })` — and
needs a `luasteam` module and a running Steam client. When either is missing it
says so and every other transport keeps working; see `docs/NETWORKING.md`.

**Hole punching is automatic and asks first.** A host with `master` discovery
punches back at any client the registry introduces; the game overrides that with
`onPunch`. A client punches when it has a registry to ask -- which a server-list
row from `master` carries on itself, so joining a clicked row needs no extra
argument -- and `punch = false` turns it off. The punch leaves the game socket
(`transport:punch`), because a mapping opened for any other socket is worth
nothing. There is **no relay**: a punch that fails ends in a stated reason, and
`docs/NETWORKING.md` is explicit that NAT traversal itself is untested here.

Host: `update/step/spawn/despawn/toggleDoor/event/chat/kick/ban/players/info`.
Client: `update/setInput/command/chat/requestStats/alpha/leave`.

Replication derives from `netFields`. Snapshots are unreliable-sequenced at 20 Hz
against a 60 Hz tick with clients interpolating; **inputs travel client→host, never
positions**; world mutation is reliable. Local movement is predicted, **damage is
never predicted**.

Snapshots are packed by `meatray.net.snapcodec` into a compact binary body, and
that is a correctness constraint rather than an optimisation: ENet promotes a
*fragmented* unreliable packet to a reliable one, so a snapshot over 1364 bytes
(`MeatRay.net.protocol.MTU_SAFE_BYTES`) silently stops being part of a snapshot
stream. Measured, that moved the entity ceiling from 8–10 to 44. The codec reads
the same `netFields` declarations replication does, so adding a synced field
still needs no serialiser edit; `x`, `y` and `angle` are sent as float32 and
nothing else is quantised. Save files were left on the text serializer on
purpose.

Both halves of that are measured on real sockets rather than argued for. Under a
fifth of the downstream datagrams being destroyed, a 1349-byte snapshot stream
skipped 105 of 501 snapshots and never stalled, while a 1434-byte one skipped
none and arrived in bursts of up to seven — the promotion, caught happening.
Positions came back inside the binary32 half-ulp bound (worst relative error
5.07e-8 against a bound of 5.96e-8) and never exactly right, so the bound was
tested rather than sidestepped; `hp` values of 2^24+i, which binary32 cannot
represent, arrived exact. `scripts/netfrag.ps1` runs it.

See [`NETWORKING.md`](NETWORKING.md). `love . --netcheck` answers "can this machine
do UDP at all" in five checks ending in a real two-peer handshake.

---

## Gameplay rules

`MeatRay.game` is the rules half: attributes, effects, tags, abilities, damage,
weapons, projectiles, inventory, explosions and gas. Every line of it is headless,
because a dedicated server runs every line of it.

```lua
local Game = MeatRay.game
Game.attach(player, { authority = true })          -- false on a client
Game.attributes.grantAll(player, { health = 100, healthMax = 100 })
Game.tick(player, step)                            -- inside the fixed tick
```

**Damage is an effect, not a function call.** `Game.damage(target, 25, opts)`
applies an instant gameplay effect, which is why armour soaks it, a resistance
reduces it and an immunity refuses it — and why a rifle round, an explosion and
the fourth tick of a poison all compose with those three without any of them
knowing about the others. Nothing in the engine writes `health.hp` directly, and
game code should not either.

`Effects.apply` refuses on a container with `authority = false`, so there is no
path from client input to an attribute even by mistake.

### Weapons

```lua
Game.weapons.define('pistol', {
    damage = 12, magazine = 12, reserve = 60,
    fireInterval = 0.15, reloadTime = 1.4,
    spread = 0.012, recoil = 0.02, recoilRecovery = 0.5, range = 32,
})
Game.weapons.equip(player, 'pistol')

Game.weapons.tick(player, step)                    -- the ONLY writer of time
local shot, why = Game.weapons.fire(player, { world = world, entities = entities })
Game.weapons.reload(player)                        -- true, or false + a reason
Game.weapons.status(player)                        -- everything a HUD wants
```

`fire` never advances time; it reads the cooldown and refuses with `'cooldown'`.
The cooldown moves only in `tick`, once per fixed simulation step — so a client
that sends fire requests faster than the tick rate does not fire faster than the
tick rate. `intervalTicks(id, rate)` reports how many whole steps a shot costs.

Spread and recoil come from `meatray.sim.worldgen.rng`, never `math.random`.
Recoil is **reported** as `shot.kick` rather than written into the shooter's
angle, because aim is an input and the host takes it verbatim; the client that
owns the aim applies the kick.

`kind = 'projectile'` launches entities instead:

```lua
Game.projectiles.step(entities, step, { world = world, entities = entities })
Game.projectiles.sweep(entities)
```

Flight is substepped, so a bolt fast enough to cross a tile in one step still
stops at the wall in it.

### Inventory

```lua
Game.inventory.defineItem('ammo.9mm', { stack = 60, ammoFor = 'pistol' })
Game.inventory.attach(player, { capacity = 8 })

local added, leftover, why = Game.inventory.add(player, 'ammo.9mm', 150)
local taken, left = Game.inventory.pickup(player, groundEntity)
local pickup = Game.inventory.drop(player, slot, count, { entities = entities })
Game.inventory.equip(player, slot)                 -- drives the weapon component
```

**`added + leftover` always equals what was asked for.** Overflow is returned, not
deleted; a pickup that half fits leaves the remainder on the floor and the world
entity survives. Equipping wires the weapon's reload to this bag, so a reload
consumes the item whose `ammoFor` names the weapon.

The replicated state is one string on the `inventory` component, so a bag
replicates and saves with nothing added to either layer.

### Explosions

```lua
Game.explosion.detonate{
    world = world, entities = entities,
    x = 12.5, y = 9.5, radius = 4, damage = 60,
    tags = { 'damage.type.explosive' }, source = shooter,
    lighting = lightGrid,          -- optional; or onLight = function(light) end
}
```

Falloff through a named curve (`linear`, `smooth`, `inverse`), occluded by walls
via `Collide.lineOfSight`, applying effects. The flash is **described** and handed
out: pass a light grid or a callback and it is pushed, pass neither and the result
still carries `light` for a host to forward as an event.

### Gas

```lua
local field = Game.gas.new{ world = world, name = 'smoke', rate = 2, decay = 0.15 }
field:emit(tx, ty, amount)
field:emitCircle(x, y, radius, amount)
field:step(step)                                   -- returns visited, flows
field:wake(tx, ty)                                 -- after a door opens
Game.gas.damage(field, entities, step, { amount = 20, tags = { 'damage.type.fire' } })
```

Smoke, fire and toxic clouds are the same field with different constants. Cost
scales with **activity**: cells wake on change, settled cells sleep, and
`step()` on a settled field visits nothing. With `decay = 0` mass is conserved
exactly; with decay the rate is exact and everything removed is booked to
`field.lost`. Gas never crosses a tile the world calls solid, which includes a
closed door.

The one obligation: when the world changes shape, call `field:wake(tx, ty)`. Two
settled cells either side of a door cannot notice it opened, because nothing
about *them* changed.

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
