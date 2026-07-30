--[[
    The relay transport, end to end, with no sockets.

    A relay, a relayed host and two relayed clients in one LuaJIT process. The
    only thing that is not production code is the wire underneath the relay: the
    frame format, the session logic, the forwarding, the transport wrapper, the
    real Host and the real Client are all the shipped ones.

    That is the same trick tests/test_net_replication.lua plays, taken one layer
    further. The relay's inner transport is a parameter precisely so this is
    possible -- `inner = 'loopback'` and the whole triangle fits in a test that
    never opens a port and never sleeps.

    The last section is the one to read: a punch that fails must not be the end
    of the road, so a real host and two real clients complete a real handshake
    and see each other, through a relay, with nothing in host.lua or client.lua
    changed to allow it.
]]

return function(t)
    local Transport = require('meatray.net.transport')
    local Loopback  = require('meatray.net.transport.loopback')
    local RelayT    = require('meatray.net.transport.relay')
    local RelayHost = require('masterserver.relayhost')
    local Relay     = require('masterserver.relay')
    local Wire      = require('meatray.net.relaywire')
    local Net       = require('meatray.net')
    local Worldgen  = require('meatray.sim.worldgen')
    local P         = require('meatray.net.protocol')

    local function fixedRandom(seed)
        local n = seed or 4242
        return function()
            n = (n * 1103515245 + 12345) % 2147483648
            return (n % 4093) / 4093
        end
    end

    local nextPort = 6900
    local function freshPort()
        nextPort = nextPort + 1
        return nextPort
    end

    -- A relay on a loopback port, plus the injectables a dial needs: a clock
    -- that never touches a wall, a sleep that does not, and a pump that gives
    -- the in-process relay a turn. Without the pump the relay would never run
    -- during a dial and every dial would time out -- which is exactly what a
    -- real client would see if the relay were down, and is tested below.
    local function newRelay(opts)
        opts = opts or {}
        local port = opts.port or freshPort()

        local logic = Relay.new{
            randomSource   = fixedRandom(opts.seed),
            maxSessions    = opts.maxSessions,
            maxSlots       = opts.maxSlots,
            maxPerAddress  = opts.maxPerAddress,
            sessionTimeout = opts.sessionTimeout,
            allocationSecret = opts.allocationSecret,
        }

        local server = assert(RelayHost.new{
            transport = 'loopback', port = port, relay = logic,
            onLog = function() end,
        })
        assert(server:start())

        local clock = 0
        local kit = {
            server = server,
            logic  = logic,
            port   = port,
            address = 'loopback:' .. port,
            clock  = function() clock = clock + 0.01; return clock end,
            sleep  = function() end,
            pump   = function() server:update(0.001) end,
        }
        return kit
    end

    local function relayTransport(kit, opts)
        opts = opts or {}

        -- Written as a statement, not `opts.pump ~= nil and opts.pump or fallback`.
        -- That form yields the fallback whenever the left side is `false`, which
        -- is the trap this codebase names in its own transport source.
        local pump = opts.pump
        if pump == nil then pump = kit and kit.pump end

        return RelayT.new{
            inner = 'loopback',
            relay = opts.relay or (kit and kit.address),
            allocationSecret = opts.allocationSecret,
            dialTimeout = opts.dialTimeout or 2,
            clock = opts.clock or (kit and kit.clock),
            sleep = opts.sleep or (kit and kit.sleep),
            pump  = pump,
        }
    end

    local function drain(transport)
        local out = {}
        while true do
            local event = transport:service()
            if not event then return out end
            out[#out + 1] = event
        end
    end

    local function firstOfType(events, kind)
        for _, event in ipairs(events) do
            if event.type == kind then return event end
        end
        return nil
    end

    -----------------------------------------------------------------------
    t.describe('it is a transport like any other')

    -- Selected by name, exactly as `enet` and `loopback` are. That is the whole
    -- of "a transport is an addition rather than a rewrite": nothing in host.lua
    -- or client.lua knows this file exists.
    t.ok(Transport.registered('relay'), 'the relay transport is registered')
    t.ok(Transport.resolve('relay') ~= nil, 'and resolves to a factory')

    local names = Transport.names()
    local listed = false
    for _, name in ipairs(names) do
        if name == 'relay' then listed = true end
    end
    t.ok(listed, 'and is listed among the transports')

    Loopback.reset()

    -----------------------------------------------------------------------
    t.describe('a host opens a session and gets a ticket')

    local kit = newRelay{ seed = 11 }
    local host = assert(relayTransport(kit))

    t.eq(host.name, 'relay', 'it names itself')

    local listened, listenErr = host:listen{ maxPeers = 8, channels = P.CHANNELS }
    t.ok(listened, 'a relayed host comes up', listenErr)
    t.ok(Wire.isHex(host.session), 'it holds a session id')
    t.ok(Wire.isHex(host.secret), 'and a secret')
    t.eq(kit.logic:sessionCount(), 1, 'and the relay agrees there is one session')

    local ticket = host:ticket()
    t.ok(ticket ~= nil, 'and it can hand out a ticket')
    local parsed = Wire.parseTicket(ticket)
    t.eq(parsed and parsed.session, host.session, 'whose session is the one it opened')
    t.eq(parsed and parsed.address, kit.address, 'and whose address is the relay it dialled')

    -- A relay session IS the traversal, so the transport says it cannot punch
    -- rather than arming an attempt nobody will make. host.lua reads exactly
    -- this to decide whether to claim a punch is possible.
    t.eq(host.punch, nil, 'a relay transport does not offer to punch')
    t.eq(host.localPort, nil, 'nor to name a port to be introduced on')
    t.ok(host.setTimeout ~= nil, 'but it does carry a timeout through to the relay link')

    -----------------------------------------------------------------------
    t.describe('a client joins with the ticket, and only with the ticket')

    local client = assert(relayTransport(kit))
    local peer, connectErr = client:connect(ticket)
    t.ok(peer ~= nil, 'a client with the ticket joins', connectErr)
    t.eq(kit.logic:slotCount(host.session), 1, 'and occupies a slot')

    kit.pump()
    local hostEvents = drain(host)
    local joined = firstOfType(hostEvents, 'connect')
    t.ok(joined ~= nil, 'the host sees a connect event, like any other transport')

    local hostPeer = joined and joined.peer
    t.ok(host:key(hostPeer) ~= nil, 'with a peer that has a key')

    -- The address is the CLIENT's, as the relay reported it, not the relay's.
    -- Ban-by-address through a relay must ban the player and not the machine
    -- forwarding for everybody.
    t.ok(host:address(hostPeer) ~= kit.address,
         'and the peer address is the client, not the relay',
         tostring(host:address(hostPeer)))

    local clientEvents = drain(client)
    t.ok(firstOfType(clientEvents, 'connect') ~= nil,
         'and the client sees its own connect, which is where its handshake starts')

    -- A stranger with the session id but not the secret gets nowhere.
    local stranger = assert(relayTransport(kit))
    local strangerPeer, strangerErr = stranger:connect(
        ('relay://%s/%s/00000000000000000000000000000000'):format(kit.address, host.session))
    t.eq(strangerPeer, nil, 'a stranger with the wrong secret is refused')
    t.ok(strangerErr and strangerErr:find(Relay.NO_SESSION, 1, true) ~= nil,
         'and told the same thing a wrong session id is told', strangerErr)
    stranger:close()

    -- Something that is not a ticket at all is refused before anything is dialled.
    local typo = assert(relayTransport(kit))
    local typoPeer, typoErr = typo:connect('198.51.100.5:6789')
    t.eq(typoPeer, nil, 'a plain address is not a relay ticket')
    t.ok(typoErr and typoErr:find('relay://', 1, true) ~= nil,
         'and the reason says what one looks like', typoErr)
    typo:close()

    -----------------------------------------------------------------------
    t.describe('traffic, both ways, with reliability intact')

    client:send(peer, 'up', P.CH_RELIABLE, true)
    kit.pump()
    local up = drain(host)
    local upEvent = firstOfType(up, 'receive')
    t.ok(upEvent ~= nil, 'a client message reaches the host')
    t.eq(upEvent and upEvent.data, 'up', 'intact')
    t.eq(upEvent and upEvent.channel, P.CH_RELIABLE, 'on the channel it was sent on')
    t.eq(upEvent and host:key(upEvent.peer), host:key(hostPeer),
         'attributed to the peer that sent it')

    host:send(hostPeer, 'down', P.CH_STREAM, false)
    kit.pump()
    local down = drain(client)
    local downEvent = firstOfType(down, 'receive')
    t.ok(downEvent ~= nil, 'a host message reaches the client')
    t.eq(downEvent and downEvent.data, 'down', 'intact')
    t.eq(downEvent and downEvent.channel, P.CH_STREAM, 'on the stream channel')

    -- A payload the relay must not interpret: nulls, newlines, and the frame
    -- format's own header values.
    local awkward = string.char(0, 255, 127, 128) .. 'body\r\n'
    host:send(hostPeer, awkward, P.CH_STREAM, false)
    kit.pump()
    local raw = firstOfType(drain(client), 'receive')
    t.eq(raw and raw.data, awkward, 'a payload containing the header bytes survives')

    -- The snapshot budget, relayed. The whole reason the header is one byte.
    local snapshot = string.rep('s', P.MTU_SAFE_BYTES)
    host:send(hostPeer, snapshot, P.CH_STREAM, false)
    kit.pump()
    local big = firstOfType(drain(client), 'receive')
    t.eq(big and #big.data, P.MTU_SAFE_BYTES,
         'a snapshot at the engine cap crosses the relay whole')

    -----------------------------------------------------------------------
    t.describe('broadcast leaves the host once, not once per player')

    local second = assert(relayTransport(kit))
    local secondPeer = assert(second:connect(ticket))
    kit.pump()
    drain(host)
    drain(second)

    -- The host's uplink is the constrained half of a relayed session: it is the
    -- side sending a snapshot stream. Fanning out here would multiply it by the
    -- player count before it ever left the machine.
    local sentBefore = host.stats.sent
    host:broadcast('everyone', P.CH_STREAM, false)
    t.eq(host.stats.sent - sentBefore, 1, 'a broadcast is one frame from the host')

    kit.pump()
    local gotA = firstOfType(drain(client), 'receive')
    local gotB = firstOfType(drain(second), 'receive')
    t.eq(gotA and gotA.data, 'everyone', 'and both clients receive it')
    t.eq(gotB and gotB.data, 'everyone', 'both of them')

    -- A client's broadcast goes to the host and nowhere else, because a client
    -- has exactly one peer.
    second:broadcast('mine', P.CH_RELIABLE, true)
    kit.pump()
    local hostGot = firstOfType(drain(host), 'receive')
    t.eq(hostGot and hostGot.data, 'mine', "a client's broadcast reaches its host")
    t.eq(firstOfType(drain(client), 'receive'), nil,
         'and never reaches another client')

    -----------------------------------------------------------------------
    t.describe('round-trip time counts both hops')

    -- The relay is the only party that can see both halves, so it reports the
    -- far one and each end adds its own. Halving this would make lag
    -- compensation rewind by half the real latency, and shots would land behind
    -- moving targets -- which reads as bad aim rather than as a network fault.
    kit.server:pumpRtt()
    kit.pump()
    drain(host)
    drain(client)

    hostPeer.rtt = 40                     -- as if the relay had reported it
    client.hopRtt = 25

    -- The loopback inner transport reports 0 for its own hop, so the sum is the
    -- reported far hop exactly, which is what makes the arithmetic assertable.
    t.eq(host:rtt(hostPeer), 40, "a host's rtt includes the relay's hop to the client")
    t.eq(client:rtt(peer), 25, "and a client's includes the relay's hop to the host")

    -----------------------------------------------------------------------
    t.describe('a kick reaches the player, with the reason')

    host:disconnect(hostPeer, 1)
    kit.pump()
    local kicked = firstOfType(drain(second), 'disconnect')
        or firstOfType(drain(client), 'disconnect')
    t.ok(kicked ~= nil, 'the kicked client is disconnected')
    t.ok(kit.logic:slotCount(host.session) <= 1, 'and its slot is freed')

    host:close()
    client:close()
    second:close()

    -----------------------------------------------------------------------
    t.describe('failure: the relay is unreachable')

    Loopback.reset()

    -- Nothing is listening. This is the "the relay is down" case, and it must be
    -- an immediate reason rather than a wait.
    local orphanKit = newRelay{ seed = 12 }
    orphanKit.server:stop()

    local orphan = assert(relayTransport(orphanKit))
    local up1, upErr = orphan:listen{}
    t.eq(up1, nil, 'a host cannot come up on a relay that is not there')
    t.ok(upErr and upErr:find('cannot reach the relay', 1, true) ~= nil,
         'and is told so plainly', upErr)
    orphan:close()

    -- No relay address at all: a mistake in the call, reported as one, with the
    -- line that fixes it.
    local nameless = assert(RelayT.new{ inner = 'loopback',
                                        clock = function() return 0 end,
                                        sleep = function() end })
    local up2, namelessErr = nameless:listen{}
    t.eq(up2, nil, 'a relay transport with no relay address refuses to listen')
    t.ok(namelessErr and namelessErr:find('relay = ', 1, true) ~= nil,
         'and the reason contains the fix', namelessErr)
    nameless:close()

    -----------------------------------------------------------------------
    t.describe('failure: the relay accepts and then says nothing')

    -- The nastiest of the three, because it looks like a working connection. The
    -- dial has a budget, states it, and reports the time actually spent -- this
    -- project has already paid once for an impatient probe that read a working
    -- port as a blocked one and produced four pointless firewall rules.
    Loopback.reset()
    local muteKit = newRelay{ seed = 13 }

    local ticks = 0
    local mute = assert(RelayT.new{
        inner = 'loopback', relay = muteKit.address,
        dialTimeout = 0.5,
        clock = function() ticks = ticks + 1; return ticks * 0.1 end,
        sleep = function() end,
        pump  = nil,                        -- the relay never gets a turn
    })

    local up3, muteErr = mute:listen{}
    t.eq(up3, nil, 'a relay that never answers is given up on')
    t.ok(muteErr and muteErr:find('0.5s', 1, true) ~= nil,
         'and the reason states the budget', muteErr)
    t.ok(muteErr and muteErr:find('waited', 1, true) ~= nil,
         'and the time actually spent, so nobody has to guess whether it was long enough',
         muteErr)
    t.ok(ticks < 200, 'and it gave up rather than spinning forever',
         ('%d clock reads'):format(ticks))
    mute:close()

    -----------------------------------------------------------------------
    t.describe('failure: the relay is full, or private')

    Loopback.reset()
    local fullKit = newRelay{ seed = 14, maxSessions = 1 }

    local firstHost = assert(relayTransport(fullKit))
    t.ok(firstHost:listen{}, 'the first host gets the only session')

    local secondHost = assert(relayTransport(fullKit))
    local up4, fullErr = secondHost:listen{}
    t.eq(up4, nil, 'the second is refused')
    t.ok(fullErr and fullErr:find('full', 1, true) ~= nil,
         'and told the relay is full rather than left waiting', fullErr)
    firstHost:close()
    secondHost:close()

    Loopback.reset()
    local privateKit = newRelay{ seed = 15, allocationSecret = 'shibboleth' }

    local uninvited = assert(relayTransport(privateKit))
    local up5, privateErr = uninvited:listen{}
    t.eq(up5, nil, 'a private relay refuses a host with no secret')
    t.ok(privateErr and privateErr:find('private', 1, true) ~= nil,
         'and says why', privateErr)
    uninvited:close()

    local invited = assert(relayTransport(privateKit, { allocationSecret = 'shibboleth' }))
    t.ok(invited:listen{}, 'and accepts one with it')
    invited:close()

    -----------------------------------------------------------------------
    t.describe('failure: the relay dies with players on it')

    Loopback.reset()
    local doomedKit = newRelay{ seed = 16 }

    local doomedHost = assert(relayTransport(doomedKit))
    assert(doomedHost:listen{})
    local doomedClient = assert(relayTransport(doomedKit))
    assert(doomedClient:connect(doomedHost:ticket()))
    doomedKit.pump()
    drain(doomedHost)
    drain(doomedClient)

    doomedKit.server:stop()
    doomedKit.pump()

    local hostAfter = drain(doomedHost)
    t.ok(firstOfType(hostAfter, 'disconnect') ~= nil,
         'the host sees every player disconnect, not a freeze')
    t.ok(doomedHost.lost ~= nil, 'and knows why', tostring(doomedHost.lost))

    local clientAfter = drain(doomedClient)
    t.ok(firstOfType(clientAfter, 'disconnect') ~= nil,
         'and the client sees its session end')
    t.ok(doomedClient.lost and doomedClient.lost:find('relay', 1, true) ~= nil,
         'with a reason that names the relay', tostring(doomedClient.lost))

    -- And nothing hangs afterwards: service returns nil rather than looping.
    t.eq(doomedHost:service(), nil, 'and service goes quiet rather than spinning')
    t.eq(doomedHost:send(nil, 'x', 0, true), false, 'sending to nobody is false, not an error')

    doomedHost:close()
    doomedClient:close()

    -----------------------------------------------------------------------
    t.describe('a real host and real clients, through a real relay')

    -- The point of the whole phase, asserted with the shipped Host and Client
    -- and nothing stubbed. A punch that fails is no longer the end of the road.
    Loopback.reset()
    local live = newRelay{ seed = 17 }

    local hostTransport = assert(relayTransport(live))

    local server, serverErr = Net.Host.new{
        mode = 'dedicated',
        transport = hostTransport,        -- an instance: the documented escape hatch
        port = 6789,
        world = Worldgen.box(12, 12),
        snapshotRate = 20,
        onLog = function() end,
        onWarning = function() end,
    }
    t.ok(server ~= nil, 'a dedicated host comes up on the relay transport', serverErr)

    local relayTicket = hostTransport:ticket()
    t.ok(relayTicket ~= nil, 'and can publish a ticket for it')

    -- A punch is not attempted, and that is correct rather than a gap: the relay
    -- session is the traversal.
    t.eq(server.canPunch, false, 'the host reports that it will not punch')

    local clientA, clientAErr = Net.Client.new{
        address = relayTicket,
        transport = relayTransport(live),
        name = 'ada',
        punch = false,
        onLog = function() end,
    }
    t.ok(clientA ~= nil, 'a client joins through the relay', clientAErr)

    local clientB, clientBErr = Net.Client.new{
        address = relayTicket,
        transport = relayTransport(live),
        name = 'grace',
        punch = false,
        onLog = function() end,
    }
    t.ok(clientB ~= nil, 'and so does a second', clientBErr)

    -- The relay gets a turn between every side's update, which is what a
    -- separate process gets for free.
    local function step(seconds)
        for _ = 1, math.ceil((seconds or 0.1) / (1 / 60)) do
            live.server:update(1 / 60)
            if server then server:update(1 / 60) end
            live.server:update(0)
            if clientA then clientA:update(1 / 60) end
            if clientB then clientB:update(1 / 60) end
            live.server:update(0)
        end
    end

    step(0.5)

    t.eq(clientA and clientA.state, 'joined', 'the first handshake completes over the relay')
    t.eq(clientB and clientB.state, 'joined', 'and the second')
    t.eq(server:playerCount(), 2, 'and the host counts both players')

    -- Snapshots arrive, which is the traffic the whole byte budget was sized on.
    -- `lastTick` starts at -1 and only ever moves when a snapshot is applied.
    t.ok(clientA.lastTick > 0, 'snapshots reach the first client',
         tostring(clientA.lastTick))
    t.ok(clientB.lastTick > 0, 'and the second', tostring(clientB.lastTick))

    -- Both players exist on both clients: that is replication working end to end
    -- across two relayed hops.
    local function entityCount(client)
        local n = 0
        for _ in pairs(client.entities or {}) do n = n + 1 end
        return n
    end
    t.ok(entityCount(clientA) >= 2, 'the first client sees both players',
         tostring(entityCount(clientA)))
    t.ok(entityCount(clientB) >= 2, 'and so does the second',
         tostring(entityCount(clientB)))

    -- The host sees the clients' real addresses, not the relay's, so moderation
    -- still works through a relay.
    local addresses = {}
    for _, peerRow in pairs(server.peers or {}) do
        addresses[#addresses + 1] = tostring(peerRow.address)
    end
    t.eq(#addresses, 2, 'the host has an address for each player')
    local distinct = addresses[1] ~= addresses[2]
    t.ok(distinct, 'and they are distinct, not both the relay',
         table.concat(addresses, ' / '))

    -- A byte forwarded is a byte the relay paid for, and it says so.
    t.ok(live.logic.stats.forwarded > 0, 'the relay forwarded traffic')
    t.ok(live.logic.stats.bytesOut > 0, 'and counted what it emitted',
         tostring(live.logic.stats.bytesOut))
    t.eq(live.logic.stats.throttled, 0, 'without throttling a normal session')

    -- One client leaves. The other keeps playing, which is the property that
    -- says a slot is freed rather than a session torn down.
    clientA:close()
    step(0.3)
    t.eq(server:playerCount(), 1, 'a client leaving is seen by the host')
    t.eq(clientB.state, 'joined', 'and the other client keeps playing')

    clientB:close()
    server:close()

    Loopback.reset()
end
