--[[
    G7: the bench HARNESS is correct — every budgeted op runs, reports a
    positive throughput, and grades. Deliberately NO timing assertions: a
    suite that fails because the machine was busy teaches people to rerun
    until green, which is worse than no gate. The floor gate lives in
    scripts/bench_headless.lua, where a human or CI reads the number.
]]

return function(t)
    local MB = require('meatray.dev.microbench')
    local budget = require('meatray.dev.bench_budget')

    -- A tiny time budget: enough to run each op a few hundred times, fast
    -- enough to belong in the suite.
    local results = MB.run{ budgetSec = 0.02, minReps = 100 }

    t.ok(#results >= 5, ('every op ran (%d)'):format(#results))

    for _, r in ipairs(results) do
        t.ok(r.reps >= 100, r.name .. ' completed its reps')
        t.ok(r.opsPerSec > 0, r.name .. ' reports positive throughput')
        t.ok(r.nsPerOp > 0, r.name .. ' reports a per-op time')
    end

    -- Every op the bench measures must have a committed floor, and every
    -- floor must name a real op — a budget entry with no measurement (or an
    -- op with no budget) is a gate with a hole in it.
    local measured = {}
    for _, r in ipairs(results) do measured[r.name] = true end
    for name in pairs(budget) do
        t.ok(measured[name], 'budget entry ' .. name .. ' names a measured op')
    end
    for _, r in ipairs(results) do
        t.ok(budget[r.name] ~= nil, r.name .. ' has a committed floor')
    end

    -- Grade returns the expected shape, and (given how generous the floors
    -- are) passes even on a slow suite run — but the assertion is on the
    -- SHAPE, not the verdict, so a busy machine cannot fail the suite.
    local graded = MB.grade(results)
    t.eq(type(graded.ok), 'boolean', 'grade reports a boolean verdict')
    t.eq(#graded.rows, #results, 'one graded row per op')
    for _, row in ipairs(graded.rows) do
        t.ok(row.verdict == 'ok' or row.verdict == 'slow'
             or row.verdict == 'FAIL' or row.verdict == 'unbudgeted',
             row.name .. ' has a known verdict')
    end

    -- A blown budget IS caught: grade against an impossible floor and it must
    -- fail, so the gate is proven to bite without depending on wall time.
    local impossible = {}
    for name in pairs(budget) do impossible[name] = 1e15 end
    local blown = MB.grade(results, impossible)
    t.eq(blown.ok, false, 'an unreachable floor fails the grade — the gate bites')
end
