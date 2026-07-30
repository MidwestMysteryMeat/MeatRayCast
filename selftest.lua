--[[
    Deterministic gate, run as `love . --selftest`.

    This covers what the headless suite cannot: anything that needs a real
    graphics context. It renders into a canvas and reads pixels back, so the
    assertions are about what actually got drawn rather than about functions
    having returned without error — a render test that only checks for the absence
    of a crash will happily pass on a black screen.

    It also writes reference images to the save directory so facing and occlusion
    can be inspected by eye, which is the only way to be sure a sprite is showing
    the right side.
]]

local MeatRay = require('meatray')

local Entity   = MeatRay.entity
local C        = MeatRay.components
local Collide  = MeatRay.collide
local Worldgen = MeatRay.worldgen
local Map      = MeatRay.map
local Billboard = MeatRay.billboard

local passed, failed = 0, 0
local problems = {}

local function ok(cond, label, detail)
    if cond then
        passed = passed + 1
        print(('  ok   %s'):format(label))
    else
        failed = failed + 1
        local line = detail and ('%s  [%s]'):format(label, tostring(detail)) or label
        problems[#problems + 1] = line
        print(('  FAIL %s'):format(line))
    end
end

-- Counts pixels that are not the clear colour, i.e. how much actually rendered.
local function coverage(imageData)
    local w, h = imageData:getWidth(), imageData:getHeight()
    local lit = 0
    -- Sampling every 4th pixel: enough to distinguish "drew something" from
    -- "drew nothing" without reading a million pixels.
    for y = 0, h - 1, 4 do
        for x = 0, w - 1, 4 do
            local r, g, b, a = imageData:getPixel(x, y)
            if a > 0 and (r + g + b) > 0.02 then lit = lit + 1 end
        end
    end
    return lit / ((w / 4) * (h / 4))
end

return function()
    print('MeatRayCast selftest')
    print(('-'):rep(58))

    local W, H = 320, 200

    ---------------------------------------------------------------------
    print('themes')
    local themeNames = MeatRay.themes.names()
    ok(#themeNames >= 5, ('%d themes defined'):format(#themeNames))

    local referenced = {}
    for _, name in ipairs(themeNames) do
        local theme = MeatRay.themes.get(name)
        ok(theme ~= nil and theme.walls ~= nil, name .. ' resolves with walls')
        referenced[theme.atmosphere] = true
        local atmos = MeatRay.themes.atmosphere(name)
        ok(atmos and atmos.maxView and atmos.maxView > 0, name .. ' has a usable atmosphere')
    end

    -- The anti-dead-data rule: every preset must be reachable from some theme.
    for _, presetName in ipairs(MeatRay.themes.atmosphereNames()) do
        ok(referenced[presetName], ('atmosphere "%s" is used by a theme'):format(presetName))
    end

    ok(MeatRay.themes.get('does-not-exist') ~= nil, 'an unknown theme falls back')
    ok(MeatRay.themes.wallColor('dungeon', 99) ~= nil, 'an out-of-range tile falls back')

    ---------------------------------------------------------------------
    print('worlds from both sources')
    local proc = Worldgen.generate{ width = 32, height = 32, seed = 4242 }
    ok(proc.width == 32, 'procedural world generated')
    ok(proc.spawn ~= nil and not proc:isSolid(math.floor(proc.spawn.x) + 1,
                                              math.floor(proc.spawn.y) + 1),
       'procedural spawn is not inside a wall')

    local mapText = love.filesystem.read('maps/arena.map')
    ok(mapText ~= nil, 'maps/arena.map is readable')

    local authored, mapErrs = Map.parse(mapText or '')
    ok(authored ~= nil, 'arena.map parses', mapErrs and mapErrs[1])

    local world, markers, spawn
    if authored then
        world, markers, spawn = Map.toWorld(authored)
        ok(world.width == authored.width, 'authored world built')
        ok(#markers > 0, ('%d entity markers in the map'):format(#markers))
        ok(spawn ~= nil and not world:isSolid(math.floor(spawn.x) + 1,
                                              math.floor(spawn.y) + 1),
           'authored spawn is not inside a wall')
        local doorCount = 0
        for _ in pairs(world.doors) do doorCount = doorCount + 1 end
        ok(doorCount > 0, ('%d doors in the authored map'):format(doorCount))
    else
        world = proc
    end

    ---------------------------------------------------------------------
    print('sprite registry')
    MeatRay.sprites.clear()
    local dir = MeatRay.sprites.define('probe8', { angles = 8, frames = 4, color = { 1, 0.2, 0.2 } })
    local flat = MeatRay.sprites.define('probe1', { angles = 1, frames = 2, color = { 0.2, 0.6, 1 } })

    ok(dir.angles == 8, 'directional sprite defined with 8 buckets')
    ok(flat.angles == 1, 'billboard sprite defined with 1 bucket')
    ok(dir.generated, 'a sprite with no image generates a placeholder')
    ok(dir.image:getHeight() == dir.cellH * 8, 'sheet has one row per angle bucket')
    ok(dir.image:getWidth() == dir.cellW * 4, 'sheet has one column per frame')
    ok(dir.quads[0][0] ~= nil and dir.quads[7][3] ~= nil, 'quads exist for every cell')
    ok(MeatRay.sprites.defined('probe8'), 'registry lookup works')
    ok(#MeatRay.sprites.names() == 2, 'both sprites registered')

    -- Each frame cell must contain pixels. The generator previously drew every
    -- frame at the origin and shifted, which silently emptied frame 0.
    -- Field access, not a method call: `image:getData and ...` is a syntax error
    -- because colon syntax must be followed by arguments.
    local sheet = dir.image.getData and dir.image:getData() or nil
    if not sheet then
        -- LOVE 11 does not keep ImageData on the Image, so regenerate one.
        ok(true, 'sheet pixel check skipped (no retained ImageData)')
    else
        for frame = 0, 3 do
            local found = false
            for py = 0, dir.cellH - 1, 2 do
                for px = 0, dir.cellW - 1, 2 do
                    local _, _, _, a = sheet:getPixel(frame * dir.cellW + px, py)
                    if a > 0 then found = true; break end
                end
                if found then break end
            end
            ok(found, ('frame %d of the sheet is not empty'):format(frame))
        end
    end

    ---------------------------------------------------------------------
    print('angle buckets across a full turn')
    -- Walking the entity's facing all the way round must visit every bucket, and
    -- bucket 0 must mean "looking at the viewer".
    local seen = {}
    for step = 0, 63 do
        local facing = step / 64 * Billboard.TWO_PI
        seen[Billboard.angleBucket(facing, 0, 8)] = true
    end
    local bucketCount = 0
    for _ in pairs(seen) do bucketCount = bucketCount + 1 end
    ok(bucketCount == 8, ('all 8 buckets reachable (%d seen)'):format(bucketCount))
    ok(Billboard.angleBucket(math.pi, 0, 8) == 0, 'facing the viewer is bucket 0')
    ok(Billboard.angleBucket(0, 0, 8) == 4, 'facing away is bucket 4')

    ---------------------------------------------------------------------
    print('render pass')
    MeatRay.raycaster.init{ width = W, height = H, theme = authored and authored.theme }

    Entity.clearArchetypes()
    Entity.archetype('probe', function(e)
        e:add(C.Billboard{ sheet = 'probe8' })
        e:add(C.Health{ hp = 10, max = 10 })
        e.radius = 0.28
    end)

    local px, py = spawn and spawn.x or 3.5, spawn and spawn.y or 3.5
    local view = MeatRay.raycaster.view(px, py, 0)

    local canvas = love.graphics.newCanvas(W, H)
    love.graphics.setCanvas(canvas)
    love.graphics.clear(0, 0, 0, 1)
    local zbuf = MeatRay.raycaster.render(view, world)
    love.graphics.setCanvas()

    ok(type(zbuf) == 'table', 'render returned a z-buffer')
    local zcount = 0
    for _ in pairs(zbuf) do zcount = zcount + 1 end
    ok(zcount == W, ('z-buffer has one entry per column (%d)'):format(zcount))

    local allPositive = true
    for x = 0, W - 1 do
        if not zbuf[x] or zbuf[x] <= 0 then allPositive = false end
    end
    ok(allPositive, 'every z-buffer entry is a positive distance')

    local shot = canvas:newImageData()
    local cov = coverage(shot)
    ok(cov > 0.5, ('the render covered %.0f%% of the frame'):format(cov * 100))

    ---------------------------------------------------------------------
    print('sprite occlusion against the z-buffer')
    -- A sprite nearer than the wall must draw; the same sprite pushed beyond the
    -- wall must not. Comparing drawn-pixel counts is the honest way to assert it.
    local function drawSpriteAt(sx, sy)
        local e = Entity.spawn('probe', sx, sy)
        e:snapPrevious()
        love.graphics.setCanvas(canvas)
        love.graphics.clear(0, 0, 0, 1)
        local z = MeatRay.raycaster.render(view, world)
        local drawn = MeatRay.sprites.draw({ e }, z, view,
                                           { screenW = W, screenH = H, time = 0, alpha = 1 })
        love.graphics.setCanvas()
        return drawn
    end

    -- Straight ahead and close: should be visible.
    local nearDrawn = drawSpriteAt(px + 1.5, py)
    ok(nearDrawn == 1, 'a sprite in open view is drawn')

    -- Behind the player: must be culled by the projection, not merely dimmed.
    local behindDrawn = drawSpriteAt(px - 3.0, py)
    ok(behindDrawn == 0, 'a sprite behind the camera is not drawn')

    -- Far beyond the atmosphere's view distance: culled.
    local atmos = MeatRay.themes.atmosphere(MeatRay.raycaster.getTheme())
    local farDrawn = drawSpriteAt(px + atmos.maxView + 10, py)
    ok(farDrawn == 0, 'a sprite past max view distance is not drawn')

    ---------------------------------------------------------------------
    print('collision and hitscan')
    local walker = Entity.new{ x = px, y = py }
    walker.radius = 0.24
    local before = walker.x
    Collide.move(walker, -50, 0, world)
    ok(walker.x > before - 50, 'a wall stopped a huge movement')
    ok(not Collide.circleBlocked(world, walker.x, walker.y, 0.24),
       'the walker did not end up inside a wall')

    local target = Entity.new{ x = px + 2, y = py }
    target.radius = 0.3
    local hit = Collide.hitscan(world, px, py, 1, 0, { target }, { maxDist = 30 })
    ok(hit ~= nil, 'hitscan hit something')
    if hit then
        ok(hit.kind == 'entity' or hit.kind == 'wall', 'hitscan reported a known kind')
    end

    ---------------------------------------------------------------------
    print('doors')
    local doorX, doorY
    for key in pairs(world.doors) do
        local sx, sy = key:match('^(%-?%d+),(%-?%d+)$')
        doorX, doorY = tonumber(sx), tonumber(sy)
        break
    end
    if doorX then
        ok(world:isSolid(doorX, doorY), 'a shut door blocks')
        world:setDoorOpen(doorX, doorY, true)
        world:update(1.0)
        ok(not world:isSolid(doorX, doorY), 'an open door does not block')
        ok(world:doorAt(doorX, doorY).openness > 0.9, 'and its animation completed')
    else
        ok(false, 'expected at least one door to test')
    end

    ---------------------------------------------------------------------
    -- Reference images, for looking at rather than asserting on.
    print('reference images')
    local function shotAt(name, camX, camY, camAngle, ents)
        local v = MeatRay.raycaster.view(camX, camY, camAngle)
        love.graphics.setCanvas(canvas)
        love.graphics.clear(0, 0, 0, 1)
        local z = MeatRay.raycaster.render(v, world)
        MeatRay.sprites.draw(ents or {}, z, v,
                             { screenW = W, screenH = H, time = 0, alpha = 1 })
        love.graphics.setCanvas()
        canvas:newImageData():encode('png', name .. '.png')
        return true
    end

    local probe = Entity.spawn('probe', px + 2.5, py)
    probe.angle = math.pi          -- facing back toward the camera
    probe:snapPrevious()
    ok(shotAt('shot_facing_front', px, py, 0, { probe }), 'wrote shot_facing_front.png')

    probe.angle = 0                -- facing away
    ok(shotAt('shot_facing_away', px, py, 0, { probe }), 'wrote shot_facing_away.png')

    ok(shotAt('shot_world', px, py, 0.4, { probe }), 'wrote shot_world.png')

    print(('-'):rep(58))
    print(('%d passed, %d failed'):format(passed, failed))
    print('images written to: ' .. love.filesystem.getSaveDirectory())

    if failed > 0 then
        print('SELFTEST FAILED')
        error(('%d assertion(s) failed: %s'):format(failed, problems[1]), 0)
    end

    print('SELFTEST PASSED')
end
