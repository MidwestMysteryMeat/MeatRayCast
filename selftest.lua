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
    -- Floor and ceiling casting.
    --
    -- The claim is narrow and has two halves, and it is only worth anything if
    -- both are asserted: the floor and the ceiling changed, and *nothing else
    -- did*. A screenshot that looks right cannot separate those, and neither can
    -- a coverage number -- a renderer that quietly shifted every wall one pixel
    -- would sail through both.
    --
    -- So the comparison is per pixel, partitioned by the z-buffer. Each column's
    -- wall strip is exactly where the wall loop drew; everything outside one is
    -- background. Inside the strips the two renders must agree bit for bit;
    -- outside them they must overwhelmingly disagree.
    --
    -- Scoped in a block on purpose: this function is already most of the way to
    -- Lua 5.1's two-hundred-local ceiling, and a section that needs a dozen
    -- working values should hand its registers back when it is done rather than
    -- spend the budget the rest of the file is living on.
    print('floor and ceiling casting')
    do

    local castOk, castWhy = MeatRay.raycaster.floorCastAvailable()
    ok(castOk, 'the host compiled the floor-cast shader', castWhy)

    local castCanvas = love.graphics.newCanvas(W, H)
    local ATMO = MeatRay.themes.atmosphere(MeatRay.raycaster.getTheme())

    local function renderShot()
        love.graphics.setCanvas(castCanvas)
        love.graphics.clear(0, 0, 0, 1)
        local z = MeatRay.raycaster.render(view, world)
        love.graphics.setCanvas()
        return castCanvas:newImageData(), z
    end

    MeatRay.raycaster.setFloorCasting(false)
    local flatShot, flatZ = renderShot()
    MeatRay.raycaster.setFloorCasting(true)
    local castShot = renderShot()
    local castShotAgain = renderShot()

    -- The determinism control. Without it, "the walls are identical" could just
    -- as easily mean the comparison is incapable of finding a difference.
    local function differingPixels(a, b)
        local n = 0
        for y = 0, H - 1 do
            for x = 0, W - 1 do
                local r1, g1, b1 = a:getPixel(x, y)
                local r2, g2, b2 = b:getPixel(x, y)
                if r1 ~= r2 or g1 ~= g2 or b1 ~= b2 then n = n + 1 end
            end
        end
        return n
    end

    ok(differingPixels(castShot, castShotAgain) == 0,
       'two renders of the same build and camera are pixel-identical')
    local movedTotal = differingPixels(flatShot, castShot)
    ok(movedTotal > 0, ('and turning casting off moves %d pixels'):format(movedTotal))

    -- Where the wall loop drew, per column, recovered from the z-buffer the same
    -- way the wall loop derived it. A column that hit nothing carries maxView
    -- and drew no strip at all; treating its phantom strip as wall would file
    -- floor pixels under walls and hide exactly the regression this is looking
    -- for.
    local spanTop, spanBottom = {}, {}
    for x = 0, W - 1 do
        local d = flatZ[x]
        spanTop[x], spanBottom[x] = -1, -1
        if d ~= nil and d < ATMO.maxView - 1e-6 then
            local lineHeight = math.floor(H / d)
            spanTop[x] = math.floor(-lineHeight / 2 + H / 2)
            spanBottom[x] = math.floor(lineHeight / 2 + H / 2)
        end
    end

    -- One row of slack on each edge of a strip belongs to neither side: which
    -- side of a boundary a rounded edge row falls on is an implementation
    -- detail, not a claim worth making.
    local function isBackground(x, y)
        return y < spanTop[x] - 1 or y > spanBottom[x]
    end

    -- Splits the same comparison by the z-buffer.
    local wallSame, wallDiff, bgSame, bgDiff = 0, 0, 0, 0
    for x = 0, W - 1 do
        local top, bottom = spanTop[x], spanBottom[x]
        for y = 0, H - 1 do
            local r1, g1, b1 = flatShot:getPixel(x, y)
            local r2, g2, b2 = castShot:getPixel(x, y)
            local same = (r1 == r2 and g1 == g2 and b1 == b2)
            if y >= top and y < bottom then
                if same then wallSame = wallSame + 1 else wallDiff = wallDiff + 1 end
            elseif isBackground(x, y) then
                if same then bgSame = bgSame + 1 else bgDiff = bgDiff + 1 end
            end
        end
    end

    ok(wallSame > W * 10, ('%d wall pixels were compared'):format(wallSame + wallDiff))
    ok(wallDiff == 0,
       ('every one of them is unchanged (%d differ)'):format(wallDiff))
    ok(bgSame + bgDiff > W * 10,
       ('%d background pixels were compared'):format(bgSame + bgDiff))
    ok(bgDiff / math.max(1, bgSame + bgDiff) > 0.8,
       ('and %.0f%% of them changed'):format(
           bgDiff / math.max(1, bgSame + bgDiff) * 100))

    -- The structural difference, stated the way a viewer would state it.
    --
    -- A flat band is one colour all the way across a row, whatever the camera is
    -- doing -- that is what makes it a band. A cast floor is a perspective view
    -- of a tiled surface and cannot be. So: count the background rows that vary
    -- horizontally. It should be none of them before and nearly all of them
    -- after, and no pixel value has to be predicted to say so.
    --
    -- Only background columns count, or the measurement is really about
    -- whichever wall happens to reach that row.
    local function variedRows(image, y0, y1)
        local varied, counted = 0, 0
        for y = y0, y1 do
            local first, differs, n = nil, false, 0
            for x = 0, W - 1 do
                if isBackground(x, y) then
                    n = n + 1
                    local r, g, b = image:getPixel(x, y)
                    local key = math.floor(r * 255 + 0.5) * 65536
                              + math.floor(g * 255 + 0.5) * 256
                              + math.floor(b * 255 + 0.5)
                    if first == nil then first = key
                    elseif key ~= first then differs = true end
                end
            end
            -- Rows with almost no background left in them say nothing either
            -- way, and including them would make the ratio below depend on the
            -- map rather than on the renderer.
            if n >= 8 then
                counted = counted + 1
                if differs then varied = varied + 1 end
            end
        end
        return varied, counted
    end

    local HORIZON = math.floor(H / 2)

    local flatFloorVaried = variedRows(flatShot, HORIZON + 1, H - 1)
    local castFloorVaried, floorRows = variedRows(castShot, HORIZON + 1, H - 1)
    ok(flatFloorVaried == 0,
       ('every one of the %d flat floor rows is a single colour'):format(floorRows))
    ok(castFloorVaried > floorRows * 0.8,
       ('and %d of %d cast floor rows are not'):format(castFloorVaried, floorRows))

    local flatCeilVaried = variedRows(flatShot, 0, HORIZON - 1)
    local castCeilVaried, ceilRows = variedRows(castShot, 0, HORIZON - 1)
    ok(flatCeilVaried == 0,
       ('the same holds for the %d ceiling rows'):format(ceilRows))
    ok(castCeilVaried > ceilRows * 0.8,
       ('and %d of %d are cast'):format(castCeilVaried, ceilRows))

    -- Ceiling zones still decide whether there is a ceiling at all. Standing
    -- outside every zone means open air, the sky wash paints the top of the
    -- frame, and casting a ceiling underneath it would be work nobody sees.
    MeatRay.raycaster.addCeilingZone(200, 200, 210, 210)
    local openShot = renderShot()
    MeatRay.raycaster.clearCeilingZones()

    ok(variedRows(openShot, 0, HORIZON - 1) == 0,
       'outside every ceiling zone the ceiling half is not cast')
    ok(select(1, variedRows(openShot, HORIZON + 1, H - 1)) > floorRows * 0.8,
       'while the floor under it still is')

    -- And the fallback is a supported configuration rather than a broken one:
    -- a host with no shaders draws this frame, every frame.
    MeatRay.raycaster.setFloorCasting(false)
    local fallbackCov = coverage(renderShot())
    MeatRay.raycaster.setFloorCasting(true)
    ok(fallbackCov > 0.5,
       ('with casting off the frame is still drawn (%.0f%% covered)')
       :format(fallbackCov * 100))

    end

    ---------------------------------------------------------------------
    -- Thin walls.
    --
    -- A segment is a wall between two arbitrary points inside the tile grid. The
    -- DDA is unchanged; whichever hit is nearer, tile face or segment, wins the
    -- column, so a column still resolves to exactly one distance and the
    -- per-column z-buffer is untouched. tests/test_render_segments.lua asserts
    -- the two pieces of arithmetic that are easy to get wrong. What only a real
    -- frame can say is that the picture agrees with them, so every assertion
    -- below reads pixels or the z-buffer back.
    --
    -- The comparison that carries the most weight is the first one: the SAME
    -- wall, at the same place, built once out of tiles and once out of one
    -- segment. Two renderers that disagree about distance, height, brightness or
    -- texel size cannot survive that, and none of it needs a predicted pixel
    -- value.
    --
    -- Its own function rather than a do-block, for the reason written on section
    -- 7b below: Lua 5.1 allows two hundred locals per function and the ceiling is
    -- the peak, which is inside a block.
    print('thin walls')
    ;(function()

    -- `facility` for the same reason the lighting section uses it: its
    -- atmosphere is `clear`, so ambient is 1.0 and the view distance is long,
    -- and nothing below is dark because the theme was dim to begin with.
    local TW, TH = 320, 200
    local TWTHEME = 'facility'

    local function box(w, h)
        local grid = {}
        for y = 1, h do
            grid[y] = {}
            for x = 1, w do
                grid[y][x] = (x == 1 or y == 1 or x == w or y == h) and 1 or 0
            end
        end
        return MeatRay.world.new(grid, { theme = TWTHEME })
    end

    MeatRay.raycaster.init{ width = TW, height = TH, theme = TWTHEME }
    local twCanvas = love.graphics.newCanvas(TW, TH)

    local function frame(w, camX, camY, angle, name)
        local v = MeatRay.raycaster.view(camX, camY, angle)
        love.graphics.setCanvas(twCanvas)
        love.graphics.clear(0, 0, 0, 1)
        local z = MeatRay.raycaster.render(v, w)
        love.graphics.setCanvas()
        local image = twCanvas:newImageData()
        if name then image:encode('png', name .. '.png') end
        return image, z
    end

    local function differing(a, b)
        local n = 0
        for y = 0, TH - 1 do
            for x = 0, TW - 1 do
                local r1, g1, b1 = a:getPixel(x, y)
                local r2, g2, b2 = b:getPixel(x, y)
                if r1 ~= r2 or g1 ~= g2 or b1 ~= b2 then n = n + 1 end
            end
        end
        return n
    end

    -----------------------------------------------------------------
    -- 1. The same wall, as tiles and as one segment.
    --
    -- A solid tile column at tile x = 8 presents its near face on the plane
    -- x = 7. A single segment from (7,3) to (7,8) is that same plane, five tiles
    -- of it, in one wall instead of five. The camera stands square-on 2.5 tiles
    -- away, so every column of the screen lands on it.
    -----------------------------------------------------------------
    local CAMX, CAMY = 4.5, 5.5
    local FACE = 2.5

    local tileWorld = box(20, 11)
    for y = 2, 10 do tileWorld.grid[y][8] = 1 end

    local segWorld = box(20, 11)
    segWorld:addSegment(7, 3, 7, 8)

    ok(segWorld:segmentCount() == 1, 'a five-tile thin wall is in the world')
    ok(tileWorld.segments == nil, 'and the tile version of it carries no segment table at all')

    local tileShot, tileZ = frame(tileWorld, CAMX, CAMY, 0, 'shot_thin_wall_tiles')
    local segShot, segZ = frame(segWorld, CAMX, CAMY, 0, 'shot_thin_wall_segment')

    -- The determinism control, first. Without it "identical" is equally
    -- consistent with a comparison incapable of finding a difference.
    ok(differing(segShot, (frame(segWorld, CAMX, CAMY, 0))) == 0,
       'two renders of the same segment scene are pixel-identical')

    local worstTile, worstSeg = 0, 0
    for x = 0, TW - 1 do
        worstTile = math.max(worstTile, math.abs(tileZ[x] - FACE))
        worstSeg = math.max(worstSeg, math.abs(segZ[x] - FACE))
    end
    ok(worstTile < 1e-9,
       ('the tile face reads %.1f tiles away in all %d columns'):format(FACE, TW))
    -- The no-fisheye claim, on the picture rather than on the arithmetic. A
    -- normalised ray direction would spread these by 1/cos: about 20% at the
    -- edges of a 66-degree frame, which is the diagonal visibly bowing.
    ok(worstSeg < 1e-9,
       ('and the segment standing on the same plane reads the same in all of them (%.3e worst)')
           :format(worstSeg))

    -- Same distance means the same strip height, so the two frames must differ
    -- only where the wall is textured and nowhere else. The z-buffer is what
    -- says which pixels those are.
    local top, bottom = {}, {}
    for x = 0, TW - 1 do
        local lineHeight = math.floor(TH / segZ[x])
        top[x] = math.floor(-lineHeight / 2 + TH / 2)
        bottom[x] = math.floor(lineHeight / 2 + TH / 2)
    end

    local wallSame, wallDiff, bgSame, bgDiff = 0, 0, 0, 0
    for x = 0, TW - 1 do
        for y = 0, TH - 1 do
            local r1, g1, b1 = tileShot:getPixel(x, y)
            local r2, g2, b2 = segShot:getPixel(x, y)
            local same = (r1 == r2 and g1 == g2 and b1 == b2)
            if y >= top[x] and y < bottom[x] then
                if same then wallSame = wallSame + 1 else wallDiff = wallDiff + 1 end
            elseif y < top[x] - 1 or y > bottom[x] then
                if same then bgSame = bgSame + 1 else bgDiff = bgDiff + 1 end
            end
        end
    end

    ok(bgSame + bgDiff > TW * 10,
       ('%d background pixels were compared'):format(bgSame + bgDiff))
    ok(bgDiff == 0,
       ('and every one of them is unchanged (%d differ): the two walls occupy exactly the same rows')
           :format(bgDiff))
    ok(wallSame + wallDiff > TW * 10,
       ('%d wall pixels were compared'):format(wallSame + wallDiff))

    -- Brightness: a segment lying north-south presents an x-facing surface, so
    -- it must take the side shade an x-facing tile face takes and not some
    -- constant of its own.
    local function bandLuma(image)
        local sum, n = 0, 0
        for x = 0, TW - 1 do
            for y = top[x] + 2, bottom[x] - 2 do
                local r, g, b = image:getPixel(x, y)
                sum = sum + (r + g + b) / 3
                n = n + 1
            end
        end
        return sum / math.max(1, n)
    end

    local tileLuma, segLuma = bandLuma(tileShot), bandLuma(segShot)
    ok(math.abs(segLuma - tileLuma) < tileLuma * 0.03,
       ('and it is drawn at the same brightness as the tile face (%.4f vs %.4f)')
           :format(segLuma, tileLuma))

    -----------------------------------------------------------------
    -- 2. Texel size, measured off the picture.
    --
    -- The brick pattern puts a mortar column every half tile, so a five-tile
    -- wall shows ten of them however it is built. Using `u` straight off the
    -- segment would stretch ONE texture across all five tiles and leave two.
    -- Counted rather than predicted: the number only has to match the tile
    -- wall's, which is the whole claim.
    -----------------------------------------------------------------
    local function mortarBands(image)
        local best = 0
        -- Several rows, because a scanline that lands inside a horizontal
        -- mortar course is uniformly dark and counts nothing. The wall is the
        -- same all the way down, so the busiest row is the honest reading.
        for _, y in ipairs({ 78, 86, 110, 118, 126 }) do
            local sum, n = 0, 0
            for x = 0, TW - 1 do
                local r, g, b = image:getPixel(x, y)
                sum = sum + (r + g + b) / 3
                n = n + 1
            end
            local threshold = sum / math.max(1, n) * 0.85

            local bands, inside = 0, false
            for x = 0, TW - 1 do
                local r, g, b = image:getPixel(x, y)
                if (r + g + b) / 3 < threshold then
                    if not inside then bands = bands + 1 end
                    inside = true
                else
                    inside = false
                end
            end
            best = math.max(best, bands)
        end
        return best
    end

    local tileBands, segBands = mortarBands(tileShot), mortarBands(segShot)
    ok(tileBands >= 6,
       ('the tile wall shows %d mortar columns across the frame'):format(tileBands))
    ok(math.abs(segBands - tileBands) <= 2,
       ('and the segment shows %d: the same texel size, not one texture stretched over five tiles')
           :format(segBands))

    -----------------------------------------------------------------
    -- 3. A world with no thin walls pays nothing, and looks like it.
    --
    -- The renderer short-circuits on a single nil test, so detaching the set
    -- must put the frame back exactly as it was -- not nearly.
    -----------------------------------------------------------------
    local bareShot = frame(box(20, 11), CAMX, CAMY, 0)
    local held = segWorld.segments
    segWorld.segments = nil
    local detachedShot = frame(segWorld, CAMX, CAMY, 0)
    segWorld.segments = held

    ok(differing(bareShot, detachedShot) == 0,
       'with the segment set detached the frame is byte-identical to a world that never had one')
    ok(differing(bareShot, segShot) > 0,
       ('while attaching it moves %d pixels'):format(differing(bareShot, segShot)))

    -----------------------------------------------------------------
    -- 4. Whichever is nearer wins the column, in both directions.
    -----------------------------------------------------------------
    local nearWorld = box(20, 11)
    for y = 2, 10 do nearWorld.grid[y][8] = 1 end
    nearWorld:addSegment(6, 3, 6, 8)          -- one tile in front of the face

    local _, nearZ = frame(nearWorld, CAMX, CAMY, 0)
    local worstNear = 0
    for x = 0, TW - 1 do worstNear = math.max(worstNear, math.abs(nearZ[x] - 1.5)) end
    ok(worstNear < 1e-9, 'a segment in front of a tile face takes the column')

    local behindWorld = box(20, 11)
    for y = 2, 10 do behindWorld.grid[y][8] = 1 end
    behindWorld:addSegment(9, 3, 9, 8)        -- two tiles behind it
    local behindShot, behindZ = frame(behindWorld, CAMX, CAMY, 0)

    local worstBehind = 0
    for x = 0, TW - 1 do worstBehind = math.max(worstBehind, math.abs(behindZ[x] - FACE)) end
    ok(worstBehind < 1e-9, 'and one behind it does not')
    ok(differing(behindShot, tileShot) == 0,
       'so a segment hidden by a tile wall is not merely dimmed, it is not drawn')

    -- What is drawn has to be what stops you, or the wall reads as the renderer
    -- being broken. meatray.sim.collide answers for the same segment.
    ok(Collide.circleBlocked(segWorld, 6.85, 5.5, 0.24),
       'and walking into the drawn segment is blocked')
    ok(not Collide.circleBlocked(segWorld, 5.5, 5.5, 0.24),
       'while the open floor in front of it is not')

    -----------------------------------------------------------------
    -- 5. A diagonal is straight, from every angle.
    --
    -- Stated so it needs no threshold picked by eye. A straight wall in a
    -- perspective projection has a screen height linear in x, and the height is
    -- h/distance -- so 1/z must be linear across the columns that land on it,
    -- and its second difference must be zero to floating point. A wall built out
    -- of tiles cannot be: its distance steps at every tile boundary, which is
    -- exactly the staircase this feature exists to avoid.
    -----------------------------------------------------------------
    local diagWorld = box(24, 16)
    diagWorld:addSegment(6, 4.5, 14, 12.5, 2)

    -- The same diagonal, as tiles: the staircase, and the control for the
    -- number below.
    local stairWorld = box(24, 16)
    for i = 0, 7 do stairWorld.grid[5 + i][7 + i] = 2 end

    -- The worst second difference of 1/z over the columns that hit the wall,
    -- and how many of them there were. Columns are compared against the same
    -- world with nothing in it, so "hit the wall" is measured rather than
    -- guessed at from a screen position.
    local function straightness(w, camX, camY, angle, name)
        local _, emptyZ = frame(box(24, 16), camX, camY, angle)
        local _, wallZ = frame(w, camX, camY, angle, name)

        local worst, counted, runs = 0, 0, 0
        local previous = -2
        for x = 1, TW - 2 do
            local onWall = wallZ[x] < emptyZ[x] - 1e-9
            if onWall and wallZ[x - 1] < emptyZ[x - 1] - 1e-9
                       and wallZ[x + 1] < emptyZ[x + 1] - 1e-9 then
                local d2 = 1 / wallZ[x + 1] - 2 / wallZ[x] + 1 / wallZ[x - 1]
                worst = math.max(worst, math.abs(d2))
                counted = counted + 1
                if previous ~= x - 1 then runs = runs + 1 end
                previous = x
            end
        end
        return worst, counted, runs
    end

    local segWorst, segCols = straightness(diagWorld, 3.5, 8.5, 0.2, 'shot_thin_wall_diagonal')
    local stairWorst, stairCols = straightness(stairWorld, 3.5, 8.5, 0.2, 'shot_thin_wall_stairs')

    ok(segCols > 40, ('the diagonal covers %d columns of the frame'):format(segCols))
    ok(stairCols > 40, ('and the staircase built from tiles covers %d'):format(stairCols))
    ok(segWorst < 1e-9,
       ('the diagonal is straight to %.2e, where the staircase steps by %.2e')
           :format(segWorst, stairWorst))
    ok(stairWorst > segWorst * 1e3,
       ('which is the difference this feature exists for (%.0fx)')
           :format(stairWorst / math.max(segWorst, 1e-18)))

    -- Turning the camera is where a fisheye would show: `t` is measured in units
    -- of an unnormalised ray direction, and a euclidean conversion would bow the
    -- wall differently at every angle. Five angles, and the wall stays straight
    -- in all of them.
    local bowed, checked = 0, 0
    for _, angle in ipairs({ -0.5, -0.2, 0.2, 0.5, 0.8 }) do
        local worst, columns = straightness(diagWorld, 3.5, 8.5, angle)
        if columns > 20 then
            checked = checked + 1
            if worst > 1e-9 then bowed = bowed + 1 end
        end
    end
    ok(checked >= 4, ('the diagonal was in frame at %d camera angles'):format(checked))
    ok(bowed == 0, 'and stayed straight at every one of them')

    -----------------------------------------------------------------
    -- 6. The wall loop still does not allocate per column.
    --
    -- Which segments a tile holds is remembered rather than looked up per tile
    -- per column, because the set's index is keyed by a 'tx,ty' string and
    -- building one a few thousand times a frame is the same mistake as the quad
    -- that used to be allocated per column. A second frame of a still scene must
    -- therefore ask about no new tiles at all.
    -----------------------------------------------------------------
    frame(diagWorld, 3.5, 8.5, 0.2)
    local cached = MeatRay.raycaster.segmentTileCache()
    frame(diagWorld, 3.5, 8.5, 0.2)
    ok(cached > 0, ('the segment lookup memoised %d tiles'):format(cached))
    ok(MeatRay.raycaster.segmentTileCache() == cached,
       'and a second render of the same scene asked about none of them again')

    -- What is remembered must not outlive what it describes. A wall added to a
    -- world that has already been drawn has to appear; a cleared set has to take
    -- its walls with it; and a set cleared and then refilled to the SAME size is
    -- the case that catches a memo keyed on the count alone.
    local liveWorld = box(20, 11)
    local emptyShot = frame(liveWorld, CAMX, CAMY, 0)

    liveWorld:addSegment(7, 3, 7, 8)
    local _, addedZ = frame(liveWorld, CAMX, CAMY, 0)
    ok(math.abs(addedZ[TW / 2] - FACE) < 1e-9,
       'a wall added after the first frame is drawn at its own distance')

    liveWorld:clearSegments()
    ok(differing(emptyShot, frame(liveWorld, CAMX, CAMY, 0)) == 0,
       'and clearing the set puts the frame back byte for byte')

    -- The refill, arranged so that remembering the old answer is visible rather
    -- than merely wrong in principle. The first wall stands behind a tile face
    -- and is never reached, so the tiles in front of it are remembered as
    -- holding nothing; the second one stands in one of exactly those tiles. A
    -- memo that survived the refill would report no wall there and the new wall
    -- would simply not be drawn.
    local refillWorld = box(20, 11)
    for y = 2, 10 do refillWorld.grid[y][8] = 1 end
    refillWorld:addSegment(13, 3, 13, 8)
    local _, hiddenZ = frame(refillWorld, CAMX, CAMY, 0)
    ok(math.abs(hiddenZ[TW / 2] - FACE) < 1e-9,
       'a wall behind a tile face leaves the tiles in front of it remembered as empty')

    refillWorld:clearSegments()
    refillWorld:addSegment(6, 3, 6, 8)
    local _, refilledZ = frame(refillWorld, CAMX, CAMY, 0)
    ok(math.abs(refilledZ[TW / 2] - 1.5) < 1e-9,
       'and a set cleared and refilled to the same size is the new set, not the old one')

    -- Put the renderer back the way the sections after this one expect to find
    -- it: the same size and theme the render pass above set up.
    MeatRay.raycaster.init{ width = W, height = H, theme = authored and authored.theme }

    end)()

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
    -- Asset import. The arithmetic is asserted headlessly in tests/test_asset_*;
    -- what is left here is everything that needs a real decoder and a real audio
    -- device, which is exactly what the headless suite cannot cover.
    --
    -- The fixtures are written rather than shipped: the repository holds no media
    -- by policy, so the honest way to prove a PNG round-trips is to encode one,
    -- read it back through the importer, and see the same dimensions come out.
    -- They land under assets/ in the save directory, where the asset browser will
    -- also find them.
    print('asset import')

    local Asset = require('meatray.asset')
    local AssetImage = require('meatray.asset.image')
    local Sound = require('meatray.asset.sound')

    Asset.clear()
    love.filesystem.createDirectory('assets/sprites')
    love.filesystem.createDirectory('assets/sounds')

    -- A 4-frame by 8-bucket sheet of 48-pixel cells, each cell a different shade
    -- so a mis-sliced import is visible as well as measurable.
    local SHEET = 'assets/sprites/probe_a8_f4.png'
    do
        local sheetData = love.image.newImageData(48 * 4, 48 * 8)
        for cy = 0, 7 do
            for cx = 0, 3 do
                local shade = 0.25 + (cy * 4 + cx) / 32 * 0.7
                for py = 2, 45 do
                    for px = 2, 45 do
                        sheetData:setPixel(cx * 48 + px, cy * 48 + py, shade, shade * 0.6, 0.3, 1)
                    end
                end
            end
        end
        sheetData:encode('png', SHEET)
    end

    ok(love.filesystem.getInfo(SHEET) ~= nil, 'wrote a sprite sheet fixture')

    local loaded, loadErr = AssetImage.load(SHEET)
    ok(loaded ~= nil, 'the importer decodes a real PNG', loadErr)
    ok(loaded and loaded:getWidth() == 192, 'at the width it was written')
    ok(loaded and loaded:getHeight() == 384, 'and the height')

    local def, planOrErr = AssetImage.sheetDef(SHEET, { angles = 8, frames = 4, fps = 6 })
    ok(def ~= nil, 'a matching grid produces a definition', planOrErr)
    ok(def and def.angles == 8, 'carrying the angle count through to Sprites.define')
    ok(def and def.frames == 4, 'and the frame count')
    ok(def and def.fps == 6, 'and the frame rate')

    -- The case that matters: a declared grid the sheet does not fit is refused
    -- here rather than rendered half-off later.
    local badDef, badErr = AssetImage.sheetDef(SHEET, { angles = 7, frames = 4 })
    ok(badDef == nil, 'a grid the sheet does not fit is refused')
    ok(badErr and badErr:find('left over') ~= nil, 'with the remainder in the message', badErr)

    local forced = AssetImage.sheetDef(SHEET, { angles = 7, frames = 4, force = true })
    ok(forced ~= nil, 'and imported anyway only when explicitly forced')

    -- Import through the registry, which is the path the browser and game use.
    local record = Asset.importSprite('probe_sheet', SHEET, { angles = 8, frames = 4, fps = 6 })
    ok(record.state == 'file', 'importSprite resolves from the file', record.problem)

    local imported = MeatRay.sprites.get('probe_sheet')
    ok(imported ~= nil, 'and registers under its logical name')
    ok(imported and not imported.generated, 'as an imported sheet, not a placeholder')
    ok(imported and imported.cellW == 48, 'sliced to 48-pixel cells')
    ok(imported and imported.cellH == 48, 'on both axes')
    ok(imported and imported.quads[7][3] ~= nil, 'with a quad for the last cell')

    -- And the whole point of the registry: a source that is not there still
    -- leaves a drawable sprite behind, and says which one it was.
    local absent = Asset.importSprite('probe_absent', 'assets/sprites/not_here.png',
                                      { angles = 4, frames = 2 })
    ok(absent.state == 'fallback', 'a missing file falls back rather than erroring')

    local placeholder = MeatRay.sprites.get('probe_absent')
    ok(placeholder ~= nil, 'and the sprite still exists')
    ok(placeholder and placeholder.generated, 'as a generated placeholder')
    ok(placeholder and placeholder.angles == 4, 'keeping the angle count that was asked for')

    local missingNow = Asset.missing()
    ok(#missingNow == 1, ('exactly one asset reports as missing (%d)'):format(#missingNow))
    ok(missingNow[1] and missingNow[1].name == 'probe_absent', 'and it is the right one')

    local report = Asset.report()
    ok(report.file == 1, 'the report counts one asset from a file')
    ok(report.missing == 1, 'and one missing')

    local found = Asset.scan('assets')
    local sawSheet = false
    for _, file in ipairs(found) do
        if file.path == SHEET then sawSheet = true end
    end
    ok(sawSheet, 'scanning the assets folder finds the sheet')

    local hinted
    for _, file in ipairs(found) do
        if file.path == SHEET then hinted = file end
    end
    ok(hinted and hinted.name == 'probe', 'with the grid hint stripped from its name')
    ok(hinted and hinted.hints and hinted.hints.angles == 8, 'and read out of the filename')

    ---------------------------------------------------------------------
    print('audio')

    -- conf.lua enables audio for any run with a window, so this is the check that
    -- the flag is actually doing what it claims.
    ok(Sound.available(), 'the audio module is available in a windowed run')

    local WAV = 'assets/sounds/probe.wav'
    do
        -- A half-second 8-bit mono square wave, written by hand. Mono matters:
        -- OpenAL will not position a stereo source, so a stereo fixture would
        -- silently skip the panning path this is here to exercise.
        local rate, seconds = 8000, 0.5
        local count = math.floor(rate * seconds)
        local samples = {}
        for i = 1, count do
            samples[i] = string.char((math.floor(i / 20) % 2 == 0) and 200 or 56)
        end
        local pcm = table.concat(samples)

        local function le32(n)
            return string.char(n % 256, math.floor(n / 256) % 256,
                               math.floor(n / 65536) % 256, math.floor(n / 16777216) % 256)
        end
        local function le16(n)
            return string.char(n % 256, math.floor(n / 256) % 256)
        end

        love.filesystem.write(WAV, table.concat({
            'RIFF', le32(36 + #pcm), 'WAVE',
            'fmt ', le32(16), le16(1), le16(1), le32(rate), le32(rate), le16(1), le16(8),
            'data', le32(#pcm), pcm,
        }))
    end

    ok(love.filesystem.getInfo(WAV) ~= nil, 'wrote a WAV fixture')

    local source, soundErr = Sound.load(WAV)
    ok(source ~= nil, 'LOVE decodes WAV with no extra dependency', soundErr)

    local soundRecord = Asset.importSound('probe_sound', WAV, { max = 10 })
    ok(soundRecord.state == 'file', 'importSound resolves from the file', soundRecord.problem)

    Sound.stopAll()
    Sound.setListener(0, 0, 0)

    -- Beyond the cutoff nothing starts at all, which is why the falloff curve
    -- reaches true zero rather than merely approaching it.
    ok(Sound.playAt('probe_sound', 500, 0) == nil, 'a source past its cutoff does not play')
    ok(Sound.voiceCount() == 0, 'and occupies no voice')

    local voice = Sound.playAt('probe_sound', 2, 0)
    ok(voice ~= nil, 'a source in range plays')
    ok(Sound.voiceCount() == 1, 'taking one voice')

    -- Overlapping the same sound must clone rather than restart, or every shot
    -- cuts off the one before it.
    Sound.playAt('probe_sound', 2, 0)
    ok(Sound.voiceCount() == 2, 'and playing it again overlaps rather than restarting')

    Sound.stopAll()
    ok(Sound.voiceCount() == 0, 'stopAll silences everything')

    -- Missing audio is silent, never an error. This is the call a game makes in
    -- its movement code, on a name nobody ever imported.
    local quiet, quietErr = pcall(Sound.playAt, 'no_such_sound', 1, 1)
    ok(quiet, 'playing a sound that does not exist does not raise', quietErr)
    ok(quietErr == nil, 'and returns nil rather than a source')

    Asset.declareSound('designed_but_unrecorded', {})
    ok(Sound.play('designed_but_unrecorded') == nil, 'a sound with no file plays nothing')
    ok(#Asset.missing() == 1, 'and is not counted as missing, because it was never promised a file')

    -- Previewing a mix must not move the ears. The asset browser draws this every
    -- frame it is open, and a preview that set the listener as a side effect
    -- would drag a running game's audio to the origin.
    Sound.setListener(9, 9, 0)
    local previewVolume = Sound.previewMix('probe_sound', 1, 0, { x = 0, y = 0, angle = 0 })
    ok(previewVolume > 0, 'previewMix answers for the listener it was given')
    ok(Sound.getListener().x == 9, 'and leaves the real listener where it was')

    Sound.clearListener()
    Sound.stopAll()

    ---------------------------------------------------------------------
    -- The asset browser's own logic, exercised without a frame in flight.
    -- Construction, scanning, prefilling and importing need no draw call, so
    -- they can be asserted here rather than only being visible in a screenshot.
    print('asset browser panel')

    local AssetPanel = require('meatray.ui.panel_assets')
    local panel = AssetPanel.new{}

    ok(panel.id == 'assets', 'the panel declares the id the shell routes by')
    ok(type(panel.draw) == 'function', 'and satisfies the panel contract')
    ok(type(panel.drawSidebar) == 'function', 'with a sidebar')
    ok(type(panel.drawInspector) == 'function', 'and an inspector')

    panel:refresh()
    ok(#panel.items > 0, ('the sprite category lists %d items'):format(#panel.items))

    local sawSheetOnDisk = false
    for _, file in ipairs(panel.found) do
        if file.path == SHEET then sawSheetOnDisk = file end
    end
    ok(sawSheetOnDisk ~= false, 'the sheet on disk is offered for import')

    -- Images are deliberately NOT declared on sight: an automatic declaration
    -- would resolve through Sprites.define with a guessed grid and overwrite
    -- whatever the game defined under that name.
    ok(Asset.get('probe', 'sprite') == nil, 'but is not declared as a sprite automatically')

    if sawSheetOnDisk then
        panel:prefill(sawSheetOnDisk)
        ok(panel.importPath == SHEET, 'prefilling fills in the path')
        ok(panel.importName == 'probe', 'and the name, with the hint stripped')
        ok(panel.importAngles == '8', 'and the angle count read out of the filename')
        ok(panel.importFrames == '4', 'and the frame count')
    end

    ok(panel:doImport(), 'importing the prefilled sheet succeeds')
    ok(Asset.get('probe', 'sprite') ~= nil, 'and the sprite is now declared')
    ok(MeatRay.sprites.get('probe').angles == 8, 'with the angle count carried through')
    ok(panel.items[panel.selected] and panel.items[panel.selected].name == 'probe',
       'and the browser selects what was just imported')

    panel.importPath = ''
    ok(not panel:doImport(), 'importing with no path is refused, not attempted')

    panel.importPath = 'assets/sprites/definitely_not_here.png'
    panel.importName = 'nothing_here'
    ok(not panel:doImport(), 'importing a file that is not there reports failure')
    ok(MeatRay.sprites.get('nothing_here') ~= nil,
       'and still leaves a drawable placeholder behind')

    panel.importPath = WAV
    panel.importName = 'panel_sound'
    ok(panel:doImport(), 'a WAV imports as a sound rather than a sheet')
    ok(Asset.get('panel_sound', 'sound') ~= nil, 'and is registered under the sound kind')
    ok(AssetPanel.CATEGORIES[panel.category].id == 'sounds',
       'and the browser reveals it by switching to the sounds category')
    ok(panel.items[panel.selected] and panel.items[panel.selected].name == 'panel_sound',
       'with it selected')

    -- The scan declared assets/sounds/probe.wav as a sound named `probe`, and the
    -- import above declared a sprite of the same name. Both must survive: names
    -- are namespaced per kind precisely so this is not a collision.
    ok(Asset.get('probe', 'sound') ~= nil, 'a sound and a sprite may share a name')
    ok(Asset.get('probe', 'sprite') ~= nil, 'with neither replacing the other')
    ok(#Asset.find('probe') == 2, 'and find() reports both')

    for index, category in ipairs(AssetPanel.CATEGORIES) do
        panel:setCategory(index)
        ok(panel.category == index, ('the %s category selects'):format(category.id))
    end

    Sound.stopAll()

    ---------------------------------------------------------------------
    --[[
        The save system against a real filesystem.

        Nearly all of it is headless and asserted in tests/test_save_*.lua, where
        the storage backend is a Lua table and the failures that matter — a write
        cut short, a flipped byte, a process killed mid-save — can be injected on
        demand. What cannot be asserted there is that any of it works against
        love.filesystem, which is sandboxed, is PhysFS underneath, and is the
        only filesystem a shipped game ever sees.

        So this section does the whole cycle for real: write a save, change the
        world and the entity in it, load the save back, and check that what comes
        back is what was written and not what is currently in memory.
    ]]
    print('save system')

    local Save = MeatRay.save

    ok(Save ~= nil, 'meatray.save resolves through the engine table')
    ok(Save.backend().name == 'love', 'and picks the LOVE backend when there is a LOVE')

    -- Recorded as an assertion rather than a comment, because the whole atomic
    -- write design turns on it: PhysFS offers no rename and no move, so a save
    -- cannot be swapped into place and has to be written, verified and recovered
    -- instead. If a future LOVE gains one, this fails and says to go and use it.
    ok(love.filesystem.rename == nil,
       'love.filesystem still has no rename, which is why writes are verified and recovered')

    Save.setDirectory('selftest-saves')

    local saveWorld = MeatRay.world.new((function()
        local g = {}
        for y = 1, 16 do
            g[y] = {}
            for x = 1, 16 do
                g[y][x] = (x == 1 or y == 1 or x == 16 or y == 16) and 1 or 0
            end
        end
        return g
    end)(), { theme = 'dungeon' })
    saveWorld:addDoor(8, 1, false)

    Entity.archetype('saveprobe', function(e)
        e:add(C.Health{ hp = 40, max = 40 })
        e:add(C.Billboard{ sheet = 'probe' })
    end)

    local saved = Entity.spawn('saveprobe', 5.25, 6.75)
    saved.angle = 2.5
    saved:get('health').hp = 13
    saveWorld:setDoorOpen(8, 1, true)

    local wrote, wroteErr = Save.save('selftest', {
        world = saveWorld,
        entities = { saved },
        progress = { chapter = 2, flags = { metTheSmith = true } },
        map = 'selftest arena',
        playTime = 63.25,
        label = 'written by the selftest',
    })
    ok(wrote, 'a save writes through love.filesystem', wroteErr)

    local savePath = Save.path('selftest')
    ok(love.filesystem.getInfo(savePath) ~= nil,
       'and the file is in the save directory: ' .. Save.describe())
    ok(love.filesystem.getInfo(savePath .. Save.TEMP) == nil,
       'with no temporary file left behind')

    -- Metadata, without opening the save. This is what a save browser draws.
    local rows = Save.list()
    ok(#rows == 1, ('the save directory lists %d save'):format(#rows))
    ok(rows[1] and rows[1].map == 'selftest arena', 'the listing knows the map name')
    ok(rows[1] and rows[1].playTime == 63.25, 'and the play time')
    ok(rows[1] and rows[1].label == 'written by the selftest', 'and the label')
    ok(rows[1] and rows[1].version == Save.VERSION, 'and the version it was written at')
    ok(rows[1] and rows[1].bytes > 0, ('and the file size (%d bytes)')
                                      :format(rows[1] and rows[1].bytes or 0))

    -- Now change everything the save describes, so that a load which quietly did
    -- nothing would be caught rather than looking like a pass.
    saveWorld:setDoorOpen(8, 1, false)
    saved.x, saved.y, saved.angle = 1.5, 1.5, 0
    saved:get('health').hp = 1

    local loaded, loadErr = Save.load('selftest')
    ok(loaded ~= nil, 'the save loads back off the disk', loadErr)

    if loaded then
        ok(loaded.world:doorAt(8, 1) ~= nil, 'the door came back')
        ok(loaded.world:doorAt(8, 1).open == true,
           'open, as it was saved, not closed as it is now')
        ok(loaded.world.width == 16 and loaded.world.height == 16, 'the world is its own size')

        local back = loaded.byId[saved.id]
        ok(back ~= nil, 'the entity came back under its own id')
        ok(back and back.x == 5.25 and back.y == 6.75,
           'at the position it was saved at, not the one it is at now')
        ok(back and back.angle == 2.5, 'facing the way it was saved')
        ok(back and back:get('health').hp == 13, 'with the health it was saved with')
        ok(back and back:get('billboard').sheet == 'probe', 'and its other component state')

        ok(loaded.progress.chapter == 2, 'game progress came back')
        ok(loaded.progress.flags.metTheSmith == true, 'including nested tables')
        ok(#loaded.unknown == 0 and #loaded.dropped == 0, 'with nothing dropped on the way')
        ok(loaded.recovered == nil, 'and nothing needed recovering')
    end

    -- A corrupt file on a real disk. The whole file is overwritten with the
    -- right shape and the wrong bytes; nothing may raise, and nothing may load.
    local realBytes = love.filesystem.read(savePath)
    love.filesystem.write(savePath, realBytes:sub(1, #realBytes - 30))
    local truncated, truncatedErr = Save.read('selftest')
    ok(truncated == nil, 'a truncated save on disk does not load')
    ok(type(truncatedErr) == 'string' and truncatedErr:find('truncated'),
       'and says it is truncated', truncatedErr)

    love.filesystem.write(savePath, 'this is not a save file at all')
    local garbage, garbageErr = Save.read('selftest')
    ok(garbage == nil, 'a garbage file does not load')
    ok(type(garbageErr) == 'string' and #garbageErr > 8, 'and is refused with a reason',
       garbageErr)

    -- The interrupted-save case, end to end on a real filesystem: a complete
    -- temporary file beside a broken save is what a killed process leaves, and
    -- reading is what repairs it.
    love.filesystem.write(savePath .. Save.TEMP, realBytes)
    local recovered = Save.read('selftest')
    ok(recovered ~= nil, 'a complete temporary file rescues a broken save')
    ok(recovered and type(recovered.recovered) == 'string', 'and the load says so')
    ok(love.filesystem.getInfo(savePath .. Save.TEMP) == nil,
       'and the temporary file is cleared once it has been used')
    ok(Save.read('selftest') ~= nil, 'leaving a save that loads normally afterwards')

    ok(Save.delete('selftest'), 'a save deletes')
    ok(love.filesystem.getInfo(savePath) == nil, 'and the file is gone from the disk')
    ok(#Save.list() == 0, 'leaving an empty save directory')

    Save.setDirectory('saves')

    ---------------------------------------------------------------------
    -- The sprite painter. The pixel model, the cell arithmetic, the undo bound
    -- and the byte-level round trip are all asserted headlessly in
    -- tests/test_paint_*; what is left here is the part that needs a real encoder
    -- and a real ImageData, which is exactly where a round trip stops being
    -- lossless without saying so.
    print('sprite painter')

    local Sheet = require('meatray.asset.sheet')
    local SheetImage = require('meatray.asset.sheet_image')
    local SpritePanel = require('meatray.ui.panel_sprite')

    ok(SheetImage.available(), 'the painter has an image module to work with')

    local painted = Sheet.new{ angles = 8, frames = 4, cellW = 12, cellH = 12 }
    ok(painted ~= nil, 'a sheet builds for the painter')
    ok(Sheet.starter(painted) > 0, 'and the starting figure draws into it')

    -- A hand-mixed, partially transparent colour, so the round trip has to carry
    -- alpha and an odd value rather than only the palette defaults.
    local ghost = Sheet.addColor(painted, 17, 200, 99, 123)
    Sheet.plot(painted, 3, 3, ghost)
    Sheet.plot(painted, 4, 3, ghost)

    local sheetData = SheetImage.toImageData(painted)
    ok(sheetData ~= nil, 'the sheet converts to an ImageData')
    ok(sheetData and sheetData:getWidth() == 48, 'at the sheet width')
    ok(sheetData and sheetData:getHeight() == 96, 'and the sheet height')

    -- The claim the painter makes, put to a real PNG encoder and decoder rather
    -- than to itself. Anything lossy — a float palette, a premultiply, a rounding
    -- step in the wrong direction — comes back as a mismatched byte, and the
    -- message says which one.
    local EXPORT = SheetImage.pathFor('painter_probe', painted)
    local written, writeErr = SheetImage.write(painted, EXPORT)
    ok(written ~= nil, 'the painter writes a PNG', writeErr)
    ok(written and love.filesystem.getInfo(written) ~= nil, 'and the file is on disk')
    ok(written == 'assets/sprites/painter_probe_a8_f4.png',
       'named with its grid, so a re-import prefills its own counts', written)

    local reread, readErr = SheetImage.read(EXPORT)
    ok(reread ~= nil, 'and reads it back with the grid taken from the filename', readErr)
    ok(reread and reread.angles == 8, 'recovering the bucket count from the name')
    ok(reread and reread.frames == 4, 'and the frame count')
    ok(reread and reread.cellW == 12, 'and the cell size those imply')

    if reread then
        local identical, where = Sheet.sameBytes(Sheet.toBytes(reread),
                                                 Sheet.toBytes(painted))
        ok(identical, 'export then re-import is byte-for-byte lossless', where)
        ok(Sheet.coverage(reread).total == Sheet.coverage(painted).total,
           'with the same number of drawn pixels')

        local pr, pg, pb, pa = Sheet.color(reread, Sheet.get(reread, 3, 3))
        ok(pr == 17 and pg == 200 and pb == 99, 'a hand-mixed colour survives the file')
        ok(pa == 123, 'including its alpha, which is where a lossy path shows first')

        -- A second pass, because a round trip that is only stable the second time
        -- is one that changed something quietly on the first.
        local again = SheetImage.write(reread, 'assets/sprites/painter_again_a8_f4.png')
        local third = again and SheetImage.read(again)
        ok(third ~= nil, 'a re-exported sheet reads back too')
        ok(third and Sheet.sameBytes(Sheet.toBytes(third), Sheet.toBytes(painted)),
           'and is still identical to what was drawn two files ago')
    end

    -- The incremental path the painter actually uses to keep the picture in step
    -- with the buffer. If these two disagree the canvas shows something the sheet
    -- does not hold, which is the worst failure an editor can have.
    local live = Sheet.new{ angles = 2, frames = 2, cellW = 8, cellH = 8 }
    local liveData = SheetImage.toImageData(live)
    local edit = Sheet.diff('live')
    Sheet.line(live, 0, 0, 15, 15, 7, 2, edit)
    SheetImage.applyDiff(live, liveData, edit, false)

    local mirrored = SheetImage.fromImageData(liveData, { angles = 2, frames = 2 })
    ok(mirrored ~= nil, 'the incrementally updated picture reads back as a sheet')
    ok(mirrored and Sheet.sameBytes(Sheet.toBytes(mirrored), Sheet.toBytes(live)),
       'and matches the buffer it was tracking, pixel for pixel')

    SheetImage.applyDiff(live, liveData, edit, true)
    local reverted = SheetImage.fromImageData(liveData, { angles = 2, frames = 2 })
    ok(reverted and Sheet.coverage(reverted).total == 0,
       'and reversing the diff clears the picture as well as the buffer')

    ---------------------------------------------------------------------
    -- The panel itself, driven without a frame in flight.
    local spritePanel = SpritePanel.new{ angles = 8, frames = 4, cellW = 12, cellH = 12 }

    ok(spritePanel.id == 'sprite', 'the panel declares the id the shell routes by')
    ok(spritePanel.title ~= nil, 'and a title for its tab')
    ok(type(spritePanel.draw) == 'function', 'with the draw hook the shell calls')
    ok(type(spritePanel.drawSidebar) == 'function', 'a sidebar')
    ok(type(spritePanel.drawInspector) == 'function', 'and an inspector')
    ok(spritePanel.sheet ~= nil, 'and a sheet ready to paint on')
    ok(Sheet.coverage(spritePanel.sheet).total > 0,
       'that opens with something drawn rather than blank')

    spritePanel:rebuildImage()
    ok(spritePanel.image ~= nil, 'the panel builds a texture for its sheet')

    spritePanel:setCell(3, 2)
    ok(spritePanel.bucket == 3 and spritePanel.frame == 2, 'the active cell can be set')

    -- Painting through the panel's own stroke path, which is what the mouse
    -- drives, rather than through Sheet directly.
    local beforeStroke = Sheet.toBytes(spritePanel.sheet)
    spritePanel.tool = 'brush'
    spritePanel.color = 6
    spritePanel:strokeBegin(38, 30)
    spritePanel:strokeMove(40, 34)
    spritePanel:strokeEnd()

    ok(not Sheet.sameBytes(Sheet.toBytes(spritePanel.sheet), beforeStroke),
       'a stroke through the panel changes the sheet')
    ok(spritePanel.history:canUndo(), 'and lands on the undo stack as one step')
    ok(spritePanel.dirty, 'and marks the sheet unsaved')

    -- Clicking inside a cell makes that cell active, so a stroke can never
    -- straddle a boundary by accident.
    ok(spritePanel.bucket == 2, 'clicking inside a cell selected that bucket')
    ok(spritePanel.frame == 3, 'and that frame')

    ok(spritePanel:undo(), 'the panel undoes the stroke')
    ok(Sheet.sameBytes(Sheet.toBytes(spritePanel.sheet), beforeStroke),
       'restoring the sheet exactly')
    ok(spritePanel:redo(), 'and redoes it')

    -- Locking to the cell is what stops a fill in one frame flooding every bucket.
    spritePanel.tool = 'fill'
    spritePanel.color = 9
    spritePanel.lockToCell = true
    local fillCell = Sheet.cellBounds(spritePanel.sheet, 5, 1)
    spritePanel:strokeBegin(fillCell.x, fillCell.y)

    local spilled = 0
    for bucketIndex = 0, 7 do
        for frameIndex = 0, 3 do
            if not (bucketIndex == 5 and frameIndex == 1) then
                local cellRect = Sheet.cellBounds(spritePanel.sheet, bucketIndex, frameIndex)
                for py = cellRect.y, cellRect.y + cellRect.h - 1 do
                    for px = cellRect.x, cellRect.x + cellRect.w - 1 do
                        if Sheet.get(spritePanel.sheet, px, py) == 9 then
                            spilled = spilled + 1
                        end
                    end
                end
            end
        end
    end
    ok(spilled == 0, ('a locked fill stays in its own cell (%d pixels leaked)'):format(spilled))

    -- The preview runs the renderer's own facing maths. Asserting its choice
    -- against Billboard directly is the only way to know the preview and the
    -- renderer cannot drift apart.
    spritePanel.facing = 0
    spritePanel.orbit = 0
    local preview = spritePanel:previewState()
    ok(preview.bucket == Billboard.angleBucket(spritePanel.facing, preview.bearing,
                                               spritePanel.sheet.angles),
       'the preview picks the bucket meatray.sim.billboard picks')
    ok(preview.bucket >= 0 and preview.bucket < spritePanel.sheet.angles,
       'and it is a bucket the sheet actually has')

    -- Turning the previewed entity all the way round must visit every bucket, or
    -- the preview cannot reveal a sheet whose rows are in the wrong order.
    local seenBuckets, distinct = {}, 0
    for step = 0, 63 do
        spritePanel.facing = step / 64 * math.pi * 2
        local b = spritePanel:previewState().bucket
        if not seenBuckets[b] then seenBuckets[b] = true; distinct = distinct + 1 end
    end
    ok(distinct == 8, ('turning through a full circle shows all 8 buckets (saw %d)')
       :format(distinct))

    -- Regrid: the same pixels read under a different grid, which is how a
    -- transposed sheet gets diagnosed rather than guessed at.
    local beforeRegrid = Sheet.toBytes(spritePanel.sheet)
    spritePanel.fieldAngles = '4'
    spritePanel.fieldFrames = '8'
    ok(spritePanel:regrid(), 'the panel regrids to another exact division')
    ok(spritePanel.sheet.angles == 4, 'taking the new bucket count')
    ok(spritePanel.sheet.cellW == 6, 'with the cell size recomputed from it')
    ok(Sheet.sameBytes(Sheet.toBytes(spritePanel.sheet), beforeRegrid),
       'without moving a pixel')

    spritePanel.fieldAngles = '7'
    ok(not spritePanel:regrid(), 'and refuses a grid the image does not divide by')
    ok(spritePanel.sheet.angles == 4, 'leaving it on the grid it had')

    -- Export through the panel, then registration: the sheet just painted becomes
    -- a sprite the renderer draws. That loop is the reason to paint in-engine.
    spritePanel.fieldAngles = '4'
    spritePanel.name = 'painted_probe'
    ok(spritePanel:export(), 'the panel exports its sheet')
    ok(not spritePanel.dirty, 'and clears the unsaved marker')
    ok(spritePanel.path == 'assets/sprites/painted_probe_a4_f8.png',
       'to a path carrying its grid', spritePanel.path)

    ok(spritePanel:register(), 'and registers it as a sprite')
    local registered = MeatRay.sprites.get('painted_probe')
    ok(registered ~= nil, 'which the sprite registry now holds')
    ok(registered and not registered.generated, 'as an imported sheet, not a placeholder')
    ok(registered and registered.angles == 4, 'with the bucket count it was painted at')
    ok(registered and registered.frames == 8, 'and the frame count')
    ok(registered and registered.cellW == 6, 'sliced to the cells that grid implies')

    -- Loading it back into a fresh painter closes the loop.
    local reopened = SpritePanel.new{ blank = true, angles = 1, frames = 1 }
    ok(reopened:load(spritePanel.path), 'a new painter loads the exported sheet')
    ok(reopened.sheet.angles == 4, 'with the bucket count read off the filename')
    ok(reopened.sheet.frames == 8, 'and the frame count')
    ok(Sheet.sameBytes(Sheet.toBytes(reopened.sheet), Sheet.toBytes(spritePanel.sheet)),
       'and identical pixels to the sheet it came from')

    ok(not reopened:load('assets/sprites/no_such_sheet_a2_f2.png'),
       'loading a file that is not there reports failure rather than erroring')
    ok(reopened.sheet ~= nil, 'and leaves the painter holding the sheet it had')

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

    ---------------------------------------------------------------------
    -- Lighting, in front of a real GPU.
    --
    -- tests/test_lighting.lua proves the maths. What it cannot prove is that the
    -- numbers reach the framebuffer: that the wall loop samples the grid at the
    -- right point, that sprites take the same light as the wall behind them, and
    -- that a lit room is measurably brighter on screen than an unlit one. Every
    -- assertion below reads pixels back and compares them.
    ---------------------------------------------------------------------
    print('lighting')

    local Lighting = require('meatray.render.lighting')

    -- A wide flat corridor, so a single camera looking down it sees lit ground,
    -- coloured ground and unlit ground in one frame with no geometry in the way
    -- to confuse the comparison.
    --
    -- The `facility` theme, deliberately: its atmosphere is `clear`, so ambient
    -- is 1.0 and the view distance is long. Everything dark in these frames is
    -- dark because the light grid says so and not because the theme was dim to
    -- begin with, which is the only way the comparisons below mean anything.
    local LIGHT_THEME = 'facility'
    local LIGHT_ATMO = MeatRay.themes.atmosphere(LIGHT_THEME)

    local function corridor(w, h)
        local grid = {}
        for y = 1, h do
            grid[y] = {}
            for x = 1, w do
                grid[y][x] = (x == 1 or y == 1 or x == w or y == h) and 1 or 0
            end
        end
        return MeatRay.world.new(grid, { theme = LIGHT_THEME })
    end

    local LW, LH = 640, 400
    local lightCanvas = love.graphics.newCanvas(LW, LH)

    -- Mean colour over a rectangle of the last frame. Region comparisons rather
    -- than single pixels: one pixel can land on a texture speckle and say
    -- anything, an area cannot.
    local function meanRegion(imageData, x1, y1, x2, y2)
        local r, g, b, n = 0, 0, 0, 0
        for y = y1, y2 do
            for x = x1, x2 do
                local pr, pg, pb = imageData:getPixel(x, y)
                r = r + pr; g = g + pg; b = b + pb; n = n + 1
            end
        end
        if n == 0 then return 0, 0, 0 end
        return r / n, g / n, b / n
    end

    local function meanLuma(imageData, x1, y1, x2, y2)
        local r, g, b = meanRegion(imageData, x1, y1, x2, y2)
        return (r + g + b) / 3
    end

    -- Renders one frame of a lit world and hands back the image. `dynamics` is a
    -- list of lights declared for this frame only.
    local function litFrame(name, lightGrid, lworld, camX, camY, camAngle, ents, dynamics)
        if lightGrid then
            lightGrid:beginFrame()
            for _, d in ipairs(dynamics or {}) do lightGrid:addDynamic(d) end
        end
        MeatRay.raycaster.setLighting(lightGrid)

        local v = MeatRay.raycaster.view(camX, camY, camAngle)
        love.graphics.setCanvas(lightCanvas)
        love.graphics.clear(0, 0, 0, 1)
        local z = MeatRay.raycaster.render(v, lworld)
        -- The same ambient and view distance the wall loop just used. Handing
        -- sprites different numbers is exactly the mismatch that makes an entity
        -- look pasted on top of the render.
        MeatRay.sprites.draw(ents or {}, z, v, {
            screenW = LW, screenH = LH, time = 0, alpha = 1,
            ambient = LIGHT_ATMO.ambient, maxView = LIGHT_ATMO.maxView,
            lighting = lightGrid,
        })
        love.graphics.setCanvas()

        local image = lightCanvas:newImageData()
        if name then image:encode('png', name .. '.png') end
        return image
    end

    MeatRay.raycaster.init{ width = LW, height = LH, theme = LIGHT_THEME }

    -----------------------------------------------------------------
    -- 1. A lit stretch and an unlit stretch of the same corridor.
    -----------------------------------------------------------------
    local HALL_W, HALL_H = 20, 9
    local hall = corridor(HALL_W, HALL_H)
    local hallLights = Lighting.new{ world = hall, baseLevel = 0.30 }
    hallLights:addStatic{ x = 4.5, y = 2.5, radius = 6,
                          color = { 1.00, 0.60, 0.24 }, intensity = 1.2 }
    hallLights:addStatic{ x = 4.5, y = 6.5, radius = 6,
                          color = { 1.00, 0.60, 0.24 }, intensity = 1.2 }
    hallLights:addStatic{ x = 8.5, y = 2.5, radius = 5,
                          color = { 0.24, 0.55, 1.00 }, intensity = 1.2 }
    hallLights:update()

    ok(hallLights:report().cellsBakedLastUpdate == HALL_W * HALL_H,
       'the corridor baked once, covering the map')

    local corridorShot = litFrame('shot_light_corridor', hallLights, hall, 2.2, 4.5, 0)

    -- The near half of the frame is the lit end; the far half, past the lights,
    -- is the unlit end. In a corridor drawn straight down its length that is a
    -- left/right split on screen only in depth, so compare the wall band by
    -- height instead: the near walls fill the edges of the frame, the far end
    -- sits in the middle.
    local nearWall = meanLuma(corridorShot, 8, 120, 70, 280)
    local farEnd = meanLuma(corridorShot, LW / 2 - 30, 170, LW / 2 + 30, 230)
    ok(nearWall > farEnd * 1.5,
       ('the lit near wall is brighter than the unlit far end (%.3f vs %.3f)')
           :format(nearWall, farEnd))
    ok(farEnd > 0.02,
       ('and the unlit far end is still above black (%.3f) - the readability floor')
           :format(farEnd))

    -----------------------------------------------------------------
    -- 2. The readability floor, at its worst case: a room with no light in it
    --    at all and a base level of zero.
    -----------------------------------------------------------------
    local pitchWorld = corridor(HALL_W, HALL_H)
    local pitchLights = Lighting.new{ world = pitchWorld, baseLevel = 0 }
    pitchLights:update()
    local pitchShot = litFrame('shot_light_floor', pitchLights, pitchWorld, 2.2, 4.5, 0)

    local pitchWall = meanLuma(pitchShot, 8, 130, 90, 270)
    ok(pitchWall > 0.03,
       ('a wall in a totally unlit room still renders above black (%.3f)'):format(pitchWall))

    -- And the floor is a floor, not the whole story: an unlit wall must still be
    -- clearly darker than a lit one, or "lighting" would mean nothing.
    local litWall = meanLuma(corridorShot, 8, 130, 90, 270)
    ok(litWall > pitchWall * 1.4,
       ('while a lit wall is clearly brighter (%.3f vs %.3f)'):format(litWall, pitchWall))

    -----------------------------------------------------------------
    -- 3. A coloured light tints the wall it falls on.
    -----------------------------------------------------------------
    local tintWorld = corridor(9, 9)
    local tintLights = Lighting.new{ world = tintWorld, baseLevel = 0.25 }
    tintLights:addStatic{ x = 7.0, y = 2.2, radius = 5,
                          color = { 1.00, 0.14, 0.08 }, intensity = 1.4 }
    tintLights:addStatic{ x = 7.0, y = 6.8, radius = 5,
                          color = { 0.10, 0.30, 1.00 }, intensity = 1.4 }
    tintLights:update()

    -- Nose to the end wall, with a red source off to one side of it and a blue
    -- source off to the other. The camera looks along +x, so the low-y half of
    -- the world lands on the left of the frame and the high-y half on the right:
    -- one flat grey wall, two tints, split down the middle of the screen.
    local tintShot = litFrame('shot_light_colour', tintLights, tintWorld, 6.5, 4.5, 0)

    local lr2, lg2, lb2 = meanRegion(tintShot, 20, 110, 280, 290)     -- left half
    local rr2, rg2, rb2 = meanRegion(tintShot, LW - 280, 110, LW - 20, 290)  -- right half

    -- Compared as ratios, which takes the wall's own colour out of the answer:
    -- the facility palette is already slightly blue, and a test that could be
    -- passed by the texture rather than by the light is not a test of the light.
    local leftBias = lr2 / math.max(lb2, 1e-6)
    local rightBias = rr2 / math.max(rb2, 1e-6)
    ok(leftBias > rightBias * 1.4,
       ('the red-lit half is far redder than the blue-lit half (r/b %.2f vs %.2f)')
           :format(leftBias, rightBias))
    ok(lr2 > lb2, ('and reads red over blue outright (%.3f vs %.3f)'):format(lr2, lb2))
    ok(rb2 > rr2, ('while the blue-lit half reads blue over red (%.3f vs %.3f)')
           :format(rb2, rr2))
    ok(lg2 < lr2 and rg2 < rb2, 'with green below the dominant channel in both')

    -----------------------------------------------------------------
    -- 4. A sprite takes the light where it stands.
    -----------------------------------------------------------------
    local spriteWorld = corridor(20, 9)
    local spriteLights = Lighting.new{ world = spriteWorld, baseLevel = 0.22 }
    spriteLights:addStatic{ x = 6.5, y = 4.5, radius = 6.5,
                            color = { 1.0, 0.85, 0.6 }, intensity = 0.9 }
    spriteLights:update()

    -- Same sprite, same distance from the camera, same screen position. Only the
    -- light where it is standing differs, because the camera moves with it.
    local function spriteBrightnessAt(name, sx)
        local subject = Entity.spawn('probe', sx, 4.5)
        subject.angle = math.pi
        subject:snapPrevious()
        local image = litFrame(name, spriteLights, spriteWorld, sx - 3, 4.5, 0, { subject })

        -- The sprite sits centred; sample only pixels bright enough to be the
        -- sprite's red body rather than the wall behind it.
        local r, n = 0, 0
        for y = 150, 300 do
            for x = LW / 2 - 40, LW / 2 + 40 do
                local pr, pg, pb = image:getPixel(x, y)
                if pr > pg * 1.4 and pr > pb * 1.4 then r = r + pr; n = n + 1 end
            end
        end
        return n > 0 and (r / n) or 0, n
    end

    local litSprite, litPixels = spriteBrightnessAt('shot_light_sprite_lit', 6.5)
    local darkSprite, darkPixels = spriteBrightnessAt('shot_light_sprite_shadow', 15.5)

    ok(litPixels > 200 and darkPixels > 200,
       ('the sprite is drawn in both frames (%d lit / %d dark pixels)')
           :format(litPixels, darkPixels))
    ok(litSprite > darkSprite * 1.3,
       ('a sprite under a light is brighter than the same sprite in the dark (%.3f vs %.3f)')
           :format(litSprite, darkSprite))
    ok(darkSprite > 0.05,
       ('and the one in the dark is still visible, not black (%.3f)'):format(darkSprite))

    -----------------------------------------------------------------
    -- 5. Light does not pass through a wall.
    -----------------------------------------------------------------
    local splitWorld = corridor(24, 9)
    for y = 1, 9 do splitWorld.grid[y][12] = 1 end        -- a full-height divider

    -- A bright light on the far side of the divider, and a camera on the near
    -- side looking straight at it. If light leaked, the near face would glow.
    local blockLights = Lighting.new{ world = splitWorld, baseLevel = 0.20 }
    blockLights:addStatic{ x = 13.5, y = 4.5, radius = 14, intensity = 1.4 }
    blockLights:update()
    local blockedShot = litFrame('shot_light_blocked', blockLights, splitWorld, 6.5, 4.5, 0)

    -- The same light, told not to cast shadows. Nothing else differs, so any
    -- change on screen is the wall doing its job in the first frame.
    local leakLights = Lighting.new{ world = splitWorld, baseLevel = 0.20 }
    leakLights:addStatic{ x = 13.5, y = 4.5, radius = 14, intensity = 1.4, shadows = false }
    leakLights:update()
    local leakedShot = litFrame('shot_light_through_wall', leakLights, splitWorld, 6.5, 4.5, 0)

    local blockedFace = meanLuma(blockedShot, LW / 2 - 60, 150, LW / 2 + 60, 250)
    local leakedFace = meanLuma(leakedShot, LW / 2 - 60, 150, LW / 2 + 60, 250)
    ok(leakedFace > blockedFace * 1.5,
       ('a light behind a wall does not light its near face (%.3f blocked vs %.3f leaking)')
           :format(blockedFace, leakedFace))

    -----------------------------------------------------------------
    -- 6. A door opening relights the room behind it, and only that.
    -----------------------------------------------------------------
    local DOOR_W, DOOR_H = 40, 11
    local doorWorld = corridor(DOOR_W, DOOR_H)
    for y = 1, DOOR_H do doorWorld.grid[y][12] = 1 end
    -- A back wall a few tiles behind the door, so what is on the far side is a
    -- lit surface rather than empty corridor running past the view distance.
    for y = 1, DOOR_H do doorWorld.grid[y][16] = 1 end
    doorWorld:addDoor(12, 4, false)

    local doorLights = Lighting.new{ world = doorWorld, baseLevel = 0.20 }
    doorLights:addStatic{ x = 13.5, y = 3.5, radius = 7, intensity = 1.5 }
    doorLights:update()
    local shutShot = litFrame('shot_light_door_shut', doorLights, doorWorld, 6.5, 3.5, 0)

    doorWorld:setDoorOpen(12, 4, true)
    doorWorld:update(1, 100)          -- finish the slide immediately
    doorLights:invalidateTile(12, 4)
    doorLights:update()
    local relit = doorLights:report().cellsBakedLastUpdate
    ok(relit > 0 and relit < DOOR_W * DOOR_H * 0.5,
       ('opening a door rebaked %d of %d cells, not the whole map')
           :format(relit, DOOR_W * DOOR_H))

    local openShot = litFrame('shot_light_door_open', doorLights, doorWorld, 6.5, 3.5, 0)
    -- Sample only what the doorway itself covers on screen: a wider region is
    -- mostly the wall either side of it, which did not change and should not.
    local shutLuma = meanLuma(shutShot, LW / 2 - 35, 175, LW / 2 + 35, 225)
    local openLuma = meanLuma(openShot, LW / 2 - 35, 175, LW / 2 + 35, 225)
    ok(openLuma > shutLuma * 1.5,
       ('and light spills through the opening (%.3f shut vs %.3f open)')
           :format(shutLuma, openLuma))

    -----------------------------------------------------------------
    -- 7. A dynamic light moves for free.
    -----------------------------------------------------------------
    local carried = Lighting.new{ world = corridor(24, 9), baseLevel = 0.15 }
    carried:update()
    local bakedCells = carried:report().cellsBaked

    local torchShot
    for step = 1, 30 do
        torchShot = litFrame(step == 30 and 'shot_light_torch' or nil,
                             carried, carried.world, 3.0 + step * 0.2, 4.5, 0, nil,
                             { { x = 3.0 + step * 0.2, y = 4.5, radius = 9,
                                 color = { 1.0, 0.86, 0.62 }, intensity = 1.3 } })
    end
    ok(carried:report().cellsBaked == bakedCells,
       'thirty frames of a moving torch rebaked nothing')

    -- The ground at the torch's feet: the bottom of the frame, which at this
    -- camera height is floor one to two tiles ahead and nothing else.
    --
    -- This region used to be the band at 8..80 x 130..270, described as "the
    -- wall beside it", and it was neither. The nearest wall a 24x9 corridor
    -- offers a camera on its centre line is 6.5 tiles away, which a radius-9
    -- torch reaches at less than the readability floor -- so the torch never
    -- moved a wall pixel in this frame. What that region actually measured was
    -- floor and ceiling, lifted wholesale by the single light sample the
    -- background used to take at the camera. That sample is exactly what per-
    -- pixel floor lighting replaced, so the assertion is restated as the thing
    -- it was really measuring, on the surface that now carries a real gradient.
    local torchNear = meanLuma(torchShot, 20, 320, LW - 20, LH - 5)
    local darkShot = litFrame(nil, carried, carried.world, 9.0, 4.5, 0)
    local torchOff = meanLuma(darkShot, 20, 320, LW - 20, LH - 5)
    ok(torchNear > torchOff * 1.4,
       ('and the carried torch pools on the floor at its feet (%.3f lit vs %.3f unlit)')
           :format(torchNear, torchOff))

    -----------------------------------------------------------------
    -- 7b. Explosions and burning gas, lighting the room they happen in.
    --
    -- meatray/game/ may not touch the renderer, so an explosion DESCRIBES its
    -- flash and hands it out; whoever holds a light grid pushes it. This is that
    -- contract exercised end to end: the blast is detonated by the headless
    -- gameplay module, the light it described is pushed into a grid it has never
    -- heard of, and the frame is measured to see that it actually got brighter.
    --
    -- The same section renders the fire the blast left behind: a gas field is a
    -- scalar over tiles, and one dynamic light per burning tile is how a demo
    -- turns it into something you can see.
    --
    -- Wrapped in a function of its own because Lua allows two hundred locals per
    -- function and this one is a single very long test. A `do ... end` block is
    -- not enough: it frees registers at the end, but the ceiling is the PEAK, and
    -- the peak is inside the block. A function has its own register space.
    -----------------------------------------------------------------
    ;(function()
    local Game = require('meatray.game')

    local blastWorld = corridor(14, 9)
    local blastLights = Lighting.new{ world = blastWorld, baseLevel = 0.22 }
    blastLights:update()

    -- 'probe8' is the sprite this file defined at the top; the point of the frame
    -- is the light, and a subject in it is what shows the light reaching a sprite
    -- and a wall by the same rule.
    local victim = Entity.new{ kind = 'imp', x = 9.5, y = 4.5, angle = math.pi }
    victim:add(C.Billboard{ sheet = 'probe8' })
    victim:add(C.Health{ hp = 200, max = 200 })
    victim.radius = 0.28
    Game.attach(victim, { authority = true })

    -- Nothing here is a light grid, and detonate does not know one exists.
    local described = nil
    local blast = Game.explosion.detonate{
        world = blastWorld, entities = { victim },
        x = 9.5, y = 4.5, radius = 5, damage = 90, curve = 'smooth',
        tags = { 'damage.type.explosive' },
        light = { radius = 11, intensity = 2.4, color = { 1.00, 0.74, 0.36 } },
        onLight = function(l) described = l end,
    }

    ok(blast ~= nil and #blast.hits == 1, 'the explosion caught the imp standing on it')
    ok(MeatRay.game.attributes.get(victim, 'health') < 200,
       ('and took it from 200 to %d, through the effect system')
           :format(MeatRay.game.attributes.get(victim, 'health')))
    ok(described ~= nil, 'and described a flash for whoever is holding a light grid')

    local darkRoom = litFrame('shot_explosion_dark', blastLights, blastWorld,
                              5.0, 4.5, 0, { victim }, {})
    local flashFrame = litFrame('shot_explosion_flash', blastLights, blastWorld,
                                5.0, 4.5, 0, { victim }, { described })

    local unlit = meanLuma(darkRoom, 0, 0, LW - 1, LH - 1)
    local flashed = meanLuma(flashFrame, 0, 0, LW - 1, LH - 1)
    ok(flashed > unlit * 1.3,
       ('the flash lights the room it went off in (%.3f vs %.3f unlit)')
           :format(flashed, unlit))

    -- The blast's own light is warm, which is what makes it read as an explosion
    -- rather than as somebody turning the lights on. Measured as a SHIFT against
    -- the same frame unlit, because the absolute colour of a frame is mostly the
    -- theme's walls and says nothing about the light that hit them.
    local dr, _, db = meanRegion(darkRoom, 0, 0, LW - 1, LH - 1)
    local fr, _, fb = meanRegion(flashFrame, 0, 0, LW - 1, LH - 1)
    ok((fr / fb) > (dr / db) * 1.05,
       ('and it is warm: the flash shifts the frame red/blue from %.3f to %.3f')
           :format(dr / db, fr / fb))

    -- Now the fire it left. A gas field spread over the corridor, then one light
    -- per burning tile.
    local fire = Game.gas.new{ world = blastWorld, name = 'fire', rate = 1.1, decay = 0.4 }
    local seeded = fire:emitCircle(9.5, 4.5, 2.4, 30)
    ok(seeded > 0, ('the blast seeded %.1f units of fire'):format(seeded))

    local visitedTotal = 0
    for _ = 1, 20 do
        local visits = fire:step(1 / 60)
        visitedTotal = visitedTotal + visits
    end
    ok(visitedTotal > 0, ('twenty steps of gas cost %d cell visits'):format(visitedTotal))
    ok(visitedTotal < blastWorld.width * blastWorld.height * 20,
       'which is less than walking the grid every step would have cost')

    local fireLights = {}
    fire:each(function(tx, ty, d)
        if d > 0.25 and #fireLights < 24 then
            local strength = d > 1 and 1 or d
            fireLights[#fireLights + 1] = {
                x = tx - 0.5, y = ty - 0.5,
                radius = 2.2 + strength * 2.0,
                intensity = 0.5 + strength * 0.9,
                color = { 1.00, 0.52, 0.18 }, curve = 'inverse',
            }
        end
    end)

    ok(#fireLights > 0, ('%d tiles are burning brightly enough to glow'):format(#fireLights))

    -- Measured where the fire actually is. The camera sits back down the
    -- corridor, so most of the frame is floor and ceiling the fire never reaches;
    -- averaging over all of it would dilute the thing being measured into noise,
    -- which is one way to write a test that passes on a black screen.
    local FX1, FY1 = math.floor(LW * 0.30), math.floor(LH * 0.30)
    local FX2, FY2 = math.floor(LW * 0.70), math.floor(LH * 0.72)

    local fireDark = litFrame(nil, blastLights, blastWorld, 5.0, 4.5, 0, { victim }, {})
    local fireFrame = litFrame('shot_gas_fire', blastLights, blastWorld,
                               5.0, 4.5, 0, { victim }, fireLights)

    local coldBand = meanLuma(fireDark, FX1, FY1, FX2, FY2)
    local burning = meanLuma(fireFrame, FX1, FY1, FX2, FY2)
    ok(burning > coldBand * 1.15,
       ('and the burning tiles light the corridor (%.3f vs %.3f unlit)')
           :format(burning, coldBand))

    local cr, _, cb = meanRegion(fireDark, FX1, FY1, FX2, FY2)
    local br, _, bb = meanRegion(fireFrame, FX1, FY1, FX2, FY2)
    -- A smaller shift than the explosion's, and correctly so: burning tiles are
    -- small, dim and scattered, where the blast is one enormous light at the
    -- camera's eye level. The claim is only that fire's colour reaches the walls.
    ok((br / bb) > (cr / cb) * 1.02,
       ('with fire\'s own colour on the walls: red/blue %.3f to %.3f')
           :format(cr / cb, br / bb))
    end)()

    -----------------------------------------------------------------
    -- 7c. Per-pixel floor and ceiling lighting.
    --
    -- Until this, the floor took ONE light sample, at the camera, and the entire
    -- lower half of the frame was multiplied by it. The cast had given the floor
    -- a real per-pixel distance, which fixed the fog; it had no per-pixel
    -- position in the light grid, so a torch lit the walls around it and did not
    -- pool on the ground. The grid now goes to the GPU as a texture, one texel
    -- per world tile, and every assertion below is a claim the single sample
    -- could not have satisfied.
    --
    -- `setLightTexture(false)` puts the single sample back, which is what makes
    -- these comparisons two renders of one build rather than two commits.
    --
    -- Its own function, not a do-block, for the reason written on 7b: Lua 5.1
    -- allows two hundred locals per function and the ceiling is the peak, which
    -- is inside a block.
    -----------------------------------------------------------------
    ;(function()

    -- A corridor with one source well off the camera's axis and close to one
    -- wall, so "near the light" and "far from the light" are the two halves of a
    -- single frame rather than two frames. Comparing halves of one frame is what
    -- takes fog, camera and geometry out of the answer: both halves are at the
    -- same depth on the same screen row, and only the light differs.
    local pxWorld = corridor(24, 9)
    local CAMX, CAMY = 6.5, 4.5

    -- A base level clear of MIN_VISIBILITY, deliberately. Below the readability
    -- floor every unlit surface clamps to the same value whichever path drew it,
    -- and a comparison between two renders that both bottomed out says nothing.
    local pxLights = Lighting.new{ world = pxWorld, baseLevel = 0.55 }
    pxLights:addStatic{ x = 12.5, y = 2.2, radius = 5,
                        color = { 1.0, 0.78, 0.45 }, intensity = 1.4 }
    -- A second source, standing exactly where the camera stands. This is the
    -- picture the old renderer got wrong in the most visible way: the one sample
    -- it took was this one, so a torch at your feet lifted the floor all the way
    -- to the horizon at full strength. Both bands below sit outside its radius,
    -- so per pixel it must reach neither of them.
    pxLights:addStatic{ x = CAMX, y = CAMY, radius = 5,
                        color = { 1.0, 0.86, 0.62 }, intensity = 1.3 }
    pxLights:update()

    -- The camera looks along +x and the camera plane runs along +y, so the low-y
    -- half of the world lands on the left of the frame. The first light sits at
    -- y=2.2: the left band is the floor around it, the right band is the floor
    -- across the corridor from it.
    --
    -- The two bands are exact mirror images of each other about the centre of
    -- the frame, and the corridor is symmetric about the camera's line, so they
    -- are at the same depths, behind the same wall edges and under the same fog.
    -- The light is the only thing that differs between them.
    local ROW1, ROW2 = 224, 248        -- floor 4.2 to 8.3 tiles ahead
    local NEARX1, NEARX2 = 40, 180
    local FARX1, FARX2 = LW - 1 - NEARX2, LW - 1 - NEARX1

    -- Renders and hands back the picture AND the z-buffer, which is what lets
    -- the comparison below say "this pixel is wall" instead of guessing from a
    -- screen row.
    local function frame(grid, dynamics, name)
        grid:beginFrame()
        for _, d in ipairs(dynamics or {}) do grid:addDynamic(d) end
        MeatRay.raycaster.setLighting(grid)
        local v = MeatRay.raycaster.view(CAMX, CAMY, 0)
        love.graphics.setCanvas(lightCanvas)
        love.graphics.clear(0, 0, 0, 1)
        local z = MeatRay.raycaster.render(v, pxWorld)
        love.graphics.setCanvas()
        local image = lightCanvas:newImageData()
        if name then image:encode('png', name .. '.png') end
        return image, z
    end

    local function differing(a, b)
        local n = 0
        for y = 0, LH - 1 do
            for x = 0, LW - 1 do
                local r1, g1, b1 = a:getPixel(x, y)
                local r2, g2, b2 = b:getPixel(x, y)
                if r1 ~= r2 or g1 ~= g2 or b1 ~= b2 then n = n + 1 end
            end
        end
        return n
    end

    ok(MeatRay.raycaster.lightTexture(), 'per-pixel floor lighting is on by default')

    -- The determinism control, first, and for the same reason the floor cast
    -- needed one: without it "the walls are identical" is equally consistent
    -- with a comparison that cannot find a difference at all. The light texture
    -- is rebuilt on every render, so this also says the rebuild lands on the
    -- same bytes twice.
    local perPixel, pz = frame(pxLights, nil, 'shot_light_perpixel')
    ok(differing(perPixel, (frame(pxLights))) == 0,
       'two renders of the same build, camera and grid are pixel-identical')

    MeatRay.raycaster.setLightTexture(false)
    local oneSample = frame(pxLights, nil, 'shot_light_onesample')
    MeatRay.raycaster.setLightTexture(true)

    ---------------------------------------------------------------
    -- Nothing but the background moved.
    ---------------------------------------------------------------
    -- Wall strips recovered from the z-buffer the way the wall loop derived
    -- them. A column that hit nothing carries maxView and drew no strip; its
    -- phantom strip would file floor pixels under walls and hide the exact
    -- regression this is looking for.
    local spanTop, spanBot = {}, {}
    for x = 0, LW - 1 do
        local d = pz[x]
        spanTop[x], spanBot[x] = -1, -1
        if d ~= nil and d < LIGHT_ATMO.maxView - 1e-6 then
            local lineHeight = math.floor(LH / d)
            spanTop[x] = math.floor(-lineHeight / 2 + LH / 2)
            spanBot[x] = math.floor(lineHeight / 2 + LH / 2)
        end
    end

    local wallSame, wallDiff, bgSame, bgDiff = 0, 0, 0, 0
    for x = 0, LW - 1 do
        for y = 0, LH - 1 do
            local r1, g1, b1 = oneSample:getPixel(x, y)
            local r2, g2, b2 = perPixel:getPixel(x, y)
            local same = (r1 == r2 and g1 == g2 and b1 == b2)
            if y >= spanTop[x] and y < spanBot[x] then
                if same then wallSame = wallSame + 1 else wallDiff = wallDiff + 1 end
            -- One row of slack on each edge of a strip belongs to neither side.
            elseif y < spanTop[x] - 1 or y > spanBot[x] then
                if same then bgSame = bgSame + 1 else bgDiff = bgDiff + 1 end
            end
        end
    end

    ok(wallSame + wallDiff > LW * 10,
       ('%d wall pixels were compared'):format(wallSame + wallDiff))
    ok(wallDiff == 0,
       ('every one of them is unchanged (%d differ) - the wall loop was not touched')
           :format(wallDiff))
    ok(bgSame + bgDiff > LW * 10,
       ('%d background pixels were compared'):format(bgSame + bgDiff))
    ok(bgDiff / math.max(1, bgSame + bgDiff) > 0.5,
       ('and %.0f%% of them changed'):format(
           bgDiff / math.max(1, bgSame + bgDiff) * 100))

    ---------------------------------------------------------------
    -- A gradient on the floor, inside one frame.
    ---------------------------------------------------------------
    -- Floor only, and the z-buffer is what says which pixels those are. The
    -- background quad is drawn first and the walls paint over it, so a band
    -- picked by screen row alone collects wall wherever a wall reaches that row —
    -- which at the outer edges of these bands it does, and those pixels would be
    -- measuring the wall loop rather than the floor.
    local function floorMean(image, x1, x2)
        local sum, n = 0, 0
        for x = x1, x2 do
            local b = spanBot[x]
            for y = math.max(ROW1, b + 1), ROW2 do
                local r, g, bl = image:getPixel(x, y)
                sum = sum + (r + g + bl) / 3
                n = n + 1
            end
        end
        return (n > 0) and (sum / n) or 0, n
    end

    local function ratio(image)
        local near, n = floorMean(image, NEARX1, NEARX2)
        local far = floorMean(image, FARX1, FARX2)
        return near / math.max(far, 1e-6), near, far, n
    end

    local litRatio, litNear, litFar, floorN = ratio(perPixel)
    local flatRatio = ratio(oneSample)

    ok(floorN > 1000, ('%d floor pixels in each band'):format(floorN))
    ok(litRatio > 1.5,
       ('floor beside the light is %.2fx the floor across from it, same rows, same frame (%.3f vs %.3f)')
           :format(litRatio, litNear, litFar))
    -- The control that makes the number above mean something: those two bands
    -- are mirror images at the same depth under the same fog, so with one sample
    -- standing in for the whole surface they had to come out the same, and they
    -- did.
    ok(flatRatio < 1.1,
       ('while one sample at the camera gives the same two bands %.2fx - no gradient at all')
           :format(flatRatio))

    ---------------------------------------------------------------
    -- The torch, which is the case a player judges this by.
    --
    -- A dynamic light is not in the bake; it is declared per frame and folded in
    -- at sample time. Uploading only the baked cells would have left this frame
    -- looking exactly like the bug.
    ---------------------------------------------------------------
    -- A fresh grid with NO static light in it at all, so the only thing that can
    -- brighten the floor below is the dynamic one.
    local torchGrid = Lighting.new{ world = pxWorld, baseLevel = 0.55 }
    torchGrid:update()
    local bakedBefore = torchGrid:report().cellsBaked

    local TORCH = { { x = 12.5, y = 2.2, radius = 5,
                      color = { 1.0, 0.78, 0.45 }, intensity = 1.4 } }

    local torched = frame(torchGrid, TORCH, 'shot_light_perpixel_torch')
    local unlit = frame(torchGrid, nil)

    local torchRatio, torchNear, torchFar = ratio(torched)
    ok(torchRatio > 1.5,
       ('a DYNAMIC light pools on the floor too: %.2fx across one frame (%.3f vs %.3f)')
           :format(torchRatio, torchNear, torchFar))

    ok(torchGrid:report().cellsBaked == bakedBefore,
       'and lighting the floor from it rebaked no cells')

    -- Local, which is the objection that kept the old band from ever brightening
    -- anything: one sample for the whole surface would have lifted the floor all
    -- the way to the horizon. The far band is across the corridor from the torch
    -- and must barely move.
    local _, unlitNear, unlitFar = ratio(unlit)
    ok(torchNear > unlitNear * 1.4,
       ('the torch brightens the floor beside it (%.3f vs %.3f unlit)')
           :format(torchNear, unlitNear))
    ok(torchFar < unlitFar * 1.15,
       ('and leaves the floor away from it alone (%.3f vs %.3f unlit)')
           :format(torchFar, unlitFar))

    ---------------------------------------------------------------
    -- Sprites are untouched, and measurably so.
    --
    -- They take their light from Grid:sample, which this change did not alter --
    -- but "did not alter" is a claim about a diff, and a sprite that had picked
    -- up the floor's new light would be a sprite lit twice. This measures it.
    ---------------------------------------------------------------
    -- Off to one side of the sprite and not on top of it: a source at the
    -- subject's own feet blows the red channel out to 1.0, and two saturated
    -- numbers agree whatever either of them was really doing.
    local white = Lighting.new{ world = pxWorld, baseLevel = 0.30 }
    white:addStatic{ x = 10.5, y = 2.2, radius = 5,
                     color = { 1, 1, 1 }, intensity = 1.0 }
    white:update()

    local subject = Entity.spawn('probe', 10.5, 4.5)
    subject.angle = math.pi
    subject:snapPrevious()

    local function spriteFrame()
        white:beginFrame()
        MeatRay.raycaster.setLighting(white)
        local v = MeatRay.raycaster.view(CAMX, CAMY, 0)
        love.graphics.setCanvas(lightCanvas)
        love.graphics.clear(0, 0, 0, 1)
        local z = MeatRay.raycaster.render(v, pxWorld)
        MeatRay.sprites.draw({ subject }, z, v, {
            screenW = LW, screenH = LH, time = 0, alpha = 1,
            ambient = LIGHT_ATMO.ambient, maxView = LIGHT_ATMO.maxView,
            lighting = white,
        })
        love.graphics.setCanvas()
        return lightCanvas:newImageData()
    end

    -- A WHITE source for this frame, deliberately: the probe sheet's body is red,
    -- and a warm light would tint the floor into the same filter and quietly turn
    -- this into a measurement of the floor.
    local function spriteBody(image)
        local sum, n = 0, 0
        for y = 100, 320 do
            for x = LW / 2 - 60, LW / 2 + 60 do
                local r, g, b = image:getPixel(x, y)
                if r > g * 1.4 and r > b * 1.4 then sum = sum + r; n = n + 1 end
            end
        end
        return n, (n > 0) and (sum / n) or 0
    end

    MeatRay.raycaster.setLightTexture(false)
    local offN, offMean = spriteBody(spriteFrame())
    MeatRay.raycaster.setLightTexture(true)
    local onN, onMean = spriteBody(spriteFrame())

    ok(onN > 500, ('%d sprite pixels found to compare'):format(onN))
    ok(onMean < 0.99,
       ('and they are not saturated, so the comparison can see a difference (%.3f)')
           :format(onMean))
    ok(onN == offN,
       ('the same sprite pixels either way (%d vs %d)'):format(onN, offN))
    ok(math.abs(onMean - offMean) < 1e-6,
       ('and exactly as bright (%.6f vs %.6f)'):format(onMean, offMean))

    ---------------------------------------------------------------
    -- The floor and the wall standing on it agree.
    --
    -- The rule that keeps light from leaking through a wall -- a solid neighbour
    -- contributes nothing to the interpolation, and its weight falls back to the
    -- tile the sample is in -- lives in Lua for the wall loop and in the shader
    -- for the floor. If the shader did not carry it, the floor at the base of
    -- every wall would blend halfway toward the unlit interior of that wall, and
    -- every wall in the level would stand in a dark ring of its own making.
    --
    -- Stated as a ratio of ratios so it needs no predicted pixel value: in a
    -- FLAT grid the floor-to-wall brightness at a wall base is whatever the
    -- textures and the side shade make it, and in a LIT grid it must be the
    -- same, because the light either side of that junction is the same light.
    ---------------------------------------------------------------
    local flatGrid = Lighting.new{ world = pxWorld, baseLevel = 0.85 }
    flatGrid:update()
    local flatShot = frame(flatGrid, nil)

    local function baseJunction(image)
        local wall, wallN, floorSum, floorN = 0, 0, 0, 0
        for x = NEARX1, NEARX2 do
            local b = spanBot[x]
            if b > 0 and b + 7 < LH and b - 7 > 0 then
                for dy = 2, 6 do
                    local r, g, bl = image:getPixel(x, b - dy)
                    wall = wall + (r + g + bl) / 3; wallN = wallN + 1
                    local fr, fg, fb = image:getPixel(x, b + dy)
                    floorSum = floorSum + (fr + fg + fb) / 3; floorN = floorN + 1
                end
            end
        end
        if wallN == 0 or wall <= 0 then return nil end
        return (floorSum / floorN) / (wall / wallN), wallN
    end

    local litJunction, junctionN = baseJunction(perPixel)
    local flatJunction = baseJunction(flatShot)

    ok(junctionN ~= nil and junctionN > 200,
       ('%s wall-base samples on both sides of the junction')
           :format(tostring(junctionN)))
    ok(litJunction ~= nil and flatJunction ~= nil and litJunction > flatJunction * 0.8,
       ('the floor at a lit wall base keeps its place against the wall (%.3f lit vs %.3f flat)')
           :format(litJunction or -1, flatJunction or -1))

    ---------------------------------------------------------------
    -- And the floor never goes below the readability floor, which is the whole
    -- point of MIN_VISIBILITY and the one thing per-pixel lighting could
    -- plausibly have broken: the band clamped one sample, the texture clamps
    -- after an interpolation.
    ---------------------------------------------------------------
    local darkGrid = Lighting.new{ world = pxWorld, baseLevel = 0 }
    darkGrid:update()
    local darkFloor = meanLuma(frame(darkGrid, nil), 20, LH - 60, LW - 20, LH - 5)
    ok(darkFloor > 0.03,
       ('the floor of a totally unlit room still renders above black (%.3f)')
           :format(darkFloor))

    end)()

    -----------------------------------------------------------------
    -- 8. The demo's own policy, on the demo's own map.
    --
    -- Everything above is a scene built to show one thing at a time. This is
    -- main.lua's placement rule run against maps/arena.map, which is the frame a
    -- player actually gets — and the one worth looking at when deciding whether
    -- the readability floor is set right.
    -----------------------------------------------------------------
    local demo = _G.MEATRAY_DEMO
    if demo and demo.lightingFor then
        local demoLights = demo.lightingFor(world)
        ok(demoLights ~= nil, 'the demo builds a light grid for the authored map')

        if demoLights then
            ok(demoLights:staticCount() > 0,
               ('and places %d static lights on it'):format(demoLights:staticCount()))

            MeatRay.raycaster.init{ width = LW, height = LH, theme = authored and authored.theme }
            local demoShot = litFrame('shot_light_demo_torch', demoLights, world,
                                      px, py, 0.4, nil,
                                      { { x = px, y = py, radius = 6.5, intensity = 0.9,
                                          color = { 1.00, 0.86, 0.62 } } })
            ok(coverage(demoShot) > 0.5, 'the demo frame renders')

            -- The same frame with the torch dropped. Nothing else changes, so the
            -- pair is the whole claim: carrying a light matters, and putting it
            -- out still leaves a level you can walk through.
            local demoDark = litFrame('shot_light_demo_notorch', demoLights, world,
                                      px, py, 0.4, nil, {})
            local withTorch = meanLuma(demoShot, 0, 0, LW - 1, LH - 1)
            local without = meanLuma(demoDark, 0, 0, LW - 1, LH - 1)
            ok(withTorch > without * 1.15,
               ('the carried torch brightens the demo frame (%.3f vs %.3f)')
                   :format(withTorch, without))
            ok(without > 0.04,
               ('and dropping it leaves a readable frame, not a black one (%.3f)')
                   :format(without))
        end
    end

    -- Leave the renderer as it was found, so nothing after this inherits a grid.
    MeatRay.raycaster.setLighting(nil)

    print(('-'):rep(58))
    print(('%d passed, %d failed'):format(passed, failed))
    print('images written to: ' .. love.filesystem.getSaveDirectory())

    if failed > 0 then
        print('SELFTEST FAILED')
        error(('%d assertion(s) failed: %s'):format(failed, problems[1]), 0)
    end

    print('SELFTEST PASSED')
end
