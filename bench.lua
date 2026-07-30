--[[
    `love . --bench [--bench-map arena|procedural] [--bench-frames 600]`

    A fixed-camera renderer benchmark. It owns the frame like the editor does,
    draws nothing but the raycaster, and reports draw calls, batched draw calls
    and frame time so a rendering change can be argued from numbers.

    Deliberately not the demo loop: sprites, the HUD, lighting and a moving
    camera all vary frame to frame, and a benchmark whose input moves cannot
    attribute a change to the thing that changed.

    `--bench-flat` turns textured floor and ceiling casting off, which is what
    makes the floor-casting measurement an experiment rather than an anecdote:
    both numbers come out of one build, one binary and one run of the machine,
    so the only difference between them is the thing being measured. Comparing
    two commits instead would also be comparing two compilations, two driver
    states and whatever else the machine was doing at the time.

    `--bench-lights N` attaches a light grid with static sources and N dynamic
    ones, and `--bench-flat-light` then turns the per-pixel floor lighting back
    off, leaving the single sample at the camera. Same experiment, same reason.
    Without `--bench-lights` there is no grid at all and the renderer takes the
    path it took before lighting existed — which is the right default for the
    wall-loop and floor-cast numbers, and useless for pricing lighting, because
    the cost being priced is per dynamic light and there are none.

    A dynamic light is re-declared inside the repeat loop rather than once per
    frame, so every scene pays for a whole frame of lighting. It has to be: the
    grid memoises line-of-sight per frame, and two hundred scenes sharing one
    frame's memo would price the first one and then measure a cache.

    `--bench-ab` measures both light paths in ONE process, alternating frame by
    frame, and prints the difference. Prefer it to two runs of `--bench-flat-light`:
    the same unchanged configuration measured 1.094 ms in one process and 1.337 ms
    in another on this machine, a 22% spread, which is several times the effect
    being looked for.
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

    -- Reported rather than assumed, for the same reason vsync is above: a host
    -- that cannot compile the shader silently falls back to flat bands, and a
    -- bench that did not say so would look like a floor cast costing nothing.
    MeatRay.raycaster.setFloorCasting(not args.benchFlat)
    local castOk, castWhy = MeatRay.raycaster.floorCastAvailable()
    print(('bench: floor casting %s (shader %s)'):format(
        MeatRay.raycaster.floorCasting() and castOk and 'ON' or 'OFF',
        castOk and 'compiled' or ('unavailable: ' .. tostring(castWhy))))

    -- Lighting, and only when asked for. A grid is a whole extra system in the
    -- frame -- a sample per screen column, plus the per-tile resample the floor
    -- texture needs -- and folding it into the default would make every number
    -- this bench has ever printed incomparable with the next one.
    local Lighting = require('meatray.render.lighting')
    local lightCount = tonumber(args.benchLights) or 0
    local lights, torches

    if lightCount > 0 then
        lights = Lighting.new{ world = world, baseLevel = 0.30 }

        -- Static sources spread across the map, so the bake is a real bake and
        -- not an empty one. Placed on open tiles only: a light inside a wall is
        -- occluded from everything and costs nothing, which would flatter the
        -- measurement.
        local placed = 0
        for ty = 2, world.height - 1, 5 do
            for tx = 2, world.width - 1, 5 do
                if not world:isSolid(tx, ty) then
                    lights:addStatic{ x = tx - 0.5, y = ty - 0.5, radius = 7,
                                      color = { 1.0, 0.72, 0.42 }, intensity = 1.1 }
                    placed = placed + 1
                end
            end
        end
        lights:update()

        -- The dynamic half: one torch on the camera and the rest spread around
        -- it. Spread on purpose, and far enough that their footprints only
        -- partly overlap — the floor resample walks the tiles inside a light's
        -- radius and skips a tile a nearer light already wrote, so a cluster of
        -- torches on top of each other costs about as much as one and would make
        -- this number look like it does not scale with the light count when what
        -- it really scales with is the area they cover.
        --
        -- Torch 1 sits on the camera, which is the case the whole change exists
        -- for; the rest ring the middle of the MAP rather than the camera,
        -- because a ring around a spawn point near an edge puts three of its four
        -- lights off the map, where their footprints clip to a subset of the
        -- first one's and the resample count never moves.
        torches = {}
        local midX, midY = world.width / 2, world.height / 2
        local spread = math.min(world.width, world.height) / 3
        for i = 1, lightCount do
            local a = (i - 2) / math.max(1, lightCount - 1) * math.pi * 2
            torches[i] = {
                x = (i == 1) and spawn.x or (midX + math.cos(a) * spread),
                y = (i == 1) and spawn.y or (midY + math.sin(a) * spread),
                radius = 9, color = { 1.0, 0.86, 0.62 }, intensity = 1.3,
            }
        end

        MeatRay.raycaster.setLighting(lights)
        MeatRay.raycaster.setLightTexture(not args.benchFlatLight)

        print(('bench: lighting ON  %d static, %d dynamic, %dx%d grid, per-pixel floor %s')
              :format(placed, lightCount, world.width, world.height,
                      MeatRay.raycaster.lightTexture() and 'ON' or 'OFF'))
    else
        MeatRay.raycaster.setLighting(nil)
        print('bench: lighting OFF (no grid; pass --bench-lights N for one)')
    end

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

    -- `--bench-ab` measures BOTH light paths inside one process, alternating
    -- frame by frame, and it exists because the alternative was measured and
    -- found wanting. Running the same build twice with and without
    -- `--bench-flat-light` gave the one-sample path 1.094 ms in one process and
    -- 1.337 ms in another -- a 22% spread on an unchanged configuration, which
    -- is several times the effect being looked for. Two processes are two driver
    -- states, two thermal windows and two shader compiles.
    --
    -- Alternating whole frames rather than halves of one frame keeps `frame ms`
    -- meaningful: it is the only number here that includes GPU time, because the
    -- CPU-side clock around the render loop returns before the GPU has finished.
    -- Whatever drift is left is shared equally by the two buckets instead of
    -- landing on whichever ran second.
    local ab = args.benchAb and lights ~= nil

    local function newAcc(name)
        return { name = name, draw = 0, batched = 0, render = 0,
                 frame = 0, frames = 0, framesTimed = 0,
                 minR = math.huge, maxR = 0, tiles = 0 }
    end
    local accOn, accOff = newAcc('per-pixel floor light'), newAcc('one sample at the camera')

    local counted = 0
    local drawn = 0
    local prev = nil        -- whose work the next getDelta() will describe

    function love.update() end

    function love.draw()
        drawn = drawn + 1

        -- getDelta() reports the frame that has just ended, which under `--bench-ab`
        -- is the OTHER mode's. Bank it against whoever actually did the work.
        if prev then
            prev.frame = prev.frame + love.timer.getDelta() * 1000
            prev.framesTimed = prev.framesTimed + 1
        end

        local acc
        if ab then
            local on = (drawn % 2 == 0)
            MeatRay.raycaster.setLightTexture(on)
            acc = on and accOn or accOff
        else
            acc = (lights and MeatRay.raycaster.lightTexture()) and accOn or accOff
        end

        local t0 = love.timer.getTime()
        for _ = 1, repeats do
            if lights then
                lights:beginFrame()
                for i = 1, #torches do lights:addDynamic(torches[i]) end
            end
            MeatRay.raycaster.render(view, world)
        end
        local t1 = love.timer.getTime()

        local stats = love.graphics.getStats()

        prev = nil
        if drawn > warmup then
            counted = counted + 1
            acc.frames = acc.frames + 1
            acc.draw = acc.draw + stats.drawcalls
            acc.batched = acc.batched + stats.drawcallsbatched
            local ms = (t1 - t0) * 1000
            acc.render = acc.render + ms
            if ms < acc.minR then acc.minR = ms end
            if ms > acc.maxR then acc.maxR = ms end
            if lights and MeatRay.raycaster.lightTexture() then
                acc.tiles = MeatRay.raycaster.lightTextureReport().tiles
            end
            prev = acc
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
                ('BENCH %s  map=%s  %dx%d  frames=%d  scenes/frame=%d  floorcast=%s  lights=%d  mode=%s')
                    :format(label, which, w, h, counted, repeats,
                            MeatRay.raycaster.floorCasting() and 'on' or 'off',
                            lights and lightCount or 0,
                            (not lights) and 'no-grid'
                                or (ab and 'A/B')
                                or (MeatRay.raycaster.lightTexture()
                                    and 'per-pixel' or 'one-sample')),
            }

            local grid = lights and (world.width * world.height) or 0

            local function report(acc)
                if acc.frames == 0 then return end
                if ab then lines[#lines + 1] = ('  %s'):format(acc.name) end
                local n = acc.frames
                lines[#lines + 1] =
                    ('    drawcalls/scene        %.1f'):format(acc.draw / n / repeats)
                lines[#lines + 1] =
                    ('    drawcallsbatched/scene %.1f'):format(acc.batched / n / repeats)
                lines[#lines + 1] =
                    ('    render ms/scene  avg %.3f  min %.3f  max %.3f')
                        :format(acc.render / n / repeats, acc.minR / repeats,
                                acc.maxR / repeats)
                local fps = acc.frame / math.max(1, acc.framesTimed) / repeats
                lines[#lines + 1] =
                    ('    frame ms/scene   avg %.3f  (%.1f scenes/s, %d frames timed)')
                        :format(fps, 1000 / fps, acc.framesTimed)
                -- What the floor lighting actually had to look at, so the cost
                -- above can be attributed rather than guessed at. `tiles` is how
                -- many light-grid cells a dynamic light forced a resample of, and
                -- the grid is how many there are in total: the ratio is what a
                -- full per-frame resample of the whole map would have cost.
                if acc.tiles > 0 and grid > 0 then
                    lines[#lines + 1] =
                        ('    light grid       %d of %d tiles resampled/scene (%.0f%%)')
                            :format(acc.tiles, grid, acc.tiles / grid * 100)
                end
            end

            report(accOff)
            report(accOn)

            if ab and accOn.framesTimed > 0 and accOff.framesTimed > 0 then
                local a = accOff.frame / accOff.framesTimed / repeats
                local b = accOn.frame / accOn.framesTimed / repeats
                lines[#lines + 1] =
                    ('  DELTA  per-pixel floor light costs %+.3f ms/scene (%+.1f%%)')
                        :format(b - a, (b - a) / a * 100)
            end

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
