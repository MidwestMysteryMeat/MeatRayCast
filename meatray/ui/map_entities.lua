--[[
    meatray.ui.map_entities — the entity palette's edit logic, headless (B9).

    Pure, and split out of panel_map for the reason inventory_view was split
    out of its panel: meatray/ui/core.lua needs LOVE's utf8 and cannot load
    under plain LuaJIT, so any logic left inside a panel is invisible to the
    suite — and edit-logic failures are not crashes. An entity placed twice
    on one tile, a rotate that walks off 2π, a delete that leaves the legend
    lying: all of them boot clean and save wrong maps.

        local ME = require('meatray.ui.map_entities')

        ME.at(map, tx, ty)                 -- entry, index (topmost) or nil
        ME.place(map, tx, ty, 'imp')       -- replace-or-create, legend kept
        ME.remove(map, tx, ty)             -- how many went
        ME.rotate(entry, 1)                -- +45°, wrapped to [0, 2π)
        ME.describe(entry)                 -- inspector strings
        ME.palette(names, current)         -- rows for the sidebar buttons

    Coordinates: entries store world positions (tile centre = tile - 0.5, the
    same convention the panel has always written); tx/ty here are 1-based
    tiles, matching every other editor call.

    HEADLESS: pure Lua.
]]

local Map = require('meatray.sim.map')

local ME = {}

local floor = math.floor
local TAU = math.pi * 2

local function tileOf(e)
    return floor(e.x) + 1, floor(e.y) + 1
end

-- The topmost entry on a tile, and where it sits in the list. Topmost because
-- the panel draws last-over-first, so what you see is what you select.
function ME.at(map, tx, ty)
    for i = #(map.entities or {}), 1, -1 do
        local e = map.entities[i]
        local ex, ey = tileOf(e)
        if ex == tx and ey == ty then return e, i end
    end
    return nil
end

-- Removes every entry on the tile. Returns how many went, because a tile
-- that accumulated three imps through an old bug should say so when cleared.
function ME.remove(map, tx, ty)
    local removed = 0
    for i = #(map.entities or {}), 1, -1 do
        local e = map.entities[i]
        local ex, ey = tileOf(e)
        if ex == tx and ey == ty then
            table.remove(map.entities, i)
            removed = removed + 1
        end
    end
    return removed
end

-- Replace-or-create: one marker per tile, always. Placing the kind that is
-- already there keeps the entry (and its angle — re-stamping an imp you
-- carefully rotated must not reset it); placing a different kind replaces.
function ME.place(map, tx, ty, kind)
    kind = tostring(kind or 'imp')
    map.entities = map.entities or {}

    local existing = ME.at(map, tx, ty)
    if existing and existing.kind == kind then
        return existing, false
    end

    ME.remove(map, tx, ty)
    local entry = {
        kind = kind,
        x = tx - 0.5, y = ty - 0.5,
        angle = 0,
        char = Map.charFor(map, kind),
    }
    map.entities[#map.entities + 1] = entry
    return entry, true
end

-- Facing, in eighth turns. Wrapped to [0, 2π) so a marker rotated all the
-- way around serializes as the small number it is, not as 6.28...318.
function ME.rotate(entry, steps)
    if not entry then return nil end
    local a = (entry.angle or 0) + (steps or 1) * (math.pi / 4)
    a = a % TAU
    if a < 0 then a = a + TAU end
    entry.angle = a
    return a
end

-- Inspector strings for a selected marker.
function ME.describe(entry)
    if not entry then return nil end
    return {
        kind = tostring(entry.kind),
        pos = ('%.1f, %.1f'):format(entry.x or 0, entry.y or 0),
        angle = ('%d°'):format(floor((entry.angle or 0) / TAU * 360 + 0.5) % 360),
    }
end

-- Sidebar rows: one per registered archetype, current one marked. `names`
-- comes from Entity.archetypeNames() — handed in rather than required here,
-- so a test (or a game with its own registry) chooses the list.
function ME.palette(names, current)
    local rows = {}
    for i = 1, #(names or {}) do
        rows[i] = { kind = names[i], selected = (names[i] == current) }
    end
    table.sort(rows, function(a, b) return a.kind < b.kind end)
    return rows
end

return ME
