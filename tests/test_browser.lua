--[[
    D32: the server-browser filter/sort model. Each criterion narrows the list;
    unknown values never silently hide a joinable server; sorting is stable.
]]

return function(t)
    local Browser = require('meatray.net.browser')
    local Net = require('meatray.net')

    t.eq(Net.browser, Browser, 'Net.browser is the module')

    local servers = {
        { address = '1.1.1.1:1', name = 'Fraghouse', map = 'arena', players = 4, max = 8, locked = false, mode = 'dm',  ping = 30 },
        { address = '2.2.2.2:2', name = 'Coop Cave', map = 'cavern', players = 8, max = 8, locked = false, mode = 'coop', ping = 120 },
        { address = '3.3.3.3:3', name = 'Private',   map = 'arena', players = 1, max = 8, locked = true,  mode = 'dm',  ping = 10 },
        { address = '4.4.4.4:4', name = 'Faraway',   map = 'tower', players = 0, max = 8, locked = false, mode = 'dm',  ping = nil },
    }

    ---------------------------------------------------------------------
    t.describe('an empty filter keeps everything, sorted by ping')

    local all = Browser.filter(servers, {})
    t.eq(#all, 4, 'all four kept')
    t.eq(all[1].address, '3.3.3.3:3', 'lowest ping first (10ms)')
    t.eq(all[2].ping, 30, 'then 30')
    t.eq(all[4].ping, nil, 'unknown ping sorts last')

    ---------------------------------------------------------------------
    t.describe('mode filter is exact and case-insensitive')

    local dm = Browser.filter(servers, { mode = 'DM' })
    t.eq(#dm, 3, 'three dm servers (case-insensitive)')
    for _, s in ipairs(dm) do t.eq(s.mode, 'dm', 'all dm') end

    ---------------------------------------------------------------------
    t.describe('map filter is a substring')

    t.eq(#Browser.filter(servers, { map = 'aren' }), 2, 'two arena maps by substring')
    t.eq(#Browser.filter(servers, { map = 'nope' }), 0, 'no match -> empty')

    ---------------------------------------------------------------------
    t.describe('name search is a substring, case-insensitive')

    t.eq(#Browser.filter(servers, { search = 'frag' }), 1, 'finds Fraghouse')

    ---------------------------------------------------------------------
    t.describe('maxPing drops slow servers but keeps unknown ping')

    local fast = Browser.filter(servers, { maxPing = 50 })
    -- 10 and 30 pass; 120 dropped; nil (unknown) kept.
    local addrs = {}
    for _, s in ipairs(fast) do addrs[s.address] = true end
    t.ok(addrs['3.3.3.3:3'] and addrs['1.1.1.1:1'], 'the two fast ones kept')
    t.ok(not addrs['2.2.2.2:2'], '120ms dropped')
    t.ok(addrs['4.4.4.4:4'], 'unknown ping kept — you learn it by connecting')

    ---------------------------------------------------------------------
    t.describe('hideLocked and hideFull')

    local unlocked = Browser.filter(servers, { hideLocked = true })
    for _, s in ipairs(unlocked) do t.ok(not s.locked, 'no locked servers') end
    t.eq(#unlocked, 3, 'one locked dropped')

    local notFull = Browser.filter(servers, { hideFull = true })
    for _, s in ipairs(notFull) do
        t.ok((s.players or 0) < (s.max or 0), 'has a free slot')
    end
    t.eq(#notFull, 3, 'the 8/8 coop server dropped')

    t.eq(#Browser.filter(servers, { hideEmpty = true }), 3, 'hideEmpty drops the 0-player one')

    ---------------------------------------------------------------------
    t.describe('combining filters ANDs them')

    -- dm servers: Fraghouse(30), Private(locked,10), Faraway(nil ping). hideLocked
    -- drops Private; maxPing=50 keeps Fraghouse and the unknown-ping Faraway.
    local combo = Browser.filter(servers, { mode = 'dm', hideLocked = true, maxPing = 50 })
    t.eq(#combo, 2, 'dm + unlocked + (fast or unknown ping)')
    for _, s in ipairs(combo) do
        t.eq(s.mode, 'dm', 'all dm'); t.ok(not s.locked, 'none locked')
    end
    -- Add hideEmpty and the empty unknown-ping server drops, leaving Fraghouse.
    local combo2 = Browser.filter(servers,
        { mode = 'dm', hideLocked = true, maxPing = 50, hideEmpty = true })
    t.eq(#combo2, 1, 'and hideEmpty narrows it to just Fraghouse')
    t.eq(combo2[1].name, 'Fraghouse', 'the survivor')

    ---------------------------------------------------------------------
    t.describe('sort by players and by name')

    local byPlayers = Browser.sort(servers, 'players')
    t.eq(byPlayers[1].players, 8, 'fullest first')
    local byName = Browser.sort(servers, 'name')
    t.eq(byName[1].name, 'Coop Cave', 'alphabetical by name')

    ---------------------------------------------------------------------
    t.describe('modes() lists the distinct modes present')

    local modes = Browser.modes(servers)
    t.eq(#modes, 2, 'two distinct modes')
    t.eq(modes[1], 'coop', 'sorted: coop then dm')
    t.eq(modes[2], 'dm', 'dm')

    ---------------------------------------------------------------------
    t.describe('the input list is never mutated')

    local before = #servers
    Browser.filter(servers, { mode = 'dm' })
    Browser.sort(servers, 'name')
    t.eq(#servers, before, 'original list untouched')
    t.eq(servers[1].address, '1.1.1.1:1', 'and in its original order')
end
