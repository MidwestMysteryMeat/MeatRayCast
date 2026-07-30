--[[
    HTTP request parsing for the registry.

    The clientAddress cases are the ones that matter. The registry's defence
    against a host listing someone else's address is "use the source address of
    the request", and behind a proxy that answer comes from a header any client
    can forge. Get it wrong and the amplification bug is back, wearing a
    different hat.
]]

return function(t)
    local http = require('masterserver.http')

    local function request(text)
        return http.parseRequest((text:gsub('\n', '\r\n')))
    end

    ---------------------------------------------------------------------
    t.describe('ordinary requests')

    local r = request('GET /v1/servers HTTP/1.1\nHost: example.com\n\n')
    t.ok(r ~= nil, 'a GET parses')
    t.eq(r.method, 'GET', 'method')
    t.eq(r.path, '/v1/servers', 'path')
    t.eq(r.headers.host, 'example.com', 'headers are readable')

    -- Header names are case-insensitive in HTTP. Code that reads
    -- headers['Content-Length'] works against curl and breaks against anything
    -- that sent it lower-case, so they are normalised on the way in.
    local mixed = request('GET / HTTP/1.1\nContent-Length: 0\nX-Custom: v\n\n')
    t.eq(mixed.headers['content-length'], '0', 'a mixed-case header is found lower-case')
    t.eq(mixed.headers['x-custom'], 'v', 'and so is a custom one')

    local post = request('POST /v1/announce HTTP/1.1\nContent-Length: 7\n\n{"a":1}')
    t.eq(post.method, 'POST', 'a POST parses')
    t.eq(post.body, '{"a":1}', 'and carries its body')

    -- The body is cut to Content-Length. Anything past it is the start of
    -- another request, and treating it as body is how request smuggling works.
    local extra = request('POST /x HTTP/1.1\nContent-Length: 3\n\nabcGET /evil HTTP/1.1\n\n')
    t.eq(extra.body, 'abc', 'the body stops at content-length')

    t.eq(request('GET /a/b?x=1&y=hello HTTP/1.1\n\n').query.x, '1', 'query strings parse')
    t.eq(request('GET /a?y=hello%20there HTTP/1.1\n\n').query.y, 'hello there',
         'and percent-decode')
    t.eq(request('GET /a?p=a+b HTTP/1.1\n\n').query.p, 'a b', 'and decode + as space')
    t.eq(request('GET /a?x=1 HTTP/1.1\n\n').path, '/a', 'the path excludes the query')

    -- First value wins for a repeated key, both in the query and in headers.
    -- Last-wins lets a request slip a second value past anything that only
    -- looked at the first.
    t.eq(request('GET /a?x=1&x=2 HTTP/1.1\n\n').query.x, '1', 'a repeated query key keeps the first')
    t.eq(request('GET / HTTP/1.1\nContent-Length: 3\nContent-Length: 900\n\nabc')
         .headers['content-length'], '3', 'and so does a repeated header')

    ---------------------------------------------------------------------
    t.describe('malformed requests are answered, not dropped')

    local bad = {
        { '', 'empty input' },
        { 'GET /', 'no blank line' },
        { 'GET /\n\n', 'no HTTP version' },
        { 'get / HTTP/1.1\n\n', 'a lower-case method' },
        { 'GET  HTTP/1.1\n\n', 'no target' },
        { 'GET / HTTP/9.9\n\n', 'an unsupported version' },
        { 'GET / HTTP/1.1\nnot a header\n\n', 'a malformed header' },
    }
    for _, case in ipairs(bad) do
        local parsed, status, why = http.parseRequest((case[1]:gsub('\n', '\r\n')))
        t.eq(parsed, nil, case[2] .. ' is refused')
        t.ok(type(status) == 'number' and status >= 400,
             'with a 4xx/5xx status: ' .. case[2] .. ' -> ' .. tostring(status))
        t.ok(type(why) == 'string', 'and a reason: ' .. tostring(why))
    end

    -- A body shorter than promised is incomplete, not empty. Treating it as
    -- complete would parse half a JSON document.
    local short = http.parseRequest('POST / HTTP/1.1\r\nContent-Length: 100\r\n\r\nabc')
    t.eq(short, nil, 'a body shorter than content-length is refused')

    local huge = http.parseRequest(
        'POST / HTTP/1.1\r\nContent-Length: ' .. (http.MAX_BODY + 1) .. '\r\n\r\n')
    t.eq(huge, nil, 'an oversized declared body is refused before it is buffered')

    local manyHeaders = { 'GET / HTTP/1.1' }
    for i = 1, http.MAX_HEADERS + 10 do manyHeaders[#manyHeaders + 1] = ('h%d: v'):format(i) end
    local flood = http.parseRequest(table.concat(manyHeaders, '\r\n') .. '\r\n\r\n')
    t.eq(flood, nil, 'a header flood is refused')

    -- Bare LF is accepted, because hand-written clients and netcat produce it.
    t.ok(http.parseRequest('GET / HTTP/1.1\n\n') ~= nil, 'bare LF line endings are tolerated')

    ---------------------------------------------------------------------
    t.describe('who actually sent this')

    local headers = { ['x-forwarded-for'] = '203.0.113.9' }

    -- With no configured proxies the header is ignored completely. This is the
    -- safe default and the right behaviour for anyone running the registry
    -- directly rather than behind something.
    t.eq(http.clientAddress('198.51.100.1', headers, nil), '198.51.100.1',
         'with no trusted proxies the socket peer wins')
    t.eq(http.clientAddress('198.51.100.1', headers, {}), '198.51.100.1',
         'and an empty trust list is the same as none')

    -- The forgery case. A client connecting directly and claiming to be someone
    -- else must not be believed, or the registry files its entry under the
    -- victim's address and every browser click sends traffic there.
    t.eq(http.clientAddress('198.51.100.1', { ['x-forwarded-for'] = '8.8.8.8' }, nil),
         '198.51.100.1', 'a direct client cannot forge its address')

    -- Behind a trusted proxy the header is read.
    local trusted = { ['10.0.0.1'] = true }
    t.eq(http.clientAddress('10.0.0.1', headers, trusted), '203.0.113.9',
         'behind a trusted proxy the forwarded address is used')

    -- A chain: "client, proxy1, proxy2". Walk from the right past addresses we
    -- trust and take the first that is not ours. Taking the LEFTMOST value is
    -- the classic mistake, because that end is entirely client-supplied.
    local chain = { ['x-forwarded-for'] = '203.0.113.9, 10.0.0.2, 10.0.0.1' }
    local twoProxies = { ['10.0.0.1'] = true, ['10.0.0.2'] = true }
    t.eq(http.clientAddress('10.0.0.1', chain, twoProxies), '203.0.113.9',
         'a chain of trusted proxies resolves to the real client')

    -- The attack on that: a client prepends a fake hop. The real client address
    -- is still the rightmost untrusted one, so the forged entry is not reached.
    local forged = { ['x-forwarded-for'] = '1.2.3.4, 203.0.113.9, 10.0.0.1' }
    t.eq(http.clientAddress('10.0.0.1', forged, trusted), '203.0.113.9',
         'a client-prepended hop does not displace the real address')

    t.eq(http.clientAddress('10.0.0.1', { ['x-forwarded-for'] = '' }, trusted), '10.0.0.1',
         'an empty header falls back to the peer')
    t.eq(http.clientAddress('10.0.0.1', {}, trusted), '10.0.0.1',
         'and so does a missing one')
    t.eq(http.clientAddress(nil, headers, trusted), nil, 'no peer means no address')

    ---------------------------------------------------------------------
    t.describe('responses')

    local ok = http.response(200, '{"a":1}')
    t.ok(ok:find('^HTTP/1.1 200 OK\r\n'), 'the status line is right')
    t.ok(ok:find('Content%-Length: 7'), 'content-length matches the body')
    t.ok(ok:find('Content%-Type: application/json'), 'JSON by default')
    t.ok(ok:find('\r\n\r\n{"a":1}$'), 'and the body follows a blank line')

    local empty = http.response(204)
    t.ok(empty:find('Content%-Length: 0'), 'a bodyless response says length zero')

    local err = http.errorResponse(404, 'no such server')
    t.ok(err:find('^HTTP/1.1 404 Not Found'), 'an error carries its status')
    t.ok(err:find('{"error":"no such server"}'), 'and a JSON body')

    -- The message goes into a JSON string, so anything that would break out of
    -- it has to be neutralised.
    local nasty = http.errorResponse(400, 'bad "quoted" \\ and\nnewline')
    t.ok(not nasty:match('\r\n\r\n.*\n'), 'an error message cannot inject a newline')
    t.ok(nasty:find('\r\n\r\n{"error":'), 'and the body is still well-formed JSON')

    ---------------------------------------------------------------------
    t.describe('it runs with no host at all')

    local file = io.open('masterserver/http.lua', 'r')
    t.ok(file ~= nil, 'the source is readable')
    if file then
        local source = file:read('*a')
        file:close()
        local code = require('tests.support.lua_source').stripNonCode(source)
        t.ok(not code:find('[^%w_]love[^%w_]'), 'http.lua does not name love')
        t.ok(not code:find("require%s*%(?%s*['\"]socket"), 'and does not require socket')
        t.ok(code:find('function http.clientAddress'), 'and the stripped source is real code')
    end
end
