--[[
    The binary snapshot codec, and the one number in this file that matters.

    A snapshot larger than one MTU is not merely a large snapshot. ENet chooses
    the delivery mode for a fragmented packet by testing the flags against
    UNRELIABLE_FRAGMENT, our unreliable send passes flags 0, and that test is
    false for 0 — so the fragment path falls through to reliable, acknowledged,
    retransmitted, head-of-line-blocked delivery. lua-enet exposes no string that
    reaches UNRELIABLE_FRAGMENT, so the flag cannot be corrected from Lua and the
    only lever is the size.

    Which makes `a realistic snapshot fits in one datagram` a correctness test
    wearing a performance test's clothes, and the reason it is asserted here
    rather than described in a comment: a comment cannot fail when someone adds
    four fields to a netFields declaration.
]]

local Entity = require('meatray.sim.entity')
local C      = require('meatray.sim.components')
local Rep    = require('meatray.net.replication')
local P      = require('meatray.net.protocol')
local Codec  = require('meatray.net.snapcodec')

---------------------------------------------------------------------------
-- The scene the size assertions are made against
---------------------------------------------------------------------------

--[[
    ENTITY COUNT THIS SUITE ASSUMES: 32.

    Eight players and twenty-four grunts, which is the shape of a full server on
    a deathmatch map: every player carries billboard, health, player and weapon
    (four components, six replicated fields between them), and every grunt
    carries billboard and health (two components, three fields).

    Coordinates are deliberately irrational-looking. Round ones like 1.5 and 2.25
    flatter the text serializer by about 25%, because "%.17g" of 1.5 is three
    characters and of 12.870000000000001 is eighteen — and a running game
    produces the second kind, not the first.
]]
local PLAYERS, GRUNTS = 8, 24
local ENTITY_COUNT = PLAYERS + GRUNTS

