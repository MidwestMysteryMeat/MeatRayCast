--[[
    The registry's JSON codec.

    Most of these are the ordinary cases. The ones worth reading are the
    empty-array ambiguity, which breaks precisely when nobody is hosting, and the
    malformed-input cases, because this parses bytes shaped by whoever felt like
    sending them.
]]

return function(t)
    local json = require('meatray.net.json')

    ---------------------------------------------------------------------
    t.describe('the empty table problem')

    -- One Lua type, two JSON types. An unmarked empty table is an object; a
    -- marked one is an array. This matters exactly when the server list is
    -- empty, which is the first thing a new player sees.
    t.eq(json.encode({}), '{}', 'an unmarked empty table is an object')
    t.eq(json.encode(json.array{}), '[]', 'a marked one is an array')
    t.eq(json.encode({ servers = json.array{} }), '{"servers":[]}',
         'so an empty server list is [] rather than {}')

    -- Non-empty is unambiguous and needs no marking.
    t.eq(json.encode({ 1, 2, 3 }), '[1,2,3]', 'a sequence is detected as an array')
    t.eq(json.encode({ a = 1 }), '{"a":1}', 'and a keyed table as an object')

    -- Decoding preserves the distinction, so a round trip does not collapse it.
    t.eq(json.encode(json.decode('[]')), '[]', 'an empty array survives a round trip')
    t.eq(json.encode(json.decode('{}')), '{}', 'and so does an empty object')

    ---------------------------------------------------------------------
    t.describe('scalars')

    t.eq(json.encode(true), 'true', 'true')
    t.eq(json.encode(false), 'false', 'false')
    t.eq(json.encode(json.null), 'null', 'null')

    -- `false` is the value most likely to be lost. The natural Lua idiom for
    -- "use a if set, else b" is `a ~= nil and a or b`, which yields b whenever a
    -- is false -- so false encodes as null, and null decodes to a table, and
    -- every table is truthy. A locked=false server would read back as locked.
    t.eq(json.encode({ locked = false }), '{"locked":false}',
         'a false value in an object stays false')
    t.eq(json.encode({ a = false, b = 0, c = '' }), '{"a":false,"b":0,"c":""}',
         'and so do the other values that are falsy or empty somewhere')
    t.eq(json.decode('{"locked":false}').locked, false, 'and survives decoding')
    t.eq(json.encode(42), '42', 'an integer has no decimal point')
    t.eq(json.encode(-7), '-7', 'negative')
    t.eq(json.encode(0.5), '0.5', 'a fraction')
    t.eq(json.encode('hi'), '"hi"', 'a string')

    t.eq(json.decode('42'), 42, 'decode integer')
    t.eq(json.decode('-0.25'), -0.25, 'decode negative fraction')
    t.eq(json.decode('true'), true, 'decode true')
    t.eq(json.decode('  "spaced"  '), 'spaced', 'leading and trailing space is fine')

    -- Values JSON cannot express are refused rather than emitted as garbage the
    -- receiving parser would reject anyway.
    t.eq(json.encode(0 / 0), nil, 'NaN cannot be encoded')
    t.eq(json.encode(math.huge), nil, 'nor infinity')
    t.eq(json.encode(print), nil, 'nor a function')

    ---------------------------------------------------------------------
    t.describe('strings survive the trip')

    local nasty = 'quote " backslash \\ newline \n tab \t control \1 end'
    local encoded = json.encode(nasty)
    t.ok(encoded ~= nil, 'a string full of control characters encodes')
    t.ok(not encoded:sub(2, -2):find('\n'), 'with no raw newline in the output')
    t.eq(json.decode(encoded), nasty, 'and decodes back to exactly the same bytes')

    t.eq(json.decode('"\\u0041"'), 'A', 'a \\u escape decodes')
    t.eq(json.decode('"\\u00e9"'), '\195\169', 'including two-byte UTF-8')
    t.eq(json.decode('"\\u20ac"'), '\226\130\172', 'and three-byte')

    ---------------------------------------------------------------------
    t.describe('malformed input is refused, not guessed at')

    -- This is the parser's real job: it reads whatever arrives on a socket.
    local bad = {
        { '{', 'an unterminated object' },
        { '[1,2', 'an unterminated array' },
        { '"no end', 'an unterminated string' },
        { '{"a":}', 'a missing value' },
        { '{"a" 1}', 'a missing colon' },
        { '{a:1}', 'an unquoted key' },
        { '[1,]', 'a trailing comma' },
        { '{"a":1,}', 'a trailing comma in an object' },
        { 'tru', 'a truncated literal' },
        { '"\\q"', 'a bad escape' },
        { '"\\u00zz"', 'a bad unicode escape' },
        { '', 'empty input' },
        { '   ', 'only whitespace' },
        { 'nonsense', 'a bare word' },
    }
    for _, case in ipairs(bad) do
        local value, err = json.decode(case[1])
        t.eq(value, nil, case[2] .. ' is refused')
        t.ok(type(err) == 'string' and #err > 0, 'with a message: ' .. case[2])
    end

    -- Trailing data is malformed. Accepting it lets two parsers disagree about
    -- what a request said, which is a class of bug that shows up as "the server
    -- read something different from what I sent".
    t.eq(json.decode('{} extra'), nil, 'trailing data is refused')
    t.eq(json.decode('1 2'), nil, 'and so are two values in a row')

    t.eq(json.decode(nil), nil, 'a non-string input is refused')
    t.eq(json.decode(42), nil, 'including a number')

    -- Deep nesting is bounded, so a small hostile payload cannot exhaust the
    -- stack. 200 opening brackets is a few hundred bytes.
    t.eq(json.decode(string.rep('[', 200) .. string.rep(']', 200)), nil,
         'deeply nested input is refused rather than overflowing')

    ---------------------------------------------------------------------
    t.describe('output is stable')

    -- Keys sorted, so the same value always produces the same bytes: responses
    -- stay cacheable, and a test can compare strings instead of re-parsing.
    local a = json.encode({ zebra = 1, apple = 2, mango = 3 })
    local b = json.encode({ mango = 3, apple = 2, zebra = 1 })
    t.eq(a, b, 'key order does not depend on table iteration order')
    t.eq(a, '{"apple":2,"mango":3,"zebra":1}', 'and is sorted')

    ---------------------------------------------------------------------
    t.describe('a realistic registry payload')

    local payload = {
        servers = json.array{
            { address = '198.51.100.7', port = 6789, name = 'Test',
              map = 'arena', players = 2, maxPlayers = 8,
              protocol = 2, locked = false, age = 0 },
        },
    }
    local text = json.encode(payload)
    t.ok(text ~= nil, 'a server list encodes')

    local back = json.decode(text)
    t.ok(back ~= nil, 'and decodes')
    t.eq(#back.servers, 1, 'with the list intact')
    t.eq(back.servers[1].address, '198.51.100.7', 'and the address')
    t.eq(back.servers[1].players, 2, 'and the player count')
    t.eq(back.servers[1].locked, false, 'and the boolean')

    ---------------------------------------------------------------------
    t.describe('it runs with no host at all')

    local file = io.open('meatray/net/json.lua', 'r')
    t.ok(file ~= nil, 'the source is readable')
    if file then
        local source = file:read('*a')
        file:close()
        local code = require('tests.support.lua_source').stripNonCode(source)
        t.ok(not code:find('[^%w_]love[^%w_]'), 'json.lua does not name love')
        t.ok(not code:find("require%s*%(?%s*['\"]socket"), 'and does not require socket')
        t.ok(code:find('function json.decode'), 'and the stripped source is still real code')
    end
end
