--[[
    RL environment. The Gym contract holds: reset gives observations sized
    as declared, stepping applies real movement through the real input path,
    reward is walking-distance progress (positive toward the goal, negative
    away), arrival ends the episode with the bonus, timeout ends it without,
    and identical action sequences replay identically. Also pins the
    Pathfind.distanceField helper it stands on.
]]

return function(t)
    local Env = require('meatray.sim.env')
    local Pathfind = require('meatray.sim.pathfind')
    local Map = require('meatray.sim.map')

    -- A corridor: spawn at the left, farthest tile at the right.
    local corridor = table.concat({
        'name Corridor',
        'spawn 1.5 1.5 0',
        '---',
        '##########',
        '#........#',
        '##########',
    }, '\n')

    ---------------------------------------------------------------------
    t.describe('the distance field it stands on')

    local world = Map.toWorld(Map.parse(corridor))
    local field = Pathfind.distanceField(world, 1.5, 1.5)
    t.eq(field:at(1.5, 1.5), 0, 'zero at the origin')
    t.eq(field:at(8.5, 1.5), 7, 'seven tiles down the corridor')
    t.eq(field:at(5.5, 0.5), nil, 'a wall tile is off-field')
    t.eq(field.farthestDist, 7, 'farthest is the corridor end')
    t.eq(field.farthestX, 8.5, 'and its centre is where expected')

    ---------------------------------------------------------------------
    t.describe('reset and the observation contract')

    local env = Env.new{ mapText = corridor, maxTicks = 600 }
    t.eq(env:observationSize(), 11, 'observation size is the neurobot senses')
    t.eq(env:actionSize(), 4, 'four intents')
    t.ok(env.goal.x > 7, 'the default goal is the far end of the corridor', env.goal.x)

    local obs = env:reset()
    t.eq(#obs, env:observationSize(), 'reset returns a full observation')
    for i, v in ipairs(obs) do
        t.ok(v >= -1 and v <= 1, ('obs %d in range'):format(i), v)
    end

    ---------------------------------------------------------------------
    t.describe('progress is rewarded; regress is charged')

    env:reset()
    -- Spawn faces +x, straight down the corridor: walk forward.
    local _, fwdReward = env:step{ 1, 0, 0, 0 }
    t.ok(fwdReward > 0, 'a step toward the goal earns positive reward', fwdReward)

    env:reset()
    local _, still = env:step{ 0, 0, 0, 0 }
    t.ok(still < 0, 'standing still pays the loitering cost', still)

    env:reset()
    env:step{ 1, 0, 0, 0 }
    local _, back = env:step{ -1, 0, 0, 0 }
    t.ok(back < 0, 'walking away from the goal is charged', back)

    ---------------------------------------------------------------------
    t.describe('an episode ends by arriving or by running out')

    env:reset()
    local arrived, steps = false, 0
    for _ = 1, 600 do
        local _, _, done, info = env:step{ 1, 0, 0, 0 }
        steps = steps + 1
        if done then
            arrived = info.arrived
            break
        end
    end
    t.ok(arrived, 'walking forward reaches the goal', steps)
    t.ok(steps < 400, 'and well before the cap', steps)

    local short = Env.new{ mapText = corridor, maxTicks = 5 }
    short:reset()
    local doneAt, wasArrived = nil, nil
    for i = 1, 10 do
        local _, _, done, info = short:step{ 0, 0, 0, 0 }
        if done then doneAt, wasArrived = i, info.arrived break end
    end
    t.eq(doneAt, 5, 'timeout ends the episode at maxTicks')
    t.ok(not wasArrived, 'and honestly reports no arrival')

    ---------------------------------------------------------------------
    t.describe('same actions, same episode — to the byte')

    local function runEpisode()
        local e = Env.new{ mapText = corridor, maxTicks = 120 }
        e:reset()
        local trace = {}
        for i = 1, 60 do
            local o, r = e:step{ 0.8, 0.1 * ((i % 3) - 1), 0.2, 0 }
            trace[#trace + 1] = ('%.17g %.17g'):format(o[1], r)
        end
        return table.concat(trace, '|')
    end
    t.eq(runEpisode(), runEpisode(), 'two identical runs trace identically')

    ---------------------------------------------------------------------
    t.describe('an explicit goal and a custom reward are honoured')

    local custom = Env.new{
        mapText = corridor,
        goal = { x = 4.5, y = 1.5 },
        reward = function() return 42 end,
    }
    custom:reset()
    local _, r = custom:step{ 1, 0, 0, 0 }
    t.eq(r, 42, 'the custom reward function is used')
    t.eq(custom.goal.x, 4.5, 'the explicit goal stands')
end
