--[[
    meatray.net.discovery.lan — find servers on the local network, configure nothing.

    Zero setup, and it works with the internet unplugged, which makes it the only
    discovery method that is guaranteed to be available at a LAN party or in a
    house whose upstream is down.

    ENet cannot broadcast, so this is LuaSocket UDP — also bundled with LOVE, so
    still nothing to install. The beacon and the game host therefore use two
    different sockets on two different ports, and the beacon's payload carries the
    game port so a browser knows where to actually connect.

    Query/response rather than announce-only, and the reason is ping. An
    announcement is one-way, so a browser that only listens can show a server's
    name and player count but has no way to tell you it is 200 ms away — and ping
    is most of how a player chooses. So:

      * the browser binds an ephemeral port and broadcasts a QUERY;
      * the beacon, bound to the discovery port, replies unicast;
      * the round trip is the ping, measured on the same path the game will use.

    The beacon also broadcasts an unsolicited ANNOUNCE on an interval. That serves
    a browser which chooses to bind the discovery port and listen passively, and it
    means a server that comes up after a browser has stopped querying still appears.

    Same-machine discovery is made explicit: the query goes to the broadcast
    address *and* to 127.0.0.1, because a host and a browser in two processes on
    one box is the normal case while developing, and relying on a broadcast
    looping back is relying on a platform detail.

    HEADLESS: no love.graphics. `require('socket')` happens inside the
    constructors so this file loads with no LOVE at all.
]]

local Serialize = require('meatray.net.serialize')

local LAN = {}

-- Not a registered IANA port; picked to sit clear of the usual game ranges.
LAN.PORT = 27780

LAN.MAGIC    = 'MRC1'
LAN.QUERY    = 'Q'
LAN.ANNOUNCE = 'A'

-- How long an entry survives without being heard from. Three announce intervals,
-- so one lost packet does not make a server flicker out of the list.
LAN.STALE_AFTER = 4.0

-- Bound explicitly to IPv4 rather than to '*'.
--
-- LuaSocket 3.0 creates a UDP socket with an unspecified address family and
-- resolves the family when it binds; '*' resolves to '::', so the socket comes up
-- IPv6-only. Every send to an IPv4 literal then fails with "No such host is
-- known", including to 127.0.0.1, and discovery silently finds nothing at all —
-- which looks exactly like a firewall problem and is not one.
--
-- IPv4 broadcast is what LAN discovery is: IPv6 has no broadcast address, it has
-- multicast, which is a different mechanism and a different implementation. When
-- that lands it belongs behind a second discovery backend, not behind this bind.
local BIND = '0.0.0.0'
local BROADCAST = '255.255.255.255'

local function loadSocket()
    local ok, socket = pcall(require, 'socket')
    if not ok or type(socket) ~= 'table' then
        return nil, 'LuaSocket is unavailable, so LAN discovery is off '
                 .. '(it ships with LOVE; a plain-Lua run does not have it). '
                 .. 'Direct connection by address still works.'
    end
    return socket
end

local function now(socket)
    return socket.gettime and socket.gettime() or os.time()
end

local function pack(kind, body)
    return LAN.MAGIC .. kind .. Serialize.encode(body or {})
end

