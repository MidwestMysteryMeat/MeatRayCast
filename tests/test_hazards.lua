--[[
    F5: hazards — the bite is accumulated and gated, the slow is a question,
    the grace resets on dry land, and the map header round-trips.
]]

return function(t)
    local Hazards = require('meatray.game.hazards')
    local Map     = require('meatray.sim.map')
    local Entity  = require('meatray.sim.entity')
    local Game    = require('meatray.game')

    t.eq(Game.hazards, Hazards, 'Game.hazards is the hazards module')

    Game.reset()
    local STEP = 1 / 60

    local function swimmer(hp)
        local e = Entity.new{}
        e.x, e.y = 5, 5
        Game.attach(e, {
            authority = true,
            attributes = { healthMax = 100, health = hp or 100 },
        })
        return e
    end

    ---------------------------------------------------------------------
    t.describe('zones: registration and lookup')

    local hz = Hazards.new()
    t.ok(hz:addZone{ kind = 'lava', x1 = 4, y1 = 4, x2 = 8, y2 = 6 }, 'lava registers')
    t.ok(hz:addZone{ kind = 'water', x1 = 10, y1 = 10, x2 = 6, y2 = 12 },
         'corner order does not matter')
    t.eq(select(2, hz:addZone{ kind = 'acid', x1 = 0, y1 = 0, x2 = 1, y2 = 1 }),
         'unknown hazard kind: acid', 'unknown kinds refuse')
    t.eq(hz:count(), 2, 'two zones live')
    t.eq(#hz:zonesAt(5, 5), 1, 'a point inside finds its zone')
    t.eq(#hz:zonesAt(20, 20), 0, 'a point outside finds none')

    ---------------------------------------------------------------------
    t.describe('the slow is a question, and overlaps multiply')

    local e = swimmer()
    t.eq(hz:speedFactor(e), 1, 'dry land is full speed')

    hz:update({ e }, STEP)
    t.near(hz:speedFactor(e), 0.7, 1e-9, 'lava slows to its factor')
    t.eq(hz:standingIn(e), 'lava', 'and names itself')

    local overlap = Hazards.new()
    overlap:addZone{ kind = 'water', x1 = 0, y1 = 0, x2 = 10, y2 = 10 }
    overlap:addZone{ kind = 'slime', x1 = 0, y1 = 0, x2 = 10, y2 = 10 }
    local both = swimmer()
    overlap:update({ both }, STEP)
    t.near(overlap:speedFactor(both), 0.55 * 0.80, 1e-9, 'overlaps multiply')
    t.eq(overlap:standingIn(both), 'slime', 'the worst kind speaks for the spot')

    ---------------------------------------------------------------------
    t.describe('the bite: accumulated, rate-independent, graced')

    local pool = Hazards.new()
    pool:addZone{ kind = 'lava', x1 = 0, y1 = 0, x2 = 10, y2 = 10 }
    local victim = swimmer()

    -- Under half an interval: no bite yet — crossing a sliver is free.
    local bites = {}
    for _ = 1, 12 do                            -- 0.2s at 60 Hz
        local b = pool:update({ victim }, STEP)
        for i = 1, #b do bites[#bites + 1] = b[i] end
    end
    t.eq(#bites, 0, 'the first moments of contact are free')
    t.eq(Game.attributes.get(victim, 'health'), 100, 'not a point lost')

    -- Stand in it for two seconds: 2 / 0.5s interval = 4 bites of 16.
    for _ = 13, 120 do
        local b = pool:update({ victim }, STEP)
        for i = 1, #b do bites[#bites + 1] = b[i] end
    end
    t.eq(#bites, 4, 'two seconds of lava is four bites')
    t.eq(Game.attributes.get(victim, 'health'), 100 - 4 * 16, 'each for full damage')
    t.eq(bites[1].kind, 'lava', 'attributed to the zone')

    -- Step out: the grace resets, so dipping is never charged.
    victim.x = 20
    pool:update({ victim }, STEP)
    victim.x = 5
    local afterDip = {}
    for _ = 1, 24 do                            -- 0.4s, just under interval
        local b = pool:update({ victim }, STEP)
        for i = 1, #b do afterDip[#afterDip + 1] = b[i] end
    end
    t.eq(#afterDip, 0, 'back in after a dip, the grace starts over')

    ---------------------------------------------------------------------
    t.describe('everything that gates damage gates hazards')

    local shielded = swimmer()
    Game.respawn.protect(shielded, 60)
    local sb = {}
    for _ = 1, 60 do
        local b = pool:update({ shielded }, STEP)
        for i = 1, #b do sb[#sb + 1] = b[i] end
    end
    t.ok(#sb > 0, 'the lava tried')
    t.eq(sb[1].result, nil, 'and was refused')
    t.ok(tostring(sb[1].reason):find('immune'), 'by the immunity, not by luck')
    t.eq(Game.attributes.get(shielded, 'health'), 100, 'shield holds in lava')

    -- Water never bites anyone.
    local wet = Hazards.new()
    wet:addZone{ kind = 'water', x1 = 0, y1 = 0, x2 = 10, y2 = 10 }
    local floater = swimmer()
    for _ = 1, 180 do wet:update({ floater }, STEP) end
    t.eq(Game.attributes.get(floater, 'health'), 100, 'water only slows')

    -- The dead are past hurting.
    local corpse = swimmer()
    corpse.dead = true
    local cb = pool:update({ corpse }, 10)
    t.eq(#cb, 0, 'a corpse in lava is scenery')

    ---------------------------------------------------------------------
    t.describe('the hazard header rides the map like a secret does')

    local SAMPLE = table.concat({
        'name  Hot Floor',
        'theme dungeon',
        'spawn 2.5 2.5 0',
        'hazard lava 4 4 8 6',
        'hazard water 2 10 10 12 12',
        '---',
        '##############',
        '#............#',
        '#............#',
        '#............#',
        '#............#',
        '#............#',
        '#............#',
        '##############',
        '---',
        '##############',
        '#............#',
        '#............#',
        '#............#',
        '#............#',
        '#............#',
        '#............#',
        '##############',
    }, '\n')

    local map, errs = Map.parse(SAMPLE)
    t.ok(map, 'map parses'
         .. (map and '' or (': ' .. table.concat(errs or {}, '; '))))
    t.eq(#(map.hazards or {}), 2, 'both headers read')
    t.eq(map.hazards[1].kind, 'lava', 'kind kept')
    t.eq(map.hazards[2].storey, 2, 'the storey form reads')

    local world = Map.toWorld(map)
    t.eq(#world.hazards, 2, 'toWorld carries them')

    local adopted = Hazards.new()
    t.eq(adopted:fromWorld(world), 2, 'fromWorld adopts them')
    t.eq(#adopted:zonesAt(5, 5, 1), 1, 'the lava is where the header said')
    t.eq(#adopted:zonesAt(11, 11, 2), 1, 'and the water on its storey')

    local text = Map.serialize(Map.fromWorld(world))
    local again = Map.parse(text)
    t.eq(#(again.hazards or {}), 2, 'hazards survive the round-trip')
    t.eq(again.hazards[1].kind, 'lava', 'with their kinds')
    t.eq(again.hazards[2].storey, 2, 'and their storeys')

    Game.reset()
end
