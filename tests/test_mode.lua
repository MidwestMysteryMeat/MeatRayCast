--[[
    Thin game-mode lifecycle template.
]]

return function(t)
    local Mode = require('meatray.game.mode')

    ---------------------------------------------------------------------
    t.describe('lifecycle hooks')

    local log = {}
    local mode = Mode.new{
        name = 'dm',
        onStart = function(m, world, entities)
            log[#log + 1] = 'start:' .. tostring(world) .. ':' .. #entities
        end,
        onTick = function(m, dt)
            log[#log + 1] = ('tick:%.2f'):format(dt)
        end,
        onStop = function(m, reason)
            log[#log + 1] = 'stop:' .. reason
        end,
        onPlayerJoin = function(m, peer, entity)
            log[#log + 1] = 'join:' .. tostring(peer)
            m:addScore(peer, 0)
        end,
        onPlayerLeave = function(m, peer)
            log[#log + 1] = 'leave:' .. tostring(peer)
        end,
        onCommand = function(m, host, peer, name, body)
            if name == 'score' then
                m:addScore(peer, body and body.n or 1)
                return true
            end
            return false
        end,
    }

    t.eq(mode.state, 'idle', 'starts idle')
    t.eq(mode.name, 'dm', 'name stored')

    mode:start('W', { 'e1' })
    t.eq(mode.state, 'running', 'running after start')
    t.eq(log[1], 'start:W:1', 'onStart fired')

    mode:tick(0.25, 'W', {})
    t.near(mode.elapsed, 0.25, 1e-9, 'elapsed accumulates')
    t.eq(log[2], 'tick:0.25', 'onTick fired')

    -- Tick while ended is a no-op.
    mode:stop('time')
    t.eq(mode.state, 'ended', 'ended')
    t.eq(log[3], 'stop:time', 'onStop reason')
    local el = mode.elapsed
    mode:tick(1.0, 'W', {})
    t.eq(mode.elapsed, el, 'no tick after stop')

    ---------------------------------------------------------------------
    t.describe('score and command routing')

    local m2 = Mode.new{
        onCommand = function(m, host, peer, name, body)
            if name == 'score' then
                m:addScore(peer, body.n or 1)
                return true
            end
        end,
    }
    m2:start()
    m2:playerJoin(7, { id = 1 })
    t.eq(m2:command(nil, 7, 'score', { n = 3 }), true, 'command handled')
    t.eq(m2.score[7], 3, 'score applied')
    t.eq(m2:command(nil, 7, 'unknown', {}), false, 'unknown not handled')
    m2:addScore(7, 2)
    t.eq(m2.score[7], 5, 'addScore stacks')

    m2:playerLeave(7)
    t.ok(true, 'leave without handler is fine')
end
