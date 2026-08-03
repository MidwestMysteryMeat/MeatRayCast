--[[
    meatray.sim.prefab — reusable room stamps (B11).

    A level is built from the same shapes over and over: a 3x3 pillar room, a
    doorway, a cross corridor, a guard post. Redrawing each tile every time is
    the work an editor exists to remove. A prefab is a rectangle of a map
    captured as data — tiles, doors, entity markers, floor heights, relative
    to its own corner — that pastes back onto any map at any offset, rotated
    to any of four facings.

        local Prefab = require('meatray.sim.prefab')

        local stamp = Prefab.capture(map, 4, 4, 6, 6)   -- a 3x3 region
        Prefab.paste(map, stamp, 10, 10, { rotate = 1 })  -- rotated 90deg

        Prefab.KIT.pillar_room                          -- a built-in stamp
        Prefab.serialize(stamp) / Prefab.deserialize(s) -- save a custom one

    Rotation is the whole reason this is not a memcpy: a door on the north
    wall of a room must become a door on the east wall when the room is turned
    a quarter, an entity's facing must turn with it, and a WxH stamp becomes
    HxW. Getting that right once, here, is what lets the editor offer "rotate"
    as a single key rather than four hand-drawn variants of every room.

    Coordinates: a stamp stores tiles at 0-based (col,row) from its top-left;
    map paste coordinates are 1-based tiles, matching every other editor call.
    Entity/door positions inside a stamp are tile-relative and become world
    positions on paste.

    HEADLESS: pure Lua.
]]

local Map = require('meatray.sim.map')

local Prefab = {}

local floor = math.floor
local HALF_PI = math.pi / 2

---------------------------------------------------------------------------
-- Capture
---------------------------------------------------------------------------

