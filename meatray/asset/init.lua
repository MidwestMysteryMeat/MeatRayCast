--[[
    meatray.asset — importing files, and running fine without them.

        local Asset = require('meatray.asset')

        Asset.importSprite('imp', 'assets/sprites/imp_a8_f4.png',
                           { angles = 8, frames = 4, fps = 7 })
        Asset.declareSound('shot', { path = 'assets/sounds/shot.wav' })

        Asset.sprite('imp')                 -- the sheet, or a placeholder
        Asset.sound.playAt('shot', x, y)    -- silent if there is no file

        for _, line in ipairs(Asset.missingLines()) do print(line) end

    The standing constraint from the roadmap is that every phase leaves the engine
    runnable with zero media. Import does not weaken that; it layers on top of it.
    Nothing here can make a lookup fail: an unimportable sprite becomes the same
    generated placeholder the engine has always drawn, an unimportable sound plays
    nothing, and both say why in `Asset.missing()`.

    Layout, and why it is split this way:

        slice.lua     grid arithmetic          headless, tested
        names.lua     logical names, paths     headless, tested
        registry.lua  resolution policy        headless, tested
        spatial.lua   falloff and pan          headless, tested
        image.lua     PNG decode               needs a drawing host
        sound.lua     WAV playback             needs an audio host

    The interesting failure modes are all in the first four, so they are all
    asserted under plain LuaJIT with no host present. The last two are thin by
    design and covered by the selftest, which has a real context.

    This file itself is headless-safe: requiring it under LuaJIT loads only the
    first four, and the two host-side modules arrive lazily on first use.
]]

local Platform = require('meatray.platform')
local Registry = require('meatray.asset.registry')
local Slice    = require('meatray.asset.slice')
local Names    = require('meatray.asset.names')
local Spatial  = require('meatray.asset.spatial')

local Asset = {}

Asset.registry = Registry
Asset.slice    = Slice
Asset.names    = Names
Asset.spatial  = Spatial

-- image and sound need a host, so they arrive on first access rather than at
-- require time — the same trick meatray/init.lua uses for the render modules,
-- for the same reason: a headless server must be able to require this file.
local lazy = {
    image = 'meatray.asset.image',
    sound = 'meatray.asset.sound',
}

setmetatable(Asset, {
    __index = function(t, key)
        local path = lazy[key]
        if not path then return nil end
        local mod = require(path)
        rawset(t, key, mod)
        return mod
    end,
})

---------------------------------------------------------------------------
-- Loaders and fallbacks
--
-- Each pair is "how to get the real thing" and "what to draw or play instead".
-- Both are registered together, on purpose: a kind with a loader and no fallback
-- is a kind whose misses have nowhere to go.
---------------------------------------------------------------------------

local installed = false

local function spriteLoader(record)
    local Image = require('meatray.asset.image')
    local Sprites = require('meatray.render.sprites')

    local def, err = Image.sheetDef(record.path, record.settings)
    if not def then return nil, err end

    return Sprites.define(record.name, def)
end

-- The placeholder path, and the reason the engine has always run with no media:
-- Sprites.define generates a sheet when handed no image, with a distinct
-- silhouette per angle bucket.
local function spriteFallback(record)
    local Sprites = require('meatray.render.sprites')
    local s = record.settings or {}
    return Sprites.define(record.name, {
        angles = s.angles or 1,
        frames = s.frames or 1,
        fps = s.fps,
        anchor = s.anchor,
        scale = s.scale,
        color = s.color,
    })
end

local function textureLoader(record)
    local Image = require('meatray.asset.image')
    return Image.textureImage(record.path)
end

-- Wall textures fall back to the procedural set, which is a complete texture set
-- for any theme. A missing wall texture therefore looks like the rest of the
-- level rather than like a hole in it.
local function textureFallback(record)
    local Textures = require('meatray.render.textures')
    local s = record.settings or {}
    local set = Textures.forTheme(s.theme)
    return set.walls[s.tile or 1] or set.walls[1]
