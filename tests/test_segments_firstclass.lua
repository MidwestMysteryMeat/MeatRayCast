--[[
    E39: segments are first-class for sight, shots and pathing — not just for the
    renderer and movement. A diagonal/angled bar now blocks line-of-sight, stops
    a hitscan, blocks AI sight, and walls off a path edge, so all of render,
    movement, sight, shots and pathfinding agree a segment is solid.
]]

return function(t)
    local Worldgen = require('meatray.sim.worldgen')
    local Collide  = require('meatray.sim.collide')
    local Pathfind = require('meatray.sim.pathfind')
    local AI       = require('meatray.sim.ai')

    local function room()
        return Worldgen.box(8, 8)   -- open interior, walls on the border
    end

    ---------------------------------------------------------------------
    t.describe('a segment blocks line of sight')

    local w = room()
    t.ok(Collide.lineOfSight(w, 2.5, 4.5, 6.5, 4.5, 1),
         'clear sight across the open room')
    w:addSegment(4, 0, 4, 8)        -- a full-height wall at x=4
    t.ok(not Collide.lineOfSight(w, 2.5, 4.5, 6.5, 4.5, 1),
         'the segment now blocks the same sight line')
    -- AI sight uses the same path.
    t.ok(not AI.hasLineOfSight(w, 2.5, 4.5, 6.5, 4.5, 1),
         'AI sight is blocked too')

    ---------------------------------------------------------------------
    t.describe('a hitscan stops at the segment')

    local dist, tx, ty, side, nx, ny = Collide.rayTile(w, 2.5, 4.5, 1, 0, 20, 1)
    t.ok(dist, 'the ray hits something')
    t.ok(math.abs(dist - 1.5) < 1e-6, ('and stops at the segment (%.3f)'):format(dist))
    t.ok(nx and nx < 0, 'the hit normal faces back toward the shooter')
    -- A ray that never reaches the segment passes (aimed away).
    t.eq(Collide.rayTile(w, 2.5, 4.5, -1, 0, 1, 1), nil,
         'a ray aimed away from it is unobstructed')

    ---------------------------------------------------------------------
    t.describe('the nearer of a tile wall and a segment wins')

    -- Shoot toward the east wall; the segment at x=4 is nearer, so it wins.
    local d2 = Collide.rayTile(w, 2.5, 4.5, 1, 0, 20, 1)
    t.ok(d2 < 5, 'the segment (1.5) beats the far tile wall')

    ---------------------------------------------------------------------
    t.describe('pathfinding refuses an edge a segment seals')

    local open = room()
    local before = Pathfind.find(open, 2.5, 4.5, 6.5, 4.5)
    t.ok(before, 'a path crosses the open room')
    open:addSegment(4, 0, 4, 8)     -- divide the room in two
    local after, why = Pathfind.find(open, 2.5, 4.5, 6.5, 4.5)
    t.ok(not after, 'a full-height segment divides the room; no path across')
    t.ok(why, 'and it says why')

    ---------------------------------------------------------------------
    t.describe('a partial segment forces a detour, not a failure')

    local gap = room()
    -- Wall x=4 from the top down to y=5, leaving the bottom rows open.
    gap:addSegment(4, 0, 4, 5)
    local path = Pathfind.find(gap, 2.5, 2.5, 6.5, 2.5)
    t.ok(path, 'a path still exists around the gap')
    t.ok(#path > 2, 'and it is a detour, not a straight line')
    -- The straight shortcut across the bar is refused by lineClear directly.
    t.ok(not Pathfind.lineClear(gap, 3, 3, 6, 3),
         'the smoother will not cut a shortcut through the bar')

    ---------------------------------------------------------------------
    t.describe('a world with no segments is unaffected (and pays nothing)')

    local plain = room()
    t.ok(Collide.lineOfSight(plain, 2.5, 4.5, 6.5, 4.5, 1), 'clear sight')
    t.ok(Pathfind.find(plain, 2.5, 4.5, 6.5, 4.5), 'clear path')
    t.ok(Pathfind.lineClear(plain, 2, 4, 6, 4), 'clear shortcut')
end
