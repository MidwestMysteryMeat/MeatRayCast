--[[
    meatray.game.intermission — the end-of-level tally (F4).

    Wolfenstein taught everyone the shape: the level ends, the numbers roll
    up one line at a time, and pressing fire hurries them. This is that
    screen as a MODEL — rows, reveal timing, formatted text — with nothing
    drawn, the same split as the HUD, the console and the options menu.

        local Intermission = require('meatray.game.intermission')
        local im = Intermission.new()

        im:begin{
            title = 'The Arena',
            result = 'win',
            next_ = 'Tower',
            stats = {
                elapsed = 143.2, parTime = 180,
                kills = 12, killsTotal = 15,
                secrets = 1, secretsTotal = 3,
                coverage = 0.62,
                deaths = 0,
            },
        }

        im:update(dt)              -- real time; the reveal is presentation
        for _, row in ipairs(im:rows()) do draw(row.label, row.text) end
        im:confirm()               -- fire: first hurries, then continues
        if im:continued() then campaign:advance() end

    Numbers COUNT UP during the reveal because that is the difference
    between a stats screen and a receipt: the roll gives each line a beat
    of attention, and a player who does not care presses fire once to slam
    everything to its final value and once more to leave. Two presses,
    always: the first is never allowed to also continue, because eating a
    "skip" as a "leave" loses the screen the player asked to see faster.

    Rows appear only for stats that were handed in. A map with no secrets
    produces no secrets row rather than a mocking 0/0.

    HEADLESS: pure Lua. The caller hands in dt.
]]

local Intermission = {}
local IntermissionMT = {}
IntermissionMT.__index = IntermissionMT

-- Seconds each row spends rolling from zero to its value.
Intermission.ROW_TIME = 0.6

---------------------------------------------------------------------------
-- Formatting
---------------------------------------------------------------------------

local floor = math.floor

local function mmss(seconds)
    seconds = math.max(0, floor((tonumber(seconds) or 0) + 0.5))
    return ('%d:%02d'):format(floor(seconds / 60), seconds % 60)
end
Intermission.mmss = mmss

---------------------------------------------------------------------------
-- Construction
---------------------------------------------------------------------------

function Intermission.new(opts)
    opts = opts or {}
    return setmetatable({
        rowTime = opts.rowTime or Intermission.ROW_TIME,
        state = 'idle',        -- idle | tallying | ready | continued
        title = nil,
        result = nil,
        next_ = nil,
        rowDefs = {},          -- { label=, value=, text(fraction)-> }
        clock = 0,
    }, IntermissionMT)
end

---------------------------------------------------------------------------
-- Begin: turn one mission's numbers into rows
---------------------------------------------------------------------------

-- info: { title, result ('win'|'lose'), next_, stats = {
--   elapsed, parTime, kills, killsTotal, secrets, secretsTotal,
--   coverage (0..1), deaths } } — every stat optional.
function IntermissionMT:begin(info)
    info = info or {}
    local s = info.stats or {}
    self.title = info.title
    self.result = info.result or 'win'
    self.next_ = info.next_
    self.clock = 0
    self.state = 'tallying'
    self.rowDefs = {}

    local function row(label, value, fmt)
        self.rowDefs[#self.rowDefs + 1] = { label = label, value = value, fmt = fmt }
    end

    if s.elapsed ~= nil then
        local par = tonumber(s.parTime)
        row('time', s.elapsed, function(v)
            local text = mmss(v)
            if par and par > 0 then
                text = text .. ('  (par %s)'):format(mmss(par))
            end
            return text
        end)
    end
    if s.kills ~= nil then
        local total = tonumber(s.killsTotal)
        row('kills', s.kills, function(v)
            local n = floor(v + 0.5)
            if total and total > 0 then
                return ('%d / %d'):format(n, total)
            end
            return tostring(n)
        end)
    end
    if s.secrets ~= nil and (tonumber(s.secretsTotal) or 0) > 0 then
        local total = tonumber(s.secretsTotal)
        row('secrets', s.secrets, function(v)
            local n = floor(v + 0.5)
            return ('%d / %d  (%d%%)'):format(n, total,
                floor(n / total * 100 + 0.5))
        end)
    end
    if s.coverage ~= nil then
        row('explored', (tonumber(s.coverage) or 0) * 100, function(v)
            return ('%d%%'):format(floor(v + 0.5))
        end)
    end
    if (tonumber(s.deaths) or 0) > 0 then
        row('deaths', s.deaths, function(v)
            return tostring(floor(v + 0.5))
        end)
    end

    return self
end

---------------------------------------------------------------------------
-- The reveal
---------------------------------------------------------------------------

function IntermissionMT:update(dt)
    if self.state ~= 'tallying' then return end
    self.clock = self.clock + math.max(0, tonumber(dt) or 0)
    if self.clock >= #self.rowDefs * self.rowTime then
        self.state = 'ready'
    end
end

-- Fire / use. The first press slams the tally to its final values; the
-- second leaves. Never both at once — see the header.
function IntermissionMT:confirm()
    if self.state == 'tallying' then
        self.clock = #self.rowDefs * self.rowTime
        self.state = 'ready'
        return 'skipped'
    end
    if self.state == 'ready' then
        self.state = 'continued'
        return 'continued'
    end
    return nil
end

function IntermissionMT:continued()
    return self.state == 'continued'
end

function IntermissionMT:active()
    return self.state == 'tallying' or self.state == 'ready'
end

function IntermissionMT:reset()
    self.state = 'idle'
    self.rowDefs = {}
    self.clock = 0
    return self
end

---------------------------------------------------------------------------
-- Draw-ready rows
---------------------------------------------------------------------------

--[[
    Returns the rows visible RIGHT NOW: each fully-revealed row at its final
    text, the row currently rolling at its partial value, nothing for rows
    whose turn has not come. { label=, text=, done=(bool) }.
]]
function IntermissionMT:rows()
    local out = {}
    for i = 1, #self.rowDefs do
        local def = self.rowDefs[i]
        local start = (i - 1) * self.rowTime
        local into = self.clock - start
        if into <= 0 then break end
        local fraction = into >= self.rowTime and 1 or (into / self.rowTime)
        out[#out + 1] = {
            label = def.label,
            text = def.fmt(def.value * fraction),
            done = fraction >= 1,
        }
    end
    return out
end

-- The headline and footer a renderer wants alongside the rows.
function IntermissionMT:header()
    return {
        title = self.title,
        result = self.result,
        next_ = self.next_,
        prompt = self.state == 'ready'
            and ((self.next_ and ('continue to ' .. self.next_)) or 'continue')
            or nil,
    }
end

return Intermission
