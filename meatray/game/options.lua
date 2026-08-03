--[[
    meatray.game.options — input remapping, mouse prefs, volume buses (Wave A3).

    Pure data + optional persistence. No rendering, no love.* required.

        local Options = require('meatray.game.options')
        local opts = Options.new()

        opts:setBind('forward', 'w')
        opts:addBind('forward', 'up')
        opts:setMouse{ sensitivity = 0.003, invertY = true }
        opts:setVolume('music', 0.7)
        opts:applyAudio()          -- pushes SFX/music buses when modules load

        local down = { w = true }
        if opts:isActive('forward', down) then ... end

        opts:save(storage)         -- meatray.save.storage backend
        opts:load(storage)

    Serialize format is a small line-oriented text file (human-editable):

        version=1
        mouse.sensitivity=0.0028
        mouse.invertY=false
        volume.master=1
        volume.sfx=1
        volume.music=1
        bind.forward=w
        bind.forward=up

    Multi-bind: repeated `bind.<action>=` lines. Unknown keys are kept in
    `extra` so future fields round-trip.

    HEADLESS: pure Lua.
]]

local Options = {}
local OptionsMT = {}
OptionsMT.__index = OptionsMT

Options.VERSION = 1
Options.DEFAULT_PATH = 'options.cfg'

-- Canonical actions a stock FPS shell expects. Games may add more via
-- Options.defineAction / opts:ensureAction.
Options.DEFAULT_ACTIONS = {
    { id = 'forward',    label = 'Move Forward',   keys = { 'w', 'up' } },
    { id = 'back',       label = 'Move Back',      keys = { 's', 'down' } },
    { id = 'left',       label = 'Move Left',      keys = { 'a', 'left' } },
    { id = 'right',      label = 'Move Right',     keys = { 'd', 'right' } },
    { id = 'jump',       label = 'Jump',           keys = { 'space' } },
    { id = 'crouch',     label = 'Crouch',         keys = { 'lctrl', 'rctrl' } },
    { id = 'sprint',     label = 'Sprint',         keys = { 'lshift' } },
    { id = 'fire',       label = 'Fire',           keys = { 'mouse1' } },
    { id = 'altfire',    label = 'Alt Fire',       keys = { 'mouse2' } },
    { id = 'reload',     label = 'Reload',         keys = { 'r' } },
    { id = 'use',        label = 'Use / Interact', keys = { 'e' }, },
    { id = 'weapon_next',label = 'Next Weapon',    keys = { 'wheelup', 'q' } },
    { id = 'weapon_prev',label = 'Prev Weapon',    keys = { 'wheeldown' } },
    { id = 'pause',      label = 'Pause',          keys = { 'p', 'escape' } },
    { id = 'scoreboard', label = 'Scoreboard',     keys = { 'tab' } },
    { id = 'minimap',    label = 'Toggle Minimap', keys = { 'm' } },
}

Options.VOLUME_BUSES = { 'master', 'sfx', 'music' }

---------------------------------------------------------------------------
-- Graphics (Wave A7)
---------------------------------------------------------------------------

-- Field of view is stored in DEGREES because that is the number on every
-- settings screen a player has ever seen. The renderer wants the camera
-- plane's half-width instead, and `fovPlane()` below is the conversion — the
-- engine's 0.66 default is 2*atan(0.66) ≈ 66.4°, which is where the classic
-- number comes from.
Options.FOV_MIN = 60
Options.FOV_MAX = 110
Options.DEFAULT_FOV = 66

-- Internal render scale. Below 1 the world is drawn into a smaller buffer and
-- stretched, which is the one graphics setting that reliably buys frames on a
-- software raycaster. 0.5 is a quarter of the pixels, not half.
Options.SCALE_MIN = 0.25
Options.SCALE_MAX = 1

-- Look limit in radians, capped at the renderer's own ceiling. See
-- meatray.render.raycaster: past about a radian the horizon leaves the frame.
Options.PITCH_MIN = 0.1
Options.PITCH_MAX = 1.0

