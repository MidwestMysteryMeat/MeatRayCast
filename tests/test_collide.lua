--[[
    Collision, wall sliding, and hitscan. The sliding cases are the ones worth
    having: "walks into a wall and stops" is easy, "walks diagonally into a wall
    and keeps the free axis" is what makes movement feel right and is where the
    maths is easy to get subtly wrong.
]]

return function(t)
    local World = require('meatray.sim.world')
    local Collide = require('meatray.sim.collide')
    local Entity = require('meatray.sim.entity')

    -- A 6x6 room with a solid border and one interior pillar at (3,3).
    local function room()
        local grid = {}
        for y = 1, 6 do
            grid[y] = {}
            for x = 1, 6 do
                local border = (x == 1 or y == 1 or x == 6 or y == 6)
                grid[y][x] = border and 1 or 0
            end
        end
        grid[3][3] = 1
        return World.new(grid)
    end

    t.describe('world basics')
    local w = room()
    t.eq(w.width, 6, 'width read from the grid')
    t.eq(w.height, 6, 'height read from the grid')
    t.ok(w:isSolid(1, 1), 'border is solid')
    t.ok(not w:isSolid(2, 2), 'interior is open')
    t.ok(w:isSolid(3, 3), 'pillar is solid')
    t.ok(w:isSolid(-5, -5), 'out of bounds reads as solid')

    t.describe('doors block only while shut')
    local dw = room()
    dw:addDoor(4, 2, false)
    t.ok(dw:isSolid(4, 2), 'closed door blocks')
    dw:setDoorOpen(4, 2, true)
    t.ok(not dw:isSolid(4, 2), 'open door does not block')
    dw:toggleDoor(4, 2)
    t.ok(dw:isSolid(4, 2), 'toggle shuts it again')
    t.ok(not dw:setDoorOpen(9, 9, true), 'opening a non-door reports failure')

    t.describe('door animation advances toward its target')
    dw:setDoorOpen(4, 2, true)
    dw:update(0.1, 4)
    local door = dw:doorAt(4, 2)
    t.ok(door.openness > 0 and door.openness < 1, 'openness is mid-travel')
    dw:update(10, 4)
    t.eq(dw:doorAt(4, 2).openness, 1, 'openness saturates at the target')

    -- Coordinate convention, since every case below depends on it: tile (N) spans
    -- world [N-1, N], so world (3.5, 3.5) sits in the middle of tile (4, 4) and
    -- the pillar at tile (3, 3) occupies world [2,3] x [2,3].
    t.describe('circle blocking')
    t.ok(not Collide.circleBlocked(w, 3.5, 3.5, 0.25), 'open tile centre is clear')
    t.ok(Collide.circleBlocked(w, 1.5, 1.5, 0.6), 'a big circle catches the border')
    t.ok(Collide.circleBlocked(w, 3.2, 3.2, 0.4), 'circle overlapping the pillar is blocked')

    t.describe('movement slides along walls')
    -- Pressed straight into the left wall: no movement at all.
    local e = Entity.new{ x = 1.3, y = 3.5 }
    e.radius = 0.25
    local moved, blocked = Collide.move(e, -0.5, 0, w)
    t.ok(blocked, 'moving into a wall reports blocked')
    t.eq(moved, 0, 'no distance travelled straight into a wall')
    t.eq(e.x, 1.3, 'position unchanged')

    -- Pressed diagonally into the same wall: x is refused, y still moves. This
    -- is the slide.
    local s = Entity.new{ x = 1.3, y = 3.5 }
    s.radius = 0.25
    local slid, hitWall = Collide.move(s, -0.5, 0.4, w)
    t.ok(hitWall, 'diagonal into a wall still reports a hit')
    t.ok(slid > 0, 'but distance was still covered')
    t.eq(s.x, 1.3, 'blocked axis did not move')
    t.ok(s.y > 3.5, 'free axis did move')

    -- Free movement is unaffected.
    local f = Entity.new{ x = 3.5, y = 3.5 }
    f.radius = 0.2
    local dist, hit = Collide.move(f, 0.1, 0.1, w)
    t.ok(not hit, 'open ground is not blocked')
    t.ok(dist > 0.14 and dist < 0.15, 'diagonal distance is the hypotenuse')

    t.describe('entity overlap')
    local a = Entity.new{ x = 2, y = 2 }; a.radius = 0.3
    local b = Entity.new{ x = 2.4, y = 2 }; b.radius = 0.3
    local c = Entity.new{ x = 4, y = 4 }; c.radius = 0.3
    t.ok(Collide.overlaps(a, b), 'touching circles overlap')
    t.ok(not Collide.overlaps(a, c), 'distant circles do not')
    t.ok(math.abs(Collide.distance(a, c) - math.sqrt(8)) < 1e-9, 'distance is euclidean')

    t.describe('range query returns nearest first')
    local near = Entity.new{ x = 2.2, y = 2 }
    local far = Entity.new{ x = 3.4, y = 2 }
    local dead = Entity.new{ x = 2.1, y = 2 }; dead.dead = true
    local found = Collide.query({ far, near, dead }, 2, 2, 2)
    t.eq(#found, 2, 'dead entities are skipped')
    t.eq(found[1], near, 'nearest comes first')
    t.eq(found[2], far, 'then the farther one')

    t.describe('ray against tiles')
    -- Fire east along world y = 2.5, which is tile row 3 — the row the pillar
    -- sits in. Starting at x = 1.5 the pillar's near face is at x = 2.
    local hitDist, tx = Collide.rayTile(w, 1.5, 2.5, 1, 0, 10)
    t.ok(hitDist ~= nil, 'ray eastward finds the pillar')
    t.eq(tx, 3, 'and reports its tile')
    t.ok(hitDist > 0.4 and hitDist < 0.6, 'at the expected distance')

    local miss = Collide.rayTile(w, 1.5, 2.5, 1, 0, 0.2)
    t.eq(miss, nil, 'a ray shorter than the gap hits nothing')

    -- A row with no pillar runs all the way to the far border instead.
    -- Border tile 6 spans world [5,6], so a ray from x = 2.5 enters it at x = 5.
    local farDist, farTx = Collide.rayTile(w, 2.5, 3.5, 1, 0, 10)
    t.eq(farTx, 6, 'a clear row reaches the border tile')
    t.ok(farDist > 2.4 and farDist < 2.6, 'at the border distance')

    t.describe('hitscan prefers whichever is nearer')
    local target = Entity.new{ x = 2.4, y = 3.5 }; target.radius = 0.3
    local shooter = Entity.new{ x = 2.0, y = 3.5 }

    local hit = Collide.hitscan(w, 2.0, 3.5, 1, 0, { target, shooter },
                                { ignore = shooter, maxDist = 10 })
    t.ok(hit ~= nil, 'something was hit')
    t.eq(hit.kind, 'entity', 'the entity in front of the wall wins')
    t.eq(hit.entity, target, 'and it is the right entity')

    -- An entity behind a wall must not be reachable. Fired along tile row 3 so
    -- the pillar (world [2,3] x [2,3]) stands between shooter and target.
    local behind = Entity.new{ x = 3.5, y = 2.5 }; behind.radius = 0.3
    local walled = Collide.hitscan(w, 1.5, 2.5, 1, 0, { behind }, { maxDist = 10 })
    t.ok(walled ~= nil, 'the shot hit something')
    t.eq(walled.kind, 'wall', 'the wall stops the shot')
    t.ok(walled.dist < 0.6, 'and it stopped at the pillar, not beyond it')
    t.ok(walled.hitx ~= nil and walled.hity ~= nil, 'wall hit reports impact point')
    t.near(walled.hitx, 2.0, 0.05, 'impact is on the near face of the pillar')
    t.eq(walled.nx, -1, 'normal faces back along the ray (west face)')
    t.eq(walled.ny, 0, 'no Y component on a vertical face')

    t.describe('line of sight respects walls and doors')
    t.ok(Collide.lineOfSight(w, 3.2, 3.5, 3.8, 3.5), 'clear across open floor')
    t.ok(not Collide.lineOfSight(w, 1.5, 2.5, 4.5, 2.5), 'blocked by the pillar')

    -- Door at tile (4,4) spans world [3,4] x [3,4], so sight along y = 3.5
    -- crosses it.
    local dw2 = room()
    dw2:addDoor(4, 4, false)
    t.ok(not Collide.lineOfSight(dw2, 2.5, 3.5, 4.5, 3.5), 'closed door blocks sight')
    dw2:setDoorOpen(4, 4, true)
    t.ok(Collide.lineOfSight(dw2, 2.5, 3.5, 4.5, 3.5), 'open door does not')
end
