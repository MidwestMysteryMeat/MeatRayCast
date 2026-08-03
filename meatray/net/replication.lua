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

local Entity    = require('meatray.sim.entity')
local World     = require('meatray.sim.world')
local Collide   = require('meatray.sim.collide')
local Worldgen  = require('meatray.sim.worldgen')
local SnapCodec = require('meatray.net.snapcodec')

local Rep = {}

-- Ids below this belong to the host; a client rebases its own counter to here on
-- join so anything it spawns locally (a muzzle flash, a decal, a debug marker)
-- can never collide with an authoritative id. Ids are never negotiated at
-- runtime, which is one round trip and one race condition avoided.
Rep.CLIENT_ID_BASE = 1000000

Rep.DEFAULT_MOVE_SPEED = 3.2
Rep.DEFAULT_TURN_SPEED = 2.6

-- Angles beyond this are refused rather than wrapped. Wrapping would be tidier
-- and would put a visible spin on every remote player the moment their aim
-- crossed the boundary, which is a rendering regression bought to fix a problem
-- that finite numbers do not have. A session cannot reach 1e6 radians: a player
-- spinning continuously at 10 rad/s takes 27 hours.
Rep.MAX_ANGLE = 1e6

-- A number, or nil — never NaN, never an infinity, never out of range.
--
-- Exported because game code needs it too. Anything that reads a value off a
-- COMMAND body and assigns it to an entity is one `tonumber` away from the bug
-- this whole layer exists to prevent: `if tonumber(body.angle) then` is true for
-- NaN, and an entity carrying a NaN angle produces a NaN position on its next
-- step, which then rides out in the snapshot to every other player. The peer that
-- sent it is not the one it breaks.
function Rep.finite(v, min, max)
    v = tonumber(v)
    if v == nil then return nil end
    if v ~= v then return nil end                      -- NaN
    if v == math.huge or v == -math.huge then return nil end
    if min and v < min then return nil end
    if max and v > max then return nil end
    return v
end

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

    -- A fresh table, always. Nothing is written back into the caller's input and
    -- nothing is applied to an entity until the whole intent has been through
    -- here, so a message that turns out to be partly garbage costs a drop rather
    -- than leaving half of itself behind.
    local out = {
        seq     = Rep.finite(input.seq, 0, 2 ^ 53) or 0,
        forward = unit(input.forward),
        strafe  = unit(input.strafe),
        turn    = unit(input.turn),
    }

    -- Absent rather than clamped when it is unusable: the last good aim is a
    -- better answer than a pegged one, and it is the same answer the player's own
    -- screen is showing.
    out.angle = Rep.finite(input.angle, -Rep.MAX_ANGLE, Rep.MAX_ANGLE)

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

    -- Developer noclip: raw translation, no collision consulted. Local only
    -- by construction — a host applies ITS OWN opts to a remote peer's
    -- input, so a client asking nicely for noclip has nowhere to ask.
    if opts.noclip then
        e.x, e.y = e.x + dx, e.y + dy
        return 1, false
    end

    return Collide.move(e, dx, dy, world)
end

---------------------------------------------------------------------------
-- Entities -> snapshots
---------------------------------------------------------------------------

-- Full state, not a delta. A full snapshot is self-correcting: a client that
-- missed a packet is right again on the next one with no repair protocol, and
-- despawns need no message of their own because an entity absent from the
-- snapshot is an entity that is gone.
--
-- This is the keyframe half of the dirty-flag stream below, and it is also what
-- a joining client is sent, because a client with no baseline can only be told
-- everything.
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

---------------------------------------------------------------------------
-- Dirty-flag snapshots
---------------------------------------------------------------------------

