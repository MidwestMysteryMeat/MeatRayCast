--[[
    meatray.game.hazards — floors that hurt and liquids that slow (F5).

    Damage floors, slime, water and lava are the oldest furniture in the
    genre and the easiest to build wrong: a special case inside movement, a
    second one inside damage, a third inside the HUD. This kit is none of
    those. A hazard is a world-space box plus a KIND, and a kind is only
    numbers: how much it slows, how hard it bites, how often, and with what
    damage tags — so armour soaks a slime bath, a fire resistance shrugs at
    lava, and god mode refuses all of it without this file knowing any of
    them exist.

        local hz = Hazards.new()
        hz:addZone{ kind = 'lava', x1 = 4, y1 = 4, x2 = 8, y2 = 6 }
        hz:fromWorld(world)              -- zones map headers declared

        hz:update(entities, dt)          -- fixed tick, host authority
        speed = base * hz:speedFactor(e) -- movement asks, hazards answer
        hz:standingIn(e)                 -- 'lava' | nil, for tints and sound

    The slow is deliberately a QUESTION (`speedFactor`) rather than a write
    into the entity: the demo's player speed is an option, an AI's is its
    own, and a modifier written into either would need this module to know
    both. Whoever owns a speed multiplies by the answer.

    Damage is applied through Damage.applyWith on an accumulator — stand in
    lava for interval seconds, take one bite, keep standing, keep biting —
    so a frame-rate change cannot change the damage rate, and the first
    moment of contact is free the way Doom's damage floors made it (the
    grace is what lets you cross a sliver of slime at full health).

    KINDS is data and overridable per instance; the stock three are tuned
    for the demo, not carved anywhere.

    HEADLESS: pure Lua.
]]

local Damage  = require('meatray.game.damage')
local Effects = require('meatray.game.effects')

local Hazards = {}
local HazardsMT = {}
HazardsMT.__index = HazardsMT

---------------------------------------------------------------------------
-- Kinds
---------------------------------------------------------------------------

-- slow: multiply movement by this while inside (1 = no effect)
-- damage / interval: bite size and cadence; 0 damage never bites
-- tags: what kind of hurt, for resistances and immunities
Hazards.KINDS = {
    water = { slow = 0.55, damage = 0 },
    slime = { slow = 0.80, damage = 4,  interval = 0.7,
              tags = { 'damage.type.toxic' } },
    lava  = { slow = 0.70, damage = 16, interval = 0.5,
              tags = { 'damage.type.fire' } },
}

---------------------------------------------------------------------------
-- Construction
---------------------------------------------------------------------------

-- opts.kinds: overrides/extensions merged over the stock table.
function Hazards.new(opts)
    opts = opts or {}
    local kinds = {}
    for name, def in pairs(Hazards.KINDS) do kinds[name] = def end
    for name, def in pairs(opts.kinds or {}) do kinds[name] = def end
    return setmetatable({
        kinds = kinds,
        zones = {},
        -- [entity] = { zones = {zone,...}, acc = {[zone]=seconds} }, weak so
        -- a despawned entity does not pin its bookkeeping forever.
        state = setmetatable({}, { __mode = 'k' }),
    }, HazardsMT)
end

