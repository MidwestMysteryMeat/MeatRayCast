--[[
    The wire format, and the packet envelope built on it.

    Every message on every transport goes through this code, so a bug here is a
    bug in all of networking at once. The assertions worth having are about the
    properties, not the bytes: exact round-trip, self-delimiting strings, and a
    flat refusal to decode garbage rather than an interesting guess at what it
    might have meant.
]]

return function(t)
    local S = require('meatray.net.serialize')
    local P = require('meatray.net.protocol')

    local function round(value, label)
        local encoded = S.encode(value)
        local decoded, err = S.decode(encoded)
        t.ok(decoded ~= nil or value == nil, (label or 'round trip') .. ' decodes', err)
        return decoded, encoded
    end

    t.describe('scalars round-trip exactly')
    t.eq(round(true, 'true'), true, 'true survives')
    t.eq(round(false, 'false'), false, 'false survives')
    t.eq(round(0, 'zero'), 0, 'zero survives')
    t.eq(round(-1, 'negative'), -1, 'a negative integer survives')
    t.eq(round(1234567, 'big int'), 1234567, 'a large integer survives')
    t.eq(round('', 'empty string'), '', 'an empty string survives')
    t.eq(round('hello', 'string'), 'hello', 'a string survives')

    -- The reason %.17g and not %g: a position written with fewer digits comes
    -- back as a slightly different double, and a client that re-sends it drifts
    -- a little further every hop.
    t.describe('floats survive without drifting')
    local awkward = { 0.1, 1 / 3, 2 ^ -30, -12.345678901234567, 1e300, 1e-300 }
    for _, v in ipairs(awkward) do
        t.eq(round(v, 'float'), v, ('%.17g round-trips bit-exactly'):format(v))
    end

    t.describe('non-finite numbers are named, not emitted raw')
    -- tonumber('inf') is nil in LuaJIT, so writing %.17g's own output for
    -- infinity would decode to nil: a coordinate that quietly vanished.
    t.eq(round(math.huge, 'inf'), math.huge, 'infinity survives')
    t.eq(round(-math.huge, '-inf'), -math.huge, 'negative infinity survives')
    local nan = S.decode(S.encode(0 / 0))
    t.ok(nan ~= nan, 'NaN survives as NaN')

    t.describe('strings are length-prefixed, so no byte needs escaping')
    for _, hostile in ipairs({
        'has:colons', 'has;semis', 'has{braces}', 'has[brackets]', '$5:fake',
        'new\nline', 'tab\tted', 'nul\0byte', '#42;',
    }) do
        t.eq(round(hostile, 'hostile string'), hostile,
             ('%q survives verbatim'):format(hostile:gsub('%c', '?')))
    end

    t.describe('tables')
    local map = round({ a = 1, b = 'two', c = { d = true } }, 'map')
    t.eq(map.a, 1, 'nested map: number')
    t.eq(map.b, 'two', 'nested map: string')
    t.eq(map.c.d, true, 'nested map: nested boolean')

    local array = round({ 10, 20, 30 }, 'array')
    t.eq(#array, 3, 'array keeps its length')
    t.eq(array[2], 20, 'array keeps its order')

    -- The array short form exists to keep a world grid affordable: a 44x44 grid
    -- is 1936 tiles, and paying an explicit key per tile roughly quadruples it.
    local grid = {}
    for y = 1, 44 do
        grid[y] = {}
        for x = 1, 44 do grid[y][x] = (x + y) % 10 end
    end
    local encodedGrid = S.encode(grid)
    local decodedGrid = S.decode(encodedGrid)
    t.eq(decodedGrid[7][13], grid[7][13], 'a 44x44 grid round-trips')
    t.ok(#encodedGrid < 12000, ('a 44x44 grid encodes small (%d bytes)'):format(#encodedGrid))

    t.describe('mixed and sparse tables keep their keys')
    local mixed = round({ 1, 2, name = 'x' }, 'mixed')
    t.eq(mixed[1], 1, 'mixed table keeps its array part')
    t.eq(mixed.name, 'x', 'mixed table keeps its named part')

    local sparse = round({ [1] = 'a', [3] = 'c' }, 'sparse')
    t.eq(sparse[1], 'a', 'sparse table keeps index 1')
    t.eq(sparse[3], 'c', 'sparse table keeps index 3')
    t.eq(sparse[2], nil, 'sparse table does not invent index 2')

    t.describe('non-string keys survive')
    local keyed = round({ [1] = 'one', [2.5] = 'two and a half', ['1'] = 'string one' },
                        'keyed')
    t.eq(keyed[1], 'one', 'a number key stays a number key')
    t.eq(keyed['1'], 'string one', 'a string key that looks numeric stays a string key')
    t.eq(keyed[2.5], 'two and a half', 'a fractional key survives')

    t.describe('what it refuses')
    local ok = pcall(S.encode, { f = function() end })
    t.ok(not ok, 'a function raises rather than encoding to nothing')

    local cycle = {}
    cycle.self = cycle
    local cyclic = pcall(S.encode, cycle)
    t.ok(not cyclic, 'a cycle raises rather than recursing forever')

    local tried, err = S.tryEncode({ f = print })
    t.ok(tried == nil and err ~= nil, 'tryEncode reports instead of raising')

    t.describe('malformed input returns a reason, never raises')
    for _, junk in ipairs({
        '', 'zzz', '#notanumber;', '#12', '$99:short', '{$1:a', '[3:#1;]',
        '$', '[', '{', '#;',
    }) do
        local value, reason = S.decode(junk)
        t.ok(value == nil and reason ~= nil,
             ('%q is rejected with a reason'):format(junk))
    end

    local trailing = S.decode(S.encode(1) .. 'junk')
    t.ok(trailing == nil, 'trailing bytes are rejected rather than ignored')

    t.ok(S.decode(nil) == nil, 'a nil input is rejected')
    t.ok(S.decode(42) == nil, 'a non-string input is rejected')

    ---------------------------------------------------------------------
    t.describe('the packet envelope')
    local packet = P.pack(P.SNAPSHOT, { tick = 9, e = {} })
    t.eq(packet:sub(1, 1), P.SNAPSHOT, 'the type is the first byte')
    t.ok(#P.SNAPSHOT == 1, 'a type tag is one byte, not a word')

    local kind, body = P.unpack(packet)
    t.eq(kind, P.SNAPSHOT, 'unpack recovers the type')
    t.eq(body.tick, 9, 'unpack recovers the body')

    local badKind, _, reason = P.unpack('Zwhatever')
    t.ok(badKind == nil and reason ~= nil, 'an unknown type is refused with a reason')

    local badBody, _, bodyReason = P.unpack(P.SNAPSHOT .. 'not-serialised')
    t.ok(badBody == nil and bodyReason ~= nil, 'a malformed body is refused with a reason')

    t.ok(P.unpack('') == nil, 'an empty packet is refused')
    t.ok(P.unpack(nil) == nil, 'a nil packet is refused')

    t.describe('channel assignment is deliberate')
    t.ok(P.CH_RELIABLE ~= P.CH_STREAM, 'reliable and stream are different channels')
    t.eq(P.CHANNELS, 2, 'two channels are opened')

    -- Every type has a name, because an unnamed type is a type that shows up in
    -- a log as a punctuation mark.
    local named = 0
    for _ in pairs(P.names) do named = named + 1 end
    t.ok(named >= 15, ('every message type is named (%d)'):format(named))
end
