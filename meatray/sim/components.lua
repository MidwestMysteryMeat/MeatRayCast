--[[
    meatray.sim.components — the component types the engine itself understands.

    Games define their own alongside these; nothing here is privileged. What
    matters is the pattern: a component declares the fields that cross the
    network, and the snapshot code reads that declaration. Add a field to
    netFields and it synchronises. Nothing else needs editing, and there is no
    per-type serialiser to forget to update.

    Note what is NOT synced. Billboard carries the sprite name so a client can
    look up its own local sprite definition, but frame timing is local: every
    client can run an animation clock itself, and spending bandwidth on which
    frame of a walk cycle an imp is showing would be absurd. Motion is likewise
    absent from the wire because the host sends positions.

    HEADLESS: this module must not touch love.graphics or any love drawing API.
]]

local Entity = require('meatray.sim.entity')

local C = {}

-- What the render layer needs to draw an entity as a sprite. `angles` is how
-- many facing buckets the sheet provides: 1 means a single image that always
-- faces the camera, 8 means Doom-style directional. The engine never assumes 8.
C.Billboard = Entity.component('billboard', { 'sheet' })

-- Damage model. Both fields sync so clients can draw health bars and react to
-- death without waiting to be told separately.
C.Health = Entity.component('health', { 'hp', 'max' })

-- Velocity in tiles per second. Local: the host is authoritative on position,
-- so a client that also integrated velocity would fight the snapshots it
-- receives rather than agreeing with them.
C.Motion = Entity.component('motion')

-- Melee reach and damage. Static per archetype, so it needs no wire presence.
C.Melee = Entity.component('melee')

-- Hitscan weapon state. `ammo` syncs because a client showing the wrong ammo
-- count is a visible lie; cooldown is local timing.
C.Weapon = Entity.component('weapon', { 'ammo' })

-- Marks an entity as controlled by a player, and by which one. Synced so every
-- client can tell peers apart and identify its own avatar.
C.Player = Entity.component('player', { 'peerId', 'name' })

-- Per-tick intent. Never synced as component state: inputs travel as their own
-- message type from client to host, which is the opposite direction to snapshots.
C.Input = Entity.component('input')

-- Simple AI bookkeeping. Entirely host-side; a client has no business running
-- enemy decisions in a host-authoritative model.
C.Brain = Entity.component('brain')

-- Blocks movement and takes up space. Radius lives on the entity itself because
-- collision reads it on the hot path.
C.Solid = Entity.component('solid')

return C
