--[[
    LÖVE configuration, including the headless case.

    A dedicated server draws nothing, so it should not open a window or a GL
    context — on a VPS there is nothing to open one against. LÖVE decides which
    modules exist here, before love.load runs, so the flag has to be read from the
    command line at config time. The `arg` global is available during conf.lua,
    which is what makes this possible without a second executable.

        love .                          the demo, windowed
        love . --server --port 6789     headless dedicated server, no GL context
        love . --browse                 headless LAN server browser, prints and exits
        love . --nettest --connect ...  headless networked assertions

    Verified rather than assumed: with window and graphics off, `love.graphics` is
    nil, `MeatRay.canRender()` is false, and the simulation runs anyway — which is
    the whole point of the headless rule in meatray/sim and meatray/net.
]]

local headless = false
for _, a in ipairs(arg or {}) do
    if a == '--server' or a == '--nettest' or a == '--browse' then headless = true end
end

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

    if headless then
        -- graphics requires window, so both go together. love.event, love.timer
        -- and love.filesystem stay: the server needs a loop, a clock and its map.
        t.modules.window = false
        t.modules.graphics = false
    end
end
