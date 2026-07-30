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

    getWidth = function() return lg.getWidth() end,
    getHeight = function() return lg.getHeight() end,
    getDimensions = function() return lg.getDimensions() end,
    getFont = function() return lg.getFont() end,
}

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

Backend.input = {
    -- Variadic, matching how the engine asks: `keyDown('w', 'up')`.
    keyDown = function(...) return love.keyboard.isDown(...) end,
    mouseDown = function(button) return love.mouse.isDown(button or 1) end,
    mousePosition = function() return love.mouse.getPosition() end,

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
        if not love.audio then return nil end
        local ok, source = pcall(love.audio.newSource, path, mode or 'static')
        if not ok then return nil end
        return source
    end,
    available = function() return love.audio ~= nil end,
}

return Backend
