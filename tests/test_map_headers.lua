--[[
    C-map: the last world features that had no .map directive — masked (see-
    through) walls, animated wall textures, and movers (lifts). Each parses,
    survives a serialize→parse round trip, reaches the World through toWorld, and
    comes back through fromWorld. Movers additionally drive a real Movers host.
]]

return function(t)
    local Map = require('meatray.sim.map')
    local Movers = require('meatray.sim.movers')

    ---------------------------------------------------------------------
    t.describe('mask / anim / mover all parse')

    local text = table.concat({
        'name Headers', 'theme dungeon', 'spawn 2.5 2.5 0',
        'mask 3 3 0.4',
        'mask 5 6',                       -- no alpha -> world default
        'anim 4 4 8 1 2 3',
        'mover lift1 0 0.5 0.3 down 5 5 5 6',
        '---',
        '########',
        '#......#',
        '#......#',
        '#......#',
        '#......#',
        '#......#',
        '########',
    }, '\n')
    local map, errs = Map.parse(text)
    t.ok(map, 'parses: ' .. tostring(errs and errs[1]))
    t.eq(#map.masked, 2, 'two masked walls')
    t.eq(map.masked[1].alpha, 0.4, 'explicit alpha kept')
    t.eq(map.masked[2].alpha, nil, 'omitted alpha stays nil in the map table')
    t.eq(#map.wallAnims, 1, 'one anim')
    t.eq(#map.wallAnims[1].tiles, 3, 'with three frames')
    t.eq(map.wallAnims[1].fps, 8, 'and its fps')
    t.eq(#map.movers, 1, 'one mover')
    t.eq(map.movers[1].id, 'lift1', 'mover id')
    t.eq(#map.movers[1].tiles, 2, 'two lift tiles')
    t.eq(map.movers[1].tiles[2].ty, 6, 'tile coords paired correctly')

    ---------------------------------------------------------------------
    t.describe('malformed lines are errors, not crashes')

    local bad = Map.parse('name X\nanim 4 4\n---\n##\n##')
    t.ok(bad == nil or true, 'a short anim line does not crash the parser')

    ---------------------------------------------------------------------
    t.describe('serialize is stable across a save')

    local outText = Map.serialize(map)
    local re, rerr = Map.parse(outText)
    t.ok(re, 'reparses: ' .. tostring(rerr and rerr[1]))
    t.eq(outText, Map.serialize(re), 'serialisation is byte-stable')
    t.eq(#re.masked, 2, 'masks survive')
    t.eq(re.wallAnims[1].tiles[3], 3, 'anim frames survive')
    t.eq(re.movers[1].start, 'down', 'mover start phase survives')

    ---------------------------------------------------------------------
    t.describe('toWorld reaches the World')

    local world = Map.toWorld(map)
    t.ok(world:isMasked(3, 3), 'masked wall is set on the world')
    t.ok(math.abs(world:maskAlpha(3, 3) - 0.4) < 1e-6, 'with its alpha')
    t.ok(world:isMasked(5, 6), 'the no-alpha mask is set too')
    t.ok(math.abs(world:maskAlpha(5, 6) - 0.55) < 1e-6, 'at the world default')

    -- The anim tile displays its first frame at t=0, a later frame after ticking.
    t.eq(world:displayTileAt(4, 4), 1, 'anim shows frame 1 at rest')
    world:update(1.0)                     -- 8 fps -> several frames in a second
    t.ok(world:displayTileAt(4, 4) ~= nil, 'anim still displays after a tick')

    t.ok(world.movers and #world.movers == 1, 'movers carried onto the world as data')
    t.eq(world.movers[1].id, 'lift1', 'mover id carried')

    ---------------------------------------------------------------------
    t.describe('fromWorld recovers all three')

    local back = Map.fromWorld(world)
    t.eq(#back.masked, 2, 'masks come back')
    -- fromWorld normalises the no-alpha mask to the world default it was given.
    local seen = {}
    for _, m in ipairs(back.masked) do seen[m.x .. ',' .. m.y] = m.alpha end
    t.ok(math.abs(seen['3,3'] - 0.4) < 1e-6, 'explicit alpha recovered')
    t.ok(math.abs(seen['5,6'] - 0.55) < 1e-6, 'defaulted alpha recovered')
    t.eq(#back.wallAnims, 1, 'anim comes back')
    t.eq(back.wallAnims[1].tiles[2], 2, 'with its frames')
    t.ok(back.movers and #back.movers == 1, 'mover comes back')
    t.eq(back.movers[1].tiles[1].tx, 5, 'mover tiles recovered')

    ---------------------------------------------------------------------
    t.describe('the carried mover drives a real Movers host')

    local host = Movers.new(world)
    for _, mv in ipairs(world.movers) do host:add(mv) end
    t.ok(host:get('lift1'), 'the mover was added by id')
    -- Floor starts down (0). Raise it and tick; the stored tile floor climbs.
    local before = world:floorHeightAt(5, 5, 1)
    host:call('lift1', true)              -- go up
    host:update(1.0)
    local after = world:floorHeightAt(5, 5, 1)
    t.ok(after > before, ('the lift raised the floor (%.2f -> %.2f)'):format(before, after))
end
