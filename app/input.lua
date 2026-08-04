--[[
    app.input — every key, click and mouse delta, and what each one means.

    Twelfth cut of un-god-filing main.lua. The layering inside keypressed is
    the design: console first (it owns the keyboard while down), then the
    shell, then the photo free-cam, and only then the game keys — each layer
    swallowing what it handles so a key cannot act twice. The helpers the
    frame loop polls (updateAim, updatePhotoCam, gatherInput) live here too,
    beside the events they complete.

    The menu and demo actions (shellOpen/Apply/Close, confirmIntermission,
    the demo record/playback starters) are constructed AFTER this module, so
    they arrive as late-binding ctx closures — the same trick the menu uses
    for the network starters. Everything else is a value.
]]

return function(ctx)
    local game, Game, MeatRay = ctx.game, ctx.Game, ctx.MeatRay
    local Collide, Inventory, Weapons = ctx.Collide, ctx.Inventory, ctx.Weapons
    local note, args = ctx.note, ctx.args
    local activeWorld, activeEntities = ctx.activeWorld, ctx.activeEntities
    local activePlayer = ctx.activePlayer
    local doorInFront, resolveFire = ctx.doorInFront, ctx.resolveFire
    local describeShot = ctx.describeShot
    local reloadMap, loadProcedural = ctx.reloadMap, ctx.loadProcedural
    local loadAuthored, resolveMapPath = ctx.loadAuthored, ctx.resolveMapPath
    -- Late-binding closures (constructed after this module):
    local demoEvent, startDemoRecord = ctx.demoEvent, ctx.startDemoRecord
    local stopDemoRecord, startDemoPlayback = ctx.stopDemoRecord, ctx.startDemoPlayback
    local shellOpen, shellClose, shellApply = ctx.shellOpen, ctx.shellClose, ctx.shellApply
    local confirmIntermission = ctx.confirmIntermission

    local M = {}

    -- Keeps an angle in [0, 2pi). Aim accumulates every frame the mouse moves, so
    -- without this it grows without bound: spin for a few minutes and it is a large
    -- float losing precision in its low bits, and it is a large number to put on the
    -- wire every input tick for no reason.
    function M.normalizeAngle(a)
        return MeatRay.billboard.normalize(a)
    end
    local normalizeAngle = M.normalizeAngle

    -- Aim is sampled per frame, not per tick, because it is input rather than
    -- simulation: the mouse moved when it moved.
    function M.updateAim(dt)
        -- Crawler movement snap-turns in 90-degree steps on keypress, so the
        -- continuous Q/E turn is off in grid mode (see M.keypressed).
        if game.gridMove then return end
        local turn = 0
        if love.keyboard.isDown('q', 'left') then turn = turn - 1 end
        if love.keyboard.isDown('e', 'right') then turn = turn + 1 end
        if turn ~= 0 then
            game.aim = normalizeAngle(game.aim + turn * game.turnSpeed * dt)
        end
    end

    -- F10: fly the photo camera from held keys. Movement only — mouse aim comes
    -- through M.mousemoved and the toggles through M.keypressed. WASD/arrows
    -- fly, space/ctrl rise and fall, shift is the fast modifier.
    function M.updatePhotoCam(dt)
        local fwd, strafe, rise = 0, 0, 0
        if love.keyboard.isDown('w', 'up') then fwd = fwd + 1 end
        if love.keyboard.isDown('s', 'down') then fwd = fwd - 1 end
        if love.keyboard.isDown('d') then strafe = strafe + 1 end
        if love.keyboard.isDown('a') then strafe = strafe - 1 end
        if love.keyboard.isDown('space') then rise = rise + 1 end
        if love.keyboard.isDown('lctrl', 'rctrl', 'c') then rise = rise - 1 end
        local fast = love.keyboard.isDown('lshift', 'rshift')
        game.photo:pan(dt, fwd, strafe, rise, { fast = fast })
        -- Keyboard look for anyone without a captured mouse (Q/E yaw, R/F pitch).
        local dyaw, dpitch = 0, 0
        if love.keyboard.isDown('q') then dyaw = dyaw - 1 end
        if love.keyboard.isDown('e') then dyaw = dyaw + 1 end
        if love.keyboard.isDown('r') then dpitch = dpitch + 1 end
        if love.keyboard.isDown('f') then dpitch = dpitch - 1 end
        if dyaw ~= 0 or dpitch ~= 0 then
            game.photo:look(dyaw * game.photo.lookSpeed * dt,
                            dpitch * game.photo.lookSpeed * dt)
        end
    end

    -- Snap an angle to the nearest quarter turn — the crawler's cardinal facing.
    function M.snapQuarter(a)
        local q = math.pi / 2
        return normalizeAngle(math.floor(a / q + 0.5) * q)
    end

    -- Captures or releases the cursor. Captured is the playing state; released is
    -- needed for anything with a pointer (the editor later) and for getting out of a
    -- windowed game without quitting it.
    function M.setMouseLook(on)
        if not MeatRay.canRender() or not love.mouse then return end
        game.mouseLook = on and true or false
        love.mouse.setRelativeMode(game.mouseLook)
        love.mouse.setVisible(not game.mouseLook)
    end

    function M.gatherInput()
        local forward, strafe = 0, 0
        -- A visual-novel template has no movement: the story moves, the player
        -- does not. Every other genre walks.
        if not (game.template and game.template.movement == 'static') then
            if love.keyboard.isDown('w', 'up') then forward = forward + 1 end
            if love.keyboard.isDown('s', 'down') then forward = forward - 1 end
            if love.keyboard.isDown('a') then strafe = strafe - 1 end
            if love.keyboard.isDown('d') then strafe = strafe + 1 end
        end
        return { forward = forward, strafe = strafe, angle = game.aim }
    end

    -- In-world layered storeys first, then multi-map links. See docs/STOREYS.md.
    function M.tryStoreyLink()
        local world, player = activeWorld(), activePlayer()
        if not world or not player then return false end
        local storey = player.storey or 1
        local tx = math.floor(player.x) + 1
        local ty = math.floor(player.y) + 1
        local tile = world:tileAt(tx, ty, storey)
        local dir
        if tile == MeatRay.world.STAIRS_UP then dir = 'up'
        elseif tile == MeatRay.world.STAIRS_DOWN then dir = 'down'
        else return false end

        -- Prefer in-world layers when present.
        local n = world.storeyCount and world:storeyCount() or 1
        if n > 1 then
            local nextS = storey + (dir == 'up' and 1 or -1)
            if nextS < 1 or nextS > n then
                note('no more storeys that way')
                return true
            end
            if not world:isWalkable(tx, ty, nextS) then
                -- Try layer spawn tile if stairs cell is solid above.
                local L = world:layer(nextS)
                if L.spawn then
                    player.x, player.y = L.spawn.x, L.spawn.y
                else
                    note('upper cell blocked')
                    return true
                end
            end
            player.storey = nextS
            Collide.ground(player, world)
            player:snapPrevious()
            game.aim = player.angle
            note(('storey %d / %d'):format(nextS, n))
            return true
        end

        if not world.links then return false end
        local link = world.links[dir]
        if not link or not link.path then
            note('stairs lead nowhere (no link ' .. dir .. ' on this map)')
            return true
        end

        local path = resolveMapPath(link.path)
        note(('taking stairs %s → %s'):format(dir, path))
        local arrival = nil
        if link.x and link.y then
            arrival = { x = link.x, y = link.y, angle = link.angle or 0 }
        end
        if game.host or game.client then
            note('multi-map storey links are single-player for now')
            return true
        end
        loadAuthored(path, { arrival = arrival })
        return true
    end

    -----------------------------------------------------------------------
    -- The LÖVE callbacks
    -----------------------------------------------------------------------

    -- Mouselook.
    --
    -- This needs relative mode, and the reason is worth writing down because the bug
    -- it causes is easy to misread as "the controls feel bad". Without it, `dx` only
    -- arrives while the cursor is inside the window: push far enough left or right and
    -- the cursor pins against the window edge, `dx` stops entirely, and turning dies.
    -- Getting back then means physically dragging the mouse all the way across the
    -- window before a single opposite delta appears. Relative mode frees the cursor
    -- from the window and delivers unbounded deltas, which is what every
    -- first-person game does.
    --
    -- No guard on the fire button either. An earlier version ignored the mouse while
    -- button 1 was held, which quietly made it impossible to turn while shooting.
    function M.mousemoved(dx, dy)
        if not game.mouseLook then return end
        -- F10: the mouse aims the free-cam while it is detached, and the player's
        -- own aim/pitch are left untouched so leaving photo mode resumes cleanly.
        if game.photo:isActive() then
            game.photo:look((dx or 0) * game.sensitivity,
                            -(dy or 0) * game.sensitivity)
            return
        end
        game.aim = normalizeAngle(game.aim + dx * game.sensitivity)
        -- Mouse up (negative dy) looks up (positive pitch). Pitch is presentation
        -- only: it never goes on the wire, so a client's look-up does not change
        -- what the host simulates about their aim for hitscan.
        if dy and dy ~= 0 then
            game.pitch = MeatRay.raycaster.clampPitch(
                game.pitch - dy * game.sensitivity)
        end
    end

    function M.mousepressed()
        -- The console owns the frame while it is down; a click through it must
        -- not fire a round or recapture the mouse. The shell is keyboard-driven,
        -- but a click through IT must not fire either.
        if game.consoleOpen then return end
        if game.shell:isOpen() then return end
        -- The tally next: fire hurries it, fire continues it, and neither press
        -- may also discharge a weapon into the next mission's first frame.
        if confirmIntermission() then return end

        -- A click with the cursor released means "I want to look again", not "fire".
        -- Firing on the same click that recaptures would make every return to the
        -- window cost a round.
        if MeatRay.canRender() and not game.mouseLook then
            M.setMouseLook(true)
            return
        end

        local player = activePlayer()
        if not player then return end
        -- A no-combat template (a visual novel) has no weapons; a click is a click,
        -- not a shot.
        if game.template and game.template.combat == 'none' then return end
        -- The dead do not fire; they wait — but a click while dead cycles the
        -- spectator to the next living player (D35).
        if player.dead then
            game.spectator:cycle(activeEntities(), 1, player)
            return
        end
        -- A replay's shots come from the recording; a live click on top of them
        -- would fork the timeline the divergence check exists to protect.
        if game.demoPlay then return end

        if game.client then
            -- The client asks; the host decides. Nothing about the shot is resolved
            -- here, which is why there is no ammo count to correct afterwards.
            game.client:command('fire', { angle = game.aim })
            return
        end

        -- Opening fire forfeits spawn protection before the shot resolves.
        Game.respawn.dropProtection(player)
        demoEvent('fire', { angle = game.aim })
        local shot = resolveFire(activeWorld(), activeEntities(), player, game.aim)
        note(describeShot(shot))
        if shot and shot.result == 'hit' then
            game.hud:hitConfirmed()
            -- F6: a kill is an obituary, not a log line. The weapon names the cause.
            if shot.killed then
                local status = Weapons.status(player)
                game.messages:kill('you', tostring(shot.targetKind or 'enemy'),
                                   status and status.id or nil)
            end
        end

        -- Recoil is reported, not applied: see meatray/game/weapons.lua. The host
        -- takes aim verbatim because aim is an input, so a kick it wrote into
        -- `e.angle` would be overwritten by the next input packet. The owner of the
        -- aim applies it, and here that is this machine.
        if shot.kick then game.aim = normalizeAngle(game.aim + shot.kick) end

        if game.host then game.host:event('hitscan', shot) end
    end

    function M.textinput(text)
        if game.consoleOpen then
            -- The toggle key must not type itself into the prompt it just opened.
            if text == '`' or text == '~' then return end
            game.consoleInput = game.consoleInput .. text
            return
        end
        -- G1: a text row (the join address) eats printable input while capturing.
        if game.shell:isOpen() and game.shell:capturing() == 'text' then
            game.shell:feedText(text)
        end
    end

    function M.keypressed(key)
        -- F3: the console owns the keyboard while it is down. Toggling it also
        -- releases the mouse, because a console you cannot click past is a trap.
        if key == '`' then
            game.consoleOpen = not game.consoleOpen
            if game.consoleOpen and MeatRay.canRender() then M.setMouseLook(false) end
            return
        end
        if game.consoleOpen then
            if key == 'return' or key == 'kpenter' then
                game.console:execute(game.consoleInput)
                game.consoleInput = ''
            elseif key == 'backspace' then
                game.consoleInput = game.consoleInput:sub(1, -2)
            elseif key == 'up' then
                game.consoleInput = game.console:historyPrev() or game.consoleInput
            elseif key == 'down' then
                game.consoleInput = game.console:historyNext() or game.consoleInput
            elseif key == 'tab' then
                local common, matches = game.console:complete(game.consoleInput)
                game.consoleInput = common
                if #matches > 1 then game.console:print(table.concat(matches, '  ')) end
            elseif key == 'escape' then
                game.consoleOpen = false
            end
            return
        end

        -- G1: the shell, after the console. While it is up it owns the keyboard;
        -- what a key MEANS is the menu model's answer, what the answer DOES is
        -- shellApply's.
        if game.shell:isOpen() then
            if game.shell:capturing() then
                shellApply(game.shell:feedKey(key))
                return
            end
            if key == 'up' then game.shell:navigate(-1)
            elseif key == 'down' then game.shell:navigate(1)
            elseif key == 'left' then shellApply(game.shell:adjust(-1))
            elseif key == 'right' then shellApply(game.shell:adjust(1))
            elseif key == 'return' or key == 'kpenter' then
                shellApply(game.shell:activate())
            elseif key == 'escape' or key == 'backspace' then
                if not game.shell:back() then shellClose() end
            end
            return
        end

        -- F10: while the free-cam is detached it owns the keyboard. Movement is
        -- polled in updatePhotoCam; here are the toggles, and every other key is
        -- swallowed so it cannot act on the frozen player behind the camera.
        if game.photo:isActive() then
            if key == 'o' or key == 'escape' then
                game.photo:exit()
                note('photo mode off')
            elseif key == 'h' then
                game.photo:toggleHud()
            elseif key == '[' then
                game.photo:adjustFov(-0.08)
            elseif key == ']' then
                game.photo:adjustFov(0.08)
            elseif key == 'pageup' then
                game.photo:setStorey(game.photo.storey + 1)
            elseif key == 'pagedown' then
                game.photo:setStorey(game.photo.storey - 1)
            end
            return
        end

        if key == 'escape' then
            -- Escape releases the cursor first — quitting on the key a player
            -- presses to get their mouse back loses sessions by reflex. With the
            -- cursor free, escape opens the shell; quitting lives on its rows.
            if game.mouseLook then
                M.setMouseLook(false)
                note('mouse released - click to look again')
                return
            end
            shellOpen()
            return
        end

        if key == 'f1' then game.showHelp = not game.showHelp end

        -- F1: F6 records, F7 replays. Both restart the level so the demo begins
        -- at a known world; both refuse in a session, where the loop isn't ours.
        if key == 'f6' then
            if game.demoRec then stopDemoRecord() else startDemoRecord() end
            return
        end
        if key == 'f7' then
            if game.demoPlay then
                game.demoPlay = nil
                note('playback stopped')
            else
                startDemoPlayback()
            end
            return
        end

        -- F10: O detaches the photo camera, seeded from the eye so it does not jump.
        if key == 'o' then
            local p = activePlayer()
            local floorZ = (p and (p.z or 0)) or 0
            game.photo:enter{
                x = p and p.x or 0, y = p and p.y or 0,
                angle = (p and p.angle) or game.aim or 0,
                storey = (p and p.storey) or 1,
                z = floorZ + MeatRay.world.EYE_HEIGHT,
                pitch = game.pitch,
            }
            note('photo mode — fly the camera; O or Esc to exit')
            return
        end

        -- A8: pause, on P alone. Escape above already means "give me my cursor
        -- back, then quit", and a key that pauses on the first press and exits on
        -- the second is how a session gets lost by reflex.
        --
        -- The key always works; whether it stops the world depends on the role,
        -- and a refusal is said out loud rather than swallowed. A session that
        -- ended takes P as "put me back in a game".
        if key == 'p' then
            if game.session:isOver() then
                game.session:restart('solo')
                local startId = args.map or (game.project and game.project:startMapId())
                if startId then reloadMap(startId) else loadProcedural() end
                note('back to a fresh game')
                return
            end
            local _, refused = game.session:toggleMenu('menu')
            -- A menu you cannot click because the cursor is captured is not a
            -- menu, so the pause hands the mouse back and taking it again is the
            -- click that resumes.
            if game.session:menuOpen() and MeatRay.canRender() then
                M.setMouseLook(false)
            end
            if refused then
                note(refused)
            else
                note(game.session:isPaused() and 'paused' or 'resumed')
            end
            return
        end

        -- A7: the graphics settings, reachable without a settings screen. Every
        -- change goes through the options model and is written to disk, so the
        -- next launch opens the way this one ended.
        if key == 'f2' or key == 'f3' or key == 'f4' then
            if key == 'f2' then
                game.options:menuNudge('graphics.quality', 1)
            else
                game.options:menuNudge('graphics.fov', key == 'f4' and 5 or -5)
            end
            game.options:applyGraphics()
            game.options:save(game.storage)
            local g = game.options:getGraphics()
            note(('graphics: %s, %d° fov, %d%% scale')
                 :format(g.quality, g.fov, math.floor(g.scale * 100 + 0.5)))
        end
        if key == 'm' then
            game.showMinimap = not game.showMinimap
            note(game.showMinimap and 'minimap on' or 'minimap off')
        end

        -- C16: the bag overlay.
        if key == 'i' then game.showBag = not game.showBag end

        -- Crawler grid movement: Q/E (and arrows) snap the facing a quarter turn.
        if game.gridMove and (key == 'q' or key == 'left') then
            game.aim = M.snapQuarter(game.aim - math.pi / 2)
        elseif game.gridMove and (key == 'e' or key == 'right') then
            game.aim = M.snapQuarter(game.aim + math.pi / 2)
        end

        -- Weapon switching goes through the BAG: `Inventory.equipWeapon` finds the
        -- item whose definition names the weapon and equips that slot, which is also
        -- what wires the new gun's reload to the right ammunition item.
        if key == '1' or key == '2' then
            local player = activePlayer()
            local wanted = (key == '2') and 'launcher' or 'pistol'
            if player then
                if game.demoPlay then return end
                if game.client then
                    game.client:command('swap', { weapon = wanted })
                elseif Inventory.equipWeapon(player, wanted) then
                    demoEvent('swap', { weapon = wanted })
                    note(wanted)
                else
                    note('no ' .. wanted .. ' in the bag')
                end
            end
        end

        -- Drop the torch. The point of the key is that the difference between
        -- carrying a light and not carrying one is visible immediately, and that
        -- neither state costs a rebake.
        if key == 'l' then
            game.torch = not game.torch
            note(game.torch and 'torch lit' or 'torch out')
        end

        if key == 'f' then
            if confirmIntermission() then return end
            local world, player = activeWorld(), activePlayer()
            if not world or not player then return end
            if game.demoPlay then return end   -- a replay's uses are its own

            if game.client then
                local tx, ty = doorInFront(world, player)
                game.client:command('door', tx and { tx = tx, ty = ty } or nil)
                if not tx then note('no door within reach') end
                return
            end

            -- Stairs (storey links) before doors: F is "use" in both cases.
            -- A link loads a different map, and a demo is one map's stream — so a
            -- recording that reaches the stairs ends there, saved, rather than
            -- carrying on into a world its header cannot rebuild.
            if M.tryStoreyLink() then
                if game.demoRec then
                    stopDemoRecord()
                    note('recording ended at the map link')
                end
                return
            end

            local tx, ty = doorInFront(world, player)
            if tx then
                demoEvent('door', { tx = tx, ty = ty })
                -- Through the lock-aware path: an unlocked door just toggles, a
                -- locked one opens only if the player holds its key.
                local opened, why, keyId = Game.secrets.tryDoor(world, player, tx, ty)
                if not opened and why == 'locked' then
                    note(('locked — you need %s'):format(tostring(keyId)))
                    return
                end
                -- The geometry changed, so the light that fell through it did too.
                -- Only the static lights that could see this tile are invalidated;
                -- the rest of the map stays baked and asleep. Gas is subscribed to
                -- the world's shape events and wakes itself.
                if game.lighting and game.lightingWorld == world then
                    game.lighting:invalidateTile(tx, ty)
                end
                note(('door at %d,%d %s'):format(tx, ty,
                     world:doorAt(tx, ty).open and 'opened' or 'closed'))
                require('meatray.asset').sound.playAt('door', tx - 0.5, ty - 0.5)
            else
                -- No door: F also shoves. A wall in reach that was declared a
                -- push-wall starts its slide here.
                local dirX = math.cos(player.angle)
                local dirY = math.sin(player.angle)
                local dist, wx, wy = Collide.rayTile(world, player.x, player.y,
                                                     dirX, dirY, game.doorReach)
                if dist and world:pushWallAt(wx, wy) then
                    demoEvent('push', { tx = wx, ty = wy })
                    local pushed = world:pushWall(wx, wy)
                    note(pushed and 'the wall gives way...'
                                or 'the wall will not move')
                    return
                end
                note('no door within reach')
            end
        end

        -- Reloading the world is a single-player convenience: doing it while hosting
        -- would leave every client holding a level that no longer exists.
        if game.host or game.client then return end

        if key == 'tab' then
            if game.source == 'procedural' then loadAuthored() else loadProcedural() end
        end

        if key == 'r' then
            game.seed = game.seed + 1
            loadProcedural()
        end

        if key == 't' then
            local names = MeatRay.themes.names()
            local current = MeatRay.raycaster.getTheme()
            local index = 1
            for i, n in ipairs(names) do if n == current then index = i end end
            local nextTheme = names[(index % #names) + 1]
            MeatRay.raycaster.setTheme(nextTheme)
            note('theme ' .. nextTheme)
        end
    end

    return M
end
