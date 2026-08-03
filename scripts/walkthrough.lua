--[[
    The blank-folder-to-game walkthrough, executed rather than described.

        luajit scripts/walkthrough.lua [dir]

    Walks the whole authoring loop the way a developer would, using only
    public engine APIs — create a project, author a second map, wire a
    trigger graph, synthesize sounds, lint everything — and exits non-zero
    the moment any step refuses. The packaging half of the loop is a
    PowerShell step, so this script ends by printing it; pairing the two is
    what "a stranger can go from nothing to a shipped exe" means:

        luajit scripts/walkthrough.lua
        powershell -File scripts/package.ps1 -Project build/walkthrough_game

    Default dir is build/walkthrough_game — inside the gitignored build/
    output, wiped and recreated on every run so the walkthrough always
    exercises the from-nothing path.
]]

package.path = package.path .. ';./?.lua;./?/init.lua'

local Project = require('meatray.game.project')
local Map = require('meatray.sim.map')
local Maplint = require('meatray.sim.maplint')
local Sfx = require('meatray.asset.sfx')
local json = require('meatray.net.json')

local dir = arg[1] or 'build/walkthrough_game'
local failed = false

local function step(label, ok, detail)
    print(('  [%s] %s%s'):format(ok and 'OK' or 'FAIL', label,
        detail and (' — ' .. tostring(detail)) or ''))
    if not ok then failed = true end
    return ok
end

print('MeatRayCast walkthrough: nothing -> game at ' .. dir)

---------------------------------------------------------------------------
-- 1. A fresh project
---------------------------------------------------------------------------

local fs = Project.diskFs()

-- From nothing, every run: stale state would hide creation bugs.
if fs.getInfo(dir .. '/' .. Project.MANIFEST) then
    os.execute((package.config:sub(1, 1) == '\\')
        and ('rmdir /s /q "%s"'):format((dir:gsub('/', '\\')))
        or ("rm -rf '%s'"):format(dir))
end

local proj, err = Project.create(fs, dir, 'Walkthrough Game')
if not step('create project', proj ~= nil, err) then os.exit(1) end
step('starter map is the start map', proj:startMapId() == 'level1')

---------------------------------------------------------------------------
-- 2. Author a second level, by editing the model the editor edits
---------------------------------------------------------------------------

local text = fs.read(proj:mapPath('level1'))
local map = Map.parse(text)
map.name = 'The Second Room'
-- One more enemy and one more pickup, placed on open floor.
map.entities[#map.entities + 1] = { kind = 'imp', x = 2.5, y = 9.5 }
map.entities[#map.entities + 1] = { kind = 'crystal', x = 13.5, y = 2.5 }

local serialized = Map.serialize(map)
local reparsed, perrs = Map.parse(serialized)
step('edited map round-trips', reparsed ~= nil, perrs and perrs[1])

step('save level2 into the project',
    fs.write(dir .. '/maps/level2.map', serialized))

proj:rescan()
step('the scan picked the new map up', proj:mapPath('level2') ~= nil)

proj.manifest.startMap = 'level2'
step('point the project at it', proj:saveManifest())

local reopened = Project.open(fs, dir)
step('a reopen agrees', reopened and reopened:startMapId() == 'level2')

---------------------------------------------------------------------------
-- 3. A trigger graph, hardened exactly as the runtime will harden it
---------------------------------------------------------------------------

local MeatGraphRay = require('meatray.game.meatgraph_ray')
local graph = MeatGraphRay.example()
local hardened, herr = MeatGraphRay.harden(graph)
step('the graph passes the sandbox gate', hardened ~= nil, herr)
step('save it into the project',
    fs.write(dir .. '/meatgraphs/welcome.graph.json', json.encode(graph)))
reopened:rescan()
step('the graph scan sees it', reopened:graphPath('welcome') ~= nil)

---------------------------------------------------------------------------
-- 4. Sounds, synthesized into the project
---------------------------------------------------------------------------

for _, name in ipairs{ 'pickup', 'hurt', 'explosion' } do
    local bytes = Sfx.wav(Sfx.preset(name))
    step('synthesize ' .. name .. '.wav',
        fs.write(dir .. '/assets/sounds/' .. name .. '.wav', bytes)
        and #bytes > 1000, #bytes .. ' bytes')
end

---------------------------------------------------------------------------
-- 5. Lint every map in the project — the same gate the editor runs on save
---------------------------------------------------------------------------

for _, id in ipairs(reopened:mapIds()) do
    local m = Map.parse(fs.read(reopened:mapPath(id)))
    local report = Maplint.check(m)
    step(('lint %s: %d error(s)'):format(id, #report.errors),
        #report.errors == 0, report.errors[1] and report.errors[1].text)
end

---------------------------------------------------------------------------

if failed then
    print('WALKTHROUGH FAILED')
    os.exit(1)
end

print('WALKTHROUGH OK — now fuse and boot it:')
print(('  powershell -ExecutionPolicy Bypass -File scripts/package.ps1 -Project %s'):format(dir))
os.exit(0)
