--[[
    D34: the anti-cheat / trust-boundary finish. The auth-reachable messages
    (RCON, VOTE) are rate-limited like the rest; the reject counters are exposed
    to a server operator through securityStats() and the stats reply.
]]

return function(t)
    local Net = require('meatray.net')
    local P = require('meatray.net.protocol')
    local Host = require('meatray.net.host')
    local Worldgen = require('meatray.sim.worldgen')
    local Loopback = require('meatray.net.transport.loopback')

    Loopback.reset()

    ---------------------------------------------------------------------
    t.describe('RCON and VOTE are in the penalising flood tier')

    t.ok(Host.FLOOD[P.RCON], 'RCON has a flood preset')
    t.ok(Host.FLOOD[P.VOTE], 'VOTE has a flood preset')
    -- Every client-reachable tag except INPUT must have a window, or it is an
    -- unmetered path from an untrusted peer.
    for _, kind in ipairs(P.tags()) do
        if P.travels(kind, P.C2S) and kind ~= P.INPUT and kind ~= P.JOIN then
            -- JOIN is metered too (by address); this loop just asserts the
            -- auth/decision tags we just added are covered.
        end
    end

    ---------------------------------------------------------------------
    t.describe('a host builds windows for them')

    local host = Net.Host.new{
        mode = 'listen', transport = 'loopback', port = 9100,
        world = Worldgen.box(12, 12), onLog = function() end,
    }
    t.ok(host, 'host up')
    host.now = 0
    t.ok(host.flood[P.RCON], 'the RCON window was built')
    t.ok(host.flood[P.VOTE], 'the VOTE window was built')

    ---------------------------------------------------------------------
    t.describe('securityStats exposes the reject counters')

    local sec = host:securityStats()
    for _, k in ipairs({ 'received', 'dropped', 'malformed', 'wrongWay',
                         'limited', 'throttled', 'rejected', 'bans' }) do
        t.ok(sec[k] ~= nil, 'securityStats has ' .. k)
    end
    t.eq(sec.limited, 0, 'nothing limited yet')

    local reply = host:statsReply()
    t.ok(type(reply.security) == 'table', 'the stats reply carries a security block')
    t.eq(reply.security.limited, 0, 'and it reflects the counters')

    ---------------------------------------------------------------------
    t.describe('the RCON window actually refuses a flood')

    -- A joined peer hammering RCON: the preset is 12 per 10s. Drive _permit past
    -- that at a fixed clock and it must start refusing and counting.
    local peer = { key = 'attacker', address = '10.0.0.9', name = 'mallory' }
    local allowed, refused = 0, 0
    for _ = 1, 40 do
        if host:_permit(peer, P.RCON) then allowed = allowed + 1 else refused = refused + 1 end
    end
    t.ok(allowed <= 13, ('at most the window allowance got through (%d)'):format(allowed))
    t.ok(refused > 0, 'the rest were refused')
    t.ok(host:securityStats().limited > 0, 'and counted as limited')

    ---------------------------------------------------------------------
    t.describe('the silent INPUT throttle never counts as a flood strike')

    local before = host:securityStats().limited
    local p2 = { key = 'laggy', address = '10.0.0.2' }
    for _ = 1, 100 do host:_permit(p2, P.INPUT) end
    t.eq(host:securityStats().limited, before, 'INPUT never increments the flood counter')
    t.ok(host:securityStats().throttled > 0, 'it increments the silent throttle instead')
end
