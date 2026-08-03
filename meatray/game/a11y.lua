--[[
    meatray.game.a11y — the accessibility settings, and the colour transform
    that is the substance of them (F8).

    The modern ship bar: a colourblind-safe palette, a photosensitivity control
    over flashes and shake, subtitles for sound cues, and hold-vs-toggle for the
    held controls. This is that as a MODEL — settings plus the pure transforms a
    renderer applies — with its own line-oriented persistence, the same shape
    meatray.game.options keeps.

        local A11y = require('meatray.game.a11y')
        local a = A11y.new()

        a:set('colorblind', 'deuteranopia')
        a:set('flashScale', 0.3)          -- photosensitivity: dim every flash
        a:set('subtitles', true)

        r, g, b = a:color(1, 0, 0)        -- red, remapped to stay distinct
        alpha   = a:flash(baseAlpha)      -- baseAlpha * flashScale
        mag     = a:shake(baseShake)      -- baseShake * shakeScale
        if a:subtitles() then show(caption) end

    The colourblind transform is the interesting part. Simulating a deficiency
    is the wrong goal — the player already has it. The goal is DISTINGUISHABILITY:
    take the difference the eye cannot see and encode it into a channel the
    deficiency spares. Red-green blindness (prot/deuteranopia) confuses the R-G
    axis, so the R-G difference is written into the blue channel; blue-yellow
    blindness (tritanopia) confuses the yellow-blue axis, so that difference is
    written into red. It is a channel-shift daltonization, not a full LMS model,
    and it is honest about that — but a pure red and a pure green, which a
    red-green colourblind player sees as nearly the same, come out with clearly
    different blue after it, which is the whole job.

    HEADLESS: pure Lua.
]]

local A11y = {}
local A11yMT = {}
A11yMT.__index = A11yMT

A11y.COLORBLIND_MODES = { 'none', 'protanopia', 'deuteranopia', 'tritanopia' }

local function clamp01(v)
    if v < 0 then return 0 end
    if v > 1 then return 1 end
    return v
end

local function clampRange(v, lo, hi)
    v = tonumber(v)
    if not v or v ~= v then return nil end
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

---------------------------------------------------------------------------
-- Construction
---------------------------------------------------------------------------

function A11y.new(opts)
    opts = opts or {}
    return setmetatable({
        colorblind   = 'none',   -- one of COLORBLIND_MODES
        flashScale   = 1,        -- 0..1, multiplies every screen flash's alpha
        shakeScale   = 1,        -- 0..2, multiplies screen-shake magnitude
        subtitles    = false,    -- show captions for sound cues
        holdToToggle = false,    -- sprint/crouch: hold vs toggle
        strength     = 0.9,      -- how hard the colourblind remap pushes (0..1)
    }, A11yMT)
end

---------------------------------------------------------------------------
-- Settings
---------------------------------------------------------------------------

local COLORBLIND_SET = {}
for _, m in ipairs(A11y.COLORBLIND_MODES) do COLORBLIND_SET[m] = true end

-- Sets one field with validation. Returns the accepted value, or nil + reason.
function A11yMT:set(field, value)
    if field == 'colorblind' then
        local m = tostring(value):lower()
        if not COLORBLIND_SET[m] then return nil, 'unknown colourblind mode' end
        self.colorblind = m
        return m
    elseif field == 'flashScale' then
        local v = clampRange(value, 0, 1)
        if not v then return nil, 'flashScale must be a number' end
        self.flashScale = v
        return v
    elseif field == 'shakeScale' then
        local v = clampRange(value, 0, 2)
        if not v then return nil, 'shakeScale must be a number' end
        self.shakeScale = v
        return v
    elseif field == 'strength' then
        local v = clampRange(value, 0, 1)
        if not v then return nil, 'strength must be a number' end
        self.strength = v
        return v
    elseif field == 'subtitles' then
        self.subtitles = value and true or false
        return self.subtitles
    elseif field == 'holdToToggle' then
        self.holdToToggle = value and true or false
        return self.holdToToggle
    end
    return nil, 'unknown accessibility field: ' .. tostring(field)
end

function A11yMT:get(field) return self[field] end

---------------------------------------------------------------------------
-- The transforms a renderer applies
---------------------------------------------------------------------------

