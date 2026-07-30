--[[
    Distance to volume, and bearing to stereo pan.

    Both of these fail silently. A rolloff that approaches zero without reaching
    it leaves every sound in the level mixed in forever — the symptom is a muddy
    mix and a voice count that only goes up, never a crash. A pan with the wrong
    sign puts the monster on your left when it is on your right, which no
    screenshot will ever show and which nobody trusts their own ears about.

    The pan sign is checked against the renderer's own definition of "right": the
    camera plane is built as (-dirY, dirX), so a source is to the viewer's right
    exactly when the 2D cross product of facing and delta is positive. Audio and
    video agreeing about which side something is on is the whole point.
]]

return function(t)
    local Spatial = require('meatray.asset.spatial')

    ---------------------------------------------------------------------
    t.describe('distance to volume')

    local opts = { ref = 1, max = 10, rolloff = 1, curve = 'inverse' }

    t.eq(Spatial.volume(0, opts), 1, 'at the listener, full volume')
    t.eq(Spatial.volume(0.5, opts), 1, 'inside the reference distance, still full')
    t.eq(Spatial.volume(1, opts), 1, 'exactly at the reference distance, still full')

    -- Reaching true zero is load-bearing: it is what lets a caller skip a distant
    -- source entirely rather than starting a silent voice that occupies the mixer.
    t.eq(Spatial.volume(10, opts), 0, 'exactly at the cutoff, silent')
    t.eq(Spatial.volume(11, opts), 0, 'beyond the cutoff, silent')
    t.eq(Spatial.volume(1e6, opts), 0, 'and a long way beyond it, still exactly zero')
    t.ok(not Spatial.audible(10, opts), 'audible() agrees at the cutoff')
    t.ok(Spatial.audible(2, opts), 'and inside it')

    local mid = Spatial.volume(5, opts)
    t.ok(mid > 0 and mid < 1, 'in between, something in between', mid)

    t.describe('and it only ever falls')
    local previous = 2
    local monotonic = true
    for step = 0, 120 do
        local d = step * 0.1
        local v = Spatial.volume(d, opts)
        if v > previous + 1e-12 then monotonic = false end
        previous = v
    end
    t.ok(monotonic, 'volume never rises as distance grows')

    t.describe('the linear curve is a straight line')
    local linear = { ref = 0, max = 10, curve = 'linear' }
    t.near(Spatial.volume(0, linear), 1, 1e-9, 'full at zero')
    t.near(Spatial.volume(5, linear), 0.5, 1e-9, 'half way out is half volume')
    t.near(Spatial.volume(2.5, linear), 0.75, 1e-9, 'and a quarter out is three quarters')
    t.eq(Spatial.volume(10, linear), 0, 'reaching zero at the cutoff')

    t.describe('rolloff sharpens the inverse curve')
    local gentle = Spatial.volume(4, { ref = 1, max = 20, rolloff = 0.2 })
    local steep = Spatial.volume(4, { ref = 1, max = 20, rolloff = 4 })
    t.ok(gentle > steep, 'a higher rolloff is quieter at the same distance',
         ('%f vs %f'):format(gentle, steep))

    t.describe('degenerate and hostile inputs')
    t.eq(Spatial.volume(-5, opts), 1, 'a negative distance clamps to zero distance')
    t.eq(Spatial.volume(nil, opts), 1, 'a nil distance is treated as zero, not an error')

    -- max <= ref is a misconfiguration. The important thing is that it does not
    -- produce a division by zero: a NaN gain reaches OpenAL as an invalid value
    -- and silences the whole mixer, not just the one sound.
    local degenerate = { ref = 5, max = 5 }
    t.eq(Spatial.volume(4, degenerate), 1, 'inside a zero-width range, audible')
    t.eq(Spatial.volume(6, degenerate), 0, 'outside it, silent')
    local inverted = Spatial.volume(3, { ref = 10, max = 2 })
    t.ok(inverted == inverted, 'an inverted range does not produce NaN')

    t.describe('the defaults are usable without being told anything')
    t.eq(Spatial.volume(0), 1, 'at the listener')
    t.eq(Spatial.volume(1000), 0, 'and silent a long way off')
    t.ok(Spatial.volume(5) > 0, 'with a few tiles still audible')

    ---------------------------------------------------------------------
    t.describe('bearing to pan')

    -- Facing +x. In this engine y grows downward, so +y is the viewer's right,
    -- exactly as the camera plane puts it on the right of the screen.
    t.near(Spatial.pan(0, 0, 0, 5, 0), 0, 1e-9, 'straight ahead is centred')
    t.near(Spatial.pan(0, 0, 0, 0, 5), 1, 1e-9, 'a source at +y is hard right')
    t.near(Spatial.pan(0, 0, 0, 0, -5), -1, 1e-9, 'a source at -y is hard left')
    t.near(Spatial.pan(0, 0, 0, -5, 0), 0, 1e-9, 'directly behind is centred, not flipped')

    -- Behind-and-to-one-side must keep the side. A pan that mirrors behind the
    -- listener makes a source walking past you snap from one ear to the other.
    t.ok(Spatial.pan(0, 0, 0, -5, 5) > 0, 'behind and to the right stays right')
    t.ok(Spatial.pan(0, 0, 0, -5, -5) < 0, 'behind and to the left stays left')

    t.near(Spatial.pan(0, 0, 0, 5, 5), math.sqrt(0.5), 1e-9,
           'forty-five degrees off is partway across')

    t.describe('the listener turning moves the image')
    -- Turning to face +y puts a source at +y straight ahead, and one at +x on the
    -- left. Rotating the listener rather than the source is the case that catches
    -- a pan computed from world axes instead of from facing.
    local half = math.pi / 2
    t.near(Spatial.pan(0, 0, half, 0, 5), 0, 1e-9, 'facing +y, a source at +y is ahead')
    t.near(Spatial.pan(0, 0, half, 5, 0), -1, 1e-9, 'and a source at +x is hard left')
    t.near(Spatial.pan(0, 0, half, -5, 0), 1, 1e-9, 'while one at -x is hard right')

    t.describe('pan is bounded and safe')
    local bounded = true
    for step = 0, 359 do
        local a = math.rad(step)
        for _, dist in ipairs({ 0.001, 1, 100 }) do
            local p = Spatial.pan(3, 4, a, 3 + dist, 4 + dist * 0.5)
            if p < -1 or p > 1 or p ~= p then bounded = false end
        end
    end
    t.ok(bounded, 'pan stays within -1..1 for every facing and distance')

    t.eq(Spatial.pan(2, 2, 0, 2, 2), 0, 'a source exactly on the listener is centred')
    t.eq(Spatial.pan(0, 0, 0, 0, 5, { panWidth = 0 }), 0, 'panWidth zero disables panning')
    t.near(Spatial.pan(0, 0, 0, 0, 5, { panWidth = 0.5 }), 0.5, 1e-9,
           'and a narrower width pulls the image toward the centre')

    t.describe('the listener is offset, not assumed to be at the origin')
    t.near(Spatial.pan(10, 10, 0, 10, 15), 1, 1e-9, 'a source right of an offset listener')
    t.near(Spatial.pan(10, 10, 0, 10, 5), -1, 1e-9, 'and one to its left')

    ---------------------------------------------------------------------
    t.describe('distance')
    t.near(Spatial.distance(0, 0, 3, 4), 5, 1e-9, 'the usual triangle')
    t.eq(Spatial.distance(2, 2, 2, 2), 0, 'and zero for the same point')

    ---------------------------------------------------------------------
    t.describe('mixing both at once')

    local listener = { x = 0, y = 0, angle = 0 }
    local volume, pan, dist = Spatial.mix(listener, 0, 3, { ref = 1, max = 10 })
    t.near(dist, 3, 1e-9, 'the distance comes back too')
    t.ok(volume > 0 and volume < 1, 'attenuated but audible', volume)
    t.near(pan, 1, 1e-9, 'and panned right')

    local far
    far, pan, dist = Spatial.mix(listener, 100, 0, { ref = 1, max = 10 })
    t.eq(far, 0, 'a distant source mixes to silence')
    t.near(dist, 100, 1e-9, 'with its true distance reported')

    -- A sound triggered before the camera exists must be unremarkable, not fatal.
    local nv, np, nd = Spatial.mix(nil, 5, 5)
    t.eq(nv, 1, 'with no listener, full volume')
    t.eq(np, 0, 'centred')
    t.eq(nd, 0, 'and no distance')

    ---------------------------------------------------------------------
    t.describe('pan to an OpenAL direction')

    local ex, ey, ez = Spatial.toEar(0)
    t.near(ex, 0, 1e-9, 'centre is straight ahead in x')
    t.eq(ey, 0, 'never above or below')
    t.near(ez, -1, 1e-9, 'and down the listener axis, which is -z')

    ex, ey, ez = Spatial.toEar(1)
    t.near(ex, 1, 1e-9, 'hard right is fully to the right')
    t.near(ez, 0, 1e-9, 'and no longer ahead at all')

    ex, ey, ez = Spatial.toEar(-1)
    t.near(ex, -1, 1e-9, 'hard left mirrors it')

    local unit = true
    for step = -10, 10 do
        local p = step / 10
        local x, y, z = Spatial.toEar(p)
        if math.abs(math.sqrt(x * x + y * y + z * z) - 1) > 1e-9 then unit = false end
    end
    t.ok(unit, 'every ear direction is a unit vector, so distance is never implied twice')

    local overX = Spatial.toEar(5)
    local underX = Spatial.toEar(-5)
    t.near(overX, 1, 1e-9, 'an out-of-range pan clamps rather than escaping')
    t.near(underX, -1, 1e-9, 'in both directions')
end
