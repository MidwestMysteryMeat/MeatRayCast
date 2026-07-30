--[[
    meatray.net.serialize — turning Lua values into wire bytes and back.

    Every message on every transport goes through here, so the format is the one
    thing the whole net stack agrees on. Three properties matter and nothing else
    does:

      1. It round-trips exactly. Numbers are written with %.17g, which is the
         shortest form that reads back as the identical double, so a position
         does not drift by a bit each hop. Non-finite values are named rather
         than emitted as "inf", because tonumber('inf') is nil in LuaJIT and a
         silently-nil coordinate is far worse than a visible one.
      2. It is self-delimiting. Strings carry a length, so they may contain any
         byte including the format's own punctuation. There is no escaping and
         therefore no escaping bug.
      3. It refuses what it cannot represent. Functions, userdata and cyclic
         tables raise instead of producing something that decodes to nonsense —
         a snapshot containing a closure is a bug in a netFields declaration and
         should be loud.

    Format, one tag byte then a payload:

        -               nil
        +   /           true, false
        #<repr>;        number
        $<len>:<bytes>  string
        [<n>:v1..vn]    table that is exactly an array of n values
        {kv kv ...}     table as key/value pairs

    The array form exists for one reason: a world grid is a few thousand
    integers, and paying six bytes of key per tile to say "1", "2", "3" is the
    difference between a join payload of 20 KB and one of 5 KB.

    HEADLESS: no LOVE anywhere. This is deliberately plain Lua so replication is
    testable with no sockets and no window.
]]

local Serialize = {}

local format = string.format
local sub, find = string.sub, string.find
local concat = table.concat
local huge = math.huge

-- 32 is far deeper than any snapshot; hitting it means a cycle or a mistake.
local MAX_DEPTH = 32

local NON_FINITE = { nan = 0 / 0, inf = huge, ['-inf'] = -huge }

local function numberToString(v)
    if v ~= v then return 'nan' end
    if v == huge then return 'inf' end
    if v == -huge then return '-inf' end
    return format('%.17g', v)
end

---------------------------------------------------------------------------
-- Encoding
---------------------------------------------------------------------------

