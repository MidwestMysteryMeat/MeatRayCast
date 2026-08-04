--[[
    The RL environment server: train MeatRayCast agents from anywhere.

        luajit scripts/env_server.lua [map] [--max-ticks N]

    The ML-Agents split over the simplest possible wire: JSON, one message
    per line, on stdio. An external trainer (PyTorch, whatever) drives
    episodes; the engine owns the sim. Protocol:

        -> {"cmd":"info"}
        <- {"obs_size":11,"action_size":4,"protocol":1}
        -> {"cmd":"reset"}
        <- {"obs":[...]}
        -> {"cmd":"step","action":[fwd,strafe,turn,fire]}
        <- {"obs":[...],"reward":0.03,"done":false,"info":{...}}
        -> {"cmd":"quit"}

    A policy trained against this sees exactly what an in-game neurobot
    sees and moves exactly as one moves, so exporting its weights as
    neural1 text (see docs/AI.md) drops it straight into `neurobot 1
    <file>`. Python example in docs/AI.md.
]]

package.path = package.path .. ';./?.lua;./?/init.lua'

local Env = require('meatray.sim.env')
local json = require('meatray.net.json')

io.stdout:setvbuf('line')

local mapPath = 'maps/arena.map'
local maxTicks = 720
do
    local i = 1
    while arg[i] do
        if arg[i] == '--max-ticks' then
            maxTicks = tonumber(arg[i + 1]) or maxTicks
            i = i + 2
        else
            mapPath = arg[i]
            i = i + 1
        end
    end
end

local f = io.open(mapPath, 'rb')
if not f then
    io.stderr:write('cannot read ' .. mapPath .. '\n')
    os.exit(1)
end
local mapText = f:read('*a')
f:close()

local env = Env.new{ mapText = mapText, maxTicks = maxTicks }
io.stderr:write(('env server: %s, obs %d, actions %d\n')
    :format(mapPath, env:observationSize(), env:actionSize()))

local function emit(t) io.stdout:write(json.encode(t), '\n') end

for line in io.lines() do
    local ok, msg = pcall(json.decode, line)
    if not ok or type(msg) ~= 'table' then
        emit{ error = 'bad json' }
    elseif msg.cmd == 'info' then
        emit{ obs_size = env:observationSize(),
              action_size = env:actionSize(), protocol = 1 }
    elseif msg.cmd == 'reset' then
        emit{ obs = json.array(env:reset()) }
    elseif msg.cmd == 'step' then
        local obs, reward, done, info = env:step(msg.action or {})
        emit{ obs = json.array(obs), reward = reward, done = done, info = info }
    elseif msg.cmd == 'quit' then
        emit{ ok = true }
        break
    else
        emit{ error = 'unknown cmd: ' .. tostring(msg.cmd) }
    end
end