-- Remaps a colour so a colourblind player can still tell it apart. Takes and
-- returns r,g,b in 0..1. 'none' is the identity. See the header for the method.
function A11yMT:color(r, g, b)
    r, g, b = tonumber(r) or 0, tonumber(g) or 0, tonumber(b) or 0
    local mode = self.colorblind
    if mode == 'none' then return r, g, b end

    local k = self.strength
    if mode == 'protanopia' or mode == 'deuteranopia' then
        -- Red-green confusion: write the R-G difference into blue, and pull the
        -- two confusable channels slightly apart in brightness.
        local d = r - g
        b = clamp01(b + k * d * 0.5 + 0.0)
        -- A small lift of the channel the deficiency weakens keeps hues from
        -- collapsing to grey.
        if mode == 'protanopia' then
            g = clamp01(g + k * 0.15 * (r - b))
        else
            r = clamp01(r + k * 0.15 * (g - b))
        end
        return r, g, b
    end

    -- tritanopia: blue-yellow confusion. Yellow is r≈g high, blue is b high;
    -- write the (yellow - blue) difference into red.
    local yellow = (r + g) * 0.5
    local d = yellow - b
    r = clamp01(r + k * d * 0.5)
    return r, g, b
end

-- Convenience for a {r,g,b[,a]} table; alpha passes through untouched.
function A11yMT:colorTable(c)
    if type(c) ~= 'table' then return c end
    local r, g, b = self:color(c[1] or 0, c[2] or 0, c[3] or 0)
    return { r, g, b, c[4] }
end

-- Photosensitivity: every screen flash's alpha runs through here, so a player
-- who sets flashScale low sees a muted version and one who sets it to 0 sees
-- none at all.
function A11yMT:flash(alpha)
    return (tonumber(alpha) or 0) * self.flashScale
end

-- Screen-shake magnitude, scaled the same way.
function A11yMT:shake(magnitude)
    return (tonumber(magnitude) or 0) * self.shakeScale
end

function A11yMT:subtitlesOn() return self.subtitles end
function A11yMT:holdIsToggle() return self.holdToToggle end

---------------------------------------------------------------------------
-- Menu rows (for the options screen)
---------------------------------------------------------------------------

function A11yMT:menuRows()
    return {
        { id = 'a11y.colorblind', kind = 'choice', label = 'Colourblind Mode',
          value = self.colorblind, choices = A11y.COLORBLIND_MODES },
        { id = 'a11y.flashScale', kind = 'slider', label = 'Flash Intensity',
          value = self.flashScale, min = 0, max = 1, step = 0.1 },
        { id = 'a11y.shakeScale', kind = 'slider', label = 'Screen Shake',
          value = self.shakeScale, min = 0, max = 2, step = 0.1 },
        { id = 'a11y.subtitles', kind = 'toggle', label = 'Subtitles',
          value = self.subtitles },
        { id = 'a11y.holdToToggle', kind = 'toggle', label = 'Hold = Toggle',
          value = self.holdToToggle },
    }
end

-- Apply a menu edit by row id.
function A11yMT:menuSet(id, value)
    local field = tostring(id):match('^a11y%.(.+)$')
    if not field then return false, 'not an accessibility row' end
    return self:set(field, value) ~= nil
end

---------------------------------------------------------------------------
-- Persistence: key=value lines, like options
---------------------------------------------------------------------------

local function parseBool(s)
    s = tostring(s):lower()
    if s == 'true' or s == '1' or s == 'on' then return true end
    if s == 'false' or s == '0' or s == 'off' then return false end
    return nil
end

function A11yMT:serialize()
    return table.concat({
        '# MeatRayCast accessibility',
        'colorblind=' .. self.colorblind,
        'flashScale=' .. tostring(self.flashScale),
        'shakeScale=' .. tostring(self.shakeScale),
        'strength=' .. tostring(self.strength),
        'subtitles=' .. tostring(self.subtitles),
        'holdToToggle=' .. tostring(self.holdToToggle),
    }, '\n') .. '\n'
end

function A11yMT:deserialize(text)
    if type(text) ~= 'string' then return false, 'string required' end
    for line in (text .. '\n'):gmatch('([^\n]*)\n') do
        line = line:gsub('\r$', '')
        if line ~= '' and not line:match('^%s*#') then
            local k, v = line:match('^%s*([%w]+)%s*=%s*(.-)%s*$')
            if k == 'colorblind' then self:set('colorblind', v)
            elseif k == 'flashScale' or k == 'shakeScale' or k == 'strength' then
                local n = tonumber(v); if n then self:set(k, n) end
            elseif k == 'subtitles' or k == 'holdToToggle' then
                local b = parseBool(v); if b ~= nil then self:set(k, b) end
            end
        end
    end
    return true
end

function A11yMT:save(storage, path)
    if not storage or not storage.write then return nil, 'storage required' end
    return storage.write(path or 'accessibility.cfg', self:serialize())
end

function A11yMT:load(storage, path)
    if not storage or not storage.read then return nil, 'storage required' end
    local bytes, err = storage.read(path or 'accessibility.cfg')
    if not bytes then return nil, err or 'missing accessibility file' end
    return self:deserialize(bytes)
end

return A11y
