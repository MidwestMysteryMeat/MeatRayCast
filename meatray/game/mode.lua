--[[
    meatray.game.mode — a thin template for a host-authoritative game mode.

        local Mode = require('meatray.game.mode')
        local mode = Mode.new{
            onStart = function(m, world, entities) ... end,
            onTick  = function(m, dt, world, entities) ... end,
            onPlayerJoin = function(m, peer, entity) ... end,
            onPlayerLeave = function(m, peer) ... end,
            onCommand = function(m, host, peer, name, body) ... end,
        }
        mode:start(world, entities)
        -- inside host onStep:
        mode:tick(dt, world, entities)

    The engine already has net, AI, triggers, weapons. What games reinvent is
    the *glue*: when does a round start, who is scored, which command names
    mean what. This module is that glue with empty defaults — not a genre
    ruleset. Keep genre logic in your game file; keep lifecycle here.

    HEADLESS: pure Lua.
]]

local Mode = {}
local ModeMT = {}
ModeMT.__index = ModeMT

function Mode.new(opts)
    opts = opts or {}
    return setmetatable({
        name = opts.name or 'mode',
        state = 'idle',          -- idle | running | ended
        elapsed = 0,
        score = {},              -- optional [peerId] = number
        data = opts.data or {},  -- free bag for the game

        onStart = opts.onStart,
        onStop = opts.onStop,
        onTick = opts.onTick,
        onPlayerJoin = opts.onPlayerJoin,
        onPlayerLeave = opts.onPlayerLeave,
        onCommand = opts.onCommand,
        onEvent = opts.onEvent,
    }, ModeMT)
end

function ModeMT:start(world, entities)
    self.state = 'running'
    self.elapsed = 0
    if self.onStart then self.onStart(self, world, entities) end
    return self
end

function ModeMT:stop(reason)
    if self.state ~= 'running' then return self end
    self.state = 'ended'
    if self.onStop then self.onStop(self, reason or 'stop') end
    return self
end

function ModeMT:tick(dt, world, entities)
    if self.state ~= 'running' then return end
    self.elapsed = self.elapsed + (dt or 0)
    if self.onTick then self.onTick(self, dt, world, entities) end
end

function ModeMT:playerJoin(peer, entity)
    if self.onPlayerJoin then self.onPlayerJoin(self, peer, entity) end
end

function ModeMT:playerLeave(peer)
    if self.onPlayerLeave then self.onPlayerLeave(self, peer) end
end

-- Returns true if the mode handled the command.
function ModeMT:command(host, peer, name, body)
    if not self.onCommand then return false end
    return self.onCommand(self, host, peer, name, body) and true or false
end

function ModeMT:event(name, body)
    if self.onEvent then self.onEvent(self, name, body) end
end

function ModeMT:addScore(peerId, delta)
    peerId = peerId or 0
    self.score[peerId] = (self.score[peerId] or 0) + (delta or 0)
    return self.score[peerId]
end

return Mode
