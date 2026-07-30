--[[
    meatray.platform — the host interface.

    MeatRayCast is a Lua engine that currently runs on LÖVE. That sentence is only
    true if LÖVE is reachable through one seam rather than called from everywhere,
    which is what this module is for. Everything the engine needs from its host —
    a surface to draw on, files, input, a clock — arrives through here, and a
    backend is the file that supplies it.

    The simulation, gameplay, networking and save layers do not use this either;
    they need no host at all. This is the boundary for the half that does.

    Why bother, given LÖVE is permissively licensed and works well:

    - A second backend becomes "implement this interface" rather than "port the
      engine". Mobile store builds, or a LuaJIT+FFI+SDL build with no framework at
      all, are then a contained project.
    - Accidental coupling shows up immediately. The save system had thirteen direct
      `love.filesystem` calls before this existed, which is thirteen more than a
      save system should know about.
    - It is enforced by a test rather than by discipline. Only files under
      `meatray/platform/` may name `love`, and `tests/test_platform.lua` fails if
      that stops being true.

    Usage:

        local P = require('meatray.platform')
        P.fs.read('maps/arena.map')
        P.gfx.rectangle('fill', x, y, w, h)

    Selecting a backend is automatic — LÖVE if a `love` global exists — and
    overridable with `Platform.use(backend)` before anything draws.
]]

local Platform = {}

Platform.backend = nil
Platform.name = 'none'

---------------------------------------------------------------------------
-- The interface a backend must supply
--
-- Listed explicitly rather than left implicit, so "what does a new backend have
-- to implement" is answerable by reading one table instead of grepping the
-- engine. The test asserts a backend supplies all of it.
---------------------------------------------------------------------------

Platform.REQUIRED = {
    gfx = {
        -- Drawing
        'setColor', 'rectangle', 'line', 'circle', 'draw', 'print', 'printf',
        'clear',
        -- Transform stack
        'push', 'pop', 'translate',
        -- Clipping. Note the engine wraps this in its own nested stack
        -- (meatray/ui/core.lua) because neither LÖVE nor most hosts provide one.
        'setScissor', 'getScissor',
        -- Surfaces and resources. `newImageData` allocates blank pixels and
        -- `readImageData` decodes a file into them, which are different enough
        -- that sharing a name cost this codebase an afternoon once already.
        'newImage', 'newQuad', 'newCanvas', 'setCanvas',
        'newImageData', 'readImageData',
        -- Programmable shading. The floor and ceiling cast is per-pixel by
        -- nature, and per-pixel in Lua is not a performance problem so much as a
        -- different program: at 960x600 the lower half alone is 288,000 pixels a
        -- frame, which no interpreter reaches sixty times a second.
        --
        -- `newShader` is the one function here allowed to answer "no". Its
        -- argument is GLSL, which is not a language every conceivable host
        -- speaks, so it returns nil plus a reason rather than raising and the
        -- renderer falls back to flat colour bands. That keeps the seam honest
        -- in both directions: a host without shaders is a supported host, and it
        -- is not one that has to pretend.
        --
        -- `sendShader` exists for the same reason `pasteImageData` does. The
        -- alternative is `shader:send(...)`, which would quietly add "and the
        -- object you hand back must have a `send` method" to the contract this
        -- table exists to state out loud.
        'newShader', 'setShader', 'sendShader',
        -- Copies one block of pixels into another. Named here rather than left
        -- as a method on whatever `newImageData` returns, because the atlas the
        -- texture generator builds is the one place the engine composites pixel
        -- data, and "a backend must also supply these methods on the object it
        -- hands back" is exactly the implicit requirement this table exists to
        -- make explicit.
        'pasteImageData',
        -- Queries
        'getWidth', 'getHeight', 'getDimensions',
        -- Text metrics, as three numbers rather than as a font object. See the
        -- note in the LÖVE backend for why the seam does not hand one out.
        'textWidth', 'textHeight', 'textWrap',
        -- Whether this host can draw at all right now. A LÖVE dedicated server
        -- has a host, a filesystem and a clock, and no graphics module.
        'available',
    },
    fs = {
        'read', 'write', 'remove', 'getInfo', 'getDirectoryItems',
        'createDirectory', 'getSaveDirectory', 'getSource', 'getWorkingDirectory',
        'newFile',
    },
    input = {
        'keyDown', 'mouseDown', 'mousePosition',
    },
    sys = {
        'time', 'os', 'quit',
        -- The run loop. `meatray.engine.run` hands its update/draw/input here
        -- rather than writing into the host's own callback table, which is the
        -- one remaining place the engine would have to know the host's name.
        'setCallbacks',
    },
    audio = {
        'newSource',
        -- Audio is the one subsystem the engine expects to be legitimately
        -- absent — no device, or a server that switched it off — so asking is
        -- part of the interface rather than something to infer from a nil.
        'available',
    },
}

