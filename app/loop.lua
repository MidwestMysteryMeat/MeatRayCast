--[[
    app.loop — the frame: real time in, fixed steps out.

    Thirteenth cut of un-god-filing main.lua. update() splits time the way
    the whole engine depends on: presentation (flashes, decals, HUD deltas,
    messages, spectator, footsteps, hazard tints, automap memory) rolls on
    REAL time every frame; the simulation advances only through the fixed
    clock — the host's, the client's, or the solo Tick that simulate() runs
    on. simulate() is also the loop the demo recorder writes down and the
    player feeds back, which is why the input decision (keyboard or
    recording) lives at its top and the divergence checksum at its bottom.

    hudState belongs to app/draw.lua, which is constructed after this
    module — it arrives as a late-binding ctx closure.
]]

return function(ctx)
    local game, Game, MeatRay = ctx.game, ctx.Game, ctx.MeatRay
    local Rep, note, args = ctx.Rep, ctx.note, ctx.args
    local activeWorld, activeEntities = ctx.activeWorld, ctx.activeEntities
    local activePlayer = ctx.activePlayer
    local spawnPlayerAt = ctx.spawnPlayerAt
    local gatherInput, updateAim = ctx.gatherInput, ctx.updateAim
    local updatePhotoCam = ctx.updatePhotoCam
    local applyDemoEvent = ctx.applyDemoEvent
    local updateCreatures, stepRules = ctx.updateCreatures, ctx.stepRules
    local hudState = ctx.hudState              -- late-binding closure

    local M = {}

    -- Single player. The host does the same thing to its own player, through the
    -- same Rep.applyInput, which is why prediction and authority agree.
    -- A5, host authority: notice the local player's death, wait out the delay on
    -- the simulation tick (so pausing pauses the wait), and bring them back
    -- shielded. Runs from simulate() when solo and from the host's onStep when
    -- hosting. Remote peers keep their entities host-side already; wiring their
    -- deaths through meatray.game.modes' onRequestRespawn into game.respawn is the
    -- multiplayer half of this same machinery.
    function M.stepRespawn(step)
        if game.player and game.player.dead
           and game.respawn:state('local') == 'alive' then
            game.respawn:notifyDeath('local')
            if game.campaign and game.campaign.state == 'mission' then
                game.campaign:addDeath(1)
            end
            note('you died')
            -- D35: swing to the killcam, looking from where I fell toward the last
            -- thing that hurt me.
            game.spectator:onDeath(game.player.x, game.player.y,
                                   game.lastHurtX, game.lastHurtY)
        end
        for _, id in ipairs(game.respawn:tick(step)) do
            if id == 'local' and game.wantPlayer and game.world then
                local spawn = Game.respawn.pickSpawn(
                    { game.world.spawn or { x = 4.5, y = 4.5 } }, game.entities)
                local p = spawnPlayerAt(spawn.x, spawn.y, spawn.angle or 0)
                game.respawn:spawned('local', p)
                if game.host then game.host.localPlayer = p end
                game.spectator:onRevive()      -- D35: my own eyes again
                note('back in — shielded for a moment')
            end
        end
    end

    function M.simulate(step)
        for _, e in ipairs(game.entities) do e:snapPrevious() end

        -- What drives this tick: the keyboard, or the recording.
        local input
        if game.demoPlay then
            if game.demoPlay:finished(game.demoTick) then
                note('demo finished')
                game.demoPlay = nil
            else
                for _, ev in ipairs(game.demoPlay:eventsAt(game.demoTick) or {}) do
                    applyDemoEvent(ev)
                end
                input = game.demoPlay:inputAt(game.demoTick)
            end
        end
        input = input or gatherInput()

        if game.demoRec then
            game.demoRec:frame(game.demoTick, Rep.sanitiseInput(input))
            for _, q in ipairs(game.demoEvents) do
                game.demoRec:event(game.demoTick, q.name, q.params)
            end
            game.demoEvents = {}
        end

        if game.player and not game.player.dead then
            -- F5: liquids slow. The kit answers a question rather than writing
            -- into the entity, and the one who owns the speed multiplies.
            local wade = game.hazards and game.hazards:speedFactor(game.player) or 1
            Rep.applyInput(game.player, Rep.sanitiseInput(input), step, game.world,
                           { moveSpeed = game.moveSpeed * wade,
                             turnSpeed = game.turnSpeed,
                             noclip = game.noclip })
        end
        updateCreatures(step, game.world, game.entities, game.player)
        stepRules(step, game.world, game.entities)
        game.world:update(step)

        M.stepRespawn(step)

        -- F4: the campaign runs on the fixed tick — mission time, exit volumes,
        -- kill tallies. Kills are counted by noticing deaths rather than by
        -- hooking every damage path, the same delta trick the HUD flash uses:
        -- a dead AI that has not been tallied yet is a kill, whoever caused it.
        if game.campaign then
            if game.campaign.state == 'mission' then
                for _, e in ipairs(game.entities) do
                    if e.dead and not e._tallied and e.components and e.components.brain then
                        e._tallied = true
                        game.campaign:addKill(1)
                    end
                end
                if game.campaignTriggers then
                    game.campaignTriggers:update(game.entities, step)
                end
            end
            game.campaign:tick(step, game.world, game.entities)
        end

        -- The forensics: a checksum a second while recording; while replaying,
        -- the FIRST disagreement is named and then the run is left to play out —
        -- a diverged replay is still worth watching to see how far off it drifts.
        if game.demoRec and game.demoTick % 60 == 59 then
            game.demoRec:checkpoint(game.demoTick, MeatRay.demo.checksum(game.entities))
        end
        if game.demoPlay and not game.demoDiverged then
            local okV, want, got = game.demoPlay:verify(game.demoTick, game.entities)
            if not okV then
                game.demoDiverged = game.demoTick
                note(('demo DIVERGED at tick %d (recorded %s, got %s)')
                     :format(game.demoTick, tostring(want), tostring(got)))
            end
        end
        game.demoTick = game.demoTick + 1
    end

    function M.update(dt)
        if args.selftest or args.nettest or args.browse or args.netcheck
           or args.netfrag or args.netproxy or args.punchcheck then return end
        dt = math.min(dt, 0.25)

        -- F10: while the photo camera is detached, the keys fly it instead of the
        -- player; the player's own aim is left exactly where it was.
        if MeatRay.canRender() then
            if game.photo:isActive() then updatePhotoCam(dt) else updateAim(dt) end
        end

        -- Flashes and decals fade in real time, not simulation time: they are
        -- presentation artefacts and nothing about the game depends on them.
        for i = #game.flashes, 1, -1 do
            local f = game.flashes[i]
            f.life = f.life - dt
            if f.life <= 0 then table.remove(game.flashes, i) end
        end
        if game.decals then game.decals:update(dt) end
        if game.particles then game.particles:update(dt) end   -- C27
        game.hud:update(dt, hudState(activePlayer()))
        -- F4/F6: the tally and the message channels roll on real time — they are
        -- presentation, and must keep rolling while the simulation idles.
        game.intermission:update(dt)
        game.messages:update(dt)
        game.screenfx:update(dt)
        -- D35: the killcam/spectator clock runs on real time, and it drops targets
        -- that die between frames.
        game.spectator:update(dt, activeEntities(), activePlayer())

        -- C20: a playing cutscene rail advances on real time (presentation), and
        -- clears itself the frame it finishes so control returns to the player.
        if game.rail then
            if game.rail:isActive() then game.rail:update(dt) else game.rail = nil end
        end

        -- Where the ears are, once per frame: every positional play this frame
        -- attenuates and pans against the player's own position and facing.
        do
            local p = activePlayer()
            if p then
                MeatRay.asset.sound.setListener(p.x, p.y, p.angle)
            end
        end

        -- C30: footsteps. Presentation only — a step every stride the player walks,
        -- its material from the surface tag (or the hazard they are wading through),
        -- played positionally. The sound is the owner's content: playAt is silent
        -- until a `footstep.<material>` WAV is declared, so this costs nothing today.
        do
            local p = activePlayer()
            local w = activeWorld()
            if p and w and not p.dead and game.footsteps then
                local step = game.footsteps:advanceFromMove(p,
                    game.footPrevX or p.x, game.footPrevY or p.y,
                    function(tx, ty, st)
                        if w.surfaceAt then
                            local m = w:surfaceAt(tx, ty, st); if m then return m end
                        end
                        if game.hazards then return game.hazards:standingIn(p) end
                        return nil
                    end)
                game.footPrevX, game.footPrevY = p.x, p.y
                if step and MeatRay.asset and MeatRay.asset.sound
                   and MeatRay.asset.sound.playAt then
                    MeatRay.asset.sound.playAt('footstep.' .. step.material, step.x, step.y)
                end
                -- C31: the room tone follows the player. On a zone change the game
                -- would crossfade the owner's loop; the tracker names which room.
                if game.ambient then
                    local zt = game.ambient:update(p.x, p.y, p.storey or 1)
                    if zt.changed then note('ambient: ' .. (zt.sound or 'silence')) end
                end
            end
        end

        -- C28: the tint of whatever the player is standing in. hold() is re-
        -- asserted every frame it applies and released the frame it stops, so a
        -- water/lava wash is up exactly while the player is in it.
        do
            local p = activePlayer()
            local kind = (game.hazards and p and not p.dead)
                         and game.hazards:standingIn(p) or nil
            for _, k in ipairs({ 'water', 'slime', 'lava' }) do
                if kind == k then
                    local col = (k == 'water') and { 0.2, 0.4, 0.85 }
                             or (k == 'slime') and { 0.3, 0.7, 0.2 }
                             or { 0.95, 0.3, 0.1 }
                    game.screenfx:hold('hazard.' .. k, col, { peak = 0.28, style = 'fill' })
                else
                    game.screenfx:release('hazard.' .. k)
                end
            end
        end

        -- F2: remember what the player can see from here. Frame-rate is the
        -- right cadence because visit() is a no-op until they cross a tile —
        -- except when the world changed shape, which forces one re-look.
        do
            local world, p = activeWorld(), activePlayer()
            if world and p and not p.dead then
                game.automap:visit(world, p.x, p.y, p.storey or 1, game.automapDirty)
                game.automapDirty = false
            end
        end

        if game.host then
            if game.host.localPlayer then game.host:setLocalInput(gatherInput()) end
            game.host:update(dt)
            game.alpha = game.host:alpha()

        elseif game.client then
            game.client:setInput(gatherInput())
            game.client:update(dt)
            game.alpha = game.client:alpha()

            -- A8: a session that ended is reported, not silently swallowed. The
            -- client's own state names which of the four ways it went, and the
            -- session keeps the first sentence — a disconnect arrives as a
            -- cascade and the last reason is always the vaguest one.
            local st = game.client.state
            if st == 'rejected' or st == 'kicked' or st == 'failed'
               or st == 'disconnected' then
                game.session:disconnected(
                    tostring(game.client.reason or 'the connection ended'), st)
                -- Session resume: keep what a reconnect needs. Only an
                -- unexpected end earns it — a kick or refusal means the host
                -- did not want this session back.
                if st == 'disconnected' and game.client.resumeToken then
                    game.lastSession = {
                        address = game.client.address,
                        resume = game.client.resumeToken,
                        name = game.client.name,
                    }
                    note('disconnected: ' .. tostring(game.session:reason())
                         .. '  —  `reconnect` to resume your session')
                else
                    game.lastSession = nil
                    note('disconnected: ' .. tostring(game.session:reason()))
                end
                game.client = nil
            end

        else
            -- The only place a pause can actually stop anything: the solo clock.
            -- A host and a client both keep stepping, which is why the session
            -- refuses to pause them in the first place. F10 photo mode freezes the
            -- same solo clock, so a still is a still — the scene holds while you
            -- fly the camera around it.
            local simDt = game.photo:pausesSim() and 0 or game.session:simDelta(dt)
            game.alpha = game.clock:advance(simDt, M.simulate)
        end
    end

    return M
end