local function unpack(datagram)
    if type(datagram) ~= 'string' or #datagram < #LAN.MAGIC + 1 then return nil end
    if datagram:sub(1, #LAN.MAGIC) ~= LAN.MAGIC then return nil end
    local kind = datagram:sub(#LAN.MAGIC + 1, #LAN.MAGIC + 1)
    local body = Serialize.decode(datagram:sub(#LAN.MAGIC + 2))
    if type(body) ~= 'table' then return nil end
    return kind, body
end

---------------------------------------------------------------------------
-- Beacon (host side)
---------------------------------------------------------------------------

-- opts.info() must return the current server description; it is called fresh on
-- every announcement rather than captured once, because the player count is the
-- field people actually read and a stale one is worse than none.
function LAN.beacon(opts)
    opts = opts or {}

    local socket, err = loadSocket()
    if not socket then return nil, err end

    local port = opts.discoveryPort or LAN.PORT
    local udp = socket.udp()
    if not udp then return nil, 'could not create a UDP socket for the LAN beacon' end

    udp:settimeout(0)
    udp:setoption('reuseaddr', true)

    local ok, bindErr = udp:setsockname(BIND, port)
    if not ok then
        udp:close()
        return nil, ('LAN beacon could not bind UDP %d: %s (another server on this '
                     .. 'machine already has it; direct connection still works)')
                    :format(port, tostring(bindErr))
    end

    -- Broadcast has to be enabled explicitly, and on some stacks only after bind.
    udp:setoption('broadcast', true)

    local self = {
        source   = 'lan',
        socket   = udp,
        port     = port,
        interval = opts.announceInterval or 1.0,
        elapsed  = math.huge,       -- announce immediately on the first update
        info     = opts.info,
        sent     = 0,
        answered = 0,
    }

    function self:describe()
        local info = (self.info and self.info()) or {}
        return {
            name    = info.name or 'MeatRayCast server',
            map     = info.map or '?',
            players = info.players or 0,
            max     = info.max or 0,
            port    = info.port,             -- the GAME port, not this one
            locked  = info.locked and 1 or 0,
            mode    = info.mode or 'listen',
            version = info.version,
        }
    end

    function self:announce()
        local datagram = pack(LAN.ANNOUNCE, self:describe())
        -- Errors are swallowed: a machine with no route for broadcast (a laptop
        -- with every interface down) must not take the server with it.
        self.socket:sendto(datagram, BROADCAST, self.port)
        self.sent = self.sent + 1
    end

    function self:pump()
        while true do
            local datagram, ip, senderPort = self.socket:receivefrom()
            if not datagram then break end

            local kind = unpack(datagram)
            if kind == LAN.QUERY then
                -- Unicast reply, straight back to the querying socket. This is the
                -- packet whose round trip becomes the displayed ping.
                self.socket:sendto(pack(LAN.ANNOUNCE, self:describe()), ip, senderPort)
                self.answered = self.answered + 1
            end
        end
    end

    function self:update(dt)
        self.elapsed = self.elapsed + (dt or 0)
        if self.elapsed >= self.interval then
            self.elapsed = 0
            self:announce()
        end
        self:pump()
    end

    function self:close()
        if self.socket then self.socket:close(); self.socket = nil end
    end

    return self
end

---------------------------------------------------------------------------
-- Browser (client side)
---------------------------------------------------------------------------

function LAN.browser(opts)
    opts = opts or {}

    local socket, err = loadSocket()
    if not socket then return nil, err end

    local port = opts.discoveryPort or LAN.PORT
    local udp = socket.udp()
    if not udp then return nil, 'could not create a UDP socket for the LAN browser' end

    udp:settimeout(0)
    udp:setsockname(BIND, 0)         -- ephemeral: never fights the beacon for the port
    udp:setoption('broadcast', true)

    local self = {
        source     = 'lan',
        socket     = udp,
        port       = port,
        interval   = opts.queryInterval or 2.0,
        elapsed    = math.huge,      -- query immediately
        found      = {},             -- [address] = entry
        queriedAt  = nil,
        socketlib  = socket,
    }

    function self:refresh()
        self.queriedAt = now(self.socketlib)
        local datagram = pack(LAN.QUERY, { version = opts.version })
        self.socket:sendto(datagram, BROADCAST, self.port)
        -- Explicit loopback, so a host and a browser in two processes on this
        -- machine find each other without depending on broadcast looping back.
        self.socket:sendto(datagram, '127.0.0.1', self.port)
        self.elapsed = 0
    end

    function self:pump()
        while true do
            local datagram, ip = self.socket:receivefrom()
            if not datagram then break end

            local kind, body = unpack(datagram)
            if kind == LAN.ANNOUNCE and body then
                local gamePort = tonumber(body.port)
                if gamePort then
                    local address = ('%s:%d'):format(ip, gamePort)
                    local at = now(self.socketlib)
                    local entry = self.found[address] or { address = address, source = 'lan' }

                    entry.name     = body.name
                    entry.map      = body.map
                    entry.players  = tonumber(body.players) or 0
                    entry.max      = tonumber(body.max) or 0
                    entry.locked   = (tonumber(body.locked) or 0) == 1
                    entry.mode     = body.mode
                    entry.version  = body.version
                    entry.lastSeen = at

                    -- Ping is only meaningful for a reply to our own query; an
                    -- unsolicited announcement arrives whenever the beacon felt
                    -- like it, so it must not overwrite a measured value with noise.
                    if self.queriedAt then
                        local rtt = (at - self.queriedAt) * 1000
                        if rtt >= 0 and rtt < 5000 then entry.ping = math.floor(rtt + 0.5) end
                    end

                    self.found[address] = entry
                end
            end
        end
    end

    function self:update(dt)
        self.elapsed = self.elapsed + (dt or 0)
        if self.elapsed >= self.interval then self:refresh() end
        self:pump()

        local at = now(self.socketlib)
        for address, entry in pairs(self.found) do
            if entry.lastSeen and at - entry.lastSeen > LAN.STALE_AFTER then
                self.found[address] = nil
            end
        end
    end

    function self:servers()
        local out = {}
        for _, entry in pairs(self.found) do out[#out + 1] = entry end
        table.sort(out, function(a, b) return a.address < b.address end)
        return out
    end

    function self:close()
        if self.socket then self.socket:close(); self.socket = nil end
        self.found = {}
    end

    return self
end

return LAN
