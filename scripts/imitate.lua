--[[
    Imitation learning: teach a brain to play like a recorded demo.

        luajit scripts/imitate.lua <file.dem> [out] [epochs]
        luajit scripts/imitate.lua --selfcheck

    The F1 demo recorder captures the input stream of a real play session —
    which makes every tick of a demo a labelled example: "given what the
    player could sense, this is what they did." This script replays the
    demo's movement against its map, pairs the neurobot's senses with the
    recorded intents, and backprop-trains a brain on the pairs. The result
    loads with `neurobot 1 <out>`: an agent that moves like the recording
    did.

    Honest scope: v1 imitates MOVEMENT and FIRE timing on authored-map
    demos (a procedural demo would need the full worldgen replay). Combat
    context (other entities) is not reconstructed, so the target/fight
    senses read empty during training — the brain learns locomotion style,
    not duelling.

    --selfcheck is the proof without a human: a C22 rules-bot wanders the
    arena while a recorder captures it, then the imitation path trains on
    that capture. Exit 0 only if the training error genuinely collapses.
]]

package.path = package.path .. ';./?.lua;./?/init.lua'

local Demo = require('meatray.sim.demo')
local Map = require('meatray.sim.map')
local Neural = require('meatray.sim.neural')
local Neurobot = require('meatray.game.neurobot')
local Rep = require('meatray.net.replication')
local Collide = require('meatray.sim.collide')

local pi = math.pi

local function readFile(path)
    local f = io.open(path, 'rb')
    if not f then return nil end
    local text = f:read('*a')
    f:close()
    return text
end

local function loadWorld(mapPath)
    local text = readFile(mapPath)
    if not text then return nil, 'cannot read ' .. tostring(mapPath) end
    local map, errs = Map.parse(text)
    if not map then return nil, mapPath .. ': ' .. tostring(errs and errs[1]) end
    local world, _, spawn = Map.toWorld(map)
    return world, spawn or { x = 2.5, y = 2.5, angle = 0 }
end

---------------------------------------------------------------------------
-- Demo -> training pairs
---------------------------------------------------------------------------

local function shortestWay(diff)
    while diff > pi do diff = diff - 2 * pi end
    while diff < -pi do diff = diff + 2 * pi end
    return diff
end

