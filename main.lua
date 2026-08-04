--[[
    MeatRayCast demo.

    Deliberately written against the library API rather than the convenience
    layer, so it doubles as proof that the library path is sufficient on its own.

        love .                                  procedural world, single player
        love . --map arena                      hand-authored map from maps/arena.map
        love . --map tower                      multi-map storeys (F → other map)
        love . --map stacked                    in-world layers (F → storey 2)
        love . --meatgraph                      MeatGraphRay host graphs (MeatEngine MeatGraph kinship)
        love . --project projects/mygame        run a game project folder (H1)
        love . --editor --project projects/mygame   edit that project in place
        love . --selftest                       headless-ish gate, prints PASS and exits

        love . --host                           listen server: play and host at once
        love . --server --port 6789 --map arena  headless dedicated server
        love . --connect 127.0.0.1:6789         join a server
        love . --browse                         list LAN servers and exit
        love . --browse --filter-mode dm --hide-full --sort ping   filtered browse
        love . --netcheck                       can this machine do UDP at all?
        love . --nettest --connect host:port     headless networked assertions
        love . --server --fillers 120           host with extra replicated entities
        love . --netfrag --connect host:port     measure the snapshot stream
        love . --netproxy --port P --forward A   a UDP relay that drops datagrams

    Controls: WASD or arrows to move, mouse or Q/E to turn, F to open a door,
    left click to fire, 1 and 2 to swap between the pistol and the grenade
    launcher, TAB to switch world source, F1 for the help overlay.

    All four network modes run the *same* game rules. The door and weapon logic
    below is written once and called from three places: directly in single player,
    from the host's command handler when a client asks, and by the listen host for
    its own player. A demo that had a separate networked implementation of firing
    would be hiding exactly the bug this is meant to demonstrate the absence of.
]]

local MeatRay = require('meatray')

local Entity     = MeatRay.entity
local C          = MeatRay.components
local Collide    = MeatRay.collide
local Movers     = MeatRay.movers   -- C-map: lifts authored in a .map
local Tick       = MeatRay.tick
local Worldgen   = MeatRay.worldgen
local Map        = MeatRay.map
local AI         = MeatRay.ai
local Decals     = MeatRay.decals
local Billboard  = MeatRay.billboard
local Net        = MeatRay.net
local Rep        = Net.replication

-- The gameplay half: attributes, effects, weapons, inventory, explosions, gas.
-- All headless, so a dedicated server runs every line of it.
local Game        = MeatRay.game
local Weapons     = Game.weapons
local Inventory   = Game.inventory
local Projectiles = Game.projectiles
local Explosion   = Game.explosion
local GasSim      = Game.gas
local MeatGraphRay = Game.meatgraphRay
local Mode         = Game.mode
local Options      = Game.options
local Storage      = require('meatray.save.storage')

