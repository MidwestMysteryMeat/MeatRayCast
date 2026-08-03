--[[
    meatray.game.meatgraph_ray — MeatGraphRay, host-side node graphs for MeatRayCast.

    MeatEngine's visual scripting is **MeatGraph**. This is the raycast engine's
    sibling: same idea (event to action graphs as JSON), same kind names where
    they overlap, host-only. We do not call them "blueprints" (Unreal's product
    name).

      * Graph JSON is the source of truth (version, nodes, links, volumes).
      * Only Event / Action / Branch walk an exec chain; data pins resolve by
        walking links backward (literals fill unwired inputs).
      * Runtime is always host-authoritative — never run on a client.

    This module interprets graphs in pure Lua rather than emitting source.

        local MG = require('meatray.game.meatgraph_ray')
        local g = MG.load(jsonText)          -- or MG.fromTable(t)
        local api = MG.apiFor{ mode = mode, world = world, log = print }
        g:fire('init', api, { seed = 1 })
        g:fire('tick', api, { t = dt })

    Compatible with MeatEngine MeatGraph node kind names for the shared subset
    (EventOnInit, ActionLog, Branch, MathAdd, ...). Raycast-specific kinds
    (ActionOpenDoor, ActionSpawnEntity, ...) are local extensions.

    HEADLESS: pure Lua.
]]

local json = require('meatray.net.json')
local Worldgen = require('meatray.sim.worldgen')

local MeatGraphRay = {}

-- G4: the fallback generator for a bare api (an editor preview, a test that
-- built no host). The engine's own LCG, never math.random — a graph that
-- runs on the host is part of the demo-recording stream, and math.random is
-- the one generator whose sequence this engine cannot replay.
local bareRng = Worldgen.rng(0x6EA7)

---------------------------------------------------------------------------
-- Kind registry (shared names first, then raycast extensions)
---------------------------------------------------------------------------

-- Event names used by :fire(event, …).
local EVENT_KIND = {
    EventOnInit         = 'init',
    EventOnTick         = 'tick',
    EventOnPlayerJoin   = 'join',
    EventOnPlayerDeath  = 'death',
    EventOnTrigger      = 'trigger',      -- enter; strA optional volume name filter
    EventOnTriggerExit  = 'trigger_exit', -- leave/dead; same filter
    EventOnTriggerStay  = 'trigger_stay', -- each step while inside
}

-- Exec pin: which output pin continues the chain (Branch is special).
local function isEventKind(kind)
    return EVENT_KIND[kind] ~= nil
end

---------------------------------------------------------------------------
-- Graph helpers
---------------------------------------------------------------------------

local GraphMT = {}
GraphMT.__index = GraphMT

local function findNode(g, id)
    for i = 1, #g.nodes do
        if g.nodes[i].id == id then return g.nodes[i] end
    end
    return nil
end

local function findLinkTo(g, nodeId, pin)
    for i = 1, #g.links do
        local L = g.links[i]
        if L.toNode == nodeId and L.toPin == pin then return L end
    end
    return nil
end

local function findExecOut(g, nodeId, outPin)
    for i = 1, #g.links do
        local L = g.links[i]
        if L.fromNode == nodeId and L.fromPin == outPin then return L end
    end
    return nil
end

---------------------------------------------------------------------------
-- Data pin evaluation
---------------------------------------------------------------------------

