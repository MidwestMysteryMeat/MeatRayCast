--[[
    meatray.asset.sfx — parametric sound-effect synthesis, headless.

    The engine's standing constraint is that it runs with zero media, and until
    now that meant sound effects were silence until an author dropped a WAV in
    from an external tool. This module closes that gap the way sfxr did for game
    jams: a small set of tunable parameters (waveform, pitch and its slide, an
    attack/sustain/decay envelope, vibrato, an arpeggio hop, retro noise) renders
    to PCM samples, and the WAV writer turns those into a file the existing
    sound pipeline loads like any other asset.

    Everything here is deterministic. Noise comes from the engine LCG seeded by
    the params table — never math.random — so the same params render the same
    bytes on every machine and every interpreter, which is what lets a test
    assert on a checksum and lets a project commit params instead of binaries.

    Layering, same shape as the rest of meatray.asset:

        params     plain data, serializable, the thing a project saves
        render     params -> float samples, pure math
        wav        samples -> RIFF/PCM16 bytes, pure string building
        presets    named starting points + a seeded randomizer for variations

    No host anywhere: the editor panel and the CLI both call this; LÖVE only
    enters the picture when the produced WAV is played back.
]]

local Worldgen = require('meatray.sim.worldgen')

local floor, abs, sin, pi = math.floor, math.abs, math.sin, math.pi

local Sfx = {}

Sfx.SAMPLE_RATE = 22050

---------------------------------------------------------------------------
-- Parameters
---------------------------------------------------------------------------

local WAVES = { square = true, saw = true, sine = true, triangle = true, noise = true }

-- Every field, its default, and the range it is clamped into. One table so
-- defaults(), normalize() and the editor's slider rows can never disagree
-- about what a parameter is allowed to be.
local FIELDS = {
    { key = 'freq',         def = 440,  lo = 20,    hi = 4000 }, -- Hz at note start
    { key = 'freqSlide',    def = 0,    lo = -8000, hi = 8000 }, -- Hz per second
    { key = 'freqLimit',    def = 20,   lo = 20,    hi = 4000 }, -- a downward slide ends the note here
    { key = 'duty',         def = 0.5,  lo = 0.05,  hi = 0.95 }, -- square pulse width
    { key = 'dutySweep',    def = 0,    lo = -2,    hi = 2 },    -- duty per second
    { key = 'attack',       def = 0,    lo = 0,     hi = 1 },    -- seconds
    { key = 'sustain',      def = 0.1,  lo = 0,     hi = 2 },
    { key = 'decay',        def = 0.2,  lo = 0,     hi = 3 },
    { key = 'punch',        def = 0,    lo = 0,     hi = 1 },    -- extra gain at sustain start
    { key = 'vibratoDepth', def = 0,    lo = 0,     hi = 200 },  -- Hz
    { key = 'vibratoSpeed', def = 0,    lo = 0,     hi = 30 },   -- Hz
    { key = 'arpMod',       def = 0,    lo = -4,    hi = 4 },    -- freq multiplier, 0 = off
    { key = 'arpTime',      def = 0,    lo = 0,     hi = 2 },    -- seconds until the hop
    { key = 'gain',         def = 0.6,  lo = 0,     hi = 1 },
    { key = 'seed',         def = 1,    lo = 1,     hi = 4294967295 }, -- noise stream
}

function Sfx.defaults()
    local p = { wave = 'square' }
    for _, f in ipairs(FIELDS) do p[f.key] = f.def end
    return p
end

function Sfx.fields() return FIELDS end

