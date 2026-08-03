--[[
    meatray.game.progression — what survives a run (C23).

    A campaign ends; a roguelite run dies. Meta progression is the thin layer of
    state that outlives either — the currency you banked, the things you have
    unlocked, the totals you have racked up across every attempt. This is that
    layer as a model, on the same storage backend options and accessibility use,
    and it holds three kinds of thing and nothing else:

        currency   one running number the game spends on unlocks
        unlocks    a set of ids the game has earned or bought
        stats      named counters that only accumulate (runs, kills, best time)

        local Progression = require('meatray.game.progression')
        local meta = Progression.new()
        meta:load(storage)                 -- pick up where the player left off

        meta:recordRun{ won = true, kills = 12, score = 3400, reward = 50 }
        meta:purchase('weapon.plasma', 200)   -- spend currency to unlock
        meta:isUnlocked('weapon.plasma')       -- gate content on it
        meta:save(storage)

    What a currency BUYS and what an unlock ENABLES is the game's business — this
    never invents an id or decides a price. It is the ledger, not the shop. Like
    i18n and accessibility, it is infrastructure: the numbers move through here,
    the meaning lives in the game.

    HEADLESS: pure Lua. Persistence goes through an injected storage backend
    (meatray.save.storage), so a test drives it with an in-memory one.
]]

local Progression = {}
local ProgMT = {}
ProgMT.__index = ProgMT

local function isFinite(n)
    return type(n) == 'number' and n == n and n ~= math.huge and n ~= -math.huge
end

---------------------------------------------------------------------------
-- Construction
---------------------------------------------------------------------------

function Progression.new(opts)
    opts = opts or {}
    return setmetatable({
        currency = tonumber(opts.currency) or 0,
        unlocks  = {},      -- [id] = true
        stats    = {},      -- [name] = number
    }, ProgMT)
end

---------------------------------------------------------------------------
-- Currency
---------------------------------------------------------------------------

function ProgMT:currencyAmount() return self.currency end

-- Add (or, with a negative, remove) currency. Never drops below zero.
function ProgMT:addCurrency(n)
    n = tonumber(n) or 0
    if not isFinite(n) then return self.currency end
    self.currency = math.max(0, self.currency + n)
    return self.currency
end

function ProgMT:canAfford(cost)
    cost = tonumber(cost) or 0
    return self.currency >= cost
end

-- Spend currency. Returns true if it went through, false + 'insufficient' if not
-- (an all-or-nothing debit — a partial spend is how a shop double-charges).
function ProgMT:spend(cost)
    cost = tonumber(cost) or 0
    if cost < 0 or not isFinite(cost) then return false, 'bad cost' end
    if self.currency < cost then return false, 'insufficient' end
    self.currency = self.currency - cost
    return true
end

---------------------------------------------------------------------------
-- Unlocks
---------------------------------------------------------------------------

-- Marks an id unlocked. Returns true if this unlocked it now, false if it was
-- already unlocked (so a caller can play the fanfare only the first time).
function ProgMT:unlock(id)
    id = tostring(id or '')
    if id == '' then return false end
    if self.unlocks[id] then return false end
    self.unlocks[id] = true
    return true
end

function ProgMT:isUnlocked(id)
    return self.unlocks[tostring(id or '')] == true
end

function ProgMT:lock(id)
    self.unlocks[tostring(id or '')] = nil
end

-- Buy an unlock: debit the cost and unlock, atomically. Returns true, or false
-- plus a reason ('owned' if already unlocked, 'insufficient' if too poor). The
-- currency is only spent when the unlock actually happens.
function ProgMT:purchase(id, cost)
    id = tostring(id or '')
    if id == '' then return false, 'no id' end
    if self.unlocks[id] then return false, 'owned' end
    local ok, why = self:spend(cost)
    if not ok then return false, why end
    self.unlocks[id] = true
    return true
end

