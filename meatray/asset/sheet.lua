--[[
    meatray.asset.sheet — the pixel model behind the sprite painter.

    A sprite sheet in this engine is `angles` ROWS of angle buckets by `frames`
    COLUMNS of animation frames, which is what meatray.render.sprites builds its
    quads from and what meatray.asset.slice already knows how to divide. This
    module is the editable form of that: a flat buffer of palette indices, plus
    the operations a pixel editor performs on it.

    Two decisions carry most of the weight here.

    **Pixels are palette indices, and palette colours are integer bytes.** Index 0
    is transparent and is not a palette entry; every other index names an RGBA
    tuple stored as four integers in 0..255. Storing colours as floats would be
    the obvious choice and the wrong one: a PNG is eight bits per channel, so a
    float palette means export quantises and re-import does not come back to the
    same numbers. Round-tripping a sheet through disk and getting different pixels
    than you drew is the one failure a painter must not have, so the in-memory
    form is byte-exact with the file form and `toBytes`/`fromBytes` are exactly
    inverse.

    **Every mutation returns a diff, and diffs are what undo stores.** A tool
    records only the pixels it actually changed, as three parallel arrays. That is
    never worse than snapshotting the canvas — a whole-sheet flood fill produces a
    diff the size of the sheet, and every ordinary stroke produces one a thousand
    times smaller — which is what keeps an undo stack on a large sheet from eating
    memory. The bound itself lives in meatray.asset.history.

    Cells are addressed as (bucket, frame), 0-based, in that order, because that
    is rows-then-columns and it is the order the sheet is laid out in. Getting
    that order backwards is precisely the bug the painter exists to make visible,
    so this module never accepts them the other way round.

    HEADLESS: no love.* anywhere in this file. All of it is asserted under plain
    LuaJIT.
]]

local Slice = require('meatray.asset.slice')

local Sheet = {}

local floor, max, min, abs = math.floor, math.max, math.min, math.abs

-- A ceiling on the buffer, so a mistyped cell size asks for a sane refusal rather
-- than an allocation the machine cannot honour.
Sheet.MAX_PIXELS = 4 * 1024 * 1024

-- A ceiling on distinct colours, which only an import can approach. Refusing past
-- it is honest: the alternative is quantising to the nearest entry, which makes
-- the round trip lossy in exactly the way this module promises it is not.
Sheet.MAX_COLORS = 4096

-- Sixteen colours to start from. Not a claim about art direction — a painter that
-- opens with an empty palette makes you mix a colour before you can draw a pixel,
-- and the first thing anyone wants to do is draw a pixel.
Sheet.DEFAULT_PALETTE = {
    {   0,   0,   0, 255 },
    {  48,  48,  56, 255 },
    { 104, 104, 116, 255 },
    { 176, 176, 188, 255 },
    { 255, 255, 255, 255 },
    { 128,  32,  32, 255 },
    { 208,  64,  48, 255 },
    { 240, 144,  48, 255 },
    { 248, 216,  88, 255 },
    {  40,  96,  56, 255 },
    {  96, 184,  88, 255 },
    {  64, 168, 168, 255 },
    {  40,  64, 128, 255 },
    {  88, 136, 224, 255 },
    { 144,  80, 176, 255 },
    { 120,  80,  48, 255 },
}

---------------------------------------------------------------------------
-- Construction
---------------------------------------------------------------------------

local function isCount(n, limit)
    return type(n) == 'number' and n == floor(n) and n >= 1 and n <= (limit or Sheet.MAX_PIXELS)
end

local function byte(v)
    v = tonumber(v) or 0
    v = floor(v + 0.5)
    if v < 0 then return 0 end
    if v > 255 then return 255 end
    return v
end

local function copyPalette(src)
    local out = {}
    for i, c in ipairs(src or Sheet.DEFAULT_PALETTE) do
        out[i] = { byte(c[1]), byte(c[2]), byte(c[3]), c[4] == nil and 255 or byte(c[4]) }
    end
    return out
end

