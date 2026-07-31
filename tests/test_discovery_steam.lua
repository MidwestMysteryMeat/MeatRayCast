--[[
    Steam lobby discovery without a Steam client: the mock store path, and the
    degradation when luasteam is absent.
]]

return function(t)
    local Discovery = require('meatray.net.discovery')
    local Steam = require('meatray.net.discovery.steam')

    ---------------------------------------------------------------------
    t.describe('steam is a real discovery backend')

    t.ok(Discovery.builtin.steam, 'steam is listed as a builtin')
    local impl, err = Discovery.resolve('steam')
    t.ok(impl ~= nil, 'steam resolves', err)
    t.eq(impl.introduces, false, 'lobbies do not claim hole-punch introductions')

    ---------------------------------------------------------------------
    t.describe('without Steam the live path refuses cleanly')

    local available, why = Steam.available()
    t.eq(available, false, 'Steam is unavailable under plain LuaJIT')
    t.ok(type(why) == 'string' and why:find('luasteam'), 'with a luasteam reason', why)

    local liveBeacon, liveErr = Steam.beacon{}
    t.eq(liveBeacon, nil, 'live beacon refuses without Steam')
    t.ok(type(liveErr) == 'string' and #liveErr > 0, 'and says why')

    local liveBrowser, liveBErr = Steam.browser{}
    t.eq(liveBrowser, nil, 'live browser refuses without Steam')
    t.ok(type(liveBErr) == 'string' and #liveBErr > 0, 'and says why')

    ---------------------------------------------------------------------
    t.describe('mock store: host announces, browser lists')

    local store = { lobbies = {}, now = function() return 1000 end }

    local beacon = assert(Steam.beacon{
        store = store,
        owner = 'steam:76561198000000001',
        info = function()
            return {
                name = 'Test Lobby', map = 'arena', players = 2, max = 8,
                mode = 'listen', locked = false,
            }
        end,
    })

    local browser = assert(Steam.browser{ store = store })
    browser:refresh()
    local list = browser:servers()
    t.eq(#list, 1, 'one lobby is listed')
    t.eq(list[1].address, 'steam:76561198000000001', 'join address is a steam: id')
    t.eq(list[1].name, 'Test Lobby', 'name is carried')
    t.eq(list[1].map, 'arena', 'map is carried')
    t.eq(list[1].players, 2, 'player count is carried')
    t.eq(list[1].max, 8, 'max is carried')
    t.eq(list[1].source, 'steam', 'source names the backend')

    beacon:close()
    browser:refresh()
    t.eq(#browser:servers(), 0, 'closing the beacon delists the lobby')

    browser:close()
end
