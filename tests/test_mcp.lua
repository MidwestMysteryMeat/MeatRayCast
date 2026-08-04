--[[
    I3: the MCP server. The dispatcher speaks JSON-RPC properly (handshake,
    list, call, notifications answered by silence, garbage answered with an
    error object, never a crash); the engine tool registry creates projects,
    refuses unparseable map writes, lints, validates graphs and renders
    sounds — all against a fake filesystem.
]]

return function(t)
    local Mcp = require('meatray.net.mcp')
    local McpTools = require('meatray.net.mcp_tools')
    local json = require('meatray.net.json')

    local function fakeFs()
        local files = {}
        return {
            read = function(path) return files[path] end,
            write = function(path, text) files[path] = text; return true end,
            getInfo = function(path)
                if files[path] then return { type = 'file' } end
                local prefix = path .. '/'
                for p in pairs(files) do
                    if p:sub(1, #prefix) == prefix then
                        return { type = 'directory' }
                    end
                end
                return nil
            end,
            getDirectoryItems = function(path)
                local out, seen, prefix = {}, {}, path .. '/'
                for p in pairs(files) do
                    if p:sub(1, #prefix) == prefix then
                        local head = p:sub(#prefix + 1):match('^([^/]+)')
                        if head and not seen[head] then
                            seen[head] = true
                            out[#out + 1] = head
                        end
                    end
                end
                return out
            end,
            createDirectory = function() return true end,
            _files = files,
        }
    end

    local fs = fakeFs()
    local server = Mcp.new{ name = 'test', version = '9', tools = McpTools.build(fs) }

    local function call(msg) return json.decode(server:handle(json.encode(msg))) end
    local function callTool(name, args)
        return call{ jsonrpc = '2.0', id = 1, method = 'tools/call',
                     params = { name = name, arguments = args } }
    end
    local function toolText(resp) return resp.result.content[1].text end

    ---------------------------------------------------------------------
    t.describe('the JSON-RPC surface')

    local init = call{ jsonrpc = '2.0', id = 1, method = 'initialize', params = {} }
    t.eq(init.result.protocolVersion, Mcp.PROTOCOL, 'initialize reports the protocol')
    t.eq(init.result.serverInfo.name, 'test', 'and the server identity')
    t.ok(init.result.capabilities.tools, 'and the tools capability')

    t.eq(server:handle('{"jsonrpc":"2.0","method":"notifications/initialized"}'), nil,
        'a notification gets silence, not a reply')
    t.eq(server:handle(''), nil, 'a blank line gets silence')

    local bad = json.decode(server:handle('{ nope'))
    t.eq(bad.error.code, -32700, 'garbage gets a parse-error object, not a crash')

    local nope = call{ jsonrpc = '2.0', id = 2, method = 'wat' }
    t.eq(nope.error.code, -32601, 'an unknown method is -32601')

    t.ok(call{ jsonrpc = '2.0', id = 3, method = 'ping' }.result, 'ping pongs')

    local list = call{ jsonrpc = '2.0', id = 4, method = 'tools/list' }
    t.ok(#list.result.tools >= 8, 'a real tool set is listed', #list.result.tools)
    local seenNames = {}
    for _, tool in ipairs(list.result.tools) do
        seenNames[tool.name] = true
        t.ok(tool.inputSchema and tool.inputSchema.type == 'object',
            tool.name .. ' carries a schema')
    end
    t.ok(seenNames.project_create and seenNames.map_write and seenNames.sfx_render,
        'the expected tools are present')

    local unknown = callTool('frobnicate', {})
    t.eq(unknown.error.code, -32602, 'an unknown tool is a param error')

    ---------------------------------------------------------------------
    t.describe('an agent authors a project end to end')

    local made = callTool('project_create', { dir = 'p/game', name = 'Agent Game' })
    t.ok(not made.result.isError, 'project_create succeeds', toolText(made))
    t.ok(toolText(made):find('agent_game'), 'and reports the id')

    local again = callTool('project_create', { dir = 'p/game', name = 'Other' })
    t.ok(again.result.isError, 'creating over it is an isError result, not a crash')

    local info = callTool('project_info', { dir = 'p/game' })
    t.ok(toolText(info):find('level1'), 'project_info sees the starter map')

    local read = callTool('map_read', { path = 'p/game/maps/level1.map' })
    t.ok(toolText(read):find('spawn'), 'map_read returns the raw map text')

    local minfo = callTool('map_info', { path = 'p/game/maps/level1.map' })
    t.ok(toolText(minfo):find('16x12'), 'map_info reports the size', toolText(minfo))

    local lint = callTool('map_lint', { path = 'p/game/maps/level1.map' })
    t.ok(toolText(lint):find('lint clean'), 'the starter map lints clean')

    ---------------------------------------------------------------------
    t.describe('map_write lints and refuses garbage')

    local wrote = callTool('map_write', {
        path = 'p/game/maps/cell.map',
        text = 'name Cell\nspawn 1.5 1.5 0\n---\n####\n#..#\n####\n',
    })
    t.ok(not wrote.result.isError, 'a valid map writes', toolText(wrote))
    t.ok(fs._files['p/game/maps/cell.map'], 'and is on disk')

    local refused = callTool('map_write', { path = 'p/game/maps/bad.map', text = '\1\2garbage' })
    t.ok(refused.result.isError, 'unparseable text is refused')
    t.ok(not fs._files['p/game/maps/bad.map'], 'and nothing was written')

    ---------------------------------------------------------------------
    t.describe('graphs meet the same sandbox the runtime enforces')

    local MeatGraphRay = require('meatray.game.meatgraph_ray')
    fs.write('g/ok.graph.json', json.encode(MeatGraphRay.example()))
    local gok = callTool('graph_validate', { path = 'g/ok.graph.json' })
    t.ok(not gok.result.isError, 'the stock example passes', toolText(gok))

    fs.write('g/evil.graph.json',
        json.encode{ nodes = { { id = 1, kind = 'RunShellCommand' } }, links = {} })
    local gbad = callTool('graph_validate', { path = 'g/evil.graph.json' })
    t.ok(gbad.result.isError, 'a hostile node kind is refused')

    ---------------------------------------------------------------------
    t.describe('sounds render through the tool')

    local sfx = callTool('sfx_render', { preset = 'pickup', seed = 7, out = 'p/game/assets/sounds/p.wav' })
    t.ok(not sfx.result.isError, 'sfx_render succeeds', toolText(sfx))
    local wav = fs._files['p/game/assets/sounds/p.wav']
    t.ok(wav and wav:sub(1, 4) == 'RIFF', 'a real WAV landed in the project')

    local badPreset = callTool('sfx_render', { preset = 'kazoo', out = 'x.wav' })
    t.ok(badPreset.result.isError, 'an unknown preset is refused with a reason')

    ---------------------------------------------------------------------
    t.describe('a crashing tool does not kill the session')

    server:addTool{
        name = 'bomb', description = 'test',
        handler = function() error('boom') end,
    }
    local bombed = callTool('bomb', {})
    t.ok(bombed.result.isError and toolText(bombed):find('boom'),
        'the crash comes back as an isError result')
    t.ok(call{ jsonrpc = '2.0', id = 9, method = 'ping' }.result,
        'and the server still answers afterwards')
end
