--[[
    meatray.sim.collide — movement, overlap and hitscan against the tile grid.

    Movers are circles. Walls are whole tiles. That pairing is what a grid
    raycaster wants: it makes wall sliding fall out of resolving each axis
    separately, and it keeps every query cheap enough to run per tick for every
    entity.

    HEADLESS: this module must not touch love.graphics or any love drawing API.
]]

local Collide = {}

local floor, abs, min, max = math.floor, math.abs, math.min, math.max
local sqrt, huge = math.sqrt, math.huge

local DEFAULT_RADIUS = 0.25

---------------------------------------------------------------------------
-- Movement
---------------------------------------------------------------------------

-- True if a circle centred at (x, y) would intersect any solid tile.
function Collide.circleBlocked(world, x, y, radius)
    radius = radius or DEFAULT_RADIUS

    local minTx, maxTx = floor(x - radius) + 1, floor(x + radius) + 1
    local minTy, maxTy = floor(y - radius) + 1, floor(y + radius) + 1

    for ty = minTy, maxTy do
        for tx = minTx, maxTx do
            if world:isSolid(tx, ty) then
                -- Nearest point on the tile square to the circle centre.
                local nx = min(max(x, tx - 1), tx)
                local ny = min(max(y, ty - 1), ty)
                local dx, dy = x - nx, y - ny
                if dx * dx + dy * dy < radius * radius then
                    return true
                end
            end
        end
    end

    return false
end

-- Moves an entity by (dx, dy), sliding along walls instead of stopping dead.
-- Each axis is resolved independently, so a mover pressed diagonally into a
-- wall keeps the component that is still free. Returns the distance actually
-- travelled and whether anything was hit.
function Collide.move(e, dx, dy, world, radius)
    radius = radius or e.radius or DEFAULT_RADIUS

    local startX, startY = e.x, e.y
    local blocked = false

    if dx ~= 0 then
        local tryX = e.x + dx
        if Collide.circleBlocked(world, tryX, e.y, radius) then
            blocked = true
        else
            e.x = tryX
        end
    end

    if dy ~= 0 then
        local tryY = e.y + dy
        if Collide.circleBlocked(world, e.x, tryY, radius) then
            blocked = true
        else
            e.y = tryY
        end
    end

    local movedX, movedY = e.x - startX, e.y - startY
    return sqrt(movedX * movedX + movedY * movedY), blocked
end

---------------------------------------------------------------------------
-- Entity overlap
---------------------------------------------------------------------------

function Collide.overlaps(a, b)
    local ra = a.radius or DEFAULT_RADIUS
    local rb = b.radius or DEFAULT_RADIUS
    local dx, dy = a.x - b.x, a.y - b.y
    local reach = ra + rb
    return dx * dx + dy * dy < reach * reach
end

function Collide.distance(a, b)
    local dx, dy = a.x - b.x, a.y - b.y
    return sqrt(dx * dx + dy * dy)
end

-- Every live entity within `range` of (x, y), nearest first. `filter` is an
-- optional predicate.
function Collide.query(entities, x, y, range, filter)
    local hits = {}
    local r2 = range * range

    for i = 1, #entities do
        local e = entities[i]
        if not e.dead and (not filter or filter(e)) then
            local dx, dy = e.x - x, e.y - y
            local d2 = dx * dx + dy * dy
            if d2 <= r2 then
                hits[#hits + 1] = { entity = e, dist2 = d2 }
            end
        end
    end

    table.sort(hits, function(p, q) return p.dist2 < q.dist2 end)

    local out = {}
    for i = 1, #hits do out[i] = hits[i].entity end
    return out
end

---------------------------------------------------------------------------
-- Hitscan
---------------------------------------------------------------------------

-- Walks the tile grid from (x, y) along (dirX, dirY) and returns the first
-- solid tile hit. Grid traversal, not the renderer's wall loop: this answers a
-- gameplay question and must stay usable with no love present.
function Collide.rayTile(world, x, y, dirX, dirY, maxDist)
    maxDist = maxDist or 64

    local tx, ty = floor(x) + 1, floor(y) + 1
    local stepX = dirX > 0 and 1 or -1
    local stepY = dirY > 0 and 1 or -1

    local invX = dirX ~= 0 and abs(1 / dirX) or huge
    local invY = dirY ~= 0 and abs(1 / dirY) or huge

    local nextX = dirX > 0 and (tx - x) or (x - (tx - 1))
    local nextY = dirY > 0 and (ty - y) or (y - (ty - 1))

    local tMaxX = dirX ~= 0 and nextX * invX or huge
    local tMaxY = dirY ~= 0 and nextY * invY or huge

    local travelled = 0
    while travelled <= maxDist do
        if tMaxX < tMaxY then
            travelled = tMaxX
            tMaxX = tMaxX + invX
            tx = tx + stepX
        else
            travelled = tMaxY
            tMaxY = tMaxY + invY
            ty = ty + stepY
        end

        if travelled > maxDist then break end

        if world:isSolid(tx, ty) then
            return travelled, tx, ty
        end
    end

    return nil
end

-- Nearest solid tile or entity along a ray. Entities are tested as circles and
-- only count when they sit in front of the wall, so shooting through a wall is
-- impossible without the caller doing anything.
function Collide.hitscan(world, x, y, dirX, dirY, entities, opts)
    opts = opts or {}
    local maxDist = opts.maxDist or 64
    local ignore = opts.ignore

    local wallDist, wallTx, wallTy = Collide.rayTile(world, x, y, dirX, dirY, maxDist)
    local limit = wallDist or maxDist

    local best, bestDist = nil, limit

    if entities then
        for i = 1, #entities do
            local e = entities[i]
            if not e.dead and e ~= ignore and (not opts.filter or opts.filter(e)) then
                local r = e.radius or DEFAULT_RADIUS
                -- Project the entity centre onto the ray, then check how far it
                -- sits off that line.
                local ox, oy = e.x - x, e.y - y
                local along = ox * dirX + oy * dirY
                if along > 0 and along < bestDist then
                    local perpX = ox - dirX * along
                    local perpY = oy - dirY * along
                    if perpX * perpX + perpY * perpY <= r * r then
                        best, bestDist = e, along
                    end
                end
            end
        end
    end

    if best then
        return { kind = 'entity', entity = best, dist = bestDist }
    end

    if wallDist then
        return { kind = 'wall', dist = wallDist, tx = wallTx, ty = wallTy }
    end

    return nil
end

-- Whether (ax, ay) can see (bx, by) with no solid tile between them.
function Collide.lineOfSight(world, ax, ay, bx, by)
    local dx, dy = bx - ax, by - ay
    local dist = sqrt(dx * dx + dy * dy)
    if dist < 1e-9 then return true end

    local hit = Collide.rayTile(world, ax, ay, dx / dist, dy / dist, dist)
    return hit == nil
end

Collide.DEFAULT_RADIUS = DEFAULT_RADIUS

return Collide
