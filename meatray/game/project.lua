--[[
    meatray.game.project — a game as a folder, the engine as its runtime.

    Until now there was exactly one game: the demo wired into main.lua, and
    "making a game" meant editing this repository. A project makes the Godot
    split: the engine stays where it is, and a game is a directory —

        mygame/
          project.json      identity + which map boots
          maps/             *.map            (scanned; files are the truth)
          meatgraphs/       *.graph.json     (scanned)
          assets/           sprites, sounds, music

    Opening a project scans those folders and produces a manifest the existing
    pack registry mounts as-is, so every path that already resolves pack assets
    (`map <id>`, trigger graph binding, the campaign) resolves project assets
    with no new lookup code. A project is, deliberately, "a pack that owns the
    boot" — same path-safety rules, same registry, same collision refusal.

    Files are the truth, not the manifest: an author who saves `maps/cave.map`
    from the editor has added a map, without editing JSON. project.json carries
    only what a scan cannot know — the name, the version, which map starts.

    Filesystem access is injected (`fs` — the Platform.fs shape: read, write,
    getInfo, getDirectoryItems, createDirectory), so every function here is
    asserted headless against a fake. `Project.diskFs()` builds the real one:
    LÖVE's sandbox when the path lives inside it (a packaged game carries its
    project inside the fuse, where only love.filesystem can see it), plain io
    outside it (a project on F:\ that PhysFS will never mount).
]]

local json = require('meatray.net.json')
local Pack = require('meatray.game.pack')

local Project = {}

Project.MANIFEST = 'project.json'
Project.MAP_DIR = 'maps'
Project.GRAPH_DIR = 'meatgraphs'
Project.ASSET_DIR = 'assets'

---------------------------------------------------------------------------
-- Paths and names
---------------------------------------------------------------------------

-- Forward slashes throughout: love.filesystem requires them, io on Windows
-- accepts them, and one canonical form means ids never differ by separator.
local function norm(path)
    return (tostring(path):gsub('\\', '/'):gsub('/+$', ''))
end

local function join(a, b)
    a = norm(a)
    if a == '' then return b end
    return a .. '/' .. b
end

-- A folder name from a display name: 'My First Game!' -> 'my_first_game'.
-- Doubles as the pack id, so it obeys the pack id charset.
function Project.slug(name)
    local s = tostring(name or ''):lower()
        :gsub("[^%w]+", '_'):gsub('^_+', ''):gsub('_+$', '')
    if s == '' then return nil, 'a project needs at least one letter or digit in its name' end
    return s
end

---------------------------------------------------------------------------
-- Manifest
---------------------------------------------------------------------------

