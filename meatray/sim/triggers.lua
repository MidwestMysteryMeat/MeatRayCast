--[[
    meatray.sim.triggers — axis-aligned volumes that notice who walks through.

        local box = Triggers.new()
        box:add{
            name = 'exit',
            x1 = 10, y1 = 4, x2 = 12, y2 = 6,   -- world coords, inclusive-ish
            onEnter = function(e, vol) ... end,
            onExit  = function(e, vol) ... end,
            onStay  = function(e, vol, dt) ... end,  -- optional, each step
        }
        -- once per tick, after movement:
        box:update(entities, dt)

    Games need doors that open when you approach, kill zones, objective rooms,
    and level transitions. Those are the same mechanism: a region, a set of
    occupants, and callbacks on the edges. Keeping it in sim/ means a dedicated
    server runs the same logic as a client and the suite can assert it without
    a window.

    Occupancy is tracked by entity id. An entity that dies while inside fires
    onExit (with reason 'dead') so a door that was held open by a corpse can
    close. Filters are optional predicates so a trigger can ignore projectiles.

    HEADLESS: pure Lua, no love.
]]

local Triggers = {}

local TriggersMT = {}
TriggersMT.__index = TriggersMT

local VolumeMT = {}
VolumeMT.__index = VolumeMT

function Triggers.new()
    return setmetatable({
        list = {},
        -- id -> set of volume indices currently occupied; used only for cleanup
        -- of dead entities that never leave a volume by walking out.
        _byEntity = {},
    }, TriggersMT)
end

-- World-space AABB. x1,y1 is the minimum corner, x2,y2 the maximum. Either
-- order is accepted and normalised. Tile-style "covers tiles 3..5" is written
-- as x1=2, y1=2, x2=5, y2=5 (world coords of tile corners).
function TriggersMT:add(opts)
    opts = opts or {}
    local x1 = tonumber(opts.x1) or tonumber(opts.x) or 0
    local y1 = tonumber(opts.y1) or tonumber(opts.y) or 0
    local x2 = tonumber(opts.x2) or (x1 + (tonumber(opts.w) or 1))
    local y2 = tonumber(opts.y2) or (y1 + (tonumber(opts.h) or 1))
    if x1 > x2 then x1, x2 = x2, x1 end
    if y1 > y2 then y1, y2 = y2, y1 end

    local vol = setmetatable({
        name = opts.name or ('trigger_' .. (#self.list + 1)),
        x1 = x1, y1 = y1, x2 = x2, y2 = y2,
        enabled = opts.enabled ~= false,
        filter = opts.filter,       -- function(e) -> bool
        onEnter = opts.onEnter,
        onExit = opts.onExit,
        onStay = opts.onStay,
        once = opts.once and true or false,  -- disable after first enter
        occupants = {},             -- [entityId] = entity
        _index = #self.list + 1,
    }, VolumeMT)

    self.list[vol._index] = vol
    return vol
end

-- Tile-rect helper: covers tiles [tx1..tx2] x [ty1..ty2] inclusive (1-based).
function TriggersMT:addTiles(opts)
    opts = opts or {}
    local tx1 = opts.tx1 or opts.tx or 1
    local ty1 = opts.ty1 or opts.ty or 1
    local tx2 = opts.tx2 or tx1
    local ty2 = opts.ty2 or ty1
    if tx1 > tx2 then tx1, tx2 = tx2, tx1 end
    if ty1 > ty2 then ty1, ty2 = ty2, ty1 end
    opts.x1, opts.y1 = tx1 - 1, ty1 - 1
    opts.x2, opts.y2 = tx2, ty2
    return self:add(opts)
end

function TriggersMT:get(name)
    for i = 1, #self.list do
        if self.list[i].name == name then return self.list[i] end
    end
    return nil
end

function TriggersMT:clear()
    self.list = {}
    self._byEntity = {}
    return self
end

function VolumeMT:contains(x, y)
    return x >= self.x1 and x <= self.x2 and y >= self.y1 and y <= self.y2
end

function VolumeMT:count()
    local n = 0
    for _ in pairs(self.occupants) do n = n + 1 end
    return n
end

local function accepts(vol, e)
    if not e or e.dead then return false end
    if vol.filter and not vol.filter(e) then return false end
    return true
end

local function fire(fn, ...)
    if not fn then return end
    -- Isolated so one bad game callback cannot skip the rest of the volume list.
    local ok, err = pcall(fn, ...)
    if not ok then
        -- No logger injected: the suite and the host can wrap onEnter themselves.
        -- Swallowing without a trail would hide game bugs, so rethrow.
        error(err, 0)
    end
end

-- Advances occupancy. Call once per simulation step after movement.
-- Returns counts: entered, exited, stayed (callback firings this step).
function TriggersMT:update(entities, dt)
    dt = dt or 0
    local entered, exited, stayed = 0, 0, 0
    local live = {}

    for i = 1, #(entities or {}) do
        local e = entities[i]
        if e and not e.dead and e.id then
            live[e.id] = e
        end
    end

    for vi = 1, #self.list do
        local vol = self.list[vi]
        if vol.enabled then
            local seen = {}

            for id, e in pairs(live) do
                if accepts(vol, e) and vol:contains(e.x, e.y) then
                    seen[id] = true
                    if not vol.occupants[id] then
                        vol.occupants[id] = e
                        entered = entered + 1
                        fire(vol.onEnter, e, vol)
                        if vol.once then
                            vol.enabled = false
                        end
                    else
                        vol.occupants[id] = e
                        if vol.onStay then
                            stayed = stayed + 1
                            fire(vol.onStay, e, vol, dt)
                        end
                    end
                end
            end

            -- Left by walking out or by dying / despawning.
            local gone = {}
            for id, e in pairs(vol.occupants) do
                if not seen[id] then
                    gone[#gone + 1] = { id = id, e = e }
                end
            end
            for g = 1, #gone do
                local id, e = gone[g].id, gone[g].e
                vol.occupants[id] = nil
                exited = exited + 1
                local reason = (not e or e.dead or not live[id]) and 'dead' or 'leave'
                fire(vol.onExit, e, vol, reason)
            end
        end
    end

    return entered, exited, stayed
end

return Triggers
