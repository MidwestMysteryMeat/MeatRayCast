--[[
    Floor and ceiling casting: the parts of it that can be checked without a GPU.

    The picture itself is asserted in selftest.lua, which renders both paths into
    a canvas and compares them pixel by pixel. What that cannot check is the
    thing most likely to break silently, because it breaks *before* the picture:
    the two halves of the shader interface. The uniform names live in a GLSL
    string, the sends live in Lua fifty lines away, and nothing connects them but
    spelling. Rename one side and LOVE raises at the send — which the backend
    deliberately swallows, because a driver is allowed to optimise a uniform away
    — so the frame renders, with a stale value, and nobody finds out.

    So this suite reads both sides and asserts they are the same set. It is a
    spelling test, which is exactly the failure available here.

    It also holds the line the render layer is otherwise the most likely to
    cross: floor casting is optional, and the module has to load and answer
    questions on a machine with no host at all.
]]

return function(t)
    local Platform = require('meatray.platform')
    local Raycaster = require('meatray.render.raycaster')

    ---------------------------------------------------------------------
    t.describe('the seam declares what a shader-capable backend must supply')

    local declared = {}
    for _, name in ipairs(Platform.REQUIRED.gfx) do declared[name] = true end

    for _, name in ipairs({ 'newShader', 'setShader', 'sendShader' }) do
        t.ok(declared[name], ('gfx.%s is part of the interface'):format(name))
    end

    -- Declared and *enforced* are different claims, and only the second one is
    -- worth anything: a name in a list that nothing checks is a comment.
    local partial = {}
    for group, names in pairs(Platform.REQUIRED) do
        partial[group] = {}
        for _, fn in ipairs(names) do partial[group][fn] = function() end end
    end
    partial.gfx.newShader = nil

    local saved = {}
    local INSTALLED = { 'backend', 'name', 'gfx', 'fs', 'input', 'sys', 'audio' }
    for _, key in ipairs(INSTALLED) do saved[key] = rawget(Platform, key) end

    local ok, err = pcall(Platform.use, partial, 'no-shaders')
    t.ok(not ok, 'a backend without newShader is refused')
    t.ok(tostring(err):find('newShader'), 'and the error names it')

    for _, key in ipairs(INSTALLED) do rawset(Platform, key, saved[key]) end

    ---------------------------------------------------------------------
    t.describe('the shader and the code that feeds it agree on every name')

    local source = Raycaster.FLOOR_SHADER
    t.ok(type(source) == 'string', 'the floor shader is a string on the module')
    t.ok(#source > 200, ('and it is %d characters of it'):format(#source or 0))

    -- Everything the shader declares...
    local declaredUniforms, declaredCount = {}, 0
    for name in source:gmatch('extern%s+[%w_]+%s+([%w_]+)%s*;') do
        declaredUniforms[name] = true
        declaredCount = declaredCount + 1
    end
    t.ok(declaredCount >= 10,
         ('the shader declares %d uniforms'):format(declaredCount))

    -- ...against everything the renderer sends. Read off the source rather than
    -- by calling the renderer, because calling it needs a host and a GPU, which
    -- is precisely the situation this suite is not in.
    local f = io.open('meatray/render/raycaster.lua', 'r')
    t.ok(f ~= nil, 'the raycaster source is readable')

    local sentUniforms, sentCount = {}, 0
    if f then
        local code = f:read('*a')
        f:close()
        for name in code:gmatch("send%(shader,%s*'([%w_]+)'") do
            sentUniforms[name] = true
            sentCount = sentCount + 1
        end
    end
    t.ok(sentCount >= 10, ('the renderer sends %d uniforms'):format(sentCount))

    local unsent, undeclared = {}, {}
    for name in pairs(declaredUniforms) do
        if not sentUniforms[name] then unsent[#unsent + 1] = name end
    end
    for name in pairs(sentUniforms) do
        if not declaredUniforms[name] then undeclared[#undeclared + 1] = name end
    end
    table.sort(unsent)
    table.sort(undeclared)

    -- A uniform the shader declares and nobody sets holds whatever the driver
    -- left there, which on most drivers is zero and on this shader is a camera
    -- at the origin.
    t.eq(#unsent, 0, ('every declared uniform is sent: %s')
                     :format(table.concat(unsent, ', ')))
    -- And the reverse, which is the rename this suite exists for.
    t.eq(#undeclared, 0, ('every sent uniform is declared: %s')
                         :format(table.concat(undeclared, ', ')))

    ---------------------------------------------------------------------
    t.describe('the module survives a machine with no host')

    -- Requiring it above already proved the top level touches no graphics. The
    -- toggle has to work too: a caller deciding whether to offer textured floors
    -- in a menu should not need a GPU to ask, and `meatray.platform` raises a
    -- clear error the moment anything reads `Platform.gfx` without a backend.
    t.ok(not rawget(_G, 'love'), 'this suite really is running without a host')

    t.ok(Raycaster.floorCasting(), 'floor casting is on by default')
    Raycaster.setFloorCasting(false)
    t.ok(not Raycaster.floorCasting(), 'and can be switched off')
    t.eq(Raycaster.setFloorCasting(true), Raycaster, 'the setter chains')
    t.ok(Raycaster.floorCasting(), 'and back on')

    -- Not a boolean-ish nil: this is read by callers deciding what to draw.
    Raycaster.setFloorCasting(nil)
    t.eq(Raycaster.floorCasting(), false, 'nil means off, as a real false')
    Raycaster.setFloorCasting(true)

    ---------------------------------------------------------------------
    t.describe('the floor and ceiling textures tile')

    -- The cast samples one texture per world tile by the fractional part of a
    -- world coordinate, so the tile boundary is a seam in the picture. A
    -- pattern that does not meet itself across that boundary draws a grid of
    -- hairlines over the whole floor. Checked on the generator rather than on an
    -- image, since there is no host here to make one.
    local Textures = require('meatray.render.textures')
    local names = {}
    for _, name in ipairs(Textures.patternNames()) do names[name] = true end
    t.ok(names.tiles, 'there is a floor pattern')
    t.ok(names.coffer, 'and a ceiling pattern')

    -- A stand-in for ImageData: the generators only ever call setPixel, which is
    -- what makes them checkable with no host at all.
    local function capture(patternName)
        local px = {}
        local sink = { setPixel = function(_, x, y, r, g, b) px[y * 1000 + x] = { r, g, b } end }
        Textures.patterns[patternName](sink, { 0.5, 0.5, 0.5 }, 1)
        return px
    end

    -- The claim, stated so it needs no magic threshold: the colour step across
    -- the wrap is no larger than the largest step the pattern already takes
    -- inside itself. A pattern that tiles has a seam indistinguishable from its
    -- own edges; a pattern that does not has a step nothing inside it matches,
    -- and that step is the hairline grid you see on the floor.
    local S = Textures.SIZE
    for _, patternName in ipairs({ 'tiles', 'coffer' }) do
        local px = capture(patternName)
        t.ok(px[0] ~= nil, ('%s wrote pixels'):format(patternName))

        local at = function(x, y) return px[y * 1000 + x][1] end

        local worstSeam, worstInterior = 0, 0
        for i = 0, S - 1 do
            -- Left edge against right edge, and top against bottom.
            worstSeam = math.max(worstSeam, math.abs(at(S - 1, i) - at(0, i)))
            worstSeam = math.max(worstSeam, math.abs(at(i, S - 1) - at(i, 0)))
            for j = 0, S - 2 do
                worstInterior = math.max(worstInterior, math.abs(at(j, i) - at(j + 1, i)))
                worstInterior = math.max(worstInterior, math.abs(at(i, j) - at(i, j + 1)))
            end
        end

        t.ok(worstSeam <= worstInterior,
             ('%s meets itself across the wrap (%.3f seam, %.3f interior)')
             :format(patternName, worstSeam, worstInterior))
    end
end
