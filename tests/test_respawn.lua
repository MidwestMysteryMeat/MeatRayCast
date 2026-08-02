--[[
    Respawn: the wait, the shield as an effect, and spawn choice.
]]

return function(t)
    local Entity  = require('meatray.sim.entity')
    local Respawn = require('meatray.game.respawn')
    local Effects = require('meatray.game.effects')
    local Damage  = require('meatray.game.damage')
    local Game    = require('meatray.game')

    t.eq(Game.respawn, Respawn, 'Game.respawn is the respawn module')

    Game.reset()
    local STEP = 1 / 60

    local function fighter()
        local e = Entity.new{}
        Game.attach(e, {
            authority = true,
            attributes = { healthMax = 100, health = 100 },
        })
        return e
    end

    ---------------------------------------------------------------------
    t.describe('the wait is the delay, exactly')

    local rs = Respawn.new{ delay = 0.5, protection = 0 }
    t.eq(rs:state(7), 'alive', 'unknown ids are alive')
    t.eq(rs:remaining(7), 0, 'and owe no wait')

    rs:notifyDeath(7)
    t.eq(rs:state(7), 'dead', 'a death is a death')
    t.ok(math.abs(rs:remaining(7) - 0.5) < 1e-9, 'the full delay is owed')

    -- Dying again mid-wait does not restart the clock.
    for _ = 1, 15 do rs:tick(STEP) end
    local owed = rs:remaining(7)
    rs:notifyDeath(7)
    t.eq(rs:remaining(7), owed, 'a second death mid-wait changes nothing')

    -- 30 steps of 1/60 is exactly 0.5: due on that step, not the one after.
    local due = {}
    for _ = 16, 30 do due = rs:tick(STEP) end
    t.eq(due[1], 7, 'due exactly when the delay elapses')
    t.eq(rs:state(7), 'ready', 'ready, not alive: nobody spawned them yet')
    t.eq(rs:canRespawn(7), true, 'canRespawn agrees')
    t.eq(rs:remaining(7), 0, 'nothing further owed')

    t.eq(#rs:tick(STEP), 0, 'due ids are announced exactly once')

    rs:spawned(7)   -- no entity: bookkeeping still closes
    t.eq(rs:state(7), 'alive', 'spawned closes the death')

    ---------------------------------------------------------------------
    t.describe('per-death delay override, the modes handshake')

    rs:notifyDeath(9, 2)
    t.ok(math.abs(rs:remaining(9) - 2) < 1e-9, 'onRequestRespawn delay wins')
    rs:clear(9)
    t.eq(rs:state(9), 'alive', 'clear forgets a leaver')

    ---------------------------------------------------------------------
    t.describe('manual mode announces nothing')

    local manual = Respawn.new{ delay = 0.1, auto = false }
    manual:notifyDeath('a')
    local announced = 0
    for _ = 1, 12 do announced = announced + #manual:tick(STEP) end
    t.eq(announced, 0, 'manual mode never announces')
    t.eq(manual:canRespawn('a'), true, 'but polling still works')

    ---------------------------------------------------------------------
    t.describe('spawn protection is an effect, and damage refuses')

    local e = fighter()
    local shielded = Respawn.new{ delay = 0, protection = 0.5 }
    shielded:notifyDeath(1)
    shielded:tick(STEP)
    local applied = shielded:spawned(1, e)
    t.ok(applied, 'the shield applies')
    t.eq(Respawn.isProtected(e), true, 'and reads back')

    local before = Game.attributes.get(e, 'health')
    local hit, why = Damage.apply(e, 25)
    t.eq(hit, nil, 'damage is refused, not reduced')
    t.ok(tostring(why):find('immune'), 'and says it was immunity')
    t.eq(Game.attributes.get(e, 'health'), before, 'not a point was lost')

    -- The shield runs on the effects clock and expires there.
    for _ = 1, 31 do Game.tick(e, STEP) end
    t.eq(Respawn.isProtected(e), false, 'the shield expires')
    t.ok(Damage.apply(e, 25), 'and damage lands again')
    t.eq(Game.attributes.get(e, 'health'), 75, 'for its full amount')

    ---------------------------------------------------------------------
    t.describe('firing drops the shield')

    local shooter = fighter()
    Respawn.protect(shooter, 5)
    t.eq(Respawn.isProtected(shooter), true, 'shield up')
    t.eq(Respawn.dropProtection(shooter), 1, 'one instance dropped')
    t.eq(Respawn.isProtected(shooter), false, 'shield gone')
    t.eq(Respawn.dropProtection(shooter), 0, 'dropping twice is harmless')

    t.eq(select(2, Respawn.protect({}, 1)), 'entity has no ability system',
         'protecting a bare table refuses, with a reason')

    ---------------------------------------------------------------------
    t.describe('pickSpawn keeps its distance')

    local spawns = {
        { x = 0,  y = 0,  angle = 0 },
        { x = 10, y = 0,  angle = math.pi },
        { x = 0,  y = 10, angle = 0 },
    }
    local hostiles = {
        { x = 1, y = 1 },
        { x = 9, y = 1 },
    }
    local pick = Respawn.pickSpawn(spawns, hostiles)
    t.eq(pick, spawns[3], 'the spawn farthest from the nearest threat wins')

    -- A third threat makes every spawn equally bad; a perfect standoff falls
    -- deterministically to the first spawn in the list.
    hostiles[3] = { x = 1, y = 9 }
    pick = Respawn.pickSpawn(spawns, hostiles)
    t.eq(pick, spawns[1], 'boxing in every spawn falls back to the first')

    t.eq(Respawn.pickSpawn(spawns, { { x = 5, y = 5, dead = true } }),
         spawns[1], 'the dead threaten nobody: first spawn on a tie')
    t.eq(Respawn.pickSpawn(spawns), spawns[1], 'no hostiles, first spawn')
    t.eq(Respawn.pickSpawn({ spawns[2] }, hostiles), spawns[2],
         'one spawn is no choice at all')
    t.eq(Respawn.pickSpawn({}), nil, 'no spawns is an answerable question')

    Game.reset()
end
