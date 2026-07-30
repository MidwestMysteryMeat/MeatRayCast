--[[
    meatray.asset.sound — the sound registry and positional playback.

    WAV only, because LÖVE decodes WAV natively and importing one therefore adds
    no dependency. Claiming OGG support that rests on a decoder a given build may
    not have is worse than not claiming it.

    Two rules shape everything here.

    **Missing audio is silent, never an error.** Every entry point returns nil and
    does nothing when there is no audio host, no such sound, or no file behind
    it. A game that plays a footstep in its movement code must not crash on a
    machine with no audio device, and must not need a `if Sound then` at every
    call site to be safe.

    **Distance and pan are decided in meatray.asset.spatial**, which is headless
    and tested. This file only applies the two numbers it is handed. That split is
    what makes "the monster is panned to the wrong side" an assertion rather than
    an argument about what you think you heard.

    On panning: OpenAL positions mono sources only. A stereo WAV is already a
    stereo image and cannot be moved, so it plays at the computed volume and
    centred, and says so once rather than once per shot.
]]

local Platform = require('meatray.platform')
local Registry = require('meatray.asset.registry')
local Spatial = require('meatray.asset.spatial')

local Sound = {}

-- Overlapping playback needs one Source per voice, so the registry holds a
-- master Source and each play clones it. A cap keeps a bug in game code — a
-- footstep triggered every frame — from allocating without bound; the oldest
-- voice is stopped rather than the newest refused, because the newest is the one
-- the player just caused.
Sound.MAX_VOICES = 32

local voices = {}
local listener = nil
local masterVolume = 1
local warnedStereo = {}

---------------------------------------------------------------------------
-- Availability
---------------------------------------------------------------------------

-- False on a dedicated server, in the headless test runner, and on a machine
-- with no audio device. Everything below checks it.
function Sound.available()
    return Platform.available() and Platform.audio.available()
end

function Sound.setMasterVolume(v)
    masterVolume = math.max(0, math.min(1, tonumber(v) or 1))
    return masterVolume
end

function Sound.getMasterVolume() return masterVolume end

---------------------------------------------------------------------------
-- Loading and declaring
---------------------------------------------------------------------------

-- Reads a Source, returning nil plus a reason rather than raising.
function Sound.load(path, kind)
    if not Sound.available() then return nil, 'no audio module' end
    if not path or path == '' then return nil, 'no path given' end

    local info = Platform.fs.getInfo(path)
    if not info then return nil, ('file not found: %s'):format(path) end
    if info.type == 'directory' then
        return nil, ('%s is a directory, not a sound'):format(path)
    end

    -- The seam returns nil rather than raising when there is no device, which is
    -- what keeps the silent-fallback promise above true all the way down. The
    -- reason rides along as a second value so this call site can still say what
    -- went wrong.
    local source, why = Platform.audio.newSource(path, kind or 'static')
    if not source then
        return nil, ('could not decode %s: %s'):format(path, tostring(why))
    end
    return source
end

-- Registers a sound under a logical name.
--
--   Sound.declare('shot', { path = 'assets/sounds/shot.wav', volume = 0.8 })
--
-- Declaring with no path is legal and means "this sound exists in the design and
-- has no file yet" — it resolves to the `generated` state, plays nothing, and is
-- deliberately not counted as missing.
function Sound.declare(name, opts)
    opts = opts or {}
    return Registry.declare(name, 'sound', {
        path = opts.path,
        settings = {
            volume = opts.volume or 1,
            pitch = opts.pitch or 1,
            kind = opts.kind or 'static',
            ref = opts.ref, max = opts.max, rolloff = opts.rolloff,
            curve = opts.curve, panWidth = opts.panWidth,
        },
    })
end

function Sound.declared(name)
    return Registry.get(name, 'sound') ~= nil
end

function Sound.names() return Registry.list('sound') end

---------------------------------------------------------------------------
-- Listener
---------------------------------------------------------------------------

-- Where the ears are. Set once per frame from the camera; until it is set,
-- positional plays are flat and centred rather than silent.
function Sound.setListener(x, y, angle)
    listener = { x = x, y = y, angle = angle or 0 }
    return listener
