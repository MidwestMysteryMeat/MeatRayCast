--[[
    Attributes: the modifier order, the ranges, the refusals, and the fact that
    an attribute is a component and therefore replicates and saves for free.

    Two things here are load-bearing beyond their size:

      * The fold must not depend on table iteration. A modifier set assembled in
        a different order on a host and a client is not a hypothetical — it is
        what `pairs()` does — and a stat that differs by a float in the last
        place is a correction the player sees.

      * Nothing non-finite may ever be stored. NaN survives every comparison a
        naive clamp makes (`nan < max` is false, so is `nan > min`), so it
        reaches the wire and then every other player.
]]

return function(t)
    local Entity     = require('meatray.sim.entity')
    local C          = require('meatray.sim.components')
    local Worldgen   = require('meatray.sim.worldgen')
    local Attributes = require('meatray.game.attributes')

    Attributes.reset()

    ---------------------------------------------------------------------
    t.describe('the engine reconciles with the existing Health component')

    local healthDef = Attributes.definition('health')
    t.eq(healthDef.componentName, 'health', 'health uses the sim component, not a new one')
    t.eq(healthDef.base, 'hp', 'its base is the existing hp field')
    t.eq(healthDef.cur, 'hp', 'and so is its current value: health is a pool')
    t.ok(healthDef.pool, 'health is declared a pool')

    local maxDef = Attributes.definition('healthMax')
    t.eq(maxDef.componentName, 'health', 'healthMax lives on the same component')
    t.eq(maxDef.cur, 'max', 'and its current value is the existing max field')

    -- The one field the attribute system added, through the declaration
    -- mechanism rather than by editing components.lua.
    local declared = {}
    for _, f in ipairs(C.Health.netFields) do declared[f] = true end
    t.ok(declared.hp and declared.max, 'the original fields are untouched')
    t.ok(declared.maxBase, 'and maxBase was declared, so it replicates and saves')

    t.ok(not Attributes.declareField(C.Health, 'maxBase'),
         'declaring the same field twice is a no-op, not a duplicate')

    ---------------------------------------------------------------------
    t.describe('an entity built the old way is adopted, not rebuilt')

    Entity.resetIds(1)
    local old = Entity.new{ kind = 'imp' }
    old:add(C.Health{ hp = 30, max = 30 })      -- exactly what main.lua writes

    t.ok(Attributes.has(old, 'health'), 'the attribute system sees health')
    t.eq(Attributes.get(old, 'health'), 30, 'and reads the existing hp')
    t.eq(Attributes.get(old, 'healthMax'), 30, 'and the existing max')
    t.eq(Attributes.base(old, 'healthMax'), 30,
         'maxBase is filled in from max on first touch')

    ---------------------------------------------------------------------
    t.describe('granting and reading')

    local e = Entity.new{}
    Attributes.grantAll(e, {
        healthMax = 100, health = 100,
        armourMax = 50,  armour  = 20,
        staminaMax = 80, stamina = 80,
        moveSpeed = 4,
    })

    t.eq(Attributes.get(e, 'health'), 100, 'health granted')
    t.eq(Attributes.get(e, 'armour'), 20, 'armour granted')
    t.eq(Attributes.get(e, 'moveSpeed'), 4, 'moveSpeed granted')
    t.ok(e:has('health') and e:has('armour') and e:has('movespeed'),
         'each attribute brought its component with it')

    local bad, badErr = Attributes.grant(e, 'nonexistent', 1)
    t.ok(bad == nil and badErr:find('unknown attribute'), 'an unknown attribute is refused')

    ---------------------------------------------------------------------
    t.describe('the documented modifier order: add, then multiply, then override')

    -- 100 base, +10 additive, x2 multiplicative.
    --   additive first:       (100 + 10) * 2 = 220   <- what this engine does
    --   multiplicative first: (100 * 2) + 10 = 210
    local mods = {
        { op = 'add', magnitude = 10, ordinal = 1, index = 1 },
        { op = 'mul', magnitude = 2,  ordinal = 2, index = 1 },
    }
    t.eq(Attributes.combine(100, mods), 220, 'additive is folded before multiplicative')

    t.eq(Attributes.combine(100, {
        { op = 'add', magnitude = 10, ordinal = 1, index = 1 },
        { op = 'add', magnitude = -3, ordinal = 2, index = 1 },
    }), 107, 'additive modifiers sum')

    t.eq(Attributes.combine(100, {
        { op = 'mul', magnitude = 1.5, ordinal = 1, index = 1 },
        { op = 'mul', magnitude = 0.5, ordinal = 2, index = 1 },
    }), 75, 'multiplicative modifiers multiply')

    t.eq(Attributes.combine(100, {
        { op = 'div', magnitude = 4, ordinal = 1, index = 1 },
    }), 25, 'div folds into the same product as multiplication by its reciprocal')

    t.eq(Attributes.combine(100, {
        { op = 'div', magnitude = 0, ordinal = 1, index = 1 },
    }), 100, 'a divide by zero is dropped rather than stored as an infinity')

    t.eq(Attributes.combine(100, {
        { op = 'add', magnitude = 50, ordinal = 1, index = 1 },
        { op = 'override', magnitude = 1, ordinal = 2, index = 1 },
    }), 1, 'an override replaces the whole result')

    t.eq(Attributes.combine(100, {
        { op = 'override', magnitude = 5, ordinal = 1, index = 1, priority = 2 },
        { op = 'override', magnitude = 9, ordinal = 2, index = 1, priority = 1 },
    }), 5, 'overrides are resolved by priority, not by arrival')

    t.eq(Attributes.combine(100, {
        { op = 'override', magnitude = 5, ordinal = 1, index = 1 },
        { op = 'override', magnitude = 9, ordinal = 2, index = 1 },
    }), 9, 'and by application order when priorities tie')

    t.eq(Attributes.combine(100, nil), 100, 'no modifiers means the base')
    t.eq(Attributes.combine(100, {}), 100, 'and so does an empty list')

    ---------------------------------------------------------------------
    t.describe('the fold does not depend on table iteration order')

    -- Build a set with every op, then shuffle it repeatedly with the engine's
    -- own deterministic rng and assert the result never moves. math.random is
    -- deliberately not used: its sequence differs between Lua builds, so a test
    -- written against it would shuffle differently on the machine that has the
    -- bug.
    local rng = Worldgen.rng(20260730)
    local set = {
        { op = 'add', magnitude = 7,    ordinal = 1, index = 1 },
        { op = 'mul', magnitude = 1.25, ordinal = 2, index = 1 },
        { op = 'add', magnitude = -2,   ordinal = 3, index = 1 },
        { op = 'div', magnitude = 2,    ordinal = 4, index = 1 },
        { op = 'mul', magnitude = 3,    ordinal = 5, index = 1 },
        { op = 'add', magnitude = 0.5,  ordinal = 6, index = 1 },
    }
    local expected = Attributes.combine(64, set)

    local stable = true
    for _ = 1, 40 do
        for i = #set, 2, -1 do
            local j = rng:int(1, i)
            set[i], set[j] = set[j], set[i]
        end
        if Attributes.combine(64, set) ~= expected then stable = false end
    end
    t.ok(stable, 'forty shuffles of the same modifier set produce the identical number')
    t.near(expected, (64 + 5.5) * (1.25 * 3 / 2), 1e-12, 'and it is the documented order')

    ---------------------------------------------------------------------
    t.describe('values are clamped to their range')

    Attributes.setBase(e, 'health', 250)
    t.eq(Attributes.get(e, 'health'), 100, 'health cannot exceed healthMax')

    Attributes.setBase(e, 'health', -40)
    t.eq(Attributes.get(e, 'health'), 0, 'nor fall below its minimum')

    Attributes.setBase(e, 'health', 100)
    Attributes.setBase(e, 'healthMax', 60)
    Attributes.recompute(e, 'health', nil)
    t.eq(Attributes.get(e, 'health'), 60,
         'lowering the ceiling pulls the pool down with it')

    Attributes.setBase(e, 'healthMax', 100)
    t.eq(Attributes.limit(e, 'health'), 100, 'the limit follows the ceiling attribute')

    local speedDef = Attributes.definition('moveSpeed')
    Attributes.setBase(e, 'moveSpeed', speedDef.max * 10)
    t.eq(Attributes.get(e, 'moveSpeed'), speedDef.max, 'a stat clamps to its declared max')
    Attributes.setBase(e, 'moveSpeed', 4)

    ---------------------------------------------------------------------
    t.describe('nothing non-finite is ever stored')

    local nan = 0 / 0
    local inf = math.huge

    t.eq(Attributes.number(nan), nil, 'NaN is not a usable number')
    t.eq(Attributes.number(inf), nil, 'nor is infinity')
    t.eq(Attributes.number(-inf), nil, 'nor negative infinity')
    t.eq(Attributes.number(tonumber('1e999')), nil, 'nor an overflowed literal')
    t.eq(Attributes.number('12'), 12, 'a numeric string is')
    t.eq(Attributes.number('nope'), nil, 'a non-numeric string is not')
    t.eq(Attributes.number(1e30), nil, 'nor a value past the sanity bound')

    local before = Attributes.get(e, 'health')
    local r1, e1 = Attributes.setBase(e, 'health', nan)
    t.ok(r1 == nil and e1 ~= nil, 'setting an attribute to NaN is refused with a reason')
    t.eq(Attributes.get(e, 'health'), before, 'and the attribute is untouched')

    local r2 = Attributes.setBase(e, 'health', tonumber('1e999'))
    t.ok(r2 == nil, 'a single 1e999 is refused')
    t.eq(Attributes.get(e, 'health'), before, 'so it cannot poison the attribute')
    t.eq(Attributes.get(e, 'health') == Attributes.get(e, 'health'), true,
         'and the stored value is still equal to itself, which NaN never is')

    local r3, e3 = Attributes.applyDelta(e, 'health', inf)
    t.ok(r3 == nil and e3 ~= nil, 'a non-finite delta is refused too')

    local r4 = Attributes.grant(e, 'stamina', nan)
    t.ok(r4 == nil, 'granting NaN is refused')

    -- The fold can overflow from parts that were each fine.
    t.eq(Attributes.combine(1e14, {
        { op = 'mul', magnitude = 1e14, ordinal = 1, index = 1 },
    }), 1e14, 'a fold that overflows the sanity bound falls back to the base')

    ---------------------------------------------------------------------
    t.describe('soak: armour absorbs before health, without health knowing how')

    local s = Entity.new{}
    Attributes.grantAll(s, { healthMax = 100, health = 100, armourMax = 30, armour = 30 })

    local hit = Attributes.applyDelta(s, 'health', -20)
    t.eq(Attributes.get(s, 'armour'), 10, 'armour took all twenty')
    t.eq(Attributes.get(s, 'health'), 100, 'health took none')
    t.eq(hit.soaked, 20, 'and the result says so')
    t.eq(hit.applied, 0, 'with nothing applied to health')

    local through = Attributes.applyDelta(s, 'health', -30)
    t.eq(Attributes.get(s, 'armour'), 0, 'the next hit empties armour')
    t.eq(Attributes.get(s, 'health'), 80, 'and the remainder reaches health')
    t.eq(through.soaked, 10, 'ten was soaked')
    t.eq(through.applied, -20, 'twenty landed')

    Attributes.grant(s, 'armour', 30)
    local ignoring = Attributes.applyDelta(s, 'health', -5, { bypassSoak = true })
    t.eq(ignoring.soaked, 0, 'bypassSoak skips armour entirely')
    t.eq(Attributes.get(s, 'armour'), 30, 'so a full armour pool is untouched by it')
    t.eq(ignoring.applied, -5, 'and all five reached health')

    local healed = Attributes.applyDelta(s, 'health', 10)
    t.eq(healed.soaked, 0, 'a positive delta never touches armour')
    t.eq(Attributes.get(s, 'armour'), 30, 'armour is unchanged by healing')

    ---------------------------------------------------------------------
    t.describe('recompute order puts ceilings before what they cap')

    local ordered = Attributes.orderedNames()
    local position = {}
    for i, name in ipairs(ordered) do position[name] = i end
    t.ok(position.healthMax < position.health, 'healthMax is recomputed before health')
    t.ok(position.armourMax < position.armour, 'armourMax before armour')
    t.ok(position.staminaMax < position.stamina, 'staminaMax before stamina')

    ---------------------------------------------------------------------
    t.describe('a snapshot round-trip carries attribute state')

    Entity.clearArchetypes()
    local Fighter = Entity.archetype('fighter', function(ent)
        ent:add(C.Health{ hp = 100, max = 100 })
        Attributes.grantAll(ent, {
            healthMax = 100, health = 100,
            armourMax = 50, armour = 50,
            staminaMax = 80, stamina = 80,
            moveSpeed = 3.2,
        })
    end)

    local host = Fighter(2, 3)
    Attributes.setBase(host, 'healthMax', 140)
    Attributes.setBase(host, 'health', 77)
    Attributes.setBase(host, 'armour', 12)
    Attributes.setBase(host, 'stamina', 41)
    Attributes.setBase(host, 'moveSpeed', 5.5)

    local snap = host:snapshot()
    t.eq(snap.c.health.hp, 77, 'health is on the wire')
    t.eq(snap.c.health.max, 140, 'and so is the effective maximum')
    t.eq(snap.c.health.maxBase, 140, 'and the unbuffed maximum behind it')
    t.eq(snap.c.armour.value, 12, 'armour travels')
    t.eq(snap.c.stamina.value, 41, 'stamina travels')
    t.eq(snap.c.movespeed.cur, 5.5, 'move speed travels')

    local client = Fighter(0, 0)
    client:applySnapshot(snap)
    t.eq(Attributes.get(client, 'health'), 77, 'health arrived')
    t.eq(Attributes.get(client, 'healthMax'), 140, 'healthMax arrived')
    t.eq(Attributes.get(client, 'armour'), 12, 'armour arrived')
    t.eq(Attributes.get(client, 'stamina'), 41, 'stamina arrived')
    t.eq(Attributes.get(client, 'moveSpeed'), 5.5, 'moveSpeed arrived')

    -- No serialiser was written for any of this. That is the point of the
    -- attribute-as-component decision, and it is the assertion worth keeping.
    local names = Attributes.all(client)
    t.eq(names.health, 77, 'and all of it reads back through the attribute API')

    Entity.clearArchetypes()
end
