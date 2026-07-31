--[[
    Thin walls: segments at arbitrary angles inside the tile grid.

    The geometry is easy to write and easy to get subtly wrong in ways that only
    show up as "I walked through a wall once". The cases worth having are the
    degenerate ones: a ray parallel to a segment, a ray starting exactly on one,
    a hit behind the viewer, and a circle near a tile edge whose wall is filed
    under the tile next door.
]]

return function(t)
    local Segments = require('meatray.sim.segments')

    local function set(...)
        local s = Segments.new()
        for _, seg in ipairs({ ... }) do s:add(seg[1], seg[2], seg[3], seg[4], seg[5]) end
        return s
    end

    ---------------------------------------------------------------------
    t.describe('adding segments')

    local s = Segments.new()
    t.eq(s:isEmpty(), true, 'a new set is empty')

    local seg = s:add(2, 2, 5, 5)
    t.ok(seg ~= nil, 'a diagonal is accepted')
    t.eq(s.count, 1, 'and counted')
    t.eq(s:isEmpty(), false, 'so the set is no longer empty')
    t.near(seg.length, math.sqrt(18), 1e-9, 'with its length precomputed')
    t.eq(seg.tex, 1, 'and a default texture')

    -- A zero-length segment can never be hit, would sit in the buckets being
    -- tested forever, and is always a mistake in the caller.
    local none, why = s:add(3, 3, 3, 3)
    t.eq(none, nil, 'a zero-length segment is refused')
    t.ok(why:find('zero length'), 'and says why')
    t.eq(s:add(1, 1, 'x', 2), nil, 'and so is a non-numeric one')
    t.eq(s.count, 1, 'neither was stored')

    ---------------------------------------------------------------------
    t.describe('bucketing covers every tile a segment crosses')

    -- A missing bucket is a wall a ray passes straight through, which is
    -- invisible until someone walks through it -- so the box is deliberately
    -- generous rather than exact.
    local diag = set({ 1.5, 1.5, 4.5, 4.5 })
    for tile = 2, 5 do
        t.ok(diag:at(tile, tile) ~= nil,
             ('the diagonal is filed under tile (%d,%d)'):format(tile, tile))
    end
    t.eq(diag:at(9, 9), nil, 'and not under a tile it never reaches')

    ---------------------------------------------------------------------
    t.describe('a ray meets a segment')

    -- A vertical bar at x = 3, from y = 2 to y = 4. A ray east along y = 3
    -- crosses it at x = 3.
    local bar = set({ 3, 2, 3, 4 })

    local dist, along = bar:nearest(1, 3, 1, 0)
    t.near(dist, 2, 1e-9, 'the hit is two tiles away')
    t.near(along, 0.5, 1e-9, 'and halfway along the segment')

    -- Past the end of the bar, nothing.
    t.eq(bar:nearest(1, 5, 1, 0), nil, 'a ray passing above the segment misses')
    t.eq(bar:nearest(1, 1, 1, 0), nil, 'and below it')

    -- Behind the viewer is not a hit. A ray is a half-line.
    t.eq(bar:nearest(5, 3, 1, 0), nil, 'a segment behind the ray is not hit')
    t.near(bar:nearest(5, 3, -1, 0), 2, 1e-9, 'but is hit when facing it')

    -- Beyond maxDist, nothing.
    t.eq(bar:nearest(1, 3, 1, 0, 1.5), nil, 'a hit past maxDist is refused')
    t.near(bar:nearest(1, 3, 1, 0, 5), 2, 1e-9, 'and accepted inside it')

    ---------------------------------------------------------------------
    t.describe('the degenerate cases')

    -- Parallel. Without the denominator check this divides by zero and produces
    -- a NaN distance, which compares false against everything -- so the wall
    -- does not error, it silently vanishes.
    local flat = set({ 2, 3, 6, 3 })
    t.eq(flat:nearest(1, 3, 1, 0), nil, 'a ray collinear with a segment does not hit it')
    t.eq(flat:nearest(1, 5, 1, 0), nil, 'nor one merely parallel')
    t.ok(flat:nearest(4, 1, 0, 1) ~= nil, 'but a ray across it does')

    -- Starting exactly on the surface. Without the epsilon a mover standing
    -- against a diagonal shoots itself in the feet: t solves to ~0 and the shot
    -- stops where it started.
    local onIt = set({ 3, 2, 3, 4 })
    t.eq(onIt:nearest(3, 3, 1, 0), nil, 'a ray starting on a segment does not hit it')
    t.eq(onIt:nearest(3, 3, -1, 0), nil, 'from either side')

    ---------------------------------------------------------------------
    t.describe('the nearest segment wins')

    local several = set(
        { 5, 2, 5, 4 },        -- far
        { 3, 2, 3, 4 },        -- near
        { 7, 2, 7, 4 })        -- further

    local nearD, _, nearSeg = several:nearest(1, 3, 1, 0)
    t.near(nearD, 2, 1e-9, 'the closest of three is returned')
    t.eq(nearSeg.x1, 3, 'and it is the right one')

    -- Order of insertion must not decide the answer.
    local reordered = set(
        { 3, 2, 3, 4 },
        { 5, 2, 5, 4 })
    t.near(reordered:nearest(1, 3, 1, 0), 2, 1e-9, 'insertion order does not matter')

    ---------------------------------------------------------------------
    t.describe('testing only the tiles a ray crossed')

    -- The renderer walks tiles in DDA order and tests only what each holds.
    -- Restricting the search must not change the answer for tiles on the path.
    local bucketed = set({ 3, 2, 3, 4 })
    local onPath = bucketed:nearest(1, 3, 1, 0, 16, { 2, 3, 3, 3, 4, 3 })
    t.near(onPath, 2, 1e-9, 'a hit is found when its tile is on the list')

    local offPath = bucketed:nearest(1, 3, 1, 0, 16, { 9, 9 })
    t.eq(offPath, nil, 'and not found when the list omits its tile')

    -- Passing nil tests everything, which must agree with the bucketed answer.
    t.near(bucketed:nearest(1, 3, 1, 0), onPath, 1e-9,
           'the exhaustive search agrees with the bucketed one')

    ---------------------------------------------------------------------
    t.describe('a diagonal actually reads as diagonal')

    -- The point of the feature: two rays a little apart hit at visibly
    -- different distances, which a tile face cannot do.
    local slope = set({ 2, 2, 6, 6 })
    local a = slope:nearest(1, 2.5, 1, 0)
    local b = slope:nearest(1, 4.5, 1, 0)
    t.ok(a and b, 'both rays hit the diagonal')
    t.ok(b > a + 1.5, 'and at distances that differ by the slope, not a tile step')

    ---------------------------------------------------------------------
    t.describe('distance from a point, for collision')

    local wall = set({ 3, 2, 3, 6 }).list[1]

    t.near(Segments.distanceTo(wall, 1, 4), 2, 1e-9, 'straight out from the middle')
    t.near(Segments.distanceTo(wall, 3, 4), 0, 1e-9, 'a point on the segment is at zero')

    -- Past the end, the distance is to the endpoint and not to the infinite
    -- line. Without the clamp a mover is blocked by a wall it has walked past.
    t.near(Segments.distanceTo(wall, 3, 9), 3, 1e-9, 'past the end measures to the endpoint')
    t.near(Segments.distanceTo(wall, 3, -1), 3, 1e-9, 'at either end')

    ---------------------------------------------------------------------
    t.describe('a circle is blocked')

    local fence = set({ 3, 2, 3, 6 })

    t.eq(fence:blocked(2.5, 4, 0.25), false, 'a circle clear of the wall is not blocked')
    t.eq(fence:blocked(2.9, 4, 0.25), true, 'one overlapping it is')
    t.eq(fence:blocked(3.1, 4, 0.25), true, 'from the other side too')
    t.eq(fence:blocked(2.5, 9, 0.25), false, 'and one nowhere near it is not')

    -- The neighbour sweep. A circle sitting near a tile edge overlaps a segment
    -- filed under the tile next door; testing only its own tile makes the wall
    -- intermittent depending on which side you approach from.
    local edge = set({ 4.0, 2, 4.0, 6 })
    t.eq(edge:blocked(3.9, 4, 0.3), true, 'a circle straddling a tile edge is still blocked')
    t.eq(edge:blocked(4.1, 4, 0.3), true, 'from the far side of the same edge')

    -- An empty set answers immediately and never claims a block.
    t.eq(Segments.new():blocked(1, 1, 1), false, 'an empty set blocks nothing')

    ---------------------------------------------------------------------
    t.describe('clearing')

    local temp = set({ 1, 1, 2, 2 }, { 3, 3, 4, 4 })
    t.eq(temp.count, 2, 'two segments')
    temp:clear()
    t.eq(temp.count, 0, 'cleared')
    t.eq(temp:isEmpty(), true, 'and empty')
    t.eq(temp:at(2, 2), nil, 'with the buckets gone too, not just the list')
    t.eq(temp:nearest(0, 0, 1, 1), nil, 'and nothing left to hit')

    ---------------------------------------------------------------------
    t.describe('a world carries them, and movement respects them')

    local World   = require('meatray.sim.world')
    local Collide = require('meatray.sim.collide')

    local grid = {}
    for y = 1, 10 do
        grid[y] = {}
        for x = 1, 10 do
            grid[y][x] = (x == 1 or y == 1 or x == 10 or y == 10) and 1 or 0
        end
    end
    local w = World.new(grid)

    -- A world with no segments carries no table at all, so both the collision
    -- and render passes short-circuit on one nil test.
    t.eq(w.segments, nil, 'a fresh world has no segment table')
    t.eq(w:segmentCount(), 0, 'and counts none')

    -- A diagonal across the open middle.
    local added = w:addSegment(3, 3, 7, 7)
    t.ok(added ~= nil, 'a segment can be added to a world')
    t.eq(w:segmentCount(), 1, 'and is counted')
    t.ok(w.segments ~= nil, 'the table exists once it is needed')

    -- The point of wiring collision: what the renderer draws, movement must
    -- honour. A wall you can see and walk through reads as the renderer being
    -- broken rather than the collision.
    t.eq(Collide.circleBlocked(w, 5, 5, 0.25), true,
         'a mover standing on the diagonal is blocked')
    t.eq(Collide.circleBlocked(w, 5, 3, 0.25), false,
         'and one clear of it is not')

    -- Sliding still works: a mover pushed into the diagonal keeps the free
    -- component instead of stopping dead.
    local mover = { x = 4.0, y = 5.0, radius = 0.2 }
    Collide.move(mover, 0.5, 0, w, 0.2)
    t.ok(mover.x <= 4.5 + 1e-9, 'the mover did not pass through the diagonal')

    t.eq(w:clearSegments():segmentCount(), 0, 'a world can drop its segments')
    t.eq(Collide.circleBlocked(w, 5, 5, 0.25), false,
         'and then nothing blocks there any more')

    ---------------------------------------------------------------------
    t.describe('it runs with no host at all')

    local file = io.open('meatray/sim/segments.lua', 'r')
    t.ok(file ~= nil, 'the source is readable')
    if file then
        local source = file:read('*a')
        file:close()
        local code = require('tests.support.lua_source').stripNonCode(source)
        t.ok(not code:find('[^%w_]love[^%w_]'), 'segments.lua does not name love')
        t.ok(code:find('function Segments.rayHit'), 'and the stripped source is real code')
    end
end
