--[[
    meatray.render.minimap — top-down plan overlay.

    Pure layout maths are headless-testable; drawing goes through Platform.gfx
    when a host is present. The minimap is presentation only: it never writes
    world state.

    Usage:
        local mm = Minimap.new{ world = world, size = 128 }
        mm:draw(playerX, playerY, playerAngle, { entities = ents, storey = 1 })
]]

local Platform = require('meatray.platform')
local World = require('meatray.sim.world')

local Minimap = {}

local MinimapMT = {}
MinimapMT.__index = MinimapMT

local floor, cos, sin, abs = math.floor, math.cos, math.sin, math.abs
local pi = math.pi

function Minimap.new(opts)
    opts = opts or {}
    return setmetatable({
        world = opts.world,
        size = opts.size or 120,           -- square pixels
        margin = opts.margin or 8,         -- from screen corner
        corner = opts.corner or 'br',      -- tl tr bl br
        scale = opts.scale,                -- tiles→px; nil = fit world
        showEntities = opts.showEntities ~= false,
        showPlayer = opts.showPlayer ~= false,
        fog = opts.fog,                    -- optional: visited[tx..','..ty]=true
        colors = opts.colors or {
            wall = { 0.45, 0.42, 0.40, 0.92 },
            floor = { 0.12, 0.12, 0.14, 0.75 },
            door = { 0.70, 0.45, 0.20, 0.95 },
            player = { 0.95, 0.85, 0.30, 1 },
            entity = { 0.85, 0.25, 0.25, 0.95 },
            border = { 0.05, 0.05, 0.06, 0.9 },
            view = { 1, 1, 0.6, 0.35 },
        },
    }, MinimapMT)
end

function MinimapMT:setWorld(world)
    self.world = world
    return self
end

-- Pixel origin of the minimap square on screen.
function MinimapMT:origin(screenW, screenH)
    local s, m = self.size, self.margin
    local c = self.corner or 'br'
    local x, y = m, m
    if c == 'tr' or c == 'br' then x = (screenW or 800) - s - m end
    if c == 'bl' or c == 'br' then y = (screenH or 600) - s - m end
    return x, y
end

-- World tile → local minimap pixel (top-left of cell).
function MinimapMT:tileToLocal(tx, ty, tileScale)
    return (tx - 1) * tileScale, (ty - 1) * tileScale
end

function MinimapMT:computeScale()
    local world = self.world
    if not world then return 1 end
    if self.scale then return self.scale end
    local tw = world.width or 1
    local th = world.height or 1
    local s = self.size / math.max(tw, th)
    if s < 1 then s = 1 end
    return s
end

-- Headless: list of draw commands for tests { kind, ... }.
function MinimapMT:build(px, py, angle, opts)
    opts = opts or {}
    local world = opts.world or self.world
    if not world then return { cmds = {}, scale = 1, ox = 0, oy = 0 } end

    local storey = opts.storey or 1
    local scale = self:computeScale()
    local cmds = {}
    local fog = opts.fog or self.fog

    for ty = 1, world.height do
        for tx = 1, world.width do
            if not fog or fog[tx .. ',' .. ty] then
                local solid = world:isSolid(tx, ty, storey)
                local door = world.doorAt and world:doorAt(tx, ty, storey)
                local kind = 'floor'
                if door then kind = 'door'
                elseif solid then kind = 'wall' end
                local lx, ly = self:tileToLocal(tx, ty, scale)
                cmds[#cmds + 1] = {
                    kind = kind, x = lx, y = ly, w = scale, h = scale,
                    tx = tx, ty = ty,
                }
            end
        end
    end

    if self.showEntities and opts.entities then
        for i = 1, #opts.entities do
            local e = opts.entities[i]
            -- Under fog, an entity in unexplored territory is not drawn: a
            -- red dot in a dark part of the plan is a wallhack with extra
            -- steps, and exactly the leak remembering-what-you-saw prevents.
            local seen = not fog
                or (e and fog[(floor(e.x or 0) + 1) .. ',' .. (floor(e.y or 0) + 1)])
            if e and seen and not e.dead and (e.storey or 1) == storey then
                cmds[#cmds + 1] = {
                    kind = 'entity',
                    x = e.x * scale - scale * 0.25,
                    y = e.y * scale - scale * 0.25,
                    w = scale * 0.5, h = scale * 0.5,
                    player = (e.has and e:has('player')) or false,
                }
            end
        end
    end

    if self.showPlayer and px and py then
        local cx, cy = px * scale, py * scale
        cmds[#cmds + 1] = {
            kind = 'player', x = cx, y = cy, angle = angle or 0, r = scale * 0.4,
        }
        -- View wedge
        local a = angle or 0
        local spread = 0.45
        local len = scale * 4
        cmds[#cmds + 1] = {
            kind = 'view',
            x = cx, y = cy,
            x1 = cx + cos(a - spread) * len,
            y1 = cy + sin(a - spread) * len,
            x2 = cx + cos(a + spread) * len,
            y2 = cy + sin(a + spread) * len,
        }
    end

    return { cmds = cmds, scale = scale, size = self.size }
