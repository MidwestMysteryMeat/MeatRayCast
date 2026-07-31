--[[
    Dirty-flag snapshots: sending only what changed, and still converging.

    THE PROPERTY THIS FILE EXISTS TO PIN

    Snapshots are unreliable. Any of them may be dropped, and "send only the
    changes" has to answer the obvious objection — what about a client that
    missed the change? The answer here is that a partial is a diff against the
    last KEYFRAME rather than against the previous frame, which makes the whole
    stream idempotent:

        keyframe K + ANY ONE later partial  ==  the host's exact state

    So a client can drop every partial but one and still be right, with no
    retransmit, no acknowledgement, and nothing stored per peer. That is asserted
    below by dropping packets, not by describing the design — including the one
    case where it does NOT hold (a dropped keyframe), which is asserted to be
    bounded rather than quietly left out.

    The other thing worth pinning is that none of this is allowed to make the
    stream bigger. A snapshot past one MTU stops being unreliable (see
    meatray/net/snapcodec.lua), so "a tile world where everything moves" must not
    come out worse than the full snapshots it replaced. There is a measurement for
    that here and a re-runnable one in scripts/snapbytes.lua.
]]

return function(t)
    local Entity   = require('meatray.sim.entity')
    local C        = require('meatray.sim.components')
    local Rep      = require('meatray.net.replication')
    local Codec    = require('meatray.net.snapcodec')
    local P        = require('meatray.net.protocol')
    local Net      = require('meatray.net')
    local Worldgen = require('meatray.sim.worldgen')
    local Loopback = require('meatray.net.transport.loopback')

    -----------------------------------------------------------------------
    -- Fixtures
    -----------------------------------------------------------------------

    -- A component with a table-valued replicated field, because "did it change?"
    -- over a table is where an identity comparison silently works until someone
    -- mutates a list in place.
    local Pack = Entity.component('dirtypack', { 'slots', 'weight' })

    local function defineArchetypes()
        Entity.clearArchetypes()

        Entity.archetype('player', function(e)
            e:add(C.Billboard{ sheet = 'marine' })
            e:add(C.Health{ hp = 100, max = 100 })
            e:add(C.Player{ peerId = 0, name = '?' })
            e:add(C.Weapon{ ammo = 40 })
            e.radius = 0.24
        end)

        Entity.archetype('grunt', function(e)
            e:add(C.Billboard{ sheet = 'grunt' })
            e:add(C.Health{ hp = 30, max = 30 })
            e.radius = 0.28
        end)

        Entity.archetype('mule', function(e)
            e:add(C.Billboard{ sheet = 'mule' })
            e:add(Pack{ slots = { 'rope', 'lamp' }, weight = 7 })
        end)
    end

    -- Eight players and twenty-four grunts, the same shape
    -- tests/test_net_snapcodec.lua measures against, at coordinates a running
    -- game produces rather than round ones.
    local function scene(players, grunts)
        Entity.resetIds(1)
        local list = {}

        for i = 1, (players or 8) do
            local e = Entity.spawn('player', 12.5 + i * 0.37, 9.25 + i * 0.11)
            e.angle = 0.5 + i * 0.13
            e:get('health').hp = 88 - i
            e:get('player').peerId = i
            e:get('weapon').ammo = 42 - i
            list[#list + 1] = e
        end

        for i = 1, (grunts or 24) do
            local e = Entity.spawn('grunt', 3.5 + i * 0.91, 21.75 + i * 0.23)
            e.angle = 1.25 + i * 0.07
            list[#list + 1] = e
        end

        return list
    end

    -- One frame of the real stream: build it, encode it with the real codec,
    -- decode it, and hand the result to the real client-side reconciler. Nothing
    -- is faked and nothing is short-circuited, so a frame that is dropped in a
    -- test is dropped exactly where a datagram would be.
    local function frame(entities, baseline, forceFull)
        local full = forceFull
        if full == nil then full = Rep.keyframeDue(baseline, Rep.KEYFRAME_INTERVAL) end

        local list, removed, isKeyframe = Rep.snapshotFrame(entities, baseline, full)

        local body = {
            tick = 1,
            e    = list,
            full = isKeyframe,
            k    = baseline and baseline.keyframes or 0,
        }
        if not isKeyframe then body.r = removed end

        local packet = P.packSnapshot(body)
        local _, decoded = P.unpack(packet)

        return decoded, packet, isKeyframe
    end

    local function deliver(state, body)
        return Rep.applyEntities(state, body.e or {}, {
            full    = body.full ~= false,
            removed = body.r,
        })
    end

    -- Everything the host believes, compared with everything the client has, at
    -- the precision the wire actually carries. Returns nil when they agree and a
    -- description of the first disagreement when they do not.
    local function disagreement(entities, state)
        local live = 0

        for i = 1, #entities do
            local e = entities[i]
            if not e.dead and not e.localOnly then
                live = live + 1
                local got = state.byId[e.id]
                if not got then
                    return ('entity %d (%s) is missing on the client'):format(e.id, e.kind)
                end

                for _, axis in ipairs({ 'x', 'y', 'angle' }) do
                    local want = (axis == 'angle')
                        and Codec.quantiseAngle(e[axis])
                        or  Codec.quantise(e[axis])
                    if got[axis] ~= want then
                        return ('entity %d %s is %.17g, host says %.17g')
                               :format(e.id, axis, got[axis], want)
                    end
                end

                for name, component in pairs(e.components) do
                    local declared = Entity.netFieldsFor(name)
                    for j = 1, #(declared or {}) do
                        local key = declared[j]
                        local mine = component[key]
                        local theirs = got:get(name) and got:get(name)[key]
                        if type(mine) == 'table' then
                            for k = 1, #mine do
                                if not theirs or theirs[k] ~= mine[k] then
                                    return ('entity %d %s.%s[%d] disagrees')
                                           :format(e.id, name, key, k)
                                end
                            end
                        elseif mine ~= theirs then
                            return ('entity %d %s.%s is %s, host says %s')
                                   :format(e.id, name, key, tostring(theirs), tostring(mine))
                        end
                    end
                end
            end
        end

        local held = 0
        for _ in pairs(state.byId) do held = held + 1 end
        if held ~= live then
            return ('the client holds %d entities and the host has %d'):format(held, live)
        end

        return nil
    end

    local function newState()
        return { entities = {}, byId = {} }
    end

    local function move(e, n)
        n = n or 1
        e.x = e.x + 0.0417 * n
        e.y = e.y + 0.0231 * n
        e.angle = e.angle + 0.011 * n
    end

    defineArchetypes()

    -----------------------------------------------------------------------
    t.describe('the frame kinds are on the wire, not inferred')

    local entities = scene(2, 2)
    local baseline = Rep.newBaseline()

    local keyBody, keyPacket, wasKeyframe = frame(entities, baseline)
    t.eq(wasKeyframe, true, 'the first frame after a fresh baseline is a keyframe')
    t.eq(keyBody.full, true, 'and says so on the wire')
    t.eq(keyBody.r, nil, 'a keyframe carries no removal list at all')
    t.eq(#keyBody.e, 4, 'and carries every entity')

    move(entities[1])
    local partBody, partPacket, wasPartial = frame(entities, baseline)
    t.eq(wasPartial, false, 'the next frame is a partial')
    t.eq(partBody.full, false, 'which also says so on the wire')
    t.ok(partBody.r ~= nil, 'and carries a removal list, even an empty one')
    t.eq(#partBody.e, 1, 'naming only the entity that moved')
    t.eq(partBody.e[1].id, entities[1].id, 'and it is the right one')

    -- Every fixture, tool and older caller in this tree builds { tick, e } and
    -- means "here is everything". That has to keep meaning what it always did.
    local legacy = Codec.decode(Codec.encode{ tick = 5, e = {} })
    t.eq(legacy and legacy.full, true, 'a body with no `full` key decodes as a keyframe')

    local refused, why = Codec.encode{ tick = 5, e = {}, full = true, r = { 9 } }
    t.eq(refused, nil, 'a keyframe carrying removals is refused rather than ignored')
    t.ok(why and why:find('keyframe'), 'with a reason that names the confusion', why)

    -- An undefined header bit means a frame kind this build does not have, and
    -- reading on would produce a plausible-looking wrong world.
    local badHeader = Codec.decode(string.char(1, Codec.VERSION, 2, 0, 0, 0))
    t.eq(badHeader, nil, 'an undefined header flag bit is refused')

    -----------------------------------------------------------------------
    t.describe('what counts as changed comes from netFields, not from a list')

    entities = scene(1, 1)
    baseline = Rep.newBaseline()
    frame(entities, baseline)                                  -- keyframe

    local player, grunt = entities[1], entities[2]

    move(player)
    local body = frame(entities, baseline)
    t.eq(#body.e, 1, 'an idle entity is not in the partial at all')
    t.ok(body.e[1].x ~= nil and body.e[1].y ~= nil, 'the mover carries its transform')
    t.eq(body.e[1].c, nil,
         'and carries no component block, because no declared field changed')
    t.eq(body.e[1].kind, nil, 'nor its kind, which cannot change')

    player:get('health').hp = 41
    body = frame(entities, baseline)
    t.ok(body.e[1].c and body.e[1].c.health, 'a damaged entity carries its health')
    t.eq(body.e[1].c.health.hp, 41, 'with the field that changed')
    t.eq(body.e[1].c.health.max, nil, 'and not the one that did not')
    t.eq(body.e[1].c.billboard, nil, 'nor a component that did not change at all')
    t.eq(body.e[1].c.weapon, nil, 'nor another one')

    -- Diffing against the KEYFRAME rather than against the previous frame has a
    -- second consequence, and it is the one that keeps local-player prediction
    -- honest: an entity that moved at all since the keyframe stays in EVERY
    -- partial until the next one, because it still differs from the baseline. So
    -- a client that mispredicted keeps being told the authoritative position
    -- every frame, rather than once and then never again.
    frame(entities, baseline, true)
    move(player)
    for step = 1, Rep.KEYFRAME_INTERVAL - 3 do
        local held = frame(entities, baseline)          -- player is NOT moved again
        local present = false
        for i = 1, #held.e do
            if held.e[i].id == player.id then present = held.e[i].x ~= nil end
        end
        t.eq(present, true,
             ('a player that moved once is still corrected on partial %d'):format(step))
    end

    -- The point of deriving from the declaration: a component this file invents
    -- right now is tracked with no edit to the codec and no edit to the diff.
    local Fresh = Entity.component('dirtyfresh', { 'stamina' })
    player:add(Fresh{ stamina = 3 })
    frame(entities, baseline, true)                            -- re-baseline
    player:get('dirtyfresh').stamina = 4
    body = frame(entities, baseline)
    t.eq(body.e[1] and body.e[1].c and body.e[1].c.dirtyfresh
         and body.e[1].c.dirtyfresh.stamina, 4,
         'a declaration added at runtime replicates its change with no codec edit')

    -- Quantisation. The baseline holds what the receiver will hold, not what the
    -- host holds, or an entity drifting by less than a binary32 step is dirty
    -- forever and re-sent every frame to say nothing.
    frame(entities, baseline, true)
    grunt.x = grunt.x + grunt.x * 2 ^ -30
    body = frame(entities, baseline)
    local movedIds = {}
    for i = 1, #body.e do movedIds[body.e[i].id] = true end
    t.eq(movedIds[grunt.id], nil,
         'a nudge below one binary32 step is not a change, because the wire cannot carry it')

    grunt.x = grunt.x + 0.5
    body = frame(entities, baseline)
    movedIds = {}
    for i = 1, #body.e do movedIds[body.e[i].id] = true end
    t.eq(movedIds[grunt.id], true, 'and a nudge the wire can carry is')

    -- A table-valued replicated field, mutated in place. An identity comparison
    -- would call this unchanged and the client would never see it.
    local mule = Entity.spawn('mule', 4.5, 4.5)
    entities[#entities + 1] = mule
    frame(entities, baseline, true)
    mule:get('dirtypack').slots[3] = 'flint'
    body = frame(entities, baseline)
    local packed
    for i = 1, #body.e do
        if body.e[i].id == mule.id then packed = body.e[i] end
    end
    t.ok(packed and packed.c and packed.c.dirtypack,
         'a table field mutated in place is seen as changed')
    t.eq(packed and packed.c and packed.c.dirtypack and packed.c.dirtypack.slots[3], 'flint',
         'and the new contents travel')
    t.eq(packed and packed.c and packed.c.dirtypack and packed.c.dirtypack.weight, nil,
         'while the field beside it stays home')

    -- And the baseline holds a copy rather than the live table, or the next
    -- mutation would edit the thing it is being compared against.
    frame(entities, baseline, true)
    body = frame(entities, baseline)
    t.eq(#body.e, 0, 'nothing is dirty immediately after a keyframe')

    -----------------------------------------------------------------------
    t.describe('a removal is explicit, and it repeats until the keyframe')

    entities = scene(1, 3)
    baseline = Rep.newBaseline()
    frame(entities, baseline)

    local doomed = table.remove(entities, 2)
    body = frame(entities, baseline)
    t.eq(#(body.r or {}), 1, 'an entity that left the list is named as removed')
    t.eq(body.r[1], doomed.id, 'by id')

    -- The repeat is the whole answer to "what if the client dropped that one".
    body = frame(entities, baseline)
    t.eq(#(body.r or {}), 1, 'and is named again in the next partial')
    body = frame(entities, baseline)
    t.eq(body.r[1], doomed.id, 'and the one after that')

    -- Something that lived and died entirely between two keyframes still has to
    -- be removable, and it was never in the baseline to be missed from.
    local mayfly = Entity.spawn('grunt', 9.5, 9.5)
    entities[#entities + 1] = mayfly
    body = frame(entities, baseline)
    local named = false
    for i = 1, #body.e do
        if body.e[i].id == mayfly.id then named = true end
    end
    t.eq(named, true, 'an entity spawned since the keyframe is sent whole')
    t.ok(body.e[1] ~= nil and (function()
            for i = 1, #body.e do
                if body.e[i].id == mayfly.id then return body.e[i].kind ~= nil end
            end
        end)(), 'including its kind, because a client has nothing to build it from')

    table.remove(entities, #entities)
    body = frame(entities, baseline)
    local removedSet = {}
    for i = 1, #(body.r or {}) do removedSet[body.r[i]] = true end
    t.eq(removedSet[mayfly.id], true,
         'and is removable even though it was never in the baseline')
    t.eq(removedSet[doomed.id], true, 'alongside the earlier removal, still repeating')

    body = frame(entities, baseline, true)
    t.eq(body.r, nil, 'a keyframe clears the removal list, because absence says it')
    t.eq(#body.e, #entities, 'and carries exactly what is alive')

    -- The schedule, asserted rather than assumed: one keyframe then nine
    -- partials, forever.
    entities = scene(1, 1)
    baseline = Rep.newBaseline()
    local pattern = {}
    for _ = 1, Rep.KEYFRAME_INTERVAL * 2 do
        local _, _, key = frame(entities, baseline)
        pattern[#pattern + 1] = key and 'K' or '.'
    end
    t.eq(table.concat(pattern),
         ('K' .. ('.'):rep(Rep.KEYFRAME_INTERVAL - 1)):rep(2),
         'a keyframe every ' .. Rep.KEYFRAME_INTERVAL .. ' frames, and no drift')

    -- Enough churn and a keyframe comes early, because the removal list repeats
    -- until one does and would otherwise grow without bound.
    entities = scene(1, Rep.MAX_PENDING_REMOVALS + 8)
    baseline = Rep.newBaseline()
    frame(entities, baseline, true)
    for _ = 1, Rep.MAX_PENDING_REMOVALS do table.remove(entities, #entities) end

    local _, _, forced = frame(entities, baseline)
    t.eq(forced, false, 'the frame that reports the removals is still a partial')
    local _, _, early = frame(entities, baseline)
    t.eq(early, true,
         ('%d pending removals force a keyframe early rather than repeating forever')
         :format(Rep.MAX_PENDING_REMOVALS))

    -----------------------------------------------------------------------
    t.describe('a client that dropped packets converges')

    -- The load-bearing one: keyframe plus ANY ONE later partial is exact. This
    -- is what makes a lossy channel survivable without a repair protocol.
    entities = scene(4, 8)
    baseline = Rep.newBaseline()
    local state = newState()

    deliver(state, (frame(entities, baseline, true)))
    t.eq(disagreement(entities, state), nil,
         'a keyframe alone puts the client exactly where the host is')

    local dropped = 0
    for step = 1, Rep.KEYFRAME_INTERVAL - 1 do
        for i = 1, 4 do move(entities[i]) end
        entities[5]:get('health').hp = 30 - step
        local partial = frame(entities, baseline)
        if step < Rep.KEYFRAME_INTERVAL - 1 then
            dropped = dropped + 1                     -- thrown away, never applied
        else
            deliver(state, partial)
        end
    end

    t.eq(dropped, Rep.KEYFRAME_INTERVAL - 2,
         ('%d partials were dropped on the floor'):format(dropped))
    t.eq(disagreement(entities, state), nil,
         'and the one that arrived was enough to be exactly right again')

    -- Every partial dropped: the keyframe is the floor, and it always comes.
    entities = scene(4, 8)
    baseline = Rep.newBaseline()
    state = newState()
    deliver(state, (frame(entities, baseline, true)))

    for step = 1, Rep.KEYFRAME_INTERVAL - 1 do
        for i = 1, 4 do move(entities[i]) end
        frame(entities, baseline)                     -- built, encoded, discarded
    end
    t.ok(disagreement(entities, state) ~= nil,
         'with every partial lost the client is behind, as it must be')

    local recovery, isKey = select(1, frame(entities, baseline)), nil
    recovery, _, isKey = frame(entities, baseline, true)
    deliver(state, recovery)
    t.eq(isKey, true, 'the keyframe arrives on schedule')
    t.eq(disagreement(entities, state), nil, 'and repairs everything at once')

    -- The one failure mode this design has, asserted rather than omitted: a
    -- client that drops a KEYFRAME is stale on whatever changed and then stopped
    -- inside that interval, and is bounded by the next keyframe.
    entities = scene(2, 2)
    baseline = Rep.newBaseline()
    state = newState()
    deliver(state, (frame(entities, baseline, true)))

    move(entities[1])
    deliver(state, (frame(entities, baseline)))       -- client is current

    local settled = entities[1].x
    frame(entities, baseline, true)                   -- KEYFRAME, dropped
    move(entities[2])
    deliver(state, (frame(entities, baseline)))

    t.eq(Codec.quantise(state.byId[entities[2].id].x), Codec.quantise(entities[2].x),
         'after a dropped keyframe the entities still changing are still correct')
    t.eq(Codec.quantise(state.byId[entities[1].id].x), Codec.quantise(settled),
         'and one that stopped holds the value it had, rather than anything invented')

    deliver(state, (frame(entities, baseline, true)))
    t.eq(disagreement(entities, state), nil,
         'and the next keyframe closes it, so the staleness is bounded by the interval')

    -- The generation field on every frame is what lets a client notice the gap
    -- above without waiting for the next scheduled keyframe. A partial whose k
    -- is ahead of the last keyframe the client applied is the signal; the host
    -- answers a 'resync' command with one reliable full snapshot.
    do
        local hostEntities = scene(2, 2)
        local hostBaseline = Rep.newBaseline()
        local hostState = newState()
        local first = select(1, frame(hostEntities, hostBaseline, true))
        t.eq(first.k, 1, 'the first keyframe is generation 1')
        deliver(hostState, first)

        move(hostEntities[1])
        local part = select(1, frame(hostEntities, hostBaseline))
        t.eq(part.k, 1, 'partials carry the generation they are relative to')
        t.eq(part.full, false, 'and are still partials')

        -- Drop the next keyframe. The following partial has k = 2 while the
        -- client still holds generation 1.
        move(hostEntities[1])
        frame(hostEntities, hostBaseline, true)          -- keyframe gen 2, dropped
        move(hostEntities[2])
        local gap = select(1, frame(hostEntities, hostBaseline))
        t.eq(gap.k, 2, 'the partial after a dropped keyframe carries the new generation')
        t.ok(gap.k > first.k, 'which is strictly greater than what the client last applied')
    end

    -- A partial for an entity a client has never seen carries no kind, and a
    -- nameless componentless ghost at the right position is worse than a gap.
    entities = scene(1, 1)
    baseline = Rep.newBaseline()
    state = newState()
    frame(entities, baseline, true)                   -- keyframe, dropped
    move(entities[2])
    local spawnedCount = deliver(state, (frame(entities, baseline)))
    t.eq(spawnedCount, 0, 'a partial for an unknown entity with no kind is skipped')
    t.eq(state.byId[entities[2].id], nil, 'rather than adopted as a ghost')
    deliver(state, (frame(entities, baseline, true)))
    t.ok(state.byId[entities[2].id] ~= nil, 'and the next keyframe introduces it properly')

    -----------------------------------------------------------------------
    t.describe('a long lossy stream ends where the host is')

    entities = scene(6, 18)
    baseline = Rep.newBaseline()
    state = newState()

    local rng = Worldgen.rng(20260730)
    local sent, arrived = 0, 0

    for step = 1, 400 do
        for i = 1, 6 do move(entities[i]) end
        if step % 17 == 0 then
            local hurt = entities[7 + (step % (#entities - 6))]
            if hurt and hurt:get('health') then
                hurt:get('health').hp = 30 - (step % 29)
            end
        end
        if step % 41 == 0 and #entities > 12 then
            table.remove(entities, #entities)
        end
        if step % 53 == 0 then
            entities[#entities + 1] = Entity.spawn('grunt', 5.5 + step * 0.01, 6.5)
        end

        local body2 = frame(entities, baseline)
        sent = sent + 1
        -- A third of the datagrams destroyed, which is heavier loss than the
        -- measured 20% run in docs/NETWORKING.md.
        if rng:float() >= 0.34 then
            arrived = arrived + 1
            deliver(state, body2)
        end
    end

    t.ok(sent - arrived > 100,
         ('%d of %d snapshots were destroyed in flight'):format(sent - arrived, sent))

    -- Then one clean keyframe interval, which is all the repair there is.
    local settledAt = nil
    for step = 1, Rep.KEYFRAME_INTERVAL do
        local body3, _, key = frame(entities, baseline)
        deliver(state, body3)
        if key and settledAt == nil then settledAt = step end
    end

    t.ok(settledAt ~= nil and settledAt <= Rep.KEYFRAME_INTERVAL,
         ('a keyframe came within %d frames'):format(Rep.KEYFRAME_INTERVAL))
    t.eq(disagreement(entities, state), nil,
         'and after a third of the stream was lost the client is exactly right')

    -----------------------------------------------------------------------
    t.describe('and none of it made the packet bigger')

    -- THE constraint. A snapshot past one MTU is delivered reliably, which is the
    -- bug meatray/net/snapcodec.lua exists to prevent, so the largest frame the
    -- stream can produce still has to fit inside one datagram.
    entities = scene(8, 24)
    baseline = Rep.newBaseline()

    local _, keyframeBytes = frame(entities, baseline, true)
    t.ok(#keyframeBytes < P.MTU_SAFE_BYTES,
         ('a 32-entity keyframe is %d bytes, under the %d-byte fragment threshold')
         :format(#keyframeBytes, P.MTU_SAFE_BYTES),
         ('%d bytes over'):format(#keyframeBytes - P.MTU_SAFE_BYTES))

    -- Idle. This is the case the whole phase is for.
    local _, idleBytes = frame(entities, baseline)
    t.ok(#idleBytes < #keyframeBytes * 0.05,
         ('an idle partial is %d bytes against a %d-byte full snapshot')
         :format(#idleBytes, #keyframeBytes))

    -- Everything moving, which must not be WORSE than a full snapshot. A partial
    -- carries a subset of the entities and a subset of each one's fields, so the
    -- only thing it can add is framing: one header flag byte and the removal
    -- count.
    frame(entities, baseline, true)
    for i = 1, #entities do move(entities[i]) end
    local _, allMovingBytes = frame(entities, baseline)
    t.ok(#allMovingBytes < #keyframeBytes,
         ('with all 32 entities moving a partial is %d bytes against %d for a full '
          .. 'snapshot, because nothing they carry beside the transform changed')
         :format(#allMovingBytes, #keyframeBytes))

    -- And the adversarial case: every declared field of every component changing
    -- every frame, so a partial has nothing at all it can leave out.
    frame(entities, baseline, true)
    for i = 1, #entities do
        move(entities[i])
        for name, component in pairs(entities[i].components) do
            local declared = Entity.netFieldsFor(name)
            for j = 1, #(declared or {}) do
                local key = declared[j]
                local value = component[key]
                if type(value) == 'number' then
                    component[key] = value + 1
                elseif type(value) == 'string' then
                    component[key] = value .. 'q'
                end
            end
        end
    end
    local _, churnBytes = frame(entities, baseline)
    local _, churnKeyframe = frame(entities, baseline, true)
    t.ok(#churnBytes <= #churnKeyframe + 8,
         ('with every declared field changing a partial is %d bytes against %d for '
          .. 'the equivalent keyframe, so the worst case costs framing and nothing '
          .. 'else'):format(#churnBytes, #churnKeyframe))

    -----------------------------------------------------------------------
    t.describe('the fallback backends encode a partial identically')

    -- LOVE 11.4 ships a LuaJIT with no string.buffer, so this is a build players
    -- run. A partial has to come out byte for byte the same there or those
    -- players are talking to a different game.
    entities = scene(3, 5)
    baseline = Rep.newBaseline()
    frame(entities, baseline, true)
    move(entities[1])
    entities[2]:get('health').hp = 12

    local wasBackend, wasFloats = Codec.backend, Codec.floats
    local list, removed, isKeyframe = Rep.snapshotFrame(entities, baseline, false)
    local partialBody = {
        tick = 7, e = list, full = isKeyframe, r = removed,
        k = baseline.keyframes,
    }

    Codec.useBackend('buffer', 'ffi')
    local fast = P.packSnapshot(partialBody)
    Codec.useBackend('table', 'lua')
    local slow = P.packSnapshot(partialBody)
    Codec.useBackend(wasBackend, wasFloats)

    t.eq(slow, fast, 'a partial encodes identically with no string.buffer and no ffi')
    local crossKind, crossBody = P.unpack(fast)
    t.eq(crossKind, P.SNAPSHOT, 'and still decodes')
    t.eq(crossBody and crossBody.full, false, 'as a partial')

    -----------------------------------------------------------------------
    t.describe('a real host and a real client, over a lossy transport')

    Loopback.reset()
    defineArchetypes()
    Entity.resetIds(1)

    local world = Worldgen.box(24, 24)
    local extras = {}
    for i = 1, 12 do
        extras[i] = Entity.spawn('grunt', 4.5 + i * 0.7, 6.5 + i * 0.3)
    end

    local host, hostErr = Net.Host.new{
        mode = 'listen', transport = 'loopback', port = 8711,
        world = world, entities = extras,
        onLog = function() end,
    }
    t.ok(host ~= nil, 'a host comes up', hostErr)
    t.eq(host.keyframeInterval, Rep.KEYFRAME_INTERVAL,
         'with dirty-flag snapshots on by default')
    t.ok(host.snapBaseline ~= nil, 'and one baseline, shared by every peer')
    local sharedBaseline = host.snapBaseline

    local client, clientErr = Net.Client.new{
        address = 'loopback:8711', transport = 'loopback', name = 'lossy',
        onLog = function() end,
    }
    t.ok(client ~= nil, 'a client connects', clientErr)

    local function pump(seconds)
        for _ = 1, math.ceil((seconds or 0.1) / (1 / 60)) do
            host:update(1 / 60)
            client:update(1 / 60)
        end
    end

    pump(0.3)
    t.eq(client.state, 'joined', 'and joins')

    -- Half the unreliable datagrams reaching the client are destroyed. The
    -- reliable channel is untouched, exactly as a real network behaves.
    client.transport.loss = 0.5
    client.transport.rng = Worldgen.rng(4242)

    local mover = host.entities[1]
    for _ = 1, 40 do
        mover.x = mover.x + 0.05
        pump(0.05)
    end

    t.ok(client.partials > 0, ('the client applied %d partials'):format(client.partials))
    t.ok(client.keyframes > 0, ('and %d keyframes'):format(client.keyframes))
    t.ok((client.transport.dropped or 0) > 10,
         ('with %d datagrams destroyed on the way'):format(client.transport.dropped or 0))

    client.transport.loss = 0
    pump(1.0)                                    -- more than one keyframe interval

    local mismatch = disagreement(host.entities, client)
    t.eq(mismatch, nil, 'and the client ends up exactly where the host is', mismatch)

    -- A second client joining part-way through a keyframe interval. It is sent a
    -- keyframe of its own, which deliberately does NOT disturb the shared
    -- baseline — nobody else received it — so the next partial it sees is a diff
    -- against an OLDER keyframe than the frame it is holding. That has to be
    -- harmless, because a partial carries absolute values rather than deltas.
    local late, lateErr = Net.Client.new{
        address = 'loopback:8711', transport = 'loopback', name = 'latecomer',
        onLog = function() end,
    }
    t.ok(late ~= nil, 'a second client joins mid-interval', lateErr)

    local function pumpBoth(seconds)
        for _ = 1, math.ceil((seconds or 0.1) / (1 / 60)) do
            host:update(1 / 60)
            client:update(1 / 60)
            late:update(1 / 60)
        end
    end

    pumpBoth(0.3)
    t.eq(late.state, 'joined', 'and completes the handshake')

    -- One frame short of a keyframe, so what it is judged on is partials landing
    -- on a baseline it never saw.
    for _ = 1, 6 do
        mover.x = mover.x + 0.05
        pumpBoth(0.03)
    end

    t.ok(late.partials > 0, ('the latecomer applied %d partials'):format(late.partials))
    local lateMismatch = disagreement(host.entities, late)
    t.eq(lateMismatch, nil,
         'and a partial against an older baseline still leaves it exactly right',
         lateMismatch)
    t.eq(host.peerCount, 2, 'the host is serving two peers')
    t.eq(host.snapBaseline, sharedBaseline,
         'from the same single baseline object it started with, never one per peer')

    -- A despawn survives the same treatment, and it is the case a "send only
    -- changes" stream is most likely to get wrong: nothing changed about the
    -- entity, it simply stopped existing.
    local victim = host.entities[#host.entities]
    victim.dead = true
    client.transport.loss = 0.5
    pump(0.6)
    client.transport.loss = 0
    pump(1.0)

    t.eq(client.byId[victim.id], nil, 'a despawn reaches a client through heavy loss')
    t.eq(disagreement(host.entities, client), nil, 'leaving both sides agreeing')

    -----------------------------------------------------------------------
    t.describe('and it can be switched off')

    Loopback.reset()
    local plainHost = Net.Host.new{
        mode = 'listen', transport = 'loopback', port = 8712,
        world = Worldgen.box(16, 16), entities = {},
        keyframeInterval = 1,
        onLog = function() end,
    }
    t.ok(plainHost ~= nil, 'keyframeInterval = 1 builds a host')
    t.eq(plainHost.snapBaseline, nil,
         'with no baseline at all, so the stream is what it was before this existed')

    for _ = 1, 20 do plainHost:update(1 / 60) end
    t.ok(plainHost.keyframesSent > 0, 'and every frame it sends is a keyframe')
    t.eq(plainHost.snapshotPartialBytes, 0, 'because it never sends a partial')

    Loopback.reset()
    Entity.clearArchetypes()
end
