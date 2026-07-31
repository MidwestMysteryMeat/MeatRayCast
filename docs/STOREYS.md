# Elevation vs multi-storey

People reasonably look at platforms, ramps, and low ceilings and say “we already
have multiple floors.” Half true. This note freezes the distinction so we do not
rebuild the wrong system.

## What MeatRayCast has today (one storey, many heights)

Everything lives in a **single continuous height range**, roughly wall units
`0 … 1` (with raised floors still in that band):

| Feature | What it is |
|---|---|
| `floor` heights | Raised walk surfaces (platforms, ramps). You step up within `Collide.MAX_STEP`. |
| `ceiling` heights | Lowered/raised ceiling *planes* over open tiles (crouch corridors, atriums). |
| Wall slabs | Short walls, floating rails, stacked vertical faces on **one** plan. |
| `^` / `v` stairs tiles | Markers / open floor; real “stairs” in gameplay are usually adjacent floor heights. |
| Camera crouch | Eye height clamps under a low ceiling. |

Think of a **warehouse with a mezzanine**: one big room, some platforms higher,
some ceilings lower. The plan (x, y) is unique — each tile has **one** walk
surface and **one** ceiling.

```
  ceiling ─────────────────
       room volume
  platform ════╗
               ║ riser
  floor ═══════╩═══════════
```

That is **not** a second floor of the building. There is no room *above* the
ceiling that you can walk into.

## What “stacked multi-storey” means (not built)

True multi-storey means **two walkable rooms in the same (x, y) column**, stacked
in z, with a ceiling/floor slab between them:

```
  upper floor walk ════════
  upper room
  ceiling/floor between ───
  lower room
  lower floor walk ════════
```

You go upstairs, walk around *above* the room you were just in, and look down a
stairwell into it (or not, if solid). That needs:

1. **More than one walk surface per tile** (or a whole second grid / storey index).
2. **Collision** that knows which storey you are on.
3. **Rendering** that hits walls/floors/ceilings on multiple vertical bands and
   sorts them correctly.

Research note (`docs/RESEARCH.md`): once walls *stack* in z, a naive per-column
z-buffer tends to break — hit lists grow by levels × columns and want a careful
sort (per column, not a global O(n log n) every frame in LuaJIT). That is why
this stayed “architecture,” not a weekend polish item.

## Practical multi-floor *gameplay* without that renderer rewrite

**Multi-map storeys:** each floor of the building is a **separate map**. Stairs
load the other map (with an optional arrival spawn). Doom-style elevators and
many FPS campaigns do exactly this.

```
link up   maps/tower_upper.map  4.5 3.5 0
link down maps/tower_ground.map 6.5 8.5 0
```

Stand on a `^` / `v` tile and press **F** (same key as doors): if the map
declared a link, the demo swaps worlds. State of the floor you left is not kept
unless you add a save/slot later — this is a level transition, not a seamless
building.

That is **shipped** for authored maps. It is the honest way to get “go upstairs”
today.

## When to invest in true stacked storeys

Worth it if you need:

- Looking between floors in one continuous space
- One networked world that spans floors without map swaps
- Vertical combat across a stairwell without a load

Not worth it yet if:

- Campaign floors can be separate maps
- Platforms / mezzanines already cover level design
- You would rather spend time on gameplay (MeatGraphRay, modes, AI)

## Related demos

| Command | What you see |
|---|---|
| `love . --map platforms` | Raised floors, risers, short rail (one storey) |
| `love . --map crouch` | Low ceilings / eye crouch (one storey) |
| `love . --map tower` | Ground floor; **F** on `^` goes to upper map |

## API sketch (true stack — future)

Not implemented. If it ever is, prefer something like:

- `world.storey` or `world.layers[storey].grid`
- Or per-tile `floors = { {z0,z1,walk}, {z0,z1,walk} }`

…and a raycaster hit list that records **vertical span** per surface, sorted
far-to-near **per column**. Do not port a global multi-level sort without a
budget test.
