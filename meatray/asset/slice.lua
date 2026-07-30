--[[
    meatray.asset.slice — grid-slicing arithmetic for imported images.

    A sprite sheet in this engine is rows of angle buckets by columns of animation
    frames, which is exactly what meatray.render.sprites already expects. Cutting
    one up is two divisions, and getting either of them wrong produces the same
    symptom every time: sprites drawn half-off, showing the bottom of one frame and
    the top of the next. That symptom is nearly impossible to read backwards into
    "the sheet is 100 pixels wide and you told me it had 3 frames", so the
    arithmetic lives here, in one place, and says so out loud.

    Refusing an inexact grid is deliberate. A sheet whose dimensions do not divide
    evenly by its declared counts is a misconfiguration, not a rounding problem;
    importing it anyway means rendering garbage and blaming the artist.

    HEADLESS: no love.* anywhere in this file. It works on numbers, never on an
    Image — which is what lets every case below be asserted without a GPU.
]]

local Slice = {}

local floor = math.floor

-- A ceiling on declared counts. Not a real limit on art, a guard against a typo:
-- `frames = 10000` on a 64-pixel sheet asks for 10,000 quads of zero width, and
-- the honest answer is "that is not a grid" rather than an out-of-memory later.
Slice.MAX_DIVISIONS = 512

local function isCount(n)
    return type(n) == 'number' and n == floor(n) and n >= 1 and n <= Slice.MAX_DIVISIONS
end

---------------------------------------------------------------------------
-- Planning
---------------------------------------------------------------------------

-- Works out how an image of `imageW` x `imageH` divides into a grid.
--
--   Slice.plan(192, 384, { angles = 8, frames = 4 })
--
-- `angles` and `frames` are the sprite-sheet spelling (rows, columns); `rows` and
-- `cols` are the generic one. Both are accepted, and `rows`/`cols` win if given.
--
-- Always returns a plan — never raises, never returns nil. `plan.ok` says whether
-- the grid is exact, and `plan.problems` says why not, one readable line per
-- reason. A caller that ignores `ok` gets a usable-but-wrong cell size rather than
-- a crash; a caller that checks it can refuse the import and print the reason.
function Slice.plan(imageW, imageH, opts)
    opts = opts or {}

    local cols = opts.cols or opts.frames or 1
    local rows = opts.rows or opts.angles or 1

    local problems = {}

    if not isCount(cols) then
        problems[#problems + 1] = ('columns/frames must be a whole number from 1 to %d, got %s')
            :format(Slice.MAX_DIVISIONS, tostring(cols))
        cols = 1
    end
    if not isCount(rows) then
        problems[#problems + 1] = ('rows/angles must be a whole number from 1 to %d, got %s')
            :format(Slice.MAX_DIVISIONS, tostring(rows))
        rows = 1
    end

    local w = (type(imageW) == 'number' and imageW >= 1) and floor(imageW) or 0
    local h = (type(imageH) == 'number' and imageH >= 1) and floor(imageH) or 0

    if w < 1 or h < 1 then
        problems[#problems + 1] = ('image has no usable size (%sx%s)')
            :format(tostring(imageW), tostring(imageH))
    end

    -- The remainder is the number that makes the misconfiguration obvious, so it
    -- goes in the message. "leaves 1 pixel over" is actionable; "does not divide
    -- evenly" is not.
    local remW = w % cols
    local remH = h % rows

    if w >= 1 and remW ~= 0 then
        problems[#problems + 1] = ('width %d does not divide into %d column%s: %.2f px each, %d px left over')
            :format(w, cols, cols == 1 and '' or 's', w / cols, remW)
    end
    if h >= 1 and remH ~= 0 then
        problems[#problems + 1] = ('height %d does not divide into %d row%s: %.2f px each, %d px left over')
            :format(h, rows, rows == 1 and '' or 's', h / rows, remH)
    end

    local cellW = floor(w / cols)
    local cellH = floor(h / rows)

    if w >= 1 and h >= 1 and (cellW < 1 or cellH < 1) then
        problems[#problems + 1] = ('a %dx%d grid on a %dx%d image gives cells smaller than a pixel')
            :format(cols, rows, w, h)
    end

    return {
        imageW = w, imageH = h,
        cols = cols, rows = rows,
        cellW = cellW, cellH = cellH,
        count = cols * rows,
        remainderW = remW, remainderH = remH,
        exact = (remW == 0 and remH == 0),
        ok = (#problems == 0),
        problems = problems,
    }
end

-- Convenience for the sprite-sheet case, where the names carry meaning.
function Slice.forSheet(imageW, imageH, angles, frames)
    return Slice.plan(imageW, imageH, { rows = angles or 1, cols = frames or 1 })
end

-- True when the grid divides exactly. The cheap check, for callers that do not
-- want the reasons.
function Slice.fits(imageW, imageH, cols, rows)
    return Slice.plan(imageW, imageH, { cols = cols, rows = rows }).ok
end

---------------------------------------------------------------------------
-- Cells
---------------------------------------------------------------------------

-- The pixel rect of one cell. `col` and `row` are ZERO-based, matching the
-- bucket/frame indices meatray.render.sprites uses for its quads — one indexing
-- convention across the two files that must agree, rather than an off-by-one
-- waiting at the boundary between them.
--
-- Returns nil for a cell outside the grid, so a caller asking for bucket 8 of 8
-- finds out here instead of drawing a quad past the edge of the image.
function Slice.cell(plan, col, row)
    if not plan then return nil end
    if col < 0 or row < 0 or col >= plan.cols or row >= plan.rows then return nil end
    return col * plan.cellW, row * plan.cellH, plan.cellW, plan.cellH
end

-- Row-major traversal: cell 1 is (0,0), cell `cols` is the end of the first row.
-- Returns zero-based col, row.
function Slice.index(plan, i)
    if not plan or i < 1 or i > plan.count then return nil end
    local zero = i - 1
    return zero % plan.cols, floor(zero / plan.cols)
end

-- All cells in row-major order, as { x, y, w, h, col, row } records. Used by the
-- asset browser to lay out a sheet, and by tests to check the whole grid at once.
function Slice.cells(plan)
    local out = {}
    if not plan then return out end
    for i = 1, plan.count do
        local col, row = Slice.index(plan, i)
        local x, y, w, h = Slice.cell(plan, col, row)
        out[i] = { x = x, y = y, w = w, h = h, col = col, row = row }
    end
    return out
end

---------------------------------------------------------------------------
-- Guessing
---------------------------------------------------------------------------

-- A first guess at the grid of an unknown sheet, assuming square cells sized by
-- the shorter edge. Only ever a suggestion for the import UI to prefill — it is
-- right often enough to save typing and wrong often enough that nothing should
-- import on its strength alone, which is why it is separate from plan().
function Slice.guess(imageW, imageH)
    local w = (type(imageW) == 'number' and imageW >= 1) and floor(imageW) or 0
    local h = (type(imageH) == 'number' and imageH >= 1) and floor(imageH) or 0
    if w < 1 or h < 1 then return 1, 1 end

    local cell = math.min(w, h)
    local cols = (w % cell == 0) and (w / cell) or 1
    local rows = (h % cell == 0) and (h / cell) or 1
    return cols, rows
end

-- One line naming the grid, for a console message or a panel label.
function Slice.describe(plan)
    if not plan then return '(no plan)' end
    return ('%dx%d sheet, %d cols x %d rows, %dx%d cells%s')
        :format(plan.imageW, plan.imageH, plan.cols, plan.rows,
                plan.cellW, plan.cellH, plan.ok and '' or ' (INEXACT)')
end

return Slice
