--[[
    meatray.net.transport.enet — real UDP, via the lua-enet that ships with LOVE.

    Bundled matters more than it sounds. The usual reason people cannot self-host
    a Lua game is that the networking library needs a C toolchain, and a
    dependency that has to be compiled is a dependency most players will not
    install. `require('enet')` works in a stock LOVE install on every platform it
    ships for, so a dedicated server is a launch flag rather than a build.

    ENet gives us the two channels the protocol wants — ordered reliable, and
    unreliable-sequenced — over one socket, plus connection management and RTT
    measurement. What it does not give us is broadcast, which is why LAN discovery
    is LuaSocket (see meatray/net/discovery/lan.lua).

    Peer identity: `tostring(peer)` on a lua-enet peer is its 'ip:port', which is
    stable for the life of the connection and unique while it is open. That is the
    connection key. Bans are by IP, taken from the same string, because two
    players behind one router share an address but not a port.

    `require('enet')` happens inside new(), not at file scope, so this module can
    be loaded and inspected — including by the headless test that asserts no net
    module touches love.graphics — with no LOVE present at all.
]]

local Transport = require('meatray.net.transport')
local P = require('meatray.net.protocol')

local Enet = {}

local EnetMT = {}
EnetMT.__index = EnetMT

-- 'unreliable' rather than 'unsequenced': both may be dropped, but only
-- unreliable-sequenced also *discards a packet that arrives after a newer one*.
-- For a snapshot stream that is the whole point — a late snapshot is a player
-- being shown the past, which is worse than a gap. (The client also refuses
-- out-of-order snapshots by tick number, because a transport is allowed to be
-- less careful than this one.)
local FLAG = { [true] = 'reliable', [false] = 'unreliable' }

local function loadEnet()
    local ok, mod = pcall(require, 'enet')
    if not ok or type(mod) ~= 'table' then
        return nil, 'lua-enet is unavailable: it ships with LOVE, so this is '
                 .. 'either a plain-Lua run or a stripped build. '
                 .. 'Use the loopback transport for headless tests.'
    end
    return mod
end

function Enet.new(opts)
    opts = opts or {}

    local enet, err = loadEnet()
    if not enet then return nil, err end

    return setmetatable({
        name     = 'enet',
        enet     = enet,
        host     = nil,
        peers    = {},          -- [key] = enet peer
        channels = opts.channels or P.CHANNELS,
        maxPeers = opts.maxPeers or 32,
        outgoing = nil,         -- the peer a client connected to
    }, EnetMT)
end

---------------------------------------------------------------------------
-- Listening and connecting
---------------------------------------------------------------------------

function EnetMT:listen(opts)
    opts = opts or {}
    local port = opts.port or 6789
    local bind = opts.bind or '0.0.0.0'

    self.maxPeers = opts.maxPeers or self.maxPeers
    self.channels = opts.channels or self.channels

    -- enet.host_create raises rather than returning nil on a bind failure, so the
    -- error has to be caught here or a port clash takes the whole game down.
    local ok, host = pcall(self.enet.host_create,
                           Transport.formatAddress(bind, port),
                           self.maxPeers, self.channels)

    if not ok or not host then
        return nil, ('cannot listen on UDP %d: %s')
            :format(port, ok and 'address unavailable' or tostring(host))
    end

    self.host = host
    self.port = port
    return true
end

-- Creates the socket without connecting to anything.
--
-- `connect` used to be the only thing that made a client socket, which was fine
-- until a client needed to know its own UDP port *before* it dialled — a hole
-- punch has to be requested and the connection made at the same moment, and the
-- request has to name the port the introduction should point at. Splitting this
-- out is the whole change: connect still creates the socket if nobody did, so no
-- existing caller has to learn about it.
--
-- '0.0.0.0:0' rather than nil, and the difference is not cosmetic.
--
-- Both give a client an ephemeral port, which is what a client wants -- a fixed
-- one would clash with a second copy of the game on the same machine. But
-- `enet_host_create(NULL, ...)` never calls bind and never fills in the host's
-- own address, so `get_socket_address()` on such a host returns whatever was in
-- the malloc'd struct. Observed, not deduced: three client hosts in a row all
-- reported "96.19.198.129:339", identical and meaningless, and a client that
-- believed it told a registry to introduce it on UDP 339. Passing an address --
-- even a wildcard one -- makes ENet bind and then read the real port back.
--
-- 0.0.0.0 is spelled out for the other reason this project already knows about:
-- a wildcard that resolves to :: is an IPv6-only socket that binds cleanly and
-- then never hears from an IPv4 peer, which looks exactly like a blocked port.
function EnetMT:open()
    if self.host then return true end

    local ok, client = pcall(self.enet.host_create, '0.0.0.0:0', 1, self.channels)
    if not ok or not client then
        return nil, 'could not create a client socket: ' .. tostring(client)
    end

    self.host = client
    return true
