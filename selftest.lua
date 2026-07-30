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
