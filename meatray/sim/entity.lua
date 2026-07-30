--[[
    meatray.sim.entity — entities, components and archetypes.

    Entities are plain tables with an id and a transform. Behaviour is composed
    from components rather than inherited: an entity is whatever components it
    carries. Each component type declares which of its fields cross the network,
    so the wire format is derived from data and never hand-written per type.

    HEADLESS: this module must not touch love.graphics or any love drawing API.
]]

local Entity = {}

local nextId = 1

---------------------------------------------------------------------------
-- Components
---------------------------------------------------------------------------

-- Defines a component type. `netFields` lists the field names that are sent in
-- network snapshots; omit it for purely local components (input state, cached
-- pathfinding, anything the owner can recompute).
--
--   local Health = Entity.component('health', {'hp', 'max'})
--   local h = Health{ hp = 30, max = 30 }
--
function Entity.component(name, netFields)
    assert(type(name) == 'string' and name ~= '', 'component needs a name')
    assert(netFields == nil or type(netFields) == 'table', 'netFields must be a table')

    local def = {
        name = name,
        netFields = netFields or {},
    }

    return setmetatable(def, {
        __call = function(self, fields)
            local c = fields or {}
            c.__def = self
            return c
        end,
    })
end

---------------------------------------------------------------------------
-- Entities
---------------------------------------------------------------------------

local EntityMT = {}
EntityMT.__index = EntityMT

-- Attaches a component instance. Returns the entity so calls can chain.
function EntityMT:add(component)
    local def = component and component.__def
    assert(def, 'add() expects a component instance built from Entity.component')
    self.components[def.name] = component
    return self
end

function EntityMT:get(name)
    return self.components[name]
end

function EntityMT:has(name)
    return self.components[name] ~= nil
end

function EntityMT:remove(name)
    self.components[name] = nil
    return self
end

-- Records the current position as the previous one. The fixed-step loop calls
-- this immediately before each simulation tick so the renderer can interpolate
-- between prev and current without the simulation knowing anything about frames.
function EntityMT:snapPrevious()
    self.prevX, self.prevY, self.prevAngle = self.x, self.y, self.angle
end

-- Position as the renderer should draw it: `alpha` is how far the current frame
-- sits between the last tick and the next (0..1).
function EntityMT:interpolated(alpha)
    local a = alpha or 1
    return self.prevX + (self.x - self.prevX) * a,
           self.prevY + (self.y - self.prevY) * a,
           self.prevAngle + (self.angle - self.prevAngle) * a
end

-- Collects the entity's networked state: the transform plus every field each
-- component declared in netFields. Nothing else travels, so components are free
-- to hold functions, caches and back-references.
function EntityMT:snapshot()
    local snap = {
        id = self.id,
        kind = self.kind,
        x = self.x,
        y = self.y,
        angle = self.angle,
        c = nil,
    }

    local comps
    for name, component in pairs(self.components) do
        local fields = component.__def.netFields
        if #fields > 0 then
            local out = {}
            for i = 1, #fields do
                out[fields[i]] = component[fields[i]]
            end
            comps = comps or {}
            comps[name] = out
        end
    end
    snap.c = comps

    return snap
end

-- Applies a snapshot produced by snapshot(). Unknown component names are
-- ignored rather than fabricated: a client that has not been told what a
-- component means has no business inventing one.
function EntityMT:applySnapshot(snap)
    self.x = snap.x or self.x
    self.y = snap.y or self.y
    self.angle = snap.angle or self.angle

    if not snap.c then return self end

    for name, fields in pairs(snap.c) do
        local component = self.components[name]
        if component then
            local declared = component.__def.netFields
            for i = 1, #declared do
                local key = declared[i]
                if fields[key] ~= nil then
                    component[key] = fields[key]
                end
            end
        end
    end

    return self
end

-- Creates a bare entity. Games normally go through an archetype instead.
function Entity.new(fields)
    fields = fields or {}

    local e = setmetatable({
        id = fields.id or nextId,
        kind = fields.kind or 'entity',
        x = fields.x or 0,
        y = fields.y or 0,
        angle = fields.angle or 0,
        components = {},
        dead = false,
    }, EntityMT)

    if not fields.id then nextId = nextId + 1 end
    e:snapPrevious()

    return e
end

-- Lets a host assign ids and a client adopt them without colliding.
function Entity.reserveId()
    local id = nextId
    nextId = nextId + 1
    return id
end

function Entity.resetIds(n)
    nextId = n or 1
end

---------------------------------------------------------------------------
-- Archetypes
---------------------------------------------------------------------------

local archetypes = {}

-- Names a kind of entity and describes how to build one. This reads like a
-- class declaration but composes rather than inherits, so orthogonal traits
-- (flying, undead, ranged) attach independently instead of forcing a hierarchy.
--
--   local Imp = Entity.archetype('imp', function(e)
--       e:add(Billboard{ sheet = 'imp', angles = 8 })
--       e:add(Health{ hp = 30, max = 30 })
--   end)
--
--   local imp = Imp(12.5, 9.5)
--
function Entity.archetype(kind, build)
    assert(type(kind) == 'string' and kind ~= '', 'archetype needs a kind name')
    assert(type(build) == 'function', 'archetype needs a build function')

    local factory = function(x, y, fields)
        fields = fields or {}
        fields.kind = kind
        fields.x = x or fields.x
        fields.y = y or fields.y

        local e = Entity.new(fields)
        build(e, fields)
        return e
    end

    archetypes[kind] = factory
    return factory
end

function Entity.spawn(kind, x, y, fields)
    local factory = archetypes[kind]
    if not factory then return nil, ('unknown archetype: %s'):format(tostring(kind)) end
    return factory(x, y, fields)
end

function Entity.hasArchetype(kind)
    return archetypes[kind] ~= nil
end

function Entity.clearArchetypes()
    archetypes = {}
end

function Entity.archetypeNames()
    local out = {}
    for kind in pairs(archetypes) do out[#out + 1] = kind end
    table.sort(out)
    return out
end

-- Capture and restore exist for hot reload. A reload clears the registry and
-- re-runs the file that fills it, so a definition file that raises halfway
-- through would otherwise leave the game with some of its archetypes missing --
-- a reload that can corrupt running state is worse than no reload at all. These
-- let the caller put everything back exactly as it was.
function Entity.captureArchetypes()
    local out = {}
    for kind, factory in pairs(archetypes) do out[kind] = factory end
    return out
end

function Entity.restoreArchetypes(captured)
    archetypes = {}
    for kind, factory in pairs(captured or {}) do archetypes[kind] = factory end
end

return Entity
