--[[
    meatray.sim.worldgen — optional BSP dungeon generator.

    Optional is the important word: the engine renders any tile grid you hand it,
    so a game with hand-authored maps never loads this file. It is here because
    "no assets required" is only true if you can also produce a level without
    one.

    The generator carries its own random number generator rather than using
    math.random. Two reasons, and the second is the load-bearing one: math.random
    differs between Lua 5.1, 5.3 and LuaJIT, and a networked host and client that
    generate a world from the same seed and get different geometry have no way to
    recover. A generator this simple must be bit-identical everywhere, so it uses
    an explicit LCG with defined 32-bit wraparound.

    Layouts:
      'bsp'  (default) binary space partition + sequential corridors. Seed-stable
             with every map ever generated before layout became an option.
      'mst'  scatter rooms, Delaunay triangulation of centres, Kruskal MST
             corridors, optional extra edges for loops (layout = 'mst').

    Pure helpers Worldgen.delaunay / Worldgen.mst are public so games and tests
    can reuse the graph step without carving tiles.

    HEADLESS: this module must not touch love.graphics or any love drawing API.
]]

local World = require('meatray.sim.world')

local Worldgen = {}

local floor, min, max = math.floor, math.min, math.max
local abs, sqrt = math.abs, math.sqrt

---------------------------------------------------------------------------
-- Deterministic RNG (Numerical Recipes LCG constants)
---------------------------------------------------------------------------

local Rng = {}
Rng.__index = Rng

function Worldgen.rng(seed)
    return setmetatable({ state = (seed or 1) % 4294967296 }, Rng)
end

function Rng:next()
    self.state = (1664525 * self.state + 1013904223) % 4294967296
    return self.state
end

-- Uniform float in [0, 1).
function Rng:float()
    return self:next() / 4294967296
end

-- Uniform integer in [lo, hi].
function Rng:int(lo, hi)
    if hi <= lo then return lo end
    return lo + floor(self:float() * (hi - lo + 1))
end

---------------------------------------------------------------------------
-- BSP partitioning
---------------------------------------------------------------------------

