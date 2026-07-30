--[[
    `love . --nettest --connect host:port --role a|b`

    A headless client that joins a real server over real UDP and asserts across
    the wire. Two of these against one dedicated server is the test the loopback
    suite cannot be: three operating-system processes, three separate copies of
    the simulation, one authoritative.

    Roles, because the interesting assertions are about one client seeing what
    another client did:

      role a  acts. Waits until both players are present, opens a door, then
              moves clear of the other player and shoots it.
      role b  observes. Asserts that the door role a opened arrived here, that
              the hitscan role a fired was resolved by the host and reported
              here, and that its own health went down without ever having been
              guessed at locally.

    Both roles assert that the host agrees with them, by asking it: the STATS
    message returns the host's own player count and door state, so "both players
    exist on both sides" is checked against the host rather than inferred.

    Blocking loops are correct here. There is no window to keep responsive, the
    server is a separate process running in real time, and the process exists to
    answer one question and exit with a status.
]]

local MeatRay = require('meatray')

return function(args)
    local Net     = MeatRay.net
    local Collide = MeatRay.collide

    local role    = (args and args.role) or 'a'
    local address = (args and args.connect) or '127.0.0.1:6789'

    local passed, failed = 0, 0
    local problems = {}

    local function ok(condition, label, detail)
        if condition then
            passed = passed + 1
            print(('  ok   [%s] %s'):format(role, label))
        else
            failed = failed + 1
            local line = detail and ('%s  [%s]'):format(label, tostring(detail)) or label
            problems[#problems + 1] = line
            print(('  FAIL [%s] %s'):format(role, line))
        end
        return condition
    end

    local function finish()
        print(('-'):rep(58))
        print(('%d passed, %d failed  (role %s)'):format(passed, failed, role))
        if failed > 0 then
            error(('%d assertion(s) failed: %s'):format(failed, problems[1]), 0)
        end
        print('NETTEST PASSED')
    end

    print(('MeatRayCast nettest: role %s joining %s'):format(role, address))
    print(('-'):rep(58))

    -----------------------------------------------------------------------
    local events = {}

    local client, joinErr = Net.join(address, {
        name = 'nettest-' .. role,
        onEvent = function(_, name, body)
            events[#events + 1] = { name = name, body = body }
        end,
        onLog = function(line) print('  ' .. line) end,
    })

    if not ok(client ~= nil, 'connected to ' .. address, joinErr) then
        return finish()
    end

    -- Real time, because the server is a real process. dt is what actually
    -- elapsed rather than what was asked for, so prediction runs at the rate the
    -- machine managed.
    local function pump(seconds, predicate)
        local remaining = seconds
        while remaining > 0 do
            local step = 0.008
            love.timer.sleep(step)
            client:update(step)
            remaining = remaining - step
            if predicate and predicate() then return true end
        end
        return predicate == nil
    end

    -- The most recent match, not the first. If a retry lands two shots, the state
    -- the client now holds corresponds to the last one, and asserting against the
    -- first would fail for a reason that has nothing to do with replication.
    local function eventNamed(name, match)
        local found
        for _, e in ipairs(events) do
            if e.name == name and (not match or match(e.body)) then found = e end
        end
        return found
    end

    -----------------------------------------------------------------------
    print('handshake')
    ok(pump(10, function() return client.state == 'joined' end),
       'the handshake completed over UDP', client.reason or client.state)
    if client.state ~= 'joined' then return finish() end

    ok(client.world ~= nil, 'the client built the server world from the join payload')
    ok(client.world and client.world.width > 0,
       ('the world is %sx%s tiles'):format(tostring(client.world and client.world.width),
                                           tostring(client.world and client.world.height)))
    ok(client.entityId ~= nil, 'the host said which entity is ours')
    ok(client.player ~= nil, 'and the first snapshot contained it')
    ok(client.player and client.player:has('health'),
       'built from the local archetype, with its components')

    -- Baselines are taken now, at the moment of joining, and not later when the
    -- observing role gets around to looking. Taken later they are a race: the
    -- other client may already have acted, and "the value did not change" would be
    -- reported as a replication failure when it is really a test that started
    -- watching too late.
    local doorsAtJoin = {}
    for key, door in pairs(client.world.doors) do doorsAtJoin[key] = door.open end

    local health = client.player:get('health')
    local weapon = client.player:get('weapon')
    local hpAtJoin = health and health.hp
    local ammoAtJoin = weapon and weapon.ammo

    -----------------------------------------------------------------------
    print('both players exist on both sides')
    ok(pump(20, function() return client:playerCount() >= 2 end),
       'this client sees two players', ('saw %d'):format(client:playerCount()))

    client:requestStats()
    ok(pump(5, function() return client.stats ~= nil end), 'the host answered a stats request')
    if client.stats then
        ok(client.stats.players >= 2,
           ('the host also reports %d players'):format(client.stats.players))
        ok(client.stats.mode == 'dedicated' or client.stats.mode == 'listen',
           ('the host is running in %s mode%s'):format(
               tostring(client.stats.mode),
               client.stats.mode == 'dedicated' and ' - no window, no GL context' or ''))
    end

    local other
    for _, e in ipairs(client.entities) do
        if e:has('player') and e.id ~= client.entityId then other = e end
    end
    ok(other ~= nil, 'the other player replicated here as an entity')

    -----------------------------------------------------------------------
    if role == 'a' then
        print('opening a door')

        -- Deterministic choice, so both processes and repeat runs agree.
        local keys = {}
        for key, open in pairs(doorsAtJoin) do
            if not open then keys[#keys + 1] = key end
        end
        table.sort(keys)

        local tx, ty
        if keys[1] then tx, ty = Net.replication.parseDoorKey(keys[1]) end
        ok(tx ~= nil, ('found a shut door to open (%s)'):format(tostring(keys[1])))

        if tx then
            client:command('door', { tx = tx, ty = ty })
            local opened = pump(6, function()
                local door = client.world:doorAt(tx, ty)
                return door and door.open
            end)
            ok(opened, ('the door at %d,%d opened on the host and came back'):format(tx, ty))
            ok(not client.world:isSolid(tx, ty), 'and the client agrees it no longer blocks')
        end

        -----------------------------------------------------------------
        print('firing a shot the host resolves')

        -- Both players spawn on the same tile, and a hitscan needs its target in
        -- front of it, so move clear first. This also exercises input -> host
        -- movement -> position replication in one go.
        --
        -- Deliberately not far. The client aims from its predicted position at an
        -- interpolated remote position while the host resolves from two
        -- authoritative ones, so a few centimetres of disagreement is normal and
        -- expected — and at range that turns into an angular error big enough to
        -- miss a 0.24-tile target. Staying close keeps the angular tolerance wide,
        -- which makes this a test of replication rather than a test of luck.
        local startX, startY = client.player.x, client.player.y
        client:setInput{ forward = 1, angle = 0 }
        pump(0.45)
        client:setInput{ forward = 0, angle = 0 }
        pump(0.3)

        local moved = math.sqrt((client.player.x - startX) ^ 2
                                + (client.player.y - startY) ^ 2)
        ok(moved > 0.3, ('input moved the player %.2f tiles'):format(moved))

        local function hitOnOther(body)
            return body and body.result == 'hit' and other and body.target == other.id
        end

        local hit
        for _ = 1, 5 do
            local target = other and client.byId[other.id]
            if not target then break end

            -- Aim, then settle. The aim has to reach the host and a snapshot has to
            -- come back before the shot is worth taking; firing on the same frame
            -- as aiming means firing at where the target was an interval ago.
            local aim = math.atan2(target.y - client.player.y, target.x - client.player.x)
            client:setInput{ forward = 0, strafe = 0, angle = aim }
            pump(0.35)

            -- Re-aim from the settled positions, then fire.
            aim = math.atan2(target.y - client.player.y, target.x - client.player.x)
            client:command('fire', { angle = aim })

            pump(2.5, function()
                hit = eventNamed('hitscan', hitOnOther)
                return hit ~= nil
            end)
            if hit then break end

            -- Missed: close the distance rather than sidestepping. A nearer target
            -- subtends a wider angle, so each retry has more tolerance than the
            -- last instead of less.
            client:setInput{ forward = 1, strafe = 0, angle = aim }
            pump(0.15)
            client:setInput{ forward = 0, strafe = 0, angle = aim }
        end

        -- On failure, say what the host actually reported and where both players
        -- were. "The shot missed" is not a finding; "the host resolved it against a
        -- wall from x=4.88 while the target was at x=3.50" is one.
        local detail
        if not hit then
            local last = eventNamed('hitscan')
            local target = other and client.byId[other.id]
            detail = ('last hitscan reported: %s; shooter here at %.3f,%.3f; '
                      .. 'target here at %s,%s; %d hitscan event(s) seen')
                :format(last and tostring(last.body.result) or 'none',
                        client.player.x, client.player.y,
                        target and ('%.3f'):format(target.x) or '?',
                        target and ('%.3f'):format(target.y) or '?',
                        #events)
        end
        ok(hit ~= nil, 'the host resolved a hitscan and reported it back', detail)
        if hit then
            ok(hit.body.target == (other and other.id),
               'and it hit the other player, by entity id')
            ok((hit.body.damage or 0) > 0, ('for %d damage'):format(hit.body.damage or 0))
        end

        -- Ammo is authoritative: the client never decremented it locally, so it can
        -- only come down once a snapshot says so — which is a round trip after the
        -- event, hence the wait.
        ok(pump(3, function() return weapon and weapon.ammo < ammoAtJoin end),
           ('ammo came down from %s to %s, on the host\'s authority')
           :format(tostring(ammoAtJoin), tostring(weapon and weapon.ammo)))

    -----------------------------------------------------------------------
    else
        print('observing what the other client did')

        -- Waiting for the *event* rather than polling for the state change. An
        -- event is a reliable message and cannot be missed by a peer that is
        -- joined; polling for a state change can only ever see the difference
        -- between two moments, and the interesting moment may already have passed.
        local doorEvent
        local sawDoor = pump(25, function()
            doorEvent = eventNamed('door')
            return doorEvent ~= nil
        end)
        ok(sawDoor, 'the host reported a door another client opened',
           'no door event arrived')

        if doorEvent then
            local tx, ty = doorEvent.body.tx, doorEvent.body.ty
            ok(doorEvent.body.by ~= client.peerId,
               ('and it was peer %s, not us'):format(tostring(doorEvent.body.by)))
            ok(pump(3, function()
                   local door = client.world:doorAt(tx, ty)
                   return door and door.open
               end), ('the door state at %d,%d replicated here'):format(tx, ty))
            ok(not client.world:isSolid(tx, ty),
               ('and the door at %d,%d is walkable here too'):format(tx, ty))
            ok(doorsAtJoin[('%d,%d'):format(tx, ty)] == false,
               'and it was shut when we joined, so it really changed')
            ok(pump(1.5, function()
                   return client.world:doorAt(tx, ty).openness > 0.9
               end), 'and the client animated it open by itself, unprompted')
        end

        local shot
        local sawShot = pump(25, function()
            shot = eventNamed('hitscan', function(body)
                return body and body.target == client.entityId
            end)
            return shot ~= nil
        end)
        ok(sawShot, 'a hitscan the host resolved against this player reached us')

        if shot then
            ok((shot.body.damage or 0) > 0,
               ('the host reported %d damage'):format(shot.body.damage or 0))

            -- The important part: the number came from the host. There is no code
            -- on the client that lowers a health value, so a correct number here is
            -- proof it was replicated and not predicted.
            ok(pump(3, function() return health.hp < hpAtJoin end),
               ('health fell from %s to %s, authoritatively')
               :format(tostring(hpAtJoin), tostring(health and health.hp)))
            ok(health.hp == shot.body.hp,
               ('and matches the value the host reported (%s)'):format(tostring(shot.body.hp)))
            ok(hpAtJoin - health.hp == shot.body.damage,
               ('by exactly the damage the host applied (%s)'):format(tostring(shot.body.damage)))
        end
    end

    -----------------------------------------------------------------------
    print('teardown')
    ok(client.state == 'joined', 'still connected at the end of the run')
    ok(client.snapshots > 0, ('received %d snapshots'):format(client.snapshots))

    -- Cleared first: the field is already set from the earlier request, so a
    -- predicate of "stats is not nil" would be satisfied by the stale answer and
    -- the numbers printed would be from four seconds ago.
    client.stats = nil
    client:requestStats()
    ok(pump(3, function() return client.stats ~= nil end), 'the host answered again')
    if client.stats then
        ok(client.stats.snapshotsSent > 0,
           ('the host has sent %d snapshots and synced the world %d time(s)')
           :format(client.stats.snapshotsSent, client.stats.worldSyncs or -1))
        ok((client.stats.worldSyncs or 0) > 0,
           'and it replicated at least one world mutation')
    end

    client:leave()
    pump(0.3)

    return finish()
end