end

-- The UDP port this transport's socket is actually bound to, which for a client
-- is whatever the operating system handed out. Read from the socket rather than
-- remembered from a request: an ephemeral bind has no number until it happens,
-- and this is the number a registry is told to introduce us on.
function EnetMT:localPort()
    if not self.host then return nil end

    local ok, address = pcall(self.host.get_socket_address, self.host)
    if not ok or type(address) ~= 'string' then return nil end

    -- Written as a statement, not `local _, port = ... and ...`. An `and`
    -- expression yields exactly one value, so that form drops the port silently
    -- and hands back nil -- which here would degrade a punched join to a direct
    -- one for no visible reason.
    local _, port = Transport.parseAddress(address, nil)
    port = tonumber(port)

    -- Port 0 is not a port anything can be introduced on. Reported as "we do not
    -- know" rather than passed on, because a registry told to introduce a client
    -- on port 0 refuses, and the reader would be looking at the registry.
    if not port or port < 1 then return nil end
    return port
end

-- Emits one outbound packet at `address`, from the game socket, to open a NAT
-- mapping for it.
--
-- The method is one line of real work and the reasoning behind it is the
-- feature. A router opens an inbound path when it sees an outbound packet from
-- the socket that path leads to. Our game socket belongs to ENet; ENet discards
-- any datagram that is not ENet, so we cannot borrow a LuaSocket UDP socket to
-- do this — a punch from a second socket opens a mapping for the second
-- socket's port, and the game port stays as shut as it was. (That constraint
-- already shaped the registry challenge, which is why the beacon owns its own
-- port and its entries are marked portVerified = false.)
--
-- `host:connect()` is the outbound packet. It puts an ENet CONNECT command on
-- the wire from exactly the right socket, which is all we want; the peer it
-- returns exists only because the API returns one, and is reset immediately.
-- `reset` rather than `disconnect`: the peer is not connected to anything, so
-- there is nobody to say goodbye to, and reset frees the slot without emitting
-- a second packet or an event.
--
-- Observed rather than assumed: with a host bound to 6789 punching at a UDP
-- listener, the listener receives a 52-byte datagram whose *source port is
-- 6789*. That source port is the claim this whole design rests on.
function EnetMT:punch(address)
    local host, port = Transport.parseAddress(address, 6789)
    if not host then return nil, port or 'bad address' end

    local opened, openErr = self:open()
    if not opened then return nil, openErr end

    local target = Transport.formatAddress(host, port)

    local ok, peer = pcall(self.host.connect, self.host, target, self.channels)
    if not ok or not peer then
        -- Every peer slot is in use, most likely. Reported rather than swallowed:
        -- a punch that never went out and a punch that went out and failed are
        -- different diagnoses, and only one of them is about the network.
        return nil, ('could not punch towards %s: %s'):format(target, tostring(peer))
    end

    -- Flush before the reset. ENet queues outgoing commands and sends them on the
    -- next service; resetting the peer first would discard the command and the
    -- punch would be a function call that did nothing at all -- the exact failure
    -- this method exists to avoid, and invisible from the caller's side.
    pcall(self.host.flush, self.host)
    pcall(peer.reset, peer)

    -- Deliberately NOT added to self.peers and NOT stored as self.outgoing. It is
    -- not a connection and must never be handed to send() or counted as one.
    return true
end

