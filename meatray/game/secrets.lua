--[[
    meatray.game.secrets — secret areas, key doors, and the count that ends up
    on the intermission screen (Wave A6).

        local Secrets = require('meatray.game.secrets')
        local s = Secrets.new{ onFound = function(area, e) note(...) end }
        s:fromWorld(world)              -- pulls the areas map headers declared
        s:addArea{ x1=, y1=, x2=, y2=, storey=, name= }   -- or by hand

        -- host, once per tick after movement:
        s:update(entities)

        s:found()    -- how many discovered
        s:total()    -- how many exist
        s:percent()  -- 0..100, the classic end-of-level stat

        -- key doors — the game-layer half of world:lockDoor:
        local opened, why, keyId = Secrets.tryDoor(world, player, tx, ty)

    A secret is found when a living player entity stands inside its box. The
    box, not the push-wall in front of it: the wall is HOW you get in, the
    room is what you found, and counting the room means a secret opened by a
    grenade (or a future second entrance) still counts.

    tryDoor is where lock meets inventory. The world stores which key a door
    wants as plain data — the sim does not know what an inventory is — and
    this module asks meatray.game.inventory whether the opener holds it.
    Keys are not consumed: a key.red opens every red door on the map, which
    is the classic contract, and a game that wants consumable passes can set
    opts.consume.

    HEADLESS: pure Lua.
]]

local Inventory = require('meatray.game.inventory')

local Secrets = {}
local SecretsMT = {}
SecretsMT.__index = SecretsMT

---------------------------------------------------------------------------
-- Construction
---------------------------------------------------------------------------

-- opts:
--   onFound   function(area, entity) fired once per area, on discovery
function Secrets.new(opts)
    opts = opts or {}
    return setmetatable({
        onFound = opts.onFound,
        areas = {},          -- { x1,y1,x2,y2, storey, name, found, foundBy }
    }, SecretsMT)
end

-- Registers one secret box. Corner order is normalised, so an editor drag in
-- any direction is a valid box.
function SecretsMT:addArea(a)
    a = a or {}
    local x1, y1 = tonumber(a.x1), tonumber(a.y1)
    local x2, y2 = tonumber(a.x2), tonumber(a.y2)
    if not (x1 and y1 and x2 and y2) then
        return nil, 'secret area needs x1 y1 x2 y2'
    end
    if x2 < x1 then x1, x2 = x2, x1 end
    if y2 < y1 then y1, y2 = y2, y1 end
    local area = {
        x1 = x1, y1 = y1, x2 = x2, y2 = y2,
        storey = a.storey or 1,
        name = a.name,
        found = false, foundBy = nil,
    }
    self.areas[#self.areas + 1] = area
    return area
end

-- Adopts every area a world carries (map `secret` headers put them there).
function SecretsMT:fromWorld(world)
    local n = 0
    for _, s in ipairs((world and world.secrets) or {}) do
        if self:addArea(s) then n = n + 1 end
    end
    return n
end

---------------------------------------------------------------------------
-- Discovery
---------------------------------------------------------------------------

local function isPlayer(e)
    return e and not e.dead and e.components and e.components.player
end

local function inside(area, e)
    if (e.storey or 1) ~= area.storey then return false end
    local x, y = e.x, e.y
    return x and y and x >= area.x1 and x <= area.x2
                   and y >= area.y1 and y <= area.y2
end

-- Marks any unfound area a living player stands inside. Call it on the host
-- after movement; the per-tick cost is areas × players, and both are small.
function SecretsMT:update(entities)
    local newlyFound = 0
    for i = 1, #self.areas do
        local area = self.areas[i]
        if not area.found then
            for j = 1, #(entities or {}) do
                local e = entities[j]
                if isPlayer(e) and inside(area, e) then
                    area.found = true
                    area.foundBy = e.id
                    newlyFound = newlyFound + 1
                    if self.onFound then self.onFound(area, e) end
                    break
                end
            end
        end
    end
    return newlyFound
end

function SecretsMT:found()
    local n = 0
    for i = 1, #self.areas do
        if self.areas[i].found then n = n + 1 end
    end
    return n
end

function SecretsMT:total()
    return #self.areas
end

-- The end-of-level number. A map with no secrets reports 100, not a division
-- by zero: you found all of nothing.
function SecretsMT:percent()
    local total = self:total()
    if total == 0 then return 100 end
    return math.floor(self:found() / total * 100 + 0.5)
end

---------------------------------------------------------------------------
-- Save / restore. Discovery is progress, so it belongs in the save.
---------------------------------------------------------------------------

function SecretsMT:capture()
    local out = {}
    for i = 1, #self.areas do
        local a = self.areas[i]
        out[i] = a.found and { found = true, foundBy = a.foundBy } or {}
    end
    return out
end

function SecretsMT:restore(captured)
    for i = 1, #self.areas do
        local c = captured and captured[i]
        self.areas[i].found = (c and c.found) and true or false
        self.areas[i].foundBy = c and c.foundBy or nil
    end
    return self
end

---------------------------------------------------------------------------
-- Key doors
---------------------------------------------------------------------------

-- The one call a game makes when someone uses a door. Unlocked doors just
-- toggle. Locked doors open — permanently unlocking — when the opener holds
-- the key item, and refuse with ('locked', keyId) when they do not, which is
-- exactly what a HUD needs to say "you need the red key".
--
-- opts.consume: spend one key on a successful unlock (off by default).
function Secrets.tryDoor(world, opener, tx, ty, storey, opts)
    storey = storey or 1
    local door = world and world:doorAt(tx, ty, storey)
    if not door then return false, 'no door' end

    local keyId = door.lock
    if keyId and not door.open then
        local held = opener and (Inventory.count(opener, keyId) or 0) or 0
        if held < 1 then
            return false, 'locked', keyId
        end
        world:unlockDoor(tx, ty, storey)
        if opts and opts.consume then
            Inventory.remove(opener, keyId, 1)
        end
        local ok = world:toggleDoor(tx, ty, storey)
        return ok and true or false, 'unlocked', keyId
    end

    local ok, why = world:toggleDoor(tx, ty, storey)
    return ok and true or false, why
end

return Secrets
