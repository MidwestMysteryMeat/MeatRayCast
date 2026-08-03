--[[
    F8: accessibility — the colourblind remap makes confusable colours
    distinguishable, the intensity scalars clamp and multiply, the flags flip,
    and it all round-trips through a file.
]]

return function(t)
    local A11y = require('meatray.game.a11y')
    local Game = require('meatray.game')

    t.eq(Game.a11y, A11y, 'Game.a11y is the module')

    ---------------------------------------------------------------------
    t.describe('defaults are the do-nothing settings')

    local a = A11y.new()
    t.eq(a:get('colorblind'), 'none', 'no colourblind mode by default')
    t.eq(a:get('flashScale'), 1, 'flashes at full')
    t.eq(a:get('shakeScale'), 1, 'shake at full')
    t.eq(a:subtitlesOn(), false, 'subtitles off')
    t.eq(a:holdIsToggle(), false, 'hold-to-toggle off')

    -- 'none' is the identity transform.
    local r, g, b = a:color(0.3, 0.6, 0.9)
    t.eq(r, 0.3, 'none passes red through')
    t.eq(g, 0.6, 'green')
    t.eq(b, 0.9, 'blue')

    ---------------------------------------------------------------------
    t.describe('the colourblind remap makes red and green distinguishable')

    -- A red-green colourblind player sees pure red and pure green as nearly
    -- the same. After deuteranopia correction their BLUE channels must differ,
    -- which is what lets them be told apart.
    local d = A11y.new()
    d:set('colorblind', 'deuteranopia')
    local _, _, redB   = d:color(1, 0, 0)
    local _, _, greenB = d:color(0, 1, 0)
    t.ok(math.abs(redB - greenB) > 0.2,
         ('red and green get different blue after correction (%.2f vs %.2f)')
             :format(redB, greenB))

    local p = A11y.new()
    p:set('colorblind', 'protanopia')
    local _, _, prB = p:color(1, 0, 0)
    local _, _, pgB = p:color(0, 1, 0)
    t.ok(math.abs(prB - pgB) > 0.2, 'protanopia separates them too')

    -- Tritanopia (blue-yellow): yellow and blue get different red.
    local tr = A11y.new()
    tr:set('colorblind', 'tritanopia')
    local yR = select(1, tr:color(1, 1, 0))     -- yellow
    local bR = select(1, tr:color(0, 0, 1))     -- blue
    t.ok(math.abs(yR - bR) > 0.2, 'tritanopia separates yellow and blue in red')

    -- Every channel stays in range.
    local cr, cg, cb = d:color(1, 0, 0)
    t.ok(cr >= 0 and cr <= 1 and cg >= 0 and cg <= 1 and cb >= 0 and cb <= 1,
         'the remap stays within 0..1')

    -- A colour table round-trips its alpha.
    local out = d:colorTable({ 1, 0, 0, 0.5 })
    t.eq(out[4], 0.5, 'alpha passes through the table transform untouched')

    ---------------------------------------------------------------------
    t.describe('intensity scalars clamp and multiply')

    local s = A11y.new()
    t.eq(s:set('flashScale', 0.3), 0.3, 'flashScale takes')
    t.near(s:flash(1.0), 0.3, 1e-9, 'and dims a flash')
    t.near(s:flash(0.5), 0.15, 1e-9, 'proportionally')
    t.eq(s:set('flashScale', 5), 1, 'over 1 clamps to 1')
    t.eq(s:set('flashScale', -1), 0, 'under 0 clamps to 0')
    t.eq(s:flash(1.0), 0, 'flashScale 0 kills the flash — photosensitivity off')

    t.eq(s:set('shakeScale', 2), 2, 'shake can go to 2 (amplify)')
    t.near(s:shake(0.5), 1.0, 1e-9, 'and doubles')
    t.eq(s:set('shakeScale', 0), 0, 'or to 0')
    t.eq(s:shake(1), 0, 'no shake at all')

    t.eq(select(2, s:set('colorblind', 'nonsense')), 'unknown colourblind mode',
         'a bad mode is refused')

    ---------------------------------------------------------------------
    t.describe('flags flip')

    local f = A11y.new()
    f:set('subtitles', true)
    t.eq(f:subtitlesOn(), true, 'subtitles on')
    f:set('holdToToggle', true)
    t.eq(f:holdIsToggle(), true, 'hold-to-toggle on')

    ---------------------------------------------------------------------
    t.describe('menu rows and menuSet')

    local m = A11y.new()
    local rows = m:menuRows()
    local byId = {}
    for _, row in ipairs(rows) do byId[row.id] = row end
    t.eq(byId['a11y.colorblind'].kind, 'choice', 'colourblind is a choice')
    t.eq(byId['a11y.flashScale'].kind, 'slider', 'flash is a slider')
    t.eq(byId['a11y.subtitles'].kind, 'toggle', 'subtitles a toggle')

    t.eq(m:menuSet('a11y.colorblind', 'tritanopia'), true, 'menuSet applies')
    t.eq(m:get('colorblind'), 'tritanopia', 'and it took')
    t.eq(select(1, m:menuSet('graphics.fov', 90)), false, 'a non-a11y id is refused')

    ---------------------------------------------------------------------
    t.describe('a file round-trips every setting')

    local w = A11y.new()
    w:set('colorblind', 'protanopia')
    w:set('flashScale', 0.4)
    w:set('shakeScale', 1.5)
    w:set('subtitles', true)
    w:set('holdToToggle', true)

    local text = w:serialize()
    local r2 = A11y.new()
    t.eq(r2:deserialize(text), true, 'deserializes')
    t.eq(r2:get('colorblind'), 'protanopia', 'mode survives')
    t.near(r2:get('flashScale'), 0.4, 1e-9, 'flashScale survives')
    t.near(r2:get('shakeScale'), 1.5, 1e-9, 'shakeScale survives')
    t.eq(r2:subtitlesOn(), true, 'subtitles survive')
    t.eq(r2:holdIsToggle(), true, 'hold-to-toggle survives')

    ---------------------------------------------------------------------
    t.describe('storage backend load/save')

    local Storage = require('meatray.save.storage')
    local mem = Storage.memory()
    local sv = A11y.new()
    sv:set('colorblind', 'deuteranopia')
    t.ok(sv:save(mem), 'saves through the backend')
    local ld = A11y.new()
    t.ok(ld:load(mem), 'and loads back')
    t.eq(ld:get('colorblind'), 'deuteranopia', 'the setting came back')
    t.eq(select(1, ld:load(mem, 'nope.cfg')), nil, 'a missing file fails, not crashes')
end
