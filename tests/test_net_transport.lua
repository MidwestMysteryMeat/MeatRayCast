--[[
    The transport interface, the registry that resolves it, and the loopback
    backend that lets everything above it be tested with no sockets.

    Two things being asserted. First, that loopback is a real transport and not a
    stub: channels, reliability, disconnects, refusals and identity all behave the
    way ENet's do, because a stub that is easier than the real thing moves the bug
    rather than finding it. Second, that the registry genuinely admits a transport
    the engine has never heard of — which is the claim that makes a future Steam
    backend an addition rather than a rewrite.
]]

return function(t)
    local Transport = require('meatray.net.transport')
    local Loopback  = require('meatray.net.transport.loopback')

    t.describe('address parsing')
    local host, port = Transport.parseAddress('203.0.113.5:6789', 1)
    t.eq(host, '203.0.113.5', 'host is split off')
    t.eq(port, 6789, 'port is split off')

    host, port = Transport.parseAddress('192.168.1.9', 6789)
    t.eq(host, '192.168.1.9', 'a bare host keeps its host')
    t.eq(port, 6789, 'a bare host takes the default port')

    host, port = Transport.parseAddress('[::1]:4000', 6789)
    t.eq(host, '::1', 'a bracketed IPv6 literal is unwrapped')
    t.eq(port, 4000, 'a bracketed IPv6 literal keeps its port')

    host, port = Transport.parseAddress('fe80::1', 6789)
    t.eq(host, 'fe80::1', 'a bare IPv6 literal is not mistaken for host:port')
    t.eq(port, 6789, 'a bare IPv6 literal takes the default port')

    t.ok(Transport.parseAddress('', 1) == nil, 'an empty address is refused')
    t.eq(Transport.formatAddress('10.0.0.1', 6789), '10.0.0.1:6789', 'formatting round-trips')
    t.eq(Transport.formatAddress('::1', 6789), '[::1]:6789', 'an IPv6 literal is bracketed')

    t.describe('the registry')
    t.ok(Transport.registered('loopback'), 'loopback is a known transport')
    t.ok(Transport.registered('enet'), 'enet is a known transport')

    local missing, reason = Transport.resolve('nonsense')
    t.ok(missing == nil and reason ~= nil, 'an unknown transport reports rather than raising')
    t.ok(reason:find('nonsense'), 'and names what was asked for')

    ---------------------------------------------------------------------
    -- The Steam transport, from a machine with no Steam on it.
    --
    -- This is the path most players are on — no Steam client, no luasteam
    -- module, and in this suite no LOVE either — and it is the one that has to
    -- be asserted rather than assumed. The claim being tested is not that Steam
    -- works; it is that Steam being absent costs nothing.
    t.describe('the steam transport degrades instead of exploding')
    local Steam = require('meatray.net.transport.steam')

    t.ok(Transport.registered('steam'), 'steam is a known transport')

    -- The name resolves even here. It has to: `require('luasteam')` is inside
    -- the constructor, so the module itself loads anywhere, and the failure has
    -- to happen where a caller can be handed a reason.
    local steamFactory, resolveErr = Transport.resolve('steam')
    t.ok(steamFactory ~= nil, 'the steam transport resolves with no Steam present')
    t.ok(resolveErr == nil, 'and resolving it is not itself an error')

    local available, why = Steam.available()
    t.ok(available == false, 'Steam reports itself unavailable under plain LuaJIT')
    t.ok(type(why) == 'string' and why:find('luasteam'),
         'and names the module that is missing')
    t.ok(why:find('enet'), 'and points at a transport that does work')

    local steamT, steamErr = Transport.new('steam', {})
    t.ok(steamT == nil, 'constructing it without Steam yields no transport')
    t.ok(type(steamErr) == 'string' and #steamErr > 0, 'and a reason instead')
    t.ok(steamErr == why, 'the reason is the same one available() gives')

    -- The whole point of the degradation: asking for Steam and being told no
    -- must leave everything else exactly as it was.
    t.ok(Transport.new('loopback', {}) ~= nil,
         'loopback still constructs after Steam has refused')
    t.ok(Transport.registered('enet'), 'and enet is still a known transport')

    t.describe('steam addresses name accounts, not endpoints')
    local id, vport = Steam.parseAddress('steam:76561197960287930')
    t.eq(id, '76561197960287930', 'a steam: address yields the SteamID64')
    t.eq(vport, Steam.VIRTUAL_PORT, 'and the default virtual port')

    -- As a *string*. A SteamID64 needs 57 bits and a Lua 5.1 number carries 53,
    -- so a transport that parsed one with tonumber would dial a rounded number
    -- that is a different account — silently, and only for some accounts.
    t.eq(type(id), 'string', 'the id stays a string, because 64 bits do not fit in a double')

    id, vport = Steam.parseAddress('steam:76561197960287930:1234')
    t.eq(id, '76561197960287930', 'an explicit virtual port does not disturb the id')
    t.eq(vport, 1234, 'and is taken as given')

    id, vport = Steam.parseAddress('steam://76561197960287930')
    t.eq(id, '76561197960287930', 'the steam:// spelling is accepted too')

    id = Steam.parseAddress('76561197960287930')
    t.eq(id, '76561197960287930', 'a bare SteamID64 is accepted')

    local badId, badWhy = Steam.parseAddress('203.0.113.5:6789')
    t.ok(badId == nil, 'an IP address is not a Steam address')
    t.ok(badWhy:find('SteamID64'), 'and the refusal says what one looks like')
    t.ok(Steam.parseAddress('') == nil, 'an empty address is refused')
    t.ok(Steam.parseAddress(nil) == nil, 'so is no address at all')

    t.eq(Steam.formatAddress('76561197960287930'), 'steam:76561197960287930',
         'formatting round-trips the default port away')
    t.eq(Steam.formatAddress('76561197960287930', 1234), 'steam:76561197960287930:1234',
         'and keeps a non-default one')

    -- Steam reserves every close reason below 1000 for itself. This engine's
    -- disconnect codes are 0 and 1, so they are shifted rather than passed
    -- through — otherwise Steam rejects the close and the kicked player is told
    -- nothing at all.
    t.describe('close reasons are shifted into the range Steam accepts')
    t.ok(Steam.endReason(0) >= Steam.APP_END_MIN, 'a normal leave is in the application range')
    t.ok(Steam.endReason(1) >= Steam.APP_END_MIN, 'so is a kick')
    t.ok(Steam.endReason(1) ~= Steam.endReason(0), 'and a kick is distinguishable from a leave')
    t.ok(Steam.endReason(99999) <= Steam.APP_END_MAX, 'an absurd code is clamped, not rejected')
    t.ok(Steam.endReason(nil) >= Steam.APP_END_MIN, 'and no code at all is still legal')

    t.describe('the steam transport claims no traversal it cannot do')
    -- Absent on purpose, exactly as on the relay transport: Steam's own
    -- traversal is the traversal, so a host must report punching as unsupported
    -- rather than arming an attempt nobody will make.
    t.ok(Steam.SteamMT.punch == nil, 'it does not pretend to hole punch')
    t.ok(Steam.SteamMT.localPort == nil, 'nor to have a UDP port to be introduced on')
    t.ok(Steam.SteamMT.ip == nil, 'nor to know a peer IP it cannot see')
    t.ok(type(Steam.SteamMT.address) == 'function',
         'the ban key is address(), which is a Steam account')
    for _, method in ipairs({ 'listen', 'connect', 'send', 'broadcast', 'update',
                              'service', 'disconnect', 'close', 'key', 'address',
                              'rtt', 'setTimeout' }) do
        t.ok(type(Steam.SteamMT[method]) == 'function',
             ('it implements %s, like every other transport'):format(method))
    end

    t.describe('a third-party transport needs no engine edit')
    local calls = {}
    Transport.register('fake', function()
        return {
            name = 'fake',
            listen = function() calls.listen = true; return true end,
            connect = function() return { key = 'x' } end,
            send = function() end, broadcast = function() end,
            update = function() end, service = function() return nil end,
            disconnect = function() end, close = function() end,
            key = function(_, p) return p.key end,
            address = function() return 'fake:0' end,
            rtt = function() return 0 end,
        }
    end)
    local fake = Transport.new('fake', {})
    t.ok(fake ~= nil and fake.name == 'fake', 'a registered transport resolves by name')
    fake:listen{}
    t.ok(calls.listen, 'and is driven through the same interface')

    local preBuilt = { name = 'handed-in' }
    t.eq(Transport.new(preBuilt), preBuilt,
         'a transport instance passed instead of a name is used as-is')

    ---------------------------------------------------------------------
    t.describe('loopback: listening and connecting')
    Loopback.reset()

    local server = Transport.new('loopback', {})
    t.ok(server:listen{ port = 7000 }, 'a loopback transport listens on a port')

    local clash = Transport.new('loopback', {})
    local clashOk, clashErr = clash:listen{ port = 7000 }
    t.ok(clashOk == nil and clashErr ~= nil, 'a port already in use is refused')
    t.ok(clashErr:find('in use'), 'and says the port is in use')

    local client = Transport.new('loopback', { clientAddress = '10.0.0.7:5000' })
    local refused, refusedErr = client:connect('loopback:9999')
    t.ok(refused == nil and refusedErr ~= nil, 'connecting to a dead port is refused')
    t.ok(refusedErr:find('refused'), 'and says so')

    local peer = client:connect('loopback:7000')
    t.ok(peer ~= nil, 'connecting to a live port succeeds')

    -- Both sides see a connect event, exactly as ENet delivers them: the return
    -- value of connect() is not the handshake.
    local clientEvent = client:service()
    local serverEvent = server:service()
    t.eq(clientEvent and clientEvent.type, 'connect', 'the client gets a connect event')
    t.eq(serverEvent and serverEvent.type, 'connect', 'the server gets a connect event')
    t.ok(server:service() == nil, 'and nothing more is pending')

    local serverPeer = serverEvent.peer
    t.describe('loopback: identity')
    t.ok(server:key(serverPeer) ~= nil, 'the server can key its peer')
    t.ok(server:key(serverPeer) ~= client:key(peer),
         'the two ends of one link are distinct keys')
    t.eq(server:address(serverPeer), '10.0.0.7:5000',
         'the server sees the address the client presented, so bans can work')

    t.describe('loopback: traffic and channels')
    client:send(peer, 'ping', 0, true)
    local got = server:service()
    t.eq(got and got.type, 'receive', 'a sent message arrives')
    t.eq(got and got.data, 'ping', 'with its payload intact')
    t.eq(got and got.channel, 0, 'on the channel it was sent on')
    t.ok(server:key(got.peer) == server:key(serverPeer),
         'and identifies the same peer as the connect event did')

    server:send(serverPeer, 'stream', 1, false)
    got = client:service()
    t.eq(got and got.channel, 1, 'the unreliable channel is a separate channel')
    t.eq(got and got.data, 'stream', 'and carries its payload')

    server:broadcast('to-everyone', 0, true)
    got = client:service()
    t.eq(got and got.data, 'to-everyone', 'broadcast reaches a connected peer')

    t.describe('loopback: latency is real, not free')
    local slowServer = Transport.new('loopback', {})
    slowServer:listen{ port = 7001 }
    local slowClient = Transport.new('loopback', { latency = 0.05 })
    local slowPeer = slowClient:connect('loopback:7001')

    -- The connect event is subject to the same latency, so it has to be waited
    -- for and drained before the delivery of a later message can be asserted on.
    slowClient:update(0.06)
    while slowClient:service() do end
    while slowServer:service() do end

    slowServer:send(slowPeer.mirror, 'later', 0, true)
    t.ok(slowClient:service() == nil, 'a delayed message is not delivered immediately')
    slowClient:update(0.02)
    t.ok(slowClient:service() == nil, 'nor before its latency has elapsed')
    slowClient:update(0.04)
    t.ok(slowClient:service() ~= nil, 'and arrives once it has')

    t.describe('loopback: loss applies to the unreliable channel only')
    local lossyServer = Transport.new('loopback', {})
    lossyServer:listen{ port = 7002 }
    local lossy = Transport.new('loopback', { loss = 1.0 })
    local lossyPeer = lossy:connect('loopback:7002')
    lossy:service(); lossyServer:service()

    lossyServer:send(lossyPeer.mirror, 'unreliable', 1, false)
    t.ok(lossy:service() == nil, 'a dropped unreliable message does not arrive')
    lossyServer:send(lossyPeer.mirror, 'reliable', 0, true)
    local survived = lossy:service()
    t.ok(survived ~= nil and survived.data == 'reliable',
         'a reliable message is never dropped')

    t.describe('loopback: disconnects')
    server:disconnect(serverPeer, 0)
    local bye = client:service()
    t.eq(bye and bye.type, 'disconnect', 'the far side is told')
    t.ok(client:send(peer, 'after', 0, true) == false,
         'and sending to a dead peer fails rather than silently queueing')

    t.describe('loopback: capacity')
    local small = Transport.new('loopback', {})
    small:listen{ port = 7003, maxPeers = 1 }
    local first = Transport.new('loopback', {})
    t.ok(first:connect('loopback:7003') ~= nil, 'the first peer fits')
    local second = Transport.new('loopback', {})
    local overflow, overflowErr = second:connect('loopback:7003')
    t.ok(overflow == nil and overflowErr:find('full'), 'the second is told the server is full')

    Loopback.reset()
    t.eq(#Loopback.listeners(), 0, 'reset() releases every port')
end
