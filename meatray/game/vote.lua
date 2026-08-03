--[[
    meatray.game.vote — call a vote, count the ballots, act on the result (F7).

    The Zandronum/EDuke staple: a player calls a vote — kick that griefer,
    change to this map, restart the round — everyone gets a moment to answer
    yes or no, and if enough say yes before the clock runs out it passes. This
    is the tally as a MODEL, host-authoritative and headless: the proposal,
    the ballots, the threshold, the timer, the verdict. What a passed vote DOES
    (actually kick, actually load the map) is the host's job through a callback,
    the same way RCON's `map` calls onMap rather than loading a world itself.

        local Vote = require('meatray.game.vote')
        local v = Vote.new{ duration = 30, threshold = 0.5,
                            onPass = function(vote) enact(vote) end }

        v:call('kick', { target = 7, by = 3 }, electorate)   -- 3 proposes kicking 7
        v:cast(3, true)                                        -- the caller votes yes
        v:cast(5, false)
        v:update(dt)                                          -- ticks the clock
        v:status()                                            -- { yes, no, need, left, ... }

    Rules that keep it fair and un-abusable:

      * One vote at a time. A second `call` while one is live is refused — a
        server where everyone spams votes is a server nobody can play on.
      * One ballot per peer, changeable until the vote closes. Casting again
        replaces; the count is over distinct voters, never over presses.
      * The threshold is of the ELECTORATE, not of who bothered to vote, and
        non-voters count as NO. That is the honest reading of "the server
        agreed": silence is not consent, so a vote nobody answers fails, and a
        kick needs positive support rather than mere absence of objection.
      * A caller cannot be the whole electorate for their own kick target: the
        target does not get a ballot on their own removal (they would always
        vote no, which is noise), and is removed from the electorate count.
      * Cooldown after a vote so the same failed proposal cannot be re-called
        instantly to grind the server down.

    The kinds are data (map/kick/restart ship; a game adds its own) so the
    model validates a proposal's shape without knowing what enacting it means.

    HEADLESS: pure Lua. The caller hands in dt.
]]

local Vote = {}
local VoteMT = {}
VoteMT.__index = VoteMT

-- Each kind: how to validate its proposal args. The tally does not care what
-- the kind DOES — only that the proposal is well-formed before it opens.
Vote.KINDS = {
    map     = function(a) return type(a.map) == 'string' and a.map ~= '' end,
    kick    = function(a) return a.target ~= nil end,
    restart = function() return true end,
}

---------------------------------------------------------------------------
-- Construction
---------------------------------------------------------------------------

-- opts:
--   duration    seconds a vote stays open (default 30)
--   threshold   fraction of the electorate that must say YES (default 0.5,
--               i.e. a majority; passes on strictly greater-than-half)
--   cooldown    seconds after a vote closes before another may be called (5)
--   onPass / onFail   function(vote) callbacks
--   kinds       override/extend Vote.KINDS
function Vote.new(opts)
    opts = opts or {}
    local kinds = {}
    for k, fn in pairs(Vote.KINDS) do kinds[k] = fn end
    for k, fn in pairs(opts.kinds or {}) do kinds[k] = fn end
    return setmetatable({
        duration = tonumber(opts.duration) or 30,
        threshold = tonumber(opts.threshold) or 0.5,
        cooldown = tonumber(opts.cooldown) or 5,
        onPass = opts.onPass,
        onFail = opts.onFail,
        kinds = kinds,

        active = nil,          -- the live vote, or nil
        cooldownLeft = 0,
    }, VoteMT)
end

---------------------------------------------------------------------------
-- Calling a vote
---------------------------------------------------------------------------