-- Refuses what cannot be rendered, clamps what merely wandered. Returns a fresh
-- normalized table (never mutates the input — the editor holds the original)
-- or nil and a reason.
function Sfx.normalize(params)
    if type(params) ~= 'table' then return nil, 'params must be a table' end
    local wave = params.wave or 'square'
    if not WAVES[wave] then return nil, ('unknown wave: %s'):format(tostring(wave)) end

    local p = { wave = wave }
    for _, f in ipairs(FIELDS) do
        local v = tonumber(params[f.key])
        if v == nil then v = f.def end
        if v < f.lo then v = f.lo elseif v > f.hi then v = f.hi end
        p[f.key] = v
    end

    -- A sound with no envelope at all is zero samples; give it the one thing
    -- that makes it audible rather than rendering an empty file.
    if p.attack + p.sustain + p.decay <= 0 then p.decay = 0.05 end
    return p
end

function Sfx.duration(params)
    local p, err = Sfx.normalize(params)
    if not p then return nil, err end
    return p.attack + p.sustain + p.decay
end

---------------------------------------------------------------------------
-- Rendering
---------------------------------------------------------------------------

-- params -> array of floats in [-1, 1]. Pure: same params, same samples.
function Sfx.render(params, sampleRate)
    local p, err = Sfx.normalize(params)
    if not p then return nil, err end
    local rate = sampleRate or Sfx.SAMPLE_RATE
    local dt = 1 / rate

    local total = p.attack + p.sustain + p.decay
    local count = floor(total * rate)
    local rng = Worldgen.rng(p.seed)

    local samples = {}
    local phase = 0
    local noiseValue = rng:float() * 2 - 1

    for i = 1, count do
        local t = (i - 1) * dt

        -- Pitch: base + linear slide, an arpeggio hop after arpTime, vibrato on
        -- top. The slide can drive the pitch below the floor; when it does the
        -- note is over (the classic laser tail) rather than aliasing forever.
        local freq = p.freq + p.freqSlide * t
        if p.arpMod ~= 0 and t >= p.arpTime and p.arpTime > 0 then
            freq = freq * p.arpMod
        end
        if p.vibratoDepth > 0 then
            freq = freq + sin(2 * pi * p.vibratoSpeed * t) * p.vibratoDepth
        end
        if freq < p.freqLimit then
            if p.freqSlide < 0 then break end
            freq = p.freqLimit
        end

        -- Envelope.
        local env
        if t < p.attack then
            env = t / p.attack
        elseif t < p.attack + p.sustain then
            local into = (t - p.attack) / (p.sustain > 0 and p.sustain or 1)
            env = 1 + p.punch * (1 - into)
        else
            local into = (t - p.attack - p.sustain) / (p.decay > 0 and p.decay or 1)
            env = 1 - into
            if env < 0 then env = 0 end
        end

        -- Oscillator. Noise is the retro kind: a random level HELD for a whole
        -- oscillator period, so pitch shapes it the way it shaped a PSG.
        local prev = phase
        phase = phase + freq * dt
        local frac = phase - floor(phase)
        local out
        if p.wave == 'square' then
            local duty = p.duty + p.dutySweep * t
            if duty < 0.05 then duty = 0.05 elseif duty > 0.95 then duty = 0.95 end
            out = frac < duty and 1 or -1
        elseif p.wave == 'saw' then
            out = 2 * frac - 1
        elseif p.wave == 'sine' then
            out = sin(2 * pi * frac)
        elseif p.wave == 'triangle' then
            out = 4 * abs(frac - 0.5) - 1
        else -- noise
            if floor(phase) > floor(prev) then
                noiseValue = rng:float() * 2 - 1
            end
            out = noiseValue
        end

        local s = out * env * p.gain
        if s > 1 then s = 1 elseif s < -1 then s = -1 end
        samples[i] = s
    end

    return samples, rate
end

---------------------------------------------------------------------------
-- WAV encoding — RIFF, PCM16, mono, hand-packed little-endian so it works
-- identically on LuaJIT (no string.pack) and PUC Lua.
---------------------------------------------------------------------------

local char = string.char

local function u16(n)
    n = n % 65536
    return char(n % 256, floor(n / 256))
end

local function u32(n)
    n = n % 4294967296
    return char(n % 256, floor(n / 256) % 256, floor(n / 65536) % 256, floor(n / 16777216) % 256)
end

