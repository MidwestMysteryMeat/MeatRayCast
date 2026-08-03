--[[
    Replication, end to end, with no sockets and no LÖVE.

    A real host and a real client, both driven by hand over the loopback
    transport: the join handshake, snapshots, inputs, world mutation and
    prediction are the production code paths, not test doubles. Only the wire is
    in-process.

    This exists before the ENet transport does, and that ordering is the point. A
    replication bug and a socket bug produce the same symptom — the client is
    wrong — so debugging them together means debugging two systems at once.
    Verifying replication first turns every later failure into a transport failure
    by elimination.

    What is asserted here is mostly about restraint: that a field not named in
    netFields does *not* travel, that a component the client does not carry is
    ignored rather than fabricated, that a stale snapshot is dropped, and that
    health is never predicted. Those are all cases where the wrong behaviour looks
    like the right one until something breaks in a way nobody can reproduce.
]]

return function(t)
    local Entity   = require('meatray.sim.entity')
    local C        = require('meatray.sim.components')
    local World    = require('meatray.sim.world')
    local Worldgen = require('meatray.sim.worldgen')
    local Net      = require('meatray.net')
    local Rep      = Net.replication
    local Loopback = require('meatray.net.transport.loopback')

    -----------------------------------------------------------------------
    -- Fixtures
    -----------------------------------------------------------------------

    -- A component with one synced field and one that is deliberately local, so
    -- "only netFields travel" can be asserted rather than assumed.
    local Mood = Entity.component('mood', { 'shown' })

    local function defineArchetypes()
        Entity.clearArchetypes()

        Entity.archetype('player', function(e)
            e:add(C.Player{ peerId = 0, name = '?' })
            e:add(C.Health{ hp = 100, max = 100 })
            e:add(C.Weapon{ ammo = 40 })
            e:add(C.Input{})
            e:add(C.Motion{ vx = 0, vy = 0 })
            e.radius = 0.24
        end)

        Entity.archetype('imp', function(e)
            e:add(C.Billboard{ sheet = 'imp' })
            e:add(C.Health{ hp = 30, max = 30 })
            e:add(C.Brain{ state = 'idle' })
            e:add(Mood{ shown = 'calm', hidden = 'secret' })
            e.radius = 0.28
        end)
    end

    local port = 0
    local function freshPort()
        port = port + 1
        return 8000 + port
    end

    -- Both sides advanced by whole ticks. Nothing here uses a wall clock, so the
    -- test is deterministic and fast.
    local function pump(host, client, seconds, step)
        step = step or 1 / 60
        for _ = 1, math.ceil((seconds or 0.1) / step) do
            if host then host:update(step) end
            if client then client:update(step) end
        end
    end

    local function makeHost(opts)
        opts = opts or {}
        local world = opts.world or Worldgen.box(20, 20)
        local host, err = Net.Host.new{
            mode = 'listen',
            transport = 'loopback',
            port = opts.port,
            world = world,
            entities = opts.entities,
            worldSpec = opts.worldSpec,
            localPlayer = opts.localPlayer,
            password = opts.password,
            onAuthenticate = opts.onAuthenticate,
            maxPlayers = opts.maxPlayers,
            snapshotRate = opts.snapshotRate or 20,
            onStep = opts.onStep,
            onCommand = opts.onCommand,
            respawn = opts.respawn,
            onPeerRespawn = opts.onPeerRespawn,
            onLog = function() end,          -- quiet; diagnostics are tested elsewhere
        }
        return host, err
    end

    local function makeClient(opts)
        opts = opts or {}
        local client, err = Net.Client.new{
            address = 'loopback:' .. opts.port,
            transport = 'loopback',
            name = opts.name or 'tester',
            password = opts.password,
            credentials = opts.credentials,
            prediction = opts.prediction,
            onEvent = opts.onEvent,
            onLog = function() end,
        }
        return client, err
    end

    -----------------------------------------------------------------------
    t.describe('the join handshake')
    Loopback.reset()
    defineArchetypes()
    Entity.resetIds(1)

    local p1 = freshPort()
    local host, hostErr = makeHost{ port = p1 }
    t.ok(host ~= nil, 'a host comes up on the loopback transport', hostErr)
    t.ok(host.localPlayer ~= nil, 'a listen host has a local player')
    t.eq(host:playerCount(), 1, 'and counts itself as a player')

    local client, clientErr = makeClient{ port = p1, name = 'ada' }
    t.ok(client ~= nil, 'a client connects', clientErr)
    t.eq(client.state, 'connecting', 'and starts out connecting, not joined')

    pump(host, client, 0.2)
    t.eq(client.state, 'joined', 'the handshake completes')
    t.eq(client.peerId, 1, 'the host assigned a peer id')
    t.ok(client.entityId ~= nil, 'and told the client which entity is its own')
    t.eq(host:playerCount(), 2, 'the host now counts two players')

    t.describe('the world crossed the wire')
    t.ok(client.world ~= nil, 'the client built a world from the join payload')
    t.eq(client.world.width, host.world.width, 'same width')
    t.eq(client.world.height, host.world.height, 'same height')
    t.eq(client.world:isSolid(1, 1), host.world:isSolid(1, 1), 'walls agree')
    t.eq(client.world:isSolid(10, 10), host.world:isSolid(10, 10), 'floors agree')

    t.describe('both players exist on both sides')
    t.eq(#host.entities, 2, 'the host holds two entities')
    t.eq(client:playerCount(), 2, 'the client sees two players')
    t.ok(client.player ~= nil, 'and knows which one it is')
    t.eq(client.player.id, client.entityId, 'by the id the host gave it')
    t.ok(client.player:has('health'), 'the local player was built from the archetype')

    -----------------------------------------------------------------------
    t.describe('an entity spawned on the host appears on the client')
    local imp = host:spawn('imp', 6.5, 6.5)
    t.ok(imp ~= nil, 'the host spawns an imp')
    imp:get('health').hp = 21
    imp:get('mood').shown = 'angry'
    imp:get('mood').hidden = 'still secret'

    pump(host, client, 0.15)

    local seen = client.byId[imp.id]
    t.ok(seen ~= nil, 'the client received it')
    t.eq(seen.kind, 'imp', 'with the right kind')
    t.near(seen.x, 6.5, 1e-6, 'at the right position')
    t.ok(seen:has('billboard'), 'built from the client-side archetype: billboard')
    t.ok(seen:has('health'), 'built from the client-side archetype: health')
    t.eq(seen:get('health').hp, 21, 'and carrying the host-side health value')

    t.describe('only netFields travel')
    t.eq(seen:get('mood').shown, 'angry', 'a declared field replicates')
    -- 'hidden' is not in Mood's netFields. The client built its own imp from its
    -- own archetype, so it has the archetype's default and not the host's value.
    -- If this ever equalled the host's string, the wire format would have stopped
    -- deriving from the declaration.
    t.eq(seen:get('mood').hidden, 'secret', 'an undeclared field does not replicate')

    -- Motion is local by design: the host sends positions, so a client that also
    -- integrated velocity would fight the snapshots it receives.
    local playerSnapshot = host.localPlayer:snapshot()
    t.eq(playerSnapshot.c.motion, nil, 'a component with no netFields is absent from the wire')
    t.ok(playerSnapshot.c.health ~= nil, 'while a component with netFields is present')
    t.eq(playerSnapshot.c.input, nil, 'input is never snapshot state')
    t.eq(playerSnapshot.c.brain, nil, 'nor is AI bookkeeping')

    t.describe('a snapshot for a component the client does not carry is ignored')
    -- applySnapshot already refuses to fabricate; this asserts it survives a real
    -- round trip through the transport, where the component name arrives as a
    -- decoded string rather than as the same table the host held.
    local sparse = Entity.new{ id = imp.id + 5000, kind = 'sparse' }
    sparse:applySnapshot(Net.serialize.decode(Net.serialize.encode(imp:snapshot())))
    t.ok(not sparse:has('health'), 'no health component was invented')
    t.ok(not sparse:has('mood'), 'no mood component was invented')
    t.near(sparse.x, 6.5, 1e-6, 'but the transform still applied')

    -----------------------------------------------------------------------
    t.describe('a netFields change propagates; a local change does not')
    imp:get('health').hp = 7
    imp:get('mood').hidden = 'changed on the host only'
    pump(host, client, 0.15)
    t.eq(seen:get('health').hp, 7, 'the changed synced field arrived')
    t.eq(seen:get('mood').hidden, 'secret', 'the changed local field did not')

    t.describe('despawn needs no message of its own')
    local doomed = host:spawn('imp', 8.5, 8.5)
    pump(host, client, 0.15)
    t.ok(client.byId[doomed.id] ~= nil, 'the client saw the second imp')
    doomed.dead = true
    pump(host, client, 0.15)
    t.ok(client.byId[doomed.id] == nil,
         'an id absent from a full snapshot is an id the client drops')

    -----------------------------------------------------------------------
    t.describe('world door state replicates')
    -- Door *state* replicates; a door that did not exist when the client joined
    -- does not appear from nowhere, because world:snapshot() is door state and not
    -- a level edit. Both sides therefore add the door, which is what loading the
    -- same map does. (Runtime level editing is phase 12's problem, not this one's.)
    host.world:addDoor(5, 5, false)
    host.lastWorld = host.world:snapshot()
    client.world:addDoor(5, 5, false)

    t.ok(host.world:isSolid(5, 5), 'the door starts shut on the host')
    t.ok(client.world:isSolid(5, 5), 'and shut on the client')

    -- Mutated directly, the way game code would write it. The host diffs door
    -- state rather than requiring gameplay code to announce a change, so this
    -- replicates without the caller knowing the net layer exists.
    host.world:toggleDoor(5, 5)
    pump(host, client, 0.15)
    t.ok(client.world:doorAt(5, 5).open, 'opening it on the host opens it on the client')
    t.ok(not client.world:isSolid(5, 5), 'and the client agrees it no longer blocks')

    host.world:toggleDoor(5, 5)
    pump(host, client, 0.15)
    t.ok(not client.world:doorAt(5, 5).open, 'and closing it closes it')

    t.describe('door animation is local, its state is not')
    -- openness is presentation: every client can run the animation itself, so it
    -- is not on the wire. It still has to converge, which it does because the
    -- client ticks the world too.
    host.world:setDoorOpen(5, 5, true)
    pump(host, client, 0.6)
    t.ok(client.world:doorAt(5, 5).openness > 0.9,
         'the client animated the door open by itself')

    -----------------------------------------------------------------------
    t.describe('client inputs move the player, on the host')
    local before = { x = client.player.x, y = client.player.y }
    local hostEntity
    for _, peer in pairs(host.peers) do hostEntity = peer.entity end
    t.ok(hostEntity ~= nil, 'the host has an entity for the peer')

    client:setInput{ forward = 1, angle = 0 }
    pump(host, client, 0.5)

    t.ok(hostEntity.x > before.x + 0.2, 'the host moved the entity in response to input')
    t.ok(client.player.x > before.x + 0.2, 'and the client predicted the same direction')
    t.near(client.player.x, hostEntity.x, 0.5,
           'prediction and authority agree to within a fraction of a tile')

    t.describe('a client cannot send a position, only an intent')
    -- Forged intent is clamped, not trusted: the host runs the same movement code
    -- against its own world either way.
    local sane = Rep.sanitiseInput{ forward = 900, strafe = -900, angle = 1.25, seq = 3 }
    t.ok(sane.forward <= 1 and sane.forward >= -1, 'a forged axis is clamped to a unit')
    t.ok(sane.strafe <= 1 and sane.strafe >= -1, 'on both axes')
    t.near(math.sqrt(sane.forward ^ 2 + sane.strafe ^ 2), 1, 1e-9,
           'and a diagonal is normalised, so it is not faster than a straight line')
    t.eq(sane.angle, 1.25, 'aim is taken verbatim, because aim is an input')
    t.eq(Rep.sanitiseInput{ angle = 0 / 0 }.angle, nil, 'a NaN angle is discarded')
    t.eq(Rep.sanitiseInput{ forward = 0 / 0 }.forward, 0, 'a NaN axis becomes zero')
    t.eq(Rep.sanitiseInput('not a table'), nil, 'a non-table input is refused')

    client:setInput{ forward = 0 }
    pump(host, client, 0.2)

    -----------------------------------------------------------------------
    t.describe('health is authoritative and never predicted')
    local hp = hostEntity:get('health')
    t.eq(client.player:get('health').hp, hp.hp, 'client and host agree before damage')

    hp.hp = hp.hp - 37
    -- The client is deliberately ticked on its own first: prediction runs, and
    -- must not touch health.
    client:update(1 / 60)
    t.ok(client.player:get('health').hp ~= hp.hp,
         'the client has not guessed at the new value')

    pump(host, client, 0.15)
    t.eq(client.player:get('health').hp, hp.hp, 'and takes it verbatim when the host says so')

    t.describe('ammo is authoritative too')
    hostEntity:get('weapon').ammo = 11
    pump(host, client, 0.15)
    t.eq(client.player:get('weapon').ammo, 11, 'ammo came from the host')

    -----------------------------------------------------------------------
    t.describe('interpolation between two snapshots')
    -- Two known snapshots, applied in order, and the entity must sit exactly
    -- halfway at alpha 0.5. This is the mechanism that turns 20 Hz of state into
    -- motion that reads as continuous.
    local mover = Entity.new{ id = 4242, kind = 'imp', x = 0, y = 0 }
    local view = { entities = {}, byId = {} }

    Rep.applyEntities(view, { { id = 4242, kind = 'imp', x = 2, y = 2, angle = 0 } })
    local adopted = view.byId[4242]
    t.ok(adopted ~= nil, 'the first snapshot spawned the entity')
    local ix, iy = adopted:interpolated(0.5)
    t.eq(ix, 2, 'with nothing to interpolate from, alpha 0.5 is still the position')
    t.eq(iy, 2, 'on both axes')

    Rep.applyEntities(view, { { id = 4242, kind = 'imp', x = 6, y = 4, angle = 1 } })
    ix, iy = adopted:interpolated(0)
    t.eq(ix, 2, 'alpha 0 is the previous snapshot')
    t.eq(iy, 2, 'on both axes')
    ix, iy = adopted:interpolated(0.5)
    t.eq(ix, 4, 'alpha 0.5 is halfway between the two snapshots')
    t.eq(iy, 3, 'on both axes')
    ix, iy = adopted:interpolated(1)
    t.eq(ix, 6, 'alpha 1 is the new snapshot')
    t.eq(iy, 4, 'on both axes')
    t.eq(mover.x, 0, 'the unrelated entity was untouched')

    t.describe('the client reports where it is between snapshots')
    t.ok(client:alpha() >= 0 and client:alpha() <= 1, 'alpha is inside 0..1')

    -----------------------------------------------------------------------
    t.describe('a stale snapshot is dropped, not applied')
    local ticked = client.lastTick
    client:handle(Net.protocol.SNAPSHOT, {
        tick = ticked + 10,
        e = { { id = client.entityId, kind = 'player', x = 3, y = 3 } },
    })
    t.eq(client.lastTick, ticked + 10, 'a newer snapshot is accepted')
    client:handle(Net.protocol.SNAPSHOT, { tick = ticked - 5, e = {} })
    t.eq(client.lastTick, ticked + 10, 'an older one does not become the new baseline')
    t.ok(client.player ~= nil, 'and it did not wipe the entity list')

    -----------------------------------------------------------------------
    t.describe('ids are coordinated, not negotiated')
    -- The client rebases its counter past everything the host will ever assign on
    -- join, so anything it spawns for itself cannot collide with an authoritative
    -- id. No round trip, so no race.
    t.ok(Entity.reserveId() >= Rep.CLIENT_ID_BASE,
         'the client-side id counter is rebased past the host range')

    local ids = {}
    local collision = false
    for _, e in ipairs(client.entities) do
        if ids[e.id] then collision = true end
        ids[e.id] = true
    end
    t.ok(not collision, 'no two entities on the client share an id')

    local localEffect = Entity.new{ kind = 'muzzleflash', x = 1, y = 1 }
    localEffect.localOnly = true
    t.ok(ids[localEffect.id] == nil,
         'an entity the client spawns for itself cannot collide with a host id')

    -- localOnly entities are never sent and never reaped by reconciliation.
    client.entities[#client.entities + 1] = localEffect
    client.byId[localEffect.id] = localEffect
    pump(host, client, 0.15)
    t.ok(client.byId[localEffect.id] ~= nil,
         'and it survives a snapshot that does not mention it')
    t.eq(#Rep.entitySnapshots({ localEffect }), 0, 'a localOnly entity is never snapshot')

    host:close()
    client:close()

    -----------------------------------------------------------------------
    t.describe('a world sent as a seed rather than a grid')
    -- Both ends regenerate identical geometry from the engine's own LCG. This is
    -- only sound because worldgen never touches math.random, whose sequence
    -- differs between Lua builds; that constraint exists so this works.
    Loopback.reset()
    Entity.resetIds(1)
    defineArchetypes()

    local spec = { width = 32, height = 32, seed = 31337, doorChance = 0.5 }
    local specWorld = Worldgen.generate(spec)
    local p2 = freshPort()
    local specHost = makeHost{ port = p2, world = specWorld, worldSpec = spec }
    local specClient = makeClient{ port = p2 }
    pump(specHost, specClient, 0.2)

    t.eq(specClient.state, 'joined', 'joining a seed-described world works')
    local mismatches = 0
    for y = 1, specWorld.height do
        for x = 1, specWorld.width do
            if specClient.world:tileAt(x, y) ~= specWorld:tileAt(x, y) then
                mismatches = mismatches + 1
            end
        end
    end
    t.eq(mismatches, 0, 'every one of 1024 tiles regenerated identically from the seed')

    local hostDoors, clientDoors = 0, 0
    for _ in pairs(specWorld.doors) do hostDoors = hostDoors + 1 end
    for _ in pairs(specClient.world.doors) do clientDoors = clientDoors + 1 end
    t.ok(hostDoors > 0, ('the generated world has doors (%d)'):format(hostDoors))
    t.eq(clientDoors, hostDoors, 'and the client has the same number')

    specHost:close()
    specClient:close()

    -----------------------------------------------------------------------
    t.describe('an unknown archetype becomes a ghost, loudly')
    Loopback.reset()
    Entity.resetIds(1)
    defineArchetypes()

    local p3 = freshPort()
    local ghostHost = makeHost{ port = p3 }

    local warnings = {}
    local ghostClient, ghostErr = Net.Client.new{
        address = 'loopback:' .. p3, transport = 'loopback',
        onWarning = function(text) warnings[#warnings + 1] = text end,
        onLog = function() end,
    }
    t.ok(ghostClient ~= nil, 'the client connects', ghostErr)
    pump(ghostHost, ghostClient, 0.1)

    -- An entity of a kind no archetype describes. In two processes this is a
    -- client running an older build than the server, which is the common case
    -- and must degrade rather than crash.
    local gargoyle = Entity.new{ id = 777, kind = 'gargoyle', x = 9.5, y = 9.5 }
    gargoyle:add(C.Health{ hp = 5, max = 5 })
    ghostHost.entities[#ghostHost.entities + 1] = gargoyle
    pump(ghostHost, ghostClient, 0.15)

    local ghost = ghostClient.byId[gargoyle.id]
    t.ok(ghost ~= nil, 'the entity still replicated as a position')
    t.near(ghost.x, 9.5, 1e-6, 'at the right place')
    t.ok(not ghost:has('health'),
         'with no components invented to fill the gap')
    t.ok(#warnings > 0, 'and the client said so rather than failing quietly')
    t.ok(tostring(warnings[1]):find('gargoyle'), 'naming the archetype it does not know')

    ghostHost:close()
    ghostClient:close()

    -----------------------------------------------------------------------
    t.describe('commands are the game\'s, not the engine\'s')
    Loopback.reset()
    Entity.resetIds(1)
    defineArchetypes()

    local p4 = freshPort()
    local received = {}
    local cmdHost = makeHost{
        port = p4,
        onCommand = function(h, peer, name, body)
            received[#received + 1] = { name = name, body = body, peer = peer.peerId }
            if name == 'door' then h:toggleDoor(body.tx, body.ty) end
        end,
    }
    cmdHost.world:addDoor(4, 4, false)
    cmdHost.lastWorld = cmdHost.world:snapshot()

    -- Added before the client joins, so it arrives in the join payload and the
    -- client needs no special handling for it.
    local cmdClient = makeClient{ port = p4 }
    pump(cmdHost, cmdClient, 0.2)
    t.ok(cmdClient.world:doorAt(4, 4) ~= nil, 'the join payload carried the door')

    cmdClient:command('door', { tx = 4, ty = 4 })
    pump(cmdHost, cmdClient, 0.2)

    t.eq(#received, 1, 'the command reached the host')
    t.eq(received[1].name, 'door', 'with its name')
    t.eq(received[1].body.tx, 4, 'and its body')
    t.ok(cmdClient.world:doorAt(4, 4).open,
         'and the world change it caused replicated back')

    t.describe('events reach the client')
    local events = {}
    cmdClient.onEvent = function(_, name, body) events[#events + 1] = { name, body } end
    cmdHost:event('hitscan', { from = 1, damage = 12 })
    pump(cmdHost, cmdClient, 0.1)
    t.eq(#events, 1, 'the event arrived')
    t.eq(events[1][1], 'hitscan', 'with its name')
    t.eq(events[1][2].damage, 12, 'and its payload')

    t.describe('the host answers for its own state')
    cmdClient:requestStats()
    pump(cmdHost, cmdClient, 0.1)
    t.ok(cmdClient.stats ~= nil, 'a stats request is answered')
    t.eq(cmdClient.stats.players, cmdHost:playerCount(), 'with the host player count')
    t.eq(cmdClient.stats.doorsOpen, 1, 'and the host door state')

    cmdHost:close()
    cmdClient:close()

    -----------------------------------------------------------------------
    t.describe('a dedicated host is the same host with no local player')
    Loopback.reset()
    Entity.resetIds(1)
    defineArchetypes()

    local p5 = freshPort()
    local steps = 0
    local dedicated, dedErr = Net.Host.new{
        mode = 'dedicated', transport = 'loopback', port = p5,
        world = Worldgen.box(16, 16),
        onStep = function() steps = steps + 1 end,
        onLog = function() end,
    }
    t.ok(dedicated ~= nil, 'a dedicated host comes up', dedErr)
    t.eq(dedicated.localPlayer, nil, 'with no local player')
    t.eq(dedicated:playerCount(), 0, 'and nobody on it')

    local a = makeClient{ port = p5, name = 'a' }
    local b = makeClient{ port = p5, name = 'b' }
    for _ = 1, 30 do
        dedicated:update(1 / 60); a:update(1 / 60); b:update(1 / 60)
    end

    t.eq(a.state, 'joined', 'the first client joined')
    t.eq(b.state, 'joined', 'the second client joined')
    t.eq(dedicated:playerCount(), 2, 'the host has two players and no avatar of its own')
    t.eq(a:playerCount(), 2, 'the first client sees both players')
    t.eq(b:playerCount(), 2, 'the second client sees both players')
    t.ok(a.entityId ~= b.entityId, 'and they are different entities')
    t.ok(a.byId[b.entityId] ~= nil, 'each client can see the other')
    t.ok(b.byId[a.entityId] ~= nil, 'in both directions')
    t.ok(steps > 0, ('the simulation stepped %d times with no window'):format(steps))

    t.describe('one client moving is visible to the other')
    local aOnB = b.byId[a.entityId]
    local startX = aOnB.x
    a:setInput{ forward = 1, angle = 0 }
    for _ = 1, 40 do
        dedicated:update(1 / 60); a:update(1 / 60); b:update(1 / 60)
    end
    t.ok(aOnB.x > startX + 0.2, 'the second client saw the first move')
    t.ok(b.player.x == b.player.x, 'and its own player is still a real position')

    t.describe('a leaving client is despawned everywhere')
    local aId = a.entityId
    a:leave()
    for _ = 1, 30 do dedicated:update(1 / 60); b:update(1 / 60) end
    t.eq(dedicated:playerCount(), 1, 'the host dropped the player')
    t.ok(b.byId[aId] == nil, 'and the other client dropped the entity')

    b:close()
    dedicated:close()
    Loopback.reset()

    -----------------------------------------------------------------------
    t.describe('world payloads, directly')
    local grid = Worldgen.box(8, 6)
    grid:addDoor(3, 3, true)
    local payload = Rep.worldPayload(grid)
    t.eq(payload.kind, 'grid', 'with no spec, the grid itself is sent')
    t.eq(#payload.grid, 6, 'the payload carries every row')
    t.eq(#payload.grid[1], 8, 'and every column')

    local rebuilt = Rep.buildWorld(Net.serialize.decode(Net.serialize.encode(payload)))
    t.ok(rebuilt ~= nil, 'the payload rebuilds a world after a round trip')
    t.eq(rebuilt.width, 8, 'with the right width')
    t.eq(rebuilt:tileAt(1, 1), grid:tileAt(1, 1), 'and the right walls')
    t.ok(rebuilt:doorAt(3, 3) ~= nil, 'and the door')
    t.ok(rebuilt:doorAt(3, 3).open, 'in the state it was in')

    local specPayload = Rep.worldPayload(grid, { width = 8, height = 8, seed = 5 })
    t.eq(specPayload.kind, 'spec', 'with a spec, only the seed is sent')
    t.eq(specPayload.grid, nil, 'and no grid')

    -----------------------------------------------------------------------
    t.describe('G2: locks, push-walls, secrets and hazards ride the payload')

    -- Locks and push-walls are mutable world state the way door-open is; a
    -- joining client (and a mid-session save, which shares this exact path)
    -- must see the red door still locked and the half-slid wall where it now
    -- stands. Secrets and hazards are static boxes, but grid payloads carry
    -- no map headers, so without this a late joiner's world has no idea they
    -- exist.
    local g2 = Worldgen.box(10, 10)
    g2:addDoor(4, 4, false)
    g2:lockDoor(4, 4, 'key.red')
    g2.grid[6][6] = 2
    g2:addPushWall(6, 6, { dx = 1, dy = 0, distance = 3, interval = 0.25 })
    g2:pushWall(6, 6)
    g2:update(0.25)                       -- one step: now at 7,6 with 2 left
    g2.secrets = { { x1 = 2, y1 = 2, x2 = 3, y2 = 3, storey = 1, name = 'nook' } }
    g2.hazards = { { kind = 'lava', x1 = 8, y1 = 8, x2 = 9, y2 = 9, storey = 1 } }

    local g2back = Rep.buildWorld(
        Net.serialize.decode(Net.serialize.encode(Rep.worldPayload(g2))))
    t.eq(g2back:doorLock(4, 4), 'key.red', 'the lock survives the wire')
    t.eq(select(2, g2back:toggleDoor(4, 4)), 'locked', 'and still refuses')
    local pwBack = g2back:pushWallAt(7, 6)
    t.ok(pwBack, 'the push-wall is at its CURRENT tile, not the authored one')
    t.eq(pwBack.left, 2, 'with the distance it has left')
    t.eq(g2back:isSolid(6, 6), false, 'the tile it vacated is open')
    t.eq(g2back:isSolid(7, 6), true, 'and the one it holds is solid')
    t.eq(g2back.secrets[1].name, 'nook', 'secret boxes ride')
    t.eq(g2back.hazards[1].kind, 'lava', 'hazard boxes ride')

    -- The spec form carries the same extras: a procedural world can gain a
    -- console-locked door mid-session and a late joiner must still see it.
    local specG2 = Rep.worldPayload(g2, { width = 10, height = 10, seed = 7 })
    t.ok(specG2.locks and #specG2.locks == 1, 'spec payloads carry locks too')
    t.ok(specG2.pushwalls and #specG2.pushwalls == 1, 'and push-walls')

    -- A payload from before G2 (no extras) still builds — old saves open.
    local old = Rep.worldPayload(Worldgen.box(6, 6))
    old.locks, old.pushwalls, old.secrets, old.hazards = nil, nil, nil, nil
    t.ok(Rep.buildWorld(old), 'a pre-G2 payload still builds a world')

    local broken, brokenErr = Rep.buildWorld({ kind = 'grid' })
    t.ok(broken == nil and brokenErr ~= nil, 'a payload with no grid is refused')
    local unknown, unknownErr = Rep.buildWorld({ kind = 'telepathy' })
    t.ok(unknown == nil and unknownErr ~= nil, 'an unknown payload kind is refused')
    t.ok(Rep.buildWorld(nil) == nil, 'a missing payload is refused')

    t.describe('a join that is never answered fails with an explanation')
    -- The case ENet cannot report: the connection is established and the host then
    -- never answers. No transport event ever arrives, so without a timeout of its
    -- own the client says "connecting..." forever, which is the least useful thing
    -- it could say and reads to a player as a hang.
    Loopback.reset()
    local silentPort = freshPort()
    local mute = require('meatray.net.transport.loopback').new{}
    mute:listen{ port = silentPort }        -- listens, and answers nothing at all

    local warned
    local waiting = Net.Client.new{
        address = 'loopback:' .. silentPort, transport = 'loopback',
        joinTimeout = 0.5,
        onWarning = function(text) warned = text end,
        onLog = function() end,
    }
    t.ok(waiting ~= nil, 'the connection itself succeeds')
    for _ = 1, 10 do waiting:update(1 / 60) end
    t.eq(waiting.state, 'connecting', 'and it waits, as it should')
    for _ = 1, 40 do waiting:update(1 / 60) end
    t.eq(waiting.state, 'failed', 'until the join timeout expires')
    t.ok(tostring(waiting.reason):find('no answer'), 'and it says it got no answer')
    t.ok(warned and warned:find('netcheck'),
         'naming the command that distinguishes a blocked machine from a wrong address')
    waiting:close()
    mute:close()
    Loopback.reset()

    t.describe('joining nothing fails with a reason, not a crash')
    local nowhere, nowhereErr = Net.Client.new{ address = 'loopback:65000',
                                                transport = 'loopback',
                                                onLog = function() end }
    t.ok(nowhere == nil and nowhereErr ~= nil, 'connecting to a dead port is reported')

    local noAddress, noAddressErr = Net.join(nil)
    t.ok(noAddress == nil and noAddressErr ~= nil, 'join with no address is reported')

    local noWorld, noWorldErr = Net.Host.new{ transport = 'loopback', port = 9001 }
    t.ok(noWorld == nil and noWorldErr:find('world'), 'a host with no world is refused')

    -----------------------------------------------------------------------
    t.describe('destroyed walls reach the client')

    -- Destruction is the second thing about a world that changes while it runs,
    -- and unlike a snapshot a world delta has no successor packet to correct it.
    -- These cases care about the client's *world*, not about what was sent.
    Loopback.reset()
    Entity.resetIds(1)

    local pD = freshPort()
    local dWorld = Worldgen.box(20, 20)
    -- box() is a hollow room, so stand a pillar up to knock down. It has to exist
    -- before the host starts: the client builds its world from the join payload.
    dWorld.grid[5][5] = 1
    t.eq(dWorld:setDestructible(5, 5, 10), true, 'the pillar is destructible')

    local dHost = makeHost{ port = pD, world = dWorld }
    local dClient = makeClient{ port = pD, name = 'sapper' }
    pump(dHost, dClient, 0.4)

    t.ok(dClient.world ~= nil, 'the client has a world')
    t.eq(dClient.world:isSolid(5, 5), true, 'which agrees the wall is standing')

    dWorld:damageTile(5, 5, 4)
    pump(dHost, dClient, 0.3)
    t.eq(dClient.world:isSolid(5, 5), true, 'a wall that only took damage does not move')

    dWorld:damageTile(5, 5, 6)
    pump(dHost, dClient, 0.3)
    t.eq(dClient.world:tileAt(5, 5), World.RUBBLE, 'the destroyed wall reaches the client')
    t.eq(dClient.world:isSolid(5, 5), false, 'and the client stops colliding with it')

    -- The repair direction travels as a key *disappearing* from the snapshot
    -- rather than as an explicit message, which is the part of the diff most
    -- likely to be wrong: sending only the keys still present would leave this
    -- client believing the wall is rubble forever.
    dWorld:repairTile(5, 5)
    pump(dHost, dClient, 0.3)
    t.eq(dClient.world:isSolid(5, 5), true, 'a repaired wall stands again on the client')

    -- A client joining after the fact must see the world as it is now, not as
    -- the map was authored.
    dWorld:setDestructible(5, 5, 1)
    dWorld:destroyTile(5, 5)
    pump(dHost, dClient, 0.3)

    local lateClient = makeClient{ port = pD, name = 'latecomer' }
    pump(dHost, lateClient, 0.5)
    t.eq(lateClient.world:isSolid(5, 5), false,
         'a client joining mid-round sees the wall already down')

    dClient:close()
    lateClient:close()
    dHost:close()

    -----------------------------------------------------------------------
    t.describe('G3: a dead peer comes back as a new entity')

    local rPort = freshPort()
    local shielded = 0
    local rHost = makeHost{
        port = rPort,
        respawn = { delay = 0.25 },
        onPeerRespawn = function() shielded = shielded + 1 end,
    }
    local rClient = makeClient{ port = rPort, name = 'lazarus' }
    pump(rHost, rClient, 0.5)
    t.ok(rClient.player ~= nil, 'joined and bound to an entity')
    local firstId = rClient.entityId

    -- The host kills the peer's entity — a rocket, a lava floor, whatever.
    local deadPeer
    for _, peer in pairs(rHost.peers) do
        if peer.entity then deadPeer = peer end
    end
    deadPeer.entity.dead = true

    pump(rHost, rClient, 0.1)
    t.eq(deadPeer.entity, nil, 'the reap released the corpse')
    t.ok(deadPeer.respawnIn ~= nil, 'and the wait began')

    pump(rHost, rClient, 0.5)
    t.ok(deadPeer.entity ~= nil, 'the host built a new entity')
    t.ok(rClient.entityId ~= firstId, 'the client was told its NEW id')
    t.ok(rClient.player ~= nil, 'and rebound off the next snapshot')
    t.eq(rClient.player.id, rClient.entityId, 'to that entity, not the corpse')
    t.ok(not rClient.player.dead, 'which is alive')
    t.eq(shielded, 1, 'the game hook fired exactly once, for the shield')

    -- Dying again works the same way: the ledger is per-death, not per-life.
    deadPeer.entity.dead = true
    pump(rHost, rClient, 0.6)
    t.eq(shielded, 2, 'a second death respawns a second time')

    -- Disabled means dead stays dead — an elimination mode owns its rounds.
    local ePort = freshPort()
    local eHost = makeHost{ port = ePort, respawn = false }
    local eClient = makeClient{ port = ePort, name = 'oneshot' }
    pump(eHost, eClient, 0.5)
    for _, peer in pairs(eHost.peers) do peer.entity.dead = true end
    pump(eHost, eClient, 1.0)
    for _, peer in pairs(eHost.peers) do
        t.eq(peer.entity, nil, 'respawn = false leaves the peer down')
    end

    rClient:close(); rHost:close()
    eClient:close(); eHost:close()

    -----------------------------------------------------------------------
    t.describe('D33: RCON over the real transport')

    local xPort = freshPort()
    local xHost = makeHost{ port = xPort }
    local mapAsked
    xHost:attachRcon{ secret = 'letmein', onMap = function(m) mapAsked = m end }
    local xClient = makeClient{ port = xPort, name = 'admin' }
    local replies = {}
    xClient.onRcon = function(_, ok, reply) replies[#replies + 1] = { ok, reply } end
    pump(xHost, xClient, 0.4)

    -- A command before authenticating is refused.
    xClient:rcon('status')
    pump(xHost, xClient, 0.3)
    t.eq(replies[#replies][1], false, 'a command before auth is refused')
    t.ok(replies[#replies][2]:find('not authenticated'), 'and says why')

    -- A wrong password fails.
    xClient:rconAuth('nope')
    pump(xHost, xClient, 0.3)
    t.eq(replies[#replies][1], false, 'a wrong password fails')

    -- The right one, then a command that acts on the host.
    xClient:rconAuth('letmein')
    pump(xHost, xClient, 0.3)
    t.eq(replies[#replies][1], true, 'the right password authenticates')

    xClient:rcon('status')
    pump(xHost, xClient, 0.3)
    t.eq(replies[#replies][1], true, 'status runs once authed')
    t.ok(replies[#replies][2]:find('players'), 'and reports over the wire')

    xClient:rcon('map arena2')
    pump(xHost, xClient, 0.3)
    t.eq(mapAsked, 'arena2', 'a map command reached the host and fired onMap')

    -- A second client is its own session — auth does not carry between peers.
    local xClient2 = makeClient{ port = xPort, name = 'stranger' }
    local replies2 = {}
    xClient2.onRcon = function(_, ok, reply) replies2[#replies2 + 1] = { ok, reply } end
    pump(xHost, xClient2, 0.4)
    xClient2:rcon('kick admin')
    pump(xHost, xClient2, 0.3)
    t.eq(replies2[#replies2][1], false,
         'a second peer is unauthenticated even while the first is authed')

    xClient:close(); xClient2:close(); xHost:close()

    -----------------------------------------------------------------------
    t.describe('F7: a vote called and passed over the transport')

    local vPort = freshPort()
    local restarted = false
    local vHost = makeHost{ port = vPort }
    vHost:attachVote{ duration = 30, threshold = 0.5,
                      onRestart = function() restarted = true end }
    local vA = makeClient{ port = vPort, name = 'a' }
    local vB = makeClient{ port = vPort, name = 'b' }
    local seenA = {}
    vA.onVote = function(_, body) seenA[#seenA + 1] = body end
    pump(vHost, vA, 0.4)
    pump(vHost, vB, 0.4)
    pump(vHost, vA, 0.2); pump(vHost, vB, 0.2)

    -- Two peers connected (a, b). A calls a restart; its own yes is implied.
    -- Electorate is 2, so it needs floor(0.5*2)+1 = 2 yes.
    vA:callVote('restart')
    pump(vHost, vA, 0.2); pump(vHost, vB, 0.2)
    t.ok(vHost.vote:isActive(), 'the vote is live on the host')
    t.eq(vHost.vote:status().yes, 1, 'the caller\'s yes is in')

    -- B votes yes: now 2 of 2, it passes and enacts.
    vB:castVote(true)
    pump(vHost, vA, 0.2); pump(vHost, vB, 0.2)
    pump(vHost, nil, 0.1)
    t.eq(restarted, true, 'the passed restart vote enacted on the host')
    t.eq(vHost.vote:isActive(), false, 'and the vote closed')

    vA:close(); vB:close(); vHost:close()

    Net.session = nil
    Loopback.reset()
    Entity.clearArchetypes()
    Entity.resetIds(1)
end
