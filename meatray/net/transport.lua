--[[
    meatray.net.transport — the registry, and the interface a transport must meet.

    Everything above this line (replication, host, client) is written against the
    interface below and never against a concrete transport. That is what makes a
    second transport an addition rather than a rewrite: the Steam sockets backend
    is a file that implements these methods and one line registering it, with no
    edit to gameplay code and no edit to the replication layer.

    A transport implements:

        t.name                      a string, for logs and diagnostics
        t:listen(opts)   -> ok, err opts.port, opts.maxPeers, opts.channels
        t:connect(addr)  -> peer, err
        t:send(peer, data, channel, reliable)
        t:broadcast(data, channel, reliable)
        t:update(dt)                advance internal time; may be a no-op
        t:service()      -> event   or nil when there is nothing pending
        t:disconnect(peer, code)
        t:close()
        t:key(peer)      -> string  stable identity for one connection
        t:address(peer)  -> string  'host:port', used for ban-by-address
        t:rtt(peer)      -> number  milliseconds, or nil if unknown

    And four optional methods:

        t:setTimeout(peer, limit, minimum, maximum) -> ok
        t:open()          -> ok, err     create the socket without connecting
        t:localPort()     -> number|nil  the UDP port that socket is bound to
        t:punch(address)  -> ok, err     emit one outbound packet at an address

    Optional because not every transport can express them — Steam's sockets
    manage their own liveness and their own traversal — so every caller tests for
    the method rather than assuming it.

    `setTimeout`: `limit` is a retransmission factor, `minimum` and `maximum` are
    milliseconds of silence before the connection is given up on. A transport
    that implements it must actually apply it; the host and the client both set
    it and both also keep their own watchdog, because a documented timeout that
    nothing enforces is worse than no timeout at all.

    `open`, `localPort` and `punch` exist for NAT traversal, and the shape they
    have is forced by how a NAT mapping is created. A router opens a mapping when
    it sees an outbound packet **from the specific socket the reply must arrive
    on**. The game socket belongs to the transport, so a punch sent from any
    other socket opens a hole for a port nothing is listening on — which is worth
    nothing at all. Hence:

      * `punch(address)` must emit its packet from the socket `listen`/`connect`
        use, and nothing else. What the packet *is* does not matter; that it
        leaves that socket is the entire content of the method.
      * `localPort()` is what a client tells a registry to introduce it on, and
        it must be the port of that same socket.
      * `open()` exists so a client can learn its port before it connects,
        because the introduction has to be requested and the connection made at
        the same moment. See meatray/net/client.lua.

    A transport that cannot punch simply omits the method, and the host says so
    rather than pretending the attempt was made.

    An event is a table:

        { type = 'connect' | 'disconnect' | 'receive',
          peer = <peer handle>, data = <string, for receive>, channel = <number> }

    service() is called in a loop until it returns nil, so a transport is free to
    deliver several events per frame. `key(peer)` must be stable for the life of
    a connection and must not be reused by a later one; `address(peer)` may be
    shared between connections (two players behind one NAT), which is why bans
    are by address and identity is by key.

    Registered names resolve lazily. `enet` pulls in LOVE's bundled lua-enet the
    first time a host or client is actually created, so requiring this module —
    and therefore running the replication tests — needs no sockets at all.

    HEADLESS: no LOVE. Backends may need it; the registry must not.
]]

local Transport = {}

local backends = {}

-- Built-ins, resolved on first use.
Transport.builtin = {
    loopback = 'meatray.net.transport.loopback',
    enet     = 'meatray.net.transport.enet',
}

-- Names the design reserves but does not implement. Kept here so asking for one
-- produces a straight answer instead of "unknown transport", which reads like a
-- typo when it is actually a roadmap item.
Transport.planned = {
    steam = 'the Steam sockets transport is planned, not implemented; '
         .. 'use enet for now (see docs/NETWORKING.md)',
}

-- Registers a backend. `factory(opts)` returns a transport instance.
function Transport.register(name, factory)
    assert(type(name) == 'string' and name ~= '', 'a transport needs a name')
    assert(type(factory) == 'function', 'a transport needs a factory function')
    backends[name] = factory
    return factory
end

function Transport.registered(name)
    return backends[name] ~= nil or Transport.builtin[name] ~= nil
end

function Transport.names()
    local out = {}
    for name in pairs(Transport.builtin) do out[#out + 1] = name end
    for name in pairs(backends) do
        if not Transport.builtin[name] then out[#out + 1] = name end
    end
    table.sort(out)
    return out
end

function Transport.resolve(name)
    if backends[name] then return backends[name] end

    local path = Transport.builtin[name]
    if path then
        local ok, mod = pcall(require, path)
        if not ok then
            return nil, ('transport %q failed to load: %s'):format(name, tostring(mod))
        end
        backends[name] = mod.new
        return mod.new
    end

    if Transport.planned[name] then
        return nil, Transport.planned[name]
    end

    return nil, ('unknown transport %q (have: %s)')
        :format(tostring(name), table.concat(Transport.names(), ', '))
end

-- Creates a transport. `name` may also be a table, in which case it is taken to
-- be an already-built transport and returned as-is — that is the escape hatch a
-- game needs to supply a transport the engine has never heard of.
function Transport.new(name, opts)
    if type(name) == 'table' then return name end

    local factory, err = Transport.resolve(name or 'enet')
    if not factory then return nil, err end

    return factory(opts or {})
end

---------------------------------------------------------------------------
-- Address helpers, shared by every backend
---------------------------------------------------------------------------

-- Splits 'host:port' into its parts. A bare host gets the default port, so
-- 'MeatRay.net.join("192.168.1.9")' does the obvious thing.
function Transport.parseAddress(address, defaultPort)
    if type(address) ~= 'string' or address == '' then
        return nil, nil, 'no address given'
    end

    -- Bracketed IPv6 literal: [::1]:6789
    local host, port = address:match('^%[(.+)%]:(%d+)$')
    if host then return host, tonumber(port) end
    host = address:match('^%[(.+)%]$')
    if host then return host, defaultPort end

    host, port = address:match('^([^:]+):(%d+)$')
    if host then return host, tonumber(port) end

    if address:find(':') then
        -- A bare IPv6 literal, no port.
        return address, defaultPort
    end

    return address, defaultPort
end

function Transport.formatAddress(host, port)
    if host and host:find(':') then return ('[%s]:%d'):format(host, port or 0) end
    return ('%s:%d'):format(tostring(host), port or 0)
end

return Transport
