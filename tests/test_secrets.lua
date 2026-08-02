--[[
    A6: locked doors, push-walls, secret areas — and the map headers that
    declare all three surviving a round-trip.
]]

return function(t)
    local World     = require('meatray.sim.world')
    local Map       = require('meatray.sim.map')
    local Entity    = require('meatray.sim.entity')
    local C         = require('meatray.sim.components')
    local Secrets   = require('meatray.game.secrets')
    local Inventory = require('meatray.game.inventory')
    local Game      = require('meatray.game')

    t.eq(Game.secrets, Secrets, 'Game.secrets is the secrets module')

    local function grid(w, h)
        local g = {}
        for y = 1, h do
            g[y] = {}
            for x = 1, w do
                g[y][x] = (x == 1 or y == 1 or x == w or y == h) and 1 or 0
            end
        end
        return g
    end

    ---------------------------------------------------------------------
    t.describe('a locked door refuses until unlocked')

    local w = World.new(grid(8, 8))
    w:addDoor(4, 4, false)
    t.eq(w:lockDoor(4, 4, 'key.red'), true, 'lock takes')
    t.eq(w:doorLock(4, 4), 'key.red', 'and reads back')

    local ok, why = w:toggleDoor(4, 4)
    t.eq(ok, false, 'locked door does not toggle open')
    t.eq(why, 'locked', 'and says why')
    ok, why = w:setDoorOpen(4, 4, true)
    t.eq(ok, false, 'setDoorOpen respects the lock too')
    t.eq(w:doorAt(4, 4).open, false, 'still shut')

    t.eq(w:unlockDoor(4, 4), true, 'unlock takes')
    t.eq(w:toggleDoor(4, 4), true, 'and the door opens')

    -- A door that is somehow open while locked may always close.
    w:lockDoor(4, 4, 'key.red')
    t.eq(w:setDoorOpen(4, 4, false), true, 'closing a locked-open door works')

    t.eq(select(2, w:lockDoor(2, 2)), 'no door', 'locking a wall refuses')

    ---------------------------------------------------------------------
    t.describe('tryDoor: where lock meets inventory')

    Game.reset()
    local player = Entity.new{}
    player.x, player.y = 3.5, 3.5
    player:add(C.Player{ peerId = 0, name = 'tester' })
    Inventory.attach(player, { capacity = 4 })

    local opened, reason, keyId = Secrets.tryDoor(w, player, 4, 4)
    t.eq(opened, false, 'no key, no entry')
    t.eq(reason, 'locked', 'refusal is a lock')
    t.eq(keyId, 'key.red', 'and names the key the HUD should ask for')

    Inventory.add(player, 'key.red', 1)
    opened, reason = Secrets.tryDoor(w, player, 4, 4)
    t.eq(opened, true, 'key in hand, door opens')
    t.eq(reason, 'unlocked', 'and reports the unlock')
    t.eq(w:doorLock(4, 4), nil, 'the lock is gone for good')
    t.eq(Inventory.count(player, 'key.red'), 1, 'the key is not consumed')

    opened = Secrets.tryDoor(w, player, 4, 4)
    t.eq(opened, true, 'an unlocked door just toggles')

    -- Consumable passes are opt-in.
    w:addDoor(5, 4, false)
    w:lockDoor(5, 4, 'key.red')
    opened = select(1, Secrets.tryDoor(w, player, 5, 4, 1, { consume = true }))
    t.eq(opened, true, 'consumable unlock opens')
    t.eq(Inventory.count(player, 'key.red'), 0, 'and spends the key')

    t.eq(select(2, Secrets.tryDoor(w, player, 2, 2)), 'no door',
         'trying a wall says so')

    ---------------------------------------------------------------------
    t.describe('push-walls slide tile by tile')

    local pw = World.new(grid(10, 10))
    pw.grid[5][5] = 2                       -- a wall mid-room
    t.eq(pw:addPushWall(5, 5, { dx = 1, dy = 0, distance = 2 }), true,
         'push-wall registers on a solid tile')
    t.eq(select(2, pw:addPushWall(3, 3, { dx = 1, dy = 0 })),
         'push-wall needs a solid wall tile', 'empty tile refuses')
    t.eq(select(2, pw:addPushWall(5, 5, { dx = 1, dy = 1 })),
         'push-wall direction must be one axis, one tile', 'diagonals refuse')

    local shapeEvents = 0
    pw:watchShape(function() shapeEvents = shapeEvents + 1 end)

    t.eq(pw:pushWall(5, 5), true, 'the push starts')
    t.eq(pw:isSolid(5, 5), true, 'wall still solid before the first step')

    pw:update(0.35)                          -- one interval: one tile
    t.eq(pw:isSolid(5, 5), false, 'origin opens after a step')
    t.eq(pw:isSolid(6, 5), true, 'the wall now stands one tile over')
    t.eq(pw.grid[5][6], 2, 'and kept its texture')
    t.eq(shapeEvents, 2, 'both tiles announced the change')

    pw:update(0.35)                          -- second tile: distance spent
    t.eq(pw:isSolid(7, 5), true, 'came to rest two tiles out')
    t.eq(pw:isSolid(6, 5), false, 'the path behind it is open')
    t.eq(pw:pushWallAt(7, 5).moving, false, 'and it stopped')

    pw:update(1)                             -- long idle: nothing else moves
    t.eq(pw:isSolid(7, 5), true, 'a spent push-wall stays put')

    -- A push into a wall refuses before it starts.
    pw.grid[3][2] = 1                        -- against the west boundary
    pw:addPushWall(2, 3, { dx = -1, dy = 0 })
    local started, blockedWhy = pw:pushWall(2, 3)
    t.eq(started, false, 'pushing into the boundary refuses')
    t.eq(blockedWhy, 'blocked', 'with the reason')

    ---------------------------------------------------------------------
    t.describe('secret areas: standing inside is finding')

    local s = Secrets.new()
    t.eq(s:percent(), 100, 'a map with no secrets is 100% found')

    local foundLog = {}
    s.onFound = function(area, e) foundLog[#foundLog + 1] = area.name end
    s:addArea{ x1 = 2, y1 = 2, x2 = 4, y2 = 4, name = 'stash' }
    s:addArea{ x1 = 8, y1 = 8, x2 = 9, y2 = 9, name = 'vault', storey = 2 }
    t.eq(s:total(), 2, 'two areas registered')

    local imp = Entity.new{}
    imp.x, imp.y = 3, 3                      -- inside, but not a player
    s:update({ imp })
    t.eq(s:found(), 0, 'monsters do not find secrets')

    player.x, player.y = 3, 3
    t.eq(s:update({ imp, player }), 1, 'a player inside finds one')
    t.eq(s:found(), 1, 'counted')
    t.eq(s:percent(), 50, 'half found')
    t.eq(foundLog[1], 'stash', 'onFound fired with the area')

    s:update({ player })
    t.eq(s:found(), 1, 'standing there twice is still one find')

    player.x, player.y = 8.5, 8.5            -- right box, wrong storey
    s:update({ player })
    t.eq(s:found(), 1, 'storey 1 feet do not find a storey 2 room')
    player.storey = 2
    s:update({ player })
    t.eq(s:percent(), 100, 'right storey finds it')

    local saved = s:capture()
    local s2 = Secrets.new()
    s2:addArea{ x1 = 2, y1 = 2, x2 = 4, y2 = 4, name = 'stash' }
    s2:addArea{ x1 = 8, y1 = 8, x2 = 9, y2 = 9, name = 'vault', storey = 2 }
    s2:restore(saved)
    t.eq(s2:found(), 2, 'discovery survives a save round-trip')

    ---------------------------------------------------------------------
    t.describe('map headers declare all three and round-trip')

    local SAMPLE = table.concat({
        'name  Secret Test',
        'theme dungeon',
        'spawn 2.5 2.5 0',
        'lock 6 3 key.red',
        'pushwall 4 5 0 1 2',
        'secret 6 6 8 8 treasure room',
        '---',
        '##########',
        '#........#',
        '#...#D...#',
        '#........#',
        '#..#.....#',
        '#........#',
        '#........#',
        '#........#',
        '#........#',
        '##########',
    }, '\n')

    local map, errs = Map.parse(SAMPLE)
    t.ok(map, 'map parses' .. (map and '' or (': ' .. table.concat(errs or {}, '; '))))
    t.eq(#(map.locks or {}), 1, 'one lock header')
    t.eq(map.locks[1].key, 'key.red', 'lock key kept')
    t.eq(#(map.pushWalls or {}), 1, 'one pushwall header')
    t.eq(map.pushWalls[1].distance, 2, 'pushwall distance kept')
    t.eq(#(map.secrets or {}), 1, 'one secret header')
    t.eq(map.secrets[1].name, 'treasure room', 'secret name kept, spaces and all')

    local world = Map.toWorld(map)
    t.eq(world:doorLock(6, 3), 'key.red', 'toWorld locks the door')
    t.ok(world:pushWallAt(4, 5), 'toWorld places the push-wall')
    t.eq(#world.secrets, 1, 'toWorld carries the secret area')

    local adopted = Secrets.new()
    t.eq(adopted:fromWorld(world), 1, 'fromWorld adopts the declared area')

    local text = Map.serialize(Map.fromWorld(world, { name = 'Secret Test' }))
    local again, errs2 = Map.parse(text)
    t.ok(again, 'serialized map re-parses'
         .. (again and '' or (': ' .. table.concat(errs2 or {}, '; '))))
    t.eq(#(again.locks or {}), 1, 'lock survives the round-trip')
    t.eq(again.locks[1].key, 'key.red', 'with its key')
    t.eq(#(again.pushWalls or {}), 1, 'pushwall survives')
    t.eq(again.pushWalls[1].dy, 1, 'with its direction')
    t.eq(#(again.secrets or {}), 1, 'secret survives')
    t.eq(again.secrets[1].name, 'treasure room', 'named')

    Game.reset()
end