end

-- The host's filesystem when there is a host, plain `io` otherwise. Both paths
-- are live: a shipped game reads through the sandbox, and a dedicated server
-- under bare LuaJIT reads its map off the disk with no host at all.
local function readFile(path)
    if Platform.available() and Platform.fs.getInfo(path) then
        return Platform.fs.read(path)
    end
    local handle = io.open(path, 'r')
    if not handle then return nil end
    local text = handle:read('*a')
    handle:close()
    return text
end

local function mapLoader(record)
    local Map = require('meatray.sim.map')
    local text = readFile(record.path)
    if not text then return nil, ('file not found: %s'):format(tostring(record.path)) end

    local map, errs = Map.parse(text)
    if not map then
        return nil, ('%s: %s'):format(record.path, tostring(errs and errs[1] or 'parse failed'))
    end
    return map
end

local function mapFallback(record)
    local Map = require('meatray.sim.map')
    local s = record.settings or {}
    return Map.blank(s.width or 16, s.height or 16)
end

-- Themes are code, not files, so there is nothing to load; the registry entry
-- exists so the browser can list them alongside everything else and so a theme
-- name that does not exist resolves to the default rather than to nil.
local function themeFallback(record)
    local Themes = require('meatray.render.themes')
    return Themes.get(record.name)
end

local function soundLoader(record)
    local Sound = require('meatray.asset.sound')
    return Sound.load(record.path, (record.settings or {}).kind)
end

-- Deliberately no sound fallback. A missing image needs *something* to draw or
-- the frame has a hole in it; a missing sound needs nothing, and silence is the
-- correct stand-in. Registering a beep here would make every unimported sound
-- audible, which is worse than any of them being missing.

function Asset.install()
    if installed then return Asset end
    installed = true

    Registry.setLoader('sprite', spriteLoader)
    Registry.setFallback('sprite', spriteFallback)

    Registry.setLoader('texture', textureLoader)
    Registry.setFallback('texture', textureFallback)

    Registry.setLoader('map', mapLoader)
    Registry.setFallback('map', mapFallback)

    Registry.setLoader('sound', soundLoader)
    Registry.setFallback('theme', themeFallback)

    return Asset
end

function Asset.installed() return installed end

---------------------------------------------------------------------------
-- Declaring and importing
---------------------------------------------------------------------------

-- Declares a sprite with no file: procedural by design, not missing.
function Asset.declareSprite(name, settings)
    Asset.install()
    return Registry.declare(name, 'sprite', { settings = settings or {} })
end

-- Declares a sprite backed by a sheet on disk. Nothing is read yet.
function Asset.declareSheet(name, path, settings)
    Asset.install()
    return Registry.declare(name, 'sprite', { path = path, settings = settings or {} })
end

-- Declare and load in one step, which is what an import button does. Returns the
-- record; `record.state == 'file'` means it worked, and `record.problem` says why
-- when it did not. Never raises, so a bad path in a dialog is a console line
-- rather than a dead editor.
function Asset.importSprite(name, path, settings)
    Asset.declareSheet(name, path, settings)
    return Registry.resolve(name, 'sprite', true)
end

function Asset.importTexture(name, path, settings)
    Asset.install()
    Registry.declare(name, 'texture', { path = path, settings = settings or {} })
    return Registry.resolve(name, 'texture', true)
end

function Asset.declareSound(name, opts)
    Asset.install()
    local Sound = require('meatray.asset.sound')
    return Sound.declare(name, opts)
end

function Asset.importSound(name, path, opts)
    opts = opts or {}
    opts.path = path
    Asset.declareSound(name, opts)
    return Registry.resolve(name, 'sound', true)
end

function Asset.declareMap(name, path)
    Asset.install()
    return Registry.declare(name, 'map', { path = path })
