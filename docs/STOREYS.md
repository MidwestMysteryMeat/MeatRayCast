# Elevation, multi-map storeys, and in-world layers

Three different ideas people call “multiple floors.” MeatRayCast supports all
three at different depths.

## 1. Elevation (one storey, many heights) — shipped

Platforms, ramps, low ceilings on a **single** plan. Each (x, y) has one walk
surface and one ceiling. See phase 18 in `ROADMAP.md`.

```
love . --map platforms
love . --map crouch
```

## 2. Multi-map storeys — shipped

Each building floor is a **separate map**. Stairs load the other map.

```
link up   maps/tower_upper.map  2.5 3.5 0
link down maps/tower.map        5.5 5.5 0
```

```
love . --map tower    # F on ^ / v
```

Campaign floors, no shared world state between loads.

## 3. In-world layered storeys — shipped (v1)

**Same world, multiple layer grids**, same width×height. Walk upstairs without
reloading a map. Active-storey render only (you do not yet look into the floor
below through a stairwell).

### Design (locked)

| Decision | Choice |
|---|---|
| Structure | `world.layers[1..N]` full plans, not multi-band cells |
| Absolute z | Storey *s* sits in `[(s-1)·H, s·H)`, `H = World.STOREY_HEIGHT` (1) |
| Relative heights | Floor/ceiling/slabs still 0..1 **within** a storey |
| Entity | `e.storey` (default 1) + absolute `e.z` |
| Collision | Queries the entity’s storey only |
| Render v1 | DDA / floor cast / sprites use `view.storey` only |
| Per-column hits | Existing multi-slab sort; **no** global multi-level sort |
| Stairs | `^`/`v` + **F** → change `storey` ±1 when `storeyCount > 1` |
| Multi-map `link` | Still works when there is only one layer |

### Map format

Multiple grids after `---`. Same dimensions required.

```text
name  Stacked
theme dungeon
spawn 2.5 5.5 0
entity c crystal
---
##########
#...^....#     storey 1
##########
---
##########
#...v.c..#     storey 2
##########
```

Header `floor` / `ceiling` / `slab` lines apply to **storey 1** in v1.
Entity markers on storey *n* get `storey = n`.

```
love . --map stacked
```

### API

```lua
world:storeyCount()
world:storeyBase(s)           -- (s-1) * STOREY_HEIGHT
world:addStorey(grid, opts)
world:tileAt(tx, ty, storey)
world:isSolid(tx, ty, storey)
world:absoluteFloorAtPoint(x, y, storey)

e.storey = 2
Collide.ground(e, world)      -- sets absolute e.z

Raycaster.view(x, y, a, { storey = e.storey, eyeZ = ... })
```

Top-level `world.grid` / `world.doors` / … are the **same tables** as
`layers[1]` — one-layer maps are unchanged.

### Also in v1 (wire + authoring)

- Entity `storey` on the snapshot wire (snapcodec v4 / protocol 5)
- Map serialize/fromWorld multi-grid round-trip

### Phase 2 progress

- **Wall peek across storeys** — raycaster emits wall faces from every layer at
  each DDA cell. Open tiles show walls below/above. Only the active storey stops
  the ray; sort stays per-column.
- **Floor/ceiling cast across storeys** — absolute floor planes from every layer
  below the eye (and ceilings above) are drawn far-to-near with that layer’s
  height texture, so looking down a stairwell paints the lower floor.
- **Storey-scoped elevation headers** — `floor 2 3 4 0.3` = storey 2, tile
  (3,4), z 0.3. Same for `ceiling`, `height`, `slab`.
- **Entity isolation** — overlap and query respect storey; sprites only draw on
  the camera’s storey. Hitscan already storey-scoped.

Still open:

- Full multi-layer door/destruction net keys
- AI awareness of other storeys (pathfind stays same-storey)

### Why not “one grid with multi-band floors only”?

Layers match authoring (two plans) and keep `isSolid` simple. Wall slabs already
cover multi-height *faces*; the missing piece was a second walkable plan, which
is a second grid.
