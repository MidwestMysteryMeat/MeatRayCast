--[[
    Soundtrack bus: declare, play, crossfade, stop — headless logical state.
]]

return function(t)
    local Registry = require('meatray.asset.registry')
    local Music = require('meatray.asset.music')

    local function reset()
        Music._reset()
        Registry.clearAll()
        -- Music resolves through the registry; no real audio host under LuaJIT.
        Registry.setLoader('music', function(record)
            if not record.path or record.path == '' then
                return nil, 'no path'
            end
            -- Fake stream handle: enough for control-flow tests.
            return { path = record.path, kind = 'stream' }
        end)
    end

    ---------------------------------------------------------------------
    t.describe('declare and play (logical)')

    reset()
    Music.declare('theme', { path = 'assets/music/theme.wav', volume = 0.8 })
    t.ok(Music.declared('theme'), 'theme is declared')
    t.eq(Music.play('theme'), 'theme', 'play returns the track name')
    t.eq(Music.current(), 'theme', 'current reports it')
    t.ok(Music.isPlaying(), 'logical isPlaying without a device')

    Music.setVolume(0.5)
    t.eq(Music.getVolume(), 0.5, 'bus volume sticks')

    ---------------------------------------------------------------------
    t.describe('crossfade steps volume over time')

    reset()
    Music.declare('a', { path = 'assets/music/a.wav' })
    Music.declare('b', { path = 'assets/music/b.wav' })
    Music.play('a')
    Music.crossfade('b', 1.0)
    t.eq(Music.current(), 'b', 'crossfade targets the new track')

    local dbg = Music._debugState()
    t.ok(dbg.outgoing ~= nil, 'outgoing holds the previous track')
    t.eq(dbg.outgoing.name, 'a', 'outgoing is a')
    t.ok((dbg.current.volume or 0) < 0.5, 'new track starts faded in')

    for _ = 1, 20 do Music.update(0.1) end
    dbg = Music._debugState()
    t.near(dbg.current.volume, 1, 0.05, 'new track reaches full volume')
    t.eq(dbg.outgoing, nil, 'outgoing finished and cleared')

    ---------------------------------------------------------------------
    t.describe('stop with fade')

    reset()
    Music.declare('theme', { path = 'assets/music/theme.wav' })
    Music.play('theme')
    Music.stop({ fade = 0.5 })
    t.eq(Music.current(), nil, 'current clears when fading out')
    dbg = Music._debugState()
    t.ok(dbg.outgoing ~= nil, 'outgoing still audible while fading')
    for _ = 1, 10 do Music.update(0.1) end
    dbg = Music._debugState()
    t.eq(dbg.outgoing, nil, 'fade-out completes')

    ---------------------------------------------------------------------
    t.describe('pause and resume')

    reset()
    Music.declare('theme', { path = 'assets/music/theme.wav' })
    Music.play('theme')
    Music.pause()
    t.ok(Music.isPaused(), 'paused')
    t.ok(not Music.isPlaying(), 'not playing while paused')
    Music.resume()
    t.ok(not Music.isPaused(), 'resumed')
    t.ok(Music.isPlaying(), 'playing again')

    ---------------------------------------------------------------------
    t.describe('missing track is silent, not an error')

    reset()
    local ok, err = pcall(function()
        Music.play('never-declared')
    end)
    t.ok(ok, 'play of unknown name does not raise', tostring(err))
    t.eq(Music.current(), nil, 'and leaves current empty')
end
