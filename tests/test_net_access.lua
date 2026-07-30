--[[
    Access control, host diagnostics, and the discovery registry.

    All three are deliberately pure enough to test without a socket. That is not
    tidiness: the diagnostics are the words a player reads when hosting does not
    work, and a wrong word there is the difference between "forward UDP 6789" and
    a player concluding that multiplayer is broken. Words a test can assert on are
    words that stay right.

    The discovery tests are mostly about degradation. Asking for a backend that
    does not exist yet — 'master', 'steam' — must leave the host running and the
    working backends working, because a registry outage that stops a LAN game is
    an outage that did not need to matter.
]]

return function(t)
    local Access      = require('meatray.net.access')
    local Diagnostics = require('meatray.net.diagnostics')
    local Discovery   = require('meatray.net.discovery')
    local Net         = require('meatray.net')
    local Loopback    = require('meatray.net.transport.loopback')
    local Worldgen    = require('meatray.sim.worldgen')
    local Entity      = require('meatray.sim.entity')

    -----------------------------------------------------------------------
    t.describe('open is the default')
    local open = Access.new{}
    t.ok(not open:locked(), 'an open server is not locked')
    t.ok(open:admit({ address = '10.0.0.5:1000' }, { players = 0 }),
         'and admits anyone')

    t.describe('password')
    local locked = Access.new{ password = 'hunter2' }
    t.ok(locked:locked(), 'a password makes the server locked, so a browser can say so')

    local ok, reason = locked:admit({ address = '10.0.0.5:1' }, { players = 0 })
    t.ok(not ok, 'no password is refused')
    t.eq(reason, Access.NEEDS_PASSWORD, 'and says a password is required')

    ok, reason = locked:admit({ address = '10.0.0.5:1', password = 'wrong' }, { players = 0 })
    t.ok(not ok, 'a wrong password is refused')
    t.eq(reason, Access.PASSWORD, 'and says the password is wrong')

    t.ok(locked:admit({ address = '10.0.0.5:1', password = 'hunter2' }, { players = 0 }),
         'the right password is admitted')

    t.describe('capacity')
    local small = Access.new{ maxPlayers = 2 }
    t.ok(small:admit({ address = 'a:1' }, { players = 1 }), 'there is room for one more')
    ok, reason = small:admit({ address = 'a:1' }, { players = 2 })
    t.ok(not ok and reason == Access.FULL, 'and none for the one after that')

    t.describe('protocol version')
    ok, reason = open:admit({ address = 'a:1', version = 99 }, { players = 0, version = 1 })
    t.ok(not ok and reason == Access.VERSION,
         'a mismatched protocol version is refused explicitly')

    t.describe('bans are by address, because a port changes on reconnect')
    local moderated = Access.new{}
    local banned, ip = moderated:ban('198.51.100.9:54321', 'griefing')
    t.ok(banned, 'a ban is accepted')
    t.eq(ip, '198.51.100.9', 'and stored as the host, not host:port')

    t.ok(moderated:isBanned('198.51.100.9:1'), 'the same address on a new port is still banned')
    t.ok(moderated:isBanned('198.51.100.9'), 'and as a bare host')
    t.ok(not moderated:isBanned('198.51.100.10:1'), 'a different address is not')

    ok, reason = moderated:admit({ address = '198.51.100.9:2' }, { players = 0 })
    t.ok(not ok and reason == Access.BANNED, 'a banned address is refused')

    -- Order matters: banned is checked before the password, so a ban cannot be
    -- used to probe for the password.
    local both = Access.new{ password = 'secret' }
    both:ban('203.0.113.1')
    local _, bothReason = both:admit({ address = '203.0.113.1:1', password = 'secret' },
                                     { players = 0 })
    t.eq(bothReason, Access.BANNED, 'a ban outranks a correct password')

    t.eq(#moderated:banned(), 1, 'the ban list has one entry')
    t.ok(moderated:unban('198.51.100.9:9999'), 'unban works from any port')
    t.ok(not moderated:isBanned('198.51.100.9'), 'and the address is admitted again')
    t.ok(not moderated:unban('198.51.100.9'), 'unbanning twice reports nothing to do')

    t.describe('the identity hook is a hook, not an auth service')
    local sawCredentials
    local hooked = Access.new{
        onAuthenticate = function(request)
            sawCredentials = request.credentials
            if request.credentials == 'good-token' then return true end
            return false, 'bad token'
        end,
    }
    t.ok(hooked:locked(), 'a game that authenticates is a locked server')
    t.ok(hooked:admit({ address = 'a:1', credentials = 'good-token' }, { players = 0 }),
         'the game can admit')
    t.eq(sawCredentials, 'good-token', 'and is handed whatever the client sent, verbatim')

    ok, reason = hooked:admit({ address = 'a:1', credentials = 'nope' }, { players = 0 })
    t.ok(not ok, 'the game can refuse')
    t.eq(reason, 'bad token', 'with its own reason')

    -- A crash in game code must refuse the join, not take the server down.
    local exploding = Access.new{ onAuthenticate = function() error('kaboom') end }
    ok, reason = exploding:admit({ address = 'a:1' }, { players = 0 })
    t.ok(not ok and reason == Access.REFUSED, 'a hook that errors refuses the join')

    -----------------------------------------------------------------------
    t.describe('private address detection')
    for _, ip2 in ipairs({ '10.1.2.3', '192.168.0.4', '172.16.5.6', '172.31.255.1',
                           '127.0.0.1', '169.254.1.1', '100.100.1.1', '::1', 'fe80::1' }) do
        t.ok(Diagnostics.isPrivateAddress(ip2), ip2 .. ' is behind NAT')
    end
    for _, ip2 in ipairs({ '203.0.113.7', '8.8.8.8', '172.32.1.1', '192.169.1.1' }) do
        t.ok(not Diagnostics.isPrivateAddress(ip2), ip2 .. ' is publicly routable')
    end
    t.ok(not Diagnostics.isPrivateAddress(nil), 'no address is not a private address')

    -----------------------------------------------------------------------
    local function joined(report)
        return table.concat(report.lines, '\n')
    end

    t.describe('a host that cannot bind is told nobody can reach it')
    local dead = Diagnostics.classify{ port = 6789, bound = false,
                                       bindError = 'address already in use' }
    t.eq(dead.reach, 'none', 'reachability is none')
    t.ok(joined(dead):find('cannot listen on UDP 6789'), 'the port is named')
    t.ok(joined(dead):find('address already in use'), 'the reason is quoted')
    t.ok(joined(dead):find('nobody can reach you'), 'and it says so plainly')
    t.ok(joined(dead):find('%-%-port 6790'), 'and suggests a port that might work')

    t.describe('a machine where UDP is blocked is told that, and not something else')
    -- The failure mode this exists for: the port binds, the server says it is
    -- listening, and no player can ever join, because something on the machine is
    -- filtering UDP. From the outside that is indistinguishable from a broken
    -- handshake, and the wrong diagnosis costs a day.
    local blockedUdp = Diagnostics.classify{
        port = 6789, bound = true, lan = true, address = '192.168.1.20',
        udp = false, udpError = 'a UDP datagram to 127.0.0.1:51000 was refused: refused',
    }
    t.eq(blockedUdp.reach, 'none', 'nobody can reach a host whose UDP is filtered')
    t.eq(blockedUdp.blocked, 'udp', 'and the report says what is blocked')
    t.ok(joined(blockedUdp):find('UDP is being blocked on this machine'),
         'it names the cause rather than the symptom')
    t.ok(joined(blockedUdp):find('even to itself'),
         'and says the evidence is a loopback test, so it is not the network')
    t.ok(joined(blockedUdp):find('was refused: refused'), 'quoting the actual error')
    t.ok(joined(blockedUdp):find('New%-NetFirewallRule'),
         'and gives the exact command that fixes it')
    t.ok(joined(blockedUdp):find('%-%-netcheck'), 'and how to check that it worked')
    t.ok(not joined(blockedUdp):find('forward UDP'),
         'and does not tell you to forward a port, which would not help')

    t.describe('a working UDP stack adds no noise')
    local fine = Diagnostics.classify{ port = 6789, bound = true, lan = true,
                                       address = '192.168.1.20', udp = true }
    t.ok(not joined(fine):find('blocked'), 'a passing self-test says nothing')

    local untested = Diagnostics.classify{ port = 6789, bound = true, lan = true }
    t.ok(not joined(untested):find('blocked'),
         'and neither does one that could not be run')

    t.describe('a LAN host is told LAN players can join')
    local lan = Diagnostics.classify{ port = 6789, bound = true, lan = true,
                                      address = '192.168.1.20', external = 'unknown',
                                      holePunch = 'unsupported' }
    t.eq(lan.reach, 'lan', 'reachability is lan')
    t.ok(joined(lan):find('listening on UDP 6789'), 'it says it is listening')
    t.ok(joined(lan):find('LAN beacon active'), 'and that the beacon is up')
    t.ok(joined(lan):find('local players can join'),
         'and that local players can join - which is the distinction that matters')
    t.ok(joined(lan):find('behind NAT'), 'it names NAT rather than implying it')
    t.ok(joined(lan):find('forward UDP 6789'), 'and names the port to forward')
    t.eq(lan.forwardPort, 6789, 'and reports it as data too')
    t.ok(joined(lan):find('no master server'),
         'and says why external reachability is unknown rather than claiming it is fine')

    t.describe('LAN discovery off means players need the address')
    local quiet = Diagnostics.classify{ port = 7000, bound = true, lan = false,
                                        address = '192.168.1.20', external = 'unknown' }
    t.ok(joined(quiet):find('LAN discovery off'), 'it says discovery is off')
    t.ok(joined(quiet):find('192%.168%.1%.20:7000'), 'and gives the address to paste')

    t.describe('an unreachable host is told the difference')
    local blocked = Diagnostics.classify{ port = 6789, bound = true, lan = true,
                                          address = '192.168.1.20',
                                          external = 'unreachable',
                                          holePunch = 'failed',
                                          holePunchNote = 'symmetric NAT' }
    t.eq(blocked.reach, 'lan', 'LAN players can still join, and that is reported')
    t.ok(joined(blocked):find('nobody outside your LAN can reach you'),
         'the failure is stated exactly, not as "cannot host"')
    t.ok(joined(blocked):find('hole punch attempted, failed'), 'the attempt is reported')
    t.ok(joined(blocked):find('symmetric NAT'), 'with the reason it failed')
    t.ok(joined(blocked):find('forward UDP 6789'), 'and the port to forward')
    t.ok(joined(blocked):find('dedicated server'), 'and the other way out')

    local isolated = Diagnostics.classify{ port = 6789, bound = true, lan = false,
                                           external = 'unreachable' }
    t.eq(isolated.reach, 'none', 'with no LAN beacon either, nobody can reach you')

    t.describe('a reachable host says so and stops advising')
    local reachable = Diagnostics.classify{ port = 6789, bound = true, lan = true,
                                            address = '203.0.113.4',
                                            external = 'reachable' }
    t.eq(reachable.reach, 'internet', 'reachability is internet')
    t.ok(joined(reachable):find('reachable from outside'), 'it says so')
    t.ok(not joined(reachable):find('forward UDP'), 'and does not tell you to forward a port')
    t.eq(reachable.forwardPort, nil, 'nor report one')

    t.describe('a public address is not called NAT')
    local public = Diagnostics.classify{ port = 6789, bound = true, lan = true,
                                         address = '203.0.113.4', external = 'unknown' }
    t.ok(joined(public):find('publicly routable'), 'it says the address looks routable')
    t.ok(not joined(public):find('behind NAT'), 'and does not claim NAT')

    t.describe('every line is prefixed so a server log stays greppable')
    for _, line in ipairs(Diagnostics.format(lan)) do
        t.ok(line:sub(1, 5) == '[net]', ('%q is prefixed'):format(line:sub(1, 20)))
    end

    -----------------------------------------------------------------------
    t.describe('discovery: direct always works')
    local direct = Discovery.browser('direct', {})
    t.ok(direct:active(), 'the direct browser is available')
    direct.direct:add('203.0.113.5:6789', { name = 'Friday game' })
    direct.direct:add('198.51.100.2:6789')
    local list = direct:servers()
    t.eq(#list, 2, 'entries the player typed are in the list')
    t.eq(list[1].source, 'direct', 'tagged with where they came from')
    local named = false
    for _, entry in ipairs(list) do if entry.name == 'Friday game' then named = true end end
    t.ok(named, 'and keep the name they were given')
    direct.direct:remove('198.51.100.2:6789')
    t.eq(#direct:servers(), 1, 'and can be removed')

    t.describe('discovery: a planned backend degrades, it does not fail')
    local warnings = {}
    local mixed = Discovery.browser({ 'direct', 'steam' }, {
        onWarning = function(text) warnings[#warnings + 1] = text end,
    })
    t.ok(mixed:active(), 'the browser still works')
    t.eq(#mixed.missing, 1, 'the unavailable backend is recorded')
    t.eq(#warnings, 1, 'and warned about once')
    t.ok(table.concat(warnings, ' | '):find('planned'),
         'the warning says the backend is planned, not broken')

    local beacon = Discovery.beacon({ 'steam' }, { info = function() return {} end })
    t.ok(not beacon:active(), 'a beacon with only planned backends announces nothing')
    t.eq(#beacon.missing, 1, 'and says which')
    beacon:update(1)     -- must not raise
    beacon:close()
    t.ok(true, 'and can still be updated and closed like any beacon')

    t.describe('discovery: master is implemented, and still degrades softly')

    -- It resolves now rather than being reported as planned.
    t.ok(Discovery.resolve('master') ~= nil, 'the master backend resolves')
    t.eq(Discovery.planned.master, nil, 'and is no longer listed as planned')

    -- Misconfiguration is the common case for this backend and must behave like
    -- any other unavailable one: recorded, warned about once, never fatal. A
    -- registry is the one discovery method that depends on something outside the
    -- machine, so it is the one most likely to be absent.
    local noUrl = {}
    local unconfigured = Discovery.browser({ 'direct', 'master' }, {
        onWarning = function(text) noUrl[#noUrl + 1] = text end,
    })
    t.ok(unconfigured:active(), 'a browser with no registry URL still works')
    t.eq(#unconfigured.missing, 1, 'master is recorded as unavailable')
    t.ok(table.concat(noUrl, ' | '):find('registry URL'),
         'and the reason names the missing configuration rather than being vague')

    local noUrlBeacon = Discovery.beacon({ 'master' }, { info = function() return {} end })
    t.ok(not noUrlBeacon:active(), 'and so does a beacon')
    noUrlBeacon:update(1)
    noUrlBeacon:close()
    t.ok(true, 'which still updates and closes cleanly')

    t.describe('discovery: an unknown backend is named, not guessed at')
    local unknown, unknownErr = Discovery.resolve('carrier-pigeon')
    t.ok(unknown == nil and unknownErr ~= nil, 'it is refused')
    t.ok(unknownErr:find('carrier%-pigeon'), 'the name asked for is quoted back')

    t.describe('discovery: a new backend needs no browser edit')
    Discovery.register('fixture', {
        browser = function()
            local b = { source = 'fixture' }
            function b:update() end
            function b:refresh() end
            function b:close() end
            function b:servers()
                return { { address = '10.0.0.1:6789', name = 'Fixture', ping = 3,
                           players = 2, max = 8, locked = true, source = 'fixture' } }
            end
            return b
        end,
    })

    local merged = Discovery.browser({ 'direct', 'fixture' }, {})
    merged.direct:add('10.0.0.1:6789', { name = 'My favourite' })
    local mergedList = merged:servers()
    t.eq(#mergedList, 1, 'the same server found twice appears once')
    t.eq(mergedList[1].name, 'My favourite',
         'the first source to name it wins, so a favourite keeps its label')
    t.eq(mergedList[1].ping, 3, 'while fields only the other source has are merged in')
    t.eq(mergedList[1].max, 8, 'including the ones a browser UI displays')
    t.ok(mergedList[1].locked, 'and the locked flag')

    -----------------------------------------------------------------------
    t.describe('a host refuses a client with the wrong password')
    Loopback.reset()
    Entity.clearArchetypes()
    Entity.resetIds(1)

    local host = Net.Host.new{
        mode = 'dedicated', transport = 'loopback', port = 8900,
        world = Worldgen.box(12, 12), password = 'letmein',
        onLog = function() end,
    }
    t.ok(host ~= nil, 'a locked host comes up')
    t.ok(host:info().locked, 'and reports itself as locked, so a browser can show it')

    local function drive(h, c, ticks)
        for _ = 1, ticks or 20 do
            if h then h:update(1 / 60) end
            if c then c:update(1 / 60) end
        end
    end

    local wrong = Net.Client.new{ address = 'loopback:8900', transport = 'loopback',
                                  password = 'nope', onLog = function() end }
    drive(host, wrong, 20)
    t.eq(wrong.state, 'rejected', 'the wrong password is rejected')
    t.eq(wrong.reason, Access.PASSWORD, 'with a reason the client can show a player')
    t.eq(host:playerCount(), 0, 'and nobody was spawned for it')

    local right = Net.Client.new{ address = 'loopback:8900', transport = 'loopback',
                                  password = 'letmein', onLog = function() end }
    drive(host, right, 20)
    t.eq(right.state, 'joined', 'the right password gets in')
    t.eq(host:playerCount(), 1, 'and is counted')

    t.describe('a locked server in a browser list warns before connecting')
    local refusedEntry, refusedWhy = Net.join({ address = 'loopback:8900', locked = true })
    t.ok(refusedEntry == nil and refusedWhy:find('password'),
         'clicking a locked server with no password says so up front')

    t.describe('kick')
    local kicked, kickErr = host:kick(1, 'testing')
    t.ok(kicked, 'the host can kick by peer id', kickErr)
    drive(host, right, 10)
    t.eq(right.state, 'kicked', 'the client is told it was kicked')
    t.eq(right.reason, 'testing', 'and why')
    t.eq(host:playerCount(), 0, 'and the host dropped it')

    t.describe('ban by address')
    local banner = Net.Host.new{
        mode = 'dedicated', transport = 'loopback', port = 8901,
        world = Worldgen.box(12, 12), onLog = function() end,
    }
    -- A fixed apparent source address, so "reconnects from the same address" is
    -- actually what is being tested rather than an artefact of one transport
    -- instance being reused.
    local rude = Net.Client.new{ address = 'loopback:8901', transport = 'loopback',
                                 clientAddress = '198.51.100.9:5000',
                                 onLog = function() end }
    drive(banner, rude, 20)
    t.eq(rude.state, 'joined', 'the peer joins first')

    local peerAddress
    for _, peer in pairs(banner.peers) do peerAddress = peer.address end
    t.eq(peerAddress, '198.51.100.9:5000', 'the host knows the address it came from')

    local didBan = banner:ban(1, 'griefing')
    t.ok(didBan, 'the host bans it')
    drive(banner, rude, 10)
    t.eq(banner:playerCount(), 0, 'a ban kicks as well as blocks')
    t.eq(#banner:bans(), 1, 'and the ban is recorded')

    -- Same host, different port: exactly what a reconnect looks like.
    local again = Net.Client.new{ address = 'loopback:8901', transport = 'loopback',
                                  clientAddress = '198.51.100.9:5100',
                                  onLog = function() end }
    drive(banner, again, 20)
    t.ok(again.state ~= 'joined', 'and reconnecting from a banned address fails')
    t.eq(again.reason, Access.BANNED, 'with the reason stated')
    t.eq(banner:playerCount(), 0, 'with nobody spawned')

    local elsewhere = Net.Client.new{ address = 'loopback:8901', transport = 'loopback',
                                      clientAddress = '198.51.100.10:5000',
                                      onLog = function() end }
    drive(banner, elsewhere, 20)
    t.eq(elsewhere.state, 'joined', 'a different address is unaffected by the ban')
    elsewhere:close()

    banner:unban(peerAddress)
    local forgiven = Net.Client.new{ address = 'loopback:8901', transport = 'loopback',
                                     clientAddress = '198.51.100.9:5200',
                                     onLog = function() end }
    drive(banner, forgiven, 20)
    t.eq(forgiven.state, 'joined', 'unbanning lets them back in')

    t.describe('a full server refuses politely')
    local tiny = Net.Host.new{
        mode = 'dedicated', transport = 'loopback', port = 8902,
        world = Worldgen.box(12, 12), maxPlayers = 1, onLog = function() end,
    }
    local first = Net.Client.new{ address = 'loopback:8902', transport = 'loopback',
                                  onLog = function() end }
    drive(tiny, first, 20)
    local second = Net.Client.new{ address = 'loopback:8902', transport = 'loopback',
                                   onLog = function() end }
    for _ = 1, 20 do tiny:update(1 / 60); first:update(1 / 60); second:update(1 / 60) end
    t.eq(first.state, 'joined', 'the first client is in')
    t.eq(second.state, 'rejected', 'the second is refused')
    t.eq(second.reason, Access.FULL, 'because the server is full, and it says so')

    host:close(); banner:close(); tiny:close()
    forgiven:close(); first:close(); second:close()
    Net.session = nil
    Loopback.reset()

    -----------------------------------------------------------------------
    t.describe('single player is the default and costs nothing')
    t.eq(Net.mode(), 'single', 'with no session, the mode is single')
    t.ok(not Net.isHost() and not Net.isClient(), 'and neither host nor client')
    Net.update(1 / 60)
    t.ok(true, 'updating a session that does not exist is a no-op, not an error')
    Net.shutdown()
    t.ok(true, 'and so is shutting one down')
end
