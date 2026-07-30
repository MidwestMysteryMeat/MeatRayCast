--[[
    `love . --bench [--bench-map arena|procedural] [--bench-frames 600]`

    A fixed-camera wall-renderer benchmark. It owns the frame like the editor
    does, draws nothing but the raycaster, and reports draw calls, batched draw
    calls and frame time so a rendering change can be argued from numbers.

    Deliberately not the demo loop: sprites, the HUD, lighting and a moving
    camera all vary frame to frame, and a benchmark whose input moves cannot
    attribute a change to the thing that changed.
]]

local MeatRay = require('meatray')
local Map = require('meatray.sim.map')
local Worldgen = require('meatray.sim.worldgen')

return function(args)
    if not (love and love.graphics) then
        print('the bench needs a window; it cannot run headless')
        love.event.quit(2)
        return
    end

    -- vsync pins every frame to the refresh interval, which would hide the whole
    -- measurement behind it. conf.lua asks for it off on a bench run and this
    -- asks again, and it is worth knowing that on Windows NEITHER WORKS: the
    -- compositor holds a windowed frame at the refresh rate whatever the flag
    -- says, and `getVSync` keeps reporting 1. The reported value is printed
    -- rather than assumed, because a bench that silently measures the monitor is
    -- worse than no bench. `--bench-repeat` below is the answer that does work.
    if love.window and love.window.updateMode then
        love.window.updateMode(love.graphics.getWidth(), love.graphics.getHeight(),
                               { vsync = 0 })
    end
    print(('bench: vsync reported as %s (see the note in bench.lua)'):format(
        tostring(love.window and love.window.getVSync and love.window.getVSync())))
    if love.mouse then
        love.mouse.setRelativeMode(false)
        love.mouse.setVisible(true)
    end

    local which = args.benchMap or 'arena'
    local frames = tonumber(args.benchFrames) or 600
    local warmup = 60

    -- Drawing the same scene N times per frame, because of the vsync note above.
    -- Frame time only means anything once the work in a frame exceeds the
    -- refresh interval; below that every reading is the monitor's. Check the
    -- result: `frame ms/scene * N` must come out comfortably above the refresh
    -- interval, or the number is a floor rather than a measurement. Per-scene
    -- figures are always divided back down by N.
    local repeats = tonumber(args.benchRepeat) or 1
    local shot = args.benchShot

    local world, spawn
    if which == 'arena' then
        local contents = assert(love.filesystem.read('maps/arena.map'), 'no arena map')
        local map = assert(Map.parse(contents), 'arena map did not parse')
        local w, _, sp = Map.toWorld(map)
        world, spawn = w, sp
        MeatRay.raycaster.setTheme(map.theme)
    else
        local spec = { width = 44, height = 44, seed = 12345, doorChance = 0.5, theme = 'dungeon' }
        local w = Worldgen.generate(spec)
        world = w
        spawn = w.spawn or { x = 4.5, y = 4.5 }
        MeatRay.raycaster.setTheme('dungeon')
    end

    MeatRay.raycaster.init{}

    -- The ceiling band only draws when zones exist and the camera is outside all
    -- of them, and it is the one thing in the frame that paints over the fog.
    -- `--bench-ceiling` declares a zone the camera is nowhere near, so that path
    -- is exercised instead of being quietly skipped.
    if args.benchCeiling then
        MeatRay.raycaster.clearCeilingZones()
        MeatRay.raycaster.addCeilingZone(200, 200, 210, 210)
    end

    -- One camera, forever. Angle picked to look across the level rather than
    -- straight into a wall two tiles away.
    local view = MeatRay.raycaster.view(spawn.x, spawn.y, spawn.angle or 0.6)

    local sumDraw, sumBatched, sumRender, sumFrame = 0, 0, 0, 0
    local minRender, maxRender = math.huge, 0
    local counted = 0
    local drawn = 0

    function love.update() end

    function love.draw()
        drawn = drawn + 1

        local t0 = love.timer.getTime()
        for _ = 1, repeats do MeatRay.raycaster.render(view, world) end
        local t1 = love.timer.getTime()

        local stats = love.graphics.getStats()

        if drawn > warmup then
            counted = counted + 1
            sumDraw = sumDraw + stats.drawcalls
            sumBatched = sumBatched + stats.drawcallsbatched
            local ms = (t1 - t0) * 1000
            sumRender = sumRender + ms
            if ms < minRender then minRender = ms end
            if ms > maxRender then maxRender = ms end
            sumFrame = sumFrame + love.timer.getDelta() * 1000
        end

        -- `--bench-shot name` captures the fixed camera and exits, which is how
        -- "the picture did not change" gets asserted rather than eyeballed. The
        -- bench draws the raycaster and nothing else, so there is no HUD and no
        -- hover state to make the comparison depend on where the mouse was.
        if shot and drawn == warmup + 1 then
            love.graphics.captureScreenshot(function(imageData)
                imageData:encode('png', shot .. '.png')
                print(('bench screenshot: %s/%s.png')
                    :format(love.filesystem.getSaveDirectory(), shot))
                love.event.quit(0)
            end)
            return
        end

        if drawn >= warmup + frames then
            local label = args.benchLabel or 'bench'
            local w, h = love.graphics.getDimensions()
            local lines = {
                ('BENCH %s  map=%s  %dx%d  frames=%d  scenes/frame=%d')
                    :format(label, which, w, h, counted, repeats),
                ('  drawcalls/scene        %.1f'):format(sumDraw / counted / repeats),
                ('  drawcallsbatched/scene %.1f'):format(sumBatched / counted / repeats),
                ('  render ms/scene  avg %.3f  min %.3f  max %.3f')
                    :format(sumRender / counted / repeats,
                            minRender / repeats, maxRender / repeats),
                ('  frame ms/scene   avg %.3f  (%.1f scenes/s)')
                    :format(sumFrame / counted / repeats,
                            1000 / (sumFrame / counted / repeats)),
            }
            for _, line in ipairs(lines) do print(line) end
            love.event.quit(0)
        end
    end

    function love.keypressed(key)
        if key == 'escape' then love.event.quit(0) end
    end

    function love.mousepressed() end
    function love.mousemoved() end
    function love.resize() end
end
