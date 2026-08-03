--[[
    H1: projects. A game is a folder the engine points at: project.json for
    identity, scanned maps/ and meatgraphs/ for content. Creation builds a
    skeleton that opens, lints and mounts; opening refuses garbage with a
    reason; the scan (not the manifest) is the truth about content; the pack
    manifest it produces mounts in the existing registry so every pack-aware
    code path resolves project assets unchanged.
]]

return function(t)
    local Project = require('meatray.game.project')
    local Game = require('meatray.game')
    local Pack = require('meatray.game.pack')
    local Map = require('meatray.sim.map')
    local Maplint = require('meatray.sim.maplint')

    t.eq(Game.project, Project, 'Game.project is the module')

    -- A Platform.fs-shaped fake over a table, directories included, so every
    -- path below runs with no disk and no host.
    local function fakeFs()
        local files, dirs = {}, {}
        return {
            read = function(path) return files[path] end,
            write = function(path, text)
                files[path] = text
                return true
            end,
            getInfo = function(path)
                if files[path] then return { type = 'file' } end
                if dirs[path] then return { type = 'directory' } end
                return nil
            end,
            getDirectoryItems = function(path)
                local out, prefix = {}, path .. '/'
                local seen = {}
                for p in pairs(files) do
                    if p:sub(1, #prefix) == prefix then
                        local rest = p:sub(#prefix + 1)
                        local head = rest:match('^([^/]+)')
                        if head and not seen[head] then
                            seen[head] = true
                            out[#out + 1] = head
                        end
                    end
                end
                return out
            end,
            createDirectory = function(path)
                dirs[path] = true
                return true
            end,
            _files = files,
        }
    end

    ---------------------------------------------------------------------
    t.describe('slugs: a folder name from a display name')

    t.eq(Project.slug('My First Game!'), 'my_first_game', 'words joined, punctuation dropped')
    t.eq(Project.slug('  FPS 2  '), 'fps_2', 'trimmed at both ends')
    t.ok(not Project.slug('!!!'), 'a name with nothing usable in it is refused')

    ---------------------------------------------------------------------
    t.describe('manifest validation refuses with reasons')

    t.ok(Project.validate{ id = 'x', name = 'X', version = '1' }, 'minimal manifest passes')
    local ok, errs = Project.validate{ name = 'X' }
    t.ok(not ok and #errs >= 2, 'missing id and version are both named')
    t.ok(not Project.validate{ id = 'a b', name = 'X', version = '1' },
        'an id with a space is refused')
    t.ok(not Project.parse('{ nope'), 'bad JSON is refused, not raised')

    ---------------------------------------------------------------------
    t.describe('create builds a skeleton that opens')

    local fs = fakeFs()
    local p, err = Project.create(fs, 'projects/demo_game', 'Demo Game')
    t.ok(p, 'create succeeds (' .. tostring(err) .. ')')
    t.eq(p.manifest.id, 'demo_game', 'id is the slug of the name')
    t.eq(p.manifest.startMap, 'level1', 'the starter map is the start map')
    t.ok(fs.read('projects/demo_game/project.json'), 'manifest written')
    t.ok(fs.read('projects/demo_game/README.md'), 'README written')

    t.eq(p:startMapId(), 'level1', 'startMapId resolves')
    t.eq(p:mapPath('level1'), 'projects/demo_game/maps/level1.map', 'map path is dir-joined')

    ---------------------------------------------------------------------
    t.describe('the starter map is a real, lintable level')

    local map, perrs = Map.parse(fs.read(p:mapPath('level1')))
    t.ok(map, 'starter map parses (' .. tostring(perrs and perrs[1]) .. ')')
    local report = Maplint.check(map)
    t.eq(#report.errors, 0, 'starter map has zero lint errors',
        report.errors[1] and report.errors[1].message)

    ---------------------------------------------------------------------
    t.describe('creation never eats an existing project')

    local again, why = Project.create(fs, 'projects/demo_game', 'Other Name')
    t.ok(not again and why:find('already'), 'refused with a reason')
    t.ok(fs.read('projects/demo_game/project.json'):find('demo_game'),
        'and the original manifest is untouched')

    ---------------------------------------------------------------------
    t.describe('the scan is the truth about content')

    fs.write('projects/demo_game/maps/cave.map', 'name Cave\nspawn 1.5 1.5 0\n---\n####\n#..#\n####\n')
    fs.write('projects/demo_game/meatgraphs/doors.graph.json', '{}')
    fs.write('projects/demo_game/maps/notes.txt', 'not a map')
    p:rescan()
    t.eq(p:mapPath('cave'), 'projects/demo_game/maps/cave.map', 'a saved map appears with no manifest edit')
    t.eq(p:graphPath('doors'), 'projects/demo_game/meatgraphs/doors.graph.json', 'graphs too')
    t.ok(not p.maps['notes'], 'a stray non-map file is not a map')

    local ids = p:mapIds()
    t.eq(#ids, 2, 'two maps known')
    t.eq(ids[1], 'cave', 'ids come sorted')

    ---------------------------------------------------------------------
    t.describe('startMap falls back sanely')

    p.manifest.startMap = 'missing'
    t.eq(p:startMapId(), 'cave', 'a dangling startMap falls back to the first map')
    p.manifest.startMap = 'level1'
    t.eq(p:startMapId(), 'level1', 'a real startMap wins')

    ---------------------------------------------------------------------
    t.describe('an opened project mounts in the pack registry as-is')

    local reg = Pack.Registry.new()
    local mounted, mountErr = reg:mount(p:packManifest(), p.dir)
    t.ok(mounted, 'mounts (' .. tostring(mountErr) .. ')')
    local path = reg:resolve('map', 'level1')
    t.eq(path, 'projects/demo_game/maps/level1.map', 'the registry resolves a project map')
    t.eq(reg:resolve('graph', 'doors'), 'projects/demo_game/meatgraphs/doors.graph.json',
        'and a project graph')

    ---------------------------------------------------------------------
    t.describe('open refuses what is not a project')

    local nope, whyNot = Project.open(fs, 'projects/elsewhere')
    t.ok(not nope and whyNot:find('no project.json'), 'a folder with no manifest is refused with the reason')

    fs.write('projects/broken/project.json', '{ "name": "x" }')
    local broken, brokenWhy = Project.open(fs, 'projects/broken')
    t.ok(not broken and brokenWhy:find('id'), 'a manifest missing its id is refused naming the field')

    ---------------------------------------------------------------------
    t.describe('saveManifest persists a change')

    p.manifest.startMap = 'cave'
    t.ok(p:saveManifest(), 'writes')
    local reopened = Project.open(fs, 'projects/demo_game')
    t.eq(reopened:startMapId(), 'cave', 'the change survived a reopen')
end
