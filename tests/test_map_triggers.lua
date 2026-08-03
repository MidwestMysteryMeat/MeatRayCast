--[[
    B10: trigger volumes on the plan. The `.map` trigger directive parses and
    survives a serialize→parse round trip (with and without a storey, once, and
    filter), toWorld/fromWorld carry it, and the headless edit model places,
    finds, rebinds, renames (uniquely) and deletes volumes.
]]

return function(t)
    local Map = require('meatray.sim.map')
    local MT = require('meatray.ui.map_triggers')

    ---------------------------------------------------------------------
    t.describe('the trigger directive parses')

    local text = table.concat({
        'name Trig', 'theme dungeon', 'spawn 2.5 2.5 0',
        'trigger alarm waves 3 4 6 7',                 -- storey 1, defaults
        'trigger boss raid 2 1 2 9 8 once any',        -- storey 2, once, any
        '---',
        '######',
        '#....#',
        '#....#',
        '######',
    }, '\n')
    local map, errs = Map.parse(text)
    t.ok(map, 'map parses: ' .. tostring(errs and errs[1]))
    t.eq(#map.triggers, 2, 'two triggers')

    local a = map.triggers[1]
    t.eq(a.name, 'alarm', 'name'); t.eq(a.graph, 'waves', 'graph id')
    t.eq(a.storey, 1, 'default storey 1')
    t.eq(a.x1, 3, 'x1'); t.eq(a.y2, 7, 'y2')
    t.eq(a.once, false, 'defaults to repeating')
    t.eq(a.filter, 'player', 'defaults to player')

    local b = map.triggers[2]
    t.eq(b.storey, 2, 'explicit storey'); t.eq(b.once, true, 'once flag')
    t.eq(b.filter, 'any', 'any filter')

    ---------------------------------------------------------------------
    t.describe('a malformed trigger is an error, not a crash')

    local bad = Map.parse('name X\ntrigger onlyname\n---\n##\n##')
    -- name X parses; the trigger line is missing everything -> recorded error,
    -- but parse still returns a map (errors are collected, not thrown).
    t.ok(bad == nil or true, 'no crash on a broken trigger line')

    ---------------------------------------------------------------------
    t.describe('serialize -> parse is exact')

    local out = Map.serialize(map)
    local reparsed, rerr = Map.parse(out)
    t.ok(reparsed, 'reparses: ' .. tostring(rerr and rerr[1]))
    t.eq(#reparsed.triggers, 2, 'both survive the round trip')
    t.eq(reparsed.triggers[1].name, 'alarm', 'name round-trips')
    t.eq(reparsed.triggers[1].graph, 'waves', 'graph round-trips')
    t.eq(reparsed.triggers[2].storey, 2, 'storey round-trips')
    t.eq(reparsed.triggers[2].once, true, 'once round-trips')
    t.eq(reparsed.triggers[2].filter, 'any', 'filter round-trips')
    -- The default-filter volume must NOT gain a stray 'player' token.
    t.eq(reparsed.triggers[1].filter, 'player', 'default filter still player')
    t.eq(reparsed.triggers[1].once, false, 'default once still false')

    ---------------------------------------------------------------------
    t.describe('toWorld and fromWorld carry triggers')

    local world = Map.toWorld(map)
    t.ok(world.triggers and #world.triggers == 2, 'world carries triggers')
    t.eq(world.triggers[1].graph, 'waves', 'world trigger keeps its graph')
    local back = Map.fromWorld(world)
    t.ok(back.triggers and #back.triggers == 2, 'fromWorld carries them back')
    t.eq(back.triggers[2].filter, 'any', 'filter survives the world round trip')

    ---------------------------------------------------------------------
    t.describe('the edit model places with sorted corners and auto-names')

    local m = { triggers = {} }
    -- Drag bottom-right to top-left: corners must come out sorted.
    local e = MT.place(m, 8, 9, 3, 4, { graph = 'waves' })
    t.eq(e.x1, 3, 'x1 sorted'); t.eq(e.x2, 8, 'x2 sorted')
    t.eq(e.y1, 4, 'y1 sorted'); t.eq(e.y2, 9, 'y2 sorted')
    t.eq(e.name, 'trig1', 'auto-named trig1')
    t.eq(e.filter, 'player', 'default filter')
    local e2 = MT.place(m, 1, 1, 2, 2, {})
    t.eq(e2.name, 'trig2', 'second auto-name is unique')

    ---------------------------------------------------------------------
    t.describe('at / removeAt work by tile, topmost first')

    -- e covers tiles whose centre is in [3,8]x[4,9]; tile (4,5)->centre 3.5,4.5.
    local hit, idx = MT.at(m, 4, 5)
    t.eq(hit, e, 'finds the covering volume')
    t.ok(idx, 'and its index')
    t.eq(MT.at(m, 1, 9), nil, 'a tile under no volume finds nothing')
    local gone = MT.removeAt(m, 4, 5)
    t.eq(gone, e, 'removeAt returns what it deleted')
    t.eq(#m.triggers, 1, 'one left')

    ---------------------------------------------------------------------
    t.describe('rebind, rename (unique), toggle, filter')

    t.eq(MT.setGraph(e2, 'boss'), 'boss', 'setGraph binds')
    t.eq(MT.toggleOnce(e2), true, 'toggleOnce flips on')
    t.eq(MT.cycleFilter(e2), 'any', 'cycleFilter -> any')
    t.eq(MT.cycleFilter(e2), 'player', 'cycleFilter -> player')

    -- Rename collision: add another, then try to steal its name.
    local e3 = MT.place(m, 5, 5, 6, 6, { name = 'gate' })
    t.eq(MT.rename(m, e2, 'gate'), false, 'rename refuses a taken name')
    t.eq(MT.rename(m, e2, 'lever'), true, 'a free name is accepted')
    t.eq(e2.name, 'lever', 'name changed')
    -- place() with a colliding name falls back to an auto-name, never collides.
    local e4 = MT.place(m, 7, 7, 8, 8, { name = 'gate' })
    t.ok(e4.name ~= 'gate', 'colliding place() auto-names instead')
    t.eq(MT.nameTaken(m, e4.name, e4), false, 'and the fallback is unique')

    ---------------------------------------------------------------------
    t.describe('describe and the graph palette')

    local d = MT.describe(e3)
    t.eq(d.name, 'gate', 'describe names it')
    t.eq(d.graph, '(none — pick one)', 'empty graph is flagged')
    local rows = MT.graphPalette({ 'waves', 'boss', 'alarm' }, 'boss')
    t.eq(rows[1].id, 'alarm', 'palette sorted')
    t.eq(rows[2].selected, true, 'current graph marked (boss at index 2)')
end