-- kind: a key in self.kinds. args: the proposal (validated by the kind).
-- electorate: array of peer ids eligible to vote. Returns the vote, or nil
-- plus a reason.
function VoteMT:call(kind, args, electorate)
    args = args or {}
    if self.active then return nil, 'a vote is already in progress' end
    if self.cooldownLeft > 0 then
        return nil, ('wait %d s before calling another vote')
                    :format(math.ceil(self.cooldownLeft))
    end
    local check = self.kinds[kind]
    if not check then return nil, 'unknown vote kind: ' .. tostring(kind) end
    if not check(args) then return nil, 'bad proposal for a ' .. kind .. ' vote' end

    -- The electorate, minus the kick target (they get no say on their own
    -- removal). Distinct ids only.
    local roll, seen = {}, {}
    for _, id in ipairs(electorate or {}) do
        if not seen[id] and not (kind == 'kick' and id == args.target) then
            seen[id] = true
            roll[#roll + 1] = id
        end
    end

    self.active = {
        kind = kind,
        args = args,
        by = args.by,
        electorate = roll,
        eligible = #roll,
        ballots = {},          -- [peerId] = true/false
        left = self.duration,
        result = nil,          -- 'pass' | 'fail'
    }

    -- The caller's yes is implied — you vote for your own proposal.
    if args.by ~= nil and seen[args.by] then
        self.active.ballots[args.by] = true
    end
    return self.active
end

---------------------------------------------------------------------------
-- Casting
---------------------------------------------------------------------------

-- A peer answers yes (true) or no (false). Only electors count; casting again
-- replaces. Returns true, or false plus a reason.
function VoteMT:cast(peerId, yes)
    local v = self.active
    if not v then return false, 'no vote in progress' end
    -- Is this peer on the roll?
    local onRoll = false
    for i = 1, #v.electorate do
        if v.electorate[i] == peerId then onRoll = true break end
    end
    if not onRoll then return false, 'not eligible to vote' end
    v.ballots[peerId] = yes and true or false
    return true
end

---------------------------------------------------------------------------
-- Counting
---------------------------------------------------------------------------

local function tally(v)
    local yes, no = 0, 0
    for _, b in pairs(v.ballots) do
        if b then yes = yes + 1 else no = no + 1 end
    end
    return yes, no
end

-- Yes-votes needed to pass: strictly more than `threshold` of the electorate.
-- floor(t*n)+1 gives "more than half" for t=0.5 whether n is odd or even.
local function needed(v, threshold)
    return math.floor(threshold * v.eligible) + 1
end

-- Resolves the live vote if it can be. A vote passes THE MOMENT enough yes
-- ballots exist (no need to wait out the clock), and fails when it can no
-- longer reach the threshold even if every remaining elector says yes, or when
-- the clock runs out. Returns 'pass' | 'fail' | nil (still open).
function VoteMT:evaluate()
    local v = self.active
    if not v or v.result then return v and v.result end
    if v.eligible == 0 then return nil end

    local yes, no = tally(v)
    local need = needed(v, self.threshold)
    local outstanding = v.eligible - (yes + no)

    if yes >= need then return 'pass' end
    if yes + outstanding < need then return 'fail' end   -- cannot get there
    if v.left <= 0 then return 'fail' end                -- time up, short of it
    return nil
end

---------------------------------------------------------------------------
-- The tick
---------------------------------------------------------------------------

function VoteMT:update(dt)
    dt = math.max(0, tonumber(dt) or 0)

    if self.cooldownLeft > 0 then
        self.cooldownLeft = math.max(0, self.cooldownLeft - dt)
    end

    local v = self.active
    if not v then return nil end

    v.left = v.left - dt
    local result = self:evaluate()
    if result then
        v.result = result
        local finished = v
        self.active = nil
        self.cooldownLeft = self.cooldown
        if result == 'pass' and self.onPass then self.onPass(finished) end
        if result == 'fail' and self.onFail then self.onFail(finished) end
        return result, finished
    end
    return nil
end

-- Removes a peer from a live vote (they disconnected). Their ballot is dropped
-- and they leave the electorate, so the threshold is of who is still here.
function VoteMT:removeVoter(peerId)
    local v = self.active
    if not v then return end
    v.ballots[peerId] = nil
    for i = #v.electorate, 1, -1 do
        if v.electorate[i] == peerId then
            table.remove(v.electorate, i)
            v.eligible = #v.electorate
        end
    end
end

---------------------------------------------------------------------------
-- Status, for the message layer to surface
---------------------------------------------------------------------------

function VoteMT:isActive()
    return self.active ~= nil
end

function VoteMT:current()
    return self.active
end

-- Draw/announce-ready snapshot, or nil when no vote is live.
function VoteMT:status()
    local v = self.active
    if not v then return nil end
    local yes, no = tally(v)
    return {
        kind = v.kind, args = v.args, by = v.by,
        yes = yes, no = no,
        eligible = v.eligible,
        need = needed(v, self.threshold),
        left = math.max(0, v.left),
    }
end

-- A one-line description of the proposal, for a centerprint.
function VoteMT:describe()
    local v = self.active
    if not v then return nil end
    if v.kind == 'kick' then return 'kick player ' .. tostring(v.args.target)
    elseif v.kind == 'map' then return 'change map to ' .. tostring(v.args.map)
    elseif v.kind == 'restart' then return 'restart the round' end
    return v.kind
end

return Vote
