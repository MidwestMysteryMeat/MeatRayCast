--[[
    app.demo — the demo recorder/player's glue into the running game (F1).

    Ninth cut of un-god-filing main.lua. The FORMAT lives in
    meatray.sim.demo; this is what the demo means to THIS game: which
    actions ride the event stream, how a recorded action replays through
    the same code paths the live keys use, and how both ends rebuild the
    level from nothing so tick zero agrees. simulate() stays in main.lua —
    it is the loop being recorded, not the recording machinery.
]]

return function(ctx)
    local game, Game, MeatRay = ctx.game, ctx.Game, ctx.MeatRay
    local Entity, Inventory = ctx.Entity, ctx.Inventory
    local note, resolveFire = ctx.note, ctx.resolveFire
    local loadAuthored, loadProcedural = ctx.loadAuthored, ctx.loadProcedural

    local M = {}

    -- A player action outside the movement stream, noted while recording. The
    -- queue flushes into the recorder on the next simulate tick — the same tick
    -- boundary playback applies it at, and nothing mutates the world between
    -- ticks, so the two runs see identical state.
    function M.demoEvent(name, params)
        if not game.demoRec then return end
        game.demoEvents[#game.demoEvents + 1] = { name = name, params = params }
    end

    -- Replays one recorded action through the same code paths the live keys use.
    function M.applyDemoEvent(ev)
        local world, player = game.world, game.player
        if not world or not player then return end
        if ev.name == 'fire' then
            -- The same two steps the live click takes, in the same order — a
            -- replayed shot that kept its spawn shield would diverge right here.
            Game.respawn.dropProtection(player)
            resolveFire(world, game.entities, player, ev.angle or player.angle)
        elseif ev.name == 'door' then
            Game.secrets.tryDoor(world, player, ev.tx, ev.ty)
            if game.lighting and game.lightingWorld == world then
                game.lighting:invalidateTile(ev.tx, ev.ty)
            end
        elseif ev.name == 'push' then
            world:pushWall(ev.tx, ev.ty)
        elseif ev.name == 'swap' then
            Inventory.equipWeapon(player, ev.weapon)
        end
    end

    local DEMO_FILE = 'last.demo'

    -- Both ends of a demo rebuild the level from nothing — same seed, same map,
    -- and the entity id counter back to 1, because ids are part of the checksum
    -- and a counter that kept counting would make every replay 'diverge' at tick
    -- zero for no interesting reason.
    function M.reloadForDemo()
        Entity.resetIds(1)
        -- The respawn ledger is part of the run: a death carried over from before
        -- the demo began would come due mid-replay and spawn a player the
        -- recording never had.
        game.respawn:reset()
        if game.source == 'authored' and game.mapPath then
            loadAuthored(game.mapPath)
        else
            loadProcedural()
        end
    end

    function M.startDemoRecord()
        if game.host or game.client then
            return note('demos record the solo loop — leave the session first')
        end
        M.reloadForDemo()
        game.demoRec = MeatRay.demo.record{
            rate = 60,
            source = game.source,
            seed = game.source ~= 'authored' and game.seed or nil,
            map = game.mapPath,
        }
        game.demoTick = 0
        game.demoEvents = {}
        note('recording — F6 to stop and save')
    end

    function M.stopDemoRecord()
        local text = game.demoRec:finish(game.demoTick - 1)
        game.demoRec = nil
        local ok, err = game.storage.write(DEMO_FILE, text)
        if ok then
            note(('demo saved: %s (%d ticks)'):format(DEMO_FILE, game.demoTick))
        else
            note('demo save failed: ' .. tostring(err))
        end
    end

    function M.startDemoPlayback()
        if game.host or game.client then
            return note('demos replay the solo loop — leave the session first')
        end
        local text = game.storage.read(DEMO_FILE)
        if not text then return note('no recorded demo (F6 records one)') end
        local play, err = MeatRay.demo.load(text)
        if not play then return note('demo unreadable: ' .. tostring(err)) end

        if play.header.source == 'authored' and play.header.map then
            game.source = 'authored'
            game.mapPath = play.header.map
        else
            game.source = 'procedural'
            game.seed = play.header.seed or game.seed
        end
        M.reloadForDemo()
        game.demoPlay = play
        game.demoTick = 0
        game.demoDiverged = nil
        note(('playing %d ticks — F7 to stop'):format(play:length()))
    end

    return M
end
