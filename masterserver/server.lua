--[[
    masterserver.server — the part that owns a port, and nothing else.

    Everything worth getting right is in registry.lua, http.lua and meatray.net.json,
    all of which run under plain LuaJIT with no socket. This file is the seam:
    it accepts connections, hands strings to those modules, and writes back what
    they return. If it grows a rule, that rule is in the wrong file.

    It needs LuaSocket, which ships with LÖVE, so it runs as:

        love masterserver

    Non-blocking throughout. A registry that blocks on a slow client stops
    answering everyone else, and "slow client" is not an edge case on the
    internet -- it is a technique.
]]

local Registry = require('masterserver.registry')
local json     = require('meatray.net.json')
local http     = require('masterserver.http')

local socket = require('socket')

local Server = {}
local ServerMT = {}
ServerMT.__index = ServerMT

Server.DEFAULT_PORT = 8080

-- How long a connection may take to send a complete request. Short, because the
-- only legitimate client sends a few hundred bytes immediately; a connection
-- that dribbles bytes for a minute is holding a slot, which is the whole point
-- of a slowloris.
Server.REQUEST_TIMEOUT = 5
Server.MAX_CONNECTIONS = 256

function Server.new(opts)
    opts = opts or {}

    local trusted = nil
    if opts.trustedProxies then
        trusted = {}
        for _, address in ipairs(opts.trustedProxies) do trusted[address] = true end
    end

    return setmetatable({
        port      = opts.port or Server.DEFAULT_PORT,
        registry  = opts.registry or Registry.new(opts.registryOptions),
        trusted   = trusted,
        conns     = {},
        now       = 0,
        onLog     = opts.onLog or print,

        -- The UDP socket the challenge goes out on. A host is not listed until
        -- a nonce sent here comes back from the address it claimed, which is the
        -- entire defence against listing somebody else's machine.
        challengePort = opts.challengePort or 0,
        awaiting = {},        -- [nonce] = { token, expires }
    }, ServerMT)
end

function ServerMT:log(...)
    if self.onLog then self.onLog('[registry] ' .. table.concat({ ... }, ' ')) end
end

function ServerMT:start()
    local listener, err = socket.bind('*', self.port)
    if not listener then
        return nil, ('cannot listen on TCP %d: %s'):format(self.port, tostring(err))
    end
    listener:settimeout(0)
    self.listener = listener

    local udp = socket.udp()
    if udp then
        -- Bind explicitly to 0.0.0.0 rather than '*'. LuaSocket 3.0 resolves '*'
        -- to :: and hands back an IPv6-only socket, and then every challenge to
        -- an IPv4 host silently goes nowhere -- which looks exactly like "every
        -- host on the internet has a closed port". That cost this project real
        -- time once already.
        udp:setsockname('0.0.0.0', self.challengePort)
        udp:settimeout(0)
        self.udp = udp
    end

    local _, actualPort = listener:getsockname()
    self.port = tonumber(actualPort) or self.port
    self:log(('listening on TCP %d'):format(self.port))

    return self
end

function ServerMT:stop()
    for _, conn in ipairs(self.conns) do conn.client:close() end
    self.conns = {}
    if self.listener then self.listener:close(); self.listener = nil end
    if self.udp then self.udp:close(); self.udp = nil end
end

---------------------------------------------------------------------------
-- Routing
---------------------------------------------------------------------------

-- Returns status, body. Pure: it takes a parsed request plus the address the
-- request really came from, and touches no socket.
function ServerMT:route(request, address)
    local registry = self.registry

    if request.path == '/v1/health' then
        return 200, json.encode{
            ok = true, servers = registry:count(), uptime = self.now,
        }
    end

    if request.path == '/v1/servers' then
        if request.method ~= 'GET' then return 405, nil end

        local filter = {}
        if request.query.protocol then filter.protocol = tonumber(request.query.protocol) end
        if request.query.notFull == '1' then filter.notFull = true end
        if request.query.notLocked == '1' then filter.notLocked = true end

        local rows = registry:list(filter)
        -- Marked as an array so an empty list encodes as [] and not {}. That is
        -- the case a new player hits first, when nobody is hosting.
        return 200, json.encode{ servers = json.array(rows) }
    end

    if request.path == '/v1/announce' then
        if request.method ~= 'POST' then return 405, nil end

        local payload, err = json.decode(request.body)
        if not payload then return 400, ('{"error":"bad JSON: %s"}'):format(tostring(err)) end

        -- A heartbeat is an announce carrying a token.
        if payload.token then
            local ok, hbErr = registry:heartbeat(payload.token, payload)
            if not ok then return 404, ('{"error":"%s"}'):format(tostring(hbErr)) end
            ok.punches = json.array(registry:takePunches(payload.token))
            return 200, json.encode(ok)
        end

        local challenge, aErr = registry:announce(address, payload)
        if not challenge then return 400, ('{"error":"%s"}'):format(tostring(aErr)) end

        self:sendChallenge(challenge)
        return 200, json.encode{
            token = challenge.token,
            nonce = challenge.nonce,
            -- Told plainly, because a host that never gets listed and is not
            -- told why concludes the registry is broken.
            note = 'reply to the UDP challenge sent to your address to be listed',
        }
    end

    if request.path == '/v1/punch' then
        if request.method ~= 'POST' then return 405, nil end

        local payload = json.decode(request.body)
        if not payload then return 400, '{"error":"bad JSON"}' end

        local intro, pErr = registry:requestPunch(
            address, tonumber(payload.port),
            tostring(payload.address or ''), tonumber(payload.hostPort))

        if not intro then return 404, ('{"error":"%s"}'):format(tostring(pErr)) end
        return 200, json.encode(intro)
    end

    return 404, nil
