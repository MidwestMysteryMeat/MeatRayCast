--[[
    Grid slicing.

    The bug this prevents is specific and expensive: a sheet whose dimensions do
    not divide evenly by its declared angle and frame counts imports without
    complaint and then renders every sprite shifted by the remainder — the bottom
    of one frame stacked on the top of the next. It reads as a renderer fault and
    it is a data fault, and by the time anyone looks at the numbers the import
    dialog is long closed. So every division is asserted here, including the ones
    that do not come out even.
]]

return function(t)
    local Slice = require('meatray.asset.slice')

    ---------------------------------------------------------------------
    t.describe('an exact grid')

    local plan = Slice.forSheet(192, 384, 8, 4)
    t.ok(plan.ok, 'a 192x384 sheet fits 8 buckets by 4 frames')
    t.ok(plan.exact, 'and reports as exact')
    t.eq(#plan.problems, 0, 'with nothing to report')
    t.eq(plan.cols, 4, 'frames become columns')
    t.eq(plan.rows, 8, 'angle buckets become rows')
    t.eq(plan.cellW, 48, 'cell width is the sheet width over the frame count')
    t.eq(plan.cellH, 48, 'cell height is the sheet height over the bucket count')
    t.eq(plan.count, 32, 'thirty-two cells in total')
    t.eq(plan.remainderW, 0, 'no width left over')
    t.eq(plan.remainderH, 0, 'no height left over')

    -- The generic spelling and the sprite-sheet spelling must agree, or the two
    -- callers of this module slice the same image differently.
    local generic = Slice.plan(192, 384, { cols = 4, rows = 8 })
    t.eq(generic.cellW, plan.cellW, 'cols/rows and frames/angles give the same cells')
    t.eq(generic.cellH, plan.cellH, 'on both axes')

    local both = Slice.plan(192, 384, { cols = 4, rows = 8, frames = 99, angles = 99 })
    t.eq(both.cols, 4, 'an explicit cols wins over frames')
    t.eq(both.rows, 8, 'an explicit rows wins over angles')

    t.describe('the default is a single cell')
    local single = Slice.plan(64, 64, nil)
    t.eq(single.cols, 1, 'one column by default')
    t.eq(single.rows, 1, 'one row by default')
    t.eq(single.count, 1, 'one cell')
    t.eq(single.cellW, 64, 'the whole image is the cell')
    t.ok(single.ok, 'and that always fits')

    ---------------------------------------------------------------------
    t.describe('a sheet that does not divide evenly')

    local ragged = Slice.forSheet(100, 64, 1, 3)
    t.ok(not ragged.ok, '100 pixels across 3 frames is refused')
    t.ok(not ragged.exact, 'and is not exact')
    t.eq(ragged.remainderW, 1, 'one pixel is left over')
    t.eq(#ragged.problems, 1, 'exactly one problem is reported')
    t.ok(ragged.problems[1]:find('1 px left over') ~= nil,
         'and the message names the remainder', ragged.problems[1])
    t.ok(ragged.problems[1]:find('100') ~= nil, 'and the width it could not divide')
    t.eq(ragged.cellW, 33, 'a usable cell size still comes back')

    local raggedTall = Slice.forSheet(64, 100, 3, 1)
    t.ok(not raggedTall.ok, 'the same check applies to rows')
    t.eq(raggedTall.remainderH, 1, 'with the height remainder reported')
    t.ok(raggedTall.problems[1]:find('height') ~= nil, 'and named as a height problem')

    local raggedBoth = Slice.forSheet(100, 100, 3, 3)
    t.eq(#raggedBoth.problems, 2, 'both axes are reported, not just the first')

    -- Nearly right is the dangerous case: one pixel of padding round a sheet is a
    -- common export setting and produces exactly this.
    local padded = Slice.forSheet(194, 386, 8, 4)
    t.ok(not padded.ok, 'a sheet with one pixel of padding is caught')

    ---------------------------------------------------------------------
    t.describe('nonsense counts are reported, never trusted')

    for _, bad in ipairs({ 0, -3, 2.5, 1 / 0, 99999 }) do
        local p = Slice.plan(64, 64, { cols = bad })
        t.ok(not p.ok, ('cols = %s is refused'):format(tostring(bad)))
        t.eq(p.cols, 1, ('cols = %s falls back to 1'):format(tostring(bad)))
    end

    local nonNumber = Slice.plan(64, 64, { rows = 'eight' })
    t.ok(not nonNumber.ok, 'a non-numeric row count is refused')
    t.eq(nonNumber.rows, 1, 'and falls back to 1 rather than erroring')

    t.describe('an image with no size')
    local empty = Slice.plan(0, 0, { cols = 2, rows = 2 })
    t.ok(not empty.ok, 'a zero-size image is refused')
    t.eq(empty.cellW, 0, 'and yields zero-size cells rather than a division by zero')

    local nilSize = Slice.plan(nil, nil, { cols = 2 })
    t.ok(not nilSize.ok, 'a nil size is refused too')

    t.describe('cells smaller than a pixel')
    local tiny = Slice.plan(4, 4, { cols = 8, rows = 8 })
    t.ok(not tiny.ok, 'an 8x8 grid on a 4x4 image is refused')

    ---------------------------------------------------------------------
    t.describe('cell rects are zero-based, matching the sprite quads')

    local x, y, w, h = Slice.cell(plan, 0, 0)
    t.eq(x, 0, 'cell (0,0) starts at the origin')
    t.eq(y, 0, 'on both axes')
    t.eq(w, 48, 'and is one cell wide')
    t.eq(h, 48, 'and one cell tall')

    local lx, ly = Slice.cell(plan, 3, 7)
    t.eq(lx, 144, 'the last column starts three cells in')
    t.eq(ly, 336, 'and the last row seven cells down')

    -- Off-grid asks must come back nil rather than a rect past the edge of the
    -- image, which is what turns "bucket 8 of 8" into a quad reading garbage.
    t.eq(Slice.cell(plan, 4, 0), nil, 'one column past the end is nil')
    t.eq(Slice.cell(plan, 0, 8), nil, 'one row past the end is nil')
    t.eq(Slice.cell(plan, -1, 0), nil, 'a negative column is nil')
    t.eq(Slice.cell(plan, 0, -1), nil, 'a negative row is nil')
    t.eq(Slice.cell(nil, 0, 0), nil, 'a nil plan is nil, not a crash')

    t.describe('row-major indexing')
    local c, r = Slice.index(plan, 1)
    t.eq(c, 0, 'cell 1 is column 0')
    t.eq(r, 0, 'and row 0')

    c, r = Slice.index(plan, 4)
    t.eq(c, 3, 'cell 4 is the end of the first row')
    t.eq(r, 0, 'still row 0')

    c, r = Slice.index(plan, 5)
    t.eq(c, 0, 'cell 5 wraps to the next row')
    t.eq(r, 1, 'which is row 1')

    c, r = Slice.index(plan, 32)
    t.eq(c, 3, 'the last cell is the last column')
    t.eq(r, 7, 'of the last row')

    t.eq(Slice.index(plan, 33), nil, 'one past the end is nil')
    t.eq(Slice.index(plan, 0), nil, 'index zero is nil, since cells count from one')

    t.describe('the whole grid at once')
    local cells = Slice.cells(plan)
    t.eq(#cells, 32, 'cells() returns one entry per cell')
    t.eq(cells[1].x, 0, 'starting at the origin')
    t.eq(cells[32].x, 144, 'and ending at the last cell')
    t.eq(cells[32].y, 336, 'on both axes')

    local distinct = {}
    local overlaps = 0
    for _, cell in ipairs(cells) do
        local key = cell.x .. ',' .. cell.y
        if distinct[key] then overlaps = overlaps + 1 end
        distinct[key] = true
    end
    t.eq(overlaps, 0, 'no two cells claim the same pixel origin')

    ---------------------------------------------------------------------
    t.describe('fits() is the cheap answer')
    t.ok(Slice.fits(192, 384, 4, 8), 'an exact grid fits')
    t.ok(not Slice.fits(100, 384, 3, 8), 'an inexact one does not')

    t.describe('guessing a grid from square cells')
    local cols, rows = Slice.guess(256, 64)
    t.eq(cols, 4, 'a wide strip guesses four columns')
    t.eq(rows, 1, 'and one row')

    cols, rows = Slice.guess(64, 256)
    t.eq(cols, 1, 'a tall strip guesses one column')
    t.eq(rows, 4, 'and four rows')

    cols, rows = Slice.guess(64, 64)
    t.eq(cols, 1, 'a square image guesses a single cell')
    t.eq(rows, 1, 'on both axes')

    cols, rows = Slice.guess(100, 64)
    t.eq(cols, 1, 'an unguessable width falls back to one column')
    t.eq(rows, 1, 'rather than inventing a fractional grid')

    cols, rows = Slice.guess(0, 0)
    t.eq(cols, 1, 'a zero-size image guesses one cell')

    t.describe('describe() names the grid')
    t.ok(Slice.describe(plan):find('4 cols') ~= nil, 'and says how many columns')
    t.ok(Slice.describe(ragged):find('INEXACT') ~= nil, 'and flags an inexact grid loudly')
    t.ok(Slice.describe(nil):find('no plan') ~= nil, 'a nil plan describes itself safely')
end
