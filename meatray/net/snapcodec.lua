--[[
    meatray.net.snapcodec — the snapshot stream's binary wire format.

    WHY THIS EXISTS, AND IT IS NOT BANDWIDTH

    Snapshots are sent with `reliable = false`, which the enet transport maps to
    lua-enet's 'unreliable', which sets ENet's packet flags to 0. ENet decides how
    to deliver a *fragmented* packet by testing

        (flags & (RELIABLE | UNRELIABLE_FRAGMENT)) == UNRELIABLE_FRAGMENT

    and that test is false for flags 0, so the fragment path falls through to
    SEND_FRAGMENT | FLAG_ACKNOWLEDGE: reliable, acknowledged, retransmitted, and
    head-of-line blocked. A snapshot that crosses one MTU therefore stops being a
    snapshot stream and becomes a reliable one, which is the single worst thing it
    could become — a late snapshot shows a player the past, and unlike a dropped
    one it also delays everything queued behind it.

    lua-enet exposes no string that maps to ENET_PACKET_FLAG_UNRELIABLE_FRAGMENT,
    so this cannot be fixed by changing the flag from Lua. The only fix available
    is to keep a snapshot inside one datagram. That is this file. It is a
    correctness fix that happens to look like a compression one.

    Measured against the text serializer on a mixed scene (8 players carrying
    billboard/health/player/weapon, the rest grunts carrying billboard/health):

        text    141-181 bytes/entity   first packet over 1364 bytes at 8-10 entities
        binary   28- 47 bytes/entity   first packet over 1364 bytes at 44 entities

    See tests/test_net_snapcodec.lua, which asserts the ceiling rather than
    describing it, so the bug cannot come back quietly.

    WHAT IS NOT HERE

    The save format shares meatray.net.serialize (see meatray/save/format.lua),
    and a save file is not allowed to change shape because the network wanted a
    smaller packet. So this is a second codec beside the first, not a replacement
    for it, and only the snapshot path uses it. Joins, chat, commands and world
    deltas stay on the text serializer; they are reliable by intent and
    fragmenting them is correct.

    THE LAYOUT, AND WHERE IT COMES FROM

    Nothing in this file names a component or a field, exactly as replication.lua
    does not. An entity snapshot is whatever `EntityMT:snapshot()` produced, which
    is whatever `netFields` declared; add a field to a netFields list and it
    travels, with no edit here. `Entity.netFieldsFor` supplies the declared field
    *order* so the encoding is deterministic without sorting a fresh table per
    component per entity per snapshot; when the lookup does not cover every field
    present (a hand-built snapshot, a component this build never declared) the
    encoder notices and falls back to sorted keys rather than dropping the ones
    the declaration did not mention.

    Field names still travel, once each, through a per-packet string table. That
    is what makes the format self-describing: a peer decodes correctly even if its
    own netFields declarations disagree with the sender's, and a stale registry
    can cost bytes but never meaning.

        magic 0x01                  never a valid meatray.net.serialize tag, which
                                    is how P.unpack tells the two bodies apart
        version byte
        byte    header flags    1 keyframe
        varint  tick
        varint  string count, then per string: varint length, bytes
        varint  entity count, then per entity:
            varint  id
            byte    flags   1 kind, 2 x, 4 y, 8 angle, 16 components
            varint  kind        -> string table
            f32     x
            f32     y
            f32     angle
            varint  component count, then per component:
                varint  name    -> string table
                varint  field count, then per field:
                    varint  name -> string table
                    value
        varint  removed count, then per removal: varint id   (partials only)

    KEYFRAMES, PARTIALS, AND WHY A FIELD MAY BE ABSENT

    The per-entity flag byte has always been able to say "this entity carries no
    angle" — nothing ever used it, because a full snapshot carries everything. A
    dirty-flag snapshot is the same layout with those bits actually earning their
    keep: a partial names only the entities that changed since the last keyframe,
    and inside each one only the transform components and the netFields that
    changed. Absence means "unchanged", which is exactly what
    EntityMT:applySnapshot already did with a missing field.

    The header flag says which kind of frame this is, and the two differ in one
    other place: in a keyframe an id that is absent is an id that is gone, and in
    a partial absence means nothing at all, so removals travel explicitly as a
    trailing list of ids. Encoding a keyframe with removals is refused rather
    than ignored — a caller that built one has the two meanings confused.

    See meatray/net/replication.lua for what "changed" is measured against, and
    docs/NETWORKING.md for how a client that dropped a packet converges.

    A value is a tag byte and a payload: nil, false, true, unsigned varint, negated
    varint, f32, f64, string reference, array, map. Numbers choose their own
    encoding — a whole number inside +-2^53 becomes a varint, and anything else
    becomes an f32 if that round-trips it exactly and an f64 if it does not. So an
    ammo count costs two bytes and a component field that genuinely needs a double
    still gets one. Only the transform is quantised, and deliberately:

    QUANTISATION, AND THE JITTER BUG SOMEONE WILL EVENTUALLY CHASE HERE

    x, y and angle are sent as IEEE-754 binary32 (4 bytes each, 12 for the
    transform, down from 39-54 bytes of "%.17g" text). Everything else is exact.

    binary32 keeps 24 significant bits, so the worst-case absolute error is
    |v| * 2^-24 — relative, not absolute:

        position 64 tiles       3.8e-6 tiles   0.00024 px at 64 px/tile
        position 1024 tiles     6.1e-5 tiles   0.0039  px at 64 px/tile
        angle 6.28 rad          3.7e-7 rad     0.000021 degrees
        angle 3.6e4 rad         2.1e-3 rad     0.12 degrees

    The last row is the one to know about: angles are *not* wrapped on the wire.
    Wrapping would put a visible spin on every remote player the moment their aim
    crossed the boundary, because the client interpolates from the previous angle
    to this one — replication.lua rejects angles past 1e6 rather than wrapping for
    the same reason. An unwrapped angle accumulates, and a session that turns
    continuously at 10 rad/s reaches 3.6e4 rad after an hour, where binary32
    resolution has decayed to about a tenth of a degree. That is still an order of
    magnitude below what a player can see at any normal FOV, and it is bounded:
    replication.MAX_ANGLE (1e6 rad, 27 hours of continuous spinning) caps the
    worst case at 0.06 rad. If a "remote players are slightly jittery" report ever
    lands, this paragraph is the first place to look, and the fix is an int32
    fixed-point angle, not a float64.

    ENDIANNESS

    Little-endian on the wire, always, converted explicitly — never inherited from
    the host. The pure-Lua float path builds its bytes least-significant first by
    construction, so it is endian-independent code that emits a fixed order. The
    ffi path reads the host's own bytes and reverses them when `ffi.abi('le')` says
    the host is big-endian. tests/test_net_snapcodec.lua asserts the two paths
    agree byte for byte and pins the encoding of 1.0, so "it happened to work on
    the machine it was written on" is not a state this file can reach.

    string.buffer IS OPTIONAL

    LOVE 11.4 and some distribution builds ship a LuaJIT without `string.buffer`,
    and some without `ffi`. Both requires are gated and both have a fallback: a
    table-of-strings accumulator, and the pure-Lua IEEE-754 codec above. The
    engine runs on those builds; it is slower at packing snapshots and produces
    identical bytes. `Codec.backend` and `Codec.floats` name which path is live.

    HEADLESS: no LOVE anywhere, and no love.data.pack in particular — which would
    otherwise be the obvious answer, since it is a real string.pack backport with
    an 'f' specifier. tests/test_headless.lua requires every meatray/net module
    with the `love` global removed, so reaching for love.data here would break the
    whole replication suite under plain LuaJIT.
]]

