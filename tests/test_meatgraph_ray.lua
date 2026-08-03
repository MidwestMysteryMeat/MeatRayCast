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

    ---------------------------------------------------------------------
    t.describe('G4: graph randomness is the engine LCG, never math.random')

    -- math.random is forbidden here because its sequence differs between Lua
    -- builds and cannot be replayed — a graph on the host is inside the demo
    -- recording stream. Prove it is never consulted by making it fatal.
    local realRandom = math.random
    math.random = function() error('math.random consulted', 2) end

    local okDraw, drawn = pcall(function()
        local api = BP.apiFor{ seed = 42 }
        local out = {}
        for i = 1, 5 do out[i] = api.randi(1, 1000) end
        return out
    end)
    math.random = realRandom
    t.ok(okDraw, 'randi never touches math.random', tostring(drawn))

    -- Two hosts built from the same seed draw the same stream; a different
    -- seed diverges. That is the whole determinism contract.
    local a = BP.apiFor{ seed = 42 }
    local b = BP.apiFor{ seed = 42 }
    local c = BP.apiFor{ seed = 43 }
    local same, diff = true, false
    for _ = 1, 20 do
        local va, vb, vc = a.randi(1, 1e6), b.randi(1, 1e6), c.randi(1, 1e6)
        if va ~= vb then same = false end
        if va ~= vc then diff = true end
    end
    t.eq(same, true, 'same seed, same stream')
    t.eq(diff, true, 'different seed, different stream')

    -- An injected rng wins over the seed — the demo layer's hook.
    local fixed = { int = function(_, lo) return lo end }
    local injected = BP.apiFor{ seed = 42, rng = fixed }
    t.eq(injected.randi(7, 99), 7, 'an injected rng is used verbatim')

    -- A bound mode keeps ONE generator across api rebuilds. bindMode
    -- memoizes it onto the apiOpts table precisely because makeApi rebuilds
    -- the api per event — a per-call rng would reset to the seed on every
    -- fire and every Randi would draw the same first number forever.
    local Mode = require('meatray.game.mode')
    local rmode = Mode.new{ name = 'rng' }
    local rgraph = BP.fromTable{
        name = 'roll',
        nodes = { { id = 1, kind = 'EventOnInit' } },
        links = {},
    }
    local apiOpts = { seed = 90599143 }
    BP.bindMode(rmode, rgraph, apiOpts)
    t.ok(apiOpts.rng and apiOpts.rng.int, 'bindMode installs one generator')
    local r1 = BP.apiFor{ rng = apiOpts.rng }.randi(1, 1000000)
    local r2 = BP.apiFor{ rng = apiOpts.rng }.randi(1, 1000000)
    t.ok(r1 ~= r2,
         'the generator advances across api rebuilds instead of resetting')

    ---------------------------------------------------------------------
    t.describe('F9: the sandbox validates an untrusted graph')

    -- The full known vocabulary is categorised, so validate can reason about
    -- what a node DOES, not just its name.
    t.ok(BP.KIND_CATEGORY.EventOnInit == 'event', 'events are categorised')
    t.ok(BP.KIND_CATEGORY.ConstInt == 'data', 'reads/maths are data')
    t.ok(BP.KIND_CATEGORY.ActionSpawnEntity == 'action', 'mutations are actions')

    local safe = BP.fromTable{
        name = 'safe',
        nodes = {
            { id = 1, kind = 'EventOnInit' },
            { id = 2, kind = 'ActionLog', strA = 'hi' },
        },
        links = { { id = 1, fromNode = 1, fromPin = 0, toNode = 2, toPin = 0 } },
    }
    t.eq(select(1, BP.validate(safe)), true, 'a graph of known kinds validates')

    -- A hostile/typo kind is rejected before it runs.
    local bad = BP.fromTable{
        name = 'bad',
        nodes = { { id = 1, kind = 'EventOnInit' },
                  { id = 2, kind = 'ActionReadFile' } },   -- not in the vocabulary
        links = {},
    }
    local okBad, errsBad = BP.validate(bad)
    t.eq(okBad, false, 'an unknown node kind is refused')
    t.ok(table.concat(errsBad, ' '):find('ActionReadFile'), 'and named')

    -- A category policy: a display-only mod may read and decide, not mutate.
    local mutating = BP.fromTable{
        name = 'mut',
        nodes = { { id = 1, kind = 'EventOnInit' },
                  { id = 2, kind = 'ActionSpawnEntity' } },
        links = {},
    }
    t.eq(select(1, BP.validate(mutating, { categories = { 'event', 'data' } })),
         false, 'an action node fails a data-only policy')
    t.eq(select(1, BP.validate(mutating, { categories = { 'event', 'action' } })),
         true, 'and passes when actions are allowed')

    -- An explicit allowlist.
    t.eq(select(1, BP.validate(safe, { allow = { 'EventOnInit' } })),
         false, 'a node off the explicit allowlist fails')
    t.eq(select(1, BP.validate(safe, { allow = { 'EventOnInit', 'ActionLog' } })),
         true, 'and passes when every kind is listed')

    -- Size caps.
    t.eq(select(1, BP.validate(safe, { maxNodes = 1 })), false,
         'over the node cap fails')

    t.eq(select(1, BP.validate({ nodes = 'nope' })), false,
         'a non-graph is refused, not crashed')

    ---------------------------------------------------------------------
    t.describe('F9: the step budget bounds a fire')

    -- harden validates then records the budget; a passing graph fires bounded.
    local hardened, herr = BP.harden(safe, { maxSteps = 100 })
    t.ok(hardened, 'a safe graph hardens' .. (hardened and '' or (': ' ..
         table.concat(herr or {}, '; '))))
    t.eq(BP.harden(bad), nil, 'a bad graph does not harden')

    -- A graph whose data chain is longer than the budget trips it and stops.
    -- Build a chain of MathAdd nodes feeding a log, then set a tiny budget.
    local chainNodes = { { id = 1, kind = 'EventOnInit' },
                         { id = 100, kind = 'ActionLog', strA = 'end' } }
    local chainLinks = { { id = 1, fromNode = 1, fromPin = 0,
                           toNode = 100, toPin = 0 } }
    for i = 2, 20 do
        chainNodes[#chainNodes + 1] = { id = i, kind = 'MathAdd', intB = 1 }
        chainLinks[#chainLinks + 1] = { id = i, fromNode = i - 1, fromPin = 1,
                                        toNode = i, toPin = 0, data = true }
    end
    -- The last MathAdd feeds the log's message input.
    chainLinks[#chainLinks + 1] = { id = 999, fromNode = 20, fromPin = 1,
                                    toNode = 100, toPin = 2, data = true }
    local chain = BP.fromTable{ name = 'chain', nodes = chainNodes, links = chainLinks }

    local logged = {}
    chain:fire('init', BP.apiFor{ log = function(m) logged[#logged + 1] = m end },
               {}, { maxSteps = 3 })
    t.eq(chain._budgetExceeded, true, 'a tiny budget is exceeded and flagged')

    -- A generous budget completes.
    logged = {}
    chain:fire('init', BP.apiFor{ log = function(m) logged[#logged + 1] = m end },
               {}, { maxSteps = 1000 })
    t.eq(chain._budgetExceeded, false, 'a generous budget is not exceeded')

    -- The demo's own example graph validates and hardens (anti-rot).
    local example = BP.example()
    t.eq(select(1, BP.validate(example)), true,
         'the built-in example graph validates clean')
end
