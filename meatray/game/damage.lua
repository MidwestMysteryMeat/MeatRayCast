--[[
    meatray.game.damage — damage and healing, expressed as effects.

    This is a small module with one job, and it exists as a module rather than as
    two functions on the facade because four things now need it: weapons,
    projectiles, explosions and gas clouds. `meatray.game` (the facade) requires
    all four, so any of them requiring the facade back to reach `Game.damage`
    would be a cycle, and the alternative — each writing its own
    `health.hp = health.hp - n` — is precisely the thing the effect system exists
    to prevent.

    `Game.damage` and `Game.heal` are still the public spelling; they are this
    module's functions, re-exported. Nothing that called them has changed.

    WHY DAMAGE IS AN EFFECT

    Because a resistance, a shield, an immunity and a damage-over-time are then
    the same object as everything else in the game and compose without knowing
    about each other. A rifle round, the fourth tick of a poison and the outer
    edge of an explosion all arrive here, so:

      * `armour` soaks all three, because `health` declares `soak = 'armour'`
        and nothing in this file knows armour exists.
      * a `damage.type.fire` resistance reduces all three, because resistance is
        a tag query and the tag rides on the effect.
      * an immunity refuses all three, at the point of application.

    Written as `takeDamage()`, `takeExplosionDamage()`, `takeGasDamage()`, every
    one of those interactions is a special case that has to be re-implemented in
    each, and the bug reports are always "fire resistance doesn't work on
    explosions".

    HEADLESS: this module must not touch love.graphics or any love drawing API.
]]

local Attributes = require('meatray.game.attributes')
local Effects    = require('meatray.game.effects')

local Damage = {}

-- The engine's default damage tag. A game that wants `damage.type.fire` passes
-- it; anything asking for `damage` or `damage.type` matches either, which is the
-- entire reason tags are hierarchical.
Damage.DEFAULT_TAGS = { 'damage.type.physical' }

--[[
    Applies damage as an instant effect.

        Damage.apply(target, 25, { tags = { 'damage.type.fire' }, source = shooter })

    Returns the effect result — including per-attribute before/after/soaked
    numbers — or nil plus a reason. It is nil rather than an error for a client
    ('not authoritative'), for a target with no ability system, and for an amount
    that is not a usable number, because all three are things a caller can be
    handed rather than things it wrote.

    Armour absorbs first, because `health` declares `soak = 'armour'`. Nothing in
    this function knows that; it would work the same way for a game whose health
    soaks into a completely different attribute.
]]
function Damage.apply(target, amount, opts)
    opts = opts or {}

    local n = Attributes.number(amount)
    if n == nil then
        return nil, ('damage amount is unusable (%s)'):format(tostring(amount))
    end
    if n < 0 then
        return nil, 'damage cannot be negative; heal instead'
    end

    return Effects.applySpec(target, {
        id        = opts.id or 'damage',
        duration  = 'instant',
        assetTags = opts.tags or Damage.DEFAULT_TAGS,
        modifiers = { {
            attr = opts.attr or 'health',
            op = 'add',
            magnitude = -n,
            bypassSoak = opts.bypassArmour and true or false,
        } },
    }, opts)
end

function Damage.heal(target, amount, opts)
    opts = opts or {}

    local n = Attributes.number(amount)
    if n == nil then
        return nil, ('heal amount is unusable (%s)'):format(tostring(amount))
    end
    if n < 0 then
        return nil, 'healing cannot be negative; damage instead'
    end

    return Effects.applySpec(target, {
        id        = opts.id or 'heal',
        duration  = 'instant',
        assetTags = opts.tags or { 'heal' },
        modifiers = { { attr = opts.attr or 'health', op = 'add', magnitude = n } },
    }, opts)
end

-- Convenience for the question every game asks about a pool.
function Damage.isDepleted(e, attr)
    local v = Attributes.get(e, attr or 'health')
    return v ~= nil and v <= Attributes.EPS
end

--[[
    Damage plus any extra effect ids, which is what every weapon, projectile and
    explosion actually wants: "take 25, and also catch fire".

    Returns the damage result (or nil plus a reason) and a list of the effect ids
    that were refused, with the reason each gave. Refusals are returned rather
    than swallowed: an on-hit effect that never lands because the target is
    immune is information, and a burn that silently never applies is a bug report
    that starts "sometimes the flamethrower does nothing".
]]
function Damage.applyWith(target, amount, effectIds, opts)
    opts = opts or {}

    local result, err = Damage.apply(target, amount, opts)

    local refused
    for i = 1, #(effectIds or {}) do
        local ok, reason = Effects.apply(target, effectIds[i], opts)
        if not ok then
            refused = refused or {}
            refused[#refused + 1] = { id = effectIds[i], reason = reason }
        end
    end

    return result, err, refused
end

return Damage
