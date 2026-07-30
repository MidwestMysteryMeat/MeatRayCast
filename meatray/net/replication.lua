--[[
    meatray.net.replication — turning simulation state into messages and back.

    This module owns the three conversions the network needs and nothing else, so
    that host and client share one implementation of each rather than two that
    drift:

      * entities  -> snapshots, and snapshots -> entities, reconciling spawns and
                     despawns from full state.
      * a world   -> a join payload, and back, from either a grid or a seed.
      * an input  -> movement, run identically on the host (authoritatively) and
                     on the client (as prediction).

    That last one is the important one. If the host integrated movement one way
    and the client predicted it another, every step would produce a small
    disagreement that the correction code would then hide — and a prediction bug
    that is being continuously papered over is a bug you find in playtesting, not
    in a test. One function, called from both sides.

    Two rules the snapshot path deliberately keeps:

      * The wire format is whatever netFields says. Nothing here names a
        component or a field. Add 'stamina' to a component's netFields and it
        replicates; there is no serialiser here to update.
      * A client never invents state it was not given. entity:applySnapshot
        ignores components the entity does not carry, and adopt() refuses to
        fabricate an archetype it does not know — it makes a positional ghost and
        says so, because an entity silently missing its collision or its health is
        a worse outcome than a visible warning.

    HEADLESS: no LOVE. This is the layer the loopback tests exercise.
]]

local Entity   = require('meatray.sim.entity')
local World    = require('meatray.sim.world')
local Collide  = require('meatray.sim.collide')
local Worldgen = require('meatray.sim.worldgen')

local Rep = {}

-- Ids below this belong to the host; a client rebases its own counter to here on
-- join so anything it spawns locally (a muzzle flash, a decal, a debug marker)
-- can never collide with an authoritative id. Ids are never negotiated at
-- runtime, which is one round trip and one race condition avoided.
Rep.CLIENT_ID_BASE = 1000000

Rep.DEFAULT_MOVE_SPEED = 3.2
Rep.DEFAULT_TURN_SPEED = 2.6

---------------------------------------------------------------------------
-- Input -> movement, the same code on both sides
---------------------------------------------------------------------------

-- Clamps an intent to something a legitimate client could have sent. The host
-- runs this on input that arrived over the network, so a peer claiming
-- forward = 900 gets forward = 1 rather than a teleport. Cheap, and it is the
-- difference between "clients send inputs" being a security property and being
-- a naming convention.
function Rep.sanitiseInput(input)
    if type(input) ~= 'table' then return nil end

    local function unit(v)
        v = tonumber(v) or 0
        if v ~= v then return 0 end          -- NaN
        if v > 1 then return 1 end
        if v < -1 then return -1 end
        return v
    end

    local out = {
        seq     = tonumber(input.seq) or 0,
        forward = unit(input.forward),
        strafe  = unit(input.strafe),
        turn    = unit(input.turn),
    }

    local angle = tonumber(input.angle)
    if angle and angle == angle and angle ~= math.huge and angle ~= -math.huge then
        out.angle = angle
    end

    -- A diagonal must not be faster than a straight line.
    local mag = math.sqrt(out.forward * out.forward + out.strafe * out.strafe)
    if mag > 1 then
        out.forward, out.strafe = out.forward / mag, out.strafe / mag
    end

    return out
end

-- Applies one tick of intent to an entity. `angle` is taken verbatim: aim is an
-- input, not a simulation result, and a host that integrated turn rates instead
-- would give every client a mouse that lags. Position is never taken from a
-- client; it is always the result of running this against the world.
function Rep.applyInput(e, input, dt, world, opts)
    if not e or not input then return 0, false end
    opts = opts or {}

    if input.angle then
        e.angle = input.angle
    elseif input.turn and input.turn ~= 0 then
        e.angle = e.angle + input.turn * (opts.turnSpeed or Rep.DEFAULT_TURN_SPEED) * dt
    end

    local forward, strafe = input.forward or 0, input.strafe or 0
    if forward == 0 and strafe == 0 then return 0, false end

    local speed = opts.moveSpeed or Rep.DEFAULT_MOVE_SPEED
    local cos, sin = math.cos(e.angle), math.sin(e.angle)
    local dx = (cos * forward - sin * strafe) * speed * dt
    local dy = (sin * forward + cos * strafe) * speed * dt

    return Collide.move(e, dx, dy, world)
end

---------------------------------------------------------------------------
-- Entities -> snapshots
---------------------------------------------------------------------------

