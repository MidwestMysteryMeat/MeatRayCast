--[[
    meatray.sim.demo — deterministic demo recording and playback (F1).

    A demo is not a video. It is the seed the world was built from and the
    complete stream of intent — per-tick input plus tick-stamped events — that
    was fed into a simulation whose every other source of change is already
    deterministic (the engine LCG, per-weapon spread seeds, the fixed tick).
    Replaying the stream into a world built from the same seed reproduces the
    session; that is the whole file format.

        -- recording, on the fixed tick:
        local rec = Demo.record{ rate = 60, source = 'procedural', seed = 90599143 }
        rec:frame(tick, input)              -- input BEFORE it is applied
        rec:event(tick, 'fire', { angle = 0.42 })
        rec:checkpoint(tick, Demo.checksum(entities))
        local text = rec:finish(lastTick)

        -- playback:
        local play = Demo.load(text)
        for tick = 0, play:length() - 1 do
            local input  = play:inputAt(tick)
            local events = play:eventsAt(tick)   -- nil most ticks
            ... apply events, then input, then simulate one step ...
            local ok, want, got = play:verify(tick, entities)
        end

    Storage is delta-encoded: a tick appears in the file only when its input
    differs from the previous tick's, or it carries events or a checkpoint.
    Holding a key for ten seconds is one line, not six hundred. Numbers are
    written with %.17g so a float (the aim angle) comes back bit-identical —
    a demo that rounds its angles is a demo that diverges.

    Checkpoints are the forensics half. `Demo.checksum` folds every entity's
    id, position, angle and hp into 8 hex characters; a recording sprinkles
    them in, and playback's `verify` names the FIRST tick where the two runs
    disagree — which is where a desync hunt wants to start, not at the end
    where everything is already wrong.

    What this file does not promise: a client's view of a networked session is
    not deterministic (snapshots arrive when they arrive), so demos record the
    authoritative loop — solo or host. And anything outside the stream that
    consults a wall clock or math.random is out of scope by definition; the
    engine keeps both out of the sim, which is what makes this module small.

    HEADLESS: pure Lua.
]]

local Demo = {}

Demo.MAGIC = 'meatdemo'
Demo.VERSION = 1

local floor = math.floor
local format = string.format

---------------------------------------------------------------------------
-- Number formatting: exact round-trips
---------------------------------------------------------------------------

-- %.17g is the shortest printf format guaranteed to round-trip an IEEE
-- double. Integers are written as integers so the file stays readable.
local function num(v)
    if v == floor(v) and math.abs(v) < 2 ^ 53 then
        return format('%d', v)
    end
    return format('%.17g', v)
end

---------------------------------------------------------------------------
-- Field lists
---------------------------------------------------------------------------

-- The input fields a demo carries, in a fixed order so serialization is
-- stable. `angle` may be nil (absent aim is meaningful to Rep.applyInput),
-- which is why comparison and encoding both treat nil as its own value.
Demo.INPUT_FIELDS = { 'forward', 'strafe', 'turn', 'angle' }

local function copyInput(input)
    local out = {}
    for _, k in ipairs(Demo.INPUT_FIELDS) do
        local v = input and input[k]
        if v ~= nil then out[k] = tonumber(v) end
    end
    return out
end

local function sameInput(a, b)
    for _, k in ipairs(Demo.INPUT_FIELDS) do
        if (a and a[k]) ~= (b and b[k]) then return false end
    end
    return true
end

---------------------------------------------------------------------------
-- Checksums
---------------------------------------------------------------------------

-- LuaJIT ships `bit`, and the suite runs on LuaJIT by the engine's own rule;
-- the arithmetic fallback keeps the module loadable under plain Lua.
local okBit, bit = pcall(require, 'bit')
local bxor32
if okBit and bit then
    bxor32 = bit.bxor
else
    bxor32 = function(a, b)
        local out, p = 0, 1
        for _ = 1, 32 do
            local abit, bbit = a % 2, b % 2
            if abit ~= bbit then out = out + p end
            a, b, p = (a - abit) / 2, (b - bbit) / 2, p * 2
        end
        return out
    end
end

