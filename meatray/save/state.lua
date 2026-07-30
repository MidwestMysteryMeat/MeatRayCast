--[[
    meatray.save.state — live simulation state to a save document, and back.

    This is the layer that decides *what* a save contains. It contains nothing of
    its own: a world becomes the payload meatray.net.replication already builds
    for a joining client, and an entity becomes the snapshot its components
    already declare through `netFields`. Loading a save and joining a server are
    the same problem — "reconstruct this world on a machine that does not have
    it" — and giving that problem two answers is how they drift.

    That reuse is the point rather than a shortcut. Add `stamina` to a
    component's netFields and it is replicated, and saved, and loaded, with no
    edit here. A hand-written save serialiser would be a second list of fields to
    keep in step with the first, and the failure mode of the two disagreeing is a
    save that loads with one stat missing.

    Two behaviours are inherited deliberately, because a save that disagreed with
    the network about them would be surprising in the worst way:

      * An entity whose archetype this build does not know becomes a positional
        ghost, and is reported. It is not fabricated from the snapshot's
        component list. A game that renamed an archetype between versions gets a
        loud, listed, harmless marker at the right coordinates instead of an
        entity that looks correct and behaves like nothing at all.

      * Components the entity does not carry are ignored, and reported. This is
        entity:applySnapshot's rule and it is right for the same reason: state
        cannot be applied to something that does not exist to hold it, and
        inventing a component to receive it means inventing what it means.

    Restore never touches the caller's world or entity list. It builds a new
    world and a new set of entities, and returns them only if all of it worked —
    so a save that turns out to be broken halfway through costs the load, not the
    session that was running before it.

    HEADLESS: no LOVE. A dedicated server persists state through this module.
]]

local Entity = require('meatray.sim.entity')
local Format = require('meatray.save.format')
local Rep    = require('meatray.net.replication')

local State = {}

local floor = math.floor

---------------------------------------------------------------------------
-- Capture
---------------------------------------------------------------------------

