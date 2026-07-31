--[[
    meatray.sim.movers — elevators and other synced floor height animators.

    A mover owns a list of tiles and slides their relative floor height between
    zDown and zUp. Games call :update(dt) on the host each tick; clients apply
    the same snapshot the doors already use (keyed heights + phase).

    Collision and rendering already read floorHeights, so a mover is "just"
    writing setFloorHeight every frame — risers rebuild on each write unless
    opts.defer is used (we defer during motion and rebuild once on stop).

    HEADLESS: pure Lua.
]]

local Movers = {}

local MoversMT = {}
MoversMT.__index = MoversMT

local function clamp(v, a, b)
    if v < a then return a end
    if v > b then return b end
    return v
end

function Movers.new(world, opts)
    opts = opts or {}
    return setmetatable({
        world = world,
        list = {},
        nextId = 1,
        -- Rebuild risers every N seconds while moving (cheap platforms).
        riserInterval = opts.riserInterval or 0.25,
        _riserAge = 0,
    }, MoversMT)
end

--[[
    opts:
      tiles   { {tx,ty}, ... } or { tx=, ty= }
      storey  default 1
      zDown   floor height when down (default 0)
      zUp     floor height when up (default 0.4)
      speed   units per second (default 0.35)
      start   'down' | 'up' (default 'down')
      id      optional fixed id for net
]]
function MoversMT:add(opts)
    opts = opts or {}
    local tiles = {}
    for i = 1, #(opts.tiles or {}) do
        local t = opts.tiles[i]
        if type(t) == 'table' then
            local tx = t.tx or t[1]
            local ty = t.ty or t[2]
            if tx and ty then tiles[#tiles + 1] = { tx = tx, ty = ty } end
        end
    end
    if #tiles == 0 then return nil, 'mover needs tiles' end

    local zDown = opts.zDown or 0
    local zUp = opts.zUp or 0.4
    if zUp < zDown then zDown, zUp = zUp, zDown end

    local startUp = (opts.start == 'up')
    local m = {
        id = opts.id or self.nextId,
        tiles = tiles,
        storey = opts.storey or 1,
        zDown = zDown,
        zUp = zUp,
        speed = opts.speed or 0.35,
        z = startUp and zUp or zDown,
        target = startUp and zUp or zDown,
        moving = false,
    }
    if type(m.id) == 'number' and m.id >= self.nextId then
        self.nextId = m.id + 1
    end
    self.list[#self.list + 1] = m
    self:_apply(m, false)
    return m
end

function MoversMT:get(id)
    for i = 1, #self.list do
        if self.list[i].id == id then return self.list[i] end
    end
    return nil
end

function MoversMT:call(id, wantUp)
    local m = self:get(id)
    if not m then return false end
    if wantUp == nil then
        -- Toggle toward the other end.
        local mid = (m.zDown + m.zUp) * 0.5
        wantUp = m.z < mid
    end
    m.target = wantUp and m.zUp or m.zDown
    m.moving = math.abs(m.z - m.target) > 1e-4
    return true
end

function MoversMT:toggle(id)
    local m = self:get(id)
    if not m then return false end
    local mid = (m.zDown + m.zUp) * 0.5
    return self:call(id, m.z < mid + 1e-4)
end

function MoversMT:_apply(m, rebuild)
    local world = self.world
    if not world or not world.setFloorHeight then return end
    for i = 1, #m.tiles do
        local t = m.tiles[i]
        world:setFloorHeight(t.tx, t.ty, m.z, {
            storey = m.storey,
            defer = not rebuild,
        })
    end
    if rebuild and world.rebuildFloorRisers then
        world:rebuildFloorRisers(m.storey)
    end
end

function MoversMT:update(dt)
    dt = dt or 0
    if dt < 0 then dt = 0 end
    local anyMoving = false
    for i = 1, #self.list do
        local m = self.list[i]
        if math.abs(m.z - m.target) > 1e-5 then
            m.moving = true
            anyMoving = true
            local step = (m.speed or 0.35) * dt
            if m.z < m.target then
                m.z = math.min(m.target, m.z + step)
            else
                m.z = math.max(m.target, m.z - step)
            end
            self:_apply(m, false)
            if math.abs(m.z - m.target) <= 1e-5 then
                m.z = m.target
                m.moving = false
                self:_apply(m, true)
            end
        else
            m.moving = false
        end
    end

    self._riserAge = self._riserAge + dt
    if anyMoving and self._riserAge >= (self.riserInterval or 0.25) then
        self._riserAge = 0
        local seen = {}
        for i = 1, #self.list do
            local m = self.list[i]
            if m.moving and not seen[m.storey] then
                seen[m.storey] = true
                if self.world.rebuildFloorRisers then
                    self.world:rebuildFloorRisers(m.storey)
                end
            end
        end
    end
end

-- Compact snapshot for WORLD-style deltas or a game channel.
function MoversMT:snapshot()
    local out = {}
    for i = 1, #self.list do
        local m = self.list[i]
        out[#out + 1] = {
            id = m.id, z = m.z, target = m.target,
            moving = m.moving and 1 or 0,
        }
    end
    return out
end

function MoversMT:applySnapshot(snap)
    if type(snap) ~= 'table' then return self end
    for i = 1, #snap do
        local s = snap[i]
        local m = self:get(s.id)
        if m then
            if s.z ~= nil then m.z = s.z end
            if s.target ~= nil then m.target = s.target end
            m.moving = s.moving == 1 or s.moving == true
            self:_apply(m, not m.moving)
        end
    end
    return self
end

function MoversMT:count() return #self.list end

return Movers
