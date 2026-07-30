--[[
    scripts/snapbytes.lua — what dirty-flag snapshots actually save.

        luajit scripts/snapbytes.lua

    Headless, no LOVE, no sockets: it builds a scene, moves a stated fraction of
    it, and runs the real encoder over the real dirty-flag baseline. The point is
    that the phase 14 numbers can be re-measured rather than believed, including
    the case that matters most — a tile world with EVERYTHING moving, where a
    dirty-flag stream must not come out worse than the full snapshots it replaced.

    Every column is bytes on the wire, `P.packSnapshot` output including the
    one-byte tag, which is what the fragment threshold is measured against.
]]

package.path = './?.lua;./?/init.lua;' .. package.path

local Entity = require('meatray.sim.entity')
local C      = require('meatray.sim.components')
local Rep    = require('meatray.net.replication')
local P      = require('meatray.net.protocol')

---------------------------------------------------------------------------
-- The same scene tests/test_net_snapcodec.lua measures against: eight players
-- carrying billboard/health/player/weapon and twenty-four grunts carrying
-- billboard/health, at coordinates a running game produces rather than round
-- ones.
---------------------------------------------------------------------------

local PLAYERS, GRUNTS = 8, 24

local function scene()
    Entity.resetIds(1)
    local list = {}

    for i = 1, PLAYERS do
        local e = Entity.new{ kind = 'player',
                              x = 12.5 + i * 0.37, y = 9.25 + i * 0.11,
                              angle = 0.5 + i * 0.13 }
        e:add(C.Billboard{ sheet = 'marine' })
        e:add(C.Health{ hp = 88 - i, max = 100 })
        e:add(C.Player{ peerId = i, name = ('player %d'):format(i) })
        e:add(C.Weapon{ ammo = 42 - i })
        list[#list + 1] = e
    end

    for i = 1, GRUNTS do
        local e = Entity.new{ kind = 'grunt',
                              x = 3.5 + i * 0.91, y = 21.75 + i * 0.23,
                              angle = 1.25 + i * 0.07 }
        e:add(C.Billboard{ sheet = 'grunt' })
        e:add(C.Health{ hp = 30, max = 30 })
        list[#list + 1] = e
    end

    return list
end

---------------------------------------------------------------------------

local FRAMES = 200      -- ten keyframe intervals at the default of ten

-- Moves the first `moving` entities by a step no smaller than a binary32 tick,
-- so "moved" means moved as far as the wire is concerned. `damage` also changes
-- a replicated component field, which is what decides whether the `c` block can
-- be left out of a partial.
local function run(entities, moving, interval, churn)
    local baseline = nil
    if interval > 1 then baseline = Rep.newBaseline() end

    local total, keyframeBytes, partialBytes = 0, 0, 0
    local keyframes, partials = 0, 0
    local biggest = 0

    for frame = 1, FRAMES do
        for i = 1, moving do
            local e = entities[i]
            e.x = e.x + 0.0417
            e.y = e.y + 0.0231
            e.angle = e.angle + 0.011

            if churn == 'hurt' then
                local h = e:get('health')
                if h then h.hp = h.hp - 1 end

            elseif churn == 'everything' then
                -- The adversarial case: every field of every declaration moves,
                -- so a partial has nothing at all it can leave out and the whole
                -- mechanism is pure overhead. This is the number that has to not
                -- be worse than a full snapshot.
                for name, component in pairs(e.components) do
                    local declared = Entity.netFieldsFor(name)
                    for j = 1, #(declared or {}) do
                        local key = declared[j]
                        local value = component[key]
                        if type(value) == 'number' then
                            component[key] = value + 1
                        elseif type(value) == 'string' then
                            -- A new string every frame, at a FIXED length. A
                            -- string that grew would measure string growth
                            -- rather than the codec, and one that alternated
                            -- between two values would keep landing back on the
                            -- keyframe's value and count as unchanged — which is
                            -- the opposite of adversarial.
                            component[key] = ('f%07d'):format(frame)
                        end
                    end
                end
            end
        end

        local full = Rep.keyframeDue(baseline, interval)
        local list, removed, isKeyframe = Rep.snapshotFrame(entities, baseline, full)

        local body = { tick = frame, e = list, full = isKeyframe }
        if not isKeyframe then body.r = removed end

        local packet, compact, why = P.packSnapshot(body)
        if not compact then
            error('the codec fell back to text: ' .. tostring(why))
        end

        total = total + #packet
        if #packet > biggest then biggest = #packet end

        if isKeyframe then
            keyframes, keyframeBytes = keyframes + 1, keyframeBytes + #packet
        else
            partials, partialBytes = partials + 1, partialBytes + #packet
        end
    end

    return {
        mean      = total / FRAMES,
        biggest   = biggest,
        keyframe  = keyframes > 0 and (keyframeBytes / keyframes) or 0,
        partial   = partials > 0 and (partialBytes / partials) or 0,
        keyframes = keyframes,
        partials  = partials,
    }
end

---------------------------------------------------------------------------

print(('MeatRayCast snapshot bytes — %d entities, %d frames, %d-byte MTU budget')
      :format(PLAYERS + GRUNTS, FRAMES, P.MTU_SAFE_BYTES))
print(('%-26s %9s %9s %9s %9s'):format('scenario', 'mean', 'keyframe', 'partial', 'largest'))
print(('-'):rep(68))

local CASES = {
    { 'idle',                0,  nil },
    { '1 of 32 moving',      1,  nil },
    { '8 of 32 moving',      8,  nil },
    { '16 of 32 moving',     16, nil },
    { 'all 32 moving',       32, nil },
    { 'all 32 moving+hurt',  32, 'hurt' },
    { 'all 32, every field', 32, 'everything' },
}

for _, case in ipairs(CASES) do
    local label, moving, churn = case[1], case[2], case[3]

    local before = run(scene(), moving, 1, churn)           -- keyframes only
    local after  = run(scene(), moving, Rep.KEYFRAME_INTERVAL, churn)

    print(('%-26s %9.1f %9s %9s %9d   full snapshots today')
          :format(label, before.mean, '-', '-', before.biggest))
    print(('%-26s %9.1f %9.1f %9.1f %9d   dirty, keyframe every %d  (%+.0f%%)')
          :format('', after.mean, after.keyframe, after.partial, after.biggest,
                  Rep.KEYFRAME_INTERVAL,
                  (after.mean / before.mean - 1) * 100))
    print('')
end

print(('-'):rep(68))
print(('keyframe interval sweep, 8 of 32 moving'))
for _, interval in ipairs({ 1, 2, 5, 10, 20, 40 }) do
    local r = run(scene(), 8, interval, nil)
    print(('  every %2d frames: mean %6.1f bytes, largest %4d, %d keyframes / %d partials')
          :format(interval, r.mean, r.biggest, r.keyframes, r.partials))
end
