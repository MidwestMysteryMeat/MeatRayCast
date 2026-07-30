--[[
    Hardening: liveness, flood control, input rate, and validation.

    Every case here is a bug that was found in a shipped project rather than
    imagined, and each is written so that reintroducing it fails a test rather
    than being noticed by a player.

      * **Liveness.** Two codebases could sit in `state == 'connected'` forever on
        a half-open connection, because both declared a ping interval and neither
        ever read the field. A third documented `timeout = 8 -- seconds before a
        silent peer is dropped` next to code that dropped nobody. So the tests
        below assert the *setting is applied*, not merely that it exists: a knob
        that is not honoured is worse than no knob, because it documents
        behaviour the server does not have.

      * **Flood control, in two tiers.** A penalising limiter pointed at an input
        stream bans your own players — twenty-five packets a second is not abuse,
        it is the client working, and a player whose packets bunch after a stall
        looks exactly like an attacker to a sliding window. So inputs go through
        a silent throttle that can never mute or ban, semantic commands go
        through a penalising window with escalating backoff, and the test that
        matters most is the one asserting a hundred thousand inputs cost nobody a
        strike.

      * **Input bounded per tick.** One server applied input on arrival and
        always integrated by a constant tick duration, so a client sending at
        four times the cadence moved at four times the speed — server
        authoritatively, with its own prediction agreeing, so nothing
        rubber-banded to give it away. MeatRayCast latches instead of applying,
        which is the correct shape; these tests pin it down, because "it happens
        to be written the safe way" is one refactor from not being true.

      * **Validation before assignment.** Another server assigned `p.yaw` before
        the line that rejected it, so a single `1e999` rode in that player's
        snapshot to everyone, forever. And it wrapped `JSON.parse` and the
        handler in one try block whose catch told the player "malformed message"
        and logged nothing — so a server exception was reported as a protocol
        error, on the wrong machine. Parse failure and handler failure are kept
        strictly apart here, and that separation is asserted.
]]

