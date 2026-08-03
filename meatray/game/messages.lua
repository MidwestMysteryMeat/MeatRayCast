--[[
    meatray.game.messages — the engine's own way of telling the player things
    (F6).

    Doom's HUDMessage, Source's centerprint and pickup ticker: a game needs
    more than one ad-hoc log to speak to a player, and it needs the engine to
    own the timing so a killfeed, a "you got the red key", a countdown and a
    big centred "3... 2... 1... FIGHT" do not fight each other for the same
    corner. This is that, as a model — channels, priorities, fade timing —
    with nothing drawn; main.lua reads it and decides pixels, the same split
    the HUD, the console and the shell keep.

        local Messages = require('meatray.game.messages')
        local m = Messages.new()

        m:centerprint('FIGHT', { hold = 1.5, size = 'big' })
        m:pickup('picked up the red key')
        m:notify('server: map changes in 30s', { priority = 2 })
        m:kill('meat', 'grunt', 'rocket')   -- attacker, victim, cause

        m:update(dt)                         -- real time; this is presentation
        m:centered()                         -- the one centerprint, or nil
        m:ticker()                           -- pickup/notify lines, newest last
        m:killfeed()                         -- kill rows, newest first

    Three channels, because they behave differently:

      * CENTERPRINT is exclusive — one at a time, big, centre-screen. A new
        one of equal-or-higher priority replaces the current; a lower one is
        dropped, because two things shouting in the middle of the screen is
        the exact mess this prevents. It is for the moment, not the record.
      * TICKER is the running feed — pickups, objectives, server notices —
        that scroll up and fade. Many at once, oldest fading first.
      * KILLFEED is the obituary column: structured rows (who, whom, how) a
        renderer styles, kept newest-first and capped.

    Fades are real-time because messages are presentation; the caller hands in
    dt, and a paused game freezing its centerprint is the right behaviour (the
    countdown should pause too).

    HEADLESS: pure Lua.
]]

local Messages = {}
local MessagesMT = {}
MessagesMT.__index = MessagesMT

Messages.TICKER_MAX = 6
Messages.KILLFEED_MAX = 6

---------------------------------------------------------------------------
-- Construction
---------------------------------------------------------------------------

-- opts: tickerHold / killHold (seconds a line lives, default 5 / 6),
--       fade (seconds a line spends fading out, default 0.5).
function Messages.new(opts)
    opts = opts or {}
    return setmetatable({
        tickerHold = opts.tickerHold or 5,
        killHold   = opts.killHold or 6,
        fade       = opts.fade or 0.5,

        center = nil,          -- { text, size, priority, life, hold }
        tickerList = {},       -- { { text, life, hold }, ... } oldest first
        killList = {},         -- { { attacker, victim, cause, life }, ... } newest first
    }, MessagesMT)
end

---------------------------------------------------------------------------
-- Centerprint: exclusive, priority-arbitrated
---------------------------------------------------------------------------

-- opts: hold (seconds, default 2), size ('big'|'normal', default 'normal'),
--       priority (higher wins; default 1).
function MessagesMT:centerprint(text, opts)
    opts = opts or {}
    local priority = tonumber(opts.priority) or 1
    -- A lower-priority shout does not interrupt a higher one mid-display —
    -- the countdown is not shoved aside by a pickup that chose the middle of
    -- the screen by mistake.
    if self.center and priority < (self.center.priority or 1) then
        return false
    end
    local hold = tonumber(opts.hold) or 2
    self.center = {
        text = tostring(text),
        size = opts.size == 'big' and 'big' or 'normal',
        priority = priority,
        hold = hold,
        life = hold + self.fade,
    }
    return true
end

function MessagesMT:clearCenter()
    self.center = nil
end

-- The current centerprint as a draw-ready row, or nil. `alpha` is 1 while
-- held and ramps to 0 over the fade.
function MessagesMT:centered()
    local c = self.center
    if not c then return nil end
    local alpha = 1
    if c.life < self.fade then alpha = c.life / self.fade end
    return { text = c.text, size = c.size, alpha = alpha }
end

---------------------------------------------------------------------------
-- Ticker: the running feed
---------------------------------------------------------------------------

local function pushTicker(self, text)
    self.tickerList[#self.tickerList + 1] =
        { text = tostring(text), hold = self.tickerHold, life = self.tickerHold + self.fade }
    while #self.tickerList > Messages.TICKER_MAX do
        table.remove(self.tickerList, 1)
    end
end

-- A pickup line ("picked up the red key"). Same channel as notify; named
-- apart because a game reads better calling the right verb, and a renderer
-- may tint them differently via the returned kind.
function MessagesMT:pickup(text)
    pushTicker(self, text)
    self.tickerList[#self.tickerList].kind = 'pickup'
    return true
end

-- A general notice (objective, server message). opts.priority is accepted
-- for symmetry but the ticker shows everything; it only tags the row.
function MessagesMT:notify(text, opts)
    pushTicker(self, text)
    self.tickerList[#self.tickerList].kind = 'notify'
    if opts and opts.priority then
        self.tickerList[#self.tickerList].priority = opts.priority
    end
    return true
end

-- Draw-ready ticker rows, oldest first, each with its fade alpha.
function MessagesMT:ticker()
    local out = {}
    for i = 1, #self.tickerList do
        local e = self.tickerList[i]
        local alpha = 1
        if e.life < self.fade then alpha = e.life / self.fade end
        out[i] = { text = e.text, kind = e.kind, alpha = alpha }
    end
    return out
end

---------------------------------------------------------------------------
-- Killfeed: structured obituaries
---------------------------------------------------------------------------

-- attacker/victim are names (or nil); cause is a short string ('rocket',
-- 'pistol', 'lava', ...). A nil attacker reads as an environment kill.
function MessagesMT:kill(attacker, victim, cause)
    table.insert(self.killList, 1, {
        attacker = attacker and tostring(attacker) or nil,
        victim = tostring(victim),
        cause = cause and tostring(cause) or nil,
        life = self.killHold + self.fade,
    })
    while #self.killList > Messages.KILLFEED_MAX do
        table.remove(self.killList)
    end
    return true
end

-- Draw-ready kill rows, newest first, with fade alpha.
function MessagesMT:killfeed()
    local out = {}
    for i = 1, #self.killList do
        local k = self.killList[i]
        local alpha = 1
        if k.life < self.fade then alpha = k.life / self.fade end
        out[i] = { attacker = k.attacker, victim = k.victim,
                   cause = k.cause, alpha = alpha }
    end
    return out
end

---------------------------------------------------------------------------
-- The tick
---------------------------------------------------------------------------

function MessagesMT:update(dt)
    dt = math.max(0, tonumber(dt) or 0)

    if self.center then
        self.center.life = self.center.life - dt
        if self.center.life <= 0 then self.center = nil end
    end

    for i = #self.tickerList, 1, -1 do
        self.tickerList[i].life = self.tickerList[i].life - dt
        if self.tickerList[i].life <= 0 then table.remove(self.tickerList, i) end
    end

    for i = #self.killList, 1, -1 do
        self.killList[i].life = self.killList[i].life - dt
        if self.killList[i].life <= 0 then table.remove(self.killList, i) end
    end
end

function MessagesMT:clear()
    self.center = nil
    self.tickerList = {}
    self.killList = {}
end

return Messages
