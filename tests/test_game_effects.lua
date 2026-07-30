--[[
    Gameplay effects: durations, stacking, periods, resistances, immunity, and
    the authority check that makes "damage is never predicted" a property of the
    code rather than a convention.

    The two assertions worth reading first:

      * A duration that is an exact multiple of the simulation step expires on
        that step. Thirty additions of 1/60 do not land exactly on 0.5, so an
        expiry test written with `<= 0` passes at 60 Hz and fails at 120, and
        the bug shows up as a buff that lasts one tick too long on some machines.

      * A client cannot move an attribute. Not "does not" — cannot: the only
        path to an attribute is through an application that refuses on a
        non-authoritative container.
]]

return function(t)
    local Entity     = require('meatray.sim.entity')
    local Worldgen   = require('meatray.sim.worldgen')
    local Attributes = require('meatray.game.attributes')
    local Effects    = require('meatray.game.effects')
    local Game       = require('meatray.game')

    Game.reset()

    local STEP = 1 / 60

    local function fighter(opts)
        opts = opts or {}
        local e = Entity.new{}
        Game.attach(e, {
            authority = opts.authority,
            attributes = {
                healthMax = 100, health = 100,
                armourMax = 50,  armour = opts.armour or 0,
                staminaMax = 100, stamina = 100,
                moveSpeed = 4,
            },
        })
        return e
    end

    ---------------------------------------------------------------------
    t.describe('definitions are validated, and report rather than raise')

    local ok, err = Effects.compile({ duration = -1 })
    t.ok(ok == nil and err:find('duration'), 'a negative duration is refused')

    ok, err = Effects.compile({ duration = 1, modifiers = { { attr = 'health', magnitude = 0/0 } } })
    t.ok(ok == nil and err:find('magnitude'), 'a NaN magnitude is refused')

    ok, err = Effects.compile({ duration = 1, modifiers = { { attr = 'health', magnitude = tonumber('1e999') } } })
    t.ok(ok == nil, 'an infinite magnitude is refused')

    ok, err = Effects.compile({ duration = 1, modifiers = { { attr = 'health', op = 'wat', magnitude = 1 } } })
    t.ok(ok == nil and err:find('unknown op'), 'an unknown op is refused')

    ok, err = Effects.compile({ duration = 1, modifiers = { { attr = 'health', op = 'div', magnitude = 0 } } })
    t.ok(ok == nil and err:find('zero'), 'a divide by zero is refused at declaration')

    ok, err = Effects.compile({ duration = 'instant', period = 1 })
    t.ok(ok == nil and err:find('period'), 'an instant effect cannot have a period')

    ok, err = Effects.compile({ duration = 1, grantedTags = { 'not a tag' } })
    t.ok(ok == nil and err:find('grantedTags'), 'an invalid granted tag is refused, and named')

    ok, err = Effects.compile({ duration = 1, stacking = { policy = 'pile' } })
    t.ok(ok == nil and err:find('stacking policy'), 'an unknown stacking policy is refused')

    t.ok(Effects.compile({ duration = 'infinite' }) ~= nil, 'infinite is a duration')
    t.ok(Effects.compile({}) ~= nil, 'and instant is the default')

    ---------------------------------------------------------------------
    t.describe('damage is an effect, and armour soaks it without knowing it')

    local hurt = fighter{ armour = 20 }
    local result = Game.damage(hurt, 30)
    t.ok(result ~= nil, 'damage applied')
    t.eq(Attributes.get(hurt, 'armour'), 0, 'armour absorbed what it could')
    t.eq(Attributes.get(hurt, 'health'), 90, 'and the remainder reached health')

    local badAmount, badErr = Game.damage(hurt, tonumber('1e999'))
    t.ok(badAmount == nil and badErr ~= nil, 'an infinite damage amount is refused')
    t.eq(Attributes.get(hurt, 'health'), 90, 'and nothing was applied')

    local nanAmount = Game.damage(hurt, 0/0)
    t.ok(nanAmount == nil, 'NaN damage is refused')
    t.eq(Attributes.get(hurt, 'health'), 90, 'and health is still a number equal to itself')

    Game.heal(hurt, 1000)
    t.eq(Attributes.get(hurt, 'health'), 100, 'healing clamps to the maximum')

    ---------------------------------------------------------------------
    t.describe('the host owns attributes: a client cannot move one')

    local client = fighter{ authority = false }
    local refused, why = Game.damage(client, 40)
    t.ok(refused == nil, 'damage on a non-authoritative container is refused')
    t.eq(why, 'not authoritative', 'and says why')
    t.eq(Attributes.get(client, 'health'), 100, 'the health bar did not flinch')

    Effects.define('fx.slow', {
        duration = 1,
        modifiers = { { attr = 'moveSpeed', op = 'mul', magnitude = 0.5 } },
        grantedTags = { 'state.slowed' },
        assetTags = { 'debuff.slow' },
    })

    local predicted, predictWhy = Effects.apply(client, 'fx.slow')
    t.ok(predicted == nil and predictWhy == 'not authoritative',
         'and a client cannot apply a buff to itself either')

    local noSystem = Entity.new{}
    local nsResult, nsWhy = Game.damage(noSystem, 10)
    t.ok(nsResult == nil and nsWhy == 'no ability system',
         'a target with no ability system is refused, not crashed')

    ---------------------------------------------------------------------
    t.describe('duration effects modify the current value and revert exactly')

    local runner = fighter{}
    local base = Attributes.base(runner, 'moveSpeed')
    t.eq(Attributes.get(runner, 'moveSpeed'), 4, 'unmodified')

    Effects.apply(runner, 'fx.slow')
    t.eq(Attributes.get(runner, 'moveSpeed'), 2, 'the slow halves it')
    t.eq(Attributes.base(runner, 'moveSpeed'), base, 'and never touches the base')
    t.ok(Effects.hasTag(runner, 'state.slowed'), 'its tag is granted')
    t.ok(Effects.hasTag(runner, 'state'), 'and answers a parent query')

    -- Exactly on the boundary: one second at 60 Hz is sixty steps, not
    -- fifty-nine and not sixty-one.
    for _ = 1, 59 do Effects.tick(runner, STEP) end
    t.eq(Effects.count(runner, 'fx.slow'), 1, 'still there after 59 of 60 steps')
    t.eq(Attributes.get(runner, 'moveSpeed'), 2, 'and still slowing')

    local expired = Effects.tick(runner, STEP)
    t.eq(expired, 1, 'and expires on the sixtieth')
    t.eq(Effects.count(runner, 'fx.slow'), 0, 'the instance is gone')
    t.eq(Attributes.get(runner, 'moveSpeed'), 4, 'the stat is exactly back to base')
    t.ok(not Effects.hasTag(runner, 'state.slowed'), 'and the tag went with it')

    ---------------------------------------------------------------------
    t.describe('an effect removes itself cleanly')

    Effects.define('fx.haste', {
        duration = 'infinite',
        modifiers = { { attr = 'moveSpeed', op = 'mul', magnitude = 1.5 },
                      { attr = 'moveSpeed', op = 'add', magnitude = 1 } },
        grantedTags = { 'state.hasted' },
        assetTags = { 'buff.haste' },
    })

    local hasted = fighter{}
    local applied = Effects.apply(hasted, 'fx.haste')
    -- Documented order: (4 + 1) * 1.5
    t.near(Attributes.get(hasted, 'moveSpeed'), 7.5, 1e-12,
           'additive then multiplicative, on a live entity')

    local removedCount = Effects.remove(hasted, applied.instance)
    t.eq(removedCount, 1, 'removing by instance works')
    t.eq(Attributes.get(hasted, 'moveSpeed'), 4, 'and leaves the stat exactly as it was')
    t.ok(not Effects.hasTag(hasted, 'state.hasted'), 'with no tag left behind')
    t.eq(#Effects.instances(hasted), 0, 'and no instance left behind')
    t.eq(Effects.remove(hasted, applied.instance), 0, 'removing it twice is harmless')

    -- Infinite effects really are infinite: a thousand steps do not budge it.
    Effects.apply(hasted, 'fx.haste')
    for _ = 1, 1000 do Effects.tick(hasted, STEP) end
    t.eq(Effects.count(hasted, 'fx.haste'), 1, 'an infinite effect never expires')
    Effects.removeById(hasted, 'fx.haste')
    t.eq(Effects.count(hasted, 'fx.haste'), 0, 'removeById clears it')

    ---------------------------------------------------------------------
    t.describe('an effect that removes itself from inside its own execution')

    local ticks = 0
    Effects.define('fx.threeticks', {
        duration = 'infinite',
        period = 0.5,
        modifiers = { { attr = 'health', op = 'add', magnitude = -1 } },
        onExecute = function(target, def)
            ticks = ticks + 1
            if ticks >= 3 then Effects.removeById(target, def.id) end
        end,
    })

    local selfRemoving = fighter{}
    Effects.apply(selfRemoving, 'fx.threeticks')
    for _ = 1, 240 do Effects.tick(selfRemoving, STEP) end   -- four seconds
    t.eq(ticks, 3, 'it executed three times and then took itself out')
    t.eq(Effects.count(selfRemoving, 'fx.threeticks'), 0, 'with nothing left in the list')
    t.eq(Attributes.get(selfRemoving, 'health'), 97, 'and exactly three points of damage')

    ---------------------------------------------------------------------
    t.describe('the modifier fold on a live entity ignores application order')

    Effects.define('fx.plusten', { duration = 'infinite',
        modifiers = { { attr = 'moveSpeed', op = 'add', magnitude = 10 } } })
    Effects.define('fx.double', { duration = 'infinite',
        modifiers = { { attr = 'moveSpeed', op = 'mul', magnitude = 2 } } })
    Effects.define('fx.minusthree', { duration = 'infinite',
        modifiers = { { attr = 'moveSpeed', op = 'add', magnitude = -3 } } })

    local a, b = fighter{}, fighter{}
    for _, id in ipairs({ 'fx.plusten', 'fx.double', 'fx.minusthree' }) do
        Effects.apply(a, id)
    end
    for _, id in ipairs({ 'fx.minusthree', 'fx.double', 'fx.plusten' }) do
        Effects.apply(b, id)
    end

    t.near(Attributes.get(a, 'moveSpeed'), 22, 1e-12, '(4 + 10 - 3) * 2')
    t.eq(Attributes.get(a, 'moveSpeed'), Attributes.get(b, 'moveSpeed'),
         'and the reverse application order gives the identical number')

    ---------------------------------------------------------------------
    t.describe('stacking: independent durations')

    Effects.define('fx.bleed', {
        duration = 1,
        period = 0.25,
        modifiers = { { attr = 'health', op = 'add', magnitude = -2 } },
        assetTags = { 'debuff.bleed', 'damage.type.physical' },
    })

    local bleeding = fighter{}
    Effects.apply(bleeding, 'fx.bleed')
    for _ = 1, 30 do Effects.tick(bleeding, STEP) end        -- half a second in
    Effects.apply(bleeding, 'fx.bleed')
    t.eq(Effects.count(bleeding, 'fx.bleed'), 2,
         'independent is the default: a second application is a second instance')

    local first = Effects.instances(bleeding)[1]
    local second = Effects.instances(bleeding)[2]
    t.near(first.remaining, 0.5, 1e-9, 'the first instance kept its own clock')
    t.near(second.remaining, 1.0, 1e-9, 'and the second started a fresh one')

    for _ = 1, 30 do Effects.tick(bleeding, STEP) end
    t.eq(Effects.count(bleeding, 'fx.bleed'), 1, 'the first expires without the second')
    for _ = 1, 30 do Effects.tick(bleeding, STEP) end
    t.eq(Effects.count(bleeding, 'fx.bleed'), 0, 'and the second half a second later')

    ---------------------------------------------------------------------
    t.describe('stacking: refresh')

    Effects.define('fx.burning', {
        duration = 1,
        modifiers = { { attr = 'moveSpeed', op = 'add', magnitude = -1 } },
        stacking = { policy = 'refresh' },
        grantedTags = { 'state.burning' },
    })

    local burning = fighter{}
    Effects.apply(burning, 'fx.burning')
    for _ = 1, 45 do Effects.tick(burning, STEP) end
    t.near(Effects.remaining(burning, 'fx.burning'), 0.25, 1e-9, 'three quarters elapsed')

    local again = Effects.apply(burning, 'fx.burning')
    t.ok(again.refreshed, 'the result says it refreshed')
    t.eq(Effects.count(burning, 'fx.burning'), 1, 'still exactly one instance')
    t.near(Effects.remaining(burning, 'fx.burning'), 1.0, 1e-9, 'with a full duration again')
    t.eq(Attributes.get(burning, 'moveSpeed'), 3, 'and the modifier did not double up')
    t.eq(Effects.tags(burning):count('state.burning'), 1, 'nor did the tag')

    ---------------------------------------------------------------------
    t.describe('stacking: counted, and capped')

    Effects.define('fx.chill', {
        duration = 2,
        modifiers = { { attr = 'moveSpeed', op = 'add', magnitude = -0.5 } },
        stacking = { policy = 'stack', limit = 3, refreshOnStack = false },
        assetTags = { 'debuff.chill' },
    })

    local chilled = fighter{}
    Effects.apply(chilled, 'fx.chill')
    t.eq(Effects.stacks(chilled, 'fx.chill'), 1, 'one stack')
    t.eq(Attributes.get(chilled, 'moveSpeed'), 3.5, 'and one modifier')

    Effects.apply(chilled, 'fx.chill')
    Effects.apply(chilled, 'fx.chill')
    t.eq(Effects.stacks(chilled, 'fx.chill'), 3, 'three stacks')
    t.eq(Effects.count(chilled, 'fx.chill'), 1, 'still one instance')
    t.eq(Attributes.get(chilled, 'moveSpeed'), 2.5, 'additive magnitude scales with the count')

    local capped, capReason = Effects.apply(chilled, 'fx.chill')
    t.ok(capped == nil, 'a fourth application is refused at the cap')
    t.eq(capReason, 'stack limit', 'and says so')
    t.eq(Effects.stacks(chilled, 'fx.chill'), 3, 'the count did not creep past the limit')

    -- Multiplicative stacking is exponential, so stacking a reduction can never
    -- flip its sign: two x0.9 stacks are x0.81, not x1.8.
    Effects.define('fx.weaken', {
        duration = 'infinite',
        modifiers = { { attr = 'moveSpeed', op = 'mul', magnitude = 0.9 } },
        stacking = { policy = 'stack', limit = 5 },
    })
    local weak = fighter{}
    Effects.apply(weak, 'fx.weaken')
    Effects.apply(weak, 'fx.weaken')
    t.near(Attributes.get(weak, 'moveSpeed'), 4 * 0.81, 1e-12,
           'two multiplicative stacks compound')

    ---------------------------------------------------------------------
    t.describe('periods execute on exact boundaries, not per frame')

    local poisoned = fighter{}
    Effects.define('fx.poison', {
        duration = 1,
        period = 0.25,
        modifiers = { { attr = 'health', op = 'add', magnitude = -5, bypassSoak = true } },
        assetTags = { 'debuff.poison', 'damage.type.toxic' },
    })
    Effects.apply(poisoned, 'fx.poison')

    local totalExecutions = 0
    for _ = 1, 14 do
        local _, ran = Effects.tick(poisoned, STEP)
        totalExecutions = totalExecutions + ran
    end
    t.eq(totalExecutions, 0, 'nothing has fired before the first quarter second')
    local _, ranNow = Effects.tick(poisoned, STEP)                  -- the 15th step
    t.eq(ranNow, 1, 'the first tick fires exactly on 0.25s')
    t.eq(Attributes.get(poisoned, 'health'), 95, 'for five points')

    for _ = 1, 45 do Effects.tick(poisoned, STEP) end               -- out to 1.0s
    t.eq(Attributes.get(poisoned, 'health'), 80, 'four ticks of five over one second')
    t.eq(Effects.count(poisoned, 'fx.poison'), 0, 'and the effect expired on the boundary')

    -- The period is per simulation step, so a bigger dt catches up rather than
    -- dropping ticks: a host that stalled must not owe the player free seconds.
    local caughtUp = fighter{}
    Effects.apply(caughtUp, 'fx.poison')
    local _, burst = Effects.tick(caughtUp, 1.0)
    t.eq(burst, 4, 'a one-second step runs all four periods')

    ---------------------------------------------------------------------
    t.describe('a NaN dt cannot make every effect permanent')

    local frozen = fighter{}
    Effects.apply(frozen, 'fx.slow')
    local before = Effects.remaining(frozen, 'fx.slow')
    Effects.tick(frozen, 0/0)
    t.eq(Effects.remaining(frozen, 'fx.slow'), before, 'a NaN dt is ignored')
    Effects.tick(frozen, -1)
    t.eq(Effects.remaining(frozen, 'fx.slow'), before, 'and so is a negative one')
    Effects.tick(frozen, tonumber('1e999'))
    t.eq(Effects.remaining(frozen, 'fx.slow'), before, 'and an infinite one')

    ---------------------------------------------------------------------
    t.describe('resistances scale incoming effects by tag')

    Effects.define('fx.fireward', {
        duration = 'infinite',
        incoming = { { tag = 'damage.type.fire', magnitude = 0.5 } },
        assetTags = { 'buff.ward' },
    })

    local warded = fighter{}
    Effects.apply(warded, 'fx.fireward')

    Game.damage(warded, 20, { tags = { 'damage.type.fire' } })
    t.eq(Attributes.get(warded, 'health'), 90, 'fire damage is halved')

    Game.damage(warded, 20, { tags = { 'damage.type.ice' } })
    t.eq(Attributes.get(warded, 'health'), 70, 'ice damage is not')

    -- Hierarchy: a ward written for `damage.type.fire` covers a subtype invented
    -- afterwards without being touched.
    Game.damage(warded, 20, { tags = { 'damage.type.fire.greek' } })
    t.eq(Attributes.get(warded, 'health'), 60, 'and a subtype of fire is halved too')

    Effects.define('fx.allward', {
        duration = 'infinite',
        incoming = { { tag = 'damage', magnitude = 0 } },
        assetTags = { 'buff.ward' },
    })
    local immuneToAll = fighter{}
    Effects.apply(immuneToAll, 'fx.allward')
    Game.damage(immuneToAll, 999, { tags = { 'damage.type.fire' } })
    t.eq(Attributes.get(immuneToAll, 'health'), 100, 'a zero multiplier is full immunity')

    ---------------------------------------------------------------------
    t.describe('gating: required tags, blocked tags, immunity')

    Effects.define('fx.needsburning', {
        duration = 1,
        requiredTags = { 'state.burning' },
        modifiers = { { attr = 'moveSpeed', op = 'add', magnitude = -1 } },
    })

    local gated = fighter{}
    local gatedResult, gatedWhy = Effects.apply(gated, 'fx.needsburning')
    t.ok(gatedResult == nil, 'a required tag the target lacks refuses the effect')
    t.ok(gatedWhy:find('missing tag'), 'and names what was missing')

    Effects.apply(gated, 'fx.burning')
    t.ok(Effects.apply(gated, 'fx.needsburning') ~= nil, 'and it applies once the tag is there')

    Effects.define('fx.notwhileburning', {
        duration = 1,
        blockedTags = { 'state.burning' },
    })
    local blocked, blockedWhy = Effects.apply(gated, 'fx.notwhileburning')
    t.ok(blocked == nil and blockedWhy:find('blocked by tag'), 'a blocked tag refuses')

    Effects.define('fx.poisonimmunity', {
        duration = 'infinite',
        immunityTags = { 'debuff.poison' },
        assetTags = { 'buff.antidote' },
    })
    local antidoted = fighter{}
    Effects.apply(antidoted, 'fx.poisonimmunity')
    local blockedPoison, poisonWhy = Effects.apply(antidoted, 'fx.poison')
    t.ok(blockedPoison == nil and poisonWhy:find('immune'), 'immunity blocks by asset tag')
    t.ok(Effects.apply(antidoted, 'fx.bleed') ~= nil, 'while an unrelated debuff still lands')

    ---------------------------------------------------------------------
    t.describe('cleansing by tag removes what it was never told the name of')

    local dirty = fighter{}
    Effects.apply(dirty, 'fx.poison')
    Effects.apply(dirty, 'fx.bleed')
    Effects.apply(dirty, 'fx.haste')
    t.eq(#Effects.instances(dirty), 3, 'three effects up')

    local cleansed = Effects.removeWithTag(dirty, 'debuff')
    t.eq(cleansed, 2, 'the parent query took both debuffs')
    t.eq(#Effects.instances(dirty), 1, 'and left the buff alone')
    t.eq(Effects.instances(dirty)[1].def.id, 'fx.haste', 'specifically the buff')

    ---------------------------------------------------------------------
    t.describe('a lasting modifier on a pool is refused, with the reason')

    Effects.define('fx.badhealthbuff', {
        duration = 5,
        modifiers = { { attr = 'health', op = 'add', magnitude = 50 } },
    })

    local pooled = fighter{}
    local poolResult, poolWhy = Effects.apply(pooled, 'fx.badhealthbuff')
    t.ok(poolResult == nil, 'a duration modifier on health is refused')
    t.ok(poolWhy:find('pool'), 'and explains that health is a pool')
    t.ok(poolWhy:find('healthMax'), 'and points at the ceiling to buff instead')
    t.eq(Attributes.get(pooled, 'health'), 100, 'nothing was applied')

    -- The supported way to do it, and the reason the refusal is not a limitation.
    Effects.define('fx.toughness', {
        duration = 2,
        modifiers = { { attr = 'healthMax', op = 'add', magnitude = 50 } },
        grantedTags = { 'buff.toughness' },
    })
    local tough = fighter{}
    Effects.apply(tough, 'fx.toughness')
    t.eq(Attributes.get(tough, 'healthMax'), 150, 'the ceiling rises')
    Game.heal(tough, 50)
    t.eq(Attributes.get(tough, 'health'), 150, 'and the pool can be filled to it')

    for _ = 1, 120 do Effects.tick(tough, STEP) end
    t.eq(Attributes.get(tough, 'healthMax'), 100, 'the ceiling drops back on expiry')
    t.eq(Attributes.get(tough, 'health'), 100, 'and the pool is pulled down with it')

    ---------------------------------------------------------------------
    t.describe('chance uses the engine rng or refuses; never math.random')

    Effects.define('fx.proc', {
        duration = 1,
        chance = 0.5,
        modifiers = { { attr = 'moveSpeed', op = 'add', magnitude = 1 } },
    })

    local procTarget = fighter{}
    local noRng, noRngWhy = Effects.apply(procTarget, 'fx.proc')
    t.ok(noRng == nil and noRngWhy == 'no rng',
         'a chance effect with no deterministic rng is refused rather than guessed')

    -- The same seed must produce the same procs on a host and a client, which is
    -- exactly why worldgen carries its own LCG.
    local function rollSequence(seed)
        local rng = Worldgen.rng(seed)
        local target = fighter{}
        local hits = {}
        for i = 1, 20 do
            hits[i] = Effects.apply(target, 'fx.proc', { rng = rng }) ~= nil and 1 or 0
        end
        return table.concat(hits)
    end

    local seqA = rollSequence(1234)
    local seqB = rollSequence(1234)
    t.eq(seqA, seqB, 'the same seed produces the same procs')
    t.ok(seqA ~= rollSequence(9999), 'and a different seed does not')
    t.ok(seqA:find('1') and seqA:find('0'), 'with a 0.5 chance actually rolling both ways')

    ---------------------------------------------------------------------
    t.describe('tags replicate as one sorted string; effect state does not')

    local tagged = fighter{}
    Effects.apply(tagged, 'fx.burning')
    Effects.apply(tagged, 'fx.haste')

    local snap = tagged:snapshot()
    t.eq(snap.c.gas, nil, 'the ability system container is host state and never travels')
    t.eq(snap.c.tags.active, 'state.burning state.hasted', 'the tags do, sorted')

    local remote = Entity.new{}
    remote:add(Effects.TagComponent{ active = '' })
    remote:applySnapshot(snap)
    t.ok(Effects.hasTag(remote, 'state.burning'),
         'a client with no ability system still answers tag queries from the string')
    t.ok(Effects.hasTag(remote, 'state'), 'hierarchically')
    t.ok(not Effects.hasTag(remote, 'state.burned'), 'and not on a near-miss')

    Effects.removeById(tagged, 'fx.burning')
    t.eq(tagged.components.tags.active, 'state.hasted',
         'the replicated string follows the container on every change')
end