function EnetMT:connect(address)
    local host, port = Transport.parseAddress(address, 6789)
    if not host then return nil, port or 'bad address' end

    local opened, openErr = self:open()
    if not opened then return nil, openErr end

    local ok, peer = pcall(self.host.connect, self.host,
                           Transport.formatAddress(host, port), self.channels)
    if not ok or not peer then
        return nil, ('could not reach %s: %s')
            :format(Transport.formatAddress(host, port), tostring(peer))
    end

    self.outgoing = peer
    self.peers[tostring(peer)] = peer
    return peer
end

---------------------------------------------------------------------------
-- Traffic
---------------------------------------------------------------------------

function EnetMT:send(peer, data, channel, reliable)
    if not peer or not self.host then return false end
    local ok = pcall(peer.send, peer, data, channel or 0, FLAG[reliable ~= false])
    return ok
end

function EnetMT:broadcast(data, channel, reliable)
    if not self.host then return end
    pcall(self.host.broadcast, self.host, data, channel or 0, FLAG[reliable ~= false])
end

-- ENet keeps its own clock, so there is nothing to advance. The method exists
-- because the loopback transport does need it and the interface must be uniform.
function EnetMT:update() end

function EnetMT:service()
    if not self.host then return nil end

    -- Zero timeout: the caller drains events in a loop and the game loop must not
    -- block. ENet still does its own bookkeeping on every service call, which is
    -- why this is called every frame even when nothing is pending.
    local ok, event = pcall(self.host.service, self.host, 0)
    if not ok or not event then return nil end

    if event.type == 'connect' then
        self.peers[tostring(event.peer)] = event.peer
    elseif event.type == 'disconnect' then
        self.peers[tostring(event.peer)] = nil
    end

    return event
end

function EnetMT:disconnect(peer, code)
    if not peer then return end

    -- Flush before disconnecting. `disconnect_now` resets the peer immediately and
    -- **discards anything still queued for it**, so a kick reason sent a moment
    -- earlier — which is exactly the pattern a kick uses — would never leave the
    -- machine, and the kicked player would see an unexplained drop instead of the
    -- reason the host gave. `disconnect_later` would preserve the queue but needs
    -- continued servicing to complete, which a client that is quitting does not do.
    -- Flush, then disconnect, satisfies both callers.
    if self.host then pcall(self.host.flush, self.host) end

    pcall(peer.disconnect_now, peer, code or 0)
    self.peers[tostring(peer)] = nil
end

function EnetMT:close()
    if not self.host then return end
    for _, peer in pairs(self.peers) do pcall(peer.disconnect_now, peer, 0) end
    self.peers = {}
    -- Two services with a short timeout give the disconnects a chance to leave
    -- the machine; without them a client that quits looks to the host like a
    -- timeout thirty seconds later.
    pcall(self.host.flush, self.host)
    pcall(self.host.service, self.host, 10)
    self.host = nil
end

---------------------------------------------------------------------------
-- Identity
---------------------------------------------------------------------------

function EnetMT:key(peer)
    return peer and tostring(peer) or nil
end

function EnetMT:address(peer)
    return peer and tostring(peer) or nil
end

-- Just the host part, which is what a ban applies to.
function EnetMT:ip(peer)
    local address = self:address(peer)
    if not address then return nil end
    local host = Transport.parseAddress(address, 0)
    return host
end

-- ENet already measures liveness — it round-trips reliable traffic and knows when
-- a peer stopped acknowledging — so the half-open connection that leaves a client
-- sitting on "connected" forever is a call away, and the usual reason it is not
-- fixed is that nobody makes the call.
--
--   limit    retransmission factor before the minimum starts to matter
--   minimum  ms; the earliest ENet may give up, once retransmissions run out
--   maximum  ms; the latest it may wait, no matter how healthy the link looked
function EnetMT:setTimeout(peer, limit, minimum, maximum)
    if not peer then return false end
    return (pcall(peer.timeout, peer, limit or 32, minimum or 5000, maximum or 30000))
end

function EnetMT:rtt(peer)
    if not peer then return nil end
    local ok, value = pcall(peer.round_trip_time, peer)
    if ok then return value end
    return nil
end

Transport.register('enet', Enet.new)

return Enet
