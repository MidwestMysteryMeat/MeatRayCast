--[[
    meatray.net.discovery.master — find servers anywhere, via a registry.

    LAN discovery works with the internet unplugged and cannot help two players
    in different houses. This is the backend that can, and it is the last piece
    of "a player can host a game anywhere and their friends can find it".

    It talks HTTP to a registry (see masterserver/ for the reference
    implementation, and docs/MASTERSERVER.md for the protocol). Two rules shape
    everything here:

    **A registry outage must never mean the game cannot be played.** Every
    failure in this file is a log line, never an error. A beacon that cannot
    reach any registry keeps running and keeps trying; a browser that gets
    nothing returns an empty list and says why. `direct` and `lan` do not depend
    on this, and a host whose announce fails is still joinable by address.

    **Nothing blocks the game loop.** LuaSocket's blocking helpers are not used
    at all. Every request is a small state machine advanced by :update(dt), so a
    registry that accepts a connection and then says nothing costs a frame's
    worth of nothing rather than a freeze.

    Two registry URLs are tried in order, because one hard-coded URL is a single
    point of failure that reveals itself on the day it goes down.

    The challenge, and why the beacon owns a second UDP port:
    a registry lists nothing until a nonce it sent comes back, which is what
    stops anyone listing a stranger's address. That nonce cannot be sent to the
    game port -- ENet owns it and silently discards anything that is not ENet --
    so the beacon opens its own socket and announces it as `challengePort`. The
    registry then marks the entry `portVerified = false`, because the game port
    itself was never proven open. That limitation is real and is surfaced rather
    than hidden.

    HEADLESS: no love. `require('socket')` happens inside the constructors, so
    this file loads with no LOVE at all.
]]

local json = require('meatray.net.json')

local Master = {}

-- Announce every 10s against a 30s registry timeout: two may be lost before an
-- entry drops out. A rate matched exactly to the timeout would delist a host on
-- a single lost packet.
Master.HEARTBEAT_INTERVAL = 10

-- This backend can carry a hole-punch introduction back to the host, which is
-- what lets a host say whether punching is possible at all. Declared here rather
-- than recognised by name in host.lua: a backend added later should not need an
-- edit somewhere else to be believed.
Master.introduces = true

-- How long one HTTP request may take before it is abandoned. Generous, because
-- an under-tight budget here produces exactly the wrong diagnosis -- "the
-- registry is down" when the answer was simply slower than an impatient
-- deadline. This project has made that mistake before.
Master.REQUEST_TIMEOUT = 15

Master.BROWSE_INTERVAL = 30

local function loadSocket()
    local ok, socket = pcall(require, 'socket')
    if not ok or type(socket) ~= 'table' then
        return nil, 'LuaSocket is not available, so master-server discovery cannot run'
    end
    return socket
end

local function now(socket)
    return socket.gettime and socket.gettime() or os.time()
end

-- "http://host:port/path" -> host, port, path. Only http: a registry behind
-- TLS needs a proxy in front, because LuaSocket has no TLS and pulling in a
-- binary dependency would break the one-file deployment story.
local function parseUrl(url)
    if type(url) ~= 'string' or url == '' then return nil end

    local rest
    if url:find('://', 1, true) then
        -- A URL that HAS a scheme must have one we understand followed by
        -- something. Falling back to the raw string here is what made
        -- "http://" parse as the host `http` on port 80: the scheme match
        -- failed, the whole string went through as a hostport, and the reader
        -- got a DNS failure for a host named "http" instead of being told their
        -- registry URL was malformed.
        rest = url:match('^https?://(.+)$')
        if not rest then return nil end
    else
        rest = url
    end

    local hostport, path = rest:match('^([^/]+)(/?.*)$')
    if not hostport then return nil end

    local host, port = hostport:match('^([^:]+):?(%d*)$')
    if not host or host == '' then return nil end
    -- A host is never a bare scheme, and a stray colon means the split failed.
    if host:find(':') then return nil end

    return host, tonumber(port) or 80, (path == '' and '/' or path)
