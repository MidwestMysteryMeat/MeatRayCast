--[[
    B9: the entity palette's edit logic — replace-or-create, kept angles,
    wrapped rotation, legend continuity, and a serialize round-trip.
]]

return function(t)
    local ME  = require('meatray.ui.map_entities')
    local Map = require('meatray.sim.map')

    local map = Map.blank(12, 12)

    ---------------------------------------------------------------------
    t.describe('place: one marker per tile, always')

    local imp, created = ME.place(map, 4, 5, 'imp')
    t.eq(created, true, 'a fresh tile creates')
    t.eq(#map.entities, 1, 'one marker')
    t.near(imp.x, 3.5, 1e-9, 'stored at the tile centre')
    t.eq(imp.char, Map.charFor(map, 'imp'), 'and stamped into the legend')

    local again, madeAnother = ME.place(map, 4, 5, 'imp')
    t.eq(madeAnother, false, 're-placing the same kind keeps the entry')
    t.eq(again, imp, 'the SAME entry — a set angle must survive a re-stamp')
    t.eq(#map.entities, 1, 'still one marker')

    ME.rotate(imp, 2)                       -- face 90°
    ME.place(map, 4, 5, 'imp')
    t.near(imp.angle, math.pi / 2, 1e-9, 'and it did survive')

    local crystal = ME.place(map, 4, 5, 'crystal')
    t.eq(#map.entities, 1, 'a different kind replaces')
    t.eq(map.entities[1], crystal, 'with the new entry')
    t.eq(ME.at(map, 4, 5).kind, 'crystal', 'which is what the tile now holds')

    ---------------------------------------------------------------------
    t.describe('at and remove')

    ME.place(map, 8, 8, 'imp')
    local found, index = ME.at(map, 8, 8)
    t.eq(found.kind, 'imp', 'at finds the marker')
    t.eq(map.entities[index], found, 'and reports where it lives')
    t.eq(ME.at(map, 9, 9), nil, 'an empty tile is nil')

    -- A tile that accumulated duplicates through an old bug clears fully and
    -- says how many went.
    map.entities[#map.entities + 1] = { kind = 'imp', x = 7.5, y = 7.5 }
    map.entities[#map.entities + 1] = { kind = 'imp', x = 7.5, y = 7.5 }
    t.eq(ME.remove(map, 8, 8), 3, 'remove clears the whole pile and counts it')
    t.eq(ME.at(map, 8, 8), nil, 'nothing left')

    ---------------------------------------------------------------------
    t.describe('rotate wraps, describe rounds')

    local marker = ME.place(map, 2, 2, 'imp')
    for _ = 1, 8 do ME.rotate(marker, 1) end
    t.near(marker.angle, 0, 1e-9, 'eight eighth-turns is home, not 2*pi')
    ME.rotate(marker, -1)
    t.near(marker.angle, math.pi * 7 / 4, 1e-9, 'backwards wraps the other way')

    local info = ME.describe(marker)
    t.eq(info.angle, '315°', 'described in degrees a human reads')
    t.eq(info.kind, 'imp', 'with the kind')
    t.eq(ME.describe(nil), nil, 'no selection describes as nothing')

    ---------------------------------------------------------------------
    t.describe('palette rows sort and mark the current kind')

    local rows = ME.palette({ 'imp', 'crystal', 'player' }, 'imp')
    t.eq(#rows, 3, 'one row per name')
    t.eq(rows[1].kind, 'crystal', 'sorted')
    t.eq(rows[2].selected, true, 'the current kind is marked')
    t.eq(rows[1].selected, false, 'and only it')
    t.eq(#ME.palette(nil, 'imp'), 0, 'no registry, no rows, no crash')

    ---------------------------------------------------------------------
    t.describe('what the palette writes, the map format keeps')

    local out = Map.blank(8, 8)
    local placed = ME.place(out, 3, 3, 'imp')
    ME.rotate(placed, 2)
    ME.place(out, 5, 5, 'crystal')

    local text = Map.serialize(out)
    local back, errs = Map.parse(text)
    t.ok(back, 'serializes and re-parses'
         .. (back and '' or (': ' .. table.concat(errs or {}, '; '))))
    t.eq(#back.entities, 2, 'both markers survive')
    local impBack = ME.at(back, 3, 3)
    t.eq(impBack.kind, 'imp', 'as their kinds')
    -- The grid stores tile + char; facing rides the entity header line only
    -- when the format grows one. Documented by assertion: today the angle is
    -- editor-session state, and pretending otherwise would be a lie a test
    -- should refuse to tell.
    t.ok(impBack.angle == 0 or impBack.angle == nil,
         'angle does not survive the text grid (a known format limit)')
end
