-- The relay check draws nothing. It is an acceptance test that happens to need
-- LÖVE's bundled lua-enet, and asking for a graphics context would stop it
-- running on the headless box where a relay actually lives.
function love.conf(t)
    t.identity = 'meatray-relaycheck'
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
