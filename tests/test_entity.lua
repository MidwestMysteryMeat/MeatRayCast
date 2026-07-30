--[[
    Entities, components, archetypes, and the snapshot derivation that the whole
    networking design rests on.
]]

return function(t)
    local Entity = require('meatray.sim.entity')

    t.describe('component declaration')
    local Health = Entity.component('health', { 'hp', 'max' })
    local h = Health{ hp = 30, max = 30 }
    t.eq(h.__def.name, 'health', 'component knows its name')
    t.eq(#h.__def.netFields, 2, 'component records its net fields')
    t.eq(h.hp, 30, 'component keeps its values')

    local Local = Entity.component('cooldown')
    t.eq(#Local(  ).__def.netFields, 0, 'a component with no netFields declares none')

    t.describe('composition')
    Entity.resetIds(1)
    local e = Entity.new{ x = 3, y = 4 }
    e:add(Health{ hp = 10, max = 10 })
    t.ok(e:has('health'), 'added component is present')
    t.eq(e:get('health').hp, 10, 'component is retrievable')
    e:remove('health')
    t.ok(not e:has('health'), 'removed component is gone')

    t.describe('archetypes read like types but compose')
    Entity.clearArchetypes()
    local Imp = Entity.archetype('imp', function(ent)
        ent:add(Health{ hp = 30, max = 30 })
        ent.radius = 0.3
    end)
    local imp = Imp(12.5, 9.5)
    t.eq(imp.kind, 'imp', 'archetype stamps the kind')
    t.eq(imp.x, 12.5, 'archetype places the entity')
    t.eq(imp:get('health').hp, 30, 'archetype builds components')
    t.ok(Entity.hasArchetype('imp'), 'archetype is registered')

    -- The trait that inheritance made awkward: orthogonal capabilities attach
    -- without a new branch in a hierarchy.
    local Flying = Entity.component('flying')
    imp:add(Flying{ height = 0.4 })
    t.ok(imp:has('flying') and imp:has('health'), 'orthogonal traits coexist')

    local spawned = Entity.spawn('imp', 1, 1)
    t.eq(spawned.kind, 'imp', 'spawn by name works')
    local missing, err = Entity.spawn('griffin', 1, 1)
    t.ok(missing == nil and err ~= nil, 'unknown archetype reports an error')

    t.describe('ids are unique')
    Entity.resetIds(1)
    local a, b = Entity.new{}, Entity.new{}
    t.ok(a.id ~= b.id, 'entities get distinct ids')
    local adopted = Entity.new{ id = 99 }
    t.eq(adopted.id, 99, 'an explicit id is respected')

    t.describe('snapshots derive from netFields')
    local Billboard = Entity.component('billboard', { 'sheet' })
    local Cooldown = Entity.component('cooldown')  -- no netFields

    local ent = Entity.new{ id = 7, kind = 'imp', x = 1.5, y = 2.5, angle = 0.25 }
    ent:add(Health{ hp = 12, max = 30 })
    ent:add(Billboard{ sheet = 'imp', angles = 8, frames = 4 })
    ent:add(Cooldown{ remaining = 0.4 })

    local snap = ent:snapshot()
    t.eq(snap.id, 7, 'snapshot carries id')
    t.eq(snap.x, 1.5, 'snapshot carries position')
    t.eq(snap.c.health.hp, 12, 'declared field is included')
    t.eq(snap.c.health.max, 30, 'all declared fields are included')
    t.eq(snap.c.billboard.sheet, 'imp', 'declared field on another component')
    t.eq(snap.c.billboard.angles, nil, 'undeclared field is omitted')
    t.eq(snap.c.cooldown, nil, 'component with no netFields is absent entirely')

    t.describe('snapshots apply back')
    local clone = Entity.new{ id = 7, kind = 'imp' }
    clone:add(Health{ hp = 30, max = 30 })
    clone:add(Billboard{ sheet = 'placeholder' })
    clone:applySnapshot(snap)
    t.eq(clone.x, 1.5, 'position applied')
    t.eq(clone.angle, 0.25, 'angle applied')
    t.eq(clone:get('health').hp, 12, 'component field applied')
    t.eq(clone:get('billboard').sheet, 'imp', 'sheet applied')

    -- A client told about a component it does not carry must not invent one.
    local sparse = Entity.new{ id = 7 }
    sparse:applySnapshot(snap)
    t.ok(not sparse:has('health'), 'unknown component is not fabricated')

    t.describe('interpolation state')
    local mover = Entity.new{ x = 0, y = 0, angle = 0 }
    mover:snapPrevious()
    mover.x, mover.y = 2, 4
    local ix, iy = mover:interpolated(0.5)
    t.eq(ix, 1, 'x interpolates halfway')
    t.eq(iy, 2, 'y interpolates halfway')
    local fx = mover:interpolated(1)
    t.eq(fx, 2, 'alpha 1 lands on the current position')
    mover:snapPrevious()
    local sx = mover:interpolated(0)
    t.eq(sx, 2, 'after snapPrevious there is nothing to interpolate')
end
