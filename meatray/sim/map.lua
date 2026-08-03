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
        floor  [storey] <tx> <ty> <z>    walk surface (optional storey, default 1)
        ceiling [storey] <tx> <ty> <z>   ceiling plane (optional storey)
        height [storey] <tx> <ty> <h>    short wall
        slab   [storey] <tx> <ty> <b> <h>
        link up|down <path> [x y angle]  multi-map storey: stairs F to other map

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
        -- "height [storey] <tx> <ty> <0..1>". Optional leading storey (default 1).
        local a, b, c, d = rest:match('^(%d+)%s+(%d+)%s+(%d+)%s+([%d%.]+)')
        local storey, tx, ty, hh
        if a and b and c and d then
            storey, tx, ty, hh = tonumber(a), tonumber(b), tonumber(c), tonumber(d)
        else
            tx, ty, hh = rest:match('^(%d+)%s+(%d+)%s+([%d%.]+)')
            storey, tx, ty, hh = 1, tonumber(tx), tonumber(ty), tonumber(hh)
        end
        if tx and ty and hh then
            map.wallHeights = map.wallHeights or {}
            map.wallHeights[#map.wallHeights + 1] = {
                storey = storey, x = tx, y = ty, h = hh,
            }
        else
            errors[#errors + 1] =
                ('line %d: height needs "[storey] tx ty fraction"'):format(lineNo)
        end
    elseif key == 'slab' then
        -- "slab [storey] <tx> <ty> <base> <height>".
        local a, b, c, d, e =
            rest:match('^(%d+)%s+(%d+)%s+(%d+)%s+([%d%.]+)%s+([%d%.]+)')
        local storey, tx, ty, base, hh
        if a and b and c and d and e then
            storey = tonumber(a)
            tx, ty, base, hh = tonumber(b), tonumber(c), tonumber(d), tonumber(e)
        else
            tx, ty, base, hh =
                rest:match('^(%d+)%s+(%d+)%s+([%d%.]+)%s+([%d%.]+)')
            storey = 1
            tx, ty, base, hh = tonumber(tx), tonumber(ty), tonumber(base), tonumber(hh)
        end
        if tx and ty and base and hh then
            map.wallSlabs = map.wallSlabs or {}
            map.wallSlabs[#map.wallSlabs + 1] = {
                storey = storey, x = tx, y = ty, base = base, h = hh,
            }
        else
            errors[#errors + 1] =
                ('line %d: slab needs "[storey] tx ty base height"'):format(lineNo)
        end
    elseif key == 'floor' then
        -- "floor [storey] <tx> <ty> <z>". Optional leading storey (default 1).
        local a, b, c, d = rest:match('^(%d+)%s+(%d+)%s+(%d+)%s+([%d%.]+)')
        local storey, tx, ty, zz
        if a and b and c and d then
            storey, tx, ty, zz = tonumber(a), tonumber(b), tonumber(c), tonumber(d)
        else
            tx, ty, zz = rest:match('^(%d+)%s+(%d+)%s+([%d%.]+)')
            storey, tx, ty, zz = 1, tonumber(tx), tonumber(ty), tonumber(zz)
        end
        if tx and ty and zz then
            map.floorHeights = map.floorHeights or {}
            map.floorHeights[#map.floorHeights + 1] = {
                storey = storey, x = tx, y = ty, z = zz,
            }
        else
            errors[#errors + 1] =
                ('line %d: floor needs "[storey] tx ty z"'):format(lineNo)
        end
    elseif key == 'ceiling' then
        local a, b, c, d = rest:match('^(%d+)%s+(%d+)%s+(%d+)%s+([%d%.]+)')
        local storey, tx, ty, zz
        if a and b and c and d then
            storey, tx, ty, zz = tonumber(a), tonumber(b), tonumber(c), tonumber(d)
        else
            tx, ty, zz = rest:match('^(%d+)%s+(%d+)%s+([%d%.]+)')
            storey, tx, ty, zz = 1, tonumber(tx), tonumber(ty), tonumber(zz)
        end
        if tx and ty and zz then
            map.ceilingHeights = map.ceilingHeights or {}
            map.ceilingHeights[#map.ceilingHeights + 1] = {
                storey = storey, x = tx, y = ty, z = zz,
            }
        else
            errors[#errors + 1] =
                ('line %d: ceiling needs "[storey] tx ty z"'):format(lineNo)
        end
    elseif key == 'link' then
        -- Multi-map storey: "link up maps/foo.map [x y [angle]]".
        -- True stacked floors in one world are a separate architecture; this is
        -- the practical "go upstairs" path (see docs/STOREYS.md).
        local dir, path, sx, sy, sa = rest:match(
            '^(%S+)%s+(%S+)%s*(%-?[%d%.]*)%s*(%-?[%d%.]*)%s*(%-?[%d%.]*)')
        dir = dir and dir:lower()
        if (dir == 'up' or dir == 'down') and path and path ~= '' then
            map.links = map.links or {}
            local entry = { path = path }
            if sx ~= '' and sy ~= '' then
                entry.x = tonumber(sx)
                entry.y = tonumber(sy)
                entry.angle = (sa ~= '' and tonumber(sa)) or 0
            end
            map.links[dir] = entry
        else
            errors[#errors + 1] =
                ('line %d: link needs "up|down path [x y [angle]]"'):format(lineNo)
        end
    elseif key == 'exit' then
        -- Level exit volume for campaign flow (meatray.game.campaign).
        --   exit <x1> <y1> <x2> <y2>           world AABB
        --   exit tiles <tx1> <ty1> <tx2> <ty2>  inclusive tile rect (1-based)
        local kind, a, b, c, d = rest:match(
            '^(%S+)%s+(%-?[%d%.]+)%s+(%-?[%d%.]+)%s+(%-?[%d%.]+)%s+(%-?[%d%.]+)')
        if kind and (kind == 'tiles' or kind == 'tile') then
            map.exit = {
                tiles = true,
                tx1 = tonumber(a), ty1 = tonumber(b),
                tx2 = tonumber(c), ty2 = tonumber(d),
            }
        else
            local x1, y1, x2, y2 = rest:match(
                '^(%-?[%d%.]+)%s+(%-?[%d%.]+)%s+(%-?[%d%.]+)%s+(%-?[%d%.]+)')
            if x1 then
                map.exit = {
                    x1 = tonumber(x1), y1 = tonumber(y1),
                    x2 = tonumber(x2), y2 = tonumber(y2),
                }
            else
                errors[#errors + 1] =
                    ('line %d: exit needs "x1 y1 x2 y2" or "tiles tx1 ty1 tx2 ty2"')
                    :format(lineNo)
            end
        end
    elseif key == 'lock' then
        -- "lock [storey] <tx> <ty> <keyid>" — the door on that tile refuses to
        -- open until something presents keyid (an item id like key.red).
        local a, b, c, k = rest:match('^(%d+)%s+(%d+)%s+(%d+)%s+(%S+)')
        local storey, tx, ty, keyId
        if a and b and c and k then
            storey, tx, ty, keyId = tonumber(a), tonumber(b), tonumber(c), k
        else
            local x, y, kk = rest:match('^(%d+)%s+(%d+)%s+(%S+)')
            storey, tx, ty, keyId = 1, tonumber(x), tonumber(y), kk
        end
        if tx and ty and keyId then
            map.locks = map.locks or {}
            map.locks[#map.locks + 1] = {
                storey = storey, x = tx, y = ty, key = keyId,
            }
        else
            errors[#errors + 1] =
                ('line %d: lock needs "[storey] tx ty keyid"'):format(lineNo)
        end
    elseif key == 'pushwall' then
        -- "pushwall [storey] <tx> <ty> <dx> <dy> <distance>". Distance is
        -- required precisely so five numbers always mean "no storey" — an
        -- optional storey AND an optional distance would be ambiguous.
        local n = {}
        for tok in rest:gmatch('%-?%d+') do n[#n + 1] = tonumber(tok) end
        local storey, tx, ty, dx, dy, dist
        if #n == 6 then
            storey, tx, ty, dx, dy, dist = n[1], n[2], n[3], n[4], n[5], n[6]
        elseif #n == 5 then
            storey, tx, ty, dx, dy, dist = 1, n[1], n[2], n[3], n[4], n[5]
        end
        if tx then
            map.pushWalls = map.pushWalls or {}
            map.pushWalls[#map.pushWalls + 1] = {
                storey = storey, x = tx, y = ty,
                dx = dx, dy = dy, distance = dist,
            }
        else
            errors[#errors + 1] =
                ('line %d: pushwall needs "[storey] tx ty dx dy distance"')
                :format(lineNo)
        end
    elseif key == 'secret' then
        -- "secret [storey] <x1> <y1> <x2> <y2> [name]" — a world-space AABB a
        -- player must stand inside to have found it (meatray.game.secrets).
        local NUM = '(%-?[%d%.]+)'
        local a, b, c, d, e, name = rest:match(
            '^(%d+)%s+' .. NUM .. '%s+' .. NUM .. '%s+' .. NUM .. '%s+' .. NUM .. '%s*(.*)$')
        local storey, x1, y1, x2, y2
        if a and tonumber(e) then
            storey = tonumber(a)
            x1, y1, x2, y2 = tonumber(b), tonumber(c), tonumber(d), tonumber(e)
        else
            local p, q, r, s
            p, q, r, s, name = rest:match(
                '^' .. NUM .. '%s+' .. NUM .. '%s+' .. NUM .. '%s+' .. NUM .. '%s*(.*)$')
            storey = 1
            x1, y1, x2, y2 = tonumber(p), tonumber(q), tonumber(r), tonumber(s)
        end
        if x1 and y1 and x2 and y2 then
            if name == '' then name = nil end
            map.secrets = map.secrets or {}
            map.secrets[#map.secrets + 1] = {
                storey = storey, x1 = x1, y1 = y1, x2 = x2, y2 = y2, name = name,
            }
        else
            errors[#errors + 1] =
                ('line %d: secret needs "[storey] x1 y1 x2 y2 [name]"'):format(lineNo)
        end
    elseif key == 'hazard' then
        -- "hazard <kind> [storey] <x1> <y1> <x2> <y2>" — a world-space box a
        -- hazard kind (water/slime/lava/...) covers. The sim carries it as
        -- data; meatray.game.hazards decides what the kind means.
        local NUM = '(%-?[%d%.]+)'
        local kindName, numRest = rest:match('^(%S+)%s+(.*)$')
        local storey, x1, y1, x2, y2
        if kindName then
            local a, b, c, d, e2 = numRest:match(
                '^(%d+)%s+' .. NUM .. '%s+' .. NUM .. '%s+' .. NUM .. '%s+' .. NUM .. '%s*$')
            if a and tonumber(e2) then
                storey = tonumber(a)
                x1, y1, x2, y2 = tonumber(b), tonumber(c), tonumber(d), tonumber(e2)
            else
                local p, q, r, s = numRest:match(
                    '^' .. NUM .. '%s+' .. NUM .. '%s+' .. NUM .. '%s+' .. NUM .. '%s*$')
                storey = 1
                x1, y1, x2, y2 = tonumber(p), tonumber(q), tonumber(r), tonumber(s)
            end
        end
        if kindName and x1 and y1 and x2 and y2 then
            map.hazards = map.hazards or {}
            map.hazards[#map.hazards + 1] = {
                kind = kindName, storey = storey,
                x1 = x1, y1 = y1, x2 = x2, y2 = y2,
            }
        else
            errors[#errors + 1] =
                ('line %d: hazard needs "<kind> [storey] x1 y1 x2 y2"'):format(lineNo)
        end
    elseif key == 'trigger' then
        -- "trigger <name> <graph> [storey] <x1> <y1> <x2> <y2> [once] [player|any]"
        -- A world-space AABB that fires a MeatGraph. `name` is the volume name a
        -- graph's EventOnTrigger matches on; `graph` is the graph id resolved
        -- through the pack registry at load. The sim carries it as data — the
        -- game layer (main.lua loadAuthored) does the loading and binding, the
        -- same division hazards and secrets already keep.
        local NUM = '(%-?[%d%.]+)'
        local name, graphId, numRest = rest:match('^(%S+)%s+(%S+)%s+(.*)$')
        local storey, x1, y1, x2, y2, tail
        if name then
            local a, b, c, d, e2, t = numRest:match(
                '^(%d+)%s+' .. NUM .. '%s+' .. NUM .. '%s+' .. NUM .. '%s+' .. NUM .. '%s*(.*)$')
            if a and tonumber(e2) then
                storey = tonumber(a)
                x1, y1, x2, y2 = tonumber(b), tonumber(c), tonumber(d), tonumber(e2)
                tail = t
            else
                local p, q, r, s, t2 = numRest:match(
                    '^' .. NUM .. '%s+' .. NUM .. '%s+' .. NUM .. '%s+' .. NUM .. '%s*(.*)$')
                storey = 1
                x1, y1, x2, y2 = tonumber(p), tonumber(q), tonumber(r), tonumber(s)
                tail = t2
            end
        end
        if name and graphId and x1 and y1 and x2 and y2 then
            local once, filter = false, 'player'
            for tok in tostring(tail or ''):gmatch('%S+') do
                if tok == 'once' then once = true
                elseif tok == 'any' or tok == 'player' then filter = tok end
            end
            map.triggers = map.triggers or {}
            map.triggers[#map.triggers + 1] = {
                name = name, graph = graphId, storey = storey,
                x1 = x1, y1 = y1, x2 = x2, y2 = y2, once = once, filter = filter,
            }
        else
            errors[#errors + 1] = ('line %d: trigger needs '
                .. '"<name> <graph> [storey] x1 y1 x2 y2 [once] [player|any]"')
                :format(lineNo)
        end
    elseif key == 'mask' then
        -- "mask <tx> <ty> [alpha]" — a see-through wall (fence/grate): solid for
        -- movement, translucent for rays. alpha is a decimal 0..1 (default 0.55
        -- applied by the world). Storey 1 only, like the other per-tile props
        -- fromWorld recovers.
        local tx, ty, alpha = rest:match('^(%d+)%s+(%d+)%s+(%d*%.%d+)%s*$')
        if not tx then tx, ty = rest:match('^(%d+)%s+(%d+)%s*$') end
        if tx and ty then
            map.masked = map.masked or {}
            map.masked[#map.masked + 1] = {
                x = tonumber(tx), y = tonumber(ty), alpha = tonumber(alpha),
            }
        else
            errors[#errors + 1] =
                ('line %d: mask needs "tx ty [alpha]"'):format(lineNo)
        end
    elseif key == 'surface' then
        -- "surface <material> <tx> <ty> [tx ty ...]" — tag tiles with a footstep
        -- material (stone/water/metal/...). Storey 1, like the other per-tile
        -- props fromWorld recovers.
        local mat, tail = rest:match('^(%S+)%s+(.*)$')
        local coords = {}
        if tail then for tok in tail:gmatch('%-?%d+') do coords[#coords + 1] = tonumber(tok) end end
        if mat and #coords >= 2 then
            map.surfaces = map.surfaces or {}
            for i = 1, #coords - 1, 2 do
                map.surfaces[#map.surfaces + 1] =
                    { material = mat, x = coords[i], y = coords[i + 1] }
            end
        else
            errors[#errors + 1] =
                ('line %d: surface needs "<material> tx ty [tx ty ...]"'):format(lineNo)
        end
    elseif key == 'anim' then
        -- "anim <tx> <ty> <fps> <tile1> [tile2 ...]" — cycle a wall's texture
        -- through the listed codes (1..9) at fps frames a second. Driven by
        -- world:update, which the game already ticks.
        local tx, ty, fps, tail = rest:match('^(%d+)%s+(%d+)%s+(%d+)%s+(.*)$')
        local tiles = {}
        if tail then
            for tok in tail:gmatch('%d+') do tiles[#tiles + 1] = tonumber(tok) end
        end
        if tx and ty and fps and #tiles > 0 then
            map.wallAnims = map.wallAnims or {}
            map.wallAnims[#map.wallAnims + 1] = {
                x = tonumber(tx), y = tonumber(ty), fps = tonumber(fps),
                tiles = tiles,
            }
        else
            errors[#errors + 1] =
                ('line %d: anim needs "tx ty fps tile1 [tile2 ...]"'):format(lineNo)
        end
    elseif key == 'ambient' then
        -- "ambient <sound> [storey] <x1> <y1> <x2> <y2>" — a world-space AABB
        -- that plays a room-tone loop. The sound id is the game's content; this
        -- is just the region. Mirrors the trigger/hazard storey-optional shape.
        local NUM = '(%-?[%d%.]+)'
        local sound, numRest = rest:match('^(%S+)%s+(.*)$')
        local storey, x1, y1, x2, y2
        if sound then
            local a, b, c, d, e2 = numRest:match(
                '^(%d+)%s+' .. NUM .. '%s+' .. NUM .. '%s+' .. NUM .. '%s+' .. NUM .. '%s*$')
            if a and tonumber(e2) then
                storey = tonumber(a)
                x1, y1, x2, y2 = tonumber(b), tonumber(c), tonumber(d), tonumber(e2)
            else
                local p, q, r, s = numRest:match(
                    '^' .. NUM .. '%s+' .. NUM .. '%s+' .. NUM .. '%s+' .. NUM .. '%s*$')
                storey = 1
                x1, y1, x2, y2 = tonumber(p), tonumber(q), tonumber(r), tonumber(s)
            end
        end
        if sound and x1 and y1 and x2 and y2 then
            map.ambientZones = map.ambientZones or {}
            map.ambientZones[#map.ambientZones + 1] = {
                sound = sound, storey = storey,
                x1 = x1, y1 = y1, x2 = x2, y2 = y2,
            }
        else
            errors[#errors + 1] =
                ('line %d: ambient needs "<sound> [storey] x1 y1 x2 y2"'):format(lineNo)
        end
    elseif key == 'mover' then
        -- "mover <id> <zDown> <zUp> <speed> <up|down> <tx1> <ty1> [tx2 ty2 ...]"
        -- A lift: the listed tiles slide their floor between zDown and zUp. The
        -- sim carries it as data; the game builds a meatray.sim.movers host and
        -- ticks it, the same division triggers and hazards keep.
        local id, zd, zu, sp, start, tail =
            rest:match('^(%S+)%s+([%d%.]+)%s+([%d%.]+)%s+([%d%.]+)%s+(%a+)%s+(.*)$')
        local coords = {}
        if tail then
            for tok in tail:gmatch('%-?%d+') do coords[#coords + 1] = tonumber(tok) end
        end
        local tiles = {}
        for i = 1, #coords - 1, 2 do
            tiles[#tiles + 1] = { tx = coords[i], ty = coords[i + 1] }
        end
        if id and zd and zu and sp and (start == 'up' or start == 'down')
           and #tiles > 0 then
            map.movers = map.movers or {}
            map.movers[#map.movers + 1] = {
                id = id, zDown = tonumber(zd), zUp = tonumber(zu),
                speed = tonumber(sp), start = start, tiles = tiles,
            }
        else
            errors[#errors + 1] = ('line %d: mover needs '
                .. '"<id> zDown zUp speed up|down tx1 ty1 [tx2 ty2 ...]"')
                :format(lineNo)
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
        floorHeights = {},
        ceilingHeights = {},
        links = {},
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

    -- Grids: everything after the first ---. Additional --- start the next
    -- storey (same width/height). See docs/STOREYS.md.
    local seps = { sep }
    for i = sep + 1, #lines do
        if lines[i]:match('^%s*%-%-%-%s*$') then
            seps[#seps + 1] = i
        end
    end

    local function sliceRows(from, to)
        local rows = {}
        for i = from, to do rows[#rows + 1] = lines[i] end
        while #rows > 0 and rows[#rows]:match('^%s*$') do rows[#rows] = nil end
        while #rows > 0 and rows[1]:match('^%s*$') do table.remove(rows, 1) end
        return rows
    end

    local storeyRows = {}
    for si = 1, #seps do
        local from = seps[si] + 1
        local to = (seps[si + 1] or (#lines + 1)) - 1
        local rows = sliceRows(from, to)
        if #rows > 0 then
            storeyRows[#storeyRows + 1] = rows
        end
    end

    if #storeyRows == 0 then
        return nil, { 'map has no grid rows' }
    end

    local function parseGrid(rows, storeyIndex, collectEntities)
        local width = 0
        for i = 1, #rows do width = math.max(width, #rows[i]) end
        local height = #rows
        local tiles, doors, entities, gridSpawn = {}, {}, {}, nil

        for y = 1, height do
            tiles[y] = {}
            local row = rows[y]
            for x = 1, width do
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
                    doors[#doors + 1] = { x = x, y = y, open = (ch == Map.DOOR_OPEN) }
                elseif ch == Map.STAIRS_UP then
                    tile = World.STAIRS_UP
                elseif ch == Map.STAIRS_DOWN then
                    tile = World.STAIRS_DOWN
                elseif ch == Map.SPAWN then
                    tile = 0
                    gridSpawn = { x = x - 0.5, y = y - 0.5, angle = 0 }
                elseif ch:match('^%a$') then
                    tile = 0
                    if collectEntities then
                        local archetype = map.legend[ch]
                        if archetype then
                            entities[#entities + 1] = {
                                kind = archetype, char = ch,
                                x = x - 0.5, y = y - 0.5, angle = 0,
                                storey = storeyIndex,
                            }
                        else
                            errors[#errors + 1] =
                                ('storey %d row %d col %d: "%s" has no entity header')
                                :format(storeyIndex, y, x, ch)
                        end
                    end
                else
                    errors[#errors + 1] =
                        ('storey %d row %d col %d: unknown character "%s"')
                        :format(storeyIndex, y, x, ch)
                end
                tiles[y][x] = tile
            end
        end
        return tiles, width, height, doors, entities, gridSpawn
    end

    local tiles1, width, height, doors1, ents1, gridSpawn =
        parseGrid(storeyRows[1], 1, true)

    map.tiles = tiles1
    map.width = width
    map.height = height
    map.doors = doors1
    map.entities = ents1
    map.storeys = { { tiles = tiles1, doors = doors1, spawn = gridSpawn } }

    for si = 2, #storeyRows do
        local tiles, w, h, doors, ents, spawn =
            parseGrid(storeyRows[si], si, true)
        if w ~= width or h ~= height then
            errors[#errors + 1] =
                ('storey %d is %dx%d but storey 1 is %dx%d')
                :format(si, w, h, width, height)
        end
        map.storeys[si] = { tiles = tiles, doors = doors, spawn = spawn }
        for i = 1, #ents do
            map.entities[#map.entities + 1] = ents[i]
        end
    end

    if map.declaredWidth and map.declaredWidth ~= width then
        errors[#errors + 1] = ('size header says width %d but grid is %d wide')
            :format(map.declaredWidth, width)
    end
    if map.declaredHeight and map.declaredHeight ~= map.height then
        errors[#errors + 1] = ('size header says height %d but grid is %d tall')
            :format(map.declaredHeight, map.height)
    end

    map.spawn = map.spawn or gridSpawn or { x = width / 2, y = height / 2, angle = 0 }
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
        local s = wh.storey or 1
        if s ~= 1 then
            out[#out + 1] = ('height %d %d %d %s'):format(s, wh.x, wh.y, tostring(wh.h))
        else
            out[#out + 1] = ('height %d %d %s'):format(wh.x, wh.y, tostring(wh.h))
        end
    end
    for _, ws in ipairs(map.wallSlabs or {}) do
        local s = ws.storey or 1
        if s ~= 1 then
            out[#out + 1] = ('slab %d %d %d %s %s'):format(
                s, ws.x, ws.y, tostring(ws.base), tostring(ws.h or ws.height))
        else
            out[#out + 1] = ('slab %d %d %s %s'):format(
                ws.x, ws.y, tostring(ws.base), tostring(ws.h or ws.height))
        end
    end
    for _, fh in ipairs(map.floorHeights or {}) do
        local s = fh.storey or 1
        if s ~= 1 then
            out[#out + 1] = ('floor %d %d %d %s'):format(s, fh.x, fh.y, tostring(fh.z))
        else
            out[#out + 1] = ('floor %d %d %s'):format(fh.x, fh.y, tostring(fh.z))
        end
    end
    for _, ch in ipairs(map.ceilingHeights or {}) do
        local s = ch.storey or 1
        if s ~= 1 then
            out[#out + 1] = ('ceiling %d %d %d %s'):format(s, ch.x, ch.y, tostring(ch.z))
        else
            out[#out + 1] = ('ceiling %d %d %s'):format(ch.x, ch.y, tostring(ch.z))
        end
    end
    if map.links then
        local order = { 'up', 'down' }
        for _, dir in ipairs(order) do
            local L = map.links[dir]
            if L and L.path then
                if L.x and L.y then
                    out[#out + 1] = ('link %s %s %s %s %s'):format(
                        dir, L.path, tostring(L.x), tostring(L.y),
                        tostring(L.angle or 0))
                else
                    out[#out + 1] = ('link %s %s'):format(dir, L.path)
                end
            end
        end
    end

    for _, lk in ipairs(map.locks or {}) do
        local s = lk.storey or 1
        if s ~= 1 then
            out[#out + 1] = ('lock %d %d %d %s'):format(s, lk.x, lk.y, lk.key)
        else
            out[#out + 1] = ('lock %d %d %s'):format(lk.x, lk.y, lk.key)
        end
    end
    for _, pw in ipairs(map.pushWalls or {}) do
        local s = pw.storey or 1
        if s ~= 1 then
            out[#out + 1] = ('pushwall %d %d %d %d %d %d'):format(
                s, pw.x, pw.y, pw.dx, pw.dy, pw.distance or 1)
        else
            out[#out + 1] = ('pushwall %d %d %d %d %d'):format(
                pw.x, pw.y, pw.dx, pw.dy, pw.distance or 1)
        end
    end
    for _, sc in ipairs(map.secrets or {}) do
        local s = sc.storey or 1
        local line
        if s ~= 1 then
            line = ('secret %d %s %s %s %s'):format(s,
                tostring(sc.x1), tostring(sc.y1), tostring(sc.x2), tostring(sc.y2))
        else
            line = ('secret %s %s %s %s'):format(
                tostring(sc.x1), tostring(sc.y1), tostring(sc.x2), tostring(sc.y2))
        end
        if sc.name then line = line .. ' ' .. sc.name end
        out[#out + 1] = line
    end
    for _, hzd in ipairs(map.hazards or {}) do
        local s = hzd.storey or 1
        if s ~= 1 then
            out[#out + 1] = ('hazard %s %d %s %s %s %s'):format(hzd.kind, s,
                tostring(hzd.x1), tostring(hzd.y1), tostring(hzd.x2), tostring(hzd.y2))
        else
            out[#out + 1] = ('hazard %s %s %s %s %s'):format(hzd.kind,
                tostring(hzd.x1), tostring(hzd.y1), tostring(hzd.x2), tostring(hzd.y2))
        end
    end
    for _, tr in ipairs(map.triggers or {}) do
        local s = tr.storey or 1
        local line
        if s ~= 1 then
            line = ('trigger %s %s %d %s %s %s %s'):format(tr.name, tr.graph, s,
                tostring(tr.x1), tostring(tr.y1), tostring(tr.x2), tostring(tr.y2))
        else
            line = ('trigger %s %s %s %s %s %s'):format(tr.name, tr.graph,
                tostring(tr.x1), tostring(tr.y1), tostring(tr.x2), tostring(tr.y2))
        end
        if tr.once then line = line .. ' once' end
        -- 'player' is the default; only the non-default filter is written.
        if tr.filter and tr.filter ~= 'player' then line = line .. ' ' .. tr.filter end
        out[#out + 1] = line
    end
    for _, mk in ipairs(map.masked or {}) do
        if mk.alpha then
            out[#out + 1] = ('mask %d %d %s'):format(mk.x, mk.y, tostring(mk.alpha))
        else
            out[#out + 1] = ('mask %d %d'):format(mk.x, mk.y)
        end
    end
    for _, an in ipairs(map.wallAnims or {}) do
        local t = {}
        for i = 1, #(an.tiles or {}) do t[i] = tostring(an.tiles[i]) end
        out[#out + 1] = ('anim %d %d %d %s'):format(
            an.x, an.y, an.fps or 6, table.concat(t, ' '))
    end
    for _, s in ipairs(map.surfaces or {}) do
        out[#out + 1] = ('surface %s %d %d'):format(s.material, s.x, s.y)
    end
    for _, az in ipairs(map.ambientZones or {}) do
        local s = az.storey or 1
        if s ~= 1 then
            out[#out + 1] = ('ambient %s %d %s %s %s %s'):format(az.sound, s,
                tostring(az.x1), tostring(az.y1), tostring(az.x2), tostring(az.y2))
        else
            out[#out + 1] = ('ambient %s %s %s %s %s'):format(az.sound,
                tostring(az.x1), tostring(az.y1), tostring(az.x2), tostring(az.y2))
        end
    end
    for _, mv in ipairs(map.movers or {}) do
        local parts = {}
        for _, tl in ipairs(mv.tiles or {}) do
            parts[#parts + 1] = tostring(tl.tx)
            parts[#parts + 1] = tostring(tl.ty)
        end
        out[#out + 1] = ('mover %s %s %s %s %s %s'):format(
            mv.id, tostring(mv.zDown or 0), tostring(mv.zUp or 0.4),
            tostring(mv.speed or 0.35), mv.start or 'down', table.concat(parts, ' '))
    end

    if map.extra then
        local keys = {}
        for k in pairs(map.extra) do keys[#keys + 1] = k end
        table.sort(keys)
        for i = 1, #keys do
            out[#out + 1] = ('%s %s'):format(keys[i], map.extra[keys[i]])
        end
    end

    local function writeGrid(tiles, doors, entities, storeyIndex)
        out[#out + 1] = '---'
        local doorAt, entityAt = {}, {}
        for _, d in ipairs(doors or {}) do
            doorAt[d.x .. ',' .. d.y] = d.open and Map.DOOR_OPEN or Map.DOOR_SHUT
        end
        for _, e in ipairs(entities or {}) do
            local es = e.storey or 1
            if es == storeyIndex then
                local tx, ty = floor(e.x) + 1, floor(e.y) + 1
                entityAt[tx .. ',' .. ty] = e.char or Map.charFor(map, e.kind)
            end
        end
        for y = 1, map.height do
            local row = {}
            for x = 1, map.width do
                local key = x .. ',' .. y
                local tile = tiles[y] and tiles[y][x] or 0
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
    end

    local storeys = map.storeys
    if not storeys or #storeys == 0 then
        storeys = { { tiles = map.tiles, doors = map.doors } }
    end
    for si = 1, #storeys do
        local S = storeys[si]
        writeGrid(S.tiles or map.tiles, S.doors or (si == 1 and map.doors) or {},
                  map.entities, si)
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
-- Elevation helpers (editor + tools)
--
-- Floor and wall heights live as sparse lists on the map table so serialize
-- can write them as header lines. These helpers keep get/set O(n) on a short
-- list rather than forcing every paint path to invent its own search.
---------------------------------------------------------------------------

local function findElev(list, tx, ty)
    if not list then return nil, nil end
    for i = 1, #list do
        local e = list[i]
        if e.x == tx and e.y == ty then return e, i end
    end
    return nil, nil
end

function Map.floorHeight(map, tx, ty)
    local e = findElev(map.floorHeights, tx, ty)
    return e and e.z or 0
end

function Map.setFloorHeight(map, tx, ty, z)
    map.floorHeights = map.floorHeights or {}
    local e, i = findElev(map.floorHeights, tx, ty)
    if z == nil or z == 0 then
        if i then table.remove(map.floorHeights, i) end
        return true
    end
    if type(z) ~= 'number' or z ~= z or z < 0 then return false end
    if e then e.z = z else map.floorHeights[#map.floorHeights + 1] = { x = tx, y = ty, z = z } end
    return true
end

function Map.wallHeight(map, tx, ty)
    local e = findElev(map.wallHeights, tx, ty)
    return e and e.h or 1
end

function Map.setWallHeight(map, tx, ty, h)
    map.wallHeights = map.wallHeights or {}
    local e, i = findElev(map.wallHeights, tx, ty)
    if h == nil or h >= 1 then
        if i then table.remove(map.wallHeights, i) end
        return true
    end
    if type(h) ~= 'number' or h ~= h or h <= 0 then return false end
    if e then e.h = h else map.wallHeights[#map.wallHeights + 1] = { x = tx, y = ty, h = h } end
    return true
end

function Map.ceilingHeight(map, tx, ty)
    local e = findElev(map.ceilingHeights, tx, ty)
    return e and e.z or 1
end

function Map.setCeilingHeight(map, tx, ty, z)
    map.ceilingHeights = map.ceilingHeights or {}
    local e, i = findElev(map.ceilingHeights, tx, ty)
    if z == nil or z == 1 then
        if i then table.remove(map.ceilingHeights, i) end
        return true
    end
    if type(z) ~= 'number' or z ~= z or z < 0 then return false end
    if e then e.z = z else map.ceilingHeights[#map.ceilingHeights + 1] = { x = tx, y = ty, z = z } end
    return true
end

function Map.clearElevation(map, tx, ty)
    Map.setFloorHeight(map, tx, ty, nil)
    Map.setWallHeight(map, tx, ty, nil)
    Map.setCeilingHeight(map, tx, ty, nil)
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
        world:addDoor(d.x, d.y, d.open, 1)
    end

    -- Extra in-world storeys (map.storeys[2..]).
    local storeys = map.storeys or { { tiles = map.tiles, doors = map.doors } }
    for si = 2, #storeys do
        local S = storeys[si]
        local g = {}
        for y = 1, map.height do
            g[y] = {}
            for x = 1, map.width do
                g[y][x] = S.tiles[y] and S.tiles[y][x] or 0
            end
        end
        world:addStorey(g, { spawn = S.spawn })
        for _, d in ipairs(S.doors or {}) do
            world:addDoor(d.x, d.y, d.open, si)
        end
    end

    local rebuilt = {}
    for _, wh in ipairs(map.wallHeights or {}) do
        world:setWallHeight(wh.x, wh.y, wh.h, wh.storey or 1)
    end
    for _, ws in ipairs(map.wallSlabs or {}) do
        world:addWallSlab(ws.x, ws.y, ws.base, ws.h or ws.height, ws.storey or 1)
    end
    -- C-map: see-through walls and animated wall textures. Storey 1, matching
    -- the layer these props round-trip through fromWorld.
    for _, mk in ipairs(map.masked or {}) do
        world:setMasked(mk.x, mk.y, mk.alpha or true, 1)
    end
    for _, an in ipairs(map.wallAnims or {}) do
        world:setWallAnim(an.x, an.y, an.tiles, an.fps or 6, 1)
    end
    for _, s in ipairs(map.surfaces or {}) do
        world:setSurface(s.x, s.y, s.material, 1)
    end
    for _, fh in ipairs(map.floorHeights or {}) do
        local s = fh.storey or 1
        world:setFloorHeight(fh.x, fh.y, fh.z, { defer = true, storey = s })
        rebuilt[s] = true
    end
    for s in pairs(rebuilt) do
        world:rebuildFloorRisers(s)
    end
    for _, ch in ipairs(map.ceilingHeights or {}) do
        world:setCeilingHeight(ch.x, ch.y, ch.z, { storey = ch.storey or 1 })
    end
    if map.links then
        world.links = {}
        for dir, L in pairs(map.links) do
            world.links[dir] = {
                path = L.path,
                x = L.x, y = L.y, angle = L.angle,
            }
        end
    end

    for _, lk in ipairs(map.locks or {}) do
        world:lockDoor(lk.x, lk.y, lk.key, lk.storey or 1)
    end
    for _, pw in ipairs(map.pushWalls or {}) do
        world:addPushWall(pw.x, pw.y, {
            dx = pw.dx, dy = pw.dy, distance = pw.distance,
            storey = pw.storey or 1,
        })
    end
    -- Secret areas are data the game layer consumes (meatray.game.secrets);
    -- the world just carries them, the way it carries spawn and links.
    if map.secrets then
        world.secrets = {}
        for i, s in ipairs(map.secrets) do
            world.secrets[i] = {
                storey = s.storey or 1, name = s.name,
                x1 = s.x1, y1 = s.y1, x2 = s.x2, y2 = s.y2,
            }
        end
    end
    -- Hazard boxes ride the same way, for meatray.game.hazards.
    if map.hazards then
        world.hazards = {}
        for i, hzd in ipairs(map.hazards) do
            world.hazards[i] = {
                kind = hzd.kind, storey = hzd.storey or 1,
                x1 = hzd.x1, y1 = hzd.y1, x2 = hzd.x2, y2 = hzd.y2,
            }
        end
    end
    -- Trigger volumes ride the same way; loadAuthored binds each to its graph.
    if map.triggers then
        world.triggers = {}
        for i, tr in ipairs(map.triggers) do
            world.triggers[i] = {
                name = tr.name, graph = tr.graph, storey = tr.storey or 1,
                x1 = tr.x1, y1 = tr.y1, x2 = tr.x2, y2 = tr.y2,
                once = tr.once or false, filter = tr.filter or 'player',
            }
        end
    end

    -- C31: ambient zones ride as data; the game builds a meatray.game.ambient
    -- tracker from them and plays a room tone by region.
    if map.ambientZones then
        world.ambientZones = {}
        for i, az in ipairs(map.ambientZones) do
            world.ambientZones[i] = {
                sound = az.sound, storey = az.storey or 1,
                x1 = az.x1, y1 = az.y1, x2 = az.x2, y2 = az.y2,
            }
        end
    end
    -- C-map: lifts ride as data; loadAuthored builds a meatray.sim.movers host
    -- and ticks it (a mover animates floorHeights, which collision and the
    -- renderer already read — nothing else has to change).
    if map.movers then
        world.movers = {}
        for i, mv in ipairs(map.movers) do
            local tiles = {}
            for j, tl in ipairs(mv.tiles or {}) do
                tiles[j] = { tx = tl.tx, ty = tl.ty }
            end
            world.movers[i] = {
                id = mv.id, zDown = mv.zDown or 0, zUp = mv.zUp or 0.4,
                speed = mv.speed or 0.35, start = mv.start or 'down', tiles = tiles,
            }
        end
    end

    local markers = {}
    for i, e in ipairs(map.entities or {}) do
        markers[i] = {
            kind = e.kind, x = e.x, y = e.y, angle = e.angle or 0,
            storey = e.storey or 1,
        }
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
        floorHeights = {},
        ceilingHeights = {},
        links = {},
        spawn = opts.spawn or (world.spawn and
            { x = world.spawn.x, y = world.spawn.y, angle = 0 }) or nil,
    }

    local function layerDoors(L)
        local doors = {}
        for key, door in pairs(L.doors or {}) do
            local sx, sy = key:match('^(%-?%d+),(%-?%d+)$')
            doors[#doors + 1] = {
                x = tonumber(sx), y = tonumber(sy), open = door.open,
            }
        end
        table.sort(doors, function(a, b)
            if a.y ~= b.y then return a.y < b.y end
            return a.x < b.x
        end)
        return doors
    end

    local nStoreys = world.storeyCount and world:storeyCount() or 1
    map.storeys = {}
    for si = 1, nStoreys do
        local L = world.layers and world.layers[si] or {
            grid = world.grid, doors = world.doors,
        }
        local tiles = {}
        for y = 1, world.height do
            tiles[y] = {}
            for x = 1, world.width do
                tiles[y][x] = L.grid[y][x] or 0
            end
        end
        map.storeys[si] = {
            tiles = tiles,
            doors = layerDoors(L),
            spawn = L.spawn,
        }
    end
    map.tiles = map.storeys[1].tiles
    map.doors = map.storeys[1].doors

    -- Locks, push-walls and secret areas ride back out so the editor's save
    -- keeps them. Push-walls serialize at their CURRENT tile with the distance
    -- they have LEFT — a half-slid secret saves as the secret it now is.
    for si = 1, nStoreys do
        local L = world.layers and world.layers[si]
                  or { doors = world.doors, pushwalls = world.pushwalls }
        for key, door in pairs(L.doors or {}) do
            if door.lock then
                local sx, sy = key:match('^(%-?%d+),(%-?%d+)$')
                map.locks = map.locks or {}
                map.locks[#map.locks + 1] = {
                    storey = si, x = tonumber(sx), y = tonumber(sy),
                    key = door.lock,
                }
            end
        end
        for key, pw in pairs(L.pushwalls or {}) do
            if (pw.left or 0) > 0 then
                local sx, sy = key:match('^(%-?%d+),(%-?%d+)$')
                map.pushWalls = map.pushWalls or {}
                map.pushWalls[#map.pushWalls + 1] = {
                    storey = si, x = tonumber(sx), y = tonumber(sy),
                    dx = pw.dx, dy = pw.dy, distance = pw.left,
                }
            end
        end
    end
    local function sortByTile(t)
        table.sort(t, function(a, b)
            if (a.storey or 1) ~= (b.storey or 1) then
                return (a.storey or 1) < (b.storey or 1)
            end
            if a.y ~= b.y then return a.y < b.y end
            return a.x < b.x
        end)
    end
    if map.locks then sortByTile(map.locks) end
    if map.pushWalls then sortByTile(map.pushWalls) end
    if world.secrets then
        map.secrets = {}
        for i, s in ipairs(world.secrets) do
            map.secrets[i] = {
                storey = s.storey or 1, name = s.name,
                x1 = s.x1, y1 = s.y1, x2 = s.x2, y2 = s.y2,
            }
        end
    end
    if world.hazards then
        map.hazards = {}
        for i, hzd in ipairs(world.hazards) do
            map.hazards[i] = {
                kind = hzd.kind, storey = hzd.storey or 1,
                x1 = hzd.x1, y1 = hzd.y1, x2 = hzd.x2, y2 = hzd.y2,
            }
        end
    end
    if world.triggers then
        map.triggers = {}
        for i, tr in ipairs(world.triggers) do
            map.triggers[i] = {
                name = tr.name, graph = tr.graph, storey = tr.storey or 1,
                x1 = tr.x1, y1 = tr.y1, x2 = tr.x2, y2 = tr.y2,
                once = tr.once or false, filter = tr.filter or 'player',
            }
        end
    end
    -- C-map: masked walls and wall anims round-trip through layer 1 (the same
    -- layer wallHeights recovers), keyed "x,y" on the world.
    if world.masked then
        map.masked = {}
        for key, alpha in pairs(world.masked) do
            local sx, sy = key:match('^(%-?%d+),(%-?%d+)$')
            if sx then
                map.masked[#map.masked + 1] = {
                    x = tonumber(sx), y = tonumber(sy), alpha = alpha,
                }
            end
        end
        table.sort(map.masked, function(a, b)
            if a.y ~= b.y then return a.y < b.y end
            return a.x < b.x
        end)
    end
    if world.wallAnims then
        map.wallAnims = {}
        for key, anim in pairs(world.wallAnims) do
            local sx, sy = key:match('^(%-?%d+),(%-?%d+)$')
            if sx and anim.tiles then
                local tiles = {}
                for j = 1, #anim.tiles do tiles[j] = anim.tiles[j] end
                map.wallAnims[#map.wallAnims + 1] = {
                    x = tonumber(sx), y = tonumber(sy),
                    fps = anim.fps or 6, tiles = tiles,
                }
            end
        end
        table.sort(map.wallAnims, function(a, b)
            if a.y ~= b.y then return a.y < b.y end
            return a.x < b.x
        end)
    end
    if world.surfaces then
        map.surfaces = {}
        for key, material in pairs(world.surfaces) do
            local sx, sy = key:match('^(%-?%d+),(%-?%d+)$')
            if sx then
                map.surfaces[#map.surfaces + 1] =
                    { x = tonumber(sx), y = tonumber(sy), material = material }
            end
        end
        table.sort(map.surfaces, function(a, b)
            if a.y ~= b.y then return a.y < b.y end
            if a.x ~= b.x then return a.x < b.x end
            return a.material < b.material
        end)
    end
    if world.movers then
        map.movers = {}
        for i, mv in ipairs(world.movers) do
            local tiles = {}
            for j, tl in ipairs(mv.tiles or {}) do
                tiles[j] = { tx = tl.tx, ty = tl.ty }
            end
            map.movers[i] = {
                id = mv.id, zDown = mv.zDown or 0, zUp = mv.zUp or 0.4,
                speed = mv.speed or 0.35, start = mv.start or 'down', tiles = tiles,
            }
        end
    end
    if world.ambientZones then
        map.ambientZones = {}
        for i, az in ipairs(world.ambientZones) do
            map.ambientZones[i] = {
                sound = az.sound, storey = az.storey or 1,
                x1 = az.x1, y1 = az.y1, x2 = az.x2, y2 = az.y2,
            }
        end
    end

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

    for key, z in pairs(world.floorHeights or {}) do
        local sx, sy = key:match('^(%-?%d+),(%-?%d+)$')
        if sx and sy then
            map.floorHeights[#map.floorHeights + 1] = {
                x = tonumber(sx), y = tonumber(sy), z = z,
            }
        end
    end
    table.sort(map.floorHeights, function(a, b)
        if a.y ~= b.y then return a.y < b.y end
        return a.x < b.x
    end)

    for key, z in pairs(world.ceilingHeights or {}) do
        local sx, sy = key:match('^(%-?%d+),(%-?%d+)$')
        if sx and sy then
            map.ceilingHeights[#map.ceilingHeights + 1] = {
                x = tonumber(sx), y = tonumber(sy), z = z,
            }
        end
    end
    table.sort(map.ceilingHeights, function(a, b)
        if a.y ~= b.y then return a.y < b.y end
        return a.x < b.x
    end)

    if world.links then
        for dir, L in pairs(world.links) do
            map.links[dir] = {
                path = L.path, x = L.x, y = L.y, angle = L.angle,
            }
        end
    end

    for _, e in ipairs(opts.entities or {}) do
        local entry = { kind = e.kind, x = e.x, y = e.y, angle = e.angle or 0 }
        entry.char = Map.charFor(map, e.kind)
        map.entities[#map.entities + 1] = entry
    end

    return map
end

return Map
