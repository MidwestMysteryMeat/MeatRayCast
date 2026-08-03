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
    simulation half (`meatray.sim.*`) needs no host at all, which is what makes a
    headless server a configuration choice and lets the whole simulation be
    unit-tested without a window. The half that does need one reaches it through
    `MeatRay.platform`, and nowhere else.
]]

local MeatRay = {}

MeatRay._VERSION = '0.1.0'
MeatRay._DESCRIPTION = 'Raycasting game engine for LOVE2D'

---------------------------------------------------------------------------
-- The host seam.
--
-- Everything in the engine that needs a window, a file, a key or a clock goes
-- through here, and a backend is the file that supplies them (meatray/platform/).
-- It is on the facade because `meatray.engine` needs it and may only use the
-- public API — and because a game embedding this engine in something that is not
-- LÖVE installs its backend through `MeatRay.platform.use`, which should not
-- require reaching past the front door to find.
--
-- Requiring it costs nothing headless: selecting a backend happens on first use,
-- not here.
---------------------------------------------------------------------------

MeatRay.platform = require('meatray.platform')

---------------------------------------------------------------------------
-- Simulation: headless, no LÖVE required.
---------------------------------------------------------------------------

MeatRay.entity     = require('meatray.sim.entity')
MeatRay.components = require('meatray.sim.components')
MeatRay.world      = require('meatray.sim.world')
MeatRay.collide    = require('meatray.sim.collide')
MeatRay.segments   = require('meatray.sim.segments')
MeatRay.pathfind   = require('meatray.sim.pathfind')
MeatRay.triggers   = require('meatray.sim.triggers')
MeatRay.ai         = require('meatray.sim.ai')
MeatRay.decals     = require('meatray.sim.decals')
MeatRay.tick       = require('meatray.sim.tick')
MeatRay.billboard  = require('meatray.sim.billboard')
MeatRay.worldgen   = require('meatray.sim.worldgen')
MeatRay.map        = require('meatray.sim.map')
MeatRay.movers     = require('meatray.sim.movers')
MeatRay.demo       = require('meatray.sim.demo')
MeatRay.prefab     = require('meatray.sim.prefab')

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

    -- Gameplay rules: attributes, effects, tags, abilities, weapons, inventory,
    -- explosions and gas. Headless to the last line — a dedicated server runs all
    -- of it — so it loads here rather than behind the graphics gate, and lazily
    -- for the same reason the net stack is lazy: a game that defines no
    -- attributes should not pay to load an attribute system.
    game = 'meatray.game',

    -- Asset import is headless-safe for the same reason: its grid arithmetic,
    -- name resolution, registry policy and audio falloff curves are plain Lua,
    -- and only the PNG and WAV modules underneath it need LÖVE — which they
    -- require lazily. A dedicated server can therefore load a game that declares
    -- its own assets without ever opening a decoder.
    asset = 'meatray.asset',

    -- Lighting is a render concern — the simulation never asks how bright a tile
    -- is — but its maths is plain Lua with no LÖVE anywhere in it, so it loads
    -- here rather than behind the graphics gate below. That is what lets the
    -- falloff curves, the colour accumulation, the readability floor and the
    -- dirty-region bookkeeping be unit-tested under bare LuaJIT instead of only
    -- in front of a GPU.
    lighting = 'meatray.render.lighting',

    -- Particles are a render concern but pure-Lua like lighting: the burst
    -- model, the velocity/gravity/drag simulation and the cap are all testable
    -- under bare LuaJIT. A dedicated server simply never calls burst.
    particles = 'meatray.render.particles',

    -- Saving is headless too, and deliberately: a dedicated server that can
    -- simulate a world but cannot persist it is half a server. The format and
    -- the state capture are pure Lua, and the storage layer picks
    -- love.filesystem only when there is a LÖVE to pick it from — so this is
    -- safe to touch under bare LuaJIT, where it writes through plain io.
    save = 'meatray.save',
}

---------------------------------------------------------------------------
-- Rendering: requires a host. Loaded lazily so `require('meatray')` still works
-- under plain LuaJIT — which is what the headless tests and a dedicated server
-- do.
---------------------------------------------------------------------------

local renderModules = {
    raycaster = 'meatray.render.raycaster',
    sprites   = 'meatray.render.sprites',
    textures  = 'meatray.render.textures',
    themes    = 'meatray.render.themes',
    minimap   = 'meatray.render.minimap',
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

        if not MeatRay.platform.available() then
            error(('meatray.%s needs a host; the simulation modules do not. '
                   .. 'Running headless? Use meatray.sim.* only.'):format(key), 2)
        end

        local mod = require(path)
        t[key] = mod
        return mod
    end,
})

-- True when the host can actually draw, i.e. rendering is available. A dedicated
-- server checks this rather than assuming: `love . --server` has a host, a
-- filesystem and a clock, and no graphics module at all.
function MeatRay.canRender()
    return MeatRay.platform.canRender()
end

return MeatRay
