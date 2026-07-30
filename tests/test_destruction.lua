--[[
    Destructible tiles.

    The cases worth having are the ones where destruction interacts with
    something that already existed: a door that gets blown up must stop being a
    door, a destroyed tile must stop blocking rays and movement, and the
    revision counter must move exactly when derived geometry would need
    rebuilding and not otherwise. Getting "wall takes damage and disappears"
    right is easy; those three are where it goes quietly wrong.
]]

return function(t)
    local World = require('meatray.sim.world')

    -- A 6x6 room with a solid border and one interior pillar at (3,3).
    local function room()
        local grid = {}
        for y = 1, 6 do
            grid[y] = {}
            for x = 1, 6 do
                local border = (x == 1 or y == 1 or x == 6 or y == 6)
                grid[y][x] = border and 1 or 0
            end
        end
        grid[3][3] = 1
        return World.new(grid)
    end

    ---------------------------------------------------------------------
    t.describe('nothing is destructible until it is said to be')

    local w = room()
    t.eq(w:isDestructible(3, 3), false, 'a plain wall is not destructible')

    local destroyed, hp = w:damageTile(3, 3, 9999)
    t.eq(destroyed, false, 'damage to an ordinary wall does nothing')
    t.eq(hp, nil, 'and reports no hit points')
    t.eq(w:isSolid(3, 3), true, 'the wall is still standing')
    t.eq(w.revision, 0, 'and nothing invalidated derived geometry')

    -- Splashing damage across a whole room must be legal, including onto empty
    -- floor and past the edge of the map, because that is what an explosion does.
    t.eq(w:damageTile(2, 2, 50), false, 'damaging empty floor is not an error')
    t.eq(w:damageTile(-4, 99, 50), false, 'damaging out of bounds is not an error')

    t.eq(w:setDestructible(2, 2, 10), false, 'empty floor cannot be made destructible')
    t.eq(w:setDestructible(3, 3, 10), true, 'a solid wall can be')

    ---------------------------------------------------------------------
    t.describe('damage accumulates, then the wall comes down')

    local d, left = w:damageTile(3, 3, 4)
    t.eq(d, false, 'a partial hit does not destroy')
    t.eq(left, 6, 'and reports what is left')
    t.eq(w:isSolid(3, 3), true, 'the wall still blocks')
    t.eq(w.revision, 0, 'a wall that merely took damage did not change the grid')

    d, left = w:damageTile(3, 3, 6)
    t.eq(d, true, 'the hit that takes it to zero destroys')
    t.eq(left, 0, 'with nothing remaining')
    t.eq(w:tileAt(3, 3), World.RUBBLE, 'the tile becomes rubble')
    t.eq(w:isSolid(3, 3), false, 'rubble does not block rays')
    t.eq(w:isWalkable(3, 3), true, 'and can be walked over')
    t.eq(w.revision, 1, 'destruction bumped the revision exactly once')

    t.eq(w:isDestructible(3, 3), false, 'a destroyed tile is no longer destructible')
    t.eq(w:damageTile(3, 3, 100), false, 'and shrugs off further damage')
    t.eq(w.revision, 1, 'which did not bump the revision again')

    ---------------------------------------------------------------------
    t.describe('destroying a door stops it being a door')

    -- This is the case that bites. A door tracked in the side table but whose
    -- tile is now a hole would keep animating, and isSolid would consult a door
    -- record for a tile that no longer has one.
    local dw = room()
    dw.grid[4][2] = World.DOOR
    dw:addDoor(2, 4, false)
    t.ok(dw:doorAt(2, 4) ~= nil, 'the door exists')
    t.eq(dw:isSolid(2, 4), true, 'and blocks while shut')

    dw:setDestructible(2, 4, 5)
    t.eq(dw:damageTile(2, 4, 5), true, 'the door can be blown open')
    t.eq(dw:doorAt(2, 4), nil, 'the door record is gone')
    t.eq(dw:tileAt(2, 4), World.RUBBLE, 'and the tile is rubble')
    t.eq(dw:isSolid(2, 4), false, 'which does not block')

    -- The animation loop must not trip over the removed door.
    local okUpdate = pcall(function() dw:update(0.016) end)
    t.eq(okUpdate, true, 'the door animation survives a destroyed door')

    ---------------------------------------------------------------------
    t.describe('repair is the inverse')

    local r = room()
    r:setDestructible(3, 3, 10)
    r:destroyTile(3, 3)
    t.eq(r:tileAt(3, 3), World.RUBBLE, 'destroyed')
    t.eq(r.revision, 1, 'one change')

    t.eq(r:repairTile(3, 3, 10), true, 'repair reports success')
    t.eq(r:tileAt(3, 3), 1, 'and puts back the tile that was there')
    t.eq(r:isSolid(3, 3), true, 'which blocks again')
    t.eq(r.revision, 2, 'and counts as another change to derived geometry')

    t.eq(r:repairTile(3, 3), false, 'repairing an intact tile does nothing')
    t.eq(r.revision, 2, 'and does not bump the revision')

    -- Repair restores the original code, not a generic wall. A map with several
    -- wall textures would otherwise be quietly repainted by combat.
    local textured = room()
    textured.grid[3][3] = 7
    textured:setDestructible(3, 3, 1)
    textured:destroyTile(3, 3)
    textured:repairTile(3, 3)
    t.eq(textured:tileAt(3, 3), 7, 'the original wall texture comes back')

    ---------------------------------------------------------------------
    t.describe('tile changes travel as differences from the authored map')

    local a = room()
    a:setDestructible(3, 3, 1)
    a:setDestructible(1, 2, 1)

    t.eq(next(a:tileSnapshot()), nil, 'an untouched world sends nothing')

    a:destroyTile(3, 3)
    local snap = a:tileSnapshot()
    t.eq(snap['3,3'], 1, 'a destroyed tile appears in the snapshot')
    t.eq(snap['1,2'], nil, 'an intact one does not')

    -- Applying to a fresh copy of the same map must reproduce it exactly.
    local b = room()
    b:applyTileSnapshot(snap)
    t.eq(b:tileAt(3, 3), World.RUBBLE, 'the receiver destroys the same tile')
    t.eq(b:isSolid(3, 3), false, 'and agrees it no longer blocks')
    t.eq(b.revision, 1, 'and knows its geometry changed')

    ---------------------------------------------------------------------
    t.describe('applying a snapshot is idempotent and does not invent state')

    local before = b.revision
    b:applyTileSnapshot(snap)
    t.eq(b.revision, before, 'applying the same snapshot twice changes nothing')

    -- A snapshot naming a tile outside the map must be ignored rather than
    -- indexing nil. A client that trusts the host still must not crash on a
    -- malformed or stale packet.
    local okBad = pcall(function()
        b:applyTileSnapshot({ ['99,99'] = 1, ['-3,2'] = 1, ['garbage'] = 1 })
    end)
    t.eq(okBad, true, 'out of bounds and malformed keys are ignored, not fatal')

    -- Absence means intact: a tile that dropped out of the snapshot is repaired,
    -- so a client joining mid-round and a client that was there converge.
    b:applyTileSnapshot({ ['3,3'] = 0 })
    t.eq(b:tileAt(3, 3), 1, 'clearing an entry repairs the tile')

    ---------------------------------------------------------------------
    t.describe('a game is told when a wall falls')

    local h = room()
    local calls = {}
    h.onDestroy = function(world, tx, ty, was)
        calls[#calls + 1] = { tx = tx, ty = ty, was = was, tile = world:tileAt(tx, ty) }
    end

    h.grid[3][3] = 4
    h:setDestructible(3, 3, 2)
    h:damageTile(3, 3, 1)
    t.eq(#calls, 0, 'damage that does not destroy fires nothing')

    h:damageTile(3, 3, 1)
    t.eq(#calls, 1, 'the killing blow fires once')
    t.eq(calls[1].tx, 3, 'with the tile x')
    t.eq(calls[1].ty, 3, 'and the tile y')
    t.eq(calls[1].was, 4, 'and the tile code that was there, for choosing debris')
    t.eq(calls[1].tile, World.RUBBLE,
         'and the world is already updated when it fires, not mid-change')

    h:damageTile(3, 3, 50)
    t.eq(#calls, 1, 'hitting the hole again fires nothing')

    -- Repair then destroy again is a second event, not a duplicate suppressed.
    h:repairTile(3, 3, 1)
    h:destroyTile(3, 3)
    t.eq(#calls, 2, 'destroying a repaired wall fires again')

    -- The hook also fires when the change arrived over the wire, so a client
    -- spawns its own debris without any of it being replicated.
    local remote = room()
    local remoteCalls = 0
    remote.onDestroy = function() remoteCalls = remoteCalls + 1 end
    remote:applyTileSnapshot({ ['3,3'] = 1 })
    t.eq(remoteCalls, 1, 'applying a world delta fires the hook on the receiver')

    ---------------------------------------------------------------------
    t.describe('destruction does not disturb door replication')

    -- The two channels are separate on purpose; a change to one must not be
    -- visible in the other.
    local c = room()
    c.grid[4][2] = World.DOOR
    c:addDoor(2, 4, false)
    c:setDestructible(3, 3, 1)
    c:destroyTile(3, 3)

    t.eq(c:snapshot()['2,4'], 0, 'the door snapshot still reports the door')
    t.eq(c:snapshot()['3,3'], nil, 'and says nothing about a destroyed wall')
    t.eq(c:tileSnapshot()['2,4'], nil, 'the tile snapshot says nothing about the door')
end
