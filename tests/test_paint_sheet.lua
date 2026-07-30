--[[
    meatray.asset.sheet — the sprite painter's pixel model.

    Everything here runs under plain LuaJIT with no LÖVE, which is the point: cell
    indexing, flood fill, and the export/import round trip are all pure arithmetic
    over a flat array, and all three are exactly the kind of thing that is nearly
    impossible to debug by looking at a canvas.

    The cell-indexing assertions are the ones that earn their place. A sprite sheet
    is `angles` rows by `frames` columns, and an editor that gets that transposed
    lets you hand-author a directional sheet with its buckets in the wrong order —
    which renders as an enemy showing you its back while it walks toward you, three
    days after you drew it.
]]

local Sheet = require('meatray.asset.sheet')

return function(t)
    ---------------------------------------------------------------------
    t.describe('construction')

    local s = Sheet.new{ angles = 8, frames = 4, cellW = 12, cellH = 16 }
    t.ok(s ~= nil, 'a sheet builds from a grid and a cell size')
    t.eq(s.width, 48, 'width is cell width times frames (columns)')
    t.eq(s.height, 128, 'height is cell height times angles (rows)')
    t.eq(#s.pixels, 48 * 128, 'the buffer holds one entry per pixel')
    t.eq(s.pixels[1], 0, 'and starts fully transparent')
    t.eq(s.pixels[#s.pixels], 0, 'all the way to the last pixel')
    t.eq(#s.palette, #Sheet.DEFAULT_PALETTE, 'with the default palette loaded')

    t.ok(Sheet.new{ angles = 0 } == nil, 'zero angle buckets is refused')
    t.ok(Sheet.new{ frames = 2.5 } == nil, 'a fractional frame count is refused')
    t.ok(Sheet.new{ cellW = 0 } == nil, 'a zero-width cell is refused')
    t.ok(Sheet.new{ angles = 512, frames = 512, cellW = 64, cellH = 64 } == nil,
         'a sheet over the pixel ceiling is refused rather than allocated')

    local _, why = Sheet.new{ angles = -3 }
    t.ok(type(why) == 'string' and why:find('angles'), 'and says which number was wrong')

    -- The palette is copied, not shared. Two sheets built from the same default
    -- must not recolour each other.
    local a = Sheet.new{ angles = 1, frames = 1, cellW = 4, cellH = 4 }
    local b = Sheet.new{ angles = 1, frames = 1, cellW = 4, cellH = 4 }
    Sheet.setColor(a, 1, 255, 0, 0, 255)
    local br = select(1, Sheet.color(b, 1))
    t.eq(br, Sheet.DEFAULT_PALETTE[1][1], 'palettes are per sheet, not shared')

    ---------------------------------------------------------------------
    t.describe('cell indexing')

    -- Every pixel on the sheet, checked against the cell it should belong to.
    -- Exhaustive on purpose: an off-by-one at a cell boundary is the whole bug
    -- class this module exists to prevent, and it lives exactly at the edges.
    local wrong = 0
    for y = 0, s.height - 1 do
        for x = 0, s.width - 1 do
            local bucket, frame = Sheet.cellAt(s, x, y)
            if bucket ~= math.floor(y / 16) or frame ~= math.floor(x / 12) then
                wrong = wrong + 1
            end
        end
    end
    t.eq(wrong, 0, 'every pixel maps to the cell its coordinates fall in')

    t.ok(Sheet.cellAt(s, -1, 0) == nil, 'a pixel left of the sheet has no cell')
    t.ok(Sheet.cellAt(s, 0, -1) == nil, 'nor one above it')
    t.ok(Sheet.cellAt(s, 48, 0) == nil, 'nor one past the right edge')
    t.ok(Sheet.cellAt(s, 0, 128) == nil, 'nor one past the bottom')

    local bucket, frame = Sheet.cellAt(s, 47, 127)
    t.eq(bucket, 7, 'the last pixel is in the last bucket')
    t.eq(frame, 3, 'and the last frame')

    -- Rows are buckets and columns are frames. Stated as an assertion because
    -- reading it the other way round is the mistake.
    local justInside = Sheet.cellAt(s, 11, 15)
    t.eq(justInside, 0, 'the pixel before the first boundary is still bucket 0')
    t.eq(select(2, Sheet.cellAt(s, 11, 15)), 0, 'and frame 0')
    t.eq(Sheet.cellAt(s, 12, 15), 0, 'one pixel right stays in bucket 0')
    t.eq(select(2, Sheet.cellAt(s, 12, 15)), 1, 'and moves to frame 1')
    t.eq(Sheet.cellAt(s, 11, 16), 1, 'one pixel down moves to bucket 1')
    t.eq(select(2, Sheet.cellAt(s, 11, 16)), 0, 'and stays on frame 0')

    local cx, cy, cw, ch = Sheet.cell(s, 3, 2)
    t.eq(cx, 24, 'cell (bucket 3, frame 2) starts at x = frame * cellW')
    t.eq(cy, 48, 'and y = bucket * cellH')
    t.eq(cw, 12, 'with the declared cell width')
    t.eq(ch, 16, 'and height')

    t.ok(Sheet.cell(s, 8, 0) == nil, 'a bucket past the last one has no rect')
    t.ok(Sheet.cell(s, 0, 4) == nil, 'nor a frame past the last one')

    local lx, ly = Sheet.localAt(s, 25, 49)
    t.eq(lx, 1, 'a pixel reports its offset inside its own cell')
    t.eq(ly, 1, 'in both axes')

    t.eq(Sheet.cellIndex(s, 0, 0), 1, 'cell numbering is row-major from 1')
    t.eq(Sheet.cellIndex(s, 0, 3), 4, 'across the first row')
    t.eq(Sheet.cellIndex(s, 1, 0), 5, 'then wrapping to the next bucket')
    t.eq(Sheet.cellIndex(s, 7, 3), 32, 'up to the last cell')
    t.ok(Sheet.cellIndex(s, 8, 0) == nil, 'and nothing beyond it')
    t.eq(Sheet.cellCount(s), 32, 'a sheet has angles times frames cells')

    -- The bounds a tool is handed must be the cell exactly, or fill leaks.
    local bounds = Sheet.cellBounds(s, 2, 1)
    t.eq(bounds.x, 12, 'cell bounds start on the cell')
    t.eq(bounds.y, 32, 'in both axes')
    t.eq(bounds.w, 12, 'and are one cell wide')
    t.eq(bounds.h, 16, 'and one cell tall')

    ---------------------------------------------------------------------
    t.describe('plotting and diffs')

    local p = Sheet.new{ angles = 2, frames = 2, cellW = 8, cellH = 8 }
    local d = Sheet.diff('test')

    t.ok(Sheet.plot(p, 0, 0, 5, d), 'plotting a pixel reports a change')
    t.eq(Sheet.get(p, 0, 0), 5, 'and the pixel holds the new index')
    t.eq(d.n, 1, 'and the diff recorded one change')
    t.eq(d.before[1], 0, 'with what was there before')
    t.eq(d.after[1], 5, 'and what replaced it')

    t.ok(not Sheet.plot(p, 0, 0, 5, d), 'plotting the same value again changes nothing')
    t.eq(d.n, 1, 'and records nothing, so a slow drag does not fill the undo stack')

    t.ok(not Sheet.plot(p, -1, 0, 5, d), 'a pixel off the sheet is refused')
    t.ok(not Sheet.plot(p, 0, 99, 5, d), 'in either direction')
    t.eq(d.n, 1, 'and records nothing either')

    t.ok(Sheet.get(p, -1, 0) == nil, 'reading off the sheet is nil, not transparent')
    t.eq(Sheet.get(p, 1, 1), 0, 'reading an untouched pixel is transparent, not nil')

    -- Reversal must be exact, since this is the mechanism undo rides on.
    Sheet.applyDiff(p, d, true)
    t.eq(Sheet.get(p, 0, 0), 0, 'reversing a diff restores the previous pixel')
    Sheet.applyDiff(p, d, false)
    t.eq(Sheet.get(p, 0, 0), 5, 'and replaying it forwards restores the edit')

    -- One edit may touch the same pixel twice — a filled shape with a detail drawn
    -- on top, or a brush dragged back over its own line. Reversing such a diff has
    -- to walk backwards, or it restores the intermediate value and undo leaves a
    -- few pixels behind. That was a real bug here, caught by the starter drawing
    -- (which draws a head over a body and eyes over the head) rather than by any
    -- single-write case, which is why it is pinned down explicitly.
    local twice = Sheet.new{ angles = 1, frames = 1, cellW = 4, cellH = 4 }
    local layered = Sheet.diff('layered')
    Sheet.plot(twice, 1, 1, 3, layered)
    Sheet.plot(twice, 1, 1, 7, layered)
    t.eq(layered.n, 2, 'both writes to the same pixel are recorded')
    t.eq(Sheet.get(twice, 1, 1), 7, 'and the last one is what stands')

    Sheet.applyDiff(twice, layered, true)
    t.eq(Sheet.get(twice, 1, 1), 0,
         'reversing restores the value from before the first write, not the second')

    Sheet.applyDiff(twice, layered, false)
    t.eq(Sheet.get(twice, 1, 1), 7, 'and replaying forwards lands on the last write again')

    -- Bounds keep a tool inside the cell it was started in.
    local cellBounds = Sheet.cellBounds(p, 0, 0)
    t.ok(not Sheet.plot(p, 8, 0, 3, nil, cellBounds),
         'a plot outside the active cell is refused when bounds are given')
    t.ok(Sheet.plot(p, 7, 7, 3, nil, cellBounds), 'and allowed inside it')

    ---------------------------------------------------------------------
    t.describe('brush, line and rectangle')

    local q = Sheet.new{ angles = 1, frames = 1, cellW = 16, cellH = 16 }

    t.eq(Sheet.stamp(q, 8, 8, 2, 1), 1, 'a size-1 brush paints one pixel')
    t.eq(Sheet.stamp(q, 4, 4, 2, 3), 9, 'a size-3 brush paints nine')
    t.eq(Sheet.get(q, 3, 3), 2, 'centred on the cursor')
    t.eq(Sheet.get(q, 5, 5), 2, 'in both directions')
    t.eq(Sheet.get(q, 6, 6), 0, 'and no further')

    local clipped = Sheet.new{ angles = 1, frames = 1, cellW = 16, cellH = 16 }
    t.eq(Sheet.stamp(clipped, 0, 0, 2, 3), 4,
         'a brush at the corner paints only the pixels that exist')

    local line = Sheet.new{ angles = 1, frames = 1, cellW = 16, cellH = 16 }
    Sheet.line(line, 0, 0, 15, 15, 4, 1)
    local diagonal = 0
    for i = 0, 15 do
        if Sheet.get(line, i, i) == 4 then diagonal = diagonal + 1 end
    end
    t.eq(diagonal, 16, 'a 45-degree line hits every pixel on the diagonal')

    -- The reason Bresenham is here at all: a stroke sampled once a frame skips
    -- pixels, and painting only at the samples draws a dotted line.
    local gaps = Sheet.new{ angles = 1, frames = 1, cellW = 16, cellH = 16 }
    Sheet.line(gaps, 0, 8, 15, 8, 4, 1)
    local run = 0
    for x = 0, 15 do
        if Sheet.get(gaps, x, 8) == 4 then run = run + 1 end
    end
    t.eq(run, 16, 'a horizontal line is unbroken end to end')

    local dot = Sheet.new{ angles = 1, frames = 1, cellW = 8, cellH = 8 }
    t.eq(Sheet.line(dot, 3, 3, 3, 3, 6, 1), 1, 'a zero-length line paints one pixel')

    local outline = Sheet.new{ angles = 1, frames = 1, cellW = 10, cellH = 10 }
    Sheet.rectangle(outline, 1, 1, 5, 4, 7, {})
    t.eq(Sheet.get(outline, 1, 1), 7, 'an outlined rectangle draws its corners')
    t.eq(Sheet.get(outline, 5, 4), 7, 'both of them')
    t.eq(Sheet.get(outline, 3, 1), 7, 'and its top edge')
    t.eq(Sheet.get(outline, 3, 4), 7, 'and its bottom edge')
    t.eq(Sheet.get(outline, 3, 2), 0, 'and leaves the inside alone')

    local solid = Sheet.new{ angles = 1, frames = 1, cellW = 10, cellH = 10 }
    t.eq(Sheet.rectangle(solid, 5, 4, 1, 1, 7, { filled = true }), 20,
         'a filled rectangle covers its whole area, corners given in any order')
    t.eq(Sheet.get(solid, 3, 2), 7, 'including the middle')

    ---------------------------------------------------------------------
    t.describe('flood fill')

    -- A plain grid with a wall down the middle: fill must respect it.
    local f = Sheet.new{ angles = 1, frames = 1, cellW = 9, cellH = 9 }
    for y = 0, 8 do Sheet.plot(f, 4, y, 1) end

    local filled = Sheet.fill(f, 0, 0, 2)
    t.eq(filled, 36, 'a fill covers the region it started in and stops at the wall')
    t.eq(Sheet.get(f, 3, 8), 2, 'reaching the far corner of that region')
    t.eq(Sheet.get(f, 5, 0), 0, 'and not crossing to the other side')
    t.eq(Sheet.get(f, 4, 4), 1, 'leaving the wall itself untouched')

    t.eq(Sheet.fill(f, 0, 0, 2), 0, 'filling with the colour already there does nothing')
    t.eq(Sheet.fill(f, -1, 0, 3), 0, 'and a seed off the sheet does nothing')

    -- Four-connected, not eight: two regions touching only at a corner are two
    -- regions. Getting this wrong makes fill leak through single-pixel diagonals,
    -- which on pixel art is most of them.
    local diag = Sheet.new{ angles = 1, frames = 1, cellW = 4, cellH = 4 }
    Sheet.plot(diag, 1, 0, 1); Sheet.plot(diag, 0, 1, 1)
    Sheet.plot(diag, 2, 1, 1); Sheet.plot(diag, 1, 2, 1)
    local pocket = Sheet.fill(diag, 1, 1, 5)
    t.eq(pocket, 1, 'a pocket closed diagonally does not leak out of its corner')

    -- The sprite-sheet case, and the reason bounds exist. Without them a fill in
    -- one frame runs across the cell boundary and floods every bucket, because
    -- nothing in the pixel data marks where a cell ends.
    local sheetFill = Sheet.new{ angles = 4, frames = 2, cellW = 6, cellH = 6 }
    local cell = Sheet.cellBounds(sheetFill, 1, 0)
    local within = Sheet.fill(sheetFill, cell.x, cell.y, 3, nil, cell)
    t.eq(within, 36, 'a bounded fill covers exactly one cell')
    t.eq(Sheet.get(sheetFill, 6, 6), 0, 'and does not reach the next frame')
    t.eq(Sheet.get(sheetFill, 0, 0), 0, 'nor the bucket above')
    t.eq(Sheet.get(sheetFill, 0, 12), 0, 'nor the bucket below')

    local unbounded = Sheet.new{ angles = 4, frames = 2, cellW = 6, cellH = 6 }
    t.eq(Sheet.fill(unbounded, 0, 0, 3), 12 * 24,
         'and an unbounded fill floods the whole sheet, which is why bounds are passed')

    ---------------------------------------------------------------------
    t.describe('palette')

    local pal = Sheet.new{ angles = 1, frames = 1, cellW = 4, cellH = 4, palette = {} }
    t.eq(Sheet.colorCount(pal), 0, 'a sheet can start with no palette at all')

    local red = Sheet.addColor(pal, 255, 0, 0)
    t.eq(red, 1, 'adding a colour returns its index')
    t.eq(Sheet.colorCount(pal), 1, 'and grows the palette')
    t.eq(Sheet.addColor(pal, 255, 0, 0), 1, 'adding the same colour reuses the index')
    t.eq(Sheet.colorCount(pal), 1, 'rather than duplicating it')

    local r, g, bl, al = Sheet.color(pal, red)
    t.eq(r, 255, 'the colour reads back as bytes')
    t.eq(g, 0, 'in every channel')
    t.eq(bl, 0, 'exactly as given')
    t.eq(al, 255, 'with alpha defaulting to opaque')

    t.eq(Sheet.addColor(pal, 255, 0, 0, 128), 2,
         'the same RGB at a different alpha is a different colour')

    t.eq(Sheet.findColor(pal, 0, 0, 0, 0), 0, 'fully transparent is index 0 by definition')
    t.ok(Sheet.findColor(pal, 1, 2, 3) == nil, 'and an absent colour is nil, not a guess')

    local zr, zg, zb, za = Sheet.color(pal, 0)
    t.eq(zr + zg + zb + za, 0, 'index 0 reads as transparent black')
    t.eq(select(4, Sheet.color(pal, 9999)), 0, 'and so does any index with no entry')

    -- Values outside the byte range are clamped rather than stored, or export
    -- writes something a PNG cannot hold and the round trip stops being exact.
    local clampIndex = Sheet.addColor(pal, 300, -20, 12.4)
    local cr, cg, cb = Sheet.color(pal, clampIndex)
    t.eq(cr, 255, 'a channel over 255 clamps')
    t.eq(cg, 0, 'and one under zero clamps')
    t.eq(cb, 12, 'and a fractional one rounds to a byte')

    t.ok(Sheet.setColor(pal, red, 10, 20, 30), 'a palette slot can be recoloured in place')
    t.eq(select(1, Sheet.color(pal, red)), 10, 'and every pixel using it follows')
    t.ok(not Sheet.setColor(pal, 999, 1, 2, 3), 'recolouring a slot that is not there fails')

    ---------------------------------------------------------------------
    t.describe('export and import round trip')

    -- A sheet with something in every cell, so a transposed or mis-sliced round
    -- trip cannot pass by symmetry.
    local rt = Sheet.new{ angles = 8, frames = 4, cellW = 6, cellH = 5 }
    for bucketIndex = 0, 7 do
        for frameIndex = 0, 3 do
            local cb = Sheet.cellBounds(rt, bucketIndex, frameIndex)
            local index = (bucketIndex * 4 + frameIndex) % 16 + 1
            Sheet.rectangle(rt, cb.x, cb.y, cb.x + cb.w - 1, cb.y + cb.h - 1,
                            index, { filled = true }, nil, cb)
            Sheet.plot(rt, cb.x, cb.y, 0)       -- one transparent pixel per cell
        end
    end

    local bytes = Sheet.toBytes(rt)
    t.eq(#bytes, rt.width * rt.height * 4, 'export produces four bytes per pixel')

    local back, importErr = Sheet.fromBytes(rt.width, rt.height, bytes,
                                            { angles = 8, frames = 4 })
    t.ok(back ~= nil, 'and those bytes import again', importErr)
    t.eq(back.width, rt.width, 'at the same width')
    t.eq(back.height, rt.height, 'and height')
    t.eq(back.angles, 8, 'with the bucket count carried by the caller')
    t.eq(back.frames, 4, 'and the frame count')
    t.eq(back.cellW, 6, 'and the cell size derived from them')
    t.eq(back.cellH, 5, 'in both axes')

    local same, detail = Sheet.sameBytes(Sheet.toBytes(back), bytes)
    t.ok(same, 'and re-exporting gives byte-identical pixels', detail)

    -- Twice, because a round trip that is only idempotent on the second pass is a
    -- round trip that quietly changed something on the first.
    local twice = Sheet.fromBytes(back.width, back.height, Sheet.toBytes(back),
                                  { angles = 8, frames = 4 })
    local sameTwice, twiceDetail = Sheet.sameBytes(Sheet.toBytes(twice), bytes)
    t.ok(sameTwice, 'and a second round trip changes nothing further', twiceDetail)

    t.ok(back.palette ~= nil and #back.palette > 0,
         'the palette is derived from the colours actually present')
    t.ok(#back.palette <= 16, 'and holds no more entries than the image needed')

    -- Alpha must survive. A painter whose transparency is lost on save produces
    -- sprites with black boxes around them, which is the classic import symptom.
    local alpha = Sheet.new{ angles = 1, frames = 1, cellW = 4, cellH = 4, palette = {} }
    local ghost = Sheet.addColor(alpha, 200, 100, 50, 77)
    Sheet.plot(alpha, 1, 1, ghost)
    local alphaBytes = Sheet.toBytes(alpha)
    local alphaBack = Sheet.fromBytes(4, 4, alphaBytes, { angles = 1, frames = 1 })
    t.ok(Sheet.sameBytes(Sheet.toBytes(alphaBack), alphaBytes),
         'a partially transparent colour round trips exactly')
    t.eq(select(4, Sheet.color(alphaBack, Sheet.get(alphaBack, 1, 1))), 77,
         'with its alpha intact')

    local bad, badWhy = Sheet.fromBytes(48, 128, bytes, { angles = 7, frames = 4 })
    t.ok(bad == nil, 'a grid the image does not divide by is refused on import')
    t.ok(type(badWhy) == 'string' and badWhy:find('left over'),
         'with the remainder in the message', badWhy)

    local short, shortWhy = Sheet.fromBytes(4, 4, { 1, 2, 3 }, { angles = 1, frames = 1 })
    t.ok(short == nil, 'a truncated byte buffer is refused rather than half-read')
    t.ok(type(shortWhy) == 'string' and shortWhy:find('expected'),
         'saying how many bytes were wanted', shortWhy)

    local okSame, sameWhy = Sheet.sameBytes({ 1, 2 }, { 1, 3 })
    t.ok(not okSame, 'the comparison reports a mismatch')
    t.ok(type(sameWhy) == 'string' and sameWhy:find('byte 2'),
         'and says which byte differed', sameWhy)

    ---------------------------------------------------------------------
    t.describe('regrid')

    -- Flipping the counts is how you find out whether you laid the sheet out as
    -- 8 buckets of 4 frames or 4 buckets of 8, without exporting anything.
    local grid = Sheet.new{ angles = 8, frames = 4, cellW = 8, cellH = 8 }
    Sheet.plot(grid, 0, 0, 3)
    local pixelsBefore = Sheet.toBytes(grid)

    t.ok(Sheet.regrid(grid, 4, 8), 'a sheet regrids to another exact division')
    t.eq(grid.angles, 4, 'taking the new bucket count')
    t.eq(grid.frames, 8, 'and frame count')
    t.eq(grid.cellW, 4, 'with the cell size recomputed')
    t.eq(grid.cellH, 16, 'in both axes')
    t.eq(grid.width, 32, 'and the image itself unchanged in width')
    t.eq(grid.height, 64, 'and height')
    t.ok(Sheet.sameBytes(Sheet.toBytes(grid), pixelsBefore),
         'and not one pixel moved')

    local regridOk, regridWhy = Sheet.regrid(grid, 5, 8)
    t.ok(not regridOk, 'a grid that does not divide is refused')
    t.ok(type(regridWhy) == 'string' and regridWhy:find('does not divide'),
         'with the reason', regridWhy)
    t.eq(grid.angles, 4, 'leaving the sheet on its previous grid')

    ---------------------------------------------------------------------
    t.describe('cell operations')

    local c = Sheet.new{ angles = 2, frames = 2, cellW = 5, cellH = 5 }
    local source = Sheet.cellBounds(c, 0, 0)
    Sheet.rectangle(c, source.x, source.y, source.x + 4, source.y + 4, 9,
                    { filled = true }, nil, source)

    local cov = Sheet.coverage(c)
    t.eq(cov.total, 25, 'coverage counts every non-transparent pixel')
    t.eq(cov.cells[Sheet.cellIndex(c, 0, 0)], 25, 'attributed to the cell it is in')
    t.eq(cov.cells[Sheet.cellIndex(c, 1, 1)], 0, 'and none to an empty cell')

    local copyDiff = Sheet.diff('copy')
    t.eq(Sheet.copyCell(c, 0, 0, 1, 1, copyDiff), 25, 'a cell copies onto another')
    t.eq(Sheet.get(c, 5, 5), 9, 'landing at the destination cell origin')
    t.eq(Sheet.get(c, 9, 9), 9, 'and its far corner')
    t.eq(Sheet.get(c, 0, 5), 0, 'without touching the cells beside it')
    t.eq(Sheet.copyCell(c, 0, 0, 0, 0, nil), 0, 'copying a cell onto itself is a no-op')
    t.eq(Sheet.copyCell(c, 9, 9, 0, 0, nil), 0, 'and a cell that does not exist is refused')

    Sheet.applyDiff(c, copyDiff, true)
    t.eq(Sheet.get(c, 5, 5), 0, 'a copy is undoable like any other edit')

    local clearDiff = Sheet.diff('clear')
    t.eq(Sheet.clearCell(c, 0, 0, clearDiff), 25, 'clearing a cell blanks exactly it')
    t.eq(Sheet.coverage(c).total, 0, 'leaving nothing drawn')
    Sheet.applyDiff(c, clearDiff, true)
    t.eq(Sheet.coverage(c).total, 25, 'and it comes back on undo')

    ---------------------------------------------------------------------
    t.describe('the starting drawing')

    -- The starter exists so the painter opens on something whose bucket order can
    -- be checked. So the assertions are about exactly that: every cell drawn, and
    -- the buckets distinguishable from each other.
    local st = Sheet.new{ angles = 8, frames = 4, cellW = 16, cellH = 16 }
    local starterDiff = Sheet.diff('starter')
    t.ok(Sheet.starter(st, { diff = starterDiff }) > 0, 'the starter draws something')

    local stCoverage = Sheet.coverage(st)
    local emptyCells = 0
    for i = 1, Sheet.cellCount(st) do
        if (stCoverage.cells[i] or 0) == 0 then emptyCells = emptyCells + 1 end
    end
    t.eq(emptyCells, 0, 'and leaves no cell empty, in all 32 of them')

    -- Bucket 0 faces the viewer and bucket angles/2 faces away, matching the
    -- engine's own generated placeholders. Eyes are what carries that: two facing
    -- you, none from behind.
    local function eyesIn(sheet, bucket)
        local b = Sheet.cellBounds(sheet, bucket, 0)
        local count = 0
        for y = b.y, b.y + b.h - 1 do
            for x = b.x, b.x + b.w - 1 do
                if Sheet.get(sheet, x, y) == 5 then count = count + 1 end
            end
        end
        return count
    end

    t.eq(eyesIn(st, 0), 2, 'the bucket facing the viewer has two eyes')
    t.eq(eyesIn(st, 4), 0, 'the bucket facing away has none')
    t.eq(eyesIn(st, 2), 1, 'and a profile bucket has one')
    t.eq(eyesIn(st, 6), 1, 'on the other side too')

    -- Odd frames bob by a pixel, so the animation is visible as well as the
    -- facing. Equal coverage in every frame with different pixels is the shape of
    -- that.
    t.ok(stCoverage.cells[Sheet.cellIndex(st, 0, 0)]
         == stCoverage.cells[Sheet.cellIndex(st, 0, 1)],
         'frames of a bucket carry the same amount of figure')

    Sheet.applyDiff(st, starterDiff, true)
    t.eq(Sheet.coverage(st).total, 0, 'and the whole starter is one undoable edit')

    local flat = Sheet.new{ angles = 1, frames = 1, cellW = 12, cellH = 12 }
    t.ok(Sheet.starter(flat) > 0, 'a single-bucket sheet starts too')
    t.eq(eyesIn(flat, 0), 2, 'facing the viewer, since its only bucket does')

    local tiny = Sheet.new{ angles = 2, frames = 1, cellW = 1, cellH = 1 }
    t.ok(Sheet.starter(tiny) >= 0, 'and a one-pixel cell does not blow up')

    ---------------------------------------------------------------------
    t.describe('the painter model stays headless')

    -- The pixel model is not sim code, so tests/test_headless.lua does not cover
    -- it. It still has to load with no LÖVE — that is what lets every assertion
    -- above run under plain LuaJIT — so the same two checks are made here.
    for _, path in ipairs({ 'meatray/asset/sheet.lua', 'meatray/asset/history.lua' }) do
        local handle = io.open(path, 'r')
        if not handle then
            t.ok(false, ('%s is readable'):format(path))
        else
            local src = handle:read('*a')
            handle:close()
            local code = src:gsub('%-%-%[%[.-%]%]', ''):gsub('%-%-[^\n]*', '')
            t.ok(not code:find('love%.'), ('%s references no love API'):format(path))
        end
    end

    local savedLove = rawget(_G, 'love')
    rawset(_G, 'love', nil)
    for _, name in ipairs({ 'meatray.asset.sheet', 'meatray.asset.history' }) do
        package.loaded[name] = nil
        local loaded, err = pcall(require, name)
        t.ok(loaded, ('%s loads with no love global'):format(name), err)
    end
    rawset(_G, 'love', savedLove)
end
