--[[
    masterserver.http — request parsing and response building, without a socket.

    Same split as the rest of this directory: everything that decides anything
    is here and testable, and masterserver/server.lua is the thin part that owns
    a port. Parsing HTTP is not hard, but every mistake in it is a security bug,
    and "reads bytes from strangers" is not a thing to leave untested because it
    happens to need a socket to reach.

    The piece worth reading is clientAddress(). Everything the registry does to
    stop a host listing someone else's address depends on knowing who actually
    sent a request, and behind a proxy that answer comes from a header a client
    can forge. Getting it wrong reintroduces the exact bug the registry's
    source-address rule exists to prevent, only harder to see.

    HEADLESS: no love, no socket.
]]

local http = {}

-- Bodies are small: an announce is a few hundred bytes. A generous cap that is
-- still far below anything worth buffering means a hostile client cannot make
-- the registry hold memory by promising a large body.
http.MAX_BODY = 64 * 1024
http.MAX_HEADER_BYTES = 16 * 1024
http.MAX_HEADERS = 64

---------------------------------------------------------------------------
-- Requests
---------------------------------------------------------------------------

local function decodePercent(s)
    return (s:gsub('+', ' '):gsub('%%(%x%x)', function(hex)
        return string.char(tonumber(hex, 16))
    end))
end

-- Splits "a=1&b=2" into a table. Repeated keys keep the first value, because
-- the alternative -- last wins -- lets a request smuggle a second value past
-- something that only looked at the first.
function http.parseQuery(text)
    local out = {}
    if not text or text == '' then return out end

    for pair in text:gmatch('[^&]+') do
        local key, value = pair:match('^([^=]*)=?(.*)$')
        if key and key ~= '' then
            key = decodePercent(key)
            if out[key] == nil then out[key] = decodePercent(value) end
        end
    end

    return out
end