local function evalData(g, nodeId, outPin, api, env, visiting)
    if visiting[nodeId] then return 0 end
    visiting[nodeId] = true
    local n = findNode(g, nodeId)
    if not n then
        visiting[nodeId] = nil
        return 0
    end

    local function input(pin, fallback)
        local L = findLinkTo(g, n.id, pin)
        if L then return evalData(g, L.fromNode, L.fromPin, api, env, visiting) end
        return fallback
    end

    local kind = n.kind
    local r

    if kind == 'EventOnInit' then
        r = (outPin == 1) and (env.seed or 0) or 0
    elseif kind == 'EventOnTick' then
        r = (outPin == 1) and (env.t or 0) or 0
    elseif kind == 'EventOnPlayerJoin' or kind == 'EventOnPlayerDeath' then
        r = (outPin == 1) and (env.peer or 0) or 0
    elseif kind == 'EventOnTrigger' then
        if outPin == 1 then r = env.trigger or ''
        elseif outPin == 2 then r = env.entityId or 0
        else r = 0 end
    elseif kind == 'GetPlayerCount' then
        r = (api.playerCount and api.playerCount()) or 0
    elseif kind == 'ConstInt' then
        r = n.intA or 0
    elseif kind == 'ConstFloat' then
        r = n.floatA or 0
    elseif kind == 'ConstString' then
        r = n.strA or ''
    elseif kind == 'Randi' then
        local lo = input(0, n.intA or 0)
        local hi = input(1, (n.intB ~= 0 and n.intB) or 10)
        if api.randi then
            r = api.randi(lo, hi)
        else
            if hi < lo then lo, hi = hi, lo end
            r = bareRng:int(lo, hi)
        end
    elseif kind == 'MathAdd' then
        local a = input(0, n.floatA or 0)
        local b = input(1, n.intB or 0)
        r = (tonumber(a) or 0) + (tonumber(b) or 0)
    elseif kind == 'MathGreater' then
        local a = input(0, 0)
        local b = input(1, 0)
        r = (tonumber(a) or 0) > (tonumber(b) or 0)
    elseif kind == 'GetItemId' then
        -- MeatEngine id lookup; here we return the name string itself.
        r = input(0, n.strA or '')
    elseif kind == 'GetWorldObject' then
        if outPin == 2 then r = n.strA or 'object'
        else r = n.intA or 0 end
    else
        r = 0
    end

    visiting[nodeId] = nil
    return r
end

local function inputExpr(g, n, pin, fallback, api, env)
    local L = findLinkTo(g, n.id, pin)
    if L then
        return evalData(g, L.fromNode, L.fromPin, api, env, {})
    end
    return fallback
end

---------------------------------------------------------------------------
-- Exec chain
---------------------------------------------------------------------------

