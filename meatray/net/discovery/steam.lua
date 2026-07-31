--[[
    meatray.net.discovery.steam — find servers through Steam lobbies.

    The Steam *transport* dials an account you already know
    (`steam:<SteamID64>`). This backend is how you find one: the host creates a
    lobby, the browser lists lobbies for the app, and a join address comes out
    as `steam:<owner SteamID64>` so the existing transport can dial it.

    ## It must never be the reason a game will not run

    No Steam client, no luasteam, no App ID: constructing a beacon or browser
    returns nil plus a reason, `direct` and `lan` are untouched, and asking for
    `discovery = 'steam'` on a machine without Steam is a missing backend rather
    than a crash. That path is asserted under plain LuaJIT.

    `require('luasteam')` is inside available(), never at file scope.

    ## Mock store for tests

    Pass `store = sharedTable` to beacon and browser in the same process and
    neither side needs Steam. The store is a list of lobby records the beacon
    writes and the browser reads — enough to pin the entry shape and the join
    address without a live client.

    HEADLESS: no love. Pure Lua except the optional luasteam binding.
]]

local Steam = {}

Steam.STALE_AFTER = 30
Steam.BROWSE_INTERVAL = 5

-- Lobby keys the host writes and the browser reads. Short names keep the
-- Steam lobby metadata budget happy.
Steam.KEY_NAME    = 'mrc_name'
Steam.KEY_MAP     = 'mrc_map'
Steam.KEY_PLAYERS = 'mrc_players'
Steam.KEY_MAX     = 'mrc_max'
Steam.KEY_MODE    = 'mrc_mode'
Steam.KEY_LOCKED  = 'mrc_locked'
Steam.KEY_VERSION = 'mrc_ver'

local function loadSteam()
    local ok, mod = pcall(require, 'luasteam')
    if not ok or type(mod) ~= 'table' then
        return nil, 'luasteam is unavailable: Steam lobby discovery needs the '
                 .. 'luasteam binding and a running Steam client '
                 .. '(see docs/NETWORKING.md). LAN and direct still work.'
    end
    return mod
end

function Steam.available()
    local mod, err = loadSteam()
    if not mod then return false, err end
    if type(mod.matchmaking) ~= 'table' then
        return false, 'luasteam has no matchmaking interface; rebuild against a '
                   .. 'Steamworks SDK that still exposes lobbies'
    end
    return true, mod
end

---------------------------------------------------------------------------
-- Shared helpers
---------------------------------------------------------------------------

local function readInfo(opts)
    if type(opts.info) == 'function' then
        local ok, info = pcall(opts.info)
        if ok and type(info) == 'table' then return info end
    end
    return type(opts.info) == 'table' and opts.info or {}
end

local function entryFromLobby(lobby, source)
    local owner = lobby.owner or lobby.address
    if not owner then return nil end
    local address = tostring(owner)
    if not address:find('^steam:') then
        address = 'steam:' .. address
    end
    return {
        address  = address,
        name     = lobby.name or 'Steam lobby',
        map      = lobby.map or '?',
        players  = tonumber(lobby.players) or 0,
        max      = tonumber(lobby.max) or 0,
        locked   = lobby.locked and true or false,
        mode     = lobby.mode or 'listen',
        ping     = lobby.ping,
        source   = source or 'steam',
        lastSeen = lobby.lastSeen or 0,
        lobbyId  = lobby.lobbyId,
    }
end

---------------------------------------------------------------------------
-- Mock path (tests, no Steam)
---------------------------------------------------------------------------

