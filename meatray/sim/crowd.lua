--[[
    meatray.sim.crowd — many agents moving somewhere together, cheaply.

    Monsters think one at a time (sim.ai); a CROWD is the opposite trade:
    dozens of agents that share one brain. That brain is a flow field — a BFS
    from the goal across every walkable tile, leaving each tile a "step this
    way" arrow — so pathing cost is paid once per goal, not once per agent,
    and a hundred agents route around walls for the price of one flood fill.

    On top of the field, per-agent steering keeps the crowd looking like a
    crowd instead of a conga line: separation pushes neighbours apart (via a
    spatial hash, so it stays O(agents), not O(agents²)), and a seeded wander
    jitters the idle so a waiting crowd mills instead of freezing. The blend
    produces a unit desired-direction per agent; integration goes through
    Collide.move so agents slide along the same walls everything else does.

    Determinism, as everywhere in the sim: iteration in insertion order, all
    randomness from one engine LCG owned by the crowd, never math.random. Two
    hosts stepping the same crowd with the same dt sequence agree forever —
    which is what lets crowd agents replicate as ordinary entities and lets a
    demo recording contain one.

    Doors: the field treats shut doors as walkable (a crowd flows through a
    doorway once something opens it) unless opts.doorsBlock says otherwise.

    HEADLESS: pure Lua.
]]

local Worldgen = require('meatray.sim.worldgen')
local Collide = require('meatray.sim.collide')

local floor, sqrt, cos, sin = math.floor, math.sqrt, math.cos, math.sin

local Crowd = {}
local CrowdMT = {}
CrowdMT.__index = CrowdMT

---------------------------------------------------------------------------
-- Construction
---------------------------------------------------------------------------

-- opts:
--   seed         LCG seed (default 1)
--   radius       agent body radius for wall sliding (default 0.3)
--   speed        tiles/second (default 1.6)
--   separation   distance under which neighbours push apart (default 0.7)
--   sepWeight    strength of that push vs the goal pull (default 1.2)
--   wander       idle jitter strength when there is no goal (default 0.3)
--   doorsBlock   true = shut doors seal the field (default false)
--   openDoors    agents open shut doors they walk into (default true —
--                matching doorsBlock=false: a field that routes through a
--                door only works if someone can open it)
function Crowd.new(world, opts)
    opts = opts or {}
    return setmetatable({
        world = world,
        rng = Worldgen.rng(tonumber(opts.seed) or 1),
        radius = opts.radius or 0.3,
        speed = opts.speed or 1.6,
        separation = opts.separation or 0.7,
        sepWeight = opts.sepWeight or 1.2,
        wander = opts.wander or 0.3,
        doorsBlock = opts.doorsBlock or false,
        openDoors = opts.openDoors ~= false,
        agents = {},           -- insertion order IS the step order
        field = nil,           -- [storey][ty][tx] = { dx, dy } toward the goal
        goal = nil,            -- { x, y, storey }
    }, CrowdMT)
end

-- An agent is any table with x, y (and optionally storey, angle). Entities
-- qualify as-is, which is the point: a crowd member is an ordinary entity
-- that replicates, takes damage and dies like everything else.
function CrowdMT:add(agent)
    agent.storey = agent.storey or 1
    self.agents[#self.agents + 1] = agent
    return agent
end

function CrowdMT:remove(agent)
    for i, a in ipairs(self.agents) do
        if a == agent then
            table.remove(self.agents, i)
            return true
        end
    end
    return false
end

function CrowdMT:count() return #self.agents end

---------------------------------------------------------------------------
-- The flow field
---------------------------------------------------------------------------

local function walkable(self, tx, ty, storey)
    local world = self.world
    if tx < 1 or ty < 1 or tx > world.width or ty > world.height then return false end
    local door = world.doorAt and world:doorAt(tx, ty, storey)
    if door then
        if self.doorsBlock and not door.open then return false end
        return true
    end
    return not world:isSolid(tx, ty, storey)
end

-- BFS out from the goal tile; every reached tile points one step back along
-- its discovery — i.e. toward the goal. 4-way, so an arrow is always a move
-- Collide.move can actually take (diagonal arrows squeeze into corners).
function CrowdMT:setGoal(x, y, storey)
    storey = storey or 1
    local world = self.world
    local gtx, gty = floor(x) + 1, floor(y) + 1
    if not walkable(self, gtx, gty, storey) then return false, 'goal is inside a wall' end

    self.goal = { x = x, y = y, storey = storey }
    local field = {}
    self.field = { [storey] = field }

    local visited = { [gty * 4096 + gtx] = true }
    local queue = { { gtx, gty } }
    local head = 1
    field[gty] = { [gtx] = { dx = 0, dy = 0 } }

    local DIRS = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }
    while head <= #queue do
        local cell = queue[head]
        head = head + 1
        local cx, cy = cell[1], cell[2]
        for _, d in ipairs(DIRS) do
            local nx, ny = cx + d[1], cy + d[2]
            local key = ny * 4096 + nx
            if not visited[key] and walkable(self, nx, ny, storey) then
                visited[key] = true
                field[ny] = field[ny] or {}
                -- The arrow points from the neighbour BACK to the cell we
                -- came from — one step closer to the goal.
                field[ny][nx] = { dx = -d[1], dy = -d[2] }
                queue[#queue + 1] = { nx, ny }
            end
        end
    end
    return true
end

function CrowdMT:clearGoal()
    self.goal = nil
    self.field = nil
end

-- The field's arrow under a world position, or nil off-field (unreached
-- tiles: sealed rooms, other storeys).
function CrowdMT:flowAt(x, y, storey)
    storey = storey or 1
    local perStorey = self.field and self.field[storey]
    if not perStorey then return nil end
    local row = perStorey[floor(y) + 1]
    return row and row[floor(x) + 1] or nil
