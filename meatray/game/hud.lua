--[[
    meatray.game.hud — the HUD as a model, not a draw call (Wave A4).

    Health, armour and ammo readouts, the damage flash, the heal glow, the hit
    marker, directional damage indicators and the low-health pulse — all as
    numbers a renderer reads, with nothing about how they look decided here.

        local Hud = require('meatray.game.hud')
        local hud = Hud.new()

        -- once per frame, with whatever the game knows about its player:
        hud:update(dt, {
            hp = 62, hpMax = 100,
            armour = 20, armourMax = 50,        -- optional
            weapon = Weapons.status(player),    -- optional, taken as-is
            carried = 34,                       -- reserve ammo, optional
        })

        -- when the game knows WHERE a hit came from:
        hud:damageFrom(srcX, srcY, px, py, pangle)

        -- when the host confirms the player's own shot landed:
        hud:hitConfirmed()

        -- drawing reads, it never writes:
        hud:flashStrength()      -- 0..1, red overlay
        hud:healStrength()       -- 0..1, green overlay
        hud:hitStrength()        -- 0..1, hit marker
        hud:indicators()         -- { {angle=rel radians, strength=0..1}, ... }
        hud:isLowHealth()        -- boolean
        hud:lowPulse(time)       -- 0..1, throb while low
        hud:bars()               -- draw-ready hp / armour / weapon rows

    The flash needs no wiring: `update` watches hp and armour and treats any
    drop as damage, any hp rise as healing. That is deliberate — damage reaches
    a player through weapons, explosions, gas, poison ticks and falling rubble,
    and a HUD that needed a hook in each of those would always be missing one.
    A drop in the pool IS the event. `damageFrom` exists for the one thing a
    delta cannot carry: direction.

    On a client the deltas arrive through snapshots, so the flash works there
    unmodified — which is the point of watching state instead of tapping the
    damage path, because the damage path only runs on the host.

    HEADLESS: pure Lua. No love.*, no clock — callers hand in dt and time.
]]

local Hud = {}
local HudMT = {}
HudMT.__index = HudMT

local max, min, floor = math.max, math.min, math.floor
local atan2 = math.atan2 or math.atan
local pi = math.pi

local function clamp01(v)
    if v < 0 then return 0 end
    if v > 1 then return 1 end
    return v
end

-- Relative bearing in (-pi, pi]: 0 is dead ahead, positive is to the left in
-- the engine's angle convention. The renderer decides what left looks like.
local function relativeAngle(sx, sy, px, py, pangle)
    local a = atan2(sy - py, sx - px) - (pangle or 0)
    while a > pi do a = a - 2 * pi end
    while a <= -pi do a = a + 2 * pi end
    return a
end

---------------------------------------------------------------------------
-- Construction
---------------------------------------------------------------------------

-- opts (all optional, all seconds unless noted):
--   flashTime      how long a full-strength damage flash takes to fade
--   healTime       same, for the heal glow
--   hitTime        same, for the hit marker
--   indicatorTime  how long a direction indicator lives
--   flashScale     the fraction of max hp lost in one frame that produces a
--                  full-strength flash. 0.35 means losing a third of your
--                  health at once saturates the overlay; chip damage does not.
--   lowHealth      fraction of max hp at or below which isLowHealth reports
--   lowPulseRate   throbs per second while low
function Hud.new(opts)
    opts = opts or {}
    return setmetatable({
        flashTime     = opts.flashTime or 0.45,
        healTime      = opts.healTime or 0.35,
        hitTime       = opts.hitTime or 0.22,
        indicatorTime = opts.indicatorTime or 1.2,
        flashScale    = opts.flashScale or 0.35,
        lowHealth     = opts.lowHealth or 0.3,
        lowPulseRate  = opts.lowPulseRate or 1.6,

        flash = 0,          -- 0..1, decays linearly over flashTime
        heal  = 0,
        hit   = 0,
        indicatorList = {}, -- { {angle=, life=} }, newest last

        -- nil until the first update: the first snapshot is a baseline, not a
        -- wound. Loading a save at 40 hp must not open on a red screen.
        lastHp = nil,
        lastArmour = nil,

        snapshot = {},      -- the last thing update was handed, verbatim
    }, HudMT)
end

---------------------------------------------------------------------------
-- The frame
---------------------------------------------------------------------------

