--[[
    meatray.ui.map_triggers — the trigger-volume tool's edit logic, headless (B10).

    Split out of panel_map for the same reason map_entities was (see its header):
    ui/core.lua needs LÖVE's utf8 and cannot load under plain LuaJIT, so any
    edit logic left inside the panel is invisible to the suite — and the ways a
    trigger tool writes a wrong map are all silent. A volume with backwards
    corners that covers nothing, a name that collides with another so both fire
    the same graph node, a graph id that never got assigned: every one of them
    saves clean and breaks at play.

        local MT = require('meatray.ui.map_triggers')

        MT.place(map, x1, y1, x2, y2, { graph = 'waves' })  -- add, corners sorted
        MT.at(map, tx, ty)          -- topmost volume over a tile, + index
        MT.removeAt(map, tx, ty)    -- delete the topmost volume over a tile
        MT.setGraph(entry, 'boss')  -- bind / rebind the graph id
        MT.cycleFilter(entry)       -- player <-> any
        MT.describe(entry)          -- inspector strings
        MT.graphPalette(ids, cur)   -- rows for the sidebar picker

    A trigger is a world-space rectangle (x1,y1)-(x2,y2), the same AABB shape
    hazards and secrets already serialize. Corners are always stored sorted so
    a bottom-right-to-top-left drag means the same box as the other way.

    Names must be unique within a map: the runtime dispatches a graph's
    EventOnTrigger by the volume NAME, so two volumes sharing a name is two
    triggers firing one node — almost never what was drawn. place() auto-names
    to the first free `trigN`, and rename() refuses a name already in use.

    HEADLESS: pure Lua.
]]

local MT = {}

local floor = math.floor

-- Sorted corners: the box is the same whichever way you dragged it.
local function sortedBox(x1, y1, x2, y2)
    if x1 > x2 then x1, x2 = x2, x1 end
    if y1 > y2 then y1, y2 = y2, y1 end
    return x1, y1, x2, y2
end

-- Does world-AABB `tr` cover the centre of 1-based tile (tx,ty)? Centre-based,
-- like secrets: a volume "over a tile" is one you would stand inside on it.
local function covers(tr, tx, ty)
    local cx, cy = tx - 0.5, ty - 0.5
    return cx >= tr.x1 and cx <= tr.x2 and cy >= tr.y1 and cy <= tr.y2
end

-- The topmost volume over a tile and its index, or nil. Topmost = last in the
-- list, because that is the one drawn over the others and so the one clicked.
function MT.at(map, tx, ty, storey)
    for i = #(map.triggers or {}), 1, -1 do
        local tr = map.triggers[i]
        if (not storey or (tr.storey or 1) == storey) and covers(tr, tx, ty) then
            return tr, i
        end
    end
    return nil
end

-- The first free `trigN` name, so every placed volume starts unique.
function MT.autoName(map)
    local used = {}
    for _, tr in ipairs(map.triggers or {}) do used[tr.name] = true end
    local n = 1
    while used['trig' .. n] do n = n + 1 end
    return 'trig' .. n
end

function MT.nameTaken(map, name, except)
    for _, tr in ipairs(map.triggers or {}) do
        if tr ~= except and tr.name == name then return true end
    end
    return false
end

-- Adds a volume. Corners are sorted; opts may set name/graph/storey/once/filter.
-- An empty/colliding name is replaced with a fresh auto-name so the map never
-- ends up with two volumes the runtime cannot tell apart.
function MT.place(map, x1, y1, x2, y2, opts)
    opts = opts or {}
    map.triggers = map.triggers or {}
    x1, y1, x2, y2 = sortedBox(x1, y1, x2, y2)

    local name = opts.name
    if not name or name == '' or MT.nameTaken(map, name) then
        name = MT.autoName(map)
    end

    local filter = opts.filter
    if filter ~= 'any' then filter = 'player' end

    local entry = {
        name = name,
        graph = tostring(opts.graph or ''),
        storey = floor(tonumber(opts.storey) or 1),
        x1 = x1, y1 = y1, x2 = x2, y2 = y2,
        once = opts.once and true or false,
        filter = filter,
    }
    map.triggers[#map.triggers + 1] = entry
    return entry
end

-- Removes a specific volume. Returns true if it was there.
function MT.remove(map, entry)
    for i = #(map.triggers or {}), 1, -1 do
        if map.triggers[i] == entry then
            table.remove(map.triggers, i)
            return true
        end
    end
    return false
end

-- Removes the topmost volume over a tile. Returns the removed entry or nil.
function MT.removeAt(map, tx, ty, storey)
    local entry, i = MT.at(map, tx, ty, storey)
    if entry then table.remove(map.triggers, i) end
    return entry
end

-- Binds (or rebinds) the graph this volume fires. Any id string is allowed —
-- validity (does the graph exist, does it pass the sandbox) is the loader's
-- job, so the editor can reference a graph that ships in a not-yet-mounted pack.
function MT.setGraph(entry, graphId)
    if not entry then return nil end
    entry.graph = tostring(graphId or '')
    return entry.graph
end

-- Renames, refusing a name already used by another volume in the map (which
-- would make both fire the same node). Returns true on success.
function MT.rename(map, entry, name)
    if not entry then return false end
    name = tostring(name or '')
    if name == '' or MT.nameTaken(map, name, entry) then return false end
    entry.name = name
    return true
end

function MT.toggleOnce(entry)
    if not entry then return nil end
    entry.once = not entry.once
    return entry.once
end

-- player <-> any. 'any' fires for bots and monsters too; 'player' is the default.
function MT.cycleFilter(entry)
    if not entry then return nil end
    entry.filter = (entry.filter == 'any') and 'player' or 'any'
    return entry.filter
end

-- Inspector strings for a selected volume.
function MT.describe(entry)
    if not entry then return nil end
    local w = (entry.x2 - entry.x1)
    local h = (entry.y2 - entry.y1)
    return {
        name = tostring(entry.name),
        graph = entry.graph ~= '' and entry.graph or '(none — pick one)',
        rect = ('%.1f,%.1f  %.1fx%.1f'):format(entry.x1, entry.y1, w, h),
        storey = tostring(entry.storey or 1),
        once = entry.once and 'once' or 'repeats',
        filter = tostring(entry.filter or 'player'),
    }
end

-- Sidebar rows for the graph picker: one per available graph id, current one
-- marked. `ids` is handed in (from the pack registry / graph-file scan) rather
-- than discovered here, so a test picks the list and no love.filesystem leaks in.
function MT.graphPalette(ids, current)
    local rows = {}
    for i = 1, #(ids or {}) do
        rows[i] = { id = ids[i], selected = (ids[i] == current) }
    end
    table.sort(rows, function(a, b) return a.id < b.id end)
    return rows
end

return MT
