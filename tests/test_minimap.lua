--[[
    Minimap layout is headless; no host required for build().
]]

return function(t)
    local Worldgen = require('meatray.sim.worldgen')
    local Minimap = require('meatray.render.minimap')
    local Entity = require('meatray.sim.entity')

    local world = Worldgen.box(10, 10)
    local mm = Minimap.new{ world = world, size = 100 }

    ---------------------------------------------------------------------
    t.describe('build lists wall and floor cells')

    local built = mm:build(5.0, 5.0, 0, {})
    t.ok(#built.cmds > 0, 'has draw commands')
    local walls, floors, players = 0, 0, 0
    for i = 1, #built.cmds do
        local k = built.cmds[i].kind
        if k == 'wall' then walls = walls + 1
        elseif k == 'floor' then floors = floors + 1
        elseif k == 'player' then players = players + 1
        end
    end
    t.ok(walls > 0, 'border walls appear')
    t.ok(floors > 0, 'interior floors appear')
    t.eq(players, 1, 'player marker present')

    ---------------------------------------------------------------------
    t.describe('entities on the same storey show up')

    local mob = Entity.new{ x = 3.5, y = 3.5, storey = 1 }
    local built2 = mm:build(5, 5, 1.2, { entities = { mob } })
    local ents = 0
    for i = 1, #built2.cmds do
        if built2.cmds[i].kind == 'entity' then ents = ents + 1 end
    end
    t.eq(ents, 1, 'one entity marker')

    ---------------------------------------------------------------------
    t.describe('origin corners')

    local ox, oy = mm:origin(800, 600)
    t.ok(ox > 600, 'br corner is on the right')
    t.ok(oy > 400, 'br corner is on the bottom')
    mm.corner = 'tl'
    ox, oy = mm:origin(800, 600)
    t.eq(ox, mm.margin, 'tl x is margin')
    t.eq(oy, mm.margin, 'tl y is margin')
end
