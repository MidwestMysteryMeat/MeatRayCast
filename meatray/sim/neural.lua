--[[
    meatray.sim.neural — small neural networks, deterministic, headless.

    Machine-learning agents for a game that insists on determinism have one
    hard requirement before any cleverness: the same seed must build the same
    net, the same inputs must produce the same outputs, on LuaJIT and plain
    Lua alike. So everything random here draws from the engine LCG, weights
    serialize with %.17g (the demo-recording float discipline), and there is
    no FFI, no matrix library, no platform anywhere — a brain is plain data
    plus arithmetic.

    What ships is a multilayer perceptron and BOTH ways games actually train
    one:

      forward     sense -> act, the per-tick call
      train       supervised backprop — teach a brain from examples, e.g. the
                  input stream of a recorded demo (F1): imitation learning
      mutate / crossover / evolvePool
                  neuroevolution — no gradients, no labels, just a fitness
                  number per brain and selection pressure; the classic fit
                  for "learn to play" where the only signal is how it went

    Sizes are game sizes: a dozen inputs, tens of hidden units. At that scale
    plain Lua tables outrun any clever representation's overhead, and a
    serialized brain is a few KB of text a project can commit.

    HEADLESS: pure Lua.
]]

local Worldgen = require('meatray.sim.worldgen')

local exp, sqrt = math.exp, math.sqrt

local Neural = {}
local NetMT = {}
NetMT.__index = NetMT

local function tanh(x)
    if x > 20 then return 1 end
    if x < -20 then return -1 end
    local e2 = exp(2 * x)
    return (e2 - 1) / (e2 + 1)
end

---------------------------------------------------------------------------
-- Construction
---------------------------------------------------------------------------

