--[[
    app.rules — one fixed step of the gameplay rules, and the spawners that
    put rule-driven things into the world.

    Tenth cut of un-god-filing main.lua. stepRules runs wherever the
    simulation is authoritative: single player, and the host in all three
    network modes — never on a client, which asks and is told. The order
    inside it is fixed and matters: effects and weapon timers first (a
    reload that finishes this step should be able to fire next step), then
    projectiles (which may detonate and therefore change health), then the
    gas field, then what the gas does to whoever is standing in it.

    snapQuarter arrives as a ctx CLOSURE: it is assigned in main.lua's
    input section after this module is built, and the wrapper reads the
    local at call time — the same late-binding trick the menu uses for the
    network starters.
]]

return function(ctx)
    local game, Game = ctx.game, ctx.Game
    local Entity, Collide, AI = ctx.Entity, ctx.Collide, ctx.AI
    local Inventory, Rep = ctx.Inventory, ctx.Rep
    local Projectiles, GasSim = ctx.Projectiles, ctx.GasSim
    local note, resolveFire = ctx.note, ctx.resolveFire
    local fireFor, pushFlash = ctx.fireFor, ctx.pushFlash
    local isAuthority, snapQuarter = ctx.isAuthority, ctx.snapQuarter

    local M = {}

    -- Creature behaviour. Host-only: a client receives transforms via snapshots and
    -- never pathfinds. Uses meatray.sim.ai (patrol / chase / cover on pathfind).
    function M.updateCreatures(dt, world, entities, target)
        if not isAuthority() then return end
        AI.stepAll(entities, dt, {
            world = world,
            entities = entities,
            target = target,
        })
    end

    -- C16: give every player-touched pickup entity its grant and remove it. The
    -- local player gets the ticker line; a remote peer's pickup is silent here
    -- (its own client says it) but the grant still lands, host-authoritative.
    function M.stepPickups(entities)
        for i = 1, #entities do
            local e = entities[i]
            if e and e.pickup and not e.dead then
                for j = 1, #entities do
                    local p = entities[j]
                    if p and p.components and p.components.player and not p.dead then
                        local dx, dy = (p.x or 0) - (e.x or 0), (p.y or 0) - (e.y or 0)
                        local reach = (p.radius or 0.24) + (e.radius or 0.22) + 0.1
                        if dx * dx + dy * dy <= reach * reach then
                            local grant = e.pickup
                            Inventory.add(p, grant.item, grant.count or 1)
                            e.dead = true          -- reaped like any dead entity
                            require('meatray.asset').sound.playAt('pickup', e.x, e.y)
                            if p == game.player then
                                game.messages:pickup(grant.label
                                    or ('picked up ' .. tostring(grant.item)))
                                -- C28: a quick green blip confirms the grab.
                                game.screenfx:flash({ 0.4, 0.9, 0.5 },
                                    { peak = 0.22, inTime = 0.02, out = 0.35 })
                            end
                            break
                        end
                    end
                end
            end
        end
    end

    -- Templates: reconfigure the running demo into a genre. Movement speeds and
    -- style come straight from the resolved config; the loadout re-equips the
    -- player; the mode string picks a stock ruleset. A scaffold template still
    -- applies its config and says out loud what it cannot provide.
    function M.applyTemplate(name)
        local cfg, why = Game.template.resolve(name)
        if not cfg then return false, why end

        game.template = cfg
        game.moveSpeed = cfg.moveSpeed or game.moveSpeed
        game.turnSpeed = cfg.turnSpeed or game.turnSpeed
        game.gridMove = (cfg.movement == 'grid')
        -- Entering grid movement, snap the current facing to a cardinal so the
        -- first quarter-turn lands square.
        if game.gridMove then game.aim = snapQuarter(game.aim) end

        -- Re-equip the local player to the template's loadout.
        local player = game.player
        if player and player.components and player.components.inventory then
            Inventory.attach(player, { capacity = 8 })   -- clears the bag
            for _, item in ipairs(cfg.loadout or {}) do
                Inventory.add(player, item.item, item.count or 1)
            end
            -- Equip the first weapon in the loadout, if any.
            for _, item in ipairs(cfg.loadout or {}) do
                local def = Inventory.itemDef and Inventory.itemDef(item.item)
                if def and def.weapon then
                    Inventory.equipWeapon(player, item.item)
                    break
                end
            end
            -- RPG stats: grant the exploration attributes a stat system reads.
            if cfg.rpgStats then
                Game.attributes.grantAll(player, {
                    healthMax = 100, health = 100,
                    staminaMax = 100, stamina = 100,
                    manaMax = 50, mana = 50,
                })
            end
        end

        note(('template: %s (%s, %s combat, %s movement)'):format(
            cfg.name or name, cfg.mode, cfg.combat, cfg.movement))
        if cfg.ready == 'scaffold' and cfg.needs then
            note('scaffold — you still need: ' .. table.concat(cfg.needs, ', '))
        end
        return true
    end

    -- C22: spawn a computer player. It is an ordinary 'player' entity — so it
    -- replicates, takes damage, respawns and appears in the killfeed exactly like
    -- a human — paired with a Bot brain that produces its input each tick.
    local botSeq = 0
    function M.spawnBot()
        local world = game.world
        if not world then return nil end
        local spawn = world.spawn or { x = 4.5, y = 4.5 }
        local e = Entity.spawn('player', spawn.x + botSeq * 0.6, spawn.y)
        if not e then return nil end
        e.isBot = true
        if world then Collide.ground(e, world) end
        e:snapPrevious()
        table.insert(game.entities, e)
        botSeq = botSeq + 1
        local brain = Game.bot.new{ seed = 1000 + botSeq, fireRange = 8 }
        game.bots[#game.bots + 1] = { entity = e, brain = brain }
        return e
    end

    -- I2: a neural-net player. Same entity and the same bots list as C22 — a
    -- Neurobot fills the identical think() contract, so stepBots drives both
    -- kinds without knowing which is which. With brainText it plays a trained
    -- brain (scripts/evolve.lua writes one); without, a fresh random one.
    function M.spawnNeurobot(brainText)
        local world = game.world
        if not world then return nil end
        local spawn = world.spawn or { x = 4.5, y = 4.5 }
        local e = Entity.spawn('player', spawn.x + botSeq * 0.6, spawn.y)
        if not e then return nil end
        e.isBot = true
        Collide.ground(e, world)
        e:snapPrevious()
        table.insert(game.entities, e)
        botSeq = botSeq + 1
        local brain
        if brainText then
            local err
            brain, err = Game.neurobot.load(brainText)
            if not brain then
                note('neurobot: ' .. tostring(err))
                return nil
            end
        else
            brain = Game.neurobot.new{ seed = 2000 + botSeq }
        end
        game.bots[#game.bots + 1] = { entity = e, brain = brain }
        return e
    end

    -- I1: a crowd member is an ordinary imp with the monster brain REMOVED — it
    -- replicates, takes damage and dies like any entity, but its motion belongs
    -- to the flock (sim.crowd), not to sim.ai. One entity, exactly one driver.
    function M.spawnCrowdAgent()
        local world = game.world
        if not (world and game.crowd) then return nil end
        local spawn = world.spawn or { x = 4.5, y = 4.5 }
        local e = Entity.spawn('imp', spawn.x, spawn.y)
        if not e then return nil end
        e:remove('brain')
        e.crowdAgent = true
        Collide.ground(e, world)
        e:snapPrevious()
        table.insert(game.entities, e)
        game.crowd:add(e)
        return e
    end

    -- C22: drive every live bot. Each produces input the host feeds through the
    -- same applyInput a human's does, then acts on its fire and use intents — the
    -- bot plays the game rather than the game moving it.
    function M.stepBots(step, world, entities)
        for i = #game.bots, 1, -1 do
            local b = game.bots[i]
            local e = b.entity
            if not e or e.dead then
                -- A dead bot is reaped with everything else; drop the brain too.
                table.remove(game.bots, i)
            else
                local intent = b.brain:think(e, world, entities, step)
                Rep.applyInput(e, Rep.sanitiseInput(intent.input), step, world,
                               { moveSpeed = game.moveSpeed, turnSpeed = game.turnSpeed })
                if intent.use and intent.useDoor then
                    world:setDoorOpen(intent.useDoor.tx, intent.useDoor.ty, true)
                end
                if intent.fire then
                    Game.respawn.dropProtection(e)
                    local shot = resolveFire(world, entities, e, intent.input.angle)
                    if shot and shot.killed then
                        game.messages:kill('a bot',
                            tostring(shot.targetKind or 'enemy'), shot.weapon)
                    end
                end
            end
        end
    end

    function M.stepRules(step, world, entities)
        if not world or not entities then return end

        Game.tickAll(entities, step)

        -- C22: bots think and act before the rest of the rules, so their shots and
        -- door-opens land this tick like a human's input already has.
        if #game.bots > 0 then M.stepBots(step, world, entities) end

        -- H5: the project's registered tick hooks. One that raises is retired
        -- with a console line — better a missing feature than sixty errors a
        -- second — and the loop runs backwards so the removal is safe.
        for i = #game.projectTicks, 1, -1 do
            local ok, err = pcall(game.projectTicks[i], step)
            if not ok then
                note('project onTick failed (hook removed): ' .. tostring(err))
                table.remove(game.projectTicks, i)
            end
        end

        -- I1: the crowd flocks to the local player. The flow field recomputes
        -- only when the player crosses into a new tile — a flood fill per step
        -- would be the whole tick budget. Dead members leave the flock; the
        -- entity reaper handles the corpse.
        if game.crowd then
            local p = game.player
            if p then
                local tileKey = math.floor(p.y) * 4096 + math.floor(p.x)
                if game.crowdGoal ~= tileKey then
                    game.crowdGoal = tileKey
                    game.crowd:setGoal(p.x, p.y, p.storey or 1)
                end
                -- LOD measures from the player even between goal recomputes.
                game.crowd:setFocus(p.x, p.y)
            end
            for i = game.crowd:count(), 1, -1 do
                local a = game.crowd.agents[i]
                if not a or a.dead then game.crowd:remove(a) end
            end
            game.crowd:step(step)
        end

        -- F5: floors that hurt. Host authority, both loops — the bite goes
        -- through the same damage path as everything else, so armour, fire
        -- resistance and god mode all have their usual say.
        if game.hazards then
            game.hazards:update(entities, step)
        end

        -- C16: on-contact pickups. Host authority (solo is its own host). An
        -- entity carrying a `pickup` grant that a living player touches is added
        -- to the bag and removed from the world, with a ticker line to say so.
        M.stepPickups(entities)

        -- Secret discovery is a rule, so it runs wherever the rules run — the
        -- solo loop and the hosted loop both come through here.
        if game.secretTracker and game.secretWorld == world then
            game.secretTracker:update(entities)
        end

        -- C17: auto-closing doors, host-authoritative like everything here. A door
        -- with someone standing in it waits rather than closing on them; the tile a
        -- door occupies is the doorway, so the block check is a plain tile match.
        world:tickDoors(step, function(tx, ty, storey)
            for i = 1, #entities do
                local e = entities[i]
                if e and not e.dead and (e.storey or 1) == storey
                   and math.floor(e.x) + 1 == tx and math.floor(e.y) + 1 == ty then
                    return true
                end
            end
            return false
        end)

        local field = fireFor(world)

        local impacts = Projectiles.step(entities, step, {
            world = world, entities = entities,
            gas = field, onLight = pushFlash,
        })

        for i = 1, #impacts do
            local impact = impacts[i]
            if impact.explosion then
                local hits = #impact.explosion.hits
                note(('explosion: %d caught, %d in cover'):format(hits, #impact.explosion.blocked))
                require('meatray.asset').sound.playAt('explosion',
                    impact.explosion.x, impact.explosion.y)
                -- C19: an explosion is the loudest thing on the map — heard far.
                AI.broadcastSound(entities, impact.explosion.x, impact.explosion.y,
                                  impact.explosion.storey or 1, { loudness = 2.2 })
                if game.decals then
                    game.decals:add{
                        x = impact.explosion.x, y = impact.explosion.y, z = 0.02,
                        kind = 'scorch', life = 18, scale = 0.55,
                    }
                end
                -- C27: an explosion throws debris and smoke (air bursts, no normal).
                if game.particles then
                    game.particles:burst('debris', impact.explosion.x,
                                         impact.explosion.y, { z = 0.4, scale = 1.5 })
                    game.particles:burst('smoke', impact.explosion.x,
                                         impact.explosion.y, { z = 0.6, scale = 1.5 })
                end
                if game.host then
                    game.host:event('boom', { x = impact.explosion.x, y = impact.explosion.y,
                                              radius = impact.explosion.radius, hits = hits })
                end
                -- Host-local player learns direction here, and only when the blast
                -- actually reached them; clients learn it from the boom event.
                if game.player then
                    for h = 1, hits do
                        if impact.explosion.hits[h].entity == game.player then
                            game.hud:damageFrom(impact.explosion.x, impact.explosion.y,
                                                game.player.x, game.player.y,
                                                game.player.angle)
                            -- D35: remember where it came from, for the killcam.
                            game.lastHurtX, game.lastHurtY =
                                impact.explosion.x, impact.explosion.y
                            break
                        end
                    end
                end
            end
        end

        Projectiles.sweep(entities)

        if field then
            field:step(step)
            GasSim.damage(field, entities, step, {
                amount = 16, minDensity = 0.04,
                tags = { 'damage.type.fire' },
            })
        end

        if game.mode then
            game.mode:tick(step, world, entities)
        end
        -- B10: map-placed trigger graphs tick beside the CLI mode, so their volumes
        -- update and any timed graph work advances on the simulation clock.
        if game.triggerModes then
            for i = 1, #game.triggerModes do
                game.triggerModes[i]:tick(step, world, entities)
            end
        end
        -- C-map: lifts slide on the simulation clock, so a recorded demo replays
        -- their motion exactly.
        if game.movers then game.movers:update(step) end
    end

    return M
end