--[[
    Most entities in a tile world are idle on any given tick, so most of a full
    snapshot is bytes that have not changed. A partial frame carries only what
    differs from the last keyframe, and nothing else about the stream moves:

      * ONE shared baseline, so ONE encode still serves every peer. That is the
        whole reason this is cheap where delta compression is not.
      * NO per-peer acknowledgement bookkeeping, and therefore no per-peer
        baselines to keep, no acks to lose, and no worst case where a packet
        grows because one client fell behind.

    Delta compression proper is deliberately not built here and should not be.
    Q3-style deltas need a per-peer baseline confirmed by an ack, which over an
    unreliable channel means the *worst* case packet is a diff against a very old
    frame — larger than a full snapshot, which walks straight back into the
    fragmentation bug meatray/net/snapcodec.lua exists to prevent.

    WHAT A PARTIAL IS MEASURED AGAINST, AND WHY IT IS THE KEYFRAME

    The obvious baseline is "the previous snapshot". It is also wrong here: a
    client that dropped one packet would then be permanently wrong about
    everything that changed inside it, because the next frame describes changes
    since a frame the client never saw.

    So a partial is a diff against the last KEYFRAME, not against the last
    partial. That makes the property a lossy channel needs:

        keyframe K + ANY ONE later partial  ==  correct state

    A client can drop every partial but the newest and still be right. There is
    no repair protocol, no retransmit, and nothing per peer, because a partial is
    idempotent and self-contained.

    It also keeps local-player prediction honest, which "diff against the
    previous frame" would not. An entity that moved at all since the keyframe
    still differs from the baseline, so it stays in EVERY partial until the next
    keyframe — meaning a client that mispredicted is told the authoritative
    position on every frame rather than once and then never again. The only case
    left uncorrected is an entity whose position is *exactly* the keyframe's
    while the client believes otherwise, and the next keyframe closes that.

    The cost is paid where it should be. A partial grows over a keyframe interval
    (an entity that moved once stays different from K until the next keyframe),
    which caps the win rather than the correctness. And a client that drops a
    KEYFRAME is stale on entities that changed and then stopped inside that
    interval, until the next keyframe — bounded by the keyframe interval, and the
    only failure mode this design has.

    WHAT COUNTS AS CHANGED

    Whatever netFields declared, and nothing else, exactly as everywhere else in
    this layer: the diff walks the snapshot EntityMT:snapshot() produced, so a
    field added to a declaration is tracked with no edit here. The transform is
    compared through SnapCodec.quantise, because the baseline has to hold what
    the client actually received rather than what the host holds — otherwise an
    entity drifting by less than a binary32 step is dirty forever.
]]

-- Snapshots between keyframes. Ten at the default 20 Hz is half a second: long
-- enough that keyframes are a tenth of the frames, short enough that the one
-- failure mode above is bounded at half a second. 1 turns the whole thing off —
-- every frame becomes a keyframe and the stream is exactly what it was before.
Rep.KEYFRAME_INTERVAL = 10

-- Pending removals force a keyframe early. Removals repeat in every partial
-- until the next keyframe (a client that dropped the one carrying a removal must
-- still learn about it), so churn accumulates bytes that a keyframe clears for
-- free. 64 ids is at most ~130 bytes before that happens.
Rep.MAX_PENDING_REMOVALS = 64

local function copyValue(v)
    if type(v) ~= 'table' then return v end
    local out = {}
    for key, value in pairs(v) do out[key] = copyValue(value) end
    return out
end

-- Deep equality over the plain data a netFields declaration may name. NaN is
-- equal to itself here on purpose: a NaN in a replicated field is a bug
-- elsewhere, and treating it as perpetually changed would hide that bug behind a
-- stream that never stops resending.
local function sameValue(a, b)
    if a == b then return true end
    if a ~= a and b ~= b then return true end
    if type(a) ~= 'table' or type(b) ~= 'table' then return false end

    for key, value in pairs(a) do
        if not sameValue(value, b[key]) then return false end
    end
    for key in pairs(b) do
        if a[key] == nil then return false end
    end
    return true
end

-- The form a snapshot is remembered in: the transform as the receiver will hold
-- it, and a copy of everything else deep enough that a component mutating a
-- table it also replicated cannot silently edit the baseline underneath us.
local function baselineCopy(snap)
    local out = {
        kind   = snap.kind,
        x      = SnapCodec.quantise(snap.x),
        y      = SnapCodec.quantise(snap.y),
        angle  = SnapCodec.quantiseAngle(snap.angle),
        storey = snap.storey or 1,
    }
    if snap.c then out.c = copyValue(snap.c) end
    return out