-- Full state, not a delta. A full snapshot is self-correcting: a client that
-- missed a packet is right again on the next one with no repair protocol, and
-- despawns need no message of their own because an entity absent from the
-- snapshot is an entity that is gone. Delta compression is a bandwidth
-- optimisation to add later, behind this same function, and it is not free —
-- deltas need acknowledgement tracking per peer, which is the part that goes
-- wrong.
function Rep.entitySnapshots(entities)
    local out = {}
    for i = 1, #entities do
        local e = entities[i]
        if not e.dead and not e.localOnly then
            out[#out + 1] = e:snapshot()
        end
    end
    return out
end

-- Builds a client-side stand-in for a host entity first seen in a snapshot.
-- The archetype is looked up locally: the host sends a kind, not a recipe, so
-- each side is free to attach whatever local-only components it wants (a client
-- adds sprites, a host adds a brain) and neither has to know about the other's.
function Rep.adopt(snap, opts)
    opts = opts or {}
    local e

    if opts.spawn then
        e = opts.spawn(snap.kind, snap.x, snap.y, snap)
    end

    if not e then
        if Entity.hasArchetype(snap.kind) then
            e = Entity.spawn(snap.kind, snap.x, snap.y)
        else
            -- No archetype: keep the transform so the thing is at least in the
            -- right place, attach nothing, and report it. Fabricating components
            -- to fill the gap would produce an entity that looks right and
            -- behaves like nothing in particular.
            e = Entity.new{ kind = snap.kind, x = snap.x, y = snap.y }
            if opts.onUnknown then opts.onUnknown(snap.kind, snap.id) end
        end
    end

    -- The host's id wins. Entity.new/spawn already consumed a local id; that is
    -- harmless because a client's counter is rebased past CLIENT_ID_BASE.
    e.id = snap.id
    e.angle = snap.angle or e.angle
    e:snapPrevious()

    return e
end

-- Reconciles a set of entities against a full snapshot list.
--
-- `state` is any table with `entities` (an array) and `byId` (a map). The client
-- passes itself. Returns counts, which is what a netgraph and a test both want.
function Rep.applyEntities(state, snaps, opts)
    opts = opts or {}
    state.byId = state.byId or {}
    state.entities = state.entities or {}

    local seen, spawned, removed = {}, 0, 0

    for i = 1, #snaps do
        local snap = snaps[i]
        if snap and snap.id then
            seen[snap.id] = true
            local e = state.byId[snap.id]

            if not e then
                e = Rep.adopt(snap, opts)
                state.byId[snap.id] = e
                state.entities[#state.entities + 1] = e
                e:applySnapshot(snap)
                -- Nothing to interpolate from on first sight, so prev == current.
                e:snapPrevious()
                spawned = spawned + 1
                if opts.onSpawn then opts.onSpawn(e, snap) end
            elseif opts.apply then
                opts.apply(e, snap)
            else
                -- The previous snapshot becomes the interpolation origin; the new
                -- one becomes the target. This is what makes 20 Hz snapshots look
                -- like continuous motion at any framerate.
                e:snapPrevious()
                e:applySnapshot(snap)
            end
        end
    end

    for i = #state.entities, 1, -1 do
        local e = state.entities[i]
        if not seen[e.id] and not e.localOnly then
            table.remove(state.entities, i)
            state.byId[e.id] = nil
            removed = removed + 1
            if opts.onDespawn then opts.onDespawn(e) end
        end
    end

    return spawned, removed
end

---------------------------------------------------------------------------
-- World -> join payload
---------------------------------------------------------------------------

-- Two forms, and which one is used is the host's choice:
--
--   'spec'  a worldgen seed and parameters. A few dozen bytes, because both ends
--           regenerate the same geometry from the engine's own LCG. Correct only
--           because worldgen never touches math.random, whose sequence differs
--           between Lua builds — that constraint exists precisely so this works.
--   'grid'  the tiles themselves. Larger, and always right: it is the only
--           option for a hand-authored map, a runtime-edited level, or a
--           generator a future version changes.
--
-- Doors travel either way, because door state is the mutable part of a world and
-- a joining client must see the doors as they are now, not as they generated.
function Rep.worldPayload(world, spec)
    local doors = {}
    for key, door in pairs(world.doors) do
        doors[#doors + 1] = { key, door.open and 1 or 0 }
    end

    if spec then
        return { kind = 'spec', spec = spec, doors = doors }
    end

    local grid = {}
    for y = 1, world.height do
        local row, out = world.grid[y], {}
        for x = 1, world.width do out[x] = row[x] or 0 end
        grid[y] = out
    end

    return {
        kind  = 'grid',
        grid  = grid,
        theme = world.theme,
        spawn = world.spawn and { x = world.spawn.x, y = world.spawn.y,
                                  angle = world.spawn.angle } or nil,
        doors = doors,
    }
end

local function parseDoorKey(key)
    local sx, sy = tostring(key):match('^(%-?%d+),(%-?%d+)$')
    return tonumber(sx), tonumber(sy)
end

function Rep.buildWorld(payload)
    if type(payload) ~= 'table' then return nil, 'no world payload' end

    local world

    if payload.kind == 'spec' then
        local ok, generated = pcall(Worldgen.generate, payload.spec or {})
        if not ok or not generated then
            return nil, 'could not regenerate the world from the seed: ' .. tostring(generated)
        end
        world = generated
    elseif payload.kind == 'grid' then
        if type(payload.grid) ~= 'table' or type(payload.grid[1]) ~= 'table' then
            return nil, 'world payload has no grid'
        end
        world = World.new(payload.grid, { theme = payload.theme, spawn = payload.spawn })
    else
        return nil, ('unknown world payload kind %q'):format(tostring(payload.kind))
    end

    for _, pair in ipairs(payload.doors or {}) do
        local tx, ty = parseDoorKey(pair[1])
        if tx then
            -- addDoor for the grid form (the doors table starts empty), and
            -- harmlessly idempotent for the spec form, where the generator
            -- already placed the same doors.
            world:addDoor(tx, ty, pair[2] == 1)
        end
    end

    return world
end

Rep.parseDoorKey = parseDoorKey

return Rep
