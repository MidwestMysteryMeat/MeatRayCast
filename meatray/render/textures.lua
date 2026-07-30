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

local Themes = require('meatray.render.themes')

local Textures = {}

local SIZE = 64          -- texture edge, in pixels
local floor, sin, max, min = math.floor, math.sin, math.max, math.min

Textures.SIZE = SIZE

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

-- Which pattern each wall tile code uses. Tiles beyond this list reuse stone,
-- so a map referencing texture 9 in a theme with four colours still draws.
local WALL_PATTERNS = { 'brick', 'stone', 'plate', 'planks', 'brick', 'stone', 'plate', 'planks', 'stone' }

Textures.patternNames = function()
    local out = {}
    for name in pairs(patterns) do out[#out + 1] = name end
    table.sort(out)
    return out
end

---------------------------------------------------------------------------
-- Building a set
---------------------------------------------------------------------------

local function makeImage(base, patternName, salt)
    local data = love.image.newImageData(SIZE, SIZE)
    local generator = patterns[patternName] or patterns.stone
    generator(data, base, salt or 0)
    local image = love.graphics.newImage(data)
    image:setFilter('nearest', 'nearest')
    return image
end

-- Generates every texture a theme needs. Called once per theme and cached, since
-- generating 64x64 pixel by pixel is cheap but not free.
local cache = {}

function Textures.forTheme(themeName)
    themeName = themeName or Themes.DEFAULT
    if cache[themeName] then return cache[themeName] end

    local theme = Themes.get(themeName)

    local set = { walls = {} }

    for tile = 1, 9 do
        local color = theme.walls[tile] or theme.walls[1]
        set.walls[tile] = makeImage(color, WALL_PATTERNS[tile] or 'stone', tile)
    end

    set.door = makeImage(theme.door or { 0.4, 0.26, 0.14 }, 'planks', 20)
    set.floor = makeImage(theme.floor or { 0.2, 0.2, 0.2 }, 'flat', 30)
    set.ceiling = theme.ceiling and makeImage(theme.ceiling, 'flat', 31) or nil

    cache[themeName] = set
    return set
end

function Textures.clearCache()
    cache = {}
end

-- A flat colour image, used for sky bands and as an absolute fallback.
function Textures.solid(color)
    local data = love.image.newImageData(1, 1)
    data:setPixel(0, 0, color[1], color[2], color[3], 1)
    local image = love.graphics.newImage(data)
    image:setFilter('nearest', 'nearest')
    return image
end

return Textures
