--[[
    Per-pixel floor and ceiling lighting: the parts of it that can be checked
    without a GPU.

    The picture is asserted in selftest.lua, which renders a lit room twice — once
    with the light grid uploaded as a texture and once with the single sample at
    the camera that preceded it — and compares them pixel by pixel, partitioned by
    the z-buffer. What that cannot check is what breaks *before* the picture, and
    this suite is those things.

    Three of them, each a real failure this codebase has the shape to produce:

      1. The seam. The renderer writes the light grid a texel at a time and
         re-uploads it, which needed two new functions on meatray.platform. A name
         in the REQUIRED table that nothing enforces is a comment, so the
         enforcement is asserted rather than the declaration.

      2. The branch. A scene with no light grid must not pay for the light
         texture. The shader reads it five times per fragment — a hand-written
         bilinear, because the leak rule cannot be expressed as a sampler filter —
         and at 960x600 the background is 288,000 fragments. Behind `if (lightOn
         > 0.5)` that is free when there is no grid; behind a `mix()` it would
         not be, and a mix is what reads more naturally and compiles to both
         sides being evaluated.

      3. The module still loading, and still answering, on a machine with no host
         at all. tests/test_platform.lua already refuses this file the right to
         name `love`; this refuses it the right to NEED one.
]]

return function(t)
    local Platform = require('meatray.platform')
    local Raycaster = require('meatray.render.raycaster')
    local Lighting = require('meatray.render.lighting')

    ---------------------------------------------------------------------
    t.describe('the seam declares the two functions a light texture needs')

    local declared = {}
    for _, name in ipairs(Platform.REQUIRED.gfx) do declared[name] = true end

    t.ok(declared.setImagePixel, 'gfx.setImagePixel is part of the interface')
    t.ok(declared.replaceImagePixels, 'gfx.replaceImagePixels is too')
    -- The pair, not either alone: writing texels with no way to upload them means
    -- a new GPU texture every frame, which is the per-frame allocation the wall
    -- loop's reused quad exists to avoid.
    t.ok(declared.newImageData and declared.newImage,
         'alongside the two that already allocated the pixels and the image')

    -- Declared and enforced are different claims and only the second is worth
    -- anything. Removed one at a time, so the check is per function.
    local INSTALLED = { 'backend', 'name', 'gfx', 'fs', 'input', 'sys', 'audio' }
    local saved = {}
    for _, key in ipairs(INSTALLED) do saved[key] = rawget(Platform, key) end

    for _, missing in ipairs({ 'setImagePixel', 'replaceImagePixels' }) do
        local partial = {}
        for group, names in pairs(Platform.REQUIRED) do
            partial[group] = {}
            for _, fn in ipairs(names) do partial[group][fn] = function() end end
        end
        partial.gfx[missing] = nil

        local ok, err = pcall(Platform.use, partial, 'no-' .. missing)
        t.ok(not ok, ('a backend without %s is refused'):format(missing))
        t.ok(tostring(err):find(missing), 'and the error names it')
    end

    for _, key in ipairs(INSTALLED) do rawset(Platform, key, saved[key]) end
    t.eq(rawget(Platform, 'backend'), saved.backend,
         'and the stub is put away again afterwards')

    ---------------------------------------------------------------------
    t.describe('the shader reads the grid, and only when there is one')

    local source = Raycaster.FLOOR_SHADER

    for _, name in ipairs({ 'lightTex', 'lightSize', 'lightOn',
                            'lightMax', 'lightMin' }) do
        t.ok(source:find('extern%s+[%w_]+%s+' .. name .. '%s*;'),
             ('the shader declares %s'):format(name))
    end

    -- The performance-critical shape, asserted because it is invisible in a
    -- screenshot: a real branch. `mix(a, gridLight(world), lightOn)` renders
    -- identically and evaluates gridLight() for every fragment whether or not
    -- there is a grid, which is five texture reads per pixel over most of the
    -- frame for a value that is then multiplied by zero.
    t.ok(source:find('if%s*%(%s*lightOn'),
         'and reads it behind a branch on lightOn, not a mix')

    -- Five reads is the hand-written bilinear plus the fallback for a point whose
    -- neighbours are all solid. Four would mean the fallback went missing, which
    -- is the dark ring at the base of every wall.
    local reads = select(2, source:gsub('Texel%s*%(%s*lightTex', ''))
    t.eq(reads, 5,
         ('gridLight samples the texture %d times: four corners and the fallback')
             :format(reads))

    -- The floor goes on the blended value. Applied per corner it would be
    -- interpolated, and an interpolation of the floor with itself sits above the
    -- floor -- see Grid:tileSample, which is the other half of this rule.
    t.ok(source:find('max%s*%(%s*vec3%s*%(%s*lightMin'),
         'and the readability floor is applied after the blend, not before')

    -- The uniforms the shader declares and the ones the renderer sends are
    -- checked against each other by tests/test_render_floorcast.lua, which reads
    -- both sides. Nothing here duplicates that; these are the names it would not
    -- notice were absent from both.

    ---------------------------------------------------------------------
    t.describe('the encoding covers the range a light may reach')

    -- The texture holds eight bits a channel, and MAX_LEVEL is above 1.0 so a
    -- flash can blow a surface out toward white. The renderer divides by
    -- MAX_LEVEL going in and the shader multiplies by it coming out; if either
    -- half used 1.0 instead, every light above the theme's ambient would clip.
    t.ok(Lighting.MAX_LEVEL > 1.0,
         ('MAX_LEVEL is above 1.0 (%.2f), so it cannot be stored raw')
             :format(Lighting.MAX_LEVEL))
    t.ok(source:find('lightMax'), 'so the shader scales by it on the way out')

    -- One step of an eight-bit channel, in light units. Worth a number rather
    -- than a shrug: this is the entire precision cost of putting the grid in a
    -- texture, and it is well under what a viewer can see on a lit floor.
    local step = Lighting.MAX_LEVEL / 255
    t.ok(step < 0.006,
         ('one texel step is %.5f of full brightness'):format(step))

    ---------------------------------------------------------------------
    t.describe('the toggle works on a machine with no host')

    t.ok(not rawget(_G, 'love'), 'this suite really is running without a host')

    t.ok(Raycaster.lightTexture(), 'per-pixel floor lighting is on by default')
    Raycaster.setLightTexture(false)
    t.ok(not Raycaster.lightTexture(), 'and can be switched off')
    t.eq(Raycaster.setLightTexture(true), Raycaster, 'the setter chains')
    t.ok(Raycaster.lightTexture(), 'and back on')

    -- Not a boolean-ish nil: this is read by a benchmark and by callers deciding
    -- what to offer, the same reason setFloorCasting answers with a real false.
    Raycaster.setLightTexture(nil)
    t.eq(Raycaster.lightTexture(), false, 'nil means off, as a real false')
    Raycaster.setLightTexture(true)

    -- The report is the performance argument in two numbers, and a caller must be
    -- able to ask for it before anything has drawn.
    local report = Raycaster.lightTextureReport()
    t.ok(type(report) == 'table', 'the light-texture report is a table')
    for _, key in ipairs({ 'width', 'height', 'tiles', 'uploads' }) do
        t.ok(type(report[key]) == 'number',
             ('and carries %s as a number before any frame'):format(key))
    end
end