end

---------------------------------------------------------------------------
-- A non-blocking HTTP request
---------------------------------------------------------------------------

local Request = {}
Request.__index = Request

local function newRequest(socket, url, method, body, deadline)
    local host, port, path = parseUrl(url)
    if not host then return nil, 'cannot parse registry URL: ' .. tostring(url) end

    local sock, err = socket.tcp()
    if not sock then return nil, tostring(err) end
    sock:settimeout(0)

    -- A non-blocking connect returns 'timeout' immediately and finishes later;
    -- readiness is polled for in :update rather than waited on here.
    sock:connect(host, port)

    local lines = {
        ('%s %s HTTP/1.1'):format(method, path),
        'Host: ' .. host,
        'Connection: close',
        'Content-Length: ' .. #(body or ''),
    }
    if body and #body > 0 then
        lines[#lines + 1] = 'Content-Type: application/json'
    end

    return setmetatable({
        socket   = socket,
        sock     = sock,
        state    = 'connecting',
        outgoing = table.concat(lines, '\r\n') .. '\r\n\r\n' .. (body or ''),
        sent     = 0,
        chunks   = {},
        deadline = deadline,
    }, Request)
end

function Request:fail(reason)
    self.state = 'failed'
    self.error = reason
    if self.sock then self.sock:close(); self.sock = nil end
    return self
end

function Request:finish()
    local text = table.concat(self.chunks)
    self.state = 'done'
    if self.sock then self.sock:close(); self.sock = nil end

    local status = tonumber(text:match('^HTTP/%d%.%d (%d%d%d)'))
    if not status then return self:fail('malformed response') end

    local headEnd = text:find('\r\n\r\n', 1, true)
    self.status = status
    self.body = headEnd and text:sub(headEnd + 4) or ''
    return self
end

function Request:update(clock)
    if self.state == 'done' or self.state == 'failed' then return self end

    if clock > self.deadline then
        -- Says how long it waited. "Timed out" alone invites the reader to
        -- assume the budget was too short, which is how a working registry gets
        -- blamed for a slow one.
        return self:fail(('no response within %ds'):format(Master.REQUEST_TIMEOUT))
    end

    if self.state == 'connecting' then
        local _, writable = self.socket.select(nil, { self.sock }, 0)
        if writable and writable[1] then self.state = 'sending' else return self end
    end

    if self.state == 'sending' then
        local sent, err, partial = self.sock:send(self.outgoing, self.sent + 1)
        self.sent = sent or partial or self.sent
        if err and err ~= 'timeout' then return self:fail(tostring(err)) end
        if self.sent >= #self.outgoing then self.state = 'receiving' end
        return self
    end

    if self.state == 'receiving' then
        local readable = self.socket.select({ self.sock }, nil, 0)
        if not (readable and readable[1]) then return self end

        local chunk, err, partial = self.sock:receive(4096)
        local data = chunk or partial
        if data and #data > 0 then self.chunks[#self.chunks + 1] = data end

        -- Connection: close, so the server closing is the end of the body.
        if err == 'closed' then return self:finish() end
        if err and err ~= 'timeout' then return self:fail(tostring(err)) end
    end

    return self
end

---------------------------------------------------------------------------
-- Beacon: announce this host to the registry
---------------------------------------------------------------------------

local Beacon = {}
Beacon.__index = Beacon

-- opts:
--   registries  list of URLs, tried in order
--   info()      returns the current server description
--   onLog       optional
--   onPunch     optional; called with { address, port } for each client
--               asking to be introduced
function Master.beacon(opts)
    opts = opts or {}

    -- Configuration is checked before the environment, deliberately. A missing
    -- registry URL is a mistake in the call, and it should be reported the same
    -- way whether or not LuaSocket happens to be present -- otherwise the same
    -- bug reports "LuaSocket is not available" headless and "needs a registry
    -- URL" under LOVE, and only one of those sends the reader anywhere useful.
    local registries = opts.registries
    if type(registries) == 'string' then registries = { registries } end
    if not registries or #registries == 0 then
        return nil, 'master-server discovery needs at least one registry URL'
    end

    local socket, err = loadSocket()
    if not socket then return nil, err end

    -- The socket the challenge is answered on. It has to be a port of our own:
    -- the game port belongs to ENet, which drops anything that is not ENet.
    local udp = socket.udp()
    if udp then
        -- 0.0.0.0 explicitly, never '*'. LuaSocket 3.0 resolves '*' to :: and
        -- returns an IPv6-only socket, and then every challenge from an IPv4
        -- registry vanishes -- indistinguishable from a closed port, and a
        -- misdiagnosis this project has already paid for once.
        udp:setsockname('0.0.0.0', 0)
        udp:settimeout(0)
    end

    -- Written as a statement rather than `local _, p = udp and udp:getsockname()`.
    -- An `and` expression yields exactly one value, so that form silently drops
    -- the port and binds the challenge to port 0 -- the registry then sends its
    -- nonce nowhere, the host is never listed, and the visible symptom is an
    -- unrelated "unknown token" from the next heartbeat. Cost an end-to-end run
    -- to find and would never have shown up in a unit test.
    local boundPort = 0
    if udp then
        local _, port = udp:getsockname()
        boundPort = tonumber(port) or 0
    end

    return setmetatable({
        socket     = socket,
        registries = registries,
        which      = 1,
        info       = opts.info,
        onLog      = opts.onLog,
        onPunch    = opts.onPunch,

        udp        = udp,
        challengePort = boundPort,

        token      = nil,
        request    = nil,
        clock      = now(socket),
        nextAt     = 0,
        failures   = 0,
        listed     = false,
    }, Beacon)
end

function Beacon:log(text)
    if self.onLog then self.onLog('[master] ' .. text) end
end

function Beacon:url()
    return self.registries[self.which]
end

-- Moves to the next registry after a failure. Two URLs are shipped precisely so
-- that one being down is a shrug rather than an outage.
function Beacon:rotate()
    if #self.registries > 1 then
        self.which = (self.which % #self.registries) + 1
        self:log('trying ' .. self:url())
    end
end

function Beacon:payload()
    local info = self.info and self.info() or {}

    return {
        token      = self.token,
        name       = info.name or 'MeatRayCast server',
        map        = info.map or 'unknown',
        port       = info.port or 6789,
        players    = info.players or 0,
        maxPlayers = info.max or info.maxPlayers or 8,
        protocol   = info.protocol or 0,
        locked     = info.locked and true or false,
        challengePort = self.challengePort,
    }
end

function Beacon:send()
    local body = json.encode(self:payload())
    if not body then return end

    local request, err = newRequest(self.socket, self:url() .. '/v1/announce',
                                    'POST', body, self.clock + Master.REQUEST_TIMEOUT)
    if not request then
        self:log(tostring(err))
        return
    end
    self.request = request
end

function Beacon:handleResponse(request)
    if request.state == 'failed' or (request.status or 0) >= 500 then
        self.failures = self.failures + 1
        self.listed = false
        -- Logged once per transition rather than every attempt: a registry that
        -- is down for an hour must not fill the console.
        if self.failures == 1 then
            self:log('registry unreachable (' ..
                     tostring(request.error or request.status) ..
                     '); direct and lan still work')
        end
        if self.failures % 3 == 0 then self:rotate() end
        return
    end

    self.failures = 0

    local reply = request.body and json.decode(request.body)
    if type(reply) ~= 'table' then return end

    if reply.error then
        -- A refusal is the registry working, so it is said plainly and once.
        self:log('registry refused the announce: ' .. tostring(reply.error))
        self.token = nil
        return
    end

    if reply.token and not self.token then
        self.token = reply.token
        self.nonce = reply.nonce
        self:log('announced; awaiting the challenge')
    end

    if reply.ok and not self.listed then
        self.listed = true
        self:log('listed on ' .. self:url())
    end

    -- Clients waiting to be introduced. Handing them straight to the game means
    -- a punch needs no request of its own.
    if reply.punches and self.onPunch then
        for _, peer in ipairs(reply.punches) do
            if type(peer) == 'table' and peer.address then self.onPunch(peer) end
        end
    end
end

-- The shortest a nudge may bring the next heartbeat forward to. Without a floor,
-- anything that can reach the challenge port can make this host issue HTTP
-- requests as fast as it can send datagrams, which is a small amplifier pointed
-- at our own registry. One a second costs nothing and removes the amplification.
Master.NUDGE_INTERVAL = 1

-- Answers the registry's challenge, and takes the registry's nudge.
--
-- Two messages arrive here now. The challenge is the anti-abuse handshake and
-- has not changed. The nudge exists because of arithmetic: punches ride back on
-- the heartbeat, heartbeats are 10 seconds apart, and a client that has to wait
-- an average of five seconds for the host to be told about it is a client
-- watching a progress bar for no reason. The registry cannot push a punch (it
-- only speaks HTTP to us, and we are the one who calls), but it can send one
-- datagram saying "ask now", and it already has our address and this port from
-- the challenge.
--
-- Deliberately carries no payload. A nudge that named the waiting client would
-- be an unauthenticated stranger telling this host to send packets at a third
-- party, which is a reflection attack with our address on it. This way the only
-- thing a forged nudge can do is cause one early heartbeat to a registry we
-- chose, and the client list still comes from that registry over HTTP.
function Beacon:pumpChallenge()
    if not self.udp then return end

    for _ = 1, 16 do
        local data, from, port = self.udp:receivefrom()
        if not data then return end

        local nonce = data:match('^meatray%-challenge (%x+)$')
        if nonce then
            self.udp:sendto('meatray-challenge-reply ' .. nonce, from, port)
        elseif data == 'meatray-punch-waiting' then
            local soonest = (self.lastNudge or -1e9) + Master.NUDGE_INTERVAL
            local at = math.max(self.clock, soonest)
            if at < self.nextAt then
                self.nextAt = at
                self.lastNudge = at
                self.nudges = (self.nudges or 0) + 1
            end
        end
    end
end

function Beacon:update(dt)
    self.clock = self.clock + (dt or 0)

    self:pumpChallenge()

    if self.request then
        self.request:update(self.clock)
        if self.request.state == 'done' or self.request.state == 'failed' then
            self:handleResponse(self.request)
            self.request = nil
            self.nextAt = self.clock + Master.HEARTBEAT_INTERVAL
        end
        return self
    end

    if self.clock >= self.nextAt then
        self:send()
        self.nextAt = self.clock + Master.HEARTBEAT_INTERVAL
    end

    return self
end

function Beacon:close()
    if self.request and self.request.sock then self.request.sock:close() end
    if self.udp then self.udp:close(); self.udp = nil end
    self.request = nil
end

---------------------------------------------------------------------------
-- Browser: ask the registry what is out there
---------------------------------------------------------------------------

local Browser = {}
Browser.__index = Browser

function Master.browser(opts)
    opts = opts or {}

    -- Configuration is checked before the environment, deliberately. A missing
    -- registry URL is a mistake in the call, and it should be reported the same
    -- way whether or not LuaSocket happens to be present -- otherwise the same
    -- bug reports "LuaSocket is not available" headless and "needs a registry
    -- URL" under LOVE, and only one of those sends the reader anywhere useful.
    local registries = opts.registries
    if type(registries) == 'string' then registries = { registries } end
    if not registries or #registries == 0 then
        return nil, 'master-server discovery needs at least one registry URL'
    end

    local socket, err = loadSocket()
    if not socket then return nil, err end

    return setmetatable({
        socket     = socket,
        registries = registries,
        which      = 1,
        onLog      = opts.onLog,
        protocol   = opts.protocol,

        found      = {},
        request    = nil,
        clock      = now(socket),
        nextAt     = 0,
        lastError  = nil,
    }, Browser)
end

function Browser:log(text)
    if self.onLog then self.onLog('[master] ' .. text) end
end

function Browser:url()
    return self.registries[self.which]
end

function Browser:refresh()
    if self.request then return self end

    local path = '/v1/servers'
    if self.protocol then path = path .. '?protocol=' .. tostring(self.protocol) end

    local request, err = newRequest(self.socket, self:url() .. path, 'GET', nil,
                                    self.clock + Master.REQUEST_TIMEOUT)
    if not request then
        self.lastError = tostring(err)
        return self
    end

    self.request = request
    return self
end

function Browser:handleResponse(request)
    if request.state == 'failed' or (request.status or 0) ~= 200 then
        self.lastError = tostring(request.error or ('HTTP ' .. tostring(request.status)))

        -- Rotate rather than give up. An empty list with no explanation is the
        -- most common way self-hosting silently defeats people, so the reason is
        -- kept and shown.
        if #self.registries > 1 then
            self.which = (self.which % #self.registries) + 1
        end
        return
    end

    local reply = request.body and json.decode(request.body)
    if type(reply) ~= 'table' or type(reply.servers) ~= 'table' then
        self.lastError = 'registry sent something that is not a server list'
        return
    end

    self.lastError = nil

    local out = {}
    for _, row in ipairs(reply.servers) do
        if type(row) == 'table' and row.address and row.port then
            out[#out + 1] = {
                address = row.address .. ':' .. tostring(row.port),
                name    = row.name or '?',
                map     = row.map,
                players = row.players,
                max     = row.maxPlayers,
                locked  = row.locked and true or false,
                protocol = row.protocol,
                -- Passed through rather than dropped: a browser may want to
                -- mark an entry whose game port was never actually proven open.
                portVerified = row.portVerified ~= false,
                source  = 'master',
                -- Where this row came from, carried on the row itself. A client
                -- joining it needs to ask that same registry for an
                -- introduction, and making the caller remember which browser
                -- produced which row is how that step gets skipped.
                registries = self.registries,
                lastSeen = self.clock,
            }
        end
    end

    self.found = out
end

function Browser:update(dt)
    self.clock = self.clock + (dt or 0)

    if self.request then
        self.request:update(self.clock)
        if self.request.state == 'done' or self.request.state == 'failed' then
            self:handleResponse(self.request)
            self.request = nil
            self.nextAt = self.clock + Master.BROWSE_INTERVAL
        end
        return self
    end

    if self.clock >= self.nextAt then
        self:refresh()
        self.nextAt = self.clock + Master.BROWSE_INTERVAL
    end

    return self
end

function Browser:servers()
    return self.found
end

function Browser:error()
    return self.lastError
end

function Browser:close()
    if self.request and self.request.sock then self.request.sock:close() end
    self.request = nil
end

---------------------------------------------------------------------------
-- Introduction: the client's half of a hole punch
---------------------------------------------------------------------------

local Punch = {}
Punch.__index = Punch

-- Asks a registry to introduce this client to a host, so the host punches back.
--
-- The shape of this is dictated by one rule, and getting it wrong is the usual
-- way hole punching does not work: **the caller must not wait for the answer.**
-- Both sides have to send at roughly the same moment, because whichever sends
-- second is the side whose packet reaches a router that has not opened yet. So
-- this returns immediately with a request that :update(dt) advances, and the
-- caller connects on the very next line. The registry says the same thing from
-- its end by returning sendNow = true.
--
-- What the answer is good for is the log, not the flow. Nothing waits on it and
-- no failure here stops the join: a registry that is down turns a punched join
-- into a plain direct one, which is exactly what would have happened without any
-- of this.
--
-- opts:
--   registries   list of URLs, or one URL. Only the first is tried -- a punch is
--                time-critical and a fallback that costs a round trip has missed
--                the moment it existed for.
--   port         OUR UDP port, from transport:localPort()
--   address/port of the host, as `host` and `hostPort`
--
-- Our own address is deliberately not sent. The registry reads it off the
-- connection, for the same reason a host does not get to name where it is.
function Master.punch(opts)
    opts = opts or {}

    local registries = opts.registries
    if type(registries) == 'string' then registries = { registries } end
    if not registries or #registries == 0 then
        return nil, 'a hole punch needs a registry URL'
    end

    local port = tonumber(opts.port)
    if not port or port < 1 or port > 65535 then
        return nil, 'a hole punch needs the local UDP port to introduce, got '
                    .. tostring(opts.port)
    end

    local hostPort = tonumber(opts.hostPort)
    if type(opts.host) ~= 'string' or opts.host == '' or not hostPort then
        return nil, 'a hole punch needs the host address to be introduced to'
    end

    local socket, err = loadSocket()
    if not socket then return nil, err end

    local body = json.encode{ port = port, address = opts.host, hostPort = hostPort }
    if not body then return nil, 'could not encode the punch request' end

    local clock = now(socket)
    local request, requestErr = newRequest(socket, registries[1] .. '/v1/punch',
                                           'POST', body, clock + Master.REQUEST_TIMEOUT)
    if not request then return nil, tostring(requestErr) end

    return setmetatable({
        request = request,
        clock   = clock,
        state   = 'asking',
        onLog   = opts.onLog,
        url     = registries[1],
        port    = port,
        target  = ('%s:%d'):format(opts.host, hostPort),
    }, Punch)
end

function Punch:log(text)
    if self.onLog then self.onLog('[master] ' .. text) end
end

function Punch:update(dt)
    if self.state ~= 'asking' then return self end

    self.clock = self.clock + (dt or 0)
    self.request:update(self.clock)

    local state = self.request.state
    if state ~= 'done' and state ~= 'failed' then return self end

    if state == 'failed' or (self.request.status or 0) ~= 200 then
        self.state = 'failed'
        self.error = tostring(self.request.error
                              or ('HTTP ' .. tostring(self.request.status)))
        -- Said, and immediately said not to matter. An unexplained line about a
        -- registry during a join that then works is a support question; the
        -- second half is what stops it being one.
        self:log(('%s would not introduce us to %s (%s); joining directly instead')
                 :format(self.url, self.target, self.error))
        return self
    end

    local reply = self.request.body and json.decode(self.request.body)
    if type(reply) ~= 'table' or reply.error then
        self.state = 'failed'
        self.error = type(reply) == 'table' and tostring(reply.error)
                     or 'the registry sent something that is not an introduction'
        self:log(('%s refused the introduction: %s'):format(self.url, self.error))
        return self
    end

    self.state = 'done'
    self.sendNow = reply.sendNow and true or false
    self:log(('%s will tell %s we are on UDP %d'):format(self.url, self.target, self.port))
    return self
end

function Punch:done()   return self.state ~= 'asking' end
function Punch:failed() return self.state == 'failed' end

function Punch:close()
    if self.request and self.request.sock then self.request.sock:close() end
    self.request = nil
    if self.state == 'asking' then self.state = 'failed' end
end

-- Exported as a test seam. The socket-owning constructors cannot run headless,
-- but URL parsing and the mapping from a registry reply to server-list entries
-- are pure, carry real edge cases, and are worth testing without a network.
Master.Request = Request
Master.parseUrl = parseUrl
Master.Beacon = Beacon
Master.Browser = Browser
Master.Punch = Punch

return Master
