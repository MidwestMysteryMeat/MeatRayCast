--[[
    meatray.sim.decals — short-lived marks in the world (scorch, blood, holes).

        local marks = Decals.new()
        marks:add{ x = 4.2, y = 5.1, kind = 'scorch', life = 8, scale = 0.35 }
        marks:update(dt)
        -- draw: for _, d in ipairs(marks:list()) do ... end

    Headless bookkeeping only. Rendering is the game's choice: spawn a
    localOnly billboard, draw a quad, or ignore them on a dedicated server.

    HEADLESS: pure Lua.
]]

local Decals = {}

local SetMT = {}
SetMT.__index = SetMT

function Decals.new(opts)
    opts = opts or {}
    return setmetatable({
        list = {},
        max = opts.max or 256,
        defaultLife = opts.defaultLife or 12,
    }, SetMT)
end

function SetMT:add(opts)
    opts = opts or {}
    local d = {
        x = tonumber(opts.x) or 0,
        y = tonumber(opts.y) or 0,
        z = tonumber(opts.z) or 0,
        angle = tonumber(opts.angle) or 0,
        kind = opts.kind or 'mark',
        scale = tonumber(opts.scale) or 0.4,
        life = tonumber(opts.life) or self.defaultLife,
        maxLife = tonumber(opts.life) or self.defaultLife,
        -- Optional wall surface: unit normal pointing out of the wall.
        nx = opts.nx, ny = opts.ny,
        wall = opts.wall and true or false,
    }
    self.list[#self.list + 1] = d

    -- Cap: drop oldest first so a firefight cannot grow without bound.
    while #self.list > self.max do
        table.remove(self.list, 1)
    end
    return d
end

-- Hitscan helper: place a mark at the hit point, slightly off the surface.
function SetMT:addHit(x, y, nx, ny, opts)
    opts = opts or {}
    local back = opts.back or 0.04
    if nx and ny then
        local len = math.sqrt(nx * nx + ny * ny)
        if len > 1e-9 then
            nx, ny = nx / len, ny / len
            x = x - nx * back
            y = y - ny * back
        end
    end
    opts.x, opts.y = x, y
    opts.nx, opts.ny = nx, ny
    opts.wall = true
    return self:add(opts)
end

function SetMT:update(dt)
    dt = dt or 0
    local i = 1
    while i <= #self.list do
        local d = self.list[i]
        d.life = d.life - dt
        if d.life <= 0 then
            table.remove(self.list, i)
        else
            i = i + 1
        end
    end
end

function SetMT:clear()
    self.list = {}
    return self
end

function SetMT:count()
    return #self.list
end

-- Stable array for draw loops.
function SetMT:all()
    return self.list
end

-- Alpha 0..1 for fading out.
function Decals.alpha(d)
    if not d or not d.maxLife or d.maxLife <= 0 then return 1 end
    local a = d.life / d.maxLife
    if a < 0 then return 0 end
    if a > 1 then return 1 end
    return a
end

return Decals
