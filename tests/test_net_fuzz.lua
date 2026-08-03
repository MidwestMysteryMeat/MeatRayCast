--[[
    G5: the fuzzer that proves the parsers refuse rather than raise. Kept
    modest in the suite (a few thousand inputs, one seed) so it costs
    milliseconds; scripts/fuzz.lua is the deep run.
]]

return function(t)
    local Fuzz = require('meatray.net.fuzz')

    ---------------------------------------------------------------------
    t.describe('the parsers accept their own valid input')

    -- A "never raises" pass is worthless if a parser refuses EVERYTHING —
    -- that also never raises. This floor makes the main assertion mean
    -- something.
    local sane, why = Fuzz.sanity()
    t.eq(sane, true, 'every target accepts its own samples' .. (sane and '' or (': ' .. tostring(why))))

    ---------------------------------------------------------------------
    t.describe('no mutated input ever raises or is accepted as junk')

    local report = Fuzz.run{ seed = 1, iterations = 1500 }
    t.ok(report.targets >= 4,
         ('at least four parsers under test (%d)'):format(report.targets))
    t.ok(report.cases > 5000, ('thousands of inputs (%d)'):format(report.cases))

    local detail = ''
    for i = 1, math.min(3, #report.failures) do
        local f = report.failures[i]
        detail = detail .. ('\n  %s @%d: %s'):format(f.target, f.iteration, f.why)
    end
    t.eq(report.ok, true, 'not one parser raised or accepted junk' .. detail)

    ---------------------------------------------------------------------
    t.describe('a run is deterministic: same seed, same verdict')

    -- The whole point of a seed is that a failure replays. Two runs at the
    -- same seed must try the same inputs and reach the same count.
    local a = Fuzz.run{ seed = 7, iterations = 800 }
    local b = Fuzz.run{ seed = 7, iterations = 800 }
    t.eq(a.cases, b.cases, 'the same seed tries the same number of cases')
    t.eq(a.ok, b.ok, 'and reaches the same verdict')

    local c = Fuzz.run{ seed = 8, iterations = 800 }
    t.eq(c.ok, true, 'a different seed is also clean (and covers other inputs)')
end
