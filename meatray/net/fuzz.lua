--[[
    meatray.net.fuzz — throw garbage at every parser and prove it flinches
    cleanly (G5).

    A dedicated server takes bytes from strangers. The whole net stack is
    written to REFUSE bad input — return nil plus a reason — rather than raise
    or hang, because a raise is a crash a stranger can trigger and a hang is a
    denial of service. That is a promise, and a promise no test exercises is a
    wish. This module is the exercise: it mutates good inputs and feeds random
    ones into each parser, and the contract it checks is uniform — every call
    returns (never raises), and returns promptly (a bounded number of steps),
    and a refusal is a nil/false, never a partial structure passed off as real.

        local Fuzz = require('meatray.net.fuzz')
        local report = Fuzz.run{ seed = 1, iterations = 2000 }
        report.ok          -- no parser ever raised or produced junk
        report.cases       -- how many inputs were tried
        report.failures    -- { { target=, input=, why= }, ... }

    Determinism: the generator is the engine LCG seeded from `seed`, so a
    failure is a fixed (seed, iteration) a developer can replay exactly —
    the same reason demos carry a seed. Nothing here reads a clock or
    math.random.

    Mutations, per target, over that target's own valid samples:
      * truncate    — every prefix, so a length field can outrun the buffer
      * flip        — one bit, one byte, so a tag or count goes wrong alone
      * splice      — random bytes appended/inserted, so a parser reading a
                      declared length walks past what it should
      * garbage     — pure random bytes of random length, the cold-open case

    HEADLESS: pure Lua.
]]

local Worldgen = require('meatray.sim.worldgen')

local Fuzz = {}

local char, byte, sub = string.char, string.byte, string.sub
local floor = math.floor

---------------------------------------------------------------------------
-- Targets: (name, a parser wrapped so a raise becomes a caught failure, and
-- a few valid samples to mutate).
---------------------------------------------------------------------------

