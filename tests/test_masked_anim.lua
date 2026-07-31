--[[
    Masked walls and animated wall texture cycles.
]]

return function(t)
    local Worldgen = require('meatray.sim.worldgen')

    local w = Worldgen.box(10, 10)
    w.grid[5][5] = 1

    ---------------------------------------------------------------------
    t.describe('masked walls stay solid but are flagged')

    t.eq(w:setMasked(5, 5, true), true, 'set masked')
    t.eq(w:isMasked(5, 5), true, 'is masked')
    t.near(w:maskAlpha(5, 5), 0.55, 0.01, 'default alpha')
    t.eq(w:isSolid(5, 5), true, 'still solid for collision')

    t.eq(w:setMasked(5, 5, 0.3), true, 'numeric alpha')
    t.near(w:maskAlpha(5, 5), 0.3, 0.01, 'custom alpha')
    t.eq(w:setMasked(5, 5, false), true, 'clear')
    t.eq(w:isMasked(5, 5), false, 'cleared')

    ---------------------------------------------------------------------
    t.describe('wall anim cycles display tile')

    w.grid[4][4] = 1
    t.eq(w:setWallAnim(4, 4, { 1, 2, 3 }, 10), true, 'anim set')
    t.eq(w:displayTileAt(4, 4), 1, 'starts on first frame')
    w:update(0.15) -- 10 fps → frame every 0.1s
    t.eq(w:displayTileAt(4, 4), 2, 'advances')
    w:update(0.1)
    t.eq(w:displayTileAt(4, 4), 3, 'third frame')
    w:update(0.1)
    t.eq(w:displayTileAt(4, 4), 1, 'wraps')

    t.eq(w:setWallAnim(4, 4, nil), true, 'clear anim')
    t.eq(w:displayTileAt(4, 4), 1, 'falls back to grid tile')
end
