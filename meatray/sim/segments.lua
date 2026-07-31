--[[
    meatray.sim.segments — walls that are not tile faces.

    A tile grid can only make walls at right angles on a lattice, which is why
    every raycaster built on one looks like it was built on one. A segment is a
    line between two arbitrary points: a diagonal, an angled corridor, a bar
    across a doorway, the hypotenuse of a room that is not a rectangle.

    **This does not touch the DDA, and that is the whole reason it is affordable.**
    The grid walk is unchanged and still finds the nearest tile face. A separate
    ray-vs-segment pass runs along the same ray, and whichever hit is nearer
    wins the column. So the renderer keeps its per-column z-buffer: a column
    still resolves to exactly one distance.

    That is the line this module deliberately does not cross. Walls that STACK --
    a rail above a floor you can see under -- would mean a column holding several
    hits at different heights, sorted by distance to the wall *base* rather than
    its face, and the per-column z-buffer collapses into one global sorted list
    of every hit in the frame. Segments give arbitrary angles for free. Height
    is a different feature with a real architectural price, and mixing them would
    hide that price inside this change. See docs/RESEARCH.md.

    Segments are opaque and full height, for the same reason: a see-through
    segment is a column with two hits, which is the same collapse wearing a
    friendlier name.

    HEADLESS: no love, no socket. Pure geometry.
]]

local Segments = {}

local floor, min, max, sqrt, huge = math.floor, math.min, math.max, math.sqrt, math.huge

-- A ray that starts exactly on a segment must not immediately hit it. Without
-- this a mover standing against a diagonal shoots itself: the hitscan begins on
-- the surface, `t` solves to ~0, and the shot stops at the shooter's feet.
Segments.EPSILON = 1e-9

local SetMT = {}
SetMT.__index = SetMT

---------------------------------------------------------------------------
-- Construction
---------------------------------------------------------------------------

function Segments.new()
    return setmetatable({
        list    = {},        -- every segment, in insertion order
        -- buckets[tx][ty] = { index, ... }. Nested tables rather than a 'tx,ty'
        -- string key: the renderer asks once per tile per column, and a string
        -- built per lookup is an allocation in the hottest loop in the engine.
        -- Nesting also puts no ceiling on coordinates, which a packed integer
        -- key would.
        buckets = {},
        count   = 0,
    }, SetMT)
end

