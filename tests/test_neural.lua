--[[
    I2: neural nets and the machine-learning agent behind them. Construction
    is seed-deterministic; forward stays in range; backprop genuinely learns
    (XOR — the classic not-linearly-separable check); evolution improves a
    population against a fitness; serialization round-trips exactly; the
    neurobot senses walls and produces sane intents through the bot contract.
]]

return function(t)
    local Neural = require('meatray.sim.neural')
    local Neurobot = require('meatray.game.neurobot')
    local Worldgen = require('meatray.sim.worldgen')
    local Map = require('meatray.sim.map')

    ---------------------------------------------------------------------
    t.describe('same seed, same brain; outputs bounded')

    local a = Neural.new{ layers = { 3, 5, 2 }, seed = 42 }
    local b = Neural.new{ layers = { 3, 5, 2 }, seed = 42 }
    local c = Neural.new{ layers = { 3, 5, 2 }, seed = 43 }
    t.eq(a:serialize(), b:serialize(), 'same seed builds the same weights')
    t.ok(a:serialize() ~= c:serialize(), 'a different seed is a different brain')

    local out = a:forward{ 0.5, -1, 1 }
    t.eq(#out, 2, 'output layer size honoured')
    t.ok(out[1] >= -1 and out[1] <= 1 and out[2] >= -1 and out[2] <= 1,
        'tanh keeps outputs in [-1, 1]')
    local out2 = a:forward{ 0.5, -1, 1 }
    t.eq(out[1], out2[1], 'forward is pure')

    ---------------------------------------------------------------------
    t.describe('backprop learns XOR')

    local xor = Neural.new{ layers = { 2, 6, 1 }, seed = 7 }
    local samples = {
        { inputs = { -1, -1 }, targets = { -1 } },
        { inputs = { -1,  1 }, targets = {  1 } },
        { inputs = {  1, -1 }, targets = {  1 } },
        { inputs = {  1,  1 }, targets = { -1 } },
    }
    local before = xor:train(samples, 1, 0.3)
    local after = xor:train(samples, 2000, 0.3)
    t.ok(after < before * 0.05, 'error collapsed', ('%.4f -> %.4f'):format(before, after))
    t.ok(xor:forward{ -1, 1 }[1] > 0.5, 'XOR(0,1) is high')
    t.ok(xor:forward{ 1, 1 }[1] < -0.5, 'XOR(1,1) is low')

    ---------------------------------------------------------------------
    t.describe('evolution improves a population')

    -- Toy fitness: output 0.8 for input 0.5. No gradients used — selection only.
    local function fitness(net)
        local y = net:forward{ 0.5 }[1]
        return -math.abs(y - 0.8)
    end
    local rng = Worldgen.rng(99)
    local pool = {}
    for i = 1, 12 do pool[i] = Neural.new{ layers = { 1, 4, 1 }, seed = i } end

    local function bestOf(p)
        local best = -math.huge
        for _, net in ipairs(p) do best = math.max(best, fitness(net)) end
        return best
    end
    local start = bestOf(pool)
    for _ = 1, 25 do
        local scores = {}
        for i, net in ipairs(pool) do scores[i] = fitness(net) end
        pool = Neural.evolvePool(pool, scores, rng, { elite = 2 })
    end
    local finish = bestOf(pool)
    t.ok(finish > start, 'the population improved', ('%.4f -> %.4f'):format(start, finish))
    t.ok(finish > -0.05, 'and got close to the target', finish)

    ---------------------------------------------------------------------
    t.describe('serialization round-trips exactly')

    local blob = xor:serialize()
    local back, err = Neural.deserialize(blob)
    t.ok(back, 'deserializes (' .. tostring(err) .. ')')
    t.eq(back:serialize(), blob, 'byte-identical after a round trip')
    t.eq(back:forward{ -1, 1 }[1], xor:forward{ -1, 1 }[1],
        'and computes identically')

    t.ok(not Neural.deserialize('what'), 'garbage is refused')
    local truncated = blob:match('^([^\n]+\n[^\n]+)')
    t.ok(not Neural.deserialize(truncated), 'a truncated blob is refused, not half-loaded')

    ---------------------------------------------------------------------
    t.describe('the neurobot fills the bot contract from its senses')

    local map = Map.parse(table.concat({
        'name Pen',
        'spawn 2.5 2.5 0',
        '---',
        '########',
        '#......#',
        '#......#',
        '#......#',
        '########',
    }, '\n'))
    local world = Map.toWorld(map)

    local bot = Neurobot.new{ seed = 11 }
    local ent = { x = 2.5, y = 2.5, angle = 0, storey = 1 }

    local senses = bot:sense(ent, world, nil)
    t.eq(#senses, Neurobot.SENSES, 'the senses vector is the declared width')
    t.eq(senses[#senses], 1, 'bias is last and constant')
    for i, s in ipairs(senses) do
        t.ok(s >= -1 and s <= 1, ('sense %d in range'):format(i), s)
    end

    -- Facing +x from x=2.5 in an 8-wide pen: the wall is ~5 tiles out —
    -- within whisker range, so the centre whisker must see SOMETHING.
    local centre = senses[math.ceil(Neurobot.WHISKERS / 2)]
    t.ok(centre > -1, 'the centre whisker sees the wall ahead')

    -- Pressed against the wall it must read nearer (higher).
    local near = bot:sense({ x = 6.9, y = 2.5, angle = 0, storey = 1 }, world, nil)
    t.ok(near[math.ceil(Neurobot.WHISKERS / 2)] > centre,
        'the whisker reads higher when the wall is nearer')

    local intent = bot:think(ent, world, nil, 1 / 60)
    t.ok(intent.input and intent.input.forward >= -1 and intent.input.forward <= 1,
        'forward intent is a unit value')
    t.ok(type(intent.fire) == 'boolean', 'fire intent is a decision')

    local i1 = bot:think({ x = 2.5, y = 2.5, angle = 0, storey = 1 }, world, nil, 1 / 60)
    local i2 = bot:think({ x = 2.5, y = 2.5, angle = 0, storey = 1 }, world, nil, 1 / 60)
    t.eq(i1.input.forward, i2.input.forward, 'thinking is deterministic')

    ---------------------------------------------------------------------
    t.describe('a brain file round-trips into a working bot')

    local loaded, loadErr = Neurobot.load(bot.brain:serialize())
    t.ok(loaded, 'load succeeds (' .. tostring(loadErr) .. ')')
    local li = loaded:think({ x = 2.5, y = 2.5, angle = 0, storey = 1 }, world, nil, 1 / 60)
    t.eq(li.input.forward, i1.input.forward, 'the loaded brain drives identically')

    local wrong = Neural.new{ layers = { 2, 2 }, seed = 1 }
    local refused = Neurobot.load(wrong:serialize())
    t.ok(not refused, 'a brain with the wrong topology is refused')
end
