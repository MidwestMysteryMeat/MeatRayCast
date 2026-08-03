--[[
    meatray.game.pack — content as a mountable pack (B13).

    A game is more than an engine: it is maps, node graphs, and later art and
    audio. Shipping that content as loose files in the repo does not scale to
    third-party content, so a pack is a self-contained bundle — a directory (or
    a zip) with a `pack.json` manifest naming what it holds. Mount a pack and
    its maps and graphs become loadable by id; the manifest is the index.

        local Pack = require('meatray.game.pack')
        local manifest, errs = Pack.parse(jsonText)      -- decode + validate
        local reg = Pack.Registry.new()
        reg:mount(manifest, '/path/to/pack')             -- register its assets
        reg:resolve('map', 'arena')                      -- -> absolute file path

    The manifest (pack.json):

        {
          "id": "coolmaps",            required, unique
          "name": "Cool Maps",         human name
          "version": "1.2.0",          required
          "engine": ">=1.0",           optional min engine, informational
          "author": "someone",
          "depends": ["basemaps"],     other pack ids that must be mounted first
          "maps":   { "arena2": "maps/arena2.map" },
          "graphs": { "waves":  "graphs/waves.graph.json" }
        }

    Security is the reason this is a validated model and not a `require`. A pack
    is content from a stranger, and its manifest names FILE PATHS. A path that
    escapes the pack — `../../etc/passwd`, an absolute `/etc/...`, a Windows
    `C:\...`, or a UNC `\\host\...` — is rejected, so mounting a hostile pack
    cannot read a file outside its own directory. Every asset path must be
    relative and stay within the pack, and that is checked before a single
    file is opened.

    Dependencies are ids, not versions: a pack that depends on `basemaps` will
    not mount until `basemaps` is mounted. Cross-pack id collisions are
    refused rather than silently shadowing, because two `arena` maps that
    resolve to different files by mount order is exactly the bug a manifest
    exists to prevent.

    HEADLESS: pure Lua. Reading the actual bytes is the caller's job (through
    love.filesystem or plain io); this owns the manifest and the id → path map.
]]

local json = require('meatray.net.json')

local Pack = {}

---------------------------------------------------------------------------
-- Path safety
---------------------------------------------------------------------------

-- A pack asset path must be RELATIVE and must not climb out of the pack. This
-- is the one security check that matters: a manifest is untrusted text, and a
-- path that escapes turns "mount this pack" into "read any file on the host".
local function safeAssetPath(p)
    if type(p) ~= 'string' or p == '' then return false, 'empty path' end
    if p:match('^/') or p:match('^%a:[/\\]') or p:match('^\\\\') then
        return false, 'absolute paths are not allowed'
    end
    -- Split on either separator and walk, forbidding any `..` component. A
    -- lone `.` is harmless; anything that would climb above the root is not.
    local depth = 0
    for part in p:gmatch('[^/\\]+') do
        if part == '..' then
            depth = depth - 1
            if depth < 0 then return false, 'path escapes the pack' end
        elseif part ~= '.' then
            depth = depth + 1
        end
    end
    return true
end
Pack.safeAssetPath = safeAssetPath

---------------------------------------------------------------------------
-- Manifest: parse + validate
---------------------------------------------------------------------------

local function isStringMap(t)
    if type(t) ~= 'table' then return false end
    for k, v in pairs(t) do
        if type(k) ~= 'string' or type(v) ~= 'string' then return false end
    end
    return true
end

