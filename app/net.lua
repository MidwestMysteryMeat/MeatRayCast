--[[
    app.net — the demo's networking glue: hosting, joining, and what a
    remote player's commands MEAN.

    Fourth cut of un-god-filing main.lua. The engine's net stack
    (meatray.net) moves packets and replicates entities; it has no gameplay
    verbs. This module is where the demo gives it some: hostCommand is the
    meaning of 'door'/'fire'/'swap' from a peer, startHost wires the host's
    step to the demo's rules, startClient wires the client's events to the
    demo's feedback (decals, flashes, killfeed, vote toasts).

    Everything in ctx is assigned before this module is built — the whole
    demo's function set exists by the networking section — so the ctx
    carries values. main.lua binds the returned starters onto its
    forward-declared locals, which the menu's closures already watch.
]]

return function(ctx)
    local game, Game, MeatRay = ctx.game, ctx.Game, ctx.MeatRay
    local Net, Rep, Inventory = ctx.Net, ctx.Rep, ctx.Inventory
    local note = ctx.note
    local NET_DOOR_REACH = ctx.NET_DOOR_REACH
    local doorInFront, resolveFire = ctx.doorInFront, ctx.resolveFire
    local describeShot, applyShotDecals = ctx.describeShot, ctx.applyShotDecals
    local pushFlash, normalizeAngle = ctx.pushFlash, ctx.normalizeAngle
    local updateCreatures, stepRules = ctx.updateCreatures, ctx.stepRules
    local stepRespawn = ctx.stepRespawn
    local reloadMap, loadAuthored = ctx.reloadMap, ctx.loadAuthored
    local loadProcedural, hostAdoptWorld = ctx.loadProcedural, ctx.hostAdoptWorld
    local setTheme, adoptWorldForAutomap = ctx.setTheme, ctx.adoptWorldForAutomap

    local M = {}

    -- What a client action means. The engine has no built-in gameplay verbs, so this
    -- is where the demo's rules live for every remote player.
    function M.hostCommand(host, peer, name, body)
        local e = peer.entity
        if not e then return false end
        body = body or {}

        if name == 'door' then
            local tx, ty = tonumber(body.tx), tonumber(body.ty)
            if tx and ty then
                local door = host.world:doorAt(tx, ty)
                local dx, dy = (tx - 0.5) - e.x, (ty - 0.5) - e.y
                if door and (dx * dx + dy * dy) <= NET_DOOR_REACH * NET_DOOR_REACH then
                    -- Lock-aware: a locked door refuses unless this peer's entity
                    -- holds the key. The refusal is simply "nothing happened".
                    local opened = Game.secrets.tryDoor(host.world, e, tx, ty)
                    if not opened then return false end
                    host:syncWorld()
                    -- Gas listens to world:watchShape by default, so the door toggle
                    -- wakes the field without a second call. See meatray/game/gas.lua.
                    host:event('door', { tx = tx, ty = ty, open = door.open and 1 or 0,
                                         by = peer.peerId })
                    return true
                end
                return false
            end

            local atx, aty = doorInFront(host.world, e)
            if atx then
                local opened = Game.secrets.tryDoor(host.world, e, atx, aty)
                if not opened then return false end
                host:syncWorld()
                host:event('door', { tx = atx, ty = aty, by = peer.peerId,
                                     open = host.world:doorAt(atx, aty).open and 1 or 0 })
                return true
            end
            return false

        elseif name == 'fire' then
            -- The client's aim is an input and is trusted; the shot itself is not.
            --
            -- Rep.finite rather than tonumber, and the difference is not cosmetic:
            -- tonumber(NaN) is a number and `if tonumber(x) then` is therefore true
            -- for it, so the obvious spelling accepts a NaN angle, which produces a
            -- NaN position on the next step and rides out in every snapshot to every
            -- player. The engine validates INPUT itself; a command body is the game's,
            -- so the game checks it.
            local aim = Rep.finite(body.angle, -Rep.MAX_ANGLE, Rep.MAX_ANGLE)
            -- The fire RATE is not the client's to decide. resolveFire reads a
            -- cooldown that only the fixed tick writes, so a peer sending FIRE at
            -- five hundred a second gets one shot per fire interval and several
            -- hundred refusals — see meatray/game/weapons.lua.
            -- Opening fire forfeits spawn protection before the shot resolves.
            Game.respawn.dropProtection(e)
            host:event('hitscan', resolveFire(host.world, host.entities, e, aim))
            return true

        elseif name == 'swap' then
            local wanted = (body.weapon == 'launcher') and 'launcher' or 'pistol'
            return Inventory.equipWeapon(e, wanted) ~= nil
        end

        return false
    end

    function M.startHost(opts)
        local host, err = Net.host{
            mode      = opts.mode,
            name      = opts.name,
            map       = game.source == 'authored' and (opts.map or 'arena') or 'procedural',
            port      = opts.port,
            password  = opts.password,
            discovery = opts.discovery,
            registries = opts.registries,
            world     = game.world,
            entities  = game.entities,
            worldSpec = game.worldSpec,
            movers    = game.movers,   -- C18: replicate authored lifts to clients
            localPlayer = game.player or false,
            onStep = function(dt, h)
                updateCreatures(dt, h.world, h.entities, h.localPlayer or h.entities[1])
                stepRules(dt, h.world, h.entities)
                stepRespawn(dt)
            end,
            onCommand  = M.hostCommand,
            -- G3: the ledger and the rebuild are the host's (net layer); the
            -- shield is the game's. Same split as everywhere else.
            onPeerRespawn = function(_, peer)
                Game.respawn.protect(peer.entity, 2)
                note(('%s is back in'):format(peer.name))
            end,
            onPeerJoin = function(_, peer) note(('%s joined'):format(peer.name)) end,
            onPeerLeave = function(_, peer) note(('%s left'):format(peer.name)) end,
            onChat = function(_, peer, text) note(('<%s> %s'):format(peer.name, text)) end,
        }

        if not host then
            note('could not host: ' .. tostring(err))
            if not MeatRay.canRender() then love.event.quit(1) end
            return nil
        end

        game.host = host
        game.clock = host.clock
        -- Hosting drops any pause the solo session was holding: see
        -- meatray/game/session.lua, a frozen clock with players connected is a
        -- server that stopped answering.
        game.session:restart('host')

        -- A push-wall's slide rewrites grid tiles outside any command handler, so
        -- nothing else would think to sync. syncWorld is delta-based; each step is
        -- two tiles on the wire.
        host.world:watchShape(function(_, _, _, kind)
            if kind == 'pushwall' then host:syncWorld() end
        end)

        -- D33: RCON is on only when a password is set, and it comes from the
        -- environment rather than a flag so it never lands in a shell history or a
        -- process list. `map` reloads the level the same way the console's map does.
        local rconSecret = os.getenv('MEATRAY_RCON_SECRET')
        if rconSecret and rconSecret ~= '' then
            host:attachRcon{
                secret = rconSecret,
                onMap = function(name) reloadMap(name) end,
            }
            note('RCON enabled')
        end

        -- F7: voting is on for any hosted game. A passed map/restart reloads the
        -- world; a passed kick the host handles itself. Vote state is announced to
        -- everyone through the message centerprint (see the client onVote below
        -- and the host's own broadcast).
        host:attachVote{
            duration = 30, threshold = 0.5,
            onMap = function(name) reloadMap(name) end,
            onRestart = function()
                if game.source == 'authored' and game.mapPath then
                    loadAuthored(game.mapPath)
                else
                    loadProcedural()
                end
                hostAdoptWorld(game.mapPath or 'procedural')
            end,
        }

        return host
    end

    function M.startClient(address, opts)
        local client, err = Net.join(address, {
            name     = opts.name,
            password = opts.password,
            -- Present only when --registry was given. With it, the join asks that
            -- registry to introduce us and connects in the same moment; without it,
            -- the join is what it always was.
            registries = opts.registries,
            onJoin = function(c)
                setTheme(c.world.theme)
                note(('joined %s'):format(tostring(c.server.name)))
            end,
            -- B14: the host swapped maps. The client already rebuilt c.world; the
            -- demo re-themes and clears its automap fog for the new level so it does
            -- not draw the old map's remembered geometry over the new one.
            onMapChange = function(c)
                setTheme(c.world.theme)
                adoptWorldForAutomap(c.world)
                note(('map changed to %s'):format(tostring(c.server.map)))
            end,
            onEvent = function(c, name, body)
                if name == 'hitscan' then
                    note(describeShot(body))
                    applyShotDecals(body)
                    -- The kick belongs to whoever owns the aim, and that is the
                    -- client that fired. Applying it here rather than on the host is
                    -- what makes recoil work over the network at all.
                    if body.kick and c.player and body.shooter == c.player.id then
                        game.aim = normalizeAngle(game.aim + body.kick)
                    end
                    if body.result == 'hit' and c.player
                       and body.shooter == c.player.id then
                        game.hud:hitConfirmed()
                    end
                    -- F6: the host authored the kill; every client's feed shows it.
                    if body.killed then
                        game.messages:kill(tostring(body.shooter or 'someone'),
                                           tostring(body.targetKind or 'enemy'),
                                           tostring(body.weapon or nil))
                    end
                elseif name == 'boom' then
                    note(('explosion at %.1f,%.1f caught %d'):format(
                         body.x or 0, body.y or 0, body.hits or 0))
                    pushFlash{ x = body.x, y = body.y,
                               radius = (body.radius or 4) * 1.75, intensity = 2.4,
                               color = { 1.00, 0.74, 0.36 } }
                    if game.decals and body.x and body.y then
                        game.decals:add{
                            x = body.x, y = body.y, z = 0.02,
                            kind = 'scorch', life = 18, scale = 0.55,
                        }
                    end
                    -- C27: the client makes the same debris/smoke the host does.
                    if game.particles and body.x and body.y then
                        game.particles:burst('debris', body.x, body.y, { z = 0.4, scale = 1.5 })
                        game.particles:burst('smoke', body.x, body.y, { z = 0.6, scale = 1.5 })
                    end
                    -- The one thing the hp delta cannot tell the HUD is direction.
                    if c.player and body.x and body.y then
                        game.hud:damageFrom(body.x, body.y,
                                            c.player.x, c.player.y, c.player.angle)
                        game.lastHurtX, game.lastHurtY = body.x, body.y   -- D35
                    end
                elseif name == 'door' then
                    note(('door at %d,%d %s'):format(body.tx or 0, body.ty or 0,
                         (body.open == 1) and 'opened' or 'closed'))
                end
            end,
            onChat = function(_, from, text) note(('<%s> %s'):format(tostring(from), text)) end,
            onReject = function(_, reason) note('refused: ' .. tostring(reason)) end,
            onRespawn = function() note('back in — shielded for a moment') end,
            -- F7: surface the vote a client sees. A live tally is a centerprint
            -- (F1 vote / say vote yes); a result is a ticker line.
            onVote = function(_, body)
                if body.state then
                    local s = body.state
                    game.messages:centerprint(
                        ('VOTE: %s   %d/%d yes   [vote yes/no]'):format(
                            s.kind, s.yes, s.need),
                        { hold = 2, priority = 4 })
                elseif body.result then
                    game.messages:notify(('vote %s: %s'):format(body.result,
                        tostring(body.kind)))
                end
            end,
        })

        if not client then
            note('could not join: ' .. tostring(err))
            return nil
        end

        game.client = client
        game.session:restart('client')
        return client
    end

    return M
end
