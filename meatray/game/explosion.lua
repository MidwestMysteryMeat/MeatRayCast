--[[
    meatray.game.explosion — radial damage that walls actually stop.

        local Explosion = require('meatray.game.explosion')

        Explosion.detonate{
            world = world, entities = entities,
            x = 12.5, y = 9.5,
            radius = 4, damage = 60,
            tags = { 'damage.type.explosive' },
            source = shooter,
            lighting = lightGrid,          -- optional: pushes the flash
        }

    Three decisions, all of which are the difference between an explosion and a
    sphere of arbitrary hurt:

    1. FALLOFF. Damage scales from full at the centre to zero at the rim through
       a named curve. The curves have the same names and the same shapes as
       `meatray.render.lighting`'s, because a player reads an explosion's reach
       from its flash and the two disagreeing looks like a bug. They are
       reimplemented here rather than imported: `meatray/game` must not depend on
       `meatray/render`, or a dedicated server would need the renderer to resolve
       a grenade.

    2. OCCLUSION. Every candidate is line-of-sight tested from the blast centre
       through `meatray.sim.collide`, so a wall between you and the grenade means
       you take nothing. This is opt-out (`occlusion = false`) for a game that
       wants concussive damage through cover, but it is on by default because
       "it killed me through a wall" is the complaint that gets filed.

       Note what the test does NOT do: it does not treat the tile the explosion
       sits in as blocking. `Collide.rayTile` steps to the next tile before
       testing, so a rocket that detonates flush against a wall still damages
       everything down the corridor it came from, rather than nothing at all.

    3. IT APPLIES EFFECTS, NOT DAMAGE. Every hit goes through
       `meatray.game.damage`, so armour soaks it, a fire resistance reduces it,
       an immunity refuses it, and an explosion that also sets you alight is one
       extra effect id rather than a new code path.

    THE LIGHT IS INJECTED, NEVER REQUIRED

    An explosion in the dark that does not light the room is a worse explosion,
    but `meatray/game` may not reach into the renderer. So the flash is described
    here and handed out: pass `lighting` (anything with an `addDynamic` method)
    or `onLight` (a function), and the caller gets the same table back in
    `result.light` regardless. A dedicated server passes neither and nothing in
    this file notices.

    HEADLESS: this module must not touch love.graphics or any love drawing API.
]]

local Collide    = require('meatray.sim.collide')
local Attributes = require('meatray.game.attributes')
local Damage     = require('meatray.game.damage')

local Explosion = {}

local sqrt, max, min = math.sqrt, math.max, math.min

Explosion.DEFAULT_TAGS = { 'damage.type.explosive' }
Explosion.DEFAULT_CURVE = 'linear'

-- A blast bigger than this is a mistake or an attack: the candidate query is
-- O(entities) either way, but a radius of 1e9 makes every line-of-sight test
-- walk the whole map.
Explosion.MAX_RADIUS = 256

---------------------------------------------------------------------------
-- Falloff
---------------------------------------------------------------------------

Explosion.curves = {}

-- Straight ramp. The default, because it is the one players can estimate.
function Explosion.curves.linear(t) return t end

-- Smoothstep: a plateau of near-full damage at the centre and a soft rim. Kind
-- to the thrower, generous to the target standing on it.
function Explosion.curves.smooth(t) return t * t * (3 - 2 * t) end

-- Inverse-square flavoured, normalised to still reach zero at the rim. Brutal
-- at the centre and nearly harmless past halfway.
function Explosion.curves.inverse(t)
    if t <= 0 then return 0 end
    local d = 1 - t
    local a = 1 / (1 + 8 * d * d)
    local aMin = 1 / 9
    return max(0, (a - aMin) / (1 - aMin))
end

-- Scale of a blast of `radius` at `dist`: 1 at the centre, 0 at and beyond the
-- rim, never outside [0, 1].
function Explosion.falloff(dist, radius, curve)
    if not radius or radius <= 0 then return 0 end
    if dist <= 0 then return 1 end
    if dist >= radius then return 0 end

    local fn = Explosion.curves[curve or Explosion.DEFAULT_CURVE] or Explosion.curves.linear
    return max(0, min(1, fn(1 - dist / radius)))
end

---------------------------------------------------------------------------
-- Definitions
---------------------------------------------------------------------------

local defs = {}