end

function MinimapMT:draw(px, py, angle, opts)
    opts = opts or {}
    if not Platform.available() then return self:build(px, py, angle, opts) end

    local gfx = Platform.gfx
    local screenW = opts.screenW or (gfx.getWidth and gfx.getWidth()) or 800
    local screenH = opts.screenH or (gfx.getHeight and gfx.getHeight()) or 600
    local ox, oy = self:origin(screenW, screenH)
    local built = self:build(px, py, angle, opts)
    local c = self.colors
    local s = self.size

    gfx.setColor(c.border[1], c.border[2], c.border[3], c.border[4] or 1)
    gfx.rectangle('fill', ox - 2, oy - 2, s + 4, s + 4)

    -- Clip-ish: just draw inside; no scissor required for solid bg.
    gfx.setColor(0.08, 0.08, 0.1, 0.85)
    gfx.rectangle('fill', ox, oy, s, s)

    for i = 1, #built.cmds do
        local cmd = built.cmds[i]
        if cmd.kind == 'wall' then
            gfx.setColor(c.wall[1], c.wall[2], c.wall[3], c.wall[4] or 1)
            gfx.rectangle('fill', ox + cmd.x, oy + cmd.y, cmd.w, cmd.h)
        elseif cmd.kind == 'floor' then
            gfx.setColor(c.floor[1], c.floor[2], c.floor[3], c.floor[4] or 1)
            gfx.rectangle('fill', ox + cmd.x, oy + cmd.y, cmd.w, cmd.h)
        elseif cmd.kind == 'door' then
            gfx.setColor(c.door[1], c.door[2], c.door[3], c.door[4] or 1)
            gfx.rectangle('fill', ox + cmd.x, oy + cmd.y, cmd.w, cmd.h)
        elseif cmd.kind == 'entity' then
            local col = cmd.player and c.player or c.entity
            gfx.setColor(col[1], col[2], col[3], col[4] or 1)
            gfx.rectangle('fill', ox + cmd.x, oy + cmd.y, cmd.w, cmd.h)
        elseif cmd.kind == 'view' then
            gfx.setColor(c.view[1], c.view[2], c.view[3], c.view[4] or 0.35)
            if gfx.polygon then
                gfx.polygon('fill',
                    ox + cmd.x, oy + cmd.y,
                    ox + cmd.x1, oy + cmd.y1,
                    ox + cmd.x2, oy + cmd.y2)
            else
                gfx.line(ox + cmd.x, oy + cmd.y, ox + cmd.x1, oy + cmd.y1)
                gfx.line(ox + cmd.x, oy + cmd.y, ox + cmd.x2, oy + cmd.y2)
            end
        elseif cmd.kind == 'player' then
            gfx.setColor(c.player[1], c.player[2], c.player[3], c.player[4] or 1)
            if gfx.circle then
                gfx.circle('fill', ox + cmd.x, oy + cmd.y, cmd.r)
            else
                local r = cmd.r
                gfx.rectangle('fill', ox + cmd.x - r, oy + cmd.y - r, r * 2, r * 2)
            end
            local a = cmd.angle or 0
            local len = cmd.r * 2.2
            gfx.line(ox + cmd.x, oy + cmd.y,
                     ox + cmd.x + cos(a) * len, oy + cmd.y + sin(a) * len)
        end
    end

    gfx.setColor(1, 1, 1, 1)
    return built
end

return Minimap
