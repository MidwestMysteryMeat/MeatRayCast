--[[
    MeatRayCast — a raycasting game engine for LÖVE.

    Two ways in, both fully supported.

    The library: you own the loop.

        local MeatRay = require('meatray')

        local world = MeatRay.worldgen.generate{ width = 48, height = 48, seed = 7 }
        MeatRay.raycaster.init{ theme = world.theme }
        MeatRay.sprites.define('imp', { angles = 8, frames = 4 })

        function love.draw()
            local view = MeatRay.raycaster.view(px, py, pangle)
            local zbuf = MeatRay.raycaster.render(view, world)
            MeatRay.sprites.draw(entities, zbuf, view)
        end

    Or the convenience layer, which owns the loop for you:

        require('meatray.engine').run{ world = world, entities = entities }

    The split is deliberate. `meatray.engine` may only call this public API — it
    has no privileged access — so anything it can do, you can do yourself. The
    simulation half (`meatray.sim.*`) never touches love.graphics at all, which is
    what makes a headless server a configuration choice and lets the whole
    simulation be unit-tested without a window.
]]

local MeatRay = {}

MeatRay._VERSION = '0.1.0'
MeatRay._DESCRIPTION = 'Raycasting game engine for LOVE2D'

---------------------------------------------------------------------------
-- Simulation: headless, no LÖVE required.
---------------------------------------------------------------------------

MeatRay.entity     = require('meatray.sim.entity')
MeatRay.components = require('meatray.sim.components')
MeatRay.world      = require('meatray.sim.world')
MeatRay.collide    = require('meatray.sim.collide')
MeatRay.tick       = require('meatray.sim.tick')
MeatRay.billboard  = require('meatray.sim.billboard')
MeatRay.worldgen   = require('meatray.sim.worldgen')
MeatRay.map        = require('meatray.sim.map')

-- Convenience aliases for the two most-used constructors.
MeatRay.component = MeatRay.entity.component
MeatRay.archetype = MeatRay.entity.archetype

---------------------------------------------------------------------------
-- Networking: headless, but loaded lazily anyway.
--
-- `MeatRay.net` needs no LÖVE — the loopback transport and the whole replication
-- layer are plain Lua, which is what lets replication be unit-tested with no
-- sockets. The enet transport and the LAN discovery backend do need libraries
-- LÖVE bundles, and each requires its own lazily, so touching `MeatRay.net` under
-- plain LuaJIT is safe.
--
-- Lazily rather than eagerly because a single-player game should not pay to load
-- a net stack it never calls, and because `MeatRay.net` being absent until asked
-- for is what makes "a game that says nothing about networking keeps working"
-- true by construction rather than by care.
---------------------------------------------------------------------------

local lazyModules = {
    net = 'meatray.net',
}

---------------------------------------------------------------------------
-- Rendering: requires LÖVE. Loaded lazily so `require('meatray')` still works
-- under plain LuaJIT — which is what the headless tests and a dedicated server
-- do.
---------------------------------------------------------------------------

local renderModules = {
    raycaster = 'meatray.render.raycaster',
    sprites   = 'meatray.render.sprites',
    textures  = 'meatray.render.textures',
    themes    = 'meatray.render.themes',
}

setmetatable(MeatRay, {
    __index = function(t, key)
        local headless = lazyModules[key]
        if headless then
            local mod = require(headless)
            t[key] = mod
            return mod
        end

        local path = renderModules[key]
        if not path then return nil end

        if not love then
            error(('meatray.%s needs LOVE; the simulation modules do not. '
                   .. 'Running headless? Use meatray.sim.* only.'):format(key), 2)
        end

        local mod = require(path)
        t[key] = mod
        return mod
    end,
})

-- True when there is a LÖVE graphics context, i.e. rendering is available. A
-- dedicated server checks this rather than assuming.
function MeatRay.canRender()
    return love ~= nil and love.graphics ~= nil
end

return MeatRay
