--[[
    Stock game modes: deathmatch, team DM, co-op, single-player objectives.
]]

return function(t)
    local Modes = require('meatray.game.modes')
    local Game  = require('meatray.game')

    t.eq(Game.modes, Modes, 'Game.modes is stock modes module')
    t.eq(#Modes.names(), 4, 'four stock names')

    ---------------------------------------------------------------------
    t.describe('deathmatch frag limit and scoring')

    local ended = {}
    local dm = Modes.deathmatch{
        fragLimit = 3,
        scorePerKill = 1,
        scorePerSuicide = -1,
        onRoundEnd = function(m, result) ended[#ended + 1] = result end,
    }
    dm:start()
    t.eq(dm:phase(), 'live', 'starts live without warmup')
    dm:playerJoin(1, { id = 1 })
    dm:playerJoin(2, { id = 2 })
    t.eq(dm:playerCount(), 2, 'two players')

    dm:recordKill(1, 2)
    t.eq(dm.score[1], 1, 'killer scored')
    t.eq(dm:getPlayer(1).frags, 1, 'frag counted')
    t.eq(dm:getPlayer(2).deaths, 1, 'death counted')

    dm:recordKill(1, 2)
    dm:recordKill(1, 2)
    t.eq(dm.state, 'ended', 'fraglimit ends match')
    t.eq(ended[1].reason, 'fraglimit', 'reason fraglimit')
    t.eq(ended[1].winner, 1, 'winner peer 1')
    t.eq(dm:standings()[1].peer, 1, 'standings lead')

    ---------------------------------------------------------------------
    t.describe('deathmatch time limit and suicide')

    local dm2 = Modes.deathmatch{ timeLimit = 5, fragLimit = 99 }
    dm2:start()
    dm2:playerJoin(7)
    dm2:recordKill(nil, 7) -- suicide / world kill
    t.eq(dm2.score[7], -1, 'suicide penalty')
    t.eq(dm2:getPlayer(7).suicides, 1, 'suicide counted')
    dm2:tick(4.5)
    t.eq(dm2.state, 'running', 'under time limit')
    t.eq(dm2:phase(), 'live', 'still live')
    dm2:tick(1.0)
    t.eq(dm2:phase(), 'ended', 'time ends')
    t.eq(dm2.data.result.reason, 'time', 'time reason')

    ---------------------------------------------------------------------
    t.describe('warmup then live')

    local dm3 = Modes.deathmatch{ warmup = 2, fragLimit = 1 }
    dm3:start()
    t.eq(dm3:phase(), 'warmup', 'warmup phase')
    dm3:playerJoin(1)
    dm3:playerJoin(2)
    local r = dm3:recordKill(1, 2)
    t.eq(r, nil, 'no score in warmup')
    t.eq(dm3.score[1] or 0, 0, 'no points in warmup')
    dm3:tick(2.1)
    t.eq(dm3:phase(), 'live', 'live after warmup')
    dm3:recordKill(1, 2)
    t.eq(dm3.data.result.reason, 'fraglimit', 'scores after warmup')

    ---------------------------------------------------------------------
    t.describe('team deathmatch')

    local tdm = Modes.teamDeathmatch{
        teams = { 'red', 'blue' },
        fragLimit = 2,
        autoBalance = true,
    }
    tdm:start()
    tdm:playerJoin(1)
    tdm:playerJoin(2)
    tdm:playerJoin(3)
    -- Auto-balance should spread across teams.
    local redN = #tdm.data.teams.red.players
    local blueN = #tdm.data.teams.blue.players
    t.eq(redN + blueN, 3, 'all assigned')
    t.ok(math.abs(redN - blueN) <= 1, 'balanced within 1')

    tdm:assignTeam(1, 'red')
    tdm:assignTeam(2, 'blue')
    tdm:assignTeam(3, 'red')
    tdm:recordKill(1, 2) -- red scores
    t.eq(tdm.data.teams.red.score, 1, 'red team score')
    tdm:recordKill(1, 2)
    t.eq(tdm.data.result.reason, 'fraglimit', 'team fraglimit')
    t.eq(tdm.data.result.winningTeam, 'red', 'red wins')

    -- Team kill penalty.
    local tdm2 = Modes.teamDeathmatch{ teams = { 'red', 'blue' }, fragLimit = 50 }
    tdm2:start()
    tdm2:playerJoin(1)
    tdm2:playerJoin(2)
    tdm2:assignTeam(1, 'red')
    tdm2:assignTeam(2, 'red')
    tdm2:recordKill(1, 2)
    t.eq(tdm2.score[1], -1, 'teamkill penalty')
    t.eq(tdm2:getPlayer(1).frags, 0, 'no frag for teamkill')

    ---------------------------------------------------------------------
    t.describe('co-op clear and wipe')

    local enemies = {
        { id = 1, dead = false, components = { ai = {} } },
        { id = 2, dead = false, components = { ai = {} } },
    }
    local heroes = {
        { id = 10, dead = false, components = { player = {} } },
    }
    local coop = Modes.coop{
        winWhenAllDead = true,
        failOnAllPlayersDead = true,
    }
    coop:start(nil, enemies)
    coop:playerJoin(1, heroes[1])
    t.eq(coop:phase(), 'live', 'coop live')
    coop:tick(0.1, nil, enemies)
    t.eq(coop.state, 'running', 'enemies alive')
    enemies[1].dead = true
    enemies[2].dead = true
    coop:tick(0.1, nil, enemies)
    t.eq(coop.data.result.reason, 'clear', 'cleared map')

    local coop2 = Modes.coop{ winWhenAllDead = false }
    local p1 = { id = 1, dead = false, components = { player = {} } }
    local p2 = { id = 2, dead = false, components = { player = {} } }
    coop2:start()
    coop2:playerJoin(1, p1)
    coop2:playerJoin(2, p2)
    p1.dead = true
    p2.dead = true
    coop2:tick(0.1, nil, { p1, p2 })
    t.eq(coop2.data.result.reason, 'wipe', 'all players dead')

    -- Empty enemy list at start does not auto-win.
    local coop3 = Modes.coop{ winWhenAllDead = true }
    coop3:start(nil, {})
    coop3:tick(0.1, nil, {})
    t.eq(coop3.state, 'running', 'no instant clear')

    ---------------------------------------------------------------------
    t.describe('co-op / SP objectives')

    local sp = Modes.singlePlayer{
        peerId = 0,
        player = { id = 1, dead = false },
        failOnDeath = true,
        objectives = {
            { id = 'kills', type = 'kills', count = 2 },
            { id = 'extract', type = 'flag', key = 'exit' },
        },
    }
    sp:start()
    t.eq(sp:phase(), 'live', 'sp live')
    sp:recordKill(0, nil, { enemy = true })
    t.eq(sp:getObjectives()[1].progress, 1, 'kill progress 1')
    t.eq(sp.state, 'running', 'need more objectives')
    sp:recordKill(0, nil, { enemy = true })
    t.ok(sp:getObjectives()[1].done, 'kills done')
    t.eq(sp.state, 'running', 'still need extract')
    sp:setObjectiveFlag('exit')
    t.eq(sp.data.result.reason, 'objectives', 'all objectives complete')

    local sp2 = Modes.singlePlayer{
        peerId = 0,
        failOnDeath = true,
        getPlayer = function() return { dead = true } end,
        objectives = { { id = 'wait', type = 'survive', duration = 99 } },
    }
    sp2:start()
    sp2:tick(0.1)
    t.eq(sp2.data.result.reason, 'death', 'sp death fail')

    local sp3 = Modes.singlePlayer{
        failOnDeath = false,
        objectives = { { id = 'hold', type = 'survive', duration = 3 } },
    }
    sp3:start()
    sp3:tick(1.5)
    t.eq(sp3.state, 'running', 'surviving')
    sp3:tick(2.0)
    t.eq(sp3.data.result.reason, 'objectives', 'survive objective')

    local sp4 = Modes.singlePlayer{
        failOnDeath = false,
        objectives = {
            { id = 'boss', type = 'custom', check = function(m)
                return m.data.bossDown
            end },
        },
    }
    sp4:start()
    sp4:tick(0.1)
    t.eq(sp4.state, 'running', 'boss up')
    sp4.data.bossDown = true
    sp4:tick(0.1)
    t.eq(sp4.data.result.reason, 'objectives', 'custom check')

    ---------------------------------------------------------------------
    t.describe('byName registry')

    local a = Modes.byName('dm', { fragLimit = 10 })
    t.eq(a.name, 'deathmatch', 'dm alias')
    local b, err = Modes.byName('nope')
    t.eq(b, nil, 'unknown nil')
    t.ok(err:find('unknown'), 'unknown err')
    local c = Modes.byName('team-deathmatch', { teams = { 'a', 'b' } })
    t.eq(c.data.rules.kind, 'team_deathmatch', 'normalized name')

    ---------------------------------------------------------------------
    t.describe('post delay and leave')

    local dm4 = Modes.deathmatch{
        fragLimit = 1,
        postDelay = 2,
    }
    dm4:start()
    dm4:playerJoin(1)
    dm4:playerJoin(2)
    dm4:recordKill(1, 2)
    t.eq(dm4:phase(), 'post', 'post phase')
    t.eq(dm4.state, 'running', 'still running during post')
    dm4:tick(2.1)
    t.eq(dm4.state, 'ended', 'stopped after post')

    local dm5 = Modes.deathmatch{}
    dm5:start()
    dm5:playerJoin(9)
    t.eq(dm5:playerCount(), 1, 'one')
    dm5:playerLeave(9)
    t.eq(dm5:playerCount(), 0, 'left')
    t.eq(dm5:getPlayer(9), nil, 'roster cleared')
end
