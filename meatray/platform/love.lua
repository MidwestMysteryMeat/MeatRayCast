--[[
    meatray.platform.love — the LÖVE backend.

    This file, and only this file, may name `love`. Everything else in the engine
    reaches the host through meatray.platform, and tests/test_platform.lua fails if
    that stops being true.

    Mostly a thin forward. Where it is not thin, the reason is written down: a few
    host APIs have shapes worth normalising so a second backend is not obliged to
    reproduce a LÖVE quirk in order to be correct.
]]

local Backend = { name = 'love' }

local lg = love.graphics
local lfs = love.filesystem

---------------------------------------------------------------------------
-- Graphics
---------------------------------------------------------------------------

Backend.gfx = {
    setColor = function(r, g, b, a) lg.setColor(r, g, b, a) end,
    rectangle = function(mode, x, y, w, h) lg.rectangle(mode, x, y, w, h) end,
    line = function(...) lg.line(...) end,
    circle = function(mode, x, y, r) lg.circle(mode, x, y, r) end,
    print = function(text, x, y) lg.print(text, x, y) end,
    printf = function(text, x, y, limit, align) lg.printf(text, x, y, limit, align) end,
    clear = function(r, g, b, a) lg.clear(r, g, b, a) end,

    -- `draw` carries LÖVE's argument order because every 2D host has an
    -- equivalent and normalising it would only move the translation elsewhere.
    draw = function(drawable, ...) lg.draw(drawable, ...) end,

    push = function() lg.push() end,
    pop = function() lg.pop() end,
    translate = function(dx, dy) lg.translate(dx, dy) end,

    -- Scissor with no arguments clears it, matching LÖVE. The engine keeps its
    -- own nested stack on top (meatray/ui/core.lua) because LÖVE has none, and a
    -- backend is not expected to provide one either.
    setScissor = function(x, y, w, h)
        if x then lg.setScissor(x, y, w, h) else lg.setScissor() end
    end,
    getScissor = function() return lg.getScissor() end,

    newImage = function(data)
        local image = lg.newImage(data)
        -- Nearest filtering is the engine's house style: every texture it makes is
        -- pixel art, and a backend that smoothed them would look wrong rather than
        -- merely different.
        image:setFilter('nearest', 'nearest')
        return image
    end,
    newQuad = function(x, y, w, h, sw, sh) return lg.newQuad(x, y, w, h, sw, sh) end,
    newCanvas = function(w, h) return lg.newCanvas(w, h) end,
    setCanvas = function(canvas)
        if canvas then lg.setCanvas(canvas) else lg.setCanvas() end
    end,
    newImageData = function(w, h) return love.image.newImageData(w, h) end,

    -- Source rectangle is always the whole block being copied, and its size is
    -- passed rather than read back off the source, so a backend needs no getter
    -- on its pixel data to implement this.
    pasteImageData = function(dest, src, x, y, w, h)
        dest:paste(src, x, y, 0, 0, w, h)
    end,

    -- One pixel, object first, matching pasteImageData above. The light grid is
    -- written a texel at a time — a torch touches a few dozen of them a frame —
    -- and a seam that made the caller reach for a method on the pixel data would
    -- be handing out a host object again.
    setImagePixel = function(data, x, y, r, g, b, a)
        data:setPixel(x, y, r, g, b, a)
    end,

    -- Re-uploads pixel data into an image of the same size. LÖVE's own name for
    -- this is `Image:replacePixels`, and the dimensions must match, which is why
    -- the renderer keeps its light image for the life of a grid and only
    -- reallocates when the world it describes changes shape.
    replaceImagePixels = function(image, data)
        image:replacePixels(data)
    end,

    -- Decodes a file into pixel data, which is a different operation from
    -- allocating blank pixels above even though LÖVE spells both
    -- `love.image.newImageData`. The sprite painter reads back the sheets it
    -- exported, so "export and re-import give identical pixels" is a claim that
    -- can be checked rather than asserted.
    --
    -- nil plus a reason rather than a raise: this sits behind a button in the
    -- editor, and a bad path there should be a console line.
    readImageData = function(path)
        if not love.image then return nil, 'no image module' end
        local ok, data = pcall(love.image.newImageData, path)
        if not ok then return nil, tostring(data) end
        return data
    end,

    -- Compiles a fragment shader, or reports that this host will not.
    --
    -- nil plus a reason rather than a raise, and deliberately so: LÖVE compiles
    -- at creation time and raises on anything the driver rejects, which is a
    -- real event on old or software GL rather than a programming mistake. The
    -- renderer treats nil as "no textured floor here" and draws flat bands,
    -- which is a worse picture and a running game.
    newShader = function(source)
        if not (lg and lg.newShader) then return nil, 'no graphics module' end
        local ok, shader = pcall(lg.newShader, source)
        if not ok then return nil, tostring(shader) end
        return shader
    end,

    -- nil clears, matching setCanvas and setScissor above.
    setShader = function(shader)
        if not lg then return end
        if shader then lg.setShader(shader) else lg.setShader() end
    end,

    -- Sets one uniform, and returns whether it landed.
    --
    -- Swallowed rather than raised because GLSL compilers delete uniforms that
    -- cannot affect the output, and LÖVE raises when you then send to the name
    -- that is no longer there. That is a property of the driver's optimiser, not
    -- a mistake at the call site, and a renderer should not crash because a
    -- branch it disabled made a uniform redundant.
    sendShader = function(shader, name, ...)
        if not shader then return false end
        return (pcall(shader.send, shader, name, ...))
    end,

    getWidth = function() return lg.getWidth() end,
    getHeight = function() return lg.getHeight() end,
    getDimensions = function() return lg.getDimensions() end,

    -- Text metrics as numbers, not as a Font.
    --
    -- The engine measured text twenty-one times through `love.graphics.getFont()`
    -- and every single one of them wanted a width, a height, or a wrap. Handing a
    -- LÖVE Font back through the seam would have made "implement this interface"
    -- also mean "implement LÖVE's Font", which is most of a text stack, and would
    -- have left a host object in the hands of code whose whole job is not to hold
    -- one. Three functions covers the entire requirement.
    textWidth = function(text) return lg.getFont():getWidth(text) end,
    textHeight = function() return lg.getFont():getHeight() end,

    -- The lines `printf` would produce at this width. LÖVE's `Font:getWrap`
    -- returns (width, lines-table); returning both has already caused a bug in
    -- this codebase, where the table was used as a line count and threw inside a
    -- swallowed draw hook (see meatray/ui/shell.lua). The seam returns the lines,
    -- and `#lines` is the count.
    textWrap = function(text, limit)
        local _, lines = lg.getFont():getWrap(text, limit)
        return lines or {}
    end,

    -- `love . --server` switches window and graphics off entirely, so this is a
    -- real question with a real "no", not a formality. love.image goes with it:
    -- every producer above needs both.
    available = function()
        return love.graphics ~= nil and love.image ~= nil
    end,
}

