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

-- Largest upward floor step a move may take in one axis resolution, in wall
-- units. Bigger than this and the move is blocked — you walk into a ledge
-- rather than teleporting onto it. Drops of any size are free: falling down
-- stairs is allowed, vaulting a full wall height is not.
Collide.MAX_STEP = 0.35

---------------------------------------------------------------------------
-- Movement
---------------------------------------------------------------------------

-- True if a circle centred at (x, y) would intersect any solid tile.
-- opts.storey (or fourth arg) selects the world layer (default 1).
function Collide.circleBlocked(world, x, y, radius, storey)
    radius = radius or DEFAULT_RADIUS
    if type(radius) == 'table' then
        storey = radius.storey
        radius = radius.radius or DEFAULT_RADIUS
    end
    storey = storey or 1

    local minTx, maxTx = floor(x - radius) + 1, floor(x + radius) + 1
    local minTy, maxTy = floor(y - radius) + 1, floor(y + radius) + 1

    for ty = minTy, maxTy do
        for tx = minTx, maxTx do
            if world:isSolid(tx, ty, storey) then
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

    -- Thin walls, if this world has any. Checked after the tiles because most
    -- worlds have none and the early return above is then the whole cost: a
    -- world with no segments pays one nil test for the feature.
    --
    -- Movement has to agree with the renderer here. A segment the ray pass draws
    -- but the collision pass ignores is a wall you can see and walk through,
    -- which reads as the renderer being broken rather than the collision.
    local segments = world.segments
    if segments and not segments:isEmpty() then
        if segments:blocked(x, y, radius) then return true end
    end

    return false
end

-- Absolute walk surface under feet (storey base + relative floor).
local function floorUnder(world, x, y, storey)
    storey = storey or 1
    if world and world.absoluteFloorAtPoint then
        return world:absoluteFloorAtPoint(x, y, storey)
    end
    if world and world.floorHeightAtPoint then
        local rel = world:floorHeightAtPoint(x, y, storey)
        local base = world.storeyBase and world:storeyBase(storey) or 0
        return base + rel
    end
    return 0
end

-- True when stepping from fromZ to toZ is allowed (drop always, rise within
-- MAX_STEP).
function Collide.canStep(fromZ, toZ, maxStep)
    maxStep = maxStep or Collide.MAX_STEP
    fromZ = fromZ or 0
    toZ = toZ or 0
    local rise = toZ - fromZ
    if rise <= 0 then return true end
    return rise <= maxStep + 1e-9
end

-- Snaps an entity's z to the floor under its feet. Call after a teleport or
-- spawn so the first frame is not floating at z=0 over a raised tile.
function Collide.ground(e, world)
    if not e or not world then return 0 end
    local storey = e.storey or 1
    local z = floorUnder(world, e.x, e.y, storey)
    e.z = z
    return z
end

-- Moves an entity by (dx, dy), sliding along walls instead of stopping dead.
-- Uses e.storey (default 1) for solidity and floor heights.
function Collide.move(e, dx, dy, world, radius)
    radius = radius or e.radius or DEFAULT_RADIUS
    local storey = e.storey or 1

    local startX, startY = e.x, e.y
    if e.z == nil then e.z = floorUnder(world, e.x, e.y, storey) end
    local blocked = false

    if dx ~= 0 then
        local tryX = e.x + dx
        if Collide.circleBlocked(world, tryX, e.y, radius, storey) then
            blocked = true
        else
            local nextZ = floorUnder(world, tryX, e.y, storey)
            if not Collide.canStep(e.z, nextZ) then
                blocked = true
            else
                e.x = tryX
                e.z = nextZ
            end
        end
    end

    if dy ~= 0 then
        local tryY = e.y + dy
        if Collide.circleBlocked(world, e.x, tryY, radius, storey) then
            blocked = true
        else
            local nextZ = floorUnder(world, e.x, tryY, storey)
            if not Collide.canStep(e.z, nextZ) then
                blocked = true
            else
                e.y = tryY
                e.z = nextZ
            end
        end
    end

    local movedX, movedY = e.x - startX, e.y - startY
    return sqrt(movedX * movedX + movedY * movedY), blocked
end

---------------------------------------------------------------------------
-- Entity overlap
---------------------------------------------------------------------------

