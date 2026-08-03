-- Deep packet fuzz (G5).
--
--   luajit scripts/fuzz.lua                 (8 seeds x 20000 each)
--   luajit scripts/fuzz.lua 50 100000       (seeds 1..50, 100k iters each)
--
-- Exit 0 only if no parser ever raised or accepted junk. A failure prints
-- its exact (seed, target, iteration) so it replays. Run from the repo root.

package.path = './?.lua;./?/init.lua;' .. package.path

local Fuzz = require('meatray.net.fuzz')

local seeds = tonumber((...)) or 8
local iters = tonumber(select(2, ...)) or 20000

local sane, why = Fuzz.sanity()
if not sane then
    print('SANITY FAILED: ' .. tostring(why))
    os.exit(2)
end

local totalCases, failed = 0, 0
for seed = 1, seeds do
    local r = Fuzz.run{ seed = seed, iterations = iters }
    totalCases = totalCases + r.cases
    if not r.ok then
        failed = failed + #r.failures
        for _, f in ipairs(r.failures) do
            print(('FAIL seed=%d target=%s iter=%d  %s')
                  :format(seed, f.target, f.iteration, f.why))
        end
    end
    io.write(('seed %d: %d cases, %d failures\n'):format(seed, r.cases, #r.failures))
end

print(('-'):rep(50))
print(('%d cases across %d seeds, %d failures'):format(totalCases, seeds, failed))
os.exit(failed == 0 and 0 or 1)
