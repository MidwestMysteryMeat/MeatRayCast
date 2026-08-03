--[[
    C28: screen effects — flashes that ramp/hold/fade and vanish, holds that
    stay until released, independent layers, and a cap that keeps the big
    effect over the small ones.
]]

return function(t)
    local ScreenFX = require('meatray.game.screenfx')
    local Game = require('meatray.game')

    t.eq(Game.screenfx, ScreenFX, 'Game.screenfx is the module')

    ---------------------------------------------------------------------
    t.describe('a flash ramps in, holds, fades out, then is gone')

    local fx = ScreenFX.new()
    fx:flash({ 1, 1, 1 }, { peak = 1, inTime = 0.1, hold = 0.2, out = 0.5 })

    -- Mid ramp-in.
    fx:update(0.05)
    local l = fx:layers()
    t.eq(#l, 1, 'one layer showing')
    t.near(l[1].alpha, 0.5, 1e-6, 'half-way up the ramp')
    t.eq(l[1].color[1], 1, 'white')

    -- At peak (past ramp, within hold).
    fx:update(0.15)                      -- t = 0.2, in the hold
    t.near(fx:layers()[1].alpha, 1, 1e-6, 'full at peak')

    -- Fading.
    fx:update(0.35)                      -- t = 0.55, 0.25 into the 0.5 fade
    t.ok(fx:layers()[1].alpha < 1 and fx:layers()[1].alpha > 0, 'fading')

    -- Gone.
    fx:update(1.0)
    t.eq(#fx:layers(), 0, 'and then nothing')

    ---------------------------------------------------------------------
    t.describe('a hold stays up until released')

    local h = ScreenFX.new()
    h:hold('water', { 0.2, 0.4, 0.8 }, { peak = 0.4, inTime = 0.1 })
    h:update(0.05)
    t.near(h:layers()[1].alpha, 0.2, 1e-6, 'ramping in')
    h:update(1.0)                        -- long past the ramp
    t.near(h:layers()[1].alpha, 0.4, 1e-6, 'then holds at peak, indefinitely')
    t.eq(h:isHeld('water'), true, 'and reports itself held')

    -- Re-asserting every tick (the "am I still in water" pattern) does not
    -- stack — it is still one layer.
    for _ = 1, 10 do h:hold('water', { 0.2, 0.4, 0.8 }, { peak = 0.4 }) end
    local flashes, holds = h:count()
    t.eq(holds, 1, 're-asserting a hold keeps it one layer')

    h:release('water')
    t.eq(h:isHeld('water'), false, 'released stops counting as held')
    t.ok(h:layers()[1] and h:layers()[1].alpha > 0, 'but lingers, fading')
    h:update(1.0)
    t.eq(#h:layers(), 0, 'and then clears')

    -- Re-asserting a releasing hold cancels the fade.
    h:hold('lava', { 0.9, 0.2, 0.1 }, { peak = 0.3, inTime = 0 })
    h:update(0.5)
    h:release('lava')
    h:hold('lava', { 0.9, 0.2, 0.1 }, { peak = 0.3 })   -- back in it before it faded
    t.eq(h:isHeld('lava'), true, 'stepping back into the lava re-holds it')

    ---------------------------------------------------------------------
    t.describe('layers are independent and additive')

    local m = ScreenFX.new()
    m:hold('water', { 0.2, 0.4, 0.8 }, { peak = 0.3, inTime = 0 })
    m:flash({ 0.3, 0.9, 0.4 }, { peak = 0.5, inTime = 0 })   -- pickup blip over it
    m:update(0.001)
    local layers = m:layers()
    t.eq(#layers, 2, 'both the tint and the blip show')
    -- Holds draw first (the backdrop), flashes over.
    t.near(layers[1].color[3], 0.8, 1e-6, 'the water backdrop is first')
    t.near(layers[2].color[2], 0.9, 1e-6, 'the green blip over it')

    ---------------------------------------------------------------------
    t.describe('style passes through')

    local s = ScreenFX.new()
    s:flash({ 1, 0, 0 }, { peak = 0.5, inTime = 0, style = 'vignette' })
    s:update(0.001)
    t.eq(s:layers()[1].style, 'vignette', 'a vignette flash reports its style')
    s:flash({ 1, 1, 1 }, { peak = 0.5, inTime = 0 })
    s:update(0.001)
    t.eq(s:layers()[2].style, 'fill', 'and the default is a flat fill')

    ---------------------------------------------------------------------
    t.describe('the cap keeps the important flash over the noise')

    local cap = ScreenFX.new{ max = 4 }
    -- Four low-priority blips, then one high-priority white-out, then more
    -- blips: the white-out must survive the cap.
    for _ = 1, 4 do cap:flash({ 0, 1, 0 }, { peak = 0.2, priority = 1 }) end
    cap:flash({ 1, 1, 1 }, { peak = 1, priority = 10 })
    for _ = 1, 4 do cap:flash({ 0, 1, 0 }, { peak = 0.2, priority = 1 }) end

    local kept = select(1, cap:count())
    t.eq(kept, 4, 'never over the cap')
    local hasWhiteout = false
    for _, layer in ipairs(cap:layers()) do
        if layer.color[1] == 1 and layer.color[2] == 1 then hasWhiteout = true end
    end
    cap:update(0.001)
    hasWhiteout = false
    for _, f in ipairs(cap.flashes) do
        if f.priority == 10 then hasWhiteout = true end
    end
    t.eq(hasWhiteout, true, 'the high-priority white-out was not dropped for a blip')

    ---------------------------------------------------------------------
    t.describe('clear and garbage-dt hygiene')

    local g = ScreenFX.new()
    g:flash({ 1, 1, 1 }, { peak = 1, inTime = 0 }); g:hold('x', { 1, 1, 1 }, { inTime = 0 })
    g:update(0.01)                       -- establish visibility
    local n0 = #g:layers()
    g:update(-3)                         -- negative dt must not advance time
    t.eq(#g:layers(), n0, 'a negative dt is ignored, nothing expired')
    g:clear()
    t.eq(#g:layers(), 0, 'clear clears everything')
end
