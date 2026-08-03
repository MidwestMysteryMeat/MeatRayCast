--[[
    B14: hot-reload the map on a running host.

    A real host and client over the loopback transport, same as
    test_net_replication. After they are joined against one world, the host
    swaps to a DIFFERENT world live (HostMT:changeWorld). The client must end up
    rendering the new geometry, bound to a new entity, with its old-map entities
    forgotten — not stranded on the world it joined against.
]]

return function(t)
    local Entity   = require('meatray.sim.entity')
    local C        = require('meatray.sim.components')
    local Worldgen = require('meatray.sim.worldgen')
    local Net      = require('meatray.net')
    local Loopback = require('meatray.net.transport.loopback')

    local function defineArchetypes()
        Entity.clearArchetypes()
        Entity.archetype('player', function(e)
            e:add(C.Player{ peerId = 0, name = '?' })
            e:add(C.Health{ hp = 100, max = 100 })
            e:add(C.Input{})
            e.radius = 0.24
        end)
    end

    local port = 0
    local function freshPort() port = port + 1; return 8300 + port end

    local function pump(host, client, seconds, step)
        step = step or 1 / 60
        for _ = 1, math.ceil((seconds or 0.1) / step) do
            if host then host:update(step) end
            if client then client:update(step) end
        end
    end

    local function makeHost(p, world)
        return Net.Host.new{
            mode = 'listen', transport = 'loopback', port = p,
            world = world, snapshotRate = 20, onLog = function() end,
        }
    end
    local function makeClient(p, onMapChange)
        return Net.Client.new{
            address = 'loopback:' .. p, transport = 'loopback',
            name = 'ada', onMapChange = onMapChange, onLog = function() end,
        }
    end

    -----------------------------------------------------------------------
    t.describe('a client joins the first world')

    Loopback.reset()
    defineArchetypes()
    Entity.resetIds(1)

    local p = freshPort()
    local oldWorld = Worldgen.box(20, 20)
    local host = makeHost(p, oldWorld)
    t.ok(host, 'host up')

    local mapChanges = 0
    local client = makeClient(p, function() mapChanges = mapChanges + 1 end)
    pump(host, client, 0.2)
    t.eq(client.state, 'joined', 'joined')
    t.eq(client.world.width, 20, 'client has the 20-wide world')
    local firstEntityId = client.entityId
    t.ok(firstEntityId ~= nil, 'client bound to an entity')
    pump(host, client, 0.2)
    t.ok(client.player ~= nil, 'and it resolved off a snapshot')

    -----------------------------------------------------------------------
    t.describe('the host swaps to a new world live')

    -- A different SIZE, so "the client adopted the new world" is unambiguous.
    local newWorld = Worldgen.box(12, 16)
    local newEntities = {}
    -- The demo would rebuild a local player too; mimic that so the host has an
    -- avatar to re-home (changeWorld takes it as opts.localPlayer).
    local hostAvatar = host.localPlayer
    local ok = host:changeWorld(newWorld, newEntities, nil,
                                { localPlayer = hostAvatar, map = 'small' })
    t.ok(ok, 'changeWorld succeeded')
    t.eq(host.world.width, 12, 'the host now holds the new world')
    t.ok(host.world == newWorld, 'by the exact table it was handed')

    -- The peer got a brand-new entity in the new world.
    local peer
    for _, pr in pairs(host.peers) do if pr.joined then peer = pr end end
    t.ok(peer and peer.entity, 'the joined peer has a fresh entity')
    t.ok(peer.entity.id ~= firstEntityId, 'with a new id, not the old one')

    -----------------------------------------------------------------------
    t.describe('the client rebuilds to the new world')

    pump(host, client, 0.3)
    t.eq(mapChanges, 1, 'the client fired its onMapChange once')
    t.eq(client.world.width, 12, 'client width is now the new world')
    t.eq(client.world.height, 16, 'client height too')
    t.eq(client.world:isSolid(1, 1), host.world:isSolid(1, 1),
         'walls agree with the new host world')
    t.eq(client.entityId, peer.entity.id, 'client rebound to its new entity id')
    t.ok(client.entityId ~= firstEntityId, 'which is not the old entity id')
    t.ok(client.player ~= nil, 'and the new player resolved off a fresh snapshot')
    t.eq(client.player.id, client.entityId, 'the resolved player is the bound one')

    -----------------------------------------------------------------------
    t.describe('no phantom world delta after the swap')

    -- The very next syncWorld must not broadcast a delta of the new world
    -- against a stale baseline — changeWorld reseated the baselines.
    local before = host.worldSyncs
    host:syncWorld()
    t.eq(host.worldSyncs, before, 'an unchanged new world produces no delta')

    -----------------------------------------------------------------------
    t.describe('a second swap works too (baselines really were reseated)')

    local third = Worldgen.box(8, 8)
    host:changeWorld(third, {}, nil, { localPlayer = host.localPlayer, map = 'tiny' })
    pump(host, client, 0.3)
    t.eq(client.world.width, 8, 'client adopted the third world')
    t.eq(mapChanges, 2, 'and fired onMapChange again')
end
