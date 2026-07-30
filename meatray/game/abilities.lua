--[[
    meatray.game.abilities — activation, cost, cooldown, cast time.

    An ability is a small state machine over the effect system. Everything it
    does to the world it does by applying effects, so a dash that costs stamina
    and grants a brief speed buff needs no new code path: the cost is an instant
    effect, the buff is a duration effect, and both compose with resistances,
    immunities and stacking because they are the same objects everything else is
    made of.

    ---------------------------------------------------------------------------
    Refusals are values, not silence
    ---------------------------------------------------------------------------

    `activate` returns `false` plus a reason, always, and `canActivate` answers
    the same question without doing anything. The reasons are stable strings:

        'no ability system'   'unknown ability: x'   'not granted'
        'cooldown'            'cost'                 'already casting'
        'blocked by tag: x'   'missing tag: x'       'not authoritative'

    An ability that cannot pay silently is the bug that produces "the button
    does nothing sometimes". The reason is returned so the HUD can say which of
    six possible causes it was, and so a test can assert on it.

    ---------------------------------------------------------------------------
    Commit points, chosen and written down
    ---------------------------------------------------------------------------

      * The cost is paid and the cooldown starts at ACTIVATION, not at the end
        of a cast. That is Unreal's default and it is the one that cannot be
        gamed: charging on completion means a player who interrupts every cast
        pays nothing and still occupies the ability's slot.
      * Effects land when the cast COMPLETES. A zero cast time completes on the
        same call, which is why an instant ability needs no separate path.
      * Cancelling does not refund. `Abilities.cancel(e, id, { refund = true })`
        refunds explicitly, for the caller who wants a stun to be merciful.

    ---------------------------------------------------------------------------
    Prediction, and the one thing it may never do
    ---------------------------------------------------------------------------

    A client may run `predict`, which performs exactly the same gating and, if it
    passes, starts a local cooldown and cast so the animation and the greyed-out
    button happen on the frame the button was pressed rather than a round trip
    later. It pays no cost and applies no effects, because both of those are
    attribute changes and attributes belong to the host.

    That is the deliberate difference from a health bar that flinches: a
    mispredicted cooldown corrects invisibly (`reject` puts it back), whereas a
    mispredicted damage number is a lie the player watched happen. The engine
    makes the second one impossible rather than discouraged — `Effects.apply`
    refuses on a non-authoritative container, so there is no path from client
    input to an attribute even by mistake.

    `predict` returns a key; the host's answer arrives later and the caller calls
    `confirm(e, key)` or `reject(e, key)`. A rejected prediction restores the
    cooldown and cast state that existed before it, so a refused activation costs
    the player nothing beyond the frames it was optimistically shown.

    HEADLESS: this module must not touch love.graphics or any love drawing API.
]]

local Tags       = require('meatray.game.tags')
local Attributes = require('meatray.game.attributes')
local Effects    = require('meatray.game.effects')

local Abilities = {}

local EPS = Attributes.EPS

local defs = {}

---------------------------------------------------------------------------
-- Definitions
---------------------------------------------------------------------------

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