local Entity = require('meatray.sim.entity')

local Codec = {}

local char, byte, sub = string.char, string.byte, string.sub
local concat, sort = table.concat, table.sort
local floor, frexp, ldexp, huge = math.floor, math.frexp, math.ldexp, math.huge

---------------------------------------------------------------------------
-- Constants
---------------------------------------------------------------------------

-- 0x01 is not a tag meatray.net.serialize can produce: its tags are '-', '+',
-- '/', '#', '$', '[' and '{', and a snapshot body is always a table, so it always
-- starts with '[' or '{'. One byte therefore tells a receiver which codec wrote
-- the body, which is what lets a binary sender and a text sender coexist.
Codec.MAGIC   = 0x01

--   1  full snapshots only: magic, version, tick, strings, entities.
--   2  a header flag byte after the version saying whether this frame is a
--      keyframe, and a trailing removal list on the frames that are not. A
--      version 1 reader would take the flag byte for the first byte of the tick
--      varint and decode a plausible-looking wrong answer, which is why the
--      version moved rather than the flag being squeezed into a spare bit.
Codec.VERSION = 2

-- 32 is far deeper than any snapshot; hitting it means a cycle or a mistake. Same
-- number as the text serializer, and for both of its reasons: a cycle on the way
-- out, and `[1:[1:[1:` recursion on the way in.
Codec.MAX_DEPTH = 32

local MAGIC, VERSION, MAX_DEPTH = Codec.MAGIC, Codec.VERSION, Codec.MAX_DEPTH

-- Whole numbers are exact in a double up to here, so this is where varints stop.
local MAX_UINT = 2 ^ 53

local T_NIL, T_FALSE, T_TRUE = 0, 1, 2
local T_UINT, T_NINT         = 3, 4
local T_F32, T_F64           = 5, 6
local T_STR                  = 7
local T_ARRAY, T_MAP         = 8, 9