-- Builds an empty sheet. Returns nil plus a reason rather than raising: every
-- caller is either a UI field someone is still typing into or an import of a file
-- someone else wrote, and neither should be able to kill the editor.
--
--   Sheet.new{ angles = 8, frames = 4, cellW = 32, cellH = 32 }
--
function Sheet.new(opts)
    opts = opts or {}

    local angles = opts.angles or 1
    local frames = opts.frames or 1
    local cellW = opts.cellW or 32
    local cellH = opts.cellH or 32

    if not isCount(angles, Slice.MAX_DIVISIONS) then
        return nil, ('angles must be a whole number from 1 to %d, got %s')
            :format(Slice.MAX_DIVISIONS, tostring(opts.angles))
    end
    if not isCount(frames, Slice.MAX_DIVISIONS) then
        return nil, ('frames must be a whole number from 1 to %d, got %s')
            :format(Slice.MAX_DIVISIONS, tostring(opts.frames))
    end
    if not isCount(cellW) or not isCount(cellH) then
        return nil, ('cell size must be whole pixels, got %sx%s')
            :format(tostring(opts.cellW), tostring(opts.cellH))
    end

    local width, height = cellW * frames, cellH * angles
    if width * height > Sheet.MAX_PIXELS then
        return nil, ('%dx%d is %d pixels, over the %d limit')
            :format(width, height, width * height, Sheet.MAX_PIXELS)
    end

    local sheet = {
        angles = angles, frames = frames,
        cellW = cellW, cellH = cellH,
        width = width, height = height,
        pixels = {},
        palette = copyPalette(opts.palette),
    }

    for i = 1, width * height do sheet.pixels[i] = 0 end

    sheet.plan = Slice.forSheet(width, height, angles, frames)
    return sheet
end

