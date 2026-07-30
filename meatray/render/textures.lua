--[[
    meatray.render.textures — every texture the engine draws, generated at runtime.

    No image files. That is not a limitation the engine works around, it is the
    reason a fresh clone runs: there is nothing to be missing. Asset import is a
    later phase and will layer on top of this rather than replace it, because a
    registry whose misses fall back to a generated texture degrades gracefully,
    while one that errors takes the whole game down over a typo in a filename.

    Patterns are derived from a theme's base colours so a new theme gets a full
    texture set for free.
]]

local Platform = require('meatray.platform')
local Themes = require('meatray.render.themes')

local Textures = {}

local SIZE = 64          -- texture edge, in pixels
local floor, sin, max, min = math.floor, math.sin, math.max, math.min

Textures.SIZE = SIZE

-- Nine wall tiles and the door, side by side in one image.
--
-- The raycaster draws one screen column at a time, and a host batches
-- consecutive draws only while they share a texture. Ten separate images meant
-- the batch broke every time the ray crossed from one wall material to another;
-- one image means it never breaks for that reason. The atlas is the only thing
-- the wall loop samples, and the individual images below it are kept for
-- everything else that wants a single wall texture on its own.
local ATLAS_SLOTS = 10
local ATLAS_W = SIZE * ATLAS_SLOTS

Textures.ATLAS_SLOTS = ATLAS_SLOTS
Textures.ATLAS_WIDTH = ATLAS_W

-- Deterministic value noise in [0,1). Not love.math.random, because the same
-- tile must look the same every run — a texture that reshuffles per launch reads
-- as flicker.
--
-- Uses the fract(sin(dot)) trick rather than integer bit-mixing on purpose: LÖVE
-- runs LuaJIT, which is Lua 5.1, so `~` and `>>` are parse errors, and the
-- 64-bit intermediates a good integer hash wants exceed the 2^53 a double holds
-- exactly. This stays in float range and is deterministic, which is all a
-- texture needs.
local function hashNoise(x, y, salt)
    local v = sin(x * 12.9898 + y * 78.233 + (salt or 0) * 43.123) * 43758.5453
    return v - floor(v)
end

local function shade(color, amount)
    return {
        min(1, max(0, color[1] * amount)),
        min(1, max(0, color[2] * amount)),
        min(1, max(0, color[3] * amount)),
    }
end

---------------------------------------------------------------------------
-- Pattern generators. Each writes one SIZE x SIZE ImageData.
---------------------------------------------------------------------------

local patterns = {}

-- Mortared blocks, offset every other course.
function patterns.brick(data, base, salt)
    local courseH, brickW, mortar = 16, 32, 2
    for y = 0, SIZE - 1 do
        local course = floor(y / courseH)
        local offset = (course % 2 == 0) and 0 or brickW / 2
        for x = 0, SIZE - 1 do
            local bx = (x + offset) % brickW
            local by = y % courseH
            local isMortar = bx < mortar or by < mortar

            local c
            if isMortar then
                c = shade(base, 0.55)
            else
                local grain = 0.9 + hashNoise(floor((x + offset) / brickW), course, salt) * 0.2
                local speck = 0.97 + hashNoise(x, y, salt) * 0.06
                c = shade(base, grain * speck)
            end
            data:setPixel(x, y, c[1], c[2], c[3], 1)
        end
    end
end

-- Rough stone: noise with a subtle diagonal grain.
function patterns.stone(data, base, salt)
    for y = 0, SIZE - 1 do
        for x = 0, SIZE - 1 do
            local coarse = hashNoise(floor(x / 8), floor(y / 8), salt)
            local fine = hashNoise(x, y, salt + 7)
            local grain = sin((x + y) * 0.12) * 0.03
            local c = shade(base, 0.82 + coarse * 0.24 + fine * 0.08 + grain)
            data:setPixel(x, y, c[1], c[2], c[3], 1)
        end
    end
