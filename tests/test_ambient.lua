--[[
    C31: ambient sound zones. The model reports which zone a point is in
    (smallest wins when they overlap), flags a change only on a transition, and
    the `.map` `ambient` directive round-trips.
]]

return function(t)
    local Ambient = require('meatray.game.ambient')
    local Game = require('meatray.game')
    local Map = require('meatray.sim.map')

    t.eq(Game.ambient, Ambient, 'Game.ambient is the module')

    local zones = {
        { sound = 'cave',    x1 = 0, y1 = 0, x2 = 20, y2 = 20, storey = 1 },
        { sound = 'reactor', x1 = 5, y1 = 5, x2 = 9,  y2 = 9,  storey = 1 },  -- nested, smaller
        { sound = 'upstairs', x1 = 0, y1 = 0, x2 = 20, y2 = 20, storey = 2 },
    }

    ---------------------------------------------------------------------
    t.describe('activeAt picks the smallest covering zone')

    t.eq(Ambient.activeAt(zones, 2.5, 2.5, 1).sound, 'cave', 'in the big room only')
    t.eq(Ambient.activeAt(zones, 7, 7, 1).sound, 'reactor',
         'inside the nested zone, the smaller one wins')
    t.eq(Ambient.activeAt(zones, 30, 30, 1), nil, 'outside every zone')
    t.eq(Ambient.activeAt(zones, 7, 7, 2).sound, 'upstairs',
         'storey is respected — the reactor is on storey 1')

    ---------------------------------------------------------------------
    t.describe('update flags a change only on a transition')

    local amb = Ambient.new(zones)
    local a = amb:update(2.5, 2.5, 1)
    t.eq(a.sound, 'cave', 'entered the cave')
    t.ok(a.changed, 'and that is a change')
    local b = amb:update(3.5, 3.5, 1)
    t.eq(b.sound, 'cave', 'still in the cave')
    t.ok(not b.changed, 'no change while you stay')
    local c = amb:update(7, 7, 1)
    t.eq(c.sound, 'reactor', 'walked into the reactor room')
    t.ok(c.changed, 'a change')
    local d = amb:update(30, 30, 1)
    t.eq(d.sound, nil, 'stepped outside every zone')
    t.ok(d.changed, 'which is also a change (to silence)')
    t.eq(amb:currentSound(), nil, 'current sound is nil outside')

    ---------------------------------------------------------------------
    t.describe('setZones resets so the next update reports a change')

    amb:update(2.5, 2.5, 1)               -- back in the cave
    amb:setZones({ { sound = 'new', x1 = 0, y1 = 0, x2 = 4, y2 = 4, storey = 1 } })
    t.eq(amb:currentSound(), nil, 'forgotten on a map change')
    local e = amb:update(2, 2, 1)
    t.eq(e.sound, 'new', 'picks up the new map\'s zone')
    t.ok(e.changed, 'as a change')

    ---------------------------------------------------------------------
    t.describe('the ambient directive parses and round-trips')

    local text = table.concat({
        'name Amb', 'theme dungeon', 'spawn 2.5 2.5 0',
        'ambient cave 0 0 20 20',
        'ambient reactor 2 5 5 9 9',      -- storey 2
        '---',
        '########',
        '#......#',
        '#......#',
        '########',
    }, '\n')
    local map = assert(Map.parse(text))
    t.eq(#map.ambientZones, 2, 'two zones')
    t.eq(map.ambientZones[1].sound, 'cave', 'sound id kept')
    t.eq(map.ambientZones[2].storey, 2, 'storey parsed')

    local out = Map.serialize(map)
    local re = assert(Map.parse(out))
    t.eq(out, Map.serialize(re), 'serialisation is byte-stable')

    local world = Map.toWorld(map)
    t.ok(world.ambientZones and #world.ambientZones == 2, 'toWorld carries them')
    local back = Map.fromWorld(world)
    t.eq(#back.ambientZones, 2, 'fromWorld recovers them')
    t.eq(back.ambientZones[2].sound, 'reactor', 'with their sound ids')

    -- End to end: a tracker built from the world reports the room.
    local live = Ambient.new(world.ambientZones)
    t.eq(live:update(3, 3, 1).sound, 'cave', 'a point in the world names its room')
end
