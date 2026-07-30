--[[
    meatray.asset.history — bounded undo and redo, over diffs.

    The strategy, stated plainly because the alternative is the usual mistake:
    **this stores diffs, not canvases, and it is bounded twice.**

    An undo stack that snapshots the whole canvas per edit is the version everyone
    writes first. On a 32x32 doodle it is fine. On a 256x256 eight-bucket sheet it
    is 65,536 pixels per step, so fifty steps is three million entries held live,
    and the painter's memory use grows with how long you have been drawing rather
    than with what you drew. Diffs invert that: a stroke costs the pixels it
    touched, which for freehand is a few hundred, and the worst case — a flood fill
    over the whole sheet — costs exactly what a snapshot would have cost anyway. So
    diffs are never worse and are usually smaller by three orders of magnitude.

    Two bounds, because a step count alone is not a memory bound:

        maxSteps    how many operations you can walk back
        maxPixels   how many recorded pixel changes may be held in total

    `maxSteps` is what a person thinks in. `maxPixels` is what actually caps
    memory, and it is the one that matters when the steps are large: sixty-four
    whole-sheet fills would be sixty-four snapshots by another name.

    One deliberate exception. If a single step is on its own larger than
    `maxPixels`, it is kept anyway rather than dropped. An undo button that
    silently declines to undo the last thing you did is worse than a bound that
    stretches for one step — a bound is a memory policy, and "the last action is
    always undoable" is a correctness promise.

    HEADLESS: no love.* anywhere in this file.
]]

local History = {}
local HistoryMT = {}
HistoryMT.__index = HistoryMT

function History.new(opts)
    opts = opts or {}
    return setmetatable({
        undoStack = {},
        redoStack = {},
        maxSteps = opts.maxSteps or 64,
        maxPixels = opts.maxPixels or 250000,
        pixels = 0,          -- recorded pixel changes held across both stacks
        dropped = 0,         -- steps evicted by the bound, ever
    }, HistoryMT)
end

local function sizeOf(diff)
    return diff and diff.n or 0
end

-- Discards the oldest undo steps until both bounds hold. Never empties the stack:
-- see the note above about the last action always being undoable.
function HistoryMT:trim()
    while #self.undoStack > self.maxSteps do
        local oldest = table.remove(self.undoStack, 1)
        self.pixels = self.pixels - sizeOf(oldest)
        self.dropped = self.dropped + 1
    end

    while self.pixels > self.maxPixels and #self.undoStack > 1 do
        local oldest = table.remove(self.undoStack, 1)
        self.pixels = self.pixels - sizeOf(oldest)
        self.dropped = self.dropped + 1
    end
end

-- Records a completed edit. An empty diff is ignored rather than pushed: a click
-- that changed nothing must not consume an undo step, or undo starts doing
-- nothing visible and reads as broken.
--
-- Recording clears the redo stack, which is the standard linear-history rule.
function HistoryMT:push(diff)
    if not diff or diff.n == 0 then return false end

    for i = 1, #self.redoStack do
        self.pixels = self.pixels - sizeOf(self.redoStack[i])
        self.redoStack[i] = nil
    end

    self.undoStack[#self.undoStack + 1] = diff
    self.pixels = self.pixels + sizeOf(diff)
    self:trim()
    return true
end

function HistoryMT:canUndo() return #self.undoStack > 0 end
function HistoryMT:canRedo() return #self.redoStack > 0 end

-- Hands back the diff to be *reversed*. Applying it is the caller's job
-- (Sheet.applyDiff(sheet, diff, true)), which keeps this module free of any
-- knowledge of what a pixel is and therefore trivially testable.
function HistoryMT:undo()
    local diff = table.remove(self.undoStack)
    if not diff then return nil end
    self.redoStack[#self.redoStack + 1] = diff
    return diff
end

-- Hands back the diff to be *applied* forwards.
function HistoryMT:redo()
    local diff = table.remove(self.redoStack)
    if not diff then return nil end
    self.undoStack[#self.undoStack + 1] = diff
    return diff
end

function HistoryMT:clear()
    self.undoStack = {}
    self.redoStack = {}
    self.pixels = 0
end

function HistoryMT:depth()
    return #self.undoStack, #self.redoStack
end

-- One line for a status bar: how far back you can go, and how close the bound is.
function HistoryMT:describe()
    return ('undo %d/%d  redo %d  %d px held')
        :format(#self.undoStack, self.maxSteps, #self.redoStack, self.pixels)
end

return History
