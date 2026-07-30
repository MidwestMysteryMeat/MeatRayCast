--[[
    The master-server discovery backend, in the parts that need no socket.

    The constructors own a UDP socket and cannot run here, but two things that
    carry real logic are pure and worth pinning: URL parsing, and the mapping
    from a registry's reply to server-list entries. The second one is where a
    hostile or broken registry gets to hand the game a table full of surprises.

    End-to-end behaviour -- announce, answer the UDP challenge, appear in the
    list -- was verified against a running registry rather than mocked, because
    the bug that mattered there (a truncated multiple-return binding the
    challenge socket to port 0) is invisible to a test that has no socket.
]]

return function(t)
    local Master = require('meatray.net.discovery.master')

    ---------------------------------------------------------------------
    t.describe('registry URLs')

    local function parsed(url)
        local host, port, path = Master.parseUrl(url)
        return { host = host, port = port, path = path }
    end

    local p = parsed('http://example.com:8080/v1')
    t.eq(p.host, 'example.com', 'host')
    t.eq(p.port, 8080, 'port')
    t.eq(p.path, '/v1', 'path')

    t.eq(parsed('http://example.com').port, 80, 'the default port is 80')
    t.eq(parsed('http://example.com').path, '/', 'and the default path is /')
    t.eq(parsed('example.com:9000').host, 'example.com', 'the scheme may be omitted')
    t.eq(parsed('https://example.com').port, 80,
         'https parses, though the transport is plain HTTP -- TLS needs a proxy')
    t.eq(parsed('http://127.0.0.1:8080/').host, '127.0.0.1', 'an IP address is a host')

    t.eq(Master.parseUrl(''), nil, 'an empty URL is refused')
    t.eq(Master.parseUrl('http://'), nil, 'and a URL with no host')
    t.eq(Master.parseUrl('http:///path'), nil, 'and one with an empty host')

    ---------------------------------------------------------------------
    t.describe('what a registry says becomes a server list')

    -- A browser built by hand, since the real constructor wants a socket.
    local function browser()
        return setmetatable({
            registries = { 'http://a', 'http://b' },
            which = 1, found = {}, clock = 100,
        }, Master.Browser)
    end

    local function replyOf(body, status)
        return { state = 'done', status = status or 200, body = body }
    end

    local b = browser()
    b:handleResponse(replyOf([[{"servers":[
        {"address":"198.51.100.7","port":6789,"name":"Alpha","map":"arena",
         "players":2,"maxPlayers":8,"protocol":2,"locked":false,"portVerified":true}
    ]}]]))

    local rows = b:servers()
    t.eq(#rows, 1, 'one server')
    t.eq(rows[1].address, '198.51.100.7:6789',
         'address and port are joined into what join() actually takes')
    t.eq(rows[1].name, 'Alpha', 'the name comes through')
    t.eq(rows[1].max, 8, 'maxPlayers becomes max, the field a browser UI reads')
    t.eq(rows[1].source, 'master', 'and the source names the backend that found it')
    t.eq(b:error(), nil, 'no error is recorded')

    -- portVerified defaults to true when absent, so a registry that predates the
    -- field is not treated as reporting every server unverified. Explicit false
    -- is honoured.
    t.eq(rows[1].portVerified, true, 'an explicitly verified port stays verified')

    local unver = browser()
    unver:handleResponse(replyOf(
        '{"servers":[{"address":"1.2.3.4","port":1,"portVerified":false}]}'))
    t.eq(unver:servers()[1].portVerified, false, 'and an unverified one is passed through')

    local old = browser()
    old:handleResponse(replyOf('{"servers":[{"address":"1.2.3.4","port":1}]}'))
    t.eq(old:servers()[1].portVerified, true, 'an absent field defaults to verified')

    ---------------------------------------------------------------------
    t.describe('a broken registry does not break the game')

    -- Every one of these must leave the browser usable and record a reason. An
    -- empty list with no explanation is the most common way self-hosting
    -- silently defeats people.
    local junk = {
        { replyOf('not json at all'), 'a non-JSON body' },
        { replyOf('{"servers":"nope"}'), 'servers that is not a list' },
        { replyOf('{}'), 'a reply with no servers key' },
        { replyOf('[]'), 'a bare array' },
        { replyOf('{"servers":[]}', 500), 'a 500 with a valid body' },
        { { state = 'failed', error = 'connection refused' }, 'a failed request' },
    }
    for _, case in ipairs(junk) do
        local br = browser()
        local ok = pcall(br.handleResponse, br, case[1])
        t.eq(ok, true, case[2] .. ' does not raise')
        t.ok(br:error() ~= nil, 'and records why: ' .. case[2])
    end

    -- A 500 rotates to the other registry, because shipping two URLs is
    -- pointless if a failure never moves off the first.
    local rot = browser()
    t.eq(rot.which, 1, 'starts on the first registry')
    rot:handleResponse(replyOf('{"servers":[]}', 500))
    t.eq(rot.which, 2, 'a server error moves to the second')

    -- Entries missing the one field join actually needs are dropped rather than
    -- turned into a row that cannot be clicked.
    local partial = browser()
    partial:handleResponse(replyOf([[{"servers":[
        {"name":"no address"},
        {"address":"1.2.3.4"},
        {"address":"5.6.7.8","port":6789,"name":"good"}
    ]}]]))
    t.eq(#partial:servers(), 1, 'rows without an address and port are dropped')
    t.eq(partial:servers()[1].name, 'good', 'and the usable one survives')

    -- An empty list is a valid answer, not a failure: it means nobody is
    -- hosting, which must be distinguishable from the registry being down.
    local none = browser()
    none:handleResponse(replyOf('{"servers":[]}'))
    t.eq(#none:servers(), 0, 'an empty list is empty')
    t.eq(none:error(), nil, 'and is not an error -- nobody hosting is not a fault')

    ---------------------------------------------------------------------
    t.describe('it is registered as a real backend now')

    local Discovery = require('meatray.net.discovery')
    t.ok(Discovery.builtin.master ~= nil, 'master is a builtin backend')
    t.eq(Discovery.planned.master, nil, 'and is no longer listed as planned')

    ---------------------------------------------------------------------
    t.describe('it loads with no host at all')

    local file = io.open('meatray/net/discovery/master.lua', 'r')
    t.ok(file ~= nil, 'the source is readable')
    if file then
        local source = file:read('*a')
        file:close()
        local code = require('tests.support.lua_source').stripNonCode(source)
        t.ok(not code:find('[^%w_]love[^%w_]'), 'master.lua does not name love')
        -- require('socket') must be inside a constructor, not at file scope, or
        -- the whole net layer stops loading under plain LuaJIT.
        t.ok(not code:find("^local%s+socket%s*=%s*require"), 'and does not require socket at load time')
        t.ok(code:find('function Master.beacon'), 'and the stripped source is real code')
    end
end
