--[[
    app.boot — love.load: from a command line to a running game.

    Fourteenth cut of un-god-filing main.lua, and the sequence IS the
    contract: parse args -> capture the cursor (not for test runs) -> rules
    before archetypes (the player archetype equips out of a bag that must
    exist) -> packs before any map loads -> project mount (flag first, then
    the fused build's own project/) -> renderer + sprites -> the console ->
    options applied before the first frame -> the early-exit subprograms
    (each owns the process from there) -> the boot world -> host/join ->
    and the title shell only when no argument already said what to do.
]]

return function(ctx)
    local game, Game, MeatRay = ctx.game, ctx.Game, ctx.MeatRay
    local Args, args = ctx.Args, ctx.args
    local Options, Storage, Tick = ctx.Options, ctx.Storage, ctx.Tick
    local Inventory = ctx.Inventory
    local note, setMouseLook = ctx.note, ctx.setMouseLook
    local defineGameplay, defineArchetypes = ctx.defineGameplay, ctx.defineArchetypes
    local defineSprites = ctx.defineSprites
    local scanPacks, mountProject = ctx.scanPacks, ctx.mountProject
    local activePlayer, activeWorld = ctx.activePlayer, ctx.activeWorld
    local loadProcedural, loadAuthored = ctx.loadProcedural, ctx.loadAuthored
    local hostAdoptWorld, reloadMap = ctx.hostAdoptWorld, ctx.reloadMap
    local spawnBot, spawnNeurobot = ctx.spawnBot, ctx.spawnNeurobot
    local spawnCrowdAgent = ctx.spawnCrowdAgent
    local applyTemplate, startCampaign = ctx.applyTemplate, ctx.startCampaign
    local startMeatGraphMode = ctx.startMeatGraphMode
    local startHost, startClient = ctx.startHost, ctx.startClient
    local shellOpen = ctx.shellOpen

    return function(argv)
        Args.parse(args, argv)

        -- Line-buffer whenever the run exists to be inspected: headless always,
        -- and shot runs too — a screenshot run that gets killed with its error
        -- still sitting in a full block buffer is undebuggable from outside.
        if not MeatRay.canRender() or args.editorShot then io.stdout:setvbuf('line') end
        if args.log then Args.teeOutput(args.log) end

        if MeatRay.canRender() then
            love.graphics.setDefaultFilter('nearest', 'nearest')
            -- Capture the cursor for mouselook, but not for the runs that are about
            -- to assert and exit: grabbing the pointer out from under someone during
            -- a test is rude and pointless.
            if not (args.selftest or args.nettest or args.browse) then
                setMouseLook(true)
            end
        end

        -- Rules before archetypes: the player archetype equips a weapon out of a
        -- bag, and both the weapon and the items have to exist first.
        defineGameplay()
        defineArchetypes()
        -- The synth soundscape. Declares are headless-safe; a dedicated server
        -- declares them and never renders one.
        ctx.defineSounds()

        -- B13: mount any asset packs before the first map loads, so a pack-provided
        -- map is resolvable from the start (menu, args, or the map command).
        scanPacks()

        -- H1: a project is a game folder outside this repo, mounted through the
        -- same registry packs use. The flag wins; failing that, a packaged game
        -- carries its project at 'project/' inside the fuse and finds it there.
        if args.project then
            mountProject(args.project)
        elseif love.filesystem.getInfo('project/' .. Game.project.MANIFEST) then
            mountProject('project')
        end

        if MeatRay.canRender() then
            MeatRay.raycaster.init{}
            defineSprites()
        end

        -- F3: the console. Construction and every command live in app/console.lua;
        -- the ctx hands it the demo's own functions, all of which exist by now.
        require('app.console'){
            game = game, Game = Game, MeatRay = MeatRay, Inventory = Inventory,
            activePlayer = activePlayer, activeWorld = activeWorld,
            loadProcedural = loadProcedural, loadAuthored = loadAuthored,
            hostAdoptWorld = hostAdoptWorld, mountProject = mountProject,
            spawnBot = spawnBot, spawnNeurobot = spawnNeurobot,
            spawnCrowdAgent = spawnCrowdAgent,
            applyTemplate = applyTemplate, startCampaign = startCampaign,
        }

        -- A7: settings are read before the first frame and applied to the
        -- renderer, so the window opens at the FOV and quality the player last
        -- chose rather than at the defaults with a correction one frame later. A
        -- missing file is the normal first-run case, not an error.
        game.options = Options.new()
        game.storage = Storage.detect()
        local loadedOpts = game.options:load(game.storage)
        game.options:applyGraphics()
        game.options:applyAudio()
        game.a11y:load(game.storage)          -- F8: accessibility, if saved
        game.progression = Game.progression.new()   -- C23: meta progression
        game.progression:load(game.storage)          -- picks up defaults on first run
        game.footsteps = Game.footsteps.new{ stride = 1.7, default = 'stone' }  -- C30
        game.sensitivity = game.options:getMouse().sensitivity or game.sensitivity
        if loadedOpts then
            local g = game.options:getGraphics()
            note(('options: %s quality, %d° fov, %d%% scale')
                 :format(g.quality, g.fov, math.floor(g.scale * 100 + 0.5)))
        end

        game.clock = Tick.new(60)

        -------------------------------------------------------------------
        -- Neither a LAN browser nor a connectivity check needs a world.
        if args.netcheck then
            return require('netcheck')(args)
        end

        -- The relay is not a game at all: no world, no archetypes, no simulation. It
        -- forwards datagrams between two other processes and counts them.
        if args.netproxy then
            return require('netproxy')(args)
        end

        -- Joins one server through a registry and reports what the punch actually
        -- did. No world, no simulation: it exists to answer whether the
        -- introduction round trip happened and how long it took.
        if args.punchcheck then
            return require('punchcheck')(args)
        end

        if args.browse then
            return require('browse')(args)
        end

        -- The editor installs its own callbacks and owns the frame from here, so it
        -- returns rather than falling through into the game's world setup.
        if args.editor then
            return require('editor')(args)
        end

        if args.bench then
            return require('bench')(args)
        end

        -------------------------------------------------------------------
        -- A client is given its world by the host, so it must not build one.
        local joining = args.connect ~= nil or args.nettest
        game.wantPlayer = not joining and args.mode ~= 'dedicated'

        if not joining then
            -- --map wins; then a mounted project's start map; then the demo's
            -- procedural world. reloadMap resolves pack/project ids first, so
            -- `--map arena` still finds maps/arena.map and a project id finds its
            -- own file.
            local startId = args.map or (game.project and game.project:startMapId())
            if startId then reloadMap(startId) else loadProcedural() end
            if args.meatgraph then startMeatGraphMode(args.meatgraph) end
        end

        -------------------------------------------------------------------
        if args.selftest then
            -- Both the require and the call go inside pcall. Writing
            -- `pcall(require('selftest'))` would run require outside the protected
            -- call, so a syntax error in the test file would crash the game instead
            -- of being reported as a test failure.
            local loaded, chunk = pcall(require, 'selftest')
            if not loaded then
                print('SELFTEST FAILED to load: ' .. tostring(chunk))
                love.event.quit(1)
                return
            end

            local ok, err = pcall(chunk)
            if not ok then
                print('SELFTEST FAILED: ' .. tostring(err))
                love.event.quit(1)
            else
                love.event.quit(0)
            end
            return
        end

        -------------------------------------------------------------------
        if args.nettest then
            local loaded, chunk = pcall(require, 'nettest')
            if not loaded then
                print('NETTEST FAILED to load: ' .. tostring(chunk))
                love.event.quit(1)
                return
            end

            local ok, err = pcall(chunk, args)
            if not ok then
                print('NETTEST FAILED: ' .. tostring(err))
                love.event.quit(1)
            else
                love.event.quit(0)
            end
            return
        end

        -------------------------------------------------------------------
        if args.netfrag then
            local loaded, chunk = pcall(require, 'netfrag')
            if not loaded then
                print('NETFRAG FAILED to load: ' .. tostring(chunk))
                love.event.quit(1)
                return
            end

            local ok, err = pcall(chunk.run, args)
            if not ok then
                print('NETFRAG FAILED: ' .. tostring(err))
                love.event.quit(1)
            end
            return
        end

        -------------------------------------------------------------------
        -- Filler entities, for the snapshot measurement only. They are ordinary
        -- replicated entities with known transforms, which is what gives the probe on
        -- the other end something whose exact value it can check the wire against —
        -- and enough of them push a snapshot past one MTU on purpose.
        if args.fillers and args.fillers > 0 and args.mode then
            local n = require('netfrag').spawnFillers(game.entities, args.fillers)
            note(('%d filler entities added, %d in the world'):format(n, #game.entities))
        end

        if args.mode then
            local discovery = args.discovery
            if args.registries then
                -- Both, not either. A registry lets players anywhere find the host;
                -- the LAN beacon keeps working with the internet unplugged, and one
                -- must never cost the other.
                discovery = {}
                if args.discovery then discovery[#discovery + 1] = args.discovery end
                discovery[#discovery + 1] = 'master'
            end

            startHost{
                mode = args.mode, port = args.port, name = args.name, map = args.map,
                password = args.password, discovery = discovery,
                registries = args.registries,
            }
        elseif args.connect then
            startClient(args.connect, { name = args.name, password = args.password,
                                        registries = args.registries })
        end

        -- G1: a plain double-click boots into the title screen over the freshly
        -- generated world. Every argument that already says what to do — a map,
        -- a graph, hosting, joining, any test mode — skips it: arguments are
        -- intent, and a menu in front of stated intent is a door in a hallway.
        if MeatRay.canRender() and not (args.map or args.meatgraph or args.mode
           or args.connect or args.browse) then
            shellOpen()
        end
    end
end
