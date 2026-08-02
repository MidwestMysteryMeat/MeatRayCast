--[[
    meatray.game.respawn — death, the wait, and coming back shielded (Wave A5).

    The host decides who is dead, when they may return, and whether they come
    back briefly untouchable. This module is that decision, kept apart from any
    particular game loop:

        local Respawn = require('meatray.game.respawn')
        local rs = Respawn.new{ delay = 3, protection = 2 }

        -- host, when a player entity dies:
        rs:notifyDeath(peerId)

        -- host, inside the fixed tick:
        for _, id in ipairs(rs:tick(step)) do
            local spot = Respawn.pickSpawn(spawns, hostiles)
            local e = spawnPlayerFor(id, spot.x, spot.y, spot.angle)
            rs:spawned(id, e)          -- applies spawn protection to e
        end

        -- anyone, for feedback:
        rs:state(id)                   -- 'alive' | 'dead' | 'ready'
        rs:remaining(id)               -- seconds until return, 0 when ready
        rs:isProtected(id)             -- shield still up?

    Spawn protection is not a flag the damage code checks — it is an EFFECT
    whose immunityTags refuse anything tagged `damage`, applied through the
    same system every burn and poison already goes through. That buys three
    things for free: the shield expires on the effects clock, the granted tag
    replicates so a client can draw the shimmer, and nothing in weapons,
    explosions or gas ever learns that spawn protection exists. Firing drops
    the shield: protection is for getting your bearings, not for a free kill.

    The modes in meatray.game.modes already fire onRequestRespawn(victim,
    delay); handing that straight to `rs:notifyDeath(victim, delay)` is the
    whole integration.

    Time here is the caller's tick, accumulated internally — nothing reads a
    clock, so a test drives the wait by calling tick.

    HEADLESS: pure Lua.
]]

local Effects = require('meatray.game.effects')

local Respawn = {}
local RespawnMT = {}
RespawnMT.__index = RespawnMT

Respawn.PROTECTION_EFFECT_ID = 'spawn_protection'
Respawn.PROTECTION_TAG = 'status.spawn_protected'

-- Thirty additions of 1/60 do not land exactly on 0.5 — the same float truth
-- meatray.game.effects documents for durations. A delay that is an exact
-- multiple of the step must elapse on that step, not the one after.
local EPS = 1e-9

---------------------------------------------------------------------------
-- Construction
---------------------------------------------------------------------------

-- opts:
--   delay        seconds a death costs before return is allowed (default 3)
--   protection   seconds of untouchability after return (default 2, 0 = none)
--   auto         when true (default) tick returns due ids exactly once; when
--                false the caller polls canRespawn and decides (click to
--                respawn, wave spawns, and so on)
function Respawn.new(opts)
    opts = opts or {}
    return setmetatable({
        delay      = math.max(0, tonumber(opts.delay) or 3),
        protection = math.max(0, tonumber(opts.protection) or 2),
        auto       = opts.auto ~= false,

        now = 0,
        dead = {},          -- id -> { at =, delay =, announced = }
    }, RespawnMT)
end

---------------------------------------------------------------------------
-- Deaths
---------------------------------------------------------------------------

-- Starts the clock for `id` (a peer id, an entity id — the module never looks
-- inside it). A second notification while already dead is ignored: dying does
-- not restart the wait. `delay` overrides the constructor's, which is exactly
-- the shape modes' onRequestRespawn hands over.
function RespawnMT:notifyDeath(id, delay)
    if id == nil then return nil, 'no id' end
    if self.dead[id] then return self.dead[id] end
    local entry = {
        at = self.now,
        delay = math.max(0, tonumber(delay) or self.delay),
        announced = false,
    }
    self.dead[id] = entry
    return entry
end

-- The id left the server, or the round reset: forget everything about it.
function RespawnMT:clear(id)
    self.dead[id] = nil
end

function RespawnMT:reset()
    self.now = 0
    self.dead = {}
end

---------------------------------------------------------------------------
-- The tick
---------------------------------------------------------------------------

