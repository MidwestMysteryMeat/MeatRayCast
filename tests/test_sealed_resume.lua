--[[
    Integration: session resume THROUGH a sealed transport.

    Resume and sealing were each proven alone (test_resume, test_sealed). This
    is the seam between them: the resume token lives in the ACCEPT payload,
    which on a sealed session travels ENCRYPTED, and a resuming client must
    seal its JOIN — token and all — with the same password. If the two
    features did not compose, a sealed session could not be resumed, which is
    exactly the case a dropped wifi connection on a private server hits.
]]

return function(t)
    local Entity   = require('meatray.sim.entity')
    local C        = require('meatray.sim.components')
    local Worldgen = require('meatray.sim.worldgen')
    local Net      = require('meatray.net')
    local Loopback = require('meatray.net.transport.loopback')
    local Crypto   = require('meatray.net.crypto')

    -- Deterministic, distinct tokens (rotation needs each draw to differ).
    local n = 0
    Crypto.randomSource = function(len)
        n = n + 1
        return string.rep(string.char(64 + (n % 40)), len)
    end

    Entity.clearArchetypes()
    Entity.archetype('player', function(e)
        e:add(C.Player{ peerId = 0, name = '?' })
        e:add(C.Health{ hp = 100, max = 100 })
        e:add(C.Input{})
        e.radius = 0.24
    end)
    Entity.resetIds(1)
    Loopback.reset()

    local function pump(host, client, seconds)
        for _ = 1, math.ceil((seconds or 0.1) * 60) do
            if host then host:update(1 / 60) end
            if client then client:update(1 / 60) end
        end
    end

    local host = Net.Host.new{
        mode = 'listen', transport = 'loopback', port = 8700,
        world = Worldgen.box(20, 20), snapshotRate = 20, onLog = function() end,
        sealed = true, password = 'secret', resumeGrace = 30,
    }
    t.ok(host and host.sealedTransport, 'a sealed, resumable host is up')

    ---------------------------------------------------------------------
    t.describe('a sealed client joins and receives an encrypted-in-flight token')

    local client = Net.Client.new{
        address = 'loopback:8700', transport = 'loopback',
        name = 'ada', sealed = true, password = 'secret', onLog = function() end,
    }
    pump(host, client, 0.3)
    t.eq(client.state, 'joined', 'the sealed join succeeded')
    local token = client.resumeToken
    t.ok(type(token) == 'string' and #token > 0, 'and carried a resume token')
    t.ok(host.transport.opened > 0, 'the token arrived through the seal (frames opened)')

    local firstEntityId, firstPeerId = client.entityId, client.peerId
    local hostPeer
    for _, p in pairs(host.peers) do hostPeer = p end
    hostPeer.entity.x, hostPeer.entity.y = 6.5, 13.25   -- a memorable spot

    ---------------------------------------------------------------------
    t.describe('an unexpected drop parks the session; a sealed resume reclaims it')

    host:onDisconnect(hostPeer.handle)      -- transport died, no LEAVE
    local parked = 0
    for _ in pairs(host.limbo) do parked = parked + 1 end
    t.eq(parked, 1, 'the session is parked in limbo')

    local back = Net.Client.new{
        address = 'loopback:8700', transport = 'loopback',
        name = 'ada', sealed = true, password = 'secret',
        resume = token, onLog = function() end,
    }
    pump(host, back, 0.3)
    t.eq(back.state, 'joined', 'the sealed resume joined')
    t.eq(back.entityId, firstEntityId, 'to the SAME entity — the two features composed')
    t.eq(back.peerId, firstPeerId, 'same peer id')
    pump(host, back, 0.2)
    t.ok(back.player and math.abs(back.player.x - 6.5) < 0.5,
        'standing where the drop happened', back.player and back.player.x)
    t.ok(back.resumeToken and back.resumeToken ~= token,
        'and the ACCEPT rotated a fresh token, still through the seal')

    ---------------------------------------------------------------------
    t.describe('a wrong-password client cannot resume even with a stolen token')

    -- The token alone is not enough on a sealed server: the frames carrying it
    -- must also open. A thief with the token but not the password is dropped
    -- at the transport, exactly like any other wrong-password client.
    local thiefToken = back.resumeToken
    local wpeer
    for _, p in pairs(host.peers) do wpeer = p end
    host:onDisconnect(wpeer.handle)         -- park it again

    local thief = Net.Client.new{
        address = 'loopback:8700', transport = 'loopback',
        name = 'mal', sealed = true, password = 'wrong',
        resume = thiefToken, onLog = function() end,
    }
    pump(host, thief, 0.3)
    t.ok(thief.state ~= 'joined',
        'a stolen token with the wrong password still cannot join', thief.state)
    -- The parked session is untouched: the thief never reached handleJoin, so
    -- the token was never consumed and the real owner could still come back.
    local stillParked = false
    for _ in pairs(host.limbo) do stillParked = true end
    t.ok(stillParked, 'and the real session is still parked, its token unspent')

    host:close()
    Crypto.randomSource = nil
    Entity.clearArchetypes()
    Entity.resetIds(1)
end