-- Where LÖVE's own signature already *is* the interface, hand the host function
-- straight through instead of wrapping it.
--
-- Every wrapper above costs one extra Lua call. That is invisible in almost all
-- of the engine and measurable in exactly one place: the raycaster's wall loop
-- calls setColor and draw once per screen column — around eight hundred times a
-- frame, every frame — and the wrappers cost about 7% of that loop's CPU time.
-- A wrapper whose whole body is "call the host with the same arguments" has
-- nothing to contribute in exchange.
--
-- Only the ones that genuinely match. `setScissor`, `setCanvas` and `newImage`
-- keep theirs because each normalises something a bare passthrough would not: a
-- nil clears rather than errors, and every image the engine makes gets nearest
-- filtering. `textWidth` and friends keep theirs because there is no host
-- function of that shape at all.
--
-- Guarded because a dedicated server has no graphics module to alias: `love .
-- --server` still loads this file for its filesystem and its clock.
if lg then
    local gfx = Backend.gfx

    gfx.setColor = lg.setColor
    gfx.draw = lg.draw
    gfx.rectangle = lg.rectangle
    gfx.line = lg.line
    gfx.circle = lg.circle
    gfx.print = lg.print
    gfx.printf = lg.printf
    gfx.clear = lg.clear
    gfx.push = lg.push
    gfx.pop = lg.pop
    gfx.translate = lg.translate
    gfx.getScissor = lg.getScissor
    gfx.newQuad = lg.newQuad
    gfx.newCanvas = lg.newCanvas
    gfx.getWidth = lg.getWidth
    gfx.getHeight = lg.getHeight
    gfx.getDimensions = lg.getDimensions
    gfx.newImageData = love.image and love.image.newImageData or gfx.newImageData
end

---------------------------------------------------------------------------
-- Filesystem
--
-- LÖVE's filesystem is PhysFS, sandboxed to the save directory and the game
-- source. That is a real constraint a backend must either match or document:
-- there is no rename, no arbitrary path access, and writes land in the save
-- directory whatever path you pass. meatray/save/storage.lua already works within
-- that and falls back to `io` when there is no host.
---------------------------------------------------------------------------

Backend.fs = {
    read = function(path, size) return lfs.read(path, size) end,
    write = function(path, data) return lfs.write(path, data) end,
    remove = function(path) return lfs.remove(path) end,
    getInfo = function(path) return lfs.getInfo(path) end,
    getDirectoryItems = function(path) return lfs.getDirectoryItems(path) end,
    createDirectory = function(path) return lfs.createDirectory(path) end,
    getSaveDirectory = function() return lfs.getSaveDirectory() end,
    getSource = function() return lfs.getSource() end,
    getWorkingDirectory = function() return lfs.getWorkingDirectory() end,
    newFile = function(path) return lfs.newFile(path) end,

    -- Reported rather than assumed. PhysFS has no rename, so the save system
    -- cannot swap files atomically and instead writes, verifies, then replaces,
    -- with recovery from the temp file on read. A backend that *does* have rename
    -- can say so and the save layer will use it.
    hasRename = function() return love.filesystem.rename ~= nil end,
}

