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
end