local FLAG_KIND, FLAG_X, FLAG_Y, FLAG_ANGLE, FLAG_C = 1, 2, 4, 8, 16

-- The only two keys a snapshot body may carry, and the only six an entity
-- snapshot may. Anything else and the encoder refuses rather than dropping it:
-- see Codec.encode, which reports the refusal so the caller can fall back to the
-- text serializer and lose bytes instead of information.
local SNAPSHOT_KEYS = { tick = true, e = true, full = true, r = true }
local ENTITY_KEYS   = { id = true, kind = true, x = true, y = true,
                        angle = true, c = true }

local CHAR = {}
for i = 0, 255 do CHAR[i] = char(i) end

local EMPTY = {}

---------------------------------------------------------------------------
-- IEEE-754, in pure Lua, little-endian by construction
---------------------------------------------------------------------------

-- These build their bytes least-significant first from arithmetic, so they emit
-- the same four or eight bytes on any host regardless of its native order. They
-- are also the fallback for a LuaJIT built without ffi.

-- One canonical quiet NaN each, rather than whatever payload the host happened to
-- be carrying. A NaN's payload bits are not observable from Lua, so emitting the
-- host's would make the wire bytes depend on the machine for no gain — and would
-- stop the two float paths below being byte-for-byte comparable, which is the
-- test that proves the endianness handling.
local NAN32, NAN64 = '\0\0\192\127', '\0\0\0\0\0\0\248\127'

local function luaPutF32(v)
    if v ~= v then return NAN32 end

    local sign = 0
    if v < 0 or (v == 0 and 1 / v < 0) then sign, v = 1, -v end

    local infinity = CHAR[0] .. CHAR[0] .. CHAR[128] .. CHAR[127 + sign * 128]
    if v == huge then return infinity end

    local m, e
    if v == 0 then
        m, e = 0, 0
    else
        m, e = frexp(v)                             -- v = m * 2^e, 0.5 <= m < 1
        e = e + 126                                 -- binary32 exponent bias
        if e <= 0 then
            -- Subnormal: the value is M * 2^-149, and M = m * 2^(e + 23).
            m = floor(m * 2 ^ (e + 23) + 0.5)
            e = 0
            if m >= 0x800000 then m, e = 0, 1 end   -- rounded up to the smallest normal
        elseif e >= 255 then
            return infinity
        else
            m = floor((m * 2 - 1) * 0x800000 + 0.5)
            if m >= 0x800000 then                   -- rounding carried into the exponent
                m, e = 0, e + 1
                if e >= 255 then return infinity end
            end
        end
    end

    return CHAR[m % 256]
        .. CHAR[floor(m / 256) % 256]
        .. CHAR[floor(m / 65536) % 128 + (e % 2) * 128]
        .. CHAR[floor(e / 2) + sign * 128]
end

local function luaGetF32(s, i)
    local b1, b2, b3, b4 = byte(s, i, i + 3)

    local sign = 1
    if b4 >= 128 then sign, b4 = -1, b4 - 128 end

    local e = b4 * 2 + floor(b3 / 128)
    local m = (b3 % 128) * 65536 + b2 * 256 + b1

    if e == 255 then
        if m == 0 then return sign * huge end
        return 0 / 0
    end
    if e == 0 then
        if m == 0 then return sign * 0 end
        return sign * ldexp(m, -149)
    end
    return sign * ldexp(m + 0x800000, e - 150)
end

local function luaPutF64(v)
    if v ~= v then return NAN64 end

    local sign = 0
    if v < 0 or (v == 0 and 1 / v < 0) then sign, v = 1, -v end

    if v == huge then
        return CHAR[0] .. CHAR[0] .. CHAR[0] .. CHAR[0] .. CHAR[0] .. CHAR[0]
            .. CHAR[240] .. CHAR[127 + sign * 128]
    end

    local m, e
    if v == 0 then
        m, e = 0, 0
    else
        m, e = frexp(v)
        e = e + 1022                                -- binary64 exponent bias
        if e <= 0 then
            m = floor(m * 2 ^ (e + 52))             -- exact: a subnormal double loses nothing here
            e = 0
        else
            m = (m * 2 - 1) * 4503599627370496      -- 2^52, and exact for every double
        end
    end

    local out, rest = {}, m
    for i = 1, 6 do
        out[i] = CHAR[rest % 256]
        rest = floor(rest / 256)
    end
    out[7] = CHAR[rest % 16 + (e % 16) * 16]
    out[8] = CHAR[floor(e / 16) + sign * 128]

    return concat(out)
end