-- Captures the inclusive tile rect (tx1,ty1)..(tx2,ty2) of `map` as a stamp.
-- Corner order is normalised, so a drag in any direction is a valid capture.
function Prefab.capture(map, tx1, ty1, tx2, ty2)
    if tx2 < tx1 then tx1, tx2 = tx2, tx1 end
    if ty2 < ty1 then ty1, ty2 = ty2, ty1 end
    tx1 = math.max(1, tx1); ty1 = math.max(1, ty1)
    tx2 = math.min(map.width, tx2); ty2 = math.min(map.height, ty2)

    local w, h = tx2 - tx1 + 1, ty2 - ty1 + 1
    local stamp = {
        w = w, h = h,
        tiles = {},           -- [row 0..h-1][col 0..w-1] = tile value
        doors = {},           -- { {x=,y=,open=}, ... } 0-based within stamp
        entities = {},        -- { {kind=,x=,y=,angle=}, ... } tile-relative
        floorHeights = {},    -- { {x=,y=,z=}, ... }
        wallHeights = {},
    }

    for row = 0, h - 1 do
        stamp.tiles[row] = {}
        for col = 0, w - 1 do
            local mrow = map.tiles[ty1 + row]
            stamp.tiles[row][col] = (mrow and mrow[tx1 + col]) or 0
        end
    end

    for _, d in ipairs(map.doors or {}) do
        if d.x >= tx1 and d.x <= tx2 and d.y >= ty1 and d.y <= ty2 then
            stamp.doors[#stamp.doors + 1] =
                { x = d.x - tx1, y = d.y - ty1, open = d.open }
        end
    end

    for _, e in ipairs(map.entities or {}) do
        local etx, ety = floor(e.x) + 1, floor(e.y) + 1
        if etx >= tx1 and etx <= tx2 and ety >= ty1 and ety <= ty2 then
            -- Store the fractional offset within the tile so a re-paste lands
            -- the marker exactly where it was, not snapped to a corner.
            stamp.entities[#stamp.entities + 1] = {
                kind = e.kind,
                x = e.x - (tx1 - 1), y = e.y - (ty1 - 1),
                angle = e.angle or 0,
            }
        end
    end

    for _, fh in ipairs(map.floorHeights or {}) do
        if fh.x >= tx1 and fh.x <= tx2 and fh.y >= ty1 and fh.y <= ty2 then
            stamp.floorHeights[#stamp.floorHeights + 1] =
                { x = fh.x - tx1, y = fh.y - ty1, z = fh.z }
        end
    end
    for _, wh in ipairs(map.wallHeights or {}) do
        if wh.x >= tx1 and wh.x <= tx2 and wh.y >= ty1 and wh.y <= ty2 then
            stamp.wallHeights[#stamp.wallHeights + 1] =
                { x = wh.x - tx1, y = wh.y - ty1, h = wh.h }
        end
    end

    return stamp
end

---------------------------------------------------------------------------
-- Rotation
---------------------------------------------------------------------------

-- Maps a 0-based (col,row) inside a WxH stamp to its position inside the
-- rotated stamp, for `quarter` in 0..3 clockwise. Returns nx, ny, and the
-- rotated stamp's (w,h). The formulas are the standard 90-degree grid
-- rotations; the h/w swap on odd quarters is why a WxH room becomes HxW.
local function rotatePoint(col, row, w, h, quarter)
    quarter = quarter % 4
    if quarter == 0 then return col, row, w, h end
    if quarter == 1 then return h - 1 - row, col, h, w end       -- 90 CW
    if quarter == 2 then return w - 1 - col, h - 1 - row, w, h end -- 180
    return row, w - 1 - col, h, w                                 -- 270 CW
end

-- A stamp rotated to a new stamp. quarter is 0..3 clockwise quarter-turns.
function Prefab.rotate(stamp, quarter)
    quarter = (tonumber(quarter) or 0) % 4
    if quarter == 0 then return stamp end

    local _, _, rw, rh = rotatePoint(0, 0, stamp.w, stamp.h, quarter)
    local out = {
        w = rw, h = rh, tiles = {},
        doors = {}, entities = {}, floorHeights = {}, wallHeights = {},
    }
    for row = 0, rh - 1 do out.tiles[row] = {} end

    for row = 0, stamp.h - 1 do
        for col = 0, stamp.w - 1 do
            local nx, ny = rotatePoint(col, row, stamp.w, stamp.h, quarter)
            out.tiles[ny][nx] = stamp.tiles[row][col]
        end
    end

    for _, d in ipairs(stamp.doors) do
        local nx, ny = rotatePoint(d.x, d.y, stamp.w, stamp.h, quarter)
        out.doors[#out.doors + 1] = { x = nx, y = ny, open = d.open }
    end

    -- Entity positions are continuous, not grid cells, so they rotate about
    -- the stamp's centre and their facing turns with the room.
    for _, e in ipairs(stamp.entities) do
        local col, row = e.x, e.y
        local nx, ny
        if quarter == 1 then nx, ny = stamp.h - row, col
        elseif quarter == 2 then nx, ny = stamp.w - col, stamp.h - row
        else nx, ny = row, stamp.w - col end
        out.entities[#out.entities + 1] = {
            kind = e.kind, x = nx, y = ny,
            angle = (e.angle or 0) + quarter * HALF_PI,
        }
    end

    for _, fh in ipairs(stamp.floorHeights) do
        local nx, ny = rotatePoint(fh.x, fh.y, stamp.w, stamp.h, quarter)
        out.floorHeights[#out.floorHeights + 1] = { x = nx, y = ny, z = fh.z }
    end
    for _, wh in ipairs(stamp.wallHeights) do
        local nx, ny = rotatePoint(wh.x, wh.y, stamp.w, stamp.h, quarter)
        out.wallHeights[#out.wallHeights + 1] = { x = nx, y = ny, h = wh.h }
    end

    return out
end

---------------------------------------------------------------------------
-- Paste
---------------------------------------------------------------------------

local function ensureRow(map, y)
    map.tiles[y] = map.tiles[y] or {}
    return map.tiles[y]
end

local function clearAt(map, tx, ty)
    for i = #map.doors, 1, -1 do
        if map.doors[i].x == tx and map.doors[i].y == ty then
            table.remove(map.doors, i)
        end
    end
    for i = #(map.entities or {}), 1, -1 do
        local e = map.entities[i]
        if floor(e.x) + 1 == tx and floor(e.y) + 1 == ty then
            table.remove(map.entities, i)
        end
    end
end

-- Pastes `stamp` onto `map` with its top-left at 1-based tile (atx,aty).
-- opts.rotate (0..3 quarter-turns). Tiles outside the map are clipped rather
-- than growing it — an editor decision the caller can override by resizing
-- first. Returns the pasted rect { tx1, ty1, tx2, ty2 } for a follow-up
-- selection, or nil if nothing landed.
function Prefab.paste(map, stamp, atx, aty, opts)
    opts = opts or {}
    if opts.rotate and opts.rotate % 4 ~= 0 then
        stamp = Prefab.rotate(stamp, opts.rotate)
    end
    atx = floor(atx); aty = floor(aty)

    local pasted = false
    local x2, y2 = atx, aty

    for row = 0, stamp.h - 1 do
        local ty = aty + row
        if ty >= 1 and ty <= map.height then
            local mrow = ensureRow(map, ty)
            for col = 0, stamp.w - 1 do
                local tx = atx + col
                if tx >= 1 and tx <= map.width then
                    clearAt(map, tx, ty)
                    mrow[tx] = stamp.tiles[row][col] or 0
                    pasted = true
                    if tx > x2 then x2 = tx end
                    if ty > y2 then y2 = ty end
                end
            end
        end
    end
    if not pasted then return nil end

    for _, d in ipairs(stamp.doors) do
        local tx, ty = atx + d.x, aty + d.y
        if tx >= 1 and tx <= map.width and ty >= 1 and ty <= map.height then
            ensureRow(map, ty)[tx] = require('meatray.sim.world').DOOR
            map.doors[#map.doors + 1] = { x = tx, y = ty, open = d.open }
        end
    end

    for _, e in ipairs(stamp.entities) do
        local wx, wy = (atx - 1) + e.x, (aty - 1) + e.y
        local tx, ty = floor(wx) + 1, floor(wy) + 1
        if tx >= 1 and tx <= map.width and ty >= 1 and ty <= map.height then
            map.entities[#map.entities + 1] = {
                kind = e.kind, x = wx, y = wy, angle = e.angle or 0,
                char = Map.charFor(map, e.kind),
            }
        end
    end

    for _, fh in ipairs(stamp.floorHeights) do
        local tx, ty = atx + fh.x, aty + fh.y
        if tx >= 1 and tx <= map.width and ty >= 1 and ty <= map.height then
            Map.setFloorHeight(map, tx, ty, fh.z)
        end
    end
    for _, wh in ipairs(stamp.wallHeights) do
        local tx, ty = atx + wh.x, aty + wh.y
        if tx >= 1 and tx <= map.width and ty >= 1 and ty <= map.height then
            Map.setWallHeight(map, tx, ty, wh.h)
        end
    end

    return { tx1 = atx, ty1 = aty, tx2 = x2, ty2 = y2 }
end

---------------------------------------------------------------------------
-- Serialize (compact, for a custom-stamp library on disk)
---------------------------------------------------------------------------

function Prefab.serialize(stamp)
    local rows = {}
    for row = 0, stamp.h - 1 do
        local cells = {}
        for col = 0, stamp.w - 1 do
            cells[col + 1] = tostring(stamp.tiles[row][col] or 0)
        end
        rows[#rows + 1] = table.concat(cells, ',')
    end
    -- Doors and entities as terse lines; enough for the built-in kit and a
    -- hand-saved room, not a general asset format.
    local doors = {}
    for _, d in ipairs(stamp.doors) do
        doors[#doors + 1] = ('%d:%d:%s'):format(d.x, d.y, d.open and '1' or '0')
    end
    local ents = {}
    for _, e in ipairs(stamp.entities) do
        ents[#ents + 1] = ('%s:%s:%s:%s'):format(e.kind, e.x, e.y, e.angle or 0)
    end
    return table.concat({
        ('%dx%d'):format(stamp.w, stamp.h),
        table.concat(rows, ';'),
        table.concat(doors, ';'),
        table.concat(ents, ';'),
    }, '|')
end

function Prefab.deserialize(text)
    local dims, grid, doors, ents = text:match('^([^|]*)|([^|]*)|([^|]*)|(.*)$')
    if not dims then return nil, 'not a prefab string' end
    local w, h = dims:match('^(%d+)x(%d+)$')
    w, h = tonumber(w), tonumber(h)
    if not w or not h then return nil, 'bad dimensions' end

    local stamp = { w = w, h = h, tiles = {}, doors = {}, entities = {},
                    floorHeights = {}, wallHeights = {} }
    local row = 0
    for line in (grid .. ';'):gmatch('([^;]*);') do
        if line ~= '' then
            stamp.tiles[row] = {}
            local col = 0
            for cell in (line .. ','):gmatch('([^,]*),') do
                if cell ~= '' then
                    stamp.tiles[row][col] = tonumber(cell) or 0
                    col = col + 1
                end
            end
            row = row + 1
        end
    end
    for d in (doors .. ';'):gmatch('([^;]*);') do
        local dx, dy, open = d:match('^(%d+):(%d+):(%d)$')
        if dx then stamp.doors[#stamp.doors + 1] =
            { x = tonumber(dx), y = tonumber(dy), open = open == '1' } end
    end
    for e in (ents .. ';'):gmatch('([^;]*);') do
        local kind, ex, ey, ea = e:match('^([^:]+):([^:]+):([^:]+):([^:]+)$')
        if kind then stamp.entities[#stamp.entities + 1] =
            { kind = kind, x = tonumber(ex), y = tonumber(ey),
              angle = tonumber(ea) or 0 } end
    end
    return stamp
end

---------------------------------------------------------------------------
-- Built-in kit
---------------------------------------------------------------------------

-- Small, wall-bordered rooms authored as strings, so the editor has stamps to
-- offer before anyone has saved one. Tile values: 0 floor, 1 wall.
local KIT_SRC = {
    pillar_room = '5x5|1,1,1,1,1;1,0,0,0,1;1,0,1,0,1;1,0,0,0,1;1,1,1,1,1|1:0:0|',
    cross       = '5x5|1,1,0,1,1;1,1,0,1,1;0,0,0,0,0;1,1,0,1,1;1,1,0,1,1||',
    guard_post  = '4x4|1,1,1,1;1,0,0,1;1,0,0,1;1,1,0,1|2:3:0|imp:1.5:1.5:0',
    alcove      = '3x3|1,1,1;1,0,1;1,0,1||crystal:1.5:1.5:0',
}

Prefab.KIT = {}
for name, src in pairs(KIT_SRC) do
    Prefab.KIT[name] = Prefab.deserialize(src)
end

function Prefab.kitNames()
    local names = {}
    for name in pairs(Prefab.KIT) do names[#names + 1] = name end
    table.sort(names)
    return names
end

return Prefab
