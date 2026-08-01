--[[
    Campaign / mission flow: map chain, win/lose, exit volume, credits.
]]

return function(t)
    local Campaign = require('meatray.game.campaign')
    local Triggers = require('meatray.sim.triggers')
    local Map      = require('meatray.sim.map')
    local Mode     = require('meatray.game.mode')
    local Game     = require('meatray.game')

    t.eq(Game.campaign, Campaign, 'Game.campaign is the campaign module')

    ---------------------------------------------------------------------
    t.describe('lifecycle: three-map win to credits')

    local loaded = {}
    local log = {}
    local camp = Campaign.new{
        id = 'demo',
        title = 'Demo',
        missions = {
            { id = 'm1', map = 'maps/a.map', name = 'One', intermission = 0 },
            { id = 'm2', map = 'maps/b.map', name = 'Two' },
            { id = 'm3', map = 'maps/c.map', name = 'Three' },
        },
        onLoadMap = function(c, path, opts)
            loaded[#loaded + 1] = path .. ':' .. (opts.reason or '')
        end,
        onMissionStart = function(c, m, i)
            log[#log + 1] = ('start:%s:%d'):format(m.id, i)
        end,
        onMissionEnd = function(c, m, result)
            log[#log + 1] = ('end:%s:%s'):format(m.id, result.outcome)
        end,
        onCredits = function(c, totals)
            log[#log + 1] = ('credits:%d'):format(totals.missions)
        end,
        onCampaignWin = function()
            log[#log + 1] = 'campaign_win'
        end,
        onCampaignLose = function(c, reason)
            log[#log + 1] = 'campaign_lose:' .. tostring(reason)
        end,
    }

    t.eq(camp.state, 'idle', 'starts idle')
    t.eq(camp:missionCount(), 3, 'three missions')

    local ok = camp:start()
    t.eq(ok, true, 'start ok')
    t.eq(camp.state, 'mission', 'running first mission')
    t.eq(camp.index, 1, 'index 1')
    t.eq(loaded[1], 'maps/a.map:mission', 'loaded first map')
    t.eq(log[1], 'start:m1:1', 'onMissionStart m1')

    camp:tick(1.5)
    t.near(camp.missionElapsed, 1.5, 1e-9, 'mission time')
    camp:addKill(2)
    camp:addSecret(1)
    t.eq(camp.totals.kills, 2, 'kills tracked')
    t.eq(camp.totals.secrets, 1, 'secrets tracked')

    camp:completeMission('manual')
    t.eq(camp.index, 2, 'advanced to m2')
    t.eq(camp.state, 'mission', 'still in mission')
    t.eq(loaded[2], 'maps/b.map:advance', 'loaded second map')
    t.eq(camp.stats[1].outcome, 'win', 'm1 won')
    t.near(camp.stats[1].elapsed, 1.5, 1e-9, 'm1 elapsed stored')

    camp:completeMission()
    t.eq(camp.index, 3, 'm3')
    camp:completeMission()
    t.eq(camp.state, 'won', 'campaign won after last map')
    t.ok(log[#log - 1] == 'credits:3' or log[#log] == 'campaign_win',
        'credits and win fired')
    local sawCredits, sawWin = false, false
    for i = 1, #log do
        if log[i] == 'credits:3' then sawCredits = true end
        if log[i] == 'campaign_win' then sawWin = true end
    end
    t.ok(sawCredits, 'credits hook')
    t.ok(sawWin, 'campaign win hook')

    ---------------------------------------------------------------------
    t.describe('exit volume completes mission')

    local loads = {}
    local c2 = Campaign.new{
        missions = {
            {
                id = 'ex',
                map = 'maps/exit.map',
                exit = { x1 = 5, y1 = 5, x2 = 7, y2 = 7 },
            },
            { id = 'next', map = 'maps/next.map' },
        },
        onLoadMap = function(_, path) loads[#loads + 1] = path end,
        playerFilter = function(e) return e and e.kind == 'player' end,
    }
    c2:start()
    local box = Triggers.new()
    local vol = c2:bindTriggers(box)
    t.ok(vol, 'exit volume installed')
    t.eq(vol.name, 'campaign_exit_ex', 'named exit vol')

    local player = { id = 1, x = 1, y = 1, kind = 'player', dead = false }
    local other  = { id = 2, x = 6, y = 6, kind = 'imp', dead = false }
    box:update({ player, other }, 0)
    t.eq(c2.index, 1, 'non-player in exit does not complete')
    t.eq(c2.state, 'mission', 'still mission')

    player.x, player.y = 6, 6
    box:update({ player, other }, 0)
    t.eq(c2.state, 'mission', 'advanced to next mission state')
    t.eq(c2.index, 2, 'second mission after exit')
    t.eq(loads[2], 'maps/next.map', 'next map loaded')

    ---------------------------------------------------------------------
    t.describe('exit tiles helper')

    local c3 = Campaign.new{
        missions = {
            {
                id = 'tiles',
                map = 'm.map',
                exitTiles = { tx1 = 3, ty1 = 3, tx2 = 3, ty2 = 3 },
            },
        },
        playerFilter = function(e) return e and e.tag == 'p' end,
        onCredits = function() end,
        onCampaignWin = function() end,
    }
    c3:start()
    local tr = c3:makeTriggers()
    local p = { id = 9, x = 2.5, y = 2.5, tag = 'p' } -- centre of tile 3,3
    tr:update({ p }, 0)
    t.eq(c3.state, 'won', 'tile exit wins single-mission campaign')

    ---------------------------------------------------------------------
    t.describe('lose on death and time limit')

    local playerRef = { id = 1, dead = false, components = { player = {} } }
    local c4 = Campaign.new{
        missions = {
            {
                id = 'hard',
                map = 'maps/hard.map',
                timeLimit = 5,
                loseOnPlayerDeath = true,
            },
        },
        getPlayer = function() return playerRef end,
        onCampaignLose = function(c, reason) log[#log + 1] = 'lose4:' .. reason end,
    }
    c4:start()
    c4:tick(1.0)
    t.eq(c4.state, 'mission', 'under time limit')
    playerRef.dead = true
    c4:tick(0.1)
    t.eq(c4.state, 'lost', 'lost on death')
    t.eq(c4.totals.deaths, 1, 'death counted')
    t.eq(c4.stats[1].reason, 'death', 'reason death')

    local c5 = Campaign.new{
        missions = { { id = 'rush', map = 'm', timeLimit = 2, loseOnPlayerDeath = false } },
    }
    c5:start()
    c5:tick(1.5)
    t.eq(c5.state, 'mission', 'not yet timed out')
    c5:tick(1.0)
    t.eq(c5.state, 'lost', 'time limit fail')
    t.eq(c5.stats[1].reason, 'time', 'reason time')

    ---------------------------------------------------------------------
    t.describe('winWhenAllDead')

    local enemies = {
        { id = 10, dead = false, components = { ai = {} } },
        { id = 11, dead = false, components = { ai = {} } },
    }
    local c6 = Campaign.new{
        missions = {
            { id = 'clear', map = 'm', winWhenAllDead = true, loseOnPlayerDeath = false },
        },
    }
    c6:start()
    c6:tick(0.1, nil, enemies)
    t.eq(c6.state, 'mission', 'enemies alive')
    enemies[1].dead = true
    enemies[2].dead = true
    c6:tick(0.1, nil, enemies)
    t.eq(c6.state, 'won', 'all dead wins')

    ---------------------------------------------------------------------
    t.describe('intermission delay')

    local c7 = Campaign.new{
        missions = {
            { id = 'a', map = 'a', intermission = 1.0 },
            { id = 'b', map = 'b' },
        },
        onIntermission = function()
            log[#log + 1] = 'intermission'
        end,
    }
    c7:start()
    c7:completeMission()
    t.eq(c7.state, 'intermission', 'in intermission')
    t.eq(c7.index, 1, 'still index 1 during intermission')
    c7:tick(0.4)
    t.eq(c7.state, 'intermission', 'intermission not done')
    c7:tick(0.7)
    t.eq(c7.state, 'mission', 'advanced after wait')
    t.eq(c7.index, 2, 'now mission 2')

    ---------------------------------------------------------------------
    t.describe('progress export / import')

    local c8 = Campaign.new{
        id = 'save_me',
        missions = {
            { id = 'a', map = 'a' },
            { id = 'b', map = 'b' },
        },
    }
    c8:start()
    c8:tick(3)
    c8:addKill(4)
    c8:completeMission()
    c8:tick(1)
    local snap = c8:exportProgress()
    t.eq(snap.campaignId, 'save_me', 'id in snapshot')
    t.eq(snap.index, 2, 'index 2')
    t.eq(snap.missionStats[1].kills, 4, 'kills in snap')

    local c9 = Campaign.new{
        id = 'save_me',
        missions = {
            { id = 'a', map = 'a' },
            { id = 'b', map = 'b' },
        },
    }
    local okImp, errImp = c9:importProgress(snap)
    t.eq(okImp, true, 'import ok', errImp)
    t.eq(c9.index, 2, 'restored index')
    t.eq(c9.totals.kills, 4, 'restored kills')
    t.eq(c9.state, 'mission', 'restored state')

    local bad = Campaign.new{ id = 'other', missions = { { map = 'x' } } }
    local okBad, errBad = bad:importProgress(snap)
    t.eq(okBad, false, 'id mismatch refused')
    t.ok(errBad:find('mismatch'), 'mismatch message')

    ---------------------------------------------------------------------
    t.describe('map header exit + Campaign.exitFromMap')

    local text = table.concat({
        'name Exit Demo',
        'theme dungeon',
        'spawn 1.5 1.5 0',
        'exit 4 4 6 6',
        '---',
        '#####',
        '#...#',
        '#...#',
        '#...#',
        '#####',
        '',
    }, '\n')
    local map, errs = Map.parse(text)
    t.ok(map, 'map parses', errs and errs[1])
    t.ok(map.exit, 'map.exit set')
    t.near(map.exit.x1, 4, 1e-9, 'exit x1')
    t.near(map.exit.y2, 6, 1e-9, 'exit y2')

    local from = Campaign.exitFromMap(map)
    t.ok(from and from.x1 == 4, 'exitFromMap world')

    local textTiles = table.concat({
        'name T',
        'exit tiles 2 2 3 3',
        '---',
        '####',
        '#..#',
        '#..#',
        '####',
        '',
    }, '\n')
    local mapT = Map.parse(textTiles)
    t.ok(mapT.exit and mapT.exit.tiles, 'tile exit header')
    local fromT = Campaign.exitFromMap(mapT)
    t.eq(fromT.exitTiles.tx1, 2, 'tile exit tx1')

    local c10 = Campaign.new{
        missions = { { id = 'frommap', map = 'x' } },
        playerFilter = function(e) return e and e.ok end,
    }
    c10:start()
    -- Mission has no exit; bind with parsed map supplies it.
    local tr2 = Triggers.new()
    local v = c10:bindTriggers(tr2, map)
    t.ok(v, 'bound exit from map')
    local pe = { id = 3, x = 5, y = 5, ok = true }
    tr2:update({ pe }, 0)
    t.eq(c10.state, 'won', 'map-supplied exit wins')

    ---------------------------------------------------------------------
    t.describe('asMode glue')

    local c11 = Campaign.new{
        missions = { { id = 'only', map = 'm' } },
    }
    local mode = c11:asMode(Mode)
    mode:start(nil, {})
    t.eq(c11.state, 'mission', 'mode start begins campaign')
    mode:tick(0.5, nil, {})
    t.near(c11.missionElapsed, 0.5, 1e-9, 'mode tick drives campaign')
    c11:completeMission()
    t.eq(c11.state, 'won', 'manual complete still works under mode')

    ---------------------------------------------------------------------
    t.describe('restart and fail')

    local c12 = Campaign.new{
        missions = {
            { id = 'a', map = 'a' },
            { id = 'b', map = 'b' },
        },
    }
    c12:start()
    c12:tick(2)
    c12:addKill(1)
    c12:restartMission()
    t.eq(c12.index, 1, 'still on first')
    t.eq(c12.stats[1].kills, 0, 'stats reset on restart')
    t.near(c12.missionElapsed, 0, 1e-9, 'timer reset')
    c12:failMission('give_up')
    t.eq(c12.state, 'lost', 'failed')
    t.eq(c12.stats[1].reason, 'give_up', 'custom fail reason')

    -- Double-complete is a no-op.
    local was = c12.state
    c12:completeMission()
    t.eq(c12.state, was, 'no complete after terminal lose')
end
