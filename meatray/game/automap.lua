--[[
    meatray.game.automap — the map you remember, not the map that exists (F2).

    The minimap has always been live: it draws the whole plan, explored or
    not, because until now nothing remembered where anyone had been. This
    module is that memory. It marks what a player has seen, hands the minimap
    the exact `fog` table it already accepts, and rides a save as one string
    per storey.

        local am = Automap.new{ radius = 4 }

        -- whenever the player stands somewhere (cheap: no-op until they
        -- cross into a new tile):
        am:visit(world, px, py, storey)

        -- drawing:
        minimap:draw(px, py, angle, { fog = am:visited(storey), ... })

        -- the end-of-level stat, and the save:
        am:coverage(world, storey)     -- 0..1 of reachable-ish tiles seen
        am:capture()  /  am:restore(captured)

    What "seen" means: a tile within `radius` of the player is revealed if
    the straight line from the player to it crosses no solid tile first. The
    first solid tile ON the line is itself revealed — the wall you are
    looking at is exactly the thing you know about — but nothing beyond it,
    so a room on the far side of that wall stays dark until you walk in.
    That is the Doom automap contract, and it is why this cannot be a plain
    radius stamp: a stamp through walls leaks the level layout, and the whole
    point of remembering is that you had to be there.

    Visits are line walks, not raycaster output, for two reasons: they run on
    a dedicated server (HEADLESS: pure Lua), and they are deliberately a
    little generous — peripheral vision at a step you walked past feels
    right; pixel-exact reveal reads as stingy.

    HEADLESS: pure Lua.
]]

local Automap = {}
local AutomapMT = {}
AutomapMT.__index = AutomapMT

local floor, sqrt = math.floor, math.sqrt

---------------------------------------------------------------------------
-- Construction
---------------------------------------------------------------------------

-- opts:
--   radius   reveal distance in tiles (default 4)
function Automap.new(opts)
    opts = opts or {}
    return setmetatable({
        radius = math.max(1, tonumber(opts.radius) or 4),
        storeys = {},        -- [storey] = { set = {key=true}, count = 0 }
        lastTile = {},       -- [storey] = 'tx,ty' the last visit ran from
    }, AutomapMT)
end

local function layer(self, storey)
    storey = storey or 1
    local L = self.storeys[storey]
    if not L then
        L = { set = {}, count = 0 }
        self.storeys[storey] = L
    end
    return L
end

local function mark(L, tx, ty)
    local key = tx .. ',' .. ty
    if not L.set[key] then
        L.set[key] = true
        L.count = L.count + 1
        return true
    end
    return false
end

---------------------------------------------------------------------------
-- Seeing
---------------------------------------------------------------------------

-- Is the straight line from (px,py) to the centre of (tx,ty) clear of solid
-- tiles before it arrives? Walked in quarter-tile steps: coarse enough to be
-- cheap, fine enough that a one-tile wall cannot be stepped over.
local function lineClear(world, px, py, tx, ty, storey)
    local cx, cy = tx - 0.5, ty - 0.5
    local dx, dy = cx - px, cy - py
    local dist = sqrt(dx * dx + dy * dy)
    if dist < 0.001 then return true end
    local steps = floor(dist * 4) + 1
    for i = 1, steps - 1 do
        local t = i / steps
        local wx, wy = floor(px + dx * t) + 1, floor(py + dy * t) + 1
        if (wx ~= tx or wy ~= ty) and world:isSolid(wx, wy, storey) then
            return false
        end
    end
    return true
end

--[[
    Marks everything visible from (px,py). Returns how many tiles became
    newly known — usually because the player crossed into a new tile;
    standing still (or moving within one) is a table lookup and out.

    `force` reruns the reveal even from an unchanged tile. Callers use it
    when the world changed shape underfoot — a door opened, a push-wall
    slid — since a new opening can reveal tiles the last pass could not see.
]]
function AutomapMT:visit(world, px, py, storey, force)
    if not world or not px or not py then return 0 end
    storey = storey or 1

    local ptx, pty = floor(px) + 1, floor(py) + 1
    local here = ptx .. ',' .. pty
    if not force and self.lastTile[storey] == here then return 0 end
    self.lastTile[storey] = here

    local L = layer(self, storey)
    local r = self.radius
    local revealed = 0

    for ty = math.max(1, pty - r), math.min(world.height, pty + r) do
        for tx = math.max(1, ptx - r), math.min(world.width, ptx + r) do
            local ddx, ddy = tx - ptx, ty - pty
            if ddx * ddx + ddy * ddy <= r * r
               and not L.set[tx .. ',' .. ty]
               and lineClear(world, px, py, tx, ty, storey) then
                if mark(L, tx, ty) then revealed = revealed + 1 end
            end
        end
    end

    return revealed
end

-- The fog table the minimap takes verbatim: visited['tx,ty'] = true.
function AutomapMT:visited(storey)
    return layer(self, storey).set
end

function AutomapMT:isVisited(tx, ty, storey)
    return layer(self, storey).set[tx .. ',' .. ty] == true
end

function AutomapMT:seenCount(storey)
    return layer(self, storey).count
end

-- Seen tiles over non-solid tiles: how much of the walkable level the player
-- has actually laid eyes on. Walls the player saw are in the seen set but
-- not the denominator, so a fully-walked level reads a little over rather
-- than never reaching 100 — clamped, because '100%' is the promise players
-- actually collect.
function AutomapMT:coverage(world, storey)
    if not world then return 0 end
    storey = storey or 1
    local open = 0
    for ty = 1, world.height do
        for tx = 1, world.width do
            if not world:isSolid(tx, ty, storey) then open = open + 1 end
        end
    end
    if open == 0 then return 0 end
    local c = self:seenCount(storey) / open
    return c > 1 and 1 or c
end

function AutomapMT:reset()
    self.storeys = {}
    self.lastTile = {}
    return self
end

---------------------------------------------------------------------------
-- Persistence: one compact string per storey, so this drops into the save
-- system's `meta` (or any other string-shaped pocket) without a schema.
---------------------------------------------------------------------------

function AutomapMT:capture()
    local out = { radius = self.radius, storeys = {} }
    for storey, L in pairs(self.storeys) do
        local keys = {}
        for key in pairs(L.set) do keys[#keys + 1] = key end
        table.sort(keys)     -- stable output; a save that diffs is debuggable
        out.storeys[storey] = table.concat(keys, ';')
    end
    return out
end

function AutomapMT:restore(captured)
    self:reset()
    if type(captured) ~= 'table' then return self end
    if tonumber(captured.radius) then
        self.radius = math.max(1, tonumber(captured.radius))
    end
    for storey, packed in pairs(captured.storeys or {}) do
        local L = layer(self, tonumber(storey) or storey)
        for key in tostring(packed):gmatch('[^;]+') do
            if key:match('^%-?%d+,%-?%d+$') and not L.set[key] then
                L.set[key] = true
                L.count = L.count + 1
            end
        end
    end
    return self
end

return Automap
