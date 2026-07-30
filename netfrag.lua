--[[
    `love . --netfrag --connect host:port [--fillers N] [--seconds S]`

    The snapshot stream, measured on a real socket rather than reasoned about.

    meatray/net/snapcodec.lua exists to keep a snapshot inside one datagram,
    because ENet decides how to deliver a *fragmented* packet by testing

        (flags & (RELIABLE | UNRELIABLE_FRAGMENT)) == UNRELIABLE_FRAGMENT

    and our unreliable send passes flags 0, for which that test is false — so a
    snapshot one byte over the MTU stops being unreliable and becomes reliable,
    acknowledged, retransmitted and head-of-line blocked. The loopback transport
    cannot show that, because it never fragments; the in-process ENet check in
    netcheck.lua cannot show it either, because a snapshot has to be *lost* before
    the difference between "skipped" and "retransmitted" is visible at all.

    So: three operating-system processes, real UDP, and a relay in the middle that
    throws datagrams away (netproxy.lua). This is the client. It joins, watches
    every snapshot arrive, and asks four questions.

      1  SIZE       is a snapshot at a realistic entity count under
                    P.MTU_SAFE_BYTES? Asked twice, of the host's own accounting
                    (`snapshotBytes` in a stats reply) and of the bytes that
                    actually landed here.

      2  DELIVERY   under induced downstream loss, what fraction of the snapshots
                    the host says it sent arrived? An unreliable stream loses
                    them: received/sent tracks (1 - loss), and the tick numbers
                    show gaps where the missing ones were. A reliable stream does
                    not lose them: received/sent goes to 1.0 and the gaps close,
                    because ENet retransmitted every one.

      3  CHARACTER  are they on time? A retransmitted snapshot arrives late and
                    drags whatever was queued behind it, so reliable delivery
                    shows up as bursts — several snapshots handed over in a single
                    service drain after a stall — and a long tail on the
                    inter-arrival time. Unreliable delivery has neither: a lost
                    snapshot costs one interval and nothing else.

      4  FIDELITY   the codec quantises x, y and angle to binary32 and nothing
                    else. The filler entities carry known positions and an hp of
                    2^24 + i, which binary32 *cannot* represent, so "hp is exact"
                    is a claim with teeth rather than a small integer that would
                    survive any encoding.

    The measurement is deliberately not "did it fragment", which cannot be seen
    from here — ENet reassembles before lua-enet is involved, so a fragmented
    packet arrives looking whole. Two things do give it away and both are
    reported: a received packet larger than the MTU cannot have crossed in one
    datagram, and the relay counts the datagrams directly.

    Every wait has a printed budget and reports what it actually spent. An earlier
    probe in this repo was called a failure because it waited 800 ticks for
    something that needed longer, and four firewall rules were written to fix a
    problem that did not exist.
]]

local MeatRay = require('meatray')

local NetFrag = {}

-- Two to the twenty-fourth. binary32 has 24 significant bits, so it represents
-- every integer up to here and then starts skipping every other one: 2^24 + 1 is
-- the smallest integer it cannot hold. Filler hp is built from it for exactly
-- that reason.
NetFrag.HP_BASE = 16777216

-- The relative bound on a binary32 round trip: half an ulp is |v| * 2^-24.
NetFrag.F32_RELATIVE = 2 ^ -24

--[[
    One filler's transform and health, from its index alone.

    Written once and called from both processes — the host to place the entity,
    the client to work out where it should have been — so the two cannot drift
    apart. The divisors are 7 and 11 rather than powers of two on purpose: i/8
    is exact in binary32 and would make the fidelity check pass without measuring
    anything.
]]
function NetFrag.filler(i)
    local x  = 2 + (i % 37) + i / 7
    local y  = 2 + (i % 29) + i / 11
    local hp = NetFrag.HP_BASE + i
    return x, y, hp
end

