--[[
    Templates: the registry resolves base chains, subsets inherit and override,
    every template validates, and the honesty flags are consistent.
]]

return function(t)
    local Template = require('meatray.game.template')
    local Game = require('meatray.game')

    t.eq(Game.template, Template, 'Game.template is the module')

    ---------------------------------------------------------------------
    t.describe('listing and lookup')

    local names = Template.list()
    t.ok(#names >= 7, ('the requested genres are present (%d)'):format(#names))
    for _, want in ipairs({ 'fps', 'tdm', 'coop', 'rpg', 'crawler',
                            'turnrpg', 'vn', 'mmo' }) do
        t.eq(Template.exists(want), true, want .. ' is a registered template')
    end
    t.eq(Template.exists('nonesuch'), false, 'and an unknown one is not')

    ---------------------------------------------------------------------
    t.describe('a root template resolves to itself')

    local fps = Template.resolve('fps')
    t.eq(fps.mode, 'deathmatch', 'FPS is deathmatch')
    t.eq(fps.movement, 'fps', 'with free-look movement')
    t.eq(fps.combat, 'realtime', 'and real-time combat')
    t.eq(fps.ready, 'playable', 'and it is playable now')
    t.ok(#fps.loadout >= 2, 'with a starting loadout')

    ---------------------------------------------------------------------
    t.describe('a subset inherits what it does not override')

    local tdm = Template.resolve('tdm')
    t.eq(tdm.mode, 'teamDeathmatch', 'TDM overrides the mode')
    t.ok(tdm.teams and #tdm.teams == 2, 'and adds teams')
    -- Inherited from FPS, untouched:
    t.eq(tdm.movement, 'fps', 'but inherits FPS movement')
    t.eq(tdm.combat, 'realtime', 'and combat')
    t.eq(#tdm.loadout, #Template.resolve('fps').loadout,
         'and the whole FPS loadout, unchanged')

    -- The subset relationship is a fact in the data.
    t.eq(Template.isSubsetOf('tdm', 'fps'), true, 'TDM is a subset of FPS')
    t.eq(Template.isSubsetOf('coop', 'fps'), true, 'so is co-op')
    t.eq(Template.isSubsetOf('crawler', 'rpg'), true, 'the crawler is a subset of RPG')
    t.eq(Template.isSubsetOf('mmo', 'rpg'), true, 'and so is the MMO')
    t.eq(Template.isSubsetOf('fps', 'tdm'), false, 'but FPS is not a subset of TDM')
    t.eq(Template.isSubsetOf('fps', 'rpg'), false, 'nor of an unrelated root')

    ---------------------------------------------------------------------
    t.describe('a two-hop chain merges root, middle, leaf')

    -- crawler → rpg (root). crawler overrides movement (grid) and mode (coop);
    -- everything else comes from rpg.
    local crawler = Template.resolve('crawler')
    t.eq(crawler.movement, 'grid', 'the crawler steps on a grid')
    t.eq(crawler.mode, 'coop', 'and is co-op')
    t.eq(crawler.rpgStats, true, 'but inherits RPG stats from its base')
    t.eq(crawler.combat, 'realtime', 'and real-time combat')
    t.ok(crawler.chainNames and #crawler.chainNames == 2,
         'the resolved config records its two-template chain')

    ---------------------------------------------------------------------
    t.describe('every template validates')

    local allOk, bad = Template.validateAll()
    local detail = ''
    if not allOk then
        for name, errs in pairs(bad) do
            detail = detail .. ('\n  %s: %s'):format(name, table.concat(errs, '; '))
        end
    end
    t.eq(allOk, true, 'no template is malformed or dangling' .. detail)

    ---------------------------------------------------------------------
    t.describe('validation catches the mistakes it exists to catch')

    -- Poke a bad template in and confirm each rule bites, then restore.
    local saved = Template.KINDS.badtest

    Template.KINDS.badtest = { name = 'bad', mode = 'nonsense',
                               movement = 'fps', combat = 'realtime',
                               ready = 'playable' }
    t.eq(select(1, Template.validate('badtest')), false, 'a bad mode fails')

    Template.KINDS.badtest = { name = 'bad', mode = 'teamDeathmatch',
                               movement = 'fps', combat = 'realtime',
                               ready = 'playable' }         -- team mode, no teams
    t.eq(select(1, Template.validate('badtest')), false,
         'a team mode with no teams fails')

    Template.KINDS.badtest = { name = 'bad', mode = 'sp', movement = 'static',
                               combat = 'none', ready = 'playable',
                               loadout = { { item = 'gun', count = 1 } } }
    t.eq(select(1, Template.validate('badtest')), false,
         'combat=none with a loadout fails — a contradiction')

    Template.KINDS.badtest = saved     -- nil, removing it
    t.eq(Template.exists('badtest'), false, 'and the poke is cleaned up')

    ---------------------------------------------------------------------
    t.describe('a base cycle is caught, not looped forever')

    Template.KINDS.loopa = { name = 'a', base = 'loopb', mode = 'sp',
                             movement = 'fps', combat = 'none', ready = 'scaffold' }
    Template.KINDS.loopb = { name = 'b', base = 'loopa', mode = 'sp',
                             movement = 'fps', combat = 'none', ready = 'scaffold' }
    t.eq(select(1, Template.resolve('loopa')), nil, 'a cyclic base resolves to nil')
    t.ok(select(2, Template.resolve('loopa')):find('cycle'), 'with a cycle reason')
    Template.KINDS.loopa, Template.KINDS.loopb = nil, nil

    ---------------------------------------------------------------------
    t.describe('honesty flags are consistent')

    -- A scaffold must SAY what it needs; a playable one claims nothing missing.
    for _, name in ipairs(Template.list()) do
        local cfg = Template.resolve(name)
        if cfg.ready == 'scaffold' then
            t.ok(cfg.needs and #cfg.needs > 0,
                 name .. ' is a scaffold and lists what it needs')
        end
    end

    -- The playable set is the FPS family plus the crawler — the genres the
    -- existing systems fully assemble.
    for _, name in ipairs({ 'fps', 'tdm', 'coop', 'crawler' }) do
        t.eq(Template.resolve(name).ready, 'playable', name .. ' is playable now')
    end
    for _, name in ipairs({ 'rpg', 'turnrpg', 'vn', 'mmo' }) do
        t.eq(Template.resolve(name).ready, 'scaffold',
             name .. ' is honestly a scaffold')
    end

    ---------------------------------------------------------------------
    t.describe('summary lines are readable')

    local s = Template.summary('vn')
    t.ok(s:find('vn'), 'names the template')
    t.ok(s:find('scaffold'), 'and its readiness')
    t.ok(s:find('needs'), 'and what a scaffold still needs')
end
