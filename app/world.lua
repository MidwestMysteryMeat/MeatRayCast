--[[
    app.world — how a level becomes the running world.

    Eighth cut of un-god-filing main.lua, and the largest: both loaders
    (procedural and authored), everything a fresh world adopts (automap,
    hazards, door auto-close, secrets, movers, ambient), map-trigger graph
    binding through the F9 sandbox, the pack scan, project mounting (H1/H5),
    and the one reloadMap every console/RCON/vote path goes through.

    The order inside loadAuthored is the contract other systems rely on:
    world first, then the player, then markers, then trigger binding — a
    graph's join/init fire with the world and the player already present.
]]

return function(ctx)
    local game, Game, MeatRay = ctx.game, ctx.Game, ctx.MeatRay
    local Entity, AI, Collide = ctx.Entity, ctx.AI, ctx.Collide
    local Movers, Map, Worldgen = ctx.Movers, ctx.Map, ctx.Worldgen
    local Mode, MeatGraphRay = ctx.Mode, ctx.MeatGraphRay
    local note, isAuthority = ctx.note, ctx.isAuthority
    local fireFor, pushFlash = ctx.fireFor, ctx.pushFlash

    local M = {}

    local GRAPH_ROOTS = { 'meatgraphs', 'graphs' }

    function M.readFileAny(path)
        if love and love.filesystem and love.filesystem.getInfo
           and love.filesystem.getInfo(path) then
            return love.filesystem.read(path)
        end
        local f = io.open(path, 'rb')
        if f then local t = f:read('*a'); f:close(); return t end
        return nil
    end

    -- A graph id -> its JSON text: a mounted pack first (B13 resolve), then a
    -- loose <root>/<id>.graph.json under the known folders. nil if nowhere.
    function M.resolveGraphText(id)
        if game.packs then
            local p = game.packs:resolve('graph', id)
            if p then local t = M.readFileAny(p); if t then return t end end
        end
        for _, root in ipairs(GRAPH_ROOTS) do
            for _, ext in ipairs({ '.graph.json', '.json' }) do
                local t = M.readFileAny(root .. '/' .. id .. ext)
                if t then return t end
            end
        end
        return nil
    end

    -- The api the graph runtime is given — spawn, gas, light, player count. Shared
    -- so a map-trigger graph gets exactly the same capabilities the CLI mode does.
    function M.graphApiOpts(world)
        return {
            log = function(msg) note(tostring(msg)) end,
            Entity = Entity, AI = AI,
            triggers = true,
            gas = world and fireFor(world) or nil,
            onLight = pushFlash,
            spawnEntity = function(kind, x, y)
                if not Entity.hasArchetype(kind) then return nil end
                local e = Entity.spawn(kind, x, y)
                if e then e:snapPrevious(); table.insert(game.entities, e) end
                return e
            end,
            playerCount = function()
                local n = 0
                for i = 1, #game.entities do
                    local e = game.entities[i]
                    if e and e:has('player') and not e.dead then n = n + 1 end
                end
                return n
            end,
            seed = game.seed,
        }
    end

    -- Loads one graph and binds the map volumes that name it. Returns the bound
    -- Mode, or nil plus a reason (which the caller logs).
    function M.bindTriggerGraph(graphId, vols, world)
        local text = M.resolveGraphText(graphId)
        if not text then return nil, 'graph not found: ' .. graphId end
        local g, err = MeatGraphRay.load(text)
        if not g then return nil, ('parse failed (%s): %s'):format(graphId, tostring(err)) end
        local hardened, errs = MeatGraphRay.harden(g)
        if not hardened then
            return nil, ('refused (%s): %s'):format(graphId, table.concat(errs, '; '))
        end
        -- The volumes are the ones drawn on the map, not any the graph declared.
        hardened.volumes = {}
        for _, tr in ipairs(vols) do
            hardened.volumes[#hardened.volumes + 1] = {
                name = tr.name, once = tr.once, filter = tr.filter,
                x1 = tr.x1, y1 = tr.y1, x2 = tr.x2, y2 = tr.y2,
            }
        end
        local mode = Mode.new{ name = 'trig:' .. graphId }
        MeatGraphRay.bindMode(mode, hardened, M.graphApiOpts(world))
        mode:start(world, game.entities)
        if game.player then mode:playerJoin(0, game.player) end
        return mode
    end

    -- Binds every trigger a map declared. Grouped by graph so a graph referenced by
    -- three volumes loads once. The bound modes tick alongside game.mode in
    -- simulate(); resetting the list here is what unbinds the previous level's.
    function M.bindMapTriggers(world)
        game.triggerModes = {}
        local list = world and world.triggers
        if not list or #list == 0 then return end

        local byGraph, order = {}, {}
        for _, tr in ipairs(list) do
            if tr.graph and tr.graph ~= '' then
                if not byGraph[tr.graph] then byGraph[tr.graph] = {}; order[#order + 1] = tr.graph end
                table.insert(byGraph[tr.graph], tr)
            else
                note('trigger "' .. tostring(tr.name) .. '" has no graph — skipped')
            end
        end

        local bound = 0
        for _, graphId in ipairs(order) do
            local mode, why = M.bindTriggerGraph(graphId, byGraph[graphId], world)
            if mode then
                game.triggerModes[#game.triggerModes + 1] = mode
                bound = bound + 1
            else
                note('trigger ' .. tostring(why))
            end
        end
        if bound > 0 then
            note(('bound %d trigger graph(s) from the map'):format(bound))
        end
    end

    -----------------------------------------------------------------------
    -- World loading, from either source
    -----------------------------------------------------------------------

    function M.spawnPlayerAt(x, y, angle)
        if not game.wantPlayer then return nil end
        local p = Entity.spawn('player', x, y)
        p.angle = angle or 0
        -- Stand on the walk surface under the spawn, not at z=0 over a raised tile.
        if game.world then Collide.ground(p, game.world) end
        p:snapPrevious()
        game.player = p
        game.aim = p.angle
        table.insert(game.entities, p)
        return p
    end

    function M.setTheme(theme)
        if MeatRay.canRender() then MeatRay.raycaster.setTheme(theme) end
    end

    -- F2/F5: everything that adopts a fresh world. The automap starts blank and
    -- re-looks on shape changes; the hazard kit picks up whatever boxes the map
    -- headers declared (nil when there are none, so the tick can skip it).
    local DOOR_AUTOCLOSE = 6   -- C17: seconds a door stays open before re-closing

    -- C21: fire a stock graph event on every running graph — the CLI mode and every
    -- map-trigger graph — using each one's live api. The demo's producers (a secret
    -- found, later a dialogue advance) call this rather than reaching into a mode.
    function M.fireGraphEvent(event, env)
        local function fireOn(mode)
            local d = mode and mode.data
            if d and d._ngGraph and d._ngApi then
                d._ngGraph:fire(event, d._ngApi, env or {})
            end
        end
        fireOn(game.mode)
        for _, m in ipairs(game.triggerModes or {}) do fireOn(m) end
    end

    function M.adoptWorldForAutomap(world)
        game.automap:reset()
        game.automapDirty = false
        game.bots = {}          -- C22: old-world bot entities are stale on reload
        game.crowd = nil        -- I1: same for the flock and its flow field
        game.crowdGoal = nil
        world:watchShape(function() game.automapDirty = true end)
        -- C17: doors re-close on their own after a beat, waiting on anyone in the
        -- doorway (see stepRules). A door authored with an explicit timer keeps it.
        world:setAllDoorsAutoClose(DOOR_AUTOCLOSE)

        game.hazards = nil
        if world.hazards and #world.hazards > 0 then
            game.hazards = Game.hazards.new()
            game.hazards:fromWorld(world)
        end
    end

    function M.loadProcedural()
        local theme = 'dungeon'
        if MeatRay.canRender() then
            local themes = MeatRay.themes.names()
            theme = themes[(game.seed % #themes) + 1]
        end

        game.worldSpec = {
            width = 44, height = 44, seed = game.seed, doorChance = 0.5, theme = theme,
        }

        local world, rooms = Worldgen.generate(game.worldSpec)

        game.world = world
        game.entities = {}
        game.player = nil
        M.setTheme(theme)
        M.adoptWorldForAutomap(world)

        local spawn = world.spawn or { x = 4.5, y = 4.5 }
        M.spawnPlayerAt(spawn.x, spawn.y, 0)

        -- One creature per room after the first, alternating kinds.
        for i = 2, #rooms do
            local room = rooms[i]
            local kind = (i % 2 == 0) and 'imp' or 'crystal'
            local e = Entity.spawn(kind, room.cx + 0.5, room.cy + 0.5)
            e.angle = (i * 0.7) % (math.pi * 2)
            e:snapPrevious()
            table.insert(game.entities, e)
        end

        game.source = 'procedural'
        game.triggerModes = nil   -- B10: a procedural world declares no triggers
        game.movers = nil         -- C-map: and no authored lifts
        game.ambient = nil        -- C31: and no ambient zones
        note(('procedural world, seed %d, theme %s, %d rooms'):format(game.seed, theme, #rooms))
    end

    -- opts.arrival = { x, y, angle } from a storey link overrides map spawn.
    function M.loadAuthored(path, opts)
        opts = opts or {}
        path = path or 'maps/arena.map'

        -- Sandbox first, real disk second: a project map lives outside PhysFS.
        local contents = M.readFileAny(path)
        if not contents then
            -- Relative path without maps/ prefix.
            if not path:match('^maps/') and not path:match('%.map$') then
                return M.loadAuthored('maps/' .. path .. '.map', opts)
            end
            note('could not read ' .. path .. ' - falling back to procedural')
            return M.loadProcedural()
        end

        local map, errs = Map.parse(contents)
        if not map then
            note('map error: ' .. tostring(errs and errs[1]))
            return M.loadProcedural()
        end

        local world, markers, spawn = Map.toWorld(map)
        game.world = world
        game.entities = {}
        game.player = nil
        M.adoptWorldForAutomap(world)
        game.worldSpec = nil          -- an authored map is sent as a grid, not a seed
        game.mapPath = path
        game.mapLinks = map.links
        M.setTheme(map.theme)

        -- Secret areas the map declared. Discovery notes itself and keeps the
        -- running count for the intermission stat (F4, when it lands).
        game.secretTracker = nil
        game.secretWorld = nil
        if world.secrets and #world.secrets > 0 then
            game.secretTracker = Game.secrets.new{
                onFound = function(area)
                    if game.campaign and game.campaign.state == 'mission' then
                        game.campaign:addSecret(1)
                    end
                    game.messages:pickup(('secret found%s — %d/%d')
                        :format(area.name and (': ' .. area.name) or '',
                                game.secretTracker:found(), game.secretTracker:total()))
                    -- C21: let a graph react to the secret (EventOnSecret).
                    M.fireGraphEvent('secret', { secret = area.name or '' })
                end,
            }
            game.secretTracker:fromWorld(world)
            game.secretWorld = world
        end

        spawn = spawn or { x = 2.5, y = 2.5, angle = 0 }
        local sx, sy, sa = spawn.x, spawn.y, spawn.angle or 0
        if opts.arrival and opts.arrival.x and opts.arrival.y then
            sx, sy = opts.arrival.x, opts.arrival.y
            sa = opts.arrival.angle or sa
        end
        M.spawnPlayerAt(sx, sy, sa)

        for _, m in ipairs(markers) do
            if Entity.hasArchetype(m.kind) then
                local e = Entity.spawn(m.kind, m.x, m.y)
                e.angle = m.angle or 0
                e.storey = m.storey or 1
                Collide.ground(e, world)
                e:snapPrevious()
                table.insert(game.entities, e)
            else
                note('map references unknown archetype: ' .. tostring(m.kind))
            end
        end

        game.source = 'authored'
        -- B10: bind any trigger volumes the map placed to their graphs. After the
        -- world and the player exist, so a graph's join/init fire with them present.
        M.bindMapTriggers(world)
        -- C-map: build the lift host from the map's `mover` directives and drive it
        -- from simulate(). A mover animates floorHeights, which collision and the
        -- renderer already read, so nothing else needs to know it exists.
        game.movers = nil
        if world.movers and #world.movers > 0 then
            game.movers = Movers.new(world)
            for _, mv in ipairs(world.movers) do game.movers:add(mv) end
            note(('%d mover(s) — `mover <id>` to call'):format(#world.movers))
        end
        -- C31: a room-tone tracker if the map declared ambient zones.
        game.ambient = world.ambientZones and #world.ambientZones > 0
                       and Game.ambient.new(world.ambientZones) or nil
        local n = world.storeyCount and world:storeyCount() or 1
        local linkHint = ''
        if n > 1 then
            linkHint = ('  (%d storeys — F on stairs)'):format(n)
        elseif map.links and (map.links.up or map.links.down) then
            linkHint = '  (F on stairs to change map)'
        end
        note(('authored map "%s", theme %s, %d markers%s'):format(
            map.name, map.theme, #markers, linkHint))
    end

    -- B14: after a loader rebuilt game.world/game.entities, hand them to a running
    -- host so it swaps the world live and re-syncs every client. Without this a
    -- `map` while hosting reassigns the demo's globals and strands the host on the
    -- old world — it keeps simulating the level the clients can no longer see.
    function M.hostAdoptWorld(mapName)
        if not game.host then return end
        game.host:changeWorld(game.world, game.entities, game.worldSpec, {
            localPlayer = game.player, map = mapName,
        })
        -- C18: the new map's lifts (nil if it has none) — changeWorld cleared the old.
        game.host:setMovers(game.movers)
        note('host swapped to ' .. tostring(mapName) .. ' — clients re-synced')
    end

    -- The one place a map change goes through, so console, RCON and votes all get
    -- the live host swap for free. `name` is a pack map id, a maps/ name, or
    -- 'procedural'.
    function M.reloadMap(name)
        if name == 'procedural' or name == 'proc' then
            M.loadProcedural()
        else
            local packPath = game.packs and game.packs:resolve('map', name)
            M.loadAuthored(packPath or ('maps/' .. name .. '.map'))
        end
        M.hostAdoptWorld(name)
    end

    function M.resolveMapPath(path)
        if not path or path == '' then return nil end
        if path:match('%.map$') then
            if path:find('/') or path:find('\\') then return path end
            return 'maps/' .. path
        end
        if path:match('^maps/') then return path .. '.map' end
        return 'maps/' .. path .. '.map'
    end

    -- B13: scan a packs/ directory and mount everything with a valid manifest.
    -- A pack is a folder under packs/ holding a pack.json; mounting it makes its
    -- maps and graphs loadable by id. Packs are mounted in name order, so a pack
    -- that depends on another must sort after it (or the caller re-runs the scan);
    -- an unmet dependency or a hostile path is logged and skipped, never fatal.
    function M.scanPacks()
        game.packs = Game.pack.Registry.new()
        if not (love and love.filesystem and love.filesystem.getInfo) then return end
        local info = love.filesystem.getInfo('packs')
        if not info or info.type ~= 'directory' then return end

        local names = love.filesystem.getDirectoryItems('packs')
        table.sort(names)
        local mounted = 0
        -- Two passes, so a pack whose dependency sorts after it still mounts: the
        -- second pass retries whatever the first deferred once its deps are in.
        for _ = 1, 2 do
            for _, name in ipairs(names) do
                local root = 'packs/' .. name
                if not game.packs:isMounted(name)
                   and love.filesystem.getInfo(root .. '/pack.json') then
                    local text = love.filesystem.read(root .. '/pack.json')
                    local manifest, errs = Game.pack.parse(text or '')
                    if not manifest then
                        note(('pack %q ignored: %s'):format(name, (errs or {})[1] or '?'))
                    else
                        local ok, why = game.packs:mount(manifest, root)
                        if ok then mounted = mounted + 1
                        else note(('pack %q not mounted: %s'):format(name, why)) end
                    end
                end
            end
        end
        if mounted > 0 then
            note(('mounted %d asset pack(s) from packs/'):format(mounted))
        end
    end

    -- H1: mount a game project folder. The project scans its own maps/ and
    -- meatgraphs/ and mounts into game.packs like any pack, so `map <id>`,
    -- trigger-graph binding and the campaign resolve its content through the
    -- lookups the engine already has. Failure is a console line, never fatal:
    -- the demo underneath is always a runnable game.
    function M.mountProject(dir)
        if not dir then return false end
        local proj, err = Game.project.open(Game.project.diskFs(), dir)
        if not proj then
            note('project: ' .. tostring(err))
            return false
        end
        local ok, mountErr = game.packs:mount(proj:packManifest(), proj.dir)
        if not ok then
            note('project not mounted: ' .. tostring(mountErr))
            return false
        end
        game.project = proj
        note(('project "%s" — %d map(s), start %s'):format(
            proj.manifest.name, #proj:mapIds(), tostring(proj:startMapId())))

        -- H5: the project's own gameplay code, run once, now — after the mount
        -- (its assets resolve) and before the first map loads (its archetypes
        -- exist when markers spawn). A broken game.lua is a console line and a
        -- playable stock demo, never a dead boot. The api it receives is the
        -- VERSIONED contract in meatray.game.project_api: the named surface is
        -- a semver promise, api.raw is the unpromised escape hatch.
        local setup, entryErr = proj:loadEntry()
        if setup then
            local api = require('meatray.game.project_api').build{
                game = game, proj = proj,
                note = note, isAuthority = isAuthority,
                engine = MeatRay,
            }
            local okRun, perr = pcall(setup, api)
            if okRun then
                note('project gameplay loaded (game.lua)')
            else
                note('project game.lua failed: ' .. tostring(perr))
            end
        elseif entryErr then
            note('project game.lua refused: ' .. tostring(entryErr))
        end
        return true
    end

    return M
end