local function mockBeacon(opts)
    opts = opts or {}
    local store = opts.store
    if type(store) ~= 'table' then
        return nil, 'steam mock beacon needs a shared store table'
    end
    store.lobbies = store.lobbies or {}

    local id = tostring(opts.lobbyId or ('mock-' .. tostring(#store.lobbies + 1)))
    local owner = opts.owner or 'steam:76561197960287930'

    local self = {
        id = id,
        owner = owner,
        closed = false,
        interval = opts.interval or 2,
        elapsed = 0,
    }

    local function publish()
        local info = readInfo(opts)
        store.lobbies[id] = {
            lobbyId  = id,
            owner    = owner,
            name     = info.name or 'MeatRayCast',
            map      = info.map or '?',
            players  = info.players or 0,
            max      = info.max or info.maxPlayers or 8,
            locked   = info.locked or false,
            mode     = info.mode or 'listen',
            lastSeen = (store.now and store.now()) or os.time(),
        }
    end

    publish()

    return {
        update = function(_, dt)
            if self.closed then return end
            self.elapsed = self.elapsed + (dt or 0)
            if self.elapsed >= self.interval then
                self.elapsed = 0
                publish()
            end
        end,
        close = function()
            self.closed = true
            store.lobbies[id] = nil
        end,
        lobbyId = function() return self.id end,
        address = function() return self.owner end,
    }
end

local function mockBrowser(opts)
    opts = opts or {}
    local store = opts.store
    if type(store) ~= 'table' then
        return nil, 'steam mock browser needs a shared store table'
    end
    store.lobbies = store.lobbies or {}

    local entries = {}
    local self = {
        closed = false,
        interval = opts.interval or Steam.BROWSE_INTERVAL,
        elapsed = 0,
    }

    local function refresh()
        entries = {}
        local now = (store.now and store.now()) or os.time()
        for _, lobby in pairs(store.lobbies) do
            if (now - (lobby.lastSeen or 0)) <= Steam.STALE_AFTER then
                local e = entryFromLobby(lobby, 'steam')
                if e then
                    e.ping = 0
                    e.lastSeen = lobby.lastSeen or now
                    entries[#entries + 1] = e
                end
            end
        end
        table.sort(entries, function(a, b)
            return tostring(a.address) < tostring(b.address)
        end)
    end

    refresh()

    return {
        update = function(_, dt)
            if self.closed then return end
            self.elapsed = self.elapsed + (dt or 0)
            if self.elapsed >= self.interval then
                self.elapsed = 0
                refresh()
            end
        end,
        refresh = function() refresh() end,
        servers = function() return entries end,
        close = function() self.closed = true end,
    }
end

---------------------------------------------------------------------------
-- Live Steam path
---------------------------------------------------------------------------

local function liveBeacon(opts, steam)
    opts = opts or {}
    local mm = steam.matchmaking
    if type(mm.createLobby) ~= 'function' then
        return nil, 'luasteam matchmaking.createLobby is missing'
    end

    -- Public lobby by default so RequestLobbyList can see it. A game that
    -- wants friends-only sets opts.lobbyType = 'friends'.
    local lobbyType = opts.lobbyType or 'public'
    local maxMembers = opts.maxMembers or 8

    local lobbyId = nil
    local closed = false
    local elapsed = 0
    local interval = opts.interval or 2

    local ok, err = pcall(function()
        -- luasteam API shapes vary by version; try the common form first.
        if mm.createLobby then
            lobbyId = mm.createLobby(lobbyType, maxMembers)
        end
    end)
    if not ok then
        return nil, 'Steam createLobby failed: ' .. tostring(err)
    end
    if lobbyId == nil and type(mm.createLobby) == 'function' then
        -- Some bindings are callback-driven and return nothing synchronously.
        -- We still install a beacon that pushes data when lobbyId appears.
    end

    local function publish()
        if closed then return end
        local info = readInfo(opts)
        local id = lobbyId
        if id == nil then return end
        local function set(key, value)
            pcall(function() mm.setLobbyData(id, key, tostring(value)) end)
        end
        set(Steam.KEY_NAME, info.name or 'MeatRayCast')
        set(Steam.KEY_MAP, info.map or '?')
        set(Steam.KEY_PLAYERS, info.players or 0)
        set(Steam.KEY_MAX, info.max or info.maxPlayers or maxMembers)
        set(Steam.KEY_MODE, info.mode or 'listen')
        set(Steam.KEY_LOCKED, (info.locked and '1') or '0')
        set(Steam.KEY_VERSION, tostring(info.version or 0))
    end

    return {
        update = function(_, dt)
            if closed then return end
            -- Drain callbacks so createLobby results land.
            if steam.runCallbacks then pcall(steam.runCallbacks) end
            elapsed = elapsed + (dt or 0)
            if elapsed >= interval then
                elapsed = 0
                publish()
            end
        end,
        close = function()
            closed = true
            if lobbyId and mm.leaveLobby then
                pcall(function() mm.leaveLobby(lobbyId) end)
            end
        end,
        lobbyId = function() return lobbyId end,
    }
end

local function liveBrowser(opts, steam)
    opts = opts or {}
    local mm = steam.matchmaking
    local entries = {}
    local closed = false
    local elapsed = 0
    local interval = opts.interval or Steam.BROWSE_INTERVAL

    local function refresh()
        entries = {}
        if type(mm.requestLobbyList) ~= 'function' then return end
        pcall(function()
            if type(mm.addRequestLobbyListStringFilter) == 'function' then
                mm.addRequestLobbyListStringFilter(Steam.KEY_NAME, '', 'ne')
            end
            mm.requestLobbyList()
        end)
        -- Results arrive via callbacks; a subsequent update drains them into
        -- entries when the binding exposes getLobbyByIndex.
        if type(mm.getLobbyByIndex) == 'function' and type(mm.getLobbyCount) == 'function' then
            local n = mm.getLobbyCount() or 0
            for i = 0, n - 1 do
                local id = mm.getLobbyByIndex(i)
                if id then
                    local function get(key)
                        local ok, v = pcall(function() return mm.getLobbyData(id, key) end)
                        return ok and v or nil
                    end
                    local owner
                    if mm.getLobbyOwner then
                        local ok, o = pcall(function() return mm.getLobbyOwner(id) end)
                        if ok then owner = o end
                    end
                    local lobby = {
                        lobbyId = id,
                        owner   = owner and tostring(owner) or nil,
                        name    = get(Steam.KEY_NAME) or 'Steam lobby',
                        map     = get(Steam.KEY_MAP) or '?',
                        players = tonumber(get(Steam.KEY_PLAYERS)) or 0,
                        max     = tonumber(get(Steam.KEY_MAX)) or 0,
                        mode    = get(Steam.KEY_MODE) or 'listen',
                        locked  = get(Steam.KEY_LOCKED) == '1',
                        lastSeen = os.time(),
                    }
                    local e = entryFromLobby(lobby, 'steam')
                    if e then entries[#entries + 1] = e end
                end
            end
        end
    end

    refresh()

    return {
        update = function(_, dt)
            if closed then return end
            if steam.runCallbacks then pcall(steam.runCallbacks) end
            elapsed = elapsed + (dt or 0)
            if elapsed >= interval then
                elapsed = 0
                refresh()
            end
        end,
        refresh = function() refresh() end,
        servers = function() return entries end,
        close = function() closed = true end,
    }
end

---------------------------------------------------------------------------
-- Public constructors
---------------------------------------------------------------------------

function Steam.beacon(opts)
    opts = opts or {}
    if opts.store then return mockBeacon(opts) end

    local ok, steamOrErr = Steam.available()
    if not ok then return nil, steamOrErr end
    return liveBeacon(opts, steamOrErr)
end

function Steam.browser(opts)
    opts = opts or {}
    if opts.store then return mockBrowser(opts) end

    local ok, steamOrErr = Steam.available()
    if not ok then return nil, steamOrErr end
    return liveBrowser(opts, steamOrErr)
end

-- Lobbies are not a punch introduction path: the Steam transport does its own
-- traversal. Declared false so a host does not claim punch support from this
-- backend alone.
Steam.introduces = false

return Steam
