--[[
    meatray.game.effects — gameplay effects, and the container that holds them.

    An effect is the one way anything changes an attribute. Damage is an effect.
    Healing is an effect. A haste buff, a poison, a stun, a shield, the cost of
    an ability — all effects. That is not tidiness for its own sake: it is what
    makes them compose. A resistance is a multiplier on incoming effects that
    carry a matching tag, so it applies to a melee hit, an explosion and the
    fourth tick of a poison without any of those three knowing that resistances
    exist. Written as functions instead — `takeDamage()`, `takeDoT()`,
    `takeExplosion()` — every new interaction is a new special case in every
    existing one, and that is the shape the bug reports take.

    Three durations:

        'instant'   executes once and is not stored. It changes `base`.
        number      stored, ticks down, expires. Modifies `cur`.
        'infinite'  stored until something removes it.

    A stored effect with a `period` executes its modifiers every period as well:
    damage over time and regeneration are the same mechanism, and both are
    instant executions on a timer rather than a slow drain, which is why they
    interact correctly with shields and resistances.

    ---------------------------------------------------------------------------
    Stacking
    ---------------------------------------------------------------------------

        'independent'  (default) every application is its own instance with its
                       own duration. Three poisons tick three times.
        'refresh'      one instance; reapplying resets its remaining duration.
        'stack'        one instance carrying a count, capped by `limit`.
                       Additive magnitudes are multiplied by the count;
                       multiplicative ones are raised to it, so two x0.9 stacks
                       are x0.81 rather than x1.8 — the only reading under which
                       stacking a reduction cannot flip its sign.
                       `refreshOnStack` also resets the duration.

    ---------------------------------------------------------------------------
    Authority
    ---------------------------------------------------------------------------

    Applying an effect is a host operation and the container knows whether it is
    the host: `Effects.apply` on a container with `authority = false` refuses and
    says so. This is the enforcement behind "damage is never predicted" — a
    client cannot reduce a health bar even by accident, because the only path to
    an attribute goes through a check it fails.

    A non-authoritative container still ticks: durations run down so a client can
    fade a buff icon out, but no modifier executes and no attribute moves. What a
    client sees of an effect is the attribute values the host sends, plus the
    replicated tag string.

    ---------------------------------------------------------------------------
    Time
    ---------------------------------------------------------------------------

    `tick(target, dt, ctx)` takes dt and never reads a clock, and is called from
    inside the fixed simulation step, so a duration is a whole number of ticks on
    every machine. Expiry uses a 1e-9 epsilon so a duration that is an exact
    multiple of the step expires on that step rather than one later because
    thirty additions of 1/60 do not land exactly on 0.5.

    HEADLESS: this module must not touch love.graphics or any love drawing API.
]]

local Entity     = require('meatray.sim.entity')
local Tags       = require('meatray.game.tags')
local Attributes = require('meatray.game.attributes')

local Effects = {}

local EPS = Attributes.EPS
local MAX_PERIODS_PER_TICK = 1024   -- a stall must not become an infinite loop

---------------------------------------------------------------------------
-- Components
---------------------------------------------------------------------------

-- The ability system container. No netFields, on purpose and for the same
-- reason `brain` has none: effect instances, cooldowns and pending casts are
-- host bookkeeping. What a client needs is the attributes they produce, which
-- replicate on their own, and the tags they grant, which replicate below.
Effects.Component = Entity.component('gas')

-- The replicated view of the tag container: one sorted, space-separated string.
-- A string rather than a table because a table field in a netFields declaration
-- is shared by reference into the snapshot, and a listen server would then have
-- its host and its local client holding the same table.
--
-- This exists so a client can gate its own *prediction* honestly. A client that
-- cannot tell it is stunned will predict a dash the host is about to refuse, and
-- the correction is visible.
Effects.TagComponent = Entity.component('tags', { 'active' })

---------------------------------------------------------------------------
-- Definitions
---------------------------------------------------------------------------

local defs = {}

local VALID_OP = { add = true, mul = true, div = true, override = true }
local VALID_POLICY = { independent = true, refresh = true, stack = true }

