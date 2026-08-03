--[[
    meatray.dev.microbench — headless hot-path timings with committed budgets
    (G7).

    bench.lua measures the renderer, which needs a window; this measures the
    parts a dedicated server spends its life in — snapshot encode/decode,
    worldgen, the gas step, the demo checksum — none of which touch LÖVE, so
    they can be timed in plain LuaJIT and gated in CI.

        local MB = require('meatray.dev.microbench')
        local results = MB.run()          -- { {name, opsPerSec, nsPerOp, ...} }
        local report = MB.grade(results)  -- vs meatray.dev.bench_budget

    The budget is a FLOOR, not a target: each op has a committed
    ops-per-second below which the lane fails, set to roughly half the
    measured throughput on the authoring machine. Half, because a benchmark
    that fails on a 10% machine-to-machine spread teaches people to ignore it;
    a 2x drop is a real regression, not noise. Warnings fire earlier (within
    1.5x) so drift is visible before it is fatal.

    Timing is os.clock (CPU seconds), and each op self-calibrates its
    iteration count against a wall budget so a fast machine runs more reps and
    a slow one fewer — the ops/sec is comparable either way. Nothing here
    reads the clock for anything but elapsed deltas, so it stays deterministic
    in what it MEASURES even though the timing itself is not.

    HEADLESS: pure Lua.
]]

local MB = {}

local clock = os.clock

---------------------------------------------------------------------------
-- The ops, each a closure over its own fixed setup
---------------------------------------------------------------------------

local function buildOps()
    local P        = require('meatray.net.protocol')
    local Codec    = require('meatray.net.snapcodec')
    local Worldgen = require('meatray.sim.worldgen')
    local Gas      = require('meatray.game.gas')
    local Demo     = require('meatray.sim.demo')
    local Entity   = require('meatray.sim.entity')
    local C        = require('meatray.sim.components')
    local Rep      = require('meatray.net').replication

    Codec.useBackend('table', 'lua')      -- price the portable path, the CI floor

    local ops = {}

    -- A full-server snapshot: 8 players + 24 grunts, the shape test_net_snapcodec
    -- uses, so the number means something next to that suite.
    do
        Entity.clearArchetypes()
        Entity.resetIds(1)
        local list = {}
        for i = 1, 8 do
            local e = Entity.new{ kind = 'player', x = 12.5 + i * 0.37,
                                  y = 9.25 + i * 0.11, angle = 0.5 + i * 0.13 }
            e:add(C.Billboard{ sheet = 'marine' })
            e:add(C.Health{ hp = 88 - i, max = 100 })
            e:add(C.Player{ peerId = i, name = ('p%d'):format(i) })
            e:add(C.Weapon{ ammo = 42 - i })
            list[#list + 1] = e
        end
        for i = 1, 24 do
            local e = Entity.new{ kind = 'grunt', x = 3.5 + i * 0.91,
                                  y = 21.75 + i * 0.23, angle = 1.25 + i * 0.07 }
            e:add(C.Billboard{ sheet = 'grunt' })
            e:add(C.Health{ hp = 30, max = 30 })
            list[#list + 1] = e
        end
        local body = { tick = 1, e = Rep.entitySnapshots(list) }
        local packed = P.packSnapshot(body)

        ops[#ops + 1] = { name = 'snapshot.encode',
                          fn = function() return P.packSnapshot(body) end }
        ops[#ops + 1] = { name = 'snapshot.decode',
                          fn = function() return P.unpack(packed) end }
        Entity.clearArchetypes()
        Entity.resetIds(1)
    end

    -- Worldgen: the demo's own 44x44 with doors and rooms.
    do
        local seed = 20260803
        ops[#ops + 1] = { name = 'worldgen.generate',
            fn = function()
                seed = seed + 1
                return Worldgen.generate{ width = 44, height = 44, seed = seed,
                                          doorChance = 0.5 }
            end }
    end

    -- Gas step: a field with a live plume on a real world, stepped once.
    do
        local world = Worldgen.generate{ width = 32, height = 32, seed = 7,
                                         doorChance = 0.4 }
        local field = Gas.new{ world = world, name = 'fire', rate = 1.1, decay = 0.55 }
        field:emit(16, 16, 6)
        ops[#ops + 1] = { name = 'gas.step',
            fn = function() field:emit(16, 16, 1); return field:step(1 / 60) end }
    end

    -- Demo checksum: the divergence hash over a full server's worth of entities.
    do
        Entity.resetIds(1)
        local list = {}
        for i = 1, 32 do
            local e = Entity.new{ kind = 'e', x = i * 0.5, y = i * 0.3,
                                  angle = i * 0.1 }
            list[i] = e
        end
        ops[#ops + 1] = { name = 'demo.checksum',
                          fn = function() return Demo.checksum(list) end }
        Entity.resetIds(1)
    end

    return ops
end

---------------------------------------------------------------------------
-- The timing loop
---------------------------------------------------------------------------

-- Runs each op enough times to fill `budgetSec` of CPU time (default 0.15s),
-- then reports throughput. A minimum rep count guards against a clock too
-- coarse to see a single fast call.
function MB.run(opts)
    opts = opts or {}
    local budgetSec = tonumber(opts.budgetSec) or 0.15
    local minReps = tonumber(opts.minReps) or 200

    local results = {}
    for _, op in ipairs(buildOps()) do
        -- Warm up, so a first-call JIT compile is not billed to the op.
        for _ = 1, 20 do op.fn() end

        local reps = 0
        local start = clock()
        repeat
            for _ = 1, 50 do op.fn() end
            reps = reps + 50
        until clock() - start >= budgetSec and reps >= minReps
        local elapsed = clock() - start

        local opsPerSec = elapsed > 0 and (reps / elapsed) or 0
        results[#results + 1] = {
            name = op.name,
            reps = reps,
            seconds = elapsed,
            opsPerSec = opsPerSec,
            nsPerOp = opsPerSec > 0 and (1e9 / opsPerSec) or 0,
        }
    end
    return results
end

---------------------------------------------------------------------------
-- Grading against the committed budget
---------------------------------------------------------------------------

-- Returns { ok, rows = { {name, opsPerSec, floor, ratio, verdict} } }.
-- verdict: 'ok' | 'slow' (under 1.5x margin, a warning) | 'FAIL' (under the
-- floor). ok is false only when something is under its floor.
function MB.grade(results, budget)
    budget = budget or require('meatray.dev.bench_budget')
    local rows, ok = {}, true
    for _, r in ipairs(results) do
        local floor = budget[r.name]
        local verdict, ratio = 'unbudgeted', nil
        if floor then
            ratio = r.opsPerSec / floor
            if r.opsPerSec < floor then
                verdict = 'FAIL'; ok = false
            elseif r.opsPerSec < floor * 1.5 then
                verdict = 'slow'
            else
                verdict = 'ok'
            end
        end
        rows[#rows + 1] = {
            name = r.name, opsPerSec = r.opsPerSec, floor = floor,
            ratio = ratio, verdict = verdict, nsPerOp = r.nsPerOp,
        }
    end
    return { ok = ok, rows = rows }
end

return MB
