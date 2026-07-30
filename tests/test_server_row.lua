--[[
    Server browser row formatting.

    Pure, and worth testing precisely because its failures are not crashes. The
    bug this file was written after was a row that rendered every server as
    holding 0 players and never showed FULL -- the panel read `entry.maxPlayers`
    while both discovery backends and the documented contract use `max`. Nothing
    threw, the editor booted clean, and the browser was quietly wrong.
]]

return function(t)
    local describe = require('meatray.ui.server_row').describe

    t.describe('the player count is actually shown')

    local row = describe{ address = '10.0.0.5:6789', name = 'Alpha', map = 'arena',
                          players = 3, max = 8 }
    t.ok(row:find('3/8'), 'players over max appears in the row: ' .. row)
    t.ok(row:find('10%.0%.0%.5'), 'and the address')
    t.ok(row:find('Alpha'), 'and the name')
    t.ok(row:find('arena'), 'and the map')

    -- The registry spells it maxPlayers; the discovery contract says max. Both
    -- are accepted so a backend is not punished for the other spelling.
    t.ok(describe{ players = 2, maxPlayers = 4 }:find('2/4'),
         'maxPlayers is accepted as well as max')
    t.ok(describe{ players = 1 }:find('1/0'), 'a missing max degrades to 0 rather than erroring')

    t.describe('flags say why you might not be able to join')

    t.ok(describe{ players = 8, max = 8 }:find('FULL'), 'a full server is marked FULL')
    t.ok(not describe{ players = 7, max = 8 }:find('FULL'), 'and a nearly-full one is not')
    -- The dead-code case: with no max known, FULL must not fire off a nil
    -- comparison or claim every server is full.
    t.ok(not describe{ players = 7 }:find('FULL'), 'an unknown max never reads as full')

    t.ok(describe{ locked = true }:find('locked'), 'a password-locked server says so')
    t.ok(describe{ dedicated = true }:find('dedicated'), 'and a dedicated one')

    -- A registry entry whose game port was never proven open. Saying so is the
    -- difference between "this might not connect" and a player deciding the
    -- game is broken.
    t.ok(describe{ portVerified = false }:find('unverified'),
         'an unverified port is flagged')
    t.ok(not describe{ portVerified = true }:find('unverified'),
         'a verified one is not')
    t.ok(not describe{}:find('unverified'),
         'and neither is an entry that says nothing about it, so LAN rows stay clean')

    t.describe('a hostile or empty entry does not break the row')

    local empty = describe{}
    t.ok(type(empty) == 'string' and #empty > 0, 'an empty entry still formats')
    t.ok(empty:find('%?'), 'and shows a placeholder address')

    -- Long strings are cut rather than pushing the columns apart.
    local long = describe{ address = string.rep('x', 200), name = string.rep('y', 200),
                           map = string.rep('z', 200), players = 1, max = 2 }
    t.ok(not long:find(string.rep('y', 20)), 'an over-long name is truncated')
    t.ok(long:find('1/2'), 'and the columns after it still line up')
end