--[[
    Names a blast so a projectile can carry `explosion = 'frag'` instead of a
    table. Same fields `detonate` takes, minus the ones that describe a
    particular moment (world, entities, x, y, source).
]]
function Explosion.compile(spec, id)
    if type(spec) ~= 'table' then
        return nil, ('an explosion spec must be a table, got %s'):format(type(spec))
    end

    local radius = Attributes.number(spec.radius)
    if radius == nil or radius <= 0 or radius > Explosion.MAX_RADIUS then
        return nil, ('explosion radius must be between 0 and %d, got %s')
                    :format(Explosion.MAX_RADIUS, tostring(spec.radius))
    end

    local damage = Attributes.number(spec.damage or 0)
    if damage == nil or damage < 0 then
        return nil, ('explosion damage must be zero or more, got %s'):format(tostring(spec.damage))
    end

    local curve = spec.curve or Explosion.DEFAULT_CURVE
    if not Explosion.curves[curve] then
        return nil, ('unknown falloff curve %q'):format(tostring(spec.curve))
    end

    local effects = {}
    for i = 1, #(spec.effects or {}) do
        if type(spec.effects[i]) ~= 'string' then
            return nil, ('effects[%d] is a %s, not an effect id'):format(i, type(spec.effects[i]))
        end
        effects[i] = spec.effects[i]
    end

    local tags = spec.tags or Explosion.DEFAULT_TAGS

    return {
        id        = id or spec.id or '(anonymous)',
        radius    = radius,
        damage    = damage,
        curve     = curve,
        tags      = tags,
        effects   = effects,
        occlusion = spec.occlusion ~= false,
        selfDamage = spec.selfDamage ~= false,
        light     = spec.light,
        gas       = spec.gas,
        gasAmount = Attributes.number(spec.gasAmount) or 0,
        gasRadius = Attributes.number(spec.gasRadius) or 0,
    }
end

function Explosion.define(id, spec)
    assert(type(id) == 'string' and id ~= '', 'an explosion needs an id')
    local def, err = Explosion.compile(spec, id)
    assert(def, err)
    defs[id] = def
    return def
end

function Explosion.definition(id) return defs[id] end