function Sheet.describe(sheet)
    if not sheet then return '(no sheet)' end
    return ('%dx%d, %d bucket%s x %d frame%s of %dx%d, %d colour%s')
        :format(sheet.width, sheet.height,
                sheet.angles, sheet.angles == 1 and '' or 's',
                sheet.frames, sheet.frames == 1 and '' or 's',
                sheet.cellW, sheet.cellH,
                #sheet.palette, #sheet.palette == 1 and '' or 's')
end

-- Reinterprets the same pixels under a different grid, without touching a pixel.
--
-- This is the cheap answer to "did I lay the buckets out as 8x4 or 4x8?": flip the
-- counts and look, rather than re-exporting and re-importing to find out. Refused
-- unless the new grid divides the existing image exactly, because a grid that does
-- not divide is the misconfiguration, not a thing to accommodate.
function Sheet.regrid(sheet, angles, frames)
    local plan = Slice.forSheet(sheet.width, sheet.height, angles, frames)
    if not plan.ok then
        return false, table.concat(plan.problems, '; ')
    end

    sheet.angles, sheet.frames = plan.rows, plan.cols
    sheet.cellW, sheet.cellH = plan.cellW, plan.cellH
    sheet.plan = plan
    return true
end

---------------------------------------------------------------------------
-- Cells
--
-- Every one of these delegates the arithmetic to meatray.asset.slice rather than
-- redoing it, so the painter and the importer cannot drift apart on where cell
-- boundaries are. `Slice.cell` takes (col, row) — frame, then bucket — which is
-- why the argument order flips at exactly one place, here, instead of at every
-- call site.
---------------------------------------------------------------------------

-- The pixel rect of one cell, as x, y, w, h. Returns nil outside the grid.
function Sheet.cell(sheet, bucket, frame)
    return Slice.cell(sheet.plan, frame, bucket)
end

-- The same rect as a bounds table, which is what the paint tools take.
function Sheet.cellBounds(sheet, bucket, frame)
    local x, y, w, h = Sheet.cell(sheet, bucket, frame)
    if not x then return nil end
    return { x = x, y = y, w = w, h = h }
end

-- Which cell a pixel belongs to, as bucket, frame (0-based, rows then columns).
-- Returns nil for a coordinate off the sheet — the answer a hit test wants when
-- the cursor is in the margin rather than a clamped lie about cell 0.
function Sheet.cellAt(sheet, x, y)
    if x < 0 or y < 0 or x >= sheet.width or y >= sheet.height then return nil end
    return floor(y / sheet.cellH), floor(x / sheet.cellW)
end

-- Where a pixel sits inside its own cell.
function Sheet.localAt(sheet, x, y)
    if x < 0 or y < 0 or x >= sheet.width or y >= sheet.height then return nil end
    return x % sheet.cellW, y % sheet.cellH
end

-- Row-major sequence number of a cell, 1-based, matching Slice.index.
function Sheet.cellIndex(sheet, bucket, frame)
    if bucket < 0 or frame < 0 or bucket >= sheet.angles or frame >= sheet.frames then
        return nil
    end
    return bucket * sheet.frames + frame + 1
end

function Sheet.cellCount(sheet)
    return sheet.angles * sheet.frames
end

---------------------------------------------------------------------------
-- Palette
---------------------------------------------------------------------------

-- The colour an index names, as four bytes. Index 0 — and any index that is not a
-- palette entry — is fully transparent, so a lookup can never fail into a nil
-- colour halfway through a draw loop.
function Sheet.color(sheet, index)
    local c = sheet.palette[index]
    if not c then return 0, 0, 0, 0 end
    return c[1], c[2], c[3], c[4]
end

-- The index naming this colour, or nil. Fully transparent is index 0 by
-- definition rather than by search.
function Sheet.findColor(sheet, r, g, b, a)
    r, g, b = byte(r), byte(g), byte(b)
    a = a == nil and 255 or byte(a)

    if r == 0 and g == 0 and b == 0 and a == 0 then return 0 end

    for i = 1, #sheet.palette do
        local c = sheet.palette[i]
        if c[1] == r and c[2] == g and c[3] == b and c[4] == a then return i end
    end
    return nil
end

-- Finds or appends. Returns the index, or nil plus a reason when the palette is
-- full.
function Sheet.addColor(sheet, r, g, b, a)
    local found = Sheet.findColor(sheet, r, g, b, a)
    if found then return found end

    if #sheet.palette >= Sheet.MAX_COLORS then
        return nil, ('palette is full at %d colours'):format(Sheet.MAX_COLORS)
    end

    sheet.palette[#sheet.palette + 1] = {
        byte(r), byte(g), byte(b), a == nil and 255 or byte(a),
    }
    return #sheet.palette
end

-- Edits a slot in place. Every pixel already drawn in that slot changes with it,
-- which is the point: recolouring a sheet should not mean repainting it.
function Sheet.setColor(sheet, index, r, g, b, a)
    local c = sheet.palette[index]
    if not c then return false end
    c[1], c[2], c[3] = byte(r), byte(g), byte(b)
    c[4] = a == nil and 255 or byte(a)
    return true
end

function Sheet.colorCount(sheet)
    return #sheet.palette
end

---------------------------------------------------------------------------
-- Diffs
---------------------------------------------------------------------------

-- An empty change record. Three parallel arrays rather than a list of tables:
-- a stroke can touch tens of thousands of pixels and one table per pixel is how a
-- painter turns into a garbage collector.
function Sheet.diff(label)
    return { label = label or 'edit', n = 0, idx = {}, before = {}, after = {} }
end

-- Replays a diff forwards, or backwards for undo. Returns how many pixels moved.
--
-- The iteration order is load-bearing and was a real bug here. One edit may touch
-- the same pixel more than once — a filled rectangle followed by a detail drawn on
-- top of it, or a brush dragged back across its own line — and the diff then holds
-- two entries for that pixel. Replaying forwards must go oldest-to-newest so the
-- last write wins; reversing must go newest-to-oldest so the *first* recorded
-- `before` is what survives. Reversing in forward order restores the intermediate
-- value instead of the original, which shows up as undo leaving a few pixels
-- behind rather than as an obvious failure.
function Sheet.applyDiff(sheet, d, reverse)
    if not d then return 0 end
    local idx = d.idx
    local pixels = sheet.pixels

    if reverse then
        local before = d.before
        for i = d.n, 1, -1 do pixels[idx[i]] = before[i] end
    else
        local after = d.after
        for i = 1, d.n do pixels[idx[i]] = after[i] end
    end

    return d.n
end

---------------------------------------------------------------------------
-- Reading and writing pixels
---------------------------------------------------------------------------

local function offsetOf(sheet, x, y)
    return y * sheet.width + x + 1
end

Sheet.offsetOf = offsetOf

local function inside(sheet, x, y, bounds)
    if x < 0 or y < 0 or x >= sheet.width or y >= sheet.height then return false end
    if bounds then
        if x < bounds.x or y < bounds.y
           or x >= bounds.x + bounds.w or y >= bounds.y + bounds.h then
            return false
        end
    end
    return true
end

Sheet.inside = inside

-- The palette index at a pixel, or nil off the sheet. Distinguishing "transparent"
-- (0) from "not on the sheet" (nil) matters for the pick tool, which should do
-- nothing rather than select transparent when you click the margin.
function Sheet.get(sheet, x, y)
    if x < 0 or y < 0 or x >= sheet.width or y >= sheet.height then return nil end
    return sheet.pixels[offsetOf(sheet, x, y)]
end

Sheet.pick = Sheet.get

-- Writes one pixel, recording into `d` if given. Returns true when the pixel
-- actually changed — a write of the value already there records nothing, which is
-- what keeps a slow drag over the same pixel from filling the undo stack with
-- no-ops.
function Sheet.plot(sheet, x, y, index, d, bounds)
    if not inside(sheet, x, y, bounds) then return false end

    local off = offsetOf(sheet, x, y)
    local old = sheet.pixels[off]
    if old == index then return false end

    if d then
        local n = d.n + 1
        d.n = n
        d.idx[n] = off
        d.before[n] = old
        d.after[n] = index
    end

    sheet.pixels[off] = index
    return true
end

-- A square brush centred on (x, y). Size 1 is a single pixel; even sizes bias up
-- and left, which is the convention every pixel editor uses and the one that makes
-- a 2px brush land where the cursor is rather than half a pixel off it.
function Sheet.stamp(sheet, x, y, index, size, d, bounds)
    size = max(1, floor(size or 1))
    local half = floor((size - 1) / 2)
    local changed = 0
    for py = y - half, y - half + size - 1 do
        for px = x - half, x - half + size - 1 do
            if Sheet.plot(sheet, px, py, index, d, bounds) then changed = changed + 1 end
        end
    end
    return changed
end

-- Bresenham between two stamps.
--
-- Not a nicety: a freehand stroke is sampled once per frame, so at 60fps and any
-- real pointer speed the samples are pixels apart and painting only at them draws
-- a dotted line. Every painter that feels broken to draw in is missing this.
function Sheet.line(sheet, x0, y0, x1, y1, index, size, d, bounds)
    x0, y0, x1, y1 = floor(x0), floor(y0), floor(x1), floor(y1)

    local dx = abs(x1 - x0)
    local dy = -abs(y1 - y0)
    local sx = x0 < x1 and 1 or -1
    local sy = y0 < y1 and 1 or -1
    local err = dx + dy

    local changed = 0
    local guard = dx - dy + 2       -- the exact step count, plus slack

    while guard > 0 do
        guard = guard - 1
        changed = changed + Sheet.stamp(sheet, x0, y0, index, size, d, bounds)
        if x0 == x1 and y0 == y1 then break end

        local e2 = 2 * err
        if e2 >= dy then err = err + dy; x0 = x0 + sx end
        if e2 <= dx then err = err + dx; y0 = y0 + sy end
    end

    return changed
end

-- A rectangle, outlined or filled, between two corners in any order.
function Sheet.rectangle(sheet, x0, y0, x1, y1, index, opts, d, bounds)
    opts = opts or {}
    local lo_x, hi_x = min(x0, x1), max(x0, x1)
    local lo_y, hi_y = min(y0, y1), max(y0, y1)
    local changed = 0

    if opts.filled then
        for y = lo_y, hi_y do
            for x = lo_x, hi_x do
                if Sheet.plot(sheet, x, y, index, d, bounds) then changed = changed + 1 end
            end
        end
        return changed
    end

    for x = lo_x, hi_x do
        if Sheet.plot(sheet, x, lo_y, index, d, bounds) then changed = changed + 1 end
        if hi_y ~= lo_y and Sheet.plot(sheet, x, hi_y, index, d, bounds) then
            changed = changed + 1
        end
    end
    for y = lo_y + 1, hi_y - 1 do
        if Sheet.plot(sheet, lo_x, y, index, d, bounds) then changed = changed + 1 end
        if hi_x ~= lo_x and Sheet.plot(sheet, hi_x, y, index, d, bounds) then
            changed = changed + 1
        end
    end
    return changed
end

-- Four-connected flood fill from a seed, over an explicit stack.
--
-- Recursion is the textbook version and it is wrong here: a fill over a
-- thousand-pixel region recurses a thousand deep, and Lua's stack limit turns a
-- large fill into a crash rather than a slow operation.
--
-- `bounds` is what makes fill safe on a sprite sheet. Without it, filling the
-- background of one frame runs straight across the cell boundary and floods every
-- bucket in the sheet, because nothing in the pixel data marks where one cell ends
-- and the next begins. The painter always passes the active cell.
function Sheet.fill(sheet, x, y, index, d, bounds)
    if not inside(sheet, x, y, bounds) then return 0 end

    local target = sheet.pixels[offsetOf(sheet, x, y)]
    if target == index then return 0 end

    local stack = { x, y }
    local top = 2
    local changed = 0

    while top > 0 do
        local py = stack[top]; top = top - 1
        local px = stack[top]; top = top - 1

        if inside(sheet, px, py, bounds)
           and sheet.pixels[offsetOf(sheet, px, py)] == target then
            Sheet.plot(sheet, px, py, index, d, bounds)
            changed = changed + 1

            stack[top + 1] = px + 1; stack[top + 2] = py
            stack[top + 3] = px - 1; stack[top + 4] = py
            stack[top + 5] = px;     stack[top + 6] = py + 1
            stack[top + 7] = px;     stack[top + 8] = py - 1
            top = top + 8
        end
    end

    return changed
end

---------------------------------------------------------------------------
-- Cell operations
---------------------------------------------------------------------------

function Sheet.clearCell(sheet, bucket, frame, d)
    local bounds = Sheet.cellBounds(sheet, bucket, frame)
    if not bounds then return 0 end
    return Sheet.rectangle(sheet, bounds.x, bounds.y,
                           bounds.x + bounds.w - 1, bounds.y + bounds.h - 1,
                           0, { filled = true }, d, bounds)
end

-- Copies one cell over another. The reason a directional sheet is bearable to
-- author at all: draw bucket 0, copy it sideways, and edit the copy rather than
-- redrawing a silhouette eight times.
function Sheet.copyCell(sheet, fromBucket, fromFrame, toBucket, toFrame, d)
    local src = Sheet.cellBounds(sheet, fromBucket, fromFrame)
    local dst = Sheet.cellBounds(sheet, toBucket, toFrame)
    if not src or not dst then return 0 end
    if src.x == dst.x and src.y == dst.y then return 0 end

    local changed = 0
    for row = 0, src.h - 1 do
        for col = 0, src.w - 1 do
            local value = sheet.pixels[offsetOf(sheet, src.x + col, src.y + row)]
            if Sheet.plot(sheet, dst.x + col, dst.y + row, value, d, dst) then
                changed = changed + 1
            end
        end
    end
    return changed
end

-- Draws one crude figure per cell: narrower and dimmer the further its bucket
-- faces away, with two eyes toward the viewer, one in profile, and none from
-- behind.
--
-- Not decoration, and not art. A painter that opens on an empty grid gives you
-- nothing to check your bucket order against, and bucket order is invisible until
-- something is drawn in every row — which is the entire reason this tool exists.
-- This is that something, and the intent is that you paint over it. It follows the
-- same reading as the engine's generated placeholders (bucket 0 faces the viewer,
-- angles/2 faces away) so a sheet started here and a sheet the engine generated
-- agree about which row is which.
function Sheet.starter(sheet, opts)
    opts = opts or {}
    local body = opts.body or 3
    local dim = opts.dim or 2
    local eye = opts.eye or 5
    local d = opts.diff

    local changed = 0

    for bucket = 0, sheet.angles - 1 do
        local away = 0
        if sheet.angles > 1 then
            away = min(bucket, sheet.angles - bucket) / (sheet.angles / 2)
        end
        local facingAway = away > 0.99
        local fill = facingAway and dim or body

        for frame = 0, sheet.frames - 1 do
            local b = Sheet.cellBounds(sheet, bucket, frame)
            local w, h = b.w, b.h

            local bodyW = max(1, floor(w * (0.46 - away * 0.10)))
            local bodyH = max(1, floor(h * 0.58))
            local bx = b.x + floor((w - bodyW) / 2)
            -- A one-pixel bob on odd frames, so the animation is visible too.
            local by = b.y + h - bodyH - max(1, floor(h * 0.06)) + (frame % 2)

            changed = changed + Sheet.rectangle(sheet, bx, by, bx + bodyW - 1,
                                                by + bodyH - 1, fill,
                                                { filled = true }, d, b)

            local headW = max(1, floor(w * 0.30))
            local headH = max(1, floor(h * 0.22))
            local hx = b.x + floor((w - headW) / 2)
            local hy = by - headH

            changed = changed + Sheet.rectangle(sheet, hx, hy, hx + headW - 1,
                                                hy + headH - 1, fill,
                                                { filled = true }, d, b)

            if not facingAway then
                local ey = hy + floor(headH / 2)
                if away < 0.5 then
                    local inset = floor(headW * 0.25)
                    if Sheet.plot(sheet, hx + inset, ey, eye, d, b) then
                        changed = changed + 1
                    end
                    if Sheet.plot(sheet, hx + headW - 1 - inset, ey, eye, d, b) then
                        changed = changed + 1
                    end
                elseif Sheet.plot(sheet, hx + floor(headW / 2), ey, eye, d, b) then
                    changed = changed + 1
                end
            end
        end
    end

    return changed
