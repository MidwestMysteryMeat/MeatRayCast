--[[
    UDP hole punching, in the parts a machine with no NAT can actually decide.

    WHAT THIS FILE CAN AND CANNOT PROVE, said first because the distinction is
    the whole reason to read it.

    It cannot prove NAT traversal. There is one machine here and a loopback
    interface, and there is no NAT to traverse -- so no test in this file, and no
    test that could be written in this file, says the feature works on the
    internet. The parts that needed real sockets were watched happening against a
    real registry and a real UDP listener, and the observation that matters is
    recorded on EnetMT:punch: a host bound to 6789, told to punch, emits a
    52-byte datagram whose SOURCE PORT is 6789. That source port is the entire
    architectural claim -- a punch from any other socket opens a mapping for a
    port nothing is listening on -- and it is a fact about ENet's socket, not
    about our arithmetic.

    What is decided here is everything that is arithmetic: that the introduction
    is requested and then not waited for, that the host punches at the address
    the registry gave and not one a client claimed, that a burst is a burst, that
    a game's own handler wins, and that every failure lands on the direct attempt
    instead of on a hang.
]]

return function(t)
    local Net       = require('meatray.net')
    local Transport = require('meatray.net.transport')
    local Loopback  = require('meatray.net.transport.loopback')
    local Master    = require('meatray.net.discovery.master')
    local Registry  = require('masterserver.registry')
    local Host      = Net.Host
    local Worldgen  = require('meatray.sim.worldgen')

    -- Registers a discovery backend into every live copy of the discovery
    -- module, and it has to, which is worth explaining rather than looking
    -- superstitious.
    --
    -- test_headless clears package.loaded for every net module and requires them
    -- again with the `love` global removed -- which is the only way to prove they
    -- do not need it, and is deliberately not "fixed". The side effect is that
    -- two live copies of each module exist afterwards: whatever was loaded first
    -- still holds the original table, while `require` now hands back the second.
    -- So `require('meatray.net.discovery')` is not necessarily the table
    -- host.lua closed over, and registering into the wrong one produces a
    -- backend that demonstrably exists and that the host has never heard of.
    --
    -- Registering into both is order-independent. Picking one is a coin flip
    -- that comes up wrong the day the suite list is reordered.
    local function registerInto(name, impl)
        local seen = {}
        for _, copy in ipairs{ require('meatray.net.discovery'), Net.discovery } do
            if copy and not seen[copy] then
                seen[copy] = true
                copy.register(name, impl)
            end
        end
    end

    local function registerProbe(impl)  registerInto('punch-probe', impl) end
    local function registerProbe2(impl) registerInto('punch-probe-quiet', impl) end

    ---------------------------------------------------------------------
    t.describe('a transport can be asked to punch, and to name its own port')

    Loopback.reset()

    local lb = Transport.new('loopback', { clientAddress = '10.0.0.7:5000' })
    t.eq(lb:localPort(), 5000, 'a client transport reports the port it is dialling from')
    t.eq(lb:open(), true, 'opening a socket that needs no socket succeeds')

    t.eq(lb:punch('198.51.100.9:6789'), true, 'a punch is accepted')
    t.eq(#lb:punches(), 1, 'and recorded')
    t.eq(lb:punches()[1], '198.51.100.9:6789', 'at the address it was given')

    t.eq(lb:punch(''), nil, 'an empty address is refused')
    t.eq(lb:punch(nil), nil, 'and so is no address at all')
    t.eq(#lb:punches(), 1, 'neither is recorded as a punch')

    local listener = Transport.new('loopback', {})
    listener:listen{ port = 7400 }
    t.eq(listener:localPort(), 7400, 'a listening transport reports the port it listens on')

    ---------------------------------------------------------------------
    t.describe('the registry knows where to nudge a listed host')

    local reg = Registry.new{ randomSource = function() return 0.5 end }
    local challenge = reg:announce('198.51.100.60', {
        name = 'Somewhere', map = 'arena', port = 7500,
        players = 0, maxPlayers = 8, protocol = 3, challengePort = 7600,
    })
    t.ok(challenge ~= nil, 'a host announces')
    reg:challengeReply(challenge.token, challenge.nonce)

    local nudgeAddress, nudgePort = reg:notifyEndpoint('198.51.100.60', 7500)
    t.eq(nudgeAddress, '198.51.100.60', 'the nudge goes to the address the registry saw')
    t.eq(nudgePort, 7600,
         'on the challenge port, because the game port is ENet\'s and drops non-ENet')

    t.eq(reg:notifyEndpoint('198.51.100.60', 9999), nil, 'an unlisted host has no endpoint')
    t.eq(reg:notifyEndpoint('203.0.113.1', 7500), nil, 'nor does a stranger at the same port')

    -- The nudge is an optimisation over the heartbeat and never a replacement
    -- for it: the punch itself still travels on the heartbeat response.
    reg:requestPunch('203.0.113.50', 40000, '198.51.100.60', 7500)
    t.eq(#reg:takePunches(challenge.token), 1,
         'the introduction still rides the heartbeat, nudge or no nudge')

    ---------------------------------------------------------------------
    t.describe('a nudged beacon brings its next heartbeat forward')

    -- A beacon built by hand around a fake socket. The real constructor wants
    -- LuaSocket, which is not here, but pumpChallenge is where the nudge is
    -- decided and it only ever touches self.udp.
    local function fakeUdp(messages)
        local sent = {}
        local i = 0
        return {
            sent = sent,
            receivefrom = function()
                i = i + 1
                local m = messages[i]
                if not m then return nil end
                return m, '198.51.100.1', 8080
            end,
            sendto = function(_, data, address, port)
                sent[#sent + 1] = { data = data, address = address, port = port }
            end,
        }
    end

    local function beaconWith(messages)
        return setmetatable({
            clock = 100, nextAt = 110, udp = fakeUdp(messages),
        }, Master.Beacon)
    end

    local nudged = beaconWith{ 'meatray-punch-waiting' }
    nudged:pumpChallenge()
    t.eq(nudged.nextAt, 100, 'a nudge moves the next heartbeat to now')
    t.eq(nudged.nudges, 1, 'and is counted')

    -- Rate limited, because anything that can reach the challenge port could
    -- otherwise make this host issue HTTP requests as fast as it can send
    -- datagrams -- a small amplifier pointed at our own registry.
    local flooded = beaconWith{ 'meatray-punch-waiting', 'meatray-punch-waiting',
                                'meatray-punch-waiting' }
    flooded:pumpChallenge()
    t.eq(flooded.nudges, 1, 'a burst of nudges is one nudge')

    local spaced = beaconWith{ 'meatray-punch-waiting' }
    spaced:pumpChallenge()
    spaced.clock = 100.2
    spaced.nextAt = 110.2
    spaced:pumpChallenge()   -- nothing left to read; simulate a second arrival
    spaced.udp = fakeUdp{ 'meatray-punch-waiting' }
    spaced:pumpChallenge()
    t.eq(spaced.nextAt, 101,
         'a second nudge inside the interval schedules at the floor, not at now')

    -- The nudge must not have eaten the challenge, which is the message this
    -- socket already existed for.
    local challenged = beaconWith{ 'meatray-challenge deadbeef' }
    challenged:pumpChallenge()
    t.eq(#challenged.udp.sent, 1, 'a challenge is still answered')
    t.eq(challenged.udp.sent[1].data, 'meatray-challenge-reply deadbeef',
         'with the nonce it carried')
    t.eq(challenged.nextAt, 110, 'and a challenge is not a nudge')

    local junk = beaconWith{ 'meatray-punch-waiting please', 'hello', '' }
    junk:pumpChallenge()
    t.eq(junk.nudges, nil, 'nothing that merely resembles a nudge is one')
    t.eq(#junk.udp.sent, 0, 'and nothing is answered')

    ---------------------------------------------------------------------
    t.describe('asking for an introduction refuses what it cannot send')

    -- Every one of these fails before a socket is wanted, which is why they can
    -- be checked here at all. The reason is always the missing thing, never
    -- "LuaSocket is unavailable" -- the same rule the beacon and browser follow,
    -- and for the same reason: a bug in the call must not report the environment.
    local noReg, noRegWhy = Master.punch{ port = 5000, host = '1.2.3.4', hostPort = 6789 }
    t.eq(noReg, nil, 'a punch with no registry is refused')
    t.ok(noRegWhy:find('registry'), 'and says a registry is what is missing')

    local noPort, noPortWhy = Master.punch{
        registries = { 'http://r' }, host = '1.2.3.4', hostPort = 6789 }
    t.eq(noPort, nil, 'a punch that cannot name our port is refused')
    t.ok(noPortWhy:find('UDP port'), 'and says so')

    local badPort = Master.punch{
        registries = { 'http://r' }, port = 0, host = '1.2.3.4', hostPort = 6789 }
    t.eq(badPort, nil, 'port 0 is not a port to be introduced on')

    local noHost, noHostWhy = Master.punch{ registries = { 'http://r' }, port = 5000 }
    t.eq(noHost, nil, 'a punch with nobody to be introduced to is refused')
    t.ok(noHostWhy:find('host address'), 'and says which half is missing')

    -- With every argument right, the only thing left to fail is the environment,
    -- and headless it does. That it fails HERE and not earlier is the assertion:
    -- validation happens before the socket, so the two failures never mask.
    local noSocket, noSocketWhy = Master.punch{
        registries = { 'http://r' }, port = 5000, host = '1.2.3.4', hostPort = 6789 }
    t.eq(noSocket, nil, 'and with no LuaSocket the punch cannot be sent')
    t.ok(noSocketWhy:find('LuaSocket'), 'which is a different reason, said differently')

    ---------------------------------------------------------------------
    t.describe('a host punches at a client the registry introduced')

    -- A discovery backend that exists to capture what host.lua hands its beacon.
    -- Registering one is the public way to add a backend, so this asserts on the
    -- real wiring rather than on a stand-in for it -- and it is the only way to
    -- reach onPunch headless, since the master beacon needs a socket.
    local captured
    registerProbe{
        introduces = true,
        beacon = function(opts)
            captured = opts
            return { update = function() end, close = function() end }
        end,
    }

    local function hostWith(opts)
        Loopback.reset()
        captured = nil
        local logs = {}

        -- `false` means no discovery at all, which nil cannot say here: nil is
        -- also what an absent field looks like, and the default has to be
        -- reachable. Written as an if, because the obvious
        -- `(opts.discovery == false) and nil or default` ALWAYS yields the
        -- default -- `a and nil or b` is b for every a, since nil is false.
        -- That form silently gave this host a beacon it was supposed not to have
        -- and the assertion it broke was three cases away.
        local discovery = opts.discovery
        if discovery == nil then discovery = { 'punch-probe' } end
        if discovery == false then discovery = nil end
        local host = Host.new{
            mode = 'listen', transport = 'loopback', port = opts.port,
            world = Worldgen.box(12, 12),
            discovery = discovery,
            onPunch = opts.onPunch,
            onLog = function(text) logs[#logs + 1] = tostring(text) end,
            onWarning = function() end,
        }
        return host, logs
    end

    local host = hostWith{ port = 7410 }
    t.ok(host ~= nil, 'a host with a punch-capable backend comes up')
    t.ok(captured ~= nil, 'and its beacon was built')
    t.ok(type(captured.onPunch) == 'function',
         'with an onPunch, so an introduction has somewhere to land')

    -- The introduction, as the beacon would deliver it.
    captured.onPunch{ address = '203.0.113.50', port = 40000 }

    local punched = host.transport:punches()
    t.eq(#punched, 1, 'the default handler punched, immediately and once')
    t.eq(punched[1], '203.0.113.50:40000',
         'at the address AND port the registry supplied')
    t.eq(host.stats.punchesAsked, 1, 'the introduction is counted')
    t.eq(host.stats.punchesSent, 1, 'and so is the packet')

    -- A single datagram on a path where nothing has got through yet is a single
    -- chance. The burst is spread rather than sent at once, so a loss and a
    -- momentary block are both survivable.
    host:update(0.1)
    t.eq(#host.transport:punches(), 1, 'nothing more goes out before the spacing has passed')
    host:update(0.2)
    t.eq(#host.transport:punches(), 2, 'and the second goes out once it has')
    for _ = 1, 20 do host:update(0.05) end
    t.eq(#host.transport:punches(), Host.PUNCH_REPEATS,
         ('the burst is exactly %d packets'):format(Host.PUNCH_REPEATS))

    for _ = 1, 40 do host:update(0.05) end
    t.eq(#host.transport:punches(), Host.PUNCH_REPEATS,
         'and then stops, rather than punching at that address forever')
    t.eq(next(host.punching), nil, 'with nothing left pending')
    host:close()

    ---------------------------------------------------------------------
    t.describe('a second request refills the burst rather than doubling it')

    local refill = hostWith{ port = 7411 }
    refill.beaconOnPunch = captured.onPunch
    captured.onPunch{ address = '203.0.113.51', port = 40001 }
    refill:update(0.3)
    t.eq(#refill.transport:punches(), 2, 'two of the burst have gone')

    captured.onPunch{ address = '203.0.113.51', port = 40001 }
    t.eq(#refill.transport:punches(), 2,
         'a repeat introduction does not fire an extra packet on the spot')
    t.eq(refill.punching['203.0.113.51:40001'].left, Host.PUNCH_REPEATS,
         'it refills what is left instead')
    t.eq(refill.stats.punchesAsked, 2, 'though both requests are counted')
    refill:close()

    ---------------------------------------------------------------------
    t.describe('there is a ceiling on how many addresses a host will punch at')

    -- An introduction makes this host send packets at an address somebody else
    -- chose, which is a reflector. The registry is one the host picked, so this
    -- is a blast radius rather than a hole -- but a registry that is compromised
    -- or simply wrong must not be able to point every listed server wherever it
    -- likes.
    local capped, cappedLogs = hostWith{ port = 7418 }
    local ceiling = math.max(Host.PUNCH_MAX_PENDING, capped.access.maxPlayers)

    for i = 1, ceiling + 25 do
        captured.onPunch{ address = ('203.0.113.%d'):format(i % 200), port = 40000 + i }
    end

    local pending = 0
    for _ in pairs(capped.punching) do pending = pending + 1 end
    t.eq(pending, ceiling, 'no more than the ceiling are in flight at once')
    t.eq(#capped.transport:punches(), ceiling, 'and no more packets than that went out')
    t.eq(capped.stats.punchesRefused, 25, 'the rest are refused and counted')
    t.ok(table.concat(cappedLogs, ' | '):find('more addresses'), 'and said out loud')

    local complained = select(2, table.concat(cappedLogs, ' | '):gsub('more addresses', ''))
    t.eq(complained, 1, 'once, not once per refusal -- the log must not be the flood')

    -- And it recovers: every burst expires, so a burst of nonsense costs a
    -- second of refusals rather than disabling the feature.
    for _ = 1, 40 do capped:update(0.05) end
    t.eq(next(capped.punching), nil, 'the bursts all expire')
    captured.onPunch{ address = '203.0.113.250', port = 40999 }
    t.eq(capped.punching['203.0.113.250:40999'] ~= nil, true,
         'and a later client is punched at normally')
    capped:close()

    ---------------------------------------------------------------------
    t.describe('an introduction that is not one is ignored')

    local junkHost = hostWith{ port = 7412 }
    local onPunch = captured.onPunch
    t.eq(onPunch{ address = '203.0.113.52' }, nil, 'a peer with no port is not punched')
    onPunch{ port = 40000 }
    onPunch{ address = '', port = 40000 }
    onPunch{ address = '203.0.113.52', port = 0 }
    onPunch{ address = '203.0.113.52', port = 99999 }
    onPunch('203.0.113.52:40000')
    onPunch(nil)
    t.eq(#junkHost.transport:punches(), 0, 'none of them emitted anything')
    t.eq(junkHost.stats.punchesAsked, 0, 'and none of them counted as an introduction')
    junkHost:close()

    ---------------------------------------------------------------------
    t.describe('a game that supplies its own onPunch keeps it')

    -- The engine punches by default because a host that is told somebody is
    -- trying to reach it and does nothing is the feature not happening. It is
    -- still a default: a game running a transport with its own traversal, or
    -- deliberately refusing strangers, must be able to say so and be obeyed.
    local mine = {}
    local owned = hostWith{
        port = 7413,
        onPunch = function(peer) mine[#mine + 1] = peer.address end,
    }
    captured.onPunch{ address = '203.0.113.53', port = 40002 }
    t.eq(#mine, 1, 'the game\'s handler ran')
    t.eq(mine[1], '203.0.113.53', 'with the peer it was given')
    t.eq(#owned.transport:punches(), 0, 'and the engine punched nothing behind its back')
    owned:close()

    ---------------------------------------------------------------------
    t.describe('a transport that cannot punch says so and does not raise')

    local cannot = hostWith{ port = 7414 }
    local said = {}
    cannot.onLog = function(text) said[#said + 1] = tostring(text) end

    -- Swapped for a transport that simply has no punch method, which is how a
    -- transport declines: the method is optional and its absence is the answer.
    -- Note what does NOT work here — assigning nil over `punch` on the loopback
    -- instance. `punch` lives on the metatable, so the field is already nil and
    -- the assignment changes nothing; the host would go on punching and the test
    -- would pass for a reason that is not the one it names.
    cannot.transport = { name = 'loopback-without-punch', close = function() end }

    local ok = pcall(captured.onPunch, { address = '203.0.113.54', port = 40003 })
    t.eq(ok, true, 'being asked to punch without being able to does not raise')
    captured.onPunch{ address = '203.0.113.54', port = 40003 }

    local complaint = table.concat(said, ' | ')
    t.ok(complaint:find('cannot hole punch'), 'it is reported as a transport limitation')
    t.ok(complaint:find('loopback%-without%-punch'),
         'naming the transport, which is the thing to change')
    local mentions = select(2, complaint:gsub('cannot hole punch', ''))
    t.eq(mentions, 1, 'and said once, not once per client that tries to join')
    t.eq(cannot.stats.punchesSent, 0, 'nothing was claimed to have been sent')
    cannot:close()

    ---------------------------------------------------------------------
    t.describe('the host reports whether a punch can happen at all')

    -- Both halves are required and both are checked against facts. A registry
    -- with no punchable transport and a punchable transport with no registry are
    -- equally unable, and neither may print a line implying an attempt.
    local Diagnostics = require('meatray.net.diagnostics')

    local armed = hostWith{ port = 7415 }
    t.eq(armed.canPunch, true, 'a registry-backed host with a punching transport is armed')
    armed:close()

    local alone = hostWith{ port = 7416, discovery = false }
    t.eq(alone.canPunch, false, 'a host with no discovery at all is not')
    alone:close()

    -- A backend that runs but cannot carry an introduction -- `lan` is the real
    -- one; it needs no traversal and has nobody to ask. The host must read the
    -- backend's own declaration rather than the fact that *a* beacon is up.
    registerProbe2{
        beacon = function()
            return { update = function() end, close = function() end }
        end,
    }
    local quiet = hostWith{ port = 7417, discovery = { 'punch-probe-quiet' } }
    t.ok(quiet.beacon:active(), 'its beacon really is running')
    t.eq(quiet.canPunch, false, 'but a backend that does not introduce cannot arm a punch')
    quiet:close()

    local function reportText(facts)
        return table.concat(Diagnostics.format(Diagnostics.classify(facts)), '\n')
    end

    local armedText = reportText{ port = 6789, bound = true, udp = true,
                                  external = 'unknown', holePunch = 'armed' }
    t.ok(armedText:find('will be punched at'), 'an armed host says clients will be punched at')
    t.ok(armedText:find('refuse anyway'),
         'and does NOT claim it works, because nothing here can know that')

    local unsupported = reportText{ port = 6789, bound = true, udp = true,
                                    external = 'unknown', holePunch = 'unsupported' }
    t.ok(unsupported:find('none is configured'), 'and an unarmed one says what is missing')

    -- "no master server configured to test it" became a lie the moment a host
    -- could configure one, and it was still being printed by a host that had
    -- just been listed by a registry. Two sentences, and the registry-backed one
    -- names the gap that actually remains: the listing proves the address, never
    -- the game port, which is the same thing portVerified = false says.
    local listed = reportText{ port = 6789, bound = true, udp = true,
                               external = 'unknown', registry = true }
    t.ok(not listed:find('no master server configured'),
         'a host a registry has listed is not told no registry is configured')
    t.ok(listed:find('a registry has your address'), 'it is told what IS known')
    t.ok(listed:find('game port'), 'and what is still unproved')

    local unlisted = reportText{ port = 6789, bound = true, udp = true,
                                 external = 'unknown' }
    t.ok(unlisted:find('no master server configured'),
         'and a host with no registry still gets the original sentence')

    t.eq(armed.report.registry, nil,
         'the report is the classified result, not the facts it was built from')

    ---------------------------------------------------------------------
    t.describe('a punch that cannot even be requested still joins directly')

    -- The load-bearing failure case. There is NO RELAY in this engine, so a
    -- punch that does not work has to end in a direct attempt and then a stated
    -- reason -- never in a hang, and never in a join that was refused locally
    -- because a registry was unreachable.
    Loopback.reset()
    local Net = require('meatray.net')

    local server = Host.new{
        mode = 'dedicated', transport = 'loopback', port = 7420,
        world = Worldgen.box(12, 12),
        onLog = function() end,
    }
    t.ok(server ~= nil, 'a server is listening')

    local clientLogs = {}
    local client = Net.Client.new{
        transport = 'loopback', address = 'loopback:7420',
        -- A registry that cannot be reached, on a machine with no LuaSocket at
        -- all: the punch cannot even be attempted.
        registries = { 'http://127.0.0.1:1' },
        onLog = function(text) clientLogs[#clientLogs + 1] = tostring(text) end,
    }

    t.ok(client ~= nil, 'the client is created anyway')
    t.ok(table.concat(clientLogs, ' | '):find('joining directly'),
         'and says the introduction could not be asked for')

    for _ = 1, 20 do
        server:update(0.05)
        client:update(0.05)
    end
    t.eq(client.state, 'joined', 'the join completed on the direct attempt')
    t.eq(client.punch, nil, 'with nothing left waiting on a registry')

    client:close('done')
    server:close()

    ---------------------------------------------------------------------
    t.describe('a punch is never waited on')

    -- Written as a property of the code rather than as a timing measurement,
    -- because a timing measurement on one machine proves nothing about another.
    -- Client.new must reach transport:connect on every path through
    -- requestPunch, including the ones that fail.
    local source = io.open('meatray/net/client.lua', 'r')
    t.ok(source ~= nil, 'client.lua is readable')
    local code = require('tests.support.lua_source')
                 .stripNonCode(source:read('*a'))
    source:close()

    local askedAt = code:find('self:requestPunch%(')
    local connectAt = code:find('transport:connect%(')
    t.ok(askedAt ~= nil and connectAt ~= nil, 'both steps are in the constructor')
    t.ok(askedAt < connectAt, 'the introduction is asked for before the connect')
    t.ok(not code:find('requestPunch[^\n]*\n[^\n]*while'),
         'and nothing loops between them')

    -- requestPunch returns a boolean nobody branches on, which is the point: the
    -- connect below it is unconditional.
    local between = code:sub(askedAt, connectAt)
    t.ok(not between:find('%f[%w]if%f[%W]'),
         'the connect is not conditional on the introduction having succeeded')

    Loopback.reset()
end
