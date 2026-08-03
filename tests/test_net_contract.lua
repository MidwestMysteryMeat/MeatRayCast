--[[
    The protocol contract: direction, dispatch, and round-trip.

    The usual way to test this is to grep the source — regex the server for emit
    calls, regex the client for listeners, diff the two lists. It works, and it
    has two structural holes that show up the moment a codebase grows a helper.
    An emitter one indirection away from a literal call is invisible to a regex,
    so it lands in an allowlist of "false positives" that then hides real ones;
    and the check runs in one direction only, because the reverse would need a
    second set of patterns nobody writes.

    Neither hole exists here, and not because the regex is better: because there
    is no regex. `meatray.net.protocol` already holds the authoritative list of
    tags, and both sides now dispatch through a table keyed by tag. So this suite
    compares two data structures the program itself uses. A handler that is
    reached through six layers of indirection is still a key in a table; a tag
    that no longer travels the way the registry says fails immediately; and both
    directions are checked because both directions are recorded.

    What is asserted:

      * P.names and P.direction describe exactly the same set of tags.
      * P.shape documents every direction every tag legally travels — which is
        what caught CHAT being filed as client->host while the host broadcast it
        with a different payload.
      * Every c2s and both tag has a host handler; every s2c and both tag has a
        client handler; neither side handles a tag the registry does not list,
        and neither handles a tag that cannot travel towards it.
      * Every tag survives pack -> unpack unchanged, including the awkward
        bodies: empty, deeply nested, floats at full precision, strings full of
        the wire format's own punctuation, and payloads large enough to exercise
        the length fields.
      * A vacuity floor, so an empty or half-loaded registry cannot pass by
        having nothing to disagree about.

    HEADLESS: no sockets, no LOVE, no host, no client instance. This is a test
    about tables.
]]

