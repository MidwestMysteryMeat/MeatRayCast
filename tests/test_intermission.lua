--[[
    F4: the tally screen — staged reveal, two-press confirm, rows only for
    stats that exist.
]]

return function(t)
    local Intermission = require('meatray.game.intermission')
    local Game = require('meatray.game')

    t.eq(Game.intermission, Intermission, 'Game.intermission is the module')

    t.eq(Intermission.mmss(143.2), '2:23', 'time formats mm:ss')
    t.eq(Intermission.mmss(0), '0:00', 'zero formats')
    t.eq(Intermission.mmss(3601), '60:01', 'an hour is minutes, not a third field')

    ---------------------------------------------------------------------
    t.describe('rows roll up one at a time')

    local im = Intermission.new{ rowTime = 1 }
    im:begin{
        title = 'The Arena', result = 'win', next_ = 'Tower',
        stats = {
            elapsed = 143.2, parTime = 180,
            kills = 12, killsTotal = 15,
            secrets = 1, secretsTotal = 3,
            coverage = 0.62,
            deaths = 0,
        },
    }
    t.eq(im:active(), true, 'tallying')
    t.eq(#im:rows(), 0, 'nothing revealed at t=0')

    im:update(0.5)
    local rows = im:rows()
    t.eq(#rows, 1, 'the first row is rolling')
    t.eq(rows[1].label, 'time', 'time leads')
    t.eq(rows[1].done, false, 'and is mid-roll')

    im:update(0.5)
    rows = im:rows()
    t.eq(rows[1].done, true, 'the first row lands on its value')
    t.eq(rows[1].text, '2:23  (par 3:00)', 'formatted, with par beside it')

    im:update(3.0)
    rows = im:rows()
    t.eq(#rows, 4, 'all four rows out (deaths=0 earned no row)')
    t.eq(rows[2].text, '12 / 15', 'kills over total')
    t.eq(rows[3].text, '1 / 3  (33%)', 'secrets with the percent')
    t.eq(rows[4].text, '62%', 'automap coverage')
    t.eq(im.state, 'ready', 'and the screen waits')

    local h = im:header()
    t.eq(h.title, 'The Arena', 'header carries the mission')
    t.ok(h.prompt:find('Tower'), 'and where continue goes')

    ---------------------------------------------------------------------
    t.describe('two presses, always')

    local quick = Intermission.new{ rowTime = 10 }
    quick:begin{ stats = { elapsed = 30, kills = 5 } }
    quick:update(0.1)
    t.eq(quick:confirm(), 'skipped', 'the first press hurries the tally')
    t.eq(quick.state, 'ready', 'everything revealed')
    t.eq(quick:rows()[2].text, '5', 'at final values')
    t.eq(quick:continued(), false, 'but the screen has NOT been left')
    t.eq(quick:confirm(), 'continued', 'the second press leaves')
    t.eq(quick:continued(), true, 'now it has')
    t.eq(quick:confirm(), nil, 'a third press is nothing')

    ---------------------------------------------------------------------
    t.describe('rows exist only for stats that do')

    local sparse = Intermission.new{ rowTime = 0.1 }
    sparse:begin{ stats = { elapsed = 10 } }
    sparse:update(10)
    t.eq(#sparse:rows(), 1, 'time only')

    local noSecrets = Intermission.new{ rowTime = 0.1 }
    noSecrets:begin{ stats = { elapsed = 5, secrets = 0, secretsTotal = 0 } }
    noSecrets:update(10)
    t.eq(#noSecrets:rows(), 1, 'a map with no secrets shows no mocking 0/0')

    local died = Intermission.new{ rowTime = 0.1 }
    died:begin{ stats = { elapsed = 5, deaths = 2 } }
    died:update(10)
    t.eq(died:rows()[2].label, 'deaths', 'deaths appear only when nonzero')

    sparse:reset()
    t.eq(sparse:active(), false, 'reset returns to idle')
end