local function runExec(g, nodeId, api, env, path)
    if not nodeId or nodeId == 0 then return end
    if path[nodeId] then return end -- cycle
    path[nodeId] = true

    local n = findNode(g, nodeId)
    if not n then
        path[nodeId] = nil
        return
    end

    local kind = n.kind
    local function nextOut(pin)
        local L = findExecOut(g, nodeId, pin)
        if L then runExec(g, L.toNode, api, env, path) end
    end

    if kind == 'ActionLog' then
        local msg = inputExpr(g, n, 2, n.strA or 'log', api, env)
        if api.log then api.log(tostring(msg)) end
        nextOut(1)

    elseif kind == 'ActionLogOnce' then
        -- strA = message key; logs only the first time this node runs.
        local key = n.strA ~= '' and n.strA or ('once_' .. tostring(n.id))
        g._once = g._once or {}
        if not g._once[key] then
            g._once[key] = true
            local msg = inputExpr(g, n, 2, key, api, env)
            if api.log then api.log(tostring(msg)) end
        end
        nextOut(1)

    elseif kind == 'ActionOpenDoor' then
        local tx = tonumber(inputExpr(g, n, 2, n.intA or 0, api, env)) or 0
        local ty = tonumber(inputExpr(g, n, 3, n.intB or 0, api, env)) or 0
        if api.openDoor then api.openDoor(tx, ty) end
        nextOut(1)

    elseif kind == 'ActionToggleDoor' then
        local tx = tonumber(inputExpr(g, n, 2, n.intA or 0, api, env)) or 0
        local ty = tonumber(inputExpr(g, n, 3, n.intB or 0, api, env)) or 0
        if api.toggleDoor then api.toggleDoor(tx, ty) end
        nextOut(1)

    elseif kind == 'ActionSpawnEntity' then
        local kindName = tostring(inputExpr(g, n, 2, n.strA or 'imp', api, env))
        local x = tonumber(inputExpr(g, n, 3, n.floatA or 0, api, env)) or 0
        local y = tonumber(inputExpr(g, n, 4, n.intA or 0, api, env)) or 0
        if api.spawnEntity then api.spawnEntity(kindName, x, y) end
        nextOut(1)

    elseif kind == 'ActionSetFloor' then
        local tx = tonumber(inputExpr(g, n, 2, n.intA or 0, api, env)) or 0
        local ty = tonumber(inputExpr(g, n, 3, n.intB or 0, api, env)) or 0
        local z  = tonumber(inputExpr(g, n, 4, n.floatA or 0, api, env)) or 0
        if api.setFloor then api.setFloor(tx, ty, z) end
        nextOut(1)

    elseif kind == 'ActionSetCeiling' then
        local tx = tonumber(inputExpr(g, n, 2, n.intA or 0, api, env)) or 0
        local ty = tonumber(inputExpr(g, n, 3, n.intB or 0, api, env)) or 0
        local z  = tonumber(inputExpr(g, n, 4, n.floatA or 1, api, env)) or 1
        if api.setCeiling then api.setCeiling(tx, ty, z) end
        nextOut(1)

    elseif kind == 'ActionSetBlock' then
        -- MeatEngine voxel write; map to destroy/repair when api allows.
        local x = tonumber(inputExpr(g, n, 2, n.intA or 0, api, env)) or 0
        local y = tonumber(inputExpr(g, n, 3, n.intB or 0, api, env)) or 0
        local block = tonumber(inputExpr(g, n, 5, n.intD or 0, api, env)) or 0
        if api.setBlock then
            api.setBlock(x, y, block)
        elseif block == 0 and api.destroyTile then
            api.destroyTile(x, y)
        end
        nextOut(1)

    elseif kind == 'ActionSpawnPickup' then
        local x = tonumber(inputExpr(g, n, 2, n.floatA or 0, api, env)) or 0
        local y = tonumber(inputExpr(g, n, 3, 0, api, env)) or 0
        local item = inputExpr(g, n, 5, n.strA or 'crystal', api, env)
        if api.spawnEntity then
            api.spawnEntity(tostring(item), x, y)
        elseif api.spawnPickup then
            api.spawnPickup(x, y, item)
        end
        nextOut(1)

    elseif kind == 'ActionAttachAI' then
        -- strA = state (patrol/chase/idle), floatA = speed, intA = alertRange
        local state = tostring(inputExpr(g, n, 2, n.strA ~= '' and n.strA or 'patrol', api, env))
        local speed = tonumber(inputExpr(g, n, 3, n.floatA ~= 0 and n.floatA or 2.4, api, env))
        local alert = tonumber(inputExpr(g, n, 4, n.intA ~= 0 and n.intA or 9, api, env))
        local eid = tonumber(inputExpr(g, n, 5, env.entityId or 0, api, env)) or 0
        if api.attachAI then
            api.attachAI(eid, { state = state, speed = speed, alertRange = alert })
        end
        nextOut(1)

    elseif kind == 'ActionAddScore' then
        local peer = tonumber(inputExpr(g, n, 2, n.intA or 0, api, env)) or 0
        local delta = tonumber(inputExpr(g, n, 3, n.intB or 1, api, env)) or 1
        if api.addScore then api.addScore(peer, delta) end
        nextOut(1)

    elseif kind == 'ActionGiveItem' then
        -- strA = item id, intA = count, entity from pin 4 or trigger env
        local item = tostring(inputExpr(g, n, 2, n.strA ~= '' and n.strA or 'ammo.pistol', api, env))
        local count = tonumber(inputExpr(g, n, 3, (n.intA ~= 0 and n.intA) or 1, api, env)) or 1
        local eid = tonumber(inputExpr(g, n, 4, env.entityId or 0, api, env)) or 0
        if api.giveItem then api.giveItem(eid, item, count) end
        nextOut(1)

    elseif kind == 'ActionEquipWeapon' then
        local weapon = tostring(inputExpr(g, n, 2, n.strA ~= '' and n.strA or 'pistol', api, env))
        local eid = tonumber(inputExpr(g, n, 3, env.entityId or 0, api, env)) or 0
        if api.equipWeapon then api.equipWeapon(eid, weapon) end
        nextOut(1)

    elseif kind == 'ActionDamage' then
        local amount = tonumber(inputExpr(g, n, 2, (n.intA ~= 0 and n.intA) or 10, api, env)) or 10
        local eid = tonumber(inputExpr(g, n, 3, env.entityId or 0, api, env)) or 0
        if api.damageEntity then api.damageEntity(eid, amount) end
        nextOut(1)

    elseif kind == 'ActionExplode' then
        -- floatA = x, intA = y (world), intB = radius*10 fallback, intC = damage
        local x = tonumber(inputExpr(g, n, 2, n.floatA or 0, api, env)) or 0
        local y = tonumber(inputExpr(g, n, 3, n.intA or 0, api, env)) or 0
        local radius = tonumber(inputExpr(g, n, 4, (n.intB ~= 0 and n.intB) or 3, api, env)) or 3
        local damage = tonumber(inputExpr(g, n, 5, (n.intC ~= 0 and n.intC) or 20, api, env)) or 20
        if api.explode then api.explode(x, y, radius, damage) end
        nextOut(1)

    elseif kind == 'ActionSeedGas' then
        -- intA,intB = tile; floatA = amount
        local tx = tonumber(inputExpr(g, n, 2, n.intA or 0, api, env)) or 0
        local ty = tonumber(inputExpr(g, n, 3, n.intB or 0, api, env)) or 0
        local amount = tonumber(inputExpr(g, n, 4, (n.floatA ~= 0 and n.floatA) or 1, api, env)) or 1
        if api.seedGas then api.seedGas(tx, ty, amount) end
        nextOut(1)

    elseif kind == 'Branch' then
        local cond = inputExpr(g, n, 1, false, api, env)
        local truthy = cond and cond ~= 0 and cond ~= ''
        if truthy then
            nextOut(2)
        else
            nextOut(3)
        end

    elseif kind == 'HighlightObject' or kind == 'PrintObject' then
        local obj = inputExpr(g, n, 2, n.intA or 0, api, env)
        if api.log then api.log('[graph] object ' .. tostring(obj)) end
        nextOut(1)

    else
        -- Pure / unknown on exec chain: try pin 0 then 1.
        nextOut(0)
        nextOut(1)
    end

    path[nodeId] = nil
