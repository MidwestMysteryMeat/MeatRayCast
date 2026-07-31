--[[
    meatray.asset.music — one looping soundtrack bus, separate from SFX.

    SFX use the voice pool in sound.lua (many short one-shots, positional).
    Music is different: at most a couple of long stream Sources, a dedicated
    volume bus, and crossfades between tracks. Mixing the two pools made every
    footstep fight the soundtrack for a voice slot.

    Rules (same spirit as sound.lua):

      * Missing audio is silent, never an error.
      * Streams use kind = 'stream' so long WAVs are not fully decoded up front.
      * Headless / no device: play/stop/update still advance logical state so
        games and tests can assert the playlist without a mixer.

    HEADLESS-safe for control flow; actual Sources only when Platform audio is up.
]]

local Platform = require('meatray.platform')
local Registry = require('meatray.asset.registry')

local Music = {}

local busVolume = 1
local current = nil   -- { name, source, volume, target, fade, fadingOut }
local outgoing = nil  -- track fading out during crossfade
local paused = false

function Music.available()
    return Platform.available() and Platform.audio.available()
end

function Music.setVolume(v)
    busVolume = math.max(0, math.min(1, tonumber(v) or 1))
    Music._applyGains()
    return busVolume
end

function Music.getVolume() return busVolume end

function Music.declare(name, opts)
    opts = opts or {}
    return Registry.declare(name, 'music', {
        path = opts.path,
        settings = {
            volume = opts.volume or 1,
            pitch = opts.pitch or 1,
            -- Streams by default: a three-minute theme must not allocate as static.
            kind = opts.kind or 'stream',
            loop = opts.loop ~= false,
        },
        pinned = opts.pinned,
    })
end

function Music.declared(name)
    return Registry.get(name, 'music') ~= nil
end

function Music.names() return Registry.list('music') end

local function trackGain(slot)
    if not slot then return 0 end
    local settings = slot.settings or {}
    local base = (settings.volume or 1) * (slot.volume or 1) * busVolume
    return math.max(0, math.min(1, base))
end

function Music._applyGains()
    if current and current.source then
        pcall(function() current.source:setVolume(trackGain(current)) end)
    end
    if outgoing and outgoing.source then
        pcall(function() outgoing.source:setVolume(trackGain(outgoing)) end)
    end
end

local function stopSlot(slot)
    if not slot then return end
    if slot.source then
        pcall(function() slot.source:stop() end)
        pcall(function()
            if slot.source.release then slot.source:release() end
        end)
    end
end

local function startSource(record, initialVol)
    if not Music.available() or not record or not record.value then
        return nil
    end
    local master = record.value
    local ok, source = pcall(function() return master:clone() end)
    if not ok or not source then source = master end

    local settings = record.settings or {}
    local vol = initialVol
    if vol == nil then vol = 1 end
    pcall(function()
        source:setLooping(settings.loop ~= false)
        source:setPitch(math.max(0.01, settings.pitch or 1))
        source:setVolume(vol)
        source:play()
    end)
    return source
end

local function makeSlot(name, fadeIn)
    local record = Registry.resolve(name, 'music')
    if not record then return nil end
    -- No path / failed load: still track logically so the game can query state.
    local settings = record.settings or {}
    local fading = fadeIn and fadeIn > 0
    local slot = {
        name = name,
        record = record,
        settings = settings,
        source = startSource(record, fading and 0 or 1),
        volume = fading and 0 or 1,
        target = 1,
        fade = fading and fadeIn or 0,
    }
    if slot.source and not fading then
        pcall(function() slot.source:setVolume(trackGain(slot)) end)
    end
    return slot
end

-- Play a track. opts.fade = seconds to fade in (0 = cut). Replaces the current
-- track; use crossfade to blend.
function Music.play(name, opts)
    opts = opts or {}
    if not name or name == '' then return nil end

    stopSlot(outgoing)
    outgoing = nil
    stopSlot(current)

    local fade = tonumber(opts.fade) or 0
    current = makeSlot(name, fade > 0 and fade or nil)
    paused = false
    Music._applyGains()
    return current and current.name or nil
end

-- Blend from the current track into `name` over `seconds` (default 1.5).
function Music.crossfade(name, seconds)
    seconds = tonumber(seconds) or 1.5
    if seconds < 0.05 then return Music.play(name) end
    if not name or name == '' then return nil end

    if current and current.name == name then
        current.target = 1
        current.fade = seconds
        return name
    end

    stopSlot(outgoing)
    if current then
        outgoing = current
        outgoing.target = 0
        outgoing.fade = seconds
    end
    current = makeSlot(name, seconds)
    paused = false
    Music._applyGains()
    return current and current.name or nil
end

function Music.stop(opts)
    opts = opts or {}
    local fade = tonumber(opts.fade) or 0
    if fade > 0 and current then
        current.target = 0
        current.fade = fade
        stopSlot(outgoing)
        outgoing = current
        current = nil
        return true
    end
    stopSlot(current)
    stopSlot(outgoing)
    current, outgoing = nil, nil
    paused = false
    return true
end

function Music.pause()
    paused = true
    if current and current.source then pcall(function() current.source:pause() end) end
    if outgoing and outgoing.source then pcall(function() outgoing.source:pause() end) end
end

function Music.resume()
    if not paused then return end
    paused = false
    if current and current.source then pcall(function() current.source:play() end) end
    if outgoing and outgoing.source then pcall(function() outgoing.source:play() end) end
end

function Music.isPaused() return paused end

function Music.current()
    return current and current.name or nil
end

function Music.isPlaying()
    if paused or not current then return false end
    if current.source then
        local ok, playing = pcall(function() return current.source:isPlaying() end)
        if ok then return playing end
    end
    -- Headless / no source: logical play state.
    return current ~= nil and (current.volume or 0) > 0
end

local function stepFade(slot, dt)
    if not slot or not slot.fade or slot.fade <= 0 then
        if slot then slot.volume = slot.target or slot.volume end
        return false
    end
    local target = slot.target or 1
    local speed = 1 / slot.fade
    if slot.volume < target then
        slot.volume = math.min(target, slot.volume + speed * dt)
    elseif slot.volume > target then
        slot.volume = math.max(target, slot.volume - speed * dt)
    end
    -- Fade complete when we reach the target.
    if math.abs(slot.volume - target) < 1e-4 then
        slot.volume = target
        slot.fade = 0
        return true
    end
    return false
end

-- Advance crossfades. Call once per frame (or tick) from the game loop.
function Music.update(dt)
    dt = tonumber(dt) or 0
    if dt < 0 then dt = 0 end
    if paused then return end

    if current then
        stepFade(current, dt)
    end
    if outgoing then
        local done = stepFade(outgoing, dt)
        if done and (outgoing.volume or 0) <= 0 then
            stopSlot(outgoing)
            outgoing = nil
        end
    end
    Music._applyGains()
end

-- Test / diagnostics.
function Music._debugState()
    return {
        current = current and {
            name = current.name, volume = current.volume, target = current.target,
            fade = current.fade, hasSource = current.source ~= nil,
        } or nil,
        outgoing = outgoing and {
            name = outgoing.name, volume = outgoing.volume, target = outgoing.target,
        } or nil,
        bus = busVolume,
        paused = paused,
    }
end

function Music._reset()
    stopSlot(current)
    stopSlot(outgoing)
    current, outgoing = nil, nil
    paused = false
    busVolume = 1
end

return Music