end

-- Counts the pixels that are not transparent, per cell and overall. The cheap
-- answer to "which buckets have I actually drawn?", which is the question a
-- half-finished 8-bucket sheet raises every time.
function Sheet.coverage(sheet)
    local out = { total = 0, cells = {} }
    for bucket = 0, sheet.angles - 1 do
        for frame = 0, sheet.frames - 1 do
            local b = Sheet.cellBounds(sheet, bucket, frame)
            local lit = 0
            for y = b.y, b.y + b.h - 1 do
                for x = b.x, b.x + b.w - 1 do
                    if sheet.pixels[offsetOf(sheet, x, y)] ~= 0 then lit = lit + 1 end
                end
            end
            out.cells[Sheet.cellIndex(sheet, bucket, frame)] = lit
            out.total = out.total + lit
        end
    end
    return out
end

---------------------------------------------------------------------------
-- Export and import, at the level of bytes
--
-- These two are exact inverses, and that is the whole contract. The LÖVE side
-- (meatray.asset.sheet_image) does nothing but move these bytes in and out of an
-- ImageData, so if these agree the file round trip agrees too.
---------------------------------------------------------------------------

-- Row-major RGBA bytes: 4 * width * height numbers in 0..255.
function Sheet.toBytes(sheet)
    local out = {}
    local palette = sheet.palette
    local pixels = sheet.pixels
    local n = 0

    for i = 1, sheet.width * sheet.height do
        local c = palette[pixels[i]]
        if c then
            out[n + 1] = c[1]; out[n + 2] = c[2]; out[n + 3] = c[3]; out[n + 4] = c[4]
        else
            out[n + 1] = 0; out[n + 2] = 0; out[n + 3] = 0; out[n + 4] = 0
        end
        n = n + 4
    end

    return out
