--[[
    meatray.net.transport.loopback — the whole net stack, no sockets.

    Messages move between two transport objects in the same process by being put
    on each other's queue. Nothing here opens a file descriptor, so the entire
    replication layer — handshake, snapshots, inputs, world mutation, prediction,
    interpolation — is testable under plain LuaJIT with no LOVE, no ports and no
    firewall.

    That ordering is not tidiness. A replication bug and a socket bug produce the
    same symptom (the client is wrong), and separating them after the fact means
    debugging two systems at once. Verified replication first turns every later
    failure into a transport failure by elimination.

    It is a real transport, not a stub: it honours channels, distinguishes
    reliable from unreliable, and can be told to add latency and to drop
    unreliable packets, so a test can assert that a lost snapshot is survivable
    and that interpolation actually interpolates.

        local host   = Transport.new('loopback', {})
        host:listen{ port = 1 }
        local client = Transport.new('loopback', { clientAddress = '10.0.0.7:5000' })
        local peer   = client:connect('loopback:1')

    HEADLESS: no LOVE, by design and by test.
]]

local Transport = require('meatray.net.transport')
local Worldgen = require('meatray.sim.worldgen')

local Loopback = {}

-- Every listening loopback transport in this process, by port. A module-level
-- table is the honest model here: a socket registry is exactly what an operating
-- system keeps, and pretending otherwise would mean inventing a lookup the real
-- transports do not need.
local listening = {}

local nextLink = 0
local nextClient = 0

local LoopbackMT = {}
LoopbackMT.__index = LoopbackMT

---------------------------------------------------------------------------

-- `clientAddress` — not `address`, which the enet transport uses for the server
-- being dialled — is the address this transport claims to be coming *from*. Each
-- instance gets a distinct one by default so that ban-by-address can be tested
-- for real: two clients that shared an apparent address would make a ban look
-- like it worked when it had only ever seen one address.
function Loopback.new(opts)
    opts = opts or {}

    nextClient = nextClient + 1

    return setmetatable({
        name      = 'loopback',
        clock     = 0,
        inbox     = {},
        peers     = {},          -- [key] = peer handle
        port      = nil,
        localAddress = opts.clientAddress or ('loopback.%d:%d'):format(nextClient, 40000 + nextClient),
        latency   = opts.latency or 0,   -- seconds added to every delivery
        loss      = opts.loss or 0,      -- 0..1, unreliable channel only
        rng       = Worldgen.rng(opts.lossSeed or 20260730),
        closed    = false,
    }, LoopbackMT)
end

-- Drops every listener. Tests call this between cases so a port left open by a
-- failed assertion cannot make the next test pass for the wrong reason.
function Loopback.reset()
    for port in pairs(listening) do listening[port] = nil end
    nextLink = 0
    nextClient = 0
end

function Loopback.listeners()
    local out = {}
    for port in pairs(listening) do out[#out + 1] = port end
    table.sort(out)
    return out
end

---------------------------------------------------------------------------
-- Listening and connecting
---------------------------------------------------------------------------

function LoopbackMT:listen(opts)
    opts = opts or {}
    local port = opts.port or 1

    if listening[port] then
        return nil, ('loopback port %d is already in use'):format(port)
    end

    listening[port] = self
    self.port = port
    self.localAddress = 'loopback:' .. port
    self.maxPeers = opts.maxPeers or 32

    return true
end

function LoopbackMT:connect(address)
    local host, port = Transport.parseAddress(address, 1)
    if host == 'loopback' then
        -- 'loopback:3' parses as host 'loopback', port 3 only when a colon is
        -- present; a bare number is also accepted.
        port = tonumber(port) or 1
    end
    port = tonumber(port) or 1

    local server = listening[port]
    if not server then
        return nil, ('connection refused: nothing is listening on loopback port %s')
            :format(tostring(port))
    end

    local count = 0
    for _ in pairs(server.peers) do count = count + 1 end
    if count >= (server.maxPeers or 32) then
        return nil, 'connection refused: server is full'
    end

    nextLink = nextLink + 1
    local id = nextLink

    -- Two handles for one link. Each side holds the handle that names the *other*
    -- end, exactly as ENet does, so replication code cannot accidentally depend
    -- on which side it is running on.
    local clientSide = {
        key = ('lb%d:server'):format(id),
        address = server.localAddress,
        far = server,
    }
    local serverSide = {
        key = ('lb%d:client'):format(id),
        address = self.localAddress,
        far = self,
    }
    clientSide.mirror = serverSide
    serverSide.mirror = clientSide

    self.peers[clientSide.key] = clientSide
    server.peers[serverSide.key] = serverSide

    server:_enqueue({ type = 'connect', peer = serverSide }, true)
    self:_enqueue({ type = 'connect', peer = clientSide }, true)

    return clientSide
end

---------------------------------------------------------------------------
-- Queueing
---------------------------------------------------------------------------

function LoopbackMT:_enqueue(event, reliable)
    if self.closed then return end

    if not reliable and self.loss > 0 and self.rng:float() < self.loss then
        self.dropped = (self.dropped or 0) + 1
        return
    end

    local box = self.inbox
    box[#box + 1] = { at = self.clock + self.latency, event = event }
end

function LoopbackMT:send(peer, data, channel, reliable)
    if not peer or not peer.far or peer.gone then return false end
    peer.far:_enqueue({
        type = 'receive', peer = peer.mirror, data = data, channel = channel or 0,
    }, reliable ~= false)
    return true
end

function LoopbackMT:broadcast(data, channel, reliable)
    for _, peer in pairs(self.peers) do
        self:send(peer, data, channel, reliable)
    end
end

function LoopbackMT:update(dt)
    self.clock = self.clock + (dt or 0)
end

function LoopbackMT:service()
    local box = self.inbox
    for i = 1, #box do
        local entry = box[i]
        if entry and entry.at <= self.clock then
            table.remove(box, i)
            return entry.event
        end
    end
    return nil
end

---------------------------------------------------------------------------
-- Teardown
---------------------------------------------------------------------------

function LoopbackMT:disconnect(peer, code)
    if not peer or peer.gone then return end
    peer.gone = true

    local mirror = peer.mirror
    if mirror then
        mirror.gone = true
        if peer.far then
            peer.far:_enqueue({ type = 'disconnect', peer = mirror, data = code or 0 }, true)
            peer.far.peers[mirror.key] = nil
        end
    end

    self.peers[peer.key] = nil
end

function LoopbackMT:close()
    for _, peer in pairs(self.peers) do self:disconnect(peer, 0) end
    if self.port and listening[self.port] == self then listening[self.port] = nil end
    self.closed = true
    self.inbox = {}
end

---------------------------------------------------------------------------
-- Identity
---------------------------------------------------------------------------

-- Recorded rather than enforced: there is no packet loss on a table, so there is
-- nothing here for a timeout to detect. It is stored so a test can assert that the
-- setting reached the transport at all — which is the half of "the timeout works"
-- that the enet backend cannot be asked about headlessly, and the half that was
-- missing in every project this hardening came from.
function LoopbackMT:setTimeout(peer, limit, minimum, maximum)
    if not peer then return false end
    peer.timeout = { limit = limit, minimum = minimum, maximum = maximum }
    return true
end

function LoopbackMT:key(peer)     return peer and peer.key end
function LoopbackMT:address(peer) return peer and peer.address end
function LoopbackMT:rtt(peer)     return peer and (self.latency * 2000) or nil end

Transport.register('loopback', Loopback.new)

return Loopback