return function(t)
    local Entity   = require('meatray.sim.entity')
    local C        = require('meatray.sim.components')
    local Worldgen = require('meatray.sim.worldgen')
    local Net      = require('meatray.net')
    local Access   = require('meatray.net.access')
    local Rep      = require('meatray.net.replication')
    local P        = require('meatray.net.protocol')
    local Loopback = require('meatray.net.transport.loopback')

    -----------------------------------------------------------------------
    -- Fixtures
    -----------------------------------------------------------------------

    local function defineArchetypes()
        Entity.clearArchetypes()
        Entity.archetype('player', function(e)
            e:add(C.Player{ peerId = 0, name = '?' })
            e:add(C.Health{ hp = 100, max = 100 })
            e:add(C.Input{})
            e.radius = 0.24
        end)
    end

    local port = 8500
    local function freshPort()
        port = port + 1
        return port
    end

    local function makeHost(opts)
        opts = opts or {}
        local logged = {}
        local host, err = Net.Host.new{
            mode        = 'listen',
            transport   = 'loopback',
            port        = opts.port,
            world       = opts.world or Worldgen.box(24, 24),
            localPlayer = false,
            snapshotRate = opts.snapshotRate or 20,
            tickRate    = opts.tickRate or 60,
            peerTimeout = opts.peerTimeout,
            inputInterval = opts.inputInterval,
            flood       = opts.flood,
            floodBan    = opts.floodBan,
            onFlood     = opts.onFlood,
            onCommand   = opts.onCommand,
            onChat      = opts.onChat,
            onLog       = function(line) logged[#logged + 1] = line end,
        }
        return host, err, logged
    end

    local function makeClient(opts)
        opts = opts or {}
        return Net.Client.new{
            address    = 'loopback:' .. opts.port,
            transport  = 'loopback',
            name       = opts.name or 'tester',
            prediction = opts.prediction,
            timeout    = opts.timeout,
            timeoutMin = opts.timeoutMin,
            onTimeout  = opts.onTimeout,
            onLog      = function() end,
        }
    end

    local function pump(host, client, seconds, step)
        step = step or 1 / 60
        for _ = 1, math.ceil((seconds or 0.1) / step) do
            if host then host:update(step) end
            if client and client.transport then client:update(step) end
        end
    end

    -- The host alone.
    --
    -- Needed by every case that injects raw input, because a running client sends
    -- its own inputs at its own rate — with `forward = 0`, and with sequence
    -- numbers of its own — and those would overwrite an injected latch and make
    -- an injected sequence look stale. That is real behaviour and not a test
    -- artefact; it just makes the client a second author of the thing under test.
    local function pumpHost(host, seconds, step)
        step = step or 1 / 60
        for _ = 1, math.ceil((seconds or 0.1) / step) do host:update(step) end
    end

    -- The one peer a single-client host has.
    local function onlyPeer(host)
        for _, peer in pairs(host.peers) do return peer end
        return nil
    end

    -- Straight onto the wire, bypassing the client's own send helpers. This is
    -- what a hostile or broken peer can do, and it is the only way to test what
    -- the host does with a message its own client would never construct.
    local function raw(client, kind, body, channel, reliable)
        client.transport:send(client.peer, P.pack(kind, body),
                              channel or P.CH_RELIABLE, reliable ~= false)
    end

    local function joinedPair(opts)
        opts = opts or {}
        Loopback.reset()
        defineArchetypes()
        Entity.resetIds(1)

        opts.port = freshPort()
        local host, err, logged = makeHost(opts)
        if not host then return nil, nil, err end

        local client = makeClient(opts)
        pump(host, client, 0.4)
        return host, client, logged
    end

    -----------------------------------------------------------------------
    -- TASK 2 — liveness
    -----------------------------------------------------------------------

    t.describe('the transport is actually told to give up on a silent peer')

    local host, client, logged = joinedPair{ timeout = 12, timeoutMin = 3000 }
    t.ok(client and client:joined(), 'a client joins over loopback')

    -- The loopback transport records what it was told rather than enforcing it —
    -- there is no packet loss on a table — which is exactly what makes "the
    -- setting was applied" assertable with no sockets. This is the assertion the
    -- projects this came from could not have written, because the call was never
    -- made in the first place.
    local applied = client.peer.timeout
    t.ok(applied ~= nil, 'the client set a timeout on its peer')
    if applied then
        t.eq(applied.maximum, 12000, 'and it is the timeout the caller asked for, in ms')
        t.eq(applied.minimum, 3000, 'with the minimum the caller asked for')
        t.eq(applied.limit, 32, 'and the default retransmission limit')
    end

    local hostSide = onlyPeer(host)
    t.ok(hostSide and hostSide.handle.timeout ~= nil,
         'and the host set one on its side of the connection too')
    if hostSide and hostSide.handle.timeout then
        t.eq(hostSide.handle.timeout.maximum, host.peerTimeout * 1000,
             'derived from the host peer timeout, so one option drives both')
    end

    t.describe('a timeout under the default minimum does not invert the two')
    Loopback.reset(); defineArchetypes(); Entity.resetIds(1)
    local p = freshPort()
    local shortHost = makeHost{ port = p }
    local shortClient = makeClient{ port = p, timeout = 2 }
    t.ok(shortClient.timeoutMin <= shortClient.timeoutMax,
         'the minimum is clamped below the maximum rather than passed through')
    t.eq(shortClient.timeoutMax, 2000, 'and the maximum honours the request')
    shortClient:close('done'); shortHost:close()

    -----------------------------------------------------------------------
    t.describe('a joined client that stops being answered says so and stops')

    local timedOut
    host, client = joinedPair{ timeout = 3, onTimeout = function(_, why) timedOut = why end }
    t.ok(client:joined(), 'joined')

    -- Nothing wrong with the socket; the host simply stops existing as far as
    -- this client is concerned. No disconnect event will ever arrive.
    pump(nil, client, 2.0)
    t.eq(client.state, 'joined', 'two seconds of silence is not yet a fault')
    t.ok(client:silentFor() > 1.9, 'but the client knows how long it has been')

    pump(nil, client, 1.5)
    t.eq(client.state, 'disconnected',
         'past the configured timeout the client gives up rather than sitting on joined')
    t.ok(client.reason and client.reason:find('stopped responding'),
         'and says why, in words a player can act on', client.reason)
    t.ok(timedOut ~= nil, 'the onTimeout hook fired')
    host:close()

    t.describe('and a healthy session is never dropped by the watchdog')
    host, client = joinedPair{ timeout = 2 }
    pump(host, client, 6.0)
    t.eq(client.state, 'joined',
         'six seconds of a two-second timeout, with traffic flowing, is fine')
    t.eq(host.stats.timedOut, 0, 'and the host dropped nobody')
    client:close('done'); host:close()

    -----------------------------------------------------------------------
    t.describe('a host drops a peer that goes quiet')

    host, client, logged = joinedPair{ peerTimeout = 2 }
    t.eq(host:playerCount(), 1, 'one player is on the host')

    -- The client stops updating: no inputs, no pings, nothing. Its socket is
    -- still open, so ENet would not necessarily call this a fault either.
    pump(host, nil, 3.0)
    t.eq(host.stats.timedOut, 1, 'the host noticed and dropped it')
    t.eq(host:playerCount(), 0, 'and the player is gone rather than a ghost')

    local saidSo = false
    for _, line in ipairs(logged) do
        if line:find('stopped responding') then saidSo = true end
    end
    t.ok(saidSo, 'and the host log says which peer and why')
    client:close('done'); host:close()

    t.describe('the peer timeout is a real setting, not a documented one')
    host, client = joinedPair{ peerTimeout = 8 }
    t.eq(host.peerTimeout, 8, 'the host stored what it was given')
    pump(host, nil, 5.0)
    t.eq(host.stats.timedOut, 0, 'five seconds of an eight-second timeout drops nobody')
    pump(host, nil, 4.0)
    t.eq(host.stats.timedOut, 1, 'and nine seconds does')
    client:close('done'); host:close()

    -----------------------------------------------------------------------
    -- TASK 3 — two-tier flood control, as units
    -----------------------------------------------------------------------

    t.describe('tier one: the silent throttle')

    local throttle = Access.throttle{ interval = 0.05 }
    t.ok(throttle:allow('a', 0), 'the first message is allowed')
    t.ok(not throttle:allow('a', 0.01), 'a message inside the interval is dropped')
    t.ok(not throttle:allow('a', 0.049), 'and so is one just inside it')
    t.ok(throttle:allow('a', 0.05), 'one at the interval is allowed')
    t.ok(throttle:allow('b', 0.051), 'a different key has its own budget')
    t.eq(throttle.skipped, 2, 'the drops are counted')
    t.eq(throttle.passed, 3, 'and so are the passes')

    -- The property that makes it the right tier for an input stream: there is
    -- nothing to escalate, nothing to remember, and no state a caller could
    -- consult to justify a punishment.
    local skippedBefore = throttle.skipped
    for _ = 1, 10000 do throttle:allow('flooder', 0.06) end
    t.eq(throttle.skipped - skippedBefore, 9999,
         'ten thousand messages in one instant cost one pass and 9999 silent drops')
    t.eq(throttle.violations, nil,
         'and the throttle has no concept of a violation to record, by construction')
    t.eq(throttle.check, nil, 'nor any way for a caller to ask it for a punishment')

    -----------------------------------------------------------------------
    t.describe('tier two: the penalising window')

    local window = Access.window{ limit = 3, per = 10, penalty = 4, escalate = 2,
                                  maxPenalty = 20, banAfter = 3 }

    -- Sends `n` messages at one instant and returns what the last one was told,
    -- which for n > limit is the refusal that carries the strike.
    local function burst(w, key, at, n)
        local a, b, c, d, e
        for _ = 1, n do a, b, c, d, e = w:check(key, at) end
        return a, b, c, d, e
    end

    t.ok(window:check('a', 0), 'first of three')
    t.ok(window:check('a', 0.1), 'second')
    t.ok(window:check('a', 0.2), 'third')

    local ok, reason, retryAfter, violations, wantsBan = window:check('a', 0.3)
    t.ok(not ok, 'the fourth inside the window is refused')
    t.eq(reason, 'rate limited', 'with a stable reason a client can be shown')
    t.eq(retryAfter, 4, 'the first backoff is the base penalty')
    t.eq(violations, 1, 'and it counts as one strike')
    t.ok(not wantsBan, 'one strike does not ask for a ban')

    t.describe('a muted sender is told how long is left, and earns no further strikes')
    ok, _, retryAfter, violations = window:check('a', 1)
    t.ok(not ok, 'still muted a second in')
    t.near(retryAfter, 3.3, 1e-9, 'the refusal reports the time remaining')
    t.eq(violations, 1, 'and hammering while muted does not compound the strike')

    t.describe('backoff escalates, and is capped')
    -- Each burst happens after the previous mute has expired, so each one is a
    -- fresh decision to flood rather than the tail of the last.
    _, _, retryAfter, violations = burst(window, 'a', 10, 4)
    t.eq(violations, 2, 'the second strike is recorded')
    t.eq(retryAfter, 8, 'and the backoff has doubled')

    _, _, retryAfter, violations, wantsBan = burst(window, 'a', 30, 4)
    t.eq(violations, 3, 'a third strike')
    t.eq(retryAfter, 16, 'a longer backoff')
    t.ok(wantsBan, 'and at banAfter it says a ban would be justified')

    _, _, retryAfter = burst(window, 'a', 80, 4)
    t.eq(retryAfter, 20, 'the backoff is capped rather than growing without bound')
    _, _, retryAfter = burst(window, 'a', 200, 4)
    t.eq(retryAfter, 20, 'and stays capped however long it goes on')

    t.describe('the window forgets when the traffic stops')
    local calm = Access.window{ limit = 2, per = 1 }
    t.ok(calm:check('b', 0), 'one')
    t.ok(calm:check('b', 0.1), 'two')
    t.ok(not calm:check('b', 0.2), 'three inside the window is refused')
    t.ok(calm:check('b', 60), 'but a message a minute later is fine')

    t.describe('skipViolation refuses without a strike')
    local hatch = Access.window{ limit = 1, per = 10, banAfter = 1 }
    hatch:check('c', 0)
    local hok, _, _, hviolations, hban = hatch:check('c', 0.1, true)
    t.ok(not hok, 'the message is still refused')
    t.eq(hviolations, 0, 'but nothing is recorded against the sender')
    t.ok(not hban, 'and no ban is ever suggested')
    t.eq(hatch:mutedFor('c', 0.2), 0, 'and the sender is not muted')

    t.describe('banAfter defaults to never')
    local polite = Access.window{ limit = 1, per = 10, penalty = 1 }
    local pv, pban
    for i = 1, 6 do
        -- Spaced well past the longest backoff, so each burst is a fresh strike
        -- rather than the tail of the previous mute.
        local _, _, _, v, b = burst(polite, 'd', i * 100, 3)
        pv, pban = v, b
    end
    t.eq(pv, 6, 'strikes still accumulate')
    t.ok(not pban, 'but an engine does not ban on its own; that is the game\'s call')
    t.eq(polite:violations('d'), 6, 'and the count is available to a game that wants it')

    -----------------------------------------------------------------------
    -- TASK 3 — the tiers, end to end through a real host
    -----------------------------------------------------------------------

    t.describe('flooding the input path never costs a player anything')

    host, client = joinedPair{}
    local peer = onlyPeer(host)
    local address = peer.address

    for i = 1, 20000 do
        raw(client, P.INPUT, { seq = i, forward = 1, angle = 0 }, P.CH_STREAM, false)
    end
    pump(host, client, 0.5)

    t.ok(host.stats.throttled > 15000,
         ('the silent throttle dropped the excess (%d)'):format(host.stats.throttled))
    t.ok(not host.access:isBanned(address),
         'twenty thousand inputs in half a second earned no ban')
    t.eq(host.stats.limited, 0, 'and no penalising limiter was involved at all')
    t.ok(onlyPeer(host) ~= nil, 'the peer is still connected')
    t.ok(client:joined(), 'and still joined')

    -- The proof that the two tiers are genuinely separate: after that flood, a
    -- chat line — which goes through the penalising tier — still gets through.
    -- If the tiers had been merged, this peer would be muted.
    local heard
    host.onChat = function(_, _, text) heard = text end
    client:chat('still here')
    pump(host, client, 0.2)
    t.eq(heard, 'still here',
         'and a semantic message still works, because the input flood earned no strike')
    client:close('done'); host:close()

    -----------------------------------------------------------------------
    t.describe('flooding a semantic path does earn a penalty')

    local floods = {}
    host, client = joinedPair{
        flood = { chat = { limit = 4, per = 10, penalty = 5 } },
        onFlood = function(_, _, tag, retry, strikes)
            floods[#floods + 1] = { tag = tag, retry = retry, strikes = strikes }
        end,
    }

    local delivered = 0
    host.onChat = function() delivered = delivered + 1 end

    for i = 1, 30 do client:chat('spam ' .. i) end
    pump(host, client, 0.3)

    t.eq(delivered, 4, 'exactly the window\'s worth of chat was acted on')
    t.ok(host.stats.limited >= 26, 'the rest was refused',
         tostring(host.stats.limited))
    t.eq(#floods, 1, 'and the game was told once, not once per refused packet')
    if floods[1] then
        t.eq(floods[1].tag, 'chat', 'the hook is told which message type')
        t.eq(floods[1].strikes, 1, 'and how many strikes the peer has')
        t.eq(floods[1].retry, 5, 'and how long the mute lasts')
    end
    t.ok(client:joined(), 'the peer is muted, not disconnected')
    t.ok(not host.access:isBanned(onlyPeer(host).address),
         'and not banned, because banning is off by default')
    client:close('done'); host:close()

    t.describe('a game that asks for a ban gets one')
    host, client = joinedPair{
        floodBan = true,
        flood = { chat = { limit = 2, per = 10, penalty = 1, banAfter = 2 } },
    }
    local victim = onlyPeer(host).address

    for i = 1, 10 do client:chat('a') end
    pump(host, client, 0.2)
    t.ok(not host.access:isBanned(victim), 'one strike is not enough')

    -- Past the first mute, and straight back into it.
    pump(host, client, 1.2)
    for i = 1, 10 do client:chat('b') end
    pump(host, client, 0.2)
    t.ok(host.access:isBanned(victim), 'the second strike reaches banAfter and bans')
    host:close()

    -----------------------------------------------------------------------
    -- TASK 4 — the input path is bounded by the tick, not by the send rate
    -----------------------------------------------------------------------

    --[[
        The hole this is guarding against: a server that applies input the moment
        it arrives and integrates each one by a constant tick duration. Send four
        times as often and you move four times as fast, authoritatively, and your
        own prediction agrees so nothing rubber-bands to reveal it.

        MeatRayCast does not have it — inputs are latched and `HostMT:step`
        consumes at most one per tick — and this is where that stops being an
        accident of how it was written.

        The throttle is switched off for these two cases on purpose. It would also
        bound the flood, and then the test would be measuring the throttle instead
        of the latch, and removing the latch would leave it green.
    ]]

    t.describe('input at four times the tick rate does not move four times as far')

    local function runCadence(perTick, ticks)
        Loopback.reset(); defineArchetypes(); Entity.resetIds(1)
        local pt = freshPort()
        local h = makeHost{ port = pt, inputInterval = 0, tickRate = 60,
                            snapshotRate = 20 }
        local c = makeClient{ port = pt, prediction = false }
        pump(h, c, 0.4)

        local pr = onlyPeer(h)
        local start = { x = pr.entity.x, y = pr.entity.y }
        local base = { applied = pr.inputsApplied, superseded = pr.inputsSuperseded,
                       received = pr.inputsReceived }

        -- From here the client is not updated: it would send its own inputs, at
        -- its own rate, and this test is about what the host does with the ones
        -- it is given.
        local seq = pr.lastSeq
        local steps = 0
        for _ = 1, ticks do
            for _ = 1, perTick do
                seq = seq + 1
                raw(c, P.INPUT, { seq = seq, forward = 1, angle = 0 },
                    P.CH_STREAM, false)
            end
            local before = h.clock.tickCount
            h:update(1 / 60)
            steps = steps + (h.clock.tickCount - before)
        end

        local moved = math.sqrt((pr.entity.x - start.x) ^ 2
                                + (pr.entity.y - start.y) ^ 2)
        local applied = pr.inputsApplied - base.applied
        local superseded = pr.inputsSuperseded - base.superseded
        local received = pr.inputsReceived - base.received
        c:close('done'); h:close()
        return moved, applied, superseded, received, steps
    end

    local TICKS = 30
    local oneX, appliedOne, supersededOne, receivedOne, stepsOne = runCadence(1, TICKS)
    local fourX, appliedFour, supersededFour, receivedFour, stepsFour = runCadence(4, TICKS)

    t.eq(stepsOne, stepsFour, 'both runs simulated the same number of ticks')
    t.ok(oneX > 1.4, ('one input per tick moved the player %.3f tiles'):format(oneX))
    t.near(fourX, oneX, 1e-9,
           ('four per tick moved %.3f, the same distance'):format(fourX))
    t.ok(fourX < oneX * 1.05,
         'four times the send rate is not four times the speed')

    t.ok(receivedFour >= receivedOne * 3.5,
         ('the host really did receive four times as many (%d vs %d)')
         :format(receivedFour, receivedOne))
    t.eq(appliedFour, stepsFour,
         'but applied exactly one per tick, however many arrived')
    t.eq(appliedOne, stepsOne, 'as did the well-behaved sender')
    t.eq(supersededOne, 0, 'which supersedes nothing')
    t.ok(supersededFour >= TICKS * 2,
         ('and the excess is counted as superseded rather than banked (%d)')
         :format(supersededFour))

    t.describe('and the excess is dropped rather than queued')
    -- The distinction matters: a queue would let a fast sender bank movement and
    -- would make a normal sender wait behind its own backlog. Received minus
    -- superseded is what actually reached a tick, and it cannot exceed the number
    -- of ticks there were.
    t.ok(receivedFour - supersededFour <= stepsFour,
         ('at most one input per tick survived to be consumed (%d over %d ticks)')
         :format(receivedFour - supersededFour, stepsFour))

    t.describe('a held input keeps applying when no packet arrives')
    host, client = joinedPair{ prediction = false }
    peer = onlyPeer(host)
    raw(client, P.INPUT, { seq = peer.lastSeq + 1, forward = 1, angle = 0 },
        P.CH_STREAM, false)
    pumpHost(host, 1 / 60)
    local afterOne = peer.entity.x
    pumpHost(host, 10 / 60)
    t.ok(peer.entity.x > afterOne,
         'the latch persists, because a key held down produced no new packet')
    client:close('done'); host:close()

    t.describe('a stale input is dropped rather than rewinding the player')
    host, client = joinedPair{ prediction = false }
    peer = onlyPeer(host)
    raw(client, P.INPUT, { seq = 100, forward = 1, angle = 0 }, P.CH_STREAM, false)
    pumpHost(host, 0.05)
    local before = host.stats.stale
    raw(client, P.INPUT, { seq = 5, forward = -1, angle = 0 }, P.CH_STREAM, false)
    pumpHost(host, 0.05)
    t.eq(host.stats.stale, before + 1, 'an input older than the latch is counted and dropped')
    t.eq(peer.input.forward, 1, 'and the newer intent is still what is latched')
    client:close('done'); host:close()

    -----------------------------------------------------------------------
    -- TASK 5 — validate before applying
    -----------------------------------------------------------------------

    t.describe('the number guard, as a unit')

    t.eq(Rep.finite(0 / 0), nil, 'NaN is not a number you may keep')
    t.eq(Rep.finite(math.huge), nil, 'nor is positive infinity')
    t.eq(Rep.finite(-math.huge), nil, 'nor negative')
    t.eq(Rep.finite(1e309), nil, 'a literal that overflows to inf is caught the same way')
    t.eq(Rep.finite('nope'), nil, 'and a non-number is nil rather than an error')
    t.eq(Rep.finite(2.5), 2.5, 'a real number survives')
    t.eq(Rep.finite('2.5'), 2.5, 'and so does one that arrived as a string')
    t.eq(Rep.finite(5, 0, 4), nil, 'out of range is refused')
    t.eq(Rep.finite(-1, 0, 4), nil, 'below range too')
    t.eq(Rep.finite(0, 0, 4), 0, 'the bounds are inclusive')

    -- `if tonumber(body.angle) then e.angle = tonumber(body.angle) end` is the
    -- shape this replaces, and it is true for NaN.
    t.ok(tonumber(0 / 0) ~= nil,
         'which matters, because tonumber(NaN) is truthy and reads as valid')

    t.describe('input sanitising never returns a value that can poison a position')

    local poisoned = Rep.sanitiseInput{ seq = 1, forward = 0 / 0, strafe = math.huge,
                                        turn = -math.huge, angle = 0 / 0 }
    t.eq(poisoned.forward, 0, 'NaN forward becomes zero')
    t.eq(poisoned.strafe, 1, 'infinite strafe clamps to the unit')
    t.eq(poisoned.turn, -1, 'and negative infinity to minus one')
    t.eq(poisoned.angle, nil, 'an unusable angle is absent, so the last good aim stands')

    local absurd = Rep.sanitiseInput{ angle = 1e300 }
    t.eq(absurd.angle, nil, 'an angle past the bound is refused rather than clamped')
    local sane = Rep.sanitiseInput{ angle = -2.5 }
    t.eq(sane.angle, -2.5, 'a real angle passes through untouched')
    t.eq(Rep.sanitiseInput{ seq = 0 / 0 }.seq, 0, 'a NaN sequence cannot wedge the latch')
    t.eq(Rep.sanitiseInput{ seq = math.huge }.seq, 0,
         'nor can an infinite one, which would drop every later input forever')

    -----------------------------------------------------------------------
    t.describe('the schema refuses whole messages, one field at a time')

    local BAD = {
        { P.INPUT, { angle = 0 / 0 }, 'NaN' },
        { P.INPUT, { angle = math.huge }, 'infinite' },
        { P.INPUT, { angle = -math.huge }, 'infinite' },
        { P.INPUT, { angle = 1e300 }, 'above' },
        { P.INPUT, { forward = 1e300 }, 'above' },
        { P.INPUT, { seq = -1 }, 'below' },
        { P.INPUT, { forward = 'fast' }, 'should be a number' },
        { P.COMMAND, { name = 42 }, 'should be a string' },
        { P.COMMAND, { body = {} }, 'missing' },
        { P.COMMAND, { name = string.rep('x', 65) }, 'over the' },
        { P.CHAT, {}, 'missing' },
        { P.CHAT, { text = 12 }, 'should be a string' },
        { P.CHAT, { text = string.rep('x', 1025) }, 'over the' },
        { P.JOIN, { version = 0 / 0 }, 'NaN' },
        { P.JOIN, { name = string.rep('x', 65) }, 'over the' },
        { P.ACCEPT, { tickRate = 0 / 0 }, 'NaN' },
        { P.ACCEPT, { tickRate = 100000 }, 'above' },
        { P.SNAPSHOT, { tick = -1 }, 'below' },
        { P.EVENT, { body = {} }, 'missing' },
    }

    for _, case in ipairs(BAD) do
        local kind, body, expect = case[1], case[2], case[3]
        local valid, why = P.check(kind, body)
        t.ok(not valid, ('a %s carrying %s is refused'):format(P.names[kind], expect))
        t.ok(why and why:find(expect, 1, true),
             ('and the reason names the problem (%s)'):format(tostring(why)))
    end

    t.ok(not P.check(P.CHAT, 'not a table'), 'a body that is not a table is refused')
    t.ok(not P.check(P.CHAT, nil), 'and so is a missing one')

    -----------------------------------------------------------------------
    t.describe('a poisoned field is never half-applied to an entity')

    --[[
        The exact failure: one player sends `yaw = 1e999`, the server assigns it
        before the line that would have rejected it, and from then on every
        snapshot to every player carries a broken value. The sender is not the one
        it breaks.
    ]]

    host, client = joinedPair{ prediction = false }
    peer = onlyPeer(host)
    local entity = peer.entity
    local startX, startY, startAngle = entity.x, entity.y, entity.angle
    local seqBefore = peer.lastSeq

    local malformedBefore = host.stats.malformed
    raw(client, P.INPUT, { seq = seqBefore + 50, forward = 1, strafe = 0, angle = 0 / 0 },
        P.CH_STREAM, false)
    pumpHost(host, 0.2)

    t.ok(host.stats.malformed > malformedBefore, 'the message was refused')
    t.eq(entity.angle, startAngle, 'the angle is untouched')
    t.eq(entity.x, startX, 'and so is the position')
    t.eq(entity.y, startY, 'in both axes')
    t.ok(entity.x == entity.x and entity.angle == entity.angle,
         'nothing on the entity is NaN')

    -- The whole message was rejected, so `forward = 1` did not sneak through on
    -- the strength of being the field that happened to be checked first — and the
    -- sequence number did not advance, which a partially-applied message would
    -- have done on its way to the field that failed.
    t.ok(peer.input == nil or peer.input.forward == 0,
         'no partial intent was latched')
    t.eq(peer.lastSeq, seqBefore, 'and the latch did not advance past it')

    -- And the peer is not broken by having sent one bad packet.
    raw(client, P.INPUT, { seq = seqBefore + 51, forward = 1, strafe = 0, angle = 0 },
        P.CH_STREAM, false)
    pumpHost(host, 0.3)
    t.ok(entity.x > startX, 'a good input immediately afterwards works normally')
    t.ok(entity.x == entity.x, 'and the position it produced is a real number')

    t.describe('a snapshot of a poisoned world never leaves the host')
    local snapshotOk = true
    for _, snap in ipairs(Rep.entitySnapshots(host.entities)) do
        if snap.x ~= snap.x or snap.y ~= snap.y or (snap.angle and snap.angle ~= snap.angle) then
            snapshotOk = false
        end
    end
    t.ok(snapshotOk, 'because the value never reached the entity to be snapshotted')
    client:close('done'); host:close()

    -----------------------------------------------------------------------
    t.describe('a parse failure and a handler failure are different things')

    --[[
        One try block around both the decode and the handler means a genuine
        server exception is reported to the player as "malformed message", and
        logged nowhere. The player then reports a protocol bug that does not
        exist, and the real stack trace was discarded on a machine nobody is
        looking at.
    ]]

    local warnings = {}
    host, client = joinedPair{
        onCommand = function() error('the game\'s own bug', 0) end,
    }
    host.onWarning = function(text) warnings[#warnings + 1] = text end

    local malformedAtStart = host.stats.malformed
    client:command('fire', { angle = 0.5 })
    pump(host, client, 0.2)

    t.eq(host.stats.handlerErrors, 1, 'the handler failure is counted as a handler failure')
    t.eq(host.stats.malformed, malformedAtStart,
         'and emphatically not as a malformed packet')
    t.eq(#warnings, 1, 'and it is logged, rather than swallowed by the pcall that caught it')
    t.ok(warnings[1] and warnings[1]:find('onCommand'),
         'with the name of the thing that failed', warnings[1])
    t.ok(client:joined(), 'the client is unaffected')
    t.eq(client.state, 'joined', 'and was told nothing about a message being malformed')

    t.describe('and a genuinely malformed packet is counted as one')
    warnings = {}
    local errorsBefore = host.stats.handlerErrors
    client.transport:send(client.peer, 'i\255\255\255not a body', P.CH_STREAM, false)
    pump(host, client, 0.2)
    t.ok(host.stats.malformed > malformedAtStart, 'the bad packet is counted as malformed')
    t.eq(host.stats.handlerErrors, errorsBefore, 'and not as a handler failure')
    client:close('done'); host:close()

    t.describe('malformed logging cannot itself become the flood')
    host, client, logged = joinedPair{}
    local linesBefore = #logged
    for _ = 1, 500 do
        client.transport:send(client.peer, 'i\255garbage', P.CH_STREAM, false)
    end
    pump(host, client, 0.2)
    t.ok(host.stats.malformed >= 500, 'five hundred bad packets were all counted')
    t.ok(#logged - linesBefore <= 2,
         ('but produced at most a line or two of log (%d)'):format(#logged - linesBefore))
    client:close('done'); host:close()

    -----------------------------------------------------------------------
    t.describe('a client cannot send host-to-client traffic')

    host, client = joinedPair{ prediction = false }
    peer = onlyPeer(host)
    local movedBefore = peer.entity.x

    -- A peer claiming to be the server: a snapshot moving everyone, a kick, an
    -- accept. There is no handler for any of it and there must never be one.
    raw(client, P.SNAPSHOT, { tick = 1e9, e = { { id = peer.entity.id, kind = 'player',
                                                  x = 99, y = 99 } } })
    raw(client, P.KICK, { reason = 'you are kicked by another player' })
    raw(client, P.ACCEPT, { peerId = 999 })
    raw(client, P.WORLD, { doors = { ['2,2'] = 1 } })
    pump(host, client, 0.2)

    t.eq(host.stats.wrongWay, 4, 'all four were refused for travelling the wrong way')
    t.eq(peer.entity.x, movedBefore, 'the forged snapshot moved nobody')
    t.ok(client:joined(), 'and the forged kick kicked nobody')
    client:close('done'); host:close()

    -----------------------------------------------------------------------
    t.describe('payloads are capped before they are decoded')

    host, client = joinedPair{}
    local capBefore = host.stats.malformed
    client.transport:send(client.peer,
                          P.pack(P.CHAT, { text = string.rep('x', 4000) }),
                          P.CH_RELIABLE, true)
    pump(host, client, 0.2)
    t.ok(host.stats.malformed > capBefore, 'an oversized chat is refused by the host')
    t.ok(client:joined(), 'without disconnecting the peer over it')

    capBefore = host.stats.malformed
    client.transport:send(client.peer,
                          P.pack(P.INPUT, { seq = 1, pad = string.rep('x', 2000) }),
                          P.CH_STREAM, false)
    pump(host, client, 0.2)
    t.ok(host.stats.malformed > capBefore,
         'and so is an input padded far past anything an input can legitimately be')

    t.describe('a packet that nests past the depth limit is refused, not raised')
    capBefore = host.stats.malformed
    client.transport:send(client.peer, 'i' .. string.rep('[1:', 500), P.CH_STREAM, false)
    pump(host, client, 0.2)
    t.ok(host.stats.malformed > capBefore, 'deep nesting is a refusal like any other')
    t.ok(client:joined(), 'and the host is still running')
    client:close('done'); host:close()

    -----------------------------------------------------------------------
    t.describe('a client validates what the host sends it, too')

    -- The host is not automatically trustworthy: a game may join a server it did
    -- not build, and a broken one is as likely as a hostile one.
    host, client = joinedPair{}
    local rejectedBefore = client.rejected
    host:sendTo(onlyPeer(host), P.PONG, { time = 0 / 0 }, P.CH_STREAM, false)
    pump(host, client, 0.2)
    t.ok(client.rejected > rejectedBefore, 'a NaN pong is refused')
    t.ok(client.rtt == nil or client.rtt == client.rtt, 'and the round-trip time is not NaN')

    local wrongBefore = client.wrongWay
    host:sendTo(onlyPeer(host), P.JOIN, { version = 1 })
    pump(host, client, 0.2)
    t.eq(client.wrongWay, wrongBefore + 1,
         'and a host sending client-to-host traffic is refused the same way')
    t.ok(client:joined(), 'the client is unbothered by either')
    client:close('done'); host:close()

    Loopback.reset()
end