local function checkTagList(list, what)
    if list == nil then return {} end
    if type(list) ~= 'table' then return nil, ('%s must be a list of tags'):format(what) end
    local out = {}
    for i = 1, #list do
        local ok, err = Tags.check(list[i])
        if not ok then return nil, ('%s: %s'):format(what, err) end
        out[i] = ok
    end
    return out
end

-- Turns a spec table into a definition, or explains why it cannot. Separate from
-- `define` so an ad-hoc effect built at runtime from numbers that came off the
-- network gets the same validation and reports rather than raises.
function Effects.compile(spec, id)
    if type(spec) ~= 'table' then
        return nil, ('an effect spec must be a table, got %s'):format(type(spec))
    end

    local duration = spec.duration or 'instant'
    if duration ~= 'instant' and duration ~= 'infinite' then
        local n = Attributes.number(duration)
        if n == nil or n <= 0 then
            return nil, ('duration must be a positive number, \'instant\' or \'infinite\', got %s')
                        :format(tostring(spec.duration))
        end
        duration = n
    end

    local period
    if spec.period ~= nil then
        period = Attributes.number(spec.period)
        if period == nil or period <= 0 then
            return nil, ('period must be a positive number, got %s'):format(tostring(spec.period))
        end
        if duration == 'instant' then
            return nil, 'an instant effect cannot have a period; it executes once'
        end
    end

    local modifiers = {}
    for i = 1, #(spec.modifiers or {}) do
        local m = spec.modifiers[i]
        if type(m) ~= 'table' then
            return nil, ('modifier %d is a %s, not a table'):format(i, type(m))
        end
        if type(m.attr) ~= 'string' or m.attr == '' then
            return nil, ('modifier %d names no attribute'):format(i)
        end
        local op = m.op or 'add'
        if not VALID_OP[op] then
            return nil, ('modifier %d has an unknown op %q'):format(i, tostring(m.op))
        end
        local mag = Attributes.number(m.magnitude)
        if mag == nil then
            return nil, ('modifier %d on %s has an unusable magnitude (%s)')
                        :format(i, m.attr, tostring(m.magnitude))
        end
        if op == 'div' and mag == 0 then
            return nil, ('modifier %d on %s divides by zero'):format(i, m.attr)
        end
        modifiers[i] = {
            attr = m.attr, op = op, magnitude = mag,
            priority = Attributes.number(m.priority) or 0,
            bypassSoak = m.bypassSoak and true or false,
        }
    end

    local incoming = {}
    for i = 1, #(spec.incoming or {}) do
        local r = spec.incoming[i]
        if type(r) ~= 'table' then
            return nil, ('resistance %d is a %s, not a table'):format(i, type(r))
        end
        local ok, err = Tags.check(r.tag)
        if not ok then return nil, ('resistance %d: %s'):format(i, err) end
        local mag = Attributes.number(r.magnitude)
        if mag == nil or mag < 0 then
            return nil, ('resistance %d on %s needs a magnitude of 0 or more (%s)')
                        :format(i, r.tag, tostring(r.magnitude))
        end
        incoming[i] = { tag = ok, magnitude = mag }
    end

    local lists, err = {}, nil
    for _, key in ipairs({ 'grantedTags', 'assetTags', 'requiredTags',
                           'blockedTags', 'immunityTags', 'removesTags' }) do
        lists[key], err = checkTagList(spec[key], key)
        if not lists[key] then return nil, err end
    end

    local stacking = spec.stacking or {}
    local policy = stacking.policy or 'independent'
    if not VALID_POLICY[policy] then
        return nil, ('unknown stacking policy %q'):format(tostring(policy))
    end
    local limit = Attributes.number(stacking.limit) or math.huge
    if limit ~= math.huge and limit < 1 then
        return nil, 'a stack limit below 1 would make the effect unappliable'
    end

    local chance = spec.chance
    if chance ~= nil then
        chance = Attributes.number(chance)
        if chance == nil or chance < 0 or chance > 1 then
            return nil, ('chance must be between 0 and 1, got %s'):format(tostring(spec.chance))
        end
    end

    return {
        id          = id or spec.id or '(anonymous)',
        duration    = duration,
        period      = period,
        executeOnApply = spec.executeOnApply and true or false,
        modifiers   = modifiers,
        incoming    = incoming,
        grantedTags = lists.grantedTags,
        assetTags   = lists.assetTags,
        requiredTags = lists.requiredTags,
        blockedTags = lists.blockedTags,
        immunityTags = lists.immunityTags,
        removesTags = lists.removesTags,
        stacking    = { policy = policy, limit = limit,
                        refreshOnStack = stacking.refreshOnStack ~= false,
                        bySource = stacking.bySource and true or false },
        chance      = chance,
        onApply     = spec.onApply,
        onExecute   = spec.onExecute,
        onExpire    = spec.onExpire,
        onRemove    = spec.onRemove,
    }
