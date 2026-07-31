--[[
    meatray.game.blueprint — host-side node graphs (MeatEngine C6 kinship).

    MeatEngine's visual scripting (docs/BLUEPRINTS.md there) authors graphs in
    imnodes and *compiles them to sandboxed Lua*. MeatRayCast has no ImGui
    editor yet; what we share is the **data model and the idea**:

      * Graph JSON is the source of truth (same shape: version, nodes, links).
      * Only Event / Action / Branch walk an exec chain; data pins resolve by
        walking links backward (literals fill unwired inputs).
      * Runtime is always host-authoritative — never run on a client.

    This module *interprets* graphs in pure Lua rather than emitting source.
    That keeps the headless suite free of loadstring and keeps capability
    gates explicit in one `api` table the host injects.

        local BP = require('meatray.game.blueprint')
        local g = BP.load(jsonText)          -- or BP.fromTable(t)
        local api = BP.apiFor{ mode = mode, world = world, log = print }
        g:fire('init', api, { seed = 1 })
        g:fire('tick', api, { t = dt })

    Compatible with MeatEngine node kind *names* for the shared subset
    (EventOnInit, ActionLog, Branch, MathAdd, …). Raycast-specific kinds
    (ActionOpenDoor, ActionSpawnEntity, …) are local extensions.

    HEADLESS: pure Lua.
]]

local json = require('meatray.net.json')

local Blueprint = {}

---------------------------------------------------------------------------
-- Kind registry (shared names first, then raycast extensions)
---------------------------------------------------------------------------

