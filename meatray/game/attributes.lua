--[[
    meatray.game.attributes — numeric stats that replicate and persist for free.

    An attribute is two numbers living in a component:

        base   the persistent value. Instant effects change this: damage, healing,
               paying a cost, a permanent upgrade.
        cur    the effective value gameplay reads. It is `base` recomputed from
               every active duration/infinite modifier, in the order documented
               below, then clamped.

    Both are declared `netFields`, so an attribute replicates through
    meatray.net.replication and persists through meatray.save.state with no edit
    to either. That is the whole reason attributes are components rather than a
    table hanging off the ability system: the engine already has one mechanism
    for "state that must reach a client and a save file", and a second one would
    be a second thing to keep in step.

    ---------------------------------------------------------------------------
    Reconciling with the existing Health component
    ---------------------------------------------------------------------------

    meatray/sim/components.lua already declares `health` with netFields
    { 'hp', 'max' }, and main.lua reads both. There is no second health here.
    The attribute system *adopts* that component:

        health      base and cur are BOTH `health.hp`
        healthMax   cur is `health.max`, base is `health.maxBase`

    So `health.hp` remains the live pool and `health.max` remains the effective
    maximum — every existing reader keeps working, unchanged, including the HUD.
    One field is new, `health.maxBase`, and it is added through the declaration
    mechanism the codebase advertises (`Attributes.declareField` appends to the
    component's netFields, idempotently), so it replicates and saves like
    everything else. It exists because a temporary "+20 maximum health" cannot be
    reverted correctly without knowing the unbuffed maximum: reverting by
    subtracting the delta you added is only right until something else changes
    the base underneath you, and then it is silently wrong forever.

    An entity built the old way — `C.Health{ hp = 30, max = 30 }` — is adopted
    lazily: `maxBase` is filled in from `max` the first time the attribute system
    touches it. Nothing has to be respawned and no archetype has to change.

    ---------------------------------------------------------------------------
    Pools and stats
    ---------------------------------------------------------------------------

    When `base` and `cur` name the same field the attribute is a POOL: one
    number that depletes and refills (health, armour, stamina). A pool takes
    instant modifiers only. Duration and infinite modifiers on a pool are refused
    with a message, because recomputing `cur` from `base` would write the result
    back into the slot it read `base` from, and the buff would become permanent
    on the first recompute. Buff the pool's ceiling instead (`healthMax`), or use
    a periodic instant effect (regeneration, damage over time) — which is how
    both are modelled in Unreal's GAS as well, for the same reason.

    ---------------------------------------------------------------------------
    THE MODIFIER ORDER — additive first, then multiplicative, then override
    ---------------------------------------------------------------------------

        cur = clamp( override  or  ((base + SUM(add)) * PRODUCT(mul)) )

    In full:

      1. Every `add` modifier is summed.       (+10, -3  ->  +7)
      2. Every `mul` modifier is multiplied.   (x1.5, x0.5 -> x0.75)
         `div` is folded into the same product as multiplication by 1/x.
      3. cur = (base + sum) * product.
      4. If any `override` modifier is active, it replaces the result entirely.
         Ties are broken by explicit `priority`, then by application order — never
         by which one `pairs()` happened to visit first.
      5. The result is clamped to [min, ceiling], where the ceiling is either the
         attribute's declared max or the current value of the attribute named by
         `ceiling` (health's ceiling is healthMax), whichever is smaller.

    Additive-then-multiplicative is a choice and the other order is a different
    game: with +10 then x2 on a base of 100, this gives 220; multiplicative first
    gives 210. Picking one and writing it down is the requirement. This order is
    chosen because it makes a multiplier scale-free — a x1.5 haste is always
    "half again as much as you actually have", including whatever flat bonuses
    you are carrying — and because it is what GAS does, which matters for anyone
    arriving from that background.

    The computation is independent of table iteration order *by construction*:
    addition and multiplication each commute, so the two buckets can be filled in
    any order, and the only non-commutative operation (override) is resolved by
    an explicit comparison rather than by arrival. `combine` still sorts before
    folding, so floating-point association is fixed too and two hosts with
    differently-hashed tables produce bit-identical numbers.

    ---------------------------------------------------------------------------
    Validation
    ---------------------------------------------------------------------------

    Nothing non-finite is ever stored. A NaN attribute is worse than a wrong one:
    it propagates through every expression that touches it, survives every
    comparison (`nan < max` is false, so a naive clamp lets it through), and
    reaches other players in the next snapshot. Every write goes through
    meatray.net.replication's `finite`, which is exported for exactly this.

    HEADLESS: this module must not touch love.graphics or any love drawing API.
]]

local Entity = require('meatray.sim.entity')
local C      = require('meatray.sim.components')
local Rep    = require('meatray.net.replication')
local Tags   = require('meatray.game.tags')

local Attributes = {}

local EPS         = 1e-9
local DEFAULT_MAX = 1e9

-- The bound beyond which a number is refused outright rather than clamped.
-- Doubles stop representing consecutive integers at 2^53 (about 9e15), so a
-- value past this point is not a large stat, it is a bug or an attack, and
-- storing it would make every later arithmetic result meaningless.
local SANITY = 1e15

Attributes.EPS = EPS
Attributes.DEFAULT_MAX = DEFAULT_MAX
Attributes.SANITY = SANITY

-- Rank decides the fold order in `combine`. It is not the same thing as the
-- documented application order (adds are summed regardless of rank); it exists
-- so the sort is a total order and therefore deterministic.
local OP_RANK = { add = 1, mul = 2, div = 2, override = 3 }

Attributes.OPS = { 'add', 'mul', 'div', 'override' }

local defs    = {}
local orderedCache = nil

---------------------------------------------------------------------------
-- Numbers
---------------------------------------------------------------------------

-- A finite number, or nil. `Rep.finite` is the codebase's one answer to this
-- question and is exported for game code; duplicating it here would be a second
-- definition of "usable number" to keep in step with the first.
function Attributes.number(v)
    return Rep.finite(v, -SANITY, SANITY)
end

---------------------------------------------------------------------------
-- Declaration
---------------------------------------------------------------------------

-- Appends a field to a component's netFields, once. This is the mechanism the
-- engine already advertises — "adding a synced field is one edit" — used from
-- the outside instead of by editing components.lua, so an attribute a game
-- defines replicates and saves on exactly the same terms as one the engine
-- defines. Returns true if it was added, false if it was already declared.
function Attributes.declareField(component, field)
    assert(type(component) == 'table' and type(component.netFields) == 'table',
           'declareField needs a component definition from Entity.component')
    assert(type(field) == 'string' and field ~= '', 'declareField needs a field name')

    local fields = component.netFields
    for i = 1, #fields do
        if fields[i] == field then return false end
    end

    fields[#fields + 1] = field
    return true
end

-- Components this module owns. Cached so a reset() reuses the same definitions
-- rather than minting new ones that existing entity instances would not match.
local ownComponents = {}

local function ownComponent(name, fields)
    local existing = ownComponents[name]
    if existing then return existing end
    local component = Entity.component(name, fields)
    ownComponents[name] = component
    return component
end

--[[
    Declares an attribute.

        Attributes.define('moveSpeed', {
            component = 'movespeed',   -- component name, or a component def
            base = 'base', cur = 'cur',
            min = 0, max = 40,
            default = 3.2,
        })

    `ceiling` names another attribute whose current value caps this one.
    `soak` names another attribute that absorbs negative deltas first — that is
    what makes armour a shield rather than a special case inside the damage code.
    `replicated = false` keeps the fields off the wire, for a stat a client can
    recompute or has no business seeing.
]]
function Attributes.define(name, spec)
    assert(type(name) == 'string' and name ~= '', 'an attribute needs a name')
    spec = spec or {}

    local component = spec.component
    if type(component) == 'string' then
        component = ownComponent(component, {})
    end
    assert(type(component) == 'table' and type(component.netFields) == 'table',
           ('attribute %s needs a component'):format(name))

    local base = spec.base or 'base'
    local cur  = spec.cur or spec.current or base
    assert(type(base) == 'string' and type(cur) == 'string',
           ('attribute %s needs field names'):format(name))

    local min = spec.min or 0
    local max = spec.max or DEFAULT_MAX
    assert(Attributes.number(min) and Attributes.number(max) and min <= max,
           ('attribute %s has an unusable range'):format(name))

    local default = spec.default or 0
    assert(Attributes.number(default), ('attribute %s has an unusable default'):format(name))

    if spec.replicated ~= false then
        Attributes.declareField(component, base)
        if cur ~= base then Attributes.declareField(component, cur) end
    end

    local def = {
        name          = name,
        component     = component,
        componentName = component.name,
        base          = base,
        cur           = cur,
        pool          = (base == cur),
        min           = min,
        max           = max,
        default       = default,
        ceiling       = spec.ceiling,
        soak          = spec.soak,
        tags          = spec.tags,
    }

    defs[name] = def
    orderedCache = nil

    return def
end

function Attributes.definition(name)
    return defs[name]
end

function Attributes.isDefined(name)
    return defs[name] ~= nil
end

function Attributes.names()
    local out = {}
    for name in pairs(defs) do out[#out + 1] = name end
    table.sort(out)
    return out
end

-- Attributes in the order they must be recomputed: a ceiling before whatever it
-- caps, so health is never clamped against a stale healthMax. Ties are broken by
-- name, so the order is the same on every machine.
function Attributes.orderedNames()
    if orderedCache then return orderedCache end

    local rank = {}

    local function rankOf(name, seen)
        if rank[name] then return rank[name] end
        local def = defs[name]
        if not def then return 0 end

        seen = seen or {}
        if seen[name] then
            error(('attribute ceilings form a cycle at %q'):format(name), 0)
        end
        seen[name] = true

        local r = 0
        if def.ceiling and defs[def.ceiling] then
            r = rankOf(def.ceiling, seen) + 1
        end
        seen[name] = nil

        rank[name] = r
        return r
    end

    local out = Attributes.names()
    for i = 1, #out do rankOf(out[i]) end
    table.sort(out, function(a, b)
        if rank[a] ~= rank[b] then return rank[a] < rank[b] end
        return a < b
    end)

    orderedCache = out
    return out
end

---------------------------------------------------------------------------
-- The modifier fold
---------------------------------------------------------------------------

-- See the header. `mods` is an array of { op, magnitude, ordinal, index,
-- priority }. `ordinal` is the application order of the effect that contributed
-- it and `index` its position within that effect, which together make the sort
-- a total order.
function Attributes.combine(base, mods)
    base = Attributes.number(base) or 0
    if not mods or #mods == 0 then return base end

    local list = {}
    for i = 1, #mods do list[i] = mods[i] end

    table.sort(list, function(a, b)
        local ra = OP_RANK[a.op] or 99
        local rb = OP_RANK[b.op] or 99
        if ra ~= rb then return ra < rb end
        local oa, ob = a.ordinal or 0, b.ordinal or 0
        if oa ~= ob then return oa < ob end
        return (a.index or 0) < (b.index or 0)
    end)

    local add, mul = 0, 1
    local override, overridePriority, overrideOrdinal

    for i = 1, #list do
        local m = list[i]
        local mag = Attributes.number(m.magnitude)
        if mag then
            if m.op == 'add' then
                add = add + mag
            elseif m.op == 'mul' then
                mul = mul * mag
            elseif m.op == 'div' then
                -- A divide by zero would be an infinity, which is the one thing
                -- an attribute may never hold. Refusing the modifier is better
                -- than poisoning the stat, and better than silently treating it
                -- as x1 without saying so anywhere.
                if mag ~= 0 then mul = mul / mag end
            elseif m.op == 'override' then
                local p = m.priority or 0
                local o = m.ordinal or 0
                if override == nil
                   or p > overridePriority
                   or (p == overridePriority and o >= overrideOrdinal) then
                    override, overridePriority, overrideOrdinal = mag, p, o
                end
            end
        end
    end

    local value
    if override ~= nil then
        value = override
    else
        value = (base + add) * mul
    end

    -- The fold can still produce something unusable from usable parts:
    -- 1e9 * 1e9 overflows the declared range, and a huge product of huge
    -- multipliers reaches infinity. Fall back to the base rather than store it.
    return Attributes.number(value) or base
end

---------------------------------------------------------------------------
-- Per-entity access
---------------------------------------------------------------------------

local function componentOf(e, def)
    return e and e.components and e.components[def.componentName]
end

function Attributes.has(e, name)
    local def = defs[name]
    if not def then return false end
    local comp = componentOf(e, def)
    -- Either field being present is enough: an entity built before the attribute
    -- system existed carries `health.max` but no `health.maxBase`, and adopting
    -- it is the whole point.
    return comp ~= nil and (comp[def.base] ~= nil or comp[def.cur] ~= nil)
end

-- Fills in a base that an older archetype never set. `C.Health{ hp = 30,
-- max = 30 }` carries no `maxBase`; adopting it from `max` is what lets the
-- attribute system take over an entity built before it existed.
local function adopt(e, def, comp)
    if comp[def.base] == nil then
        local seed = comp[def.cur]
        if seed == nil then seed = def.default end
        comp[def.base] = Attributes.number(seed) or def.default
    end
    if comp[def.cur] == nil then
        comp[def.cur] = comp[def.base]
    end
    return comp
end

-- The current (effective) value, or nil if the entity has no such attribute.
function Attributes.get(e, name)
    local def = defs[name]
    if not def then return nil end
    local comp = componentOf(e, def)
    if not comp or comp[def.base] == nil and comp[def.cur] == nil then return nil end
    adopt(e, def, comp)
    return comp[def.cur]
end

function Attributes.base(e, name)
    local def = defs[name]
    if not def then return nil end
    local comp = componentOf(e, def)
    if not comp or comp[def.base] == nil and comp[def.cur] == nil then return nil end
    adopt(e, def, comp)
    return comp[def.base]
end

-- The upper bound this attribute may reach right now: its declared max, or the
-- current value of the attribute named by `ceiling`, whichever is lower.
function Attributes.limit(e, name)
    local def = defs[name]
    if not def then return nil end

    local max = def.max
    if def.ceiling then
        local ceiling = Attributes.get(e, def.ceiling)
        if ceiling ~= nil and ceiling < max then max = ceiling end
    end

    return max
end

function Attributes.clamp(e, name, v)
    local def = defs[name]
    if not def then return nil end

    local n = Attributes.number(v)
    if n == nil then return nil end

    local max = Attributes.limit(e, name)
    if n < def.min then n = def.min end
    if n > max then n = max end

    return n
end

-- Attaches the attribute to an entity, creating its component if needed.
-- Returns the base value that was stored, or nil plus a reason.
function Attributes.grant(e, name, value)
    local def = defs[name]
    if not def then return nil, ('unknown attribute %q'):format(tostring(name)) end
    if type(e) ~= 'table' or type(e.components) ~= 'table' then
        return nil, 'grant needs an entity'
    end

    local comp = componentOf(e, def)
    if not comp then
        comp = def.component{}
        e:add(comp)
    end

    if value == nil then value = def.default end
    local n = Attributes.number(value)
    if n == nil then
        return nil, ('%s cannot be set to %s'):format(name, tostring(value))
    end

    if n < def.min then n = def.min end
    if n > def.max then n = def.max end

    comp[def.base] = n
    comp[def.cur]  = Attributes.clamp(e, name, n) or n

    return comp[def.base]
end

-- Grants several at once: { health = 100, healthMax = 100, stamina = 50 }.
-- Applied in ceiling order so a pool is never clamped against a ceiling that
-- has not been set yet.
function Attributes.grantAll(e, values)
    local ordered = Attributes.orderedNames()
    for i = 1, #ordered do
        local name = ordered[i]
        if values[name] ~= nil then Attributes.grant(e, name, values[name]) end
    end
    return e
end

-- Writes the base value. Validated, clamped, never non-finite. `cur` is set
-- provisionally from the new base; the effect system recomputes it properly
-- straight afterwards, and an entity with no effects is already correct.
--
-- Returns the stored value and the delta actually applied, or nil plus a reason.
function Attributes.setBase(e, name, value)
    local def = defs[name]
    if not def then return nil, ('unknown attribute %q'):format(tostring(name)) end
    if not Attributes.has(e, name) then
        return nil, ('this entity has no %s'):format(name)
    end

    local n = Attributes.number(value)
    if n == nil then
        return nil, ('%s cannot be set to %s'):format(name, tostring(value))
    end

    -- Through the accessor, so an entity carrying only the old fields is adopted
    -- before anything is written to it.
    local before = Attributes.base(e, name)
    local comp   = componentOf(e, def)

    local stored = Attributes.clamp(e, name, n)
    comp[def.base] = stored
    -- One slot for a pool; for a stat this is provisional — the effect system
    -- recomputes `cur` from the modifier set immediately afterwards, and an
    -- entity with no effects is already correct at this value.
    comp[def.cur] = stored

    return stored, stored - before
end

-- Recomputes `cur` from `base` and the modifiers handed in. This is the only
-- writer of `cur` for a non-pool attribute.
function Attributes.recompute(e, name, mods)
    local def = defs[name]
    if not def then return nil end
    if not Attributes.has(e, name) then return nil end

    local base = Attributes.base(e, name)
    local comp = componentOf(e, def)

    if def.pool then
        -- Nothing to fold: a pool refuses duration modifiers, so its current
        -- value is its base. Re-clamping still matters — a healthMax that just
        -- dropped must pull hp down with it.
        local clamped = Attributes.clamp(e, name, base)
        comp[def.base] = clamped
        comp[def.cur]  = clamped
        return clamped
    end

    local value = Attributes.clamp(e, name, Attributes.combine(base, mods))
    if value == nil then value = Attributes.clamp(e, name, base) or def.min end
    comp[def.cur] = value

    return value
end

--[[
    Moves an attribute by a delta, honouring soak.

    This is how damage lands. `soak` is what makes armour a shield without the
    damage path knowing anything about armour: health declares `soak = 'armour'`,
    a negative delta drains armour first and only the remainder reaches health,
    and damage-over-time, explosions and melee all get that behaviour without
    each implementing it. `opts.bypassSoak` is how poison ignores armour.

    Returns a result table:
        { applied = , soaked = , before = , after = , attribute = }
]]
function Attributes.applyDelta(e, name, delta, opts)
    opts = opts or {}

    local def = defs[name]
    if not def then return nil, ('unknown attribute %q'):format(tostring(name)) end
    if not Attributes.has(e, name) then
        return nil, ('this entity has no %s'):format(name)
    end

    local d = Attributes.number(delta)
    if d == nil then
        return nil, ('%s cannot move by %s'):format(name, tostring(delta))
    end

    local before  = Attributes.base(e, name)
    local soaked  = 0

    if d < 0 and not opts.bypassSoak and def.soak and Attributes.has(e, def.soak) then
        local pool = Attributes.base(e, def.soak) or 0
        local want = -d
        local take = pool < want and pool or want
        if take > 0 then
            Attributes.setBase(e, def.soak, pool - take)
            soaked = take
            d = d + take
        end
    end

    local after = before
    if d ~= 0 then
        after = Attributes.setBase(e, name, before + d) or before
    end

    return {
        attribute = name,
        before    = before,
        after     = after,
        applied   = after - before,
        soaked    = soaked,
    }
end

-- Every attribute the entity carries, as { name = current }. For tests, for a
-- debug overlay, and for a host that wants to log what it just changed.
function Attributes.all(e)
    local out = {}
    local ordered = Attributes.orderedNames()
    for i = 1, #ordered do
        local name = ordered[i]
        if Attributes.has(e, name) then out[name] = Attributes.get(e, name) end
    end
    return out
end

---------------------------------------------------------------------------
-- The engine's own attributes
---------------------------------------------------------------------------

-- Deliberately few. A game defines its own alongside these exactly as it defines
-- its own components; nothing here is privileged.
function Attributes.registerDefaults()
    -- Adopts meatray/sim/components.lua's Health rather than replacing it.
    Attributes.define('healthMax', {
        component = C.Health,
        base = 'maxBase', cur = 'max',
        min = 1, max = 1e6, default = 100,
    })
    Attributes.define('health', {
        component = C.Health,
        base = 'hp', cur = 'hp',
        min = 0, max = 1e6, default = 100,
        ceiling = 'healthMax',
        soak = 'armour',
    })

    local ArmourC = ownComponent('armour', {})
    Attributes.define('armourMax', {
        component = ArmourC,
        base = 'maxBase', cur = 'max',
        min = 0, max = 1e6, default = 0,
    })
    Attributes.define('armour', {
        component = ArmourC,
        base = 'value', cur = 'value',
        min = 0, max = 1e6, default = 0,
        ceiling = 'armourMax',
    })

    local StaminaC = ownComponent('stamina', {})
    Attributes.define('staminaMax', {
        component = StaminaC,
        base = 'maxBase', cur = 'max',
        min = 0, max = 1e6, default = 100,
    })
    Attributes.define('stamina', {
        component = StaminaC,
        base = 'value', cur = 'value',
        min = 0, max = 1e6, default = 100,
        ceiling = 'staminaMax',
    })

    -- A stat, not a pool: it has a base and a separately-buffed current value,
    -- which is what a slow or a haste modifies. Its default matches
    -- meatray.net.replication's DEFAULT_MOVE_SPEED so an entity that opts in
    -- does not silently change speed.
    Attributes.define('moveSpeed', {
        component = ownComponent('movespeed', {}),
        base = 'base', cur = 'cur',
        min = 0, max = 100, default = Rep.DEFAULT_MOVE_SPEED,
    })
end

-- Clears every definition and re-registers the engine's own. Component
-- definitions are reused rather than rebuilt, so entities created before a reset
-- keep working.
function Attributes.reset()
    defs = {}
    orderedCache = nil
    Attributes.registerDefaults()
    return Attributes
end

Attributes.registerDefaults()

Attributes.Tags = Tags

return Attributes