-- Advances the wait. In auto mode, returns each due id exactly once — the
-- caller spawns them and calls `spawned`. In manual mode returns an empty
-- list; poll canRespawn instead.
function RespawnMT:tick(dt)
    self.now = self.now + math.max(0, tonumber(dt) or 0)
    local due = {}
    if self.auto then
        for id, entry in pairs(self.dead) do
            if not entry.announced and self.now - entry.at >= entry.delay - EPS then
                entry.announced = true
                due[#due + 1] = id
            end
        end
        -- pairs order is not a contract anyone should inherit.
        table.sort(due, function(a, b) return tostring(a) < tostring(b) end)
    end
    return due
end

function RespawnMT:canRespawn(id)
    local entry = self.dead[id]
    if not entry then return false end
    return self.now - entry.at >= entry.delay - EPS
end

-- Seconds left in the wait; 0 when ready or not dead at all.
function RespawnMT:remaining(id)
    local entry = self.dead[id]
    if not entry then return 0 end
    local left = entry.delay - (self.now - entry.at)
    return left > EPS and left or 0
end

function RespawnMT:state(id)
    local entry = self.dead[id]
    if not entry then return 'alive' end
    return self:canRespawn(id) and 'ready' or 'dead'
end

---------------------------------------------------------------------------
-- Return, and the shield
---------------------------------------------------------------------------

-- The caller made a new entity for `id`; this closes the death and raises the
-- shield. Passing an entity without an ability system (or no entity, in a
-- test) just skips the effect — death bookkeeping still closes.
function RespawnMT:spawned(id, entity)
    self.dead[id] = nil
    if entity and self.protection > 0 then
        return Respawn.protect(entity, self.protection)
    end
    return nil
end

-- The shield, as an ordinary effect. `damage.*` asset tags are refused for
-- the duration by the effects system's own immunity check; nothing in any
-- damage path is consulted. Standalone so a mode can shield for other reasons
-- (round start, cutscene) without inventing a second mechanism.
function Respawn.protect(entity, seconds)
    if not entity or not Effects.system(entity) then
        return nil, 'entity has no ability system'
    end
    return Effects.applySpec(entity, {
        id = Respawn.PROTECTION_EFFECT_ID,
        duration = math.max(0.01, tonumber(seconds) or 2),
        grantedTags = { Respawn.PROTECTION_TAG },
        immunityTags = { 'damage' },
    })
end

-- Shooting drops the shield. Wire this to the fire path; a protected player
-- who opens fire is choosing to fight.
function Respawn.dropProtection(entity, ctx)
    if not entity or not Effects.system(entity) then return 0 end
    return Effects.removeById(entity, Respawn.PROTECTION_EFFECT_ID, ctx, 'fired')
end

function RespawnMT:isProtected(entity)
    return Respawn.isProtected(entity)
end

-- Answered through Effects.hasTag, so a client reading the replicated tag
-- string and a host reading the live container agree.
function Respawn.isProtected(entity)
    if not entity then return false end
    return Effects.hasTag(entity, Respawn.PROTECTION_TAG)
end

---------------------------------------------------------------------------
-- Where to come back
---------------------------------------------------------------------------

-- Picks the spawn farthest from the nearest living hostile — the classic
-- arena rule, and the whole of it. `spawns` is { {x=,y=,angle=}, ... };
-- `hostiles` is any entity list, dead ones ignored. With no hostiles (or one
-- spawn) the first spawn wins, so single-player maps need no special case.
-- Deterministic: ties break toward the earlier spawn in the list.
function Respawn.pickSpawn(spawns, hostiles)
    if type(spawns) ~= 'table' or #spawns == 0 then return nil end
    if #spawns == 1 then return spawns[1] end

    local best, bestScore = spawns[1], -1
    for i = 1, #spawns do
        local s = spawns[i]
        local nearest = math.huge
        for j = 1, #(hostiles or {}) do
            local h = hostiles[j]
            if h and not h.dead and h.x and h.y then
                local dx, dy = h.x - s.x, h.y - s.y
                local d2 = dx * dx + dy * dy
                if d2 < nearest then nearest = d2 end
            end
        end
        if nearest == math.huge then nearest = 0 end
        if nearest > bestScore then
            best, bestScore = s, nearest
        end
    end
    return best
end

return Respawn
