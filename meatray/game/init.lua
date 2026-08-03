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

    Ten pieces, in dependency order:

        tags        hierarchical strings, the vocabulary everything else gates on
        attributes  numbers that replicate and persist because they are components
        effects     the only thing that changes an attribute
        abilities   activation with cost, cooldown and cast time
        damage      damage and healing, expressed as effects
        explosion   radial damage with falloff, stopped by walls
        projectiles rockets and grenades, as ordinary entities
        weapons     ammo, reload, fire rate, spread and recoil
        inventory   slots, stacks, pickups, and equipping a weapon
        gas         smoke, fire and toxic clouds on the tile grid

    The last six are built ON the first four rather than beside them, which is
    the only thing that makes them compose. A weapon does not subtract hit
    points; it applies a damage EFFECT, so armour soaks it, a fire resistance
    reduces it and an immunity refuses it, and none of those three appear
    anywhere in weapons.lua. An explosion, a burning floor tile and the fourth
    tick of a poison all arrive at the same place by the same road.

    Nothing here reaches for LÖVE. A dedicated server runs all of it, which is
    the same rule meatray/sim and meatray/net keep, and for the same reason:
    gameplay that cannot run without a window is gameplay that cannot run on a
    server and cannot be tested without one. The one visual thing in this half of
    the engine — the flash an explosion pushes into the light grid — is INJECTED:
    pass a lighting grid to `Explosion.detonate` and it lights the room, pass
    nothing and a headless server notices no difference.

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

local Tags        = require('meatray.game.tags')
local Attributes  = require('meatray.game.attributes')
local Effects     = require('meatray.game.effects')
local Abilities   = require('meatray.game.abilities')
local Damage      = require('meatray.game.damage')
local Explosion   = require('meatray.game.explosion')
local Projectiles = require('meatray.game.projectiles')
local Weapons     = require('meatray.game.weapons')
local Inventory   = require('meatray.game.inventory')
local Gas         = require('meatray.game.gas')
local Mode        = require('meatray.game.mode')
local Modes       = require('meatray.game.modes')
local Campaign    = require('meatray.game.campaign')
local Options     = require('meatray.game.options')
local Hud         = require('meatray.game.hud')
local Respawn     = require('meatray.game.respawn')
local Secrets     = require('meatray.game.secrets')
local Session     = require('meatray.game.session')
local Automap     = require('meatray.game.automap')
local ConsoleMod  = require('meatray.game.console')
local IntermissionMod = require('meatray.game.intermission')
local HazardsMod  = require('meatray.game.hazards')
local MenuMod     = require('meatray.game.menu')
local I18NMod     = require('meatray.game.i18n')
local MeatGraphRay = require('meatray.game.meatgraph_ray')

local Game = {}

Game.tags        = Tags
Game.attributes  = Attributes
Game.effects     = Effects
Game.abilities   = Abilities
Game.damageModel = Damage
Game.explosion   = Explosion
Game.projectiles = Projectiles
Game.weapons     = Weapons
Game.inventory   = Inventory
Game.gas         = Gas
Game.mode        = Mode
Game.modes       = Modes
Game.campaign    = Campaign
Game.options     = Options
Game.hud         = Hud
Game.respawn     = Respawn
Game.secrets     = Secrets
Game.session     = Session
Game.automap     = Automap
Game.console     = ConsoleMod
Game.intermission = IntermissionMod
Game.hazards     = HazardsMod
Game.menu        = MenuMod
Game.i18n        = I18NMod
Game.meatgraphRay = MeatGraphRay

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

-- These live in meatray.game.damage now, and are re-exported here unchanged.
-- Weapons, projectiles, explosions and gas clouds all need to deal damage, and
-- all four are required BY this file — so any of them reaching back through the
-- facade for `Game.damage` would be a require cycle. The public spelling is
-- untouched: `Game.damage(target, 25, opts)` is the same function it was.
--
-- Mutating `Game.DEFAULT_DAMAGE_TAGS` still works, because it is the same table
-- Damage uses. Replacing it wholesale does not; pass `opts.tags` instead.
Game.DEFAULT_DAMAGE_TAGS = Damage.DEFAULT_TAGS

Game.damage      = Damage.apply
Game.heal        = Damage.heal
Game.isDepleted  = Damage.isDepleted
Game.damageWith  = Damage.applyWith

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
      4. Weapons: the fire cooldown, the reload timer and recoil recovery — the
         only place any of the three moves. See meatray/game/weapons.lua: this
         being the sole writer of weapon time is what stops a client that sends
         fire requests faster than the tick rate from firing faster than it.

    `dt` is the simulation step, always. Nothing in here reads a clock.
]]
function Game.tick(e, dt, ctx)
    local expired, executions = Effects.tick(e, dt, ctx)
    Abilities.interrupt(e, { reason = 'interrupted' })
    local ready, completed = Abilities.tick(e, dt, ctx)
    if e and e.components and e.components.weapon then
        Weapons.tick(e, dt, ctx)
    end
    return expired, executions, ready, completed
end

-- Every entity with an ability system or a weapon, in array order. A gun with no
-- ability system is a legitimate thing to have — a turret, a demo player — and
-- its cooldown still has to advance, or it fires once and never again.
function Game.tickAll(entities, dt, ctx)
    local n = 0
    for i = 1, #(entities or {}) do
        local e = entities[i]
        if not e.dead and (Effects.system(e) or (e.components and e.components.weapon)) then
            Game.tick(e, dt, ctx)
            n = n + 1
        end
    end
    return n
end

---------------------------------------------------------------------------
-- Definitions
---------------------------------------------------------------------------

-- Clears every effect, ability, weapon, explosion and item definition and
-- restores the engine's own attributes. Hot reload and tests both need this; it
-- is deliberately the same shape as Entity.clearArchetypes.
function Game.reset()
    Attributes.reset()
    Effects.reset()
    Abilities.reset()
    Weapons.reset()
    Explosion.reset()
    Inventory.resetItems()
    return Game
end

function Game.capture()
    return {
        effects    = Effects.capture(),
        abilities  = Abilities.capture(),
        weapons    = Weapons.capture(),
        explosions = Explosion.capture(),
        items      = Inventory.captureItems(),
    }
end

function Game.restore(captured)
    captured = captured or {}
    Effects.restore(captured.effects)
    Abilities.restore(captured.abilities)
    Weapons.restore(captured.weapons)
    Explosion.restore(captured.explosions)
    Inventory.restoreItems(captured.items)
    return Game
end

return Game