local function luaGetF64(s, i)
    local b1, b2, b3, b4, b5, b6, b7, b8 = byte(s, i, i + 7)

    local sign = 1
    if b8 >= 128 then sign, b8 = -1, b8 - 128 end

    local e = b8 * 16 + floor(b7 / 16)
    local m = (b7 % 16) * 281474976710656           -- 2^48
            + b6 * 1099511627776                    -- 2^40
            + b5 * 4294967296
            + b4 * 16777216
            + b3 * 65536
            + b2 * 256
            + b1

    if e == 2047 then
        if m == 0 then return sign * huge end
        return 0 / 0
    end
    if e == 0 then
        if m == 0 then return sign * 0 end
        return sign * ldexp(m, -1074)
    end
    return sign * ldexp(m + 4503599627370496, e - 1075)
end

---------------------------------------------------------------------------
-- IEEE-754, through ffi, with the host's endianness handled rather than assumed
---------------------------------------------------------------------------

local ffiPutF32, ffiGetF32, ffiPutF64, ffiGetF64

do
    local ok, ffi = pcall(require, 'ffi')
    if ok and type(ffi) == 'table' then
        local built, box = pcall(ffi.new, 'union { float f; double d; uint8_t b[8]; }')
        if built and box then
            local ffiString, ffiCopy = ffi.string, ffi.copy
            -- Explicit, not inherited. On a little-endian host the union's own
            -- bytes are already the wire order; on a big-endian one they are its
            -- reverse, and a four- or eight-byte string reversal is exactly the
            -- byte swap.
            local little = ffi.abi('le')

            ffiPutF32 = function(v)
                if v ~= v then return NAN32 end
                box.f = v
                local s = ffiString(box.b, 4)
                if little then return s end
                return s:reverse()
            end

            ffiGetF32 = function(s, i)
                local bytes = sub(s, i, i + 3)
                if not little then bytes = bytes:reverse() end
                ffiCopy(box.b, bytes, 4)
                return box.f
            end

            ffiPutF64 = function(v)
                if v ~= v then return NAN64 end
                box.d = v
                local s = ffiString(box.b, 8)
                if little then return s end
                return s:reverse()
            end

            ffiGetF64 = function(s, i)
                local bytes = sub(s, i, i + 7)
                if not little then bytes = bytes:reverse() end
                ffiCopy(box.b, bytes, 8)
                return box.d
            end
        end
    end
end

---------------------------------------------------------------------------
-- Backend selection
---------------------------------------------------------------------------

-- Gated, because a LuaJIT without string.buffer is a real configuration and not a
-- hypothetical one: LOVE 11.4 ships one. Same for ffi.
local haveBuffer, bufferLib = pcall(require, 'string.buffer')
if not haveBuffer or type(bufferLib) ~= 'table' or type(bufferLib.new) ~= 'function' then
    bufferLib = nil
end

Codec.hasStringBuffer = bufferLib ~= nil
Codec.hasFFIFloats    = ffiPutF32 ~= nil

local putF32, getF32, putF64, getF64
local newWriter

local function bufferNew()
    local b = bufferLib.new()
    return b, b.put, tostring
end

local function tablePut(w, s)
    local n = w.n + 1
    w.n = n
    w[n] = s
end

local function tableDone(w)
    return concat(w, '', 1, w.n)
end

local function tableNew()
    return { n = 0 }, tablePut, tableDone
end

-- Names the live paths, and switches them. `which` is 'buffer' or 'table' for the
-- accumulator and 'ffi' or 'lua' for the floats; either may be nil to leave that
-- half alone. Returns the two names now in force. Asking for a backend this build
-- does not have gets the fallback, silently, which is the entire point of having
-- one. The tests use this to exercise the fallback path on a toolchain that has
-- both.
function Codec.useBackend(accumulator, floats)
    if accumulator == 'buffer' and bufferLib then
        newWriter, Codec.backend = bufferNew, 'buffer'
    elseif accumulator ~= nil then
        newWriter, Codec.backend = tableNew, 'table'
    end

    if floats == 'ffi' and ffiPutF32 then
        putF32, getF32, putF64, getF64 = ffiPutF32, ffiGetF32, ffiPutF64, ffiGetF64
        Codec.floats = 'ffi'
    elseif floats ~= nil then
        putF32, getF32, putF64, getF64 = luaPutF32, luaGetF32, luaPutF64, luaGetF64
        Codec.floats = 'lua'
    end

    return Codec.backend, Codec.floats
end

Codec.useBackend(bufferLib and 'buffer' or 'table', ffiPutF32 and 'ffi' or 'lua')

-- What a receiver will actually hold for a transform field, which is not what
-- the sender holds: x, y and angle are quantised to binary32 on the way out.
--
-- This exists for the dirty-flag path in replication.lua. A baseline is only
-- honest if it stores what the other side has, so "did this change?" is asked
-- about the quantised value — otherwise an entity drifting by less than a
-- binary32 step is marked dirty forever and re-sent every frame to say nothing.
-- Passes anything that is not a number straight through, so a caller can hand it
-- a nil transform without guarding first.
function Codec.quantise(v)
    if type(v) ~= 'number' then return v end
    return getF32(putF32(v), 1)
