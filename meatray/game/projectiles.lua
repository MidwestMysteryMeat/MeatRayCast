--[[
    meatray.game.projectiles — rockets, grenades and bolts, as entities.

    A projectile is an ordinary entity carrying a `projectile` component, so it
    replicates, saves and draws through machinery that already exists: the host
    puts it in its entity list, `Rep.entitySnapshots` sends its transform, and a
    client builds it from its own archetype of the same kind. Nothing in the net
    layer or the renderer was edited to make that work, which is the test of
    whether it was built the right way.

        local p = Projectiles.spawn{
            kind = 'rocket', x = px, y = py, angle = aim,
            speed = 14, radius = 0.18, damage = 30,
            range = 40, owner = shooter,
            explosion = 'frag',
        }
        entities[#entities + 1] = p

        -- inside the fixed tick, on the host:
        local impacts = Projectiles.step(entities, step, { world = world, entities = entities })

    ---------------------------------------------------------------------------
    SUBSTEPPING, WHICH IS THE WHOLE PROBLEM
    ---------------------------------------------------------------------------

    A rocket at 14 tiles/second moves 0.23 tiles per 60 Hz tick, which is fine.
    A bolt at 60 moves a whole tile, and a tile is exactly the thing it is
    supposed to be stopped by — so a naive `x = x + vx * dt` walks straight
    through walls and past targets whenever the speed goes up, and the bug shows
    up as "the fast gun doesn't work indoors".

    So flight is subdivided: each tick is walked in steps no longer than
    `MAX_SUBSTEP` tiles, and every substep tests the wall it is entering and the
    entities it now overlaps. The cost is proportional to distance travelled,
    which is the honest thing for it to be proportional to, and it is capped so a
    projectile handed an absurd speed cannot lock the tick.

    ---------------------------------------------------------------------------
    WHAT HAPPENS ON IMPACT
    ---------------------------------------------------------------------------

    Direct damage goes through `meatray.game.damage`, so it is an effect and
    everything composes with it. An `explosion` (an id or a table) detonates at
    the impact point through `meatray.game.explosion`, which does its own
    line-of-sight test — so a rocket that hits the wall beside you damages you
    through the corner, and one that hits the far side of the wall does not.

    A projectile never damages its own owner directly (you cannot shoot yourself
    in the back at point blank), but its explosion can, because rocket-jumping
    into your own blast is a decision a game gets to make and `selfDamage` is
    where it makes it.

    HEADLESS: this module must not touch love.graphics or any love drawing API.
]]

local Entity     = require('meatray.sim.entity')
local Collide    = require('meatray.sim.collide')
local Attributes = require('meatray.game.attributes')
local Damage     = require('meatray.game.damage')
local Explosion  = require('meatray.game.explosion')

local Projectiles = {}

local floor, sqrt, cos, sin = math.floor, math.sqrt, math.cos, math.sin
local ceil, max = math.ceil, math.max

-- The furthest a projectile may move between collision tests. A quarter tile is
-- comfortably smaller than the thinnest thing in the world (a wall is a whole
-- tile) and smaller than any sane hit radius.
Projectiles.MAX_SUBSTEP = 0.25

-- A hard ceiling on substeps per tick per projectile, so a speed of 1e6 costs a
-- bounded amount rather than the frame.
Projectiles.MAX_SUBSTEPS = 128

Projectiles.DEFAULT_SPEED = 12
Projectiles.DEFAULT_RADIUS = 0.15
Projectiles.DEFAULT_RANGE = 48

-- Host bookkeeping: flight state, the owner reference and the payload. No
-- netFields, deliberately — a client needs the projectile's POSITION, which the
-- transform already carries, and has no business knowing what it will do when it
-- lands. `kind` is what tells the client which sprite to draw.
Projectiles.Component = Entity.component('projectile')

---------------------------------------------------------------------------
-- Spawning
---------------------------------------------------------------------------

--[[
    Builds a projectile entity. Does NOT add it to any list: the caller owns the
    entity array, and a function that silently appended to one it was handed
    would be the only thing in the engine that did.

    opts:
        kind        archetype/sprite name (default 'projectile')
        x, y        origin
        angle       direction, radians               (or dirX/dirY)
        speed       tiles per second
        radius      hit radius in tiles
        damage      direct damage on contact
        tags        damage tags
        effects     effect ids applied to whatever it hits directly
        range       maximum distance before it expires
        lifetime    maximum seconds before it expires (optional)
        owner       the entity that fired it; never hit directly
        explosion   an explosion id, or a spec table
        explodeOnExpire   detonate when range/lifetime runs out (default false)
        pierce      how many entities it passes through (default 0)
        spawn       function(kind, x, y, fields) -> entity, to override construction

    Returns the entity, or nil plus a reason.
]]
function Projectiles.spawn(opts)
    if type(opts) ~= 'table' then
        return nil, ('spawn needs a table, got %s'):format(type(opts))
    end

    local x = Attributes.number(opts.x)
    local y = Attributes.number(opts.y)
    if x == nil or y == nil then
        return nil, ('projectile position is unusable (%s, %s)')
                    :format(tostring(opts.x), tostring(opts.y))
    end

    local dirX, dirY = opts.dirX, opts.dirY
    if dirX == nil or dirY == nil then
        local angle = Attributes.number(opts.angle)
        if angle == nil then
            return nil, ('projectile angle is unusable (%s)'):format(tostring(opts.angle))
        end
        dirX, dirY = cos(angle), sin(angle)
    end

    dirX = Attributes.number(dirX)
    dirY = Attributes.number(dirY)
    if dirX == nil or dirY == nil then
        return nil, 'projectile direction is unusable'
    end

    local len = sqrt(dirX * dirX + dirY * dirY)
    if len < 1e-9 then return nil, 'projectile direction has no length' end
    dirX, dirY = dirX / len, dirY / len

    local speed = Attributes.number(opts.speed) or Projectiles.DEFAULT_SPEED
    if speed <= 0 then
        return nil, ('projectile speed must be positive, got %s'):format(tostring(opts.speed))
    end

    local radius = Attributes.number(opts.radius) or Projectiles.DEFAULT_RADIUS
    if radius < 0 then radius = 0 end

    local range = Attributes.number(opts.range) or Projectiles.DEFAULT_RANGE
    if range <= 0 then
        return nil, ('projectile range must be positive, got %s'):format(tostring(opts.range))
    end

    local damage = Attributes.number(opts.damage) or 0
    if damage < 0 then damage = 0 end

    local kind = opts.kind or 'projectile'

    local e
    if type(opts.spawn) == 'function' then
        e = opts.spawn(kind, x, y, opts)
    end
    if not e then
        if Entity.hasArchetype(kind) then
            e = Entity.spawn(kind, x, y)
        else
            e = Entity.new{ kind = kind, x = x, y = y }
        end
    end

    e.x, e.y = x, y
    e.angle = Attributes.number(opts.angle) or math.atan2(dirY, dirX)
    e.radius = radius
    e:snapPrevious()

    e:add(Projectiles.Component{
        dirX = dirX, dirY = dirY,
        speed = speed,
        radius = radius,
        damage = damage,
        tags = opts.tags,
        effects = opts.effects,
        remaining = range,
        range = range,
        lifetime = Attributes.number(opts.lifetime),
        age = 0,
        owner = opts.owner,
        ownerId = opts.owner and opts.owner.id or nil,
        explosion = opts.explosion,
        explodeOnExpire = opts.explodeOnExpire and true or false,
        pierce = max(0, floor(Attributes.number(opts.pierce) or 0)),
        hitCount = 0,
        hitIds = {},
    })

    return e
end

function Projectiles.is(e)
    return type(e) == 'table' and type(e.components) == 'table'
           and e.components.projectile ~= nil
end

---------------------------------------------------------------------------
-- Impact
---------------------------------------------------------------------------

local function detonate(e, p, ctx, impact)
    local spec = p.explosion
    if spec == nil then return nil end

    local blast = {
        world = ctx.world,
        entities = ctx.entities,
        x = e.x, y = e.y,
        source = p.owner,
        lighting = ctx.lighting,
        onLight = ctx.onLight,
        gas = ctx.gas,
        light = ctx.light,
    }

    if type(spec) == 'string' then
        blast.use = spec
    else
        for k, v in pairs(spec) do
            if blast[k] == nil then blast[k] = v end
        end
        blast.x, blast.y = e.x, e.y
    end

    local result, err = Explosion.detonate(blast)
    impact.explosion = result
    impact.explosionError = err
    return result
end

-- One contact with one entity. Returns true if the projectile should stop.
local function hitEntity(e, p, target, ctx, impact)
    impact.kind = 'entity'
    impact.target = target
    impact.targetId = target.id
    impact.targetKind = target.kind

    if p.damage > 0 then
        local applied, err, refused = Damage.applyWith(target, p.damage, p.effects, {
            tags = p.tags, source = p.owner, id = 'projectile',
        })
        impact.damage = p.damage
        impact.result = applied
        impact.reason = (not applied) and err or nil
        impact.refused = refused
    end

    p.hitCount = p.hitCount + 1
    p.hitIds[target.id or target] = true

    return p.hitCount > p.pierce
end

---------------------------------------------------------------------------
-- The tick
---------------------------------------------------------------------------

--[[
    Advances every projectile in `entities` by one fixed simulation step.

    `ctx` needs `world` and `entities` (the list to test against, normally the
    same one). `lighting`, `onLight` and `gas` are forwarded to any explosion,
    and are as optional there as they are here.

    Returns an array of impact records, in entity order:

        { entity =, kind = 'wall'|'entity'|'expired', x =, y =,
          tx =, ty =,                    -- for a wall
          target =, targetId =, targetKind =, damage =, result =,
          explosion = <explosion result> or nil }

    A projectile that impacts is marked `dead`, which is the same signal the
    replication layer and the save layer already use for "this is gone": no
    despawn message, no removal protocol, no second mechanism.
]]
function Projectiles.step(entities, dt, ctx)
    ctx = ctx or {}
    local impacts = {}

    if type(entities) ~= 'table' then return impacts end

    local step = Attributes.number(dt)
    if step == nil or step <= 0 then return impacts end

    local world = ctx.world
    local against = ctx.entities or entities

    for i = 1, #entities do
        local e = entities[i]
        local p = (not (e == nil or e.dead)) and e.components and e.components.projectile or nil

        if p then
            p.age = p.age + step

            local travel = p.speed * step
            if travel > p.remaining then travel = p.remaining end

            local substeps = ceil(travel / Projectiles.MAX_SUBSTEP)
            if substeps < 1 then substeps = 1 end
            if substeps > Projectiles.MAX_SUBSTEPS then substeps = Projectiles.MAX_SUBSTEPS end
            local sub = travel / substeps

            local impact = nil

            for _ = 1, substeps do
                local nx = e.x + p.dirX * sub
                local ny = e.y + p.dirY * sub

                -- The wall it is entering, tested before the move is committed,
                -- so the impact point is on this side of the wall rather than
                -- inside it — which matters because an explosion inside a wall
                -- is line-of-sight blocked from everything.
                if world then
                    local tx, ty = floor(nx) + 1, floor(ny) + 1
                    if world:isSolid(tx, ty) then
                        impact = { entity = e, kind = 'wall', x = e.x, y = e.y,
                                   tx = tx, ty = ty }
                        break
                    end
                end

                e.x, e.y = nx, ny
                p.remaining = p.remaining - sub

                -- Entities. `Collide.query` returns nearest first, so a shot
                -- through a crowd resolves against the one it actually reached.
                local reach = p.radius + 1
                local near = Collide.query(against, e.x, e.y, reach)
                for k = 1, #near do
                    local target = near[k]
                    if target ~= e and target ~= p.owner
                       and not p.hitIds[target.id or target]
                       and not (target.components and target.components.projectile) then
                        local tr = target.radius or Collide.DEFAULT_RADIUS
                        local dx, dy = target.x - e.x, target.y - e.y
                        local reachSq = (tr + p.radius) * (tr + p.radius)
                        if dx * dx + dy * dy <= reachSq then
                            local record = { entity = e, x = e.x, y = e.y }
                            if hitEntity(e, p, target, ctx, record) then
                                impact = record
                                break
                            else
                                -- Pierced: record it and keep flying.
                                impacts[#impacts + 1] = record
                            end
                        end
                    end
                end

                if impact then break end
                if p.remaining <= 1e-9 then break end
            end

            if not impact then
                local outOfRange = p.remaining <= 1e-9
                local outOfTime  = p.lifetime ~= nil and p.age >= p.lifetime
                if outOfRange or outOfTime then
                    impact = { entity = e, kind = 'expired', x = e.x, y = e.y,
                               reason = outOfTime and 'lifetime' or 'range' }
                end
            end

            if impact then
                if impact.kind ~= 'expired' or p.explodeOnExpire then
                    detonate(e, p, ctx, impact)
                end
                e.dead = true
                impacts[#impacts + 1] = impact
            end
        end
    end

    return impacts
end

-- Removes dead projectiles from an array in place, preserving order. A host that
-- keeps its entity list tidy is a host whose snapshots do not carry corpses; the
-- caller may just as well leave them for its own sweeper.
function Projectiles.sweep(entities)
    local removed = 0
    local n = #entities
    local write = 1
    for read = 1, n do
        local e = entities[read]
        if e.dead and Projectiles.is(e) then
            removed = removed + 1
        else
            entities[write] = e
            write = write + 1
        end
    end
    for i = write, n do entities[i] = nil end
    return removed
end

return Projectiles
