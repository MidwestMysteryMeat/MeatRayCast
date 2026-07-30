--[[
    Abilities: cost, cooldown, cast time, gating, and prediction.

    The refusals matter more than the successes. An ability that declines
    silently is the bug that reads as "the button does nothing sometimes", and
    the six reasons it can decline are indistinguishable to a player unless the
    code hands one back.

    The prediction assertions are the host-authority ones. A client may start a
    cooldown early; it may not touch an attribute. The second is enforced one
    layer down, in Effects.apply, so there is no path from a client's key press
    to a health bar even by mistake.
]]

return function(t)
    local Entity     = require('meatray.sim.entity')
    local Attributes = require('meatray.game.attributes')
    local Effects    = require('meatray.game.effects')
    local Abilities  = require('meatray.game.abilities')
    local Game       = require('meatray.game')

    Game.reset()

    local STEP = 1 / 60

    local function actor(opts)
        opts = opts or {}
        local e = Entity.new{}
        Game.attach(e, {
            authority = opts.authority,
            attributes = {
                healthMax = 100, health = 100,
                staminaMax = 100, stamina = opts.stamina or 100,
                armourMax = 50, armour = 0,
                moveSpeed = 4,
            },
        })
        return e
    end

    Effects.define('ab.dashspeed', {
        duration = 0.5,
        modifiers = { { attr = 'moveSpeed', op = 'mul', magnitude = 2 } },
        grantedTags = { 'state.dashing' },
        assetTags = { 'buff.dash' },
    })

    Effects.define('ab.stun', {
        duration = 1,
        grantedTags = { 'state.stunned' },
        assetTags = { 'debuff.stun' },
    })

    Effects.define('ab.fireball.hit', {
        duration = 'instant',
        modifiers = { { attr = 'health', op = 'add', magnitude = -30 } },
        assetTags = { 'damage.type.fire' },
    })

    Abilities.define('dash', {
        cost = { { attr = 'stamina', magnitude = 25 } },
        cooldown = 2,
        tags = { 'ability.dash' },
        blockedTags = { 'state.stunned' },
        effects = { 'ab.dashspeed' },
    })

    Abilities.define('fireball', {
        cost = { { attr = 'stamina', magnitude = 40 } },
        cooldown = 3,
        castTime = 0.5,
        tags = { 'ability.fireball' },
        blockedTags = { 'state.stunned' },
        effectsOnHit = { 'ab.fireball.hit' },
    })

    ---------------------------------------------------------------------
    t.describe('definitions are validated and report rather than raise')

    local ok, err = Abilities.compile({ cooldown = -1 })
    t.ok(ok == nil and err:find('cooldown'), 'a negative cooldown is refused')

    ok, err = Abilities.compile({ castTime = 0/0 })
    t.ok(ok == nil and err:find('cast time'), 'a NaN cast time is refused')

    ok, err = Abilities.compile({ cost = { { attr = 'stamina', magnitude = -5 } } })
    t.ok(ok == nil and err:find('cost'), 'a negative cost is refused')

    ok, err = Abilities.compile({ cost = { { magnitude = 5 } } })
    t.ok(ok == nil and err:find('names no attribute'), 'a cost with no attribute is refused')

    ok, err = Abilities.compile({ blockedTags = { 'not a tag' } })
    t.ok(ok == nil and err:find('blockedTags'), 'an invalid tag is refused, and named')

    ok, err = Abilities.compile({ effects = { 42 } })
    t.ok(ok == nil and err:find('effects'), 'an effect list of non-strings is refused')

    ---------------------------------------------------------------------
    t.describe('granting')

    local hero = actor{}
    t.ok(not Abilities.granted(hero, 'dash'), 'nothing is granted by default')

    local activated, reason = Abilities.activate(hero, 'dash')
    t.ok(activated == false and reason == 'not granted',
         'an ability the entity does not have is refused by name')

    t.ok(Abilities.grant(hero, 'dash'), 'granting works')
    t.ok(Abilities.granted(hero, 'dash'), 'and is visible')

    local unknownOk, unknownWhy = Abilities.grant(hero, 'teleport')
    t.ok(unknownOk == false and unknownWhy:find('unknown ability'),
         'granting an undeclared ability is refused')

    Abilities.grant(hero, 'fireball')
    local ids = Abilities.grantedIds(hero)
    t.eq(#ids, 2, 'two abilities granted')
    t.eq(ids[1], 'dash', 'listed sorted, so a HUD is stable')
    t.eq(ids[2], 'fireball', 'sorted')

    ---------------------------------------------------------------------
    t.describe('activation pays the cost and applies the effect')

    t.ok(Abilities.canActivate(hero, 'dash'), 'the dash is ready')

    local result = Abilities.activate(hero, 'dash')
    t.ok(result ~= false, 'it activated')
    t.ok(result.committed, 'and committed immediately, since it has no cast time')
    t.eq(Attributes.get(hero, 'stamina'), 75, 'twenty-five stamina was spent')
    t.eq(Attributes.get(hero, 'moveSpeed'), 8, 'and the speed buff landed')
    t.ok(Effects.hasTag(hero, 'state.dashing'), 'with its tag')
    t.eq(#result.result.applied, 1, 'the result names the effect it applied')

    ---------------------------------------------------------------------
    t.describe('cooldown refusal')

    t.near(Abilities.cooldownRemaining(hero, 'dash'), 2, 1e-12, 'two seconds of cooldown')
    t.ok(Abilities.onCooldown(hero, 'dash'), 'and it reads as on cooldown')

    local again, againWhy, againDetail = Abilities.activate(hero, 'dash')
    t.eq(again, false, 'a second activation is refused')
    t.eq(againWhy, 'cooldown', 'because of the cooldown')
    t.ok(againDetail > 0, 'and the refusal carries how long is left')
    t.eq(Attributes.get(hero, 'stamina'), 75, 'a refused activation costs nothing')

    -- The cooldown runs out on the exact step, not the one after.
    for _ = 1, 119 do Game.tick(hero, STEP) end
    t.ok(Abilities.onCooldown(hero, 'dash'), 'still cooling after 119 of 120 steps')
    local ready = select(3, Game.tick(hero, STEP))
    t.eq(ready, 1, 'and comes off cooldown on the 120th')
    t.ok(not Abilities.onCooldown(hero, 'dash'), 'the cooldown is gone')
    t.eq(Abilities.cooldownRemaining(hero, 'dash'), 0, 'and reads as zero')

    -- The dash buff expired somewhere in there; the stat is exactly back.
    t.eq(Attributes.get(hero, 'moveSpeed'), 4, 'and the dash buff reverted cleanly')

    ---------------------------------------------------------------------
    t.describe('cost refusal')

    local tired = actor{ stamina = 10 }
    Abilities.grant(tired, 'dash')

    local canPay, payWhy, payAttr = Abilities.canActivate(tired, 'dash')
    t.eq(canPay, false, 'ten stamina cannot buy a twenty-five stamina dash')
    t.eq(payWhy, 'cost', 'and the reason is the cost')
    t.eq(payAttr, 'stamina', 'and it names the attribute that could not pay')

    local refused = Abilities.activate(tired, 'dash')
    t.eq(refused, false, 'activation is refused')
    t.eq(Attributes.get(tired, 'stamina'), 10, 'and the stamina is untouched')
    t.eq(Abilities.cooldownRemaining(tired, 'dash'), 0, 'no cooldown was started either')
    t.ok(not Effects.hasTag(tired, 'state.dashing'), 'and no effect was applied')

    -- Exactly enough is enough.
    Attributes.setBase(tired, 'stamina', 25)
    t.ok(Abilities.canActivate(tired, 'dash'), 'exactly the cost is affordable')
    Abilities.activate(tired, 'dash')
    t.eq(Attributes.get(tired, 'stamina'), 0, 'and spends it to zero')

    -- An ability whose cost attribute the entity does not have at all.
    Abilities.define('manabolt', { cost = { { attr = 'mana', magnitude = 5 } } })
    local noMana = actor{}
    Abilities.grant(noMana, 'manabolt')
    local manaOk, manaWhy = Abilities.canActivate(noMana, 'manabolt')
    t.eq(manaOk, false, 'an ability costing an attribute the entity lacks is refused')
    t.eq(manaWhy, 'cost', 'as a cost failure, not a crash')

    ---------------------------------------------------------------------
    t.describe('tag gating')

    local stunned = actor{}
    Abilities.grant(stunned, 'dash')
    Effects.apply(stunned, 'ab.stun')

    local gated, gatedWhy, gatedTag = Abilities.canActivate(stunned, 'dash')
    t.eq(gated, false, 'a stunned actor cannot dash')
    t.ok(gatedWhy:find('blocked by tag'), 'and the reason names the mechanism')
    t.eq(gatedTag, 'state.stunned', 'and the tag')

    for _ = 1, 60 do Game.tick(stunned, STEP) end
    t.ok(Abilities.canActivate(stunned, 'dash'), 'and can once the stun expires')

    Abilities.define('rage', { requiredTags = { 'state.bloodied' } })
    Abilities.grant(stunned, 'rage')
    local needTag, needWhy = Abilities.canActivate(stunned, 'rage')
    t.eq(needTag, false, 'a required tag that is absent refuses')
    t.ok(needWhy:find('missing tag'), 'and says which')

    ---------------------------------------------------------------------
    t.describe('cast time: cost at activation, effects at completion')

    local caster = actor{}
    Abilities.grant(caster, 'fireball')

    local victim = actor{}
    local cast = Abilities.activate(caster, 'fireball', { targets = { victim } })
    t.ok(cast ~= false, 'the cast started')
    t.eq(cast.committed, false, 'but did not commit yet')
    t.eq(Attributes.get(caster, 'stamina'), 60, 'the cost was paid up front')
    t.near(Abilities.cooldownRemaining(caster, 'fireball'), 3, 1e-12,
           'and the cooldown started up front, so interrupting is not a free reset')
    t.ok(Effects.hasTag(caster, 'state.casting'), 'the casting tag is up')
    t.eq(Attributes.get(victim, 'health'), 100, 'and the target is untouched so far')

    local busy, busyWhy = Abilities.activate(caster, 'fireball', { targets = { victim } })
    t.eq(busy, false, 'a second cast of the same ability is refused')
    t.eq(busyWhy, 'already casting', 'as already casting')

    for _ = 1, 29 do Game.tick(caster, STEP) end
    t.eq(Attributes.get(victim, 'health'), 100, 'still nothing at 29 of 30 steps')

    local completed = select(4, Game.tick(caster, STEP))
    t.eq(completed, 1, 'the cast completes on the thirtieth step')
    t.eq(Attributes.get(victim, 'health'), 70, 'and the target takes thirty')
    t.ok(not Effects.hasTag(caster, 'state.casting'), 'the casting tag is gone')
    t.eq(Abilities.casting(caster, 'fireball'), nil, 'and so is the cast')

    ---------------------------------------------------------------------
    t.describe('a stun interrupts a cast on the tick it arrives')

    local interrupted = actor{}
    Abilities.grant(interrupted, 'fireball')
    local target2 = actor{}
    Abilities.activate(interrupted, 'fireball', { targets = { target2 } })
    t.ok(Abilities.casting(interrupted, 'fireball') ~= nil, 'casting')

    Effects.apply(interrupted, 'ab.stun')
    Game.tick(interrupted, STEP)
    t.eq(Abilities.casting(interrupted, 'fireball'), nil, 'the stun cancelled the cast')

    for _ = 1, 60 do Game.tick(interrupted, STEP) end
    t.eq(Attributes.get(target2, 'health'), 100, 'and the fireball never landed')
    t.eq(Attributes.get(interrupted, 'stamina'), 60, 'the cost was not refunded')
    t.ok(Abilities.onCooldown(interrupted, 'fireball'), 'and the cooldown still runs')

    -- Refunding is available, it is just not the default.
    local merciful = actor{}
    Abilities.grant(merciful, 'fireball')
    Abilities.activate(merciful, 'fireball', { targets = {} })
    Abilities.cancel(merciful, 'fireball', { refund = true })
    t.eq(Attributes.get(merciful, 'stamina'), 100, 'an explicit refund returns the cost')
    t.eq(Abilities.cooldownRemaining(merciful, 'fireball'), 0, 'and clears the cooldown')

    local notCasting, notWhy = Abilities.cancel(merciful, 'fireball')
    t.eq(notCasting, false, 'cancelling nothing is refused')
    t.eq(notWhy, 'not casting', 'with a reason')

    ---------------------------------------------------------------------
    t.describe('prediction: a client may start a cooldown, never a damage number')

    local predictor = actor{ authority = false }
    Abilities.grant(predictor, 'dash')

    local hostRefusal = Abilities.activate(predictor, 'dash')
    t.eq(hostRefusal, false, 'a non-authoritative container refuses a real activation')

    local key = Abilities.predict(predictor, 'dash')
    t.ok(type(key) == 'number', 'but it may predict one')
    t.ok(Abilities.onCooldown(predictor, 'dash'), 'the cooldown starts locally, so the UI responds')
    t.eq(Attributes.get(predictor, 'stamina'), 100,
         'and nothing was spent: attributes belong to the host')
    t.ok(not Effects.hasTag(predictor, 'state.dashing'),
         'and no effect was applied locally')

    local predictAgain, predictWhy = Abilities.predict(predictor, 'dash')
    t.eq(predictAgain, false, 'a second prediction is refused by its own local cooldown')
    t.eq(predictWhy, 'cooldown', 'for the same reason the host would refuse it')

    t.ok(Abilities.confirm(predictor, key), 'the host confirms')
    local confirmTwice = Abilities.confirm(predictor, key)
    t.eq(confirmTwice, false, 'confirming twice is refused rather than double-counted')

    -- A rejection restores exactly what was there before.
    local rejected = actor{ authority = false }
    Abilities.grant(rejected, 'fireball')
    local before = Abilities.cooldownRemaining(rejected, 'fireball')
    local key2 = Abilities.predict(rejected, 'fireball')
    t.ok(Abilities.onCooldown(rejected, 'fireball'), 'the predicted cooldown is running')
    t.ok(Effects.hasTag(rejected, 'state.casting'), 'and the predicted cast is up')

    Abilities.reject(rejected, key2, 'host said no')
    t.eq(Abilities.cooldownRemaining(rejected, 'fireball'), before,
         'a rejection puts the cooldown back exactly as it was')
    t.eq(Abilities.casting(rejected, 'fireball'), nil, 'and drops the predicted cast')
    t.ok(not Effects.hasTag(rejected, 'state.casting'), 'and its tag')
    t.ok(Abilities.canActivate(rejected, 'fireball'), 'leaving the ability usable again')

    -- A predicted cast that runs to completion on a client applies nothing.
    local ghostCaster = actor{ authority = false }
    Abilities.grant(ghostCaster, 'fireball')
    local ghostTarget = actor{}
    Abilities.predict(ghostCaster, 'fireball', { targets = { ghostTarget } })
    for _ = 1, 60 do Game.tick(ghostCaster, STEP) end
    t.eq(Attributes.get(ghostTarget, 'health'), 100,
         'a predicted cast completing on a client damages nobody')
    t.eq(Attributes.get(ghostCaster, 'stamina'), 100, 'and spends nothing')

    ---------------------------------------------------------------------
    t.describe('an entity with no ability system refuses everything politely')

    local bare = Entity.new{}
    local bareOk, bareWhy = Abilities.canActivate(bare, 'dash')
    t.eq(bareOk, false, 'canActivate is false')
    t.eq(bareWhy, 'no ability system', 'with a reason')
    t.eq(select(2, Abilities.activate(bare, 'dash')), 'no ability system', 'and so is activate')
    t.eq(Abilities.cooldownRemaining(bare, 'dash'), 0, 'cooldowns read as zero')
    t.eq(select(2, Abilities.tick(bare, STEP)), 0, 'and ticking it does nothing')

    ---------------------------------------------------------------------
    t.describe('revoking clears the state that went with it')

    local forgetful = actor{}
    Abilities.grant(forgetful, 'dash')
    Abilities.activate(forgetful, 'dash')
    t.ok(Abilities.onCooldown(forgetful, 'dash'), 'on cooldown')
    Abilities.revoke(forgetful, 'dash')
    t.ok(not Abilities.granted(forgetful, 'dash'), 'revoked')
    t.eq(Abilities.cooldownRemaining(forgetful, 'dash'), 0, 'and the cooldown went with it')

    ---------------------------------------------------------------------
    t.describe('nothing in the ability system reads a clock')

    local ticker = actor{}
    Abilities.grant(ticker, 'dash')
    Abilities.activate(ticker, 'dash')
    local nanReady = Abilities.tick(ticker, 0/0)
    t.eq(nanReady, 0, 'a NaN dt advances nothing')
    t.near(Abilities.cooldownRemaining(ticker, 'dash'), 2, 1e-12,
           'and leaves the cooldown exactly where it was')
    Abilities.tick(ticker, -5)
    t.near(Abilities.cooldownRemaining(ticker, 'dash'), 2, 1e-12,
           'a negative dt cannot rewind one either')
end
