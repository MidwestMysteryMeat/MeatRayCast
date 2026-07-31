--[[
    Grid A*: routes around walls, refuses impossible goals, simplifies.
]]

return function(t)
    local World = require('meatray.sim.world')
    local Worldgen = require('meatray.sim.worldgen')
    local Pathfind = require('meatray.sim.pathfind')

    local function openBox(w, h)
        return Worldgen.box(w, h)
    end

    ---------------------------------------------------------------------
    t.describe('straight path in an empty room')

    local room = openBox(12, 12)
    local path = Pathfind.find(room, 2.5, 2.5, 9.5, 2.5)
    t.ok(path ~= nil, 'finds a path across open floor')
    t.ok(#path >= 2, 'at least start and goal')
    t.near(path[1].x, 2.5, 0.01, 'starts at the start tile centre')
    t.near(path[#path].x, 9.5, 0.01, 'ends at the goal tile centre')
    t.ok(Pathfind.length(path) > 6, 'path length is roughly the distance')

    ---------------------------------------------------------------------
    t.describe('routes around a wall')

    -- Vertical wall with a gap at the bottom.
    local maze = openBox(15, 15)
    for y = 2, 12 do
        maze.grid[y][8] = 1
    end
    -- gap at y=13
    maze.grid[13][8] = 0

    local around = Pathfind.find(maze, 3.5, 5.5, 12.5, 5.5)
    t.ok(around ~= nil, 'finds a way around the wall')
    local crossedWall = false
    for i = 1, #around do
        if around[i].tx == 8 and around[i].ty >= 2 and around[i].ty <= 12 then
            crossedWall = true
        end
    end
    t.eq(crossedWall, false, 'path never steps into the solid wall column')

    local bottom = false
    for i = 1, #around do
        if around[i].ty >= 12 then bottom = true end
    end
    t.ok(bottom, 'path goes through the southern gap')

    ---------------------------------------------------------------------
    t.describe('no path when sealed')

    local sealed = openBox(10, 10)
    for y = 2, 9 do sealed.grid[y][5] = 1 end
    local none, why = Pathfind.find(sealed, 2.5, 5.5, 8.5, 5.5)
    t.eq(none, nil, 'no path through a solid divider')
    t.ok(why and why:find('no path'), 'reason says so', why)

    ---------------------------------------------------------------------
    t.describe('same tile and goal snap')

    local one = Pathfind.find(room, 4.2, 4.2, 4.8, 4.7)
    t.eq(#one, 1, 'start and goal in the same tile is a one-point path')

    -- Goal inside a wall: snap to a neighbour.
    room.grid[5][5] = 1
    local snap = Pathfind.find(room, 2.5, 2.5, 4.5, 4.5)
    t.ok(snap ~= nil, 'goal in a wall still produces a path nearby')
    local last = snap[#snap]
    t.eq(room:isSolid(last.tx, last.ty), false, 'final waypoint is walkable')

    ---------------------------------------------------------------------
    t.describe('simplify shortens without crossing walls')

    local long = Pathfind.find(maze, 3.5, 3.5, 12.5, 12.5)
    t.ok(long and #long > 3, 'long path has intermediate points')
    local short = Pathfind.simplify(maze, long)
    t.ok(#short <= #long, 'simplify never lengthens the waypoint list')
    t.ok(#short >= 2, 'and keeps endpoints')
    t.near(short[1].x, long[1].x, 1e-9, 'start preserved')
    t.near(short[#short].x, long[#long].x, 1e-9, 'goal preserved')

    ---------------------------------------------------------------------
    t.describe('nextWaypoint advances along the path')

    local p = {
        { x = 1.5, y = 1.5, tx = 2, ty = 2 },
        { x = 3.5, y = 1.5, tx = 4, ty = 2 },
        { x = 5.5, y = 1.5, tx = 6, ty = 2 },
    }
    local wx, wy, i = Pathfind.nextWaypoint(p, 1.5, 1.5, 0.4)
    t.eq(i, 2, 'at the first waypoint, next is the second')
    t.near(wx, 3.5, 1e-9)

    -- Walk the path using the returned index so intermediate corners stay done.
    local x, y, idx = 1.5, 1.5, 1
    for _ = 1, 10 do
        local nx, ny, ni = Pathfind.nextWaypoint(p, x, y, 0.4, idx)
        if not nx then break end
        x, y, idx = nx, ny, ni
    end
    t.near(x, 5.5, 1e-9, 'following nextWaypoint reaches the goal')
    local done = Pathfind.nextWaypoint(p, x, y, 0.4, idx)
    t.eq(done, nil, 'and then reports the path is finished')
end