local game = {
    world = nil,
    entities = {},
    player = nil,
    clock = nil,
    alpha = 0,
    source = 'procedural',
    seed = 20260730,
    mode = nil,             -- optional host ruleset (often MeatGraphRay-bound)
    graph = nil,            -- loaded MeatGraphRay graph, if any
    triggers = nil,         -- meatray.sim.triggers, when a graph installs volumes
    zbuffer = nil,
    lighting = nil,         -- meatray.render.lighting grid for the active world
    lightingWorld = nil,    -- the world it was baked against
    torch = true,           -- does the player carry a light?
    showMinimap = true,     -- top-down plan overlay (M toggles)
    minimap = nil,
    fire = nil,             -- meatray.game.gas field for the active world
    fireWorld = nil,        -- the world it belongs to
    flashes = {},           -- short-lived explosion lights, presentation only
    particles = MeatRay.canRender() and MeatRay.particles.new{ max = 500 } or nil,  -- C27
    hud = Game.hud.new(),   -- damage flash, bars, hit marker: model in meatray.game.hud
    respawn = Game.respawn.new{ delay = 3, protection = 2 },  -- A5, host authority
    -- A8: running / paused / over, and who is allowed to decide. Starts solo;
    -- startHost and startClient move the role.
    session = Game.session.new{ role = 'solo' },
    -- F1: demo recording and playback (meatray.sim.demo). Solo only — the
    -- demo records the authoritative loop, and a client does not have one.
    demoRec = nil,          -- active recorder
    demoPlay = nil,         -- active playback
    demoTick = 0,           -- tick counter since record/playback began
    demoEvents = {},        -- events queued between ticks while recording
    demoDiverged = nil,     -- first tick playback disagreed, reported once
    -- F2: what the player has seen of the plan. Reset with every world; the
    -- minimap draws only these tiles.
    automap = Game.automap.new{ radius = 5 },
    automapDirty = false,   -- a door/push/collapse happened: re-look
    -- F3: the dev console. Built in love.load (it registers commands over
    -- systems that exist by then); ` toggles the overlay.
    console = nil,
    consoleOpen = false,
    consoleInput = '',
    noclip = false,         -- written only by the noclip cvar's onChange
    -- F4: the campaign (started from the console) and the tally between its
    -- missions. `intermission` is the screen model; campaignTriggers is the
    -- exit volume box for the current mission.
    campaign = nil,
    intermission = Game.intermission.new(),
    campaignTriggers = nil,
    campaignKillTotal = nil,
    campaignDone = false,
    -- G1: the shell. A stack of screens over the models that have waited for
    -- one since A3. Opening it pauses a solo game through the session's own
    -- policy; online it floats over a world that keeps running.
    shell = Game.menu.new(),
    -- F6: engine-owned player messaging — centerprint, pickup ticker,
    -- killfeed. Replaces ad-hoc feedback for the moments that deserve more
    -- than a log line.
    messages = Game.messages.new(),
    projectTicks = {},      -- H5: per-step hooks a project's game.lua registered
    screenfx = Game.screenfx.new(),  -- C28: layered full-screen tints
    spectator = Game.spectator.new{ killcamTime = 2.5 },  -- D35
    photo = Game.photo.new{ moveSpeed = 4, lookSpeed = 1.5 },  -- F10: free-cam
    rail = nil,             -- C20: the playing cutscene camera rail, if any
    a11y = Game.a11y.new(),  -- F8: accessibility settings (loaded at boot)
    lastHurtX = nil, lastHurtY = nil,  -- D35: where the last damage came from
    showBag = false,        -- C16: the inventory grid overlay (I toggles)
    bots = {},              -- C22: { { entity, brain } } computer players
    decals = Decals.new{ max = 192, defaultLife = 14 },
    log = {},
    showHelp = true,
    turnSpeed = 2.6,
    moveSpeed = 3.2,
    template = nil,         -- the active genre template config, or nil (default FPS)
    gridMove = false,       -- crawler movement: step tiles, turn in quarters
    aim = 0,
    pitch = 0,              -- look up/down, radians; local only, not on the wire
    sensitivity = 0.0028,   -- radians per pixel of mouse movement
    mouseLook = false,      -- is the cursor captured for looking?
    doorReach = 2,
    wantPlayer = true,
    host = nil,
    client = nil,
}


-- Demo policy, not an engine rule. When a client names the door it means, the
-- host still range-checks it — but generously, so the two-process network test
-- does not depend on where the level happens to have put a door. A shipping game
-- would use the aim ray below and a reach of a tile or two.
local NET_DOOR_REACH = 16

---------------------------------------------------------------------------
-- Archetypes. Behaviour composes; nothing inherits.
---------------------------------------------------------------------------

-- A client's copies of entities are not authoritative: nothing on a client may
-- move an attribute, and `Effects.apply` refuses on a container that says so.
-- The archetype asks at build time rather than being told, because entities are
-- adopted from snapshots long after the archetypes were declared.
local function isAuthority()
    return _G.MEATRAY_DEMO == nil or _G.MEATRAY_DEMO.client == nil
end

-- The stock content — effects, weapons, items, archetypes, placeholder
-- sprites — lives in app/content.lua. Bound to the old local names so the
-- boot and hot-reload call sites read unchanged.
local content = require('app.content'){
    Game = Game, MeatRay = MeatRay, Entity = Entity, C = C, AI = AI,
    Weapons = Weapons, Explosion = Explosion, Inventory = Inventory,
    isAuthority = isAuthority,
}
local defineGameplay = content.gameplay
local defineArchetypes = content.archetypes
local defineSprites = content.sprites

---------------------------------------------------------------------------
-- Logging
---------------------------------------------------------------------------

local function note(text)
    table.insert(game.log, 1, text)
    while #game.log > 6 do table.remove(game.log) end
    if not MeatRay.canRender() then print(text) end
end

---------------------------------------------------------------------------
-- Game rules, written once and shared by every mode. The combat half —
-- resolveFire and the shot presentation around it — lives in app/combat.lua,
-- bound to the old local names so every call site reads unchanged.
---------------------------------------------------------------------------

local combat = require('app.combat'){
    game = game, Game = Game, MeatRay = MeatRay,
    Collide = Collide, Billboard = Billboard, Decals = Decals,
    GasSim = GasSim, Weapons = Weapons, AI = AI,
}
local doorInFront = combat.doorInFront
local fireFor = combat.fireFor
local pushFlash = combat.pushFlash
local applyShotDecals = combat.applyShotDecals
local resolveFire = combat.resolveFire
local drawDecals = combat.drawDecals
local drawParticles = combat.drawParticles
local describeShot = combat.describeShot

-- The fixed-step rules, the genre-template switch and the bot/crowd spawners
-- live in app/rules.lua. snapQuarter is assigned in the input section below,
-- so it rides the ctx as a late-binding closure (the startHost trick).
local snapQuarter

local rules = require('app.rules'){
    game = game, Game = Game,
    Entity = Entity, Collide = Collide, AI = AI,
    Inventory = Inventory, Rep = Rep,
    Projectiles = Projectiles, GasSim = GasSim,
    note = note, resolveFire = resolveFire,
    fireFor = fireFor, pushFlash = pushFlash,
    isAuthority = isAuthority,
    snapQuarter = function(a) return snapQuarter(a) end,
}
local updateCreatures = rules.updateCreatures
local applyTemplate = rules.applyTemplate
local spawnBot = rules.spawnBot
local spawnNeurobot = rules.spawnNeurobot
local spawnCrowdAgent = rules.spawnCrowdAgent
local stepRules = rules.stepRules

-- MeatGraphRay: host-side node graphs (MeatEngine's MeatGraph, raycast side).
-- Optional: --meatgraph [path] loads meatgraphs/demo.graph.json or a custom graph.
-- Not called "blueprints" — that is Unreal's product name.
local function startMeatGraphMode(path)
    path = path or 'meatgraphs/demo.graph.json'
    local text
    if love and love.filesystem and love.filesystem.read then
        text = love.filesystem.read(path)
    end
    if not text then
        local f = io.open(path, 'rb')
        if f then text = f:read('*a'); f:close() end
    end
    if not text then
        note('MeatGraphRay graph not found: ' .. tostring(path) .. ' (using built-in example)')
        game.graph = MeatGraphRay.example()
    else
        local g, err = MeatGraphRay.load(text)
        if not g then
            note('MeatGraphRay parse failed: ' .. tostring(err))
            return
        end
        -- F9: a graph loaded from a file is untrusted content. Validate it
        -- against the sandbox and refuse a bad one, and harden the rest so
        -- every fire is bounded by a step budget — a mod graph cannot hang
        -- the host or reach anything the node vocabulary does not expose.
        local hardened, errs = MeatGraphRay.harden(g)
        if not hardened then
            note('MeatGraphRay refused (sandbox): ' .. table.concat(errs, '; '))
            return
        end
        game.graph = hardened
    end

    local mode = Mode.new{ name = game.graph.name or 'meatgraph' }
    MeatGraphRay.bindMode(mode, game.graph, {
        log = function(msg) note(tostring(msg)) end,
        Entity = Entity,
        AI = AI,
        -- true = create a Triggers set and install graph.volumes
        triggers = true,
        -- Live gas field when the demo has one (fire field doubles as seed target).
        gas = game.world and fireFor(game.world) or nil,
        onLight = pushFlash,
        spawnEntity = function(kind, x, y)
            if not Entity.hasArchetype(kind) then return nil end
            local e = Entity.spawn(kind, x, y)
            if e then
                e:snapPrevious()
                table.insert(game.entities, e)
            end
            return e
        end,
        playerCount = function()
            local n = 0
            for i = 1, #game.entities do
                local e = game.entities[i]
                if e and e:has('player') and not e.dead then n = n + 1 end
            end
            return n
        end,
        seed = game.seed,
    })
    game.mode = mode
    mode:start(game.world, game.entities)
    game.triggers = mode.data and mode.data._ngTriggers or nil
    if game.player then
        mode:playerJoin(0, game.player)
    end
    local volN = mode.data and mode.data._ngVolumeCount or 0
    note(('MeatGraphRay "%s" running (%d nodes, %d volumes)'):format(
        game.graph.name or 'unnamed', game.graph:nodeCount(), volN))
end

---------------------------------------------------------------------------
-- World loading, graph binding, packs and projects live in app/world.lua,
-- bound to the old local names so every call site reads unchanged.
---------------------------------------------------------------------------

local worldGlue = require('app.world'){
    game = game, Game = Game, MeatRay = MeatRay,
    Entity = Entity, AI = AI, Collide = Collide,
    Movers = Movers, Map = Map, Worldgen = Worldgen,
    Mode = Mode, MeatGraphRay = MeatGraphRay,
    note = note, isAuthority = isAuthority,
    fireFor = fireFor, pushFlash = pushFlash,
}
local readFileAny = worldGlue.readFileAny
local resolveGraphText = worldGlue.resolveGraphText
local graphApiOpts = worldGlue.graphApiOpts
local bindMapTriggers = worldGlue.bindMapTriggers
local spawnPlayerAt = worldGlue.spawnPlayerAt
local setTheme = worldGlue.setTheme
local fireGraphEvent = worldGlue.fireGraphEvent
local adoptWorldForAutomap = worldGlue.adoptWorldForAutomap
local loadProcedural = worldGlue.loadProcedural
local loadAuthored = worldGlue.loadAuthored
local hostAdoptWorld = worldGlue.hostAdoptWorld
local reloadMap = worldGlue.reloadMap
local resolveMapPath = worldGlue.resolveMapPath
local scanPacks = worldGlue.scanPacks
local mountProject = worldGlue.mountProject

-- Forward declarations: defined below under "Whatever is being played right
-- now", but tryStoreyLink needs to call them, so the locals must exist here.
local activeWorld, activeEntities, activePlayer


---------------------------------------------------------------------------
-- Whatever is being played right now: local, hosted, or replicated
---------------------------------------------------------------------------

function activeWorld()
    if game.client then return game.client.world end
    return game.world
end

function activeEntities()
    if game.client then return game.client.entities end
    return game.entities
end

function activePlayer()
    if game.client then return game.client.player end
    return game.player
end

-- The command line (parsed in love.load) and the input layer. Bound here,
-- after the active* accessors it senses through; the menu/demo actions it
-- dispatches to are built below, so they ride as late-binding closures.
local Args = require('app.args')
local args = Args.new()

-- Forward declarations for the closures below — the same guard startHost
-- uses: a bare later-declared local in a closure is a nil global (c5be3fa).
local demoEvent, startDemoRecord, stopDemoRecord, startDemoPlayback
local shellOpen, shellClose, shellApply, confirmIntermission

local inputGlue = require('app.input'){
    game = game, Game = Game, MeatRay = MeatRay,
    Collide = Collide, Inventory = Inventory, Weapons = Weapons,
    note = note, args = args,
    activeWorld = activeWorld, activeEntities = activeEntities,
    activePlayer = activePlayer,
    doorInFront = doorInFront, resolveFire = resolveFire,
    describeShot = describeShot,
    reloadMap = reloadMap, loadProcedural = loadProcedural,
    loadAuthored = loadAuthored, resolveMapPath = resolveMapPath,
    demoEvent = function(...) return demoEvent(...) end,
    startDemoRecord = function(...) return startDemoRecord(...) end,
    stopDemoRecord = function(...) return stopDemoRecord(...) end,
    startDemoPlayback = function(...) return startDemoPlayback(...) end,
    shellOpen = function(...) return shellOpen(...) end,
    shellClose = function(...) return shellClose(...) end,
    shellApply = function(...) return shellApply(...) end,
    confirmIntermission = function(...) return confirmIntermission(...) end,
}
local normalizeAngle = inputGlue.normalizeAngle
local updateAim = inputGlue.updateAim
local updatePhotoCam = inputGlue.updatePhotoCam
local setMouseLook = inputGlue.setMouseLook
local gatherInput = inputGlue.gatherInput
snapQuarter = inputGlue.snapQuarter



-- Single player. The host does the same thing to its own player, through the
-- same Rep.applyInput, which is why prediction and authority agree.
-- A5, host authority: notice the local player's death, wait out the delay on
-- the simulation tick (so pausing pauses the wait), and bring them back
-- shielded. Runs from simulate() when solo and from the host's onStep when
-- hosting. Remote peers keep their entities host-side already; wiring their
-- deaths through meatray.game.modes' onRequestRespawn into game.respawn is the
-- multiplayer half of this same machinery.
local function stepRespawn(step)
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

---------------------------------------------------------------------------
-- F1: demos. Recording writes down what THIS loop was fed; playback feeds
-- the same stream back into a world rebuilt from the same seed. The glue
-- lives in app/demo.lua; simulate() below is the loop being recorded.
---------------------------------------------------------------------------

local demoGlue = require('app.demo'){
    game = game, Game = Game, MeatRay = MeatRay,
    Entity = Entity, Inventory = Inventory,
    note = note, resolveFire = resolveFire,
    loadAuthored = loadAuthored, loadProcedural = loadProcedural,
}
demoEvent = demoGlue.demoEvent          -- assigns the forward-declared locals
local applyDemoEvent = demoGlue.applyDemoEvent
local reloadForDemo = demoGlue.reloadForDemo
startDemoRecord = demoGlue.startDemoRecord
stopDemoRecord = demoGlue.stopDemoRecord
startDemoPlayback = demoGlue.startDemoPlayback

local function simulate(step)
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

    stepRespawn(step)

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


---------------------------------------------------------------------------
-- F4: the demo campaign and the intermission confirm live in app/campaign.lua.
---------------------------------------------------------------------------

local campaignGlue = require('app.campaign'){
    game = game, Game = Game, note = note,
    activePlayer = function() return activePlayer() end,
    loadAuthored = loadAuthored,
}
local startCampaign = campaignGlue.start
confirmIntermission = campaignGlue.confirm   -- assigns the forward-declared local

---------------------------------------------------------------------------
-- G1: the shell's screens and what its rows DO. The menu model proposes
-- (navigation, capture, value cycling); this is where proposals land.
--
-- startHost/startClient are defined in the networking section BELOW, so they
-- are forward-declared here — a bare reference would silently resolve to a
-- nil global at runtime, the trap c5be3fa fixed for tryStoreyLink.
---------------------------------------------------------------------------

local startHost, startClient

-- The screens and their dispositions live in app/menu.lua; the two network
-- starters are wrapped so the closures see the locals assigned below.
local shellMenu = require('app.menu'){
    game = game, Game = Game, MeatRay = MeatRay,
    note = note, setMouseLook = setMouseLook,
    loadProcedural = loadProcedural, reloadMap = reloadMap,
    mountProject = mountProject, applyTemplate = applyTemplate,
    startCampaign = startCampaign,
    startHost = function(...) return startHost(...) end,
    startClient = function(...) return startClient(...) end,
}
shellOpen, shellClose, shellApply =     -- assigns the forward-declared locals
    shellMenu.open, shellMenu.close, shellMenu.apply


---------------------------------------------------------------------------
-- Networking: hosting, joining and remote-command meaning live in
-- app/net.lua. Everything in the ctx exists by this point; the returned
-- starters land on the forward-declared locals the menu closures watch.
---------------------------------------------------------------------------

local netGlue = require('app.net'){
    game = game, Game = Game, MeatRay = MeatRay,
    Net = Net, Rep = Rep, Inventory = Inventory,
    note = note, NET_DOOR_REACH = NET_DOOR_REACH,
    doorInFront = doorInFront, resolveFire = resolveFire,
    describeShot = describeShot, applyShotDecals = applyShotDecals,
    pushFlash = pushFlash, normalizeAngle = normalizeAngle,
    updateCreatures = updateCreatures, stepRules = stepRules,
    stepRespawn = stepRespawn,
    reloadMap = reloadMap, loadAuthored = loadAuthored,
    loadProcedural = loadProcedural, hostAdoptWorld = hostAdoptWorld,
    setTheme = setTheme, adoptWorldForAutomap = adoptWorldForAutomap,
}
startHost, startClient = netGlue.startHost, netGlue.startClient

---------------------------------------------------------------------------
-- LÖVE callbacks
---------------------------------------------------------------------------

-- The command line and the --log tee live in app/args.lua.

function love.load(argv)
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

    -- F3: the console. Construction and every command live in app/console.lua
    -- (the first cut of un-god-filing this file); the ctx hands it the demo's
    -- own functions, all of which exist by this point in love.load.
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

    -----------------------------------------------------------------------
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

    -----------------------------------------------------------------------
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

    -----------------------------------------------------------------------
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

    -----------------------------------------------------------------------
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

    -----------------------------------------------------------------------
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

    -----------------------------------------------------------------------
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

-- The render path: app/draw.lua owns every pixel. Bound here, above
-- love.update, because update watches hudState deltas each frame.
local drawGlue = require('app.draw'){
    game = game, Game = Game, MeatRay = MeatRay,
    Net = Net, Weapons = Weapons, Inventory = Inventory,
    note = note, args = args,
    activeWorld = activeWorld, activeEntities = activeEntities,
    activePlayer = activePlayer,
    drawDecals = drawDecals, drawParticles = drawParticles,
}
local hudState = drawGlue.hudState
local lightingFor = drawGlue.lightingFor

function love.update(dt)
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
            note('disconnected: ' .. tostring(game.session:reason()))
            game.client = nil
        end

    else
        -- The only place a pause can actually stop anything: the solo clock.
        -- A host and a client both keep stepping, which is why the session
        -- refuses to pause them in the first place. F10 photo mode freezes the
        -- same solo clock, so a still is a still — the scene holds while you
        -- fly the camera around it.
        local simDt = game.photo:pausesSim() and 0 or game.session:simDelta(dt)
        game.alpha = game.clock:advance(simDt, simulate)
    end
end

---------------------------------------------------------------------------
-- The whole render path lives in app/draw.lua (bound above love.update).
---------------------------------------------------------------------------

function love.draw()
    drawGlue.draw()
end

-- Every key, click and mouse delta lives in app/input.lua; these stubs are
-- the only LÖVE-facing surface left here.
function love.mousemoved(_, _, dx, dy) inputGlue.mousemoved(dx, dy) end
function love.mousepressed() inputGlue.mousepressed() end
function love.textinput(text) inputGlue.textinput(text) end
function love.keypressed(key) inputGlue.keypressed(key) end

function love.resize(w, h)
    if MeatRay.canRender() then MeatRay.raycaster.resize(w, h) end
    -- The scaled buffer is sized from the window, so it is stale now. Dropping
    -- it rather than resizing it lets the next frame rebuild it from the one
    -- place that knows the rule.
    game.scaleCanvas = nil
end

-- Settings that were changed but never saved (a resolution the player nudged
-- and then quit on) are written here rather than lost. `dirty` is the model's
-- own flag, so a session that changed nothing writes nothing.
function love.quit()
    if game.options and game.options.dirty and game.storage then
        game.options:save(game.storage)
    end
end

-- Exposed so the selftest and the network test can drive the same state the demo
-- uses, and so a game embedding this demo can reach in.
_G.MEATRAY_DEMO = game
_G.MEATRAY_DEMO.resolveFire = resolveFire
_G.MEATRAY_DEMO.describeShot = describeShot
_G.MEATRAY_DEMO.doorInFront = doorInFront
-- Exposed so the selftest can render a frame of the demo's own lighting policy
-- rather than a scene built to flatter it.
_G.MEATRAY_DEMO.lightingFor = lightingFor