-- The index is recovered from hp rather than from the entity id, because ids
-- depend on how many entities the map happened to contain and the client has no
-- business knowing that.
function NetFrag.indexOf(hp, count)
    if type(hp) ~= 'number' then return nil end
    local i = hp - NetFrag.HP_BASE
    if i ~= math.floor(i) or i < 1 or i > count then return nil end
    return i
end

--[[
    Adds `count` filler entities to a list the host is about to be given.

    Crystals rather than imps: a crystal carries billboard and health and no
    brain, which is both the cheapest entity that still replicates something
    interesting and the profile snapcodec.lua measured itself against. Nothing on
    the host moves them or touches their health, so the client's expectation is
    valid for the whole run.

    `max` is raised above hp because a rules pass that clamped health to its
    maximum would silently rewrite the value this test is built on.
]]
function NetFrag.spawnFillers(entities, count)
    local Entity = MeatRay.entity
    for i = 1, count do
        local x, y, hp = NetFrag.filler(i)
        local e = Entity.spawn('crystal', x, y)
        local health = e:get('health')
        health.hp  = hp
        health.max = NetFrag.HP_BASE * 2
        entities[#entities + 1] = e
    end
    return count
end

---------------------------------------------------------------------------

local function percentile(sorted, q)
    if #sorted == 0 then return 0 end
    local idx = math.floor(q * (#sorted - 1)) + 1
    return sorted[idx]
end

function NetFrag.run(args)
    local Net = MeatRay.net
    local P   = Net.protocol

    local address    = (args and args.connect) or '127.0.0.1:6800'
    local label      = (args and args.label) or 'netfrag'
    local seconds    = tonumber(args and args.seconds) or 30
    local fillers    = tonumber(args and args.fillers) or 0
    -- 'under' or 'over', spelled out by the caller rather than guessed from the
    -- filler count. What a given number of fillers costs depends on the map, the
    -- archetypes and every component that declares netFields, so a probe that
    -- inferred the intent from the count would quietly assert the wrong thing the
    -- first time any of those changed — which is exactly what it did once.
    local expect     = (args and args.expect) or 'under'
    local joinBudget = tonumber(args and args.joinBudget) or 30
    local warmup     = tonumber(args and args.warmup) or 3

    local passed, failed, notes = 0, 0, {}
    local function ok(condition, text, detail)
        if condition then
            passed = passed + 1
            print(('  ok   %s'):format(text))
        else
            failed = failed + 1
            notes[#notes + 1] = text
            print(('  FAIL %s%s'):format(text, detail and ('  [' .. tostring(detail) .. ']') or ''))
        end
        return condition
    end
    local function say(text) print('  --   ' .. text) end

    print(('MeatRayCast netfrag [%s]: joining %s, expecting %d fillers')
          :format(label, address, fillers))
    print(('-'):rep(66))

    -----------------------------------------------------------------------
    -- Instrumentation. Installed on the instance, so nothing in meatray is
    -- edited to be observed and the code under test is the shipped code.
    local arrivals = {}          -- { tick, bytes, at, pump }
    local pumpIndex = 0
    local pendingBytes, pendingAt

    local client, joinErr = Net.join(address, {
        name  = label,
        onLog = function(line) print('  net  ' .. line) end,
    })

    if not client then
        print('NETFRAG FAILED: could not start a client: ' .. tostring(joinErr))
        return love.event.quit(1)
    end

    do
        local transport = client.transport
        local realService = transport.service
        transport.service = function(self, ...)
            local event = realService(self, ...)
            if event and event.type == 'receive'
               and event.data and event.data:sub(1, 1) == P.SNAPSHOT then
                pendingBytes, pendingAt = #event.data, love.timer.getTime()
            end
            return event
        end

        local realSnapshot = client.handleSnapshot
        client.handleSnapshot = function(self, body)
            arrivals[#arrivals + 1] = {
                tick  = tonumber(body.tick) or -1,
                bytes = pendingBytes or 0,
                at    = pendingAt or love.timer.getTime(),
                pump  = pumpIndex,
            }
            return realSnapshot(self, body)
        end
    end

    -- Real elapsed time, not the nominal step: the host is another process and
    -- the numbers being collected are wall-clock numbers.
    local function pump(budget, predicate)
        local started = love.timer.getTime()
        while love.timer.getTime() - started < budget do
            local before = love.timer.getTime()
            love.timer.sleep(0.002)
            pumpIndex = pumpIndex + 1
            client:update(love.timer.getTime() - before)
            if predicate and predicate() then
                return true, love.timer.getTime() - started
            end
        end
        return predicate == nil, love.timer.getTime() - started
    end

    -----------------------------------------------------------------------
    print('handshake')
    local joined, joinSpent = pump(joinBudget, function() return client.state == 'joined' end)
    say(('waited %.2f s of a %g s budget'):format(joinSpent, joinBudget))
    if not ok(joined, 'joined over real UDP', client.reason or client.state) then
        print(('%d passed, %d failed'):format(passed, failed))
        print('NETFRAG FAILED')
        return love.event.quit(1)
    end

    local firstSnap, snapSpent = pump(10, function() return #arrivals > 0 end)
    say(('first snapshot after %.2f s of a 10 s budget'):format(snapSpent))
    if not ok(firstSnap, 'a snapshot arrived') then
        print('NETFRAG FAILED')
        return love.event.quit(1)
    end

    local function stats(budget)
        client.stats = nil
        client:requestStats()
        local got, spent = pump(budget or 10, function() return client.stats ~= nil end)
        return got and client.stats or nil, spent
    end

    local before, statSpent = stats(15)
    say(('stats reply after %.2f s of a 15 s budget'):format(statSpent))
    if not ok(before ~= nil, 'the host answered a stats request') then
        print('NETFRAG FAILED')
        return love.event.quit(1)
    end

    say(('host: %d entities, %d players, snapshot %d bytes, %d sent so far')
        :format(before.entities or -1, before.players or -1,
                before.snapshotBytes or -1, before.snapshotsSent or -1))

    -----------------------------------------------------------------------
    -- Settle before measuring. A join costs a world payload and a burst of
    -- spawns, and averaging those into a steady-state latency figure is how a
    -- measurement ends up describing the handshake.
    say(('warming up for %g s'):format(warmup))
    pump(warmup)

    local windowFrom = #arrivals + 1
    local sentAtStart = (stats(15) or {}).snapshotsSent
    local windowStart = love.timer.getTime()

    print(('measuring for %g s'):format(seconds))
    pump(seconds)

    local windowEnd = love.timer.getTime()
    local after = stats(15)
    local windowTo = #arrivals
    local elapsed = windowEnd - windowStart

    if not ok(after ~= nil and sentAtStart ~= nil, 'the host accounted for the window') then
        print('NETFRAG FAILED')
        return love.event.quit(1)
    end

    -----------------------------------------------------------------------
    print(('-'):rep(66))
    print('window')

    local sent = (after.snapshotsSent or 0) - sentAtStart
    local received = windowTo - windowFrom + 1
    if received < 0 then received = 0 end

    say(('%.2f s elapsed, host sent %d snapshots, %d arrived here')
        :format(elapsed, sent, received))
    say(('host snapshot size %d bytes, MTU_SAFE_BYTES %d, host fell back to text %s times')
        :format(after.snapshotBytes or -1, P.MTU_SAFE_BYTES,
                tostring(after.snapshotFallbacks or 'n/a')))

    local delivery = sent > 0 and (received / sent) or 0

    -----------------------------------------------------------------------
    -- Sizes, as they landed here. ENet reassembles fragments before lua-enet
    -- sees them, so this is the size of the logical packet: anything over the
    -- MTU necessarily crossed the wire as several datagrams.
    local minBytes, maxBytes, sumBytes = math.huge, 0, 0
    for i = windowFrom, windowTo do
        local b = arrivals[i].bytes
        if b < minBytes then minBytes = b end
        if b > maxBytes then maxBytes = b end
        sumBytes = sumBytes + b
    end
    if minBytes == math.huge then minBytes = 0 end

    -----------------------------------------------------------------------
    -- Ticks. The host runs at tickRate and snapshots at snapshotRate, so
    -- consecutive snapshots are a fixed number of ticks apart; anything larger is
    -- a snapshot that never arrived, and anything negative is one that arrived
    -- after a newer one.
    local step = math.floor((client.tickRate or 60) / (client.snapshotRate or 20) + 0.5)
    if step < 1 then step = 1 end

    local missing, outOfOrder, contiguous, gapMax = 0, 0, 0, 0
    local interArrival = {}
    local bursts, burstMax = 0, 0
    local perPump = {}

    for i = windowFrom + 1, windowTo do
        local prev, cur = arrivals[i - 1], arrivals[i]
        local deltaTicks = cur.tick - prev.tick
        if deltaTicks < 0 then
            outOfOrder = outOfOrder + 1
        elseif deltaTicks == step then
            contiguous = contiguous + 1
        else
            local lost = math.floor(deltaTicks / step) - 1
            if lost > 0 then missing = missing + lost end
            if deltaTicks > gapMax then gapMax = deltaTicks end
        end
        interArrival[#interArrival + 1] = (cur.at - prev.at) * 1000
    end

    for i = windowFrom, windowTo do
        local p = arrivals[i].pump
        perPump[p] = (perPump[p] or 0) + 1
    end
    for _, n in pairs(perPump) do
        if n >= 2 then bursts = bursts + 1 end
        if n > burstMax then burstMax = n end
    end

    table.sort(interArrival)
    local iaSum = 0
    for _, v in ipairs(interArrival) do iaSum = iaSum + v end
    local iaMean = #interArrival > 0 and (iaSum / #interArrival) or 0

    -----------------------------------------------------------------------
    print(('-'):rep(66))
    print('1. size')
    say(('host reported %d bytes, largest packet seen here %d bytes, smallest %d, mean %.0f')
        :format(after.snapshotBytes or -1, maxBytes, minBytes,
                received > 0 and (sumBytes / received) or 0))

    local fragmenting = (after.snapshotBytes or 0) > P.MTU_SAFE_BYTES
                        or maxBytes > P.MTU_SAFE_BYTES

    if expect == 'over' then
        -- The deliberate-overflow run. Being over the line is the point of it.
        ok(fragmenting,
           ('snapshots are over MTU_SAFE_BYTES and therefore fragmenting '
            .. '(%d bytes, at least %d datagrams)')
           :format(maxBytes, math.ceil(maxBytes / P.MTU_SAFE_BYTES)))
    else
        ok(not fragmenting,
           ('a %d-entity snapshot fits in one datagram (%d <= %d bytes, %d to spare)')
           :format(after.entities or -1, maxBytes, P.MTU_SAFE_BYTES,
                   P.MTU_SAFE_BYTES - maxBytes),
           ('%d bytes, %d over'):format(maxBytes, maxBytes - P.MTU_SAFE_BYTES))
    end

    print('2. delivery')
    say(('%d of %d arrived = %.1f%%'):format(received, sent, 100 * delivery))
    say(('%d snapshots never arrived (tick gaps), largest gap %d ticks = %.1f intervals')
        :format(missing, gapMax, step > 0 and (gapMax / step) or 0))
    say(('%d contiguous pairs, %d arrived out of order'):format(contiguous, outOfOrder))

    print('3. character')
    say(('inter-arrival ms: mean %.1f, p50 %.1f, p90 %.1f, p99 %.1f, max %.1f')
        :format(iaMean, percentile(interArrival, 0.50), percentile(interArrival, 0.90),
                percentile(interArrival, 0.99), percentile(interArrival, 1.0)))
    say(('%d service drains delivered more than one snapshot, most in one drain: %d')
        :format(bursts, burstMax))

    -----------------------------------------------------------------------
    print('4. fidelity')

    local seenFillers, worstAbs, worstRel, worstWho = 0, 0, 0, nil
    local hpExact, hpWrong = 0, 0
    local badHp

    if fillers > 0 then
        for _, e in ipairs(client.entities) do
            local health = e:get('health')
            local i = health and NetFrag.indexOf(health.hp, fillers)
            if i then
                seenFillers = seenFillers + 1
                local ex, ey, ehp = NetFrag.filler(i)

                if health.hp == ehp then hpExact = hpExact + 1
                else hpWrong = hpWrong + 1; badHp = badHp or ('%d vs %d'):format(health.hp, ehp) end

                local dx, dy = math.abs(e.x - ex), math.abs(e.y - ey)
                local relX = ex ~= 0 and dx / math.abs(ex) or dx
                local relY = ey ~= 0 and dy / math.abs(ey) or dy
                local rel = math.max(relX, relY)
                local abs = math.max(dx, dy)
                if abs > worstAbs then worstAbs = abs end
                if rel > worstRel then worstRel = rel; worstWho = i end
            end
        end

        ok(seenFillers == fillers,
           ('all %d filler entities replicated here'):format(fillers),
           ('saw %d'):format(seenFillers))

        if seenFillers > 0 then
            say(('worst position error %.3e tiles, %.3e relative (filler %s)')
                :format(worstAbs, worstRel, tostring(worstWho)))
            say(('the binary32 half-ulp bound is %.3e relative'):format(NetFrag.F32_RELATIVE))
            ok(worstRel <= NetFrag.F32_RELATIVE * 1.0000001,
               'every position is inside the documented binary32 bound',
               ('%.3e > %.3e'):format(worstRel, NetFrag.F32_RELATIVE))
            ok(worstAbs > 0,
               ('positions really were quantised (worst error %.3e tiles, not zero) '
                .. '- so the bound above was tested, not vacuous'):format(worstAbs))
            ok(hpWrong == 0,
               ('hp arrived exact on %d fillers, including values binary32 cannot '
                .. 'represent (2^24+i)'):format(hpExact), badHp)
        end
    else
        say('no fillers on this run, so positions have no ground truth to check')
    end

    local weapon = client.player and client.player:get('weapon')
    if weapon and weapon.ammo then
        local shots = 0
        local seenAmmo = { weapon.ammo }
        local fractional = (weapon.ammo ~= math.floor(weapon.ammo))
        for _ = 1, 3 do
            client:command('fire', { angle = client.player.angle or 0 })
            pump(0.6)
            local a = client.player and client.player:get('weapon')
            if a and a.ammo then
                seenAmmo[#seenAmmo + 1] = a.ammo
                if a.ammo ~= math.floor(a.ammo) then fractional = true end
                if a.ammo < seenAmmo[#seenAmmo - 1] then shots = shots + 1 end
            end
        end
        say('ammo as it arrived: ' .. table.concat(seenAmmo, ', '))
        ok(not fractional, 'ammo is an exact integer at every step, never quantised')
        ok(shots > 0, 'and it moved, so the values are the host\'s and not a stale first snapshot',
           'ammo never changed')
    else
        say('this client has no weapon, so ammo could not be checked')
    end

    -----------------------------------------------------------------------
    print(('-'):rep(66))
    print(('RESULT %s  sent=%d received=%d delivery=%.3f missing=%d ooo=%d '
           .. 'maxbytes=%d p99ms=%.1f bursts=%d')
          :format(label, sent, received, delivery, missing, outOfOrder, maxBytes,
                  percentile(interArrival, 0.99), bursts))
    print(('%d passed, %d failed'):format(passed, failed))
    if failed > 0 then
        print('NETFRAG FAILED: ' .. table.concat(notes, '; '))
        return love.event.quit(1)
    end
    print('NETFRAG PASSED')
    love.event.quit(0)
end

return NetFrag
