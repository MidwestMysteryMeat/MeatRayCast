--[[
    meatray.ui.rect — rectangle maths for the UI layer.

    Separate from ui/core.lua and free of any LÖVE dependency, so the arithmetic
    that decides what is clipped, what is hit, and where a row lands can be
    unit-tested without a window. That split matters more here than it looks: a
    clipping bug shows up as "a button I can't see still responds to clicks", or
    "the scrolled content draws over its own header", and both are far easier to
    catch in an assertion than by staring at a frame.

    HEADLESS: no love.* anywhere in this file.
]]

local Rect = {}

local floor, max, min = math.floor, math.max, math.min

function Rect.new(x, y, w, h)
    return { x = x, y = y, w = w, h = h }
end

-- The overlap of two rects. Returns a zero-size rect rather than nil when they
-- do not overlap, so callers can intersect a chain without nil checks at each
-- step — a fully clipped-away widget is simply one with no area.
function Rect.intersect(a, b)
    local x1 = max(a.x, b.x)
    local y1 = max(a.y, b.y)
    local x2 = min(a.x + a.w, b.x + b.w)
    local y2 = min(a.y + a.h, b.y + b.h)
    return { x = x1, y = y1, w = max(0, x2 - x1), h = max(0, y2 - y1) }
end

function Rect.contains(r, px, py)
    return px >= r.x and px < r.x + r.w
       and py >= r.y and py < r.y + r.h
end

function Rect.isEmpty(r)
    return r.w <= 0 or r.h <= 0
end

function Rect.overlaps(a, b)
    return not Rect.isEmpty(Rect.intersect(a, b))
end

-- Shrinks by a padding on every side, clamped so an over-large padding produces
-- an empty rect rather than an inside-out one with negative dimensions.
function Rect.inset(r, pad, padY)
    local px = pad
    local py = padY or pad
    return {
        x = r.x + px,
        y = r.y + py,
        w = max(0, r.w - px * 2),
        h = max(0, r.h - py * 2),
    }
end

-- Splits a rect into two along an edge. `amount` above 1 is pixels; 0..1 is a
-- fraction. Returns the taken piece and the remainder, which is what a docking
-- layout does at every step.
function Rect.split(r, side, amount)
    local take = amount
    if amount > 0 and amount <= 1 then
        take = (side == 'left' or side == 'right') and r.w * amount or r.h * amount
    end
    take = floor(max(0, min(take, (side == 'left' or side == 'right') and r.w or r.h)))

    if side == 'left' then
        return { x = r.x, y = r.y, w = take, h = r.h },
               { x = r.x + take, y = r.y, w = r.w - take, h = r.h }
    elseif side == 'right' then
        return { x = r.x + r.w - take, y = r.y, w = take, h = r.h },
               { x = r.x, y = r.y, w = r.w - take, h = r.h }
    elseif side == 'top' then
        return { x = r.x, y = r.y, w = r.w, h = take },
               { x = r.x, y = r.y + take, w = r.w, h = r.h - take }
    else -- bottom
        return { x = r.x, y = r.y + r.h - take, w = r.w, h = take },
               { x = r.x, y = r.y, w = r.w, h = r.h - take }
    end
end

-- Which row index a point falls on inside a scrolled list, or nil if outside.
-- The scroll offset is part of the calculation on purpose: doing it at the call
-- site is how a list ends up selecting the row you saw before scrolling.
function Rect.rowAt(r, py, rowHeight, scrollOffset, rowCount)
    if rowHeight <= 0 then return nil end
    if py < r.y or py >= r.y + r.h then return nil end

    local index = floor((py - r.y + (scrollOffset or 0)) / rowHeight) + 1
    if index < 1 then return nil end
    if rowCount and index > rowCount then return nil end
    return index
end

-- Clamps a scroll offset to the range that can actually be shown. Content
-- shorter than its viewport pins to zero rather than allowing a negative offset,
-- which would drift the content away from its own container.
function Rect.clampScroll(offset, viewportHeight, contentHeight)
    local maxOffset = max(0, (contentHeight or 0) - (viewportHeight or 0))
    return max(0, min(maxOffset, offset or 0)), maxOffset
end

-- Lays out `count` cells of `cellW` x `cellH` in a grid `width` wide. Returns a
-- function giving the position of index i, plus the total height, so a thumbnail
-- grid can be measured before it is drawn.
function Rect.grid(width, cellW, cellH, gap, count)
    gap = gap or 0
    local perRow = max(1, floor((width + gap) / (cellW + gap)))
    local rows = math.ceil(count / perRow)

    return function(i)
        local col = (i - 1) % perRow
        local row = floor((i - 1) / perRow)
        return col * (cellW + gap), row * (cellH + gap)
    end, rows * cellH + max(0, rows - 1) * gap, perRow
end

return Rect
