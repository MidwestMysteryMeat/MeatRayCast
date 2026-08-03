--[[
    C18: authored lifts replicate to clients. A host with a mover map sends the
    lift CONFIG in the world payload and the live lift Z in WORLD deltas; a client
    rebuilds the mover host and applies the deltas onto its own floor heights, so
    it stands where the platform actually is — not where the map authored it.
]]

return function(t)
    local Entity   = require('meatray.sim.entity')
    local C        = require('meatray.sim.components')
    local Map      = require('meatray.sim.map')
    local Movers   = require('meatray.sim.movers')
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

    local function pump(host, client, seconds, step)
        step = step or 1 / 60
        for _ = 1, math.ceil((seconds or 0.1) / step) do
            if host then host:update(step) end
            if client then client:update(step) end
        end
    end

    Loopback.reset()
    defineArchetypes()
    Entity.resetIds(1)

    -- A map with one lift on tiles (5,5)-(5,6).
    local mapText = table.concat({
        'name Lift', 'theme dungeon', 'spawn 2.5 2.5 0',
        'mover gate 0 0.6 0.3 down 5 5 5 6',
        '---',
        '########',
        '#......#',
        '#......#',
        '#......#',
        '#......#',
        '#......#',
        '#......#',
        '########',
    }, '\n')
    local map = assert(Map.parse(mapText))
    local world = Map.toWorld(map)
    t.ok(world.movers and #world.movers == 1, 'the world carries the mover config')

    local movers = Movers.new(world)
    for _, mv in ipairs(world.movers) do movers:add(mv) end

    ---------------------------------------------------------------------
    t.describe('the client rebuilds the lift from the world payload')

    local host = Net.Host.new{
        mode = 'listen', transport = 'loopback', port = 9200,
        world = world, movers = movers, snapshotRate = 20, onLog = function() end,
    }
    t.ok(host, 'host up')

    local client = Net.Client.new{
        address = 'loopback:9200', transport = 'loopback',
        name = 'ada', onLog = function() end,
    }
    pump(host, client, 0.2)
    t.eq(client.state, 'joined', 'joined')
    t.ok(client.world.movers and #client.world.movers == 1,
         'the client received the mover config')
    t.ok(client.movers, 'and built a mover host from it')

    ---------------------------------------------------------------------
    t.describe('raising the lift on the host raises it on the client')

    local cliBefore = client.world:floorHeightAt(5, 5, 1)
    t.ok(math.abs(cliBefore) < 1e-6, 'client floor starts down (0)')

    host.movers:call('gate', true)        -- send it up
    pump(host, client, 1.0)               -- host ticks + syncs, client applies

    local hostZ = host.world:floorHeightAt(5, 5, 1)
    local cliZ = client.world:floorHeightAt(5, 5, 1)
    t.ok(hostZ > 0, ('the host raised the lift (%.2f)'):format(hostZ))
    t.ok(cliZ > 0, ('the client saw it rise (%.2f)'):format(cliZ))
    t.ok(math.abs(hostZ - cliZ) < 1e-3,
         ('host and client agree on the lift height (%.3f vs %.3f)'):format(hostZ, cliZ))

    ---------------------------------------------------------------------
    t.describe('a still lift produces no world delta')

    pump(host, client, 3.0)               -- the 0.6@0.3 lift needs ~2s; settle fully
    t.ok(not host.movers:get('gate').moving, 'the lift has stopped')
    local syncsBefore = host.worldSyncs
    pump(host, client, 0.5)               -- nothing moving now
    -- Once the lift has stopped and doors/tiles are static, syncWorld finds
    -- nothing to send: the mover snapshot matches the last one broadcast.
    t.eq(host.worldSyncs, syncsBefore, 'a settled world stops producing deltas')
end
