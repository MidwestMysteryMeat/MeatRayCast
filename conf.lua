function love.conf(t)
    t.identity = 'meatraycast'
    t.version = '11.4'
    t.console = false

    t.window.title = 'MeatRayCast'
    t.window.width = 960
    t.window.height = 600
    t.window.resizable = true
    t.window.minwidth = 320
    t.window.minheight = 240
    t.window.vsync = 1

    -- The engine generates every texture and plays no audio yet, so most of
    -- LÖVE's subsystems are dead weight here. Turning them off keeps startup
    -- quick and makes the dependency surface honest.
    t.modules.audio = false
    t.modules.sound = false
    t.modules.physics = false
    t.modules.joystick = false
    t.modules.touch = false
    t.modules.video = false
end