--[[
    Declares an ability.

        Abilities.define('dash', {
            cost      = { { attr = 'stamina', magnitude = 25 } },
            cooldown  = 3,
            castTime  = 0,
            tags         = { 'ability.dash' },
            blockedTags  = { 'state.stunned' },
            effects      = { 'dash.speed' },       -- applied to the activator
            effectsOnHit = { 'dash.impact' },      -- applied to ctx.targets
        })

    `cost` magnitudes are positive amounts to spend. They are checked against the
    attribute's *current* value and paid as instant modifiers, so a cost
    interacts with buffs and caps exactly as everything else does.
]]
function Abilities.compile(spec, id)
    if type(spec) ~= 'table' then
        return nil, ('an ability spec must be a table, got %s'):format(type(spec))
    end

    local cost = {}
    for i = 1, #(spec.cost or {}) do
        local c = spec.cost[i]
        if type(c) ~= 'table' then
            return nil, ('cost %d is a %s, not a table'):format(i, type(c))
        end
        if type(c.attr) ~= 'string' or c.attr == '' then
            return nil, ('cost %d names no attribute'):format(i)
        end
        local mag = Attributes.number(c.magnitude)
        if mag == nil or mag < 0 then
            return nil, ('cost %d on %s needs a magnitude of 0 or more (%s)')
                        :format(i, c.attr, tostring(c.magnitude))
        end
        cost[i] = { attr = c.attr, magnitude = mag }
    end

    local cooldown = Attributes.number(spec.cooldown or 0)
    if cooldown == nil or cooldown < 0 then
        return nil, ('cooldown must be zero or more, got %s'):format(tostring(spec.cooldown))
    end

    local castTime = Attributes.number(spec.castTime or 0)
    if castTime == nil or castTime < 0 then
        return nil, ('cast time must be zero or more, got %s'):format(tostring(spec.castTime))
    end

    local lists, err = {}, nil
    for _, key in ipairs({ 'tags', 'blockedTags', 'requiredTags', 'castingTags' }) do
        lists[key], err = checkTagList(spec[key], key)
        if not lists[key] then return nil, err end
    end

    local function idList(list, what)
        if list == nil then return {} end
        if type(list) ~= 'table' then return nil, ('%s must be a list of effect ids'):format(what) end
        local out = {}
        for i = 1, #list do
            if type(list[i]) ~= 'string' then
                return nil, ('%s[%d] is a %s, not an effect id'):format(what, i, type(list[i]))
            end
            out[i] = list[i]
        end
        return out
    end

    local effects, effErr = idList(spec.effects, 'effects')
    if not effects then return nil, effErr end
    local onHit, hitErr = idList(spec.effectsOnHit, 'effectsOnHit')
    if not onHit then return nil, hitErr end

    return {
        id           = id or spec.id or '(anonymous)',
        cost         = cost,
        cooldown     = cooldown,
        castTime     = castTime,
        tags         = lists.tags,
        blockedTags  = lists.blockedTags,
        requiredTags = lists.requiredTags,
        -- Granted for the duration of a cast, so "cannot cast while casting" and
        -- "movement cancels a cast" are tag questions like everything else.
        castingTags  = (#lists.castingTags > 0) and lists.castingTags or { 'state.casting' },
        effects      = effects,
        effectsOnHit = onHit,
        onActivate   = spec.onActivate,
        onCommit     = spec.onCommit,
        onCancel     = spec.onCancel,
    }
end

function Abilities.define(id, spec)
    assert(type(id) == 'string' and id ~= '', 'an ability needs an id')
    local def, err = Abilities.compile(spec, id)
    assert(def, err)
    defs[id] = def
    return def
end

function Abilities.definition(id)
    return defs[id]
end

function Abilities.ids()
    local out = {}
    for id in pairs(defs) do out[#out + 1] = id end
    table.sort(out)
    return out
end

function Abilities.reset()
    defs = {}
    return Abilities
end

function Abilities.capture()
    local out = {}
    for id, def in pairs(defs) do out[id] = def end
    return out
end

function Abilities.restore(captured)
    defs = {}
    for id, def in pairs(captured or {}) do defs[id] = def end
end

---------------------------------------------------------------------------
-- Granting
---------------------------------------------------------------------------

function Abilities.grant(e, id)
    local gas = Effects.system(e)
    if not gas then return false, 'no ability system' end
    if not defs[id] then return false, ('unknown ability: %s'):format(tostring(id)) end
    gas.abilities[id] = true
    return true
end

function Abilities.revoke(e, id)
    local gas = Effects.system(e)
    if not gas then return false, 'no ability system' end
    gas.abilities[id] = nil
    gas.cooldowns[id] = nil
    gas.casts[id] = nil
    return true
end

function Abilities.granted(e, id)
    local gas = Effects.system(e)
    return gas ~= nil and gas.abilities[id] == true
end

-- Sorted, so a HUD that lists an entity's abilities lists them the same way
-- every run rather than in whatever order the hash produced.
function Abilities.grantedIds(e)
    local gas = Effects.system(e)
    if not gas then return {} end
    local out = {}
    for id in pairs(gas.abilities) do out[#out + 1] = id end
    table.sort(out)
    return out
end

---------------------------------------------------------------------------
-- Cooldowns and casts
---------------------------------------------------------------------------

function Abilities.cooldownRemaining(e, id)
    local gas = Effects.system(e)
    if not gas then return 0 end
    return gas.cooldowns[id] or 0
end

function Abilities.onCooldown(e, id)
    return Abilities.cooldownRemaining(e, id) > EPS
end

function Abilities.casting(e, id)
    local gas = Effects.system(e)
    if not gas then return nil end
    if id then return gas.casts[id] end
    for _, cast in pairs(gas.casts) do return cast end
    return nil
end

function Abilities.castRemaining(e, id)
    local cast = Abilities.casting(e, id)
    return cast and cast.remaining or 0
end

---------------------------------------------------------------------------
-- Gating
---------------------------------------------------------------------------

-- Can this be paid for right now? Separated so the refusal and the payment
-- cannot disagree about what a cost is.
local function affordable(e, def)
    for i = 1, #def.cost do
        local c = def.cost[i]
        local have = Attributes.get(e, c.attr)
        if have == nil then return false, c.attr end
        if have + EPS < c.magnitude then return false, c.attr end
    end
    return true
end

--[[
    Everything `activate` checks, with nothing applied. Returns true, or false
    plus a reason and (where there is one) the detail that caused it.
]]
function Abilities.canActivate(e, id, ctx)
    ctx = ctx or {}

    local gas = Effects.system(e)
    if not gas then return false, 'no ability system' end

    local def = defs[id]
    if not def then return false, ('unknown ability: %s'):format(tostring(id)) end

    if ctx.requireGranted ~= false and not gas.abilities[id] then
        return false, 'not granted'
    end

    if gas.casts[id] then return false, 'already casting' end

    if #def.blockedTags > 0 then
        local blocked, which = gas.tags:hasAny(def.blockedTags)
        if blocked then return false, 'blocked by tag: ' .. tostring(which), which end
    end

    if #def.requiredTags > 0 then
        local ok, missing = gas.tags:hasAll(def.requiredTags)
        if not ok then return false, 'missing tag: ' .. tostring(missing), missing end
    end

    if (gas.cooldowns[id] or 0) > EPS then
        return false, 'cooldown', gas.cooldowns[id]
    end

    local canPay, attr = affordable(e, def)
    if not canPay then return false, 'cost', attr end

    return true
end

---------------------------------------------------------------------------
-- Activation
---------------------------------------------------------------------------

local function payCost(e, def, ctx)
    if #def.cost == 0 then return {} end

    local modifiers = {}
    for i = 1, #def.cost do
        local c = def.cost[i]
        -- Costs bypass soak: spending stamina must not be absorbed by armour,
        -- and a cost that a shield paid for would be free.
        modifiers[i] = { attr = c.attr, op = 'add', magnitude = -c.magnitude,
                         bypassSoak = true }
    end

    local result, err = Effects.applySpec(e, {
        id = def.id .. '.cost',
        duration = 'instant',
        modifiers = modifiers,
    }, ctx)

    return result, err
end

local function commit(e, def, ctx)
    local applied, refused = {}, {}

    for i = 1, #def.effects do
        local r, err = Effects.apply(e, def.effects[i], ctx)
        if r then applied[#applied + 1] = def.effects[i]
        else refused[#refused + 1] = { id = def.effects[i], reason = err } end
    end

    local targets = ctx.targets or {}
    local hit = 0
    for i = 1, #targets do
        local target = targets[i]
        for j = 1, #def.effectsOnHit do
            local r, err = Effects.apply(target, def.effectsOnHit[j],
                                         { source = e, rng = ctx.rng, targets = nil })
            if r then hit = hit + 1
            else refused[#refused + 1] = { id = def.effectsOnHit[j], reason = err } end
        end
    end

    if def.onCommit then def.onCommit(e, def, ctx) end

    return { id = def.id, applied = applied, refused = refused, hits = hit }
end

--[[
    Activates an ability on the host.

    Returns a result table, or false plus a reason. On success:

        { id =, committed = bool, castTime =, cooldown =, result = <commit> }

    `committed` is false when the ability has a cast time: the cost is already
    paid and the cooldown already running, and the effects land when
    `Abilities.tick` runs the cast out.
]]
function Abilities.activate(e, id, ctx)
    ctx = ctx or {}

    local gas = Effects.system(e)
    if not gas then return false, 'no ability system' end
    if not gas.authority then return false, 'not authoritative' end

    local ok, reason, detail = Abilities.canActivate(e, id, ctx)
    if not ok then return false, reason, detail end

    local def = defs[id]

    local paid, payErr = payCost(e, def, ctx)
    if not paid then return false, payErr or 'cost' end

    if def.cooldown > 0 then gas.cooldowns[id] = def.cooldown end
    if def.onActivate then def.onActivate(e, def, ctx) end

    if def.castTime > 0 then
        gas.casts[id] = {
            id = id, remaining = def.castTime, total = def.castTime,
            ctx = ctx, predicted = false,
        }
        for i = 1, #def.castingTags do gas.tags:add(def.castingTags[i], 1) end
        Effects.syncTags(e)
        return { id = id, committed = false, castTime = def.castTime,
                 cooldown = def.cooldown }
    end

    local result = commit(e, def, ctx)
    return { id = id, committed = true, castTime = 0, cooldown = def.cooldown,
             result = result }
end

--[[
    The client's optimistic half. Runs the same gating, then starts a local
    cooldown and cast so the interface responds immediately. Pays nothing and
    applies nothing.

    Returns a prediction key, or false plus a reason.
]]
function Abilities.predict(e, id, ctx)
    ctx = ctx or {}

    local gas = Effects.system(e)
    if not gas then return false, 'no ability system' end

    local ok, reason, detail = Abilities.canActivate(e, id, ctx)
    if not ok then return false, reason, detail end

    local def = defs[id]

    local key = gas.nextPrediction
    gas.nextPrediction = gas.nextPrediction + 1

    gas.predictions[key] = {
        id = id,
        cooldownBefore = gas.cooldowns[id],
        castBefore = gas.casts[id],
    }

    if def.cooldown > 0 then gas.cooldowns[id] = def.cooldown end

    if def.castTime > 0 then
        gas.casts[id] = {
            id = id, remaining = def.castTime, total = def.castTime,
            ctx = ctx, predicted = true,
        }
        for i = 1, #def.castingTags do gas.tags:add(def.castingTags[i], 1) end
        Effects.syncTags(e)
    end

    return key
end

-- The host said yes. Nothing to undo; the prediction stops being provisional.
function Abilities.confirm(e, key)
    local gas = Effects.system(e)
    if not gas then return false, 'no ability system' end

    local pending = gas.predictions[key]
    if not pending then return false, 'unknown prediction' end
    gas.predictions[key] = nil

    local cast = gas.casts[pending.id]
    if cast then cast.predicted = false end

    return true
end

-- The host said no. Put back exactly what was there before the prediction, so a
-- refused activation costs the player a few frames of a greyed-out button and
-- nothing else.
function Abilities.reject(e, key, reason)
    local gas = Effects.system(e)
    if not gas then return false, 'no ability system' end

    local pending = gas.predictions[key]
    if not pending then return false, 'unknown prediction' end
    gas.predictions[key] = nil

    local def = defs[pending.id]
    local cast = gas.casts[pending.id]

    if cast and cast.predicted then
        for i = 1, #def.castingTags do gas.tags:remove(def.castingTags[i], 1) end
        Effects.syncTags(e)
    end

    gas.cooldowns[pending.id] = pending.cooldownBefore
    gas.casts[pending.id] = pending.castBefore

    return true, reason
end

-- Stops a cast in progress. No refund unless asked for: an interrupt that
-- refunds by default makes every stun a free reset.
function Abilities.cancel(e, id, opts)
    opts = opts or {}

    local gas = Effects.system(e)
    if not gas then return false, 'no ability system' end

    local cast = gas.casts[id]
    if not cast then return false, 'not casting' end

    local def = defs[id]
    gas.casts[id] = nil
    for i = 1, #def.castingTags do gas.tags:remove(def.castingTags[i], 1) end

    if opts.refund then
        if gas.authority then
            local modifiers = {}
            for i = 1, #def.cost do
                modifiers[i] = { attr = def.cost[i].attr, op = 'add',
                                 magnitude = def.cost[i].magnitude, bypassSoak = true }
            end
            if #modifiers > 0 then
                Effects.applySpec(e, { id = def.id .. '.refund',
                                       duration = 'instant', modifiers = modifiers })
            end
        end
        gas.cooldowns[id] = nil
    end

    Effects.syncTags(e)
    if def.onCancel then def.onCancel(e, def, cast.ctx, opts.reason) end

    return true
end

-- Cancels every cast whose ability is blocked by a tag the entity now has. This
-- is what makes `state.stunned` interrupt: the stun grants a tag, and the next
-- tick finds the casts that tag forbids.
function Abilities.interrupt(e, opts)
    local gas = Effects.system(e)
    if not gas then return 0 end

    local ids = {}
    for id in pairs(gas.casts) do ids[#ids + 1] = id end
    table.sort(ids)

    local stopped = 0
    for i = 1, #ids do
        local def = defs[ids[i]]
        if def and #def.blockedTags > 0 and gas.tags:hasAny(def.blockedTags) then
            Abilities.cancel(e, ids[i], opts)
            stopped = stopped + 1
        end
    end

    return stopped
end

---------------------------------------------------------------------------
-- The tick
---------------------------------------------------------------------------

--[[
    Runs cooldowns down and casts out, one fixed simulation step.

    Returns how many cooldowns finished and how many casts completed. Ids are
    processed in sorted order so two hosts stepping the same state complete the
    same casts in the same order, which matters as soon as one cast's effects
    could gate another's.
]]
function Abilities.tick(e, dt, ctx)
    local gas = Effects.system(e)
    if not gas then return 0, 0 end

    local step = Attributes.number(dt)
    if step == nil or step <= 0 then return 0, 0 end

    local ready = 0
    local ids = {}
    for id in pairs(gas.cooldowns) do ids[#ids + 1] = id end
    table.sort(ids)
    for i = 1, #ids do
        local id = ids[i]
        local remaining = gas.cooldowns[id] - step
        if remaining <= EPS then
            gas.cooldowns[id] = nil
            ready = ready + 1
        else
            gas.cooldowns[id] = remaining
        end
    end

    local completed = 0
    local castIds = {}
    for id in pairs(gas.casts) do castIds[#castIds + 1] = id end
    table.sort(castIds)

    for i = 1, #castIds do
        local id = castIds[i]
        local cast = gas.casts[id]
        if cast then
            cast.remaining = cast.remaining - step
            if cast.remaining <= EPS then
                local def = defs[id]
                gas.casts[id] = nil
                for k = 1, #def.castingTags do gas.tags:remove(def.castingTags[k], 1) end

                -- A predicted cast completing on a client applies nothing: the
                -- host's own commit is what moves attributes, and it arrives as
                -- a snapshot.
                if gas.authority and not cast.predicted then
                    commit(e, def, cast.ctx or ctx or {})
                end
                completed = completed + 1
            end
        end
    end

    if completed > 0 then Effects.syncTags(e) end

    return ready, completed
end

return Abilities
