--[[
    meatray.net — one line to turn networking on.

    The engine does not choose the topology. A co-op crawler, a LAN shooter and a
    persistent server want different answers, so the game chooses and every choice
    is one field:

        MeatRay.net.host{ mode = 'listen', discovery = 'lan' }
        MeatRay.net.host{ mode = 'dedicated', port = 6789, discovery = { 'lan', 'master' } }
        MeatRay.net.join('203.0.113.5:6789')
        MeatRay.net.join(serverList[1])

    The default is `single`: a game that never mentions networking runs exactly as
    it did before, because nothing here is reachable until it is called and the
    modules below load with no LOVE and open no sockets on require.

    Three axes, chosen independently, and none of them leaks into gameplay code:

        mode        single | listen | dedicated | client
        transport   enet (default) | loopback | steam (planned)
        discovery   direct | lan | master (planned) | steam (planned)

    Asking for something that is planned but absent is not an error — a host with
    discovery = { 'lan', 'master' } comes up on LAN and says why master is missing.
    A registry outage must never be the reason a game cannot be played, and the
    same degradation covers a feature that does not exist yet.

    HEADLESS: no love.graphics anywhere under meatray/net/. The enet transport and
    the lan discovery backend need libraries LOVE bundles, and both load lazily, so
    the loopback transport and the whole replication layer run under plain LuaJIT.
]]

local Net = {}

Net.serialize    = require('meatray.net.serialize')
Net.snapcodec    = require('meatray.net.snapcodec')
Net.protocol     = require('meatray.net.protocol')
Net.transport    = require('meatray.net.transport')
Net.discovery    = require('meatray.net.discovery')
Net.replication  = require('meatray.net.replication')
Net.access       = require('meatray.net.access')
Net.diagnostics  = require('meatray.net.diagnostics')
Net.Host         = require('meatray.net.host')
Net.Client       = require('meatray.net.client')

Net.DEFAULT_PORT = Net.Host.DEFAULT_PORT
Net.VERSION      = Net.protocol.VERSION

-- The active session: a host, a client, or nil for single player.
Net.session = nil

---------------------------------------------------------------------------
-- Hosting
---------------------------------------------------------------------------

-- opts:
--   mode         'listen' (default) or 'dedicated'
--   world        required; the World the host is authoritative over
--   entities     the authoritative entity array (defaults to a new one)
--   port         6789
--   name, map    what the server browser shows
--   transport    'enet' (default), 'loopback', or a transport instance
--   discovery    nil, a name, or a list of names
--   worldSpec    a worldgen argument table; when given, clients regenerate the
--                world from the seed instead of receiving the grid
--   password, onAuthenticate, maxPlayers
--   tickRate 60, snapshotRate 20, moveSpeed, turnSpeed
--   onStep(dt, host)                       game simulation, inside the fixed tick
--   onCommand(host, peer, name, body)      what a client action means
--   onPeerJoin / onPeerLeave / onChat / onLog / onWarning
--
-- Returns the host, or nil plus a reason. The reason is always something a player
-- can act on: a port in use, a missing world, an unknown transport.
function Net.host(opts)
    opts = opts or {}

    local host, err = Net.Host.new(opts)
    if not host then return nil, err end

    Net.session = host
    return host
end

---------------------------------------------------------------------------
-- Joining
---------------------------------------------------------------------------

-- `target` is an address string, or a server list entry from a browser, or a
-- table with `host` and `port`. All three because all three are things a caller
-- naturally has: typed text, a clicked row, and a config file.
function Net.join(target, opts)
    opts = opts or {}

    local address
    if type(target) == 'string' then
        address = target
    elseif type(target) == 'table' then
        address = target.address
        if not address and target.host then
            address = Net.transport.formatAddress(target.host, target.port or Net.DEFAULT_PORT)
        end
        -- A locked server entry with no password given is worth catching here
        -- rather than as a rejection three round trips later.
        if target.locked and not opts.password then
            return nil, ('%s is password protected'):format(tostring(address))
        end
    end

    if not address then
        return nil, 'join needs an address, a server list entry, or { host = , port = }'
    end

    local merged = { address = address }
    for k, v in pairs(opts) do merged[k] = v end
    merged.address = address

    local client, err = Net.Client.new(merged)
    if not client then return nil, err end

    Net.session = client
    return client
end

---------------------------------------------------------------------------
-- Browsing
---------------------------------------------------------------------------

-- A server browser over any set of discovery backends. Unavailable ones land in
-- `browser.missing` and the rest still work, so a UI built against this needs no
-- change when master discovery lands — and a discovery backend can be added
-- without touching the browser at all.
function Net.browse(opts)
    opts = opts or {}
    local names = opts.discovery or opts.sources or { 'lan' }
    return Net.discovery.browser(names, opts)
end

---------------------------------------------------------------------------
-- Session
---------------------------------------------------------------------------

function Net.mode()
    if not Net.session then return 'single' end
    return Net.session.mode or 'single'
end

function Net.isHost()
    return Net.session ~= nil and (Net.session.mode == 'listen'
                                   or Net.session.mode == 'dedicated')
end

function Net.isClient()
    return Net.session ~= nil and Net.session.mode == 'client'
end

-- Convenience for a game with one session: update whatever is active, or nothing
-- at all in single player.
function Net.update(dt)
    if Net.session then Net.session:update(dt) end
end

function Net.shutdown()
    if not Net.session then return end
    if Net.session.close then Net.session:close() end
    Net.session = nil
end

return Net
