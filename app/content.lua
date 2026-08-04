--[[
    app.content — what the demo's world is MADE of: effects, weapons,
    explosions, items, archetypes and placeholder sprites.

    Sixth cut of un-god-filing main.lua. This is the file a reader opens to
    ask "what does the pistol do" or "what is an imp" — data-shaped code
    with no control flow worth hiding. A project's game.lua (H5) is the
    same idea one layer up: this defines the STOCK game, that defines
    yours.

    Returns { gameplay, archetypes, sprites } — called at boot in that
    order (rules before archetypes: the player archetype equips a weapon
    out of a bag, and both the weapon and the items have to exist first),
    and again on a hot reload, which is why gameplay() starts from
    Game.reset() and archetypes() from a cleared registry.
]]

return function(ctx)
    local Game, MeatRay = ctx.Game, ctx.MeatRay
    local Entity, C, AI = ctx.Entity, ctx.C, ctx.AI
    local Weapons, Explosion, Inventory = ctx.Weapons, ctx.Explosion, ctx.Inventory
    local isAuthority = ctx.isAuthority

    local M = {}

    -- How much of the demo's rules live in data rather than in code. Defined once at
    -- boot and reset first, so a hot reload re-runs it cleanly.
    function M.gameplay()
        Game.reset()

        Game.effects.define('burning', {
            duration = 4, period = 1,
            assetTags = { 'debuff.burning' },
            modifiers = { { attr = 'health', magnitude = -3 } },
            stacking = { policy = 'refresh' },
        })

        Weapons.define('pistol', {
            damage = 12, magazine = 12, fireInterval = 0.15, reloadTime = 1.2,
            spread = 0.010, recoil = 0.018, recoilMax = 0.10, recoilRecovery = 0.5,
            kick = 0.020, range = 32, autoReload = true, ammoItem = 'ammo.pistol',
        })

        Weapons.define('launcher', {
            kind = 'projectile', damage = 0,
            magazine = 1, fireInterval = 0.9, reloadTime = 1.6,
            ammoItem = 'ammo.grenade', autoReload = true,
            projectile = { kind = 'grenade', speed = 11, radius = 0.22, range = 26,
                           explosion = 'frag' },
        })

        -- The flash is DESCRIBED here and pushed by whoever has a light grid. A
        -- dedicated server detonates the same explosion and pushes nothing.
        Explosion.define('frag', {
            radius = 4.5, damage = 70, curve = 'smooth',
            tags = { 'damage.type.explosive' },
            effects = { 'burning' },
            gasAmount = 30, gasRadius = 2.4,
            light = { radius = 12, intensity = 2.4, color = { 1.00, 0.74, 0.36 } },
        })

        Inventory.defineItem('pistol',        { stack = 1, weapon = 'pistol' })
        Inventory.defineItem('launcher',      { stack = 1, weapon = 'launcher' })
        Inventory.defineItem('ammo.pistol',   { stack = 120, ammoFor = 'pistol' })
        Inventory.defineItem('ammo.grenade',  { stack = 12,  ammoFor = 'launcher' })
    end

    -----------------------------------------------------------------------
    -- Archetypes. Behaviour composes; nothing inherits.
    -----------------------------------------------------------------------

    function M.archetypes()
        Entity.clearArchetypes()

        -- Directional: eight angle buckets, so you can see which way it faces.
        Entity.archetype('imp', function(e)
            e:add(C.Billboard{ sheet = 'imp' })
            e:add(C.Health{ hp = 30, max = 30 })
            e:add(C.Brain{ state = 'patrol' })
            e.radius = 0.28
            Game.attach(e, { authority = isAuthority() })
            -- Host only: clients never run AI. Attach is cheap and fill fields;
            -- step is gated by isAuthority in updateCreatures.
            if isAuthority() then
                AI.attach(e, { state = 'patrol', alertRange = 10, speed = 2.2 })
            end
        end)

        -- Always-facing: one bucket, a floating pickup. C16: a crystal is grabbed
        -- on contact and refills pistol ammo — the demo's one live pickup, and the
        -- reason the bag UI and the pickup ticker have something real to show.
        Entity.archetype('crystal', function(e)
            e:add(C.Billboard{ sheet = 'crystal' })
            e:add(C.Health{ hp = 10, max = 10 })
            e.radius = 0.22
            e.pickup = { item = 'ammo.pistol', count = 12, label = 'pistol ammo +12' }
            Game.attach(e, { authority = isAuthority() })
        end)

        Entity.archetype('player', function(e)
            e:add(C.Player{ peerId = 0, name = 'local' })
            e:add(C.Health{ hp = 100, max = 100 })
            e:add(C.Weapon{})
            e:add(C.Input{})
            e.radius = 0.24
            Game.attach(e, { authority = isAuthority() })

            -- The bag is what the gun reloads out of: `Inventory.equip` wires the
            -- weapon's ammunition supply to it, so a reload consumes the item whose
            -- `ammoFor` names the weapon and weapons.lua never learns what an
            -- inventory is.
            Inventory.attach(e, { capacity = 8 })
            Inventory.add(e, 'pistol', 1)
            Inventory.add(e, 'launcher', 1)
            Inventory.add(e, 'ammo.pistol', 96)
            Inventory.add(e, 'ammo.grenade', 6)
            Inventory.equipWeapon(e, 'pistol')
        end)

        -- What the launcher throws. A projectile is an ordinary entity, so it
        -- replicates and draws through machinery that needed no edit.
        Entity.archetype('grenade', function(e)
            e:add(C.Billboard{ sheet = 'grenade' })
            e.radius = 0.22
        end)
    end

    function M.sprites()
        MeatRay.sprites.clear()
        MeatRay.sprites.define('imp', {
            angles = 8, frames = 4, fps = 7,
            color = { 0.78, 0.24, 0.20 }, anchor = 'feet', scale = 0.85,
        })
        MeatRay.sprites.define('crystal', {
            angles = 1, frames = 2, fps = 3,
            color = { 0.35, 0.75, 0.95 }, anchor = 'center', scale = 0.5,
        })
        -- Other players draw as imps: a placeholder, but a visible one.
        MeatRay.sprites.define('player', {
            angles = 8, frames = 4, fps = 7,
            color = { 0.35, 0.85, 0.45 }, anchor = 'feet', scale = 0.9,
        })
        MeatRay.sprites.define('grenade', {
            angles = 1, frames = 1, fps = 1,
            color = { 0.95, 0.80, 0.30 }, anchor = 'center', scale = 0.28,
        })
    end

    return M
end
