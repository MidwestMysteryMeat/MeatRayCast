--[[
    Lag compensation.

    The case that matters most here is not accuracy, it is the clamp. `when` is
    derived from a round-trip time, and an unclamped rewind lets a client with a
    claimed huge RTT shoot someone who has already left the room. That is an
    exploit rather than an inaccuracy, so it is tested as one.

    The second is that the restore is unconditional. A validation function that
    raises must not leave every entity in the game standing where it was half a
    second ago -- a far worse bug than the one this module fixes, and invisible
    until somebody walks through a wall.
]]

return function(t)
    local LagComp = require('meatray.net.lagcomp')

    local function entity(id, x, y)
        return { id = id, x = x, y = y, radius = 0.25 }
    end

    -- A target walking east along y = 5, one tile per capture.
    local function walked(history, steps)
        local e = entity(1, 0, 5)
        local list = { e }
        for i = 0, steps do
            e.x = i
            history:capture(i * 0.100, list)
        end
        return e, list
    end

    ---------------------------------------------------------------------
    t.describe('the window')

    local h = LagComp.new()
    t.eq(h:window(), LagComp.HISTORY * LagComp.CAPTURE_INTERVAL,
         'window is history depth times capture interval')
    t.near(h:window(), 0.6, 1e-9, 'which is 600ms by default')
    t.eq(h.stored, 0, 'nothing stored before the first capture')

    -- An empty history answers rather than raising: a shot may arrive before
    -- the host has captured anything at all.
    local empty, wasClamped = LagComp.new():positionsAt(0)
    t.eq(next(empty), nil, 'an empty history returns no positions')
    t.eq(wasClamped, false, 'and does not claim to have clamped')

    ---------------------------------------------------------------------
    t.describe('rewinding to where the target was')

    local hist = LagComp.new()
    local target = walked(hist, 5)          -- captures at t=0.0 .. 0.5, x=0..5

    t.eq(target.x, 5, 'the target is now at x=5')

    local at = hist:positionsAt(0.5)
    t.near(at[1][1], 5, 1e-9, 'rewinding to now gives the current position')

    at = hist:positionsAt(0.3)
    t.near(at[1][1], 3, 1e-9, 'rewinding 200ms gives where it was then')

    at = hist:positionsAt(0.1)
    t.near(at[1][1], 1, 1e-9, 'and further back still')

    -- Between captures, interpolated. A client rendering between two snapshots
    -- aimed at a position that was never captured, so landing on a stored frame
    -- is the exception rather than the rule.
    at = hist:positionsAt(0.25)
    t.near(at[1][1], 2.5, 1e-9, 'a time between captures interpolates')
    at = hist:positionsAt(0.44)
    t.near(at[1][1], 4.4, 1e-9, 'anywhere between them')

    ---------------------------------------------------------------------
    t.describe('the clamp is a security boundary')

    -- A client that reports an enormous round trip is asking the host to rewind
    -- past everything it remembers. It gets the oldest frame, not the position
    -- the target held when it was somewhere else entirely.
    local far, clamped = hist:positionsAt(-100)
    t.eq(clamped, true, 'a rewind past the window reports that it was clamped')
    t.near(far[1][1], 0, 1e-9, 'and resolves to the oldest frame, not further')
    t.ok(hist.stats.clamped > 0, 'and the clamp is counted, so abuse is visible')

    -- The window really is bounded: with a target that kept walking, a rewind
    -- to the far past must not reach a position older than the window allows.
    local rolling = LagComp.new()
    local walker = entity(1, 0, 5)
    for i = 0, 50 do
        walker.x = i
        rolling:capture(i * 0.100, { walker })
    end
    -- 51 captures at 100ms, six deep: the oldest survivor is x = 45.
    local oldest = rolling:positionsAt(-999)
    t.near(oldest[1][1], 45, 1e-9,
           'an ancient rewind reaches the oldest STORED frame, six back and no further')
    t.ok(oldest[1][1] > 0, 'not the position at the start of the match')

    -- A rewind into the future is clamped too. A client claiming a negative
    -- round trip must not be able to shoot where a target is about to be.
    local ahead, aheadClamped = hist:positionsAt(999)
    t.eq(aheadClamped, true, 'a rewind into the future is clamped')
    t.near(ahead[1][1], 5, 1e-9, 'to now, never beyond it')

    ---------------------------------------------------------------------
    t.describe('aim time')

    -- Both terms are real: half the trip is travel, the interpolation delay is
    -- how far behind live the client deliberately renders.
    t.near(LagComp.aimTime(10.0, 0.100, 0.050), 9.90, 1e-9,
           '100ms rtt and 50ms interpolation rewinds 100ms')
    t.near(LagComp.aimTime(10.0, 0, 0), 10.0, 1e-9, 'a perfect link rewinds nothing')
    t.near(LagComp.aimTime(10.0, nil, nil), 10.0, 1e-9, 'missing values are treated as zero')

    ---------------------------------------------------------------------
    t.describe('entities that did not exist then')

    -- Something that spawned inside the interval was not on the shooter's
    -- screen and must not be hittable in the past.
    local spawn = LagComp.new()
    local a = entity(1, 0, 5)
    spawn:capture(0.0, { a })
    local b = entity(2, 9, 9)
    spawn:capture(0.1, { a, b })

    local before = spawn:positionsAt(0.0)
    t.ok(before[1] ~= nil, 'the entity that existed is there')
    t.eq(before[2], nil, 'the one that had not spawned yet is not')

    local after = spawn:positionsAt(0.1)
    t.ok(after[2] ~= nil, 'and it appears once it exists')

    ---------------------------------------------------------------------
    t.describe('running a check against the rewound world')

    local w = LagComp.new()
    local mover = entity(1, 0, 5)
    local bystander = entity(2, 20, 20)
    local all = { mover, bystander }

    for i = 0, 3 do
        mover.x = i
        w:capture(i * 0.100, all)
    end
    t.eq(mover.x, 3, 'the mover is at 3 now')

    local seen = w:withRewound(0.1, all, function()
        return mover.x, bystander.x
    end)
    t.near(seen, 1, 1e-9, 'inside the callback the mover is where it was')
    t.near(mover.x, 3, 1e-9, 'and it is put back afterwards')
    t.near(bystander.x, 20, 1e-9, 'a stationary entity is unchanged')

    -- The restore must survive the callback raising. Otherwise one bad
    -- validation leaves the whole game standing in the past.
    local raised = pcall(function()
        w:withRewound(0.1, all, function() error('boom', 0) end)
    end)
    t.eq(raised, false, 'a raising callback still propagates its error')
    t.near(mover.x, 3, 1e-9, 'but every entity is restored anyway')
    t.near(mover.y, 5, 1e-9, 'on both axes')

    ---------------------------------------------------------------------
    t.describe('capture is on a timer, not every tick')

    local timed = LagComp.new{ interval = 0.100 }
    local e = entity(1, 0, 0)
    local list = { e }

    t.eq(timed:update(0, 1 / 60, list), true, 'the first update captures')
    local captures = 1
    for i = 1, 60 do                      -- one second at 60Hz
        if timed:update(i / 60, 1 / 60, list) then captures = captures + 1 end
    end
    t.ok(captures >= 9 and captures <= 12,
         ('a second at 60Hz captures about ten times, not sixty (got %d)'):format(captures))

    ---------------------------------------------------------------------
    t.describe('it holds no memory it does not need')

    -- Frames are preallocated and reused. At 10Hz forever, a table per capture
    -- would be a slow drip of garbage into the host's hot path.
    local reuse = LagComp.new()
    local first = reuse.frames[1]
    for i = 0, 30 do reuse:capture(i * 0.1, { entity(1, i, 0) }) end
    t.ok(rawequal(reuse.frames[1], first), 'the frame tables are the same objects')
    t.eq(#reuse.frames, LagComp.HISTORY, 'and there are still only six of them')
    t.eq(reuse.stored, LagComp.HISTORY, 'with the buffer full but not grown')

    ---------------------------------------------------------------------
    t.describe('through a real host')

    -- The module working in isolation is not the same as the feature existing.
    -- This drives a real host, over the loopback transport, with a real peer.
    local Net      = require('meatray.net')
    local Worldgen = require('meatray.sim.worldgen')
    local Entity   = require('meatray.sim.entity')
    local Loopback = require('meatray.net.transport.loopback')

    Loopback.reset()
    Entity.clearArchetypes()
    Entity.archetype('dummy', function(en) en.radius = 0.25 end)

    local host = Net.Host.new{
        mode = 'dedicated', transport = 'loopback', port = 8991,
        world = Worldgen.box(24, 24),
        snapshotRate = 20,
        onLog = function() end,
    }
    t.ok(host ~= nil, 'a host comes up')
    t.ok(host.lagComp ~= nil, 'with lag compensation on by default')

    local mover = host:spawn('dummy', 2.5, 5.5)
    t.ok(mover ~= nil, 'and an entity to shoot at')

    -- Walk it east for a second of host time, letting the host capture as it goes.
    for i = 1, 60 do
        mover.x = 2.5 + i * 0.1
        host:update(1 / 60)
    end
    t.near(mover.x, 8.5, 1e-6, 'the target has moved well away from where it started')
    t.ok(host.lagComp.stats.captures >= 8,
         ('the host captured history as it ran (%d)'):format(host.lagComp.stats.captures))

    -- With no peer the rewind still runs the callback, against the present.
    local nowX = host:rewindFor(nil, function() return mover.x end)
    t.near(nowX, mover.x, 1e-9, 'no peer means no rewind, and the shot still resolves')

    -- A peer whose transport reports latency should see the target in the past.
    -- Loopback reports rtt as latency*2000 ms, so a latency of 0.15 is a 300ms
    -- round trip: 150ms of travel plus a 50ms interpolation delay.
    local fake = { handle = {} }
    local realRtt = host.transport.rtt
    host.transport.rtt = function() return 300 end

    local aimAt = host:aimTimeFor(fake)
    t.ok(aimAt < host.now, 'the aim time is in the past')
    t.near(host.now - aimAt, 0.15 + 1 / 20, 1e-6,
           'by half the round trip plus one snapshot interval')

    local sawX = host:rewindFor(fake, function() return mover.x end)
    host.transport.rtt = realRtt

    -- The target moves 0.1 units per frame at 60Hz, so 6 units a second. A
    -- rewind of 0.15 + 0.05 seconds is therefore 1.2 units back. Derived rather
    -- than written as a constant, so the test says why the number is what it is.
    local speed = 0.1 * 60
    local rewound = 0.15 + 1 / 20
    t.ok(sawX < mover.x, 'the shooter saw the target behind where it now is')
    t.near(mover.x - sawX, speed * rewound, 0.05,
           'by exactly the distance it covered during the rewind')
    t.near(mover.x, 8.5, 1e-6, 'and the entity is back where it belongs afterwards')

    host:close()
    Entity.clearArchetypes()
    Loopback.reset()

    ---------------------------------------------------------------------
    t.describe('it runs with no host at all')

    local file = io.open('meatray/net/lagcomp.lua', 'r')
    t.ok(file ~= nil, 'the source is readable')
    if file then
        local source = file:read('*a')
        file:close()
        local code = require('tests.support.lua_source').stripNonCode(source)
        t.ok(not code:find('[^%w_]love[^%w_]'), 'lagcomp.lua does not name love')
        t.ok(not code:find('os%.time'), 'and reads no clock of its own')
        t.ok(code:find('function HistoryMT:withRewound'), 'and the stripped source is real code')
    end
end