local function encodeValue(v, out, depth)
    if depth > MAX_DEPTH then
        error('serialize: value nests deeper than ' .. MAX_DEPTH
              .. ' levels (a cycle?)', 0)
    end

    local kind = type(v)

    if v == nil then
        out[#out + 1] = '-'

    elseif kind == 'boolean' then
        out[#out + 1] = v and '+' or '/'

    elseif kind == 'number' then
        out[#out + 1] = '#'
        out[#out + 1] = numberToString(v)
        out[#out + 1] = ';'

    elseif kind == 'string' then
        out[#out + 1] = '$'
        out[#out + 1] = format('%d', #v)
        out[#out + 1] = ':'
        out[#out + 1] = v

    elseif kind == 'table' then
        -- A table is written in array form only when its entry count equals its
        -- length, which is exactly the case where keys 1..n and nothing else are
        -- present. Anything with a hole falls through to the map form, where the
        -- keys are explicit and no guess is being made.
        local n = #v
        local count = 0
        for _ in pairs(v) do count = count + 1 end

        if count == n then
            out[#out + 1] = '['
            out[#out + 1] = format('%d', n)
            out[#out + 1] = ':'
            for i = 1, n do encodeValue(v[i], out, depth + 1) end
            out[#out + 1] = ']'
        else
            out[#out + 1] = '{'
            for key, value in pairs(v) do
                encodeValue(key, out, depth + 1)
                encodeValue(value, out, depth + 1)
            end
            out[#out + 1] = '}'
        end

    else
        error('serialize: cannot encode a ' .. kind
              .. ' (netFields should only name plain data)', 0)
    end
end

-- Encodes a value to a string. Raises on anything unrepresentable; callers that
-- must not fail should use Serialize.tryEncode.
function Serialize.encode(value)
    local out = {}
    encodeValue(value, out, 1)
    return concat(out)
end

function Serialize.tryEncode(value)
    local ok, result = pcall(Serialize.encode, value)
    if ok then return result end
    return nil, result
end

---------------------------------------------------------------------------
-- Decoding
---------------------------------------------------------------------------

-- The depth limit applies to decoding as well as encoding, and for a different
-- reason. Encoding hits it on a cycle, which is a bug in a netFields declaration.
-- Decoding hits it on `[1:[1:[1:...` — thirty bytes of hostile packet per level,
-- with the recursion running on the C stack. Bounding it here means the cost of a
-- malformed packet is a rejection rather than a stack overflow that the caller's
-- pcall has to be trusted to survive.
local function decodeValue(s, i, depth)
    depth = depth or 1
    if depth > MAX_DEPTH then
        error('serialize: input nests deeper than ' .. MAX_DEPTH .. ' levels', 0)
    end

    local tag = sub(s, i, i)

    if tag == '' then
        error('serialize: input ended mid-value at byte ' .. i, 0)

    elseif tag == '-' then
        return nil, i + 1

    elseif tag == '+' then
        return true, i + 1

    elseif tag == '/' then
        return false, i + 1

    elseif tag == '#' then
        local stop = find(s, ';', i + 1, true)
        if not stop then error('serialize: unterminated number at byte ' .. i, 0) end
        local raw = sub(s, i + 1, stop - 1)
        local v = NON_FINITE[raw]
        if v == nil then v = tonumber(raw) end
        if v == nil then error('serialize: "' .. raw .. '" is not a number', 0) end
        return v, stop + 1

    elseif tag == '$' then
        local colon = find(s, ':', i + 1, true)
        if not colon then error('serialize: unterminated string at byte ' .. i, 0) end
        local len = tonumber(sub(s, i + 1, colon - 1))
        if not len or len < 0 then error('serialize: bad string length at byte ' .. i, 0) end
        local stop = colon + len
        if stop > #s then error('serialize: string claims ' .. len .. ' bytes but only '
                                .. (#s - colon) .. ' remain', 0) end
        return sub(s, colon + 1, stop), stop + 1

    elseif tag == '[' then
        local colon = find(s, ':', i + 1, true)
        if not colon then error('serialize: unterminated array at byte ' .. i, 0) end
        local n = tonumber(sub(s, i + 1, colon - 1))
        if not n or n < 0 then error('serialize: bad array length at byte ' .. i, 0) end
        local t, p = {}, colon + 1
        for k = 1, n do t[k], p = decodeValue(s, p, depth + 1) end
        if sub(s, p, p) ~= ']' then error('serialize: array not closed at byte ' .. p, 0) end
        return t, p + 1

    elseif tag == '{' then
        local t, p = {}, i + 1
        while true do
            local here = sub(s, p, p)
            if here == '}' then break end
            if here == '' then error('serialize: table not closed', 0) end
            local key, value
            key, p = decodeValue(s, p, depth + 1)
            value, p = decodeValue(s, p, depth + 1)
            if key ~= nil then t[key] = value end
        end
        return t, p + 1
    end

    error('serialize: unknown tag "' .. tag .. '" at byte ' .. i, 0)
end

-- Decodes a string produced by encode. Returns the value, or nil plus a message
-- when the input is malformed — which is the normal case for a packet from a
-- hostile or mismatched peer, so it must never raise into the service loop.
function Serialize.decode(s)
    if type(s) ~= 'string' then return nil, 'serialize: expected a string' end

    local ok, value, rest = pcall(decodeValue, s, 1, 1)
    if not ok then return nil, tostring(value) end
    if rest <= #s then
        return nil, ('serialize: %d trailing byte(s) after the value'):format(#s - rest + 1)
    end
    return value
end

Serialize.MAX_DEPTH = MAX_DEPTH

return Serialize