end

-- One entity's snapshot reduced to what differs from its baseline, or nil when
-- nothing does. The id always travels; everything else is present only if it
-- changed, which the flag byte in the wire format has always been able to say.
local function pruneSnapshot(snap, base)
    local out, dirty = { id = snap.id }, false

    if snap.kind ~= nil and snap.kind ~= base.kind then
        out.kind, dirty = snap.kind, true
    end
    if snap.x ~= nil and SnapCodec.quantise(snap.x) ~= base.x then
        out.x, dirty = snap.x, true
    end
    if snap.y ~= nil and SnapCodec.quantise(snap.y) ~= base.y then
        out.y, dirty = snap.y, true
    end
    if snap.angle ~= nil and SnapCodec.quantiseAngle(snap.angle) ~= base.angle then
        out.angle, dirty = snap.angle, true
    end
    local snapStorey = snap.storey or 1
    local baseStorey = base.storey or 1
    if snapStorey ~= baseStorey then
        out.storey, dirty = snapStorey, true
    end

    if snap.c then
        local baseComponents, changedComponents = base.c, nil

        for name, fields in pairs(snap.c) do
            local baseFields = baseComponents and baseComponents[name]

            if not baseFields then
                -- A component the entity did not have at the keyframe: all of it
                -- is news.
                changedComponents = changedComponents or {}
                changedComponents[name] = fields
            else
                local changedFields
                for key, value in pairs(fields) do
                    if not sameValue(value, baseFields[key]) then
                        changedFields = changedFields or {}
                        changedFields[key] = value
                    end
                end
                if changedFields then
                    changedComponents = changedComponents or {}
                    changedComponents[name] = changedFields
                end
            end
        end

        -- A component that vanished is not expressible and never was:
        -- applySnapshot has always ignored a name it is not given rather than
        -- removing it, in a full snapshot as much as in a partial. Nothing is
        -- lost here that a full snapshot carried.
        if changedComponents then
            out.c, dirty = changedComponents, true
        end
    end

    if not dirty then return nil end
    return out
end

-- The shared state a dirty-flag stream keeps. One of these per host, never one
-- per peer — that is the constraint the whole design is built around.
function Rep.newBaseline()
    return {
        byId    = {},      -- id -> the state as of the last keyframe
        known   = {},      -- ids the stream has named since the last keyframe
        gone    = {},      -- ids removed since it, in the order they went
        goneSet = {},
        frames  = 0,       -- frames emitted since the last keyframe, keyframe = 0
        keyframes = 0,
        partials  = 0,
    }
end

-- Whether the next frame has to be a keyframe: the interval elapsed, the
-- baseline is empty (nothing has ever been sent), or removals have piled up.
function Rep.keyframeDue(baseline, interval)
    if not baseline then return true end
    interval = interval or Rep.KEYFRAME_INTERVAL
    if interval <= 1 then return true end
    if baseline.keyframes == 0 then return true end
    if baseline.frames >= interval - 1 then return true end
    if #baseline.gone >= Rep.MAX_PENDING_REMOVALS then return true end
    return false
end

