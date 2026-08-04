--[[
    The MCP server: MeatRayCast as a tool an AI agent can use.

        luajit scripts/mcp_server.lua

    Speaks Model Context Protocol over stdio (one JSON-RPC message per
    line). Register it with Claude Code from the engine folder:

        claude mcp add meatraycast -- luajit scripts/mcp_server.lua

    and the agent gains the engine's authoring surface: create projects,
    read/lint/write maps, validate graphs against the runtime sandbox,
    synthesize sounds. The protocol lives in meatray.net.mcp, the tools in
    meatray.net.mcp_tools; this file is only the stdio loop.
]]

package.path = package.path .. ';./?.lua;./?/init.lua'

local Mcp = require('meatray.net.mcp')
local McpTools = require('meatray.net.mcp_tools')
local Project = require('meatray.game.project')

-- Line-buffered stdout or the client waits forever on a reply the buffer
-- is holding; stderr is the log channel (stdout belongs to the protocol).
io.stdout:setvbuf('line')

local server = Mcp.new{
    name = 'meatraycast',
    version = '1.0.0',
    tools = McpTools.build(Project.diskFs()),
}

io.stderr:write('meatraycast mcp server on stdio\n')

for line in io.lines() do
    local out = server:handle(line)
    if out then io.stdout:write(out, '\n') end
end
