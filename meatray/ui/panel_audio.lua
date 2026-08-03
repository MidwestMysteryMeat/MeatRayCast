--[[
    Audio panel — sound-effect authoring inside the editor shell.

    The synth itself (meatray.asset.sfx) is headless and tested; this panel is
    the thin host-side face on it: pick a preset, scrub a seed until the
    variation sounds right, listen, and save the WAV where the project's sound
    pipeline will find it. The saved file is an ordinary asset from that moment
    on — declareSound/importSound neither know nor care that it was synthesized
    in-engine rather than dropped in from outside.

    The seed is the design decision here: a variation is (preset, seed), which
    is reproducible forever, so "that pickup sound but slightly lower" is a
    number an author can write down, not a file only one machine ever made.

    Panel contract (see shell.lua): id, title, draw, drawSidebar, no update.
]]

local UI = require('meatray.ui.core')
local Platform = require('meatray.platform')
local Sfx = require('meatray.asset.sfx')

local Panel = {}
Panel.__index = Panel

local PREVIEW_PATH = 'sfx_preview.wav'

function Panel.new(opts)
    opts = opts or {}
    return setmetatable({
        id = 'audio',
        title = 'Audio',
        presets = Sfx.presetNames(),
        sel = 1,
        seed = 0,           -- 0 = the preset itself; anything else a variation
        -- H1: with a project, saves land in its assets/sounds on the real
        -- disk. Without one, Platform.fs puts them in the LÖVE save dir.
        fs = opts.fs or Platform.fs,
        soundsDir = opts.soundsDir or 'assets/sounds',
        samples = nil,      -- cached render of the current (preset, seed)
        cachedKey = nil,
        source = nil,       -- the playing preview, so replay restarts it
    }, Panel)
end

function Panel:attach(shell)
    self.shell = shell
end

---------------------------------------------------------------------------
-- The current sound
---------------------------------------------------------------------------

function Panel:params()
    local name = self.presets[self.sel]
    if self.seed > 0 then
        return Sfx.randomize(name, self.seed)
    end
    return Sfx.preset(name)
end

function Panel:currentSamples()
    local key = self.presets[self.sel] .. '#' .. self.seed
    if self.cachedKey ~= key then
        self.samples = Sfx.render(self:params())
        self.cachedKey = key
    end
    return self.samples
end

function Panel:fileName()
    local name = self.presets[self.sel]
    if self.seed > 0 then name = name .. '_' .. self.seed end
    return name .. '.wav'
end

---------------------------------------------------------------------------
-- Actions
---------------------------------------------------------------------------

function Panel:play()
    if not (Platform.audio and Platform.audio.available and Platform.audio.available()) then
        if self.shell then self.shell:warn('no audio device') end
        return false
    end
    -- Through the save-dir sandbox on purpose: the preview is scratch, and
    -- newSource reads from the sandbox. Only an explicit Save touches the
    -- project.
    local bytes = Sfx.wav(self:params())
    Platform.fs.write(PREVIEW_PATH, bytes)
    if self.source then pcall(function() self.source:stop() end) end
    self.source = Platform.audio.newSource(PREVIEW_PATH, 'static')
    if self.source then self.source:play() end
    return self.source ~= nil
end

function Panel:save()
    local bytes = Sfx.wav(self:params())
    local path = self.soundsDir .. '/' .. self:fileName()
    local ok, err = self.fs.write(path, bytes)
    if not ok and self.fs.createDirectory then
        -- First save into a fresh project: make the folder and retry once.
        self.fs.createDirectory(self.soundsDir)
        ok, err = self.fs.write(path, bytes)
    end
    if self.shell then
        if ok then
            self.shell:ok(('saved %s (%d bytes) — declare it with Asset.importSound')
                :format(path, #bytes))
        else
            self.shell:error(('could not write %s: %s'):format(path, tostring(err)))
        end
    end
    return ok
end

---------------------------------------------------------------------------
-- Drawing
---------------------------------------------------------------------------

-- The waveform, as one min/max column per pixel — the familiar audio-editor
-- picture, and enough to see the envelope and the cut tail at a glance.
function Panel:draw(rect)
    local samples = self:currentSamples() or {}
    local n = #samples
    local midY = rect.y + rect.h * 0.5
    local half = rect.h * 0.45

    UI.rect(rect.x, rect.y, rect.w, rect.h, UI.theme.bg, 'fill')

    if n == 0 then
        UI.text('nothing rendered', rect.x + 8, rect.y + 8, UI.theme.warn)
        return
    end

    local cols = math.max(1, rect.w - 16)
    local per = n / cols
    for c = 0, cols - 1 do
        local lo, hi = 1, -1
        local from = math.floor(c * per) + 1
        local to = math.min(n, math.floor((c + 1) * per) + 1)
        for i = from, to do
            local s = samples[i]
            if s < lo then lo = s end
            if s > hi then hi = s end
        end
        if hi >= lo then
            local x = rect.x + 8 + c
            UI.rect(x, midY - hi * half, 1, math.max(1, (hi - lo) * half), UI.theme.accent, 'fill')
        end
    end

    local p = self:params()
    UI.text(('%s   %.2fs   %d samples   wave %s  freq %d')
        :format(self:fileName(), Sfx.duration(p), n, p.wave, p.freq),
        rect.x + 8, rect.y + 6, UI.theme.text)
end

function Panel:drawSidebar(rect, shell)
    local y = rect.y
    local rowH = UI.metrics.rowHeight

    UI.text('Preset', rect.x, y, UI.theme.textDim); y = y + rowH
    for i, name in ipairs(self.presets) do
        if UI.button('audio/preset/' .. name,
                     (i == self.sel and '> ' or '  ') .. name,
                     rect.x, y, { w = rect.w - 4 }) then
            self.sel = i
        end
        y = y + rowH
    end
    y = y + 6

    UI.text('Variation seed (0 = preset)', rect.x, y, UI.theme.textDim); y = y + rowH
    local seed = UI.slider('audio/seed', self.seed, 0, 999, rect.x, y, rect.w - 8)
    self.seed = math.floor(seed + 0.5)
    y = y + rowH + 6

    if UI.button('audio/play', 'Play', rect.x, y, { w = rect.w - 4 }) then
        self:play()
    end
    y = y + rowH

    if UI.button('audio/save', 'Save WAV', rect.x, y, { w = rect.w - 4 }) then
        self:save()
    end
    y = y + rowH + 6

    UI.text('saves to ' .. self.soundsDir .. '/', rect.x, y, UI.theme.textDim)
end

return Panel