-- samples -> the complete bytes of a .wav file.
function Sfx.encodeWav(samples, sampleRate)
    local rate = sampleRate or Sfx.SAMPLE_RATE
    local n = #samples
    local parts = {}
    for i = 1, n do
        local s = samples[i]
        if s > 1 then s = 1 elseif s < -1 then s = -1 end
        local v = floor(s * 32767 + 0.5)
        if v < 0 then v = v + 65536 end
        parts[i] = u16(v)
    end
    local data = table.concat(parts)

    return table.concat{
        'RIFF', u32(36 + #data), 'WAVE',
        'fmt ', u32(16),
        u16(1),          -- PCM
        u16(1),          -- mono
        u32(rate),
        u32(rate * 2),   -- byte rate
        u16(2),          -- block align
        u16(16),         -- bits per sample
        'data', u32(#data),
        data,
    }
end

-- params -> WAV bytes in one step; what the editor's save button calls.
function Sfx.wav(params, sampleRate)
    local samples, rateOrErr = Sfx.render(params, sampleRate)
    if not samples then return nil, rateOrErr end
    return Sfx.encodeWav(samples, rateOrErr)
end

---------------------------------------------------------------------------
-- Presets — named starting points, each a complete params table.
---------------------------------------------------------------------------

local PRESETS = {
    pickup = { wave = 'square', freq = 1046, sustain = 0.04, decay = 0.25,
               punch = 0.4, arpMod = 1.5, arpTime = 0.06, gain = 0.5 },
    laser = { wave = 'saw', freq = 1200, freqSlide = -6000, freqLimit = 200,
              sustain = 0.05, decay = 0.15, gain = 0.5 },
    explosion = { wave = 'noise', freq = 900, freqSlide = -1400, freqLimit = 60,
                  sustain = 0.15, decay = 0.7, punch = 0.5, gain = 0.7, seed = 7 },
    hurt = { wave = 'saw', freq = 300, freqSlide = -900, freqLimit = 80,
             sustain = 0.03, decay = 0.12, gain = 0.55 },
    jump = { wave = 'square', freq = 330, freqSlide = 900, sustain = 0.08,
             decay = 0.2, duty = 0.35, gain = 0.45 },
    powerup = { wave = 'triangle', freq = 440, freqSlide = 1200, sustain = 0.2,
                decay = 0.3, vibratoDepth = 30, vibratoSpeed = 12, gain = 0.5 },
    blip = { wave = 'square', freq = 700, sustain = 0.02, decay = 0.06, gain = 0.4 },
    step = { wave = 'noise', freq = 500, freqSlide = -2000, freqLimit = 100,
             decay = 0.08, gain = 0.3, seed = 3 },
}

function Sfx.presetNames()
    local names = {}
    for name in pairs(PRESETS) do names[#names + 1] = name end
    table.sort(names)
    return names
end

function Sfx.preset(name)
    local base = PRESETS[name]
    if not base then return nil, ('unknown preset: %s'):format(tostring(name)) end
    local p = Sfx.defaults()
    for k, v in pairs(base) do p[k] = v end
    return Sfx.normalize(p)
end

-- A seeded variation on a preset: same character, different voice. The seed is
-- the whole identity of the variation — randomize('pickup', 42) is one sound,
-- forever, on every machine.
function Sfx.randomize(name, seed)
    local p, err = Sfx.preset(name)
    if not p then return nil, err end
    local rng = Worldgen.rng(seed or 1)
    local function jitter(v, spread) return v * (1 + (rng:float() * 2 - 1) * spread) end
    p.freq = jitter(p.freq, 0.25)
    p.freqSlide = jitter(p.freqSlide, 0.3)
    p.sustain = jitter(p.sustain, 0.3)
    p.decay = jitter(p.decay, 0.3)
    p.duty = jitter(p.duty, 0.2)
    if p.wave == 'noise' then p.seed = rng:int(1, 1000000) end
    return Sfx.normalize(p)
end

return Sfx