-- state: { hp, hpMax, armour, armourMax, weapon, carried } — every field
-- optional; absent means "the game does not track this" and the readout for it
-- goes away rather than showing zero.
function HudMT:update(dt, state)
    dt = dt or 0
    state = state or {}
    self.snapshot = state

    local hp = tonumber(state.hp)
    local hpMax = max(1, tonumber(state.hpMax) or 1)
    local armour = tonumber(state.armour)

    if hp and self.lastHp then
        local lost = self.lastHp - hp
        if lost > 0 then
            -- Armour losses join the same flash: being hit is being hit,
            -- whichever pool paid for it. Soaked damage flashes at half
            -- weight so a full suit still reads softer than bare skin.
            self.flash = clamp01(self.flash + lost / (hpMax * self.flashScale))
        elseif lost < 0 then
            self.heal = clamp01(self.heal + (-lost) / (hpMax * self.flashScale))
        end
    end
    if armour and self.lastArmour and self.lastArmour > armour then
        local soaked = self.lastArmour - armour
        self.flash = clamp01(self.flash + soaked / (hpMax * self.flashScale) * 0.5)
    end
    self.lastHp = hp or self.lastHp
    self.lastArmour = armour or self.lastArmour

    if self.flash > 0 then self.flash = max(0, self.flash - dt / self.flashTime) end
    if self.heal > 0 then self.heal = max(0, self.heal - dt / self.healTime) end
    if self.hit > 0 then self.hit = max(0, self.hit - dt / self.hitTime) end

    local list = self.indicatorList
    for i = #list, 1, -1 do
        list[i].life = list[i].life - dt
        if list[i].life <= 0 then table.remove(list, i) end
    end
end

-- Registers where a hit came from, in world space. Call it when the source is
-- known (projectile impact, hitscan attacker, explosion centre); the flash
-- itself does not depend on it.
function HudMT:damageFrom(sx, sy, px, py, pangle)
    sx, sy, px, py = tonumber(sx), tonumber(sy), tonumber(px), tonumber(py)
    if not (sx and sy and px and py) then return nil end
    local entry = {
        angle = relativeAngle(sx, sy, px, py, tonumber(pangle) or 0),
        life = self.indicatorTime,
    }
    local list = self.indicatorList
    list[#list + 1] = entry
    -- Eight is already an unreadable screen; past that the oldest goes.
    if #list > 8 then table.remove(list, 1) end
    return entry
end

-- The player's own shot connected. Strength stacks a little so a shotgun's
-- pellets read as one heavy tick, not eight resets.
function HudMT:hitConfirmed()
    self.hit = clamp01(self.hit + 0.6)
    return self.hit
end

---------------------------------------------------------------------------
-- Reads
---------------------------------------------------------------------------

function HudMT:flashStrength() return self.flash end
function HudMT:healStrength() return self.heal end
function HudMT:hitStrength() return self.hit end

function HudMT:indicators()
    local out = {}
    for i = 1, #self.indicatorList do
        local e = self.indicatorList[i]
        out[i] = { angle = e.angle, strength = clamp01(e.life / self.indicatorTime) }
    end
    return out
end

function HudMT:isLowHealth()
    local hp = tonumber(self.snapshot.hp)
    local hpMax = tonumber(self.snapshot.hpMax)
    if not hp or not hpMax or hpMax <= 0 then return false end
    return hp > 0 and hp / hpMax <= self.lowHealth
end

-- 0..1 throb, driven by whatever clock the caller keeps. Zero when healthy so
-- a renderer can multiply by it unconditionally.
function HudMT:lowPulse(time)
    if not self:isLowHealth() then return 0 end
    local t = (tonumber(time) or 0) * self.lowPulseRate * 2 * pi
    return 0.5 + 0.5 * math.sin(t)
end

-- Draw-ready rows. Each is nil when the game never supplied the numbers, so a
-- renderer shows nothing rather than an empty gauge.
--
--   hp     = { value, max, fraction }
--   armour = { value, max, fraction }        max may be nil (fraction is too)
--   weapon = { id, ammo, magazine, carried, reloading, reloadFraction, empty }
function HudMT:bars()
    local s = self.snapshot
    local out = {}

    local hp = tonumber(s.hp)
    if hp then
        local hpMax = max(1, tonumber(s.hpMax) or 1)
        out.hp = { value = floor(hp + 0.5), max = hpMax,
                   fraction = clamp01(hp / hpMax) }
    end

    local armour = tonumber(s.armour)
    if armour then
        local amax = tonumber(s.armourMax)
        out.armour = { value = floor(armour + 0.5), max = amax,
                       fraction = amax and amax > 0 and clamp01(armour / amax) or nil }
    end

    local w = s.weapon
    if w then
        local reloadFraction = nil
        if w.reloading and (w.reloadTotal or 0) > 0 then
            reloadFraction = clamp01(1 - (w.reloadRemaining or 0) / w.reloadTotal)
        end
        out.weapon = {
            id = w.id,
            ammo = w.ammo or 0,
            magazine = w.magazine,
            carried = tonumber(s.carried),
            reloading = w.reloading or false,
            reloadFraction = reloadFraction,
            empty = w.empty or false,
        }
    end

    return out
end

return Hud
