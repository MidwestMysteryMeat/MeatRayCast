--[[
    app.combat — shots, their consequences, and their presentation.

    Seventh cut of un-god-filing main.lua: the one place a trigger pull is
    resolved (resolveFire — authoritative wherever it runs), the door and
    fire-field helpers beside it, and the cosmetic layer a shot leaves
    behind — decals, particles, flashes — drawn z-tested against the same
    buffer sprites use.

    The split inside this file matters more than the file itself:
    resolveFire changes the world and runs only where the sim is
    authoritative; pushFlash/applyShotDecals/drawDecals/drawParticles are
    presentation and run wherever there is a screen. A dedicated server
    calls the first and never the second, and nothing here would notice.
]]

return function(ctx)
    local game, Game, MeatRay = ctx.game, ctx.Game, ctx.MeatRay
    local Collide, Billboard, Decals = ctx.Collide, ctx.Billboard, ctx.Decals
    local GasSim, Weapons, AI = ctx.GasSim, ctx.Weapons, ctx.AI

    local M = {}

    -- The door the entity is looking at, within reach, or nil.
    function M.doorInFront(world, e, reach)
        local dirX, dirY = math.cos(e.angle), math.sin(e.angle)
        local dist, tx, ty = Collide.rayTile(world, e.x, e.y, dirX, dirY, reach or game.doorReach)
        if dist and world:doorAt(tx, ty) then return tx, ty end
        return nil
    end

    -- The fire field for a world, built once and cached against it. Fire is a gas:
    -- a scalar that diffuses across open tiles, decays, and hurts whatever stands in
    -- it. Smoke and poison are the same object with different constants.
    function M.fireFor(world)
        if not world then return nil end
        if game.fire and game.fireWorld == world then return game.fire end
        game.fire = GasSim.new{ world = world, name = 'fire', rate = 1.1, decay = 0.55 }
        game.fireWorld = world
        return game.fire
    end

    -- An explosion's flash. Dynamic lights are per-frame, so the light itself is
    -- pushed in love.draw; this only records that there was one and how long ago.
    -- Presentation, and deliberately not simulation: a dedicated server records
    -- nothing and the game is identical.
    function M.pushFlash(light)
        if not light then return end
        game.flashes[#game.flashes + 1] = {
            x = light.x, y = light.y, radius = light.radius,
            intensity = light.intensity or 1.6, color = light.color,
            life = 0.28, maxLife = 0.28,
        }
    end

    -- Wall holes for hitscan; ground marks when something dies. Cosmetic only.
    function M.applyShotDecals(shot)
        if not shot or not game.decals then return end
        if shot.result == 'wall' and shot.hitx and shot.hity then
            game.decals:addHit(shot.hitx, shot.hity, shot.nx, shot.ny, {
                kind = 'bullet', life = 12, scale = 0.18,
                z = 0.45,
            })
            -- C27: sparks fly off the stone.
            if game.particles then
                game.particles:burst('spark', shot.hitx, shot.hity,
                                      { nx = shot.nx, ny = shot.ny, z = 0.45 })
            end
        elseif shot.result == 'hit' and shot.hitx and shot.hity then
            if shot.killed then
                game.decals:add{
                    x = shot.hitx, y = shot.hity, z = 0.02,
                    kind = 'blood', life = 10, scale = 0.35,
                }
            end
            -- C27: a hit sprays blood back toward the shooter — the normal is the
            -- shot direction reversed — whether or not it killed.
            if game.particles then
                local a = shot.angle or 0
                game.particles:burst('blood', shot.hitx, shot.hity,
                                      { nx = -math.cos(a), ny = -math.sin(a), z = 0.5 })
            end
        end
        -- C27: the tracer, from the muzzle to where the round stopped.
        if game.particles and shot.x and shot.y and shot.hitx and shot.hity
           and (shot.result == 'wall' or shot.result == 'hit') then
            game.particles:tracer(shot.x, shot.y, shot.hitx, shot.hity, { z = 0.5 })
        end
    end

    -- Resolves a shot. Authoritative wherever it runs: in single player that is the
    -- only machine, and in every network mode it only ever runs on the host.
    --
    -- Nothing here subtracts hit points. `Weapons.fire` applies a damage EFFECT, so
    -- armour, resistances and immunities all work on it without this function — or
    -- weapons.lua — knowing that any of them exist.
    function M.resolveFire(world, entities, shooter, aim)
        local shot, why = Weapons.fire(shooter, {
            world = world, entities = entities, angle = aim,
            gas = M.fireFor(world), onLight = M.pushFlash,
        })

        if not shot then
            return { shooter = shooter.id, result = why or 'nothing' }
        end

        -- C19: a shot is a NOISE. Nearby AI that did not see it walk over to look
        -- (AI.hear ignores a shooter that is itself already chasing, so a firing
        -- monster does not investigate its own muzzle).
        AI.broadcastSound(entities, shooter.x, shooter.y, shooter.storey or 1,
                          { loudness = 1 })

        -- Flattened to primitives on purpose. `Weapons.fire` returns live entity
        -- references (the target it hit, the projectiles it made) because a caller
        -- in the same process wants them — and meatray.net.serialize refuses tables
        -- it cannot represent rather than emitting nonsense, so handing the raw
        -- record to `host:event` would be a message that never arrives. This is the
        -- event shape the demo already sent, so describeShot, the log and nettest all
        -- keep reading exactly what they read before.
        local flat = {
            shooter = shooter.id,
            x = shot.x, y = shot.y, angle = shot.angle,
            weapon = shot.weapon, ammo = shot.ammo, kick = shot.kick,
            result = shot.result,
            dist = shot.dist, tx = shot.tx, ty = shot.ty,
            hitx = shot.hitx, hity = shot.hity,
            nx = shot.nx, ny = shot.ny,
            target = shot.targetId, targetKind = shot.targetKind,
            damage = shot.damage, hp = shot.hp, killed = shot.killed,
            pellets = #(shot.pellets or {}),
        }
        -- Presentation: bullet marks are local on every machine that saw the event.
        M.applyShotDecals(flat)
        return flat
    end

    -- Project short-lived marks into the view. Occlusion uses the same z-buffer
    -- column as sprites so a hole behind a wall does not ghost through.
    local DECAL_COLOR = {
        bullet = { 0.12, 0.10, 0.08 },
        blood  = { 0.45, 0.05, 0.05 },
        scorch = { 0.08, 0.07, 0.06 },
        mark   = { 0.20, 0.18, 0.15 },
    }

    function M.drawDecals(view, zbuffer)
        if not game.decals or not MeatRay.canRender() then return end
        local list = game.decals:all()
        if #list == 0 then return end

        local w = love.graphics.getWidth()
        local h = love.graphics.getHeight()
        local horizonShift = view.horizonShift or 0
        local eyeZ = view.eyeZ
        if eyeZ == nil then eyeZ = 0.5 end

        for i = 1, #list do
            local d = list[i]
            local tx, ty = Billboard.project(
                d.x, d.y, view.x, view.y,
                view.dirX, view.dirY, view.planeX, view.planeY)
            if tx and ty and ty < 40 then
                local col = math.floor(w / 2 * (1 + tx / ty) + 0.5)
                local depth = zbuffer and zbuffer[col]
                if not depth or ty <= depth + 0.05 then
                    local feetZ = d.z or 0
                    local scale = d.scale or 0.25
                    -- Wall marks hang mid-height; floor marks sit on the surface.
                    if d.wall then feetZ = d.z or 0.4 end
                    local rect = Billboard.screenRect(tx, ty, w, h, {
                        scale = scale,
                        anchor = d.wall and 'center' or 'feet',
                        horizonShift = horizonShift,
                        eyeZ = eyeZ,
                        feetZ = feetZ,
                    })
                    if rect then
                        local a = Decals.alpha(d) * 0.85
                        local c = DECAL_COLOR[d.kind] or DECAL_COLOR.mark
                        love.graphics.setColor(c[1], c[2], c[3], a)
                        love.graphics.rectangle('fill', rect.x, rect.y, rect.w, rect.h)
                    end
                end
            end
        end
        love.graphics.setColor(1, 1, 1, 1)
    end

    -- C27: draw the live particles, billboarded and z-tested against the same
    -- buffer sprites and decals use, so a spark behind a wall is occluded. Points
    -- are little quads; a tracer is a line between its two projected endpoints.
    function M.drawParticles(view, zbuffer)
        if not game.particles or not MeatRay.canRender() then return end
        local list = game.particles:all()
        if #list == 0 then return end

        local w = love.graphics.getWidth()
        local h = love.graphics.getHeight()
        local Particles = MeatRay.particles

        local function projectPoint(px, py, pz)
            local tx, ty = Billboard.project(px, py, view.x, view.y,
                                             view.dirX, view.dirY, view.planeX, view.planeY)
            if not tx or not ty or ty >= 40 or ty <= 0 then return nil end
            local col = math.floor(w / 2 * (1 + tx / ty) + 0.5)
            local depth = zbuffer and zbuffer[col]
            if depth and ty > depth + 0.05 then return nil end     -- occluded
            local rect = Billboard.screenRect(tx, ty, w, h, {
                scale = 0.1, anchor = 'center',
                horizonShift = view.horizonShift or 0,
                eyeZ = view.eyeZ or 0.5, feetZ = pz or 0.5,
            })
            return rect, ty
        end

        for i = 1, #list do
            local p = list[i]
            local a = Particles.alpha(p)
            local c = p.color or { 1, 1, 1 }
            if p.tracer then
                local r1 = projectPoint(p.x, p.y, p.z)
                local r2 = projectPoint(p.x2, p.y2, p.z2)
                if r1 and r2 then
                    love.graphics.setColor(c[1], c[2], c[3], a)
                    love.graphics.setLineWidth(2)
                    love.graphics.line(r1.x + r1.w / 2, r1.y + r1.h / 2,
                                       r2.x + r2.w / 2, r2.y + r2.h / 2)
                    love.graphics.setLineWidth(1)
                end
            else
                local rect, ty = projectPoint(p.x, p.y, p.z)
                if rect then
                    -- Size shrinks with distance the same way the billboard does.
                    local s = math.max(1, (p.size or 0.03) * h / ty)
                    love.graphics.setColor(c[1], c[2], c[3], a)
                    love.graphics.rectangle('fill', rect.x + rect.w / 2 - s / 2,
                                            rect.y + rect.h / 2 - s / 2, s, s)
                end
            end
        end
        love.graphics.setColor(1, 1, 1, 1)
    end

    function M.describeShot(shot)
        if not shot then return 'nothing happened' end
        if shot.result == 'empty' then return 'out of ammo' end
        if shot.result == 'cooldown' then return 'still cycling' end
        if shot.result == 'reloading' then return 'reloading' end
        if shot.result == 'launched' then return 'grenade away' end
        if shot.result == 'miss' then return 'shot into the dark' end
        if shot.result == 'wall' then
            return ('hit wall at %d,%d (%.1f away)'):format(shot.tx or 0, shot.ty or 0,
                                                            shot.dist or 0)
        end
        if shot.result ~= 'hit' then return tostring(shot.result) end
        if shot.killed then return ('killed %s'):format(tostring(shot.targetKind)) end
        return ('hit %s for %d, %d left'):format(tostring(shot.targetKind),
                                                 shot.damage or 0, shot.hp or 0)
    end

    return M
end
