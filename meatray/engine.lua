--[[
    meatray.engine — the optional convenience layer.

    The library half of MeatRayCast owns nothing: you call `render`, you call
    `sprites.draw`, you drive your own clock. That is the right default, and the
    demo is written that way on purpose to prove it is sufficient. But every game
    then writes the same forty lines of accumulator, interpolation and input
    plumbing, and writing them wrongly is how a project ends up with physics that
    drifts with framerate.

        local Engine = require('meatray.engine')

        local app = Engine.new{
            world = MeatRay.worldgen.generate{ seed = 7 },
            onSpawn = function(app) ... end,
            onTick  = function(app, step) ... end,
        }

        function love.update(dt) app:update(dt) end
        function love.draw()     app:draw()     end

    **The hard rule: this file may only use the public API.** It has no privileged
    access to anything, so everything it does you can do yourself, and dropping
    down to the library is never a rewrite — only a copy of the parts you wanted.
    That constraint is what stops the "convenience layer" quietly becoming the only
    supported path, which is how a library turns into a framework by accident.

    It is also why this file requires `meatray` rather than reaching into
    `meatray.sim.*` and `meatray.render.*` directly: if the public facade cannot
    express something, that is a gap in the facade, and hiding it here would mean
    nobody ever notices.
]]

local MeatRay = require('meatray')

local Engine = {}
local App = {}
App.__index = App

local min = math.min

---------------------------------------------------------------------------

