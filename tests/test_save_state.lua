--[[
    Live state to a save and back.

    The property under test is round-trip fidelity, asserted at the data level
    and through the real file bytes rather than through the capture table alone —
    a save that survives being encoded but not being written is not a save.

    Everything else here is about what a load refuses to invent. The replication
    layer already decided this: a client never fabricates an archetype it does
    not know, and never applies a component an entity does not carry, because an
    entity that looks right and behaves like nothing is worse than a visible
    marker. A save file is the same problem with a longer delay — an archetype
    renamed between versions is exactly the case — so the behaviour must be the
    same, and asserting it is the only way it stays that way.
]]

return function(t)
    local Entity = require('meatray.sim.entity')
    local C      = require('meatray.sim.components')
    local World  = require('meatray.sim.world')
    local Format = require('meatray.save.format')
    local State  = require('meatray.save.state')

    -- Archetypes are a process-wide registry, so this suite borrows it and puts
    -- it back. The same functions exist for hot reload, and for the same reason.
    local borrowed = Entity.captureArchetypes()

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

    local function buildWorld()
        local world = World.new(grid(12, 9), { theme = 'dungeon',
                                               spawn = { x = 2.5, y = 2.5, angle = 0.5 } })
        world.grid[4][5] = 3
        world:addDoor(6, 4, false)
        world:addDoor(8, 6, true)
        return world
    end

    Entity.clearArchetypes()

    Entity.archetype('imp', function(e)
        e:add(C.Billboard{ sheet = 'imp' })
        e:add(C.Health{ hp = 30, max = 30 })
        e:add(C.Motion{ vx = 0, vy = 0 })          -- no netFields: never travels
    end)

    Entity.archetype('crate', function(e)
        e:add(C.Solid{})
    end)

    ---------------------------------------------------------------------------
    t.describe('a captured world and its entities come back identical')

    local world = buildWorld()
    world:setDoorOpen(6, 4, true)
    world:setDoorOpen(8, 6, false)

    local imp = Entity.spawn('imp', 4.25, 3.75)
    imp.angle = 1.25
    imp:get('health').hp = 17
    imp:get('motion').vx = 99                      -- local state, must not survive

    local crate = Entity.spawn('crate', 9.5, 6.5)
    local corpse = Entity.spawn('imp', 2.5, 2.5)
    corpse.dead = true
    local flash = Entity.spawn('crate', 3.5, 3.5)
    flash.localOnly = true

    local entities = { imp, crate, corpse, flash }

    local doc, captureErr = State.capture{
        world = world,
        entities = entities,
        progress = { level = 3, keys = { 'red', 'blue' }, seen = { arena = true },
                     score = 12345.5 },
        map = 'arena',
        playTime = 91.5,
        label = 'Before the boss',
        savedAt = 1700000000,
    }
    t.ok(doc ~= nil, 'state captures', captureErr)

    -- Through the actual file bytes: capture -> encode -> decode -> restore is
    -- the path a real save takes, and it is the one worth asserting on.
    local bytes, encodeErr = Format.encode(doc)
    t.ok(bytes ~= nil, 'the captured state encodes to a file', encodeErr)
    local reloaded, decodeErr = Format.decode(bytes)
    t.ok(reloaded ~= nil, 'and decodes again', decodeErr)

    local state, restoreErr = State.restore(reloaded)
    t.ok(state ~= nil, 'and restores', restoreErr)

    t.describe('the world survives exactly')
    t.eq(state.world.width, world.width, 'width')
    t.eq(state.world.height, world.height, 'height')
    t.eq(state.world.theme, 'dungeon', 'theme')

    local mismatched = 0
    for y = 1, world.height do
        for x = 1, world.width do
            if state.world:tileAt(x, y) ~= world:tileAt(x, y) then
                mismatched = mismatched + 1
            end
        end
    end
    t.eq(mismatched, 0, ('every one of %d tiles matches'):format(world.width * world.height))

    t.describe('door state survives, which is the only mutable part of a world')
    t.ok(state.world:doorAt(6, 4) ~= nil, 'the first door is still a door')
    t.ok(state.world:doorAt(8, 6) ~= nil, 'the second door is still a door')
    t.eq(state.world:doorAt(6, 4).open, true, 'the opened door is still open')
    t.eq(state.world:doorAt(8, 6).open, false, 'the closed door is still closed')
    t.eq(state.world:isSolid(6, 4), false, 'and the open one is still walkable')
    t.eq(state.world:isSolid(8, 6), true, 'and the closed one still blocks')

    t.describe('entities survive, and only the ones that should')
    t.eq(#state.entities, 2, 'the dead entity and the local-only one were not saved')

    local loadedImp = state.byId[imp.id]
    t.ok(loadedImp ~= nil, 'the imp came back under its own id')
    t.eq(loadedImp.kind, 'imp', 'its kind')
    t.eq(loadedImp.x, 4.25, 'its x, bit-exactly')
    t.eq(loadedImp.y, 3.75, 'its y, bit-exactly')
    t.eq(loadedImp.angle, 1.25, 'its angle, bit-exactly')
    t.eq(loadedImp.prevX, loadedImp.x, 'with nothing to interpolate from on load')

    t.eq(loadedImp:get('health').hp, 17, 'a netFields value is restored')
    t.eq(loadedImp:get('health').max, 30, 'and so is the rest of the component')
    t.eq(loadedImp:get('billboard').sheet, 'imp', 'so is a string field')

    -- Motion declares no netFields, so it is not saved and the archetype's own
    -- value is what a loaded entity has. That is the same rule the network
    -- follows, and it is why adding a field to netFields is the only edit needed
    -- to make it persist.
    t.eq(loadedImp:get('motion').vx, 0, 'a component with no netFields is not saved')

    local loadedCrate = state.byId[crate.id]
    t.ok(loadedCrate ~= nil, 'the crate came back')
    t.eq(loadedCrate.x, 9.5, 'at its position')

    t.describe('progress is the game\'s, and travels verbatim')
    t.eq(state.progress.level, 3, 'a number')
    t.eq(state.progress.keys[2], 'blue', 'a nested array')
    t.eq(state.progress.seen.arena, true, 'a nested map')
    t.eq(state.progress.score, 12345.5, 'a float, exactly')

    t.describe('metadata describes the save without opening it')
    t.eq(reloaded.meta.map, 'arena', 'the map name')
    t.eq(reloaded.meta.savedAt, 1700000000, 'the timestamp')
    t.eq(reloaded.meta.playTime, 91.5, 'the play time')
    t.eq(reloaded.meta.label, 'Before the boss', 'the label')
    t.eq(reloaded.meta.entities, 2, 'how many entities are inside')
    t.eq(reloaded.meta.width, 12, 'the world width')

    t.describe('the id counter is carried so a load cannot collide with itself')
    local fresh = Entity.spawn('crate', 1.5, 1.5)
    t.ok(state.byId[fresh.id] == nil,
         'an entity spawned after a load gets an id no loaded entity is using')
    t.ok(fresh.id > imp.id, 'because the counter was moved past the highest saved id')

    t.describe('nothing was reported that should not have been')
    t.eq(#state.unknown, 0, 'no unknown archetypes')
    t.eq(#state.dropped, 0, 'no dropped components')

    ---------------------------------------------------------------------------
    t.describe('a world can be saved as a seed instead of a grid')

    local Worldgen = require('meatray.sim.worldgen')
    local generated = Worldgen.generate{ width = 32, height = 32, seed = 4242 }
    local spec = { width = 32, height = 32, seed = 4242 }

    local specDoc = State.capture{ world = generated, worldSpec = spec, savedAt = 1 }
    local gridDoc = State.capture{ world = generated, savedAt = 1 }

    local specBytes = Format.encode(specDoc)
    local gridBytes = Format.encode(gridDoc)
    t.ok(#specBytes < #gridBytes / 4,
         ('a seed save is far smaller than a grid save (%d vs %d bytes)')
         :format(#specBytes, #gridBytes))

    local specState = State.restore(Format.decode(specBytes))
    t.ok(specState ~= nil, 'a seed save restores')

    local regenMismatch = 0
    for y = 1, generated.height do
        for x = 1, generated.width do
            if specState.world:tileAt(x, y) ~= generated:tileAt(x, y) then
                regenMismatch = regenMismatch + 1
            end
        end
    end
    t.eq(regenMismatch, 0, 'and regenerates the same world tile for tile')

    -- Doors travel either way, because door state is not a function of the seed.
    local anyDoor
    for key in pairs(generated.doors) do anyDoor = key break end
    if anyDoor then
        local tx, ty = anyDoor:match('^(%-?%d+),(%-?%d+)$')
        tx, ty = tonumber(tx), tonumber(ty)
        generated:setDoorOpen(tx, ty, true)
        local openState = State.restore(Format.decode(
            Format.encode(State.capture{ world = generated, worldSpec = spec, savedAt = 1 })))
        t.eq(openState.world:doorAt(tx, ty).open, true,
             'an opened door survives a seed save, which the seed cannot describe')
    else
        t.ok(true, 'this generated world has no doors to open')
    end

    ---------------------------------------------------------------------------
    t.describe('a load refuses to invent an archetype it does not know')

    -- The version-skew case, in full: a save written when 'imp' existed, loaded
    -- by a build where it does not.
    local skewDoc = State.capture{ world = buildWorld(), entities = { imp }, savedAt = 1 }
    local skewBytes = Format.encode(skewDoc)

    Entity.clearArchetypes()

    local ghostState, ghostErr = State.restore(Format.decode(skewBytes))
    t.ok(ghostState ~= nil, 'the save still loads', ghostErr)
    t.eq(#ghostState.entities, 1, 'the entity is still there')

    local ghost = ghostState.byId[imp.id]
    t.eq(ghost.kind, 'imp', 'it remembers what it was meant to be')
    t.eq(ghost.x, 4.25, 'and it is in the right place')
    t.eq(ghost:has('health'), false, 'but it has no health component invented for it')
    t.eq(ghost:has('billboard'), false, 'and no billboard either')

    t.eq(#ghostState.unknown, 1, 'and the load reports exactly one unknown archetype')
    t.eq(ghostState.unknown[1].kind, 'imp', 'naming the archetype')
    t.eq(ghostState.unknown[1].id, imp.id, 'and the entity it belonged to')

    -- The same state the archetype would have carried is in the file. Nothing
    -- read it, which is the point: the loader has nowhere to put it and does not
    -- make somewhere.
    t.eq(#ghostState.dropped, 2,
         'the two components the file carried are reported as dropped')

    t.describe('a load refuses to apply a component the entity does not carry')

    -- The narrower version of the same skew: the archetype still exists, but it
    -- lost a component between the save and the load.
    Entity.clearArchetypes()
    Entity.archetype('imp', function(e)
        e:add(C.Billboard{ sheet = 'imp' })
    end)

    local partialState = State.restore(Format.decode(skewBytes))
    t.ok(partialState ~= nil, 'the save loads')

    local partial = partialState.byId[imp.id]
    t.eq(partial:has('billboard'), true, 'the component that still exists is restored')
    t.eq(partial:get('billboard').sheet, 'imp', 'with its saved value')
    t.eq(partial:has('health'), false, 'the component that no longer exists is not invented')
    t.eq(#partialState.unknown, 0, 'the archetype itself was known')
    t.eq(#partialState.dropped, 1, 'and exactly one component is reported dropped')
    t.eq(partialState.dropped[1].component, 'health', 'named')
    t.eq(partialState.dropped[1].kind, 'imp', 'with the kind that carried it')
    t.eq(partialState.dropped[1].id, imp.id, 'and the entity it belonged to')

    ---------------------------------------------------------------------------
    t.describe('a broken save is refused rather than half-applied')

    Entity.clearArchetypes()
    Entity.archetype('imp', function(e) e:add(C.Health{ hp = 30, max = 30 }) end)

    local function refuse(body, label)
        local broken, err = State.restore({ version = 1, meta = {}, body = body })
        t.ok(broken == nil, label)
        t.ok(type(err) == 'string' and #err > 8, label .. ': with a reason', err)
        return err
    end

    refuse({}, 'a save with no world is refused')
    refuse({ world = 'a string' }, 'a save whose world is a string is refused')
    refuse({ world = { kind = 'grid' } }, 'a world payload with no grid is refused')
    refuse({ world = { kind = 'nonsense' } }, 'an unknown world payload kind is refused')
    refuse({ world = { kind = 'grid', grid = { { 0 } } }, entities = 'nope' },
           'a save whose entities are a string is refused')
    refuse({ world = { kind = 'grid', grid = { { 0 } } }, progress = 7 },
           'a save whose progress is a number is refused')

    local goodWorld = { kind = 'grid', grid = { { 1, 1, 1 }, { 1, 0, 1 }, { 1, 1, 1 } } }

    refuse({ world = goodWorld, entities = { 'not a table' } },
           'an entity that is not a table is refused')
    refuse({ world = goodWorld, entities = { { kind = 'imp', x = 1, y = 1 } } },
           'an entity with no id is refused')
    refuse({ world = goodWorld, entities = { { id = 'four', x = 1, y = 1 } } },
           'an entity whose id is a string is refused')
    refuse({ world = goodWorld, entities = { { id = 1, kind = 4, x = 1, y = 1 } } },
           'an entity whose kind is a number is refused')
    refuse({ world = goodWorld, entities = { { id = 1, x = 0 / 0, y = 1 } } },
           'an entity at a NaN position is refused')
    refuse({ world = goodWorld, entities = { { id = 1, x = 1, y = math.huge } } },
           'an entity at an infinite position is refused')
    refuse({ world = goodWorld, entities = { { id = 1, x = 1, y = 1, angle = 0 / 0 } } },
           'an entity at a NaN angle is refused')
    refuse({ world = goodWorld, entities = { { id = 1, x = 1, y = 1, c = 'nope' } } },
           'an entity whose components are a string is refused')
    refuse({ world = goodWorld, entities = { { id = 1, kind = 'imp', x = 1, y = 1 },
                                             { id = 2, x = 0 / 0, y = 1 } } },
           'one bad entity out of two refuses the whole save')

    t.ok(State.restore(nil) == nil, 'restoring a nil is refused')
    t.ok(State.restore('a string') == nil, 'restoring a string is refused')
    t.ok(State.restore({ version = 1, meta = {} }) == nil, 'restoring a bodiless doc is refused')

    t.describe('an archetype that raises during a load does not escape it')
    Entity.clearArchetypes()
    Entity.archetype('exploder', function() error('this archetype is broken', 0) end)

    local exploded, explodedErr = State.restore({
        version = 1, meta = {},
        body = { world = goodWorld, entities = { { id = 1, kind = 'exploder', x = 1, y = 1 } } },
    })
    t.ok(exploded == nil, 'the load fails instead of the game')
    t.ok(tostring(explodedErr):find('this archetype is broken'),
         'and the reason reaches the caller', explodedErr)

    ---------------------------------------------------------------------------
    t.describe('capture refuses what it cannot save')

    t.ok(State.capture{} == nil, 'capturing without a world is refused')
    t.ok(State.capture{ world = { grid = 'no' } } == nil,
         'capturing something that is not a world is refused')
    t.ok(State.capture{ world = buildWorld(), entities = 'nope' } == nil,
         'capturing with entities that are not an array is refused')

    local functionDoc = State.capture{ world = buildWorld(),
                                       progress = { onLoad = function() end }, savedAt = 1 }
    t.ok(functionDoc ~= nil, 'a function in progress survives capture (it is a plain table)')
    local refused, refusedErr = Format.encode(functionDoc)
    t.ok(refused == nil, 'and is refused at encode time, when the save is written')
    t.ok(tostring(refusedErr):find('function'), 'with the type named', refusedErr)

    ---------------------------------------------------------------------------
    t.describe('G2: a save keeps its locks, half-slid walls and the automap')

    -- The save rides Rep.worldPayload, so this is the same machinery the join
    -- payload test covers — asserted here once through the FULL save document
    -- (capture → encode → decode → restore), because "the wire test passes"
    -- and "the save file works" have diverged before in other engines.
    local g2World = buildWorld()
    g2World:lockDoor(6, 4, 'key.blue')
    g2World.grid[5][3] = 2
    g2World:addPushWall(3, 5, { dx = 1, dy = 0, distance = 2 })
    g2World:pushWall(3, 5)
    g2World:update(0.35)                          -- one tile in, one to go
    g2World.secrets = { { x1 = 2, y1 = 2, x2 = 3, y2 = 3, storey = 1 } }
    g2World.hazards = { { kind = 'slime', x1 = 9, y1 = 2, x2 = 10, y2 = 3, storey = 1 } }

    local Automap = require('meatray.game.automap')
    local am = Automap.new{ radius = 3 }
    am:visit(g2World, 2.5, 2.5)
    local seenBefore = am:seenCount()
    t.ok(seenBefore > 0, 'the automap saw something worth saving')

    local g2doc = State.capture{
        world = g2World, entities = {},
        meta = { automap = am:capture() },
        savedAt = 1700000001,
    }
    t.ok(g2doc, 'the G2 world captures')

    local g2bytes = Format.encode(g2doc)
    local g2decoded = Format.decode(g2bytes)
    local g2restored, g2err = State.restore(g2decoded)
    t.ok(g2restored, 'and the document restores', g2err)

    local rw = g2restored.world
    t.eq(rw:doorLock(6, 4), 'key.blue', 'the lock came back locked')
    t.ok(rw:pushWallAt(4, 5), 'the push-wall is where it had slid to')
    t.eq(rw:pushWallAt(4, 5).left, 1, 'with one tile still owed')
    t.eq(rw.secrets[1].x1, 2, 'the secret box came back')
    t.eq(rw.hazards[1].kind, 'slime', 'and the hazard')

    local am2 = Automap.new()
    am2:restore(g2restored.meta and g2restored.meta.automap
                or g2decoded.body.meta.automap)
    t.eq(am2:seenCount(), seenBefore, 'the automap memory rode the meta pocket')

    ---------------------------------------------------------------------------
    Entity.restoreArchetypes(borrowed)
end