local function scene(players, grunts)
    Entity.resetIds(1)
    local list = {}

    for i = 1, players do
        local e = Entity.new{ kind = 'player',
                              x = 12.5 + i * 0.37, y = 9.25 + i * 0.11,
                              angle = 0.5 + i * 0.13 }
        e:add(C.Billboard{ sheet = 'marine' })
        e:add(C.Health{ hp = 88 - i, max = 100 })
        e:add(C.Player{ peerId = i, name = ('player %d'):format(i) })
        e:add(C.Weapon{ ammo = 42 - i })
        list[#list + 1] = e
    end

    for i = 1, grunts do
        local e = Entity.new{ kind = 'grunt',
                              x = 3.5 + i * 0.91, y = 21.75 + i * 0.23,
                              angle = 1.25 + i * 0.07 }
        e:add(C.Billboard{ sheet = 'grunt' })
        e:add(C.Health{ hp = 30, max = 30 })
        list[#list + 1] = e
    end

    return list
end

local function snapshotOf(entities, tick)
    return { tick = tick or 987654, e = Rep.entitySnapshots(entities) }
end

local function deepEqual(a, b, path)
    path = path or 'value'
    if type(a) ~= type(b) then
        return false, ('%s: %s vs %s'):format(path, type(a), type(b))
    end
    if type(a) ~= 'table' then
        if a ~= b and not (a ~= a and b ~= b) then      -- NaN equals NaN here
            return false, ('%s: %s vs %s'):format(path, tostring(a), tostring(b))
        end
        return true
    end
    for k, v in pairs(a) do
        local ok, why = deepEqual(v, b[k], path .. '.' .. tostring(k))
        if not ok then return false, why end
    end
    for k in pairs(b) do
        if a[k] == nil then return false, ('%s.%s only on one side'):format(path, tostring(k)) end
    end
    return true
end

---------------------------------------------------------------------------

return function(t)
    -----------------------------------------------------------------------
    t.describe('a full snapshot stays inside one datagram')

    local entities = scene(PLAYERS, GRUNTS)
    local snapshot = snapshotOf(entities)

    local packet = P.packSnapshot(snapshot)
    local textPacket = P.pack(P.SNAPSHOT, snapshot)

    t.eq(#entities, ENTITY_COUNT, 'the scene really is the documented size')

    -- THE regression test. Everything else in this file exists to make this one
    -- meaningful; this one is what stops the bug coming back.
    t.ok(#packet < P.MTU_SAFE_BYTES,
         ('a %d-entity snapshot is %d bytes, under the %d-byte ENet fragment '
          .. 'threshold'):format(ENTITY_COUNT, #packet, P.MTU_SAFE_BYTES),
         ('%d bytes over; past this line ENet delivers snapshots reliably, which '
          .. 'is the bug this codec exists to fix')
         :format(#packet - P.MTU_SAFE_BYTES))

    -- And the reason it needed fixing, asserted rather than remembered. If this
    -- ever passes, the text serializer got small enough that the whole codec is
    -- arguably unnecessary — which would be worth knowing.
    t.ok(#textPacket > P.MTU_SAFE_BYTES,
         ('the same snapshot through the text serializer is %d bytes, which does '
          .. 'fragment'):format(#textPacket))

    -- The other MTU that matters. ENet negotiates the *minimum* of the two peers,
    -- so a peer that came up at 576 imposes a budget near 548 on everyone talking
    -- to it. Twelve entities is what measurably fits there (sixteen is 634 bytes
    -- and does not), so that is what is asserted — the small-MTU ceiling is real
    -- and it is roughly a third of the default one.
    local smallMtuPacket = P.packSnapshot(snapshotOf(scene(3, 9)))
    t.ok(#smallMtuPacket < 548,
         ('a 12-entity snapshot is %d bytes, inside the 548-byte budget a peer at '
          .. 'a 576 MTU would impose'):format(#smallMtuPacket))
    t.ok(#P.pack(P.SNAPSHOT, snapshotOf(scene(3, 9))) > 548,
         'where the text serializer needed 2112 bytes for the same twelve')

    t.describe('and the saving is where the doc says it is')

    local perEntityText   = (#textPacket - 1) / ENTITY_COUNT
    local perEntityBinary = (#packet - 1) / ENTITY_COUNT

    t.ok(perEntityBinary < perEntityText / 3,
         ('%.1f bytes per entity, down from %.1f')
         :format(perEntityBinary, perEntityText))

    -----------------------------------------------------------------------
    t.describe('a snapshot round-trips through the envelope')

    local kind, body = P.unpack(packet)
    t.eq(kind, P.SNAPSHOT, 'the tag survives')
    t.ok(body ~= nil, 'the body decodes')

    if body then
        t.eq(body.tick, 987654, 'the tick is exact, not quantised')
        t.eq(#body.e, ENTITY_COUNT, 'every entity arrives')

        -- The transform is the only quantised thing in the format, so it is the
        -- only thing compared with a tolerance. binary32 keeps 24 significant
        -- bits, so the bound is relative: |v| * 2^-24, with a floor for values
        -- near zero.
        local function within(got, want, label)
            local bound = math.abs(want) * 2 ^ -24 + 1e-30
            t.ok(math.abs(got - want) <= bound, label,
                 ('got %.17g, wanted %.17g, bound %.3g'):format(got, want, bound))
        end

        local byId = {}
        for i = 1, #body.e do byId[body.e[i].id] = body.e[i] end

        local checkedFields = 0
        for i = 1, #entities do
            local e = entities[i]
            local got = byId[e.id]
            if not got then
                t.ok(false, ('entity %d arrived'):format(e.id))
            else
                t.eq(got.kind, e.kind, ('entity %d keeps its kind'):format(e.id))
                within(got.x, e.x, ('entity %d x is within the binary32 bound'):format(e.id))
                within(got.y, e.y, ('entity %d y is within the binary32 bound'):format(e.id))
                -- Angles are int32 fixed-point at ANGLE_SCALE, so the step is
                -- absolute rather than relative. Half a tick is the worst error.
                local angleBound = 0.5 / Codec.ANGLE_SCALE + 1e-15
                t.ok(math.abs(got.angle - e.angle) <= angleBound,
                     ('entity %d angle is within one fixed-point step'):format(e.id),
                     ('got %.17g, wanted %.17g, bound %.3g')
                        :format(got.angle, e.angle, angleBound))

                -- Component fields are NOT quantised; they must come back bit
                -- for bit. An ammo count that drifted would be a worse bug than
                -- any amount of bandwidth.
                for name, fields in pairs(e:snapshot().c or {}) do
                    for key, value in pairs(fields) do
                        checkedFields = checkedFields + 1
                        t.eq(got.c and got.c[name] and got.c[name][key], value,
                             ('entity %d %s.%s is exact'):format(e.id, name, key))
                    end
                end
            end
        end

        t.ok(checkedFields >= 40,
             ('%d declared component fields were checked'):format(checkedFields))
    end

    -----------------------------------------------------------------------
    t.describe('the wire layout is still whatever netFields says')

    -- A field the declaration does not name never reaches the wire, and a
    -- component the receiver does not carry is ignored rather than fabricated.
    -- Both rules live in entity.lua; this asserts the codec did not quietly
    -- route around either of them.
    local Mood = Entity.component('mood', { 'shown' })

    local sender = Entity.new{ kind = 'ghost', x = 4.5, y = 6.25, angle = 0.5 }
    sender:add(Mood{ shown = 'grim', private = 'not declared' })

    local carried = P.packSnapshot(snapshotOf({ sender }))
    t.ok(not carried:find('not declared', 1, true),
         'a field missing from netFields is not in the bytes at all')
    t.ok(not carried:find('private', 1, true),
         'and neither is its name')

    local _, ghostBody = P.unpack(carried)
    t.eq(ghostBody.e[1].c.mood.shown, 'grim', 'the declared field does travel')
    t.eq(ghostBody.e[1].c.mood.private, nil, 'the undeclared one does not')

    -- An unknown component: it decodes (the format is self-describing, so the
    -- bytes are readable), and applySnapshot is what refuses to invent it.
    local receiver = Entity.new{ id = sender.id, kind = 'ghost' }
    receiver:applySnapshot(ghostBody.e[1])
    t.eq(receiver:get('mood'), nil, 'a component the receiver lacks is not fabricated')
    t.near(receiver.x, 4.5, 1e-6, 'but the transform still applies')

    -- Adding a field to a declaration is all it takes; there is no codec to edit.
    local Wide = Entity.component('wide', { 'a', 'b', 'c', 'd' })
    local wideEntity = Entity.new{ kind = 'ghost' }
    wideEntity:add(Wide{ a = 1, b = 'two', c = true, d = { 4, 5, 6 } })
    local _, wideBody = P.unpack((P.packSnapshot(snapshotOf({ wideEntity }))))
    local same, why = deepEqual({ a = 1, b = 'two', c = true, d = { 4, 5, 6 } },
                                wideBody.e[1].c.wide, 'wide')
    t.ok(same, 'a four-field declaration replicates with no codec change', why)

    -----------------------------------------------------------------------
    t.describe('values keep their types and their precision')

    local Odd = Entity.component('odd', { 'flagOn', 'flagOff', 'zero', 'neg',
                                          'big', 'frac', 'exact32', 'text',
                                          'list', 'map', 'inf', 'nan' })
    local values = {
        flagOn  = true,
        flagOff = false,
        zero    = 0,
        neg     = -12345,
        big     = 2 ^ 52 + 1,
        frac    = 1 / 3,                 -- needs a full double
        exact32 = 0.5,                   -- survives binary32
        text    = 'a string with \0 a nul and } a brace',
        list    = { 1, 2, 3, 'four' },
        map     = { alpha = 1, beta = { nested = true } },
        inf     = math.huge,
        nan     = 0 / 0,
    }

    local oddEntity = Entity.new{ kind = 'ghost', x = 1, y = 2, angle = 3 }
    oddEntity:add(Odd(values))

    local _, oddBody = P.unpack((P.packSnapshot(snapshotOf({ oddEntity }))))
    local got = oddBody.e[1].c.odd

    for key, want in pairs(values) do
        if key ~= '__def' then
            local ok, detail = deepEqual(want, got[key], key)
            t.ok(ok, ('%s round-trips exactly'):format(key), detail)
        end
    end
    t.ok(got.nan ~= got.nan, 'a NaN arrives as a NaN rather than as nil')
    t.eq(got.inf, math.huge, 'an infinity arrives as an infinity')
    t.eq(got.frac, 1 / 3, 'a value that needs float64 gets float64')

    -----------------------------------------------------------------------
    t.describe('float encoding is little-endian by decision, not by accident')

    local lua = Codec.floatCodecs.lua
    local ffi = Codec.floatCodecs.ffi

    -- Pinned bytes. If someone "optimises" this to write the host's own order,
    -- these fail on the machine that did it, not on a user's.
    t.eq(lua.putF32(1.0), string.char(0x00, 0x00, 0x80, 0x3F),
         '1.0 as binary32 is 00 00 80 3F, least significant byte first')
    t.eq(lua.putF64(1.0), string.char(0, 0, 0, 0, 0, 0, 0xF0, 0x3F),
         '1.0 as binary64 is 00 00 00 00 00 00 F0 3F')
    t.eq(lua.putF32(-2.0), string.char(0x00, 0x00, 0x00, 0xC0),
         '-2.0 as binary32 is 00 00 00 C0')

    -- Two independent implementations agreeing byte for byte is the real proof:
    -- one derives its bytes arithmetically and cannot depend on host order, the
    -- other reads the host's memory and swaps when ffi.abi says to.
    local CORPUS = {
        0, 1, -1, 0.5, -0.5, 2, 1 / 3, 12.5, -1.25, 987654.321,
        2 ^ -126,                    -- smallest normal binary32
        2 ^ -149,                    -- smallest subnormal binary32
        1.5e-45, 1e-40,              -- inside the binary32 subnormal range
        3.4028234663852886e38,       -- largest finite binary32
        1e308, 5e-324,               -- binary64 extremes
        2 ^ 53, math.huge, -math.huge, 0 / 0,
    }

    if ffi then
        local mismatches = 0
        for _, v in ipairs(CORPUS) do
            if lua.putF32(v) ~= ffi.putF32(v) then mismatches = mismatches + 1 end
            if lua.putF64(v) ~= ffi.putF64(v) then mismatches = mismatches + 1 end
        end
        t.eq(mismatches, 0,
             ('the pure-Lua and ffi float paths agree on all %d test values')
             :format(#CORPUS))
    else
        t.ok(true, 'no ffi on this build, so there is nothing to cross-check')
    end

    -- And each path reads back what it wrote, including the values that are
    -- easiest to get wrong: subnormals, the two zeroes, and the non-finites.
    local paths = { { 'lua', lua } }
    if ffi then paths[#paths + 1] = { 'ffi', ffi } end

    for _, entry in ipairs(paths) do
        local name, codec = entry[1], entry[2]
        local wrong = 0
        for _, v in ipairs(CORPUS) do
            local back64 = codec.getF64(codec.putF64(v), 1)
            if not (back64 == v or (back64 ~= back64 and v ~= v)) then wrong = wrong + 1 end

            local back32 = codec.getF32(codec.putF32(v), 1)
            -- binary32 cannot hold every one of these; what must hold is that a
            -- value it *can* hold comes back unchanged, and one it cannot comes
            -- back as a near neighbour rather than as garbage.
            if v == v and v ~= 0 and back32 == back32 and back32 ~= 0
               and math.abs(back32) ~= math.huge and math.abs(v) < 3.4e38 then
                -- Relative for normals, plus one subnormal step. Below 2^-126
                -- binary32 spacing stops shrinking with the value, so a purely
                -- relative bound would fail on 1e-40 for a correct answer.
                local bound = math.abs(v) * 2 ^ -23 + 2 ^ -148
                if math.abs(back32 - v) > bound then wrong = wrong + 1 end
            end
        end
        t.eq(wrong, 0, ('the %s float path reads back what it wrote'):format(name))
    end

    -- Signed zero is preserved rather than flattened, which is the sort of thing
    -- that is fine until something divides by it.
    t.ok(1 / lua.getF64(lua.putF64(-0.0), 1) < 0, 'negative zero survives binary64')
    t.ok(1 / lua.getF32(lua.putF32(-0.0), 1) < 0, 'negative zero survives binary32')

    -----------------------------------------------------------------------
    t.describe('the codec works with no string.buffer and no ffi')

    -- LOVE 11.4 ships a LuaJIT without string.buffer, so this is a configuration
    -- players actually run, not a hypothetical. The fallback is asserted to
    -- produce *identical bytes*, not merely working ones: a build that encoded
    -- differently would be a build that talks to a different game.
    local wasBackend, wasFloats = Codec.backend, Codec.floats

    local ok, err = pcall(function()
        Codec.useBackend('table', 'lua')
        t.eq(Codec.backend, 'table', 'the accumulator falls back to a plain table')
        t.eq(Codec.floats, 'lua', 'and the floats to the pure-Lua codec')

        local fallbackPacket = P.packSnapshot(snapshot)
        t.eq(#fallbackPacket, #packet,
             'the fallback path produces a packet of the same size')
        t.eq(fallbackPacket, packet,
             'and byte for byte the same packet')

        local fbKind, fbBody = P.unpack(fallbackPacket)
        t.eq(fbKind, P.SNAPSHOT, 'which still decodes')
        t.eq(fbBody and #fbBody.e, ENTITY_COUNT, 'to the same entities')

        -- Decoding with the fallback what the fast path encoded, and the reverse.
        Codec.useBackend('buffer', 'ffi')
        local fastPacket = P.packSnapshot(snapshot)
        Codec.useBackend('table', 'lua')
        local crossKind, crossBody = P.unpack(fastPacket)
        t.eq(crossKind, P.SNAPSHOT, 'a fast-path packet decodes on a fallback build')
        t.eq(crossBody and #crossBody.e, ENTITY_COUNT, 'with every entity intact')
    end)

    Codec.useBackend(wasBackend, wasFloats)
    t.ok(ok, 'the fallback checks ran', err)
    t.eq(Codec.backend, wasBackend, 'and the backend is restored afterwards')
    t.eq(Codec.floats, wasFloats, 'as are the floats')

    -- Asking for something this build does not have gets the fallback rather
    -- than an error, which is the entire point of having one.
    local gotBackend = Codec.useBackend('nonsense', 'nonsense')
    t.eq(gotBackend, 'table', 'an unknown accumulator name falls back rather than raising')
    Codec.useBackend(wasBackend, wasFloats)

    -----------------------------------------------------------------------
    t.describe('a body the layout cannot model falls back rather than losing a field')

    -- A snapshot with a key outside { tick, e } is a shape this codec does not
    -- describe. It must go out as text — bigger, and fragmenting — because
    -- dropping the key would be a silent desync and refusing to send would be a
    -- stalled stream.
    local oddBody2 = { tick = 4, e = {}, extra = 'a key the layout does not model' }
    local fallbackPacket, compact, whyNot = P.packSnapshot(oddBody2)
    t.ok(not compact, 'an unmodelled body reports that it fell back')
    t.ok(whyNot ~= nil and whyNot:find('extra'), 'and names the key that caused it', whyNot)

    local fbKind, fbBody = P.unpack(fallbackPacket)
    t.eq(fbKind, P.SNAPSHOT, 'the fallback packet is still a snapshot')
    t.eq(fbBody and fbBody.extra, 'a key the layout does not model',
         'and it kept the key rather than dropping it')

    local _, entityCompact = P.packSnapshot({ tick = 1, e = { { id = 1, weird = true } } })
    t.ok(not entityCompact, 'an entity snapshot with an unmodelled key falls back too')

    -- Bodies that are legal but odd still take the compact path.
    local _, emptyCompact = P.packSnapshot({})
    t.ok(emptyCompact, 'an empty body is modelled')
    local _, emptyList = P.unpack((P.packSnapshot({})))
    t.eq(emptyList and #emptyList.e, 0, 'and decodes to no entities')
    t.eq(emptyList and emptyList.tick, 0, 'with tick 0 rather than nil')

    -- Text snapshots from a peer that has not been updated still decode, which
    -- is what makes the magic byte worth having.
    local textKind, textBody = P.unpack(P.pack(P.SNAPSHOT, { tick = 7, e = {} }))
    t.eq(textKind, P.SNAPSHOT, 'a text-serialised snapshot still decodes')
    t.eq(textBody and textBody.tick, 7, 'with its body intact')

    -----------------------------------------------------------------------
    t.describe('malformed input returns a reason, never raises')

    -- Byte layout: magic 1, version, header flag (1 = keyframe), varint tick,
    -- keyframe generation, string count, entity count, entities.
    local V = Codec.VERSION
    local JUNK = {
        '', '\1', string.char(1, V),                    -- truncated
        string.char(1, V, 1, 0, 0, 0),                  -- ends before the entity count
        '\1\1\1\0\0\0\0',                               -- version 1: this build speaks 4
        '\1\9\1\0\0\0\0',                               -- a version from nowhere
        string.char(1, V, 2, 0, 0, 0, 0),               -- an undefined header flag bit
        string.char(1, V, 1, 255),                      -- a varint that never ends
        string.char(1, V, 1, 0, 0, 0, 200),             -- 200 entities, seven bytes
        string.char(1, V, 1, 0, 0, 200, 0),             -- 200 strings, seven bytes
        string.char(1, V, 1, 0, 0, 0, 1, 1, 255),       -- an entity with junk flags
        string.char(1, V, 1, 0, 0, 0, 1, 1, 1, 99),     -- a string ref with no entry
        string.char(1, V, 1, 0, 0, 0, 1, 1, 16, 200),   -- 200 components, no bytes
        string.char(1, V, 0, 0, 0, 0, 0, 200),          -- 200 removals, no bytes
        string.rep('\1', 64),
        string.char(1, V, 1, 0, 0, 0, 0) .. '\0\0\0\0', -- trailing bytes
    }

    for i = 1, #JUNK do
        local value, reason = Codec.decode(JUNK[i])
        t.ok(value == nil and reason ~= nil,
             ('junk %d is rejected with a reason'):format(i),
             value ~= nil and 'it was accepted' or 'no reason given')
    end

    t.ok(Codec.decode(nil) == nil, 'a nil input is rejected')
    t.ok(Codec.decode(42) == nil, 'a non-string input is rejected')

    -- The envelope must not raise either, which is the property the whole net
    -- stack's service loop depends on.
    -- Layout: magic, version, full flag, tick, keyGen, string count, then junk.
    local raised = not pcall(P.unpack,
        P.SNAPSHOT .. string.char(1, V, 1, 0, 0, 0, 255))
    t.ok(not raised, 'and a hostile snapshot returns a reason rather than raising')

    -- A count that claims more entries than there are bytes is rejected before
    -- the loop runs, not after a hundred million iterations of it.
    local hostile = P.SNAPSHOT
        .. string.char(1, V, 1, 0, 0, 0)
        .. string.char(255, 255, 255, 127)
    local hostileKind, _, hostileWhy = P.unpack(hostile)
    t.ok(hostileKind == nil, 'an impossible entity count is refused')
    t.ok(hostileWhy ~= nil and hostileWhy:find('bytes remain'),
         'with a reason that says why it is impossible', hostileWhy)

    -----------------------------------------------------------------------
    t.describe('encoding refuses what it cannot represent')

    local Bad = Entity.component('bad', { 'fn' })
    local badEntity = Entity.new{ kind = 'ghost' }
    badEntity:add(Bad{ fn = print })

    local badBody = snapshotOf({ badEntity })
    local badBytes, badWhy = Codec.encode(badBody)
    t.ok(badBytes == nil and badWhy ~= nil,
         'a function in a netFields declaration is refused, with a reason', badWhy)
    t.ok(badWhy and badWhy:find('function'), 'that names what it could not encode', badWhy)

    -- And then it stays refused. The text fallback is the same serializer with
    -- the same rule, which raises rather than returning: a closure in a netFields
    -- declaration is a bug in a declaration, and serialize.lua's stated position
    -- is that it should be loud. P.packSnapshot inherits that, exactly as P.pack
    -- always has, rather than inventing a quieter answer for snapshots only.
    t.ok(not pcall(P.packSnapshot, badBody),
         'and the text fallback raises on it too, as P.pack does')

    local cycle = {}
    cycle.self = cycle
    local Cyclic = Entity.component('cyclic', { 'loop' })
    local cyclicEntity = Entity.new{ kind = 'ghost' }
    cyclicEntity:add(Cyclic{ loop = cycle })
    local cyclicBytes, cyclicWhy = Codec.encode(snapshotOf({ cyclicEntity }))
    t.ok(cyclicBytes == nil, 'a cycle is refused rather than recursed forever', cyclicWhy)
    t.ok(cyclicWhy and cyclicWhy:find('deeper'), 'by the depth limit', cyclicWhy)

    -----------------------------------------------------------------------
    t.describe('the declaration registry the codec reads')

    local declared = Entity.netFieldsFor('health')
    t.ok(declared ~= nil, 'a declared component can be looked up by name')
    t.eq(declared and #declared, 2, 'with the fields it declared')
    t.eq(Entity.netFieldsFor('motion'), nil,
         'a component with no netFields reports none rather than an empty list')
    t.eq(Entity.netFieldsFor('no such component'), nil, 'and an unknown name is nil')

    -- The registry is an optimisation, not the format. A component name this
    -- build never declared still encodes and decodes, because the field names
    -- travel in the packet.
    local unknownSnap = { tick = 1, e = { { id = 9, kind = 'ghost', x = 1, y = 2,
                                            angle = 0,
                                            c = { neverDeclared = { alpha = 1,
                                                                    beta = 'two' } } } } }
    local unknownKind, unknownBody = P.unpack((P.packSnapshot(unknownSnap)))
    t.eq(unknownKind, P.SNAPSHOT, 'an undeclared component name still encodes')
    local sameUnknown, unknownWhy = deepEqual(unknownSnap.e[1].c, unknownBody.e[1].c, 'c')
    t.ok(sameUnknown, 'and round-trips its fields', unknownWhy)

    -----------------------------------------------------------------------
    t.describe('the save format was not dragged along')

    -- meatray/save/format.lua shares meatray.net.serialize. The whole reason this
    -- is a second codec rather than a replacement is that a save file must not
    -- change shape because a packet wanted to be smaller.
    local Serialize = require('meatray.net.serialize')
    t.eq(Serialize.encode(1.5), '#1.5;', 'the text serializer still writes numbers as text')
    t.eq(Serialize.decode('#1.5;'), 1.5, 'and still reads them')
    local Format = require('meatray.save.format')
    t.ok(Format.VERSION ~= nil, 'the save format still loads and reports a version')

    -----------------------------------------------------------------------
    t.describe('negative zero survives both float backends')

    -- -0.0 is a real position (the sign is which side of the axis you
    -- approached from) and encodeNumber already refuses to flatten it into
    -- the integer path. The pure-Lua decoders then used to hand back
    -- `sign * 0`, which under Lua 5.4 is INTEGER arithmetic — no signed
    -- zero — so the sign the bytes carried evaporated on the last line.
    -- LuaJIT's all-doubles arithmetic hid it, which is why the assertion
    -- runs the pure backend explicitly.
    local function isNegZero(v) return v == 0 and 1 / v < 0 end

    local zeroSnap = { tick = 1, e = { { id = 1, kind = 'grunt',
                                         x = -0.0, y = 0.0, angle = 0,
                                         c = { probe = { off = -0.0 } } } } }
    local zeroBackend, zeroFloats = Codec.backend, Codec.floats
    for _, floats in ipairs({ 'ffi', 'lua' }) do
        Codec.useBackend('table', floats)
        if Codec.floats == floats then    -- ffi may be absent on a plain host
            local _, zb = P.unpack((P.packSnapshot(zeroSnap)))
            t.ok(isNegZero(zb.e[1].x),
                 ('x = -0.0 keeps its sign through the %s floats'):format(floats))
            t.ok(not isNegZero(zb.e[1].y),
                 ('and +0.0 does not gain one (%s)'):format(floats))
            t.ok(isNegZero(zb.e[1].c.probe.off),
                 ('a component number keeps it too (%s)'):format(floats))
        end
    end
    Codec.useBackend(zeroBackend, zeroFloats)
end
