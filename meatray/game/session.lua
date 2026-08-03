--[[
    meatray.game.session — is the game running, paused, or over, and who is
    allowed to decide (Wave A8).

        local Session = require('meatray.game.session')
        local s = Session.new{ role = 'solo' }

        -- the game loop asks for its simulation time, every frame:
        local step = s:simDelta(dt)     -- dt normally, 0 while paused
        if step > 0 then clock:advance(step, simulate) end

        -- the pause key asks, rather than assumes:
        local ok, why = s:togglePause('menu')
        if not ok then note(why) end    -- "you cannot pause an online game"

        -- the net layer reports what happened to us:
        s:disconnected('the server closed the connection')
        s:isOver()                      -- true; the UI shows s:reason()

    Two things that look separate and are not.

    PAUSING is a question about authority, not about menus. On a solo game
    stopping time is free. Online it is not yours to stop: the host keeps
    simulating whether or not your window has a menu over it, so a client that
    "paused" would only be lying to its owner while it drifted out of sync.
    That is why this is a policy object and not a boolean — the answer depends
    on the role, and the caller is told WHY it was refused so it can say so.

    DISCONNECTING is the same question answered by the other side: the session
    ends, we did not choose it, and something has to say so out loud. A game
    that silently drops back to an empty world when the host quits is the
    reason people file bugs about "it just closed".

    Role is settable because one process moves between all three: a demo starts
    solo, hosts, and later joins someone else.

    HEADLESS: pure Lua, no clock of its own — the caller hands in dt.
]]

local Session = {}
local SessionMT = {}
SessionMT.__index = SessionMT

Session.ROLES = { solo = true, host = true, client = true }

-- Why a session ended. The distinction that matters to a player is whether
-- they chose it: 'quit' is a decision, everything else is an interruption.
Session.END_REASONS = {
    quit = 'quit', kicked = 'kicked', rejected = 'rejected',
    timeout = 'timeout', failed = 'failed', lost = 'lost',
}

---------------------------------------------------------------------------
-- Construction
---------------------------------------------------------------------------

-- opts:
--   role            'solo' (default) | 'host' | 'client'
--   allowHostPause  may a host stop the world for everyone? Default false.
--                   Off is the safe default: a host who pauses has frozen
--                   every other player's game, and most games would rather
--                   the host's menu simply not do that.
--   onPause / onResume / onEnd   optional callbacks
function Session.new(opts)
    opts = opts or {}
    local role = tostring(opts.role or 'solo')
    if not Session.ROLES[role] then role = 'solo' end

    return setmetatable({
        role = role,
        allowHostPause = opts.allowHostPause and true or false,

        paused = false,
        pauseReason = nil,      -- 'menu', 'focus', whatever the caller passed
        menu = false,           -- open menus are LOCAL and independent of pause
        over = false,
        endReason = nil,        -- human-readable sentence
        endKind = nil,          -- one of Session.END_REASONS

        onPause = opts.onPause,
        onResume = opts.onResume,
        onEnd = opts.onEnd,
    }, SessionMT)
end

-- Changes role mid-session: solo → host when someone starts a server, host or
-- client → solo when the session ends. A role that can no longer justify a
-- pause drops it rather than leaving the world frozen — going online with the
-- game paused would otherwise stop the local clock forever.
function SessionMT:setRole(role)
    role = tostring(role or 'solo')
    if not Session.ROLES[role] then return nil, 'unknown role' end
    self.role = role
    if self.paused and not self:mayPause() then
        self:resume('role changed')
    end
    return role
end

---------------------------------------------------------------------------
-- Pause policy
---------------------------------------------------------------------------

-- May this session stop time right now, and if not, why not — phrased for a
-- player rather than for a log.
function SessionMT:mayPause()
    if self.over then return false, 'the session is over' end
    if self.role == 'solo' then return true end
    if self.role == 'host' then
        if self.allowHostPause then return true end
        return false, 'pausing would freeze everyone else'
    end
    return false, 'you cannot pause an online game'
end

function SessionMT:pause(reason)
    local may, why = self:mayPause()
    if not may then return nil, why end
    if self.paused then return true end
    self.paused = true
    self.pauseReason = reason or 'paused'
    if self.onPause then self.onPause(self, self.pauseReason) end
    return true
