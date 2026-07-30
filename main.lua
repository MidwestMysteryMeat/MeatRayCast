--[[
    MeatRayCast demo.

    Deliberately written against the library API rather than the convenience
    layer, so it doubles as proof that the library path is sufficient on its own.

        love .                  procedural world (BSP)
        love . --map arena      hand-authored map from maps/arena.map
        love . --selftest       headless-ish gate, prints PASS and exits

    Controls: WASD or arrows to move, mouse or Q/E to turn, E to open a door,
    left click to fire, TAB to switch world source, F1 for the help overlay.
]]

local MeatRay = require('meatray')

local Entity     = MeatRay.entity
local C          = MeatRay.components
local Collide    = MeatRay.collide
local Tick       = MeatRay.tick
local Worldgen   = MeatRay.worldgen
local Map        = MeatRay.map

local game = {
    world = nil,
    entities = {},
    player = nil,
    clock = nil,
    alpha = 0,
    source = 'procedural',
    seed = 20260730,
    zbuffer = nil,
    log = {},
    showHelp = true,
    turnSpeed = 2.6,
    moveSpeed = 3.2,
}

---------------------------------------------------------------------------
-- Archetypes. Behaviour composes; nothing inherits.
---------------------------------------------------------------------------

local function defineArchetypes()
    Entity.clearArchetypes()

    -- Directional: eight angle buckets, so you can see which way it faces.
    Entity.archetype('imp', function(e)
        e:add(C.Billboard{ sheet = 'imp' })
        e:add(C.Health{ hp = 30, max = 30 })
        e:add(C.Brain{ state = 'idle' })
        e.radius = 0.28
    end)

    -- Always-facing: one bucket, a floating pickup.
    Entity.archetype('crystal', function(e)
        e:add(C.Billboard{ sheet = 'crystal' })
        e:add(C.Health{ hp = 10, max = 10 })
        e.radius = 0.22
    end)

    Entity.archetype('player', function(e)
        e:add(C.Player{ peerId = 0, name = 'local' })
        e:add(C.Health{ hp = 100, max = 100 })
        e:add(C.Weapon{ ammo = 40 })
        e:add(C.Input{})
        e.radius = 0.24
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
end

---------------------------------------------------------------------------
-- World loading, from either source
---------------------------------------------------------------------------

local function note(text)
    table.insert(game.log, 1, text)
    while #game.log > 6 do table.remove(game.log) end
end

local function spawnPlayerAt(x, y, angle)
    local p = Entity.spawn('player', x, y)
    p.angle = angle or 0
    p:snapPrevious()
    game.player = p
    table.insert(game.entities, p)
end

local function loadProcedural()
    local themes = MeatRay.themes.names()
    local theme = themes[(game.seed % #themes) + 1]

    local world, rooms = Worldgen.generate{
        width = 44, height = 44, seed = game.seed, doorChance = 0.5, theme = theme,
    }

    game.world = world
    game.entities = {}
    MeatRay.raycaster.setTheme(theme)

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
    MeatRay.raycaster.setTheme(map.theme)

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
-- Simulation
---------------------------------------------------------------------------

local function playerInput(dt)
    local p = game.player
    if not p then return end

    local turn = 0
    if love.keyboard.isDown('q', 'left') then turn = turn - 1 end
    if love.keyboard.isDown('e', 'right') then turn = turn + 1 end
    p.angle = p.angle + turn * game.turnSpeed * dt

    local forward, strafe = 0, 0
    if love.keyboard.isDown('w', 'up') then forward = forward + 1 end
    if love.keyboard.isDown('s', 'down') then forward = forward - 1 end
    if love.keyboard.isDown('a') then strafe = strafe - 1 end
    if love.keyboard.isDown('d') then strafe = strafe + 1 end

    if forward ~= 0 or strafe ~= 0 then
        local cos, sin = math.cos(p.angle), math.sin(p.angle)
        local dx = (cos * forward - sin * strafe) * game.moveSpeed * dt
        local dy = (sin * forward + cos * strafe) * game.moveSpeed * dt
        Collide.move(p, dx, dy, game.world)
    end
end

local function updateEntities(dt)
    -- The creatures only turn to face the player. Enough to prove directional
    -- sprites work; anything more belongs in a game, not an engine demo.
    for _, e in ipairs(game.entities) do
        if e ~= game.player and e:has('brain') then
            local bearing = MeatRay.billboard.bearing(e.x, e.y, game.player.x, game.player.y)
            e.angle = bearing
        end
    end
end

local function simulate(step)
    for _, e in ipairs(game.entities) do e:snapPrevious() end
    playerInput(step)
    updateEntities(step)
    game.world:update(step)
end

---------------------------------------------------------------------------
-- LÖVE callbacks
---------------------------------------------------------------------------

local selftest = false
local mapArg = nil

function love.load(args)
    for i, a in ipairs(args or {}) do
        if a == '--selftest' then selftest = true end
        if a == '--map' then mapArg = args[i + 1] or 'arena' end
    end

    love.graphics.setDefaultFilter('nearest', 'nearest')

    defineArchetypes()
    MeatRay.raycaster.init{}
    defineSprites()

    game.clock = Tick.new(60)

    if mapArg then loadAuthored('maps/' .. mapArg .. '.map') else loadProcedural() end

    if selftest then
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
    end
end

function love.update(dt)
    if selftest then return end
    game.alpha = game.clock:advance(math.min(dt, 0.25), simulate)
end

function love.draw()
    if selftest or not game.world then return end

    local p = game.player
    local px, py, pangle = p:interpolated(game.alpha)
    local view = MeatRay.raycaster.view(px, py, pangle)

    game.zbuffer = MeatRay.raycaster.render(view, game.world)

    local atmosphere = MeatRay.themes.atmosphere(MeatRay.raycaster.getTheme())
    MeatRay.sprites.draw(game.entities, game.zbuffer, view, {
        time = game.clock:time(),
        alpha = game.alpha,
        ambient = atmosphere.ambient,
        maxView = atmosphere.maxView,
    })

    -- HUD
    love.graphics.setColor(1, 1, 1)
    local health = p:get('health')
    local weapon = p:get('weapon')
    love.graphics.print(('%d fps   hp %d/%d   ammo %d   [%s]  theme %s')
        :format(love.timer.getFPS(), health.hp, health.max, weapon.ammo,
                game.source, MeatRay.raycaster.getTheme()), 8, 8)

    for i, line in ipairs(game.log) do
        love.graphics.setColor(1, 1, 1, 1 - (i - 1) * 0.15)
        love.graphics.print(line, 8, 26 + (i - 1) * 14)
    end

    if game.showHelp then
        love.graphics.setColor(1, 1, 1, 0.75)
        love.graphics.print(
            'WASD move  Q/E or mouse turn  F open door  click fire\n'
            .. 'TAB switch procedural/authored  R reseed  T cycle theme  F1 help',
            8, love.graphics.getHeight() - 34)
    end

    -- A crosshair, so firing has somewhere to aim.
    local w, h = love.graphics.getWidth(), love.graphics.getHeight()
    love.graphics.setColor(1, 1, 1, 0.6)
    love.graphics.line(w / 2 - 6, h / 2, w / 2 + 6, h / 2)
    love.graphics.line(w / 2, h / 2 - 6, w / 2, h / 2 + 6)
    love.graphics.setColor(1, 1, 1)
end

function love.mousemoved(_, _, dx)
    if game.player and love.mouse.isDown(1) == false then
        game.player.angle = game.player.angle + dx * 0.003
    end
end

function love.mousepressed()
    local p = game.player
    if not p then return end

    local weapon = p:get('weapon')
    if weapon.ammo <= 0 then
        note('out of ammo')
        return
    end
    weapon.ammo = weapon.ammo - 1

    local dirX, dirY = math.cos(p.angle), math.sin(p.angle)
    local hit = Collide.hitscan(game.world, p.x, p.y, dirX, dirY, game.entities,
                                { ignore = p, maxDist = 32 })

    if not hit then
        note('shot into the dark')
    elseif hit.kind == 'wall' then
        note(('hit wall at %d,%d (%.1f away)'):format(hit.tx, hit.ty, hit.dist))
    else
        local health = hit.entity:get('health')
        if health then
            health.hp = health.hp - 12
            if health.hp <= 0 then
                hit.entity.dead = true
                note(('killed %s'):format(hit.entity.kind))
            else
                note(('hit %s for 12, %d left'):format(hit.entity.kind, health.hp))
            end
        end
    end
end

function love.keypressed(key)
    if key == 'escape' then love.event.quit() end

    if key == 'f1' then game.showHelp = not game.showHelp end

    if key == 'f' then
        -- Open whichever door is in front of you.
        local p = game.player
        local dirX, dirY = math.cos(p.angle), math.sin(p.angle)
        local dist, tx, ty = Collide.rayTile(game.world, p.x, p.y, dirX, dirY, 2)
        if dist and game.world:doorAt(tx, ty) then
            game.world:toggleDoor(tx, ty)
            note(('door at %d,%d %s'):format(tx, ty,
                 game.world:doorAt(tx, ty).open and 'opened' or 'closed'))
        else
            note('no door within reach')
        end
    end

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
    MeatRay.raycaster.resize(w, h)
end

-- Exposed so the selftest can drive the same state the demo uses.
_G.MEATRAY_DEMO = game