-- Event names used by :fire(event, …).
local EVENT_KIND = {
    EventOnInit        = 'init',
    EventOnTick        = 'tick',
    EventOnPlayerJoin  = 'join',
    EventOnPlayerDeath = 'death',
    EventOnTrigger     = 'trigger',
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
            r = lo + math.floor(math.random() * (hi - lo + 1))
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

    elseif kind == 'ActionAddScore' then
        local peer = tonumber(inputExpr(g, n, 2, n.intA or 0, api, env)) or 0
        local delta = tonumber(inputExpr(g, n, 3, n.intB or 1, api, env)) or 1
        if api.addScore then api.addScore(peer, delta) end
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
        if api.log then api.log('[blueprint] object ' .. tostring(obj)) end
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

    local fired = false
    for i = 1, #self.nodes do
        local n = self.nodes[i]
        if n.kind == want then
            -- Optional filter: EventOnTrigger only if strA empty or matches.
            if want == 'EventOnTrigger' and n.strA and n.strA ~= '' then
                if tostring(env.trigger or '') ~= n.strA then
                    goto continue
                end
            end
            fired = true
            local L = findExecOut(self, n.id, 0)
            if L then runExec(self, L.toNode, api, env, {}) end
            ::continue::
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

function Blueprint.fromTable(t)
    if type(t) ~= 'table' then return nil, 'graph must be a table' end
    local g = setmetatable({
        name = t.name or 'main',
        version = t.version or 1,
        nextNodeId = tonumber(t.nextNodeId) or 1,
        nextLinkId = tonumber(t.nextLinkId) or 1,
        nodes = {},
        links = {},
    }, GraphMT)

    for i = 1, #(t.nodes or {}) do
        g.nodes[i] = normalizeNode(t.nodes[i])
    end
    for i = 1, #(t.links or {}) do
        g.links[i] = normalizeLink(t.links[i])
    end
    return g
end

function Blueprint.load(text)
    if type(text) == 'table' then return Blueprint.fromTable(text) end
    if type(text) ~= 'string' then return nil, 'expected JSON string or table' end
    local ok, data = pcall(json.decode, text)
    if not ok then return nil, tostring(data) end
    return Blueprint.fromTable(data)
end

function Blueprint.save(g)
    local t = {
        version = g.version or 1,
        name = g.name or 'main',
        nextNodeId = g.nextNodeId or 1,
        nextLinkId = g.nextLinkId or 1,
        nodes = g.nodes,
        links = g.links,
    }
    return json.encode(t)
end

-- Starter graph: init log + tick branch when players > 0.
function Blueprint.example()
    return Blueprint.fromTable{
        version = 1,
        name = 'demo',
        nextNodeId = 10,
        nextLinkId = 10,
        nodes = {
            { id = 1, kind = 'EventOnInit', x = 40, y = 40 },
            { id = 2, kind = 'ActionLog', x = 280, y = 40, strA = 'blueprint world init' },
            { id = 3, kind = 'EventOnTick', x = 40, y = 200 },
            { id = 4, kind = 'GetPlayerCount', x = 200, y = 260 },
            { id = 5, kind = 'ConstInt', x = 200, y = 320, intA = 0 },
            { id = 6, kind = 'MathGreater', x = 360, y = 260 },
            { id = 7, kind = 'Branch', x = 520, y = 200 },
            { id = 8, kind = 'ActionLog', x = 700, y = 180, strA = 'players online' },
            { id = 9, kind = 'EventOnPlayerJoin', x = 40, y = 420 },
            { id = 10, kind = 'ActionLog', x = 280, y = 420, strA = 'player joined (blueprint)' },
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
function Blueprint.apiFor(opts)
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

    function api.randi(lo, hi)
        lo, hi = tonumber(lo) or 0, tonumber(hi) or 0
        if hi < lo then lo, hi = hi, lo end
        if opts.rng and opts.rng.int then return opts.rng:int(lo, hi) end
        return lo + math.floor(math.random() * (hi - lo + 1))
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

    return api
end

-- Binds a graph to a Mode instance: onStart / onTick / onPlayerJoin fire events.
function Blueprint.bindMode(mode, graph, apiOpts)
    if not mode or not graph then return mode end
    local prevStart, prevTick = mode.onStart, mode.onTick
    local prevJoin, prevLeave = mode.onPlayerJoin, mode.onPlayerLeave

    mode.onStart = function(m, world, entities)
        if prevStart then prevStart(m, world, entities) end
        local api = Blueprint.apiFor{
            world = world, mode = m, entities = entities,
            log = apiOpts and apiOpts.log,
            spawnEntity = apiOpts and apiOpts.spawnEntity,
            Entity = apiOpts and apiOpts.Entity,
            notes = apiOpts and apiOpts.notes,
            playerCount = apiOpts and apiOpts.playerCount,
            rng = apiOpts and apiOpts.rng,
        }
        m.data = m.data or {}
        m.data._bpApi = api
        m.data._bpGraph = graph
        graph:fire('init', api, { seed = (apiOpts and apiOpts.seed) or 1 })
    end

    mode.onTick = function(m, dt, world, entities)
        if prevTick then prevTick(m, dt, world, entities) end
        local api = m.data and m.data._bpApi
        local g = m.data and m.data._bpGraph
        if api and g then
            if world then api = Blueprint.apiFor{
                world = world, mode = m, entities = entities,
                log = apiOpts and apiOpts.log,
                spawnEntity = apiOpts and apiOpts.spawnEntity,
                Entity = apiOpts and apiOpts.Entity,
                notes = apiOpts and apiOpts.notes,
                playerCount = apiOpts and apiOpts.playerCount,
                rng = apiOpts and apiOpts.rng,
            } end
            g:fire('tick', api, { t = dt })
        end
    end

    mode.onPlayerJoin = function(m, peer, entity)
        if prevJoin then prevJoin(m, peer, entity) end
        local g = m.data and m.data._bpGraph
        local api = m.data and m.data._bpApi
        if g and api then
            g:fire('join', api, { peer = peer })
        end
    end

    mode.onPlayerLeave = function(m, peer)
        if prevLeave then prevLeave(m, peer) end
    end

    return mode
end

Blueprint.EVENT_KIND = EVENT_KIND
Blueprint.isEventKind = isEventKind

return Blueprint