-- Neural.new{ layers = { in, hidden..., out }, seed = n }
-- Weights start Xavier-scaled from the LCG: same seed, same brain, forever.
function Neural.new(opts)
    opts = opts or {}
    local layers = opts.layers
    assert(type(layers) == 'table' and #layers >= 2, 'layers = {in, ..., out} required')

    local rng = Worldgen.rng(tonumber(opts.seed) or 1)
    local net = setmetatable({
        layers = {},
        weights = {},   -- [L][j][i]: into unit j of layer L+1 from unit i of layer L
        biases = {},    -- [L][j]
    }, NetMT)
    for i, n in ipairs(layers) do net.layers[i] = n end

    for L = 1, #layers - 1 do
        local nIn, nOut = layers[L], layers[L + 1]
        local scale = sqrt(2 / (nIn + nOut))
        local w, b = {}, {}
        for j = 1, nOut do
            local row = {}
            for i = 1, nIn do
                row[i] = (rng:float() * 2 - 1) * scale
            end
            w[j] = row
            b[j] = 0
        end
        net.weights[L] = w
        net.biases[L] = b
    end
    return net
end

---------------------------------------------------------------------------
-- Forward
---------------------------------------------------------------------------

-- inputs (array sized layers[1]) -> outputs (array sized layers[#layers]),
-- tanh throughout so outputs live in [-1, 1] — the range game intents want
-- (forward, strafe, turn are all signed unit quantities).
function NetMT:forward(inputs)
    local act = inputs
    for L = 1, #self.layers - 1 do
        local w, b = self.weights[L], self.biases[L]
        local out = {}
        for j = 1, self.layers[L + 1] do
            local sum = b[j]
            local row = w[j]
            for i = 1, self.layers[L] do
                sum = sum + row[i] * (act[i] or 0)
            end
            out[j] = tanh(sum)
        end
        act = out
    end
    return act
end

---------------------------------------------------------------------------
-- Supervised training (backprop, SGD)
---------------------------------------------------------------------------

-- One gradient step on one example. Returns the squared error before the
-- step. Plain SGD on purpose: at these sizes momentum buys nothing a lower
-- learning rate does not, and one knob is one knob.
function NetMT:trainStep(inputs, targets, rate)
    rate = rate or 0.1

    -- Forward, keeping every layer's activations for the backward pass.
    local acts = { inputs }
    for L = 1, #self.layers - 1 do
        local w, b = self.weights[L], self.biases[L]
        local out = {}
        for j = 1, self.layers[L + 1] do
            local sum = b[j]
            local row = w[j]
            for i = 1, self.layers[L] do
                sum = sum + row[i] * (acts[L][i] or 0)
            end
            out[j] = tanh(sum)
        end
        acts[L + 1] = out
    end

    -- Output deltas; tanh' = 1 - y².
    local top = #self.layers
    local deltas = {}
    local err = 0
    do
        local d = {}
        local outs = acts[top]
        for j = 1, self.layers[top] do
            local diff = outs[j] - (targets[j] or 0)
            err = err + diff * diff
            d[j] = diff * (1 - outs[j] * outs[j])
        end
        deltas[top] = d
    end

    -- Backward through the hidden layers.
    for L = top - 1, 2, -1 do
        local d = {}
        local wAbove = self.weights[L]
        local dAbove = deltas[L + 1]
        for i = 1, self.layers[L] do
            local sum = 0
            for j = 1, self.layers[L + 1] do
                sum = sum + wAbove[j][i] * dAbove[j]
            end
            local y = acts[L][i]
            d[i] = sum * (1 - y * y)
        end
        deltas[L] = d
    end

    -- Descend.
    for L = 1, top - 1 do
        local w, b = self.weights[L], self.biases[L]
        local dAbove = deltas[L + 1]
        for j = 1, self.layers[L + 1] do
            local row = w[j]
            local dj = dAbove[j] * rate
            for i = 1, self.layers[L] do
                row[i] = row[i] - dj * (acts[L][i] or 0)
            end
            b[j] = b[j] - dj
        end
    end
    return err
end

-- Epoch loop over {{inputs=..., targets=...}, ...}. Returns the mean squared
-- error of the FINAL epoch, so a caller can assert learning happened.
function NetMT:train(samples, epochs, rate)
    local lastErr = 0
    for _ = 1, epochs or 1 do
        lastErr = 0
        for _, s in ipairs(samples) do
            lastErr = lastErr + self:trainStep(s.inputs, s.targets, rate)
        end
        lastErr = lastErr / #samples
    end
    return lastErr
end

---------------------------------------------------------------------------
-- Neuroevolution
---------------------------------------------------------------------------

-- In-place weight jitter: each weight has `rate` chance of moving by up to
-- ±amount. The rng is a parameter, not global state — the caller owns the
-- determinism story (usually one LCG for a whole training run).
function NetMT:mutate(rng, rate, amount)
    rate = rate or 0.1
    amount = amount or 0.5
    for L = 1, #self.layers - 1 do
        local w, b = self.weights[L], self.biases[L]
        for j = 1, self.layers[L + 1] do
            local row = w[j]
            for i = 1, self.layers[L] do
                if rng:float() < rate then
                    row[i] = row[i] + (rng:float() * 2 - 1) * amount
                end
            end
            if rng:float() < rate then
                b[j] = b[j] + (rng:float() * 2 - 1) * amount
            end
        end
    end
    return self
end

-- Uniform crossover: each weight from one parent or the other. Parents must
-- share a topology; refusing loudly beats a silently broken child.
function Neural.crossover(a, b, rng)
    assert(#a.layers == #b.layers, 'crossover needs identical topologies')
    for i = 1, #a.layers do
        assert(a.layers[i] == b.layers[i], 'crossover needs identical topologies')
    end
    local child = Neural.new{ layers = a.layers, seed = 1 }
    for L = 1, #a.layers - 1 do
        for j = 1, a.layers[L + 1] do
            for i = 1, a.layers[L] do
                child.weights[L][j][i] =
                    (rng:float() < 0.5 and a or b).weights[L][j][i]
            end
            child.biases[L][j] = (rng:float() < 0.5 and a or b).biases[L][j]
        end
    end
    return child
end

-- One generation: given parallel arrays of nets and fitness scores, breed
-- the next population. Elitism keeps the best `elite` unchanged (progress is
-- never lost to a bad dice roll); the rest are tournament-selected parents
-- crossed and mutated. Returns the new population, best-first.
function Neural.evolvePool(nets, scores, rng, opts)
    opts = opts or {}
    local elite = opts.elite or 2
    local tournament = opts.tournament or 3
    local rate = opts.mutateRate or 0.15
    local amount = opts.mutateAmount or 0.4

    local order = {}
    for i = 1, #nets do order[i] = i end
    table.sort(order, function(x, y) return scores[x] > scores[y] end)

    local function pick()
        local best
        for _ = 1, tournament do
            local c = rng:int(1, #nets)
            if not best or scores[c] > scores[best] then best = c end
        end
        return nets[best]
    end

    local pool = {}
    for rank = 1, math.min(elite, #nets) do
        pool[#pool + 1] = nets[order[rank]]
    end
    while #pool < #nets do
        local child = Neural.crossover(pick(), pick(), rng)
        child:mutate(rng, rate, amount)
        pool[#pool + 1] = child
    end
    return pool
end

---------------------------------------------------------------------------
-- Serialization — text, byte-stable, committable
---------------------------------------------------------------------------

-- "neural1 <layers>|<weights and biases layer by layer>", floats as %.17g so
-- a round trip is exact (the same rule the demo recorder lives by).
function NetMT:serialize()
    local parts = { 'neural1 ' .. table.concat(self.layers, ',') }
    for L = 1, #self.layers - 1 do
        local nums = {}
        for j = 1, self.layers[L + 1] do
            local row = self.weights[L][j]
            for i = 1, self.layers[L] do
                nums[#nums + 1] = ('%.17g'):format(row[i])
            end
            nums[#nums + 1] = ('%.17g'):format(self.biases[L][j])
        end
        parts[#parts + 1] = table.concat(nums, ' ')
    end
    return table.concat(parts, '\n')
end

function Neural.deserialize(text)
    if type(text) ~= 'string' then return nil, 'not a string' end
    local lines = {}
    for line in text:gmatch('[^\n]+') do lines[#lines + 1] = line end
    local layerSpec = lines[1] and lines[1]:match('^neural1 ([%d,]+)$')
    if not layerSpec then return nil, 'not a neural1 blob' end

    local layers = {}
    for n in layerSpec:gmatch('%d+') do layers[#layers + 1] = tonumber(n) end
    if #layers < 2 then return nil, 'bad layer spec' end

    local net = Neural.new{ layers = layers, seed = 1 }
    for L = 1, #layers - 1 do
        local line = lines[L + 1]
        if not line then return nil, 'truncated: missing layer ' .. L end
        local vals = {}
        for v in line:gmatch('%S+') do vals[#vals + 1] = tonumber(v) end
        local expect = layers[L + 1] * (layers[L] + 1)
        if #vals ~= expect then
            return nil, ('layer %d holds %d numbers, wanted %d'):format(L, #vals, expect)
        end
        local k = 1
        for j = 1, layers[L + 1] do
            for i = 1, layers[L] do
                net.weights[L][j][i] = vals[k]
                k = k + 1
            end
            net.biases[L][j] = vals[k]
            k = k + 1
        end
    end
    return net
end

return Neural
