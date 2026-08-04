--[[
    meatray.net.mcp_tools — what the engine offers an AI agent.

    The tool registry the MCP server serves: authoring operations an agent
    can do to a game project from outside the process — create it, read and
    write its maps (never without linting), validate its graphs against the
    same sandbox the runtime enforces, synthesize its sounds. Everything
    here is a thin face on modules the suite already asserts; a tool adds
    no behaviour of its own beyond formatting an answer.

    Filesystem access is injected (Project.diskFs shape) so the whole
    registry runs against a fake in tests. Handlers return (text) on
    success or (nil, reason) on refusal — mcp.lua turns the latter into an
    isError result the agent reads, not a dead RPC.

    HEADLESS: pure Lua.
]]

local Project = require('meatray.game.project')
local Map = require('meatray.sim.map')
local Maplint = require('meatray.sim.maplint')
local Sfx = require('meatray.asset.sfx')
local MeatGraphRay = require('meatray.game.meatgraph_ray')
local json = require('meatray.net.json')

local McpTools = {}

local function lintText(report)
    local lines = {}
    for _, e in ipairs(report.errors) do
        lines[#lines + 1] = 'ERROR ' .. e.text
    end
    for _, w in ipairs(report.warnings) do
        lines[#lines + 1] = 'warn  ' .. w.text
    end
    if #lines == 0 then return 'lint clean' end
    return table.concat(lines, '\n')
end

-- fs: Project.diskFs() in production, a fake in tests.
function McpTools.build(fs)
    local tools = {}
    local function tool(t) tools[#tools + 1] = t end

    local function readMap(path)
        local text = fs.read(path)
        if not text then return nil, 'cannot read ' .. tostring(path) end
        local map, errs = Map.parse(text)
        if not map then
            return nil, path .. ' does not parse: ' .. tostring(errs and errs[1])
        end
        return map
    end

    ---------------------------------------------------------------------

    tool{
        name = 'project_create',
        description = 'Create a new game project folder (project.json, starter map, asset dirs).',
        inputSchema = { type = 'object',
            properties = { dir = { type = 'string' }, name = { type = 'string' } },
            required = { 'dir', 'name' } },
        handler = function(args)
            local proj, err = Project.create(fs, tostring(args.dir), tostring(args.name))
            if not proj then return nil, err end
            return ('created %s (id %s) — start map %s'):format(
                proj.dir, proj.manifest.id, tostring(proj:startMapId()))
        end,
    }

    tool{
        name = 'project_info',
        description = 'Read a project: identity, its maps and graphs, which map boots.',
        inputSchema = { type = 'object',
            properties = { dir = { type = 'string' } }, required = { 'dir' } },
        handler = function(args)
            local proj, err = Project.open(fs, tostring(args.dir))
            if not proj then return nil, err end
            local m = proj.manifest
            local lines = {
                ('%s v%s (id %s) at %s'):format(m.name, m.version, m.id, proj.dir),
                'start map: ' .. tostring(proj:startMapId()),
                'maps: ' .. table.concat(proj:mapIds(), ', '),
            }
            local graphs = {}
            for id in pairs(proj.graphs) do graphs[#graphs + 1] = id end
            table.sort(graphs)
            lines[#lines + 1] = 'graphs: ' ..
                (#graphs > 0 and table.concat(graphs, ', ') or '(none)')
            return table.concat(lines, '\n')
        end,
    }

    ---------------------------------------------------------------------

    tool{
        name = 'map_read',
        description = 'Read a .map file verbatim (the text grid format).',
        inputSchema = { type = 'object',
            properties = { path = { type = 'string' } }, required = { 'path' } },
        handler = function(args)
            local text = fs.read(tostring(args.path))
            if not text then return nil, 'cannot read ' .. tostring(args.path) end
            return text
        end,
    }

    tool{
        name = 'map_info',
        description = 'Parse a map and report name, theme, size, spawn, entities, doors, storeys.',
        inputSchema = { type = 'object',
            properties = { path = { type = 'string' } }, required = { 'path' } },
        handler = function(args)
            local map, err = readMap(tostring(args.path))
            if not map then return nil, err end
            return table.concat({
                ('name: %s'):format(map.name or 'untitled'),
                ('theme: %s'):format(map.theme or 'dungeon'),
                ('size: %dx%d, %d storey(s)'):format(map.width, map.height,
                    #(map.storeys or { 1 })),
                ('spawn: %s'):format(map.spawn
                    and ('%.1f, %.1f'):format(map.spawn.x, map.spawn.y) or 'none'),
                ('entities: %d, doors: %d'):format(#(map.entities or {}),
                    #(map.doors or {})),
            }, '\n')
        end,
    }

    tool{
        name = 'map_lint',
        description = 'Run the map validation linter (reachability, spawn/exit/lock sanity).',
        inputSchema = { type = 'object',
            properties = { path = { type = 'string' } }, required = { 'path' } },
        handler = function(args)
            local map, err = readMap(tostring(args.path))
            if not map then return nil, err end
            return lintText(Maplint.check(map))
        end,
    }

    tool{
        name = 'map_write',
        description = 'Write a .map file. Refused unless the text parses; the lint report comes back with the write.',
        inputSchema = { type = 'object',
            properties = { path = { type = 'string' }, text = { type = 'string' } },
            required = { 'path', 'text' } },
        handler = function(args)
            local map, errs = Map.parse(tostring(args.text))
            if not map then
                return nil, 'refused: text does not parse: ' .. tostring(errs and errs[1])
            end
            local report = Maplint.check(map)
            local ok, werr = fs.write(tostring(args.path), tostring(args.text))
            if not ok then return nil, 'write failed: ' .. tostring(werr) end
            return ('wrote %s (%dx%d)\n%s'):format(tostring(args.path),
                map.width, map.height, lintText(report))
        end,
    }

    ---------------------------------------------------------------------

    tool{
        name = 'graph_validate',
        description = 'Validate a MeatGraphRay graph against the runtime mod sandbox (node allowlist, caps).',
        inputSchema = { type = 'object',
            properties = { path = { type = 'string' } }, required = { 'path' } },
        handler = function(args)
            local text = fs.read(tostring(args.path))
            if not text then return nil, 'cannot read ' .. tostring(args.path) end
            local ok, decoded = pcall(json.decode, text)
            if not ok then return nil, 'not JSON: ' .. tostring(decoded) end
            local hardened, why = MeatGraphRay.harden(decoded)
            if not hardened then return nil, 'sandbox refuses it: ' .. tostring(why) end
            return ('graph passes the sandbox: %d node(s)'):format(
                #(decoded.nodes or {}))
        end,
    }

    tool{
        name = 'sfx_render',
        description = 'Synthesize a sound effect (preset + optional seed variation) to a WAV file.',
        inputSchema = { type = 'object',
            properties = {
                preset = { type = 'string',
                    description = table.concat(Sfx.presetNames(), ' | ') },
                seed = { type = 'number' },
                out = { type = 'string' },
            },
            required = { 'preset', 'out' } },
        handler = function(args)
            local params, err
            if args.seed and tonumber(args.seed) then
                params, err = Sfx.randomize(tostring(args.preset), tonumber(args.seed))
            else
                params, err = Sfx.preset(tostring(args.preset))
            end
            if not params then return nil, err end
            local bytes = Sfx.wav(params)
            local ok, werr = fs.write(tostring(args.out), bytes)
            if not ok then return nil, 'write failed: ' .. tostring(werr) end
            return ('%s -> %s (%d bytes, %.2fs)'):format(tostring(args.preset),
                tostring(args.out), #bytes, Sfx.duration(params))
        end,
    }

    return tools
end

return McpTools