function Collide.overlaps(a, b)
    -- Different in-world storeys do not collide (walk over each other).
    if (a.storey or 1) ~= (b.storey or 1) then return false end
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
-- optional predicate. opts.storey limits to one layer (default: any).
function Collide.query(entities, x, y, range, filter, opts)
    opts = opts or {}
    local storey = opts.storey
    local hits = {}
    local r2 = range * range

    for i = 1, #entities do
        local e = entities[i]
        if not e.dead
           and (storey == nil or (e.storey or 1) == storey)
           and (not filter or filter(e)) then
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
--
-- Returns: dist, tx, ty, side, nx, ny
--   side  0 = vertical face (stepped on X), 1 = horizontal (stepped on Y)
--   nx,ny unit normal pointing out of the wall toward the open cell the ray left
function Collide.rayTile(world, x, y, dirX, dirY, maxDist, storey)
    maxDist = maxDist or 64
    storey = storey or 1

    local tx, ty = floor(x) + 1, floor(y) + 1
    local stepX = dirX > 0 and 1 or -1
    local stepY = dirY > 0 and 1 or -1

    local invX = dirX ~= 0 and abs(1 / dirX) or huge
    local invY = dirY ~= 0 and abs(1 / dirY) or huge

    local nextX = dirX > 0 and (tx - x) or (x - (tx - 1))
    local nextY = dirY > 0 and (ty - y) or (y - (ty - 1))

    local tMaxX = dirX ~= 0 and nextX * invX or huge
    local tMaxY = dirY ~= 0 and nextY * invY or huge

    local wallDist, wallTx, wallTy, wallSide, wallNx, wallNy
    local travelled = 0
    while travelled <= maxDist do
        local side
        if tMaxX < tMaxY then
            travelled = tMaxX
            tMaxX = tMaxX + invX
            tx = tx + stepX
            side = 0
        else
            travelled = tMaxY
            tMaxY = tMaxY + invY
            ty = ty + stepY
            side = 1
        end

        if travelled > maxDist then break end

        if world:isSolid(tx, ty, storey) then
            if side == 0 then
                wallNx, wallNy = -stepX, 0
            else
                wallNx, wallNy = 0, -stepY
            end
            wallDist, wallTx, wallTy, wallSide = travelled, tx, ty, side
            break
        end
    end

    -- E39: a segment is a wall too. Gameplay (LOS, hitscan, AI sight) walked the
    -- tile grid only, so a bullet and an AI's gaze passed straight through a
    -- diagonal that stops the renderer AND movement. Test segments up to the
    -- nearer of the tile wall and maxDist, and let the closer hit win — now all
    -- four (render, movement, sight, shots) agree a segment is solid.
    local segments = world.segments
    if segments and not segments:isEmpty() then
        local limit = wallDist or maxDist
        local segT, _, seg = segments:nearest(x, y, dirX, dirY, limit)
        if segT and (not wallDist or segT < wallDist) then
            -- The segment's normal, turned to face the ray origin.
            local nlen = sqrt(seg.dx * seg.dx + seg.dy * seg.dy)
            local nx, ny = 0, 0
            if nlen > 1e-12 then nx, ny = seg.dy / nlen, -seg.dx / nlen end
            if nx * dirX + ny * dirY > 0 then nx, ny = -nx, -ny end
            local htx, hty = floor(x + dirX * segT) + 1, floor(y + dirY * segT) + 1
            return segT, htx, hty, nil, nx, ny
        end
    end

    return wallDist, wallTx, wallTy, wallSide, wallNx, wallNy
end

-- Nearest solid tile or entity along a ray. Entities are tested as circles and
-- only count when they sit in front of the wall, so shooting through a wall is
-- impossible without the caller doing anything.
--
-- Wall hits include hitx/hity (impact point) and nx/ny (outward face normal).
-- opts.storey selects the layer; entities on other storeys are ignored.
function Collide.hitscan(world, x, y, dirX, dirY, entities, opts)
    opts = opts or {}
    local maxDist = opts.maxDist or 64
    local ignore = opts.ignore
    local storey = opts.storey or 1

    local wallDist, wallTx, wallTy, wallSide, wallNx, wallNy =
        Collide.rayTile(world, x, y, dirX, dirY, maxDist, storey)
    local limit = wallDist or maxDist

    local best, bestDist = nil, limit

    if entities then
        for i = 1, #entities do
            local e = entities[i]
            local eStorey = e.storey or 1
            if not e.dead and e ~= ignore and eStorey == storey
               and (not opts.filter or opts.filter(e)) then
                local r = e.radius or DEFAULT_RADIUS
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
        return {
            kind = 'entity', entity = best, dist = bestDist,
            hitx = x + dirX * bestDist, hity = y + dirY * bestDist,
        }
    end

    if wallDist then
        return {
            kind = 'wall', dist = wallDist, tx = wallTx, ty = wallTy,
            side = wallSide, nx = wallNx, ny = wallNy,
            hitx = x + dirX * wallDist, hity = y + dirY * wallDist,
        }
    end

    return nil
end

-- Whether (ax, ay) can see (bx, by) with no solid tile between them.
-- Optional storey (default 1) selects the layer; LOS never peeks through floors.
function Collide.lineOfSight(world, ax, ay, bx, by, storey)
    local dx, dy = bx - ax, by - ay
    local dist = sqrt(dx * dx + dy * dy)
    if dist < 1e-9 then return true end

    local hit = Collide.rayTile(world, ax, ay, dx / dist, dy / dist, dist, storey or 1)
    return hit == nil
end

Collide.DEFAULT_RADIUS = DEFAULT_RADIUS

return Collide
