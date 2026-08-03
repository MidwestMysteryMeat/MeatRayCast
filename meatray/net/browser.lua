--[[
    meatray.net.browser — filtering and sorting a server list (D32).

    Discovery (meatray.net.discovery) produces server records; this decides which
    of them a player is shown and in what order. It is the model behind a server
    browser's filter row, kept separate from any UI so the LAN CLI, the in-shell
    browser and a test all filter by the same rules.

        local Browser = require('meatray.net.browser')

        local shown = Browser.filter(servers, {
            mode = 'dm',        -- exact game mode (case-insensitive)
            map = 'arena',      -- substring of the map name
            maxPing = 80,       -- drop anything slower (unknown ping is kept)
            hideLocked = true,  -- drop password-protected servers
            hideFull = true,    -- drop servers with no free slot
            search = 'frag',    -- substring of the server name
            sort = 'ping',      -- 'ping' | 'players' | 'name'
        })

    A server record is the shape discovery documents:
        { address, name, map, players, max, locked, mode, ping, source, lastSeen }

    Every criterion is optional; an empty filter returns the list sorted only.
    Unknown values do not silently hide a server you could still join: a record
    with no ping passes a maxPing filter (you learn its ping by connecting), and a
    record missing a field it is not being filtered on is unaffected.

    HEADLESS: pure Lua, no love.*, no sockets. Input is a plain list of records.
]]

local Browser = {}

local function lc(s) return tostring(s or ''):lower() end

---------------------------------------------------------------------------
-- Predicates
---------------------------------------------------------------------------

-- Does one record pass the filter? Broken out so a UI can grey a row instead of
-- hiding it, and so the test can check one rule at a time.
function Browser.matches(s, f)
    if not s then return false end
    f = f or {}

    if f.mode and f.mode ~= '' then
        if lc(s.mode) ~= lc(f.mode) then return false end
    end
    if f.map and f.map ~= '' then
        if not lc(s.map):find(lc(f.map), 1, true) then return false end
    end
    if f.search and f.search ~= '' then
        if not lc(s.name):find(lc(f.search), 1, true) then return false end
    end
    if f.maxPing then
        -- A known ping over the ceiling is hidden; an unknown ping is not,
        -- because hiding a server you might happily join is the worse mistake.
        if type(s.ping) == 'number' and s.ping > f.maxPing then return false end
    end
    if f.hideLocked and s.locked then return false end
    if f.hideFull then
        local max = tonumber(s.max) or 0
        if max > 0 and (tonumber(s.players) or 0) >= max then return false end
    end
    if f.hideEmpty then
        if (tonumber(s.players) or 0) <= 0 then return false end
    end
    return true
end

---------------------------------------------------------------------------
-- Sorting
---------------------------------------------------------------------------

-- Comparators. Ping sorts fastest first with unknown ping last (you cannot rank
-- what you have not measured, so it goes to the bottom rather than the top).
-- Players sorts fullest first (where the game is). Name is alphabetical.
local SORTS = {
    ping = function(a, b)
        local pa, pb = a.ping, b.ping
        if pa == nil and pb == nil then return a.address < b.address end
        if pa == nil then return false end
        if pb == nil then return true end
        if pa ~= pb then return pa < pb end
        return a.address < b.address
    end,
    players = function(a, b)
        local na, nb = tonumber(a.players) or 0, tonumber(b.players) or 0
        if na ~= nb then return na > nb end
        return a.address < b.address
    end,
    name = function(a, b)
        local la, lb = lc(a.name), lc(b.name)
        if la ~= lb then return la < lb end
        return a.address < b.address
    end,
}
Browser.SORTS = SORTS

function Browser.sort(servers, key)
    local cmp = SORTS[key] or SORTS.ping
    local out = {}
    for i = 1, #(servers or {}) do out[i] = servers[i] end
    table.sort(out, cmp)
    return out
end

---------------------------------------------------------------------------
-- The whole operation
---------------------------------------------------------------------------

-- Filter then sort. Returns a new list; the input is not mutated.
function Browser.filter(servers, f)
    f = f or {}
    local kept = {}
    for i = 1, #(servers or {}) do
        if Browser.matches(servers[i], f) then kept[#kept + 1] = servers[i] end
    end
    return Browser.sort(kept, f.sort)
end

-- The distinct game modes present in a list, sorted — so a UI can offer the
-- modes that actually exist rather than a hard-coded menu.
function Browser.modes(servers)
    local seen, out = {}, {}
    for i = 1, #(servers or {}) do
        local m = servers[i].mode
        if m and not seen[m] then seen[m] = true; out[#out + 1] = m end
    end
    table.sort(out)
    return out
end

return Browser
