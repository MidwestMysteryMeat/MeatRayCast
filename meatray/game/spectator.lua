--[[
    meatray.game.spectator — the camera when it is not your own eyes (D35).

    Two features, one state machine, because they are the same question asked
    twice: whose eyes am I looking through? Normally your own. The moment you
    die, a KILLCAM swings the view to what killed you for a beat. Then, while
    you wait to respawn (or if you joined only to watch), you SPECTATE — the
    camera rides a living player, and you cycle through them. This is that
    machine as a MODEL: it decides the mode and produces a camera pose each
    frame; nothing is drawn, the renderer reads the pose.

        local Spectator = require('meatray.game.spectator')
        local spec = Spectator.new{ killcamTime = 2.5 }

        -- the local player just died, killed from (kx,ky):
        spec:onDeath(self.x, self.y, kx, ky, killerEntity)

        -- next / previous living player to watch:
        spec:cycle(entities, 1, self)

        spec:update(dt, entities, self)   -- advances, drops dead targets
        local cam = spec:camera(self)     -- { x, y, angle, mode } or nil (own eyes)

    Modes:
      * 'eyes'      not spectating; camera() returns nil so the caller uses the
                    player's own view. The resting state.
      * 'killcam'   a timed shot looking from where you fell toward what killed
                    you. It expires into 'spectate' (if anyone is alive to
                    watch) or back to 'eyes'.
      * 'spectate'  first-person on a chosen living player; cycle moves the
                    choice. A target that dies is dropped and the next picked,
                    so the view never sits on a corpse.

    Reviving (onRevive) drops straight back to 'eyes' — you have your own body
    again, so you look through it.

    HEADLESS: pure Lua. The caller hands in dt and the entity list.
]]

local Spectator = {}
local SpectatorMT = {}
SpectatorMT.__index = SpectatorMT

local atan2 = math.atan2 or math.atan

---------------------------------------------------------------------------
-- Construction
---------------------------------------------------------------------------

-- opts.killcamTime: seconds the death-cam holds (default 2.5).
function Spectator.new(opts)
    opts = opts or {}
    return setmetatable({
        killcamTime = tonumber(opts.killcamTime) or 2.5,
        mode = 'eyes',
        killcam = nil,         -- { fromX, fromY, atX, atY, killer, left }
        target = nil,          -- the entity being spectated
    }, SpectatorMT)
end

---------------------------------------------------------------------------
-- Living players to watch
---------------------------------------------------------------------------

local function isLivePlayer(e, exclude)
    return e and e ~= exclude and not e.dead
       and e.components and e.components.player
end

-- Every living player except `self`, in id order so cycling is stable.
function SpectatorMT:targets(entities, selfEnt)
    local out = {}
    for i = 1, #(entities or {}) do
        if isLivePlayer(entities[i], selfEnt) then out[#out + 1] = entities[i] end
    end
    table.sort(out, function(a, b) return (a.id or 0) < (b.id or 0) end)
    return out
end

---------------------------------------------------------------------------
-- Death, killcam, revive
---------------------------------------------------------------------------

-- You died at (fromX,fromY), killed from (atX,atY). killer is the attacker
-- entity if known (so the cam can follow it if it moves), else nil.
function SpectatorMT:onDeath(fromX, fromY, atX, atY, killer)
    self.mode = 'killcam'
    self.killcam = {
        fromX = fromX, fromY = fromY,
        atX = atX or fromX, atY = atY or fromY,
        killer = killer,
        left = self.killcamTime,
    }
end

-- You have a body again.
function SpectatorMT:onRevive()
    self.mode = 'eyes'
    self.killcam = nil
    self.target = nil
end

function SpectatorMT:mode_() return self.mode end
function SpectatorMT:isSpectating() return self.mode ~= 'eyes' end

---------------------------------------------------------------------------
-- Cycling the spectated target
---------------------------------------------------------------------------

-- Moves to the next (dir=1) or previous (dir=-1) living player. Entering
-- spectate from any mode. Returns the new target, or nil if nobody is alive.
function SpectatorMT:cycle(entities, dir, selfEnt)
    local list = self:targets(entities, selfEnt)
    if #list == 0 then
        self.mode = 'eyes'
        self.target = nil
        return nil
    end
    dir = (dir or 1) >= 0 and 1 or -1

    local at = 0
    for i = 1, #list do if list[i] == self.target then at = i break end end
    local nextAt = ((at - 1 + dir) % #list) + 1
    if at == 0 then nextAt = (dir == 1) and 1 or #list end

    self.mode = 'spectate'
    self.killcam = nil
    self.target = list[nextAt]
    return self.target
end

---------------------------------------------------------------------------
-- The tick
---------------------------------------------------------------------------

function SpectatorMT:update(dt, entities, selfEnt)
    dt = math.max(0, tonumber(dt) or 0)

    if self.mode == 'killcam' then
        self.killcam.left = self.killcam.left - dt
        -- Follow a moving killer so the shot stays on them.
        if self.killcam.killer and not self.killcam.killer.dead then
            self.killcam.atX = self.killcam.killer.x
            self.killcam.atY = self.killcam.killer.y
        end
        if self.killcam.left <= 0 then
            -- Expire into spectate if there is anyone to watch, else eyes.
            if self:cycle(entities, 1, selfEnt) == nil then
                self.mode = 'eyes'
            end
        end
        return
    end

    if self.mode == 'spectate' then
        -- A target that died (or left) is dropped; move to the next living one.
        if not self.target or self.target.dead then
            if self:cycle(entities, 1, selfEnt) == nil then
                self.mode = 'eyes'
            end
        end
    end
end

---------------------------------------------------------------------------
-- The camera pose
---------------------------------------------------------------------------

-- The pose to render from right now, or nil to use the player's own eyes.
--   killcam:   positioned a little back from where you fell, looking at the
--              killer — the classic "who got me" shot.
--   spectate:  first-person on the target: its position and facing.
function SpectatorMT:camera(selfEnt)
    if self.mode == 'killcam' and self.killcam then
        local k = self.killcam
        local ang = atan2(k.atY - k.fromY, k.atX - k.fromX)
        -- Sit slightly behind the fall point along the line to the killer, so
        -- the corpse's spot and the killer are both in frame.
        local back = 1.5
        return {
            x = k.fromX - math.cos(ang) * back,
            y = k.fromY - math.sin(ang) * back,
            angle = ang,
            mode = 'killcam',
            timeLeft = k.left,
        }
    end

    if self.mode == 'spectate' and self.target and not self.target.dead then
        return {
            x = self.target.x, y = self.target.y,
            angle = self.target.angle or 0,
            storey = self.target.storey or 1,
            mode = 'spectate',
            targetName = self.target.components
                         and self.target.components.player
                         and self.target.components.player.name or nil,
        }
    end

    return nil
end

return Spectator