end

function Asset.declareTheme(name)
    Asset.install()
    return Registry.declare(name, 'theme', {})
end

---------------------------------------------------------------------------
-- Lookups. None of these can fail.
---------------------------------------------------------------------------

-- The sprite definition, importing or generating as needed. A name that was
-- never declared is declared on the spot as procedural, so game code that
-- references a sprite nobody set up still draws something and still shows up in
-- the missing-asset report as generated rather than as a silent nil.
function Asset.sprite(name, settings)
    Asset.install()
    if not Registry.get(name, 'sprite') then Asset.declareSprite(name, settings) end
    return Registry.value(name, 'sprite')
end

function Asset.texture(name, settings)
    Asset.install()
    if not Registry.get(name, 'texture') then
        Registry.declare(name, 'texture', { settings = settings or {} })
    end
    return Registry.value(name, 'texture')
end

function Asset.map(name)
    Asset.install()
    if not Registry.get(name, 'map') then Asset.declareMap(name, name) end
    return Registry.value(name, 'map')
end

function Asset.theme(name)
    Asset.install()
    if not Registry.get(name, 'theme') then Asset.declareTheme(name) end
    return Registry.value(name, 'theme')
end

---------------------------------------------------------------------------
-- Inventory
---------------------------------------------------------------------------

function Asset.missing() return Registry.missing() end
function Asset.missingLines() return Registry.missingLines() end
function Asset.report() return Registry.report() end
function Asset.list(kind) return Registry.list(kind) end
function Asset.records(kind) return Registry.records(kind) end
-- Names are namespaced per kind, so both arguments are required: a project may
-- have a `door` sprite and a `door` sound, and a lookup that guessed between them
-- would be right most of the time, which is the worst possible failure rate.
function Asset.get(name, kind) return Registry.get(name, kind) end
function Asset.find(name) return Registry.find(name) end
function Asset.clear() Registry.clear() end

-- Prints the inventory. Called by a game at startup, or by the editor on demand:
-- "12 assets, 9 from files, 2 generated, 1 missing" is the line that tells you
-- whether the build you are about to ship has holes in it.
function Asset.summaryLine()
    local r = Asset.report()
    return ('%d assets: %d from files, %d generated, %d MISSING')
        :format(r.total, r.file, r.generated, r.missing)
end

---------------------------------------------------------------------------
-- Scanning
---------------------------------------------------------------------------

-- Walks a directory for importable files. Returns records of
-- { path, name, kind, hints }, sorted by path, with no side effects on the
-- registry — scanning is a question, importing is the answer.
--
-- Returns an empty list rather than erroring when there is no filesystem or the
-- directory does not exist, so the browser can point at `assets/` on a project
-- that has never made one.
function Asset.scan(dir, opts)
    opts = opts or {}
    local out = {}

    -- No host means no directory listing: plain Lua cannot enumerate one, and
    -- an empty list is the documented answer rather than a raise.
    if not Platform.available() then return out end

    local fs = Platform.fs
    local maxDepth = opts.maxDepth or 3

    local function walk(path, depth)
        local info = fs.getInfo(path)
        if not info or info.type ~= 'directory' then return end

        local items = fs.getDirectoryItems(path)
        table.sort(items)

        for _, item in ipairs(items) do
            local full = Names.join(path, item)
            local itemInfo = fs.getInfo(full)

            if itemInfo and itemInfo.type == 'directory' then
                if depth < maxDepth then walk(full, depth + 1) end
            elseif itemInfo then
                local kind = Names.kindFor(full)
                if kind and (not opts.kind or opts.kind == kind) then
                    out[#out + 1] = {
                        path = full,
                        name = Names.fromPath(full),
                        kind = kind,
                        hints = Names.hints(full),
                        size = itemInfo.size,
                    }
                end
            end
        end
    end

    walk(dir, 1)
    return out
end

return Asset
