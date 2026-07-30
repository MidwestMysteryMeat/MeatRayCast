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

function EnetMT:connect(address)
    local host, port = Transport.parseAddress(address, 6789)
    if not host then return nil, port or 'bad address' end

    if not self.host then
        local ok, client = pcall(self.enet.host_create, nil, 1, self.channels)
        if not ok or not client then
            return nil, 'could not create a client socket: ' .. tostring(client)
        end
        self.host = client
    end

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

function EnetMT:rtt(peer)
    if not peer then return nil end
    local ok, value = pcall(peer.round_trip_time, peer)
    if ok then return value end
    return nil
end

Transport.register('enet', Enet.new)

return Enet
