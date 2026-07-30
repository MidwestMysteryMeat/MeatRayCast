--[[
    Weapons: ammo, reload, fire rate, spread and recoil.

    The assertion this file exists for is the fire rate one. A weapon whose
    cooldown is decremented when a fire request ARRIVES fires as fast as the
    requests arrive, which means as fast as a client chooses to send them — and
    that is a shipped bug in a sibling project, not a hypothetical. So the suite
    sends a thousand fire commands inside a single simulation step and asserts
    that exactly one shot came out, then walks the tick forward one step at a
    time and asserts the next shot lands on the step the fire interval says and
    not one earlier.

    The second thing worth the file is that damage arrives as an EFFECT. A
    resistance is applied to the target and the same shot is fired again; if the
    damage number does not change, the weapon is writing hit points directly and
    every buff, shield and resistance in the game is decorative.
]]

local Entity   = require('meatray.sim.entity')
local C        = require('meatray.sim.components')
local Worldgen = require('meatray.sim.worldgen')
local Game     = require('meatray.game')

local Weapons    = Game.weapons
local Effects    = Game.effects
local Attributes = Game.attributes

local STEP = 1 / 60

return function(t)
    Game.reset()
    Entity.clearArchetypes()

    local function world() return Worldgen.box(24, 24) end

    -- A target that can actually take damage: the ability system is what turns a
    -- health component into something effects can move.
    local function dummy(x, y, hp)
        local e = Entity.new{ kind = 'dummy', x = x, y = y }
        e:add(C.Health{ hp = hp or 100, max = hp or 100 })
        e.radius = 0.3
        Game.attach(e, { authority = true })
        return e
    end

    local function shooter(x, y, angle)
        local e = Entity.new{ kind = 'shooter', x = x, y = y }
        e.angle = angle or 0
        e.radius = 0.24
        return e
    end

    ---------------------------------------------------------------------
    t.describe('a weapon spec is validated and reports rather than raises')

    t.ok(Weapons.define('pistol', {
        damage = 12, magazine = 12, reserve = 60,
        fireInterval = 0.15, reloadTime = 1.0, range = 32,
    }), 'a plain hitscan weapon compiles')

    local bad, why = Weapons.compile({ kind = 'laser' })
    t.ok(bad == nil, 'an unknown weapon kind is refused')
    t.ok(why and why:find('unknown weapon kind'), 'and says so', why)

    bad, why = Weapons.compile({ magazine = 0 })
    t.ok(bad == nil, 'a magazine of zero is refused')

    bad, why = Weapons.compile({ damage = 'twelve' })
    t.ok(bad == nil, 'a damage that is not a number is refused rather than defaulted')
    t.ok(why and why:find('damage'), 'and names the field', why)

    bad, why = Weapons.compile({ damage = 0 / 0 })
    t.ok(bad == nil, 'a NaN damage is refused before it can reach an attribute')

    bad, why = Weapons.compile({ kind = 'projectile' })
    t.ok(bad == nil, 'a projectile weapon with no projectile table is refused')

    bad, why = Weapons.compile({ ammoPerShot = 99, magazine = 10 })
    t.ok(bad == nil, 'a shot that costs more than the magazine holds is refused')

    bad, why = Weapons.compile({ spread = 4 })
    t.ok(bad == nil, 'a spread wider than pi is refused')

    t.eq(Weapons.compile({ fireInterval = 0.15 }).fireInterval, 0.15,
         'a valid interval survives compilation')

    ---------------------------------------------------------------------
    t.describe('equipping adopts the existing weapon component')

    local declared = {}
    for _, f in ipairs(C.Weapon.netFields) do declared[f] = true end
    t.ok(declared.ammo, 'the original ammo field is untouched')
    t.ok(declared.reserve, 'reserve was declared, so it replicates and saves')
    t.ok(declared.reloadRemaining, 'and so was reloadRemaining')
    t.ok(declared.id, 'and the equipped weapon id')

    local p = shooter(2.5, 2.5, 0)
    local state = Weapons.equip(p, 'pistol')
    t.ok(state ~= nil, 'equip returns the weapon state')
    t.eq(p.components.weapon, state, 'and it is the entity\'s own weapon component')
    t.eq(state.id, 'pistol', 'the weapon is recorded')
    t.eq(state.ammo, 12, 'the magazine starts full')
    t.eq(state.reserve, 60, 'and the reserve is the definition\'s')
    t.eq(Weapons.equipped(p), 'pistol', 'equipped() answers')

    local nope, reason = Weapons.equip(p, 'railgun')
    t.ok(nope == nil, 'an unknown weapon cannot be equipped')
    t.ok(reason and reason:find('unknown weapon'), 'and says which', reason)

    ---------------------------------------------------------------------
    t.describe('THE FIRE RATE IS ENFORCED IN TICKS, NOT IN INPUTS')

    -- 0.15 s at 60 Hz is nine whole steps: the cooldown is only ever tested on a
    -- step boundary, so an interval that is not a multiple of the step rounds up.
    t.eq(Weapons.intervalTicks('pistol', 60), 9,
         'a 0.15s interval is nine steps at 60 Hz')

    local w = world()
    local target = dummy(8.5, 2.5)
    local ents = { p, target }

    p.x, p.y, p.angle = 2.5, 2.5, 0
    Weapons.equip(p, 'pistol')

    local shot = Weapons.fire(p, { world = w, entities = ents })
    t.ok(shot ~= nil, 'the first shot goes off')
    t.eq(shot.result, 'hit', 'and hits the dummy in front of it')
    t.eq(p.components.weapon.ammo, 11, 'and costs one round')

    -- The bug this asserts against: a thousand requests inside one step.
    local refusals, extraShots, cooldownReason = 0, 0, nil
    for _ = 1, 1000 do
        local s, r = Weapons.fire(p, { world = w, entities = ents })
        if s then extraShots = extraShots + 1
        else refusals = refusals + 1; cooldownReason = r end
    end
    t.eq(extraShots, 0, 'a thousand fire requests inside one tick fire nothing more')
    t.eq(refusals, 1000, 'every one of them is refused')
    t.eq(cooldownReason, 'cooldown', 'with the reason a HUD can explain')
    t.eq(p.components.weapon.ammo, 11, 'and not one extra round left the magazine')

    -- Now walk the tick forward and find the exact step the next shot lands on.
    local firedOnStep = nil
    for step = 1, 20 do
        Weapons.tick(p, STEP)
        local s = Weapons.fire(p, { world = w, entities = ents })
        if s and not firedOnStep then firedOnStep = step end
    end
    t.eq(firedOnStep, 9, 'the next shot lands on step nine, not step eight')

    ---------------------------------------------------------------------
    t.describe('a client firing faster than the tick rate still fires at the weapon rate')

    Weapons.define('smg', { damage = 5, magazine = 600, reserve = 0,
                            fireInterval = 0.1, range = 32 })
    local spammer = shooter(2.5, 4.5, 0)
    Weapons.equip(spammer, 'smg')
    local spamEnts = { spammer }
    local spamWorld = world()

    local landed = 0
    for _ = 1, 120 do                                -- two seconds of simulation
        Weapons.tick(spammer, STEP)
        for _ = 1, 50 do                             -- fifty requests every step
            if Weapons.fire(spammer, { world = spamWorld, entities = spamEnts }) then
                landed = landed + 1
            end
        end
    end

    -- The first shot lands on the first step (the weapon starts ready) and one
    -- lands every `intervalTicks` steps after it. Written out rather than
    -- hand-counted, so the assertion still means something if the rate changes.
    local ticksPerShot = Weapons.intervalTicks('smg', 60)
    t.eq(ticksPerShot, 6, '0.1s is six steps at 60 Hz')
    local expected = math.floor((120 - 1) / ticksPerShot) + 1
    t.eq(landed, expected,
         ('6000 requests over 120 ticks produced %d shots'):format(expected))
    t.ok(landed < 6000 / 100, 'which is a tiny fraction of what was asked for')

    ---------------------------------------------------------------------
    t.describe('ammunition runs out, and says so')

    Weapons.define('holdout', { damage = 3, magazine = 2, reserve = 0,
                                fireInterval = 0, reloadTime = 0.5, range = 20 })
    local h = shooter(2.5, 6.5, 0)
    Weapons.equip(h, 'holdout')
    local hEnts, hWorld = { h }, world()

    t.ok(Weapons.fire(h, { world = hWorld, entities = hEnts }), 'first round fires')
    t.ok(Weapons.fire(h, { world = hWorld, entities = hEnts }), 'second round fires')
    local s, r = Weapons.fire(h, { world = hWorld, entities = hEnts })
    t.ok(s == nil, 'the third does not')
    t.eq(r, 'empty', 'because the magazine is empty')
    t.eq(h.components.weapon.ammo, 0, 'and the count is zero, not negative')

    ---------------------------------------------------------------------
    t.describe('reload edge cases')

    Weapons.equip(h, 'holdout', { ammo = 2, reserve = 5 })
    local ok, full = Weapons.reload(h)
    t.ok(not ok, 'reloading a full magazine is refused')
    t.eq(full, 'full', 'with the reason')

    Weapons.equip(h, 'holdout', { ammo = 0, reserve = 0 })
    local ok2, none = Weapons.reload(h)
    t.ok(not ok2, 'reloading with nothing in reserve is refused')
    t.eq(none, 'no reserve', 'with the reason')
    t.eq(h.components.weapon.reloadRemaining, 0, 'and no animation was started')

    Weapons.equip(h, 'holdout', { ammo = 0, reserve = 5 })
    t.ok(Weapons.reload(h), 'a real reload starts')
    t.ok(Weapons.reloading(h), 'and reports itself in progress')
    t.eq(h.components.weapon.ammo, 0, 'the magazine is not filled at the request')
    t.eq(h.components.weapon.reserve, 5, 'and nothing has left the reserve yet')

    local s3, r3 = Weapons.fire(h, { world = hWorld, entities = hEnts })
    t.ok(s3 == nil and r3 == 'reloading', 'firing mid-reload is refused')

    local reloaded, loaded = false, 0
    for _ = 1, 30 do                                  -- 0.5s = 30 steps
        local done, n = Weapons.tick(h, STEP)
        if done then reloaded, loaded = true, n end
    end
    t.ok(reloaded, 'the reload completes on the tick')
    t.eq(loaded, 2, 'moving exactly a magazine\'s worth')
    t.eq(h.components.weapon.ammo, 2, 'the magazine is full')
    t.eq(h.components.weapon.reserve, 3, 'and the reserve paid for it')
    t.ok(not Weapons.reloading(h), 'and the reload is over')

    -- Interrupted: the time is spent, the ammunition is not.
    Weapons.equip(h, 'holdout', { ammo = 0, reserve = 5 })
    Weapons.reload(h)
    for _ = 1, 15 do Weapons.tick(h, STEP) end
    t.ok(Weapons.reloading(h), 'halfway through a reload')
    t.ok(Weapons.cancelReload(h), 'it can be interrupted')
    t.eq(h.components.weapon.ammo, 0, 'the magazine is exactly what it was')
    t.eq(h.components.weapon.reserve, 5, 'and NOT ONE ROUND was consumed')
    t.ok(not Weapons.reloading(h), 'and nothing is in progress')
    t.ok(not Weapons.cancelReload(h), 'cancelling nothing is refused, not silent')

    -- Interrupted reloads do not resume by themselves.
    for _ = 1, 60 do Weapons.tick(h, STEP) end
    t.eq(h.components.weapon.ammo, 0, 'an interrupted reload does not finish later')

    -- A partial reserve fills what it can.
    Weapons.equip(h, 'holdout', { ammo = 0, reserve = 1 })
    Weapons.reload(h)
    for _ = 1, 31 do Weapons.tick(h, STEP) end
    t.eq(h.components.weapon.ammo, 1, 'a partial reserve loads what it has')
    t.eq(h.components.weapon.reserve, 0, 'and empties')

    -- A zero reload time completes on the call, with no separate path.
    Weapons.define('instant', { magazine = 4, reserve = 8, reloadTime = 0,
                                fireInterval = 0 })
    local q = shooter(2.5, 8.5, 0)
    Weapons.equip(q, 'instant', { ammo = 0, reserve = 8 })
    t.ok(Weapons.reload(q), 'a zero reload time reloads')
    t.eq(q.components.weapon.ammo, 4, 'immediately')
    t.eq(q.components.weapon.reserve, 4, 'taking from the reserve')

    ---------------------------------------------------------------------
    t.describe('DAMAGE ARRIVES AS AN EFFECT, so a resistance actually reduces it')

    Effects.define('kevlar', {
        duration = 'infinite',
        incoming = { { tag = 'damage.type.physical', magnitude = 0.25 } },
    })

    local rw = world()
    local victim = dummy(8.5, 10.5, 500)
    local rifleman = shooter(2.5, 10.5, 0)
    Weapons.define('rifle', { damage = 40, magazine = 30, fireInterval = 0,
                              range = 32, tags = { 'damage.type.physical' } })
    Weapons.equip(rifleman, 'rifle')
    local rEnts = { rifleman, victim }

    local before = Attributes.get(victim, 'health')
    Weapons.fire(rifleman, { world = rw, entities = rEnts })
    local bare = before - Attributes.get(victim, 'health')
    t.near(bare, 40, 1e-9, 'an unprotected hit does the weapon\'s damage')

    t.ok(Effects.apply(victim, 'kevlar'), 'the target puts on armour')
    before = Attributes.get(victim, 'health')
    Weapons.fire(rifleman, { world = rw, entities = rEnts })
    local soaked = before - Attributes.get(victim, 'health')
    t.near(soaked, 10, 1e-9,
           'the SAME shot now does a quarter, because the weapon applied an effect')
    t.ok(soaked < bare, 'a resistance the weapon knows nothing about reduced it')

    -- And the pool soak: armour absorbs before health, again with nothing in
    -- weapons.lua aware that armour exists.
    Effects.removeById(victim, 'kevlar')
    Attributes.grant(victim, 'armourMax', 100)
    Attributes.grant(victim, 'armour', 100)
    local hpBefore = Attributes.get(victim, 'health')
    Weapons.fire(rifleman, { world = rw, entities = rEnts })
    t.eq(Attributes.get(victim, 'health'), hpBefore, 'armour took the whole hit')
    t.near(Attributes.get(victim, 'armour'), 60, 1e-9, 'and lost exactly the damage')

    ---------------------------------------------------------------------
    t.describe('a client cannot resolve its own shot')

    local remote = shooter(2.5, 12.5, 0)
    Game.attach(remote, { authority = false })
    Weapons.equip(remote, 'rifle')
    local rs, rr = Weapons.fire(remote, { world = rw, entities = { remote } })
    t.ok(rs == nil, 'a non-authoritative container refuses to fire')
    t.eq(rr, 'not authoritative', 'and says why')
    t.eq(remote.components.weapon.ammo, 30, 'and no ammunition was spent')

    ---------------------------------------------------------------------
    t.describe('aim is validated before it touches anything')

    local aimer = shooter(2.5, 14.5, 0)
    Weapons.equip(aimer, 'rifle')
    local as, ar = Weapons.fire(aimer, { world = rw, entities = { aimer }, angle = 0 / 0 })
    t.ok(as == nil, 'a NaN aim is refused')
    t.ok(ar and ar:find('aim is unusable'), 'by name', ar)
    t.eq(aimer.angle, 0, 'and the entity\'s angle was not poisoned')
    t.eq(aimer.components.weapon.ammo, 30, 'and no round was spent on it')

    as, ar = Weapons.fire(aimer, { world = rw, entities = { aimer }, angle = math.huge })
    t.ok(as == nil, 'an infinite aim is refused too')
    t.ok(aimer.angle == aimer.angle, 'the angle is still a number')

    t.ok(Weapons.fire(aimer, { world = rw, entities = { aimer }, angle = 1.5 }),
         'a real aim fires')
    t.near(aimer.angle, 1.5, 1e-12, 'and is taken verbatim, because aim is an input')

    ---------------------------------------------------------------------
    t.describe('spread and recoil are deterministic')

    Weapons.define('shotgun', {
        damage = 6, magazine = 8, pellets = 6, spread = 0.25,
        fireInterval = 0, range = 24,
    })

    local function pelletAngles(seed)
        local g = shooter(2.5, 16.5, 0)
        Weapons.equip(g, 'shotgun', { seed = seed })
        local out = {}
        for _ = 1, 3 do
            local sh = Weapons.fire(g, { world = rw, entities = { g } })
            for i = 1, #sh.pellets do out[#out + 1] = sh.pellets[i].angle end
        end
        return out
    end

    local runA = pelletAngles(4242)
    local runB = pelletAngles(4242)
    local runC = pelletAngles(9999)

    t.eq(#runA, 18, 'six pellets over three shots')
    local same, differ = true, false
    for i = 1, #runA do
        if runA[i] ~= runB[i] then same = false end
        if runA[i] ~= runC[i] then differ = true end
    end
    t.ok(same, 'the same seed produces bit-identical pellet angles')
    t.ok(differ, 'and a different seed does not')

    local spreadSeen = false
    for i = 1, #runA do
        if math.abs(runA[i]) > 1e-6 then spreadSeen = true end
    end
    t.ok(spreadSeen, 'the pellets are actually spread, not all on the axis')

    local within = true
    for i = 1, #runA do
        if math.abs(runA[i]) > 0.25 + 1e-9 then within = false end
    end
    t.ok(within, 'and every pellet is inside the declared cone')

    ---------------------------------------------------------------------
    t.describe('recoil accumulates, is capped, and recovers on the tick')

    Weapons.define('chatter', {
        damage = 1, magazine = 100, fireInterval = 0, range = 20,
        spread = 0.01, recoil = 0.05, recoilMax = 0.2, recoilRecovery = 0.5,
        kick = 0.03,
    })
    local ch = shooter(2.5, 18.5, 0)
    Weapons.equip(ch, 'chatter')

    local first = Weapons.fire(ch, { world = rw, entities = { ch } })
    t.near(math.abs(first.kick), 0.03, 1e-12, 'a shot reports an aim kick')
    t.ok(first.kick ~= 0, 'which is not zero')
    t.near(ch.components.weapon.recoil, 0.05, 1e-12, 'and the cone widened')

    for _ = 1, 20 do Weapons.fire(ch, { world = rw, entities = { ch } }) end
    t.near(ch.components.weapon.recoil, 0.2, 1e-12,
           'twenty more shots hit the cap and stop there')

    local wide = Weapons.fire(ch, { world = rw, entities = { ch } })
    t.near(wide.spread, 0.21, 1e-9, 'the shot cone is the base spread plus recoil')

    for _ = 1, 60 do Weapons.tick(ch, STEP) end
    t.near(ch.components.weapon.recoil, 0, 1e-9, 'a second of not firing sheds it all')

    t.eq(ch.angle, 0, 'and recoil never moved the shooter\'s own aim')

    ---------------------------------------------------------------------
    t.describe('what a shot reports')

    local rep = shooter(2.5, 20.5, 0)
    Weapons.equip(rep, 'rifle')
    local wallShot = Weapons.fire(rep, { world = rw, entities = { rep } })
    t.eq(wallShot.result, 'wall', 'a shot into a wall says so')
    t.ok(wallShot.tx ~= nil and wallShot.ty ~= nil, 'and names the tile')
    t.ok(wallShot.dist and wallShot.dist > 0, 'and how far away it was')

    local killTarget = dummy(6.5, 20.5, 10)
    local kEnts = { rep, killTarget }
    local kill = Weapons.fire(rep, { world = rw, entities = kEnts })
    t.eq(kill.result, 'hit', 'a lethal shot hits')
    t.ok(kill.killed, 'and reports the kill')
    t.ok(killTarget.dead, 'and the target is dead')
    t.eq(kill.targetKind, 'dummy', 'naming what it was')

    t.describe('status is answerable from either side of the wire')
    local status = Weapons.status(rep)
    t.eq(status.id, 'rifle', 'status names the weapon')
    t.eq(status.magazine, 30, 'and the magazine size')
    t.ok(not status.reloading, 'and whether it is reloading')

    ---------------------------------------------------------------------
    t.describe('a projectile weapon puts entities into the world')

    Weapons.define('launcher', {
        kind = 'projectile', magazine = 4, reserve = 4, fireInterval = 0.5,
        damage = 20,
        projectile = { kind = 'rocket', speed = 10, radius = 0.2, range = 20 },
    })
    local gunner = shooter(4.5, 4.5, 0)
    Weapons.equip(gunner, 'launcher')
    local pEnts = { gunner }
    local launch = Weapons.fire(gunner, { world = rw, entities = pEnts })
    t.ok(launch ~= nil, 'a projectile weapon fires')
    t.eq(launch.result, 'launched', 'and says what it did')
    t.eq(#launch.projectiles, 1, 'making one projectile')
    t.eq(#pEnts, 2, 'which was added to the entity list it was given')
    t.eq(pEnts[2].kind, 'rocket', 'as a rocket')
    t.ok(Game.projectiles.is(pEnts[2]), 'carrying a projectile component')
    t.eq(gunner.components.weapon.ammo, 3, 'and it cost a round')

    ---------------------------------------------------------------------
    t.describe('weapon state survives a save')

    local State = require('meatray.save.state')

    Entity.archetype('gunner', function(e)
        e:add(C.Weapon{})
        e.radius = 0.24
    end)

    local saveWorld = Worldgen.box(12, 12)
    local keeper = Entity.spawn('gunner', 3.5, 3.5)
    Weapons.equip(keeper, 'pistol', { ammo = 7, reserve = 23 })
    Weapons.reload(keeper)

    local doc = State.capture{ world = saveWorld, entities = { keeper }, savedAt = 1 }
    t.ok(doc ~= nil, 'the world captures')

    local loaded = State.restore(doc)
    t.ok(loaded ~= nil, 'and restores')
    local back = loaded.entities[1]
    t.eq(back:get('weapon').id, 'pistol', 'the equipped weapon survived')
    t.eq(back:get('weapon').ammo, 7, 'and the magazine')
    t.eq(back:get('weapon').reserve, 23, 'and the reserve')
    t.ok(back:get('weapon').reloadRemaining > 0, 'and the reload in progress')

    Game.reset()
    Entity.clearArchetypes()
end
