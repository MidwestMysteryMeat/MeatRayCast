--[[
    meatray.game — the ability system, assembled.

        local Game = require('meatray.game')

        Game.attach(player, { authority = true })
        Game.attributes.grantAll(player, {
            healthMax = 100, health = 100,
            staminaMax = 100, stamina = 100,
            moveSpeed = 3.2,
        })

        Game.abilities.grant(player, 'dash')
        Game.abilities.activate(player, 'dash')

        -- inside the fixed tick, on the host:
        Game.tick(player, step)

    Four pieces, in dependency order:

        tags        hierarchical strings, the vocabulary everything else gates on
        attributes  numbers that replicate and persist because they are components
        effects     the only thing that changes an attribute
        abilities   activation with cost, cooldown and cast time

    Nothing here reaches for LÖVE. A dedicated server runs all of it, which is
    the same rule meatray/sim and meatray/net keep, and for the same reason:
    gameplay that cannot run without a window is gameplay that cannot run on a
    server and cannot be tested without one.

    ---------------------------------------------------------------------------
    Where the host/client line falls
    ---------------------------------------------------------------------------

      * Attributes are components. They replicate through netFields and persist
        through meatray.save.state with nothing added to either.
      * Effect instances, cooldowns and casts live in the unreplicated `gas`
        component: host bookkeeping. The tags they grant DO replicate, as one
        sorted string, so a client can gate its own prediction.
      * `Effects.apply` refuses on a non-authoritative container. There is no
        path from client input to an attribute, so damage cannot be predicted
        even by accident.

    HEADLESS: this module must not touch love.graphics or any love drawing API.
]]

local Tags       = require('meatray.game.tags')
local Attributes = require('meatray.game.attributes')
local Effects    = require('meatray.game.effects')
local Abilities  = require('meatray.game.abilities')

local Game = {}

Game.tags       = Tags
Game.attributes = Attributes
Game.effects    = Effects
Game.abilities  = Abilities

---------------------------------------------------------------------------
-- Setup
---------------------------------------------------------------------------

-- Attaches an ability system and, optionally, a starting set of attributes.
--
--   Game.attach(e, { authority = false, attributes = { health = 100 } })
function Game.attach(e, opts)
    opts = opts or {}
    local gas = Effects.attach(e, opts)
    if opts.attributes then Attributes.grantAll(e, opts.attributes) end
    Effects.recompute(e)
    return gas
end

function Game.has(e)
    return Effects.system(e) ~= nil
end

---------------------------------------------------------------------------
-- Damage and healing, as effects
---------------------------------------------------------------------------

-- The engine's default damage tag. A game that wants `damage.type.fire` passes
-- it; anything asking for `damage` or `damage.type` matches either, which is the
-- entire reason tags are hierarchical.
Game.DEFAULT_DAMAGE_TAGS = { 'damage.type.physical' }

--[[
    Applies damage as an instant effect.

        Game.damage(target, 25, { tags = { 'damage.type.fire' }, source = shooter })

    Returns the effect result — including per-attribute before/after/soaked
    numbers — or nil plus a reason. It is nil rather than an error for a client
    ('not authoritative'), for a target with no ability system, and for an amount
    that is not a usable number, because all three are things a caller can be
    handed rather than things it wrote.

    Armour absorbs first, because `health` declares `soak = 'armour'`. Nothing in
    this function knows that; it would work the same way for a game whose health
    soaks into a completely different attribute.
]]
function Game.damage(target, amount, opts)
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
        assetTags = opts.tags or Game.DEFAULT_DAMAGE_TAGS,
        modifiers = { {
            attr = opts.attr or 'health',
            op = 'add',
            magnitude = -n,
            bypassSoak = opts.bypassArmour and true or false,
        } },
    }, opts)
end

function Game.heal(target, amount, opts)
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
function Game.isDepleted(e, attr)
    local v = Attributes.get(e, attr or 'health')
    return v ~= nil and v <= Attributes.EPS
end

---------------------------------------------------------------------------
-- The tick
---------------------------------------------------------------------------

--[[
    One fixed simulation step for one entity.

    Order matters and is fixed:

      1. Effects: durations run down, periods execute, expiries are collected.
      2. Interrupt: a cast whose ability is blocked by a tag the entity acquired
         in step 1 is cancelled. A stun that arrives this tick stops the cast
         this tick, not next tick.
      3. Abilities: cooldowns run down, casts complete and commit.

    `dt` is the simulation step, always. Nothing in here reads a clock.
]]
function Game.tick(e, dt, ctx)
    local expired, executions = Effects.tick(e, dt, ctx)
    Abilities.interrupt(e, { reason = 'interrupted' })
    local ready, completed = Abilities.tick(e, dt, ctx)
    return expired, executions, ready, completed
end

-- Every entity that has an ability system, in array order.
function Game.tickAll(entities, dt, ctx)
    local n = 0
    for i = 1, #(entities or {}) do
        local e = entities[i]
        if not e.dead and Effects.system(e) then
            Game.tick(e, dt, ctx)
            n = n + 1
        end
    end
    return n
end

---------------------------------------------------------------------------
-- Definitions
---------------------------------------------------------------------------

-- Clears every effect and ability definition and restores the engine's own
-- attributes. Hot reload and tests both need this; it is deliberately the same
-- shape as Entity.clearArchetypes.
function Game.reset()
    Attributes.reset()
    Effects.reset()
    Abilities.reset()
    return Game
end

function Game.capture()
    return { effects = Effects.capture(), abilities = Abilities.capture() }
end

function Game.restore(captured)
    captured = captured or {}
    Effects.restore(captured.effects)
    Abilities.restore(captured.abilities)
    return Game
end

return Game
