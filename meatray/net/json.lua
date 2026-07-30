--[[
    meatray.net.json — enough JSON for the registry protocol, and no more.

    Written rather than vendored because the registry's whole dependency story is
    "a file and a Lua interpreter". A registry anyone can run is the point; one
    that needs a package manager first is a registry most people will not run.

    The awkward part of JSON in Lua is not parsing, it is that one Lua type has
    to become two JSON types. `{}` is both an empty array and an empty object,
    and guessing wrong matters on a wire: a client that receives `{}` where it
    expected `[]` for an empty server list either crashes or shows a broken UI,
    and the case only happens when nobody is hosting -- which is exactly the
    moment a new player first opens the browser.

    So emptiness is explicit. `json.array(t)` marks a table as an array
    regardless of content, and an unmarked empty table encodes as `{}`. The
    registry marks its list, so an empty list is `[]` every time rather than
    only when it happens to be non-empty.

    Decoding is strict: trailing data, unterminated strings and bad escapes are
    errors rather than best guesses. This parses input from the internet, and
    a parser that tries to be helpful about malformed input is a parser that
    disagrees with the next parser about what the input meant.

    HEADLESS: no love, no socket, no os.
]]

local json = {}

local ARRAY_MT = { __jsonarray = true }

-- Marks a table as a JSON array. Needed only for tables that may be empty;
-- a table with 1..n integer keys is detected without it.
function json.array(t)
    return setmetatable(t or {}, ARRAY_MT)
end

function json.isArray(t)
    if getmetatable(t) == ARRAY_MT then return true end
    if next(t) == nil then return false end        -- empty and unmarked: object

    local n = 0
    for k in pairs(t) do
        if type(k) ~= 'number' then return false end
        if k ~= math.floor(k) or k < 1 then return false end
        n = n + 1
    end
    return n == #t
end

-- A distinct null, because nil cannot live in a Lua table and dropping the key
-- silently is how a field goes missing without anyone noticing.
json.null = setmetatable({}, { __tostring = function() return 'null' end })

---------------------------------------------------------------------------
-- Encoding
---------------------------------------------------------------------------