-- Files a segment under every tile its bounding box covers.
--
-- The box rather than the exact traversal: a segment crossing a tile corner
-- diagonally would need its own DDA to bucket precisely, and the cost of
-- getting it slightly wrong is asymmetric. An extra bucket means a few wasted
-- intersection tests; a missing one means a wall a ray passes straight through,
-- which is invisible until someone walks through it.
function SetMT:index(i, seg)
    local tx1 = floor(min(seg.x1, seg.x2)) + 1
    local tx2 = floor(max(seg.x1, seg.x2)) + 1
    local ty1 = floor(min(seg.y1, seg.y2)) + 1
    local ty2 = floor(max(seg.y1, seg.y2)) + 1

    for ty = ty1, ty2 do
        for tx = tx1, tx2 do
            local column = self.buckets[tx]
            if not column then
                column = {}
                self.buckets[tx] = column
            end
            local bucket = column[ty]
            if not bucket then
                bucket = {}
                column[ty] = bucket
            end
            bucket[#bucket + 1] = i
        end
    end
end

-- Adds a segment. `tex` selects a wall texture the same way a tile code does,
-- so a segment and a tile wall are drawn by the same path.
--
-- Returns the segment, or nil plus a reason. A zero-length segment is refused
-- rather than stored: it can never be hit, it would sit in the buckets being
-- tested forever, and it is always a mistake in the caller.
function SetMT:add(x1, y1, x2, y2, tex)
    if type(x1) ~= 'number' or type(y1) ~= 'number'
       or type(x2) ~= 'number' or type(y2) ~= 'number' then
        return nil, 'a segment needs four numbers'
    end

    local dx, dy = x2 - x1, y2 - y1
    local length = sqrt(dx * dx + dy * dy)
    if length <= Segments.EPSILON then
        return nil, 'a segment of zero length can never be hit'
    end

    local seg = {
        x1 = x1, y1 = y1, x2 = x2, y2 = y2,
        dx = dx, dy = dy,
        length = length,
        tex = tex or 1,
    }

    self.count = self.count + 1
    self.list[self.count] = seg
    self:index(self.count, seg)

    return seg
end

function SetMT:clear()
    self.list = {}
    self.buckets = {}
    self.count = 0
    return self
end

function SetMT:isEmpty()
    return self.count == 0
end

-- The segments filed under a tile, or nil. Exposed because the renderer walks
-- tiles in DDA order and wants to test only what the tile it just entered holds.
function SetMT:at(tx, ty)
    local column = self.buckets[tx]
    return column and column[ty]
end

---------------------------------------------------------------------------
-- Ray against one segment
---------------------------------------------------------------------------

-- Returns distance along the ray, and how far along the segment the hit fell
-- (0..1), or nil.
--
-- Standard two-line intersection, written out rather than folded into one
-- expression because the denominator sign carries meaning: zero means parallel,
-- and parallel-and-collinear is the case that produces a division by zero and a
-- NaN distance that compares false against every other distance -- so the wall
-- silently vanishes rather than erroring.
function Segments.rayHit(seg, ox, oy, dirX, dirY, maxDist)
    local denom = dirX * seg.dy - dirY * seg.dx
    if denom > -Segments.EPSILON and denom < Segments.EPSILON then
        return nil                      -- parallel, including collinear
    end

    local ex, ey = seg.x1 - ox, seg.y1 - oy

    -- Distance along the ray.
    local t = (ex * seg.dy - ey * seg.dx) / denom
    if t <= Segments.EPSILON then return nil end
    if maxDist and t > maxDist then return nil end

    -- Position along the segment, 0 at (x1,y1) and 1 at (x2,y2).
    local u = (ex * dirY - ey * dirX) / denom
    if u < 0 or u > 1 then return nil end

    return t, u
end

-- The nearest segment hit along a ray, testing only the tiles the caller names.
--
-- `tiles` is a flat list of tx,ty pairs -- normally the tiles a DDA stepped
-- through. Passing nil tests everything, which is correct but linear in the
-- segment count and is only meant for small worlds and tests.
function SetMT:nearest(ox, oy, dirX, dirY, maxDist, tiles)
    local bestT, bestU, bestSeg = maxDist or huge, nil, nil
    local list = self.list

    -- Written out twice rather than through a local `consider` closure. A
    -- closure allocates on every call, and this is called per column per frame:
    -- at 960 columns that is 960 allocations a frame for a helper that saves
    -- eight lines.
    if tiles then
        -- A segment spans several tiles, so the same index turns up more than
        -- once along a ray. Tested twice is only wasted work, and the table
        -- needed to avoid it costs more than the handful of segments a tile
        -- holds.
        for i = 1, #tiles, 2 do
            local bucket = self:at(tiles[i], tiles[i + 1])
            if bucket then
                for b = 1, #bucket do
                    local seg = list[bucket[b]]
                    if seg then
                        local t, u = Segments.rayHit(seg, ox, oy, dirX, dirY, bestT)
                        if t and t < bestT then bestT, bestU, bestSeg = t, u, seg end
                    end
                end
            end
        end
    else
        for i = 1, self.count do
            local seg = list[i]
            if seg then
                local t, u = Segments.rayHit(seg, ox, oy, dirX, dirY, bestT)
                if t and t < bestT then bestT, bestU, bestSeg = t, u, seg end
            end
        end
    end

    if not bestSeg then return nil end
    return bestT, bestU, bestSeg
end

---------------------------------------------------------------------------
-- Movement
---------------------------------------------------------------------------

-- Shortest distance from a point to a segment, and the closest point on it.
-- Used for collision: a mover is a circle, so it is blocked when this is under
-- its radius.
function Segments.distanceTo(seg, px, py)
    local t = ((px - seg.x1) * seg.dx + (py - seg.y1) * seg.dy)
              / (seg.length * seg.length)
    t = max(0, min(1, t))          -- clamp to the segment, not its infinite line

    local cx = seg.x1 + seg.dx * t
    local cy = seg.y1 + seg.dy * t
    local ddx, ddy = px - cx, py - cy

    return sqrt(ddx * ddx + ddy * ddy), cx, cy
end

-- True if a circle at (x,y) overlaps any segment.
--
-- Tests the tile the circle is in and its eight neighbours, because a circle
-- near a tile edge overlaps a segment filed under the tile next door. Missing
-- that is how a mover walks through a wall only when approaching it from one
-- particular direction -- a bug that looks like the wall is intermittent.
function SetMT:blocked(x, y, radius)
    if self.count == 0 then return false end

    local tx, ty = floor(x) + 1, floor(y) + 1

    for oy = -1, 1 do
        for ox = -1, 1 do
            local bucket = self:at(tx + ox, ty + oy)
            if bucket then
                for b = 1, #bucket do
                    local seg = self.list[bucket[b]]
                    if seg and Segments.distanceTo(seg, x, y) < radius then
                        return true, seg
                    end
                end
            end
        end
    end

    return false
end

Segments.SetMT = SetMT

return Segments
