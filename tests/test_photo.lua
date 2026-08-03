--[[
    F10: photo / free-cam. The camera detaches without jumping, flies free of
    walls relative to its own facing, clamps pitch and FOV, hides the HUD, asks
    the sim to freeze, and produces a pose only while active.
]]

return function(t)
    local Photo = require('meatray.game.photo')
    local Game = require('meatray.game')

    t.eq(Game.photo, Photo, 'Game.photo is the module')

    ---------------------------------------------------------------------
    t.describe('inactive by default, no pose, no pause')

    local c = Photo.new{}
    t.eq(c:isActive(), false, 'starts inactive')
    t.eq(c:pose(), nil, 'no pose while inactive')
    t.eq(c:pausesSim(), false, 'does not pause while inactive')
    -- input while inactive is inert
    c:pan(1, 1, 0, 0)
    c:look(1, 1)
    t.eq(c:pose(), nil, 'still no pose after ignored input')

    ---------------------------------------------------------------------
    t.describe('entering seeds from the current view without jumping')

    c:enter{ x = 5, y = 6, angle = 0, storey = 2, z = 0.5 }
    t.eq(c:isActive(), true, 'active after enter')
    t.eq(c:pausesSim(), true, 'freezes the sim by default')
    local p = c:pose()
    t.eq(p.x, 5, 'seeded x'); t.eq(p.y, 6, 'seeded y')
    t.eq(p.angle, 0, 'seeded angle'); t.eq(p.storey, 2, 'seeded storey')
    t.eq(p.z, 0.5, 'seeded z')
    t.eq(p.mode, 'photo', 'pose is tagged photo')

    ---------------------------------------------------------------------
    t.describe('forward flies along the facing, free of walls')

    -- angle 0 = +x. One second of full forward at speed 4 -> +4 in x.
    c:pan(1, 1, 0, 0)
    local p2 = c:pose()
    t.ok(math.abs(p2.x - 9) < 1e-9, 'flew +4 in x')
    t.ok(math.abs(p2.y - 6) < 1e-9, 'y unchanged going straight')

    -- strafe is to the right of facing (+90°): at yaw 0 that is +y.
    c:pan(1, 0, 1, 0)
    t.ok(math.abs(c:pose().y - 10) < 1e-9, 'strafed +4 in y')

    -- rise moves z only.
    c:pan(1, 0, 0, 1)
    t.ok(math.abs(c:pose().z - 4.5) < 1e-9, 'rose in z')

    ---------------------------------------------------------------------
    t.describe('the fast modifier multiplies speed')

    local f = Photo.new{ moveSpeed = 2, fastMul = 5 }
    f:enter{ x = 0, y = 0, angle = 0 }
    f:pan(1, 1, 0, 0, { fast = true })
    t.ok(math.abs(f:pose().x - 10) < 1e-9, '2 * 5 = 10 tiles under fast')

    ---------------------------------------------------------------------
    t.describe('pitch is clamped, yaw wraps')

    local a = Photo.new{ maxPitch = 0.9 }
    a:enter{ x = 0, y = 0, angle = 0 }
    a:look(0, 10)
    t.ok(math.abs(a:pose().pitch - 0.9) < 1e-9, 'pitch clamps up')
    a:look(0, -100)
    t.ok(math.abs(a:pose().pitch + 0.9) < 1e-9, 'pitch clamps down')
    a:look(2 * math.pi + 0.25, 0)
    t.ok(a:pose().angle < 2 * math.pi, 'yaw wraps into [0, 2pi)')

    ---------------------------------------------------------------------
    t.describe('FOV clamps to its range')

    local l = Photo.new{ fov = 1.0, fovRange = { 0.6, 1.8 } }
    l:enter{}
    t.eq(l:adjustFov(5), 1.8, 'FOV clamps to max')
    t.eq(l:adjustFov(-5), 0.6, 'FOV clamps to min')
    t.eq(l:pose().fov, 0.6, 'pose carries the FOV')

    ---------------------------------------------------------------------
    t.describe('HUD hide toggles and only reports while active')

    local h = Photo.new{}
    t.eq(h:hudIsHidden(), false, 'not hidden while inactive')
    h:enter{}
    t.eq(h:toggleHud(), true, 'toggle on')
    t.eq(h:hudIsHidden(), true, 'hidden while active')
    t.eq(h:pose().hudHidden, true, 'pose reflects the hidden HUD')
    h:exit()
    t.eq(h:hudIsHidden(), false, 'not reported hidden once inactive')
    t.eq(h:pose(), nil, 'no pose after exit')

    ---------------------------------------------------------------------
    t.describe('toggle enters then exits')

    local g = Photo.new{}
    t.eq(g:toggle{ x = 1, y = 2, angle = 0 }, true, 'toggle enters')
    t.eq(g:pose().x, 1, 'seeded on toggle-enter')
    t.eq(g:toggle{}, false, 'toggle exits')
    t.eq(g:pose(), nil, 'no pose after toggle-exit')

    ---------------------------------------------------------------------
    t.describe('freezeSim=false films a live scene')

    local live = Photo.new{ freezeSim = false }
    live:enter{}
    t.eq(live:isActive(), true, 'active')
    t.eq(live:pausesSim(), false, 'but does not freeze the sim')

    ---------------------------------------------------------------------
    t.describe('NaN input cannot corrupt the pose')

    local n = Photo.new{}
    n:enter{ x = 0, y = 0, angle = 0 }
    n:pan(0 / 0, 0 / 0, 0, 0)
    local np = n:pose()
    t.ok(np.x == np.x, 'x stayed a number, not NaN')
end
