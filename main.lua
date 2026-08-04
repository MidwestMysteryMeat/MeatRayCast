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

-- In-world layered storeys first, then multi-map links. See docs/STOREYS.md.
local function tryStoreyLink()
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


---------------------------------------------------------------------------
-- Input
---------------------------------------------------------------------------

-- Keeps an angle in [0, 2pi). Aim accumulates every frame the mouse moves, so
-- without this it grows without bound: spin for a few minutes and it is a large
-- float losing precision in its low bits, and it is a large number to put on the
-- wire every input tick for no reason.
local function normalizeAngle(a)
    return MeatRay.billboard.normalize(a)
end

-- Aim is sampled per frame, not per tick, because it is input rather than
-- simulation: the mouse moved when it moved.
local function updateAim(dt)
    -- Crawler movement snap-turns in 90-degree steps on keypress, so the
    -- continuous Q/E turn is off in grid mode (see love.keypressed).
    if game.gridMove then return end
    local turn = 0
    if love.keyboard.isDown('q', 'left') then turn = turn - 1 end
    if love.keyboard.isDown('e', 'right') then turn = turn + 1 end
    if turn ~= 0 then
        game.aim = normalizeAngle(game.aim + turn * game.turnSpeed * dt)
    end
end

-- F10: fly the photo camera from held keys. Movement only — mouse aim comes
-- through love.mousemoved and the toggles through love.keypressed. WASD/arrows
-- fly, space/ctrl rise and fall, shift is the fast modifier.
local function updatePhotoCam(dt)
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
function snapQuarter(a)
    local q = math.pi / 2
    return normalizeAngle(math.floor(a / q + 0.5) * q)
end

-- Captures or releases the cursor. Captured is the playing state; released is
-- needed for anything with a pointer (the editor later) and for getting out of a
-- windowed game without quitting it.
local function setMouseLook(on)
    if not MeatRay.canRender() or not love.mouse then return end
    game.mouseLook = on and true or false
    love.mouse.setRelativeMode(game.mouseLook)
    love.mouse.setVisible(not game.mouseLook)
end

local function gatherInput()
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
local demoEvent = demoGlue.demoEvent
local applyDemoEvent = demoGlue.applyDemoEvent
local reloadForDemo = demoGlue.reloadForDemo
local startDemoRecord = demoGlue.startDemoRecord
local stopDemoRecord = demoGlue.stopDemoRecord
local startDemoPlayback = demoGlue.startDemoPlayback

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
local confirmIntermission = campaignGlue.confirm

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
local shellOpen, shellClose, shellApply =
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
local Args = require('app.args')
local args = Args.new()

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
function love.mousemoved(_, _, dx, dy)
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

function love.mousepressed()
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
        setMouseLook(true)
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

function love.textinput(text)
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

function love.keypressed(key)
    -- F3: the console owns the keyboard while it is down. Toggling it also
    -- releases the mouse, because a console you cannot click past is a trap.
    if key == '`' then
        game.consoleOpen = not game.consoleOpen
        if game.consoleOpen and MeatRay.canRender() then setMouseLook(false) end
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
            setMouseLook(false)
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
            setMouseLook(false)
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
        game.aim = snapQuarter(game.aim - math.pi / 2)
    elseif game.gridMove and (key == 'e' or key == 'right') then
        game.aim = snapQuarter(game.aim + math.pi / 2)
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
        if tryStoreyLink() then
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
