--[[
    meatray.asset.image — PNG import for sprite sheets and wall textures.

    Everything decidable without a GPU has already been decided in
    meatray.asset.slice; this file is the part that has to touch love.graphics.
    It does three things in order, and stops at the first that fails:

        1. is the file there
        2. does it decode
        3. does it divide by the declared grid

    Step 3 is the one that earns its place. A sheet whose dimensions do not divide
    evenly by its angle and frame counts still *loads* — and then renders sprites
    sliced half-off, showing the bottom of one frame above the top of the next. It
    looks like a renderer bug and it is a data bug, so an inexact grid is refused
    with the numbers in the message rather than imported and drawn.

    Refusing means falling back to the generated placeholder, not raising. The
    sprite still exists, still draws, and says in the console why it is a
    placeholder.
]]

local Slice = require('meatray.asset.slice')
local Names = require('meatray.asset.names')

local Image = {}

---------------------------------------------------------------------------
-- Loading
---------------------------------------------------------------------------

function Image.available()
    return love ~= nil and love.graphics ~= nil and love.image ~= nil
end

-- Reads an image, returning nil plus a reason instead of raising. Both failure
-- modes are checked separately because they need different fixes: a missing file
-- is a path problem, a decode failure is a file problem.
function Image.load(path)
    if not Image.available() then
        return nil, 'no graphics context'
    end
    if not path or path == '' then
        return nil, 'no path given'
    end

    local info = love.filesystem.getInfo and love.filesystem.getInfo(path)
    if not info then
        return nil, ('file not found: %s (looked in %s and the save directory)')
            :format(path, love.filesystem.getWorkingDirectory and
                          love.filesystem.getWorkingDirectory() or 'the game directory')
    end
    if info.type == 'directory' then
        return nil, ('%s is a directory, not an image'):format(path)
    end

    local ok, image = pcall(love.graphics.newImage, path)
    if not ok then
        return nil, ('could not decode %s: %s'):format(path, tostring(image))
    end

    -- Nearest filtering, to match every generated texture in the engine. A single
    -- imported sheet drawn with the default linear filter is instantly obvious
    -- next to procedural art and reads as a rendering bug.
    image:setFilter('nearest', 'nearest')
    return image
end

---------------------------------------------------------------------------
-- Sprite sheets
---------------------------------------------------------------------------

-- Builds the table meatray.render.sprites.define accepts from a file on disk.
-- Returns def, plan on success, or nil, reason, plan on failure — the plan comes
-- back either way so the browser can show the grid it rejected.
--
--   local def = Image.sheetDef('assets/sprites/imp_a8_f4.png',
--                              { angles = 8, frames = 4, fps = 7 })
--   Sprites.define('imp', def)
--
-- `settings.force` imports an inexact grid anyway. It exists because an artist
-- mid-edit sometimes wants to see the wrong slice rather than a placeholder, and
-- it is off by default because that is not the normal case.
function Image.sheetDef(path, settings)
    settings = settings or {}

    local image, err = Image.load(path)
    if not image then return nil, err end

    local angles = settings.angles or 1
    local frames = settings.frames or 1
    local plan = Slice.forSheet(image:getWidth(), image:getHeight(), angles, frames)

    if not plan.ok and not settings.force then
        return nil, ('%s does not fit a %d x %d grid: %s')
            :format(path, angles, frames, table.concat(plan.problems, '; ')), plan
    end

    return {
        image = image,
        angles = plan.rows,
        frames = plan.cols,
        fps = settings.fps or 8,
        anchor = settings.anchor or 'feet',
        scale = settings.scale or 1,
        color = settings.color or { 0.7, 0.7, 0.7 },
    }, plan
end

-- Reads the sheet's dimensions and suggests a grid, for prefilling an import
-- dialog: the filename hint if there is one, otherwise square cells.
function Image.inspect(path)
    local image, err = Image.load(path)
    if not image then return nil, err end

    local w, h = image:getWidth(), image:getHeight()
    local hint = Names.hints(path)

    local angles, frames
    if hint then
        angles, frames = hint.angles, hint.frames
    else
        local cols, rows = Slice.guess(w, h)
        angles, frames = rows, cols
    end

    return {
        image = image,
        width = w, height = h,
        angles = angles, frames = frames,
        fromHint = hint ~= nil,
        plan = Slice.forSheet(w, h, angles, frames),
    }
end

---------------------------------------------------------------------------
-- Wall textures
---------------------------------------------------------------------------

-- A wall texture is one image with no grid, so the only checks are existence and
-- decoding. Non-square or oddly sized textures are allowed: the renderer samples
-- by ratio, so a 32x128 pillar texture is a legitimate choice rather than a
-- mistake worth blocking.
function Image.textureImage(path)
    local image, err = Image.load(path)
    if not image then return nil, err end
    return image
end

return Image