end

---------------------------------------------------------------------------
-- Public graph API
---------------------------------------------------------------------------

function GraphMT:fire(event, api, env)
    api = api or {}
    env = env or {}
    local want
    for kind, name in pairs(EVENT_KIND) do
        if name == event then want = kind; break end
    end
    if not want then return false end

    local filterKinds = {
        EventOnTrigger = true,
        EventOnTriggerExit = true,
        EventOnTriggerStay = true,
    }

    local fired = false
    for i = 1, #self.nodes do
        local n = self.nodes[i]
        if n.kind == want then
            -- Optional name filter on trigger events (strA empty = any volume).
            if filterKinds[want] and n.strA and n.strA ~= '' then
                if tostring(env.trigger or '') ~= n.strA then
                    -- skip
                else
                    fired = true
                    local L = findExecOut(self, n.id, 0)
                    if L then runExec(self, L.toNode, api, env, {}) end
                end
            else
                fired = true
                local L = findExecOut(self, n.id, 0)
                if L then runExec(self, L.toNode, api, env, {}) end
            end
        end
    end
    return fired
end

function GraphMT:hasEvent(event)
    for kind, name in pairs(EVENT_KIND) do
        if name == event then
            for i = 1, #self.nodes do
                if self.nodes[i].kind == kind then return true end
            end
        end
    end
    return false
end

function GraphMT:nodeCount()
    return #self.nodes
end

---------------------------------------------------------------------------
-- Load / save
---------------------------------------------------------------------------

local function normalizeNode(n)
    return {
        id = tonumber(n.id) or 0,
        kind = tostring(n.kind or 'ActionLog'),
        x = tonumber(n.x) or 0,
        y = tonumber(n.y) or 0,
        strA = n.strA and tostring(n.strA) or '',
        intA = tonumber(n.intA) or 0,
        intB = tonumber(n.intB) or 0,
        intC = tonumber(n.intC) or 0,
        intD = tonumber(n.intD) or 0,
        floatA = tonumber(n.floatA) or 0,
    }
