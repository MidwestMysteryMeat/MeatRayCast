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

    HEADLESS: this module must not touch love.graphics or any love drawing API.
]]

local World = require('meatray.sim.world')

local Worldgen = {}

local floor, min, max = math.floor, math.min, math.max

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
-- Generation
---------------------------------------------------------------------------

-- opts:
--   width, height   grid size in tiles (default 48x48)
--   seed            any integer; the same seed always yields the same map
--   minRoom         smallest room side (default 4)
--   maxDepth        BSP recursion limit (default 5)
--   doorChance      0..1 chance a corridor mouth becomes a door (default 0.35)
--   wallTile        tile code for walls (default 1, selects a wall texture)
--   theme           opaque name handed to the render layer
--
-- Returns a World plus a table of the rooms it placed.
function Worldgen.generate(opts)
    opts = opts or {}

    local width   = opts.width or 48
    local height  = opts.height or 48
    local minRoom = opts.minRoom or 4
    local maxDepth = opts.maxDepth or 5
    local doorChance = opts.doorChance or 0.35
    local wallTile = opts.wallTile or 1

    local rng = Worldgen.rng(opts.seed or 1)

    -- Start solid; rooms and corridors carve into it.
    local grid = {}
    for y = 1, height do
        grid[y] = {}
        for x = 1, width do grid[y][x] = wallTile end
    end

    local leaves = {}
    splitNode({ x = 1, y = 1, w = width, h = height }, rng, minRoom + 2, 0, maxDepth, leaves)

    -- Carve one room per leaf, inset so rooms never touch the partition edge
    -- (that inset is what guarantees a wall between neighbouring rooms).
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

            for y = ry, ry + rh - 1 do
                for x = rx, rx + rw - 1 do
                    if x > 1 and y > 1 and x < width and y < height then
                        grid[y][x] = World.EMPTY
                    end
                end
            end

            rooms[#rooms + 1] = room
        end
    end

    -- Connect each room to the previous one with an L-shaped corridor. Simple,
    -- and it guarantees the whole map is reachable, which matters more for an
    -- engine demo than interesting topology.
    local doorSites = {}

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

    for i = 2, #rooms do
        local a, b = rooms[i - 1], rooms[i]
        if rng:int(0, 1) == 1 then
            carveH(a.cx, b.cx, a.cy)
            carveV(a.cy, b.cy, b.cx)
        else
            carveV(a.cy, b.cy, a.cx)
            carveH(a.cx, b.cx, b.cy)
        end
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
