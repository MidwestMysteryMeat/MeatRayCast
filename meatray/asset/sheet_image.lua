--[[
    meatray.asset.sheet_image — the sprite painter's bridge to real pixels.

    Everything decidable without a GPU is already decided in meatray.asset.sheet;
    this file is the thin part that has to touch the host's pixels, which it does
    through meatray.platform. It moves bytes between a Sheet and an ImageData,
    writes a PNG the asset pipeline can import, and reads one back.

    Deliberately thin, and deliberately byte-exact. LÖVE's ImageData is RGBA8, and
    its getPixel/setPixel talk in floats over 0..1, so every crossing is a
    conversion. A conversion done casually — `v / 255` out and `v * 255` back —
    accumulates a rounding error that shows up as a colour that is one off after a
    round trip, which is invisible on screen and fatal to the claim that export and
    re-import give identical pixels. Both directions round explicitly, and the
    selftest asserts the whole loop on a real encoder rather than trusting it.

    The export filename carries the grid: `name_a8_f4.png`. meatray.asset.names
    already parses that back out, so a sheet exported here re-imports into the
    asset browser with its bucket and frame counts already filled in, instead of
    someone retyping the two numbers that are the easiest thing in the pipeline to
    get wrong.
]]

local Platform = require('meatray.platform')
local Sheet = require('meatray.asset.sheet')
local Names = require('meatray.asset.names')

local SheetImage = {}

local floor = math.floor

local function toByte(f)
    local v = floor((f or 0) * 255 + 0.5)
    if v < 0 then return 0 end
    if v > 255 then return 255 end
    return v
end

function SheetImage.available()
    return Platform.canRender()
end

---------------------------------------------------------------------------
-- Sheet to pixels
---------------------------------------------------------------------------

-- Fills an ImageData from a sheet, allocating one if the caller has none of the
-- right size. Reusing the caller's buffer matters: this runs on every load and
-- every regrid, and allocating a new ImageData per call leaves the old one for the
-- collector while the GPU may still be reading it.
function SheetImage.toImageData(sheet, into)
    if not SheetImage.available() then return nil, 'no image module' end

    local data = into
    if not data or data:getWidth() ~= sheet.width or data:getHeight() ~= sheet.height then
        data = Platform.gfx.newImageData(sheet.width, sheet.height)
    end

    local palette = sheet.palette
    local pixels = sheet.pixels
    local width = sheet.width

    for i = 1, width * sheet.height do
        local c = palette[pixels[i]]
        local x = (i - 1) % width
        local y = floor((i - 1) / width)
        if c then
            data:setPixel(x, y, c[1] / 255, c[2] / 255, c[3] / 255, c[4] / 255)
        else
            data:setPixel(x, y, 0, 0, 0, 0)
        end
    end

    return data
end

-- Replays a diff onto an ImageData, touching only the pixels it changed. `from`
-- and `to` restrict it to a slice of the diff, which is how a stroke still being
-- drawn pushes only its newest pixels each frame.
--
-- This is what makes painting cheap. Rebuilding the whole ImageData after every
-- brush dab is O(sheet) per dab, which on a 384-pixel-tall sheet is seventy
-- thousand setPixel calls to show one pixel moving — the difference between a
-- painter that feels immediate and one that feels stuck.
--
-- Reversal walks backwards for the same reason meatray.asset.sheet's applyDiff
-- does: one edit may write the same pixel twice, and undoing in forward order
-- restores the intermediate value rather than the original. The two must agree, or
-- the picture on screen drifts from the buffer it is supposed to be showing.
function SheetImage.applyDiff(sheet, data, diff, reverse, from, to)
    if not data or not diff then return 0 end

    from = from or 1
    to = to or diff.n
    if to > diff.n then to = diff.n end
    if from < 1 then from = 1 end

    local src = reverse and diff.before or diff.after
    local palette = sheet.palette
    local width = sheet.width
    local moved = 0

    local first, last, step = from, to, 1
    if reverse then first, last, step = to, from, -1 end

    for i = first, last, step do
        local off = diff.idx[i] - 1
        local x = off % width
        local y = floor(off / width)
        local c = palette[src[i]]
        if c then
            data:setPixel(x, y, c[1] / 255, c[2] / 255, c[3] / 255, c[4] / 255)
        else
            data:setPixel(x, y, 0, 0, 0, 0)
        end
        moved = moved + 1
    end

    return moved
end

---------------------------------------------------------------------------
-- Pixels to sheet
---------------------------------------------------------------------------

-- Reads an ImageData into a new sheet under the given grid. Returns nil plus a
-- reason for a grid the image does not fit, matching meatray.asset.image's refusal
-- rather than importing something that will render half-off.
function SheetImage.fromImageData(data, opts)
    if not data then return nil, 'no image data' end
    opts = opts or {}

    local w, h = data:getWidth(), data:getHeight()
    local bytes = {}
    local n = 0

    for y = 0, h - 1 do
        for x = 0, w - 1 do
            local r, g, b, a = data:getPixel(x, y)
            bytes[n + 1] = toByte(r)
            bytes[n + 2] = toByte(g)
            bytes[n + 3] = toByte(b)
            bytes[n + 4] = toByte(a)
            n = n + 4
        end
    end

    return Sheet.fromBytes(w, h, bytes, opts)
end

---------------------------------------------------------------------------
-- Files
---------------------------------------------------------------------------

-- The path a sheet should be written to, with its grid in the name.
function SheetImage.pathFor(name, sheet, folder)
    folder = folder or 'assets/sprites'
    return ('%s/%s_a%d_f%d.png'):format(folder, Names.normalise(name),
                                        sheet.angles, sheet.frames)
end

-- Writes a PNG into the LÖVE save directory. Returns the path, or nil plus a
-- reason — never raises, because this is behind a button.
function SheetImage.write(sheet, path)
    if not SheetImage.available() then return nil, 'no image module' end
    if not path or path == '' then return nil, 'no path given' end

    local data, err = SheetImage.toImageData(sheet)
    if not data then return nil, err end

    local dir = Names.split(path)
    if dir ~= '' then Platform.fs.createDirectory(dir) end

    local ok, encodeErr = pcall(function() data:encode('png', path) end)
    if not ok then
        return nil, ('could not write %s: %s'):format(path, tostring(encodeErr))
    end

    return path
end

-- Reads a PNG back into an editable sheet. The grid comes from `opts`, or from the
-- filename hint when the caller has nothing better — which is the case every time
-- you reopen something this module wrote.
function SheetImage.read(path, opts)
    if not SheetImage.available() then return nil, 'no image module' end
    if not path or path == '' then return nil, 'no path given' end

    if not Platform.fs.getInfo(path) then
        return nil, ('file not found: %s'):format(path)
    end

    local data, why = Platform.gfx.readImageData(path)
    if not data then
        return nil, ('could not decode %s: %s'):format(path, tostring(why))
    end

    opts = opts or {}
    if not opts.angles or not opts.frames then
        local hint = Names.hints(path)
        opts.angles = opts.angles or (hint and hint.angles) or 1
        opts.frames = opts.frames or (hint and hint.frames) or 1
    end

    return SheetImage.fromImageData(data, opts)
end

return SheetImage
