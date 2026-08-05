--[[
    Networked demo: record a joined session's snapshot stream and replay it
    standalone. A real loopback host+client; the client records; the demo is
    then replayed with no socket and must reconstruct the same entities at the
    same positions the live client held — because a replay feeds the identical
    snapshots back through the identical apply path.
]]

return function(t)
    local Entity   = require('meatray.sim.entity')
    local C        = require('meatray.sim.components')
    local Worldgen = require('meatray.sim.worldgen')
    local Net      = require('meatray.net')
    local Loopback = require('meatray.net.transport.loopback')
    local NetDemo  = require('meatray.net.netdemo')

    Entity.clearArchetypes()
    Entity.archetype('player', function(e)
        e:add(C.Player{ peerId = 0, name = '?' })
        e:add(C.Health{ hp = 100, max = 100 })
        e:add(C.Input{})
        e.radius = 0.24
    end)
    -- A moving non-player so the stream carries motion to reconstruct.
    Entity.archetype('mob', function(e)
        e:add(C.Health{ hp = 10, max = 10 })
        e.radius = 0.2
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
        mode = 'listen', transport = 'loopback', port = 8800,
        world = Worldgen.box(24, 24), snapshotRate = 20, onLog = function() end,
    }
    -- Put a mob in the world and give it a steady drift, so the snapshots have
    -- something changing to record.
    local mob = Entity.spawn('mob', 5.5, 5.5)
    mob:snapPrevious()
    table.insert(host.entities, mob)

    local client = Net.Client.new{
        address = 'loopback:8800', transport = 'loopback',
        name = 'rec', onLog = function() end,
    }
    pump(host, client, 0.3)
    t.eq(client.state, 'joined', 'joined')

    ---------------------------------------------------------------------
    t.describe('a joined client records its snapshot stream')

    local rec = client:startNetDemo()
    t.ok(rec, 'recording started')
    t.ok(rec.world, 'and the join world payload was captured')

    -- Drive a few seconds; move the mob each tick so its recorded path is real.
    for i = 1, 60 * 3 do
        mob.x = 5.5 + i * 0.02
        mob:snapPrevious()
        host:update(1 / 60)
        client:update(1 / 60)
    end
    t.ok(rec:count() > 10, 'many snapshots captured', rec:count())

    local text = client:stopNetDemo()
    t.ok(type(text) == 'string' and #text > 0, 'the demo serialized')
    t.eq(client.netDemoRec, nil, 'and recording stopped')

    -- The live truth to compare against: where the client thinks entities are.
    local liveMob, livePlayer
    for _, e in ipairs(client.entities) do
        if e.kind == 'mob' then liveMob = e
        elseif e.id == client.entityId then livePlayer = e end
    end
    t.ok(liveMob, 'the client is holding the mob')

    ---------------------------------------------------------------------
    t.describe('the demo loads and replays standalone, reconstructing the entities')

    local loaded, lerr = NetDemo.load(text)
    t.ok(loaded, 'load succeeds (' .. tostring(lerr) .. ')')
    t.ok(loaded.world, 'carries the world payload')
    t.ok(#loaded.snaps == rec:count(), 'every recorded snapshot is present')

    t.ok(not NetDemo.load('{"nope":1}'), 'a non-netdemo is refused')

    -- Replay with NO host, NO socket — just the recorded stream.
    Entity.resetIds(9000)      -- a distinct id space, to prove ids come from the demo
    local play = NetDemo.replay(loaded)
    t.ok(play.world and play.world.width == 24, 'the world rebuilt from the payload')
    local finalEntities = play:runToEnd()
    t.ok(#finalEntities > 0, 'the replay reconstructed entities')

    -- The mob the demo replayed must stand where the live client last saw it.
    local replayedMob = liveMob and play:entity(liveMob.id) or nil
    t.ok(replayedMob, 'the mob was reconstructed under its recorded id')
    t.ok(math.abs(replayedMob.x - liveMob.x) < 0.01,
        'and at the position the live client held', replayedMob.x .. ' vs ' .. liveMob.x)
    t.ok(math.abs(replayedMob.y - liveMob.y) < 0.01, 'in y too')

    ---------------------------------------------------------------------
    t.describe('stepped replay advances tick by tick')

    local stepper = NetDemo.replay(loaded)
    local firstTick = stepper:step()
    t.ok(firstTick ~= nil, 'the first step applied a snapshot')
    local n = 1
    while stepper:step() do n = n + 1 end
    t.eq(n, #loaded.snaps, 'stepping walks every recorded snapshot exactly once')

    host:close()
    Entity.clearArchetypes()
    Entity.resetIds(1)
end
