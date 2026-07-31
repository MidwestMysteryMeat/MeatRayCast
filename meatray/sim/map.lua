--[[
    meatray.sim.map — the hand-authored map format.

    A map is readable text: a small key/value header, a `---` separator, then the
    level drawn as a grid of characters. That choice buys three things a binary or
    JSON format does not. You can hand-edit a level in any text editor without the
    tool. A git diff shows the level changing shape, so level design reviews like
    code. And parsing it needs no dependency, which keeps the engine's promise
    that it pulls in nothing.

        name   Test Arena
        theme  dungeon
        spawn  4.5 3.5 0
        entity i imp
        ---
        ############
        #..........#
        #..####....#
        #..#  D....#
        #..####..i.#
        #........@.#
        ############

    Grid characters:
        #        wall using texture 1
        1..9     wall using that texture
        . space  open floor
        D        door, shut at start
        d        door, open at start
        ^ v      stairs up / down
        @        player spawn (equivalent to a spawn header)
        a-z      entity marker, resolved through an `entity <char> <archetype>`
                 header line

    Header lines also include:
        height <tx> <ty> <0..1>          short wall on the floor
        slab   <tx> <ty> <base> <height>  wall slab at base z (stacked/floating)

    Procedural generation is the other half of this: meatray.sim.worldgen builds a
    World directly. Both paths end at the same World object, so nothing downstream
    knows or cares which was used.

    HEADLESS: this module must not touch love.graphics or any love drawing API.
]]

local World = require('meatray.sim.world')

local Map = {}

local floor = math.floor

Map.WALL       = '#'
Map.FLOOR      = '.'
Map.DOOR_SHUT  = 'D'
Map.DOOR_OPEN  = 'd'
Map.SPAWN      = '@'
Map.STAIRS_UP  = '^'
Map.STAIRS_DOWN = 'v'

---------------------------------------------------------------------------
-- Blank maps
---------------------------------------------------------------------------

-- A sealed room of open floor, which is the only sensible thing to hand someone
-- who just clicked "new map": an empty grid with no border would let them walk
-- off the edge on their first playtest.
function Map.blank(width, height, opts)
    opts = opts or {}
    width = width or 24
    height = height or 24

    local tiles = {}
    for y = 1, height do
        tiles[y] = {}
        for x = 1, width do
            local border = (x == 1 or y == 1 or x == width or y == height)
            tiles[y][x] = border and 1 or 0
        end
    end

    return {
        name = opts.name or 'untitled',
        theme = opts.theme or 'dungeon',
        width = width,
        height = height,
        tiles = tiles,
        doors = {},                 -- { {x=,y=,open=bool}, ... }
        entities = {},              -- { {kind=,x=,y=,angle=}, ... }
        legend = opts.legend or {}, -- char -> archetype name
        spawn = { x = width / 2, y = height / 2, angle = 0 },
    }
end

---------------------------------------------------------------------------
-- Parsing
---------------------------------------------------------------------------