-- Validates a decoded manifest table. Returns ok, errors.
function Pack.validate(m)
    local errs = {}
    if type(m) ~= 'table' then return false, { 'manifest is not an object' } end

    if type(m.id) ~= 'string' or m.id == '' then
        errs[#errs + 1] = 'missing "id"'
    elseif not m.id:match('^[%w%-_%.]+$') then
        errs[#errs + 1] = 'id has characters outside [A-Za-z0-9-_.]'
    end
    if type(m.version) ~= 'string' or m.version == '' then
        errs[#errs + 1] = 'missing "version"'
    end
    if m.depends ~= nil then
        if type(m.depends) ~= 'table' then
            errs[#errs + 1] = '"depends" must be an array of pack ids'
        else
            for _, d in ipairs(m.depends) do
                if type(d) ~= 'string' then
                    errs[#errs + 1] = 'a dependency is not a string id'
                end
            end
        end
    end

    for _, kind in ipairs({ 'maps', 'graphs' }) do
        local set = m[kind]
        if set ~= nil then
            if not isStringMap(set) then
                errs[#errs + 1] = ('"%s" must be a map of id -> path'):format(kind)
            else
                for id, path in pairs(set) do
                    local ok, why = safeAssetPath(path)
                    if not ok then
                        errs[#errs + 1] = ('%s %q: %s'):format(kind, id, why)
                    end
                end
            end
        end
    end

    return #errs == 0, errs
end

-- Decodes JSON text and validates it. Returns the manifest, or nil + errors.
function Pack.parse(text)
    if type(text) ~= 'string' then return nil, { 'manifest must be JSON text' } end
    local ok, decoded = pcall(json.decode, text)
    if not ok then return nil, { 'bad JSON: ' .. tostring(decoded) } end
    local valid, errs = Pack.validate(decoded)
    if not valid then return nil, errs end
    return decoded
end

---------------------------------------------------------------------------
-- Registry: mounting and resolving
---------------------------------------------------------------------------

Pack.Registry = {}
local RegMT = {}
RegMT.__index = RegMT

function Pack.Registry.new()
    return setmetatable({
        packs = {},        -- [id] = { manifest, root }
        order = {},        -- mount order
        -- [kind][assetId] = { pack = id, path = absolute } — the resolved index
        index = { map = {}, graph = {} },
    }, RegMT)
end

local function joinPath(root, rel)
    if root == nil or root == '' then return rel end
    local sep = root:match('[/\\]$') and '' or '/'
    return root .. sep .. rel
end

-- Mounts a validated manifest whose files live under `root`. Returns true, or
-- false plus a reason. Refuses a duplicate pack id, an unmet dependency, or an
-- asset id that collides with one already mounted.
function RegMT:mount(manifest, root)
    local ok, errs = Pack.validate(manifest)
    if not ok then return false, 'invalid manifest: ' .. table.concat(errs, '; ') end

    if self.packs[manifest.id] then
        return false, 'a pack with id ' .. manifest.id .. ' is already mounted'
    end

    for _, dep in ipairs(manifest.depends or {}) do
        if not self.packs[dep] then
            return false, ('depends on %q, which is not mounted'):format(dep)
        end
    end

    -- Check every asset id is free BEFORE writing any, so a collision leaves
    -- the registry unchanged rather than half-mounted.
    for kind, key in pairs({ maps = 'map', graphs = 'graph' }) do
        for id in pairs(manifest[kind] or {}) do
            if self.index[key][id] then
                return false, ('%s id %q already provided by pack %q')
                    :format(key, id, self.index[key][id].pack)
            end
        end
    end

    self.packs[manifest.id] = { manifest = manifest, root = root }
    self.order[#self.order + 1] = manifest.id
    for kind, key in pairs({ maps = 'map', graphs = 'graph' }) do
        for id, path in pairs(manifest[kind] or {}) do
            self.index[key][id] = { pack = manifest.id, path = joinPath(root, path) }
        end
    end
    return true
end

-- The absolute file path for an asset, or nil. kind is 'map' or 'graph'.
function RegMT:resolve(kind, id)
    local set = self.index[kind]
    local entry = set and set[id]
    return entry and entry.path or nil, entry and entry.pack or nil
end

-- Every asset id of a kind, sorted, each with the pack that provides it.
function RegMT:list(kind)
    local out = {}
    for id, entry in pairs(self.index[kind] or {}) do
        out[#out + 1] = { id = id, pack = entry.pack, path = entry.path }
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

function RegMT:mounted()
    local out = {}
    for _, id in ipairs(self.order) do
        local p = self.packs[id]
        out[#out + 1] = { id = id, name = p.manifest.name or id,
                          version = p.manifest.version }
    end
    return out
end

function RegMT:isMounted(id)
    return self.packs[tostring(id)] ~= nil
end

return Pack
