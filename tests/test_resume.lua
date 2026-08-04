--[[
    Session resume. A real host and client over loopback: an unexpected
    drop parks the player in limbo; a JOIN presenting the ACCEPT's token
    within grace gets the SAME entity back (id and position both); tokens
    are single-use and rotate; a deliberate LEAVE forfeits resume; the
    grace expires honestly; a map change voids every parked session.
]]

return function(t)
    local Entity   = require('meatray.sim.entity')
    local C        = require('meatray.sim.components')
    local Worldgen = require('meatray.sim.worldgen')
    local Net      = require('meatray.net')
    local Loopback = require('meatray.net.transport.loopback')
    local Crypto   = require('meatray.net.crypto')

    -- Deterministic, DISTINCT tokens: the suite must not depend on OS
    -- entropy, and rotation needs each draw to differ.
    local drawCount = 0
    Crypto.randomSource = function(n)
        drawCount = drawCount + 1
        return string.rep(string.char(64 + (drawCount % 32)), n)
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

    local port = 8400
    local function pump(host, client, seconds)
        for _ = 1, math.ceil((seconds or 0.1) * 60) do
            if host then host:update(1 / 60) end
            if client then client:update(1 / 60) end
        end
    end

    local world = Worldgen.box(20, 20)
    local host = Net.Host.new{
        mode = 'listen', transport = 'loopback', port = port,
        world = world, snapshotRate = 20, onLog = function() end,
        resumeGrace = 30,
    }
    t.ok(host, 'host up')

    ---------------------------------------------------------------------
    t.describe('the ACCEPT carries a token')

    local client = Net.Client.new{
        address = 'loopback:' .. port, transport = 'loopback',
        name = 'ada', onLog = function() end,
    }
    pump(host, client, 0.2)
    t.eq(client.state, 'joined', 'joined')
    local token = client.resumeToken
    t.ok(type(token) == 'string' and #token > 0, 'a resume token arrived')
    local firstEntityId = client.entityId
    local firstPeerId = client.peerId

    -- Move the player somewhere memorable so continuity is checkable.
    local hostPeer
    for _, p in pairs(host.peers) do hostPeer = p end
    t.ok(hostPeer and hostPeer.entity, 'the host holds the player')
    hostPeer.entity.x, hostPeer.entity.y = 7.25, 11.5

    ---------------------------------------------------------------------
    t.describe('an unexpected drop parks the session; the token reclaims it')

    host:onDisconnect(hostPeer.handle)      -- the transport died; no LEAVE
    local peersLeft = 0
    for _ in pairs(host.peers) do peersLeft = peersLeft + 1 end
    t.eq(peersLeft, 0, 'the peer is gone')
    local parked = 0
    for _ in pairs(host.limbo) do parked = parked + 1 end
    t.eq(parked, 1, 'and the session is parked')
    t.ok(not hostPeer.entity.dead, 'the entity was NOT killed')

    local back = Net.Client.new{
        address = 'loopback:' .. port, transport = 'loopback',
        name = 'ada', resume = token, onLog = function() end,
    }
    pump(host, back, 0.2)
    t.eq(back.state, 'joined', 'the return joined')
    t.eq(back.entityId, firstEntityId, 'to the SAME entity')
    t.eq(back.peerId, firstPeerId, 'with the same peer id')
    pump(host, back, 0.2)
    t.ok(back.player, 'bound off a snapshot')
    t.ok(math.abs(back.player.x - 7.25) < 0.5,
        'standing where they were dropped', back.player.x)

    t.ok(back.resumeToken and back.resumeToken ~= token,
        'the ACCEPT rotated the token — the old one is spent')
    local stillParked = 0
    for _ in pairs(host.limbo) do stillParked = stillParked + 1 end
    t.eq(stillParked, 0, 'limbo is empty again')

    ---------------------------------------------------------------------
    t.describe('a spent or bogus token is a fresh join, not a refusal')

    local stale = Net.Client.new{
        address = 'loopback:' .. port, transport = 'loopback',
        name = 'eve', resume = token,        -- the SPENT token
        onLog = function() end,
    }
    pump(host, stale, 0.2)
    t.eq(stale.state, 'joined', 'joined anyway')
    t.ok(stale.entityId ~= firstEntityId, 'as a brand new player')
    stale:leave(); pump(host, stale, 0.1)

    ---------------------------------------------------------------------
    t.describe('a deliberate LEAVE forfeits resume')

    -- `back` is the live session for firstEntityId. Say goodbye properly.
    local leaveToken = back.resumeToken
    back:leave()
    pump(host, back, 0.2)
    local parkedAfterLeave = 0
    for _ in pairs(host.limbo) do parkedAfterLeave = parkedAfterLeave + 1 end
    t.eq(parkedAfterLeave, 0, 'nothing parked — they said goodbye')

    local wishful = Net.Client.new{
        address = 'loopback:' .. port, transport = 'loopback',
        name = 'ada', resume = leaveToken, onLog = function() end,
    }
    pump(host, wishful, 0.2)
    t.eq(wishful.state, 'joined', 'they can come back...')
    t.ok(wishful.entityId ~= firstEntityId, '...but as a fresh player')

    ---------------------------------------------------------------------
    t.describe('grace expires honestly')

    local wpeer
    for _, p in pairs(host.peers) do wpeer = p end
    local wToken = wishful.resumeToken
    local wEntity = wpeer.entity
    host:onDisconnect(wpeer.handle)
    t.ok(not wEntity.dead, 'parked alive')

    -- Push the host clock past the grace and let update sweep.
    host.now = host.now + 31
    host:update(1 / 60)
    t.ok(wEntity.dead, 'the grace ran out and the player finally died')

    local tooLate = Net.Client.new{
        address = 'loopback:' .. port, transport = 'loopback',
        name = 'ada', resume = wToken, onLog = function() end,
    }
    pump(host, tooLate, 0.2)
    t.eq(tooLate.state, 'joined', 'late arrival still joins')
    t.ok(tooLate.entityId ~= wEntity.id, 'as someone new')

    ---------------------------------------------------------------------
    t.describe('a map change voids every parked session')

    local tpeer
    for _, p in pairs(host.peers) do tpeer = p end
    host:onDisconnect(tpeer.handle)
    local parkedBefore = 0
    for _ in pairs(host.limbo) do parkedBefore = parkedBefore + 1 end
    t.eq(parkedBefore, 1, 'one parked session')

    host:changeWorld(Worldgen.box(12, 12), {}, nil, { map = 'elsewhere' })
    local parkedAfter = 0
    for _ in pairs(host.limbo) do parkedAfter = parkedAfter + 1 end
    t.eq(parkedAfter, 0, 'the map change cleared it')

    host:close()
    Crypto.randomSource = nil
    Entity.clearArchetypes()
    Entity.resetIds(1)
end