end

function SessionMT:resume(reason)
    if not self.paused then return true end
    self.paused = false
    local was = self.pauseReason
    self.pauseReason = nil
    if self.onResume then self.onResume(self, reason or was) end
    return true
end

function SessionMT:togglePause(reason)
    if self.paused then return self:resume(reason) end
    return self:pause(reason)
end

function SessionMT:isPaused()
    return self.paused and not self.over
end

function SessionMT:reason()
    if self.over then return self.endReason end
    return self.pauseReason
end

---------------------------------------------------------------------------
-- Menus
--
-- Opening a menu and stopping time are the same gesture on a solo game and
-- two different ones online, which is exactly why they are two calls. The
-- menu always opens; the pause is attempted and may be refused.
---------------------------------------------------------------------------

function SessionMT:openMenu(reason)
    if self.over then return nil, 'the session is over' end
    self.menu = true
    local paused, why = self:pause(reason or 'menu')
    return true, (not paused) and why or nil
end

function SessionMT:closeMenu()
    self.menu = false
    if self.paused and self.pauseReason == 'menu' then
        self:resume('menu closed')
    end
    return true
end

function SessionMT:toggleMenu(reason)
    if self.menu then return self:closeMenu() end
    return self:openMenu(reason)
end

function SessionMT:menuOpen()
    return self.menu and not self.over
end

---------------------------------------------------------------------------
-- The one call the game loop makes
---------------------------------------------------------------------------

-- Simulation time for this frame: dt normally, 0 while paused or over. A
-- paused game still renders, still fades its decals and still animates its
-- menu — those run on real time, which is why this gates only the step handed
-- to the fixed clock and not the frame.
function SessionMT:simDelta(dt)
    dt = tonumber(dt) or 0
    if dt < 0 or dt ~= dt then return 0 end
    if self.paused or self.over then return 0 end
    return dt
end

---------------------------------------------------------------------------
-- Ending
---------------------------------------------------------------------------

--[[
    The session is over. `kind` is one of Session.END_REASONS and decides
    whether this reads as a decision or an interruption; `text` is the sentence
    a player sees.

    Ending is one-way and the FIRST reason wins. A disconnect usually arrives
    as a cascade — the transport times out, then reports a disconnect, then the
    state machine gives up — and the useful sentence is the first one, not the
    last and vaguest one.
]]
function SessionMT:endSession(kind, text)
    if self.over then return false, self.endReason end
    self.over = true
    self.endKind = Session.END_REASONS[tostring(kind or '')] or 'lost'
    self.endReason = text or kind or 'the session ended'
    self.paused = false
    self.pauseReason = nil
    self.menu = false
    if self.onEnd then self.onEnd(self, self.endKind, self.endReason) end
    return true
end

-- Convenience for the net layer: everything that is not our own quit.
function SessionMT:disconnected(text, kind)
    return self:endSession(kind or 'lost', text or 'disconnected')
end

function SessionMT:quit(text)
    return self:endSession('quit', text or 'left the game')
end

function SessionMT:isOver()
    return self.over
end

-- Did the player choose this ending? A UI shows "disconnected: <why>" for
-- false and simply returns to the menu for true.
function SessionMT:endedByChoice()
    return self.over and self.endKind == 'quit'
end

function SessionMT:endKindOf()
    return self.endKind
end

-- Back to a fresh solo session, keeping the policy this one was built with.
-- The demo calls it when a disconnected player loads a level again.
function SessionMT:restart(role)
    self.paused = false
    self.pauseReason = nil
    self.menu = false
    self.over = false
    self.endReason = nil
    self.endKind = nil
    if role then self:setRole(role) end
    return self
end

---------------------------------------------------------------------------
-- Status, for a HUD that wants one line
---------------------------------------------------------------------------

function SessionMT:status()
    if self.over then
        return {
            state = 'over', role = self.role,
            kind = self.endKind, reason = self.endReason,
            byChoice = self:endedByChoice(),
        }
    end
    return {
        state = self.paused and 'paused' or 'running',
        role = self.role,
        reason = self.pauseReason,
        menu = self.menu,
    }
end

return Session
