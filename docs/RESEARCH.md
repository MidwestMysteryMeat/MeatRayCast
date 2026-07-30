# Prior art

A survey of open-source raycasters, done to answer specific questions rather
than to browse. It is recorded here mostly for its **negative** results: the
things that look promising, cost a day to evaluate, and turn out to be dead
ends. Those are the findings that get quietly re-discovered a year later by
someone who has no way of knowing the question was already asked.

Nothing listed here is vendored. Nothing here changed `NOTICE`.

## The licence trap, and why it is written down twice

One research pass reported that lodev's raycaster — the source `raycaster.lua`
is derived from, and the one entry in our `NOTICE` — is "All rights reserved,
no licence anywhere, not open source."

**That is wrong.** It came from reading the tutorial page footer instead of the
source files. Fetching `raycaster_textured.cpp`, `raycaster_floor.cpp` and
`raycaster_sprites.cpp` directly shows all three carry a verbatim 2-clause BSD
grant under `Copyright (c) 2004-2019, Lode Vandevenne`. The "All rights
reserved" line that triggered the false alarm is part of the standard BSD
boilerplate itself, not a withdrawal of the grant.

`NOTICE` already explains this, at the bottom, for exactly this reason. It is
repeated here because the failure mode is not "someone doesn't know" — it is
"someone checks, checks badly, and confidently concludes the attribution is
wrong." An attribution removed on that basis would be a licence violation
introduced by an act of diligence.

**Do not act on a licence claim about this project's dependencies without
reading the source file headers yourself.** A repo page, a footer, and GitHub's
own licence detector are all capable of being wrong in both directions.
GitHub reported `NOASSERTION` for one candidate below whose `LICENSE` is
verbatim MIT.

## Answers to questions we actually had

**Variable-height walls / thin walls** — `andrew-lim/sdl2-raycast` (MIT) is the
best architecture document found. Stacked same-dimension grids give you levels;
a `ThinWall {x1,y1,x2,y2,height,z,slope}` is a Doom-style linedef segment.

The genuinely useful structural finding: **thin walls do not modify the DDA at
all.** A separate ray-vs-segment pass runs along the same ray and appends into
the same hit list. Arbitrary-angle walls inside a tile grid cost nothing
architecturally.

The expensive finding: **the per-column z-buffer does not survive.** Once walls
stack, sorting by distance to the wall *face* is wrong — it must be distance to
the wall *base* — and the design collapses into one global list of every hit
from every column and level, sorted far-to-near. Before committing to variable
height, read `src/raycasting.h` and decide whether that trade is wanted. In
LuaJIT it is the part that would hurt: a per-frame array of `columns × levels`
records plus an O(n log n) sort with a non-trivial comparator. If it is ever
done here, bucket by quantised distance or sort per column — do not port the
comparator-based global sort.

**Floor and ceiling casting** — `raycaster_floor.cpp`, same author and same BSD
grant as the file already attributed. If implemented, add that filename to
`NOTICE`. A shader path exists (`melchor629/raycastergl`, MIT) that runs the
DDA in a compute shader; its per-column output struct is a good independent
specification of what a column actually needs to carry.

**Mirrors and recursive portals** — nothing exists. Two independent sweeps found
no open-source tile-grid raycaster that implements them. The canonical tutorial
gives one sentence and no code. This is genuinely unsolved territory in the
public corpus, not something being overlooked.

**Sprite stacking** — a firm no, with a reason rather than a preference.
Stacking offsets slices by a *constant screen-space vector*, which requires a
fixed camera pitch and no perspective divide. In a first-person view the offset
has to vary with distance and screen-x, and at that point it has become
billboarding again. Directional billboards plus a `z` field cover the same
ground.

**The `cub3d` category** — dozens of repositories from the same school
assignment. All unlicensed, all close transcriptions of the same tutorial.
Skip the entire class; there is no independent signal in it.

## On batching

The most elegant batched implementation found draws the whole screen as one
vertex array with 2 vertices per column and shading carried as vertex colour.
It is unlicensed, and it does not port: LÖVE's `Mesh` has no textured lines
mode, so it would need 4 vertices and a static vertex map per column.

The portable version needs `Mesh:setVertices` fed from a `ByteData` rather than
a Lua table — the table overload iterates *in Lua*, and at 4 verts × 800
columns per frame that iteration costs more than the draw calls it saves. That
is FFI buffer work living in the platform seam.

So the batching work done here deliberately took the cheaper route: remove what
defeats LÖVE's *existing* automatic batching rather than hand-build a mesh. See
the commit history for `render/raycaster.lua` and the measured numbers.

## Verdict on vendoring

Nothing surveyed clears the bar. The engine's one piece of derived code is
already attributed. Every idea above is reusable as an *idea* — a data layout, a
proof that an approach does or does not work — without copying a line.
