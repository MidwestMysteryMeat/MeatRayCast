--[[
    MeatRayCast demo.

    Deliberately written against the library API rather than the convenience
    layer, so it doubles as proof that the library path is sufficient on its own.

        love .                                  procedural world, single player
        love . --map arena                      hand-authored map from maps/arena.map
        love . --map tower                      multi-map storeys (F → other map)
        love . --map stacked                    in-world layers (F → storey 2)
        love . --meatgraph                      MeatGraphRay host graphs (MeatEngine MeatGraph kinship)
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
    screenfx = Game.screenfx.new(),  -- C28: layered full-screen tints
    spectator = Game.spectator.new{ killcamTime = 2.5 },  -- D35
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

    -- Always-facing: one bucket, a floating pickup. C16: a crystal is grabbed
    -- on contact and refills pistol ammo — the demo's one live pickup, and the
    -- reason the bag UI and the pickup ticker have something real to show.
    Entity.archetype('crystal', function(e)
        e:add(C.Billboard{ sheet = 'crystal' })
        e:add(C.Health{ hp = 10, max = 10 })
        e.radius = 0.22
        e.pickup = { item = 'ammo.pistol', count = 12, label = 'pistol ammo +12' }
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

-- C27: draw the live particles, billboarded and z-tested against the same
-- buffer sprites and decals use, so a spark behind a wall is occluded. Points
-- are little quads; a tracer is a line between its two projected endpoints.
local function drawParticles(view, zbuffer)
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
-- C16: give every player-touched pickup entity its grant and remove it. The
-- local player gets the ticker line; a remote peer's pickup is silent here
-- (its own client says it) but the grant still lands, host-authoritative.
local function stepPickups(entities)
    for i = 1, #entities do
        local e = entities[i]
        if e and e.pickup and not e.dead then
            for j = 1, #entities do
                local p = entities[j]
                if p and p.components and p.components.player and not p.dead then
                    local dx, dy = (p.x or 0) - (e.x or 0), (p.y or 0) - (e.y or 0)
                    local reach = (p.radius or 0.24) + (e.radius or 0.22) + 0.1
                    if dx * dx + dy * dy <= reach * reach then
                        local grant = e.pickup
                        Inventory.add(p, grant.item, grant.count or 1)
                        e.dead = true          -- reaped like any dead entity
                        if p == game.player then
                            game.messages:pickup(grant.label
                                or ('picked up ' .. tostring(grant.item)))
                            -- C28: a quick green blip confirms the grab.
                            game.screenfx:flash({ 0.4, 0.9, 0.5 },
                                { peak = 0.22, inTime = 0.02, out = 0.35 })
                        end
                        break
                    end
                end
            end
        end
    end
end

-- snapQuarter is defined with updateAim below, but applyTemplate calls it — so
-- it is forward-declared, the same guard startHost/startClient use, because a
-- bare reference would resolve to a nil global (the trap c5be3fa fixed).
local snapQuarter

-- Templates: reconfigure the running demo into a genre. Movement speeds and
-- style come straight from the resolved config; the loadout re-equips the
-- player; the mode string picks a stock ruleset. A scaffold template still
-- applies its config and says out loud what it cannot provide.
local function applyTemplate(name)
    local cfg, why = Game.template.resolve(name)
    if not cfg then return false, why end

    game.template = cfg
    game.moveSpeed = cfg.moveSpeed or game.moveSpeed
    game.turnSpeed = cfg.turnSpeed or game.turnSpeed
    game.gridMove = (cfg.movement == 'grid')
    -- Entering grid movement, snap the current facing to a cardinal so the
    -- first quarter-turn lands square.
    if game.gridMove then game.aim = snapQuarter(game.aim) end

    -- Re-equip the local player to the template's loadout.
    local player = game.player
    if player and player.components and player.components.inventory then
        Inventory.attach(player, { capacity = 8 })   -- clears the bag
        for _, item in ipairs(cfg.loadout or {}) do
            Inventory.add(player, item.item, item.count or 1)
        end
        -- Equip the first weapon in the loadout, if any.
        for _, item in ipairs(cfg.loadout or {}) do
            local def = Inventory.itemDef and Inventory.itemDef(item.item)
            if def and def.weapon then
                Inventory.equipWeapon(player, item.item)
                break
            end
        end
        -- RPG stats: grant the exploration attributes a stat system reads.
        if cfg.rpgStats then
            Game.attributes.grantAll(player, {
                healthMax = 100, health = 100,
                staminaMax = 100, stamina = 100,
                manaMax = 50, mana = 50,
            })
        end
    end

    note(('template: %s (%s, %s combat, %s movement)'):format(
        cfg.name or name, cfg.mode, cfg.combat, cfg.movement))
    if cfg.ready == 'scaffold' and cfg.needs then
        note('scaffold — you still need: ' .. table.concat(cfg.needs, ', '))
    end
    return true
end

-- C22: spawn a computer player. It is an ordinary 'player' entity — so it
-- replicates, takes damage, respawns and appears in the killfeed exactly like
-- a human — paired with a Bot brain that produces its input each tick.
local botSeq = 0
local function spawnBot()
    local world = game.world
    if not world then return nil end
    local spawn = world.spawn or { x = 4.5, y = 4.5 }
    local e = Entity.spawn('player', spawn.x + botSeq * 0.6, spawn.y)
    if not e then return nil end
    e.isBot = true
    if world then Collide.ground(e, world) end
    e:snapPrevious()
    table.insert(game.entities, e)
    botSeq = botSeq + 1
    local brain = Game.bot.new{ seed = 1000 + botSeq, fireRange = 8 }
    game.bots[#game.bots + 1] = { entity = e, brain = brain }
    return e
end

-- C22: drive every live bot. Each produces input the host feeds through the
-- same applyInput a human's does, then acts on its fire and use intents — the
-- bot plays the game rather than the game moving it.
local function stepBots(step, world, entities)
    for i = #game.bots, 1, -1 do
        local b = game.bots[i]
        local e = b.entity
        if not e or e.dead then
            -- A dead bot is reaped with everything else; drop the brain too.
            table.remove(game.bots, i)
        else
            local intent = b.brain:think(e, world, entities, step)
            Rep.applyInput(e, Rep.sanitiseInput(intent.input), step, world,
                           { moveSpeed = game.moveSpeed, turnSpeed = game.turnSpeed })
            if intent.use and intent.useDoor then
                world:setDoorOpen(intent.useDoor.tx, intent.useDoor.ty, true)
            end
            if intent.fire then
                Game.respawn.dropProtection(e)
                local shot = resolveFire(world, entities, e, intent.input.angle)
                if shot and shot.killed then
                    game.messages:kill('a bot',
                        tostring(shot.targetKind or 'enemy'), shot.weapon)
                end
            end
        end
    end
end

local function stepRules(step, world, entities)
    if not world or not entities then return end

    Game.tickAll(entities, step)

    -- C22: bots think and act before the rest of the rules, so their shots and
    -- door-opens land this tick like a human's input already has.
    if #game.bots > 0 then stepBots(step, world, entities) end

    -- F5: floors that hurt. Host authority, both loops — the bite goes
    -- through the same damage path as everything else, so armour, fire
    -- resistance and god mode all have their usual say.
    if game.hazards then
        game.hazards:update(entities, step)
    end

    -- C16: on-contact pickups. Host authority (solo is its own host). An
    -- entity carrying a `pickup` grant that a living player touches is added
    -- to the bag and removed from the world, with a ticker line to say so.
    stepPickups(entities)

    -- Secret discovery is a rule, so it runs wherever the rules run — the
    -- solo loop and the hosted loop both come through here.
    if game.secretTracker and game.secretWorld == world then
        game.secretTracker:update(entities)
    end

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
            -- C27: an explosion throws debris and smoke (air bursts, no normal).
            if game.particles then
                game.particles:burst('debris', impact.explosion.x,
                                     impact.explosion.y, { z = 0.4, scale = 1.5 })
                game.particles:burst('smoke', impact.explosion.x,
                                     impact.explosion.y, { z = 0.6, scale = 1.5 })
            end
            if game.host then
                game.host:event('boom', { x = impact.explosion.x, y = impact.explosion.y,
                                          radius = impact.explosion.radius, hits = hits })
            end
            -- Host-local player learns direction here, and only when the blast
            -- actually reached them; clients learn it from the boom event.
            if game.player then
                for h = 1, hits do
                    if impact.explosion.hits[h].entity == game.player then
                        game.hud:damageFrom(impact.explosion.x, impact.explosion.y,
                                            game.player.x, game.player.y,
                                            game.player.angle)
                        -- D35: remember where it came from, for the killcam.
                        game.lastHurtX, game.lastHurtY =
                            impact.explosion.x, impact.explosion.y
                        break
                    end
                end
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

-- F2/F5: everything that adopts a fresh world. The automap starts blank and
-- re-looks on shape changes; the hazard kit picks up whatever boxes the map
-- headers declared (nil when there are none, so the tick can skip it).
local function adoptWorldForAutomap(world)
    game.automap:reset()
    game.automapDirty = false
    game.bots = {}          -- C22: old-world bot entities are stale on reload
    world:watchShape(function() game.automapDirty = true end)

    game.hazards = nil
    if world.hazards and #world.hazards > 0 then
        game.hazards = Game.hazards.new()
        game.hazards:fromWorld(world)
    end
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
    adoptWorldForAutomap(world)

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

-- opts.arrival = { x, y, angle } from a storey link overrides map spawn.
local function loadAuthored(path, opts)
    opts = opts or {}
    path = path or 'maps/arena.map'

    local contents = love.filesystem.read(path)
    if not contents then
        -- Relative path without maps/ prefix.
        if not path:match('^maps/') and not path:match('%.map$') then
            return loadAuthored('maps/' .. path .. '.map', opts)
        end
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
    adoptWorldForAutomap(world)
    game.worldSpec = nil          -- an authored map is sent as a grid, not a seed
    game.mapPath = path
    game.mapLinks = map.links
    setTheme(map.theme)

    -- Secret areas the map declared. Discovery notes itself and keeps the
    -- running count for the intermission stat (F4, when it lands).
    game.secretTracker = nil
    game.secretWorld = nil
    if world.secrets and #world.secrets > 0 then
        game.secretTracker = Game.secrets.new{
            onFound = function(area)
                if game.campaign and game.campaign.state == 'mission' then
                    game.campaign:addSecret(1)
                end
                game.messages:pickup(('secret found%s — %d/%d')
                    :format(area.name and (': ' .. area.name) or '',
                            game.secretTracker:found(), game.secretTracker:total()))
            end,
        }
        game.secretTracker:fromWorld(world)
        game.secretWorld = world
    end

    spawn = spawn or { x = 2.5, y = 2.5, angle = 0 }
    local sx, sy, sa = spawn.x, spawn.y, spawn.angle or 0
    if opts.arrival and opts.arrival.x and opts.arrival.y then
        sx, sy = opts.arrival.x, opts.arrival.y
        sa = opts.arrival.angle or sa
    end
    spawnPlayerAt(sx, sy, sa)

    for _, m in ipairs(markers) do
        if Entity.hasArchetype(m.kind) then
            local e = Entity.spawn(m.kind, m.x, m.y)
            e.angle = m.angle or 0
            e.storey = m.storey or 1
            Collide.ground(e, world)
            e:snapPrevious()
            table.insert(game.entities, e)
        else
            note('map references unknown archetype: ' .. tostring(m.kind))
        end
    end

    game.source = 'authored'
    local n = world.storeyCount and world:storeyCount() or 1
    local linkHint = ''
    if n > 1 then
        linkHint = ('  (%d storeys — F on stairs)'):format(n)
    elseif map.links and (map.links.up or map.links.down) then
        linkHint = '  (F on stairs to change map)'
    end
    note(('authored map "%s", theme %s, %d markers%s'):format(
        map.name, map.theme, #markers, linkHint))
end

local function resolveMapPath(path)
    if not path or path == '' then return nil end
    if path:match('%.map$') then
        if path:find('/') or path:find('\\') then return path end
        return 'maps/' .. path
    end
    if path:match('^maps/') then return path .. '.map' end
    return 'maps/' .. path .. '.map'
end

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

-- What the HUD model watches each frame. The flash comes from deltas in these
-- numbers, so this works identically for a host and for a client whose hp
-- arrives in snapshots — see meatray/game/hud.lua.
local function hudState(player)
    if not player then return {} end
    local health = player:get('health')
    local status = Weapons.status(player)
    local carried = status and Inventory.count(player,
        status.id == 'launcher' and 'ammo.grenade' or 'ammo.pistol') or nil
    return {
        hp = health and health.hp, hpMax = health and health.max,
        weapon = status, carried = carried,
    }
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
-- the same stream back into a world rebuilt from the same seed. Everything
-- else about the run — spread, AI, gas, respawn — is already deterministic,
-- which is the engine promise the demo format banks on.
---------------------------------------------------------------------------

-- A player action outside the movement stream, noted while recording. The
-- queue flushes into the recorder on the next simulate tick — the same tick
-- boundary playback applies it at, and nothing mutates the world between
-- ticks, so the two runs see identical state.
local function demoEvent(name, params)
    if not game.demoRec then return end
    game.demoEvents[#game.demoEvents + 1] = { name = name, params = params }
end

-- Replays one recorded action through the same code paths the live keys use.
local function applyDemoEvent(ev)
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

local DEMO_FILE = 'last.demo'

-- Both ends of a demo rebuild the level from nothing — same seed, same map,
-- and the entity id counter back to 1, because ids are part of the checksum
-- and a counter that kept counting would make every replay 'diverge' at tick
-- zero for no interesting reason.
local function reloadForDemo()
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

local function startDemoRecord()
    if game.host or game.client then
        return note('demos record the solo loop — leave the session first')
    end
    reloadForDemo()
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

local function stopDemoRecord()
    local text = game.demoRec:finish(game.demoTick - 1)
    game.demoRec = nil
    local ok, err = game.storage.write(DEMO_FILE, text)
    if ok then
        note(('demo saved: %s (%d ticks)'):format(DEMO_FILE, game.demoTick))
    else
        note('demo save failed: ' .. tostring(err))
    end
end

local function startDemoPlayback()
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
    reloadForDemo()
    game.demoPlay = play
    game.demoTick = 0
    game.demoDiverged = nil
    note(('playing %d ticks — F7 to stop'):format(play:length()))
end

---------------------------------------------------------------------------
-- F4: the demo campaign. Three missions over the maps that ship: cross the
-- arena, find the vault in the secrets map (its exit is INSIDE the secret —
-- finding it is finishing), then clear the arena. Between missions the
-- intermission model rolls the numbers up; fire hurries, fire continues.
---------------------------------------------------------------------------

local function startCampaign()
    game.campaign = Game.campaign.new{
        id = 'demo',
        title = 'Meat Run',
        missions = {
            { id = 'arena', map = 'maps/arena.map', name = 'The Arena',
              exitTiles = { tx1 = 19, ty1 = 16, tx2 = 20, ty2 = 17 },
              parTime = 90, intermission = 3600, loseOnPlayerDeath = false },
            { id = 'secrets', map = 'maps/secrets.map', name = 'The Vault',
              exitTiles = { tx1 = 3, ty1 = 10, tx2 = 4, ty2 = 10 },
              parTime = 60, intermission = 3600, loseOnPlayerDeath = false },
            { id = 'finale', map = 'maps/arena.map', name = 'Clear It Out',
              winWhenAllDead = true,
              parTime = 180, intermission = 3600, loseOnPlayerDeath = false },
        },
        getPlayer = function() return activePlayer() end,
        onLoadMap = function(_, path)
            loadAuthored(path)
        end,
        onMissionStart = function(camp, mission)
            -- The kill denominator: how many brains the map woke up with.
            local total = 0
            for _, e in ipairs(game.entities) do
                if e.components and e.components.brain then total = total + 1 end
            end
            game.campaignKillTotal = total
            game.campaignTriggers = camp:makeTriggers()
            -- F6: the mission name is a moment, not a log line.
            game.messages:centerprint(mission.name or mission.id,
                                      { size = 'big', hold = 2.5, priority = 3 })
        end,
        onMissionEnd = function(camp, mission, result)
            local secretsFound, secretsTotal = 0, 0
            if game.secretTracker then
                secretsFound = game.secretTracker:found()
                secretsTotal = game.secretTracker:total()
            end
            game.intermission:begin{
                title = mission.name or mission.id,
                result = result.outcome,
                next_ = camp.missions[result.index + 1]
                        and (camp.missions[result.index + 1].name
                             or camp.missions[result.index + 1].id) or nil,
                stats = {
                    elapsed = result.stats.elapsed,
                    parTime = result.stats.parTime,
                    kills = result.stats.kills,
                    killsTotal = game.campaignKillTotal,
                    secrets = secretsFound,
                    secretsTotal = secretsTotal,
                    coverage = game.automap:coverage(game.world),
                    deaths = result.stats.deaths,
                },
            }
        end,
        onCampaignWin = function(camp)
            game.campaignDone = true
            game.intermission:begin{
                title = 'campaign complete',
                result = 'win',
                stats = {
                    elapsed = camp.totals.elapsed,
                    kills = camp.totals.kills,
                    secrets = camp.totals.secrets,
                    deaths = camp.totals.deaths,
                },
            }
        end,
    }
    game.campaignDone = false
    game.campaign:start()
end

---------------------------------------------------------------------------
-- G1: the shell's screens and what its rows DO. The menu model proposes
-- (navigation, capture, value cycling); this is where proposals land.
--
-- startHost/startClient are defined in the networking section BELOW, so they
-- are forward-declared here — a bare reference would silently resolve to a
-- nil global at runtime, the trap c5be3fa fixed for tryStoreyLink.
---------------------------------------------------------------------------

local startHost, startClient

local function shellOpen()
    if game.shell:isOpen() then return end
    game.shell:push{
        id = 'title', title = 'MEATRAYCAST',
        rows = {
            { id = 'continue', label = 'Continue', kind = 'action' },
            { id = 'campaign', label = 'New Campaign', kind = 'action' },
            { id = 'roam', label = 'Free Roam (new seed)', kind = 'action' },
            { id = 'templates', label = 'Genre Templates', kind = 'action' },
            { id = 'join', label = 'Join Game', kind = 'action' },
            { id = 'host', label = 'Host Game', kind = 'action' },
            { id = 'options', label = 'Options', kind = 'action' },
            { id = 'quit', label = 'Quit', kind = 'action' },
        },
    }
    game.session:openMenu('menu')
    if MeatRay.canRender() then setMouseLook(false) end
end

local function shellClose()
    game.shell:close()
    game.session:closeMenu()
    -- Anything the options screen changed is applied live; the file is
    -- written once here, and only if something is actually dirty.
    game.options:applyGraphics()
    game.options:applyAudio()
    game.sensitivity = game.options:getMouse().sensitivity or game.sensitivity
    if game.options.dirty then game.options:save(game.storage) end
end

-- One row activated (or one captured value landed). The menu proposed; this
-- disposes.
local function shellApply(result)
    if not result then return end
    local screen = result.screen

    if result.kind == 'set' or result.kind == 'submit' then
        if screen == 'options' then
            -- F8: accessibility rows (a11y.*) route to the a11y model; the
            -- rest to options. One Options screen, two backing models.
            if tostring(result.row.id):sub(1, 5) == 'a11y.' then
                game.a11y:menuSet(result.row.id, result.value)
                game.a11y:save(game.storage)
            else
                game.options:menuSet(result.row.id, result.value)
                game.options:applyGraphics()
                game.options:applyAudio()
            end
            -- Refresh the rows so the screen shows what was actually accepted
            -- (clamps, custom-quality rederivation, bind lists, a11y clamps).
            local fresh = game.options:menuRows()
            for _, ar in ipairs(game.a11y:menuRows()) do fresh[#fresh + 1] = ar end
            local rows = game.shell:current().rows
            for i = 1, #rows do
                if fresh[i] and rows[i].id == fresh[i].id then
                    rows[i].value = fresh[i].value
                end
            end
        elseif screen == 'join' and result.kind == 'submit' then
            local addr = result.value
            if addr ~= '' then
                shellClose()
                startClient(addr, { name = 'player' })
            end
        end
        return
    end

    if result.kind ~= 'action' then return end
    local id = result.row.id

    if id == 'continue' then
        shellClose()
    elseif id == 'campaign' then
        shellClose()
        startCampaign()
    elseif id == 'roam' then
        shellClose()
        game.seed = game.seed + 1
        game.session:restart('solo')
        loadProcedural()
    elseif id == 'templates' then
        -- A screen of every genre; picking one starts a fresh world and
        -- applies the template to it.
        local rows = {}
        for _, name in ipairs(Game.template.list()) do
            local cfg = Game.template.resolve(name)
            rows[#rows + 1] = {
                id = 'template.' .. name,
                label = ('%s  (%s)'):format(cfg.name or name,
                    cfg.ready == 'playable' and 'playable' or 'scaffold'),
                kind = 'action',
            }
        end
        game.shell:push{ id = 'templates', title = 'GENRE TEMPLATES', rows = rows }
    elseif id:sub(1, 9) == 'template.' then
        shellClose()
        game.seed = game.seed + 1
        game.session:restart('solo')
        loadProcedural()
        applyTemplate(id:sub(10))
    elseif id == 'join' then
        game.shell:push{
            id = 'join', title = 'JOIN GAME',
            rows = {
                { id = 'addr', label = 'Address', kind = 'text',
                  value = '127.0.0.1:6789' },
            },
        }
    elseif id == 'host' then
        shellClose()
        startHost{ mode = 'listen', name = 'MeatRayCast', port = 6789 }
        note('hosting on UDP 6789')
    elseif id == 'options' then
        -- F8: the options screen carries graphics/audio/binds AND the
        -- accessibility rows, so they persist and apply the same way.
        local rows = game.options:menuRows()
        for _, ar in ipairs(game.a11y:menuRows()) do rows[#rows + 1] = ar end
        game.shell:push{ id = 'options', title = 'OPTIONS', rows = rows }
    elseif id == 'quit' then
        game.session:quit('left the game')
        if game.host then game.host:close() end
        if game.client then game.client:leave() end
        love.event.quit()
    end
end

-- Fire / F while the tally is up: the first press hurries, the second
-- continues. Returns true when the press belonged to the screen.
local function confirmIntermission()
    if not game.intermission:active() then return false end
    local what = game.intermission:confirm()
    if what == 'continued' then
        if game.campaignDone then
            game.campaign = nil
            game.campaignTriggers = nil
            game.campaignDone = false
            note('campaign over — sandbox resumes')
        elseif game.campaign then
            game.campaign:advance()
        end
        game.intermission:reset()
    end
    return true
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

function startHost(opts)
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
            stepRespawn(dt)
        end,
        onCommand  = hostCommand,
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
            onMap = function(name)
                if name == 'procedural' then loadProcedural()
                else loadAuthored('maps/' .. name .. '.map') end
                host:syncWorld()
            end,
        }
        note('RCON enabled')
    end

    -- F7: voting is on for any hosted game. A passed map/restart reloads the
    -- world; a passed kick the host handles itself. Vote state is announced to
    -- everyone through the message centerprint (see the client onVote below
    -- and the host's own broadcast).
    host:attachVote{
        duration = 30, threshold = 0.5,
        onMap = function(name)
            if name == 'procedural' then loadProcedural()
            else loadAuthored('maps/' .. name .. '.map') end
            host:syncWorld()
        end,
        onRestart = function()
            if game.source == 'authored' and game.mapPath then
                loadAuthored(game.mapPath)
            else
                loadProcedural()
            end
        end,
    }

    return host
end

function startClient(address, opts)
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
        elseif a == '--meatgraph' then args.meatgraph = value(i, 'meatgraphs/demo.graph.json')
        -- Older flag names kept as synonyms so scripts do not break overnight.
        elseif a == '--graph' then args.meatgraph = value(i, 'meatgraphs/demo.graph.json')
        elseif a == '--blueprint' then args.meatgraph = value(i, 'meatgraphs/demo.graph.json')
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

    -- F3: the console. Cheats are gated on a QUESTION answered at execute
    -- time — the same process moves between solo, hosting and joining, and
    -- god must stop working the moment the world stops being yours. A
    -- running demo also refuses cheats: a 'give' mid-recording forks the
    -- timeline the divergence check exists to protect.
    game.console = Game.console.new{
        allowCheats = function()
            if game.client then return false, 'cheats are for your own world' end
            if game.demoRec or game.demoPlay then
                return false, 'cheats would fork the demo'
            end
            return true
        end,
    }
    game.console:defineCvar('noclip', {
        default = false, cheat = true, help = 'walk through walls',
        onChange = function(_, v) game.noclip = v end,
    })
    game.console:register('god', {
        cheat = true, help = 'god — toggle damage immunity',
    }, function()
        local player = activePlayer()
        if not player then return 'no player' end
        if Game.effects.hasTag(player, 'status.god') then
            Game.effects.removeById(player, 'god')
            return 'god off'
        end
        local okG, why = Game.effects.applySpec(player, {
            id = 'god', duration = 1e9,
            grantedTags = { 'status.god' }, immunityTags = { 'damage' },
        })
        return okG and 'god on' or ('god failed: ' .. tostring(why))
    end)
    game.console:register('give', {
        cheat = true, help = 'give <item> [count]',
    }, function(_, cargs)
        local player = activePlayer()
        if not player then return 'no player' end
        if not cargs[1] then return 'give what?' end
        local n = tonumber(cargs[2]) or 1
        local okGive, why = Inventory.add(player, cargs[1], n)
        if not okGive then return 'refused: ' .. tostring(why) end
        return ('gave %d %s'):format(n, cargs[1])
    end)
    game.console:register('map', {
        cheat = true, help = 'map <name|procedural> [seed] — load a level',
    }, function(_, cargs)
        local which = cargs[1]
        if not which then return 'map what? (a maps/ name, or procedural)' end
        if which == 'procedural' or which == 'proc' then
            game.seed = tonumber(cargs[2]) or (game.seed + 1)
            loadProcedural()
            return 'procedural, seed ' .. game.seed
        end
        loadAuthored('maps/' .. which .. '.map')
        return 'loaded ' .. which
    end)
    game.console:register('bot', {
        cheat = true, help = 'bot [n] — add n computer players (default 1)',
    }, function(_, cargs)
        local n = math.max(1, math.min(16, math.floor(tonumber(cargs[1]) or 1)))
        local added = 0
        for _ = 1, n do if spawnBot() then added = added + 1 end end
        game.messages:notify(('%d bot(s) joined'):format(added))
        return ('added %d bot(s), %d total'):format(added, #game.bots)
    end)
    game.console:register('template', {
        cheat = true,
        help = 'template [name] — list genres, or switch the demo to one',
    }, function(_, cargs)
        if not cargs[1] then
            local lines = { 'templates:' }
            for _, n in ipairs(Game.template.list()) do
                lines[#lines + 1] = '  ' .. Game.template.summary(n)
            end
            return lines
        end
        local ok, why = applyTemplate(cargs[1])
        return ok and ('switched to ' .. cargs[1]) or ('cannot: ' .. tostring(why))
    end)
    game.console:register('callvote', {
        help = 'callvote restart | map <name> | kick <peerId>',
    }, function(_, cargs)
        local kind = cargs[1]
        if not kind then return 'callvote restart | map <name> | kick <peerId>' end
        if game.client then
            game.client:callVote(kind, { map = cargs[2],
                                         target = tonumber(cargs[2]) })
            return 'vote called'
        elseif game.host and game.host.vote then
            -- A listen host votes as peer 0.
            local electorate = { 0 }
            for _, p in pairs(game.host.peers) do
                if p.joined then electorate[#electorate + 1] = p.peerId end
            end
            local ok, why = game.host.vote:call(kind,
                { by = 0, map = cargs[2], target = tonumber(cargs[2]) }, electorate)
            return ok and 'vote called' or ('cannot: ' .. tostring(why))
        end
        return 'voting needs a hosted or joined game'
    end)
    game.console:register('vote', {
        help = 'vote yes | no — answer the current vote',
    }, function(_, cargs)
        local yes = (cargs[1] == 'yes' or cargs[1] == 'y' or cargs[1] == '1')
        if game.client then game.client:castVote(yes)
        elseif game.host and game.host.vote then game.host.vote:cast(0, yes)
        else return 'no vote to answer' end
        return 'ballot cast'
    end)
    game.console:register('campaign', {
        cheat = true, help = 'campaign — start the three-mission demo campaign',
    }, function()
        startCampaign()
        return 'campaign started — reach the exit'
    end)
    game.console:register('stat', {
        help = 'stat net — connection and replication numbers',
    }, function(_, cargs)
        if cargs[1] ~= 'net' then return 'stat what? (net)' end
        if game.host then
            local h = game.host
            return {
                ('hosting on UDP %d — %d player(s)'):format(h.port, h:playerCount()),
                ('reach: %s'):format(tostring(h.report and h.report.reach)),
            }
        elseif game.client then
            local c = game.client
            return {
                ('client of %s (%s)'):format(c.address, c.state),
                ('snapshots %d, corrections %d'):format(c.snapshots, c.corrections),
            }
        end
        return 'solo: no network'
    end)
    game.console:register('quit', { help = 'quit — leave' }, function()
        love.event.quit()
        return 'bye'
    end)

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
        if args.map then loadAuthored('maps/' .. args.map .. '.map') else loadProcedural() end
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
        -- refuses to pause them in the first place.
        game.alpha = game.clock:advance(game.session:simDelta(dt), simulate)
    end
end

---------------------------------------------------------------------------
-- A7: the render-scale pass.
--
-- At scale 1 these two are almost nothing: the world draws straight to the
-- window, exactly as it did before options existed. Below 1 they route it
-- through a canvas the size `options:renderSize` asked for, and the renderer
-- is told that smaller size so its column loop and its z-buffer are the ones
-- the buffer actually has. The upscale is nearest-neighbour on purpose —
-- smoothing a software raycaster's output is how a deliberate low-res look
-- turns into a smeared one.
---------------------------------------------------------------------------

local function beginWorldPass()
    local scale = game.options and game.options:getGraphics().scale or 1
    local w, h = love.graphics.getWidth(), love.graphics.getHeight()
    if scale >= 1 then
        -- Still make sure the renderer agrees with the window, in case the
        -- previous frame was scaled and this one is not.
        MeatRay.raycaster.resize(w, h)
        return nil
    end

    local cw, ch = game.options:renderSize(w, h)
    local canvas = game.scaleCanvas
    if not canvas or game.scaleCanvasW ~= cw or game.scaleCanvasH ~= ch then
        canvas = love.graphics.newCanvas(cw, ch)
        canvas:setFilter('nearest', 'nearest')
        game.scaleCanvas, game.scaleCanvasW, game.scaleCanvasH = canvas, cw, ch
    end

    MeatRay.raycaster.resize(cw, ch)
    love.graphics.setCanvas(canvas)
    love.graphics.clear(0, 0, 0, 1)
    return { canvas = canvas, w = w, h = h, cw = cw, ch = ch }
end

local function endWorldPass(target)
    if not target then return end
    love.graphics.setCanvas()
    love.graphics.setColor(1, 1, 1)
    love.graphics.draw(target.canvas, 0, 0, 0,
                       target.w / target.cw, target.h / target.ch)
    -- The HUD that follows measures itself against the window, so put the
    -- renderer back before anything else asks how big the screen is.
    MeatRay.raycaster.resize(target.w, target.h)
end

-- G1: the shell drawn. One column of rows, a cursor, and per-kind value
-- text; the whole point of the model split is that this function is the only
-- place any of that becomes pixels.
local function drawShell()
    if not game.shell:isOpen() then return end
    local w, h = love.graphics.getWidth(), love.graphics.getHeight()
    local screen = game.shell:current()
    local lineH = love.graphics.getFont():getHeight() + 10

    love.graphics.setColor(0, 0, 0, 0.82)
    love.graphics.rectangle('fill', 0, 0, w, h)
    love.graphics.setColor(0.95, 0.85, 0.40)
    love.graphics.printf(screen.title or screen.id, 0, h * 0.14, w, 'center')

    local rows = screen.rows
    local top = h * 0.26
    -- Long screens (options) scroll around the cursor.
    local visible = math.floor((h * 0.62) / lineH)
    local first = 1
    if #rows > visible then
        first = math.max(1, math.min(screen.selected - math.floor(visible / 2),
                                     #rows - visible + 1))
    end

    for i = first, math.min(#rows, first + visible - 1) do
        local row = rows[i]
        local y = top + (i - first) * lineH
        local isSel = (i == screen.selected)

        love.graphics.setColor(isSel and 1 or 0.62, isSel and 1 or 0.62,
                               isSel and 0.75 or 0.65)
        love.graphics.printf((isSel and '> ' or '  ') .. row.label,
                             w * 0.22, y, w * 0.34, 'left')

        local value
        if row.kind == 'toggle' then
            value = row.value and 'on' or 'off'
        elseif row.kind == 'slider' then
            value = ('%.2f'):format(tonumber(row.value) or 0)
        elseif row.kind == 'choice' then
            value = tostring(row.value)
        elseif row.kind == 'bind' then
            local keys = row.value
            value = type(keys) == 'table' and table.concat(keys, ', ')
                    or tostring(keys or '')
            if isSel and game.shell:capturing() == 'bind' then
                value = 'press a key...'
            end
        elseif row.kind == 'text' then
            value = tostring(row.value or '')
            if isSel and game.shell:capturing() == 'text' then
                value = value .. '_'
            end
        end
        if value then
            love.graphics.printf(value, w * 0.56, y, w * 0.24, 'right')
        end
    end

    love.graphics.setColor(0.5, 0.5, 0.55)
    love.graphics.printf(
        'arrows move   left/right adjust   enter select   esc back',
        0, h * 0.9, w, 'center')
    love.graphics.setColor(1, 1, 1)
end

-- F4: the tally between missions. Full-frame, over the world and the HUD;
-- only the console outranks it.
local function drawIntermission()
    if not game.intermission:active() then return end
    local w, h = love.graphics.getWidth(), love.graphics.getHeight()
    love.graphics.setColor(0, 0, 0, 0.78)
    love.graphics.rectangle('fill', 0, 0, w, h)

    local head = game.intermission:header()
    love.graphics.setColor(0.95, 0.85, 0.40)
    love.graphics.printf(head.title or '', 0, h * 0.22, w, 'center')

    local y = h * 0.32
    for _, row in ipairs(game.intermission:rows()) do
        love.graphics.setColor(0.65, 0.65, 0.68)
        love.graphics.printf(row.label, w * 0.28, y, w * 0.18, 'left')
        love.graphics.setColor(row.done and 1 or 0.8, row.done and 1 or 0.8, 0.85)
        love.graphics.printf(row.text, w * 0.48, y, w * 0.24, 'right')
        y = y + love.graphics.getFont():getHeight() + 8
    end

    if head.prompt then
        love.graphics.setColor(0.55, 0.90, 0.55)
        love.graphics.printf('fire — ' .. head.prompt, 0, h * 0.72, w, 'center')
    end
    love.graphics.setColor(1, 1, 1)
end

-- C16: the bag as a grid overlay. Cells and their positions come from
-- meatray.ui.inventory_view (grid + slots), tested; this blits them.
local InventoryView = require('meatray.ui.inventory_view')
local function drawBag(w, h)
    if not game.showBag then return end
    local player = activePlayer()
    if not player then return end
    local slots = InventoryView.slots(player)
    if #slots == 0 then return end

    local grid = InventoryView.grid(#slots, { cols = 4, cell = 46, pad = 6 })
    local ox = (w - grid.width) / 2
    local oy = (h - grid.height) / 2

    love.graphics.setColor(0, 0, 0, 0.72)
    love.graphics.rectangle('fill', ox - 16, oy - 34, grid.width + 32, grid.height + 50)
    love.graphics.setColor(0.9, 0.85, 0.5)
    love.graphics.print('BAG', ox, oy - 28)

    for _, cell in ipairs(grid.cells) do
        local slot = slots[cell.index]
        local x, y = ox + cell.x, oy + cell.y
        local sz = grid.cellSize

        -- The cell: brighter when it holds something, ringed when equipped.
        love.graphics.setColor(0.14, 0.15, 0.18, 0.95)
        love.graphics.rectangle('fill', x, y, sz, sz)
        if slot.equipped then
            love.graphics.setColor(0.95, 0.85, 0.35)
            love.graphics.rectangle('line', x, y, sz, sz)
        elseif not slot.empty then
            love.graphics.setColor(0.4, 0.42, 0.48)
            love.graphics.rectangle('line', x, y, sz, sz)
        end

        if not slot.empty then
            love.graphics.setColor(slot.over and 1 or 0.85,
                                   slot.over and 0.5 or 0.9, 0.85)
            love.graphics.printf(tostring(slot.name):sub(1, 8), x + 2, y + 4, sz - 4, 'center')
            love.graphics.setColor(1, 1, 1)
            love.graphics.printf(slot.countText, x + 2, y + sz - 16, sz - 4, 'center')
            -- Stack fill bar along the bottom edge.
            if slot.stack > 1 then
                love.graphics.setColor(0.35, 0.7, 0.4, 0.8)
                love.graphics.rectangle('fill', x + 2, y + sz - 3, (sz - 4) * slot.fill, 2)
            end
        end
    end
    love.graphics.setColor(1, 1, 1)
end

-- C28: the screen-effect layers, blitted full-frame. A fill is a flat rect; a
-- vignette darkens only the edges. Drawn under the HUD so the numbers stay
-- legible through a tint, over the world so the tint actually reads.
local function drawScreenFX(w, h)
    for _, layer in ipairs(game.screenfx:layers()) do
        -- F8: photosensitivity — every full-screen effect's alpha runs through
        -- the accessibility flash scale, and its colour through the colourblind
        -- remap, so a player who dimmed flashes or set a colourblind mode sees
        -- the adjusted version.
        local c = game.a11y:colorTable(layer.color)
        local alpha = game.a11y:flash(layer.alpha)
        if layer.style == 'vignette' then
            -- Four edge bands, heavier than a fill would be, so the centre
            -- stays clear — the shape a damage/underwater edge wants.
            local edge = math.floor(math.min(w, h) * 0.18)
            love.graphics.setColor(c[1], c[2], c[3], alpha)
            love.graphics.rectangle('fill', 0, 0, w, edge)
            love.graphics.rectangle('fill', 0, h - edge, w, edge)
            love.graphics.rectangle('fill', 0, edge, edge, h - edge * 2)
            love.graphics.rectangle('fill', w - edge, edge, edge, h - edge * 2)
        else
            love.graphics.setColor(c[1], c[2], c[3], alpha)
            love.graphics.rectangle('fill', 0, 0, w, h)
        end
    end
    love.graphics.setColor(1, 1, 1)
end

-- F6: the three message channels. Killfeed top-right, ticker bottom-left
-- above the HUD, centerprint dead centre. Every string and fade comes from
-- meatray.game.messages; this is the only place any of it becomes pixels.
local function drawMessages(w, h)
    local msg = game.messages

    -- Killfeed, top-right, newest at the top.
    local ky = 30
    for _, k in ipairs(msg:killfeed()) do
        local line = k.attacker and ('%s  »  %s'):format(k.attacker, k.victim)
                     or ('%s died'):format(k.victim)
        if k.cause then line = line .. ('  [%s]'):format(k.cause) end
        love.graphics.setColor(0.9, 0.85, 0.8, k.alpha)
        love.graphics.printf(line, 0, ky, w - 12, 'right')
        ky = ky + 16
    end

    -- Ticker, bottom-left, above where the HUD bars sit.
    local ticker = msg:ticker()
    local ty = h - 104
    for i = #ticker, 1, -1 do
        local row = ticker[i]
        local c = row.kind == 'pickup' and { 0.7, 0.95, 0.7 } or { 0.85, 0.85, 0.95 }
        love.graphics.setColor(c[1], c[2], c[3], row.alpha)
        love.graphics.print(row.text, 12, ty)
        ty = ty - 15
    end

    -- Centerprint, dead centre, exclusive.
    local c = msg:centered()
    if c then
        love.graphics.setColor(1, 0.95, 0.6, c.alpha)
        local oy = c.size == 'big' and -8 or 0
        love.graphics.printf(c.text, 0, h * 0.34 + oy, w, 'center')
    end
    love.graphics.setColor(1, 1, 1)
end

-- F3: the console overlay. Drawn last, over everything — a console that can
-- be covered by a death screen is a console you cannot debug the death with.
-- (Defined before love.draw on purpose: a forward reference here is a nil
-- global at runtime, the exact bug c5be3fa fixed for tryStoreyLink.)
local function drawConsole()
    if not game.consoleOpen then return end
    local w = love.graphics.getWidth()
    local h = math.floor(love.graphics.getHeight() * 0.4)
    local lineH = love.graphics.getFont():getHeight() + 2

    love.graphics.setColor(0.05, 0.06, 0.08, 0.92)
    love.graphics.rectangle('fill', 0, 0, w, h)
    love.graphics.setColor(0.3, 0.6, 0.3, 0.9)
    love.graphics.rectangle('fill', 0, h - 1, w, 1)

    local ring = game.console:lines()
    local rows = math.floor((h - lineH * 1.5) / lineH)
    love.graphics.setColor(0.85, 0.9, 0.85)
    local y = h - lineH * 2
    for i = #ring, math.max(1, #ring - rows + 1), -1 do
        love.graphics.print(ring[i], 6, y)
        y = y - lineH
        if y < 0 then break end
    end

    love.graphics.setColor(1, 1, 1)
    love.graphics.print('] ' .. game.consoleInput .. '_', 6, h - lineH - 2)
end

-- The A4 feedback kit drawn: every number here comes from meatray.game.hud,
-- and everything about how it looks is decided in this function and nowhere
-- else. The debug print line above the log stays; this is the player-facing
-- layer, that one is the developer-facing one.
local function drawHudKit(w, h)
    local hud = game.hud

    -- Damage flash and heal glow, whole-frame washes. F8: through the
    -- accessibility flash scale (photosensitivity) and colourblind remap.
    local flash = hud:flashStrength()
    if flash > 0 then
        local fr, fg, fb = game.a11y:color(0.90, 0.08, 0.05)
        love.graphics.setColor(fr, fg, fb, game.a11y:flash(flash * 0.32))
        love.graphics.rectangle('fill', 0, 0, w, h)
    end
    local glow = hud:healStrength()
    if glow > 0 then
        local hr, hg, hb = game.a11y:color(0.20, 0.85, 0.30)
        love.graphics.setColor(hr, hg, hb, game.a11y:flash(glow * 0.18))
        love.graphics.rectangle('fill', 0, 0, w, h)
    end

    -- Low-health throb: a border, not a wash, so the world stays readable.
    local pulse = hud:lowPulse(love.timer.getTime())
    if pulse > 0 then
        local edge = 24
        love.graphics.setColor(0.80, 0.05, 0.05, pulse * 0.30)
        love.graphics.rectangle('fill', 0, 0, w, edge)
        love.graphics.rectangle('fill', 0, h - edge, w, edge)
        love.graphics.rectangle('fill', 0, edge, edge, h - edge * 2)
        love.graphics.rectangle('fill', w - edge, edge, edge, h - edge * 2)
    end

    -- Hit marker: four ticks just outside the crosshair.
    local hit = hud:hitStrength()
    if hit > 0 then
        love.graphics.setColor(1, 1, 1, hit)
        for _, s in ipairs{ {1,1}, {1,-1}, {-1,1}, {-1,-1} } do
            love.graphics.line(w / 2 + s[1] * 9,  h / 2 + s[2] * 9,
                               w / 2 + s[1] * 15, h / 2 + s[2] * 15)
        end
    end

    -- Directional damage: arcs around the crosshair. The model hands over a
    -- relative bearing where 0 is dead ahead; on screen, ahead is up.
    for _, ind in ipairs(hud:indicators()) do
        local a = -ind.angle - math.pi / 2
        love.graphics.setColor(0.95, 0.15, 0.10, ind.strength * 0.9)
        love.graphics.arc('line', 'open', w / 2, h / 2, 52, a - 0.35, a + 0.35)
    end

    local rows = hud:bars()

    -- Health (and armour, when a game tracks it), bottom-left.
    local x, y = 10, h - 78
    if rows.hp then
        local frac = rows.hp.fraction
        love.graphics.setColor(0, 0, 0, 0.55)
        love.graphics.rectangle('fill', x, y, 180, 14)
        love.graphics.setColor(0.90 - 0.55 * frac, 0.15 + 0.60 * frac, 0.14, 0.9)
        love.graphics.rectangle('fill', x + 1, y + 1, 178 * frac, 12)
        love.graphics.setColor(1, 1, 1)
        love.graphics.print(('%d / %d'):format(rows.hp.value, rows.hp.max),
                            x + 4, y - 1)
        y = y + 18
    end
    if rows.armour then
        love.graphics.setColor(0, 0, 0, 0.55)
        love.graphics.rectangle('fill', x, y, 180, 10)
        if rows.armour.fraction then
            love.graphics.setColor(0.35, 0.55, 0.90, 0.9)
            love.graphics.rectangle('fill', x + 1, y + 1,
                                    178 * rows.armour.fraction, 8)
        end
        love.graphics.setColor(1, 1, 1)
        love.graphics.print(tostring(rows.armour.value), x + 186, y - 3)
    end

    -- Weapon and ammo, bottom-right.
    if rows.weapon then
        local text
        if rows.weapon.reloading then
            text = ('%s  reloading %d%%'):format(rows.weapon.id,
                math.floor((rows.weapon.reloadFraction or 0) * 100 + 0.5))
        else
            text = ('%s  %d/%s%s'):format(rows.weapon.id, rows.weapon.ammo,
                tostring(rows.weapon.magazine or '-'),
                rows.weapon.carried and ('  (%d)'):format(rows.weapon.carried) or '')
        end
        love.graphics.setColor(1, 1, 1, rows.weapon.empty and 0.5 or 1)
        love.graphics.print(text, w - 10 - love.graphics.getFont():getWidth(text),
                            h - 78)
    end

    -- F1: say when the frame is a recording or a replay. The dot is the
    -- classic camcorder promise that input is being written down.
    if game.demoRec then
        love.graphics.setColor(0.95, 0.2, 0.15)
        love.graphics.circle('fill', w - 18, 18, 5)
        love.graphics.print('REC', w - 52, 10)
    elseif game.demoPlay then
        love.graphics.setColor(0.4, 0.9, 0.5)
        local tag = game.demoDiverged
            and ('PLAY (diverged @%d)'):format(game.demoDiverged) or 'PLAY'
        love.graphics.print(tag, w - 10 - love.graphics.getFont():getWidth(tag), 10)
    end
    love.graphics.setColor(1, 1, 1)

    -- A8: paused, or over. Drawn before the death overlay reads, because
    -- being disconnected outranks being dead — a corpse in a session that
    -- ended is not waiting for anything.
    if game.session:isOver() then
        love.graphics.setColor(0, 0, 0, 0.72)
        love.graphics.rectangle('fill', 0, 0, w, h)
        local head = game.session:endedByChoice() and 'left the game' or 'disconnected'
        local why = tostring(game.session:reason() or '')
        love.graphics.setColor(0.95, 0.75, 0.30)
        love.graphics.printf(head, 0, h / 2 - 40, w, 'center')
        love.graphics.setColor(0.85, 0.85, 0.85)
        love.graphics.printf(why, 0, h / 2 - 18, w, 'center')
        love.graphics.printf('P for a fresh game', 0, h / 2 + 12, w, 'center')
        love.graphics.setColor(1, 1, 1)
        return
    end
    if game.session:isPaused() then
        love.graphics.setColor(0, 0, 0, 0.55)
        love.graphics.rectangle('fill', 0, 0, w, h)
        love.graphics.setColor(1, 1, 1)
        love.graphics.printf('paused', 0, h / 2 - 24, w, 'center')
        love.graphics.printf('P to resume', 0, h / 2, w, 'center')
    elseif game.session:menuOpen() then
        -- Online: the menu is up but the world is still moving. Say so, so
        -- nobody reads a menu as safety.
        love.graphics.setColor(1, 0.85, 0.4)
        love.graphics.printf('menu open — the game is still running',
                             0, 10, w, 'center')
        love.graphics.setColor(1, 1, 1)
    end

    -- A5 feedback: the dead see the wait; the just-returned see their shield.
    local player = activePlayer()
    if game.respawn:state('local') ~= 'alive' then
        love.graphics.setColor(0, 0, 0, 0.55)
        love.graphics.rectangle('fill', 0, 0, w, h)
        local left = game.respawn:remaining('local')
        local text = left > 0 and ('you died — back in %.1f'):format(left)
                              or 'you died'
        love.graphics.setColor(0.92, 0.25, 0.18)
        love.graphics.printf(text, 0, h / 2 - 32, w, 'center')
        -- D35: name what the camera is doing while you are down.
        local scam = game.spectator:camera(player)
        if scam then
            love.graphics.setColor(0.8, 0.8, 0.85)
            local tag = scam.mode == 'killcam' and 'killcam'
                     or ('spectating ' .. (scam.targetName or 'a player')
                         .. '  —  click to cycle')
            love.graphics.printf(tag, 0, h / 2 - 8, w, 'center')
        end
    elseif player and Game.respawn.isProtected(player) then
        love.graphics.setColor(0.45, 0.80, 1.00, 0.55)
        love.graphics.circle('line', w / 2, h / 2, 24)
    end

    love.graphics.setColor(1, 1, 1)
end

function love.draw()
    if args.selftest then return end

    local world, player = activeWorld(), activePlayer()
    if not world or not player then
        love.graphics.setColor(1, 1, 1)
        -- A8: a client that joined without ever loading a local level has no
        -- world to fall back to when the session ends, and "no world" is not
        -- what happened. Say what did.
        local headline = game.client and 'connecting...' or 'no world'
        if game.session:isOver() then
            headline = ('disconnected: %s   —   P for a fresh game')
                       :format(tostring(game.session:reason() or ''))
        end
        love.graphics.print(headline, 8, 8)
        for i, line in ipairs(game.log) do love.graphics.print(line, 8, 26 + (i - 1) * 14) end
        drawShell()
        drawConsole()
        return
    end

    -- The local player is predicted, so it interpolates on the simulation tick;
    -- everything the host owns interpolates between snapshots. Two different
    -- alphas, because they are two different clocks.
    local cameraAlpha = game.client and game.client:tickAlpha() or game.alpha
    local px, py, pangle, pz = player:interpolated(cameraAlpha)
    local storey = player.storey or 1

    -- D35: when the spectator has a pose (killcam or spectating a live player),
    -- the camera comes from there instead of the player's own eyes.
    local spCam = game.spectator:camera(player)
    if spCam then
        px, py, pangle = spCam.x, spCam.y, spCam.angle
        storey = spCam.storey or storey
    end
    local floorZ = pz or player.z or 0
    local eyeHeight = MeatRay.world.EYE_HEIGHT
    -- Low ceilings crouch the camera (relative ceiling within storey).
    if world.ceilingHeightAtPoint then
        local relFloor = world.floorHeightAtPoint
            and world:floorHeightAtPoint(px, py, storey) or 0
        local relCeil = world:ceilingHeightAtPoint(px, py, storey)
        local room = relCeil - relFloor
        local maxEye = room - 0.08
        if maxEye < 0.12 then maxEye = 0.12 end
        if eyeHeight > maxEye then eyeHeight = maxEye end
    end
    local eyeZ = floorZ + eyeHeight
    local view = MeatRay.raycaster.view(px, py, pangle, {
        eyeZ = eyeZ,
        eyeHeight = eyeHeight,
        pitch = game.pitch,
        storey = storey,
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

    -- A7: the world is drawn at the render scale, the HUD at native. Below
    -- scale 1 that means an offscreen canvas the size the options asked for,
    -- stretched over the window afterwards — the one graphics setting that
    -- reliably buys frames on a software raycaster, because the cost here is
    -- per pixel and nothing else in the frame is.
    local target = beginWorldPass()

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
    drawParticles(view, game.zbuffer)

    endWorldPass(target)

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
            'WASD move  mouse look (yaw+pitch)  Q/E turn  F door/stairs  click fire  L torch\n'
            .. '1 pistol  2 grenade launcher  M minimap  TAB world  R reseed  T theme\n'
            .. 'F1 help  I bag  F2 quality  F3/F4 fov  F6 record demo  F7 replay  P pause  ` console (bot/give/map)',
            8, love.graphics.getHeight() - 48)
    end

    -- A crosshair, so firing has somewhere to aim.
    local w, h = love.graphics.getWidth(), love.graphics.getHeight()
    love.graphics.setColor(1, 1, 1, 0.6)
    love.graphics.line(w / 2 - 6, h / 2, w / 2 + 6, h / 2)
    love.graphics.line(w / 2, h / 2 - 6, w / 2, h / 2 + 6)
    love.graphics.setColor(1, 1, 1)

    -- C28: screen tints sit over the world and crosshair, under the HUD and
    -- messages, so a lava wash colours the scene without drowning the numbers.
    drawScreenFX(w, h)

    drawHudKit(w, h)

    if game.showMinimap and MeatRay.minimap then
        if not game.minimap or game.minimap.world ~= world then
            game.minimap = MeatRay.minimap.new{
                world = world, size = 128, corner = 'br', margin = 10,
            }
        end
        game.minimap:draw(px, py, pangle, {
            entities = activeEntities(),
            storey = storey,
            screenW = w, screenH = h,
            -- F2: only what this player has seen. The minimap has taken a
            -- fog table since it was written; this is the memory behind it.
            fog = game.automap:visited(storey),
        })
    end

    drawBag(w, h)
    drawMessages(w, h)
    drawIntermission()
    drawShell()
    drawConsole()
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
            if args.map then
                loadAuthored('maps/' .. args.map .. '.map')
            else
                loadProcedural()
            end
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