end

local function normalizeLink(L)
    return {
        id = tonumber(L.id) or 0,
        fromNode = tonumber(L.fromNode) or 0,
        fromPin = tonumber(L.fromPin) or 0,
        toNode = tonumber(L.toNode) or 0,
        toPin = tonumber(L.toPin) or 0,
    }
end

local function normalizeVolume(v)
    return {
        name = v.name and tostring(v.name) or 'zone',
        -- Tile-space preferred (1-based inclusive); world AABB if x1 present.
        tx1 = v.tx1 and tonumber(v.tx1) or nil,
        ty1 = v.ty1 and tonumber(v.ty1) or nil,
        tx2 = v.tx2 and tonumber(v.tx2) or nil,
        ty2 = v.ty2 and tonumber(v.ty2) or nil,
        x1 = v.x1 and tonumber(v.x1) or nil,
        y1 = v.y1 and tonumber(v.y1) or nil,
        x2 = v.x2 and tonumber(v.x2) or nil,
        y2 = v.y2 and tonumber(v.y2) or nil,
        once = v.once and true or false,
        filter = v.filter and tostring(v.filter) or nil, -- 'player' | 'any' | nil
    }
end

function MeatGraphRay.fromTable(t)
    if type(t) ~= 'table' then return nil, 'graph must be a table' end
    local g = setmetatable({
        name = t.name or 'main',
        version = t.version or 1,
        nextNodeId = tonumber(t.nextNodeId) or 1,
        nextLinkId = tonumber(t.nextLinkId) or 1,
        nodes = {},
        links = {},
        volumes = {},
        _once = {},
    }, GraphMT)

    for i = 1, #(t.nodes or {}) do
        g.nodes[i] = normalizeNode(t.nodes[i])
    end
    for i = 1, #(t.links or {}) do
        g.links[i] = normalizeLink(t.links[i])
    end
    for i = 1, #(t.volumes or {}) do
        g.volumes[i] = normalizeVolume(t.volumes[i])
    end
    return g
end

function MeatGraphRay.load(text)
    if type(text) == 'table' then return MeatGraphRay.fromTable(text) end
    if type(text) ~= 'string' then return nil, 'expected JSON string or table' end
    local ok, data = pcall(json.decode, text)
    if not ok then return nil, tostring(data) end
    return MeatGraphRay.fromTable(data)
end

function MeatGraphRay.save(g)
    local t = {
        version = g.version or 1,
        name = g.name or 'main',
        nextNodeId = g.nextNodeId or 1,
        nextLinkId = g.nextLinkId or 1,
        nodes = g.nodes,
        links = g.links,
        volumes = g.volumes,
    }
    return json.encode(t)
end

-- Starter graph: init log + tick branch when players > 0.
function MeatGraphRay.example()
    return MeatGraphRay.fromTable{
        version = 1,
        name = 'demo',
        nextNodeId = 10,
        nextLinkId = 10,
        nodes = {
            { id = 1, kind = 'EventOnInit', x = 40, y = 40 },
            { id = 2, kind = 'ActionLog', x = 280, y = 40, strA = 'node graph world init' },
            { id = 3, kind = 'EventOnTick', x = 40, y = 200 },
            { id = 4, kind = 'GetPlayerCount', x = 200, y = 260 },
            { id = 5, kind = 'ConstInt', x = 200, y = 320, intA = 0 },
            { id = 6, kind = 'MathGreater', x = 360, y = 260 },
            { id = 7, kind = 'Branch', x = 520, y = 200 },
            { id = 8, kind = 'ActionLog', x = 700, y = 180, strA = 'players online' },
            { id = 9, kind = 'EventOnPlayerJoin', x = 40, y = 420 },
            { id = 10, kind = 'ActionLog', x = 280, y = 420, strA = 'player joined (node graph)' },
        },
        links = {
            { id = 1, fromNode = 1, fromPin = 0, toNode = 2, toPin = 0 },
            { id = 2, fromNode = 3, fromPin = 0, toNode = 7, toPin = 0 },
            { id = 3, fromNode = 4, fromPin = 0, toNode = 6, toPin = 0 },
            { id = 4, fromNode = 5, fromPin = 0, toNode = 6, toPin = 1 },
            { id = 5, fromNode = 6, fromPin = 2, toNode = 7, toPin = 1 },
            { id = 6, fromNode = 7, fromPin = 2, toNode = 8, toPin = 0 },
            { id = 7, fromNode = 9, fromPin = 0, toNode = 10, toPin = 0 },
        },
    }
