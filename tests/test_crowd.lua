--[[
    I1: crowd simulation. The flow field reaches every walkable tile and its
    arrows walk to the goal; agents follow it through a doorway; separation
    keeps a pile of agents apart; stepping is deterministic; sealed rooms are
    honestly off-field.
]]

return function(t)
    local Crowd = require('meatray.sim.crowd')
    local Map = require('meatray.sim.map')

    -- Two rooms joined by one door; a sealed cell bottom-right.
    local map = Map.parse(table.concat({
        'name Crowded',
        'spawn 2.5 2.5 0',
        '---',
        '##########',
        '#....#...#',
        '#....D...#',
        '#....#.#.#',
        '#....#.#.#',
        '##########',
    }, '\n'))
    t.ok(map, 'test map parses')
    local world = Map.toWorld(map)

    ---------------------------------------------------------------------
    t.describe('the flow field covers what walking covers')

    local crowd = Crowd.new(world, { seed = 5 })
    t.ok(crowd:setGoal(8.5, 1.5), 'goal in the right room accepted')
    t.ok(crowd:flowAt(1.5, 1.5), 'left room is on the field')
    t.ok(crowd:flowAt(8.5, 4.5), 'right-room corridor is on the field')
    t.ok(not crowd:flowAt(7.5, 3.5), 'the walled-off cell is off-field, not wrongly reachable')

    local ok, why = crowd:setGoal(5.5, 1.5)
    t.ok(not ok and why:find('wall'), 'a goal inside a wall is refused with the reason')

    ---------------------------------------------------------------------
    t.describe('arrows walk to the goal')

    t.ok(crowd:setGoal(8.5, 1.5), 'goal restored')
    -- Follow the field tile by tile from the far corner; it must arrive.
    local x, y = 1.5, 4.5
    local arrived = false
    for _ = 1, 64 do
        local flow = crowd:flowAt(x, y)
        if not flow then break end
        if flow.dx == 0 and flow.dy == 0 then arrived = true break end
        x, y = x + flow.dx, y + flow.dy
    end
    t.ok(arrived, 'following arrows from the far corner reaches the goal tile')

    ---------------------------------------------------------------------
    t.describe('agents walk the field through the door')

    local a = crowd:add{ x = 1.5, y = 1.5 }
    local b = crowd:add{ x = 1.5, y = 4.5 }
    t.eq(crowd:count(), 2, 'two agents in')

    for _ = 1, 60 * 20 do crowd:step(1 / 60) end

    local function distToGoal(agent)
        return math.sqrt((agent.x - 8.5) ^ 2 + (agent.y - 1.5) ^ 2)
    end
    t.ok(distToGoal(a) < 2.5, 'agent A crossed the level to the goal', distToGoal(a))
    t.ok(distToGoal(b) < 2.5, 'agent B too', distToGoal(b))
    t.ok(a.x > 5 and b.x > 5, 'both actually passed through the doorway wall')

    ---------------------------------------------------------------------
    t.describe('separation keeps a pile apart')

    local packed = Crowd.new(world, { seed = 9 })
    for _ = 1, 6 do packed:add{ x = 2.5, y = 2.5 } end
    packed:setGoal(2.5, 2.5)     -- goal where they stand: only separation acts
    for _ = 1, 60 * 3 do packed:step(1 / 60) end

    local minGap = math.huge
    for i = 1, packed:count() do
        for j = i + 1, packed:count() do
            local p, q = packed.agents[i], packed.agents[j]
            local d = math.sqrt((p.x - q.x) ^ 2 + (p.y - q.y) ^ 2)
            if d < minGap then minGap = d end
        end
    end
    t.ok(minGap > 0.25, 'no two agents remain stacked', minGap)

    ---------------------------------------------------------------------
    t.describe('the whole thing is deterministic')

    local function run()
        local c = Crowd.new(Map.toWorld(map), { seed = 7 })
        c:setGoal(8.5, 1.5)
        local ags = { c:add{ x = 1.5, y = 1.5 }, c:add{ x = 2.5, y = 3.5 } }
        for _ = 1, 60 * 5 do c:step(1 / 60) end
        return ('%.17g %.17g %.17g %.17g'):format(ags[1].x, ags[1].y, ags[2].x, ags[2].y)
    end
    t.eq(run(), run(), 'two identical runs end in identical positions')

    ---------------------------------------------------------------------
    t.describe('LOD: far agents stride, near agents do not, speed holds')

    local big = Map.parse(table.concat({
        'name Long',
        'spawn 1.5 1.5 0',
        '---',
        '##########################',
        '#........................#',
        '##########################',
    }, '\n'))
    local bigWorld = Map.toWorld(big)

    -- Two identical corridors: LOD off vs LOD on with the focus at the goal.
    -- The far agent strides under LOD, but scaled dt means it must cover
    -- comparable ground — LOD trades update granularity, never speed.
    local function corridorRun(lod)
        local c = Crowd.new(Map.toWorld(big), {
            seed = 4, separation = 0,      -- isolate the LOD effect
            lod = lod,
        })
        c:setGoal(24.5, 1.5)
        local far = c:add{ x = 1.5, y = 1.5 }
        for _ = 1, 60 * 4 do c:step(1 / 60) end
        return far.x
    end
    local plain = corridorRun(nil)
    local strided = corridorRun{ radius = 4, stride = 3 }
    t.ok(plain > 6, 'the un-LODded agent covered real distance', plain)
    t.ok(math.abs(plain - strided) < 1.5,
        'the strided agent kept pace within a stride of slack',
        ('%.2f vs %.2f'):format(plain, strided))

    -- Determinism holds with LOD on.
    local function lodTrace()
        local c = Crowd.new(bigWorld, { seed = 6, lod = { radius = 3, stride = 4 } })
        c:setGoal(24.5, 1.5)
        local a1 = c:add{ x = 1.5, y = 1.5 }
        local a2 = c:add{ x = 3.5, y = 1.5 }
        for _ = 1, 120 do c:step(1 / 60) end
        return ('%.17g %.17g'):format(a1.x, a2.x)
    end
    t.eq(lodTrace(), lodTrace(), 'LOD striding is deterministic')

    ---------------------------------------------------------------------
    t.describe('remove works and idle crowds mill')

    t.ok(crowd:remove(a), 'removing a member reports true')
    t.ok(not crowd:remove(a), 'removing it again reports false')

    local idle = Crowd.new(world, { seed = 3 })
    local m = idle:add{ x = 2.5, y = 2.5, angle = 0 }
    for _ = 1, 60 * 2 do idle:step(1 / 60) end
    local drift = math.sqrt((m.x - 2.5) ^ 2 + (m.y - 2.5) ^ 2)
    t.ok(drift > 0.05, 'a goalless agent mills instead of freezing', drift)
end
