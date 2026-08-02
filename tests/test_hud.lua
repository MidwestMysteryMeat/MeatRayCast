--[[
    HUD model: flash from pool deltas, indicators, hit marker, bars.
]]

return function(t)
    local Hud  = require('meatray.game.hud')
    local Game = require('meatray.game')

    t.eq(Game.hud, Hud, 'Game.hud is the hud module')

    ---------------------------------------------------------------------
    t.describe('baseline: the first snapshot is not a wound')

    local hud = Hud.new()
    hud:update(0, { hp = 40, hpMax = 100 })
    t.eq(hud:flashStrength(), 0, 'loading at 40 hp does not flash')
    t.eq(hud:healStrength(), 0, 'nor glow')

    ---------------------------------------------------------------------
    t.describe('damage flash from an hp drop')

    hud:update(0, { hp = 25, hpMax = 100 })
    local f = hud:flashStrength()
    t.ok(f > 0, 'losing hp flashes')
    t.ok(f <= 1, 'flash is clamped')

    -- 15 lost of 100 at flashScale 0.35 is a partial flash, not a full one.
    t.ok(f < 1, 'chip damage does not saturate')

    hud:update(0.2, { hp = 25, hpMax = 100 })
    t.ok(hud:flashStrength() < f, 'flash decays with dt')
    hud:update(10, { hp = 25, hpMax = 100 })
    t.eq(hud:flashStrength(), 0, 'flash reaches zero')

    -- A huge single hit saturates.
    local big = Hud.new()
    big:update(0, { hp = 100, hpMax = 100 })
    big:update(0, { hp = 10, hpMax = 100 })
    t.eq(big:flashStrength(), 1, 'a 90-point hit is a full flash')

    ---------------------------------------------------------------------
    t.describe('heal glow from an hp rise')

    hud:update(0, { hp = 60, hpMax = 100 })
    t.ok(hud:healStrength() > 0, 'healing glows')
    t.eq(hud:flashStrength(), 0, 'healing does not flash')
    hud:update(10, { hp = 60, hpMax = 100 })
    t.eq(hud:healStrength(), 0, 'glow decays to zero')

    ---------------------------------------------------------------------
    t.describe('armour losses flash at half weight')

    local soak = Hud.new()
    soak:update(0, { hp = 100, hpMax = 100, armour = 50, armourMax = 50 })
    soak:update(0, { hp = 100, hpMax = 100, armour = 15, armourMax = 50 })
    local soaked = soak:flashStrength()
    t.ok(soaked > 0, 'a fully soaked hit still flashes')

    local bare = Hud.new()
    bare:update(0, { hp = 100, hpMax = 100 })
    bare:update(0, { hp = 65, hpMax = 100 })
    t.ok(soaked < bare:flashStrength(), 'soaked reads softer than bare')

    ---------------------------------------------------------------------
    t.describe('hit marker')

    t.eq(hud:hitStrength(), 0, 'quiet until confirmed')
    hud:hitConfirmed()
    local h1 = hud:hitStrength()
    t.ok(h1 > 0, 'confirmed hit shows')
    hud:hitConfirmed()
    t.ok(hud:hitStrength() > h1, 'pellets stack')
    t.ok(hud:hitStrength() <= 1, 'and clamp')
    hud:update(10, { hp = 60, hpMax = 100 })
    t.eq(hud:hitStrength(), 0, 'marker decays')

    ---------------------------------------------------------------------
    t.describe('directional indicators')

    local d = Hud.new()
    d:update(0, { hp = 100, hpMax = 100 })

    -- Player at origin facing +x (angle 0); source dead ahead.
    local ahead = d:damageFrom(5, 0, 0, 0, 0)
    t.ok(math.abs(ahead.angle) < 1e-9, 'dead ahead is angle 0')

    -- Source directly behind resolves to pi, not -pi and not 3pi.
    local behind = d:damageFrom(-5, 0, 0, 0, 0)
    t.ok(math.abs(math.abs(behind.angle) - math.pi) < 1e-9, 'behind is pi')

    -- Facing the source cancels its bearing.
    local faced = d:damageFrom(0, 5, 0, 0, math.pi / 2)
    t.ok(math.abs(faced.angle) < 1e-9, 'facing the source reads ahead')

    local list = d:indicators()
    t.eq(#list, 3, 'three indicators live')
    t.ok(list[1].strength > 0 and list[1].strength <= 1, 'strength in range')

    d:update(0.7, { hp = 100, hpMax = 100 })
    t.ok(d:indicators()[1].strength < 1, 'indicators fade')
    d:update(10, { hp = 100, hpMax = 100 })
    t.eq(#d:indicators(), 0, 'indicators expire')

    t.eq(d:damageFrom(nil, 1, 2, 3), nil, 'garbage coordinates refuse')

    for i = 1, 20 do d:damageFrom(i, i, 0, 0, 0) end
    t.eq(#d:indicators(), 8, 'the pile is capped')

    ---------------------------------------------------------------------
    t.describe('low health')

    local low = Hud.new()
    low:update(0, { hp = 100, hpMax = 100 })
    t.eq(low:isLowHealth(), false, 'full is not low')
    t.eq(low:lowPulse(0.3), 0, 'no pulse while healthy')

    low:update(0, { hp = 25, hpMax = 100 })
    t.eq(low:isLowHealth(), true, '25% is low')
    local p = low:lowPulse(0.31)
    t.ok(p >= 0 and p <= 1, 'pulse in range')

    low:update(0, { hp = 0, hpMax = 100 })
    t.eq(low:isLowHealth(), false, 'dead is not "low", it is dead')

    ---------------------------------------------------------------------
    t.describe('bars are draw-ready and absent fields stay absent')

    local b = Hud.new()
    b:update(0, {})
    local rows = b:bars()
    t.eq(rows.hp, nil, 'no hp tracked, no hp row')
    t.eq(rows.armour, nil, 'no armour row')
    t.eq(rows.weapon, nil, 'no weapon row')

    b:update(0, {
        hp = 62.4, hpMax = 100,
        armour = 20, armourMax = 50,
        carried = 34,
        weapon = { id = 'pistol', ammo = 7, magazine = 9,
                   reloading = true, reloadRemaining = 0.3, reloadTotal = 1.2,
                   empty = false },
    })
    rows = b:bars()
    t.eq(rows.hp.value, 62, 'hp rounds for display')
    t.eq(rows.hp.max, 100, 'hp max')
    t.ok(math.abs(rows.hp.fraction - 0.624) < 1e-9, 'hp fraction')
    t.eq(rows.armour.value, 20, 'armour value')
    t.ok(math.abs(rows.armour.fraction - 0.4) < 1e-9, 'armour fraction')
    t.eq(rows.weapon.id, 'pistol', 'weapon id passes through')
    t.eq(rows.weapon.ammo, 7, 'ammo')
    t.eq(rows.weapon.carried, 34, 'reserve ammo joins the weapon row')
    t.eq(rows.weapon.reloading, true, 'reloading flag')
    t.ok(math.abs(rows.weapon.reloadFraction - 0.75) < 1e-9, 'reload progress')

    -- Armour with no declared maximum still shows a number, just no gauge.
    b:update(0, { hp = 50, hpMax = 100, armour = 12 })
    rows = b:bars()
    t.eq(rows.armour.value, 12, 'unbounded armour keeps its number')
    t.eq(rows.armour.fraction, nil, 'but has no fraction to draw')

    ---------------------------------------------------------------------
    t.describe('update survives sparse and missing state')

    local sparse = Hud.new()
    sparse:update(0.016)
    sparse:update(0.016, { hp = 10 })
    sparse:update(0.016, {})
    sparse:update(0.016, { hp = 5 })
    t.ok(sparse:flashStrength() > 0,
         'a drop across a sparse frame still flashes')
end
