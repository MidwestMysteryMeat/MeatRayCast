--[[
    meatray.asset.history — bounded undo and redo.

    The bound is the part worth asserting hardest. An undo stack with no ceiling is
    a slow memory leak that only shows up after a long session, and a ceiling
    enforced only on step count is not a memory bound at all when the steps are
    whole-sheet fills. Both limits are checked here, along with the one deliberate
    exception: a single step larger than the whole budget is kept anyway, because
    "undo does nothing" is a worse failure than "the bound stretched once".

    History stores diffs and hands them back; applying them is meatray.asset.sheet's
    job. The last group here drives both together, since the property that actually
    matters is that undo followed by redo returns the pixels to where they were.
]]

local History = require('meatray.asset.history')
local Sheet = require('meatray.asset.sheet')

-- A diff of `n` pixels, with contents nobody here inspects.
local function fakeDiff(n, label)
    local d = Sheet.diff(label)
    for i = 1, n do
        d.n = i
        d.idx[i] = i
        d.before[i] = 0
        d.after[i] = 1
    end
    return d
end

return function(t)
    ---------------------------------------------------------------------
    t.describe('pushing and walking back')

    local h = History.new{}
    t.ok(not h:canUndo(), 'a new history has nothing to undo')
    t.ok(not h:canRedo(), 'and nothing to redo')
    t.eq(h.pixels, 0, 'and holds no pixels')

    local first = fakeDiff(3, 'first')
    t.ok(h:push(first), 'a non-empty edit is recorded')
    t.ok(h:canUndo(), 'and can be undone')
    t.eq(h.pixels, 3, 'with its size counted against the bound')

    local undone = h:undo()
    t.eq(undone, first, 'undo hands back the diff to reverse')
    t.ok(not h:canUndo(), 'leaving nothing further back')
    t.ok(h:canRedo(), 'and something to redo')

    local redone = h:redo()
    t.eq(redone, first, 'redo hands back the same diff to replay')
    t.ok(h:canUndo(), 'and it is on the undo stack again')
    t.ok(not h:canRedo(), 'with the redo stack emptied')

    t.ok(h:undo() ~= nil, 'undo works after redo')
    t.ok(h:undo() == nil, 'and undoing past the beginning returns nil rather than erroring')
    t.ok(h:redo() ~= nil, 'redo works after that')
    t.ok(h:redo() == nil, 'and redoing past the end returns nil too')

    ---------------------------------------------------------------------
    t.describe('what is not worth an undo step')

    local e = History.new{}
    t.ok(not e:push(Sheet.diff('nothing')),
         'an edit that changed no pixels is not recorded')
    t.ok(not e:canUndo(), 'so a click that did nothing does not consume an undo')
    t.ok(not e:push(nil), 'and neither does a missing diff')
    t.eq(e.pixels, 0, 'with nothing counted against the bound')

    ---------------------------------------------------------------------
    t.describe('a new edit clears the redo branch')

    local branch = History.new{}
    branch:push(fakeDiff(4, 'a'))
    branch:push(fakeDiff(4, 'b'))
    branch:undo()
    t.ok(branch:canRedo(), 'undoing leaves a redo available')
    t.eq(branch.pixels, 8, 'and both steps still counted')

    branch:push(fakeDiff(2, 'c'))
    t.ok(not branch:canRedo(), 'a new edit discards the redo branch')
    t.eq(branch.pixels, 6, 'and stops counting what it discarded')

    local depthUndo, depthRedo = branch:depth()
    t.eq(depthUndo, 2, 'leaving the two steps that are still reachable')
    t.eq(depthRedo, 0, 'and no forward branch')

    ---------------------------------------------------------------------
    t.describe('the step bound')

    local stepped = History.new{ maxSteps = 4, maxPixels = 1e9 }
    for i = 1, 10 do stepped:push(fakeDiff(1, 'step' .. i)) end

    local depth = stepped:depth()
    t.eq(depth, 4, 'the stack never grows past maxSteps')
    t.eq(stepped.dropped, 6, 'and says how many steps it dropped')
    t.eq(stepped.pixels, 4, 'with the dropped pixels no longer counted')

    -- The oldest go first, so the most recent work stays undoable.
    local kept = {}
    while stepped:canUndo() do
        local d = stepped:undo()
        kept[#kept + 1] = d.label
    end
    t.eq(kept[1], 'step10', 'the newest step is the first one back')
    t.eq(kept[4], 'step7', 'and the oldest survivor is the fourth')

    ---------------------------------------------------------------------
    t.describe('the pixel bound')

    -- The bound that actually caps memory. Sixty-four steps of a whole-sheet fill
    -- would be sixty-four canvas snapshots under another name, which is the exact
    -- thing storing diffs was supposed to avoid.
    local sized = History.new{ maxSteps = 1000, maxPixels = 1000 }
    for _ = 1, 10 do sized:push(fakeDiff(300, 'big')) end

    t.ok(sized.pixels <= 1000, 'the held pixel count stays inside maxPixels')
    t.eq(sized:depth(), 3, 'which here means three steps of three hundred pixels')
    t.ok(sized.dropped > 0, 'the rest were evicted')

    -- The exception, and it is deliberate: one step larger than the whole budget
    -- is still kept. An undo button that declines to undo the thing you just did
    -- is worse than a bound that stretches for a single step.
    local huge = History.new{ maxSteps = 100, maxPixels = 500 }
    huge:push(fakeDiff(5000, 'flood'))
    t.eq(huge:depth(), 1, 'a single step over the whole budget is kept')
    t.ok(huge:canUndo(), 'so the last action is always undoable')
    t.eq(huge.pixels, 5000, 'and the history admits how much it is holding')

    huge:push(fakeDiff(10, 'after'))
    t.eq(huge:depth(), 1, 'and the next edit evicts it rather than accumulating')
    t.eq(huge.pixels, 10, 'bringing the held count back under the bound')

    ---------------------------------------------------------------------
    t.describe('clearing')

    local c = History.new{}
    c:push(fakeDiff(5, 'x'))
    c:undo()
    c:clear()
    t.ok(not c:canUndo(), 'clearing drops the undo stack')
    t.ok(not c:canRedo(), 'and the redo stack')
    t.eq(c.pixels, 0, 'and the pixel count with them')
    t.ok(type(c:describe()) == 'string', 'and the summary line still renders')

    ---------------------------------------------------------------------
    t.describe('undo and redo against real pixels')

    -- The property that matters: after undo the sheet is byte-identical to what it
    -- was before the edit, and after redo it is byte-identical to what it was
    -- after. Anything less and the undo stack is decoration.
    local sheet = Sheet.new{ angles = 4, frames = 2, cellW = 8, cellH = 8 }
    local history = History.new{ maxSteps = 8, maxPixels = 100000 }

    local blank = Sheet.toBytes(sheet)

    local strokeDiff = Sheet.diff('stroke')
    Sheet.line(sheet, 0, 0, 15, 31, 4, 2, strokeDiff)
    history:push(strokeDiff)
    local afterStroke = Sheet.toBytes(sheet)
    t.ok(not Sheet.sameBytes(afterStroke, blank), 'the stroke changed the sheet')

    local fillDiff = Sheet.diff('fill')
    local cell = Sheet.cellBounds(sheet, 2, 1)
    Sheet.fill(sheet, cell.x, cell.y, 9, fillDiff, cell)
    history:push(fillDiff)
    local afterFill = Sheet.toBytes(sheet)

    Sheet.applyDiff(sheet, history:undo(), true)
    local backOne, detailOne = Sheet.sameBytes(Sheet.toBytes(sheet), afterStroke)
    t.ok(backOne, 'undoing the fill restores the sheet exactly', detailOne)

    Sheet.applyDiff(sheet, history:undo(), true)
    local backTwo, detailTwo = Sheet.sameBytes(Sheet.toBytes(sheet), blank)
    t.ok(backTwo, 'undoing the stroke restores the blank sheet exactly', detailTwo)

    Sheet.applyDiff(sheet, history:redo(), false)
    Sheet.applyDiff(sheet, history:redo(), false)
    local forward, detailThree = Sheet.sameBytes(Sheet.toBytes(sheet), afterFill)
    t.ok(forward, 'and redoing both replays them exactly', detailThree)

    -- Walking the whole stack back and forth, which is where an off-by-one in the
    -- stack handling shows up and a single undo/redo pair does not.
    local walk = Sheet.new{ angles = 2, frames = 2, cellW = 6, cellH = 6 }
    local walkHistory = History.new{ maxSteps = 32, maxPixels = 100000 }
    local snapshots = { Sheet.toBytes(walk) }

    for step = 1, 12 do
        local d = Sheet.diff('step')
        Sheet.stamp(walk, step % 12, (step * 3) % 12, (step % 15) + 1, 2, d)
        walkHistory:push(d)
        snapshots[#snapshots + 1] = Sheet.toBytes(walk)
    end

    local rewindOk = true
    for step = 12, 1, -1 do
        Sheet.applyDiff(walk, walkHistory:undo(), true)
        if not Sheet.sameBytes(Sheet.toBytes(walk), snapshots[step]) then
            rewindOk = false
        end
    end
    t.ok(rewindOk, 'every step of a twelve-deep rewind lands on the right pixels')

    local replayOk = true
    for step = 1, 12 do
        Sheet.applyDiff(walk, walkHistory:redo(), false)
        if not Sheet.sameBytes(Sheet.toBytes(walk), snapshots[step + 1]) then
            replayOk = false
        end
    end
    t.ok(replayOk, 'and every step of the replay forwards does too')
end
