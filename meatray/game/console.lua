--[[
    meatray.game.console — the dev console and its cvars (F3).

    Quake's gift to development: a text box that can read and write the
    variables the engine runs on, and run the verbs a developer needs a
    hundred times a day. This is the MODEL — parsing, cvars, commands,
    history, completion, output ring — with nothing drawn; main.lua owns the
    overlay, the same split options and the HUD use.

        local con = Console.new{ allowCheats = function() return solo end }

        con:defineCvar('cl_showfps', { default = true, help = 'fps readout' })
        con:register('give', {
            help = 'give <item> [count]', cheat = true,
        }, function(c, args) ... return 'gave ' .. args[1] end)

        con:execute('give ammo.pistol 20')
        con:execute('cl_showfps')          -- bare cvar name prints it
        con:execute('cl_showfps 0')        -- name + value sets it

        con:lines()                        -- output ring, for drawing
        con:complete('cl_')                -- tab: common prefix + candidates
        con:historyPrev() / historyNext()  -- arrows

    This console is NOT RCON (D33). RCON is remote administration of a
    dedicated server — authentication, an operator, a network. This is the
    local developer's hand inside their own process, which is why cheats are
    gated on a QUESTION (`allowCheats`, answered by the session role at
    execute time) rather than a boolean set once: the same process moves
    between solo, hosting and joining, and 'god' must stop working the moment
    the world stops being yours.

    HEADLESS: pure Lua.
]]

local Console = {}
local ConsoleMT = {}
ConsoleMT.__index = ConsoleMT

Console.MAX_LINES = 200
Console.MAX_HISTORY = 50

---------------------------------------------------------------------------
-- Construction
---------------------------------------------------------------------------