---------------------------------------------------------------------------

-- Defined below, next to the metatable that also uses it. Forward-declared
-- because `Platform.available()` has to be able to trigger selection: it is the
-- first thing most callers ask, and a selector that only ran on a *draw* would
-- answer "no host" on a machine that plainly has one.
local autodetect

-- Installs a backend. Called automatically on first use; call it yourself before
-- anything draws if you are supplying your own.
function Platform.use(backend, name)
    assert(type(backend) == 'table', 'a platform backend must be a table')

    local missing = {}
    for group, names in pairs(Platform.REQUIRED) do
        local supplied = backend[group]
        if type(supplied) ~= 'table' then
            missing[#missing + 1] = group .. ' (whole group)'
        else
            for _, fn in ipairs(names) do
                if type(supplied[fn]) ~= 'function' then
                    missing[#missing + 1] = group .. '.' .. fn
                end
            end
        end
    end

    -- Refuse a partial backend rather than failing later at an arbitrary draw
    -- call. A backend that is 90% implemented fails in whichever feature the
    -- player happens to reach first, which is a terrible way to find out.
    if #missing > 0 then
        error(('platform backend "%s" is missing: %s')
              :format(tostring(name or backend.name or '?'),
                      table.concat(missing, ', ')), 2)
    end

    Platform.backend = backend
    Platform.name = name or backend.name or 'custom'

    Platform.gfx = backend.gfx
    Platform.fs = backend.fs
    Platform.input = backend.input
    Platform.sys = backend.sys
    Platform.audio = backend.audio

    return Platform
end

-- True when a host is installed, or can be. False under plain LuaJIT, which is
-- how the asset and save layers decide to fall back to `io`.
function Platform.available()
    return (rawget(Platform, 'backend') or autodetect()) ~= nil
end

-- True when the installed host can actually draw, which is a narrower question.
-- `love . --server` turns the window and graphics modules off in conf.lua: there
-- is still a host, a filesystem and a clock, and there is nothing to draw on.
-- `MeatRay.canRender()` is this.
function Platform.canRender()
    return Platform.available() and Platform.gfx.available()
end

---------------------------------------------------------------------------
-- Automatic selection
---------------------------------------------------------------------------

function autodetect()
    if rawget(Platform, 'backend') then return Platform.backend end

    if rawget(_G, 'love') then
        return Platform.use(require('meatray.platform.love'), 'love')
    end

    return nil
end

-- Lazy: touching `Platform.gfx` under plain LuaJIT with no host installed gives a
-- clear error naming the problem, rather than a nil index inside a draw call
-- fifty frames later.
setmetatable(Platform, {
    __index = function(_, key)
        if key == 'gfx' or key == 'fs' or key == 'input'
           or key == 'sys' or key == 'audio' then
            if autodetect() then return rawget(Platform, key) end
            error(('meatray.platform.%s: no host backend is installed. '
                   .. 'Running headless? The sim, game, net and save layers need '
                   .. 'no host; only render, ui and asset do.'):format(key), 2)
        end
        return nil
    end,
})

return Platform