-- Parses a whole request from a string. Returns a request table, or nil plus a
-- status code and message so the caller can answer rather than just drop it.
--
-- Headers are lower-cased on the way in. HTTP header names are
-- case-insensitive, and code that reads `headers['Content-Length']` works
-- against curl and fails against something that sent `content-length`.
function http.parseRequest(text)
    if type(text) ~= 'string' or #text == 0 then
        return nil, 400, 'empty request'
    end

    local headEnd = text:find('\r\n\r\n', 1, true)
    local sep = 4
    if not headEnd then
        -- Tolerate bare LF, which hand-written clients and netcat produce.
        headEnd = text:find('\n\n', 1, true)
        sep = 2
    end
    if not headEnd then return nil, 400, 'incomplete request' end

    local head = text:sub(1, headEnd - 1)
    if #head > http.MAX_HEADER_BYTES then return nil, 431, 'headers too large' end

    local body = text:sub(headEnd + sep)

    local lines = {}
    for line in head:gmatch('[^\r\n]+') do lines[#lines + 1] = line end
    if #lines == 0 then return nil, 400, 'no request line' end

    local method, target, version = lines[1]:match('^(%u+)%s+(%S+)%s+HTTP/(%d%.%d)$')
    if not method then return nil, 400, 'bad request line' end
    if version ~= '1.0' and version ~= '1.1' then
        return nil, 505, 'unsupported HTTP version'
    end

    local headers = {}
    local count = 0
    for i = 2, #lines do
        local name, value = lines[i]:match('^([%w%-_]+)%s*:%s*(.*)$')
        if not name then return nil, 400, 'bad header' end

        count = count + 1
        if count > http.MAX_HEADERS then return nil, 431, 'too many headers' end

        name = name:lower()
        -- First value wins, for the same reason as query parameters: two
        -- Content-Length headers is a request smuggling attempt, not a typo.
        if headers[name] == nil then
            headers[name] = (value:gsub('%s+$', ''))
        end
    end

    local path, query = target:match('^([^?]*)%??(.*)$')

    local declared = tonumber(headers['content-length'])
    if declared then
        if declared < 0 or declared > http.MAX_BODY then
            return nil, 413, 'body too large'
        end
        if #body < declared then return nil, 400, 'body shorter than content-length' end
        body = body:sub(1, declared)
    elseif #body > http.MAX_BODY then
        return nil, 413, 'body too large'
    end

    return {
        method  = method,
        path    = path,
        query   = http.parseQuery(query),
        headers = headers,
        body    = body,
    }
end

---------------------------------------------------------------------------
-- Who actually sent this
---------------------------------------------------------------------------

-- The registry files every announce under the source address of the request,
-- so that a host cannot list someone else's address and turn the browser into
-- an amplifier pointed at them. Behind a reverse proxy or a CDN the socket peer
-- is the proxy, and the real client address arrives in a header -- one that any
-- client can set to anything.
--
-- So the header is read ONLY when the socket peer is a proxy we were explicitly
-- told to trust. With no configured proxies the header is ignored entirely and
-- the socket peer is used, which is the safe default and the right one for
-- anyone running this directly.
--
-- This has to be right from the first deployment, not retrofitted: every entry
-- recorded before the fix has the wrong address in it, and there is no way to
-- tell afterwards which ones were forged.
--
--   peer          the socket peer address, from the transport
--   headers       parsed request headers, lower-cased
--   trusted       set of proxy addresses, { ['10.0.0.1'] = true }, or nil
function http.clientAddress(peer, headers, trusted)
    if type(peer) ~= 'string' or peer == '' then return nil end
    if not trusted or not trusted[peer] then return peer end

    local forwarded = headers and headers['x-forwarded-for']
    if not forwarded or forwarded == '' then return peer end

    -- X-Forwarded-For accumulates left to right: "client, proxy1, proxy2".
    -- Walk from the right, skipping addresses we ourselves trust, and take the
    -- first one that is not a known proxy. Taking the leftmost entry instead is
    -- the classic mistake -- that value is entirely client-supplied, so a client
    -- sending "X-Forwarded-For: 1.2.3.4" would be believed.
    local hops = {}
    for hop in forwarded:gmatch('[^,]+') do
        hops[#hops + 1] = (hop:gsub('^%s+', ''):gsub('%s+$', ''))
    end

    for i = #hops, 1, -1 do
        local hop = hops[i]
        if hop ~= '' and not trusted[hop] then return hop end
    end

    return peer
end

---------------------------------------------------------------------------
-- Responses
---------------------------------------------------------------------------

local REASON = {
    [200] = 'OK',              [204] = 'No Content',
    [400] = 'Bad Request',     [403] = 'Forbidden',
    [404] = 'Not Found',       [405] = 'Method Not Allowed',
    [409] = 'Conflict',        [413] = 'Payload Too Large',
    [429] = 'Too Many Requests',
    [431] = 'Request Header Fields Too Large',
    [500] = 'Internal Server Error',
    [503] = 'Service Unavailable',
    [505] = 'HTTP Version Not Supported',
}

function http.reason(status)
    return REASON[status] or 'Unknown'
end

-- Builds a complete response. Content-Length is always sent and the connection
-- is always closed: this serves small JSON documents to clients that ask once,
-- and keep-alive would buy nothing while adding a state machine.
function http.response(status, body, headers)
    body = body or ''

    local out = {
        ('HTTP/1.1 %d %s'):format(status, http.reason(status)),
        ('Content-Length: %d'):format(#body),
        'Connection: close',
    }

    local given = headers or {}
    if not given['Content-Type'] then
        out[#out + 1] = 'Content-Type: application/json; charset=utf-8'
    end

    for name, value in pairs(given) do
        out[#out + 1] = ('%s: %s'):format(name, tostring(value))
    end

    return table.concat(out, '\r\n') .. '\r\n\r\n' .. body
end

-- An error as JSON, because every other response from this service is JSON and
-- a client that has to branch on content type to read an error message will not
-- bother, and will report "the registry returned nothing".
function http.errorResponse(status, message)
    local text = tostring(message or http.reason(status)):gsub('[%c"\\]', ' ')
    return http.response(status, ('{"error":"%s"}'):format(text))
end

return http