-- Builds one frame of the stream and advances the baseline.
--
-- Returns the entity list, the removal list (nil in a keyframe), and whether
-- this frame is a keyframe. Pass no baseline to get exactly the old behaviour:
-- every entity, every field, every time.
function Rep.snapshotFrame(entities, baseline, full)
    if not baseline then
        return Rep.entitySnapshots(entities), nil, true
    end

    if full then
        baseline.byId, baseline.known = {}, {}
        baseline.gone, baseline.goneSet = {}, {}

        local out = {}
        for i = 1, #entities do
            local e = entities[i]
            if not e.dead and not e.localOnly then
                local snap = e:snapshot()
                out[#out + 1] = snap
                baseline.byId[snap.id] = baselineCopy(snap)
                baseline.known[snap.id] = true
            end
        end

        baseline.frames = 0
        baseline.keyframes = baseline.keyframes + 1
        return out, nil, true
    end

    local out, seen = {}, {}

    for i = 1, #entities do
        local e = entities[i]
        if not e.dead and not e.localOnly then
            local snap = e:snapshot()
            local id = snap.id
            seen[id] = true

            local base = baseline.byId[id]
            if base then
                local part = pruneSnapshot(snap, base)
                if part then out[#out + 1] = part end
            else
                -- Spawned since the keyframe, so there is nothing to diff
                -- against and it goes out whole. Deliberately NOT folded into
                -- the baseline: doing that would make it depend on a client
                -- having received this particular partial, which is the one
                -- thing the keyframe baseline exists to avoid. It costs a
                -- re-send per frame until the next keyframe, on entities that
                -- are new and therefore few.
                out[#out + 1] = snap
            end

            baseline.known[id] = true

            -- An id cannot come back from the dead — Entity.reserveId never
            -- reuses one — but if a game ever hands out its own ids, a live
            -- entity must beat a stale removal rather than being deleted by it.
            if baseline.goneSet[id] then
                baseline.goneSet[id] = nil
                for k = #baseline.gone, 1, -1 do
                    if baseline.gone[k] == id then table.remove(baseline.gone, k) end
                end
            end
        end
    end

    -- Removals accumulate and repeat until the next keyframe. A client that
    -- dropped the partial carrying one would otherwise keep a corpse forever,
    -- and repeating a handful of varints is the cheapest possible answer.
    local newlyGone
    for id in pairs(baseline.known) do
        if not seen[id] and not baseline.goneSet[id] then
            newlyGone = newlyGone or {}
            newlyGone[#newlyGone + 1] = id
        end
    end
    if newlyGone then
        -- Sorted, so two hosts running the same simulation produce the same
        -- bytes. `pairs` order is not, and a stream whose contents depend on
        -- hash order is a stream nobody can diff two captures of.
        table.sort(newlyGone)
        for i = 1, #newlyGone do
            local id = newlyGone[i]
            baseline.goneSet[id] = true
            baseline.gone[#baseline.gone + 1] = id
        end
    end

    baseline.frames = baseline.frames + 1
    baseline.partials = baseline.partials + 1

    return out, baseline.gone, false
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

-- Reconciles a set of entities against a snapshot list.
--
-- `state` is any table with `entities` (an array) and `byId` (a map). The client
-- passes itself. Returns counts, which is what a netgraph and a test both want.
--
-- Two frame kinds, and the difference is entirely in what ABSENCE means:
--
--   keyframe (the default, and what `opts.full ~= false` preserves for every
--            existing caller) — an id that is not in the list is an id that is
--            gone, which is why a full snapshot needs no despawn message.
--   partial  (`opts.full = false`) — absence means unchanged and nothing else,
--            so removals arrive explicitly in `opts.removed`.
function Rep.applyEntities(state, snaps, opts)
    opts = opts or {}
    state.byId = state.byId or {}
    state.entities = state.entities or {}

    local full = opts.full ~= false
    local seen, spawned, removed = {}, 0, 0

    for i = 1, #snaps do
        local snap = snaps[i]
        if snap and snap.id then
            seen[snap.id] = true
            local e = state.byId[snap.id]

            if not e and not full and snap.kind == nil then
                -- A partial for an entity this client has never seen, and no
                -- kind to build it from: it existed at a keyframe that was
                -- dropped. Skipping it leaves it absent until the next keyframe,
                -- which is a second of one entity missing; adopting it would
                -- make a permanent nameless ghost with no components, at the
                -- right position, that looks like a rendering bug.
                seen[snap.id] = nil

            elseif not e then
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

            -- Walk-surface height is not on the wire: both sides derive it from
            -- the shared floor table. Re-ground after every apply so a remote
            -- player standing on a raised tile is drawn at the right height
            -- rather than floating at z=0 until they next move on this machine.
            if e and state.world and state.world.floorHeightAtPoint then
                e.z = state.world:floorHeightAtPoint(e.x, e.y)
            end
        end
    end

    -- In a keyframe, absence is removal. In a partial it is not, so the removals
    -- are named — and naming an id that is already gone has to be harmless,
    -- because a removal repeats in every partial until the next keyframe.
    local dropping
    if full then
        dropping = function(e) return not seen[e.id] end
    else
        local ids = {}
        local list = opts.removed
        if type(list) == 'table' then
            for i = 1, #list do ids[list[i]] = true end
        end
        dropping = function(e) return ids[e.id] == true end
    end

    for i = #state.entities, 1, -1 do
        local e = state.entities[i]
        if dropping(e) and not e.localOnly then
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
-- Destroyed tiles do the same: a mid-round join must see rubble, not the
-- authored wall (critical for seed payloads, which regenerate a pristine grid).
-- Multi-storey: door/tile keys use World.stateKey ("tx,ty" storey 1, "s,tx,ty"
-- above); extra layer grids ride along as payload.layers[2..N].
function Rep.worldPayload(world, spec)
    local doors = {}
    local nStoreys = world.storeyCount and world:storeyCount() or 1
    for si = 1, nStoreys do
        local layerDoors = (world.layer and world:layer(si).doors) or (si == 1 and world.doors) or {}
        for key, door in pairs(layerDoors) do
            local tx, ty = key:match('^(%-?%d+),(%-?%d+)$')
            if tx then
                local wire = World.stateKey(tonumber(tx), tonumber(ty), si)
                doors[#doors + 1] = { wire, door.open and 1 or 0 }
            end
        end
    end

    local tiles = {}
    if world.tileSnapshot then
        for key, gone in pairs(world:tileSnapshot()) do
            tiles[#tiles + 1] = { key, gone }
        end
    end

    -- A6/F2 state (G2). Locks and push-walls are MUTABLE world state the way
    -- door-open is: a joining client (and a mid-session save) must see the
    -- red door still locked and the half-slid wall where it now stands, not
    -- where the map file authored it. Secrets and hazards are static boxes,
    -- but the grid/spec forms do not carry map headers, so without these a
    -- join client's world has no idea they exist.
    local locks = {}
    for si = 1, nStoreys do
        local layerDoors = (world.layer and world:layer(si).doors)
                           or (si == 1 and world.doors) or {}
        for key, door in pairs(layerDoors) do
            if door.lock then
                local tx, ty = key:match('^(%-?%d+),(%-?%d+)$')
                if tx then
                    locks[#locks + 1] =
                        { World.stateKey(tonumber(tx), tonumber(ty), si), door.lock }
                end
            end
        end
    end

    local pushwalls = {}
    for si = 1, nStoreys do
        local layerPush = (world.layer and world:layer(si).pushwalls)
                          or (si == 1 and world.pushwalls) or {}
        for key, pw in pairs(layerPush) do
            if (pw.left or 0) > 0 then
                local tx, ty = key:match('^(%-?%d+),(%-?%d+)$')
                if tx then
                    pushwalls[#pushwalls + 1] = {
                        World.stateKey(tonumber(tx), tonumber(ty), si),
                        pw.dx, pw.dy, pw.left, pw.interval,
                    }
                end
            end
        end
    end

    local extras = {
        locks = (#locks > 0) and locks or nil,
        pushwalls = (#pushwalls > 0) and pushwalls or nil,
        secrets = world.secrets,
        hazards = world.hazards,
        -- C18: the lift CONFIG (tiles/travel), so a joining client can rebuild
        -- the same movers and then apply their live z from WORLD deltas. The
        -- current z rides the snapshot stream, not this static payload.
        movers = world.movers,
    }

    if spec then
        return { kind = 'spec', spec = spec, doors = doors, tiles = tiles,
                 locks = extras.locks, pushwalls = extras.pushwalls,
                 secrets = extras.secrets, hazards = extras.hazards,
                 movers = extras.movers }
    end

    local function copyGrid(src)
        local grid = {}
        for y = 1, #src do
            local row, out = src[y], {}
            for x = 1, #row do out[x] = row[x] or 0 end
            grid[y] = out
        end
        return grid
    end

    local grid = copyGrid(world.grid)
    local layers = nil
    if nStoreys > 1 then
        layers = {}
        for si = 2, nStoreys do
            layers[si - 1] = copyGrid(world:layer(si).grid)
        end
    end

    return {
        kind   = 'grid',
        grid   = grid,
        layers = layers,
        theme  = world.theme,
        spawn  = world.spawn and { x = world.spawn.x, y = world.spawn.y,
                                   angle = world.spawn.angle } or nil,
        doors  = doors,
        tiles  = tiles,
        locks      = extras.locks,
        pushwalls  = extras.pushwalls,
        secrets    = extras.secrets,
        hazards    = extras.hazards,
        movers     = extras.movers,
    }
end

local function parseDoorKey(key)
    -- Prefer multi-storey form; fall back to "tx,ty" as storey 1.
    if World.parseStateKey then
        local tx, ty, storey = World.parseStateKey(key)
        if tx then return tx, ty, storey end
    end
    local sx, sy = tostring(key):match('^(%-?%d+),(%-?%d+)$')
    return tonumber(sx), tonumber(sy), 1
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
        if type(payload.layers) == 'table' then
            for i = 1, #payload.layers do
                local g = payload.layers[i]
                if type(g) == 'table' and type(g[1]) == 'table' then
                    world:addStorey(g)
                end
            end
        end
    else
        return nil, ('unknown world payload kind %q'):format(tostring(payload.kind))
    end

    for _, pair in ipairs(payload.doors or {}) do
        local tx, ty, storey = parseDoorKey(pair[1])
        if tx then
            -- addDoor for the grid form (the doors table starts empty), and
            -- harmlessly idempotent for the spec form, where the generator
            -- already placed the same doors.
            world:addDoor(tx, ty, pair[2] == 1, storey)
        end
    end

    -- Broken tiles: seed joins need this; grid joins already baked rubble into
    -- the copied grids, but apply still fills the broken side-table for repair.
    if type(payload.tiles) == 'table' and world.applyTileSnapshot then
        local snap = {}
        for _, pair in ipairs(payload.tiles) do
            if type(pair) == 'table' and pair[1] ~= nil then
                snap[pair[1]] = pair[2] == nil and 1 or pair[2]
            end
        end
        -- Also accept the keyed form { ["x,y"] = 1 } used by WORLD deltas.
        if next(snap) == nil then
            for k, v in pairs(payload.tiles) do
                if type(k) == 'string' then snap[k] = v end
            end
        end
        if next(snap) then world:applyTileSnapshot(snap) end
    end

    -- A6/F2 state back onto the rebuilt world (G2), after doors and tiles so
    -- a push-wall lands on the grid as it now stands.
    for _, pair in ipairs(payload.locks or {}) do
        local tx, ty, storey = parseDoorKey(pair[1])
        if tx and world.lockDoor then
            world:lockDoor(tx, ty, pair[2], storey)
        end
    end
    for _, entry in ipairs(payload.pushwalls or {}) do
        local tx, ty, storey = parseDoorKey(entry[1])
        if tx and world.addPushWall then
            world:addPushWall(tx, ty, {
                dx = entry[2], dy = entry[3],
                distance = entry[4], interval = entry[5],
                storey = storey,
            })
        end
    end
    if type(payload.secrets) == 'table' then
        world.secrets = payload.secrets
    end
    if type(payload.hazards) == 'table' then
        world.hazards = payload.hazards
    end
    -- C18: the lift config, so the client can build a matching Movers host and
    -- drive its floor heights off the WORLD deltas the host sends.
    if type(payload.movers) == 'table' then
        world.movers = payload.movers
    end

    return world
end

Rep.parseDoorKey = parseDoorKey

return Rep
