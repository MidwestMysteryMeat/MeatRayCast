-- The relay has no window. It runs on a box with a public address, and asking
-- for a graphics context there is how it fails to start on the machine it is
-- actually meant to run on.
function love.conf(t)
    t.identity = 'meatray-relay'
    t.window = nil
    t.modules.window   = false
    t.modules.graphics = false
    t.modules.audio    = false
    t.modules.sound    = false
    t.modules.image    = false
    t.modules.font     = false
    t.modules.joystick = false
    t.modules.mouse    = false
    t.modules.touch    = false
    t.modules.video    = false
    t.modules.physics  = false
end