end

---------------------------------------------------------------------------
-- Encoding
---------------------------------------------------------------------------

local function putUInt(put, w, v)
    while v >= 128 do
        local b = v % 128
        v = (v - b) / 128
        put(w, CHAR[b + 128])
    end
    put(w, CHAR[v])
end

local function intern(st, s)
    local index = st.index
    local at = index[s]
    if at then return at end
    at = st.count + 1
    st.count = at
    index[s] = at
    st.strings[at] = s
    return at
end

local encodeValue

-- Whole numbers become varints, which is where most of the saving is: an ammo
-- count, an id, a peer number and a hit-point total are all one tag byte plus one
-- or two payload bytes instead of a decimal string. Everything else picks the
-- narrowest float that reproduces it *exactly*, so a component field never
-- silently loses precision — only the transform is quantised, and that is a
-- decision made above this function, not here.
local function encodeNumber(st, v)
    if v % 1 == 0 and v > -MAX_UINT and v < MAX_UINT
       and not (v == 0 and 1 / v < 0) then
        if v >= 0 then
            st.put(st.w, CHAR[T_UINT])
            putUInt(st.put, st.w, v)
        else
            st.put(st.w, CHAR[T_NINT])
            putUInt(st.put, st.w, -v)
        end
        return
    end

    local narrow = putF32(v)
    if getF32(narrow, 1) == v then
        st.put(st.w, CHAR[T_F32])
        st.put(st.w, narrow)
    else
        st.put(st.w, CHAR[T_F64])
        st.put(st.w, putF64(v))
    end
end

encodeValue = function(st, v, depth)
    if depth > MAX_DEPTH then
        error('snapcodec: value nests deeper than ' .. MAX_DEPTH
              .. ' levels (a cycle?)', 0)
    end

    local kind = type(v)

    if v == nil then
        st.put(st.w, CHAR[T_NIL])

    elseif kind == 'boolean' then
        st.put(st.w, v and CHAR[T_TRUE] or CHAR[T_FALSE])

    elseif kind == 'number' then
        encodeNumber(st, v)

    elseif kind == 'string' then
        st.put(st.w, CHAR[T_STR])
        putUInt(st.put, st.w, intern(st, v))

    elseif kind == 'table' then
        -- Array form when the entry count equals the length, exactly as the text
        -- serializer decides it, and for the same reason: paying a key per slot
        -- for 1, 2, 3 is the difference between a compact inventory and a fat one.
        local n = #v
        local count = 0
        for _ in pairs(v) do count = count + 1 end

        if count == n then
            st.put(st.w, CHAR[T_ARRAY])
            putUInt(st.put, st.w, n)
            for i = 1, n do encodeValue(st, v[i], depth + 1) end
        else
            st.put(st.w, CHAR[T_MAP])
            putUInt(st.put, st.w, count)
            for key, value in pairs(v) do
                encodeValue(st, key, depth + 1)
                encodeValue(st, value, depth + 1)
            end
        end

    else
        error('snapcodec: cannot encode a ' .. kind
              .. ' (netFields should only name plain data)', 0)
    end
end