local ESCAPES = {
    ['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b', ['\f'] = '\\f',
    ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t',
}

local function escapeString(s)
    return (s:gsub('[%c"\\]', function(c)
        return ESCAPES[c] or ('\\u%04x'):format(c:byte())
    end))
end

local function encodeNumber(n)
    if n ~= n or n == math.huge or n == -math.huge then
        -- JSON has no way to say these. Refusing beats emitting `nan`, which is
        -- not JSON and which the receiving parser will reject anyway -- better
        -- to fail on the side that still has the context to say what happened.
        error('cannot encode ' .. tostring(n) .. ' as JSON', 0)
    end
    if n == math.floor(n) and math.abs(n) < 1e15 then
        return ('%d'):format(n)
    end
    return ('%.14g'):format(n)
end

local encodeValue

local function encodeTable(value, out, depth)
    if depth > 64 then error('JSON nesting too deep', 0) end

    if json.isArray(value) then
        out[#out + 1] = '['
        for i = 1, #value do
            if i > 1 then out[#out + 1] = ',' end
            encodeValue(value[i], out, depth + 1)
        end
        out[#out + 1] = ']'
        return
    end

    -- Keys sorted, so the same table always encodes to the same bytes. That
    -- makes responses cacheable and diffable, and makes a test able to compare
    -- output rather than re-parse it.
    local keys = {}
    for k in pairs(value) do
        if type(k) ~= 'string' and type(k) ~= 'number' then
            error('JSON object keys must be strings or numbers', 0)
        end
        keys[#keys + 1] = tostring(k)
    end
    table.sort(keys)

    out[#out + 1] = '{'
    for i, k in ipairs(keys) do
        if i > 1 then out[#out + 1] = ',' end
        out[#out + 1] = '"' .. escapeString(k) .. '":'

        -- Written long-hand rather than as `a ~= nil and a or b`. That idiom
        -- silently yields b whenever a is `false`, so a false value encodes as
        -- null -- and since json.null is a table, and every table is truthy in
        -- Lua, the receiver reads it back as true. `locked = false` arriving as
        -- "locked" is the kind of bug that survives a long time.
        local v = value[k]
        if v == nil then v = value[tonumber(k)] end
        encodeValue(v, out, depth + 1)
    end
    out[#out + 1] = '}'
end

encodeValue = function(value, out, depth)
    local kind = type(value)

    if value == json.null or value == nil then
        out[#out + 1] = 'null'
    elseif kind == 'boolean' then
        out[#out + 1] = value and 'true' or 'false'
    elseif kind == 'number' then
        out[#out + 1] = encodeNumber(value)
    elseif kind == 'string' then
        out[#out + 1] = '"' .. escapeString(value) .. '"'
    elseif kind == 'table' then
        encodeTable(value, out, depth)
    else
        error('cannot encode a ' .. kind .. ' as JSON', 0)
    end
end

-- Returns the string, or nil plus a message. Never raises: this runs on input
-- shaped by a remote peer, and a registry that dies encoding its own reply is a
-- registry that can be killed by a request.
function json.encode(value)
    local out = {}
    local ok, err = pcall(encodeValue, value, out, 0)
    if not ok then return nil, tostring(err) end
    return table.concat(out)
end

---------------------------------------------------------------------------
-- Decoding
---------------------------------------------------------------------------

local Parser = {}
Parser.__index = Parser

function Parser:error(msg)
    error(('%s at byte %d'):format(msg, self.pos), 0)
end

function Parser:skipSpace()
    local _, stop = self.src:find('^[ \t\r\n]*', self.pos)
    self.pos = stop + 1
end

function Parser:expect(char)
    if self.src:sub(self.pos, self.pos) ~= char then
        self:error(("expected '%s'"):format(char))
    end
    self.pos = self.pos + 1
end

local UNESCAPES = {
    ['"'] = '"', ['\\'] = '\\', ['/'] = '/', b = '\b',
    f = '\f', n = '\n', r = '\r', t = '\t',
}

function Parser:parseString()
    self:expect('"')
    local out = {}

    while true do
        local c = self.src:sub(self.pos, self.pos)
        if c == '' then self:error('unterminated string') end

        if c == '"' then
            self.pos = self.pos + 1
            return table.concat(out)
        end

        if c == '\\' then
            local esc = self.src:sub(self.pos + 1, self.pos + 1)
            if esc == 'u' then
                local hex = self.src:sub(self.pos + 2, self.pos + 5)
                if not hex:match('^%x%x%x%x$') then self:error('bad \\u escape') end
                local code = tonumber(hex, 16)
                -- Only the BMP below the surrogate range is decoded to UTF-8.
                -- Surrogate pairs are left as the replacement character rather
                -- than half-decoded, since a lone surrogate in a server name is
                -- not worth the code to reassemble.
                if code < 0x80 then
                    out[#out + 1] = string.char(code)
                elseif code < 0x800 then
                    out[#out + 1] = string.char(0xC0 + math.floor(code / 0x40),
                                                0x80 + (code % 0x40))
                elseif code >= 0xD800 and code <= 0xDFFF then
                    out[#out + 1] = '\239\191\189'
                else
                    out[#out + 1] = string.char(0xE0 + math.floor(code / 0x1000),
                                                0x80 + (math.floor(code / 0x40) % 0x40),
                                                0x80 + (code % 0x40))
                end
                self.pos = self.pos + 6
            else
                local plain = UNESCAPES[esc]
                if not plain then self:error('bad escape \\' .. esc) end
                out[#out + 1] = plain
                self.pos = self.pos + 2
            end
        else
            out[#out + 1] = c
            self.pos = self.pos + 1
        end
    end
end

function Parser:parseNumber()
    local text = self.src:match('^-?%d+%.?%d*[eE]?[-+]?%d*', self.pos)
    if not text or text == '' then self:error('bad number') end
    local n = tonumber(text)
    if not n then self:error('bad number') end
    self.pos = self.pos + #text
    return n
end

function Parser:parseValue(depth)
    if depth > 64 then self:error('nesting too deep') end
    self:skipSpace()

    local c = self.src:sub(self.pos, self.pos)

    if c == '"' then return self:parseString() end
    if c == '{' then return self:parseObject(depth) end
    if c == '[' then return self:parseArray(depth) end
    if c == '-' or c:match('%d') then return self:parseNumber() end

    if self.src:sub(self.pos, self.pos + 3) == 'true' then
        self.pos = self.pos + 4; return true
    end
    if self.src:sub(self.pos, self.pos + 4) == 'false' then
        self.pos = self.pos + 5; return false
    end
    if self.src:sub(self.pos, self.pos + 3) == 'null' then
        self.pos = self.pos + 4; return json.null
    end

    self:error('unexpected input')
end

function Parser:parseObject(depth)
    self:expect('{')
    local out = {}

    self:skipSpace()
    if self.src:sub(self.pos, self.pos) == '}' then
        self.pos = self.pos + 1
        return out
    end

    while true do
        self:skipSpace()
        local key = self:parseString()
        self:skipSpace()
        self:expect(':')
        out[key] = self:parseValue(depth + 1)
        self:skipSpace()

        local c = self.src:sub(self.pos, self.pos)
        if c == ',' then
            self.pos = self.pos + 1
        elseif c == '}' then
            self.pos = self.pos + 1
            return out
        else
            self:error('expected , or }')
        end
    end
end

function Parser:parseArray(depth)
    self:expect('[')
    local out = json.array{}

    self:skipSpace()
    if self.src:sub(self.pos, self.pos) == ']' then
        self.pos = self.pos + 1
        return out
    end

    while true do
        out[#out + 1] = self:parseValue(depth + 1)
        self:skipSpace()

        local c = self.src:sub(self.pos, self.pos)
        if c == ',' then
            self.pos = self.pos + 1
        elseif c == ']' then
            self.pos = self.pos + 1
            return out
        else
            self:error('expected , or ]')
        end
    end
end

-- Returns the value, or nil plus a message. Strict about trailing data: input
-- that continues past a complete value is malformed, and accepting it means two
-- parsers can disagree about what a request said.
function json.decode(text)
    if type(text) ~= 'string' then return nil, 'input must be a string' end
    if #text == 0 then return nil, 'empty input' end

    local parser = setmetatable({ src = text, pos = 1 }, Parser)

    local ok, result = pcall(parser.parseValue, parser, 0)
    if not ok then return nil, tostring(result) end

    parser:skipSpace()
    if parser.pos <= #text then
        return nil, ('trailing data at byte %d'):format(parser.pos)
    end

    return result
end

return json