-- FNV-1a over a quantized view of every entity, folded in entity id order so
-- the array's incidental ordering cannot change the answer. Positions are
-- quantized to 1/1024 of a tile: coarse enough to ignore formatting, fine
-- enough that a real divergence (a shot that hit in one run and missed in the
-- other) moves it immediately. Returns 8 hex characters.
function Demo.checksum(entities)
    local rows = {}
    for i = 1, #(entities or {}) do
        local e = entities[i]
        if type(e) == 'table' and e.id and not e.localOnly then
            local hp = ''
            if e.get then
                local ok, health = pcall(e.get, e, 'health')
                if ok and health and health.hp then hp = tostring(health.hp) end
            end
            rows[#rows + 1] = {
                id = e.id,
                line = format('%s:%d:%d:%d:%s:%s',
                    tostring(e.id),
                    floor((e.x or 0) * 1024 + 0.5),
                    floor((e.y or 0) * 1024 + 0.5),
                    floor((e.angle or 0) * 1024 + 0.5),
                    e.dead and 'd' or 'a',
                    hp),
            }
        end
    end
    table.sort(rows, function(a, b) return a.id < b.id end)

    local hash = 2166136261
    for i = 1, #rows do
        local s = rows[i].line
        for c = 1, #s do
            hash = (bxor32(hash, s:byte(c)) * 16777619) % 4294967296
        end
    end
    return format('%08x', hash)
end

---------------------------------------------------------------------------
-- Recording
---------------------------------------------------------------------------

local RecMT = {}
RecMT.__index = RecMT

-- opts: rate (ticks/second, default 60), source ('procedural'|'authored'),
-- seed (number, procedural), map (path, authored), name (free text).
function Demo.record(opts)
    opts = opts or {}
    return setmetatable({
        rate = opts.rate or 60,
        source = opts.source or 'procedural',
        seed = opts.seed,
        map = opts.map,
        name = opts.name,

        lastInput = nil,       -- previous tick's input, for delta encoding
        ticks = {},            -- [tick] = { input = , events = {}, check = }
        order = {},            -- tick numbers that hold anything, ascending
        lastTick = -1,
    }, RecMT)
end

