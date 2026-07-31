--[[
    MeatRayCast demo.

    Deliberately written against the library API rather than the convenience
    layer, so it doubles as proof that the library path is sufficient on its own.

        love .                                  procedural world, single player
        love . --map arena                      hand-authored map from maps/arena.map
        love . --blueprint                      host node graph (MeatEngine C6 kinship)
        love . --selftest                       headless-ish gate, prints PASS and exits

        love . --host                           listen server: play and host at once
        love . --server --port 6789 --map arena  headless dedicated server
        love . --connect 127.0.0.1:6789         join a server
        love . --browse                         list LAN servers and exit
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
local Blueprint   = Game.blueprint
local Mode        = Game.mode

local game = {
    world = nil,
    entities = {},
    player = nil,
    clock = nil,
    alpha = 0,
    source = 'procedural',
    seed = 20260730,
    mode = nil,             -- optional host ruleset (often blueprint-bound)
    blueprint = nil,        -- loaded graph, if any
    triggers = nil,         -- meatray.sim.triggers, when a blueprint installs volumes
    zbuffer = nil,
    lighting = nil,         -- meatray.render.lighting grid for the active world
    lightingWorld = nil,    -- the world it was baked against
    torch = true,           -- does the player carry a light?
    fire = nil,             -- meatray.game.gas field for the active world
    fireWorld = nil,        -- the world it belongs to
    flashes = {},           -- short-lived explosion lights, presentation only
    decals = Decals.new{ max = 192, defaultLife = 14 },
    log = {},
    showHelp = true,
    turnSpeed = 2.6,
    moveSpeed = 3.2,
    aim = 0,
    pitch = 0,              -- look up/down, radians; local only, not on the wire
    sensitivity = 0.0028,   -- radians per pixel of mouse movement
    mouseLook = false,      -- is the cursor captured for looking?
    doorReach = 2,
    wantPlayer = true,
    host = nil,
    client = nil,
}

-- How much of the demo's rules live in data rather than in code. Defined once at
-- boot and reset first, so a hot reload re-runs it cleanly.
local function defineGameplay()
    Game.reset()

    Game.effects.define('burning', {
        duration = 4, period = 1,
        assetTags = { 'debuff.burning' },
        modifiers = { { attr = 'health', magnitude = -3 } },
        stacking = { policy = 'refresh' },
    })

    Weapons.define('pistol', {
        damage = 12, magazine = 12, fireInterval = 0.15, reloadTime = 1.2,
        spread = 0.010, recoil = 0.018, recoilMax = 0.10, recoilRecovery = 0.5,
        kick = 0.020, range = 32, autoReload = true, ammoItem = 'ammo.pistol',
    })

    Weapons.define('launcher', {
        kind = 'projectile', damage = 0,
        magazine = 1, fireInterval = 0.9, reloadTime = 1.6,
        ammoItem = 'ammo.grenade', autoReload = true,
        projectile = { kind = 'grenade', speed = 11, radius = 0.22, range = 26,
                       explosion = 'frag' },
    })

    -- The flash is DESCRIBED here and pushed by whoever has a light grid. A
    -- dedicated server detonates the same explosion and pushes nothing.
    Explosion.define('frag', {
        radius = 4.5, damage = 70, curve = 'smooth',
        tags = { 'damage.type.explosive' },
        effects = { 'burning' },
        gasAmount = 30, gasRadius = 2.4,
        light = { radius = 12, intensity = 2.4, color = { 1.00, 0.74, 0.36 } },
    })

    Inventory.defineItem('pistol',        { stack = 1, weapon = 'pistol' })
    Inventory.defineItem('launcher',      { stack = 1, weapon = 'launcher' })
    Inventory.defineItem('ammo.pistol',   { stack = 120, ammoFor = 'pistol' })
    Inventory.defineItem('ammo.grenade',  { stack = 12,  ammoFor = 'launcher' })
end

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

local function defineArchetypes()
    Entity.clearArchetypes()

    -- Directional: eight angle buckets, so you can see which way it faces.
    Entity.archetype('imp', function(e)
        e:add(C.Billboard{ sheet = 'imp' })
        e:add(C.Health{ hp = 30, max = 30 })
        e:add(C.Brain{ state = 'patrol' })
        e.radius = 0.28
        Game.attach(e, { authority = isAuthority() })
        -- Host only: clients never run AI. Attach is cheap and fill fields;
        -- step is gated by isAuthority in updateCreatures.
        if isAuthority() then
            AI.attach(e, { state = 'patrol', alertRange = 10, speed = 2.2 })
        end
    end)

    -- Always-facing: one bucket, a floating pickup.
    Entity.archetype('crystal', function(e)
        e:add(C.Billboard{ sheet = 'crystal' })
        e:add(C.Health{ hp = 10, max = 10 })
        e.radius = 0.22
        Game.attach(e, { authority = isAuthority() })
    end)

    Entity.archetype('player', function(e)
        e:add(C.Player{ peerId = 0, name = 'local' })
        e:add(C.Health{ hp = 100, max = 100 })
        e:add(C.Weapon{})
        e:add(C.Input{})
        e.radius = 0.24
        Game.attach(e, { authority = isAuthority() })

        -- The bag is what the gun reloads out of: `Inventory.equip` wires the
        -- weapon's ammunition supply to it, so a reload consumes the item whose
        -- `ammoFor` names the weapon and weapons.lua never learns what an
        -- inventory is.
        Inventory.attach(e, { capacity = 8 })
        Inventory.add(e, 'pistol', 1)
        Inventory.add(e, 'launcher', 1)
        Inventory.add(e, 'ammo.pistol', 96)
        Inventory.add(e, 'ammo.grenade', 6)
        Inventory.equipWeapon(e, 'pistol')
    end)

    -- What the launcher throws. A projectile is an ordinary entity, so it
    -- replicates and draws through machinery that needed no edit.
    Entity.archetype('grenade', function(e)
        e:add(C.Billboard{ sheet = 'grenade' })
        e.radius = 0.22
    end)
end

local function defineSprites()
    MeatRay.sprites.clear()
    MeatRay.sprites.define('imp', {
        angles = 8, frames = 4, fps = 7,
        color = { 0.78, 0.24, 0.20 }, anchor = 'feet', scale = 0.85,
    })
    MeatRay.sprites.define('crystal', {
        angles = 1, frames = 2, fps = 3,
        color = { 0.35, 0.75, 0.95 }, anchor = 'center', scale = 0.5,
    })
    -- Other players draw as imps: a placeholder, but a visible one.
    MeatRay.sprites.define('player', {
        angles = 8, frames = 4, fps = 7,
        color = { 0.35, 0.85, 0.45 }, anchor = 'feet', scale = 0.9,
    })
    MeatRay.sprites.define('grenade', {
        angles = 1, frames = 1, fps = 1,
        color = { 0.95, 0.80, 0.30 }, anchor = 'center', scale = 0.28,
    })
end

---------------------------------------------------------------------------
-- Logging
---------------------------------------------------------------------------

local function note(text)
    table.insert(game.log, 1, text)
    while #game.log > 6 do table.remove(game.log) end
    if not MeatRay.canRender() then print(text) end
end

---------------------------------------------------------------------------
-- Game rules, written once and shared by every mode
---------------------------------------------------------------------------

-- The door the entity is looking at, within reach, or nil.
local function doorInFront(world, e, reach)
    local dirX, dirY = math.cos(e.angle), math.sin(e.angle)
    local dist, tx, ty = Collide.rayTile(world, e.x, e.y, dirX, dirY, reach or game.doorReach)
    if dist and world:doorAt(tx, ty) then return tx, ty end
    return nil
end

-- The fire field for a world, built once and cached against it. Fire is a gas:
-- a scalar that diffuses across open tiles, decays, and hurts whatever stands in
-- it. Smoke and poison are the same object with different constants.
local function fireFor(world)
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
local function pushFlash(light)
    if not light then return end
    game.flashes[#game.flashes + 1] = {
        x = light.x, y = light.y, radius = light.radius,
        intensity = light.intensity or 1.6, color = light.color,
        life = 0.28, maxLife = 0.28,
    }
end

-- Wall holes for hitscan; ground marks when something dies. Cosmetic only.
local function applyShotDecals(shot)
    if not shot or not game.decals then return end
    if shot.result == 'wall' and shot.hitx and shot.hity then
        game.decals:addHit(shot.hitx, shot.hity, shot.nx, shot.ny, {
            kind = 'bullet', life = 12, scale = 0.18,
            z = 0.45,
        })
    elseif shot.result == 'hit' and shot.killed and shot.hitx and shot.hity then
        game.decals:add{
            x = shot.hitx, y = shot.hity, z = 0.02,
            kind = 'blood', life = 10, scale = 0.35,
        }
    end
end

-- Resolves a shot. Authoritative wherever it runs: in single player that is the
-- only machine, and in every network mode it only ever runs on the host.
--
-- Nothing here subtracts hit points. `Weapons.fire` applies a damage EFFECT, so
-- armour, resistances and immunities all work on it without this function — or
-- weapons.lua — knowing that any of them exist.
local function resolveFire(world, entities, shooter, aim)
    local shot, why = Weapons.fire(shooter, {
        world = world, entities = entities, angle = aim,
        gas = fireFor(world), onLight = pushFlash,
    })

    if not shot then
        return { shooter = shooter.id, result = why or 'nothing' }
    end

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
    applyShotDecals(flat)
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

local function drawDecals(view, zbuffer)
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

local function describeShot(shot)
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

-- Creature behaviour. Host-only: a client receives transforms via snapshots and
-- never pathfinds. Uses meatray.sim.ai (patrol / chase / cover on pathfind).
local function updateCreatures(dt, world, entities, target)
    if not isAuthority() then return end
    AI.stepAll(entities, dt, {
        world = world,
        entities = entities,
        target = target,
    })
end

--[[
    One fixed step of the gameplay rules, run wherever the simulation is
    authoritative: single player, and the host in all three network modes. Never
    on a client, which asks and is told.

    Order is fixed and matters: effects and weapon timers first (a reload that
    finishes this step should be able to fire next step), then projectiles (which
    may detonate and therefore change health), then the gas field, then what the
    gas does to whoever is standing in it.
]]
local function stepRules(step, world, entities)
    if not world or not entities then return end

    Game.tickAll(entities, step)

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
            if game.decals then
                game.decals:add{
                    x = impact.explosion.x, y = impact.explosion.y, z = 0.02,
                    kind = 'scorch', life = 18, scale = 0.55,
                }
            end
            if game.host then
                game.host:event('boom', { x = impact.explosion.x, y = impact.explosion.y,
                                          radius = impact.explosion.radius, hits = hits })
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
end

-- Host-side blueprint graph (MeatEngine C6 kinship). Optional: pass
-- --blueprint [path] to load blueprints/demo.graph.json or a custom graph.
local function startBlueprintMode(path)
    path = path or 'blueprints/demo.graph.json'
    local text
    if love and love.filesystem and love.filesystem.read then
        text = love.filesystem.read(path)
    end
    if not text then
        local f = io.open(path, 'rb')
        if f then text = f:read('*a'); f:close() end
    end
    if not text then
        note('blueprint not found: ' .. tostring(path) .. ' (using built-in example)')
        game.blueprint = Blueprint.example()
    else
        local g, err = Blueprint.load(text)
        if not g then
            note('blueprint parse failed: ' .. tostring(err))
            return
        end
        game.blueprint = g
    end

    local mode = Mode.new{ name = game.blueprint.name or 'blueprint' }
    Blueprint.bindMode(mode, game.blueprint, {
        log = function(msg) note(tostring(msg)) end,
        Entity = Entity,
        AI = AI,
        -- true = create a Triggers set and install graph.volumes
        triggers = true,
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
    game.triggers = mode.data and mode.data._bpTriggers or nil
    if game.player then
        mode:playerJoin(0, game.player)
    end
    local volN = mode.data and mode.data._bpVolumeCount or 0
    note(('blueprint "%s" running (%d nodes, %d volumes)'):format(
        game.blueprint.name or 'unnamed', game.blueprint:nodeCount(), volN))
end

---------------------------------------------------------------------------
-- World loading, from either source
---------------------------------------------------------------------------

local function spawnPlayerAt(x, y, angle)
    if not game.wantPlayer then return nil end
    local p = Entity.spawn('player', x, y)
    p.angle = angle or 0
    -- Stand on the walk surface under the spawn, not at z=0 over a raised tile.
    if game.world then Collide.ground(p, game.world) end
    p:snapPrevious()
    game.player = p
    game.aim = p.angle
    table.insert(game.entities, p)
    return p
end

local function setTheme(theme)
    if MeatRay.canRender() then MeatRay.raycaster.setTheme(theme) end
end

local function loadProcedural()
    local theme = 'dungeon'
    if MeatRay.canRender() then
        local themes = MeatRay.themes.names()
        theme = themes[(game.seed % #themes) + 1]
    end

    game.worldSpec = {
        width = 44, height = 44, seed = game.seed, doorChance = 0.5, theme = theme,
    }

    local world, rooms = Worldgen.generate(game.worldSpec)

    game.world = world
    game.entities = {}
    game.player = nil
    setTheme(theme)

    local spawn = world.spawn or { x = 4.5, y = 4.5 }
    spawnPlayerAt(spawn.x, spawn.y, 0)

    -- One creature per room after the first, alternating kinds.
    for i = 2, #rooms do
        local room = rooms[i]
        local kind = (i % 2 == 0) and 'imp' or 'crystal'
        local e = Entity.spawn(kind, room.cx + 0.5, room.cy + 0.5)
        e.angle = (i * 0.7) % (math.pi * 2)
        e:snapPrevious()
        table.insert(game.entities, e)
    end

    game.source = 'procedural'
    note(('procedural world, seed %d, theme %s, %d rooms'):format(game.seed, theme, #rooms))
end

local function loadAuthored(path)
    path = path or 'maps/arena.map'

    local contents = love.filesystem.read(path)
    if not contents then
        note('could not read ' .. path .. ' - falling back to procedural')
        return loadProcedural()
    end

    local map, errs = Map.parse(contents)
    if not map then
        note('map error: ' .. tostring(errs and errs[1]))
        return loadProcedural()
    end

    local world, markers, spawn = Map.toWorld(map)
    game.world = world
    game.entities = {}
    game.player = nil
    game.worldSpec = nil          -- an authored map is sent as a grid, not a seed
    setTheme(map.theme)

    spawnPlayerAt(spawn.x, spawn.y, spawn.angle or 0)

    for _, m in ipairs(markers) do
        if Entity.hasArchetype(m.kind) then
            local e = Entity.spawn(m.kind, m.x, m.y)
            e.angle = m.angle or 0
            e:snapPrevious()
            table.insert(game.entities, e)
        else
            note('map references unknown archetype: ' .. tostring(m.kind))
        end
    end

    game.source = 'authored'
    note(('authored map "%s", theme %s, %d markers'):format(map.name, map.theme, #markers))
end

---------------------------------------------------------------------------
-- Whatever is being played right now: local, hosted, or replicated
---------------------------------------------------------------------------

local function activeWorld()
    if game.client then return game.client.world end
    return game.world
end

local function activeEntities()
    if game.client then return game.client.entities end
    return game.entities
end

local function activePlayer()
    if game.client then return game.client.player end
    return game.player
end

---------------------------------------------------------------------------
-- Lighting. Demo policy, not an engine rule: the engine ships lighting off by
-- default, and this is one way to switch it on.
---------------------------------------------------------------------------

-- How dark an unlit tile is before meatray.render.lighting applies its own
-- readability floor. Low enough that a torch is worth carrying, high enough that
-- the floor is what you actually see in an unlit room rather than a clamp you
-- never reach.
local DEMO_BASE_LEVEL = 0.34

-- Static lights are placed deterministically off the tile coordinates, not from
-- an RNG: a host and a client that generate the same world must bake the same
-- lighting, and "the level looks different on each machine" is a bug that only
-- shows up with two people in the room.
local function placeStaticLights(grid, world)
    local placed = 0

    for ty = 2, world.height - 1 do
        for tx = 2, world.width - 1 do
            if placed < 18 and not world:isSolid(tx, ty)
               and (tx * 7 + ty * 13) % 29 == 0 then
                -- Against a wall, so it reads as a sconce rather than as a
                -- floating ball of light.
                local againstWall = world:isSolid(tx - 1, ty) or world:isSolid(tx + 1, ty)
                               or world:isSolid(tx, ty - 1) or world:isSolid(tx, ty + 1)
                if againstWall then
                    placed = placed + 1
                    -- Every third one is cold, so a coloured light tinting a wall
                    -- is visible in any screenshot of the demo rather than only
                    -- in a scene built to show it.
                    local cold = (placed % 3 == 0)
                    grid:addStatic{
                        x = tx - 0.5, y = ty - 0.5,
                        radius = cold and 5.5 or 6.5,
                        intensity = cold and 0.85 or 1.0,
                        color = cold and { 0.30, 0.58, 1.00 } or { 1.00, 0.60, 0.24 },
                    }
                end
            end
        end
    end

    return placed
end

-- Built once per world and cached against it, so switching level, reseeding, or
-- joining a host all rebuild it exactly once and nothing rebakes per frame.
local function lightingFor(world)
    if not world then return nil end
    if game.lighting and game.lightingWorld == world then return game.lighting end

    local grid = MeatRay.lighting.new{ world = world, baseLevel = DEMO_BASE_LEVEL }
    local placed = placeStaticLights(grid, world)
    grid:update()

    game.lighting, game.lightingWorld = grid, world
    if MeatRay.canRender() then MeatRay.raycaster.setLighting(grid) end
    note(('lighting: %d static lights baked'):format(placed))
    return grid
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
    local turn = 0
    if love.keyboard.isDown('q', 'left') then turn = turn - 1 end
    if love.keyboard.isDown('e', 'right') then turn = turn + 1 end
    if turn ~= 0 then
        game.aim = normalizeAngle(game.aim + turn * game.turnSpeed * dt)
    end
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
    if love.keyboard.isDown('w', 'up') then forward = forward + 1 end
    if love.keyboard.isDown('s', 'down') then forward = forward - 1 end
    if love.keyboard.isDown('a') then strafe = strafe - 1 end
    if love.keyboard.isDown('d') then strafe = strafe + 1 end
    return { forward = forward, strafe = strafe, angle = game.aim }
end

-- Single player. The host does the same thing to its own player, through the
-- same Rep.applyInput, which is why prediction and authority agree.
local function simulate(step)
    for _, e in ipairs(game.entities) do e:snapPrevious() end
    if game.player then
        Rep.applyInput(game.player, Rep.sanitiseInput(gatherInput()), step, game.world,
                       { moveSpeed = game.moveSpeed, turnSpeed = game.turnSpeed })
    end
    updateCreatures(step, game.world, game.entities, game.player)
    stepRules(step, game.world, game.entities)
    game.world:update(step)
end

---------------------------------------------------------------------------
-- Networking
---------------------------------------------------------------------------

-- What a client action means. The engine has no built-in gameplay verbs, so this
-- is where the demo's rules live for every remote player.
local function hostCommand(host, peer, name, body)
    local e = peer.entity
    if not e then return false end
    body = body or {}

    if name == 'door' then
        local tx, ty = tonumber(body.tx), tonumber(body.ty)
        if tx and ty then
            local door = host.world:doorAt(tx, ty)
            local dx, dy = (tx - 0.5) - e.x, (ty - 0.5) - e.y
            if door and (dx * dx + dy * dy) <= NET_DOOR_REACH * NET_DOOR_REACH then
                host:toggleDoor(tx, ty)
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
            host:toggleDoor(atx, aty)
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
        host:event('hitscan', resolveFire(host.world, host.entities, e, aim))
        return true

    elseif name == 'swap' then
        local wanted = (body.weapon == 'launcher') and 'launcher' or 'pistol'
        return Inventory.equipWeapon(e, wanted) ~= nil
    end

    return false
end

local function startHost(opts)
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
        localPlayer = game.player or false,
        onStep = function(dt, h)
            updateCreatures(dt, h.world, h.entities, h.localPlayer or h.entities[1])
            stepRules(dt, h.world, h.entities)
        end,
        onCommand  = hostCommand,
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
    return host
end

local function startClient(address, opts)
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
            elseif name == 'door' then
                note(('door at %d,%d %s'):format(body.tx or 0, body.ty or 0,
                     (body.open == 1) and 'opened' or 'closed'))
            end
        end,
        onChat = function(_, from, text) note(('<%s> %s'):format(tostring(from), text)) end,
        onReject = function(_, reason) note('refused: ' .. tostring(reason)) end,
    })

    if not client then
        note('could not join: ' .. tostring(err))
        return nil
    end

    game.client = client
    return client
end

---------------------------------------------------------------------------
-- LÖVE callbacks
---------------------------------------------------------------------------

local args = {
    selftest = false, nettest = false, browse = false, netcheck = false,
    netfrag = false, netproxy = false, punchcheck = false, fillers = nil,
    map = nil, mode = nil, connect = nil, port = nil,
    name = nil, password = nil, role = 'a', discovery = 'lan', log = nil,
    registries = nil,
}

local function parseArgs(argv)
    argv = argv or {}

    -- The argument after a flag, unless it is itself a flag.
    --
    -- Taking argv[i + 1] blindly means an optional-value flag swallows the next
    -- option: `--editor --editor-tab sprite` had `--editor` consume `--editor-tab`
    -- as a map name and then report "cannot read maps/--editor-tab.map", which
    -- reads as a missing file rather than as a parsing bug. Every flag below used
    -- to do this, so it is fixed once here rather than at fourteen call sites.
    local function value(i, fallback)
        local nextArg = argv[i + 1]
        if nextArg == nil or nextArg:sub(1, 2) == '--' then return fallback end
        return nextArg
    end

    for i, a in ipairs(argv) do
        if a == '--selftest' then args.selftest = true
        elseif a == '--nettest' then args.nettest = true
        elseif a == '--browse' then args.browse = true
        elseif a == '--bench' then args.bench = true
        elseif a == '--bench-map' then args.benchMap = value(i, 'arena')
        elseif a == '--bench-frames' then args.benchFrames = value(i)
        elseif a == '--bench-label' then args.benchLabel = value(i)
        elseif a == '--bench-repeat' then args.benchRepeat = value(i)
        elseif a == '--bench-shot' then args.benchShot = value(i, 'bench')
        elseif a == '--bench-ceiling' then args.benchCeiling = true
        elseif a == '--bench-flat' then args.benchFlat = true
        elseif a == '--bench-lights' then args.benchLights = value(i, '4')
        elseif a == '--bench-flat-light' then args.benchFlatLight = true
        elseif a == '--bench-segments' then args.benchSegments = value(i, '8')
        elseif a == '--bench-ab' then args.benchAb = true
        elseif a == '--editor' then args.editor = value(i, true)
        elseif a == '--editor-shot' then args.editorShot = value(i, 'editor')
        elseif a == '--editor-tab' then args.editorTab = value(i)
        elseif a == '--browse-seconds' then args.browseSeconds = value(i)
        elseif a == '--browse-wait-all' then args.browseWaitAll = true
        elseif a == '--netcheck' then args.netcheck = true
        elseif a == '--netfrag' then args.netfrag = true
        elseif a == '--netproxy' then args.netproxy = true
        elseif a == '--punchcheck' then args.punchcheck = true
        -- Repeatable, because one hard-coded registry URL is a single point of
        -- failure that reveals itself on the day it goes down. Naming one also
        -- turns master discovery on for a host and hole punching on for a join:
        -- there is no second flag to forget.
        elseif a == '--registry' then
            local url = value(i)
            if url then
                args.registries = args.registries or {}
                args.registries[#args.registries + 1] = url
            end
        -- Shared by the two halves of the snapshot measurement: the host spawns
        -- this many filler entities, and the probe expects to find them.
        elseif a == '--fillers' then args.fillers = tonumber(value(i))
        elseif a == '--seconds' then args.seconds = tonumber(value(i))
        elseif a == '--warmup' then args.warmup = tonumber(value(i))
        elseif a == '--label' then args.label = value(i)
        elseif a == '--forward' then args.forward = value(i)
        elseif a == '--bind' then args.bind = value(i)
        elseif a == '--loss' then args.loss = tonumber(value(i))
        elseif a == '--drop' then args.drop = value(i, 'down')
        elseif a == '--grace' then args.grace = tonumber(value(i))
        elseif a == '--seed' then args.seed = tonumber(value(i))
        elseif a == '--expect' then args.expect = value(i, 'under')
        elseif a == '--server' then args.mode = 'dedicated'
        elseif a == '--host' then args.mode = 'listen'
        elseif a == '--map' then args.map = value(i, 'arena')
        elseif a == '--blueprint' then args.blueprint = value(i, 'blueprints/demo.graph.json')
        elseif a == '--connect' then args.connect = value(i)
        elseif a == '--port' then args.port = tonumber(value(i))
        elseif a == '--name' then args.name = value(i)
        elseif a == '--password' then args.password = value(i)
        elseif a == '--role' then args.role = value(i, 'a')
        elseif a == '--log' then args.log = value(i)
        elseif a == '--no-lan' then args.discovery = nil
        end
    end
end

-- `--log PATH` tees everything print() would say into a real file.
--
-- Two reasons, and the second is the one that made it necessary. A dedicated
-- server wants a log it can be asked about later. And on Windows, `lovec.exe`
-- reopens stdout onto the console, so a parent process redirecting stdout to a
-- file captures nothing at all — which makes an automated acceptance runner
-- impossible to write against stdout. An explicit file sidesteps the platform
-- entirely and works the same everywhere.
local function teeOutput(path)
    local file = io.open(path, 'w')
    if not file then
        print('could not open log file: ' .. tostring(path))
        return
    end

    local realPrint = print
    _G.print = function(...)
        realPrint(...)
        local parts = {}
        for i = 1, select('#', ...) do parts[i] = tostring((select(i, ...))) end
        file:write(table.concat(parts, '\t'), '\n')
        file:flush()          -- a log that is lost when the process is killed is not a log
    end
end

function love.load(argv)
    parseArgs(argv)

    if not MeatRay.canRender() then io.stdout:setvbuf('line') end
    if args.log then teeOutput(args.log) end

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

    if MeatRay.canRender() then
        MeatRay.raycaster.init{}
        defineSprites()
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
        if args.map then loadAuthored('maps/' .. args.map .. '.map') else loadProcedural() end
        if args.blueprint then startBlueprintMode(args.blueprint) end
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
end

function love.update(dt)
    if args.selftest or args.nettest or args.browse or args.netcheck
       or args.netfrag or args.netproxy or args.punchcheck then return end
    dt = math.min(dt, 0.25)

    if MeatRay.canRender() then updateAim(dt) end

    -- Flashes and decals fade in real time, not simulation time: they are
    -- presentation artefacts and nothing about the game depends on them.
    for i = #game.flashes, 1, -1 do
        local f = game.flashes[i]
        f.life = f.life - dt
        if f.life <= 0 then table.remove(game.flashes, i) end
    end
    if game.decals then game.decals:update(dt) end

    if game.host then
        if game.host.localPlayer then game.host:setLocalInput(gatherInput()) end
        game.host:update(dt)
        game.alpha = game.host:alpha()

    elseif game.client then
        game.client:setInput(gatherInput())
        game.client:update(dt)
        game.alpha = game.client:alpha()

        -- A client whose session ended has nothing left to do. In a real game
        -- this is where the menu comes back.
        if game.client.state == 'rejected' or game.client.state == 'kicked'
           or game.client.state == 'failed' then
            note('disconnected: ' .. tostring(game.client.reason))
            game.client = nil
        end

    else
        game.alpha = game.clock:advance(dt, simulate)
    end
end

function love.draw()
    if args.selftest then return end

    local world, player = activeWorld(), activePlayer()
    if not world or not player then
        love.graphics.setColor(1, 1, 1)
        love.graphics.print(game.client and 'connecting...' or 'no world', 8, 8)
        for i, line in ipairs(game.log) do love.graphics.print(line, 8, 26 + (i - 1) * 14) end
        return
    end

    -- The local player is predicted, so it interpolates on the simulation tick;
    -- everything the host owns interpolates between snapshots. Two different
    -- alphas, because they are two different clocks.
    local cameraAlpha = game.client and game.client:tickAlpha() or game.alpha
    local px, py, pangle, pz = player:interpolated(cameraAlpha)
    local floorZ = pz or player.z or 0
    local eyeHeight = MeatRay.world.EYE_HEIGHT
    -- Low ceilings crouch the camera so it never pokes through the plane.
    if world.ceilingHeightAtPoint then
        local ceilZ = world:ceilingHeightAtPoint(px, py)
        local room = ceilZ - floorZ
        local maxEye = room - 0.08
        if maxEye < 0.12 then maxEye = 0.12 end
        if eyeHeight > maxEye then eyeHeight = maxEye end
    end
    local eyeZ = floorZ + eyeHeight
    local view = MeatRay.raycaster.view(px, py, pangle, {
        eyeZ = eyeZ,
        eyeHeight = eyeHeight,
        pitch = game.pitch,
    })

    -- One frame of lighting: forget last frame's dynamic lights, then declare
    -- this frame's. The carried torch is the whole demonstration that dynamic
    -- light costs nothing to move — it changes position every single frame and
    -- rebakes nothing.
    local lighting = lightingFor(world)
    if lighting then
        lighting:beginFrame()
        if game.torch then
            lighting:addDynamic{
                x = px, y = py, radius = 6.5, intensity = 0.9,
                color = { 1.00, 0.86, 0.62 },
            }
        end

        -- Explosion flashes, fading. `Explosion.detonate` described these; the
        -- game decided to keep them for a quarter of a second and push them here,
        -- and a dedicated server ignored the same descriptions entirely.
        for i = 1, #game.flashes do
            local f = game.flashes[i]
            local fade = f.life / f.maxLife
            lighting:addDynamic{
                x = f.x, y = f.y, radius = f.radius,
                intensity = f.intensity * fade, color = f.color, curve = 'inverse',
            }
        end

        -- Burning tiles glow. This is the gas field driving the light grid: the
        -- cost is one light per burning tile, bounded by the grid's own cap, and
        -- the field only reports cells that actually hold something.
        local field = (game.fireWorld == world) and game.fire or nil
        if field then
            local lit = 0
            field:each(function(tx, ty, d)
                if d > 0.25 and lit < 24 then
                    lit = lit + 1
                    local strength = d > 1 and 1 or d
                    lighting:addDynamic{
                        x = tx - 0.5, y = ty - 0.5,
                        radius = 2.2 + strength * 2.0,
                        intensity = 0.5 + strength * 0.9,
                        color = { 1.00, 0.52, 0.18 },
                        curve = 'inverse',
                    }
                end
            end)
        end
    end

    game.zbuffer = MeatRay.raycaster.render(view, world)

    local atmosphere = MeatRay.themes.atmosphere(MeatRay.raycaster.getTheme())
    MeatRay.sprites.draw(activeEntities(), game.zbuffer, view, {
        time = (game.clock and game.clock:time()) or 0,
        alpha = game.alpha,
        ambient = atmosphere.ambient,
        maxView = atmosphere.maxView,
        lighting = lighting,
    })

    drawDecals(view, game.zbuffer)

    -- HUD
    love.graphics.setColor(1, 1, 1)
    local health = player:get('health')
    local status = Weapons.status(player)
    local carried = status and Inventory.count(player,
                        status.id == 'launcher' and 'ammo.grenade' or 'ammo.pistol') or 0
    love.graphics.print(('%d fps   hp %d/%d   %s %d/%d (%d)%s   [%s]  theme %s  %s')
        :format(love.timer.getFPS(),
                health and health.hp or 0, health and health.max or 0,
                status and status.id or 'unarmed',
                status and status.ammo or 0, status and status.magazine or 0,
                carried,
                (status and status.reloading) and ' reloading' or '',
                game.source, MeatRay.raycaster.getTheme(), Net.mode()), 8, 8)

    if game.host then
        love.graphics.print(('hosting on UDP %d   %d player(s)   %s')
            :format(game.host.port, game.host:playerCount(), game.host.report.reach),
            8, love.graphics.getHeight() - 52)
    elseif game.client then
        love.graphics.print(('client of %s   %d player(s)   snapshots %d   corrections %d')
            :format(game.client.address, game.client:playerCount(),
                    game.client.snapshots, game.client.corrections),
            8, love.graphics.getHeight() - 52)
    end

    for i, line in ipairs(game.log) do
        love.graphics.setColor(1, 1, 1, 1 - (i - 1) * 0.15)
        love.graphics.print(line, 8, 26 + (i - 1) * 14)
    end

    if game.showHelp then
        love.graphics.setColor(1, 1, 1, 0.75)
        love.graphics.print(
            'WASD move  mouse look (yaw+pitch)  Q/E turn  F open door  click fire  L torch\n'
            .. '1 pistol  2 grenade launcher  TAB world  R reseed  T theme  F1 help',
            8, love.graphics.getHeight() - 34)
    end

    -- A crosshair, so firing has somewhere to aim.
    local w, h = love.graphics.getWidth(), love.graphics.getHeight()
    love.graphics.setColor(1, 1, 1, 0.6)
    love.graphics.line(w / 2 - 6, h / 2, w / 2 + 6, h / 2)
    love.graphics.line(w / 2, h / 2 - 6, w / 2, h / 2 + 6)
    love.graphics.setColor(1, 1, 1)
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
    -- A click with the cursor released means "I want to look again", not "fire".
    -- Firing on the same click that recaptures would make every return to the
    -- window cost a round.
    if MeatRay.canRender() and not game.mouseLook then
        setMouseLook(true)
        return
    end

    local player = activePlayer()
    if not player then return end

    if game.client then
        -- The client asks; the host decides. Nothing about the shot is resolved
        -- here, which is why there is no ammo count to correct afterwards.
        game.client:command('fire', { angle = game.aim })
        return
    end

    local shot = resolveFire(activeWorld(), activeEntities(), player, game.aim)
    note(describeShot(shot))

    -- Recoil is reported, not applied: see meatray/game/weapons.lua. The host
    -- takes aim verbatim because aim is an input, so a kick it wrote into
    -- `e.angle` would be overwritten by the next input packet. The owner of the
    -- aim applies it, and here that is this machine.
    if shot.kick then game.aim = normalizeAngle(game.aim + shot.kick) end

    if game.host then game.host:event('hitscan', shot) end
end

function love.keypressed(key)
    if key == 'escape' then
        -- Escape releases the cursor first. Quitting on the same key that a
        -- player presses to get their mouse back is a good way to lose a session
        -- by reflex; a second press then exits.
        if game.mouseLook then
            setMouseLook(false)
            note('mouse released - click to look again')
            return
        end
        if game.host then game.host:close() end
        if game.client then game.client:leave() end
        love.event.quit()
    end

    if key == 'f1' then game.showHelp = not game.showHelp end

    -- Weapon switching goes through the BAG: `Inventory.equipWeapon` finds the
    -- item whose definition names the weapon and equips that slot, which is also
    -- what wires the new gun's reload to the right ammunition item.
    if key == '1' or key == '2' then
        local player = activePlayer()
        local wanted = (key == '2') and 'launcher' or 'pistol'
        if player then
            if game.client then
                game.client:command('swap', { weapon = wanted })
            elseif Inventory.equipWeapon(player, wanted) then
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
        local world, player = activeWorld(), activePlayer()
        if not world or not player then return end

        if game.client then
            local tx, ty = doorInFront(world, player)
            game.client:command('door', tx and { tx = tx, ty = ty } or nil)
            if not tx then note('no door within reach') end
            return
        end

        local tx, ty = doorInFront(world, player)
        if tx then
            world:toggleDoor(tx, ty)
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
