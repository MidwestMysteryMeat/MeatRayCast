--[[
    UI rectangle maths.

    These are the calculations behind clipping, hit testing and docking. Each one
    has a characteristic bug that is obvious as an assertion and maddening as a
    visual symptom: a hit test that ignores the scroll offset selects the row you
    saw before scrolling; an intersection that returns negative dimensions clips
    inside-out and draws over its own header; a split that does not clamp hands a
    panel a negative width.
]]

return function(t)
    local Rect = require('meatray.ui.rect')

    t.describe('intersection')
    local a = Rect.new(0, 0, 100, 100)
    local b = Rect.new(50, 50, 100, 100)
    local i = Rect.intersect(a, b)
    t.eq(i.x, 50, 'overlap x')
    t.eq(i.y, 50, 'overlap y')
    t.eq(i.w, 50, 'overlap width')
    t.eq(i.h, 50, 'overlap height')

    -- Disjoint rects must produce an empty rect, never negative dimensions: a
    -- scissor with a negative width is undefined and clips the wrong thing.
    local far = Rect.intersect(Rect.new(0, 0, 10, 10), Rect.new(500, 500, 10, 10))
    t.eq(far.w, 0, 'disjoint width is zero, not negative')
    t.eq(far.h, 0, 'disjoint height is zero, not negative')
    t.ok(Rect.isEmpty(far), 'and it reports empty')

    -- Intersecting a chain must keep narrowing, which is what nesting a panel in
    -- a scroll region in a dock actually does.
    local chained = Rect.intersect(Rect.intersect(a, b), Rect.new(60, 60, 200, 200))
    t.eq(chained.x, 60, 'chained intersection narrows')
    t.eq(chained.w, 40, 'and shrinks to the innermost bound')

    local contained = Rect.intersect(Rect.new(0, 0, 100, 100), Rect.new(20, 20, 10, 10))
    t.eq(contained.w, 10, 'a fully contained rect is unchanged')

    t.describe('containment is half-open')
    local r = Rect.new(10, 10, 20, 20)
    t.ok(Rect.contains(r, 10, 10), 'the top-left corner is inside')
    t.ok(Rect.contains(r, 29, 29), 'the last pixel is inside')
    t.ok(not Rect.contains(r, 30, 20), 'the right edge is outside')
    t.ok(not Rect.contains(r, 20, 30), 'the bottom edge is outside')
    t.ok(not Rect.contains(r, 9, 20), 'left of the rect is outside')

    -- Half-open matters: adjacent rects sharing an edge must not both claim the
    -- same pixel, or two neighbouring buttons both light up.
    local left = Rect.new(0, 0, 10, 10)
    local right = Rect.new(10, 0, 10, 10)
    t.ok(Rect.contains(right, 10, 5) and not Rect.contains(left, 10, 5),
         'adjacent rects do not both own the shared edge')

    t.describe('inset')
    local inset = Rect.inset(Rect.new(0, 0, 100, 50), 10)
    t.eq(inset.x, 10, 'inset moves the origin')
    t.eq(inset.w, 80, 'and shrinks by twice the padding')
    t.eq(inset.h, 30, 'on both axes')

    local overInset = Rect.inset(Rect.new(0, 0, 10, 10), 20)
    t.eq(overInset.w, 0, 'over-inset clamps to zero rather than going negative')
    t.eq(overInset.h, 0, 'on both axes')

    local asym = Rect.inset(Rect.new(0, 0, 100, 100), 5, 20)
    t.eq(asym.w, 90, 'asymmetric inset x')
    t.eq(asym.h, 60, 'asymmetric inset y')

    t.describe('splitting, which is what docking does')
    local full = Rect.new(0, 0, 200, 100)

    local leftPane, rest = Rect.split(full, 'left', 60)
    t.eq(leftPane.w, 60, 'left split takes the pixels asked for')
    t.eq(rest.x, 60, 'and the remainder starts after it')
    t.eq(rest.w, 140, 'with the rest of the width')
    t.eq(leftPane.h, 100, 'height is untouched')

    local rightPane, rest2 = Rect.split(full, 'right', 50)
    t.eq(rightPane.x, 150, 'right split sits at the far edge')
    t.eq(rest2.x, 0, 'and the remainder keeps the origin')

    local topPane, rest3 = Rect.split(full, 'top', 25)
    t.eq(topPane.h, 25, 'top split height')
    t.eq(rest3.y, 25, 'remainder starts below it')

    local bottomPane, rest4 = Rect.split(full, 'bottom', 25)
    t.eq(bottomPane.y, 75, 'bottom split sits at the bottom')
    t.eq(rest4.h, 75, 'remainder keeps the top')

    -- Fractions, so a layout can be proportional without the caller doing maths.
    local half = Rect.split(full, 'left', 0.5)
    t.eq(half.w, 100, 'a fraction splits proportionally')

    -- Asking for more than exists must clamp, not produce a negative remainder.
    local huge, none = Rect.split(full, 'left', 9999)
    t.eq(huge.w, 200, 'an over-large split takes everything')
    t.eq(none.w, 0, 'and leaves nothing, not a negative width')

    t.describe('row hit testing accounts for scrolling')
    local list = Rect.new(0, 100, 200, 80)

    t.eq(Rect.rowAt(list, 100, 20, 0, 10), 1, 'the first row at the top')
    t.eq(Rect.rowAt(list, 119, 20, 0, 10), 1, 'still the first row at its last pixel')
    t.eq(Rect.rowAt(list, 120, 20, 0, 10), 2, 'the second row starts on the boundary')

    -- The bug this exists to prevent: with the list scrolled by two rows, a click
    -- at the top must select row 3, not row 1.
    t.eq(Rect.rowAt(list, 100, 20, 40, 10), 3, 'scrolling shifts which row is hit')
    t.eq(Rect.rowAt(list, 139, 20, 40, 10), 4, 'and keeps shifting down the list')

    t.eq(Rect.rowAt(list, 99, 20, 0, 10), nil, 'above the list hits nothing')
    t.eq(Rect.rowAt(list, 180, 20, 0, 10), nil, 'below the list hits nothing')
    t.eq(Rect.rowAt(list, 100, 20, 0, 2), 1, 'a short list still resolves its rows')
    t.eq(Rect.rowAt(list, 160, 20, 0, 2), nil, 'past the last row hits nothing')
    t.eq(Rect.rowAt(list, 100, 0, 0, 10), nil, 'a zero row height cannot divide')

    t.describe('scroll clamping')
    local off, maxOff = Rect.clampScroll(50, 100, 300)
    t.eq(off, 50, 'an in-range offset is kept')
    t.eq(maxOff, 200, 'the maximum is content minus viewport')

    t.eq((Rect.clampScroll(500, 100, 300)), 200, 'past the end clamps to the maximum')
    t.eq((Rect.clampScroll(-50, 100, 300)), 0, 'before the start clamps to zero')

    -- Content shorter than its viewport must pin to zero. Allowing a negative or
    -- positive offset here drifts content away from its own container.
    local shortOff, shortMax = Rect.clampScroll(30, 200, 50)
    t.eq(shortOff, 0, 'content shorter than the viewport pins to the top')
    t.eq(shortMax, 0, 'with no scrollable range')

    t.describe('grid layout')
    local at, height, perRow = Rect.grid(200, 48, 48, 4, 10)
    t.eq(perRow, 3, 'three 48px cells with 4px gaps fit in 200px')

    local x1, y1 = at(1)
    t.eq(x1, 0, 'the first cell is at the origin')
    t.eq(y1, 0, 'on both axes')

    local x2 = at(2)
    t.eq(x2, 52, 'the second cell is one cell plus a gap along')

    local x4, y4 = at(4)
    t.eq(x4, 0, 'the fourth cell wraps to the next row')
    t.eq(y4, 52, 'one row down')

    t.ok(height >= 4 * 48, ('total height covers 4 rows (%d)'):format(height))

    -- A grid narrower than one cell must still place one per row rather than
    -- dividing by zero or looping forever.
    local _, _, narrow = Rect.grid(10, 48, 48, 4, 5)
    t.eq(narrow, 1, 'a too-narrow grid still fits one per row')
end
