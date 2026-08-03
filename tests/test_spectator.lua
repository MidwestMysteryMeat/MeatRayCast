--[[
    D35: spectator + killcam — the state machine (eyes → killcam → spectate),
    a camera that points at the killer then rides a living player, cycling that
    skips the dead and self, and revive dropping back to your own eyes.
]]

return function(t)
    local Spectator = require('meatray.game.spectator')
    local Entity    = require('meatray.sim.entity')
    local C         = require('meatray.sim.components')
    local Game      = require('meatray.game')

    t.eq(Game.spectator, Spectator, 'Game.spectator is the module')

    local function player(id, x, y, angle, name)
        local e = Entity.new{}
        e.id, e.x, e.y, e.angle = id, x, y, angle or 0
        e:add(C.Player{ peerId = id, name = name or ('p' .. id) })
        return e
    end

    ---------------------------------------------------------------------
    t.describe('resting state is your own eyes')

    local me = player(1, 5, 5)
    local other = player(2, 8, 5)
    local spec = Spectator.new{ killcamTime = 2 }

    t.eq(spec:mode_(), 'eyes', 'starts on eyes')
    t.eq(spec:isSpectating(), false, 'not spectating')
    t.eq(spec:camera(me), nil, 'and camera() is nil — use the player\'s own view')

    ---------------------------------------------------------------------
    t.describe('targets are living players, not self, in id order')

    local a, b, c = player(3, 1, 1), player(2, 2, 2), player(4, 3, 3)
    local list = spec:targets({ me, a, b, c }, me)
    t.eq(#list, 3, 'three others')
    t.eq(list[1].id, 2, 'sorted by id')
    t.eq(list[3].id, 4, 'ascending')
    b.dead = true
    t.eq(#spec:targets({ me, a, b, c }, me), 2, 'a dead player drops off the list')

    ---------------------------------------------------------------------
    t.describe('death starts a killcam pointing at the killer')

    -- I fall at (5,5); the killer stands at (10,5), due +x.
    local killer = player(9, 10, 5)
    spec:onDeath(5, 5, 10, 5, killer)
    t.eq(spec:mode_(), 'killcam', 'death enters the killcam')

    local cam = spec:camera(me)
    t.eq(cam.mode, 'killcam', 'the camera is a killcam')
    t.near(cam.angle, 0, 1e-6, 'looking toward the killer (+x)')
    t.ok(cam.x < 5, 'and sitting back from where I fell, so both are in frame')
    t.ok(cam.timeLeft > 0, 'with time on the clock')

    -- The killcam follows a killer that moves.
    killer.x, killer.y = 5, 10                  -- killer moved to due +y
    spec:update(0.1, { me, killer }, me)
    cam = spec:camera(me)
    t.near(cam.angle, math.pi / 2, 0.2, 'the cam tracks the killer as they move')

    ---------------------------------------------------------------------
    t.describe('the killcam expires into spectating a live player')

    spec:update(5, { me, killer }, me)          -- long past killcamTime
    t.eq(spec:mode_(), 'spectate', 'expires into spectate (someone is alive)')
    local scam = spec:camera(me)
    t.eq(scam.mode, 'spectate', 'now a spectate camera')
    t.ok(scam.x == killer.x and scam.y == killer.y, 'riding the living player')

    ---------------------------------------------------------------------
    t.describe('cycling moves through the living, skipping dead and self')

    local sp = Spectator.new{}
    local pA, pB, pC = player(10, 0, 0), player(11, 1, 1), player(12, 2, 2)
    local ents = { me, pA, pB, pC }
    sp:cycle(ents, 1, me)
    t.eq(sp:camera(me).x, pA.x, 'first cycle lands on the lowest-id other player')
    sp:cycle(ents, 1, me)
    t.eq(sp.target.id, 11, 'next moves up')
    sp:cycle(ents, 1, me)
    t.eq(sp.target.id, 12, 'and up')
    sp:cycle(ents, 1, me)
    t.eq(sp.target.id, 10, 'and wraps')
    sp:cycle(ents, -1, me)
    t.eq(sp.target.id, 12, 'backwards wraps the other way')

    ---------------------------------------------------------------------
    t.describe('a spectated target that dies is dropped')

    sp.target = pB                              -- watching pB
    sp.mode = 'spectate'
    pB.dead = true
    sp:update(0.1, ents, me)
    t.ok(sp.target ~= pB, 'the view left the corpse')
    t.ok(sp.target and not sp.target.dead, 'and moved to a living player')

    -- When the LAST living player dies, spectate falls back to eyes.
    for _, e in ipairs({ pA, pB, pC }) do e.dead = true end
    sp:update(0.1, ents, me)
    t.eq(sp:mode_(), 'eyes', 'nobody left to watch: back to your own eyes')

    ---------------------------------------------------------------------
    t.describe('revive returns to your own eyes')

    local rv = Spectator.new{}
    rv:onDeath(1, 1, 2, 2, nil)
    t.eq(rv:mode_(), 'killcam', 'dead: killcam')
    rv:onRevive()
    t.eq(rv:mode_(), 'eyes', 'revived: eyes')
    t.eq(rv:camera(me), nil, 'and the camera hands back to the player')

    ---------------------------------------------------------------------
    t.describe('death with nobody else alive: killcam then eyes')

    local alone = Spectator.new{ killcamTime = 1 }
    local solo = player(1, 5, 5)
    alone:onDeath(5, 5, 6, 5, nil)
    alone:update(2, { solo }, solo)             -- past the killcam, no targets
    t.eq(alone:mode_(), 'eyes', 'no one to spectate, so back to eyes')
end