end

-- Riveted metal plate: panel seams plus corner rivets.
function patterns.plate(data, base, salt)
    local panel = 32
    for y = 0, SIZE - 1 do
        for x = 0, SIZE - 1 do
            local px, py = x % panel, y % panel
            local seam = px < 2 or py < 2
            local amount = seam and 0.62 or (0.92 + hashNoise(x, y, salt) * 0.10)

            -- Rivets near each panel corner.
            local rx, ry = px - 6, py - 6
            if rx * rx + ry * ry < 6 then amount = 1.22 end

            local c = shade(base, amount)
            data:setPixel(x, y, c[1], c[2], c[3], 1)
        end
    end
end

-- Vertical planks with visible seams and grain.
function patterns.planks(data, base, salt)
    local plankW = 16
    for y = 0, SIZE - 1 do
        for x = 0, SIZE - 1 do
            local px = x % plankW
            local seam = px < 1
            local plank = floor(x / plankW)
            local grain = sin(y * 0.35 + plank * 2.1) * 0.05
            local amount = seam and 0.55 or (0.9 + grain + hashNoise(plank, floor(y / 3), salt) * 0.12)
            local c = shade(base, amount)
            data:setPixel(x, y, c[1], c[2], c[3], 1)
        end
    end
end

-- Flat with faint noise, for floors and ceilings.
function patterns.flat(data, base, salt)
    for y = 0, SIZE - 1 do
        for x = 0, SIZE - 1 do
            local c = shade(base, 0.94 + hashNoise(x, y, salt) * 0.12)
            data:setPixel(x, y, c[1], c[2], c[3], 1)
        end
    end
end

-- Flagstones: four grouted squares to a tile.
--
-- The floor is the one surface a viewer sees the *perspective* of rather than
-- the surface of, and perspective is only legible against straight lines that
-- converge. `flat` above is faint per-pixel noise, which is exactly the pattern
-- that survives a per-pixel floor cast as an undifferentiated fizz -- correct,
-- and indistinguishable from the flat colour band it replaced. Grout lines cost
-- the same to generate and are what makes the cast visible at all.
function patterns.tiles(data, base, salt)
    local stone, grout = 32, 3
    for y = 0, SIZE - 1 do
        for x = 0, SIZE - 1 do
            local sx, sy = x % stone, y % stone
            local isGrout = sx < grout or sy < grout

            local amount
            if isGrout then
                amount = 0.58
            else
                -- Per-stone tint, so neighbouring flags are not clones, plus a
                -- little per-pixel wear on top.
                local stoneShade = 0.88 + hashNoise(floor(x / stone), floor(y / stone), salt) * 0.22
                local wear = 0.97 + hashNoise(x, y, salt + 3) * 0.06
                -- A soft bevel toward the grout reads as a raised flag rather
                -- than as paint.
                local edge = min(sx - grout, sy - grout, stone - 1 - sx, stone - 1 - sy)
                local bevel = edge < 3 and (0.94 + edge * 0.02) or 1
                amount = stoneShade * wear * bevel
            end

            local c = shade(base, amount)
            data:setPixel(x, y, c[1], c[2], c[3], 1)
        end
    end
end

-- Coffered ceiling: a recessed panel per tile, dark toward the edges.
--
-- Same reasoning as `tiles`, one surface up. A ceiling cast from faint noise is
-- indistinguishable from the band it replaced.
function patterns.coffer(data, base, salt)
    local half = SIZE / 2
    for y = 0, SIZE - 1 do
        for x = 0, SIZE - 1 do
            -- Distance to the nearest tile edge, 0 at the seam, 1 at the centre.
            local inset = min(x, y, SIZE - 1 - x, SIZE - 1 - y) / half
            local amount = 0.60 + min(1, inset * 3.2) * 0.42
            amount = amount * (0.97 + hashNoise(x, y, salt) * 0.06)
            local c = shade(base, amount)
            data:setPixel(x, y, c[1], c[2], c[3], 1)
        end
    end
