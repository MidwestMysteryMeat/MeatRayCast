--[[
    Host-side node graphs (MeatEngine C6-compatible JSON + raycast actions).
]]

return function(t)
    local BP = require('meatray.game.meatgraph_ray')
    local Mode = require('meatray.game.mode')
    local Worldgen = require('meatray.sim.worldgen')
    local Entity = require('meatray.sim.entity')
    local C = require('meatray.sim.components')

    ---------------------------------------------------------------------
    t.describe('example graph fires init log')

    local notes = {}
    local g = BP.example()
    t.ok(g ~= nil, 'example builds')
    t.ok(g:hasEvent('init'), 'has init')
    t.ok(g:hasEvent('tick'), 'has tick')

    local api = BP.apiFor{
        notes = notes,
        playerCount = function() return 2 end,
    }
    t.eq(g:fire('init', api, { seed = 7 }), true, 'init fires')
    t.ok(#notes >= 1, 'logged on init')
    t.eq(notes[1], 'node graph world init', 'init message')

    notes = {}
    api = BP.apiFor{ notes = notes, playerCount = function() return 2 end }
    g:fire('tick', api, { t = 0.016 })
    t.ok(#notes >= 1, 'tick logs when players > 0')
    t.eq(notes[1], 'players online', 'branch true path')

    notes = {}
    api = BP.apiFor{ notes = notes, playerCount = function() return 0 end }
    g:fire('tick', api, { t = 0.016 })
    t.eq(#notes, 0, 'tick silent when no players')

    ---------------------------------------------------------------------
    t.describe('JSON round-trip preserves structure')

    local text = BP.save(g)
    t.ok(type(text) == 'string' and #text > 20, 'encodes JSON')
    local g2, err = BP.load(text)
    t.ok(g2 ~= nil, 'loads back', err)
    t.eq(g2:nodeCount(), g:nodeCount(), 'same node count')
    t.eq(g2.name, 'demo', 'name preserved')

    notes = {}
    g2:fire('init', BP.apiFor{ notes = notes }, {})
    t.eq(notes[1], 'node graph world init', 'round-trip still runs')

    ---------------------------------------------------------------------
    t.describe('raycast actions: door and floor')

    local world = Worldgen.box(12, 12)
    world:addDoor(5, 5, false)
    t.eq(world:doorAt(5, 5).open, false, 'door starts shut')

    local doorGraph = BP.fromTable{
        name = 'doors',
        nodes = {
            { id = 1, kind = 'EventOnInit' },
            { id = 2, kind = 'ActionOpenDoor', intA = 5, intB = 5 },
            { id = 3, kind = 'ActionSetFloor', intA = 3, intB = 3, floatA = 0.4 },
        },
        links = {
            { id = 1, fromNode = 1, fromPin = 0, toNode = 2, toPin = 0 },
            { id = 2, fromNode = 2, fromPin = 1, toNode = 3, toPin = 0 },
        },
    }
    doorGraph:fire('init', BP.apiFor{ world = world }, {})
    t.eq(world:doorAt(5, 5).open, true, 'graph opened the door')
    t.near(world:floorHeightAt(3, 3), 0.4, 1e-9, 'and raised a floor tile')

    ---------------------------------------------------------------------
    t.describe('spawn entity action')

    Entity.clearArchetypes()
    Entity.archetype('crystal', function(e)
        e:add(C.Health{ hp = 1, max = 1 })
    end)
    local bag = {}
    local spawnG = BP.fromTable{
        nodes = {
            { id = 1, kind = 'EventOnInit' },
            { id = 2, kind = 'ActionSpawnEntity', strA = 'crystal', floatA = 4.5, intA = 5.5 },
        },
        links = {
            { id = 1, fromNode = 1, fromPin = 0, toNode = 2, toPin = 0 },
        },
    }
    -- intA is integer in normalize; use float pins via floatA for x and intA for y
    -- (y becomes 5 after tonumber of intA=5.5 -> wait normalize uses tonumber so 5.5 ok)
    spawnG.nodes[2].intA = 5.5
    spawnG:fire('init', BP.apiFor{
        entities = bag,
        Entity = Entity,
    }, {})
    t.eq(#bag, 1, 'spawned one entity')
    t.eq(bag[1].kind, 'crystal', 'correct archetype')
    t.near(bag[1].x, 4.5, 1e-9, 'x from floatA')

    ---------------------------------------------------------------------
    t.describe('Mode bind fires init and join')

    notes = {}
    local mode = Mode.new{ name = 'bp-test' }
    local graph = BP.example()
    BP.bindMode(mode, graph, { notes = notes, playerCount = function() return 1 end })
    mode:start(world, bag)
    t.ok(#notes >= 1, 'mode start runs graph init')

    local before = #notes
    mode:playerJoin(3, bag[1])
    t.ok(#notes > before, 'join event logged')

    mode:tick(0.1, world, bag)
    t.ok(true, 'tick with bound graph does not raise')

    ---------------------------------------------------------------------
    t.describe('MeatEngine kind names accepted')

    local me = BP.fromTable{
        nodes = {
            { id = 1, kind = 'EventOnInit' },
            { id = 2, kind = 'ActionLog', strA = 'from meatengine names' },
            { id = 3, kind = 'ConstInt', intA = 3 },
            { id = 4, kind = 'ConstInt', intA = 4 },
            { id = 5, kind = 'MathAdd' },
        },
        links = {
            { id = 1, fromNode = 1, fromPin = 0, toNode = 2, toPin = 0 },
            { id = 2, fromNode = 3, fromPin = 0, toNode = 5, toPin = 0 },
            { id = 3, fromNode = 4, fromPin = 0, toNode = 5, toPin = 1 },
        },
    }
    -- MathAdd is pure; only assert log chain still works with shared names.
    notes = {}
    me:fire('init', BP.apiFor{ notes = notes }, {})
    t.eq(notes[1], 'from meatengine names', 'shared kind strings work')

    ---------------------------------------------------------------------
    t.describe('volumes install and fire trigger events')

    Entity.clearArchetypes()
    Entity.archetype('hero', function(e)
        e:add(C.Player{ peerId = 1, name = 'p' })
    end)
    local hero = Entity.spawn('hero', 0.5, 0.5)
    hero.id = 42

    notes = {}
    local trigGraph = BP.fromTable{
        name = 'zones',
        volumes = {
            { name = 'pad', tx1 = 3, ty1 = 3, tx2 = 4, ty2 = 4, filter = 'player' },
        },
        nodes = {
            { id = 1, kind = 'EventOnTrigger', strA = 'pad' },
            { id = 2, kind = 'ActionLog', strA = 'on pad' },
            { id = 3, kind = 'EventOnTriggerExit', strA = 'pad' },
            { id = 4, kind = 'ActionLog', strA = 'left pad' },
            { id = 5, kind = 'ActionLogOnce', strA = 'once only' },
        },
        links = {
            { id = 1, fromNode = 1, fromPin = 0, toNode = 2, toPin = 0 },
            { id = 2, fromNode = 2, fromPin = 1, toNode = 5, toPin = 0 },
            { id = 3, fromNode = 3, fromPin = 0, toNode = 4, toPin = 0 },
        },
    }

    local mode2 = Mode.new{ name = 'trig' }
    BP.bindMode(mode2, trigGraph, {
        notes = notes,
        triggers = true,
        playerCount = function() return 1 end,
    })
    local ents = { hero }
    mode2:start(world, ents)
    t.eq(mode2.data._ngVolumeCount, 1, 'one volume installed')

    -- Tile (3,3) spans world [2,3]x[2,3]; centre is ~2.5,2.5
    hero.x, hero.y = 2.5, 2.5
    mode2:tick(1 / 60, world, ents)
    t.ok(#notes >= 1, 'enter logged')
    local sawPad = false
    for i = 1, #notes do if notes[i] == 'on pad' then sawPad = true end end
    t.ok(sawPad, 'EventOnTrigger matched volume name')

    local nAfterEnter = #notes
    mode2:tick(1 / 60, world, ents) -- stay, LogOnce should not re-fire enter chain
    -- enter only once; stay does not re-fire EventOnTrigger
    hero.x, hero.y = 9, 9
    mode2:tick(1 / 60, world, ents)
    local sawLeave = false
    for i = nAfterEnter, #notes do
        if notes[i] == 'left pad' then sawLeave = true end
    end
    t.ok(sawLeave, 'EventOnTriggerExit fired on leave')

    ---------------------------------------------------------------------
    t.describe('ActionLogOnce only once')

    notes = {}
    local onceG = BP.fromTable{
        nodes = {
            { id = 1, kind = 'EventOnInit' },
            { id = 2, kind = 'ActionLogOnce', strA = 'hello once' },
        },
        links = {
            { id = 1, fromNode = 1, fromPin = 0, toNode = 2, toPin = 0 },
        },
    }
    local apiOnce = BP.apiFor{ notes = notes }
    onceG:fire('init', apiOnce, {})
    onceG:fire('init', apiOnce, {})
    local count = 0
    for i = 1, #notes do if notes[i] == 'hello once' then count = count + 1 end end
    t.eq(count, 1, 'LogOnce ignores second fire')

    ---------------------------------------------------------------------
    t.describe('give item and damage actions')

    Entity.clearArchetypes()
    Entity.archetype('hero', function(e)
        e:add(C.Player{ peerId = 1, name = 'p' })
        e:add(C.Health{ hp = 50, max = 50 })
    end)
    local Inventory = require('meatray.game.inventory')
    Inventory.defineItem('ammo.mgtest', { stack = 99 })

    local bagman = Entity.spawn('hero', 2, 2)
    bagman.id = 99
    Inventory.attach(bagman, { capacity = 8 })

    local giveG = BP.fromTable{
        nodes = {
            { id = 1, kind = 'EventOnInit' },
            { id = 2, kind = 'ActionGiveItem', strA = 'ammo.mgtest', intA = 12 },
            { id = 3, kind = 'ActionDamage', intA = 15 },
        },
        links = {
            { id = 1, fromNode = 1, fromPin = 0, toNode = 2, toPin = 0 },
            { id = 2, fromNode = 2, fromPin = 1, toNode = 3, toPin = 0 },
        },
    }
    giveG:fire('init', BP.apiFor{
        entities = { bagman },
        entity = bagman,
    }, { entityId = 99 })
    t.ok(Inventory.count(bagman, 'ammo.mgtest') >= 1, 'giveItem added ammo')
    t.ok(bagman:get('health').hp < 50, 'damage reduced health',
         tostring(bagman:get('health').hp))

    ---------------------------------------------------------------------
    t.describe('explode and seed gas')

    local Gas = require('meatray.game.gas')
    local field = Gas.new{ world = world, name = 'testgas', listen = false }
    local boom = BP.fromTable{
        nodes = {
            { id = 1, kind = 'EventOnInit' },
            { id = 2, kind = 'ActionExplode', floatA = 5.5, intA = 5, intB = 2, intC = 5 },
            { id = 3, kind = 'ActionSeedGas', intA = 5, intB = 5, floatA = 2 },
        },
        links = {
            { id = 1, fromNode = 1, fromPin = 0, toNode = 2, toPin = 0 },
            { id = 2, fromNode = 2, fromPin = 1, toNode = 3, toPin = 0 },
        },
    }
    local dummy = Entity.spawn('hero', 5.5, 5.5)
    dummy.id = 7
    boom:fire('init', BP.apiFor{
        world = world,
        entities = { dummy },
        gas = field,
    }, {})
    t.ok(true, 'explode + seedGas do not raise')
    t.ok(field:densityAt(5, 5) > 0, 'gas was seeded at tile',
         tostring(field:densityAt(5, 5)))
end
