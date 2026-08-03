--[[
    C19: AI hearing. A noise the AI cannot see sends it to investigate the spot —
    beyond the last-known VISUAL. Hearing gives a place to look, never a lock: it
    sets the investigate state and last-known point, and does not reveal a target.
]]

return function(t)
    local Entity = require('meatray.sim.entity')
    local C = require('meatray.sim.components')
    local AI = require('meatray.sim.ai')

    Entity.clearArchetypes()
    Entity.archetype('mob', function(e)
        e:add(C.Brain{})
        e:add(C.Health{ hp = 100, max = 100 })
        e.radius = 0.25
    end)
    Entity.archetype('hero', function(e)
        e:add(C.Player{ peerId = 1, name = 'p' })
        e.radius = 0.24
    end)

    ---------------------------------------------------------------------
    t.describe('a nearby sound sends a patrolling AI to investigate')

    local mob = Entity.spawn('mob', 5.5, 5.5)
    AI.attach(mob, { state = 'patrol' })
    t.eq(mob:get('brain').state, 'patrol', 'starts patrolling')

    local reacted = AI.hear(mob, 9.5, 5.5, 1)   -- 4 tiles away, in range
    t.ok(reacted, 'it heard the sound')
    local b = mob:get('brain')
    t.eq(b.state, 'investigate', 'and switched to investigate')
    t.eq(b.lastKnownX, 9.5, 'aiming at the noise x')
    t.eq(b.lastKnownY, 5.5, 'and y')
    t.eq(b.investigateTimer, 0, 'the search clock reset')

    ---------------------------------------------------------------------
    t.describe('a sound out of hearing range is ignored')

    local deafish = Entity.spawn('mob', 2.5, 2.5)
    AI.attach(deafish, { state = 'patrol' })
    -- Default hearing is 13; put the noise 20 tiles away.
    t.ok(not AI.hear(deafish, 22.5, 2.5, 1), 'too far to hear')
    t.eq(deafish:get('brain').state, 'patrol', 'still patrolling')

    ---------------------------------------------------------------------
    t.describe('loudness scales the range')

    local far = Entity.spawn('mob', 2.5, 2.5)
    AI.attach(far, { state = 'patrol' })
    -- 18 tiles away: silent at loudness 1, heard at loudness 2 (range 26).
    t.ok(not AI.hear(far, 20.5, 2.5, 1, { loudness = 1 }), 'a quiet sound does not carry')
    t.ok(AI.hear(far, 20.5, 2.5, 1, { loudness = 2 }), 'a loud one does')

    ---------------------------------------------------------------------
    t.describe('a chasing AI does not abandon its lead for a noise')

    local hunter = Entity.spawn('mob', 5.5, 5.5)
    AI.attach(hunter, { state = 'patrol' })
    hunter:get('brain').state = 'chase'
    t.ok(not AI.hear(hunter, 6.5, 5.5, 1), 'a live chase ignores sound')
    t.eq(hunter:get('brain').state, 'chase', 'still chasing')

    ---------------------------------------------------------------------
    t.describe('a non-investigating AI stays deaf unless forced')

    local dumb = Entity.spawn('mob', 5.5, 5.5)
    AI.attach(dumb, { state = 'patrol', investigate = false })
    t.ok(not AI.hear(dumb, 6.5, 5.5, 1), 'no investigate = no hearing')
    t.ok(AI.hear(dumb, 6.5, 5.5, 1, { force = true }), 'force overrides')

    ---------------------------------------------------------------------
    t.describe('cross-storey sound is muffled and gated on crossStorey')

    local ground = Entity.spawn('mob', 5.5, 5.5)
    ground.storey = 1
    AI.attach(ground, { state = 'patrol' })   -- crossStorey defaults off
    t.ok(not AI.hear(ground, 6.5, 5.5, 2), 'no cross-storey hearing by default')

    local listener = Entity.spawn('mob', 5.5, 5.5)
    listener.storey = 1
    AI.attach(listener, { state = 'patrol', crossStorey = true })
    -- Same-storey it hears at 13; across a storey the range halves to ~6.5.
    t.ok(not AI.hear(listener, 15.5, 5.5, 2), 'far cross-storey sound is muffled out')
    t.ok(AI.hear(listener, 9.5, 5.5, 2), 'a close cross-storey sound still carries')

    ---------------------------------------------------------------------
    t.describe('broadcastSound reaches every AI in range, players excepted')

    local a = Entity.spawn('mob', 5.5, 5.5);  AI.attach(a, { state = 'patrol' })
    local c = Entity.spawn('mob', 7.5, 5.5);  AI.attach(c, { state = 'patrol' })
    local d = Entity.spawn('mob', 40.5, 40.5); AI.attach(d, { state = 'patrol' })
    local hero = Entity.spawn('hero', 6.5, 5.5)   -- players do not "hear"
    local list = { a, c, d, hero }
    local n = AI.broadcastSound(list, 6.5, 5.5, 1)
    t.eq(n, 2, 'the two nearby mobs reacted; the far one and the player did not')
    t.eq(a:get('brain').state, 'investigate', 'a investigates')
    t.eq(d:get('brain').state, 'patrol', 'the far mob is unmoved')
end