-- Presets are what most players actually touch; the individual toggles are for
-- the ones who do not. Setting a preset writes the fields, and changing any
-- field afterwards moves quality to 'custom' — a preset name that lies about
-- what is switched on is worse than no preset at all.
Options.QUALITY_PRESETS = {
    low    = { scale = 0.5,  floorCast = false, lightTexture = false },
    medium = { scale = 0.75, floorCast = true,  lightTexture = false },
    high   = { scale = 1,    floorCast = true,  lightTexture = true },
}
Options.QUALITY_ORDER = { 'low', 'medium', 'high', 'custom' }
-- What a settings screen may PICK. 'custom' is a report about the other
-- fields, not a thing to choose — offering it as a choice means a menu that
-- faithfully cycles the list proposes a value setQuality rightly refuses.
Options.QUALITY_PICKABLE = { 'low', 'medium', 'high' }

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function clamp01(v)
    v = tonumber(v)
    if not v then return nil end
    if v < 0 then return 0 end
    if v > 1 then return 1 end
    return v
end

local function copyKeys(list)
    local out = {}
    for i = 1, #(list or {}) do out[i] = tostring(list[i]):lower() end
    return out
end

local function trim(s)
    return (tostring(s or ''):gsub('^%s+', ''):gsub('%s+$', ''))
end

local function parseBool(s)
    s = tostring(s or ''):lower()
    if s == '1' or s == 'true' or s == 'yes' or s == 'on' then return true end
    if s == '0' or s == 'false' or s == 'no' or s == 'off' then return false end
    return nil
end

local function defaultBinds()
    local binds = {}
    local labels = {}
    for i = 1, #Options.DEFAULT_ACTIONS do
        local a = Options.DEFAULT_ACTIONS[i]
        binds[a.id] = copyKeys(a.keys)
        labels[a.id] = a.label
    end
    return binds, labels
end

---------------------------------------------------------------------------
-- Construction
---------------------------------------------------------------------------

function Options.new(opts)
    opts = opts or {}
    local binds, labels = defaultBinds()
    if type(opts.binds) == 'table' then
        for action, keys in pairs(opts.binds) do
            binds[tostring(action)] = copyKeys(keys)
        end
    end
    if type(opts.labels) == 'table' then
        for action, label in pairs(opts.labels) do
            labels[tostring(action)] = tostring(label)
        end
    end

    local self = setmetatable({
        version = Options.VERSION,
        binds = binds,           -- [action] = { key, ... }
        labels = labels,         -- [action] = display name
        mouse = {
            sensitivity = tonumber(opts.sensitivity)
                or (opts.mouse and tonumber(opts.mouse.sensitivity))
                or 0.0028,
            invertY = false,
        },
        volume = {
            master = 1,
            sfx = 1,
            music = 1,
        },
        graphics = {
            scale = 1,
            fov = Options.DEFAULT_FOV,
            pitchLimit = Options.PITCH_MAX,
            floorCast = true,
            lightTexture = true,
            quality = 'high',
        },
        extra = {},              -- unknown serialize keys round-trip
        path = opts.path or Options.DEFAULT_PATH,
        dirty = false,
    }, OptionsMT)

    if opts.mouse then
        if opts.mouse.sensitivity ~= nil then
            self.mouse.sensitivity = tonumber(opts.mouse.sensitivity) or self.mouse.sensitivity
        end
        if opts.mouse.invertY ~= nil then
            self.mouse.invertY = opts.mouse.invertY and true or false
        end
    end
    if opts.invertY ~= nil then
        self.mouse.invertY = opts.invertY and true or false
    end
    if type(opts.volume) == 'table' then
        for _, bus in ipairs(Options.VOLUME_BUSES) do
            if opts.volume[bus] ~= nil then
                self.volume[bus] = clamp01(opts.volume[bus]) or self.volume[bus]
            end
        end
    end
    if type(opts.graphics) == 'table' then
        self:setGraphics(opts.graphics)
        self.dirty = false
    end

    return self
end

function Options.defaults()
    return Options.new()
end

---------------------------------------------------------------------------
-- Actions / binds
---------------------------------------------------------------------------

function OptionsMT:ensureAction(action, label, defaultKeys)
    action = tostring(action or '')
    if action == '' then return false, 'action required' end
    if not self.binds[action] then
        self.binds[action] = copyKeys(defaultKeys or {})
    end
    if label then self.labels[action] = tostring(label) end
    return true
