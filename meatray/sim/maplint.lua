--[[
    meatray.sim.maplint — is this map a level, or a trap? (B12)

    A map can parse perfectly and still be unplayable: a spawn inside a wall,
    a room no corridor reaches, an exit behind an unbroken wall, a push-wall
    aimed into another wall so it never moves, a lock on a tile with no door.
    Every one of those boots clean and fails a player later — this project
    shipped exactly one of them (the first draft of secrets.map aimed its
    push-wall into a wall) and only a hand-written test caught it.

        local Lint = require('meatray.sim.maplint')
        local report = Lint.check(map, { archetypes = Entity.archetypeNames() })

        report.ok          -- no errors (warnings allowed)
        report.errors      -- { { code=, text=, tx=, ty= }, ... }
        report.warnings    -- same shape

    ERRORS are things a player will hit as a wall: no spawn, spawn in solid,
    unreachable exit, a lock with no door, a push-wall that cannot take its
    first step, an entity inside a wall or off the map. WARNINGS are things a
    designer probably wants to know: unreachable open floor, a locked door
    with no key on the map, stairs with no link, an unknown archetype (only
    when a registry was handed in — a map full of modded kinds lints clean
    without one).

    Reachability is a flood from the spawn across storey 1, where doors count
    as passable (a shut door opens; that is what doors are for) — including
    locked ones, which instead produce the no-key warning, because 'locked'
    is a puzzle and 'unreachable' is a defect, and a linter that confuses the
    two teaches people to ignore it.

    HEADLESS: pure Lua. Lints the PARSED MAP (via its own toWorld build), so
    the CLI and the suite check the same thing a game will actually load.
]]

local Map = require('meatray.sim.map')

local Maplint = {}

local floor = math.floor