end

-- Which pattern each wall tile code uses. Tiles beyond this list reuse stone,
-- so a map referencing texture 9 in a theme with four colours still draws.
local WALL_PATTERNS = { 'brick', 'stone', 'plate', 'planks', 'brick', 'stone', 'plate', 'planks', 'stone' }

-- The generators themselves, exposed because they need no host: each one writes
-- into anything with a `setPixel`, which is what lets tests/test_render_floorcast
-- assert that the floor and ceiling patterns tile without a GPU to make an image
-- with. That is the whole reason the drawing is separated from the allocation.
Textures.patterns = patterns

Textures.patternNames = function()
    local out = {}
    for name in pairs(patterns) do out[#out + 1] = name end
    table.sort(out)
    return out
end

---------------------------------------------------------------------------
-- Building a set
---------------------------------------------------------------------------

local function makeImageData(base, patternName, salt)
    local data = Platform.gfx.newImageData(SIZE, SIZE)
    local generator = patterns[patternName] or patterns.stone
    generator(data, base, salt or 0)
    return data
end

local function makeImage(base, patternName, salt)
    -- Nearest filtering comes from the backend; see meatray/platform/love.lua.
    return Platform.gfx.newImage(makeImageData(base, patternName, salt))
end

-- Generates every texture a theme needs. Called once per theme and cached, since
-- generating 64x64 pixel by pixel is cheap but not free.
local cache = {}

function Textures.forTheme(themeName)
    themeName = themeName or Themes.DEFAULT
    if cache[themeName] then return cache[themeName] end

    local theme = Themes.get(themeName)

    -- `walls` and `door` are the individual images, which is what a caller
    -- holding one wall texture wants (see meatray/asset/init.lua). `atlas` is
    -- the same pixels laid out side by side, which is what the wall loop draws
    -- from. Both come out of one generation pass: the per-tile ImageData is made
    -- once, handed to the host as an image, and copied into the atlas.
    local set = { walls = {}, wallSlot = {}, atlasWidth = ATLAS_W }
    local atlasData = Platform.gfx.newImageData(ATLAS_W, SIZE)

    local function place(data, slot)
        Platform.gfx.pasteImageData(atlasData, data, slot * SIZE, 0, SIZE, SIZE)
        return slot * SIZE
    end

    for tile = 1, 9 do
        local color = theme.walls[tile] or theme.walls[1]
        local data = makeImageData(color, WALL_PATTERNS[tile] or 'stone', tile)
        set.walls[tile] = Platform.gfx.newImage(data)
        set.wallSlot[tile] = place(data, tile - 1)
    end

    local doorData = makeImageData(theme.door or { 0.4, 0.26, 0.14 }, 'planks', 20)
    set.door = Platform.gfx.newImage(doorData)
    set.doorSlot = place(doorData, 9)

    set.atlas = Platform.gfx.newImage(atlasData)

    -- One world tile of floor and of ceiling, which is what the floor cast in
    -- meatray/render/raycaster.lua samples: it wraps these by the fractional
    -- part of a world coordinate, so the tile edge is the seam and the pattern
    -- has to tile cleanly across it. Both do, by construction.
    set.floor = makeImage(theme.floor or { 0.2, 0.2, 0.2 }, 'tiles', 30)
    set.ceiling = theme.ceiling and makeImage(theme.ceiling, 'coffer', 31) or nil

    cache[themeName] = set
    return set
end

function Textures.clearCache()
    cache = {}
end

-- A flat colour image, used for sky bands and as an absolute fallback.
function Textures.solid(color)
    local data = Platform.gfx.newImageData(1, 1)
    data:setPixel(0, 0, color[1], color[2], color[3], 1)
    return Platform.gfx.newImage(data)
end

return Textures
