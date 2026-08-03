-- Headless hot-path benchmark with budget gate (G7).
--
--   luajit scripts/bench_headless.lua            (grade against the budget)
--   luajit scripts/bench_headless.lua --long     (steadier numbers, slower)
--
-- Exit 0 when every op clears its committed floor; exit 1 on any FAIL. A
-- 'slow' verdict warns but passes. Run from the repo root.

package.path = './?.lua;./?/init.lua;' .. package.path

local MB = require('meatray.dev.microbench')

-- The floors are LuaJIT numbers because LuaJIT is what the engine ships on;
-- plain PUC Lua runs these 5-75x slower and would fail every floor for a
-- reason that is not a regression. Under plain Lua the bench still RUNS and
-- prints, but the pass/fail gate is off — run it under luajit to gate.
local isJit = (type(jit) == 'table')

local long = false
for _, a in ipairs({ ... }) do if a == '--long' then long = true end end

local results = MB.run{ budgetSec = long and 0.6 or 0.2 }
local graded = MB.grade(results)

print(('%-22s %14s %14s %8s  %s')
      :format('op', 'ops/sec', 'floor', 'x', 'verdict'))
print(('-'):rep(70))
for _, row in ipairs(graded.rows) do
    print(('%-22s %14.0f %14s %8s  %s'):format(
        row.name,
        row.opsPerSec,
        row.floor and ('%.0f'):format(row.floor) or '-',
        row.ratio and ('%.2f'):format(row.ratio) or '-',
        row.verdict))
end
print(('-'):rep(70))
if not isJit then
    print('BUDGET GATE OFF (not LuaJIT — floors are LuaJIT-calibrated). '
          .. 'Numbers above are informational; run under luajit to gate.')
    os.exit(0)
end
print(graded.ok and 'BUDGET OK' or 'BUDGET FAILED')
os.exit(graded.ok and 0 or 1)