local function slot(self, tick)
    tick = floor(tonumber(tick) or 0)
    local t = self.ticks[tick]
    if not t then
        t = {}
        self.ticks[tick] = t
        self.order[#self.order + 1] = tick
    end
    if tick > self.lastTick then self.lastTick = tick end
    return t
end

-- The input about to be applied on `tick`. Recorded only when it changed —
-- callers just call this every tick and the file stays small.
function RecMT:frame(tick, input)
    local snap = copyInput(input)
    if self.lastInput and sameInput(snap, self.lastInput) then
        self.lastTick = math.max(self.lastTick, floor(tonumber(tick) or 0))
        return false
    end
    slot(self, tick).input = snap
    self.lastInput = snap
    return true
end

-- A tick-stamped action outside the movement stream: a shot, a door, a swap.
-- `params` is a flat table of numbers and strings.
function RecMT:event(tick, name, params)
    local t = slot(self, tick)
    t.events = t.events or {}
    local ev = { name = tostring(name) }
    for k, v in pairs(params or {}) do
        if type(v) == 'number' or type(v) == 'string' then ev[k] = v end
    end
    t.events[#t.events + 1] = ev
    return ev
end

function RecMT:checkpoint(tick, checksum)
    slot(self, tick).check = tostring(checksum)
    return true
end

-- Closes the recording and returns the file text. `lastTick` stretches the
-- demo to its true length: a minute of standing still after the last change
-- is still a minute of demo.
function RecMT:finish(lastTick)
    if lastTick then self.lastTick = math.max(self.lastTick, floor(lastTick)) end
    table.sort(self.order)

    local out = {
        format('%s %d', Demo.MAGIC, Demo.VERSION),
        'rate ' .. num(self.rate),
        'source ' .. tostring(self.source),
    }
    if self.seed then out[#out + 1] = 'seed ' .. num(self.seed) end
    if self.map then out[#out + 1] = 'map ' .. tostring(self.map) end
    if self.name then out[#out + 1] = 'name ' .. tostring(self.name) end
    out[#out + 1] = '---'

    for _, tick in ipairs(self.order) do
        local t = self.ticks[tick]
        out[#out + 1] = 't ' .. tick
        if t.input then
            local parts = { 'i' }
            for _, k in ipairs(Demo.INPUT_FIELDS) do
                if t.input[k] ~= nil then
                    parts[#parts + 1] = k .. '=' .. num(t.input[k])
                end
            end
            out[#out + 1] = table.concat(parts, ' ')
        end
        for _, ev in ipairs(t.events or {}) do
            local parts = { 'e', ev.name }
            local keys = {}
            for k in pairs(ev) do
                if k ~= 'name' then keys[#keys + 1] = k end
            end
            table.sort(keys)
            for _, k in ipairs(keys) do
                local v = ev[k]
                parts[#parts + 1] = k .. '='
                    .. (type(v) == 'number' and num(v) or tostring(v))
            end
            out[#out + 1] = table.concat(parts, ' ')
        end
        if t.check then
            out[#out + 1] = 'c ' .. t.check
        end
    end

    out[#out + 1] = 'end ' .. math.max(0, self.lastTick + 1)
    return table.concat(out, '\n') .. '\n'
end

---------------------------------------------------------------------------
-- Playback
---------------------------------------------------------------------------

local PlayMT = {}
PlayMT.__index = PlayMT

local function parseValue(s)
    local n = tonumber(s)
    if n ~= nil then return n end
    return s
end

function Demo.load(text)
    if type(text) ~= 'string' then return nil, 'demo must be a string' end

    local lines = {}
    for line in (text .. '\n'):gmatch('([^\n]*)\n') do
        lines[#lines + 1] = (line:gsub('\r$', ''))
    end

    local magic, version = (lines[1] or ''):match('^(%S+)%s+(%d+)$')
    if magic ~= Demo.MAGIC then
        return nil, 'not a demo file (bad magic)'
    end
    if tonumber(version) ~= Demo.VERSION then
        return nil, ('unsupported demo version %s'):format(tostring(version))
    end

    local play = setmetatable({
        header = { rate = 60, source = 'procedural' },
        ticks = {},
        order = {},
        length_ = 0,
    }, PlayMT)

    local i = 2
    while i <= #lines and not lines[i]:match('^%s*%-%-%-%s*$') do
        local key, rest = lines[i]:match('^(%S+)%s+(.*)$')
        if key == 'rate' then play.header.rate = tonumber(rest) or 60
        elseif key == 'source' then play.header.source = rest
        elseif key == 'seed' then play.header.seed = tonumber(rest)
        elseif key == 'map' then play.header.map = rest
        elseif key == 'name' then play.header.name = rest
        end
        i = i + 1
    end
    if i > #lines then return nil, 'no --- separator' end

    local current
    for j = i + 1, #lines do
        local line = lines[j]
        local kind, rest = line:match('^(%S+)%s*(.*)$')
        if kind == 't' then
            local tick = floor(tonumber(rest) or 0)
            current = {}
            play.ticks[tick] = current
            play.order[#play.order + 1] = tick
        elseif kind == 'i' and current then
            local input = {}
            for k, v in rest:gmatch('(%w+)=(%S+)') do
                input[k] = tonumber(v)
            end
            current.input = input
        elseif kind == 'e' and current then
            local name, params = rest:match('^(%S+)%s*(.*)$')
            local ev = { name = name }
            for k, v in (params or ''):gmatch('(%w+)=(%S+)') do
                ev[k] = parseValue(v)
            end
            current.events = current.events or {}
            current.events[#current.events + 1] = ev
        elseif kind == 'c' and current then
            current.check = rest
        elseif kind == 'end' then
            play.length_ = floor(tonumber(rest) or 0)
        end
    end
    table.sort(play.order)

    -- Precompute, per recorded tick, the input in force from that tick on, so
    -- inputAt is a binary search over changes rather than a scan over time.
    local inForce = nil
    play.inputRuns = {}
    for _, tick in ipairs(play.order) do
        local t = play.ticks[tick]
        if t.input then
            inForce = t.input
            play.inputRuns[#play.inputRuns + 1] = { tick = tick, input = inForce }
        end
    end

    return play
end

function PlayMT:length()
    return self.length_
end

-- The input in force on `tick`: the most recent recorded change at or before
-- it. Ticks before the first change get an empty input, which Rep.sanitiseInput
-- reads as standing still.
function PlayMT:inputAt(tick)
    tick = floor(tonumber(tick) or 0)
    local runs = self.inputRuns
    local lo, hi, best = 1, #runs, nil
    while lo <= hi do
        local mid = floor((lo + hi) / 2)
        if runs[mid].tick <= tick then
            best = runs[mid].input
            lo = mid + 1
        else
            hi = mid - 1
        end
    end
    local out = {}
    for _, k in ipairs(Demo.INPUT_FIELDS) do
        if best and best[k] ~= nil then out[k] = best[k] end
    end
    return out
end

function PlayMT:eventsAt(tick)
    local t = self.ticks[floor(tonumber(tick) or 0)]
    return t and t.events or nil
end

function PlayMT:checkpointAt(tick)
    local t = self.ticks[floor(tonumber(tick) or 0)]
    return t and t.check or nil
end

-- Compares live entities against the recorded checkpoint for this tick, if
-- there is one. Silent (true) on ticks without a checkpoint; on a mismatch,
-- returns false plus both sums — the tick this FIRST returns false on is
-- where the divergence began, give or take one checkpoint interval.
function PlayMT:verify(tick, entities)
    local want = self:checkpointAt(tick)
    if not want then return true end
    local got = Demo.checksum(entities)
    if got == want then return true end
    return false, want, got
end

function PlayMT:finished(tick)
    return floor(tonumber(tick) or 0) >= self.length_
end

return Demo
