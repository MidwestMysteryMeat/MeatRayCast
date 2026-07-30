--[[
    Archetype capture and restore, which is what makes hot reload safe to attempt.

    The property that matters: a definition file that raises halfway through must
    leave the registry exactly as it was. A reload that can half-apply is worse
    than no reload, because the game keeps running in a state no file describes and
    the next bug report is unreproducible.

    The reload module itself needs LÖVE (it reads files and touches the sprite
    registry), so what is tested here is the capture/restore contract underneath
    it, which is pure.
]]

return function(t)
    local Entity = require('meatray.sim.entity')

    t.describe('capture and restore round-trip')
    Entity.clearArchetypes()

    Entity.archetype('goblin', function(e) e.marker = 'goblin' end)
    Entity.archetype('troll', function(e) e.marker = 'troll' end)

    local names = Entity.archetypeNames()
    t.eq(#names, 2, 'two archetypes registered')
    t.eq(names[1], 'goblin', 'names come back sorted')
    t.eq(names[2], 'troll', 'both present')

    local captured = Entity.captureArchetypes()

    Entity.clearArchetypes()
    t.eq(#Entity.archetypeNames(), 0, 'clearing empties the registry')
    t.ok(not Entity.hasArchetype('goblin'), 'and the archetype is gone')

    Entity.restoreArchetypes(captured)
    t.eq(#Entity.archetypeNames(), 2, 'restore brings them back')
    t.ok(Entity.hasArchetype('goblin'), 'by name')

    -- Restored factories must still build, not merely exist. A capture that kept
    -- names but lost the closures would pass a existence check and fail at spawn.
    local built = Entity.spawn('goblin', 1, 1)
    t.ok(built ~= nil, 'a restored archetype still spawns')
    t.eq(built.marker, 'goblin', 'and runs its original build function')
    t.eq(built.kind, 'goblin', 'with the right kind')

    t.describe('restore replaces rather than merges')
    Entity.clearArchetypes()
    Entity.archetype('ghost', function() end)
    Entity.restoreArchetypes(captured)
    t.ok(not Entity.hasArchetype('ghost'),
         'an archetype defined after the capture is not kept')
    t.ok(Entity.hasArchetype('troll'), 'and the captured ones are')

    t.describe('capture is a snapshot, not a live view')
    local snapshot = Entity.captureArchetypes()
    Entity.archetype('wraith', function() end)
    t.ok(Entity.hasArchetype('wraith'), 'the registry has the new archetype')
    t.eq(snapshot.wraith, nil, 'but the earlier snapshot does not')

    Entity.restoreArchetypes(snapshot)
    t.ok(not Entity.hasArchetype('wraith'),
         'restoring the snapshot removes what came after it')

    t.describe('empty and nil are handled')
    Entity.restoreArchetypes({})
    t.eq(#Entity.archetypeNames(), 0, 'restoring an empty capture empties the registry')

    Entity.restoreArchetypes(nil)
    t.eq(#Entity.archetypeNames(), 0, 'restoring nil is not an error')

    -- Leave the registry clean for whatever runs next.
    Entity.clearArchetypes()
end