-- opts:
--   world        a World (required, or provide worldSpec)
--   worldSpec    { seed=, width=, height=, theme= } to generate one instead
--   entities     an initial list (default {})
--   player       the entity the camera follows (default: the first with `player`)
--   tickRate     simulation steps per second (default 60)
--   theme        renderer theme name (defaults to the world's)
--   moveSpeed / turnSpeed
--   lighting     a meatray.render.lighting grid, or nil
--   onTick(app, step)      per simulation step, fixed dt
--   onSpawn(app)           once, after the world exists
--   onDraw(app, zbuffer)   after walls and sprites, before the HUD
--   onInput(app)           returns { forward, strafe, angle } to override the
--                          default keyboard handling
function Engine.new(opts)
    opts = opts or {}

    local world = opts.world
    if not world and opts.worldSpec then
        world = MeatRay.worldgen.generate(opts.worldSpec)
    end
    assert(world, 'meatray.engine needs a world or a worldSpec')

    local app = setmetatable({
        world = world,
        entities = opts.entities or {},
        player = opts.player,
        clock = MeatRay.tick.new(opts.tickRate or 60),
        alpha = 0,
        moveSpeed = opts.moveSpeed or 3.2,
        turnSpeed = opts.turnSpeed or 2.6,
        aim = 0,
        lighting = opts.lighting,
        zbuffer = nil,
        onTick = opts.onTick,
        onDraw = opts.onDraw,
        onInput = opts.onInput,
        started = false,
    }, App)

    if MeatRay.canRender() then
        MeatRay.raycaster.init{ theme = opts.theme or world.theme }
        if app.lighting then MeatRay.raycaster.setLighting(app.lighting) end
    end

    if opts.onSpawn then opts.onSpawn(app) end

    -- Find the camera entity if the caller did not name one.
    if not app.player then
        for _, e in ipairs(app.entities) do
            if e.components and e.components.player then app.player = e; break end
        end
    end

    if app.player then app.aim = app.player.angle or 0 end

    return app
end

---------------------------------------------------------------------------
-- Input
---------------------------------------------------------------------------

-- Default keyboard handling. Replaced wholesale by `onInput`, not merged with it:
-- a game that wants different controls wants *its* controls, and a half-overridden
-- input scheme is harder to reason about than one you wrote.
function App:gatherInput()
    if self.onInput then return self.onInput(self) end
    if not MeatRay.platform.available() then
        return { forward = 0, strafe = 0, angle = self.aim }
    end

    -- A host with no keyboard — a dedicated server, which has no window and
    -- therefore no input at all — reports nothing held rather than raising. That
    -- is the seam's answer, not a check repeated here.
    local keyDown = MeatRay.platform.input.keyDown

    local forward, strafe = 0, 0
    if keyDown('w', 'up') then forward = forward + 1 end
    if keyDown('s', 'down') then forward = forward - 1 end
    if keyDown('a') then strafe = strafe - 1 end
    if keyDown('d') then strafe = strafe + 1 end

    return { forward = forward, strafe = strafe, angle = self.aim }
end

-- Feeds mouse movement into the aim angle. A game using mouselook should call
-- this from love.mousemoved and enable relative mode itself — the engine does not
-- capture the cursor on your behalf, because a game with menus needs it back.
function App:look(dx, sensitivity)
    self.aim = MeatRay.billboard.normalize(self.aim + dx * (sensitivity or 0.0028))
    return self.aim
end

function App:turn(amount)
    self.aim = MeatRay.billboard.normalize(self.aim + amount)
    return self.aim
end

---------------------------------------------------------------------------
-- The loop
---------------------------------------------------------------------------

-- One simulation step. Fixed dt, always.
function App:step(dt)
    local player = self.player

    if player then
        player:snapPrevious()

        local input = self:gatherInput()
        player.angle = input.angle or player.angle

        if (input.forward or 0) ~= 0 or (input.strafe or 0) ~= 0 then
            local c, s = math.cos(player.angle), math.sin(player.angle)
            local dx = (c * input.forward - s * input.strafe) * self.moveSpeed * dt
            local dy = (s * input.forward + c * input.strafe) * self.moveSpeed * dt
            MeatRay.collide.move(player, dx, dy, self.world)
        end
    end

    for _, e in ipairs(self.entities) do
        if e ~= player then e:snapPrevious() end
    end

    self.world:update(dt)

    if self.onTick then self.onTick(self, dt) end
end

-- Advances real time. Clamped, because a machine that stalls returns with a huge
-- dt and simulating every missed step at once makes the stall worse; the clock
-- caps catch-up too, and reports what it dropped rather than hiding it.
function App:update(dt)
    self.alpha = self.clock:advance(min(dt, 0.25), function(step) self:step(step) end)
    return self.alpha
end

function App:view()
    local player = self.player
    local eyeHeight = MeatRay.world.EYE_HEIGHT
    if not player then
        return MeatRay.raycaster.view(1.5, 1.5, self.aim, {
            eyeZ = eyeHeight, eyeHeight = eyeHeight,
        })
    end
    local px, py, pangle, pz = player:interpolated(self.alpha)
    return MeatRay.raycaster.view(px, py, pangle, {
        eyeZ = (pz or player.z or 0) + eyeHeight,
        eyeHeight = eyeHeight,
    })
end

function App:draw()
    if not MeatRay.canRender() then return end

    local view = self:view()

    if self.lighting then
        -- Dynamic lights are declared per frame by whoever knows what is on fire.
        -- The engine advances the frame; a game adds its own in onTick or onDraw.
        self.lighting:beginFrame()
    end

    self.zbuffer = MeatRay.raycaster.render(view, self.world)

    local atmosphere = MeatRay.themes.atmosphere(MeatRay.raycaster.getTheme())
    MeatRay.sprites.draw(self.entities, self.zbuffer, view, {
        time = self.clock:time(),
        alpha = self.alpha,
        ambient = atmosphere.ambient,
        maxView = atmosphere.maxView,
        lighting = self.lighting,
    })

    if self.onDraw then self.onDraw(self, self.zbuffer) end

    return self.zbuffer
end

---------------------------------------------------------------------------
-- Entities
---------------------------------------------------------------------------

function App:spawn(kind, x, y, fields)
    local e, err = MeatRay.entity.spawn(kind, x, y, fields)
    if not e then return nil, err end
    e:snapPrevious()
    self.entities[#self.entities + 1] = e
    return e
end

function App:remove(entity)
    for i = #self.entities, 1, -1 do
        if self.entities[i] == entity then
            table.remove(self.entities, i)
            return true
        end
    end
    return false
end

-- Drops entities marked dead. Called by the game when it wants to, not
-- automatically: an entity that is dead this tick may still need to be drawn as a
-- corpse, and deciding that is a game's business.
function App:sweepDead()
    local removed = 0
    for i = #self.entities, 1, -1 do
        if self.entities[i].dead then
            table.remove(self.entities, i)
            removed = removed + 1
        end
    end
    return removed
end

---------------------------------------------------------------------------
-- Worlds
---------------------------------------------------------------------------

-- Swaps the world, keeping the loop running. Entities are cleared, because they
-- indexed a world that no longer exists and quietly leaving them behind is how a
-- creature ends up standing inside a wall in the next level.
function App:setWorld(world, opts)
    opts = opts or {}
    self.world = world
    self.entities = opts.entities or {}
    self.player = opts.player

    if MeatRay.canRender() and (opts.theme or world.theme) then
        MeatRay.raycaster.setTheme(opts.theme or world.theme)
    end

    if world.spawn and self.player then
        self.player.x, self.player.y = world.spawn.x, world.spawn.y
        self.player:snapPrevious()
    end

    return self
end

-- Loads a hand-authored map and returns the markers for the game to spawn. The
-- engine does not spawn them itself: it has no idea which archetypes a game has
-- registered, and guessing would be worse than handing them over.
function App:loadMap(text, opts)
    local map, errs = MeatRay.map.parse(text)
    if not map then return nil, errs end

    local world, markers, spawn = MeatRay.map.toWorld(map)
    self:setWorld(world, { theme = map.theme, player = self.player })

    if spawn and self.player then
        self.player.x, self.player.y = spawn.x, spawn.y
        self.player.angle = spawn.angle or self.player.angle
        self.aim = self.player.angle
        self.player:snapPrevious()
    end

    return map, markers, spawn
end

Engine.App = App

-- `Engine.run` for the simplest possible case: installs the host's callbacks and
-- gets out of the way. A game that wants any control over its own callbacks
-- should build the app and call update/draw itself.
--
-- The callbacks go in through the platform rather than being written onto the
-- host directly. This is the only place in the engine that owns a loop at all,
-- so it is also the only place that would otherwise have to know the host's name.
function Engine.run(opts)
    local app = Engine.new(opts)
    local platform = MeatRay.platform

    platform.sys.setCallbacks{
        update = function(dt) app:update(dt) end,
        draw = function() app:draw() end,
        mousemoved = function(_, _, dx) app:look(dx) end,
        keypressed = function(key)
            if key == 'escape' then platform.sys.quit() end
            if opts.onKey then opts.onKey(app, key) end
        end,
    }

    return app
end

return Engine