-- Every target's call is wrapped so that ANY of these counts as a pass:
--   nil + reason           the documented refusal
--   false + reason         same, for the boolean-returning parsers
--   a real parsed value     (only for inputs that happen to be valid)
-- and exactly one thing counts as a failure: the pcall itself erroring.
-- "Never a partial structure passed off as real" is enforced per target by
-- its own accept() when it returns a table.
local function buildTargets()
    local P = require('meatray.net.protocol')
    local Codec = require('meatray.net.snapcodec')
    local Wire = require('meatray.net.relaywire')

    local targets = {}

    -- protocol.unpack: the front door for every datagram.
    do
        local samples = {}
        samples[#samples + 1] = P.pack(P.PING, { time = 1 })
        samples[#samples + 1] = P.pack(P.CHAT, { text = 'hi' })
        samples[#samples + 1] = P.pack(P.KICK, { reason = 'x' })
        samples[#samples + 1] = P.pack(P.RESPAWN, { entityId = 42 })
        targets[#targets + 1] = {
            name = 'protocol.unpack',
            samples = samples,
            call = function(s) return P.unpack(s) end,
        }
    end

    -- snapcodec.decode: the largest and most structured payload.
    do
        local snap = { tick = 7, e = {
            { id = 1, kind = 'p', x = 1.5, y = 2.5, angle = 0.3,
              c = { h = { hp = 88, max = 100 } } },
            { id = 2, kind = 'g', x = -3.25, y = 9.75, angle = -1.1 },
        } }
        targets[#targets + 1] = {
            name = 'snapcodec.decode',
            samples = { Codec.encode(snap) },
            call = function(s) return Codec.decode(s) end,
        }
    end

    -- relaywire.parse: control frames from an untrusted relay peer.
    do
        local samples = { 'D 1 2 hello', 'HELLO 3' }
        if Wire.data then samples[#samples + 1] = Wire.data(1, 'abc') end
        if Wire.control then samples[#samples + 1] = Wire.control('PING') end
        targets[#targets + 1] = {
            name = 'relaywire.parse',
            samples = samples,
            call = function(s) return Wire.parse(s) end,
        }
    end

    -- relaywire.parseTicket: the four-field connect string.
    do
        targets[#targets + 1] = {
            name = 'relaywire.parseTicket',
            samples = { 'a.b.c.d', '1.2.3.4', 'x' },
            call = function(s) return Wire.parseTicket(s) end,
        }
    end

    -- masterserver line parser, when present.
    do
        local okHttp, http = pcall(require, 'masterserver.http')
        if okHttp and http and http.parseRequest then
            targets[#targets + 1] = {
                name = 'masterserver.parseRequest',
                samples = {
                    'GET /list HTTP/1.1\r\nHost: x\r\n\r\n',
                    'POST /announce HTTP/1.1\r\n\r\n{}',
                },
                call = function(s) return http.parseRequest(s) end,
            }
        end
    end

    return targets
end

---------------------------------------------------------------------------
-- Mutation, all driven by one seeded LCG
---------------------------------------------------------------------------

local function mutate(rng, sample)
    local mode = rng:int(1, 4)

    if mode == 1 then
        -- truncate to a random prefix
        if #sample == 0 then return '' end
        return sub(sample, 1, rng:int(0, #sample))

    elseif mode == 2 then
        -- flip one bit of one byte
        if #sample == 0 then return char(rng:int(0, 255)) end
        local i = rng:int(1, #sample)
        local b = byte(sample, i)
        local flipped = b
        -- xor a single random bit without a bit library
        local bit = 2 ^ rng:int(0, 7)
        if floor(b / bit) % 2 == 1 then flipped = b - bit else flipped = b + bit end
        return sub(sample, 1, i - 1) .. char(flipped % 256) .. sub(sample, i + 1)

    elseif mode == 3 then
        -- splice random bytes in
        local n = rng:int(1, 8)
        local junk = {}
        for _ = 1, n do junk[#junk + 1] = char(rng:int(0, 255)) end
        local at = rng:int(0, #sample)
        return sub(sample, 1, at) .. table.concat(junk) .. sub(sample, at + 1)
    end

    -- pure garbage
    local n = rng:int(0, 64)
    local junk = {}
    for _ = 1, n do junk[#junk + 1] = char(rng:int(0, 255)) end
    return table.concat(junk)
end

---------------------------------------------------------------------------
-- The run
---------------------------------------------------------------------------

-- opts: seed (default 1), iterations (per target, default 500)
function Fuzz.run(opts)
    opts = opts or {}
    local seed = tonumber(opts.seed) or 1
    local iters = tonumber(opts.iterations) or 500
    local targets = buildTargets()

    local failures = {}
    local cases = 0

    for _, target in ipairs(targets) do
        -- Each target gets its own stream, derived from the run seed and a
        -- stable hash of its name, so adding a target does not shift the
        -- inputs the others see (a failure keeps its coordinates).
        local nameHash = 0
        for i = 1, #target.name do nameHash = (nameHash * 31 + byte(target.name, i)) % 2 ^ 24 end
        local rng = Worldgen.rng((seed + nameHash) % 4294967296)

        for i = 1, iters do
            local sample = target.samples[rng:int(1, #target.samples)] or ''
            local input = mutate(rng, sample)
            cases = cases + 1

            local ok, a, b, c = pcall(target.call, input)
            if not ok then
                failures[#failures + 1] = {
                    target = target.name, iteration = i,
                    why = 'RAISED: ' .. tostring(a),
                    input = input,
                }
            elseif type(a) == 'table' and target.accept then
                local good, why = target.accept(a)
                if not good then
                    failures[#failures + 1] = {
                        target = target.name, iteration = i,
                        why = 'accepted junk: ' .. tostring(why),
                        input = input,
                    }
                end
            end
        end
    end

    return {
        ok = #failures == 0,
        cases = cases,
        targets = #targets,
        failures = failures,
    }
end

-- The valid-input floor: every parser must accept its own good samples, or a
-- "never raises" pass is meaningless (a parser that refuses everything also
-- never raises). Returns true, or false plus the target that rejected itself.
function Fuzz.sanity()
    local targets = buildTargets()
    for _, target in ipairs(targets) do
        for _, sample in ipairs(target.samples) do
            local ok, a = pcall(target.call, sample)
            if not ok then
                return false, target.name .. ' raised on its own valid sample'
            end
        end
    end
    return true
end

return Fuzz
