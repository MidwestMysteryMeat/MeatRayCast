--[[
    B11: prefab capture, rotation, paste, and the round-trip — with rotation
    the load-bearing part, because a WxH room turned a quarter is HxW with its
    doors on a different wall.
]]

return function(t)
    local Prefab = require('meatray.sim.prefab')
    local Map    = require('meatray.sim.map')
    local MeatRay = require('meatray')

    t.eq(MeatRay.prefab, Prefab, 'MeatRay.prefab is the prefab module')

    ---------------------------------------------------------------------
    t.describe('capture: a rect becomes a stamp, corner-agnostic')

    -- A 12x12 map with a distinctive 3x3 block at (4,4): a wall ring around
    -- an open centre, a door on the top edge, an imp in the middle.
    local src = Map.blank(12, 12)
    src.tiles[4][4] = 1; src.tiles[4][5] = 1; src.tiles[4][6] = 1
    src.tiles[5][4] = 1; src.tiles[5][6] = 1
    src.tiles[6][4] = 1; src.tiles[6][5] = 1; src.tiles[6][6] = 1
    src.tiles[4][5] = 10                      -- a door tile on the top edge
    src.doors[#src.doors + 1] = { x = 5, y = 4, open = false }
    src.entities[#src.entities + 1] = { kind = 'imp', x = 4.5, y = 4.5, angle = 0 }

    local stamp = Prefab.capture(src, 4, 4, 6, 6)
    t.eq(stamp.w, 3, 'captured width')
    t.eq(stamp.h, 3, 'captured height')
    t.eq(stamp.tiles[0][0], 1, 'top-left wall, 0-based')
    t.eq(stamp.tiles[1][1], 0, 'open centre')
    t.eq(#stamp.doors, 1, 'the door came along')
    t.eq(stamp.doors[1].x, 1, 'at its stamp-relative column')
    t.eq(#stamp.entities, 1, 'and the imp')
    t.near(stamp.entities[1].x, 1.5, 1e-9, 'at its offset within the stamp')

    local flipped = Prefab.capture(src, 6, 6, 4, 4)
    t.eq(flipped.w, 3, 'a reversed drag captures the same rect')
    t.eq(flipped.tiles[0][0], stamp.tiles[0][0], 'from the same corner')

    ---------------------------------------------------------------------
    t.describe('rotation turns the room and everything in it')

    -- A 2x3 asymmetric stamp: a door on the north edge, so we can watch it
    -- move to the east edge after a clockwise quarter.
    local room = Prefab.deserialize('2x3|1,1;0,0;0,0|0:0:0|imp:0.5:0.5:0')
    t.eq(room.w, 2, 'built 2 wide')
    t.eq(room.h, 3, 'and 3 tall')

    local turned = Prefab.rotate(room, 1)
    t.eq(turned.w, 3, 'a quarter turn swaps the dimensions')
    t.eq(turned.h, 2, 'to 3x2')

    -- The door at stamp (0,0) — north-west — rotates clockwise to the north-
    -- east corner (col w-1, row 0).
    t.eq(turned.doors[1].x, turned.w - 1, 'the door moved to the new east edge')
    t.eq(turned.doors[1].y, 0, 'top row')

    -- The imp's facing turned with the room.
    t.near(turned.entities[1].angle, math.pi / 2, 1e-9, 'the imp faces a quarter round')

    -- Four quarter-turns is the identity, tile for tile.
    local full = Prefab.rotate(Prefab.rotate(Prefab.rotate(Prefab.rotate(room, 1), 1), 1), 1)
    t.eq(full.w, room.w, 'four turns restore the width')
    t.eq(full.h, room.h, 'and the height')
    t.eq(full.tiles[1][1], room.tiles[1][1], 'and the tiles')

    ---------------------------------------------------------------------
    t.describe('paste lands it, clipped to the map, selection returned')

    local dst = Map.blank(20, 20)
    local rect = Prefab.paste(dst, stamp, 8, 8)
    t.ok(rect, 'paste reports what it wrote')
    t.eq(rect.tx1, 8, 'at the offset')
    t.eq(rect.tx2, 10, 'spanning the stamp width')
    t.eq(dst.tiles[8][8], 1, 'the top-left wall landed')
    t.eq(dst.tiles[9][9], 0, 'the open centre landed')
    t.eq(#dst.doors, 1, 'the door landed')
    t.eq(dst.doors[1].x, 9, 'at the offset column')
    t.eq(#dst.entities, 1, 'the imp landed')
    t.near(dst.entities[1].x, 8.5, 1e-9, 'at its world position')
    t.eq(dst.entities[1].char, Map.charFor(dst, 'imp'), 'stamped into the destination legend')

    -- A rotated paste.
    local dst2 = Map.blank(20, 20)
    Prefab.paste(dst2, room, 5, 5, { rotate = 1 })
    -- room is 2x3; rotated it is 3x2, so the far corner is (5+2, 5+1).
    t.eq(dst2.tiles[5][7] ~= nil, true, 'the rotated stamp reached its new width')

    -- Pasting off the edge clips rather than growing the map.
    local edge = Map.blank(10, 10)
    local clipped = Prefab.paste(edge, stamp, 9, 9)
    t.ok(clipped, 'a partly-off paste still lands what fits')
    t.eq(edge.width, 10, 'and does not resize the map')
    t.eq(Prefab.paste(edge, stamp, 50, 50), nil, 'a fully-off paste lands nothing')

    ---------------------------------------------------------------------
    t.describe('paste overwrites, it does not accumulate')

    local twice = Map.blank(20, 20)
    Prefab.paste(twice, stamp, 5, 5)
    Prefab.paste(twice, stamp, 5, 5)
    t.eq(#twice.doors, 1, 'pasting the same stamp twice leaves one door, not two')
    t.eq(#twice.entities, 1, 'and one imp')

    ---------------------------------------------------------------------
    t.describe('serialize round-trips a stamp exactly')

    local text = Prefab.serialize(stamp)
    local back, err = Prefab.deserialize(text)
    t.ok(back, 'deserializes' .. (back and '' or (': ' .. tostring(err))))
    t.eq(back.w, stamp.w, 'width')
    t.eq(back.h, stamp.h, 'height')
    t.eq(back.tiles[0][0], stamp.tiles[0][0], 'tiles')
    t.eq(#back.doors, #stamp.doors, 'doors')
    t.eq(back.entities[1].kind, 'imp', 'entities')
    t.eq(Prefab.deserialize('garbage'), nil, 'garbage refuses')

    ---------------------------------------------------------------------
    t.describe('the built-in kit is real, pasteable rooms')

    local names = Prefab.kitNames()
    t.ok(#names >= 4, ('the kit has stamps (%d)'):format(#names))
    for _, name in ipairs(names) do
        local kit = Prefab.KIT[name]
        t.ok(kit and kit.w > 0 and kit.h > 0, name .. ' is a real stamp')
        local m = Map.blank(16, 16)
        t.ok(Prefab.paste(m, kit, 4, 4), name .. ' pastes onto a map')
    end

    -- A kit room pasted then re-serialized survives a full map round-trip.
    local kitMap = Map.blank(16, 16)
    Prefab.paste(kitMap, Prefab.KIT.guard_post, 5, 5)
    local mapText = Map.serialize(kitMap)
    local reparsed = Map.parse(mapText)
    t.ok(reparsed, 'a map with a pasted prefab serializes and re-parses')
    t.ok(#reparsed.entities >= 1, 'and keeps the prefab\'s entities')
end
