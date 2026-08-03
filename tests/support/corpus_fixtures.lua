--[[
    Shared fixtures for the wire/save compatibility corpus (G6).

    Both the generator (scripts/gen_corpus.lua) and the test (test_compat.lua)
    build the SAME canonical objects here, so the golden bytes and the live
    check can never drift apart by accident: they come from one definition.

    Everything is deterministic — fixed ids, fixed coordinates, a fixed
    savedAt — so encoding the same fixture twice, on any build, produces the
    same bytes. That is the whole premise of a golden corpus.

    Each fixture: { name, kind = 'packet'|'snapshot'|'save', build = fn ->
    the LIVE object, encode = fn(obj) -> bytes, decodeCheck = fn(decoded) ->
    ok, why }. The generator calls build+encode; the test decodes the stored
    bytes and runs decodeCheck.
]]

local P     = require('meatray.net.protocol')
local Codec = require('meatray.net.snapcodec')
local Format = require('meatray.save.format')
local State = require('meatray.save.state')
local World = require('meatray.sim.world')
local Entity = require('meatray.sim.entity')
local C     = require('meatray.sim.components')

local Fixtures = {}

-- A fixed 6x6 room with one door, reused by the save fixtures.
local function room()
    local g = {}
    for y = 1, 6 do
        g[y] = {}
        for x = 1, 6 do
            g[y][x] = (x == 1 or y == 1 or x == 6 or y == 6) and 1 or 0
        end
    end
    local w = World.new(g, { theme = 'dungeon', spawn = { x = 2.5, y = 2.5 } })
    w:addDoor(3, 3, true)
    return w
end

-- A fixed snapshot body: two entities with known transforms and one nested
-- component. Its numbers include a negative and a non-round float so a codec
-- that mangles either is caught.
local function snapshotBody()
    return {
        tick = 4242,
        e = {
            { id = 1, kind = 'p', x = 12.5, y = 9.25, angle = 0.3927,
              c = { h = { hp = 88, max = 100 }, w = { ammo = 42 } } },
            { id = 2, kind = 'g', x = -3.75, y = 21.125, angle = -1.5708 },
        },
    }
end

-- A save document over the fixed room, with a couple of entities and a meta
-- block. savedAt is pinned, so the bytes are stable.
local function saveDoc()
    Entity.clearArchetypes()
    Entity.resetIds(1)
    Entity.archetype('imp', function(e)
        e:add(C.Billboard{ sheet = 'imp' })
        e:add(C.Health{ hp = 30, max = 30 })
    end)

    local world = room()
    local imp = Entity.spawn('imp', 4.25, 3.75)
    imp.angle = 1.25
    imp:get('health').hp = 17

    local doc = State.capture{
        world = world,
        entities = { imp },
        progress = { level = 2, keys = { 'red' } },
        meta = { automap = { radius = 4, storeys = { [1] = '2,2;2,3;3,2' } } },
        map = 'corpus',
        savedAt = 1700000000,
        playTime = 42.5,
    }
    Entity.clearArchetypes()
    Entity.resetIds(1)
    return doc
end

---------------------------------------------------------------------------
-- The fixture list
---------------------------------------------------------------------------

function Fixtures.all()
    return {
        {
            name = 'packet.ping',
            kind = 'packet',
            version = P.VERSION,
            build = function() return { time = 12345 } end,
            encode = function(b) return P.pack(P.PING, b) end,
            decodeCheck = function(kind, body)
                if kind ~= P.PING then return false, 'wrong tag' end
                if body.time ~= 12345 then return false, 'time lost' end
                return true
            end,
        },
        {
            name = 'packet.chat',
            kind = 'packet',
            version = P.VERSION,
            build = function() return { text = 'hello world', name = 'meat' } end,
            encode = function(b) return P.pack(P.CHAT, b) end,
            decodeCheck = function(kind, body)
                if kind ~= P.CHAT then return false, 'wrong tag' end
                if body.text ~= 'hello world' then return false, 'text lost' end
                return true
            end,
        },
        {
            name = 'packet.accept',
            kind = 'packet',
            version = P.VERSION,
            build = function()
                return { peerId = 3, entityId = 1048580, tickRate = 60,
                         snapshotRate = 20, moveSpeed = 3.2, turnSpeed = 2.6,
                         idBase = 1048576, name = 'srv', map = 'arena',
                         mode = 'dm' }
            end,
            encode = function(b) return P.pack(P.ACCEPT, b) end,
            decodeCheck = function(kind, body)
                if kind ~= P.ACCEPT then return false, 'wrong tag' end
                if body.peerId ~= 3 then return false, 'peerId lost' end
                if body.entityId ~= 1048580 then return false, 'entityId lost' end
                if math.abs((body.moveSpeed or 0) - 3.2) > 1e-6 then
                    return false, 'moveSpeed drifted'
                end
                return true
            end,
        },
        {
            name = 'snapshot.two-entities',
            kind = 'snapshot',
            version = P.VERSION,
            build = snapshotBody,
            encode = function(b) return P.packSnapshot(b) end,
            decodeCheck = function(kind, body)
                if kind ~= P.SNAPSHOT then return false, 'wrong tag' end
                if body.tick ~= 4242 then return false, 'tick lost' end
                if #body.e ~= 2 then return false, 'entity count lost' end
                if math.abs(body.e[1].x - 12.5) > 1e-4 then
                    return false, 'x drifted'
                end
                if body.e[2].x >= 0 then return false, 'negative x lost its sign' end
                if not (body.e[1].c and body.e[1].c.h and body.e[1].c.h.hp == 88) then
                    return false, 'nested component lost'
                end
                return true
            end,
        },
        {
            name = 'save.room-with-imp',
            kind = 'save',
            version = Format.VERSION,
            build = saveDoc,
            encode = function(doc) return Format.encode(doc) end,
            decodeCheck = function(doc)
                if type(doc) ~= 'table' or type(doc.body) ~= 'table' then
                    return false, 'no body'
                end
                if doc.meta.map ~= 'corpus' then return false, 'map name lost' end
                if not (doc.body.progress and doc.body.progress.level == 2) then
                    return false, 'progress lost'
                end
                local world = doc.body.world
                if type(world) ~= 'table' then return false, 'no world payload' end
                if #(doc.body.entities or {}) ~= 1 then
                    return false, 'entity count lost'
                end
                return true
            end,
        },
    }
end

-- Snapshot/packet fixtures use snapcodec; pin the pure-Lua backend so the
-- bytes match on LuaJIT and plain Lua alike.
function Fixtures.pinBackend()
    Codec.useBackend('table', 'lua')
end

-- Decodes stored bytes for a fixture and hands the result to its check.
-- Packets and snapshots go through P.unpack; saves through Format.decode.
function Fixtures.decode(fixture, bytes)
    if fixture.kind == 'save' then
        local doc, err = Format.decode(bytes)
        if not doc then return false, 'decode failed: ' .. tostring(err) end
        return fixture.decodeCheck(doc)
    end
    local kind, body, err = P.unpack(bytes)
    if not kind then return false, 'unpack failed: ' .. tostring(err) end
    return fixture.decodeCheck(kind, body)
end

return Fixtures