local function add(list, code, text, tx, ty)
    list[#list + 1] = { code = code, text = text, tx = tx, ty = ty }
end

---------------------------------------------------------------------------
-- The flood
---------------------------------------------------------------------------

local function reachableFrom(world, tx, ty)
    local seen = {}
    local stack = { { tx, ty } }
    local key = function(x, y) return x .. ',' .. y end
    seen[key(tx, ty)] = true
    local count = 0

    while #stack > 0 do
        local top = table.remove(stack)
        local x, y = top[1], top[2]
        count = count + 1
        for _, d in ipairs{ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } } do
            local nx, ny = x + d[1], y + d[2]
            if nx >= 1 and ny >= 1 and nx <= world.width and ny <= world.height
               and not seen[key(nx, ny)] then
                local passable = not world:isSolid(nx, ny)
                                 or world:doorAt(nx, ny) ~= nil
                if passable then
                    seen[key(nx, ny)] = true
                    stack[#stack + 1] = { nx, ny }
                end
            end
        end
    end

    return seen, count
end

---------------------------------------------------------------------------
-- The check
---------------------------------------------------------------------------

-- opts:
--   archetypes   array of known kind names; absent skips the unknown check
function Maplint.check(map, opts)
    opts = opts or {}
    local errors, warnings = {}, {}
    local report = { errors = errors, warnings = warnings }

    if type(map) ~= 'table' or type(map.tiles) ~= 'table' then
        add(errors, 'not-a-map', 'this is not a parsed map table')
        report.ok = false
        return report
    end

    local world = Map.toWorld(map)

    -- Spawn.
    local spawn = map.spawn
    local stx, sty
    if not spawn then
        add(errors, 'no-spawn', 'the map declares no spawn')
    else
        stx, sty = floor(spawn.x) + 1, floor(spawn.y) + 1
        if stx < 1 or sty < 1 or stx > world.width or sty > world.height then
            add(errors, 'spawn-outside',
                ('spawn (%.1f, %.1f) is off the map'):format(spawn.x, spawn.y))
            stx = nil
        elseif world:isSolid(stx, sty) and not world:doorAt(stx, sty) then
            add(errors, 'spawn-in-solid',
                ('spawn stands inside a solid tile at %d,%d'):format(stx, sty),
                stx, sty)
            stx = nil
        end
    end

    -- Reachability (storey 1, from the spawn).
    local seen
    if stx then
        local open = 0
        for ty = 1, world.height do
            for tx = 1, world.width do
                if not world:isSolid(tx, ty) then open = open + 1 end
            end
        end

        local reachedCount
        seen, reachedCount = reachableFrom(world, stx, sty)

        local unreachable, example = 0, nil
        for ty = 1, world.height do
            for tx = 1, world.width do
                if not world:isSolid(tx, ty) and not seen[tx .. ',' .. ty] then
                    unreachable = unreachable + 1
                    example = example or { tx, ty }
                end
            end
        end
        if unreachable > 0 then
            add(warnings, 'unreachable-floor',
                ('%d open tile(s) cannot be walked to (first at %d,%d)')
                    :format(unreachable, example[1], example[2]),
                example[1], example[2])
        end
        report.openTiles = open
        report.reached = reachedCount
    end

    -- The exit must be reachable: an exit is a promise.
    if map.exit and seen then
        local ex, ey
        if map.exit.tiles then
            ex, ey = map.exit.tx1, map.exit.ty1
        else
            ex, ey = floor(map.exit.x1) + 1, floor(map.exit.y1) + 1
        end
        if ex and not seen[ex .. ',' .. ey] then
            add(errors, 'exit-unreachable',
                ('the exit at %d,%d cannot be reached from the spawn')
                    :format(ex, ey), ex, ey)
        end
    end

    -- Entities: on the map, and not inside a wall.
    local known
    if opts.archetypes then
        known = {}
        for _, name in ipairs(opts.archetypes) do known[name] = true end
    end
    for _, e in ipairs(map.entities or {}) do
        local tx, ty = floor(e.x) + 1, floor(e.y) + 1
        if tx < 1 or ty < 1 or tx > world.width or ty > world.height then
            add(errors, 'entity-outside',
                ('%s at (%.1f, %.1f) is off the map'):format(e.kind, e.x, e.y))
        elseif world:isSolid(tx, ty) and not world:doorAt(tx, ty) then
            add(errors, 'entity-in-solid',
                ('%s stands inside a solid tile at %d,%d'):format(e.kind, tx, ty),
                tx, ty)
        end
        if known and not known[e.kind] then
            add(warnings, 'unknown-archetype',
                ('no registered archetype named %q'):format(tostring(e.kind)))
        end
    end

    -- Locks: a lock is a property OF a door.
    local keysOnMap = {}
    for _, lk in ipairs(map.locks or {}) do
        if not world:doorAt(lk.x, lk.y, lk.storey or 1) then
            add(errors, 'lock-no-door',
                ('lock %q at %d,%d has no door under it'):format(lk.key, lk.x, lk.y),
                lk.x, lk.y)
        end
        keysOnMap[lk.key] = false      -- wanted; not yet seen as obtainable
    end
    -- A key is 'on the map' when some entity kind carries its name. Loose on
    -- purpose: key delivery is a game decision (a drop, a graph, a vendor),
    -- so this can only ever be a warning.
    for _, e in ipairs(map.entities or {}) do
        if keysOnMap[e.kind] ~= nil then keysOnMap[e.kind] = true end
    end
    for keyId, found in pairs(keysOnMap) do
        if not found then
            add(warnings, 'key-not-on-map',
                ('a door wants %q and nothing on the map is one'):format(keyId))
        end
    end

    -- Push-walls: must sit on a solid tile and have somewhere to go.
    for _, pw in ipairs(map.pushWalls or {}) do
        local storey = pw.storey or 1
        if not world:isSolid(pw.x, pw.y, storey) then
            add(errors, 'pushwall-not-solid',
                ('push-wall at %d,%d is not on a solid tile'):format(pw.x, pw.y),
                pw.x, pw.y)
        else
            local nx, ny = pw.x + pw.dx, pw.y + pw.dy
            if world:isSolid(nx, ny, storey) then
                add(errors, 'pushwall-blocked',
                    ('push-wall at %d,%d cannot take its first step (into %d,%d)')
                        :format(pw.x, pw.y, nx, ny), pw.x, pw.y)
            end
        end
    end

    -- Boxes that miss the map entirely are typos, not designs.
    local function boxOnMap(b)
        return b.x2 >= 0 and b.y2 >= 0
           and b.x1 <= world.width and b.y1 <= world.height
    end
    for _, s in ipairs(map.secrets or {}) do
        if not boxOnMap(s) then
            add(warnings, 'secret-off-map',
                ('secret %q lies entirely off the map'):format(tostring(s.name or '?')))
        end
    end
    for _, hz in ipairs(map.hazards or {}) do
        if not boxOnMap(hz) then
            add(warnings, 'hazard-off-map',
                ('hazard %q lies entirely off the map'):format(hz.kind))
        end
    end

    -- Stairs and links: each is a promise about the other.
    local World = require('meatray.sim.world')
    local stairsUp, stairsDown = false, false
    for ty = 1, world.height do
        for tx = 1, world.width do
            local tile = world:tileAt(tx, ty)
            if tile == World.STAIRS_UP then stairsUp = true end
            if tile == World.STAIRS_DOWN then stairsDown = true end
        end
    end
    local links = map.links or {}
    if stairsUp and not links.up and (world.storeyCount and world:storeyCount() or 1) < 2 then
        add(warnings, 'stairs-no-link', 'stairs up, but no up link and no upper storey')
    end
    if stairsDown and not links.down then
        add(warnings, 'stairs-no-link', 'stairs down, but no down link')
    end
    if links.up and not stairsUp then
        add(warnings, 'link-no-stairs', 'an up link, but no stairs up to take it')
    end
    if links.down and not stairsDown then
        add(warnings, 'link-no-stairs', 'a down link, but no stairs down to take it')
    end

    report.ok = #errors == 0
    return report
end

-- Lints file text (parse + check), for the CLI and anything else holding
-- bytes rather than a table. Parse failures are themselves the report.
function Maplint.checkText(text, opts)
    local map, errs = Map.parse(text)
    if not map then
        local report = { errors = {}, warnings = {}, ok = false }
        for _, e in ipairs(errs or {}) do
            add(report.errors, 'parse', tostring(e))
        end
        return report
    end
    return Maplint.check(map, opts)
end

return Maplint
