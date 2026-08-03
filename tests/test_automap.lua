--[[
    F2: automap memory — reveal is line-of-sight, walls hide what is behind
    them, and the memory survives a save.
]]

return function(t)
    local Automap = require('meatray.game.automap')
    local World   = require('meatray.sim.world')
    local Game    = require('meatray.game')

    t.eq(Game.automap, Automap, 'Game.automap is the automap module')

    -- A 13-wide room split by a full-height wall at x=7 with a doorway gap
    -- at y=7. Standing on the west side, the east side is unseeable until
    -- something opens — which is exactly what the assertions turn on.
    local function splitRoom()
        local g = {}
        for y = 1, 13 do
            g[y] = {}
            for x = 1, 13 do
                local edge = (x == 1 or y == 1 or x == 13 or y == 13)
                local wall = (x == 7 and y ~= 7)
                g[y][x] = (edge or wall) and 1 or 0
            end
        end
        g[7][7] = 0
        return World.new(g)
    end

    ---------------------------------------------------------------------
    t.describe('reveal: what you can see, and only that')

    local w = splitRoom()
    local am = Automap.new{ radius = 4 }

    t.eq(am:seenCount(), 0, 'nothing known at the start')

    -- Standing west of the divider, mid-room.
    local revealed = am:visit(w, 3.5, 6.5)
    t.ok(revealed > 0, 'standing somewhere reveals it')
    t.eq(am:isVisited(4, 7), true, 'the tile underfoot is known')
    t.eq(am:isVisited(3, 5), true, 'and open floor in view')
    t.eq(am:isVisited(7, 5), true, 'the wall you are looking at is known')
    t.eq(am:isVisited(8, 5), false, 'the room behind it is not')
    t.eq(am:isVisited(11, 7), false, 'nor anything deeper east')

    t.eq(am:visit(w, 3.6, 6.6), 0, 'moving within one tile is free')
    t.eq(am:visit(w, 3.5, 6.5), 0, 'and standing still is too')

    -- Walking through the doorway reveals the far side.
    am:visit(w, 7.5, 7.5)
    am:visit(w, 9.5, 7.5)
    t.eq(am:isVisited(9, 7), true, 'through the gap, the east side appears')
    t.ok(am:seenCount() > revealed, 'the memory only grows')

    ---------------------------------------------------------------------
    t.describe('radius bounds the reveal')

    local far = Automap.new{ radius = 2 }
    far:visit(w, 3.5, 3.5)
    t.eq(far:isVisited(3, 3), true, 'adjacent is seen')
    t.eq(far:isVisited(6, 7), false, 'four tiles away is not, at radius 2')

    ---------------------------------------------------------------------
    t.describe('a door that opens changes what a forced revisit sees')

    local wd = splitRoom()
    wd:addDoor(7, 7, false)              -- shut door in the gap
    local amd = Automap.new{ radius = 5 }
    amd:visit(wd, 5.5, 6.5)
    t.eq(amd:isVisited(7, 7), true, 'a shut door is a thing you can see')
    t.eq(amd:isVisited(9, 7), false, 'but not through')

    wd:setDoorOpen(7, 7, true)
    t.eq(amd:visit(wd, 5.5, 6.5), 0, 'same tile, no force: nothing rechecked')
    local more = amd:visit(wd, 5.5, 6.5, 1, true)
    t.ok(more > 0, 'forced, the open door lets the far side in')
    t.eq(amd:isVisited(9, 7), true, 'and it is remembered')

    ---------------------------------------------------------------------
    t.describe('storeys are separate memories')

    local two = splitRoom()
    two:addStorey((function()
        local g = {}
        for y = 1, 13 do
            g[y] = {}
            for x = 1, 13 do
                g[y][x] = (x == 1 or y == 1 or x == 13 or y == 13) and 1 or 0
            end
        end
        return g
    end)())
    local ams = Automap.new{ radius = 3 }
    ams:visit(two, 3.5, 3.5, 1)
    ams:visit(two, 9.5, 9.5, 2)
    t.eq(ams:isVisited(3, 3, 1), true, 'storey 1 knows its tiles')
    t.eq(ams:isVisited(3, 3, 2), false, 'storey 2 does not inherit them')
    t.eq(ams:isVisited(9, 9, 2), true, 'and keeps its own')

    ---------------------------------------------------------------------
    t.describe('coverage climbs toward, and stops at, 1')

    local cov = Automap.new{ radius = 6 }
    local cw = splitRoom()
    t.eq(cov:coverage(cw), 0, 'zero before anyone moves')
    cov:visit(cw, 3.5, 6.5)
    local partial = cov:coverage(cw)
    t.ok(partial > 0 and partial < 1, 'part-way through is a fraction')

    -- Walk everywhere open.
    for y = 2, 12 do
        for x = 2, 12 do
            if not cw:isSolid(x, y) then
                cov:visit(cw, x - 0.5, y - 0.5)
            end
        end
    end
    t.eq(cov:coverage(cw), 1, 'walking everywhere is 100%, exactly')

    ---------------------------------------------------------------------
    t.describe('the memory survives a save')

    local saved = am:capture()
    t.eq(type(saved.storeys[1]), 'string', 'a storey packs to one string')

    local back = Automap.new()
    back:restore(saved)
    t.eq(back:seenCount(), am:seenCount(), 'every tile came back')
    t.eq(back:isVisited(4, 7), true, 'including the ones that matter')
    t.eq(back:isVisited(8, 5), am:isVisited(8, 5), 'and none extra')
    t.eq(back.radius, am.radius, 'the radius rides along')

    -- Round-tripping the capture is stable: same string both times.
    t.eq(back:capture().storeys[1], saved.storeys[1], 'capture is stable')

    back:restore(nil)
    t.eq(back:seenCount(), 0, 'restoring nothing is a clean slate')
    back:restore({ storeys = { [1] = 'garbage;;3,3;also garbage' } })
    t.eq(back:seenCount(), 1, 'garbage keys are dropped, good ones kept')
    t.eq(back:isVisited(3, 3), true, 'the good one being this')

    ---------------------------------------------------------------------
    t.describe('the minimap under fog hides tiles AND entities')

    local Minimap = require('meatray.render.minimap')
    local mw = splitRoom()
    local fogMap = Automap.new{ radius = 4 }
    fogMap:visit(mw, 3.5, 6.5)           -- west side only

    local mm = Minimap.new{ world = mw, size = 64 }
    local lurker = { x = 10.5, y = 6.5 } -- east side, unseen
    local nearby = { x = 3.5, y = 5.5 }  -- west side, seen

    local plan = mm:build(3.5, 6.5, 0, {
        fog = fogMap:visited(1),
        entities = { lurker, nearby },
    })
    local tiles, entities = 0, 0
    local drewOccluded = false
    for _, cmd in ipairs(plan.cmds) do
        if cmd.kind == 'wall' or cmd.kind == 'floor' or cmd.kind == 'door' then
            tiles = tiles + 1
            -- East of the divider is fair game ON the doorway row — the gap
            -- is a sightline. Off that row the wall occludes, and drawing
            -- there would mean the fog leaked.
            if cmd.tx and cmd.tx > 7 and cmd.ty ~= 7 then drewOccluded = true end
        elseif cmd.kind == 'entity' then
            entities = entities + 1
        end
    end
    t.ok(tiles > 0, 'fogged plan draws the seen tiles')
    t.eq(drewOccluded, false, 'and nothing the divider occludes')
    t.eq(entities, 1, 'an entity in the dark is not a red dot — that is a wallhack')
end
