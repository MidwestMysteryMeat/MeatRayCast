--[[
    Billboard projection and angle-bucket selection.

    The bucket cases matter because getting them wrong is a bug you see rather
    than crash on: an enemy charging you while showing its back. The occlusion
    cases matter because they are the whole reason render() returns a z-buffer.
]]

return function(t)
    local B = require('meatray.sim.billboard')
    local pi = math.pi

    t.describe('angle normalisation')
    t.near(B.normalize(0), 0, 1e-9, 'zero stays zero')
    t.near(B.normalize(-pi / 2), 3 * pi / 2, 1e-9, 'negatives wrap forward')
    t.near(B.normalize(3 * B.TWO_PI + pi), pi, 1e-9, 'multiple turns collapse')

    t.describe('a single-angle sprite always shows one bucket')
    for _, facing in ipairs({ 0, pi / 3, pi, -pi / 2 }) do
        t.eq(B.angleBucket(facing, 0, 1), 0, 'angles=1 is always bucket 0')
    end

    t.describe('directional buckets')
    -- The second argument is the bearing FROM the viewer TO the entity. So with
    -- it at 0, the viewer stands west of the entity looking east at it. An
    -- entity facing west (pi) is therefore looking straight back at the viewer.
    t.eq(B.angleBucket(pi, 0, 8), 0, 'facing the viewer is bucket 0')

    -- Facing east with the viewer to the west means facing away.
    t.eq(B.angleBucket(0, 0, 8), 4, 'facing away is the opposite bucket')

    -- Moving the viewer instead of the entity must give the same answer.
    t.eq(B.angleBucket(0, pi, 8), 0, 'facing east with the viewer east is bucket 0')

    -- Quarter turns land on the quarter buckets.
    t.eq(B.angleBucket(pi / 2, 0, 8), 6, 'perpendicular one way')
    t.eq(B.angleBucket(-pi / 2, 0, 8), 2, 'perpendicular the other way')

    -- Buckets are centred, so a small wobble around dead-on stays on bucket 0
    -- instead of flickering between 0 and 7.
    local eighth = B.TWO_PI / 8
    t.eq(B.angleBucket(pi + eighth * 0.4, 0, 8), 0, 'a small positive wobble holds')
    t.eq(B.angleBucket(pi - eighth * 0.4, 0, 8), 0, 'a small negative wobble holds')

    -- Just past the bucket boundary it must actually move on, or the buckets
    -- would be meaningless.
    t.ok(B.angleBucket(pi + eighth * 0.6, 0, 8) ~= 0, 'past the boundary it changes')

    -- Every bucket must be reachable and in range for any bucket count.
    t.describe('bucket counts other than 8 work')
    for _, n in ipairs({ 2, 4, 6, 16 }) do
        local seen = {}
        for step = 0, n * 4 do
            local a = step * (B.TWO_PI / (n * 4))
            local bucket = B.angleBucket(a, 0, n)
            t.ok(bucket >= 0 and bucket < n, ('bucket in range for angles=' .. n))
            seen[bucket] = true
        end
        local count = 0
        for _ in pairs(seen) do count = count + 1 end
        t.eq(count, n, ('all %d buckets reachable'):format(n))
    end

    t.describe('bearing')
    t.near(B.bearing(0, 0, 1, 0), 0, 1e-9, 'east is zero')
    t.near(B.bearing(0, 0, 0, 1), pi / 2, 1e-9, 'south is a quarter turn')

    t.describe('animation frames come from a clock, not from state')
    t.eq(B.animFrame(0, 4, 8), 0, 'time zero is frame zero')
    t.eq(B.animFrame(0.125, 4, 8), 1, 'one eighth of a second at 8fps is frame 1')
    t.eq(B.animFrame(0.5, 4, 8), 0, 'four frames at 8fps wraps in half a second')
    t.eq(B.animFrame(3.7, 1, 8), 0, 'a single-frame sprite never advances')
    t.eq(B.animFrame(3.7, nil, 8), 0, 'no frame count is treated as static')

    t.describe('projection into view space')
    -- Camera at (0,0) facing east, standard plane for a 66-degree FOV.
    local camX, camY = 0, 0
    local dirX, dirY = 1, 0
    local planeX, planeY = 0, 0.66

    -- Directly ahead: no lateral offset, depth equal to the distance.
    local tx, ty = B.project(4, 0, camX, camY, dirX, dirY, planeX, planeY)
    t.ok(tx ~= nil, 'a sprite ahead projects')
    t.near(tx, 0, 1e-9, 'dead ahead has no lateral offset')
    t.near(ty, 4, 1e-9, 'depth equals the distance')

    -- Behind the camera must be rejected outright, not drawn inside-out.
    local bx = B.project(-4, 0, camX, camY, dirX, dirY, planeX, planeY)
    t.eq(bx, nil, 'a sprite behind the camera is rejected')

    -- On the camera is also rejected: it would divide by ~zero.
    local ox = B.project(0, 0, camX, camY, dirX, dirY, planeX, planeY)
    t.eq(ox, nil, 'a sprite on the camera is rejected')

    -- Off to one side gets a lateral offset with the expected sign.
    local rx = B.project(4, 2, camX, camY, dirX, dirY, planeX, planeY)
    t.ok(rx > 0, 'a sprite to one side offsets that way')
    local lx = B.project(4, -2, camX, camY, dirX, dirY, planeX, planeY)
    t.ok(lx < 0, 'and the other side offsets the other way')

    t.describe('screen placement')
    local rect = B.screenRect(0, 4, 800, 600, { scale = 1 })
    t.ok(rect ~= nil, 'a projected sprite gets a rect')
    t.eq(rect.centerX, 400, 'dead ahead is centred horizontally')
    t.eq(rect.w, rect.h, 'sprites are square')
    t.eq(rect.depth, 4, 'the rect carries its depth for sorting')

    -- Nearer is bigger. This is the check that catches an inverted projection.
    local near = B.screenRect(0, 2, 800, 600, {})
    local far = B.screenRect(0, 8, 800, 600, {})
    t.ok(near.w > far.w, 'a nearer sprite is larger')
    t.near(near.w / far.w, 4, 0.05, 'and scales inversely with depth')

    -- Anchoring is the difference between standing on the floor and hovering.
    -- It only shows on a sprite shorter than a full wall: at scale 1 a sprite is
    -- exactly wall height, so both anchors put it in the same place.
    local feet = B.screenRect(0, 4, 800, 600, { anchor = 'feet', scale = 0.5 })
    local centre = B.screenRect(0, 4, 800, 600, { anchor = 'center', scale = 0.5 })
    t.ok(feet.y > centre.y, 'a short feet-anchored sprite sits lower than a centred one')

    local fullFeet = B.screenRect(0, 4, 800, 600, { anchor = 'feet', scale = 1 })
    local fullCentre = B.screenRect(0, 4, 800, 600, { anchor = 'center', scale = 1 })
    t.eq(fullFeet.y, fullCentre.y, 'a full-height sprite anchors identically either way')

    -- Something vanishingly far away should not produce a zero-size rect.
    local tiny = B.screenRect(0, 100000, 800, 600, {})
    t.eq(tiny, nil, 'a sub-pixel sprite is dropped rather than drawn empty')

    t.describe('depth sorting paints far to near')
    local list = {
        { name = 'near', depth = 1 },
        { name = 'far', depth = 9 },
        { name = 'mid', depth = 5 },
    }
    B.sortByDepth(list)
    t.eq(list[1].name, 'far', 'farthest is drawn first')
    t.eq(list[3].name, 'near', 'nearest is drawn last')

    t.describe('z-buffer occlusion')
    local zbuf = { [10] = 5.0, [11] = 5.0, [12] = 0.5 }
    t.ok(B.columnVisible(10, 3.0, zbuf, 800), 'a sprite nearer than the wall shows')
    t.ok(not B.columnVisible(10, 7.0, zbuf, 800), 'a sprite behind the wall is hidden')
    t.ok(not B.columnVisible(12, 3.0, zbuf, 800), 'a close wall hides a farther sprite')
    t.ok(B.columnVisible(50, 3.0, zbuf, 800), 'no wall recorded means nothing occludes')
    t.ok(not B.columnVisible(-1, 1.0, zbuf, 800), 'off the left edge is not drawn')
    t.ok(not B.columnVisible(800, 1.0, zbuf, 800), 'off the right edge is not drawn')
end