end

-- Rebuilds a sheet from raw bytes, deriving the palette from the colours actually
-- present in first-seen row-major order.
--
-- Deriving rather than requiring a palette is what makes import work on a file
-- this editor did not write. Deriving *deterministically* is what makes the round
-- trip provable: the same bytes always give the same palette and therefore the
-- same bytes back.
function Sheet.fromBytes(width, height, bytes, opts)
    opts = opts or {}

    local angles = opts.angles or 1
    local frames = opts.frames or 1

    local plan = Slice.forSheet(width, height, angles, frames)
    if not plan.ok and not opts.force then
        return nil, ('a %d bucket x %d frame grid does not fit %dx%d: %s')
            :format(angles, frames, tostring(width), tostring(height),
                    table.concat(plan.problems, '; '))
    end

    local sheet, err = Sheet.new{
        angles = plan.rows, frames = plan.cols,
        cellW = plan.cellW, cellH = plan.cellH,
        palette = {},
    }
    if not sheet then return nil, err end

    local expected = width * height * 4
    if #bytes < expected then
        return nil, ('expected %d bytes for a %dx%d image, got %d')
            :format(expected, width, height, #bytes)
    end

    local lookup = {}          -- packed colour -> index, so import is not O(n*palette)
    local pixels = sheet.pixels
    local palette = sheet.palette

    for i = 1, sheet.width * sheet.height do
        local o = (i - 1) * 4
        local r, g, b, a = byte(bytes[o + 1]), byte(bytes[o + 2]),
                           byte(bytes[o + 3]), byte(bytes[o + 4])

        if r == 0 and g == 0 and b == 0 and a == 0 then
            pixels[i] = 0
        else
            local packed = ((r * 256 + g) * 256 + b) * 256 + a
            local index = lookup[packed]
            if not index then
                if #palette >= Sheet.MAX_COLORS then
                    return nil, ('image uses more than %d distinct colours')
                        :format(Sheet.MAX_COLORS)
                end
                palette[#palette + 1] = { r, g, b, a }
                index = #palette
                lookup[packed] = index
            end
            pixels[i] = index
        end
    end

    return sheet
end

-- Byte-for-byte comparison, for a round-trip assertion that says where it broke
-- rather than just that it did.
function Sheet.sameBytes(a, b)
    if #a ~= #b then
        return false, ('length %d vs %d'):format(#a, #b)
    end
    for i = 1, #a do
        if a[i] ~= b[i] then
            local pixel = floor((i - 1) / 4)
            return false, ('byte %d (pixel %d, channel %d): %s vs %s')
                :format(i, pixel, (i - 1) % 4 + 1, tostring(a[i]), tostring(b[i]))
        end
    end
    return true
end

return Sheet
