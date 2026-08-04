--[[
    meatray.sim.pathfind — A* on the tile grid.

        local path = Pathfind.find(world, fromX, fromY, toX, toY)
        -- path is a list of { x = tileCenterX, y = tileCenterY }, or nil

    AI needs a route that respects walls and closed doors. The grid already
    answers that through world:isWalkable, so pathfinding is a graph search over
    tiles, not a second collision model. Host-only in multiplayer: a client that
    pathfinds its own enemies will disagree with the host about where they walk.

    Defaults:
      * 4-connected (cardinal). Diagonal is opt-in because a diagonal step can
        cut a corner between two solid tiles and look like clipping.
      * Goal tile is accepted even if the caller passed a point inside a solid
        (the search still needs a free cell next to it; see find).
      * MAX_EXPANDED caps work so a pathological map cannot hang a tick.

    HEADLESS: pure Lua, no love.
]]

local Pathfind = {}

local floor, abs, huge = math.floor, math.abs, math.huge
local sqrt = math.sqrt

-- Lazy require so pathfind stays usable if world constants are needed only for
-- stair edges (cross-storey search).
local WorldMod

local function worldMod()
    if not WorldMod then WorldMod = require('meatray.sim.world') end
    return WorldMod
end

-- A search that expands this many nodes is almost certainly lost. A 64x64 open
-- field is ~4k cells; 16k leaves room for waste without letting a tick stall.
-- Cross-storey multiplies the graph; the same budget still bounds a tick.
Pathfind.MAX_EXPANDED = 16384
-- Cost of taking stairs between adjacent storeys (one tile step, plus a little
-- so AI prefers same-floor routes when both exist).
Pathfind.STAIR_COST = 1.25

local DX4 = { 1, -1, 0, 0 }
local DY4 = { 0, 0, 1, -1 }
local DX8 = { 1, -1, 0, 0, 1, 1, -1, -1 }
local DY8 = { 0, 0, 1, -1, 1, -1, 1, -1 }

local function tileOf(x, y)
    return floor(x) + 1, floor(y) + 1
end

local function center(tx, ty)
    return tx - 0.5, ty - 0.5
end

-- E39: a segment (a diagonal bar, an angled wall) can seal the edge between two
-- tiles that are each walkable. The straight center-to-center move crossing a
-- segment means a walker cannot take that step, so pathing routes around the bar
-- the same way movement is stopped by it. A world with no segments pays one nil
-- test and nothing more.
local function segmentBlocksEdge(world, ax, ay, bx, by)
    local seg = world.segments
    if not seg or seg:isEmpty() then return false end
    local dx, dy = bx - ax, by - ay
    local d = sqrt(dx * dx + dy * dy)
    if d < 1e-9 then return false end
    return seg:nearest(ax, ay, dx / d, dy / d, d) ~= nil
end

local function key(tx, ty)
    return tx .. ',' .. ty
end

local function key3(tx, ty, storey)
    return storey .. ',' .. tx .. ',' .. ty
end

local function heuristic(ax, ay, bx, by, diagonal)
    local dx, dy = abs(ax - bx), abs(ay - by)
    if diagonal then
        -- Octile distance: matches 8-connected costs of 1 and sqrt(2).
        local dmin = dx < dy and dx or dy
        return (dx + dy) + (sqrt(2) - 2) * dmin
    end
    return dx + dy
end

local function heuristic3(ax, ay, as, bx, by, bs, diagonal)
    return heuristic(ax, ay, bx, by, diagonal)
           + abs((as or 1) - (bs or 1)) * Pathfind.STAIR_COST
end

