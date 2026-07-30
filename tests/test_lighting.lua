--[[
    Lighting: falloff, colour accumulation, the readability floor, shadowing, and
    the dirty-region bookkeeping that keeps the per-frame cost off the world size.

    All of it runs under plain LuaJIT with no LÖVE, which is the whole reason the
    maths lives in a module of its own rather than inline in the wall loop. Two of
    the assertions below exist to keep that true: the module must load with no
    `love` global at all, and its source must not name a love drawing API. That is
    the same pair of checks tests/test_headless.lua makes of meatray/sim — applied
    here voluntarily, because meatray/render is otherwise allowed a GPU and
    nothing else would stop this file quietly acquiring one.

    The performance claims are asserted, not asserted-about. `report()` counts
    cells baked and line-of-sight tests run, so "a clean grid does no work" and
    "a door only relights the lights that could see it" are numbers this suite can
    check rather than comments hoping to stay true.
]]

return function(t)
    local World = require('meatray.sim.world')
    local Lighting = require('meatray.render.lighting')

    ---------------------------------------------------------------------
    -- Worlds
    ---------------------------------------------------------------------

    -- An open room with a solid border: size x size, everything inside walkable.
    local function openRoom(size)
        size = size or 12
        local grid = {}
        for y = 1, size do
            grid[y] = {}
            for x = 1, size do
                local border = (x == 1 or y == 1 or x == size or y == size)
                grid[y][x] = border and 1 or 0
            end
        end
        return World.new(grid)
    end

    -- Two rooms of equal width divided by a full-height wall down the middle,
    -- with an optional door in it. 13 wide so the divider lands on x = 7.
    local function dividedRoom(withDoor)
        local w = openRoom(13)
        for y = 1, 13 do w.grid[y][7] = 1 end
        if withDoor then w:addDoor(7, 6, false) end
        return w
    end

    ---------------------------------------------------------------------
    t.describe('falloff curves')

    for _, curve in ipairs({ 'linear', 'smooth', 'inverse' }) do
        t.near(Lighting.falloff(0, 8, curve), 1, 1e-9, curve .. ' is full at the source')
        t.eq(Lighting.falloff(8, 8, curve), 0, curve .. ' is zero at the radius')
        t.eq(Lighting.falloff(9, 8, curve), 0, curve .. ' is zero beyond the radius')

        -- Monotonically decreasing all the way out. A curve that bulges is a
        -- curve that puts a bright ring around a light.
        local previous = 2
        local monotone = true
        for step = 0, 40 do
            local v = Lighting.falloff(step / 40 * 8, 8, curve)
            if v > previous + 1e-12 then monotone = false end
            if v < 0 or v > 1 then monotone = false end
            previous = v
        end
        t.ok(monotone, curve .. ' falls monotonically and stays in [0,1]')
    end

    t.near(Lighting.falloff(4, 8, 'linear'), 0.5, 1e-9, 'linear is half-way at half the radius')
    t.near(Lighting.falloff(4, 8, 'smooth'), 0.5, 1e-9, 'smoothstep is symmetric about the midpoint')
    t.ok(Lighting.falloff(4, 8, 'inverse') < Lighting.falloff(4, 8, 'linear'),
         'inverse square is darker in the mid-range than linear')
    t.ok(Lighting.falloff(1, 8, 'smooth') > Lighting.falloff(1, 8, 'linear'),
         'smoothstep holds brightness near the source')

    -- A radius that makes no sense must not produce a light that makes no sense.
    t.eq(Lighting.falloff(1, 0), 0, 'a zero radius lights nothing')
    t.eq(Lighting.falloff(1, -3), 0, 'a negative radius lights nothing')
    t.eq(Lighting.falloff(3, 8, 'no_such_curve'), Lighting.falloff(3, 8, 'smooth'),
         'an unknown curve name falls back to the default rather than erroring')

    ---------------------------------------------------------------------
    t.describe('an unlit grid is the identity')

    local plain = Lighting.new{ world = openRoom(12) }
    local pr, pg, pb = plain:sample(5.5, 5.5)
    t.near(pr, 1, 1e-9, 'a grid with no lights samples 1.0 red')
    t.near(pg, 1, 1e-9, 'and 1.0 green')
    t.near(pb, 1, 1e-9, 'and 1.0 blue')
    t.eq(plain:staticCount(), 0, 'with no static lights')
    t.eq(plain:dynamicCount(), 0, 'and no dynamic ones')

    ---------------------------------------------------------------------
    t.describe('the readability floor')

    -- A map that asks for total blackness does not get it.
    local pitch = Lighting.new{ world = openRoom(12), baseLevel = 0 }
    local dr, dg, db = pitch:sample(5.5, 5.5)
    t.near(dr, Lighting.MIN_VISIBILITY, 1e-9, 'baseLevel 0 still samples the floor')
    t.near(dg, Lighting.MIN_VISIBILITY, 1e-9, 'on every channel')
    t.near(db, Lighting.MIN_VISIBILITY, 1e-9, 'including blue')

    local negative = Lighting.new{ world = openRoom(12), baseLevel = -5 }
    t.near(negative:sample(5.5, 5.5), Lighting.MIN_VISIBILITY, 1e-9,
           'and so does a nonsensical negative base')

    t.ok(Lighting.MIN_VISIBILITY > 0.2,
         'the floor is high enough to read a wall texture by')
    t.ok(Lighting.MIN_VISIBILITY < 1,
         'and low enough that darkness still means something')
    t.eq(Lighting.clampLevel(-1), Lighting.MIN_VISIBILITY, 'clampLevel floors')
    t.eq(Lighting.clampLevel(99), Lighting.MAX_LEVEL, 'clampLevel ceilings')
    t.eq(Lighting.clampLevel(0.8), 0.8, 'and leaves a legal value alone')

    -- The floor must survive the full path, not only a direct clamp: an unlit
    -- corner of a real dark map, several tiles from the nearest light, still
    -- reads at the floor.
    local dark = Lighting.new{ world = openRoom(12), baseLevel = 0.05 }
    dark:addStatic{ x = 2.5, y = 2.5, radius = 3, color = { 1, 1, 1 } }
    dark:update()
    local far = dark:brightness(10.5, 10.5)
    t.near(far, Lighting.MIN_VISIBILITY, 1e-9,
           'a corner no light reaches still renders at the floor, not at black')
    t.ok(dark:brightness(2.5, 2.5) > far + 0.2,
         'while the lit tile is visibly brighter than the floor')

    ---------------------------------------------------------------------
    t.describe('the ceiling')

    local blazing = Lighting.new{ world = openRoom(12), baseLevel = 1.0 }
    blazing:addStatic{ x = 5.5, y = 5.5, radius = 5, intensity = 8 }
    blazing:update()
    local br = blazing:sample(5.5, 5.5)
    t.near(br, Lighting.MAX_LEVEL, 1e-9, 'a very bright light clamps at MAX_LEVEL')
    t.ok(Lighting.MAX_LEVEL > 1, 'which is above 1 so a flash can blow out')

    ---------------------------------------------------------------------
    t.describe('coloured light accumulation')

    local tinted = Lighting.new{ world = openRoom(16), baseLevel = 0.4 }
    tinted:addStatic{ x = 4.5, y = 8.5, radius = 6, color = { 1, 0.2, 0.05 } }   -- warm
    tinted:addStatic{ x = 12.5, y = 8.5, radius = 6, color = { 0.05, 0.3, 1 } }  -- cold
    tinted:update()

    local wr, wg, wb = tinted:sample(4.5, 8.5)
    t.ok(wr > wb + 0.4, 'a warm light leaves red well above blue')
    t.ok(wr > wg, 'and red above green')

    local cr, cg, cb = tinted:sample(12.5, 8.5)
    t.ok(cb > cr + 0.4, 'a cold light leaves blue well above red')
    t.ok(cb > cg, 'and blue above green')

    -- Halfway between the two, both contribute and the tint cancels out.
    local mr, mg, mb = tinted:sample(8.5, 8.5)
    t.near(mr, mb, 0.12, 'midway between a warm and a cold light the tint balances')
    t.ok(mr > 0.4 and mb > 0.4, 'and both sources still reach the middle')

    -- Two identical lights on the same tile are brighter than one. Both readings
    -- are kept clear of the floor and the ceiling, so this measures accumulation
    -- rather than a clamp.
    local STACK_BASE = 0.4
    local stacked = Lighting.new{ world = openRoom(12), baseLevel = STACK_BASE }
    stacked:addStatic{ x = 6.5, y = 6.5, radius = 4, intensity = 0.25 }
    stacked:update()
    local oneLight = stacked:brightness(6.5, 6.5)
    stacked:addStatic{ x = 6.5, y = 6.5, radius = 4, intensity = 0.25 }
    stacked:update()
    local twoLights = stacked:brightness(6.5, 6.5)
    t.ok(oneLight > Lighting.MIN_VISIBILITY and twoLights < Lighting.MAX_LEVEL,
         'both readings sit between the floor and the ceiling')
    t.ok(twoLights > oneLight + 0.1, 'a second identical source adds to the first')
    t.near(twoLights - STACK_BASE, (oneLight - STACK_BASE) * 2, 1e-6,
           'and accumulation is linear below the ceiling')

    ---------------------------------------------------------------------
    t.describe('light does not cross a solid tile')

    local split = Lighting.new{ world = dividedRoom(false), baseLevel = 0.1 }
    split:addStatic{ x = 3.5, y = 6.5, radius = 12, intensity = 1.5 }
    split:update()

    local nearSide = split:brightness(5.5, 6.5)
    local farSide = split:brightness(9.5, 6.5)
    t.ok(nearSide > 0.5, 'the light fills its own side of the wall')
    t.near(farSide, Lighting.MIN_VISIBILITY, 1e-9,
           'and does not reach the room on the other side at all')

    -- Distance alone would have lit it: the same point with shadows switched off
    -- is bright, so the darkness above is the wall doing its job and not the
    -- falloff running out.
    local leaky = Lighting.new{ world = dividedRoom(false), baseLevel = 0.1 }
    leaky:addStatic{ x = 3.5, y = 6.5, radius = 12, intensity = 1.5, shadows = false }
    leaky:update()
    t.ok(leaky:brightness(9.5, 6.5) > 0.4,
         'the same light with shadows off does reach, so it was the wall that stopped it')

    -- Interpolation must not leak either. A sample pressed right up against the
    -- divider on the dark side stays dark, even though a lit tile is one step
    -- away across the wall.
    t.near(split:brightness(7.05, 6.5), Lighting.MIN_VISIBILITY, 1e-9,
           'a sample hard against the far face of the wall does not pick up the lit side')

    ---------------------------------------------------------------------
    t.describe('a door changes what the light reaches')

    local doored = Lighting.new{ world = dividedRoom(true), baseLevel = 0.1 }
    doored:addStatic{ x = 5.5, y = 5.5, radius = 8, intensity = 1 }
    doored:update()

    local shutLevel = doored:brightness(8.5, 5.5)
    t.near(shutLevel, Lighting.MIN_VISIBILITY, 1e-9, 'with the door shut, the far room is dark')

    doored.world:setDoorOpen(7, 6, true)
    doored:invalidateTile(7, 6)
    t.ok(doored:isDirty(), 'opening a door marks the grid dirty')
    doored:update()

    local openLevel = doored:brightness(8.5, 5.5)
    t.ok(openLevel > shutLevel + 0.05,
         'and once relit, light spills through the opening')

    doored.world:setDoorOpen(7, 6, false)
    doored:invalidateTile(7, 6)
    doored:update()
    t.near(doored:brightness(8.5, 5.5), shutLevel, 1e-9,
           'shutting it again puts the far room back exactly as it was')

    ---------------------------------------------------------------------
    t.describe('dirty regions: a settled grid does no work')

    local settled = Lighting.new{ world = openRoom(40), baseLevel = 0.3 }
    settled:addStatic{ x = 5.5, y = 5.5, radius = 4 }
    settled:addStatic{ x = 30.5, y = 30.5, radius = 4 }
    settled:update()

    t.ok(settled:report().cellsBakedLastUpdate == 40 * 40,
         'the first bake covers the world once')
    t.ok(not settled:isDirty(), 'and leaves nothing dirty')

    local losBefore = settled:report().losTests
    for _ = 1, 200 do settled:update() end
    t.eq(settled:report().cellsBakedLastUpdate, 0,
         '200 further updates on an unchanged world bake zero cells')
    t.eq(settled:report().losTests, losBefore,
         'and run zero line-of-sight tests')

    -- Sampling a settled grid never triggers a bake either, however many times.
    local bakesBefore = settled:report().bakes
    for i = 1, 500 do settled:sample(3.5 + (i % 20), 3.5 + (i % 20)) end
    t.eq(settled:report().bakes, bakesBefore, '500 samples trigger no rebake')

    ---------------------------------------------------------------------
    t.describe('dirty regions: only what changed is rebaked')

    -- A change in the corner near the first light must not walk the far corner.
    settled.world.grid[8][8] = 1
    settled:invalidateTile(8, 8)
    settled:update()

    local touched = settled:report().cellsBakedLastUpdate
    t.ok(touched > 0, 'invalidating a tile inside a light rebakes something')
    t.ok(touched < 40 * 40 * 0.2,
         ('and rebakes a small fraction of the world, not all of it (%d of %d)')
             :format(touched, 40 * 40))

    -- A change nowhere near any light costs nothing at all.
    settled:update()
    settled.world.grid[20][20] = 1
    settled:invalidateTile(20, 20)
    t.ok(not settled:isDirty(), 'a change no light can see marks nothing dirty')
    settled:update()
    t.eq(settled:report().cellsBakedLastUpdate, 0, 'and rebakes nothing')

    -- The rebaked footprint scales with the light, not with the map. The same
    -- light in a world four times the area dirties the same number of cells.
    local function dirtiedBy(size)
        local g = Lighting.new{ world = openRoom(size), baseLevel = 0.3 }
        g:addStatic{ x = 6.5, y = 6.5, radius = 4 }
        g:update()                       -- full bake
        g:invalidateTile(6, 6)
        g:update()
        return g:report().cellsBakedLastUpdate
    end
    t.eq(dirtiedBy(20), dirtiedBy(40),
         'the rebaked area depends on the light radius, not on the world size')

    ---------------------------------------------------------------------
    t.describe('removing a static light relights its footprint')

    local removable = Lighting.new{ world = openRoom(14), baseLevel = 0.2 }
    local torch = removable:addStatic{ x = 7.5, y = 7.5, radius = 5 }
    removable:update()
    t.ok(removable:brightness(7.5, 7.5) > 0.8, 'the light is there')

    t.ok(removable:removeStatic(torch), 'removing it reports success')
    removable:update()
    t.near(removable:brightness(7.5, 7.5), Lighting.MIN_VISIBILITY, 1e-9,
           'and the tile falls back to the floor')
    t.ok(not removable:removeStatic(torch), 'removing it twice reports failure')

    local byId = Lighting.new{ world = openRoom(14), baseLevel = 0.2 }
    byId:addStatic{ x = 7.5, y = 7.5, radius = 5, id = 'brazier' }
    byId:update()
    t.ok(byId:removeStatic('brazier'), 'a light can be removed by its id')

    ---------------------------------------------------------------------
    t.describe('dynamic lights are never baked')

    local dyn = Lighting.new{ world = openRoom(16), baseLevel = 0.2 }
    dyn:update()
    local cleanBakes = dyn:report().bakes
    local cleanCells = dyn:report().cellsBaked

    dyn:beginFrame()
    dyn:addDynamic{ x = 8.5, y = 8.5, radius = 5, color = { 1, 0.8, 0.4 } }
    local flashR, flashG, flashB = dyn:sample(8.5, 8.5)
    t.ok(flashR > 0.8, 'a dynamic light lights the tile it is on')
    t.ok(flashR > flashB, 'and carries its colour')
    t.eq(dyn:report().bakes, cleanBakes, 'without triggering a bake')
    t.eq(dyn:report().cellsBaked, cleanCells, 'and without writing a single cell')
    t.ok(flashG > flashB and flashG < flashR, 'with the middle channel in between')

    -- The next frame forgets it. This is the difference between a muzzle flash
    -- and a permanent scorch mark.
    dyn:beginFrame()
    t.eq(dyn:dynamicCount(), 0, 'beginFrame clears last frame\'s dynamic lights')
    t.near(dyn:sample(8.5, 8.5), Lighting.MIN_VISIBILITY, 1e-9,
           'and the flash is gone with no rebake needed')

    -- A dynamic light respects walls the same way a static one does.
    local dynWall = Lighting.new{ world = dividedRoom(false), baseLevel = 0.1 }
    dynWall:update()
    dynWall:beginFrame()
    dynWall:addDynamic{ x = 3.5, y = 6.5, radius = 9, intensity = 1 }
    t.ok(dynWall:brightness(5.5, 6.5) > 0.5, 'a carried torch lights its own room')
    t.near(dynWall:brightness(9.5, 6.5), Lighting.MIN_VISIBILITY, 1e-9,
           'and stops at the wall like a baked one')

    -- sampleStatic answers the stable question, ignoring whatever is on fire.
    dynWall:beginFrame()
    dynWall:addDynamic{ x = 5.5, y = 6.5, radius = 5, intensity = 1 }
    t.ok(dynWall:brightness(5.5, 6.5) > 0.5, 'sample sees the dynamic light')
    t.near(dynWall:sampleStatic(5.5, 6.5), Lighting.MIN_VISIBILITY, 1e-9,
           'sampleStatic does not')
    t.eq(dynWall:dynamicCount(), 1, 'and sampleStatic leaves the frame intact')

    ---------------------------------------------------------------------
    t.describe('the dynamic light budget is bounded')

    local crowd = Lighting.new{ world = openRoom(12), baseLevel = 0.2 }
    crowd:beginFrame()
    local accepted = 0
    for i = 1, Lighting.MAX_DYNAMIC + 50 do
        if crowd:addDynamic{ x = 6.5, y = 6.5, radius = 2, intensity = 0.01 } then
            accepted = accepted + 1
        end
    end
    t.eq(accepted, Lighting.MAX_DYNAMIC, 'exactly MAX_DYNAMIC lights are accepted')
    t.eq(crowd:dynamicCount(), Lighting.MAX_DYNAMIC, 'and no more are held')

    ---------------------------------------------------------------------
    t.describe('the per-frame line-of-sight memo')

    -- Sampling the same tile repeatedly with the same dynamic light must run the
    -- shadow test once per frame, not once per sample. Without this, per-column
    -- sampling would multiply out to columns x lights x ray length every frame.
    local memo = Lighting.new{ world = openRoom(24), baseLevel = 0.3 }
    memo:update()
    memo:beginFrame()
    memo:addDynamic{ x = 12.5, y = 12.5, radius = 8 }

    local before = memo:report().losTests
    for _ = 1, 300 do memo:sample(10.5, 12.5) end
    t.eq(memo:report().losTests - before, 1,
         '300 samples of one tile cost one line-of-sight test')

    -- A new frame must not trust the old answer.
    memo:beginFrame()
    memo:addDynamic{ x = 12.5, y = 12.5, radius = 8 }
    local beforeFrame = memo:report().losTests
    memo:sample(10.5, 12.5)
    t.eq(memo:report().losTests - beforeFrame, 1, 'a new frame re-tests it once')

    -- A light that declares no shadows skips the test entirely, which is the
    -- cheapest light in the engine.
    memo:beginFrame()
    memo:addDynamic{ x = 12.5, y = 12.5, radius = 8, shadows = false }
    local beforeFree = memo:report().losTests
    for _ = 1, 50 do memo:sample(10.5, 12.5) end
    t.eq(memo:report().losTests - beforeFree, 0,
         'a shadowless light runs no line-of-sight tests at all')

    ---------------------------------------------------------------------
    t.describe('sampling never runs off the map')

    local edge = Lighting.new{ world = openRoom(10), baseLevel = 0.5 }
    edge:addStatic{ x = 5.5, y = 5.5, radius = 3 }
    edge:update()
    for _, p in ipairs({ { -50, -50 }, { 0, 0 }, { 10, 10 }, { 500, 5.5 }, { 5.5, -0.001 } }) do
        local r, g, b = edge:sample(p[1], p[2])
        t.ok(r >= Lighting.MIN_VISIBILITY and r <= Lighting.MAX_LEVEL,
             ('sample(%s, %s) stays in range'):format(p[1], p[2]))
        t.ok(g == g and b == b, 'and produces no NaN')   -- NaN is the only value ~= itself
    end

    ---------------------------------------------------------------------
    t.describe('bad input is refused rather than half-accepted')

    local guard = Lighting.new{ world = openRoom(8) }
    t.ok(not pcall(function() guard:addStatic{ y = 3 } end), 'a light with no x is refused')
    t.ok(not pcall(function() guard:addStatic{ x = 3 } end), 'a light with no y is refused')
    t.ok(not pcall(function() guard:addStatic('torch') end), 'a light that is not a table is refused')
    t.ok(not pcall(function() Lighting.new{} end), 'a grid with no world is refused')

    ---------------------------------------------------------------------
    t.describe('lighting stays headless')

    -- 1. It loads with no love global whatsoever.
    local savedLove = rawget(_G, 'love')
    rawset(_G, 'love', nil)
    package.loaded['meatray.render.lighting'] = nil
    local loaded, err = pcall(require, 'meatray.render.lighting')
    t.ok(loaded, 'meatray.render.lighting loads with no love global', err)
    rawset(_G, 'love', savedLove)

    -- 2. Its source names no love drawing API, comments stripped first — the doc
    --    block at the top of the file states this very rule and so necessarily
    --    mentions what it forbids.
    local handle = io.open('meatray/render/lighting.lua', 'r')
    t.ok(handle ~= nil, 'meatray/render/lighting.lua is readable')
    if handle then
        local src = handle:read('*a')
        handle:close()
        local code = src:gsub('%-%-%[%[.-%]%]', ''):gsub('%-%-[^\n]*', '')
        for _, pattern in ipairs({ 'love%.graphics', 'love%.window', 'love%.audio',
                                   'love%.image', 'love%.keyboard', 'love%.mouse' }) do
            t.ok(not code:find(pattern),
                 ('lighting.lua does not touch %s'):format(pattern:gsub('%%', '')))
        end
        t.ok(not code:find('[^%w_]love[^%w_]'), 'and does not name love at all')
    end
end