local function parseHeaderLine(map, line, lineNo, errors)
    local key, rest = line:match('^(%S+)%s*(.*)$')
    if not key then return end

    key = key:lower()

    if key == 'name' then
        map.name = rest
    elseif key == 'theme' then
        map.theme = rest
    elseif key == 'spawn' then
        local sx, sy, sa = rest:match('^(%-?[%d%.]+)%s+(%-?[%d%.]+)%s*(%-?[%d%.]*)')
        if sx and sy then
            map.spawn = { x = tonumber(sx), y = tonumber(sy), angle = tonumber(sa) or 0 }
        else
            errors[#errors + 1] = ('line %d: spawn needs "x y [angle]"'):format(lineNo)
        end
    elseif key == 'size' then
        local sw, sh = rest:match('^(%d+)%s+(%d+)')
        if sw and sh then
            map.declaredWidth, map.declaredHeight = tonumber(sw), tonumber(sh)
        else
            errors[#errors + 1] = ('line %d: size needs "width height"'):format(lineNo)
        end
    elseif key == 'entity' then
        local char, archetype = rest:match('^(%S)%s+(%S+)')
        if char and archetype then
            map.legend[char] = archetype
        else
            errors[#errors + 1] = ('line %d: entity needs "<char> <archetype>"'):format(lineNo)
        end
    elseif key == 'height' then
        -- Wall height for a solid tile: "height <tx> <ty> <0..1>". Applied in
        -- Map.toWorld after the grid exists, so a height on open floor is
        -- refused there rather than at parse time (the tile code is not known
        -- yet while the header is still being read).
        local tx, ty, hh = rest:match('^(%d+)%s+(%d+)%s+([%d%.]+)')
        if tx and ty and hh then
            map.wallHeights = map.wallHeights or {}
            map.wallHeights[#map.wallHeights + 1] = {
                x = tonumber(tx), y = tonumber(ty), h = tonumber(hh),
            }
        else
            errors[#errors + 1] =
                ('line %d: height needs "tx ty fraction"'):format(lineNo)
        end
    elseif key == 'slab' then
        -- Stacked / floating wall: "slab <tx> <ty> <base> <height>".
        local tx, ty, base, hh =
            rest:match('^(%d+)%s+(%d+)%s+([%d%.]+)%s+([%d%.]+)')
        if tx and ty and base and hh then
            map.wallSlabs = map.wallSlabs or {}
            map.wallSlabs[#map.wallSlabs + 1] = {
                x = tonumber(tx), y = tonumber(ty),
                base = tonumber(base), h = tonumber(hh),
            }
        else
            errors[#errors + 1] =
                ('line %d: slab needs "tx ty base height"'):format(lineNo)
        end
    else
        -- Unknown keys are kept rather than dropped, so a map written by a newer
        -- editor survives a round-trip through an older one instead of being
        -- silently stripped.
        map.extra = map.extra or {}
        map.extra[key] = rest
    end
end

-- Parses map text. Returns the map table, or nil plus a list of errors.
function Map.parse(text)
    if type(text) ~= 'string' then return nil, { 'map text must be a string' } end

    local errors = {}
    local map = {
        name = 'untitled',
        theme = 'dungeon',
        tiles = {},
        doors = {},
        entities = {},
        legend = {},
        wallHeights = {},
        wallSlabs = {},
        spawn = nil,
    }

    -- Split header from grid on the first `---` line.
    --
    -- Carriage returns are stripped rather than rejected. A map written on Windows
    -- has them, and so does any checkout where git's autocrlf converted the file —
    -- which is the default on Windows, so a fresh clone would otherwise fail to
    -- parse maps the repository itself ships. Refusing a file for its line endings
    -- is a hostile way to greet someone who has just cloned the project, and the
    -- error it produced ("unknown character") pointed nowhere near the cause.
    local lines = {}
    for line in (text .. '\n'):gmatch('([^\n]*)\n') do
        lines[#lines + 1] = (line:gsub('\r$', ''))
    end

    local sep
    for i = 1, #lines do
        if lines[i]:match('^%s*%-%-%-%s*$') then sep = i; break end
    end

    if not sep then
        return nil, { 'no "---" separator between header and grid' }
    end

    for i = 1, sep - 1 do
        local line = lines[i]
        -- Blank lines and # comments are allowed in the header. A comment marker
        -- would be ambiguous in the grid (it means wall there), which is exactly
        -- why comments are header-only.
        if not line:match('^%s*$') and not line:match('^%s*#') then
            parseHeaderLine(map, line, i, errors)
        end
    end

    -- Grid rows are everything after the separator, trailing blank lines dropped.
    local rows = {}
    for i = sep + 1, #lines do rows[#rows + 1] = lines[i] end
    while #rows > 0 and rows[#rows]:match('^%s*$') do rows[#rows] = nil end

    if #rows == 0 then
        return nil, { 'map has no grid rows' }
    end

    local width = 0
    for i = 1, #rows do width = math.max(width, #rows[i]) end

    map.height = #rows
    map.width = width

    if map.declaredWidth and map.declaredWidth ~= width then
        errors[#errors + 1] = ('size header says width %d but grid is %d wide')
            :format(map.declaredWidth, width)
    end
    if map.declaredHeight and map.declaredHeight ~= map.height then
        errors[#errors + 1] = ('size header says height %d but grid is %d tall')
            :format(map.declaredHeight, map.height)
    end

    local gridSpawn

    for y = 1, map.height do
        map.tiles[y] = {}
        local row = rows[y]

        for x = 1, width do
            -- Rows shorter than the widest are padded with floor rather than
            -- rejected, so a hand-edited map with ragged trailing spaces loads.
            local ch = row:sub(x, x)
            if ch == '' then ch = ' ' end

            local tile = 0

            if ch == Map.WALL then
                tile = 1
            elseif ch:match('^%d$') then
                local n = tonumber(ch)
                tile = (n == 0) and 0 or n
            elseif ch == Map.FLOOR or ch == ' ' then
                tile = 0
            elseif ch == Map.DOOR_SHUT or ch == Map.DOOR_OPEN then
                tile = World.DOOR
                map.doors[#map.doors + 1] = { x = x, y = y, open = (ch == Map.DOOR_OPEN) }
            elseif ch == Map.STAIRS_UP then
                tile = World.STAIRS_UP
            elseif ch == Map.STAIRS_DOWN then
                tile = World.STAIRS_DOWN
            elseif ch == Map.SPAWN then
                tile = 0
                gridSpawn = { x = x - 0.5, y = y - 0.5, angle = 0 }
            elseif ch:match('^%a$') then
                tile = 0
                local archetype = map.legend[ch]
                if archetype then
                    map.entities[#map.entities + 1] = {
                        kind = archetype, char = ch,
                        x = x - 0.5, y = y - 0.5, angle = 0,
                    }
                else
                    errors[#errors + 1] =
                        ('row %d col %d: "%s" has no `entity %s <archetype>` header')
                        :format(y, x, ch, ch)
                end
            else
                errors[#errors + 1] = ('row %d col %d: unknown character "%s"')
                    :format(y, x, ch)
            end

            map.tiles[y][x] = tile
        end
    end

    -- An explicit spawn header wins over an `@` in the grid, because it can carry
    -- a facing angle and a fractional position.
    map.spawn = map.spawn or gridSpawn or { x = width / 2, y = map.height / 2, angle = 0 }

    map.declaredWidth, map.declaredHeight = nil, nil

    if #errors > 0 then return nil, errors end
    return map
end

---------------------------------------------------------------------------
-- Serialising
---------------------------------------------------------------------------

-- Writes a map back out. Round-trips: parse(serialize(m)) reproduces m.
function Map.serialize(map)
    local out = {}

    out[#out + 1] = 'name  ' .. (map.name or 'untitled')
    out[#out + 1] = 'theme ' .. (map.theme or 'dungeon')
    out[#out + 1] = ('size  %d %d'):format(map.width, map.height)

    if map.spawn then
        out[#out + 1] = ('spawn %s %s %s'):format(
            tostring(map.spawn.x), tostring(map.spawn.y),
            tostring(map.spawn.angle or 0))
    end

    -- Legend lines are sorted so the file is stable: an unsorted pairs() walk
    -- would reorder them between saves and make every diff look like a change.
    local chars = {}
    for ch in pairs(map.legend or {}) do chars[#chars + 1] = ch end
    table.sort(chars)
    for i = 1, #chars do
        out[#out + 1] = ('entity %s %s'):format(chars[i], map.legend[chars[i]])
    end

    for _, wh in ipairs(map.wallHeights or {}) do
        out[#out + 1] = ('height %d %d %s'):format(wh.x, wh.y, tostring(wh.h))
    end
    for _, ws in ipairs(map.wallSlabs or {}) do
        out[#out + 1] = ('slab %d %d %s %s'):format(
            ws.x, ws.y, tostring(ws.base), tostring(ws.h or ws.height))
    end

    if map.extra then
        local keys = {}
        for k in pairs(map.extra) do keys[#keys + 1] = k end
        table.sort(keys)
        for i = 1, #keys do
            out[#out + 1] = ('%s %s'):format(keys[i], map.extra[keys[i]])
        end
    end

    out[#out + 1] = '---'

    -- Index doors and entities by tile so the grid write is a single pass.
    local doorAt, entityAt = {}, {}
    for _, d in ipairs(map.doors or {}) do
        doorAt[d.x .. ',' .. d.y] = d.open and Map.DOOR_OPEN or Map.DOOR_SHUT
    end
    for _, e in ipairs(map.entities or {}) do
        local tx, ty = floor(e.x) + 1, floor(e.y) + 1
        entityAt[tx .. ',' .. ty] = e.char or Map.charFor(map, e.kind)
    end

    local spawnTx, spawnTy
    if map.spawn then
        spawnTx, spawnTy = floor(map.spawn.x) + 1, floor(map.spawn.y) + 1
    end

    for y = 1, map.height do
        local row = {}
        for x = 1, map.width do
            local key = x .. ',' .. y
            local tile = map.tiles[y] and map.tiles[y][x] or 0
            local ch

            if doorAt[key] then
                ch = doorAt[key]
            elseif entityAt[key] then
                ch = entityAt[key]
            elseif tile == World.STAIRS_UP then
                ch = Map.STAIRS_UP
            elseif tile == World.STAIRS_DOWN then
                ch = Map.STAIRS_DOWN
            elseif tile == World.DOOR then
                ch = Map.DOOR_SHUT
            elseif tile == 0 then
                -- The spawn marker only goes in the grid when there is no spawn
                -- header, and there always is one above, so plain floor here.
                ch = Map.FLOOR
            elseif tile == 1 then
                ch = Map.WALL
            elseif tile >= 2 and tile <= 9 then
                ch = tostring(tile)
            else
                ch = Map.WALL
            end

            row[#row + 1] = ch
        end
        out[#out + 1] = table.concat(row)
    end

    return table.concat(out, '\n') .. '\n'
end

-- Finds or assigns the grid character for an archetype, extending the legend if
-- the editor has just placed a kind the map has never held before.
function Map.charFor(map, kind)
    map.legend = map.legend or {}

    for ch, archetype in pairs(map.legend) do
        if archetype == kind then return ch end
    end

    -- Prefer the kind's own initial, then any free lowercase letter. 'd' and 'v'
    -- are reserved by doors and stairs.
    local preferred = kind:sub(1, 1):lower()
    local candidates = { preferred }
    for c = string.byte('a'), string.byte('z') do
        candidates[#candidates + 1] = string.char(c)
    end

    for i = 1, #candidates do
        local ch = candidates[i]
        if ch:match('^%a$') and ch ~= Map.DOOR_OPEN and ch ~= Map.STAIRS_DOWN
           and not map.legend[ch] then
            map.legend[ch] = kind
            return ch
        end
    end

    return '?'
end

---------------------------------------------------------------------------
-- Bridging to the simulation
---------------------------------------------------------------------------

-- Builds a World from a map, plus the list of entity markers for the game to
-- spawn. Markers are returned rather than spawned here because this module knows
-- nothing about archetypes and must not: it is a file format, not a factory.
function Map.toWorld(map)
    local grid = {}
    for y = 1, map.height do
        grid[y] = {}
        for x = 1, map.width do
            grid[y][x] = map.tiles[y][x] or 0
        end
    end

    local world = World.new(grid, {
        theme = map.theme,
        spawn = map.spawn and { x = map.spawn.x, y = map.spawn.y } or nil,
    })

    for _, d in ipairs(map.doors or {}) do
        world:addDoor(d.x, d.y, d.open)
    end

    for _, wh in ipairs(map.wallHeights or {}) do
        -- Refused silently for open floor / OOB: the map author may have left a
        -- height line pointing at a tile that was later opened, and a load that
        -- dies on that is worse than a height that simply does not apply.
        world:setWallHeight(wh.x, wh.y, wh.h)
    end
    for _, ws in ipairs(map.wallSlabs or {}) do
        world:addWallSlab(ws.x, ws.y, ws.base, ws.h or ws.height)
    end

    local markers = {}
    for i, e in ipairs(map.entities or {}) do
        markers[i] = { kind = e.kind, x = e.x, y = e.y, angle = e.angle or 0 }
    end

    return world, markers, map.spawn
end

-- Captures a World back into a map table, which is what the editor saves.
function Map.fromWorld(world, opts)
    opts = opts or {}

    local map = {
        name = opts.name or 'untitled',
        theme = opts.theme or world.theme or 'dungeon',
        width = world.width,
        height = world.height,
        tiles = {},
        doors = {},
        entities = {},
        legend = {},
        wallHeights = {},
        wallSlabs = {},
        spawn = opts.spawn or (world.spawn and
            { x = world.spawn.x, y = world.spawn.y, angle = 0 }) or nil,
    }

    for y = 1, world.height do
        map.tiles[y] = {}
        for x = 1, world.width do
            map.tiles[y][x] = world:tileAt(x, y)
        end
    end

    for key, door in pairs(world.doors) do
        local sx, sy = key:match('^(%-?%d+),(%-?%d+)$')
        map.doors[#map.doors + 1] = {
            x = tonumber(sx), y = tonumber(sy), open = door.open,
        }
    end
    table.sort(map.doors, function(a, b)
        if a.y ~= b.y then return a.y < b.y end
        return a.x < b.x
    end)

    for key, h in pairs(world.wallHeights or {}) do
        local sx, sy = key:match('^(%-?%d+),(%-?%d+)$')
        if sx and sy then
            map.wallHeights[#map.wallHeights + 1] = {
                x = tonumber(sx), y = tonumber(sy), h = h,
            }
        end
    end
    table.sort(map.wallHeights, function(a, b)
        if a.y ~= b.y then return a.y < b.y end
        return a.x < b.x
    end)

    for key, slabs in pairs(world.wallSlabs or {}) do
        local sx, sy = key:match('^(%-?%d+),(%-?%d+)$')
        if sx and sy and type(slabs) == 'table' then
            for i = 1, #slabs do
                local s = slabs[i]
                map.wallSlabs[#map.wallSlabs + 1] = {
                    x = tonumber(sx), y = tonumber(sy),
                    base = s.base or 0, h = s.height or 1,
                }
            end
        end
    end
    table.sort(map.wallSlabs, function(a, b)
        if a.y ~= b.y then return a.y < b.y end
        if a.x ~= b.x then return a.x < b.x end
        return (a.base or 0) < (b.base or 0)
    end)

    for _, e in ipairs(opts.entities or {}) do
        local entry = { kind = e.kind, x = e.x, y = e.y, angle = e.angle or 0 }
        entry.char = Map.charFor(map, e.kind)
        map.entities[#map.entities + 1] = entry
    end

    return map
end

return Map