--[[
    Builds a save document from live state.

        local doc = Save.state.capture{
            world     = world,
            entities  = entities,
            progress  = { level = 3, keys = { 'red' } },
            map       = 'arena',
            playTime  = session.elapsed,
            label     = 'Before the boss',
        }

    `worldSpec` is the alternative to storing the grid: pass the table that was
    handed to worldgen and the save keeps a seed instead of a few thousand tiles,
    exactly as a join payload does. It is correct only while the generator keeps
    producing the same world from the same seed, which is a promise across
    machines but not across engine versions — so a save that must survive an
    engine upgrade should store the grid, and that is the default.

    `progress` is the game's, and is never interpreted here. Anything the
    serialiser can carry (nested tables of numbers, strings and booleans) travels
    verbatim; a function or a userdata in there is refused at encode time with a
    message naming it, which is better than a save that silently dropped the
    player's inventory.
]]
function State.capture(opts)
    opts = opts or {}

    if not opts.world then
        return nil, 'a save needs a world'
    end
    if type(opts.world.grid) ~= 'table' or type(opts.world.doors) ~= 'table' then
        return nil, 'the world to save is not a meatray world (no grid or doors)'
    end

    local entities = opts.entities or {}
    if type(entities) ~= 'table' then
        return nil, ('entities must be an array, got %s'):format(type(entities))
    end

    local okWorld, world = pcall(Rep.worldPayload, opts.world, opts.worldSpec)
    if not okWorld then
        return nil, 'the world could not be captured: ' .. tostring(world)
    end

    local snaps, highest = {}, 0
    for i = 1, #entities do
        local e = entities[i]
        -- `dead` and `localOnly` mean the same thing here as on the wire: a
        -- corpse being cleaned up this tick and a client-side muzzle flash are
        -- both state nobody should be handed back on load.
        if type(e) == 'table' and not e.dead and not e.localOnly and e.snapshot then
            local okSnap, snap = pcall(e.snapshot, e)
            if not okSnap then
                return nil, ('entity %s could not be captured: %s')
                            :format(tostring(e.id), tostring(snap))
            end
            snaps[#snaps + 1] = snap
            if type(snap.id) == 'number' and snap.id > highest then highest = snap.id end
        end
    end

    -- The id counter travels so a loaded session does not hand a fresh entity an
    -- id that a loaded one already has. Without it the first thing spawned after
    -- a load can collide with something in the save, and the symptom is one
    -- entity replacing another at random.
    local nextId = floor(highest) + 1

    local meta = {}
    for k, v in pairs(opts.meta or {}) do meta[k] = v end

    -- os.time and os.clock exist under LÖVE and under bare LuaJIT alike. The
    -- clock is injectable so tests are not at the mercy of the wall clock.
    meta.savedAt  = opts.savedAt or (opts.now and opts.now()) or os.time()
    meta.map      = opts.map or opts.world.name or 'unnamed'
    meta.playTime = tonumber(opts.playTime) or 0
    meta.label    = opts.label
    meta.theme    = opts.world.theme
    meta.entities = #snaps
    meta.width    = opts.world.width
    meta.height   = opts.world.height

    return {
        version = Format.VERSION,
        meta = meta,
        body = {
            world    = world,
            entities = snaps,
            progress = opts.progress or {},
            nextId   = nextId,
        },
    }
end

---------------------------------------------------------------------------
-- Restore
---------------------------------------------------------------------------

-- Validates one entity snapshot before anything is built from it. A snapshot
-- that decoded cleanly can still be nonsense — a string where an id belongs, a
-- NaN coordinate — and an entity carrying a NaN position produces a NaN on its
-- next step and then in everything it touches. Rejecting the save is the cheap
-- outcome.
local function checkSnapshot(snap, index)
    if type(snap) ~= 'table' then
        return nil, ('entity %d in this save is a %s, not a table'):format(index, type(snap))
    end
    if Rep.finite(snap.id, 0, 2 ^ 53) == nil then
        return nil, ('entity %d in this save has no usable id (%s)')
                    :format(index, tostring(snap.id))
    end
    if snap.kind ~= nil and type(snap.kind) ~= 'string' then
        return nil, ('entity %d in this save has a %s where its kind belongs')
                    :format(index, type(snap.kind))
    end
    for _, field in ipairs({ 'x', 'y', 'angle' }) do
        if snap[field] ~= nil and Rep.finite(snap[field], -1e9, 1e9) == nil then
            return nil, ('entity %d in this save has an unusable %s (%s)')
                        :format(index, field, tostring(snap[field]))
        end
    end
    if snap.c ~= nil and type(snap.c) ~= 'table' then
        return nil, ('entity %d in this save has a %s where its components belong')
                    :format(index, type(snap.c))
    end
    return true
end

--[[
    Rebuilds live state from a save document.

    Returns a table, or nil plus a message:

        {
            world     = World,
            entities  = { Entity, ... },
            byId      = { [id] = Entity },
            progress  = the game's table, verbatim
            meta      = the save's metadata
            version   = the version it was written at (after migration)
            unknown   = { { id =, kind = }, ... }        archetypes not in this build
            dropped   = { { id =, kind =, component = }, ... }  state with nowhere to go
        }

    `unknown` and `dropped` are always tables and are usually empty. They are
    returned rather than logged because the caller is the only thing that knows
    whether a ghost entity is a broken save or a mod being unloaded on purpose,
    and because a test can assert on a returned list and cannot assert on a print.

    `opts.spawn(kind, x, y, snap)` overrides how an entity is built, matching the
    hook the replication layer takes. `opts.reserveIds = false` leaves the global
    id counter alone, for a caller loading a save into a session that already has
    live entities of its own.
]]
function State.restore(doc, opts)
    opts = opts or {}

    if type(doc) ~= 'table' then
        return nil, ('a save document must be a table, got %s'):format(type(doc))
    end

    local body = doc.body
    if type(body) ~= 'table' then
        return nil, ('this save has a %s where its body belongs'):format(type(body))
    end
    if type(body.world) ~= 'table' then
        return nil, 'this save has no world in it'
    end

    local snaps = body.entities or {}
    if type(snaps) ~= 'table' then
        return nil, ('this save has a %s where its entities belong'):format(type(snaps))
    end

    if body.progress ~= nil and type(body.progress) ~= 'table' then
        return nil, ('this save has a %s where its progress belongs')
                    :format(type(body.progress))
    end

    -- Validate every snapshot before building any of them. Half a world and
    -- three of eleven entities is a state no save describes, and the caller
    -- would have no way back to the session it had before the load.
    for i = 1, #snaps do
        local ok, err = checkSnapshot(snaps[i], i)
        if not ok then return nil, err end
    end

    local world, worldErr = Rep.buildWorld(body.world)
    if not world then
        return nil, 'this save\'s world could not be rebuilt: ' .. tostring(worldErr)
    end

    local unknown, dropped = {}, {}
    local entities, byId = {}, {}

    local built, buildErr = pcall(function()
        for i = 1, #snaps do
            local snap = snaps[i]

            local e = Rep.adopt(snap, {
                spawn = opts.spawn,
                onUnknown = function(kind, id)
                    unknown[#unknown + 1] = { id = id, kind = kind }
                end,
            })

            e:applySnapshot(snap)
            e:snapPrevious()

            -- Which components the save carried that this entity cannot hold.
            -- applySnapshot has already ignored them; this is the report, and it
            -- is the difference between a quiet loss and a visible one.
            for name in pairs(snap.c or {}) do
                if not e:has(name) then
                    dropped[#dropped + 1] = { id = snap.id, kind = snap.kind, component = name }
                end
            end

            entities[#entities + 1] = e
            byId[snap.id] = e
        end
    end)

    if not built then
        -- An archetype's own build function raised. Nothing of the caller's has
        -- been touched, so the load simply does not happen.
        return nil, 'this save could not be rebuilt: ' .. tostring(buildErr)
    end

    if opts.reserveIds ~= false then
        local nextId = Rep.finite(body.nextId, 1, 2 ^ 53)
        if nextId then Entity.resetIds(floor(nextId)) end
    end

    return {
        world    = world,
        entities = entities,
        byId     = byId,
        progress = body.progress or {},
        meta     = doc.meta or {},
        version  = doc.version,
        unknown  = unknown,
        dropped  = dropped,
    }
end

return State