end

function Sound.getListener() return listener end

function Sound.clearListener() listener = nil end

---------------------------------------------------------------------------
-- Voices
---------------------------------------------------------------------------

local function prune()
    for i = #voices, 1, -1 do
        local v = voices[i]
        if not v.source:isPlaying() then table.remove(voices, i) end
    end
end

local function claimVoice()
    prune()
    if #voices >= Sound.MAX_VOICES then
        local oldest = table.remove(voices, 1)
        pcall(function() oldest.source:stop() end)
    end
end

function Sound.voiceCount()
    prune()
    return #voices
end

function Sound.stopAll()
    for _, v in ipairs(voices) do pcall(function() v.source:stop() end) end
    voices = {}
end

---------------------------------------------------------------------------
-- Playback
---------------------------------------------------------------------------

local function startVoice(record, volume, pan, opts)
    local master = record.value
    if not master then return nil end

    claimVoice()

    -- clone() shares the decoded data and gives an independent playhead, which is
    -- what lets the same sound overlap itself. Re-playing the master instead
    -- restarts it and cuts off the shot you just fired.
    local ok, source = pcall(function() return master:clone() end)
    if not ok or not source then source = master end

    local settings = record.settings or {}
    local gain = volume * (settings.volume or 1) * (opts.volume or 1) * masterVolume
    gain = math.max(0, math.min(1, gain))

    pcall(function()
        source:setVolume(gain)
        source:setPitch(math.max(0.01, (settings.pitch or 1) * (opts.pitch or 1)))
        source:setLooping(opts.loop and true or false)
    end)

    if pan and pan ~= 0 then
        -- Relative positioning puts the listener at the origin, so the vector is
        -- purely a direction and nothing has to track the camera in world space.
        local ex, ey, ez = Spatial.toEar(pan)
        local placed = pcall(function()
            source:setRelative(true)
            source:setPosition(ex, ey, ez)
        end)
        if not placed and not warnedStereo[record.name] then
            warnedStereo[record.name] = true
            print(('[sound] %s is stereo, so it cannot be panned; playing centred')
                :format(record.name))
        end
    end

    local played = pcall(function() source:play() end)
    if not played then return nil end

    voices[#voices + 1] = { source = source, name = record.name }
    return source
end

-- Plays a sound flat, with no positioning. Returns the Source, or nil when there
-- is nothing to play — which includes every "missing audio" case.
function Sound.play(name, opts)
    if not Sound.available() then return nil end
    opts = opts or {}

    local record = Registry.resolve(name, 'sound')
    if not record or not record.value then return nil end

    return startVoice(record, 1, 0, opts)
end

-- Plays a sound at a world position, attenuated and panned for the current
-- listener.
--
-- A source past its cutoff distance is skipped entirely rather than started at
-- zero gain: silent voices still occupy the mixer and the voice cap, and the
-- whole reason the falloff curve reaches true zero is so this check can be made.
function Sound.playAt(name, x, y, opts)
    if not Sound.available() then return nil end
    opts = opts or {}

    local record = Registry.resolve(name, 'sound')
    if not record or not record.value then return nil end

    local settings = record.settings or {}
    local mix = {
        ref = opts.ref or settings.ref,
        max = opts.max or settings.max,
        rolloff = opts.rolloff or settings.rolloff,
        curve = opts.curve or settings.curve,
        panWidth = opts.panWidth or settings.panWidth,
    }

    local volume, pan = Spatial.mix(listener, x, y, mix)
    if volume <= 0 then return nil end

    return startVoice(record, volume, pan, opts)
end

-- What playAt would do, without playing it. The asset browser shows this so the
-- falloff settings can be understood before a sound is wired into gameplay.
--
-- The listener is a parameter rather than the module's own, on purpose: a preview
-- that set the global listener as a side effect of drawing would fight the game
-- for it, and a panel open beside a running level would silently move the ears
-- every frame.
function Sound.previewMix(name, x, y, from)
    local record = Registry.get(name, 'sound')
    local settings = record and record.settings or {}
    return Spatial.mix(from or listener, x, y, settings)
end

return Sound