end

function OptionsMT:actions()
    local list = {}
    local seen = {}
    for i = 1, #Options.DEFAULT_ACTIONS do
        local id = Options.DEFAULT_ACTIONS[i].id
        if self.binds[id] then
            list[#list + 1] = id
            seen[id] = true
        end
    end
    local extra = {}
    for id in pairs(self.binds) do
        if not seen[id] then extra[#extra + 1] = id end
    end
    table.sort(extra)
    for i = 1, #extra do list[#list + 1] = extra[i] end
    return list
end

function OptionsMT:labelOf(action)
    return self.labels[action] or action
end

function OptionsMT:keysOf(action)
    local k = self.binds[action]
    if not k then return {} end
    return copyKeys(k)
end

function OptionsMT:setBind(action, key)
    action = tostring(action or '')
    if action == '' then return false, 'action required' end
    if key == nil or key == '' then
        self.binds[action] = {}
        self.dirty = true
        return true
    end
    self.binds[action] = { tostring(key):lower() }
    self.dirty = true
    return true
end

function OptionsMT:addBind(action, key)
    action = tostring(action or '')
    key = tostring(key or ''):lower()
    if action == '' or key == '' then return false, 'action and key required' end
    local list = self.binds[action]
    if not list then
        self.binds[action] = { key }
        self.dirty = true
        return true
    end
    for i = 1, #list do
        if list[i] == key then return true end -- already bound
    end
    list[#list + 1] = key
    self.dirty = true
    return true
end

function OptionsMT:removeBind(action, key)
    local list = self.binds[action]
    if not list then return false end
    key = tostring(key or ''):lower()
    for i = #list, 1, -1 do
        if list[i] == key then
            table.remove(list, i)
            self.dirty = true
            return true
        end
    end
    return false
end

function OptionsMT:clearBinds(action)
    if not self.binds[action] then return false end
    self.binds[action] = {}
    self.dirty = true
    return true
end

function OptionsMT:resetBinds()
    local binds, labels = defaultBinds()
    self.binds = binds
    -- Keep custom labels for non-default actions; restore stock labels.
    for id, label in pairs(labels) do self.labels[id] = label end
    self.dirty = true
    return self
end

-- Which action (if any) currently uses this key. First match in actions() order.
function OptionsMT:actionForKey(key)
    key = tostring(key or ''):lower()
    if key == '' then return nil end
    local order = self:actions()
    for i = 1, #order do
        local action = order[i]
        local keys = self.binds[action]
        for j = 1, #keys do
            if keys[j] == key then return action end
        end
    end
    return nil
end

-- Rebind with optional conflict steal: remove key from other actions first.
function OptionsMT:rebind(action, key, opts)
    opts = opts or {}
    action = tostring(action or '')
    key = tostring(key or ''):lower()
    if action == '' or key == '' then return false, 'action and key required' end
    if not self.binds[action] then
        self.binds[action] = {}
    end
    local owner = self:actionForKey(key)
    if owner and owner ~= action then
        if opts.steal == false then
            return false, 'key in use by ' .. owner
        end
        self:removeBind(owner, key)
    end
    if opts.replace ~= false then
        self.binds[action] = { key }
    else
        self:addBind(action, key)
    end
    self.dirty = true
    return true
end

--[[
    keyState is a map of key -> truthy while held (from love.keyboard or a stub).
    mouse buttons use keys 'mouse1', 'mouse2', ... when the game feeds them in.
]]
function OptionsMT:isActive(action, keyState)
    if type(keyState) ~= 'table' then return false end
    local keys = self.binds[action]
    if not keys then return false end
    for i = 1, #keys do
        local k = keys[i]
        if keyState[k] then return true end
        -- Allow un-normalized case from some hosts.
        if keyState[k:upper()] then return true end
    end
    return false
end

-- Vector intent for movement actions: dx, dy in {-1,0,1} plane (x=right, y=forward).
function OptionsMT:moveVector(keyState)
    local x, y = 0, 0
    if self:isActive('forward', keyState) then y = y + 1 end
    if self:isActive('back', keyState) then y = y - 1 end
    if self:isActive('right', keyState) then x = x + 1 end
    if self:isActive('left', keyState) then x = x - 1 end
    return x, y
end

---------------------------------------------------------------------------
-- Mouse
---------------------------------------------------------------------------

function OptionsMT:setMouse(t)
    t = t or {}
    if t.sensitivity ~= nil then
        local s = tonumber(t.sensitivity)
        if s and s > 0 then
            self.mouse.sensitivity = s
            self.dirty = true
        end
    end
    if t.invertY ~= nil then
        self.mouse.invertY = t.invertY and true or false
        self.dirty = true
    end
    return self.mouse
end

function OptionsMT:getMouse()
    return {
        sensitivity = self.mouse.sensitivity,
        invertY = self.mouse.invertY and true or false,
    }
end

--[[
    Apply mouselook deltas. Returns yawAdd, pitchAdd where positive pitch is
    look-up. Matches stock main.lua (mouse up / negative dy → look up) when
    invertY is false; invertY flips that relationship.
]]
function OptionsMT:lookDelta(dx, dy)
    local sens = self.mouse.sensitivity or 0.0028
    local yawAdd = (dx or 0) * sens
    local pitchAdd = -(dy or 0) * sens
    if self.mouse.invertY then pitchAdd = -pitchAdd end
    return yawAdd, pitchAdd
end

---------------------------------------------------------------------------
-- Volumes
---------------------------------------------------------------------------

function OptionsMT:setVolume(bus, value)
    bus = tostring(bus or ''):lower()
    if bus == 'sound' then bus = 'sfx' end
    local v = clamp01(value)
    if v == nil then return nil, 'volume must be 0..1' end
    if bus ~= 'master' and bus ~= 'sfx' and bus ~= 'music' then
        return nil, 'unknown bus'
    end
    self.volume[bus] = v
    self.dirty = true
    return v
end

function OptionsMT:getVolume(bus)
    bus = tostring(bus or ''):lower()
    if bus == 'sound' then bus = 'sfx' end
    return self.volume[bus]
end

function OptionsMT:getVolumes()
    return {
        master = self.volume.master,
        sfx = self.volume.sfx,
        music = self.volume.music,
    }
end

-- Effective gain for a bus (master * bus).
function OptionsMT:effectiveVolume(bus)
    bus = tostring(bus or 'sfx'):lower()
    if bus == 'sound' then bus = 'sfx' end
    local m = self.volume.master or 1
    if bus == 'master' then return m end
    return m * (self.volume[bus] or 1)
end

--[[
    Push volume state into asset modules when they are available. Safe headless:
    require is pcall'd; missing audio is a no-op.
]]
function OptionsMT:applyAudio()
    local master = self.volume.master or 1
    local sfx = (self.volume.sfx or 1) * master
    local music = (self.volume.music or 1) * master

    local okS, Sound = pcall(require, 'meatray.asset.sound')
    if okS and Sound and Sound.setMasterVolume then
        Sound.setMasterVolume(sfx)
    end
    local okM, Music = pcall(require, 'meatray.asset.music')
    if okM and Music and Music.setVolume then
        Music.setVolume(music)
    end
    return { sfx = sfx, music = music, master = master }
end

---------------------------------------------------------------------------
-- Graphics
---------------------------------------------------------------------------

local function clampRange(v, lo, hi)
    v = tonumber(v)
    if not v or v ~= v then return nil end
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

-- Does the current field set match a named preset exactly?
local function presetMatching(g)
    for name, p in pairs(Options.QUALITY_PRESETS) do
        if math.abs((g.scale or 1) - p.scale) < 1e-9
           and (g.floorCast and true or false) == p.floorCast
           and (g.lightTexture and true or false) == p.lightTexture then
            return name
        end
    end
    return 'custom'
end

--[[
    Sets any subset of { scale, fov, pitchLimit, floorCast, lightTexture,
    quality }. Every numeric field is clamped rather than rejected: these
    arrive from a settings screen, a config file a player edited by hand, and
    a save from a build with different limits, and a silently sane value is
    the right answer for all three.

    `quality` is applied first so an explicit field in the same call wins over
    the preset it came with.
]]
function OptionsMT:setGraphics(t)
    if type(t) ~= 'table' then return nil, 'table required' end
    local g = self.graphics

    if t.quality ~= nil then
        local preset = Options.QUALITY_PRESETS[tostring(t.quality):lower()]
        if preset then
            g.scale = preset.scale
            g.floorCast = preset.floorCast
            g.lightTexture = preset.lightTexture
        end
    end

    if t.scale ~= nil then
        g.scale = clampRange(t.scale, Options.SCALE_MIN, Options.SCALE_MAX) or g.scale
    end
    if t.fov ~= nil then
        g.fov = clampRange(t.fov, Options.FOV_MIN, Options.FOV_MAX) or g.fov
    end
    if t.pitchLimit ~= nil then
        g.pitchLimit = clampRange(t.pitchLimit, Options.PITCH_MIN, Options.PITCH_MAX)
                       or g.pitchLimit
    end
    if t.floorCast ~= nil then g.floorCast = t.floorCast and true or false end
    if t.lightTexture ~= nil then g.lightTexture = t.lightTexture and true or false end

    g.quality = presetMatching(g)
    self.dirty = true
    return self:getGraphics()
end

function OptionsMT:getGraphics()
    local g = self.graphics
    return {
        scale = g.scale, fov = g.fov, pitchLimit = g.pitchLimit,
        floorCast = g.floorCast, lightTexture = g.lightTexture,
        quality = g.quality,
    }
end

-- Convenience for a preset button.
function OptionsMT:setQuality(name)
    if not Options.QUALITY_PRESETS[tostring(name or ''):lower()] then
        return nil, 'unknown quality preset'
    end
    return self:setGraphics{ quality = name }
end

-- The renderer's number: half-width of the camera plane for the stored FOV.
function OptionsMT:fovPlane()
    return math.tan(math.rad(self.graphics.fov) / 2)
end

-- Pixel dimensions of the internal render buffer at the current scale. Never
-- returns zero: a 1x1 buffer is ugly, a 0-wide one is a crash.
function OptionsMT:renderSize(width, height)
    local s = self.graphics.scale or 1
    local w = math.max(1, math.floor((tonumber(width) or 0) * s + 0.5))
    local h = math.max(1, math.floor((tonumber(height) or 0) * s + 0.5))
    return w, h
end

--[[
    Push graphics state into the renderer when there is one. Safe headless for
    the same reason applyAudio is: the require is pcall'd, so a dedicated
    server calls this and nothing happens.

    Scale is deliberately NOT applied here. The other three are renderer state;
    scale is a decision about what surface the game draws into, which belongs
    to whoever owns the frame — see main.lua, which sizes its canvas from
    `renderSize`. Reporting it back keeps that caller honest about what it owes.
]]
function OptionsMT:applyGraphics()
    local g = self.graphics
    local applied = {
        scale = g.scale,
        fovPlane = self:fovPlane(),
        pitchLimit = g.pitchLimit,
        floorCast = g.floorCast,
        lightTexture = g.lightTexture,
        renderer = false,
    }

    local ok, Raycaster = pcall(require, 'meatray.render.raycaster')
    if ok and type(Raycaster) == 'table' then
        if Raycaster.setFovPlane then Raycaster.setFovPlane(applied.fovPlane) end
        if Raycaster.setMaxPitch then Raycaster.setMaxPitch(g.pitchLimit) end
        if Raycaster.setFloorCasting then Raycaster.setFloorCasting(g.floorCast) end
        if Raycaster.setLightTexture then Raycaster.setLightTexture(g.lightTexture) end
        applied.renderer = true
    end

    return applied
end

---------------------------------------------------------------------------
-- Snapshot / export
---------------------------------------------------------------------------

function OptionsMT:export()
    local binds = {}
    for action, keys in pairs(self.binds) do
        binds[action] = copyKeys(keys)
    end
    return {
        version = self.version or Options.VERSION,
        mouse = self:getMouse(),
        volume = self:getVolumes(),
        graphics = self:getGraphics(),
        binds = binds,
        extra = self.extra,
    }
end

function OptionsMT:import(data)
    if type(data) ~= 'table' then return false, 'table required' end
    if type(data.mouse) == 'table' then
        self:setMouse(data.mouse)
    end
    if type(data.volume) == 'table' then
        for _, bus in ipairs(Options.VOLUME_BUSES) do
            if data.volume[bus] ~= nil then
                self:setVolume(bus, data.volume[bus])
            end
        end
    end
    if type(data.graphics) == 'table' then
        self:setGraphics(data.graphics)
    end
    if type(data.binds) == 'table' then
        for action, keys in pairs(data.binds) do
            self.binds[tostring(action)] = copyKeys(keys)
        end
    end
    if type(data.extra) == 'table' then
        self.extra = {}
        for k, v in pairs(data.extra) do self.extra[k] = v end
    end
    if data.version then self.version = tonumber(data.version) or self.version end
    self.dirty = true
    return true
end

---------------------------------------------------------------------------
-- Serialize (line format)
---------------------------------------------------------------------------

function OptionsMT:serialize()
    local lines = {
        '# MeatRayCast options — edit freely; unknown keys are preserved',
        'version=' .. tostring(self.version or Options.VERSION),
        ('mouse.sensitivity=%s'):format(tostring(self.mouse.sensitivity)),
        ('mouse.invertY=%s'):format(self.mouse.invertY and 'true' or 'false'),
        ('volume.master=%s'):format(tostring(self.volume.master)),
        ('volume.sfx=%s'):format(tostring(self.volume.sfx)),
        ('volume.music=%s'):format(tostring(self.volume.music)),
        ('graphics.scale=%s'):format(tostring(self.graphics.scale)),
        ('graphics.fov=%s'):format(tostring(self.graphics.fov)),
        ('graphics.pitchLimit=%s'):format(tostring(self.graphics.pitchLimit)),
        ('graphics.floorCast=%s'):format(self.graphics.floorCast and 'true' or 'false'),
        ('graphics.lightTexture=%s'):format(
            self.graphics.lightTexture and 'true' or 'false'),
        -- Written for the human reading the file, and re-derived on load from
        -- the fields above rather than trusted: an edited scale with a stale
        -- `quality=high` beside it must not report itself as high.
        ('graphics.quality=%s'):format(tostring(self.graphics.quality)),
    }
    local actions = self:actions()
    for i = 1, #actions do
        local action = actions[i]
        local keys = self.binds[action] or {}
        if #keys == 0 then
            lines[#lines + 1] = ('bind.%s='):format(action)
        else
            for j = 1, #keys do
                lines[#lines + 1] = ('bind.%s=%s'):format(action, keys[j])
            end
        end
    end
    local extraKeys = {}
    for k in pairs(self.extra or {}) do extraKeys[#extraKeys + 1] = k end
    table.sort(extraKeys)
    for i = 1, #extraKeys do
        local k = extraKeys[i]
        lines[#lines + 1] = ('extra.%s=%s'):format(k, tostring(self.extra[k]))
    end
    return table.concat(lines, '\n') .. '\n'
end

function OptionsMT:deserialize(text)
    if type(text) ~= 'string' then return false, 'string required' end
    local newBinds = {}
    local sawBind = false
    -- Whether the file spelled out the individual graphics fields. If it did,
    -- they are the truth and a `quality` line beside them is only a label.
    local sawGraphicsField = false
    for line in (text .. '\n'):gmatch('(.-)\n') do
        line = trim(line)
        if line ~= '' and not line:match('^#') then
            local key, val = line:match('^([^=]+)=(.*)$')
            if key then
                key, val = trim(key), trim(val)
                if key == 'version' then
                    self.version = tonumber(val) or self.version
                elseif key == 'mouse.sensitivity' then
                    local s = tonumber(val)
                    if s and s > 0 then self.mouse.sensitivity = s end
                elseif key == 'mouse.invertY' then
                    local b = parseBool(val)
                    if b ~= nil then self.mouse.invertY = b end
                elseif key == 'volume.master' or key == 'volume.sfx'
                    or key == 'volume.music' or key == 'volume.sound' then
                    local bus = key:match('^volume%.(.+)$')
                    if bus == 'sound' then bus = 'sfx' end
                    local v = clamp01(val)
                    if v ~= nil then self.volume[bus] = v end
                elseif key:sub(1, 9) == 'graphics.' then
                    local field = key:sub(10)
                    if field == 'floorCast' or field == 'lightTexture' then
                        local b = parseBool(val)
                        if b ~= nil then
                            sawGraphicsField = true
                            self:setGraphics{ [field] = b }
                        end
                    elseif field == 'quality' then
                        -- Applied only if the file did not also carry the
                        -- fields; setGraphics re-derives the name either way.
                        if Options.QUALITY_PRESETS[val:lower()] and not sawGraphicsField then
                            self:setGraphics{ quality = val }
                        end
                    elseif field == 'scale' or field == 'fov'
                        or field == 'pitchLimit' then
                        sawGraphicsField = true
                        local n = tonumber(val)
                        if n then self:setGraphics{ [field] = n } end
                    else
                        self.extra[key] = val
                    end
                elseif key:sub(1, 5) == 'bind.' then
                    local action = key:sub(6)
                    if action ~= '' then
                        sawBind = true
                        newBinds[action] = newBinds[action] or {}
                        if val ~= '' then
                            newBinds[action][#newBinds[action] + 1] = val:lower()
                        end
                    end
                elseif key:sub(1, 6) == 'extra.' then
                    self.extra[key:sub(7)] = val
                else
                    self.extra[key] = val
                end
            end
        end
    end
    if sawBind then
        -- Replace known actions from file; keep defaults for missing actions.
        local defaults = defaultBinds()
        for action, keys in pairs(defaults) do
            if newBinds[action] then
                self.binds[action] = newBinds[action]
            else
                self.binds[action] = keys
            end
        end
        for action, keys in pairs(newBinds) do
            if not self.binds[action] then
                self.binds[action] = keys
            end
        end
    end
    self.dirty = false
    return true
end

---------------------------------------------------------------------------
-- Persistence via storage backend
---------------------------------------------------------------------------

function OptionsMT:save(storage, path)
    path = path or self.path or Options.DEFAULT_PATH
    if not storage or not storage.write then
        return nil, 'storage backend required'
    end
    local bytes = self:serialize()
    local dir = path:match('^(.+)/[^/]+$') or path:match('^(.+)\\[^\\]+$')
    if dir and storage.mkdir then
        storage.mkdir(dir)
    end
    local ok, err = storage.write(path, bytes)
    if not ok then return nil, err end
    self.dirty = false
    self.path = path
    return true
end

function OptionsMT:load(storage, path)
    path = path or self.path or Options.DEFAULT_PATH
    if not storage or not storage.read then
        return nil, 'storage backend required'
    end
    local bytes, err = storage.read(path)
    if not bytes then return nil, err or 'missing options file' end
    local ok, derr = self:deserialize(bytes)
    if not ok then return nil, derr end
    self.path = path
    self.dirty = false
    return true
end

---------------------------------------------------------------------------
-- Options menu model (UI-agnostic rows for a settings screen)
---------------------------------------------------------------------------

--[[
    Returns ordered rows a UI can render:

      { id, kind, label, value, ... }

    kind: 'bind' | 'slider' | 'toggle'
]]
function OptionsMT:menuRows()
    local rows = {
        {
            id = 'mouse.sensitivity',
            kind = 'slider',
            label = 'Mouse Sensitivity',
            value = self.mouse.sensitivity,
            min = 0.0005,
            max = 0.02,
            step = 0.0005,
        },
        {
            id = 'mouse.invertY',
            kind = 'toggle',
            label = 'Invert Y',
            value = self.mouse.invertY and true or false,
        },
        {
            id = 'volume.master',
            kind = 'slider',
            label = 'Master Volume',
            value = self.volume.master,
            min = 0, max = 1, step = 0.05,
        },
        {
            id = 'volume.sfx',
            kind = 'slider',
            label = 'SFX Volume',
            value = self.volume.sfx,
            min = 0, max = 1, step = 0.05,
        },
        {
            id = 'volume.music',
            kind = 'slider',
            label = 'Music Volume',
            value = self.volume.music,
            min = 0, max = 1, step = 0.05,
        },
        {
            id = 'graphics.quality',
            kind = 'choice',
            label = 'Quality',
            value = self.graphics.quality,
            choices = Options.QUALITY_PICKABLE,
        },
        {
            id = 'graphics.scale',
            kind = 'slider',
            label = 'Render Scale',
            value = self.graphics.scale,
            min = Options.SCALE_MIN, max = Options.SCALE_MAX, step = 0.05,
        },
        {
            id = 'graphics.fov',
            kind = 'slider',
            label = 'Field of View',
            value = self.graphics.fov,
            min = Options.FOV_MIN, max = Options.FOV_MAX, step = 1,
        },
        {
            id = 'graphics.pitchLimit',
            kind = 'slider',
            label = 'Look Up/Down Limit',
            value = self.graphics.pitchLimit,
            min = Options.PITCH_MIN, max = Options.PITCH_MAX, step = 0.05,
        },
        {
            id = 'graphics.floorCast',
            kind = 'toggle',
            label = 'Textured Floors',
            value = self.graphics.floorCast and true or false,
        },
        {
            id = 'graphics.lightTexture',
            kind = 'toggle',
            label = 'Per-Pixel Floor Light',
            value = self.graphics.lightTexture and true or false,
        },
    }
    local actions = self:actions()
    for i = 1, #actions do
        local a = actions[i]
        rows[#rows + 1] = {
            id = 'bind.' .. a,
            kind = 'bind',
            label = self:labelOf(a),
            action = a,
            value = copyKeys(self.binds[a]),
        }
    end
    return rows
end

-- Apply a menu adjustment by row id. For sliders, delta is multiplied by step.
function OptionsMT:menuSet(id, value)
    id = tostring(id or '')
    if id == 'mouse.sensitivity' then
        self:setMouse{ sensitivity = value }
        return true
    end
    if id == 'mouse.invertY' then
        self:setMouse{ invertY = value and true or false }
        return true
    end
    if id == 'volume.master' or id == 'volume.sfx' or id == 'volume.music' then
        local bus = id:match('^volume%.(.+)$')
        return self:setVolume(bus, value) ~= nil
    end
    if id:sub(1, 9) == 'graphics.' then
        local field = id:sub(10)
        if field == 'quality' then
            return self:setQuality(value) ~= nil
        end
        if field == 'scale' or field == 'fov' or field == 'pitchLimit' then
            return self:setGraphics{ [field] = value } ~= nil
        end
        if field == 'floorCast' or field == 'lightTexture' then
            return self:setGraphics{ [field] = value and true or false } ~= nil
        end
        return false, 'unknown graphics field'
    end
    if id:sub(1, 5) == 'bind.' then
        local action = id:sub(6)
        if type(value) == 'table' then
            self.binds[action] = copyKeys(value)
            self.dirty = true
            return true
        end
        return self:setBind(action, value)
    end
    return false, 'unknown menu id'
end

function OptionsMT:menuNudge(id, direction)
    direction = direction or 1
    local rows = self:menuRows()
    for i = 1, #rows do
        local r = rows[i]
        if r.id == id then
            if r.kind == 'toggle' then
                return self:menuSet(id, not r.value)
            end
            if r.kind == 'slider' then
                local step = r.step or 0.05
                local v = (r.value or 0) + direction * step
                if r.min and v < r.min then v = r.min end
                if r.max and v > r.max then v = r.max end
                return self:menuSet(id, v)
            end
            if r.kind == 'choice' then
                -- Cycles the named presets and skips 'custom', which is a
                -- report about the other fields rather than a thing to pick.
                local pickable = {}
                for _, name in ipairs(r.choices or {}) do
                    if name ~= 'custom' then pickable[#pickable + 1] = name end
                end
                if #pickable == 0 then return false, 'no choices' end
                local at = 1
                for k = 1, #pickable do
                    if pickable[k] == r.value then at = k break end
                end
                local nextAt = ((at - 1 + direction) % #pickable) + 1
                return self:menuSet(id, pickable[nextAt])
            end
            return false, 'bind rows need menuSet with a key'
        end
    end
    return false, 'unknown menu id'
end

return Options
