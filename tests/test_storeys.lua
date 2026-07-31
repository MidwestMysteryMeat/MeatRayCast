--[[
    In-world layered storeys: isolation, absolute floor z, map multi-grid.
]]

return function(t)
    local World = require('meatray.sim.world')
    local Worldgen = require('meatray.sim.worldgen')
    local Collide = require('meatray.sim.collide')
    local Entity = require('meatray.sim.entity')
    local Map = require('meatray.sim.map')

    ---------------------------------------------------------------------
    t.describe('single layer is storey 1')

    local w = Worldgen.box(8, 8)
    t.eq(w:storeyCount(), 1, 'one storey by default')
    t.eq(w:storeyBase(1), 0, 'ground base is 0')
    t.eq(w:storeyBase(2), World.STOREY_HEIGHT, 'storey 2 base')
    t.eq(w.layers[1].grid, w.grid, 'layer 1 grid is the top-level alias')

    ---------------------------------------------------------------------
    t.describe('addStorey isolates tiles')

    local upper = {}
    for y = 1, 8 do
        upper[y] = {}
        for x = 1, 8 do
            upper[y][x] = (x == 1 or y == 1 or x == 8 or y == 8) and 1 or 0
        end
    end
    -- Pillar only on upper
    upper[4][4] = 1
    local s2 = w:addStorey(upper)
    t.eq(s2, 2, 'second storey index')
    t.eq(w:storeyCount(), 2, 'two storeys')
    t.eq(w:isSolid(4, 4, 1), false, 'ground open under pillar')
    t.eq(w:isSolid(4, 4, 2), true, 'upper has pillar')
    t.eq(w:isSolid(4, 4), false, 'default storey is 1')

    ---------------------------------------------------------------------
    t.describe('absolute floor z tracks storey')

    t.eq(w:absoluteFloorAt(3, 3, 1), 0, 'storey 1 floor 0')
    t.eq(w:absoluteFloorAt(3, 3, 2), World.STOREY_HEIGHT, 'storey 2 floor base')
    w:setFloorHeight(3, 3, 0.25, { storey = 2 })
    t.near(w:absoluteFloorAt(3, 3, 2), World.STOREY_HEIGHT + 0.25, 1e-9,
           'relative floor on storey 2')

    ---------------------------------------------------------------------
    t.describe('entity storey collision')

    -- Tile (3,3) centres at world (2.5, 2.5)
    local e = Entity.new{ x = 2.5, y = 2.5, storey = 2 }
    Collide.ground(e, w)
    t.near(e.z, World.STOREY_HEIGHT + 0.25, 1e-9, 'grounded on storey 2 floor')

    -- Pillar at tile (4,4) centre (3.5, 3.5). Approach from (2.5, 3.5).
    e.x, e.y = 2.5, 3.5
    e.storey = 2
    Collide.ground(e, w)
    local _, blocked = Collide.move(e, 1.2, 0, w)
    t.eq(blocked, true, 'blocked by upper-storey wall')
    t.ok(e.x < 3.2, 'did not enter pillar tile')

    -- Ground storey walks free under the pillar
    local g = Entity.new{ x = 2.5, y = 3.5, storey = 1 }
    Collide.ground(g, w)
    Collide.move(g, 1.2, 0, w)
    t.ok(g.x > 3.2, 'storey 1 walks under upper pillar')

    ---------------------------------------------------------------------
    t.describe('map multi-grid parse')

    local text = [[
name  Dual
theme dungeon
spawn 2.5 2.5 0
entity c crystal
---
####
#.^#
#..#
####
---
####
#.v#
#.c#
####
]]
    local map, err = Map.parse(text)
    t.ok(map ~= nil, 'parses dual grid', err and err[1])
    t.eq(#(map.storeys or {}), 2, 'two storeys on map')
    local world, markers = Map.toWorld(map)
    t.eq(world:storeyCount(), 2, 'world has two layers')
    -- Row2 "#.^#" → tile (3,2) is stairs
    t.eq(world:tileAt(3, 2, 1), World.STAIRS_UP, 'ground stairs up')
    t.eq(world:tileAt(3, 2, 2), World.STAIRS_DOWN, 'upper stairs down')
    local found = false
    for i = 1, #markers do
        if markers[i].kind == 'crystal' and markers[i].storey == 2 then
            found = true
        end
    end
    t.ok(found, 'crystal on storey 2')

    ---------------------------------------------------------------------
    t.describe('multi-storey serialize round-trips')

    local ser = Map.serialize(map)
    local seps = 0
    for _ in ser:gmatch('\n%-%-%-\n') do seps = seps + 1 end
    -- leading --- plus possible; count '---' lines
    local dash = 0
    for line in (ser .. '\n'):gmatch('([^\n]*)\n') do
        if line:match('^%s*%-%-%-%s*$') then dash = dash + 1 end
    end
    t.eq(dash, 2, 'serialize writes two grid separators')
    local again = assert(Map.parse(ser))
    t.eq(#(again.storeys or {}), 2, 'round-trip keeps two storeys')
    local w2 = Map.toWorld(again)
    t.eq(w2:tileAt(3, 2, 1), World.STAIRS_UP, 'stairs survive serialize')
    t.eq(w2:tileAt(3, 2, 2), World.STAIRS_DOWN, 'upper stairs survive')

    ---------------------------------------------------------------------
    t.describe('entity snapshot carries storey')

    local climber = Entity.new{ x = 1, y = 1, storey = 2 }
    local snap = climber:snapshot()
    t.eq(snap.storey, 2, 'snapshot includes storey')
    local other = Entity.new{ x = 0, y = 0, storey = 1 }
    other:applySnapshot(snap)
    t.eq(other.storey, 2, 'applySnapshot sets storey')

    ---------------------------------------------------------------------
    t.describe('storey-scoped elevation headers')

    local elev = [[
name  Loft
theme dungeon
spawn 2.5 2.5 0
floor 2 2 2 0.3
ceiling 2 2 2 0.7
---
####
#..#
#..#
####
---
####
#..#
#..#
####
]]
    local em = assert(Map.parse(elev))
    t.eq(em.floorHeights[1].storey, 2, 'floor header storey')
    t.near(em.floorHeights[1].z, 0.3, 1e-9, 'floor z')
    local ew = Map.toWorld(em)
    t.near(ew:floorHeightAt(2, 2, 2), 0.3, 1e-9, 'applied on storey 2')
    t.eq(ew:floorHeightAt(2, 2, 1), 0, 'storey 1 unchanged')
    t.near(ew:ceilingHeightAt(2, 2, 2), 0.7, 1e-9, 'ceiling on storey 2')
    local eser = Map.serialize(em)
    t.ok(eser:find('floor 2 2 2 0.3', 1, true), 'serialize keeps storey prefix')

    ---------------------------------------------------------------------
    t.describe('entities on different storeys do not overlap')

    local a = Entity.new{ x = 2.5, y = 2.5, storey = 1, radius = 0.3 }
    local b = Entity.new{ x = 2.5, y = 2.5, storey = 2, radius = 0.3 }
    t.eq(Collide.overlaps(a, b), false, 'different storeys skip overlap')
    b.storey = 1
    t.eq(Collide.overlaps(a, b), true, 'same storey still overlaps')

    local q = Collide.query({ a, b }, 2.5, 2.5, 2, nil, { storey = 2 })
    t.eq(#q, 0, 'query storey 2 finds none when both on 1')
    b.storey = 2
    q = Collide.query({ a, b }, 2.5, 2.5, 2, nil, { storey = 2 })
    t.eq(#q, 1, 'query storey 2 finds b')
    t.eq(q[1], b, 'and it is b')

    ---------------------------------------------------------------------
    t.describe('multi-layer door and destruction snapshots')

    local dual = Worldgen.box(8, 8)
    local upperGrid = {}
    for y = 1, 8 do
        upperGrid[y] = {}
        for x = 1, 8 do
            upperGrid[y][x] = (x == 1 or y == 1 or x == 8 or y == 8) and 1 or 0
        end
    end
    dual:addStorey(upperGrid)
    dual:addDoor(3, 4, false, 1)
    dual:addDoor(5, 5, false, 2)
    dual:setDoorOpen(5, 5, true, 2)

    local doorSnap = dual:snapshot()
    t.eq(doorSnap['3,4'], 0, 'storey-1 door key stays tx,ty')
    t.eq(doorSnap['2,5,5'], 1, 'storey-2 door key is s,tx,ty and open')

    local dualB = Worldgen.box(8, 8)
    dualB:addStorey(upperGrid)
    dualB:addDoor(3, 4, false, 1)
    dualB:addDoor(5, 5, false, 2)
    dualB:applySnapshot(doorSnap)
    t.eq(dualB:doorAt(5, 5, 2).open, true, 'apply opens upper door')
    t.eq(dualB:doorAt(3, 4, 1).open, false, 'ground door still shut')

    dual:setDestructible(4, 4, 1, 2)
    t.eq(dual:destroyTile(4, 4, 2), true, 'destroy upper pillar')
    t.eq(dual:isSolid(4, 4, 2), false, 'upper is rubble')
    t.eq(dual:isSolid(4, 4, 1), false, 'ground under it was empty')
    local tileSnap = dual:tileSnapshot()
    t.eq(tileSnap['2,4,4'], 1, 'broken tile wire key is s,tx,ty')
    t.eq(tileSnap['4,4'], nil, 'not reported as storey-1')

    local dualC = Worldgen.box(8, 8)
    dualC:addStorey(upperGrid)
    dualC:applyTileSnapshot(tileSnap)
    t.eq(dualC:tileAt(4, 4, 2), World.RUBBLE, 'tile apply destroys storey 2')
    t.eq(dualC:tileAt(4, 4, 1), World.EMPTY, 'storey 1 grid untouched')

    ---------------------------------------------------------------------
    t.describe('AI stays on its storey')

    local AI = require('meatray.sim.ai')
    local Entity = require('meatray.sim.entity')
    local C = require('meatray.sim.components')
    Entity.clearArchetypes()
    Entity.archetype('ai_hero', function(e)
        e:add(C.Player{ peerId = 1, name = 'p' })
    end)
    Entity.archetype('ai_mob', function(e)
        e:add(C.Brain{})
    end)

    local mob = Entity.spawn('ai_mob', 3.5, 3.5)
    mob.storey = 1
    local upHero = Entity.spawn('ai_hero', 3.5, 4.5)
    upHero.storey = 2
    local sameHero = Entity.spawn('ai_hero', 5.5, 3.5)
    sameHero.storey = 1

    t.eq(AI.findTarget(mob, { mob, upHero, sameHero }), sameHero,
         'findTarget picks same-storey player')
    t.eq(AI.findTarget(mob, { mob, upHero }), nil,
         'ignores player on the floor above')
    t.eq(AI.findTarget(mob, { mob, upHero }, { anyStorey = true }), upHero,
         'anyStorey override still works')

    -- LOS on storey 2 sees the upper pillar; storey 1 does not.
    dual.layers[2].grid[4][4] = 1 -- restore a wall if rubble from earlier
    dual.layers[2].broken['4,4'] = nil
    dual.layers[2].grid[4][4] = 1
    t.eq(Collide.lineOfSight(dual, 2.5, 3.5, 5.5, 3.5, 2), false,
         'LOS blocked by upper wall on storey 2')
    t.eq(Collide.lineOfSight(dual, 2.5, 3.5, 5.5, 3.5, 1), true,
         'LOS open on storey 1 under that wall')
    t.eq(AI.hasLineOfSight(dual, 2.5, 3.5, 5.5, 3.5, 2), false,
         'AI LOS uses storey')
end
