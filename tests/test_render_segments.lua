--[[
    Thin walls, from the renderer's side: the two things that are wrong in a way
    a screenshot does not name.

    The picture itself is asserted in selftest.lua, which renders a diagonal into
    a canvas and compares it against the same wall built out of tiles. What that
    cannot state cleanly is *why* either of these is right, and both are one line
    of arithmetic sitting a long way from where the mistake shows up:

      1. The ray direction the wall loop casts with is `dir + plane * cameraX`
         and is deliberately NOT normalised. Its component along `dir` is exactly
         1, so a distance measured in units of that vector already IS the
         perpendicular distance -- which is the whole reason the tile path has no
         cosine in it either. Normalise it first and only the segments fisheye,
         which reads as a straight diagonal bowing as the camera turns rather
         than as a distance bug.

      2. `u` from meatray.sim.segments is 0..1 along a segment of ANY length, so
         using it as a texture coordinate stretches one texture across the whole
         wall. A six-tile diagonal gets texels six times too wide, standing next
         to a tile wall that does not.

    Neither needs a GPU to check, so neither is checked with one.
]]

return function(t)
    local Raycaster = require('meatray.render.raycaster')
    local Segments = require('meatray.sim.segments')
    local World = require('meatray.sim.world')
    local Textures = require('meatray.render.textures')

    local SIZE = Textures.SIZE
    local wallX = Raycaster.segmentWallX

    ---------------------------------------------------------------------
    t.describe('the texture coordinate is per tile of wall, not per segment')

    t.near(wallX(0, 6), 0, 1e-12, 'the start of a segment is the start of a texture')
    t.near(wallX(0.25, 6), 0.5, 1e-12,
           'a quarter along a six-tile wall is halfway across the fourth texture')
    t.near(wallX(0.5, 6), 0, 1e-12, 'and halfway along is a texture boundary')

    -- The failure this exists to prevent, stated as a difference: using `u`
    -- directly would have answered 0.25 and 0.5 to those two.
    t.ok(math.abs(wallX(0.25, 6) - 0.25) > 0.2,
         'which is not what using u directly would have given')

    -- A one-tile segment IS a tile face, and must be textured like one.
    for _, u in ipairs({ 0, 0.125, 0.5, 0.75, 0.9999 }) do
        t.near(wallX(u, 1), u, 1e-12,
               ('a one-tile segment textures exactly like a tile face at u=%.4f'):format(u))
    end

    -- Every value it can return is a texture coordinate, including on lengths
    -- that are not whole tiles: a diagonal is almost never one.
    for _, length in ipairs({ 0.5, 1, 4.5, 6, 8.4853 }) do
        local outside = 0
        for i = 0, 200 do
            local v = wallX(i / 200, length)
            if v < 0 or v >= 1 then outside = outside + 1 end
        end
        t.eq(outside, 0, ('a length of %.4f stays inside one texture'):format(length))
    end

    -- The claim itself: a segment N tiles long shows N repeats of the texture.
    -- Counted as sawtooth resets rather than asserted at sample points, so it is
    -- the whole sweep being checked and not three lucky values of u.
    local function periods(length)
        local resets, previous = 0, wallX(0, length)
        for i = 1, 20000 do
            local v = wallX(i / 20000, length)
            if v < previous then resets = resets + 1 end
            previous = v
        end
        return resets
    end

    t.eq(periods(6), 6, 'a six-tile segment repeats its texture six times')
    t.eq(periods(1), 1, 'a one-tile segment once')
    t.eq(periods(4.5), 4, 'and a four-and-a-half-tile one four times and a half')

    -- Texel size, which is what "does not stretch" actually means. One texel of
    -- a tile wall covers 1/SIZE of a world tile. Advancing along a segment by
    -- the u that spans one texel must move the coordinate by exactly the same
    -- amount, whatever the segment's length.
    for _, length in ipairs({ 1, 3, 6, 8.4853 }) do
        local du = 1 / (length * SIZE)
        local worst = 0
        for i = 0, 100 do
            local u = i / 100 * (1 - du)
            local step = wallX(u + du, length) - wallX(u, length)
            if step < 0 then step = step + 1 end        -- across a texture seam
            worst = math.max(worst, math.abs(step - 1 / SIZE))
        end
        t.ok(worst < 1e-9,
             ('a texel on a %.4f-tile segment is the same size as a tile wall texel (%.3e off)')
                 :format(length, worst))
    end

    ---------------------------------------------------------------------
    t.describe('the unnormalised ray direction already carries the perpendicular distance')

    -- The reason, first, because everything below follows from it. The camera
    -- plane is perpendicular to the facing, so the component of
    -- `dir + plane * cameraX` along `dir` is 1 for every column on the screen.
    local worstDot = 0
    for _, angle in ipairs({ 0, 0.6, 2.5, -1.2, math.pi }) do
        local view = Raycaster.view(3.5, 4.5, angle)
        for x = 0, 64 do
            local cameraX = 2 * x / 64 - 1
            local rayDirX = view.dirX + view.planeX * cameraX
            local rayDirY = view.dirY + view.planeY * cameraX
            local along = rayDirX * view.dirX + rayDirY * view.dirY
            worstDot = math.max(worstDot, math.abs(along - 1))
        end
    end
    t.ok(worstDot < 1e-12,
         ('every column of every camera projects onto the facing as exactly 1 (%.3e off)')
             :format(worstDot))

    -- And the consequence, measured the way a viewer would see it: a flat wall
    -- square-on to the camera is the same distance away in every column. If it
    -- is not, the wall bows -- and it bows only on segments, because the tile
    -- path takes its distance from the DDA and never touches this.
    local function flatWallSpread(x0, y0, angle, distance, normalise)
        local view = Raycaster.view(x0, y0, angle)

        -- A wall plane at `distance` ahead, perpendicular to the facing, long
        -- enough to cover the whole field of view.
        local cx, cy = x0 + view.dirX * distance, y0 + view.dirY * distance
        local set = Segments.new()
        set:add(cx - view.planeX * 8, cy - view.planeY * 8,
                cx + view.planeX * 8, cy + view.planeY * 8)

        local lo, hi = math.huge, 0
        for x = 0, 96 do
            local cameraX = 2 * x / 96 - 1
            local rayDirX = view.dirX + view.planeX * cameraX
            local rayDirY = view.dirY + view.planeY * cameraX
            if normalise then
                local len = math.sqrt(rayDirX * rayDirX + rayDirY * rayDirY)
                rayDirX, rayDirY = rayDirX / len, rayDirY / len
            end
            local hit = set:nearest(x0, y0, rayDirX, rayDirY, 64)
            if hit then
                lo = math.min(lo, hit)
                hi = math.max(hi, hit)
            end
        end
        return lo, hi
    end

    for _, camera in ipairs({ { 2.5, 3.5, 0, 4 }, { 6.5, 6.5, 0.7, 3 },
                              { 9.25, 2.75, -2.1, 5.5 } }) do
        local lo, hi = flatWallSpread(camera[1], camera[2], camera[3], camera[4], false)
        t.near(lo, camera[4], 1e-9, ('the near edge of a flat wall reads %.4f tiles'):format(lo))
        t.ok(hi - lo < 1e-9,
             ('and every column of it agrees, so it does not bow (%.3e spread)')
                 :format(hi - lo))
    end

    -- The control: normalising the direction first is the mistake, and this is
    -- how big it is. Without this the assertion above is equally consistent with
    -- a measurement that cannot see the difference.
    local lo, hi = flatWallSpread(2.5, 3.5, 0, 4, true)
    t.ok(hi > lo * 1.15,
         ('while normalising the ray first bows the same wall by %.0f%% across the screen')
             :format((hi / lo - 1) * 100))

    ---------------------------------------------------------------------
    t.describe('a world with no thin walls carries nothing to test')

    local grid = {}
    for y = 1, 8 do
        grid[y] = {}
        for x = 1, 8 do grid[y][x] = (x == 1 or y == 1 or x == 8 or y == 8) and 1 or 0 end
    end

    local world = World.new(grid)
    t.eq(world.segments, nil, 'a fresh world has no segment table at all')
    t.eq(world:segmentCount(), 0, 'and counts none')

    world:addSegment(2, 2, 5, 5)
    t.ok(world.segments ~= nil, 'adding one creates the set on demand')
    t.eq(world:segmentCount(), 1, 'holding it')

    -- The renderer memoises which segments a tile holds rather than rebuilding
    -- the set's string key once per tile per column. Nothing has rendered here,
    -- so this only checks the report exists and answers; selftest.lua asserts
    -- the number stops moving on the second frame, which is the real claim.
    t.eq(type(Raycaster.segmentTileCache()), 'number',
         'the renderer reports how many tiles its segment lookup has memoised')
end