-- Every unlocked id, sorted, so a UI lists them stably.
function ProgMT:unlockedList()
    local out = {}
    for id in pairs(self.unlocks) do out[#out + 1] = id end
    table.sort(out)
    return out
end

---------------------------------------------------------------------------
-- Stats
---------------------------------------------------------------------------

function ProgMT:getStat(name) return self.stats[tostring(name or '')] or 0 end

function ProgMT:setStat(name, value)
    value = tonumber(value)
    if isFinite(value) then self.stats[tostring(name or '')] = value end
    return self:getStat(name)
end

-- Accumulate a counter (the common case: total kills, runs played).
function ProgMT:addStat(name, delta)
    delta = tonumber(delta) or 0
    if not isFinite(delta) then return self:getStat(name) end
    local key = tostring(name or '')
    self.stats[key] = (self.stats[key] or 0) + delta
    return self.stats[key]
end

-- Keep the larger / smaller value ever seen — best score, fastest time. Records
-- unconditionally the first time the stat is seen.
function ProgMT:recordMax(name, value)
    value = tonumber(value)
    if not isFinite(value) then return self:getStat(name) end
    local key = tostring(name or '')
    if self.stats[key] == nil or value > self.stats[key] then self.stats[key] = value end
    return self.stats[key]
end

function ProgMT:recordMin(name, value)
    value = tonumber(value)
    if not isFinite(value) then return self:getStat(name) end
    local key = tostring(name or '')
    if self.stats[key] == nil or value < self.stats[key] then self.stats[key] = value end
    return self.stats[key]
end

-- One call at the end of a run: bank the reward, bump the totals, keep the bests.
-- Every field is optional; the game passes what its run produced.
function ProgMT:recordRun(summary)
    summary = summary or {}
    self:addStat('runs', 1)
    if summary.won then self:addStat('wins', 1) end
    if summary.kills then self:addStat('kills', summary.kills) end
    if summary.reward then self:addCurrency(summary.reward) end
    if summary.score then self:recordMax('bestScore', summary.score) end
    if summary.time then self:recordMin('bestTime', summary.time) end
    return self
end

---------------------------------------------------------------------------
-- Persistence — key=value lines, same shape as options/accessibility
---------------------------------------------------------------------------

function ProgMT:serialize()
    local out = { '# MeatRayCast meta progression',
                  'currency=' .. tostring(self.currency) }
    for _, id in ipairs(self:unlockedList()) do
        out[#out + 1] = 'unlock=' .. id
    end
    local names = {}
    for k in pairs(self.stats) do names[#names + 1] = k end
    table.sort(names)
    for _, k in ipairs(names) do
        out[#out + 1] = ('stat.%s=%s'):format(k, tostring(self.stats[k]))
    end
    return table.concat(out, '\n') .. '\n'
end

function ProgMT:deserialize(text)
    if type(text) ~= 'string' then return false, 'string required' end
    for line in (text .. '\n'):gmatch('([^\n]*)\n') do
        line = line:gsub('\r$', '')
        if line ~= '' and not line:match('^%s*#') then
            local k, v = line:match('^%s*(.-)%s*=%s*(.-)%s*$')
            if k == 'currency' then
                local n = tonumber(v); if isFinite(n) then self.currency = math.max(0, n) end
            elseif k == 'unlock' then
                if v ~= '' then self.unlocks[v] = true end
            else
                local stat = k and k:match('^stat%.(.+)$')
                if stat then
                    local n = tonumber(v); if isFinite(n) then self.stats[stat] = n end
                end
            end
        end
    end
    return true
end

function ProgMT:save(storage, path)
    if not storage or not storage.write then return nil, 'storage required' end
    return storage.write(path or 'progression.cfg', self:serialize())
end

-- A missing file is the normal first-run case, not an error: returns true with
-- the defaults untouched.
function ProgMT:load(storage, path)
    if not storage or not storage.read then return nil, 'storage required' end
    local bytes = storage.read(path or 'progression.cfg')
    if not bytes then return true end
    return self:deserialize(bytes)
end

return Progression