end

---------------------------------------------------------------------------
-- Host API factory — wires Mode / World / Entity conveniences
---------------------------------------------------------------------------

-- Builds an `api` table the graph can call. Everything optional; missing
-- methods become no-ops so a headless test only injects what it asserts.
function MeatGraphRay.apiFor(opts)
    opts = opts or {}
    local world = opts.world
    local mode = opts.mode
    local entities = opts.entities
    local logFn = opts.log
    local spawnFn = opts.spawnEntity
    local notes = opts.notes -- optional array to append log lines into

    local api = {}

    function api.log(msg)
        if notes then notes[#notes + 1] = tostring(msg) end
        if logFn then logFn(msg) end
    end

    function api.playerCount()
        if opts.playerCount then return opts.playerCount() end
        if mode and mode.score then
            local n = 0
            for _ in pairs(mode.score) do n = n + 1 end
            return n
        end
        local c = 0
        for i = 1, #(entities or {}) do
            local e = entities[i]
            if e and e:has('player') and not e.dead then c = c + 1 end
        end
        return c
    end

    -- G4: an injected rng wins; otherwise one is built from the SEED, so two
    -- hosts constructed alike draw alike — which is what lets a graph run
    -- inside a recorded demo. math.random appears nowhere: its sequence
    -- differs between Lua builds and cannot be replayed.
    local rng = (opts.rng and opts.rng.int and opts.rng)
                or Worldgen.rng(tonumber(opts.seed) or 1)
    function api.randi(lo, hi)
        lo, hi = tonumber(lo) or 0, tonumber(hi) or 0
        if hi < lo then lo, hi = hi, lo end
        return rng:int(lo, hi)
    end

    function api.openDoor(tx, ty)
        if world and world.setDoorOpen then world:setDoorOpen(tx, ty, true) end
    end

    function api.toggleDoor(tx, ty)
        if world and world.toggleDoor then world:toggleDoor(tx, ty) end
    end

    function api.setFloor(tx, ty, z)
        if world and world.setFloorHeight then world:setFloorHeight(tx, ty, z) end
    end

    function api.setCeiling(tx, ty, z)
        if world and world.setCeilingHeight then world:setCeilingHeight(tx, ty, z) end
    end

    function api.destroyTile(tx, ty)
        if world and world.destroyTile then world:destroyTile(tx, ty) end
    end

    function api.setBlock(tx, ty, block)
        if block == 0 then
            api.destroyTile(tx, ty)
        elseif world and world.repairTile then
            world:repairTile(tx, ty)
        end
    end

    function api.spawnEntity(kind, x, y)
        if spawnFn then return spawnFn(kind, x, y) end
        if opts.Entity and entities then
            local e = opts.Entity.spawn(kind, x, y)
            if e then entities[#entities + 1] = e end
            return e
        end
    end

    function api.addScore(peer, delta)
        if mode and mode.addScore then mode:addScore(peer, delta) end
    end

    function api.attachAI(entityId, brainOpts)
        if opts.attachAI then return opts.attachAI(entityId, brainOpts) end
        local AI = opts.AI or require('meatray.sim.ai')
        local list = entities or {}
        for i = 1, #list do
            local e = list[i]
            if e and e.id == entityId then
                AI.attach(e, brainOpts or {})
                return e
            end
        end
        -- Fall back: attach to the entity named in env during trigger fire.
        if opts.entity then
            AI.attach(opts.entity, brainOpts or {})
            return opts.entity
        end
    end

    function api.findEntity(entityId)
        if (not entityId or entityId == 0) and opts.entity then return opts.entity end
        for i = 1, #(entities or {}) do
            local e = entities[i]
            if e and e.id == entityId then return e end
        end
        if opts.entity then return opts.entity end
    end

    function api.giveItem(entityId, itemId, count)
        if opts.giveItem then return opts.giveItem(entityId, itemId, count) end
        local Inventory = opts.Inventory or require('meatray.game.inventory')
        local e = api.findEntity(entityId)
        if not e then return end
        if not e:has('inventory') then Inventory.attach(e, { capacity = 16 }) end
        return Inventory.add(e, itemId, count or 1)
    end

    function api.equipWeapon(entityId, weaponId)
        if opts.equipWeapon then return opts.equipWeapon(entityId, weaponId) end
        local Inventory = opts.Inventory or require('meatray.game.inventory')
        local e = api.findEntity(entityId)
        if not e then return end
        return Inventory.equipWeapon(e, weaponId)
    end

    function api.damageEntity(entityId, amount)
        if opts.damageEntity then return opts.damageEntity(entityId, amount) end
        local Damage = opts.Damage or require('meatray.game.damage')
        local Effects = opts.Effects or require('meatray.game.effects')
        local e = api.findEntity(entityId)
        if not e then return end
        -- Damage rides the ability system; attach a host-side container if none.
        if not e:get('gas') then
            Effects.attach(e, { authority = true })
        end
        return Damage.apply(e, amount or 0, { authority = true })
    end

    function api.explode(x, y, radius, damage)
        if opts.explode then return opts.explode(x, y, radius, damage) end
        local Explosion = opts.Explosion or require('meatray.game.explosion')
        if not world or not entities then return end
        return Explosion.detonate{
            world = world,
            entities = entities,
            x = x, y = y,
            radius = radius or 3,
            damage = damage or 20,
            gas = opts.gas,
            onLight = opts.onLight,
        }
    end

    function api.seedGas(tx, ty, amount)
        if opts.seedGas then return opts.seedGas(tx, ty, amount) end
        local field = opts.gas
        if field and field.emit then
            return field:emit(tx, ty, amount or 1)
        end
    end

    return api
end

local function makeApi(m, world, entities, apiOpts, extra)
    extra = extra or {}
    return MeatGraphRay.apiFor{
        world = world, mode = m, entities = entities,
        log = apiOpts and apiOpts.log,
        spawnEntity = apiOpts and apiOpts.spawnEntity,
        Entity = apiOpts and apiOpts.Entity,
        notes = apiOpts and apiOpts.notes,
        playerCount = apiOpts and apiOpts.playerCount,
        rng = apiOpts and apiOpts.rng,
        AI = apiOpts and apiOpts.AI,
        attachAI = apiOpts and apiOpts.attachAI,
        Inventory = apiOpts and apiOpts.Inventory,
        Damage = apiOpts and apiOpts.Damage,
        Explosion = apiOpts and apiOpts.Explosion,
        gas = apiOpts and apiOpts.gas,
        onLight = apiOpts and apiOpts.onLight,
        giveItem = apiOpts and apiOpts.giveItem,
        equipWeapon = apiOpts and apiOpts.equipWeapon,
        damageEntity = apiOpts and apiOpts.damageEntity,
        explode = apiOpts and apiOpts.explode,
        seedGas = apiOpts and apiOpts.seedGas,
        entity = extra.entity,
    }
end

---------------------------------------------------------------------------
-- Trigger volumes declared on the graph
---------------------------------------------------------------------------

-- Install graph.volumes into a Triggers set. Enter/exit/stay fire graph
-- events with env { trigger, entityId, entity, reason }.
-- Returns the number of volumes installed.
function MeatGraphRay.installVolumes(graph, triggers, getApi)
    if not graph or not triggers then return 0 end
    local vols = graph.volumes or {}
    local n = 0
    for i = 1, #vols do
        local v = vols[i]
        local opts = {
            name = v.name,
            once = v.once,
        }
        if v.tx1 then
            opts.tx1, opts.ty1 = v.tx1, v.ty1 or v.tx1
            opts.tx2, opts.ty2 = v.tx2 or v.tx1, v.ty2 or v.ty1 or v.tx1
        else
            opts.x1, opts.y1 = v.x1 or 0, v.y1 or 0
            opts.x2, opts.y2 = v.x2 or (opts.x1 + 1), v.y2 or (opts.y1 + 1)
        end

        if v.filter == 'player' then
            opts.filter = function(e) return e and e:has('player') end
        end

        local function envFor(e, reason)
            return {
                trigger = v.name,
                entityId = e and e.id or 0,
                entity = e,
                reason = reason,
            }
        end

        opts.onEnter = function(e, vol)
            local api = getApi and getApi(e) or {}
            graph:fire('trigger', api, envFor(e, 'enter'))
        end
        opts.onExit = function(e, vol, reason)
            local api = getApi and getApi(e) or {}
            graph:fire('trigger_exit', api, envFor(e, reason or 'leave'))
        end
        opts.onStay = function(e, vol, dt)
            local api = getApi and getApi(e) or {}
            local env = envFor(e, 'stay')
            env.t = dt
            graph:fire('trigger_stay', api, env)
        end

        if v.tx1 then
            triggers:addTiles(opts)
        else
            triggers:add(opts)
        end
        n = n + 1
    end
    return n
end

-- Binds a graph to a Mode instance: onStart / onTick / onPlayerJoin fire events.
-- If apiOpts.triggers is a Triggers set (or true to create one), volumes from
-- the graph are installed and updated each tick.
function MeatGraphRay.bindMode(mode, graph, apiOpts)
    if not mode or not graph then return mode end
    apiOpts = apiOpts or {}
    -- G4: one generator for the whole bound mode, made HERE and not in
    -- apiFor, because makeApi rebuilds the api per event — a per-call rng
    -- would reset to the seed on every fire and every Randi would draw the
    -- same first number forever.
    if not (apiOpts.rng and apiOpts.rng.int) then
        apiOpts.rng = Worldgen.rng(tonumber(apiOpts.seed) or 1)
    end
    local prevStart, prevTick = mode.onStart, mode.onTick
    local prevJoin, prevLeave = mode.onPlayerJoin, mode.onPlayerLeave

    mode.onStart = function(m, world, entities)
        if prevStart then prevStart(m, world, entities) end
        local api = makeApi(m, world, entities, apiOpts)
        m.data = m.data or {}
        m.data._ngApi = api
        m.data._ngGraph = graph
        m.data._ngApiOpts = apiOpts

        -- Trigger set: inject, create, or reuse.
        local Triggers = require('meatray.sim.triggers')
        local box = apiOpts.triggers
        if box == true then box = Triggers.new() end
        if box then
            local function getApi(entity)
                return makeApi(m, world, entities, apiOpts, { entity = entity })
            end
            local n = MeatGraphRay.installVolumes(graph, box, getApi)
            m.data._ngTriggers = box
            m.data._ngVolumeCount = n
        end

        graph:fire('init', api, { seed = apiOpts.seed or 1 })
    end

    mode.onTick = function(m, dt, world, entities)
        if prevTick then prevTick(m, dt, world, entities) end
        local g = m.data and m.data._ngGraph
        if not g then return end

        local api = makeApi(m, world, entities, apiOpts)
        m.data._ngApi = api

        local box = m.data._ngTriggers
        if box then
            box:update(entities, dt)
        end

        g:fire('tick', api, { t = dt })
    end

    mode.onPlayerJoin = function(m, peer, entity)
        if prevJoin then prevJoin(m, peer, entity) end
        local g = m.data and m.data._ngGraph
        if g then
            local api = makeApi(m, m.data and nil, nil, apiOpts)
            -- Prefer live api if already built this session.
            api = m.data and m.data._ngApi or api
            g:fire('join', api, { peer = peer, entityId = entity and entity.id or 0 })
        end
    end

    mode.onPlayerLeave = function(m, peer)
        if prevLeave then prevLeave(m, peer) end
    end

    return mode
end

MeatGraphRay.EVENT_KIND = EVENT_KIND
MeatGraphRay.isEventKind = isEventKind

return MeatGraphRay