function HazardsMT:addZone(z)
    z = z or {}
    local kind = self.kinds[tostring(z.kind or '')]
    if not kind then return nil, 'unknown hazard kind: ' .. tostring(z.kind) end
    local x1, y1 = tonumber(z.x1), tonumber(z.y1)
    local x2, y2 = tonumber(z.x2), tonumber(z.y2)
    if not (x1 and y1 and x2 and y2) then
        return nil, 'hazard zone needs x1 y1 x2 y2'
    end
    if x2 < x1 then x1, x2 = x2, x1 end
    if y2 < y1 then y1, y2 = y2, y1 end
    local zone = {
        kind = tostring(z.kind), def = kind,
        x1 = x1, y1 = y1, x2 = x2, y2 = y2,
        storey = z.storey or 1, name = z.name,
    }
    self.zones[#self.zones + 1] = zone
    return zone
end

-- Adopts what the map headers put on the world, the same ride secrets take.
function HazardsMT:fromWorld(world)
    local n = 0
    for _, z in ipairs((world and world.hazards) or {}) do
        if self:addZone(z) then n = n + 1 end
    end
    return n
end

function HazardsMT:count()
    return #self.zones
end

---------------------------------------------------------------------------
-- Queries
---------------------------------------------------------------------------

local function inside(zone, e)
    if (e.storey or 1) ~= zone.storey then return false end
    local x, y = e.x, e.y
    return x and y and x >= zone.x1 and x <= zone.x2
                   and y >= zone.y1 and y <= zone.y2
end

function HazardsMT:zonesAt(x, y, storey)
    local probe = { x = x, y = y, storey = storey or 1 }
    local out = {}
    for i = 1, #self.zones do
        if inside(self.zones[i], probe) then out[#out + 1] = self.zones[i] end
    end
    return out
end

-- The movement multiplier for this entity, as of the last update. Overlapping
-- zones multiply — waist-deep in slime under water is slower than either.
function HazardsMT:speedFactor(e)
    local st = e and self.state[e]
    if not st or #st.zones == 0 then return 1 end
    local f = 1
    for i = 1, #st.zones do
        f = f * (st.zones[i].def.slow or 1)
    end
    return f
end

-- The kind the entity is standing in (the worst one, by damage), or nil.
-- What a HUD tint or a footstep sound wants to know.
function HazardsMT:standingIn(e)
    local st = e and self.state[e]
    if not st or #st.zones == 0 then return nil end
    local worst = st.zones[1]
    for i = 2, #st.zones do
        if (st.zones[i].def.damage or 0) > (worst.def.damage or 0) then
            worst = st.zones[i]
        end
    end
    return worst.kind
end

---------------------------------------------------------------------------
-- The tick
---------------------------------------------------------------------------

--[[
    Recomputes who stands where and applies the accumulated bites. Damage
    goes to entities with an ability system only — the same rule gas keeps —
    and through Damage.applyWith, so everything that gates damage gates this.
    Returns the list of bites applied, for logs and tests.
]]
function HazardsMT:update(entities, dt)
    dt = math.max(0, tonumber(dt) or 0)
    local bites = {}

    for i = 1, #(entities or {}) do
        local e = entities[i]
        if type(e) == 'table' and not e.dead then
            local st = self.state[e]
            local occupied
            for z = 1, #self.zones do
                local zone = self.zones[z]
                if inside(zone, e) then
                    occupied = occupied or {}
                    occupied[#occupied + 1] = zone
                end
            end

            if occupied then
                st = st or { zones = {}, acc = {} }
                self.state[e] = st
                st.zones = occupied

                if Effects.system(e) then
                    for z = 1, #occupied do
                        local zone = occupied[z]
                        local def = zone.def
                        if (def.damage or 0) > 0 then
                            local acc = (st.acc[zone] or 0) + dt
                            local interval = def.interval or 1
                            -- The same epsilon rule effect durations and the
                            -- respawn wait follow: an interval that is an
                            -- exact multiple of the tick bites on that tick,
                            -- not one late — 120 sixtieths is not quite 2.0.
                            while acc >= interval - 1e-9 do
                                acc = acc - interval
                                local applied, why = Damage.applyWith(
                                    e, def.damage, def.effects, {
                                        tags = def.tags,
                                        id = 'hazard.' .. zone.kind,
                                    })
                                bites[#bites + 1] = {
                                    entity = e, kind = zone.kind,
                                    damage = def.damage,
                                    result = applied,
                                    reason = (not applied) and why or nil,
                                }
                            end
                            st.acc[zone] = acc
                        end
                    end
                end
            elseif st then
                -- Dry land: the grace resets, so dipping in and out of lava
                -- forever is never charged. That is Doom's rule too.
                self.state[e] = nil
            end
        end
    end

    return bites
end

return Hazards
