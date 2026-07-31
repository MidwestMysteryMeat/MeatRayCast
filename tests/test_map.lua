--[[
    The hand-authored map format.

    The round-trip test is the important one: an editor that loses data on save
    is worse than no editor, because the loss is silent and you only discover it
    after the work is gone.
]]

return function(t)
    local Map = require('meatray.sim.map')
    local World = require('meatray.sim.world')

    local SAMPLE = table.concat({
        'name  Test Arena',
        'theme dungeon',
        'spawn 4.5 3.5 0',
        'entity i imp',
        'entity g guard',
        '# a header comment',
        '---',
        '##########',
        '#........#',
        '#..2222..#',
        '#..2  D..#',
        '#..2222..#',
        '#...i..g.#',
        '##########',
    }, '\n')

    t.describe('parsing the header')
    local map, errs = Map.parse(SAMPLE)
    t.ok(map ~= nil, 'sample parses', errs and errs[1])
    if not map then return end

    t.eq(map.name, 'Test Arena', 'name read')
    t.eq(map.theme, 'dungeon', 'theme read')
    t.eq(map.spawn.x, 4.5, 'spawn x read')
    t.eq(map.spawn.y, 3.5, 'spawn y read')
    t.eq(map.legend.i, 'imp', 'legend entry read')
    t.eq(map.legend.g, 'guard', 'second legend entry read')

    t.describe('parsing the grid')
    t.eq(map.width, 10, 'width from the widest row')
    t.eq(map.height, 7, 'height from the row count')
    t.eq(map.tiles[1][1], 1, '# is wall texture 1')
    t.eq(map.tiles[2][2], 0, '. is open floor')
    t.eq(map.tiles[3][4], 2, 'a digit selects that wall texture')
    t.eq(map.tiles[4][5], 0, 'a space is open floor')

    t.describe('doors come out of the grid')
    t.eq(#map.doors, 1, 'one door found')
    t.eq(map.doors[1].x, 7, 'door x')
    t.eq(map.doors[1].y, 4, 'door y')
    t.ok(not map.doors[1].open, 'D starts shut')
    t.eq(map.tiles[4][7], World.DOOR, 'and the tile is a door tile')

    t.describe('entity markers resolve through the legend')
    t.eq(#map.entities, 2, 'two markers found')
    local imp, guard
    for _, e in ipairs(map.entities) do
        if e.kind == 'imp' then imp = e elseif e.kind == 'guard' then guard = e end
    end
    t.ok(imp ~= nil, 'imp marker resolved')
    t.ok(guard ~= nil, 'guard marker resolved')
    t.eq(imp.x, 4.5, 'marker sits at the tile centre')
    t.eq(imp.y, 5.5, 'marker row is centred too')
    t.eq(map.tiles[6][5], 0, 'the marker tile itself is walkable')

    t.describe('errors are reported, not guessed at')
    local noSep = Map.parse('name x\n####\n####')
    t.eq(noSep, nil, 'a missing --- separator fails')

    local badChar = Map.parse('---\n##\n#%\n')
    t.eq(badChar, nil, 'an unknown grid character fails')

    local unmapped, unmappedErrs = Map.parse('---\n####\n#z.#\n####')
    t.eq(unmapped, nil, 'a letter with no legend entry fails')
    t.ok(unmappedErrs[1]:find('entity') or unmappedErrs[1]:find('"z"'),
         'and the error names the unmapped letter')

    local sizeMismatch = Map.parse('size 99 99\n---\n##\n##')
    t.eq(sizeMismatch, nil, 'a size header that disagrees with the grid fails')

    local noGrid = Map.parse('name x\n---\n')
    t.eq(noGrid, nil, 'a map with no rows fails')

    t.describe('an @ marks spawn when there is no spawn header')
    local atMap = Map.parse('---\n#####\n#.@.#\n#####')
    t.ok(atMap ~= nil, 'grid-spawn map parses')
    t.eq(atMap.spawn.x, 2.5, 'spawn x from the marker')
    t.eq(atMap.spawn.y, 1.5, 'spawn y from the marker')
    t.eq(atMap.tiles[2][3], 0, 'and the spawn tile is walkable')

    -- An explicit header must win, since it can carry a facing angle.
    local both = Map.parse('spawn 9.5 9.5 1.5\n---\n#####\n#.@.#\n#####')
    t.eq(both.spawn.x, 9.5, 'the header beats the grid marker')
    t.eq(both.spawn.angle, 1.5, 'and carries the angle')

    t.describe('round-trip is lossless')
    local text = Map.serialize(map)
    local again, againErrs = Map.parse(text)
    t.ok(again ~= nil, 'serialised output parses back', againErrs and againErrs[1])

    if again then
        t.eq(again.name, map.name, 'name survives')
        t.eq(again.theme, map.theme, 'theme survives')
        t.eq(again.width, map.width, 'width survives')
        t.eq(again.height, map.height, 'height survives')
        t.eq(again.spawn.x, map.spawn.x, 'spawn survives')
        t.eq(#again.doors, #map.doors, 'door count survives')
        t.eq(again.doors[1].x, map.doors[1].x, 'door position survives')
        t.eq(#again.entities, #map.entities, 'entity count survives')

        local tilesMatch = true
        for y = 1, map.height do
            for x = 1, map.width do
                if again.tiles[y][x] ~= map.tiles[y][x] then tilesMatch = false end
            end
        end
        t.ok(tilesMatch, 'every tile survives')

        -- Serialising twice must produce identical bytes, or every save would
        -- show up as a diff even when nothing changed.
        t.eq(Map.serialize(again), text, 'serialisation is stable across saves')
    end

    t.describe('an open door round-trips as open')
    local openDoor = Map.parse('---\n#####\n#.d.#\n#####')
    t.ok(openDoor.doors[1].open, 'd parses as open')
    local reparsed = Map.parse(Map.serialize(openDoor))
    t.ok(reparsed.doors[1].open, 'and stays open through a save')

    t.describe('blank maps are sealed and playable')
    local blank = Map.blank(12, 9)
    t.eq(blank.width, 12, 'requested width')
    t.eq(blank.height, 9, 'requested height')
    t.eq(blank.tiles[1][1], 1, 'border is wall')
    t.eq(blank.tiles[5][6], 0, 'interior is open')
    local blankText = Map.serialize(blank)
    t.ok(Map.parse(blankText) ~= nil, 'a blank map serialises to something valid')

    t.describe('building a world from a map')
    local world, markers, spawn = Map.toWorld(map)
    t.eq(world.width, 10, 'world width matches')
    t.eq(world.height, 7, 'world height matches')
    t.ok(world:isSolid(1, 1), 'walls are solid in the world')
    t.ok(not world:isSolid(2, 2), 'floor is open in the world')
    t.ok(world:isSolid(7, 4), 'the shut door is solid')
    world:setDoorOpen(7, 4, true)
    t.ok(not world:isSolid(7, 4), 'and opens like any other door')
    t.eq(world.theme, 'dungeon', 'theme carried onto the world')
    t.eq(#markers, 2, 'markers handed back for the game to spawn')
    t.eq(spawn.x, 4.5, 'spawn handed back')

    t.describe('capturing a world back into a map')
    local captured = Map.fromWorld(world, {
        name = 'Captured',
        entities = { { kind = 'imp', x = 4.5, y = 5.5 } },
        spawn = { x = 2.5, y = 2.5, angle = 0 },
    })
    t.eq(captured.name, 'Captured', 'name applied')
    t.eq(captured.width, world.width, 'width captured')
    t.eq(#captured.doors, 1, 'door captured')
    t.eq(#captured.entities, 1, 'entity captured')
    t.ok(captured.legend[captured.entities[1].char] == 'imp',
         'a legend entry was created for the placed kind')

    local capturedText = Map.serialize(captured)
    local capturedBack = Map.parse(capturedText)
    t.ok(capturedBack ~= nil, 'a captured world serialises to a loadable map')
    if capturedBack then
        t.eq(#capturedBack.entities, 1, 'and its entity survives the trip')
        t.eq(capturedBack.entities[1].kind, 'imp', 'as the right kind')
    end

    t.describe('legend characters are assigned without collisions')
    local m = Map.blank(5, 5)
    local c1 = Map.charFor(m, 'imp')
    local c2 = Map.charFor(m, 'guard')
    local c3 = Map.charFor(m, 'imp')
    t.ok(c1 ~= c2, 'different kinds get different characters')
    t.eq(c1, c3, 'the same kind always gets the same character')
    t.ok(c1 ~= Map.DOOR_OPEN, 'the door character is never reused')
    t.ok(c1 ~= Map.STAIRS_DOWN, 'the stairs character is never reused')

    t.describe('storey links parse and round-trip')
    local linked = [[
name  Linked
theme dungeon
spawn 2.5 2.5 0
link up maps/tower_upper.map 3.5 4.5 1.2
link down maps/tower.map
---
####
#..#
#.^#
####
]]
    local lm = assert(Map.parse(linked))
    t.ok(lm.links and lm.links.up, 'up link present')
    t.eq(lm.links.up.path, 'maps/tower_upper.map', 'up path')
    t.near(lm.links.up.x, 3.5, 1e-9, 'arrival x')
    t.near(lm.links.up.y, 4.5, 1e-9, 'arrival y')
    t.eq(lm.links.down.path, 'maps/tower.map', 'down path without spawn')
    local lw = Map.toWorld(lm)
    t.eq(lw.links.up.path, 'maps/tower_upper.map', 'toWorld copies links')
    local lser = Map.serialize(Map.fromWorld(lw))
    t.ok(lser:find('link up maps/tower_upper.map', 1, true), 'serialize writes link up')
    local againL = Map.toWorld(assert(Map.parse(lser)))
    t.eq(againL.links.down.path, 'maps/tower.map', 'link round-trip')

    t.describe('unknown header keys survive a round-trip')
    local futured = Map.parse('name x\nmusic ambient_01\n---\n###\n#.#\n###')
    t.ok(futured ~= nil, 'an unknown key does not fail the parse')
    t.eq(futured.extra.music, 'ambient_01', 'and is kept')
    local futuredBack = Map.parse(Map.serialize(futured))
    t.eq(futuredBack.extra.music, 'ambient_01', 'and written back out')

    t.describe('line endings do not decide whether a map loads')
    -- git's autocrlf is on by default on Windows, so a fresh clone rewrites the
    -- maps this repository ships into CRLF. The parser rejecting a carriage return
    -- meant such a clone could not open its own sample map, and the error it gave
    -- ("unknown character") pointed nowhere near the cause.
    local lfText = table.concat({
        'name Endings',
        'theme dungeon',
        'spawn 1.5 1.5 0',
        'entity i imp',
        '---',
        '#####',
        '#.i.#',
        '#####',
    }, '\n')

    local crlfText = lfText:gsub('\n', '\r\n')

    local fromLF = Map.parse(lfText)
    local fromCRLF, crlfErrs = Map.parse(crlfText)

    t.ok(fromLF ~= nil, 'the LF map parses')
    t.ok(fromCRLF ~= nil, 'the CRLF map parses too', crlfErrs and crlfErrs[1])

    if fromLF and fromCRLF then
        t.eq(fromCRLF.width, fromLF.width, 'width is unaffected by line endings')
        t.eq(fromCRLF.height, fromLF.height, 'and so is height')
        t.eq(fromCRLF.name, fromLF.name, 'the header reads the same')
        t.eq(#fromCRLF.entities, #fromLF.entities, 'markers survive either way')
        t.eq(fromCRLF.spawn.x, fromLF.spawn.x, 'so does the spawn')
        -- The strongest form: both must serialise to identical bytes, so a CRLF
        -- checkout cannot quietly produce a different map from an LF one.
        t.eq(Map.serialize(fromCRLF), Map.serialize(fromLF),
             'both round-trip to identical output')
    end

    -- A trailing carriage return on the final row, which is what a partial
    -- conversion leaves behind.
    local ragged = Map.parse('name X\r\n---\r\n###\r\n#.#\r\n###\r')
    t.ok(ragged ~= nil, 'a trailing carriage return does not break the last row')
end