-- Binary min-heap on f-score. Open set for A*.
local function heapPush(h, node)
    h[#h + 1] = node
    local i = #h
    while i > 1 do
        local p = floor(i / 2)
        if h[p].f <= h[i].f then break end
        h[p], h[i] = h[i], h[p]
        i = p
    end
end

local function heapPop(h)
    local n = #h
    if n == 0 then return nil end
    local top = h[1]
    local last = h[n]
    h[n] = nil
    if n == 1 then return top end
    h[1] = last
    local i = 1
    while true do
        local l, r = i * 2, i * 2 + 1
        local smallest = i
        if l <= #h and h[l].f < h[smallest].f then smallest = l end
        if r <= #h and h[r].f < h[smallest].f then smallest = r end
        if smallest == i then break end
        h[i], h[smallest] = h[smallest], h[i]
        i = smallest
    end
    return top
end

local function walkable(world, tx, ty, opts)
    if not world:inBounds(tx, ty) then return false end
    if opts and opts.walkable then
        return opts.walkable(world, tx, ty) and true or false
    end
    if world.isWalkable then
        return world:isWalkable(tx, ty, opts and opts.storey or 1)
    end
    return not world:isSolid(tx, ty)
end

-- Nearest walkable tile to (tx, ty), including itself. Spiral search so a goal
-- inside a wall still produces a path to the door beside it.
local function nearestWalkable(world, tx, ty, opts, maxR)
    maxR = maxR or 8
    if walkable(world, tx, ty, opts) then return tx, ty end
    for r = 1, maxR do
        for dy = -r, r do
            for dx = -r, r do
                if abs(dx) == r or abs(dy) == r then
                    local nx, ny = tx + dx, ty + dy
                    if walkable(world, nx, ny, opts) then return nx, ny end
                end
            end
        end
    end
    return nil
end

local function reconstruct(came, endKey, endTx, endTy, endStorey)
    local path = {}
    local k, tx, ty, storey = endKey, endTx, endTy, endStorey
    while k do
        local cx, cy = center(tx, ty)
        path[#path + 1] = { x = cx, y = cy, tx = tx, ty = ty, storey = storey or 1 }
        local prev = came[k]
        if not prev then break end
        k, tx, ty, storey = prev.k, prev.tx, prev.ty, prev.storey
    end
    -- cameFrom walks goal → start; reverse to start → goal.
    local i, j = 1, #path
    while i < j do
        path[i], path[j] = path[j], path[i]
        i, j = i + 1, j - 1
    end
    return path
end

local function layerOpts(opts, storey)
    if not opts then return { storey = storey or 1 } end
    -- Shallow copy so storey can change without mutating the caller's table.
    return {
        storey = storey or opts.storey or 1,
        walkable = opts.walkable,
        diagonal = opts.diagonal,
        maxExpand = opts.maxExpand,
        maxGoalSnap = opts.maxGoalSnap,
    }
end

-- Vertical neighbours via stairs on this tile. Up on STAIRS_UP, down on
-- STAIRS_DOWN, only when the destination cell is walkable on that storey.
local function stairNeighbours(world, tx, ty, storey, out)
    local W = worldMod()
    local tile = world.tileAt and world:tileAt(tx, ty, storey) or nil
    if not tile then return out end
    local nStoreys = world.storeyCount and world:storeyCount() or 1
    if tile == W.STAIRS_UP and storey < nStoreys then
        out[#out + 1] = { tx = tx, ty = ty, storey = storey + 1, cost = Pathfind.STAIR_COST }
    elseif tile == W.STAIRS_DOWN and storey > 1 then
        out[#out + 1] = { tx = tx, ty = ty, storey = storey - 1, cost = Pathfind.STAIR_COST }
    end
    return out
end

--[[
    opts:
      diagonal     allow 8-connected moves (default false)
      maxExpand    override MAX_EXPANDED
      walkable     function(world, tx, ty) -> bool  (single-storey only)
      maxGoalSnap  spiral radius when the goal tile is solid (default 8)
      storey       layer for both ends (default 1)
      fromStorey   start layer (overrides storey for the start)
      toStorey     goal layer (overrides storey for the goal)
      crossStorey  allow stairs between layers (default true when from≠to)
]]
function Pathfind.find(world, fromX, fromY, toX, toY, opts)
    opts = opts or {}
    if not world or not world.width then return nil, 'pathfind needs a world' end

    local fromStorey = opts.fromStorey or opts.storey or 1
    local toStorey = opts.toStorey or opts.storey or 1
    local nStoreys = world.storeyCount and world:storeyCount() or 1
    if fromStorey < 1 then fromStorey = 1 end
    if toStorey < 1 then toStorey = 1 end
    if fromStorey > nStoreys then fromStorey = nStoreys end
    if toStorey > nStoreys then toStorey = nStoreys end

    local cross = opts.crossStorey
    if cross == nil then cross = (fromStorey ~= toStorey) and nStoreys > 1 end
    cross = cross and nStoreys > 1

    -- Without cross-storey edges, a different goal floor is unreachable.
    if not cross and fromStorey ~= toStorey then
        return nil, 'no path'
    end

    local fromOpts = layerOpts(opts, fromStorey)
    local toOpts = layerOpts(opts, toStorey)

    local sx, sy = tileOf(fromX, fromY)
    local gx, gy = tileOf(toX, toY)

    sx, sy = nearestWalkable(world, sx, sy, fromOpts, opts.maxGoalSnap)
    gx, gy = nearestWalkable(world, gx, gy, toOpts, opts.maxGoalSnap)
    if not sx or not gx then return nil, 'no walkable tile near start or goal' end

    if sx == gx and sy == gy and fromStorey == toStorey then
        local cx, cy = center(sx, sy)
        return { { x = cx, y = cy, tx = sx, ty = sy, storey = fromStorey } }
    end

    local diagonal = opts.diagonal and true or false
    local DX, DY = diagonal and DX8 or DX4, diagonal and DY8 or DY4
    local nDir = diagonal and 8 or 4
    local maxExpand = opts.maxExpand or Pathfind.MAX_EXPANDED

    -- Single-storey: original key space (tx,ty) for less work and stable tests.
    if not cross then
        local plane = fromOpts
        local startK = key(sx, sy)
        local goalK = key(gx, gy)

        local open = {}
        local gScore = { [startK] = 0 }
        local came = {}
        local closed = {}

        heapPush(open, {
            tx = sx, ty = sy, k = startK, storey = fromStorey,
            g = 0, f = heuristic(sx, sy, gx, gy, diagonal),
        })

        local expanded = 0
        while #open > 0 do
            local cur = heapPop(open)
            if closed[cur.k] then goto continue end
            closed[cur.k] = true
            expanded = expanded + 1
            if expanded > maxExpand then
                return nil, 'search exceeded expansion budget'
            end

            if cur.k == goalK then
                return reconstruct(came, cur.k, cur.tx, cur.ty, fromStorey)
            end

            for d = 1, nDir do
                local nx, ny = cur.tx + DX[d], cur.ty + DY[d]
                if walkable(world, nx, ny, plane) then
                    if diagonal and DX[d] ~= 0 and DY[d] ~= 0 then
                        if not walkable(world, cur.tx + DX[d], cur.ty, plane)
                           or not walkable(world, cur.tx, cur.ty + DY[d], plane) then
                            goto nextDir
                        end
                    end

                    -- E39: refuse a step a segment walls off.
                    local acx, acy = center(cur.tx, cur.ty)
                    local bcx, bcy = center(nx, ny)
                    if segmentBlocksEdge(world, acx, acy, bcx, bcy) then
                        goto nextDir
                    end

                    local nk = key(nx, ny)
                    if not closed[nk] then
                        local step = (DX[d] ~= 0 and DY[d] ~= 0) and sqrt(2) or 1
                        local tentative = cur.g + step
                        if tentative < (gScore[nk] or huge) then
                            gScore[nk] = tentative
                            came[nk] = { k = cur.k, tx = cur.tx, ty = cur.ty, storey = fromStorey }
                            local f = tentative + heuristic(nx, ny, gx, gy, diagonal)
                            heapPush(open, {
                                tx = nx, ty = ny, k = nk, storey = fromStorey,
                                g = tentative, f = f,
                            })
                        end
                    end
                end
                ::nextDir::
            end
            ::continue::
        end

        return nil, 'no path'
    end

    -- Cross-storey A*: nodes are (tx, ty, storey); stairs are vertical edges.
    local startK = key3(sx, sy, fromStorey)
    local goalK = key3(gx, gy, toStorey)
    local open = {}
    local gScore = { [startK] = 0 }
    local came = {}
    local closed = {}
    local stairBuf = {}

    heapPush(open, {
        tx = sx, ty = sy, storey = fromStorey, k = startK,
        g = 0, f = heuristic3(sx, sy, fromStorey, gx, gy, toStorey, diagonal),
    })

    local expanded = 0
    while #open > 0 do
        local cur = heapPop(open)
        if closed[cur.k] then goto cont3 end
        closed[cur.k] = true
        expanded = expanded + 1
        if expanded > maxExpand then
            return nil, 'search exceeded expansion budget'
        end

        if cur.k == goalK then
            return reconstruct(came, cur.k, cur.tx, cur.ty, cur.storey)
        end

        local plane = layerOpts(opts, cur.storey)

        for d = 1, nDir do
            local nx, ny = cur.tx + DX[d], cur.ty + DY[d]
            if walkable(world, nx, ny, plane) then
                if diagonal and DX[d] ~= 0 and DY[d] ~= 0 then
                    if not walkable(world, cur.tx + DX[d], cur.ty, plane)
                       or not walkable(world, cur.tx, cur.ty + DY[d], plane) then
                        goto next3
                    end
                end
                local nk = key3(nx, ny, cur.storey)
                if not closed[nk] then
                    local step = (DX[d] ~= 0 and DY[d] ~= 0) and sqrt(2) or 1
                    local tentative = cur.g + step
                    if tentative < (gScore[nk] or huge) then
                        gScore[nk] = tentative
                        came[nk] = {
                            k = cur.k, tx = cur.tx, ty = cur.ty, storey = cur.storey,
                        }
                        local f = tentative + heuristic3(nx, ny, cur.storey, gx, gy, toStorey, diagonal)
                        heapPush(open, {
                            tx = nx, ty = ny, storey = cur.storey, k = nk,
                            g = tentative, f = f,
                        })
                    end
                end
            end
            ::next3::
        end

        -- Stairs at the current cell.
        for i = #stairBuf, 1, -1 do stairBuf[i] = nil end
        stairNeighbours(world, cur.tx, cur.ty, cur.storey, stairBuf)
        for i = 1, #stairBuf do
            local n = stairBuf[i]
            local nOpts = layerOpts(opts, n.storey)
            if walkable(world, n.tx, n.ty, nOpts) then
                local nk = key3(n.tx, n.ty, n.storey)
                if not closed[nk] then
                    local tentative = cur.g + (n.cost or Pathfind.STAIR_COST)
                    if tentative < (gScore[nk] or huge) then
                        gScore[nk] = tentative
                        came[nk] = {
                            k = cur.k, tx = cur.tx, ty = cur.ty, storey = cur.storey,
                        }
                        local f = tentative + heuristic3(n.tx, n.ty, n.storey, gx, gy, toStorey, diagonal)
                        heapPush(open, {
                            tx = n.tx, ty = n.ty, storey = n.storey, k = nk,
                            g = tentative, f = f,
                        })
                    end
                end
            end
        end
        ::cont3::
    end

    return nil, 'no path'
end

-- Length of a path in world units (straight segments between waypoints).
function Pathfind.length(path)
    if not path or #path < 2 then return 0 end
    local sum = 0
    for i = 2, #path do
        local dx = path[i].x - path[i - 1].x
        local dy = path[i].y - path[i - 1].y
        sum = sum + sqrt(dx * dx + dy * dy)
    end
    return sum
end

-- Drops intermediate waypoints that have line-of-sight on the grid (cardinal
-- supercover). Shortens AI steers without re-running A*.
function Pathfind.simplify(world, path, opts)
    if not path or #path <= 2 then return path end
    opts = opts or {}
    local out = { path[1] }
    local i = 1
    while i < #path do
        local best = i + 1
        for j = #path, i + 2, -1 do
            if Pathfind.lineClear(world, path[i].tx, path[i].ty,
                                  path[j].tx, path[j].ty, opts) then
                best = j
                break
            end
        end
        out[#out + 1] = path[best]
        i = best
    end
    return out
end

-- Bresenham-style line: every tile on the segment must be walkable.
function Pathfind.lineClear(world, x0, y0, x1, y1, opts)
    opts = opts or {}
    -- E39: a straight shortcut may not cut through a segment wall either, or
    -- path smoothing would send a unit diagonally through the diagonal it is
    -- supposed to route around. Tile coords in, tile centres to the ray test.
    if segmentBlocksEdge(world, x0 - 0.5, y0 - 0.5, x1 - 0.5, y1 - 0.5) then
        return false
    end
    local dx = abs(x1 - x0)
    local dy = -abs(y1 - y0)
    local sx = x0 < x1 and 1 or -1
    local sy = y0 < y1 and 1 or -1
    local err = dx + dy
    local x, y = x0, y0
    while true do
        if not walkable(world, x, y, opts) then return false end
        if x == x1 and y == y1 then return true end
        local e2 = 2 * err
        if e2 >= dy then
            err = err + dy
            x = x + sx
        end
        if e2 <= dx then
            err = err + dx
            y = y + sy
        end
    end
end

-- Next steer point. Skips waypoints already within radius of (x,y), starting
-- at fromIndex (default 1). Returns x, y, index [, storey] — or nil when the
-- path is finished. Pass the returned index back as fromIndex on the next tick
-- so a unit that has walked past intermediate corners does not re-seek them.
--
-- Optional `storey`: a waypoint on another floor is never skipped for free —
-- the caller must change entity.storey first (stairs step), even if xy matches.
function Pathfind.nextWaypoint(path, x, y, radius, fromIndex, storey)
    if not path or #path == 0 then return nil end
    radius = radius or 0.35
    local r2 = radius * radius
    local i = fromIndex or 1
    if i < 1 then i = 1 end
    while i <= #path do
        local wp = path[i]
        local dx, dy = wp.x - x, wp.y - y
        local wpS = wp.storey
        local sameFloor = storey == nil or wpS == nil or wpS == storey
        if (dx * dx + dy * dy > r2) or not sameFloor then
            return wp.x, wp.y, i, wpS
        end
        i = i + 1
    end
    return nil
end

---------------------------------------------------------------------------
-- Distance field (BFS): walking distance from one point to every tile
---------------------------------------------------------------------------

-- Floods outward from (fromX, fromY) and returns:
--
--   field:at(x, y)      walking distance in tiles, or nil off-field
--   field.farthestX/Y   centre of the reachable tile farthest away
--   field.farthestDist  its distance
--
-- The honest metric for "how far is the agent from the goal" on any map
-- with interior walls: euclidean distance is deceptive there (crowd goals,
-- RL rewards and evolution fitness all hit this), and one flood answers it
-- for every tile at once. Doors count as walkable by default — the same
-- promise botWalkable makes — override with opts.walkable. Single-storey.
function Pathfind.distanceField(world, fromX, fromY, opts)
    opts = opts or {}
    local storey = opts.storey or 1
    local walkable = opts.walkable or function(w, tx, ty)
        if w.doorAt and w:doorAt(tx, ty, storey) then return true end
        return not w:isSolid(tx, ty, storey)
    end

    local sx, sy = floor(fromX) + 1, floor(fromY) + 1
    local dist = {}
    local field = {
        dist = dist,
        farthestX = sx - 0.5, farthestY = sy - 0.5, farthestDist = 0,
    }
    function field:at(x, y)
        return self.dist[(floor(y) + 1) * 4096 + (floor(x) + 1)]
    end

    if not walkable(world, sx, sy) then return field end
    dist[sy * 4096 + sx] = 0

    local queue, head = { { sx, sy } }, 1
    local DIRS = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }
    while head <= #queue do
        local cx, cy = queue[head][1], queue[head][2]
        head = head + 1
        local d = dist[cy * 4096 + cx]
        if d > field.farthestDist then
            field.farthestDist = d
            field.farthestX, field.farthestY = cx - 0.5, cy - 0.5
        end
        for _, dir in ipairs(DIRS) do
            local nx, ny = cx + dir[1], cy + dir[2]
            local key = ny * 4096 + nx
            if not dist[key]
               and nx >= 1 and ny >= 1 and nx <= world.width and ny <= world.height
               and walkable(world, nx, ny) then
                dist[key] = d + 1
                queue[#queue + 1] = { nx, ny }
            end
        end
    end
    return field
end

return Pathfind