local function splitNode(node, rng, minSize, depth, maxDepth, out)
    local w, h = node.w, node.h

    local canSplit = depth < maxDepth
        and (w >= minSize * 2 + 1 or h >= minSize * 2 + 1)

    if not canSplit then
        out[#out + 1] = node
        return
    end

    -- Split the longer axis so rooms stay roughly square.
    local horizontal
    if w > h * 1.25 then
        horizontal = false
    elseif h > w * 1.25 then
        horizontal = true
    else
        horizontal = rng:int(0, 1) == 1
    end

    if horizontal and h < minSize * 2 + 1 then horizontal = false end
    if not horizontal and w < minSize * 2 + 1 then horizontal = true end

    if horizontal then
        local cut = rng:int(minSize, h - minSize - 1)
        splitNode({ x = node.x, y = node.y,       w = w, h = cut },
                  rng, minSize, depth + 1, maxDepth, out)
        splitNode({ x = node.x, y = node.y + cut, w = w, h = h - cut },
                  rng, minSize, depth + 1, maxDepth, out)
    else
        local cut = rng:int(minSize, w - minSize - 1)
        splitNode({ x = node.x,       y = node.y, w = cut,     h = h },
                  rng, minSize, depth + 1, maxDepth, out)
        splitNode({ x = node.x + cut, y = node.y, w = w - cut, h = h },
                  rng, minSize, depth + 1, maxDepth, out)
    end
end

---------------------------------------------------------------------------
-- Delaunay triangulation (Bowyer–Watson) and minimum spanning tree (Kruskal)
--
-- Published algorithms, implemented here from scratch so the generator stays
-- Apache-2.0 clean. Used by layout = 'mst' to connect scattered rooms with a
-- short tree of corridors, then optionally re-add a few triangulation edges
-- for loops. Pure functions so tests can pin them without a full map.
---------------------------------------------------------------------------

-- Circumcircle of triangle (ax,ay)-(bx,by)-(cx,cy). Returns cx, cy, r2 or nil
-- if the points are collinear / degenerate.
local function circumcircle(ax, ay, bx, by, cx, cy)
    local d = 2 * (ax * (by - cy) + bx * (cy - ay) + cx * (ay - by))
    if d > -1e-12 and d < 1e-12 then return nil end
    local ax2ay2 = ax * ax + ay * ay
    local bx2by2 = bx * bx + by * by
    local cx2cy2 = cx * cx + cy * cy
    local ux = (ax2ay2 * (by - cy) + bx2by2 * (cy - ay) + cx2cy2 * (ay - by)) / d
    local uy = (ax2ay2 * (cx - bx) + bx2by2 * (ax - cx) + cx2cy2 * (bx - ax)) / d
    local dx, dy = ax - ux, ay - uy
    return ux, uy, dx * dx + dy * dy
end

local function pointInCircum(px, py, tri)
    local dx, dy = px - tri.cx, py - tri.cy
    return dx * dx + dy * dy <= tri.r2 + 1e-9
end

--[[
    points: { {x=, y=}, ... }  (at least 3 for a non-empty triangulation)
    Returns:
      triangles = { { a, b, c }, ... }  1-based point indices, CCW-ish
      edges     = { { i, j, w }, ... }  unique undirected edges, w = distance
]]
function Worldgen.delaunay(points)
    local n = #(points or {})
    if n < 2 then return {}, {} end
    if n == 2 then
        local dx = points[1].x - points[2].x
        local dy = points[1].y - points[2].y
        return {}, { { 1, 2, sqrt(dx * dx + dy * dy) } }
    end

    -- Bounding box → super-triangle large enough to contain every point.
    local minX, minY = points[1].x, points[1].y
    local maxX, maxY = minX, minY
    for i = 2, n do
        local p = points[i]
        if p.x < minX then minX = p.x end
        if p.y < minY then minY = p.y end
        if p.x > maxX then maxX = p.x end
        if p.y > maxY then maxY = p.y end
    end
    local dx = maxX - minX
    local dy = maxY - minY
    local dmax = (dx > dy and dx or dy)
    if dmax < 1 then dmax = 1 end
    local midx = (minX + maxX) * 0.5
    local midy = (minY + maxY) * 0.5

    -- Super-triangle vertices live past the real point list.
    local s1, s2, s3 = n + 1, n + 2, n + 3
    local all = {}
    for i = 1, n do all[i] = points[i] end
    all[s1] = { x = midx - 20 * dmax, y = midy - dmax }
    all[s2] = { x = midx,             y = midy + 20 * dmax }
    all[s3] = { x = midx + 20 * dmax, y = midy - dmax }

    local function makeTri(a, b, c)
        local ux, uy, r2 = circumcircle(all[a].x, all[a].y, all[b].x, all[b].y,
                                        all[c].x, all[c].y)
        if not ux then return nil end
        return { a = a, b = b, c = c, cx = ux, cy = uy, r2 = r2 }
    end

    local tris = { makeTri(s1, s2, s3) }

    for i = 1, n do
        local p = all[i]
        local bad = {}
        for t = 1, #tris do
            if pointInCircum(p.x, p.y, tris[t]) then
                bad[#bad + 1] = t
            end
        end

        -- Polygon edges of the cavity: edges that appear once among bad tris.
        local edgeCount = {}
        local function touchEdge(u, v)
            if u > v then u, v = v, u end
            local k = u .. ',' .. v
            edgeCount[k] = (edgeCount[k] or 0) + 1
        end
        for b = 1, #bad do
            local tri = tris[bad[b]]
            touchEdge(tri.a, tri.b)
            touchEdge(tri.b, tri.c)
            touchEdge(tri.c, tri.a)
        end

        -- Remove bad triangles (high index first so removals stay valid).
        table.sort(bad, function(a, b) return a > b end)
        for b = 1, #bad do table.remove(tris, bad[b]) end

        for k, count in pairs(edgeCount) do
            if count == 1 then
                local u, v = k:match('^(%d+),(%d+)$')
                u, v = tonumber(u), tonumber(v)
                local nt = makeTri(u, v, i)
                if nt then tris[#tris + 1] = nt end
            end
        end
    end

    -- Drop anything that still touches the super-triangle.
    local outTris = {}
    local edgeMap = {}
    for t = 1, #tris do
        local tri = tris[t]
        if tri.a <= n and tri.b <= n and tri.c <= n then
            outTris[#outTris + 1] = { tri.a, tri.b, tri.c }
            local function addEdge(u, v)
                if u > v then u, v = v, u end
                local k = u .. ',' .. v
                if not edgeMap[k] then
                    local dxv = all[u].x - all[v].x
                    local dyv = all[u].y - all[v].y
                    edgeMap[k] = { i = u, j = v, w = sqrt(dxv * dxv + dyv * dyv) }
                end
            end
            addEdge(tri.a, tri.b)
            addEdge(tri.b, tri.c)
            addEdge(tri.c, tri.a)
        end
    end

    local edges = {}
    for _, e in pairs(edgeMap) do
        edges[#edges + 1] = e
    end
    -- Stable order: by weight, then endpoints. Deterministic for the same points.
    table.sort(edges, function(a, b)
        if a.w ~= b.w then return a.w < b.w end
        if a.i ~= b.i then return a.i < b.i end
        return a.j < b.j
    end)

    return outTris, edges
end

-- Kruskal MST. edges: { {i=, j=, w=}, ... }, nVerts: number of vertices 1..n.
-- Returns the tree edges (subset), sorted like the input after weight sort.
function Worldgen.mst(nVerts, edges)
    nVerts = nVerts or 0
    if nVerts <= 1 or not edges or #edges == 0 then return {} end

    local parent, rank = {}, {}
    for i = 1, nVerts do parent[i] = i; rank[i] = 0 end

    local function find(x)
        while parent[x] ~= x do
            parent[x] = parent[parent[x]]
            x = parent[x]
        end
        return x
    end

    local function unite(a, b)
        a, b = find(a), find(b)
        if a == b then return false end
        if rank[a] < rank[b] then a, b = b, a end
        parent[b] = a
        if rank[a] == rank[b] then rank[a] = rank[a] + 1 end
        return true
    end

    local sorted = {}
    for i = 1, #edges do sorted[i] = edges[i] end
    table.sort(sorted, function(a, b)
        local aw, bw = a.w or 0, b.w or 0
        if aw ~= bw then return aw < bw end
        local ai, bi = a.i or a[1], b.i or b[1]
        if ai ~= bi then return ai < bi end
        return (a.j or a[2]) < (b.j or b[2])
    end)

    local tree = {}
    for i = 1, #sorted do
        local e = sorted[i]
        local u, v = e.i or e[1], e.j or e[2]
        if unite(u, v) then
            tree[#tree + 1] = e
            if #tree >= nVerts - 1 then break end
        end
    end
    return tree
end

---------------------------------------------------------------------------
-- Generation
---------------------------------------------------------------------------

local function newSolidGrid(width, height, wallTile)
    local grid = {}
    for y = 1, height do
        grid[y] = {}
        for x = 1, width do grid[y][x] = wallTile end
    end
    return grid
end

local function carveRoom(grid, room, width, height)
    for y = room.y, room.y + room.h - 1 do
        for x = room.x, room.x + room.w - 1 do
            if x > 1 and y > 1 and x < width and y < height then
                grid[y][x] = World.EMPTY
            end
        end
    end
end

-- L-shaped corridor; records tiles that were solid before carving (door sites).
local function carveCorridor(grid, ax, ay, bx, by, width, height, doorSites, preferH)
    local function carveH(x1, x2, y)
        for x = min(x1, x2), max(x1, x2) do
            if x > 1 and x < width and y > 1 and y < height then
                if grid[y][x] ~= World.EMPTY then
                    grid[y][x] = World.EMPTY
                    doorSites[#doorSites + 1] = { x = x, y = y }
                end
            end
        end
    end
    local function carveV(y1, y2, x)
        for y = min(y1, y2), max(y1, y2) do
            if x > 1 and x < width and y > 1 and y < height then
                if grid[y][x] ~= World.EMPTY then
                    grid[y][x] = World.EMPTY
                    doorSites[#doorSites + 1] = { x = x, y = y }
                end
            end
        end
    end
    if preferH then
        carveH(ax, bx, ay)
        carveV(ay, by, bx)
    else
        carveV(ay, by, ax)
        carveH(ax, bx, by)
    end
end

local function placeDoors(world, doorSites, rng, doorChance)
    local candidates = {}
    for i = 1, #doorSites do
        local site = doorSites[i]
        if rng:float() < doorChance then
            local x, y = site.x, site.y
            local solidH = world:isSolid(x - 1, y) and world:isSolid(x + 1, y)
            local solidV = world:isSolid(x, y - 1) and world:isSolid(x, y + 1)
            if solidH ~= solidV then
                candidates[#candidates + 1] = { x = x, y = y }
            end
        end
    end

    local placed = {}
    for i = 1, #candidates do
        local x, y = candidates[i].x, candidates[i].y
        local neighbourIsDoor =
            placed[(x - 1) .. ',' .. y] or placed[(x + 1) .. ',' .. y] or
            placed[x .. ',' .. (y - 1)] or placed[x .. ',' .. (y + 1)] or
            placed[x .. ',' .. y]

        if not neighbourIsDoor then
            world:addDoor(x, y, false)
            placed[x .. ',' .. y] = true
        end
    end
end

local function decorateElevation(world, rooms, rng)
    if #rooms <= 1 then return end
    for i = 2, #rooms do
        local room = rooms[i]
        local roll = rng:float()
        if roll < 0.22 then
            local cz = 0.45 + rng:float() * 0.2
            for y = room.y, room.y + room.h - 1 do
                for x = room.x, room.x + room.w - 1 do
                    if world:inBounds(x, y) and not world:isSolid(x, y) then
                        world:setCeilingHeight(x, y, cz)
                    end
                end
            end
        elseif roll < 0.40 then
            local inset = 1
            local z = 0.2 + rng:float() * 0.25
            for y = room.y + inset, room.y + room.h - 1 - inset do
                for x = room.x + inset, room.x + room.w - 1 - inset do
                    if world:inBounds(x, y) and not world:isSolid(x, y) then
                        world:setFloorHeight(x, y, z, { defer = true })
                    end
                end
            end
        end
    end
    world:rebuildFloorRisers()
end

local function roomsOverlap(a, b, gap)
    gap = gap or 1
    return not (a.x + a.w + gap <= b.x
             or b.x + b.w + gap <= a.x
             or a.y + a.h + gap <= b.y
             or b.y + b.h + gap <= a.y)
end

-- Scatter rooms with rejection sampling + light separation passes.
local function placeScatteredRooms(rng, width, height, opts)
    local minRoom = opts.minRoom or 4
    local maxRoom = opts.maxRoom or min(10, floor(min(width, height) / 4))
    if maxRoom < minRoom then maxRoom = minRoom end
    local count = opts.roomCount or max(4, floor((width * height) / 180))
    local maxCount = opts.maxRooms or 24
    if count > maxCount then count = maxCount end
    local gap = opts.roomGap or 2
    local margin = 2

    local rooms = {}
    local attempts = count * 40
    while #rooms < count and attempts > 0 do
        attempts = attempts - 1
        local rw = rng:int(minRoom, maxRoom)
        local rh = rng:int(minRoom, maxRoom)
        local rx = rng:int(margin, max(margin, width - rw - margin + 1))
        local ry = rng:int(margin, max(margin, height - rh - margin + 1))
        local room = {
            x = rx, y = ry, w = rw, h = rh,
            cx = floor(rx + rw / 2),
            cy = floor(ry + rh / 2),
        }
        local ok = true
        for i = 1, #rooms do
            if roomsOverlap(room, rooms[i], gap) then ok = false; break end
        end
        if ok then rooms[#rooms + 1] = room end
    end

    -- Separation steering: push overlapping pairs apart (rare after rejection).
    for _ = 1, 8 do
        local moved = false
        for i = 1, #rooms do
            for j = i + 1, #rooms do
                local a, b = rooms[i], rooms[j]
                if roomsOverlap(a, b, gap) then
                    local dx = a.cx - b.cx
                    local dy = a.cy - b.cy
                    if dx == 0 and dy == 0 then dx = 1 end
                    if abs(dx) >= abs(dy) then
                        if dx > 0 then a.x = a.x + 1; b.x = b.x - 1
                        else a.x = a.x - 1; b.x = b.x + 1 end
                    else
                        if dy > 0 then a.y = a.y + 1; b.y = b.y - 1
                        else a.y = a.y - 1; b.y = b.y + 1 end
                    end
                    a.x = max(margin, min(a.x, width - a.w - margin + 1))
                    b.x = max(margin, min(b.x, width - b.w - margin + 1))
                    a.y = max(margin, min(a.y, height - a.h - margin + 1))
                    b.y = max(margin, min(b.y, height - b.h - margin + 1))
                    a.cx = floor(a.x + a.w / 2); a.cy = floor(a.y + a.h / 2)
                    b.cx = floor(b.x + b.w / 2); b.cy = floor(b.y + b.h / 2)
                    moved = true
                end
            end
        end
        if not moved then break end
    end

    return rooms
end

local function generateBsp(opts, rng, width, height, wallTile)
    local minRoom = opts.minRoom or 4
    local maxDepth = opts.maxDepth or 5
    local grid = newSolidGrid(width, height, wallTile)

    local leaves = {}
    splitNode({ x = 1, y = 1, w = width, h = height }, rng, minRoom + 2, 0, maxDepth, leaves)

    local rooms = {}
    for i = 1, #leaves do
        local leaf = leaves[i]
        local rw = max(minRoom, leaf.w - 3)
        local rh = max(minRoom, leaf.h - 3)
        rw = min(rw, leaf.w - 2)
        rh = min(rh, leaf.h - 2)

        if rw >= minRoom and rh >= minRoom then
            local rx = leaf.x + rng:int(1, max(1, leaf.w - rw - 1))
            local ry = leaf.y + rng:int(1, max(1, leaf.h - rh - 1))

            local room = {
                x = rx, y = ry, w = rw, h = rh,
                cx = floor(rx + rw / 2),
                cy = floor(ry + rh / 2),
            }
            carveRoom(grid, room, width, height)
            rooms[#rooms + 1] = room
        end
    end

    -- Sequential L-corridors: guarantees connectivity; topology is a path.
    local doorSites = {}
    for i = 2, #rooms do
        local a, b = rooms[i - 1], rooms[i]
        carveCorridor(grid, a.cx, a.cy, b.cx, b.cy, width, height, doorSites,
                      rng:int(0, 1) == 1)
    end

    return grid, rooms, doorSites
end

local function generateMst(opts, rng, width, height, wallTile)
    local grid = newSolidGrid(width, height, wallTile)
    local rooms = placeScatteredRooms(rng, width, height, opts)

    if #rooms == 0 then
        -- Fallback: one centre room so the map is never all wall.
        local rw = min(6, width - 4)
        local rh = min(6, height - 4)
        local room = {
            x = floor((width - rw) / 2) + 1,
            y = floor((height - rh) / 2) + 1,
            w = rw, h = rh,
        }
        room.cx = floor(room.x + room.w / 2)
        room.cy = floor(room.y + room.h / 2)
        rooms[1] = room
    end

    for i = 1, #rooms do
        carveRoom(grid, rooms[i], width, height)
    end

    local doorSites = {}
    if #rooms >= 2 then
        local pts = {}
        for i = 1, #rooms do
            pts[i] = { x = rooms[i].cx, y = rooms[i].cy }
        end
        local _, delEdges = Worldgen.delaunay(pts)
        -- If Delaunay failed to produce enough edges (degenerate), fall back to
        -- a complete graph of room pairs so MST still connects everything.
        local edges = delEdges
        if #edges < #rooms - 1 then
            edges = {}
            for i = 1, #rooms do
                for j = i + 1, #rooms do
                    local dx = rooms[i].cx - rooms[j].cx
                    local dy = rooms[i].cy - rooms[j].cy
                    edges[#edges + 1] = {
                        i = i, j = j, w = sqrt(dx * dx + dy * dy),
                    }
                end
            end
        end

        local tree = Worldgen.mst(#rooms, edges)
        local inTree = {}
        for i = 1, #tree do
            local e = tree[i]
            local u, v = e.i, e.j
            if u > v then u, v = v, u end
            inTree[u .. ',' .. v] = true
            local a, b = rooms[e.i], rooms[e.j]
            carveCorridor(grid, a.cx, a.cy, b.cx, b.cy, width, height, doorSites,
                          rng:int(0, 1) == 1)
        end

        -- Extra loops: re-add some Delaunay edges that are not in the MST.
        local loopChance = opts.loopChance
        if loopChance == nil then loopChance = 0.15 end
        for i = 1, #edges do
            local e = edges[i]
            local u, v = e.i, e.j
            if u > v then u, v = v, u end
            if not inTree[u .. ',' .. v] and rng:float() < loopChance then
                local a, b = rooms[e.i], rooms[e.j]
                carveCorridor(grid, a.cx, a.cy, b.cx, b.cy, width, height, doorSites,
                              rng:int(0, 1) == 1)
            end
        end
    end

    return grid, rooms, doorSites
end

-- opts:
--   width, height   grid size in tiles (default 48x48)
--   seed            any integer; the same seed always yields the same map
--   layout          'bsp' (default) or 'mst' (Delaunay + MST corridors)
--   minRoom         smallest room side (default 4)
--   maxRoom         largest room side for mst layout (default ~map/4)
--   maxDepth        BSP recursion limit (default 5)
--   roomCount       target room count for mst layout
--   loopChance      mst: chance to re-add a non-tree Delaunay edge (default 0.15)
--   doorChance      0..1 chance a corridor mouth becomes a door (default 0.35)
--   wallTile        tile code for walls (default 1, selects a wall texture)
--   theme           opaque name handed to the render layer
--   elevation       if not false, decorate some rooms with raised floors /
--                   low ceilings (default true). Uses the same RNG stream after
--                   doors so tile geometry stays identical to older seeds.
--
-- Returns a World plus a table of the rooms it placed.
-- Default layout remains BSP so existing seeds stay bit-identical.
function Worldgen.generate(opts)
    opts = opts or {}

    local width   = opts.width or 48
    local height  = opts.height or 48
    local doorChance = opts.doorChance or 0.35
    local wallTile = opts.wallTile or 1
    local wantElev = opts.elevation ~= false
    local layout = opts.layout or 'bsp'

    local rng = Worldgen.rng(opts.seed or 1)

    local grid, rooms, doorSites
    if layout == 'mst' or layout == 'delaunay' or layout == 'rooms' then
        grid, rooms, doorSites = generateMst(opts, rng, width, height, wallTile)
    else
        grid, rooms, doorSites = generateBsp(opts, rng, width, height, wallTile)
    end

    local world = World.new(grid, {
        theme = opts.theme,
        spawn = rooms[1] and { x = rooms[1].cx + 0.5, y = rooms[1].cy + 0.5 } or nil,
    })

    -- Doors go on corridor tiles walled on exactly one axis, which is what a
    -- doorway looks like: walled on both would be a sealed hole, walled on
    -- neither would be a door standing in the middle of a room.
    --
    -- Candidates are judged against the door-free geometry and only then placed.
    -- Judging as we go would be order-dependent, because a closed door is itself
    -- solid: place one and the next candidate beside it suddenly looks like it
    -- has a wall it does not have. Adjacent doors are rejected for the same
    -- reason — two in a row read as a wall rather than a doorway.
    placeDoors(world, doorSites, rng, doorChance)

    -- Optional elevation: variety without changing the solid/open layout that
    -- older seeds and determinism tests pin. Spawn room stays classic height.
    if wantElev then
        decorateElevation(world, rooms, rng)
    end

    return world, rooms
end

-- A bare walled box, for tests and for games that only want the renderer.
function Worldgen.box(width, height, wallTile)
    local grid = {}
    for y = 1, height do
        grid[y] = {}
        for x = 1, width do
            local border = (x == 1 or y == 1 or x == width or y == height)
            grid[y][x] = border and (wallTile or 1) or World.EMPTY
        end
    end
    return World.new(grid, { spawn = { x = width / 2, y = height / 2 } })
end

return Worldgen
