--[[
    meatray.ui.reload — hot reload, scoped to data and definitions.

    What reloads: archetypes, sprite definitions, themes, maps, tuning tables —
    anything a game declares by calling into a registry. Live entities keep
    running and keep their state; re-spawning picks up the new definition. That
    covers the loop that actually matters, which is tweak a number and feel the
    difference.

    What does not reload: the engine's own modules. This is a refusal, not a gap.
    `package.loaded[m] = nil; require(m)` leaves closures holding upvalues captured
    over the *old* module, metatable identity comparisons failing against instances
    built by the previous version, and stale references in anything that cached a
    function. The result is a class of bug that exists only after a reload and
    cannot be reproduced from a clean boot — close to the worst debugging
    experience a tool can hand someone. Since this engine loads no assets, a
    restart costs a couple of seconds, which is a far better trade.

    The mechanism is deliberately blunt: clear the registries, re-run the file that
    populates them. That works because the registries are keyed by name and expose
    a clear() — which is why they were built that way. Anything holding a direct
    reference to a definition table instead of looking it up by name will go stale,
    and that is a bug in the holder.
]]

local Reload = {}

local Entity = require('meatray.sim.entity')

---------------------------------------------------------------------------
-- What a reloadable file is allowed to touch
---------------------------------------------------------------------------

-- A definition file is plain Lua run in a sandbox that exposes exactly the
-- registries it is allowed to populate. Running it with the full global
-- environment would let a definition file quietly do anything, and the first time
-- someone's "tuning table" opens a socket the reload story is over.
local function buildEnv(extra)
    local env = {
        -- Enough standard library to write data files with a little logic in them.
        pairs = pairs, ipairs = ipairs, next = next, type = type,
        tostring = tostring, tonumber = tonumber,
        math = math, string = string, table = table,
        select = select, error = error, assert = assert,
        print = print,
    }

    for k, v in pairs(extra or {}) do env[k] = v end

    return env
end

---------------------------------------------------------------------------
-- Reloading
---------------------------------------------------------------------------

-- Runs a definition file against fresh registries.
--
-- `opts.archetypes` clears and repopulates entity archetypes; `opts.sprites`
-- does the same for sprite definitions. Both default on. `opts.extra` adds names
-- to the sandbox, which is how a game exposes its own registries.
--
-- Returns ok, err. On failure NOTHING is applied: the registries are captured
-- first and restored if the file raises, because a syntax error halfway through a
-- definition file must not leave the game with half its archetypes missing. A
-- reload that can corrupt the running state is worse than no reload at all.
function Reload.definitions(path, opts)
    opts = opts or {}

    local source, readErr = love.filesystem.read(path)
    if not source then
        return false, ('cannot read %s: %s'):format(path, tostring(readErr))
    end

    local chunk, loadErr = load(source, '@' .. path, 't', buildEnv(opts.extra))
    if not chunk then
        -- A syntax error is the common case while typing, so it must read like a
        -- compiler message and not like an engine failure.
        return false, tostring(loadErr)
    end

    -- Snapshot what we are about to clear.
    local restore = {}

    if opts.archetypes ~= false then
        restore.archetypes = Entity.captureArchetypes()
        Entity.clearArchetypes()
    end

    local Sprites
    if opts.sprites ~= false and love.graphics then
        Sprites = require('meatray.render.sprites')
        restore.sprites = {}
        for _, name in ipairs(Sprites.names()) do
            restore.sprites[name] = Sprites.get(name)
        end
        Sprites.clear()
    end

    local ok, err = pcall(chunk)

    if not ok then
        -- Put everything back exactly as it was, so a definition file that fails
        -- halfway leaves the running game untouched rather than half-defined.
        if restore.archetypes then Entity.restoreArchetypes(restore.archetypes) end
        if restore.sprites then
            Sprites.clear()
            for name, def in pairs(restore.sprites) do
                -- Re-register through the public API. Passing the already-built
                -- image back means no placeholder is regenerated and the restored
                -- sprite is the same pixels, not a lookalike.
                Sprites.define(name, {
                    image = def.image, angles = def.angles, frames = def.frames,
                    fps = def.fps, anchor = def.anchor, scale = def.scale,
                    color = def.color,
                })
            end
        end
        return false, tostring(err)
    end

    return true
end

---------------------------------------------------------------------------
-- Watching
---------------------------------------------------------------------------

-- Polls a file's modification time. LÖVE has no filesystem watcher, and polling a
-- handful of files a few times a second is far cheaper than the alternative of
-- reloading on a keypress and forgetting to press it.
local Watcher = {}
Watcher.__index = Watcher

function Reload.watcher(interval)
    return setmetatable({
        files = {},        -- [path] = last modtime
        interval = interval or 0.5,
        accum = 0,
    }, Watcher)
end

function Watcher:watch(path)
    local info = love.filesystem.getInfo(path)
    self.files[path] = info and info.modtime or 0
    return self
end

function Watcher:forget(path)
    self.files[path] = nil
end

-- Returns a list of paths whose modification time changed since the last check.
function Watcher:poll(dt)
    self.accum = self.accum + (dt or 0)
    if self.accum < self.interval then return nil end
    self.accum = 0

    local changed
    for path, seen in pairs(self.files) do
        local info = love.filesystem.getInfo(path)
        local now = info and info.modtime or 0
        if now ~= seen then
            self.files[path] = now
            changed = changed or {}
            changed[#changed + 1] = path
        end
    end

    return changed
end

return Reload