end

-- Sends the nonce to the address the host claimed. The reply arrives on the UDP
-- socket and is matched in :pumpUdp.
function ServerMT:sendChallenge(challenge)
    if not self.udp then return end

    self.awaiting[challenge.nonce] = {
        token = challenge.token,
        expires = self.now + self.registry.challengeTimeout,
    }
    self.udp:sendto('meatray-challenge ' .. challenge.nonce,
                    challenge.address, challenge.port)
end

---------------------------------------------------------------------------
-- The loop
---------------------------------------------------------------------------

function ServerMT:accept()
    while #self.conns < Server.MAX_CONNECTIONS do
        local client = self.listener:accept()
        if not client then return end

        client:settimeout(0)
        local peer = client:getpeername() or ''
        self.conns[#self.conns + 1] = {
            client = client, peer = peer,
            buffer = {}, deadline = self.now + Server.REQUEST_TIMEOUT,
        }
    end
end

function ServerMT:pumpConnections()
    for i = #self.conns, 1, -1 do
        local conn = self.conns[i]
        local done = false

        local chunk, err, partial = conn.client:receive(4096)
        local data = chunk or partial
        if data and #data > 0 then conn.buffer[#conn.buffer + 1] = data end

        local text = table.concat(conn.buffer)

        -- A request is complete once the headers are, plus whatever body the
        -- headers promised. parseRequest says "incomplete" rather than failing,
        -- so a request split across packets is waited for rather than rejected.
        if text:find('\r\n\r\n', 1, true) or text:find('\n\n', 1, true) then
            local request, status, why = http.parseRequest(text)

            if request then
                local address = http.clientAddress(conn.peer, request.headers, self.trusted)
                local ok, resStatus, body = pcall(self.route, self, request, address)

                if not ok then
                    -- A handler that raises must not take the registry down. One
                    -- malformed request killing the service is a denial of
                    -- service with a single packet.
                    self:log('handler error: ' .. tostring(resStatus))
                    conn.client:send(http.errorResponse(500, 'internal error'))
                else
                    conn.client:send(body and http.response(resStatus, body)
                                          or http.errorResponse(resStatus))
                end
                done = true

            elseif why ~= 'incomplete request' and why ~= 'body shorter than content-length' then
                conn.client:send(http.errorResponse(status or 400, why))
                done = true
            end
        end

        if err == 'closed' then done = true end
        if self.now > conn.deadline then
            -- Timed out mid-request. Answered rather than dropped, so a genuinely
            -- slow client learns why instead of seeing a silent disconnect.
            pcall(function() conn.client:send(http.errorResponse(408, 'request timed out')) end)
            done = true
        end

        if done then
            conn.client:close()
            table.remove(self.conns, i)
        end
    end
end

function ServerMT:pumpUdp()
    if not self.udp then return end

    for _ = 1, 64 do
        local data = self.udp:receivefrom()
        if not data then return end

        local nonce = data:match('^meatray%-challenge%-reply (%x+)$')
        if nonce then
            local pending = self.awaiting[nonce]
            if pending and self.now <= pending.expires then
                self.awaiting[nonce] = nil
                self.registry:challengeReply(pending.token, nonce)
            end
        end
    end
end

function ServerMT:update(dt)
    self.now = self.now + (dt or 0)
    self.registry:update(self.now)

    for nonce, pending in pairs(self.awaiting) do
        if self.now > pending.expires then self.awaiting[nonce] = nil end
    end

    self:accept()
    self:pumpConnections()
    self:pumpUdp()

    return self
end

Server.ServerMT = ServerMT

return Server