---------------------------------------------------------------------------
-- Input
---------------------------------------------------------------------------

-- Each of these is guarded rather than assumed present. A headless run has no
-- window, and LÖVE's keyboard and mouse modules go with the window — so "nothing
-- is held down" is the honest answer there, and it is a far better one than the
-- nil index a dedicated server would otherwise take from shared input code.
Backend.input = {
    -- Variadic, matching how the engine asks: `keyDown('w', 'up')`.
    keyDown = function(...)
        return love.keyboard ~= nil and love.keyboard.isDown(...)
    end,
    mouseDown = function(button)
        return love.mouse ~= nil and love.mouse.isDown(button or 1)
    end,
    mousePosition = function()
        if not love.mouse then return 0, 0 end
        return love.mouse.getPosition()
    end,

    setRelativeMouse = function(on)
        if love.mouse then love.mouse.setRelativeMode(on and true or false) end
    end,
    setMouseVisible = function(on)
        if love.mouse then love.mouse.setVisible(on and true or false) end
    end,
}

---------------------------------------------------------------------------
-- System
---------------------------------------------------------------------------

Backend.sys = {
    -- Wall clock, for presentation only. Anything that must agree across a
    -- network reads the tick clock instead — see meatray/sim/tick.lua, which
    -- takes dt as an argument precisely so it never needs this.
    time = function() return love.timer and love.timer.getTime() or os.clock() end,
    os = function() return love.system and love.system.getOS() or 'unknown' end,
    quit = function(code) love.event.quit(code) end,

    -- Moves the window, and reports the desktop it is on. Both are no-ops that
    -- answer honestly rather than raising when there is no window at all:
    -- `love . --server` switches the window module off entirely, and a headless
    -- host asking where the desktop is should get nil, not an error.
    setWindowPosition = function(x, y, display)
        if love.window and love.window.setPosition then
            love.window.setPosition(x, y, display)
        end
    end,
    desktopSize = function(display)
        if love.window and love.window.getDesktopDimensions then
            return love.window.getDesktopDimensions(display)
        end
        return nil
    end,

    -- Installs the run loop. Only `meatray.engine.run` uses this — the library
    -- half of the engine never owns the loop — but without it that one file has
    -- to write `function love.draw()` itself, and a seam with one hole in it is
    -- not a seam.
    --
    -- Each callback is wrapped rather than assigned straight through, so the
    -- engine's callbacks keep the argument list this interface documents even
    -- where a host's own differs.
    setCallbacks = function(cb)
        cb = cb or {}
        if cb.update then love.update = function(dt) cb.update(dt) end end
        if cb.draw then love.draw = function() cb.draw() end end
        if cb.keypressed then
            love.keypressed = function(key) cb.keypressed(key) end
        end
        if cb.mousemoved then
            love.mousemoved = function(x, y, dx, dy) cb.mousemoved(x, y, dx, dy) end
        end
    end,
}

---------------------------------------------------------------------------
-- Audio
---------------------------------------------------------------------------

Backend.audio = {
    newSource = function(path, mode)
        -- conf.lua switches the audio module off for headless runs, so this is
        -- reachable with no audio device. Returning nil rather than raising keeps
        -- the asset registry's silent-fallback promise: missing audio is silence,
        -- never a crash.
        if not love.audio then return nil, 'no audio module' end
        local ok, source = pcall(love.audio.newSource, path, mode or 'static')
        -- The reason rides along as a second return so a caller that wants to
        -- report it can, without any caller being obliged to look: `local s =
        -- newSource(p)` still reads exactly as "nil means silence".
        if not ok then return nil, tostring(source) end
        return source
    end,
    available = function() return love.audio ~= nil end,

    -- Builds a playable Source from raw float samples (the H3 synthesizer's
    -- output) with no file anywhere. OPTIONAL in the backend contract —
    -- callers must check for its presence — because a fake backend in a test
    -- has no reason to implement sample upload, and audio is already the one
    -- subsystem allowed to be absent.
    newSourceFromSamples = function(samples, rate)
        if not love.audio or not love.sound then return nil, 'no audio module' end
        local ok, source = pcall(function()
            local data = love.sound.newSoundData(#samples, rate or 22050, 16, 1)
            for i = 1, #samples do data:setSample(i - 1, samples[i]) end
            return love.audio.newSource(data, 'static')
        end)
        if not ok then return nil, tostring(source) end
        return source
    end,
}

return Backend