end

function Effects.define(id, spec)
    assert(type(id) == 'string' and id ~= '', 'an effect needs an id')
    local def, err = Effects.compile(spec, id)
    assert(def, err)
    defs[id] = def
    return def
end

function Effects.definition(id)
    return defs[id]
end

function Effects.ids()
    local out = {}
    for id in pairs(defs) do out[#out + 1] = id end
    table.sort(out)
    return out
end

function Effects.reset()
    defs = {}
    return Effects
end

-- Capture/restore, matching Entity.captureArchetypes: a hot reload that raises
-- halfway through a definitions file must be able to put everything back.
function Effects.capture()
    local out = {}
    for id, def in pairs(defs) do out[id] = def end
    return out
end

function Effects.restore(captured)
    defs = {}
    for id, def in pairs(captured or {}) do defs[id] = def end
end

---------------------------------------------------------------------------
-- The container
---------------------------------------------------------------------------

--[[
    Attaches an ability system to an entity.

        Effects.attach(player, { authority = host and true or false })

    `authority` defaults to true, which is right for a single-player game, a
    listen server's own simulation and a dedicated server. A client sets it to
    false and thereby loses the ability to move its own attributes.
]]
function Effects.attach(e, opts)
    opts = opts or {}
    assert(type(e) == 'table' and type(e.components) == 'table', 'attach needs an entity')

    local gas = e.components.gas
    if not gas then
        gas = Effects.Component{}
        e:add(gas)
    end

    gas.authority      = opts.authority ~= false
    gas.tags           = gas.tags or Tags.newContainer()
    gas.effects        = gas.effects or {}
    gas.cooldowns      = gas.cooldowns or {}
    gas.casts          = gas.casts or {}
    gas.abilities      = gas.abilities or {}
    gas.predictions    = gas.predictions or {}
    gas.nextOrdinal    = gas.nextOrdinal or 1
    gas.nextPrediction = gas.nextPrediction or 1
    gas.time           = gas.time or 0

    if opts.tags ~= false and not e.components.tags then
        e:add(Effects.TagComponent{ active = '' })
    end

    Effects.syncTags(e)
    return gas
end

function Effects.system(e)
    if type(e) ~= 'table' or type(e.components) ~= 'table' then return nil end
    return e.components.gas
end

function Effects.tags(e)
    local gas = Effects.system(e)
    return gas and gas.tags or nil
end

-- Mirrors the tag container into its replicated string. Called after every
-- change, so the wire form can never disagree with the container.
function Effects.syncTags(e)
    local gas = Effects.system(e)
    if not gas then return nil end
    local comp = e.components.tags
    if comp then comp.active = gas.tags:toString() end
    return gas.tags
end

-- Does this entity have the tag, hierarchically? Answers from the container on
-- a host and from the replicated string on a client, so gameplay code asks the
-- same question on both sides.
function Effects.hasTag(e, query)
    local gas = Effects.system(e)
    if gas then return gas.tags:has(query) end
    local comp = e and e.components and e.components.tags
    if comp then return Tags.stringHas(comp.active, query) end
    return false
end

---------------------------------------------------------------------------
-- Modifier execution
---------------------------------------------------------------------------

-- The product of every active resistance whose query matches one of the applied
-- effect's asset tags. Multiplication commutes, so no ordering is needed for
-- this to be deterministic.
local function incomingScale(gas, assetTags)
    if not assetTags or #assetTags == 0 then return 1 end

    local scale = 1
    for i = 1, #gas.effects do
        local inst = gas.effects[i]
        local incoming = inst.def.incoming
        for k = 1, #incoming do
            local entry = incoming[k]
            for a = 1, #assetTags do
                if Tags.matches(assetTags[a], entry.tag) then
                    scale = scale * (entry.magnitude ^ (inst.stacks or 1))
                    break
                end
            end
        end
    end

    return scale
end

-- Runs a definition's modifiers against `base` values, once. Used by instant
-- effects and by each period of a periodic one. Returns an array of per-
-- attribute results, in modifier declaration order.
local function executeModifiers(target, def, stacks, ctx)
    local gas = Effects.system(target)
    if not gas then return {} end

    stacks = stacks or 1
    local scale = incomingScale(gas, def.assetTags)

    -- Group by attribute, keeping first-declared order so the results array is
    -- the same on every machine.
    local order, byAttr, bypass = {}, {}, {}
    for i = 1, #def.modifiers do
        local m = def.modifiers[i]
        if not byAttr[m.attr] then
            byAttr[m.attr] = {}
            order[#order + 1] = m.attr
        end

        local mag = m.magnitude
        if m.op == 'add' then
            mag = mag * stacks
        elseif m.op == 'mul' or m.op == 'div' then
            mag = mag ^ stacks
        end

        local list = byAttr[m.attr]
        list[#list + 1] = { op = m.op, magnitude = mag, ordinal = 0,
                            index = i, priority = m.priority }
        if m.bypassSoak then bypass[m.attr] = true end
    end

    local results = {}
    for i = 1, #order do
        local attr = order[i]
        if Attributes.has(target, attr) then
            local base = Attributes.base(target, attr)
            local want = Attributes.combine(base, byAttr[attr])
            local delta = (want - base) * scale
            if delta ~= 0 then
                local r = Attributes.applyDelta(target, attr, delta,
                                                { bypassSoak = bypass[attr] })
                if r then results[#results + 1] = r end
            end
        end
    end

    if def.onExecute then def.onExecute(target, def, results, ctx) end
    return results
end

-- Every modifier every stored effect contributes to one attribute, tagged with
-- the ordinal of the effect that contributed it so the fold has a total order.
local function gather(gas, attr)
    local out = {}
    for i = 1, #gas.effects do
        local inst = gas.effects[i]
        local mods = inst.def.modifiers
        for j = 1, #mods do
            local m = mods[j]
            if m.attr == attr then
                local mag = m.magnitude
                local stacks = inst.stacks or 1
                if m.op == 'add' then
                    mag = mag * stacks
                elseif m.op == 'mul' or m.op == 'div' then
                    mag = mag ^ stacks
                end
                out[#out + 1] = { op = m.op, magnitude = mag,
                                  ordinal = inst.ordinal, index = j,
                                  priority = m.priority }
            end
        end
    end
    return out
end

-- Recomputes every attribute the entity carries, ceilings first. Cheap: there
-- are a handful of attributes and the alternative — tracking exactly which ones
-- a change could have touched — is a cache with an invalidation bug in it.
function Effects.recompute(target)
    local gas = Effects.system(target)
    local ordered = Attributes.orderedNames()

    for i = 1, #ordered do
        local name = ordered[i]
        if Attributes.has(target, name) then
            Attributes.recompute(target, name, gas and gather(gas, name) or nil)
        end
    end

    return target
end

---------------------------------------------------------------------------
-- Application
---------------------------------------------------------------------------

local function grantTags(gas, def)
    for i = 1, #def.grantedTags do gas.tags:add(def.grantedTags[i], 1) end
end

local function revokeTags(gas, def, stacks)
    for i = 1, #def.grantedTags do gas.tags:remove(def.grantedTags[i], 1) end
end

-- Is any active effect immune to this one?
local function immuneTo(gas, def)
    if #def.assetTags == 0 then return nil end
    for i = 1, #gas.effects do
        local queries = gas.effects[i].def.immunityTags
        for k = 1, #queries do
            for a = 1, #def.assetTags do
                if Tags.matches(def.assetTags[a], queries[k]) then
                    return queries[k]
                end
            end
        end
    end
    return nil
end

local function findInstance(gas, def, source)
    for i = 1, #gas.effects do
        local inst = gas.effects[i]
        if inst.def.id == def.id and (not def.stacking.bySource or inst.source == source) then
            return inst, i
        end
    end
    return nil
end

-- A duration or infinite modifier on a pool attribute cannot be reverted,
-- because the pool's current value is its base value. Refusing at application
-- time and naming the attribute is worth far more than the alternative, which is
-- a buff that becomes permanent and looks like an attribute bug.
local function checkPoolModifiers(def)
    -- An instant effect writes the pool directly, and a periodic one executes
    -- instantly on every period — both are fine, and damage over time is exactly
    -- the second. What cannot work is a *lasting* modifier with no period: it
    -- would never execute, and the recompute that would normally fold it in is
    -- the same write that produced its base. It would silently do nothing.
    if def.duration == 'instant' or def.period then return true end
    for i = 1, #def.modifiers do
        local attrDef = Attributes.definition(def.modifiers[i].attr)
        if attrDef and attrDef.pool then
            return nil, ('%s lasts, and %s is a pool: buff its ceiling (%s) or use a period instead')
                        :format(def.id, attrDef.name, tostring(attrDef.ceiling or 'its maximum'))
        end
    end
    return true
end

--[[
    Applies a definition to a target.

    Returns a result table, or nil plus a reason. The reasons are strings meant
    to be read by a person and matched by a test:

        'no ability system'      the target has no container
        'not authoritative'      a client tried to change an attribute
        'unknown effect: x'
        'chance'                 rolled and missed
        'no rng'                 a chance effect with no deterministic rng
        'missing tag: x'         a required tag the target does not have
        'blocked by tag: x'
        'immune: x'
        'stack limit'
        plus the pool-modifier refusal above
]]
function Effects.applyDef(target, def, ctx)
    ctx = ctx or {}

    local gas = Effects.system(target)
    if not gas then return nil, 'no ability system' end
    if not gas.authority then return nil, 'not authoritative' end

    local okPool, poolErr = checkPoolModifiers(def)
    if not okPool then return nil, poolErr end

    if def.chance and def.chance < 1 then
        local rng = ctx.rng
        -- math.random is not an option: its sequence differs between LuaJIT and
        -- stock Lua, so a host and a client rolling the same proc would disagree.
        -- Refusing is the honest answer; falling back would be a silent
        -- desynchronisation.
        if type(rng) ~= 'table' or type(rng.float) ~= 'function' then
            return nil, 'no rng'
        end
        if rng:float() >= def.chance then return nil, 'chance' end
    end

    if #def.requiredTags > 0 then
        local ok, missing = gas.tags:hasAll(def.requiredTags)
        if not ok then return nil, 'missing tag: ' .. tostring(missing) end
    end

    if #def.blockedTags > 0 then
        local blocked, which = gas.tags:hasAny(def.blockedTags)
        if blocked then return nil, 'blocked by tag: ' .. tostring(which) end
    end

    local immune = immuneTo(gas, def)
    if immune then return nil, 'immune: ' .. immune end

    -- Cleansing runs before application so an effect can remove the thing it
    -- replaces.
    local cleansed = 0
    for i = 1, #def.removesTags do
        cleansed = cleansed + Effects.removeWithTag(target, def.removesTags[i], ctx)
    end

    ---------------------------------------------------------------------
    -- Instant: execute and vanish.
    ---------------------------------------------------------------------
    if def.duration == 'instant' then
        local results = executeModifiers(target, def, 1, ctx)
        Effects.recompute(target)
        if def.onApply then def.onApply(target, def, nil, ctx) end
        return { instant = true, id = def.id, results = results, cleansed = cleansed }
    end

    ---------------------------------------------------------------------
    -- Stored: stacking decides whether this is a new instance.
    ---------------------------------------------------------------------
    local policy = def.stacking.policy
    local existing = (policy ~= 'independent') and findInstance(gas, def, ctx.source) or nil

    if existing then
        local refreshed, stacked = false, false

        if policy == 'refresh' then
            existing.remaining = existing.duration
            refreshed = true
        elseif policy == 'stack' then
            if existing.stacks >= def.stacking.limit then
                if def.stacking.refreshOnStack then
                    existing.remaining = existing.duration
                    refreshed = true
                else
                    return nil, 'stack limit'
                end
            else
                existing.stacks = existing.stacks + 1
                stacked = true
                if def.stacking.refreshOnStack then
                    existing.remaining = existing.duration
                    refreshed = true
                end
            end
        end

        Effects.recompute(target)
        Effects.syncTags(target)

        return { instance = existing, id = def.id, refreshed = refreshed,
                 stacked = stacked, stacks = existing.stacks, cleansed = cleansed }
    end

    local inst = {
        def         = def,
        id          = def.id,
        ordinal     = gas.nextOrdinal,
        handle      = gas.nextOrdinal,
        stacks      = 1,
        source      = ctx.source,
        duration    = (def.duration ~= 'infinite') and def.duration or nil,
        remaining   = (def.duration ~= 'infinite') and def.duration or nil,
        period      = def.period,
        periodAccum = 0,
        active      = true,
    }
    gas.nextOrdinal = gas.nextOrdinal + 1

    gas.effects[#gas.effects + 1] = inst
    grantTags(gas, def)

    if def.period and def.executeOnApply then
        executeModifiers(target, def, inst.stacks, ctx)
    end

    Effects.recompute(target)
    Effects.syncTags(target)

    if def.onApply then def.onApply(target, def, inst, ctx) end

    return { instance = inst, id = def.id, stacks = 1, cleansed = cleansed }
end

function Effects.apply(target, id, ctx)
    local def = defs[id]
    if not def then return nil, ('unknown effect: %s'):format(tostring(id)) end
    return Effects.applyDef(target, def, ctx)
end

-- An effect built at the call site rather than registered. This is the path
-- damage takes, and it is why `compile` reports instead of raising: the amount
-- may have come from a weapon table, a config file or a network message.
function Effects.applySpec(target, spec, ctx)
    local def, err = Effects.compile(spec, spec and spec.id or 'dynamic')
    if not def then return nil, err end
    return Effects.applyDef(target, def, ctx)
end

---------------------------------------------------------------------------
-- Removal
---------------------------------------------------------------------------

local function detach(target, gas, index, ctx, reason)
    local inst = gas.effects[index]
    inst.active = false
    table.remove(gas.effects, index)
    revokeTags(gas, inst.def)
    if inst.def.onRemove then inst.def.onRemove(target, inst.def, inst, ctx, reason) end
    return inst
end

-- Removes one instance, by instance table or by handle.
function Effects.remove(target, instance, ctx)
    local gas = Effects.system(target)
    if not gas then return 0 end

    for i = 1, #gas.effects do
        local inst = gas.effects[i]
        if inst == instance or inst.handle == instance then
            detach(target, gas, i, ctx, 'removed')
            Effects.recompute(target)
            Effects.syncTags(target)
            return 1
        end
    end

    return 0
end

-- Removes every instance of a definition. Returns how many went.
function Effects.removeById(target, id, ctx)
    local gas = Effects.system(target)
    if not gas then return 0 end

    local removed = 0
    for i = #gas.effects, 1, -1 do
        if gas.effects[i].def.id == id then
            detach(target, gas, i, ctx, 'removed')
            removed = removed + 1
        end
    end

    if removed > 0 then
        Effects.recompute(target)
        Effects.syncTags(target)
    end

    return removed
end

-- Removes every instance whose asset tags match the query, hierarchically. This
-- is what a cleanse is: `removeWithTag(e, 'debuff')` takes the poison, the slow
-- and the curse without naming any of them.
function Effects.removeWithTag(target, query, ctx)
    local gas = Effects.system(target)
    if not gas then return 0 end

    local removed = 0
    for i = #gas.effects, 1, -1 do
        local assetTags = gas.effects[i].def.assetTags
        local hit = false
        for a = 1, #assetTags do
            if Tags.matches(assetTags[a], query) then hit = true break end
        end
        if hit then
            detach(target, gas, i, ctx, 'cleansed')
            removed = removed + 1
        end
    end

    if removed > 0 then
        Effects.recompute(target)
        Effects.syncTags(target)
    end

    return removed
end

function Effects.clear(target, ctx)
    local gas = Effects.system(target)
    if not gas then return 0 end

    local removed = #gas.effects
    for i = #gas.effects, 1, -1 do detach(target, gas, i, ctx, 'cleared') end

    Effects.recompute(target)
    Effects.syncTags(target)
    return removed
end

---------------------------------------------------------------------------
-- Queries
---------------------------------------------------------------------------

function Effects.instances(target)
    local gas = Effects.system(target)
    return gas and gas.effects or {}
end

function Effects.find(target, id)
    local gas = Effects.system(target)
    if not gas then return nil end
    for i = 1, #gas.effects do
        if gas.effects[i].def.id == id then return gas.effects[i] end
    end
    return nil
end

function Effects.count(target, id)
    local gas = Effects.system(target)
    if not gas then return 0 end
    local n = 0
    for i = 1, #gas.effects do
        if gas.effects[i].def.id == id then n = n + 1 end
    end
    return n
end

function Effects.stacks(target, id)
    local inst = Effects.find(target, id)
    return inst and inst.stacks or 0
end

function Effects.remaining(target, id)
    local inst = Effects.find(target, id)
    return inst and inst.remaining or nil
end

---------------------------------------------------------------------------
-- The tick
---------------------------------------------------------------------------

--[[
    Advances every stored effect by one simulation step.

    Returns the number of effects that expired and the number of periodic
    executions that ran, which is what a test wants to assert and what a netgraph
    wants to draw.

    `dt` is the fixed step. It is validated: a NaN dt would make every remaining
    duration NaN, every comparison against it false, and every effect on the
    entity permanent.
]]
function Effects.tick(target, dt, ctx)
    local gas = Effects.system(target)
    if not gas then return 0, 0 end

    local step = Attributes.number(dt)
    if step == nil or step <= 0 then return 0, 0 end

    gas.time = gas.time + step

    local executions = 0

    -- Iterate a copy. A periodic effect's onExecute may remove effects — its own
    -- included, which is how a "three ticks then gone" poison is written — and
    -- mutating the array underneath the loop would skip whatever slid into the
    -- vacated index. `active` is cleared on removal so the copy cannot resurrect
    -- something that has already been detached.
    local live = {}
    for i = 1, #gas.effects do live[i] = gas.effects[i] end

    for i = 1, #live do
        local inst = live[i]

        if inst.active and inst.period then
            inst.periodAccum = inst.periodAccum + step
            local guard = 0
            while inst.periodAccum >= inst.period - EPS and guard < MAX_PERIODS_PER_TICK do
                inst.periodAccum = inst.periodAccum - inst.period
                guard = guard + 1
                -- A client ticks the clock so its icons are right and executes
                -- nothing, because executing would move an attribute.
                if gas.authority then
                    executeModifiers(target, inst.def, inst.stacks, ctx)
                    executions = executions + 1
                end
            end
        end

        if inst.active and inst.remaining then
            inst.remaining = inst.remaining - step
            if inst.remaining <= EPS then inst.expired = true end
        end
    end

    local expired = 0
    for i = #gas.effects, 1, -1 do
        if gas.effects[i].expired then
            local inst = gas.effects[i]
            inst.active = false
            table.remove(gas.effects, i)
            revokeTags(gas, inst.def)
            if inst.def.onExpire then inst.def.onExpire(target, inst.def, inst, ctx) end
            if inst.def.onRemove then inst.def.onRemove(target, inst.def, inst, ctx, 'expired') end
            expired = expired + 1
        end
    end

    if expired > 0 or executions > 0 then
        Effects.recompute(target)
        Effects.syncTags(target)
    end

    return expired, executions
end

return Effects
