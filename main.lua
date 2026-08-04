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

-- The frame loop — stepRespawn, simulate and love.update — lives in
-- app/loop.lua. hudState belongs to the draw module built further down,
-- so it rides as a late-binding closure over a forward-declared local.
local hudState
local loopGlue = require('app.loop'){
    game = game, Game = Game, MeatRay = MeatRay,
    Rep = Rep, note = note, args = args,
    activeWorld = activeWorld, activeEntities = activeEntities,
    activePlayer = activePlayer,
    spawnPlayerAt = spawnPlayerAt,
    gatherInput = gatherInput, updateAim = updateAim,
    updatePhotoCam = updatePhotoCam,
    applyDemoEvent = applyDemoEvent,
    updateCreatures = updateCreatures, stepRules = stepRules,
    hudState = function(p) return hudState(p) end,
}
local stepRespawn = loopGlue.stepRespawn


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

-- Boot: love.load lives in app/boot.lua — the sequence there IS the contract.
local bootGlue = require('app.boot'){
    game = game, Game = Game, MeatRay = MeatRay,
    Args = Args, args = args,
    Options = Options, Storage = Storage, Tick = Tick,
    Inventory = Inventory,
    note = note, setMouseLook = setMouseLook,
    defineGameplay = defineGameplay, defineArchetypes = defineArchetypes,
    defineSprites = defineSprites,
    scanPacks = scanPacks, mountProject = mountProject,
    activePlayer = activePlayer, activeWorld = activeWorld,
    loadProcedural = loadProcedural, loadAuthored = loadAuthored,
    hostAdoptWorld = hostAdoptWorld, reloadMap = reloadMap,
    spawnBot = spawnBot, spawnNeurobot = spawnNeurobot,
    spawnCrowdAgent = spawnCrowdAgent,
    applyTemplate = applyTemplate, startCampaign = startCampaign,
    startMeatGraphMode = startMeatGraphMode,
    startHost = startHost, startClient = startClient,
    shellOpen = shellOpen,
}

function love.load(argv)
    bootGlue(argv)
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
hudState = drawGlue.hudState            -- assigns the forward-declared local
local lightingFor = drawGlue.lightingFor

function love.update(dt)
    loopGlue.update(dt)
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
