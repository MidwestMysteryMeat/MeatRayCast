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

-- A search that expands this many nodes is almost certainly lost. A 64x64 open
-- field is ~4k cells; 16k leaves room for waste without letting a tick stall.
Pathfind.MAX_EXPANDED = 16384

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

local function key(tx, ty)
    return tx .. ',' .. ty
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

local function reconstruct(came, endKey, endTx, endTy)
    local path = {}
    local k, tx, ty = endKey, endTx, endTy
    while k do
        local cx, cy = center(tx, ty)
        path[#path + 1] = { x = cx, y = cy, tx = tx, ty = ty }
        local prev = came[k]
        if not prev then break end
        k, tx, ty = prev.k, prev.tx, prev.ty
    end
    -- cameFrom walks goal → start; reverse to start → goal.
    local i, j = 1, #path
    while i < j do
        path[i], path[j] = path[j], path[i]
        i, j = i + 1, j - 1
    end
    return path
end

--[[
    opts:
      diagonal   allow 8-connected moves (default false)
      maxExpand  override MAX_EXPANDED
      walkable   function(world, tx, ty) -> bool
      maxGoalSnap spiral radius when the goal tile is solid (default 8)
]]
function Pathfind.find(world, fromX, fromY, toX, toY, opts)
    opts = opts or {}
    if not world or not world.width then return nil, 'pathfind needs a world' end

    local sx, sy = tileOf(fromX, fromY)
    local gx, gy = tileOf(toX, toY)

    sx, sy = nearestWalkable(world, sx, sy, opts, opts.maxGoalSnap)
    gx, gy = nearestWalkable(world, gx, gy, opts, opts.maxGoalSnap)
    if not sx or not gx then return nil, 'no walkable tile near start or goal' end

    if sx == gx and sy == gy then
        local cx, cy = center(sx, sy)
        return { { x = cx, y = cy, tx = sx, ty = sy } }
    end

    local diagonal = opts.diagonal and true or false
    local DX, DY = diagonal and DX8 or DX4, diagonal and DY8 or DY4
    local nDir = diagonal and 8 or 4
    local maxExpand = opts.maxExpand or Pathfind.MAX_EXPANDED

    local startK = key(sx, sy)
    local goalK = key(gx, gy)

    local open = {}
    local gScore = { [startK] = 0 }
    local came = {}
    local closed = {}
    local inOpen = { [startK] = true }

    heapPush(open, {
        tx = sx, ty = sy, k = startK,
        g = 0, f = heuristic(sx, sy, gx, gy, diagonal),
    })

    local expanded = 0
    while #open > 0 do
        local cur = heapPop(open)
        inOpen[cur.k] = nil
        if closed[cur.k] then goto continue end
        closed[cur.k] = true
        expanded = expanded + 1
        if expanded > maxExpand then
            return nil, 'search exceeded expansion budget'
        end

        if cur.k == goalK then
            return reconstruct(came, cur.k, cur.tx, cur.ty)
        end

        for d = 1, nDir do
            local nx, ny = cur.tx + DX[d], cur.ty + DY[d]
            if walkable(world, nx, ny, opts) then
                -- Corner cut: diagonal through two solids is refused.
                if diagonal and DX[d] ~= 0 and DY[d] ~= 0 then
                    if not walkable(world, cur.tx + DX[d], cur.ty, opts)
                       or not walkable(world, cur.tx, cur.ty + DY[d], opts) then
                        goto nextDir
                    end
                end

                local nk = key(nx, ny)
                if not closed[nk] then
                    local step = (DX[d] ~= 0 and DY[d] ~= 0) and sqrt(2) or 1
                    local tentative = cur.g + step
                    if tentative < (gScore[nk] or huge) then
                        gScore[nk] = tentative
                        came[nk] = { k = cur.k, tx = cur.tx, ty = cur.ty }
                        local f = tentative + heuristic(nx, ny, gx, gy, diagonal)
                        heapPush(open, { tx = nx, ty = ny, k = nk, g = tentative, f = f })
                        inOpen[nk] = true
                    end
                end
            end
            ::nextDir::
        end
        ::continue::
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
-- at fromIndex (default 1). Returns x, y, index — or nil when the path is
-- finished. Pass the returned index back as fromIndex on the next tick so a
-- unit that has walked past intermediate corners does not re-seek them.
function Pathfind.nextWaypoint(path, x, y, radius, fromIndex)
    if not path or #path == 0 then return nil end
    radius = radius or 0.35
    local r2 = radius * radius
    local i = fromIndex or 1
    if i < 1 then i = 1 end
    while i <= #path do
        local dx, dy = path[i].x - x, path[i].y - y
        if dx * dx + dy * dy > r2 then
            return path[i].x, path[i].y, i
        end
        i = i + 1
    end
    return nil
end

return Pathfind
