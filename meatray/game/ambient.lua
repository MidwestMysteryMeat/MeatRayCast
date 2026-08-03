--[[
    meatray.game.ambient — room tone by region (C31).

    A cave drips, a reactor hums, a chapel rings with quiet. Ambient zones are the
    rectangles that say which of those you are standing in, so the game can fade
    the right loop under the action. This is the model that answers "which zone am
    I in now, and did it just change" — it plays no audio, exactly like footsteps
    (C30) name a material without owning its splash.

        local Ambient = require('meatray.game.ambient')
        local amb = Ambient.new(world.ambientZones)

        -- each frame, at the listener's position:
        local t = amb:update(px, py, storey)
        if t.changed then
            crossfadeAmbient(t.sound)   -- t.sound is nil when you step outside all zones
        end

    A zone is { sound, x1, y1, x2, y2, storey }. When zones overlap the SMALLEST
    wins — an alcove inside a hall is the room you are actually in — so nesting a
    tight zone inside a broad one does what an author expects. `update` reports a
    change only when the active sound id differs from the last, so a caller
    crossfades on transitions and does nothing while you stay put.

    Deterministic: position in, zone out. No clock, no rng.

    HEADLESS: pure Lua. The room tones are the game's content; this is the map.
]]

local Ambient = {}
local AmbientMT = {}
AmbientMT.__index = AmbientMT

local function area(z)
    return math.abs((z.x2 - z.x1) * (z.y2 - z.y1))
end

local function covers(z, x, y, storey)
    if (z.storey or 1) ~= (storey or 1) then return false end
    return x >= z.x1 and x <= z.x2 and y >= z.y1 and y <= z.y2
end

-- The zone a point is in, smallest-area first when they overlap, or nil. Static:
-- no state, so a UI or a test can ask about any point.
function Ambient.activeAt(zones, x, y, storey)
    local best, bestArea = nil, math.huge
    for i = 1, #(zones or {}) do
        local z = zones[i]
        if covers(z, x, y, storey) then
            local a = area(z)
            if a < bestArea then best, bestArea = z, a end
        end
    end
    return best
end

---------------------------------------------------------------------------
-- Stateful tracker
---------------------------------------------------------------------------

function Ambient.new(zones)
    return setmetatable({
        zones = zones or {},
        current = nil,        -- the sound id currently active (nil = outside all)
    }, AmbientMT)
end

-- Move the listener. Returns { zone, sound, changed } — `changed` true only on
-- the frame the active sound id differs from the last one reported.
function AmbientMT:update(x, y, storey)
    local zone = Ambient.activeAt(self.zones, x, y, storey)
    local sound = zone and zone.sound or nil
    local changed = (sound ~= self.current)
    self.current = sound
    return { zone = zone, sound = sound, changed = changed }
end

-- The sound id active right now (nil outside all zones).
function AmbientMT:currentSound() return self.current end

-- Replace the zone set (a map change) and forget the current zone, so the next
-- update reports a change into whatever the new map puts the listener in.
function AmbientMT:setZones(zones)
    self.zones = zones or {}
    self.current = nil
    return self
end

return Ambient