return function(t)
    local P      = require('meatray.net.protocol')
    local Host   = require('meatray.net.host')
    local Client = require('meatray.net.client')

    local function count(tbl)
        local n = 0
        for _ in pairs(tbl) do n = n + 1 end
        return n
    end

    local function sorted(keys)
        local out = {}
        for k in pairs(keys) do out[#out + 1] = k end
        table.sort(out)
        return out
    end

    local function nameOf(kind)
        return P.names[kind] or ('unregistered tag %q'):format(tostring(kind))
    end

    -----------------------------------------------------------------------
    -- The vacuity floor.
    --
    -- Every assertion below is a loop over a registry, and a loop over an empty
    -- registry passes. That is the failure mode where a suite goes green because
    -- a require quietly returned a stub, and it is the one a "0 mismatches"
    -- result cannot distinguish from success. Floors first, and deliberately
    -- floors rather than exact counts: adding a message type should not fail
    -- this file, and losing one must.
    -----------------------------------------------------------------------
    t.describe('vacuity floor: there is actually something to check')

    local MIN_TAGS, MIN_HOST, MIN_CLIENT = 15, 7, 9

    local tags = P.tags()
    t.ok(#tags >= MIN_TAGS,
         ('the registry lists at least %d message types'):format(MIN_TAGS),
         ('found %d'):format(#tags))
    t.ok(count(Host.handlers) >= MIN_HOST,
         ('the host dispatches at least %d tags'):format(MIN_HOST),
         ('found %d'):format(count(Host.handlers)))
    t.ok(count(Client.handlers) >= MIN_CLIENT,
         ('the client dispatches at least %d tags'):format(MIN_CLIENT),
         ('found %d'):format(count(Client.handlers)))

    -----------------------------------------------------------------------
    t.describe('the registry describes itself consistently')

    for _, kind in ipairs(tags) do
        t.ok(P.direction[kind] ~= nil,
             ('%s has a direction'):format(nameOf(kind)))
    end

    -- And the reverse, which is the half that gets forgotten: a direction for a
    -- tag that no longer exists, or one added to direction and not to names.
    for kind in pairs(P.direction) do
        t.ok(P.names[kind] ~= nil,
             ('the direction table has no entry for an unnamed tag (%q)'):format(kind))
    end
    t.eq(count(P.direction), count(P.names),
         'P.names and P.direction cover exactly the same tags')

    for _, kind in ipairs(tags) do
        local d = P.direction[kind]
        t.ok(d == P.C2S or d == P.S2C or d == P.BOTH,
             ('%s has a direction the protocol recognises'):format(nameOf(kind)),
             tostring(d))
    end

    -----------------------------------------------------------------------
    -- The payload documentation, machine-checked.
    --
    -- This is the assertion that would have caught the real inconsistency this
    -- suite was written for. CHAT was documented under a "client -> host"
    -- heading as `{ text }`, while the host broadcast it and the client handled
    -- it, with `{ text, name }` coming back down. Both statements were true and
    -- the file only had room for one of them, because a comment heading cannot
    -- express "both, and they differ".
    -----------------------------------------------------------------------
    t.describe('every direction a tag travels is documented')

    for _, kind in ipairs(tags) do
        local shape = P.shape[kind]
        t.ok(type(shape) == 'table', ('%s has a documented payload'):format(nameOf(kind)))

        if type(shape) == 'table' then
            if P.travels(kind, P.C2S) then
                t.ok(type(shape.c2s) == 'string' and #shape.c2s > 0,
                     ('%s documents what a client sends'):format(nameOf(kind)))
            else
                t.ok(shape.c2s == nil,
                     ('%s does not document a direction it cannot travel (c2s)')
                     :format(nameOf(kind)))
            end

            if P.travels(kind, P.S2C) then
                t.ok(type(shape.s2c) == 'string' and #shape.s2c > 0,
                     ('%s documents what the host sends'):format(nameOf(kind)))
            else
                t.ok(shape.s2c == nil,
                     ('%s does not document a direction it cannot travel (s2c)')
                     :format(nameOf(kind)))
            end
        end
    end

    t.describe('chat is documented as the asymmetric tag it is')
    t.eq(P.direction[P.CHAT], P.BOTH, 'chat travels both ways')
    t.ok(P.shape[P.CHAT].c2s ~= P.shape[P.CHAT].s2c,
         'and its payload differs by direction, which is why the direction is recorded')
    t.ok(P.shape[P.CHAT].c2s:find('text') and not P.shape[P.CHAT].c2s:find('name'),
         'a client sends only the text')
    t.ok(P.shape[P.CHAT].s2c:find('text') and P.shape[P.CHAT].s2c:find('name'),
         'and the host attaches the name, because a client could name anyone')

    -----------------------------------------------------------------------
    -- Deliberately one-way tags.
    --
    -- MMOLite's pattern: an allowlist where every entry carries the reason it is
    -- legitimate, and a ratchet rather than an equality so that the list can
    -- only ever shrink. Empty today — every tag the registry points at a side is
    -- handled by that side — and the floor of zero is what keeps a future
    -- "temporarily unhandled" from becoming permanent.
    -----------------------------------------------------------------------
    t.describe('the unhandled allowlist, and its ratchet')

    local UNHANDLED_HOST   = {}   -- [tag] = 'why a host legitimately ignores it'
    local UNHANDLED_CLIENT = {}   -- [tag] = 'why a client legitimately ignores it'

    -- Never raise these. Lowering them is the only legal edit.
    local MAX_UNHANDLED_HOST, MAX_UNHANDLED_CLIENT = 0, 0

    t.ok(count(UNHANDLED_HOST) <= MAX_UNHANDLED_HOST,
         ('at most %d host tags are allowed to go unhandled'):format(MAX_UNHANDLED_HOST),
         ('allowlisted %d'):format(count(UNHANDLED_HOST)))
    t.ok(count(UNHANDLED_CLIENT) <= MAX_UNHANDLED_CLIENT,
         ('at most %d client tags are allowed to go unhandled'):format(MAX_UNHANDLED_CLIENT),
         ('allowlisted %d'):format(count(UNHANDLED_CLIENT)))

    -- A stale allowlist is worse than none: it silences a check for a tag that
    -- is now handled, and nothing would ever tell you.
    for kind, why in pairs(UNHANDLED_HOST) do
        t.ok(type(why) == 'string' and #why > 0,
             ('the host allowlist entry for %s carries a reason'):format(nameOf(kind)))
        t.ok(Host.handlers[kind] == nil,
             ('%s is allowlisted and genuinely unhandled by the host'):format(nameOf(kind)))
    end
    for kind, why in pairs(UNHANDLED_CLIENT) do
        t.ok(type(why) == 'string' and #why > 0,
             ('the client allowlist entry for %s carries a reason'):format(nameOf(kind)))
        t.ok(Client.handlers[kind] == nil,
             ('%s is allowlisted and genuinely unhandled by the client'):format(nameOf(kind)))
    end

    -----------------------------------------------------------------------
    t.describe('every tag the host must handle, the host handles')

    for _, kind in ipairs(tags) do
        if P.travels(kind, P.C2S) and not UNHANDLED_HOST[kind] then
            t.ok(Host.handlers[kind] ~= nil,
                 ('the host handles %s'):format(nameOf(kind)))
        end
    end

    t.describe('every tag the client must handle, the client handles')

    for _, kind in ipairs(tags) do
        if P.travels(kind, P.S2C) and not UNHANDLED_CLIENT[kind] then
            t.ok(Client.handlers[kind] ~= nil,
                 ('the client handles %s'):format(nameOf(kind)))
        end
    end

    -----------------------------------------------------------------------
    -- The reverse direction, which the source-grep version of this test never
    -- had: a handler with nothing behind it. Either the tag was removed from the
    -- protocol and the handler was left, or the handler is for traffic that
    -- cannot legally arrive on that side — a host with a SNAPSHOT handler is a
    -- host that will act on a client claiming to be the server.
    -----------------------------------------------------------------------
    t.describe('no handler exists for a tag the registry does not list')

    for _, kind in ipairs(sorted(Host.handlers)) do
        t.ok(P.names[kind] ~= nil,
             ('the host handler %q corresponds to a registered tag'):format(kind))
        t.ok(P.travels(kind, P.C2S),
             ('the host only handles traffic that travels towards it (%s)')
             :format(nameOf(kind)))
    end

    for _, kind in ipairs(sorted(Client.handlers)) do
        t.ok(P.names[kind] ~= nil,
             ('the client handler %q corresponds to a registered tag'):format(kind))
        t.ok(P.travels(kind, P.S2C),
             ('the client only handles traffic that travels towards it (%s)')
             :format(nameOf(kind)))
    end

    t.describe('every handler is callable')
    for _, kind in ipairs(sorted(Host.handlers)) do
        t.eq(type(Host.handlers[kind]), 'function',
             ('the host handler for %s is a function'):format(nameOf(kind)))
    end
    for _, kind in ipairs(sorted(Client.handlers)) do
        t.eq(type(Client.handlers[kind]), 'function',
             ('the client handler for %s is a function'):format(nameOf(kind)))
    end

    -----------------------------------------------------------------------
    -- Round trip.
    --
    -- Neither of the projects this suite was modelled on has this at all: they
    -- check that a message type is handled somewhere and never that the body
    -- arrives intact. A tag that dispatches correctly and delivers a mangled
    -- payload is a worse bug than one that dispatches nowhere, because the first
    -- one looks like it works.
    -----------------------------------------------------------------------

    local function deepEqual(a, b, path)
        path = path or ''
        if type(a) ~= type(b) then
            return false, ('%s: %s vs %s'):format(path, type(a), type(b))
        end
        if type(a) ~= 'table' then
            if a ~= b then
                return false, ('%s: %s vs %s'):format(path, tostring(a), tostring(b))
            end
            return true
        end
        for k, v in pairs(a) do
            local ok, why = deepEqual(v, b[k], path .. '.' .. tostring(k))
            if not ok then return false, why end
        end
        for k in pairs(b) do
            if a[k] == nil then
                return false, ('%s.%s: appeared out of nowhere'):format(path, tostring(k))
            end
        end
        return true
    end

    -- Sanity on the comparator itself, because a deep-equal that returns true
    -- for everything would make every assertion below vacuous.
    t.ok(deepEqual({ a = { 1, 2 } }, { a = { 1, 2 } }), 'deepEqual accepts equal tables')
    t.ok(not deepEqual({ a = { 1, 2 } }, { a = { 1, 3 } }), 'and rejects unequal ones')
    t.ok(not deepEqual({ a = 1 }, { a = 1, b = 2 }), 'and rejects an extra field')
    t.ok(not deepEqual({ a = 1, b = 2 }, { a = 1 }), 'and a missing one')

    local SAMPLES = {
        [P.JOIN] = { version = 1, name = 'ada', password = 'hunter2',
                     credentials = { token = 'eyJhbGc', expires = 1893456000 } },
        [P.INPUT] = { seq = 4096, forward = 0.70710678118654746, strafe = -1,
                      turn = 0, angle = 3.141592653589793 },
        [P.COMMAND] = { name = 'fire',
                        body = { angle = -2.5, tx = 12, ty = 9, tags = { 'a', 'b' } } },
        [P.CHAT] = { text = 'hello, "world"', name = 'ada' },
        [P.STATS] = {},
        [P.PING] = { time = 1234.5678 },
        [P.LEAVE] = {},

        [P.ACCEPT] = { peerId = 3, entityId = 42, name = 'MeatRayCast listen',
                       map = 'arena', mode = 'listen', tickRate = 60,
                       snapshotRate = 20, moveSpeed = 3.2, turnSpeed = 2.6,
                       idBase = 1000000,
                       world = { kind = 'grid', theme = 'brick',
                                 grid = { { 1, 1, 1 }, { 1, 0, 1 }, { 1, 1, 1 } },
                                 doors = { { '2,2', 1 } },
                                 spawn = { x = 1.5, y = 1.5, angle = 0 } } },
        [P.REJECT] = { reason = 'wrong password',
                       detail = 'server speaks protocol 1, client speaks 2' },
        [P.SNAPSHOT] = { tick = 987654,
                         e = { { id = 1, kind = 'player', x = 1.5, y = 2.25,
                                 angle = 0.75, health = { hp = 88 } },
                               { id = 2, kind = 'grunt', x = 9.125, y = 4.0625,
                                 angle = -1.25 } } },
        [P.WORLD] = { doors = { ['3,4'] = 1, ['5,6'] = 0 } },
        [P.EVENT] = { name = 'hitscan',
                      body = { result = 'hit', target = 7, x = 1.5, y = 2.5 } },
        [P.REPLY] = { players = 2, peers = 2, entities = 14, doorsOpen = 1,
                      tick = 900, snapshotsSent = 300, worldSyncs = 2,
                      mode = 'dedicated', map = 'arena', name = 'srv' },
        [P.KICK] = { reason = 'kicked' },
        [P.PONG] = { time = 0 },
        [P.RESPAWN] = { entityId = 1048577 },
        [P.RCON] = { ok = true, reply = 'authenticated' },
        [P.VOTE] = { call = 'restart' },
        -- B14: a full-world resync, the same worldPayload shape ACCEPT carries,
        -- plus the peer's new entity id.
        [P.MAPCHANGE] = { entityId = 88, map = 'arena2',
                          world = { kind = 'grid', theme = 'brick',
                                    grid = { { 1, 1, 1 }, { 1, 0, 1 }, { 1, 1, 1 } },
                                    doors = { { '2,2', 1 } },
                                    spawn = { x = 1.5, y = 1.5, angle = 0 } } },
    }

    t.describe('every tag has a representative body')
    for _, kind in ipairs(tags) do
        t.ok(SAMPLES[kind] ~= nil,
             ('%s has a sample body, so adding a tag forces one'):format(nameOf(kind)))
    end

    -- A schema that rejects legitimate traffic is the failure mode of adding
    -- validation, and it is silent: the packets simply stop arriving.
    t.describe('the schema accepts every representative body')
    for _, kind in ipairs(tags) do
        local ok, why = P.check(kind, SAMPLES[kind])
        t.ok(ok, ('a real %s passes validation'):format(nameOf(kind)), why)
    end

    t.describe('pack -> unpack returns the same tag and an identical body')
    for _, kind in ipairs(tags) do
        local sample = SAMPLES[kind]
        local packet = P.pack(kind, sample)
        local gotKind, gotBody, why = P.unpack(packet)

        t.eq(gotKind, kind, ('%s comes back as itself'):format(nameOf(kind)), why)
        if gotKind then
            local same, detail = deepEqual(sample, gotBody, nameOf(kind))
            t.ok(same, ('%s round-trips unchanged'):format(nameOf(kind)), detail)
        end
    end

    -----------------------------------------------------------------------
    t.describe('the awkward bodies, against every tag')

    -- Applied to every tag rather than to one, because the envelope is shared
    -- and a length bug in it is a bug in all fifteen.
    local EDGE = {
        { 'an empty body', {} },

        { 'nesting', { a = { b = { c = { d = { 1, 2, 3, { deep = true } } } } } } },

        -- %.17g is the shortest form that reads back as the identical double.
        -- A position that lost a bit per hop would drift invisibly for a while
        -- and then stop matching the host, which reads as a prediction bug.
        { 'floats at full precision', {
            third = 1 / 3, pi = math.pi, e = math.exp(1),
            tiny = 1e-300, huge = 1e300, neg = -0.1,
            big = 2 ^ 53 - 1, denormal = 5e-324,
            zero = 0, negzero = -0.0,
        } },

        -- The wire format is self-delimiting: strings carry a length, so there is
        -- no escaping and therefore no escaping bug. This is what proves it.
        { 'strings full of the format\'s own punctuation', {
            tags   = '$5:{}[]#;-+/',
            lines  = 'first\nsecond\r\nthird',
            quotes = 'he said "hi" and \'bye\'',
            nul    = 'before\0after',
            backsl = 'C:\\Users\\jonat\\path',
            eight  = '\xc3\xa9\xe2\x80\x94\xff\xfe',
            empty  = '',
        } },

        -- Keys are values too, so punctuation in a key has to survive the same
        -- way a value does.
        { 'awkward keys', {
            ['a:b'] = 1, ['{'] = 2, [']'] = 3, ['1'] = 'string one',
            [1] = 'number one', ['with space'] = true, [''] = 'empty key',
        } },

        { 'mixed arrays and maps', {
            array = { 1, 2, 3, 4, 5 },
            holed = { [1] = 'a', [3] = 'c' },
            empty = {},
            bools = { true, false, true },
        } },
    }

    for _, case in ipairs(EDGE) do
        local label, body = case[1], case[2]
        for _, kind in ipairs(tags) do
            local gotKind, gotBody, why = P.unpack(P.pack(kind, body))
            t.eq(gotKind, kind, ('%s survives %s'):format(nameOf(kind), label), why)
            if gotKind then
                local same, detail = deepEqual(body, gotBody, label)
                t.ok(same, ('%s: %s round-trips unchanged'):format(nameOf(kind), label),
                     detail)
            end
        end
    end

    -----------------------------------------------------------------------
    t.describe('bodies large enough to exercise the length fields')

    local bigString = string.rep('meatray ', 8192)          -- 64 KiB
    local bigArray = {}
    for i = 1, 5000 do bigArray[i] = i * 0.5 end
    local wideMap = {}
    for i = 1, 2000 do wideMap[('key%04d'):format(i)] = i end

    local BIG = {
        { 'a 64 KiB string', { text = bigString } },
        { 'a 5000-element array', { grid = bigArray } },
        { 'a 2000-key map', { doors = wideMap } },
    }

    for _, case in ipairs(BIG) do
        local label, body = case[1], case[2]
        local packet = P.pack(P.SNAPSHOT, body)
        t.ok(#packet > 20000, ('%s really is large (%d bytes)'):format(label, #packet))

        local gotKind, gotBody, why = P.unpack(packet)
        t.eq(gotKind, P.SNAPSHOT, ('%s decodes'):format(label), why)
        if gotKind then
            local same, detail = deepEqual(body, gotBody, label)
            t.ok(same, ('%s round-trips unchanged'):format(label), detail)
        end
    end

    -----------------------------------------------------------------------
    t.describe('the envelope refuses what it should')

    local _, _, emptyWhy = P.unpack('')
    t.ok(emptyWhy ~= nil, 'an empty packet is refused with a reason')

    local _, _, unknownWhy = P.unpack('Z' .. 'garbage')
    t.ok(unknownWhy and unknownWhy:find('unknown'),
         'an unregistered tag is refused as unknown, not as a bad body')

    local _, _, truncWhy = P.unpack(P.pack(P.SNAPSHOT, SAMPLES[P.SNAPSHOT]):sub(1, 30))
    t.ok(truncWhy ~= nil, 'a truncated packet is refused with a reason')

    -- Not an error return, which is the point: a malformed packet on a public
    -- port is an expected event and must never raise into the service loop.
    local didRaise = not pcall(P.unpack, '{' .. string.rep('[1:', 200))
    t.ok(not didRaise, 'and a hostile packet returns a reason rather than raising')

    -- The per-tag ceilings the host applies. Passing no limits leaves only the
    -- global ceiling, which is why the same packet is accepted above.
    t.describe('per-tag size limits')
    for _, kind in ipairs(tags) do
        if P.travels(kind, P.C2S) then
            t.ok(P.limits[kind] ~= nil,
                 ('%s has a size limit, since it arrives from an untrusted peer')
                 :format(nameOf(kind)))
        end
    end

    local fatChat = P.pack(P.CHAT, { text = string.rep('x', 5000) })
    t.ok(P.unpack(fatChat) ~= nil, 'an oversized chat decodes with no limits given')
    local overKind, _, overWhy = P.unpack(fatChat, P.limits)
    t.ok(overKind == nil, 'and is refused when the host limits are applied')
    t.ok(overWhy and overWhy:find('limit'), 'with a reason that names the limit', overWhy)

    -- Every representative body must fit inside its own limit, or the limits are
    -- set below real traffic and the first symptom is players unable to join.
    for _, kind in ipairs(tags) do
        if P.limits[kind] then
            local packet = P.pack(kind, SAMPLES[kind])
            t.ok(#packet <= P.limits[kind],
                 ('a real %s (%d bytes) fits inside its %d byte limit')
                 :format(nameOf(kind), #packet, P.limits[kind]))
        end
    end

    t.describe('the global ceiling')
    t.ok(P.MAX_PACKET > 64 * 1024,
         'the ceiling is above the largest legitimate payload, a grid world join')
    local beyond = P.pack(P.SNAPSHOT, { text = string.rep('x', P.MAX_PACKET + 1) })
    local _, _, ceilingWhy = P.unpack(beyond)
    t.ok(ceilingWhy and ceilingWhy:find('ceiling'),
         'and anything past it is refused before a byte is decoded', ceilingWhy)
end
