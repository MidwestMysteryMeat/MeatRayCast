--[[
    meatray.net.mcp — a Model Context Protocol server, the protocol half.

    MCP is how AI agents (Claude Code, and anything else that speaks it) call
    tools in another process: JSON-RPC 2.0, one message per line over stdio.
    This module is the dispatcher — parse a line, run the method, build the
    reply — with no transport and no engine knowledge, so every path in it is
    asserted headless. The engine's actual tools live in mcp_tools.lua; the
    stdio loop lives in scripts/mcp_server.lua; each layer is a page.

    The protocol surface is the minimum a client needs, implemented honestly:

        initialize                 capability handshake (tools only)
        notifications/initialized  acknowledged by silence (it is a notification)
        ping                       liveness
        tools/list                 every tool with its JSON Schema
        tools/call                 run one; a tool FAILURE is a result with
                                   isError (the agent should read it), a
                                   protocol failure is a JSON-RPC error

    Malformed JSON, unknown methods and unknown tools all answer with the
    proper JSON-RPC error object rather than dying: the peer is an agent
    mid-conversation, and a server that exits on the first bad line takes
    the whole session down with it.
]]

local json = require('meatray.net.json')

local Mcp = {}
local McpMT = {}
McpMT.__index = McpMT

Mcp.PROTOCOL = '2024-11-05'

---------------------------------------------------------------------------
-- Construction
---------------------------------------------------------------------------

-- opts: name/version (serverInfo), tools = ordered list of
--   { name, description, inputSchema, handler = function(args) -> text | nil, err }
function Mcp.new(opts)
    opts = opts or {}
    local self = setmetatable({
        name = opts.name or 'meatraycast',
        version = opts.version or '0',
        tools = {},
        byName = {},
    }, McpMT)
    for _, tool in ipairs(opts.tools or {}) do self:addTool(tool) end
    return self
end

function McpMT:addTool(tool)
    assert(tool and tool.name and tool.handler, 'a tool needs a name and a handler')
    assert(not self.byName[tool.name], 'duplicate tool: ' .. tool.name)
    self.tools[#self.tools + 1] = tool
    self.byName[tool.name] = tool
    return tool
end

---------------------------------------------------------------------------
-- Replies
---------------------------------------------------------------------------

local function reply(id, result)
    return json.encode{ jsonrpc = '2.0', id = id, result = result }
end

local function fail(id, code, message)
    return json.encode{
        jsonrpc = '2.0', id = id,
        error = { code = code, message = message },
    }
end

-- A tool's answer: text content, flagged as an error or not. Tool failures
-- ride RESULTS on purpose — the agent is meant to read "map has 2 lint
-- errors" and act on it, not to see a dead RPC.
local function toolResult(id, text, isError)
    return reply(id, {
        content = json.array{ { type = 'text', text = tostring(text) } },
        isError = isError or false,
    })
end

---------------------------------------------------------------------------
-- Dispatch
---------------------------------------------------------------------------

-- One incoming line -> one outgoing line, or nil (notifications, blanks).
function McpMT:handle(line)
    if not line or line:match('^%s*$') then return nil end

    local ok, msg = pcall(json.decode, line)
    if not ok or type(msg) ~= 'table' then
        return fail(json.null, -32700, 'parse error')
    end

    local id = msg.id
    local method = msg.method

    -- A notification has no id and gets no reply, whatever it says.
    if id == nil then return nil end

    if method == 'initialize' then
        return reply(id, {
            protocolVersion = Mcp.PROTOCOL,
            capabilities = { tools = { listChanged = false } },
            serverInfo = { name = self.name, version = self.version },
        })
    end

    if method == 'ping' then
        return reply(id, { ok = true })
    end

    if method == 'tools/list' then
        local listed = json.array{}
        for _, tool in ipairs(self.tools) do
            listed[#listed + 1] = {
                name = tool.name,
                description = tool.description or '',
                inputSchema = tool.inputSchema
                    or { type = 'object', properties = {} },
            }
        end
        return reply(id, { tools = listed })
    end

    if method == 'tools/call' then
        local params = type(msg.params) == 'table' and msg.params or {}
        local tool = self.byName[params.name]
        if not tool then
            return fail(id, -32602, 'unknown tool: ' .. tostring(params.name))
        end
        local args = type(params.arguments) == 'table' and params.arguments or {}

        -- A tool that raises is a bug, but the SESSION survives it: the
        -- traceback goes back as an error result the agent can report.
        local callOk, text, err = pcall(tool.handler, args)
        if not callOk then
            return toolResult(id, 'tool crashed: ' .. tostring(text), true)
        end
        if text == nil then
            return toolResult(id, tostring(err or 'failed'), true)
        end
        return toolResult(id, text, false)
    end

    return fail(id, -32601, 'method not found: ' .. tostring(method))
end

return Mcp