-- project.json validation. Same posture as pack manifests: refuse with a list
-- of reasons, never guess.
function Project.validate(m)
    local errs = {}
    if type(m) ~= 'table' then return false, { 'manifest is not a table' } end
    if type(m.id) ~= 'string' or not m.id:match('^[%w%-_%.]+$') then
        errs[#errs + 1] = 'id is required (letters, digits, - _ .)'
    end
    if type(m.name) ~= 'string' or m.name == '' then
        errs[#errs + 1] = 'name is required'
    end
    if type(m.version) ~= 'string' or m.version == '' then
        errs[#errs + 1] = 'version is required'
    end
    if m.startMap ~= nil and type(m.startMap) ~= 'string' then
        errs[#errs + 1] = 'startMap must be a map id (string)'
    end
    if #errs > 0 then return false, errs end
    return true
end

function Project.parse(text)
    local ok, decoded = pcall(json.decode, text)
    if not ok then return nil, { 'bad JSON: ' .. tostring(decoded) } end
    local valid, errs = Project.validate(decoded)
    if not valid then return nil, errs end
    return decoded
end

---------------------------------------------------------------------------
-- The project object
---------------------------------------------------------------------------

local ProjectMT = {}
ProjectMT.__index = ProjectMT

-- Walks one content dir, mapping id -> project-relative path. An id is the
-- filename stem; the same stemming the loose GRAPH_ROOTS lookup uses, so an
-- id means the same thing everywhere.
local function scanKind(fs, dir, sub, pattern, out)
    local root = join(dir, sub)
    local info = fs.getInfo(root)
    if not info or info.type ~= 'directory' then return end
    local items = fs.getDirectoryItems(root) or {}
    table.sort(items)
    for _, item in ipairs(items) do
        local id = item:match(pattern)
        if id then
            local ok = Pack.safeAssetPath(sub .. '/' .. item)
            if ok then out[id] = sub .. '/' .. item end
        end
    end
end

function ProjectMT:rescan()
    self.maps, self.graphs = {}, {}
    scanKind(self.fs, self.dir, Project.MAP_DIR, '^(.+)%.map$', self.maps)
    scanKind(self.fs, self.dir, Project.GRAPH_DIR, '^(.+)%.graph%.json$', self.graphs)
    scanKind(self.fs, self.dir, Project.GRAPH_DIR, '^(.+)%.json$', self.graphs)
    return self
end

-- The shape Pack.Registry.new():mount() takes. The registry then owns
-- id -> absolute-path resolution for every consumer the engine already has.
function ProjectMT:packManifest()
    return {
        id = self.manifest.id,
        name = self.manifest.name,
        version = self.manifest.version,
        maps = self.maps,
        graphs = self.graphs,
    }
end

function ProjectMT:mapPath(id)
    local rel = self.maps[id]
    return rel and join(self.dir, rel) or nil
end

function ProjectMT:graphPath(id)
    local rel = self.graphs[id]
    return rel and join(self.dir, rel) or nil
end

function ProjectMT:mapIds()
    local ids = {}
    for id in pairs(self.maps) do ids[#ids + 1] = id end
    table.sort(ids)
    return ids
end

-- Which map boots: the manifest's choice when it names one that exists,
-- otherwise the alphabetically-first map, otherwise nil (an empty project
-- boots to the menu, not to a crash).
function ProjectMT:startMapId()
    local want = self.manifest.startMap
    if want and self.maps[want] then return want end
    return self:mapIds()[1]
end

function ProjectMT:roots()
    return {
        maps = join(self.dir, Project.MAP_DIR),
        graphs = join(self.dir, Project.GRAPH_DIR),
        assets = join(self.dir, Project.ASSET_DIR),
    }
end

-- Persist a manifest change (startMap, version bump). Everything else about a
-- project lives in its files.
function ProjectMT:saveManifest()
    return self.fs.write(join(self.dir, Project.MANIFEST), json.encode(self.manifest))
end

---------------------------------------------------------------------------
-- Open and create
---------------------------------------------------------------------------

function Project.open(fs, dir)
    dir = norm(dir)
    local text = fs.read(join(dir, Project.MANIFEST))
    if not text then
        return nil, ('no %s in %s'):format(Project.MANIFEST, dir)
    end
    local manifest, errs = Project.parse(text)
    if not manifest then
        return nil, ('%s: %s'):format(dir, table.concat(errs, '; '))
    end
    local p = setmetatable({ fs = fs, dir = dir, manifest = manifest }, ProjectMT)
    return p:rescan()
end

-- The starter map: small, valid under the linter (spawn present and
-- reachable), and enough furniture that the first boot is a game, not a void.
local STARTER_MAP = table.concat({
    'name  First Level',
    'theme dungeon',
    'spawn 2.5 2.5 0',
    'entity i imp',
    'entity c crystal',
    '---',
    '################',
    '#..............#',
    '#..............#',
    '#....####......#',
    '#....#..#......#',
    '#....D..#......#',
    '#....#..#..c...#',
    '#....####......#',
    '#..........i...#',
    '#..............#',
    '#..............#',
    '################',
}, '\n') .. '\n'

-- Creates the folder skeleton and returns the opened project. Refuses to
-- create over an existing project — creation is never allowed to eat one.
function Project.create(fs, dir, name, opts)
    opts = opts or {}
    dir = norm(dir)
    local id, slugErr = Project.slug(name)
    if not id then return nil, slugErr end
    if fs.getInfo(join(dir, Project.MANIFEST)) then
        return nil, ('%s already holds a project'):format(dir)
    end

    for _, sub in ipairs{ '', Project.MAP_DIR, Project.GRAPH_DIR,
                          Project.ASSET_DIR, Project.ASSET_DIR .. '/sounds' } do
        local path = sub == '' and dir or join(dir, sub)
        local ok, err = fs.createDirectory(path)
        if not ok and not fs.getInfo(path) then
            return nil, ('cannot create %s: %s'):format(path, tostring(err))
        end
    end

    local manifest = {
        id = id,
        name = tostring(name),
        version = '0.1.0',
        engine = '>=1.0',
        startMap = 'level1',
    }
    local wrote, werr = fs.write(join(dir, Project.MANIFEST), json.encode(manifest))
    if not wrote then return nil, ('cannot write manifest: %s'):format(tostring(werr)) end

    if opts.starterMap ~= false then
        fs.write(join(dir, Project.MAP_DIR .. '/level1.map'), STARTER_MAP)
    end

    fs.write(join(dir, 'README.md'), table.concat({
        '# ' .. tostring(name),
        '',
        'A MeatRayCast project. From the engine folder:',
        '',
        '    love . --project ' .. dir .. '              play it',
        '    love . --editor --project ' .. dir .. '     edit it',
        '',
        'Maps in `maps/`, node graphs in `meatgraphs/`, art and sound in',
        '`assets/`. Saving a new `.map` into `maps/` adds it to the game —',
        'no manifest editing. `project.json` names the map that boots.',
    }, '\n') .. '\n')

    return Project.open(fs, dir)
end

---------------------------------------------------------------------------
-- The real filesystem
---------------------------------------------------------------------------

local WINDOWS = package.config:sub(1, 1) == '\\'

-- Listing a directory outside LÖVE's sandbox has no portable Lua API, so the
-- disk fs shells out for that one operation. Everything else is io/os.
local function diskList(dir)
    local cmd
    if WINDOWS then
        cmd = ('dir /b /a "%s" 2>nul'):format((dir:gsub('/', '\\')))
    else
        cmd = ("ls -1A '%s' 2>/dev/null"):format(dir)
    end
    local pipe = io.popen(cmd)
    if not pipe then return {} end
    local items = {}
    for line in pipe:lines() do
        if line ~= '' then items[#items + 1] = line end
    end
    pipe:close()
    return items
end

local function diskInfo(path)
    local f = io.open(path, 'rb')
    if f then
        f:close()
        return { type = 'file' }
    end
    -- Directories refuse io.open; os.rename-to-self succeeds iff the path
    -- exists at all. File was ruled out above, so what remains is a directory.
    local ok = os.rename(path, path)
    if ok then return { type = 'directory' } end
    return nil
end

-- Platform.fs-shaped access that follows the path: inside the LÖVE sandbox
-- (a project packaged into the fuse) it reads through love.filesystem; outside
-- it (a project folder on the real disk) it uses io and the shell. Writes
-- always go to the real disk — the sandbox write dir is save-game territory,
-- and a project is source, not save.
function Project.diskFs()
    local lfs = rawget(_G, 'love') and love.filesystem or nil
    local function inSandbox(path)
        return lfs and lfs.getInfo and lfs.getInfo(path) ~= nil
    end
    return {
        read = function(path)
            if inSandbox(path) then return lfs.read(path) end
            local f = io.open(path, 'rb')
            if not f then return nil end
            local text = f:read('*a')
            f:close()
            return text
        end,
        write = function(path, text)
            local f, err = io.open(path, 'wb')
            if not f then return false, err end
            f:write(text)
            f:close()
            return true
        end,
        getInfo = function(path)
            if inSandbox(path) then return lfs.getInfo(path) end
            return diskInfo(path)
        end,
        getDirectoryItems = function(path)
            if inSandbox(path) then return lfs.getDirectoryItems(path) end
            return diskList(path)
        end,
        createDirectory = function(path)
            local cmd
            if WINDOWS then
                cmd = ('mkdir "%s" 2>nul'):format((path:gsub('/', '\\')))
            else
                cmd = ("mkdir -p '%s' 2>/dev/null"):format(path)
            end
            os.execute(cmd)
            return diskInfo(path) ~= nil
        end,
    }
end

return Project