-- Replays the demo's inputs through the real movement path, harvesting
-- (senses, intents) at every tick. The turn target is recovered from the
-- recorded absolute aim: the rate that would have produced this tick's
-- angle from the last one — the same encoding the neurobot outputs.
local function harvest(play, world, spawn)
    local dt = 1 / (play.rate or 60)
    local senser = Neurobot.new{ seed = 1 }
    local ent = { x = spawn.x, y = spawn.y, angle = spawn.angle or 0, storey = 1 }
    Collide.ground(ent, world)

    local turnSpeed = 3     -- matches Neurobot.new's default turnSpeed
    local samples = {}

    for tick = 0, play:length() do
        local input = play:inputAt(tick)

        local fires = false
        for _, ev in ipairs(play:eventsAt(tick) or {}) do
            if ev.name == 'fire' then fires = true end
            -- A demo may carry 'goal' events (the selfcheck's teacher does):
            -- they make the intent observable to the goal senses. A human
            -- demo without them trains on walls alone, which is still a
            -- locomotion style.
            if ev.name == 'goal' and ev.x and ev.y then
                senser:setGoal(ev.x, ev.y)
            end
        end

        local turn = 0
        if input.angle then
            turn = shortestWay(input.angle - ent.angle) / (turnSpeed * dt)
            if turn > 1 then turn = 1 elseif turn < -1 then turn = -1 end
        end

        samples[#samples + 1] = {
            inputs = senser:sense(ent, world, nil),
            targets = { input.forward or 0, input.strafe or 0, turn,
                        fires and 1 or -1 },
        }

        Rep.applyInput(ent, Rep.sanitiseInput(input), dt, world)
    end
    return samples
end

-- Mean squared error over the set WITHOUT training — the honest baseline.
-- (train() returns the error of the epoch it just ran, which is already a
-- partially-trained number; comparing final against that undersells the
-- collapse and once made this script fail its own check.)
local function evaluate(net, samples)
    local err = 0
    for _, s in ipairs(samples) do
        local out = net:forward(s.inputs)
        for j = 1, #s.targets do
            local d = out[j] - s.targets[j]
            err = err + d * d
        end
    end
    return err / #samples
end

local function trainOn(samples, epochs)
    local net = Neural.new{
        layers = { Neurobot.SENSES, 16, Neurobot.INTENTS },
        seed = 7,
    }
    local before = evaluate(net, samples)
    net:train(samples, epochs, 0.05)
    return net, before, evaluate(net, samples)
end

---------------------------------------------------------------------------
-- Self-check: a rules-bot records the demo, imitation learns from it
---------------------------------------------------------------------------

local function selfcheck()
    local Bot = require('meatray.game.bot')
    local world, spawn = loadWorld('maps/arena.map')
    assert(world, spawn)

    local rec = Demo.record{ source = 'authored', map = 'maps/arena.map', rate = 60 }
    local teacher = Bot.new{ seed = 5 }
    local ent = { x = spawn.x, y = spawn.y, angle = spawn.angle or 0, storey = 1,
                  kind = 'player' }
    Collide.ground(ent, world)

    local dt = 1 / 60
    local lastGoal = nil
    for tick = 0, 599 do
        local intent = teacher:think(ent, world, { ent }, dt)
        rec:frame(tick, intent.input)
        if intent.fire then rec:event(tick, 'fire', { angle = intent.input.angle }) end
        -- Expose the teacher's wander goal to the recording: without it the
        -- policy is partially unobservable from the senses and no amount of
        -- training can close that gap — the check would measure the wrong
        -- thing.
        local g = teacher.wanderGoal
        if g and g ~= lastGoal then
            lastGoal = g
            rec:event(tick, 'goal', { x = g.x, y = g.y })
        end
        Rep.applyInput(ent, Rep.sanitiseInput(intent.input), dt, world)
    end
    local text = rec:finish(599)

    local play = Demo.load(text)
    assert(play, 'self-generated demo must load')
    local samples = harvest(play, world, spawn)
    print(('selfcheck: %d ticks harvested from the teacher'):format(#samples))

    local _, first, final = trainOn(samples, 300)
    print(('selfcheck: error %.4f -> %.4f over 300 epochs'):format(first, final))
    if final < first * 0.5 then
        print('SELFCHECK OK — imitation learns the teacher')
        os.exit(0)
    end
    print('SELFCHECK FAILED — error did not collapse')
    os.exit(1)
end

---------------------------------------------------------------------------

if arg[1] == '--selfcheck' then selfcheck() end

local demoPath = arg[1]
local outPath = arg[2] or 'build/imitated_brain.txt'
local epochs = tonumber(arg[3]) or 80

if not demoPath then
    io.stderr:write('usage: luajit scripts/imitate.lua <file.dem> [out] [epochs]\n')
    io.stderr:write('       luajit scripts/imitate.lua --selfcheck\n')
    os.exit(1)
end

local text = readFile(demoPath)
if not text then
    io.stderr:write('cannot read ' .. demoPath .. '\n')
    os.exit(1)
end
local play, err = Demo.load(text)
if not play then
    io.stderr:write('not a demo: ' .. tostring(err) .. '\n')
    os.exit(1)
end
if play.source ~= 'authored' or not play.map then
    io.stderr:write('v1 imitates authored-map demos; this one is ' ..
        tostring(play.source) .. '\n')
    os.exit(1)
end

local world, spawn = loadWorld(play.map)
if not world then
    io.stderr:write(tostring(spawn) .. '\n')
    os.exit(1)
end

local samples = harvest(play, world, spawn)
print(('%d ticks harvested from %s'):format(#samples, demoPath))

local net, first, final = trainOn(samples, epochs)
print(('trained %d epochs: error %.4f -> %.4f'):format(epochs, first, final))

local f = io.open(outPath, 'wb')
if not f then
    io.stderr:write('cannot write ' .. outPath .. '\n')
    os.exit(1)
end
f:write(net:serialize())
f:close()
print(('brain -> %s   (console: neurobot 1 %s)'):format(outPath, outPath))
