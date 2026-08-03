--[[
    F1: demo record/playback — the format round-trips exactly, and replaying a
    real simulation from the same seed lands on the same checksums.
]]

return function(t)
    local Demo     = require('meatray.sim.demo')
    local MeatRay  = require('meatray')
    local Entity   = require('meatray.sim.entity')
    local C        = require('meatray.sim.components')
    local Worldgen = require('meatray.sim.worldgen')
    local Rep      = require('meatray.net').replication
    local Game     = require('meatray.game')

    t.eq(MeatRay.demo, Demo, 'MeatRay.demo is the demo module')

    ---------------------------------------------------------------------
    t.describe('the format: deltas, events, exact floats')

    local rec = Demo.record{ rate = 60, source = 'procedural', seed = 90599143 }

    -- An awkward float on purpose: if the angle comes back off by one ulp the
    -- whole determinism story is over before it starts.
    local angle = 0.1 + 0.2

    rec:frame(0, { forward = 1, strafe = 0, angle = angle })
    for tick = 1, 599 do
        rec:frame(tick, { forward = 1, strafe = 0, angle = angle })
    end
    rec:frame(600, { forward = 0, strafe = -1, angle = angle })
    rec:event(600, 'fire', { angle = angle, weapon = 'pistol' })
    rec:event(600, 'door', { tx = 7, ty = 4 })
    rec:checkpoint(600, 'deadbeef')
    local text = rec:finish(900)

    -- Ten seconds of held key is one input line, not six hundred.
    local _, inputLines = text:gsub('\ni ', '\ni ')
    t.eq(inputLines, 2, 'unchanged input is not re-recorded')

    local play, err = Demo.load(text)
    t.ok(play, 'demo loads' .. (play and '' or (': ' .. tostring(err))))
    t.eq(play.header.seed, 90599143, 'seed survives')
    t.eq(play.header.rate, 60, 'rate survives')
    t.eq(play:length(), 901, 'length is the last tick plus one')

    t.eq(play:inputAt(0).forward, 1, 'tick 0 input')
    t.eq(play:inputAt(300).forward, 1, 'a tick inside the run inherits it')
    t.eq(play:inputAt(300).angle, angle, 'the float is bit-identical')
    t.eq(play:inputAt(600).strafe, -1, 'the change lands on its tick')
    t.eq(play:inputAt(899).strafe, -1, 'and holds to the end')

    local evs = play:eventsAt(600)
    t.eq(#evs, 2, 'both events on their tick')
    t.eq(evs[1].name, 'fire', 'in the order they happened')
    t.eq(evs[1].angle, angle, 'with their own exact float')
    t.eq(evs[1].weapon, 'pistol', 'string params survive')
    t.eq(evs[2].tx, 7, 'numeric params survive')
    t.eq(play:eventsAt(599), nil, 'quiet ticks carry nothing')

    t.eq(play:checkpointAt(600), 'deadbeef', 'checkpoints survive')
    t.eq(play:verify(599, {}), true, 'no checkpoint means no complaint')

    t.eq(select(2, Demo.load('not a demo')), 'not a demo file (bad magic)',
         'garbage refuses with a reason')
    t.eq(select(2, Demo.load(nil)), 'demo must be a string', 'nil refuses')

    ---------------------------------------------------------------------
    t.describe('checksums: order-blind, change-sensitive')

    local a = Entity.new{}; a.id, a.x, a.y, a.angle = 1, 2.5, 3.5, 0.4
    local b = Entity.new{}; b.id, b.x, b.y, b.angle = 2, 7.5, 1.5, -1.1

    local sum = Demo.checksum({ a, b })
    t.eq(#sum, 8, 'eight hex characters')
    t.eq(Demo.checksum({ b, a }), sum, 'array order does not matter')

    b.x = b.x + 0.01
    t.ok(Demo.checksum({ a, b }) ~= sum, 'a centimetre of drift changes it')
    b.x = b.x - 0.01
    t.eq(Demo.checksum({ a, b }), sum, 'and putting it back restores it')

    local ghost = Entity.new{}; ghost.id, ghost.localOnly = 99, true
    t.eq(Demo.checksum({ a, b, ghost }), sum, 'local-only entities are invisible')

    ---------------------------------------------------------------------
    t.describe('the claim itself: record a real sim, replay it, same world')

    Game.reset()
    Entity.resetIds(1)

    -- The same gameplay definitions both runs will use.
    Game.effects.define('burn', {
        duration = 1, assetTags = { 'damage.type.fire' },
        modifiers = { { attr = 'health', op = 'add', magnitude = -1 } },
    })

    local function buildRun(seed)
        Entity.resetIds(1)
        local world = Worldgen.generate{
            width = 24, height = 24, seed = seed, doorChance = 0.4,
        }
        local player = Entity.new{}
        player.x, player.y = (world.spawn and world.spawn.x) or 4.5,
                             (world.spawn and world.spawn.y) or 4.5
        player.angle = 0
        player.radius = 0.24
        player:add(C.Player{ peerId = 0, name = 'rec' })
        Game.attach(player, {
            authority = true,
            attributes = { healthMax = 100, health = 100, moveSpeed = 3.2 },
        })
        return world, player, { player }
    end

    local STEP = 1 / 60
    local Collide = require('meatray.sim.collide')

    -- One tick of the demo loop, shared verbatim by the recording run and the
    -- playback run — the test is that the DATA reproduces the run, so the
    -- code must be the same on both sides, exactly as main.lua replays
    -- through its own simulate().
    local function stepOnce(world, player, entities, input)
        Rep.applyInput(player, Rep.sanitiseInput(input), STEP, world,
                       { moveSpeed = 3.2, turnSpeed = 2.6 })
        Game.tickAll(entities, STEP)
        world:update(STEP)
    end

    -- Recording run: wander with turns, so the path is not a straight line
    -- that would forgive an angle bug.
    local world1, p1, ents1 = buildRun(20260802)
    local rec2 = Demo.record{ rate = 60, source = 'procedural', seed = 20260802 }
    local sums = {}
    for tick = 0, 299 do
        local input = {
            forward = (tick % 120 < 90) and 1 or 0,
            strafe = (tick % 200 < 40) and 1 or 0,
            angle = 0.02 * tick,
        }
        rec2:frame(tick, input)
        stepOnce(world1, p1, ents1, input)
        if tick % 60 == 59 then
            local sum60 = Demo.checksum(ents1)
            rec2:checkpoint(tick, sum60)
            sums[#sums + 1] = sum60
        end
    end
    local demoText = rec2:finish(299)
    t.eq(#sums, 5, 'five checkpoints recorded')

    -- Playback run: a fresh world from the header's seed, driven only by the
    -- demo. No state crosses from the first run except the file text.
    local replay = Demo.load(demoText)
    local world2, p2, ents2 = buildRun(replay.header.seed)
    local diverged
    for tick = 0, replay:length() - 1 do
        stepOnce(world2, p2, ents2, replay:inputAt(tick))
        local ok2, want, got = replay:verify(tick, ents2)
        if not ok2 and not diverged then
            diverged = { tick = tick, want = want, got = got }
        end
    end
    t.eq(diverged, nil, 'the replay never diverges'
         .. (diverged and (' (first at tick ' .. diverged.tick .. ')') or ''))
    t.eq(Demo.checksum(ents2), sums[#sums], 'and ends on the recorded world')

    -- The forensics half: replay again with one tick of input tampered with,
    -- and verify must name a tick at or after the tampering, not the end.
    -- Tick 60 is inside a forward-held stretch (60 % 120 < 90), so zeroing it
    -- genuinely changes the path — tampering a tick that was already idle
    -- would prove nothing, which is a mistake this comment is here to prevent.
    local world3, p3, ents3 = buildRun(replay.header.seed)
    local firstBad
    for tick = 0, replay:length() - 1 do
        local input = replay:inputAt(tick)
        if tick == 60 then input.forward = 0 end
        stepOnce(world3, p3, ents3, input)
        local ok3 = replay:verify(tick, ents3)
        if not ok3 and not firstBad then firstBad = tick end
    end
    t.ok(firstBad, 'a tampered run is caught')
    t.ok(firstBad and firstBad >= 60 and firstBad <= 119,
         ('and named near the tampering, not the end (tick %s)')
             :format(tostring(firstBad)))

    Game.reset()
    Entity.resetIds(1)
end