function Explosion.ids()
    local out = {}
    for id in pairs(defs) do out[#out + 1] = id end
    table.sort(out)
    return out
end

function Explosion.reset() defs = {} return Explosion end

function Explosion.capture()
    local out = {}
    for id, def in pairs(defs) do out[id] = def end
    return out
end

function Explosion.restore(captured)
    defs = {}
    for id, def in pairs(captured or {}) do defs[id] = def end
end

---------------------------------------------------------------------------
-- The flash
---------------------------------------------------------------------------

-- Describes the dynamic light an explosion should push, and pushes it if the
-- caller handed in somewhere to push it to. Returns the table either way, so a
-- headless host can put it in an event and let each client light its own room.
local function flash(ctx, def, x, y)
    local spec = ctx.light
    if spec == false then return nil end
    if spec == nil then spec = def and def.light end
    if spec == false then return nil end
    spec = spec or {}

    local light = {
        x = x, y = y,
        -- Light reaches further than shrapnel: a blast that only lit its own
        -- damage radius reads as smaller than it is.
        radius    = Attributes.number(spec.radius) or ((def and def.radius or ctx.radius or 4) * 1.75),
        intensity = Attributes.number(spec.intensity) or 1.6,
        color     = spec.color or { 1.0, 0.72, 0.35 },
        curve     = spec.curve or 'inverse',
        shadows   = spec.shadows ~= false,
        id        = spec.id,
    }

    -- Duck-typed on purpose. A lighting grid is the obvious thing to pass, but a
    -- test passes a table that records what it was given, and neither this module
    -- nor a dedicated server has to know which it got.
    local grid = ctx.lighting
    if grid and type(grid.addDynamic) == 'function' then
        grid:addDynamic(light)
    end
    if type(ctx.onLight) == 'function' then
        ctx.onLight(light)
    end

    return light
end

Explosion.flash = flash

---------------------------------------------------------------------------
-- Detonation
---------------------------------------------------------------------------

--[[
    Sets one off.

        Explosion.detonate{ world =, entities =, x =, y =, radius =, damage = }

    `def` (or `use = 'frag'`) supplies defaults from a named definition; any
    field given here wins over it.

    Returns:

        {
            x, y, radius, damage, curve,
            hits    = { { entity =, dist =, scale =, damage =, result =, refused = } },
            blocked = { entity =, dist = }, ...   -- in cover
            missed  = n,                          -- inside the query, outside the falloff
            light   = { ... } or nil,
            gas     = amount injected, if a gas field was handed in
        }

    or nil plus a reason. The reasons are strings a test can match:
    'an explosion needs a world', 'an explosion needs entities',
    'explosion position is unusable (...)', 'explosion radius is unusable (...)',
    'explosion damage is unusable (...)', 'unknown explosion: x'.
]]
function Explosion.detonate(ctx)
    if type(ctx) ~= 'table' then
        return nil, ('detonate needs a table, got %s'):format(type(ctx))
    end

    local def
    if ctx.use ~= nil then
        def = defs[ctx.use]
        if not def then return nil, ('unknown explosion: %s'):format(tostring(ctx.use)) end
    elseif type(ctx.def) == 'table' then
        def = ctx.def
    end

    local world = ctx.world
    if type(world) ~= 'table' or type(world.isSolid) ~= 'function' then
        return nil, 'an explosion needs a world'
    end

    local entities = ctx.entities
    if type(entities) ~= 'table' then
        return nil, 'an explosion needs entities'
    end

    -- Validated before anything is touched. A NaN centre makes every distance
    -- NaN, every comparison against the radius false, and the explosion silently
    -- harmless — which looks like a gameplay bug and is a data bug.
    local x = Attributes.number(ctx.x)
    local y = Attributes.number(ctx.y)
    if x == nil or y == nil then
        return nil, ('explosion position is unusable (%s, %s)')
                    :format(tostring(ctx.x), tostring(ctx.y))
    end

    local radius = Attributes.number(ctx.radius) or (def and def.radius)
    if radius == nil or radius <= 0 or radius > Explosion.MAX_RADIUS then
        return nil, ('explosion radius is unusable (%s)'):format(tostring(ctx.radius))
    end

    local damage = Attributes.number(ctx.damage)
    if damage == nil then damage = def and def.damage or 0 end
    if damage < 0 then
        return nil, ('explosion damage is unusable (%s)'):format(tostring(ctx.damage))
    end

    local curve = ctx.curve or (def and def.curve) or Explosion.DEFAULT_CURVE
    if not Explosion.curves[curve] then
        return nil, ('unknown falloff curve %q'):format(tostring(curve))
    end

    local tags      = ctx.tags or (def and def.tags) or Explosion.DEFAULT_TAGS
    local effects   = ctx.effects or (def and def.effects) or nil
    local occlusion = ctx.occlusion
    if occlusion == nil then occlusion = def and def.occlusion end
    if occlusion == nil then occlusion = true end

    local source = ctx.source
    local selfDamage = ctx.selfDamage
    if selfDamage == nil then selfDamage = def and def.selfDamage end
    if selfDamage == nil then selfDamage = true end

    local result = {
        x = x, y = y, radius = radius, damage = damage, curve = curve,
        hits = {}, blocked = {}, missed = 0,
    }

    local candidates = Collide.query(entities, x, y, radius, ctx.filter)

    for i = 1, #candidates do
        local target = candidates[i]
        local skip = (target == ctx.ignore)
                     or (not selfDamage and source ~= nil and target == source)
                     -- A grenade does not shred the grenade, and a cloud of
                     -- shrapnel does not detonate its own siblings.
                     or (ctx.ignoreProjectiles ~= false and target.components
                         and target.components.projectile ~= nil)

        if not skip then
            local dx, dy = target.x - x, target.y - y
            local dist = sqrt(dx * dx + dy * dy)
            local scale = Explosion.falloff(dist, radius, curve)

            if scale <= 0 then
                result.missed = result.missed + 1
            elseif occlusion and not Collide.lineOfSight(world, x, y, target.x, target.y) then
                result.blocked[#result.blocked + 1] = { entity = target, dist = dist }
            else
                local amount = damage * scale
                local applied, err, refused =
                    Damage.applyWith(target, amount, effects,
                                     { tags = tags, source = source, id = 'explosion' })

                result.hits[#result.hits + 1] = {
                    entity  = target,
                    dist    = dist,
                    scale   = scale,
                    damage  = amount,
                    result  = applied,
                    reason  = (not applied) and err or nil,
                    refused = refused,
                }
            end
        end
    end

    -- Smoke and fire, if the caller keeps a gas field. Injected the same way the
    -- light is: this module does not own one and does not require one.
    local gasField = ctx.gas
    local gasAmount = Attributes.number(ctx.gasAmount) or (def and def.gasAmount) or 0
    if gasField and type(gasField.emitCircle) == 'function' and gasAmount > 0 then
        local gasRadius = Attributes.number(ctx.gasRadius) or (def and def.gasRadius) or 0
        if gasRadius <= 0 then gasRadius = radius * 0.5 end
        result.gas = gasField:emitCircle(x, y, gasRadius, gasAmount)
    end

    result.light = flash(ctx, def, x, y)

    return result
end

-- Convenience: `Explosion.at(x, y, 'frag', { world =, entities = })`.
function Explosion.at(x, y, use, ctx)
    local merged = {}
    for k, v in pairs(ctx or {}) do merged[k] = v end
    merged.x, merged.y = x, y
    if type(use) == 'string' then merged.use = use
    elseif type(use) == 'table' then merged.def = use end
    return Explosion.detonate(merged)
end

return Explosion