end

---------------------------------------------------------------------------
-- Stepping
---------------------------------------------------------------------------

-- One spatial-hash bucket pass per step: neighbours are only compared inside
-- a cell and its 8 surrounds, so separation is linear in practice.
local function buildHash(agents, cell)
    local hash = {}
    for i, a in ipairs(agents) do
        local key = (a.storey or 1) * 1e8 + floor(a.y / cell) * 1e4 + floor(a.x / cell)
        local bucket = hash[key]
        if not bucket then bucket = {}; hash[key] = bucket end
        bucket[#bucket + 1] = i
    end
    return hash
end

local function separationPush(self, hash, cell, index, agent)
    local pushX, pushY = 0, 0
    local sep = self.separation
    local storey = agent.storey or 1
    local cx, cy = floor(agent.x / cell), floor(agent.y / cell)
    for oy = -1, 1 do
        for ox = -1, 1 do
            local bucket = hash[storey * 1e8 + (cy + oy) * 1e4 + (cx + ox)]
            if bucket then
                for _, j in ipairs(bucket) do
                    if j ~= index then
                        local other = self.agents[j]
                        local dx, dy = agent.x - other.x, agent.y - other.y
                        local d2 = dx * dx + dy * dy
                        if d2 <= 1e-9 then
                            -- Exactly stacked: the symmetric push is zero and
                            -- would stay zero forever. Break the tie with a
                            -- seeded shove; insertion-order iteration keeps
                            -- even this deterministic.
                            local ang = self.rng:float() * 2 * 3.141592653589793
                            pushX = pushX + cos(ang)
                            pushY = pushY + sin(ang)
                        elseif d2 < sep * sep then
                            local d = sqrt(d2)
                            local w = (sep - d) / sep      -- closer = harder
                            pushX = pushX + dx / d * w
                            pushY = pushY + dy / d * w
                        end
                    end
                end
            end
        end
    end
    return pushX, pushY
end

-- Advances every agent. Each gets a desired direction — the field's arrow
-- (softened toward the exact goal point on the goal tile) blended with the
-- separation push, or a wander jitter with no goal — normalised and walked
-- through Collide.move at the crowd's speed. Sets agent.angle to the walk
-- direction so a renderer can face the sprite without knowing about crowds.
function CrowdMT:step(dt)
    dt = math.max(0, tonumber(dt) or 0)
    if dt == 0 or #self.agents == 0 then return end

    local cell = math.max(self.separation, 0.5)
    local hash = buildHash(self.agents, cell)

    for i, a in ipairs(self.agents) do
        local dirX, dirY = 0, 0

        local flow = self:flowAt(a.x, a.y, a.storey)
        if flow then
            if flow.dx == 0 and flow.dy == 0 and self.goal then
                -- On the goal tile: aim at the goal point itself, so the
                -- crowd gathers on it rather than orbiting the tile centre.
                dirX, dirY = self.goal.x - a.x, self.goal.y - a.y
                local d = sqrt(dirX * dirX + dirY * dirY)
                if d < 0.2 then dirX, dirY = 0, 0
                else dirX, dirY = dirX / d, dirY / d end
            else
                -- Steer at the CENTRE of the next tile, not along the raw
                -- arrow. The raw arrow grinds corners: an agent hugging the
                -- wall beside a one-tile doorway pushes straight into the
                -- door frame forever, because "+x" is blocked and there is
                -- no sideways component to slide on. Aiming at the centre
                -- gives the slide that component and lines agents up with
                -- the gap.
                local cx = (floor(a.x) + flow.dx) + 0.5
                local cy = (floor(a.y) + flow.dy) + 0.5
                dirX, dirY = cx - a.x, cy - a.y
                local d = sqrt(dirX * dirX + dirY * dirY)
                if d > 1e-6 then dirX, dirY = dirX / d, dirY / d end
            end
        elseif not self.goal and self.wander > 0 then
            -- Milling: a small seeded turn each step, applied to the angle
            -- the agent already had, so idle motion is drift, not teleport.
            local ang = (a.angle or 0) + (self.rng:float() - 0.5) * 2.5 * self.wander
            dirX, dirY = cos(ang) * self.wander, sin(ang) * self.wander
        end

        local pushX, pushY = separationPush(self, hash, cell, i, a)
        dirX = dirX + pushX * self.sepWeight
        dirY = dirY + pushY * self.sepWeight

        local len = sqrt(dirX * dirX + dirY * dirY)
        if len > 1e-6 then
            dirX, dirY = dirX / len, dirY / len

            -- A shut door in the way gets opened, not bounced off — the
            -- field routed through it on the promise someone would.
            if self.openDoors and self.world.toggleDoor then
                local tx = floor(a.x + dirX * 0.7) + 1
                local ty = floor(a.y + dirY * 0.7) + 1
                local door = self.world.doorAt and self.world:doorAt(tx, ty, a.storey)
                if door and not door.open then
                    self.world:toggleDoor(tx, ty, a.storey)
                end
            end

            Collide.move(a, dirX * self.speed * dt, dirY * self.speed * dt,
                         self.world, self.radius)
            a.angle = math.atan2 and math.atan2(dirY, dirX) or math.atan(dirY, dirX)
        end
    end
end

return Crowd