-- The field order for one component's values. `netFields` is the declaration the
-- whole replication path already runs on, so reading it here is what keeps the
-- wire layout derived from the declaration rather than from a second list.
--
-- The declaration is trusted only as far as it accounts for every field actually
-- present. A hand-built snapshot, or a component this build never declared, falls
-- back to sorted keys — dropping a field the declaration failed to mention would
-- be a silent desync, and a sort is cheap next to that.
local function fieldOrder(name, fields)
    local total = 0
    for _ in pairs(fields) do total = total + 1 end

    local declared = Entity.netFieldsFor(name)
    if declared then
        local present = 0
        for i = 1, #declared do
            if fields[declared[i]] ~= nil then present = present + 1 end
        end
        if present == total then return declared, present end
    end

    local keys = {}
    for key in pairs(fields) do
        if type(key) ~= 'string' then
            error(('snapcodec: component %q has a non-string field name')
                  :format(tostring(name)), 0)
        end
        keys[#keys + 1] = key
    end
    sort(keys)

    return keys, total
end

local function encodeComponents(st, components)
    local names = {}
    for name in pairs(components) do
        if type(name) ~= 'string' then
            error('snapcodec: a component name is not a string', 0)
        end
        names[#names + 1] = name
    end
    sort(names)

    putUInt(st.put, st.w, #names)

    for i = 1, #names do
        local name = names[i]
        local fields = components[name]
        if type(fields) ~= 'table' then
            error(('snapcodec: component %q is not a table of fields'):format(name), 0)
        end

        local order, count = fieldOrder(name, fields)

        putUInt(st.put, st.w, intern(st, name))
        putUInt(st.put, st.w, count)

        for j = 1, #order do
            local key = order[j]
            local value = fields[key]
            if value ~= nil then
                putUInt(st.put, st.w, intern(st, key))
                encodeValue(st, value, 1)
            end
        end
    end
end

local function encodeEntity(st, snap)
    if type(snap) ~= 'table' then
        error('snapcodec: an entity snapshot is not a table', 0)
    end

    for key in pairs(snap) do
        if not ENTITY_KEYS[key] then
            error(('snapcodec: entity snapshot carries %q, which the snapshot '
                   .. 'layout does not model'):format(tostring(key)), 0)
        end
    end

    local id = snap.id
    if type(id) ~= 'number' or id % 1 ~= 0 or id < 0 or id >= MAX_UINT then
        error('snapcodec: an entity id is not a whole non-negative number', 0)
    end

    local kind, x, y, angle, c = snap.kind, snap.x, snap.y, snap.angle, snap.c

    if kind ~= nil and type(kind) ~= 'string' then
        error('snapcodec: an entity kind is not a string', 0)
    end
    if x ~= nil and type(x) ~= 'number' then
        error('snapcodec: entity x is not a number', 0)
    end
    if y ~= nil and type(y) ~= 'number' then
        error('snapcodec: entity y is not a number', 0)
    end
    if angle ~= nil and type(angle) ~= 'number' then
        error('snapcodec: entity angle is not a number', 0)
    end
    if c ~= nil and type(c) ~= 'table' then
        error('snapcodec: entity components are not a table', 0)
    end

    local flags = 0
    if kind  ~= nil then flags = flags + FLAG_KIND end
    if x     ~= nil then flags = flags + FLAG_X end
    if y     ~= nil then flags = flags + FLAG_Y end
    if angle ~= nil then flags = flags + FLAG_ANGLE end
    if c     ~= nil then flags = flags + FLAG_C end

    local put, w = st.put, st.w

    putUInt(put, w, id)
    put(w, CHAR[flags])

    if kind  ~= nil then putUInt(put, w, intern(st, kind)) end
    if x     ~= nil then put(w, putF32(x)) end
    if y     ~= nil then put(w, putF32(y)) end
    if angle ~= nil then put(w, putF32(angle)) end
    if c     ~= nil then encodeComponents(st, c) end
end

local function encodeBody(snapshot)
    if type(snapshot) ~= 'table' then
        error('snapcodec: a snapshot body is not a table', 0)
    end

    for key in pairs(snapshot) do
        if not SNAPSHOT_KEYS[key] then
            error(('snapcodec: snapshot body carries %q, which the snapshot '
                   .. 'layout does not model'):format(tostring(key)), 0)
        end
    end

    local tick = snapshot.tick or 0
    if type(tick) ~= 'number' or tick % 1 ~= 0 or tick < 0 or tick >= MAX_UINT then
        error('snapcodec: a tick is not a whole non-negative number', 0)
    end

    -- A body with no `full` key is a keyframe. Every fixture, tool and older
    -- caller in the tree builds { tick, e } and means "here is everything", so
    -- that has to keep meaning what it always did; a partial is the frame that
    -- has to say so.
    local full = snapshot.full
    if full ~= nil and type(full) ~= 'boolean' then
        error('snapcodec: the keyframe flag is not a boolean', 0)
    end
    full = full ~= false

    local removed = snapshot.r or EMPTY
    if type(removed) ~= 'table' then
        error('snapcodec: the removal list is not a table', 0)
    end
    local removedCount = 0
    for _ in pairs(removed) do removedCount = removedCount + 1 end
    if removedCount ~= #removed then
        error('snapcodec: the removal list is not a plain array', 0)
    end
    if full and removedCount > 0 then
        error('snapcodec: a keyframe carries ' .. removedCount .. ' removal(s), and '
              .. 'in a keyframe an absent id is already a removed one', 0)
    end

    local list = snapshot.e or EMPTY
    if type(list) ~= 'table' then
        error('snapcodec: the entity list is not a table', 0)
    end

    local n = #list
    local count = 0
    for _ in pairs(list) do count = count + 1 end
    if count ~= n then
        error('snapcodec: the entity list is not a plain array', 0)
    end

    -- Entities first, because encoding them is what discovers the strings; the
    -- header is assembled afterwards and prepended, so a decoder still meets the
    -- string table before the first reference to it.
    local w, put, done = newWriter()
    local st = { w = w, put = put, strings = {}, index = {}, count = 0 }

    for i = 1, n do encodeEntity(st, list[i]) end

    -- Removals ride at the end of the body rather than in the header, because
    -- they are the one part that needs no string table and therefore no second
    -- pass. A keyframe writes nothing here at all, not even a zero count.
    if not full then
        putUInt(put, w, removedCount)
        for i = 1, removedCount do
            local id = removed[i]
            if type(id) ~= 'number' or id % 1 ~= 0 or id < 0 or id >= MAX_UINT then
                error('snapcodec: a removed id is not a whole non-negative number', 0)
            end
            putUInt(put, w, id)
        end
    end

    local body = done(w)

    local hw, hput, hdone = newWriter()
    hput(hw, CHAR[MAGIC])
    hput(hw, CHAR[VERSION])
    hput(hw, CHAR[full and 1 or 0])
    putUInt(hput, hw, tick)
    putUInt(hput, hw, st.count)
    for i = 1, st.count do
        local s = st.strings[i]
        putUInt(hput, hw, #s)
        hput(hw, s)
    end
    putUInt(hput, hw, n)

    return hdone(hw) .. body
end

-- Encodes a snapshot body. Returns the bytes, or nil plus a reason when the body
-- is a shape this layout does not model — which is not a failure so much as a
-- routing decision: the caller sends it through the text serializer instead and
-- pays bytes rather than losing a field. Never raises.
function Codec.encode(snapshot)
    local ok, result = pcall(encodeBody, snapshot)
    if ok then return result end
    return nil, tostring(result)
end

---------------------------------------------------------------------------
-- Decoding
---------------------------------------------------------------------------

local function readUInt(s, i)
    local v, scale = 0, 1
    for _ = 1, 8 do
        local b = byte(s, i)
        if not b then
            error('snapcodec: input ended inside a number at byte ' .. i, 0)
        end
        i = i + 1
        v = v + (b % 128) * scale
        if b < 128 then
            if v >= MAX_UINT then
                error('snapcodec: a number is beyond 2^53 at byte ' .. i, 0)
            end
            return v, i
        end
        scale = scale * 128
    end
    error('snapcodec: a number runs past eight bytes at byte ' .. i, 0)
end

-- Every element of an array, map or entity list costs at least one byte, so a
-- count larger than the bytes remaining is a lie. Checking it here turns a
-- hostile "one billion entries" header into an immediate rejection instead of a
-- billion-iteration loop that fails at the end.
local function boundedCount(n, s, i, what)
    if n > (#s - i + 1) then
        error(('snapcodec: %s claims %d entries but only %d bytes remain')
              :format(what, n, #s - i + 1), 0)
    end
    return n
end

local decodeValue

decodeValue = function(st, s, i, depth)
    if depth > MAX_DEPTH then
        error('snapcodec: input nests deeper than ' .. MAX_DEPTH .. ' levels', 0)
    end

    local tag = byte(s, i)
    if not tag then
        error('snapcodec: input ended mid-value at byte ' .. i, 0)
    end
    i = i + 1

    if tag == T_NIL then
        return nil, i

    elseif tag == T_FALSE then
        return false, i

    elseif tag == T_TRUE then
        return true, i

    elseif tag == T_UINT then
        return readUInt(s, i)

    elseif tag == T_NINT then
        local v, nexti = readUInt(s, i)
        return -v, nexti

    elseif tag == T_F32 then
        if i + 3 > #s then error('snapcodec: input ended inside a float at byte ' .. i, 0) end
        return getF32(s, i), i + 4

    elseif tag == T_F64 then
        if i + 7 > #s then error('snapcodec: input ended inside a double at byte ' .. i, 0) end
        return getF64(s, i), i + 8

    elseif tag == T_STR then
        local at, nexti = readUInt(s, i)
        local value = st.strings[at]
        if value == nil then
            error(('snapcodec: string reference %d has no entry at byte %d')
                  :format(at, i), 0)
        end
        return value, nexti

    elseif tag == T_ARRAY then
        local n, nexti = readUInt(s, i)
        boundedCount(n, s, nexti, 'an array')
        local t = {}
        for k = 1, n do t[k], nexti = decodeValue(st, s, nexti, depth + 1) end
        return t, nexti

    elseif tag == T_MAP then
        local n, nexti = readUInt(s, i)
        boundedCount(n, s, nexti, 'a map')
        local t = {}
        for _ = 1, n do
            local key, value
            key, nexti = decodeValue(st, s, nexti, depth + 1)
            value, nexti = decodeValue(st, s, nexti, depth + 1)
            if key ~= nil then t[key] = value end
        end
        return t, nexti
    end

    error(('snapcodec: unknown value tag %d at byte %d'):format(tag, i - 1), 0)
end

local function decodeComponents(st, s, i)
    local n
    n, i = readUInt(s, i)
    boundedCount(n, s, i, 'a component list')

    local out = {}
    for _ = 1, n do
        local at
        at, i = readUInt(s, i)
        local name = st.strings[at]
        if name == nil then
            error(('snapcodec: component name reference %d has no entry'):format(at), 0)
        end

        local count
        count, i = readUInt(s, i)
        boundedCount(count, s, i, 'a field list')

        local fields = {}
        for _ = 1, count do
            local ref
            ref, i = readUInt(s, i)
            local key = st.strings[ref]
            if key == nil then
                error(('snapcodec: field name reference %d has no entry'):format(ref), 0)
            end
            fields[key], i = decodeValue(st, s, i, 1)
        end

        out[name] = fields
    end

    return out, i
end

local function decodeBody(s)
    if byte(s, 1) ~= MAGIC then
        error('snapcodec: not a binary snapshot body', 0)
    end

    local version = byte(s, 2)
    if version ~= VERSION then
        error(('snapcodec: body is format version %s, this build speaks %d')
              :format(tostring(version), VERSION), 0)
    end

    local header = byte(s, 3)
    if not header then
        error('snapcodec: input ended before the header flag byte', 0)
    end
    -- Refused rather than masked off: an undefined bit means the sender is
    -- describing a frame kind this build does not have, and reading the rest as
    -- if it were a keyframe would produce a plausible-looking wrong world.
    if header >= 2 then
        error(('snapcodec: header sets undefined flag bits (%d)'):format(header), 0)
    end
    local full = header % 2 == 1

    local st = { strings = {} }
    local i = 4

    local tick
    tick, i = readUInt(s, i)

    local stringCount
    stringCount, i = readUInt(s, i)
    boundedCount(stringCount, s, i, 'a string table')

    for k = 1, stringCount do
        local len
        len, i = readUInt(s, i)
        if i + len - 1 > #s then
            error(('snapcodec: string %d claims %d bytes but only %d remain')
                  :format(k, len, #s - i + 1), 0)
        end
        st.strings[k] = sub(s, i, i + len - 1)
        i = i + len
    end

    local entityCount
    entityCount, i = readUInt(s, i)
    boundedCount(entityCount, s, i, 'an entity list')

    local list = {}
    for k = 1, entityCount do
        local id
        id, i = readUInt(s, i)

        local flags = byte(s, i)
        if not flags then
            error('snapcodec: input ended before an entity flag byte', 0)
        end
        i = i + 1

        -- Refused before anything is read from them: an undefined bit means the
        -- sender is describing a layout this build does not have, and guessing at
        -- the rest of the entity would produce a plausible-looking wrong answer.
        if flags >= 32 then
            error(('snapcodec: entity %d sets undefined flag bits (%d)'):format(k, flags), 0)
        end

        local snap = { id = id }

        if flags % 2 == 1 then
            local at
            at, i = readUInt(s, i)
            local kind = st.strings[at]
            if kind == nil then
                error(('snapcodec: kind reference %d has no entry'):format(at), 0)
            end
            snap.kind = kind
        end

        if floor(flags / FLAG_X) % 2 == 1 then
            if i + 3 > #s then error('snapcodec: input ended inside a position', 0) end
            snap.x, i = getF32(s, i), i + 4
        end
        if floor(flags / FLAG_Y) % 2 == 1 then
            if i + 3 > #s then error('snapcodec: input ended inside a position', 0) end
            snap.y, i = getF32(s, i), i + 4
        end
        if floor(flags / FLAG_ANGLE) % 2 == 1 then
            if i + 3 > #s then error('snapcodec: input ended inside an angle', 0) end
            snap.angle, i = getF32(s, i), i + 4
        end
        if floor(flags / FLAG_C) % 2 == 1 then
            snap.c, i = decodeComponents(st, s, i)
        end

        list[k] = snap
    end

    local removed
    if not full then
        local removedCount
        removedCount, i = readUInt(s, i)
        boundedCount(removedCount, s, i, 'a removal list')

        removed = {}
        for k = 1, removedCount do
            removed[k], i = readUInt(s, i)
        end
    end

    if i <= #s then
        error(('snapcodec: %d trailing byte(s) after the snapshot')
              :format(#s - i + 1), 0)
    end

    return { tick = tick, e = list, full = full, r = removed }
end

-- Decodes a body produced by Codec.encode. Returns the body, or nil plus a
-- reason — never raises, because a malformed packet on a public port is an
-- expected event and the service loop must not have to survive it.
function Codec.decode(s)
    if type(s) ~= 'string' then return nil, 'snapcodec: expected a string' end
    local ok, value = pcall(decodeBody, s)
    if not ok then return nil, tostring(value) end
    return value
end

-- Whether a body was written by this codec rather than the text serializer.
function Codec.isBinary(s)
    return type(s) == 'string' and byte(s, 1) == MAGIC
end

---------------------------------------------------------------------------
-- Exposed for the tests, and for anyone measuring
---------------------------------------------------------------------------

Codec.floatCodecs = {
    lua = { putF32 = luaPutF32, getF32 = luaGetF32,
            putF64 = luaPutF64, getF64 = luaGetF64 },
    ffi = ffiPutF32 and { putF32 = ffiPutF32, getF32 = ffiGetF32,
                          putF64 = ffiPutF64, getF64 = ffiGetF64 } or nil,
}

return Codec