-- opts:
--   allowCheats   function() -> bool[, reason]. Absent means cheats allowed
--                 (a bare model in a test is nobody's server).
function Console.new(opts)
    opts = opts or {}
    local self = setmetatable({
        allowCheats = opts.allowCheats,

        cvars = {},          -- [name] = def
        commands = {},       -- [name] = { fn=, help=, cheat= }
        names = {},          -- sorted union, rebuilt lazily for completion
        namesDirty = true,

        ring = {},           -- output lines, oldest first
        history = {},        -- executed lines, oldest first
        historyAt = nil,     -- cursor into history while browsing
    }, ConsoleMT)

    -- The console can always explain itself.
    self:register('help', {
        help = 'help [name] — list commands and cvars, or describe one',
    }, function(c, args)
        if args[1] then
            local cmd = c.commands[args[1]]
            if cmd then return args[1] .. ': ' .. (cmd.help or 'no help') end
            local cv = c.cvars[args[1]]
            if cv then
                return ('%s = %s (%s)%s'):format(args[1], tostring(c:get(args[1])),
                    cv.kind, cv.help and (' — ' .. cv.help) or '')
            end
            return "no such command or cvar: " .. args[1]
        end
        local out = {}
        for name in pairs(c.commands) do out[#out + 1] = name end
        table.sort(out)
        return 'commands: ' .. table.concat(out, ', ')
    end)

    self:register('cvarlist', {
        help = 'cvarlist [prefix] — every cvar and its value',
    }, function(c, args)
        local out = {}
        for name in pairs(c.cvars) do
            if not args[1] or name:sub(1, #args[1]) == args[1] then
                out[#out + 1] = name
            end
        end
        table.sort(out)
        for i = 1, #out do
            out[i] = ('%s = %s'):format(out[i], tostring(c:get(out[i])))
        end
        if #out == 0 then return 'no cvars match' end
        return out
    end)

    self:register('echo', { help = 'echo <text>' }, function(_, args)
        return table.concat(args, ' ')
    end)

    self:register('toggle', {
        help = 'toggle <bool cvar>',
    }, function(c, args)
        local name = args[1]
        local cv = name and c.cvars[name]
        if not cv then return 'no such cvar: ' .. tostring(name) end
        if cv.kind ~= 'bool' then return name .. ' is not a bool' end
        local ok, err = c:set(name, not c:get(name))
        if not ok then return err end
        return ('%s = %s'):format(name, tostring(c:get(name)))
    end)

    return self
end

---------------------------------------------------------------------------
-- Cvars
---------------------------------------------------------------------------

local function coerce(def, value)
    if def.kind == 'bool' then
        if type(value) == 'boolean' then return value end
        local s = tostring(value):lower()
        if s == '1' or s == 'true' or s == 'on' or s == 'yes' then return true end
        if s == '0' or s == 'false' or s == 'off' or s == 'no' then return false end
        return nil, 'expected a boolean (1/0/on/off)'
    elseif def.kind == 'number' then
        local n = tonumber(value)
        if not n or n ~= n then return nil, 'expected a number' end
        if def.min and n < def.min then n = def.min end
        if def.max and n > def.max then n = def.max end
        return n
    end
    return tostring(value)
end

-- spec: { default (required; type decides kind unless kind given),
--         kind = 'bool'|'number'|'string', min, max, help,
--         cheat = true (writing it is a cheat),
--         onChange = function(name, value, oldValue) }
function ConsoleMT:defineCvar(name, spec)
    name = tostring(name)
    spec = spec or {}
    local kind = spec.kind
    if not kind then
        local t = type(spec.default)
        kind = (t == 'boolean' and 'bool') or (t == 'number' and 'number') or 'string'
    end
    local def = {
        kind = kind, min = spec.min, max = spec.max,
        help = spec.help, cheat = spec.cheat or false,
        onChange = spec.onChange,
        value = nil,
    }
    local v, err = coerce(def, spec.default)
    if v == nil and err then return nil, 'bad default: ' .. err end
    def.value = v
    def.default = v
    self.cvars[name] = def
    self.namesDirty = true
    return def
end

function ConsoleMT:get(name)
    local def = self.cvars[tostring(name)]
    return def and def.value
end

function ConsoleMT:set(name, value)
    name = tostring(name)
    local def = self.cvars[name]
    if not def then return nil, 'no such cvar: ' .. name end
    if def.cheat and self.allowCheats then
        local ok, why = self.allowCheats()
        if not ok then return nil, why or 'cheats are not available here' end
    end
    local v, err = coerce(def, value)
    if v == nil then return nil, err end
    local old = def.value
    def.value = v
    if def.onChange and v ~= old then def.onChange(name, v, old) end
    return v
end

---------------------------------------------------------------------------
-- Commands
---------------------------------------------------------------------------

-- handler(console, args) -> string | array of strings | nil. What it returns
-- is printed; raising is caught and printed too, because a console that dies
-- of a typo in a handler is worse than no console.
function ConsoleMT:register(name, spec, fn)
    if type(spec) == 'function' then fn, spec = spec, {} end
    self.commands[tostring(name)] = {
        fn = fn, help = (spec or {}).help, cheat = (spec or {}).cheat or false,
    }
    self.namesDirty = true
    return self
end

---------------------------------------------------------------------------
-- Parsing and execution
---------------------------------------------------------------------------

-- Whitespace-split with double-quoted strings: give "boom stick" 2
local function tokenize(line)
    local args = {}
    local i, n = 1, #line
    while i <= n do
        local c = line:sub(i, i)
        if c:match('%s') then
            i = i + 1
        elseif c == '"' then
            local close = line:find('"', i + 1, true)
            if not close then
                args[#args + 1] = line:sub(i + 1)
                i = n + 1
            else
                args[#args + 1] = line:sub(i + 1, close - 1)
                i = close + 1
            end
        else
            local stop = line:find('[%s"]', i) or (n + 1)
            args[#args + 1] = line:sub(i, stop - 1)
            i = stop
        end
    end
    return args
end
Console.tokenize = tokenize

function ConsoleMT:print(text)
    if text == nil then return end
    local lines = type(text) == 'table' and text or { tostring(text) }
    for i = 1, #lines do
        self.ring[#self.ring + 1] = tostring(lines[i])
        if #self.ring > Console.MAX_LINES then table.remove(self.ring, 1) end
    end
end

function ConsoleMT:lines()
    return self.ring
end

function ConsoleMT:clear()
    self.ring = {}
end

-- Runs one input line: a command, a bare cvar name (prints it), or a cvar
-- name with a value (sets it). Everything the line caused is echoed into the
-- ring; returns true plus the printed text, or false plus the refusal.
function ConsoleMT:execute(line)
    line = tostring(line or ''):gsub('^%s+', ''):gsub('%s+$', '')
    if line == '' then return true end

    self:print('> ' .. line)
    self.history[#self.history + 1] = line
    if #self.history > Console.MAX_HISTORY then table.remove(self.history, 1) end
    self.historyAt = nil

    local args = tokenize(line)
    local name = table.remove(args, 1)

    local cmd = self.commands[name]
    if cmd then
        if cmd.cheat and self.allowCheats then
            local ok, why = self.allowCheats()
            if not ok then
                local msg = why or 'cheats are not available here'
                self:print(msg)
                return false, msg
            end
        end
        local ok, result = pcall(cmd.fn, self, args)
        if not ok then
            local msg = 'error: ' .. tostring(result)
            self:print(msg)
            return false, msg
        end
        self:print(result)
        return true, result
    end

    local cv = self.cvars[name]
    if cv then
        if #args == 0 then
            local msg = ('%s = %s'):format(name, tostring(cv.value))
            self:print(msg)
            return true, msg
        end
        local v, err = self:set(name, table.concat(args, ' '))
        if v == nil then
            self:print(err)
            return false, err
        end
        local msg = ('%s = %s'):format(name, tostring(cv.value))
        self:print(msg)
        return true, msg
    end

    local msg = 'unknown: ' .. tostring(name) .. ' (try help)'
    self:print(msg)
    return false, msg
end

---------------------------------------------------------------------------
-- History and completion
---------------------------------------------------------------------------

function ConsoleMT:historyPrev()
    if #self.history == 0 then return nil end
    if self.historyAt == nil then
        self.historyAt = #self.history
    elseif self.historyAt > 1 then
        self.historyAt = self.historyAt - 1
    end
    return self.history[self.historyAt]
end

function ConsoleMT:historyNext()
    if self.historyAt == nil then return nil end
    if self.historyAt < #self.history then
        self.historyAt = self.historyAt + 1
        return self.history[self.historyAt]
    end
    self.historyAt = nil
    return ''                       -- walked past the newest: an empty line
end

local function allNames(self)
    if self.namesDirty then
        local names = {}
        for name in pairs(self.commands) do names[#names + 1] = name end
        for name in pairs(self.cvars) do names[#names + 1] = name end
        table.sort(names)
        self.names = names
        self.namesDirty = false
    end
    return self.names
end

-- Tab completion over commands and cvars together. Returns the longest
-- common extension of the prefix, plus the full candidate list — one match
-- means "type it for me", several mean "show me".
function ConsoleMT:complete(prefix)
    prefix = tostring(prefix or '')
    local matches = {}
    for _, name in ipairs(allNames(self)) do
        if name:sub(1, #prefix) == prefix then matches[#matches + 1] = name end
    end
    if #matches == 0 then return prefix, matches end
    local common = matches[1]
    for i = 2, #matches do
        local m = matches[i]
        local j = #prefix
        while j < #common and j < #m
              and common:sub(j + 1, j + 1) == m:sub(j + 1, j + 1) do
            j = j + 1
        end
        common = common:sub(1, j)
    end
    return common, matches
end

return Console
