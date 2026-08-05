--[[
    meatray.net.netdemo — record and replay a NETWORKED session.

    The F1 demo (meatray.sim.demo) records the SOLO loop as an input stream and
    re-simulates it. A joined client never simulates — it is told the world by
    snapshots — so that format cannot capture a multiplayer game. This one can:
    it records the authoritative snapshot stream the client already receives,
    plus the world payload it joined against, and replays by feeding those
    snapshots back through the SAME apply path (Rep.applyEntities) with no
    socket. What a spectator saw is exactly what a replay shows, because it is
    the identical bytes.

    Kept OUT of sim.demo on purpose: sim.demo has a golden compat corpus, and a
    networked recording is a different thing (a state stream, not an input
    stream). Two formats, two files, no entanglement.

    A recording is JSON: { rate, world = joinPayload, snaps = { {t, body}, .. } }.
    Every snapshot is stored — keyframes and partials — because a partial is a
    diff against the accumulated baseline, and replaying the whole stream in
    order reconstructs that baseline exactly as the live client did.

    HEADLESS: pure Lua.
]]

local json = require('meatray.net.json')
local Rep = require('meatray.net.replication')

local NetDemo = {}

NetDemo.MAGIC = 'meatray-netdemo-1'

---------------------------------------------------------------------------
-- Recording
---------------------------------------------------------------------------

local RecMT = {}
RecMT.__index = RecMT

function NetDemo.recorder(opts)
    opts = opts or {}
    return setmetatable({
        rate = opts.rate or 20,        -- snapshot rate, informational
        world = opts.world,            -- the join world payload
        snaps = {},
    }, RecMT)
end

-- The world the client joined against — Rep.worldPayload shape, stored once so
-- replay rebuilds the same geometry. A later call replaces it (a map change is
-- a fresh world), which a replay treats as a new segment start.
function RecMT:setWorld(payload)
    self.world = payload
end

-- One received snapshot. body is the decoded snapshot table (tick/full/k/e/r).
function RecMT:frame(tick, body)
    -- Store a shallow copy of the fields that matter, so a later mutation of the
    -- live body (the client reuses tables) cannot rewrite history.
    self.snaps[#self.snaps + 1] = {
        t = tick,
        full = body.full,
        k = body.k,
        e = body.e,
        r = body.r,
    }
end

function RecMT:count() return #self.snaps end

function RecMT:finish()
    return json.encode{
        magic = NetDemo.MAGIC,
        rate = self.rate,
        world = self.world,
        snaps = self.snaps,
    }
end

---------------------------------------------------------------------------
-- Loading
---------------------------------------------------------------------------

function NetDemo.load(text)
    local ok, decoded = pcall(json.decode, text)
    if not ok then return nil, 'bad JSON: ' .. tostring(decoded) end
    if type(decoded) ~= 'table' or decoded.magic ~= NetDemo.MAGIC then
        return nil, 'not a netdemo'
    end
    decoded.snaps = decoded.snaps or {}
    return decoded
end

---------------------------------------------------------------------------
-- Replay
---------------------------------------------------------------------------

-- A replay is a context the snapshots reconstruct into. It carries the same
-- byId/entities Rep.applyEntities reads, and a tick cursor. Optionally the
-- world is rebuilt from the payload for a caller that wants to render it.
local PlayMT = {}
PlayMT.__index = PlayMT

function NetDemo.replay(demo)
    if type(demo) == 'string' then
        local d, err = NetDemo.load(demo)
        if not d then return nil, err end
        demo = d
    end
    local world = demo.world and Rep.buildWorld(demo.world) or nil
    return setmetatable({
        snaps = demo.snaps,
        world = world,
        rate = demo.rate,
        byId = {},
        entities = {},
        cursor = 0,             -- index of the last applied snapshot
    }, PlayMT)
end

function PlayMT:length() return #self.snaps end

-- Applies the next recorded snapshot. Returns its tick, or nil at the end.
function PlayMT:step()
    if self.cursor >= #self.snaps then return nil end
    self.cursor = self.cursor + 1
    local s = self.snaps[self.cursor]
    Rep.applyEntities(self, s.e or {}, {
        full = s.full ~= false,
        removed = s.r,
    })
    return s.t
end

-- Applies everything through to the end; the terminal state is what a viewer
-- would see on the last frame. Returns the entity list.
function PlayMT:runToEnd()
    while self:step() do end
    return self.entities
end

-- The entity replayed under an id, or nil. Lets a test assert continuity
-- against the live session the demo was taken from.
function PlayMT:entity(id)
    return self.byId[id]
end

return NetDemo
