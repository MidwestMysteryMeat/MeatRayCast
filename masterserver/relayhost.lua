--[[
    masterserver.relayhost — the part of the relay that owns a port, and nothing
    else.

    Every rule is in masterserver/relay.lua, which runs under plain LuaJIT with
    no socket. This file accepts connections, hands strings to that module, and
    executes the actions it returns. If it grows a rule, that rule is in the
    wrong file. That is the same seam masterserver/server.lua has, and it is why
    the registry's rules have tests at all.

    ## Why the relay is an ENet host and not a UDP forwarder

    The obvious design is a raw UDP forwarder: peers speak ENet end to end and
    the relay rewrites addresses. It cannot be built. ENet owns its socket and
    discards any datagram that is not ENet, so a peer has no way to address a
    datagram *through* the relay -- its ENet connection would be with the relay
    regardless. Building it anyway means reimplementing ENet's reliability,
    ordering and fragmentation on top of a socket the engine does not own.

    So the relay terminates ENet on both sides and forwards payloads between two
    connections. Both hops get reliability, ordering, fragmentation, congestion
    control and connection management from ENet, unchanged, and the relay adds
    one byte (meatray/net/relaywire.lua). It also gets ENet's connect handshake,
    which is a round trip -- so every link the relay holds came from an address
    that really answered, and a spoofed source cannot occupy one.

    The cost, stated: the two hops are independently reliable rather than
    end-to-end reliable. If the relay dies mid-session, an acknowledged packet
    may not have reached the far side. Both ends see a disconnect and neither is
    left believing the session is healthy, which is the property that matters.

    ## Deployment

    A relay needs a machine with a public address; the implementation does not.
    This runs happily against loopback, which is how it is tested. To deploy:

        love relayserver --port 6790
        love relayserver --port 6790 --secret my-community-secret

    HEADLESS-ish: this module loads with no LOVE, because the transport it uses
    resolves lazily and `enet` is required inside the enet backend's constructor.
    Running it needs lua-enet, which ships with LOVE.
]]

local Relay     = require('masterserver.relay')
local Transport = require('meatray.net.transport')
local Wire      = require('meatray.net.relaywire')
local P         = require('meatray.net.protocol')

local RelayHost = {}

RelayHost.DEFAULT_PORT = 6790

-- How often each link's round-trip time is measured and told to the far end.
-- Once a second: RTT moves slowly, lag compensation reads it every shot, and a
-- control frame a second per link is noise next to a 20 Hz snapshot stream.
RelayHost.RTT_INTERVAL = 1

local RelayHostMT = {}
RelayHostMT.__index = RelayHostMT

-- opts:
--   port           6790
--   bind           '0.0.0.0'  -- never '*', see below
--   transport      'enet' (default) or 'loopback' or a transport instance
--   relay          an existing masterserver.relay, or nil to build one
--   relayOptions   passed to Relay.new
--   onLog
function RelayHost.new(opts)
    opts = opts or {}

    local relay = opts.relay or Relay.new(opts.relayOptions)

    local transport, err = Transport.new(opts.transport or 'enet', {
        channels = opts.channels or P.CHANNELS,
        maxPeers = relay.maxLinks,
    })
    if not transport then return nil, err end

    return setmetatable({
        relay     = relay,
        transport = transport,
        port      = opts.port or RelayHost.DEFAULT_PORT,
        bind      = opts.bind or '0.0.0.0',
        channels  = opts.channels or P.CHANNELS,

        peers  = {},          -- [link key] = transport peer handle
        now    = 0,
        rttAt  = 0,
        onLog  = opts.onLog or print,
    }, RelayHostMT)
end

function RelayHostMT:log(...)
    if self.onLog then self.onLog('[relay] ' .. table.concat({ ... }, ' ')) end
end

function RelayHostMT:start()
    -- '0.0.0.0' spelled out, never '*'. A wildcard that resolves to :: is an
    -- IPv6-only socket that binds cleanly and then never hears from an IPv4
    -- peer, which looks exactly like a blocked port. This project has paid for
    -- that once already; see docs/NETWORKING.md.
    local ok, err = self.transport:listen{
        port     = self.port,
        bind     = self.bind,
        maxPeers = self.relay.maxLinks,
        channels = self.channels,
    }
    if not ok then
        return nil, ('cannot listen on UDP %d: %s'):format(self.port, tostring(err))
    end

    self:log(('listening on UDP %d, up to %d sessions of %d slots')
             :format(self.port, self.relay.maxSessions, self.relay.maxSlots))
    self:log(('budget: %d KiB/s per session, %d KiB/s in total')
             :format(self.relay.sessionRate / 1024, self.relay.total.rate / 1024))
    if self.relay.allocationSecret then
        self:log('private: hosts must present the allocation secret')
    end

    return self
end

function RelayHostMT:stop()
    self.transport:close()
    self.peers = {}
end

---------------------------------------------------------------------------
-- Executing what the logic asked for
---------------------------------------------------------------------------

-- Two action shapes and nothing else. A `close` has already been applied inside
-- the logic -- the link is gone from its tables and every notification it caused
-- is in this same list -- so there is nothing to call back into and no way for a
-- teardown to loop.
function RelayHostMT:apply(actions)
    if not actions then return end

    for _, action in ipairs(actions) do
        local peer = self.peers[action.close or action.to]

        if action.close then
            if peer then
                -- Flushed before the disconnect by the transport, so a `closed
                -- <reason>` control frame queued a line earlier still leaves the
                -- machine. A player dropped without a reason files a bug about
                -- the wrong thing.
                self.transport:disconnect(peer, 0)
            end
            self.peers[action.close] = nil

        elseif action.to and peer then
            self.transport:send(peer, action.data, action.channel, action.reliable)
        end
    end
end

---------------------------------------------------------------------------
-- The loop
---------------------------------------------------------------------------

function RelayHostMT:pump()
    while true do
        local event = self.transport:service()
        if not event then return end

        local key = self.transport:key(event.peer)
        if key then
            if event.type == 'connect' then
                self.peers[key] = event.peer
                local ok, why = self.relay:link(key, self.transport:address(event.peer))
                if not ok then
                    -- Refused before it can cost anything. Told why, because a
                    -- host that cannot get a session and is not told concludes
                    -- the relay is broken.
                    self.transport:send(event.peer,
                        Wire.control('refused ' .. tostring(why)), 0, true)
                    self.transport:disconnect(event.peer, 0)
                    self.peers[key] = nil
                end

            elseif event.type == 'receive' then
                self:apply(self.relay:receive(key, event.data, event.channel))

            elseif event.type == 'disconnect' then
                self:apply(self.relay:unlink(key))
                self.peers[key] = nil
            end
        end
    end
end

-- Measures each link's hop and tells the far end, so a relayed peer can add the
-- two halves and get the real path RTT. See RelayMT:reportRtt for why this is
-- not optional: lag compensation reads transport:rtt(), and half the truth there
-- is worse than none.
function RelayHostMT:pumpRtt()
    if not self.transport.rtt then return end

    for key, peer in pairs(self.peers) do
        local ms = self.transport:rtt(peer)
        if ms then self:apply(self.relay:reportRtt(key, ms)) end
    end
end

function RelayHostMT:update(dt)
    self.now = self.now + (dt or 0)

    self.transport:update(dt)
    self:apply(self.relay:update(self.now))
    self:pump()

    if self.now - self.rttAt >= RelayHost.RTT_INTERVAL then
        self.rttAt = self.now
        self:pumpRtt()
    end

    return self
end

RelayHost.RelayHostMT = RelayHostMT

return RelayHost
