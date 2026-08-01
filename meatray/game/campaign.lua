--[[
    meatray.game.campaign — map-chain mission flow (win / lose / next / credits).

    The engine already has maps, triggers, and a thin Mode template. What a
    shippable game still reinvents is the *graph of levels*: which map is
    active, what counts as finishing it, when the next one loads, and what
    happens when the chain ends. This module is that graph — pure orchestration,
    no rendering, no filesystem I/O.

        local Campaign = require('meatray.game.campaign')
        local camp = Campaign.new{
            id = 'demo',
            title = 'Demo Campaign',
            missions = {
                {
                    id = 'arena',
                    map = 'maps/arena.map',
                    name = 'The Arena',
                    exit = { x1 = 18, y1 = 1, x2 = 20, y2 = 3 },
                    -- or exitTiles = { tx1 = 19, ty1 = 2, tx2 = 20, ty2 = 3 },
                    parTime = 180,
                    timeLimit = nil,
                },
                { id = 'tower', map = 'maps/tower.map', name = 'Tower' },
            },
            -- Required to actually swap worlds (campaign never loads files itself):
            onLoadMap = function(camp, path, opts) ... end,
            onMissionStart = function(camp, mission, index) end,
            onMissionEnd   = function(camp, mission, result) end,
            onIntermission = function(camp, from, to, result) end,
            onCredits      = function(camp, totals) end,
            onCampaignWin  = function(camp, totals) end,
            onCampaignLose = function(camp, reason) end,
            playerFilter   = function(e) return e and e:has('player') end,
            getPlayer      = function() return playerEntity end,
        }

        camp:start()
        -- after movement each fixed tick:
        camp:tick(dt, world, entities)
        -- when a map is ready, install the exit volume (optional auto-win):
        camp:bindTriggers(triggers)

    States: idle | mission | intermission | credits | won | lost

    Win paths:
      * player (filter) enters the mission exit volume (default when exit set)
      * camp:completeMission('win') from game/MeatGraph/mode code
      * optional winWhenAllDead: no living entities matching enemyFilter

    Lose paths:
      * camp:failMission(reason)
      * optional timeLimit exceeded
      * optional loseOnPlayerDeath when getPlayer() reports dead/depleted

    HEADLESS: pure Lua. No love.*, no I/O.
]]

local Triggers = require('meatray.sim.triggers')
local Damage   = require('meatray.game.damage')

local Campaign = {}
local CampaignMT = {}
CampaignMT.__index = CampaignMT

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function copyMission(m, index)
    m = m or {}
    return {
        id = m.id or ('mission_' .. index),
        map = m.map or m.path,
        name = m.name or m.id or ('Mission ' .. index),
        exit = m.exit and {
            x1 = m.exit.x1 or m.exit.x,
            y1 = m.exit.y1 or m.exit.y,
            x2 = m.exit.x2,
            y2 = m.exit.y2,
            w = m.exit.w,
            h = m.exit.h,
        } or nil,
        exitTiles = m.exitTiles and {
            tx1 = m.exitTiles.tx1 or m.exitTiles.tx,
            ty1 = m.exitTiles.ty1 or m.exitTiles.ty,
            tx2 = m.exitTiles.tx2 or m.exitTiles.tx1 or m.exitTiles.tx,
            ty2 = m.exitTiles.ty2 or m.exitTiles.ty1 or m.exitTiles.ty,
        } or nil,
        parTime = m.parTime,
        timeLimit = m.timeLimit,
        winOnExit = m.winOnExit ~= false,
        winWhenAllDead = m.winWhenAllDead and true or false,
        loseOnPlayerDeath = m.loseOnPlayerDeath ~= false,
        intermission = m.intermission, -- seconds; nil/0 = skip
        data = m.data or {},
        -- Original table reference for advanced authors.
        _src = m,
    }
end

local function emptyMissionStats()
    return {
        elapsed = 0,
        kills = 0,
        secrets = 0,
        deaths = 0,
        outcome = nil, -- 'win' | 'lose' | nil
        reason = nil,
    }
end

local function fire(fn, ...)
    if not fn then return end
    local ok, err = pcall(fn, ...)
    if not ok then error(err, 0) end
end

local function playerIsOut(e)
    if not e or e.dead then return true end
    if Damage.isDepleted(e, 'health') then return true end
    return false
end

---------------------------------------------------------------------------
-- Construction
---------------------------------------------------------------------------

--[[
    Builds a campaign runner.

    `missions` is an ordered list. Each entry needs at least `map` (path string
    the game understands). Exit volumes are optional; without one the mission
    only ends via completeMission / failMission / winWhenAllDead / timeLimit.
]]
function Campaign.new(opts)
    opts = opts or {}
    local missions = {}
    for i = 1, #(opts.missions or {}) do
        missions[i] = copyMission(opts.missions[i], i)
    end

    return setmetatable({
        id = opts.id or 'campaign',
        title = opts.title or opts.id or 'Campaign',
        missions = missions,
        state = 'idle',
        index = 0,              -- 1-based current mission; 0 before start
        elapsed = 0,            -- whole-campaign time while in mission/intermission
        missionElapsed = 0,
        intermissionLeft = 0,
        stats = {},             -- [index] = mission stats
        totals = emptyMissionStats(),
        pendingResult = nil,    -- set during intermission
        _exitVol = nil,
        _triggers = nil,
        _ended = false,

        onLoadMap = opts.onLoadMap,
        onMissionStart = opts.onMissionStart,
        onMissionEnd = opts.onMissionEnd,
        onIntermission = opts.onIntermission,
        onCredits = opts.onCredits,
        onCampaignWin = opts.onCampaignWin,
        onCampaignLose = opts.onCampaignLose,
        onState = opts.onState, -- function(camp, newState, oldState)

        playerFilter = opts.playerFilter or function(e)
            return e and not e.dead and e.components and e.components.player
        end,
        enemyFilter = opts.enemyFilter or function(e)
            return e and not e.dead and e.components and e.components.ai
        end,
        getPlayer = opts.getPlayer,

        data = opts.data or {},
    }, CampaignMT)
end

-- Parse a linear campaign from a plain table (JSON-decoded or Lua).
function Campaign.fromTable(t)
    if type(t) ~= 'table' then return nil, 'campaign table required' end
    return Campaign.new(t)
end

---------------------------------------------------------------------------
-- Query
---------------------------------------------------------------------------

function CampaignMT:missionCount()
    return #self.missions
end

function CampaignMT:currentMission()
    if self.index < 1 or self.index > #self.missions then return nil end
    return self.missions[self.index]
end

function CampaignMT:isActive()
    return self.state == 'mission' or self.state == 'intermission'
end

function CampaignMT:isTerminal()
    return self.state == 'won' or self.state == 'lost' or self.state == 'credits'
end

function CampaignMT:progress()
    return {
        id = self.id,
        title = self.title,
        state = self.state,
        index = self.index,
        total = #self.missions,
        mission = self:currentMission(),
        missionElapsed = self.missionElapsed,
        elapsed = self.elapsed,
        totals = {
            elapsed = self.totals.elapsed,
            kills = self.totals.kills,
            secrets = self.totals.secrets,
            deaths = self.totals.deaths,
        },
        stats = self.stats,
    }
end

function CampaignMT:exportProgress()
    local missionStats = {}
    for i = 1, #self.missions do
        local s = self.stats[i]
        if s then
            missionStats[i] = {
                elapsed = s.elapsed,
                kills = s.kills,
                secrets = s.secrets,
                deaths = s.deaths,
                outcome = s.outcome,
                reason = s.reason,
            }
        end
    end
    return {
        campaignId = self.id,
        state = self.state,
        index = self.index,
        elapsed = self.elapsed,
        missionElapsed = self.missionElapsed,
        intermissionLeft = self.intermissionLeft,
        totals = {
            elapsed = self.totals.elapsed,
            kills = self.totals.kills,
            secrets = self.totals.secrets,
            deaths = self.totals.deaths,
            outcome = self.totals.outcome,
            reason = self.totals.reason,
        },
        missionStats = missionStats,
    }
end

function CampaignMT:importProgress(p)
    if type(p) ~= 'table' then return false, 'progress table required' end
    if p.campaignId and p.campaignId ~= self.id then
        return false, 'campaign id mismatch'
    end
    self.state = p.state or self.state
    self.index = tonumber(p.index) or self.index
    self.elapsed = tonumber(p.elapsed) or 0
    self.missionElapsed = tonumber(p.missionElapsed) or 0
    self.intermissionLeft = tonumber(p.intermissionLeft) or 0
    if type(p.totals) == 'table' then
        self.totals.elapsed = tonumber(p.totals.elapsed) or 0
        self.totals.kills = tonumber(p.totals.kills) or 0
        self.totals.secrets = tonumber(p.totals.secrets) or 0
        self.totals.deaths = tonumber(p.totals.deaths) or 0
        self.totals.outcome = p.totals.outcome
        self.totals.reason = p.totals.reason
    end
    if type(p.missionStats) == 'table' then
        for i = 1, #self.missions do
            local s = p.missionStats[i]
            if s then
                self.stats[i] = {
                    elapsed = tonumber(s.elapsed) or 0,
                    kills = tonumber(s.kills) or 0,
                    secrets = tonumber(s.secrets) or 0,
                    deaths = tonumber(s.deaths) or 0,
                    outcome = s.outcome,
                    reason = s.reason,
                }
            end
        end
    end
    return true
end

---------------------------------------------------------------------------
-- State transitions
---------------------------------------------------------------------------

local function setState(self, newState)
    local old = self.state
    if old == newState then return end
    self.state = newState
    fire(self.onState, self, newState, old)
end

local function ensureStats(self, index)
    if not self.stats[index] then
        self.stats[index] = emptyMissionStats()
    end
    return self.stats[index]
end

local function loadMissionMap(self, mission, opts)
    opts = opts or {}
    if not mission or not mission.map then
        return false, 'mission has no map'
    end
    if not self.onLoadMap then
        -- Headless / unit tests may omit onLoadMap; orchestration still runs.
        return true
    end
    local ok, err = pcall(self.onLoadMap, self, mission.map, {
        mission = mission,
        index = self.index,
        arrival = opts.arrival,
        reason = opts.reason or 'mission',
    })
    if not ok then return false, err end
    return true
end

function CampaignMT:_beginMission(index, opts)
    opts = opts or {}
    if index < 1 or index > #self.missions then
        return false, 'mission index out of range'
    end
    self.index = index
    self.missionElapsed = 0
    self._ended = false
    self._exitVol = nil
    ensureStats(self, index)
    -- Fresh live counters for this attempt (keep prior outcomes only if replaying
    -- after a recorded finish — restart clears outcome).
    if opts.resetStats ~= false then
        self.stats[index] = emptyMissionStats()
    end
    setState(self, 'mission')
    local mission = self.missions[index]
    local ok, err = loadMissionMap(self, mission, opts)
    if not ok then
        setState(self, 'idle')
        return false, err
    end
    fire(self.onMissionStart, self, mission, index)
    -- Re-bind exit if triggers were already attached.
    if self._triggers then
        self:bindTriggers(self._triggers)
    end
    return true
end

function CampaignMT:start(opts)
    opts = opts or {}
    if #self.missions == 0 then return false, 'campaign has no missions' end
    self.elapsed = 0
    self.totals = emptyMissionStats()
    self.stats = {}
    self.pendingResult = nil
    self.intermissionLeft = 0
    local startAt = tonumber(opts.index) or 1
    return self:_beginMission(startAt, opts)
end

function CampaignMT:restartMission()
    if self.index < 1 then return false, 'no current mission' end
    return self:_beginMission(self.index, { resetStats = true, reason = 'restart' })
end

function CampaignMT:gotoMission(index, opts)
    return self:_beginMission(index, opts)
end

---------------------------------------------------------------------------
-- Scoring hooks (gameplay code calls these)
---------------------------------------------------------------------------

function CampaignMT:addKill(n)
    n = n or 1
    if self.state ~= 'mission' then return end
    local s = ensureStats(self, self.index)
    s.kills = s.kills + n
    self.totals.kills = self.totals.kills + n
end

function CampaignMT:addSecret(n)
    n = n or 1
    if self.state ~= 'mission' then return end
    local s = ensureStats(self, self.index)
    s.secrets = s.secrets + n
    self.totals.secrets = self.totals.secrets + n
end

function CampaignMT:addDeath(n)
    n = n or 1
    local s = ensureStats(self, self.index)
    s.deaths = s.deaths + n
    self.totals.deaths = self.totals.deaths + n
end

---------------------------------------------------------------------------
-- Exit volumes
---------------------------------------------------------------------------

--[[
    Pull an exit volume from a parsed map table (header `exit` → map.extra, or
    first-class map.exit if the map module set it).
]]
function Campaign.exitFromMap(map)
    if type(map) ~= 'table' then return nil end
    if type(map.exit) == 'table' then
        local e = map.exit
        if e.tiles or e.tx1 then
            return {
                exitTiles = {
                    tx1 = e.tx1, ty1 = e.ty1,
                    tx2 = e.tx2 or e.tx1, ty2 = e.ty2 or e.ty1,
                },
            }
        end
        if e.x1 then
            return { x1 = e.x1, y1 = e.y1, x2 = e.x2, y2 = e.y2 }
        end
    end
    local extra = map.extra
    if type(extra) ~= 'table' or type(extra.exit) ~= 'string' then return nil end
    local rest = extra.exit
    local kind, a, b, c, d = rest:match(
        '^(%S+)%s+(%-?[%d%.]+)%s+(%-?[%d%.]+)%s+(%-?[%d%.]+)%s+(%-?[%d%.]+)')
    if kind and (kind == 'tiles' or kind == 'tile') then
        return {
            exitTiles = {
                tx1 = tonumber(a), ty1 = tonumber(b),
                tx2 = tonumber(c), ty2 = tonumber(d),
            },
        }
    end
    local x1, y1, x2, y2 = rest:match(
        '^(%-?[%d%.]+)%s+(%-?[%d%.]+)%s+(%-?[%d%.]+)%s+(%-?[%d%.]+)')
    if x1 then
        return {
            x1 = tonumber(x1), y1 = tonumber(y1),
            x2 = tonumber(x2), y2 = tonumber(y2),
        }
    end
    return nil
end

function CampaignMT:resolveExit(mission, map)
    mission = mission or self:currentMission()
    if not mission then return nil end
    if mission.exit then return { kind = 'world', box = mission.exit } end
    if mission.exitTiles then return { kind = 'tiles', box = mission.exitTiles } end
    local fromMap = Campaign.exitFromMap(map)
    if not fromMap then return nil end
    if fromMap.exitTiles then return { kind = 'tiles', box = fromMap.exitTiles } end
    if fromMap.x1 then return { kind = 'world', box = fromMap } end
    return nil
end

--[[
    Installs (or reinstalls) the current mission's exit volume on a Triggers set.
    Previous campaign-owned exit volume is disabled. Safe to call every map load.
]]
function CampaignMT:bindTriggers(triggers, map)
    self._triggers = triggers
    if self._exitVol then
        self._exitVol.enabled = false
        self._exitVol = nil
    end
    if not triggers or self.state ~= 'mission' then return nil end
    local mission = self:currentMission()
    if not mission or mission.winOnExit == false then return nil end

    local resolved = self:resolveExit(mission, map)
    if not resolved then return nil end

    local camp = self
    local opts = {
        name = 'campaign_exit_' .. (mission.id or tostring(self.index)),
        once = true,
        filter = function(e) return camp.playerFilter(e) end,
        onEnter = function(e, vol)
            if camp.state == 'mission' and not camp._ended then
                camp:completeMission('exit', { entity = e, volume = vol })
            end
        end,
    }
    local vol
    if resolved.kind == 'tiles' then
        local b = resolved.box
        opts.tx1, opts.ty1, opts.tx2, opts.ty2 = b.tx1, b.ty1, b.tx2, b.ty2
        vol = triggers:addTiles(opts)
    else
        local b = resolved.box
        opts.x1, opts.y1 = b.x1, b.y1
        opts.x2, opts.y2 = b.x2, b.y2
        opts.w, opts.h = b.w, b.h
        vol = triggers:add(opts)
    end
    self._exitVol = vol
    return vol
end

-- Convenience: build a fresh Triggers box and bind the exit.
function CampaignMT:makeTriggers(map)
    local box = Triggers.new()
    self:bindTriggers(box, map)
    return box
end

---------------------------------------------------------------------------
-- Complete / fail / advance
---------------------------------------------------------------------------

local function finalizeMission(self, outcome, reason, extra)
    if self.state ~= 'mission' or self._ended then return false end
    self._ended = true
    local mission = self:currentMission()
    local s = ensureStats(self, self.index)
    s.elapsed = self.missionElapsed
    s.outcome = outcome
    s.reason = reason
    self.totals.elapsed = self.totals.elapsed + self.missionElapsed

    local result = {
        outcome = outcome,
        reason = reason,
        index = self.index,
        mission = mission,
        stats = {
            elapsed = s.elapsed,
            kills = s.kills,
            secrets = s.secrets,
            deaths = s.deaths,
            parTime = mission and mission.parTime,
        },
        extra = extra,
    }
    fire(self.onMissionEnd, self, mission, result)

    if outcome == 'lose' then
        self.totals.outcome = 'lose'
        self.totals.reason = reason
        setState(self, 'lost')
        fire(self.onCampaignLose, self, reason, result)
        return true
    end

    -- Win: intermission then next mission, or credits.
    local nextIndex = self.index + 1
    local nextMission = self.missions[nextIndex]
    local wait = (mission and tonumber(mission.intermission)) or 0
    self.pendingResult = result

    if wait > 0 and nextMission then
        self.intermissionLeft = wait
        setState(self, 'intermission')
        fire(self.onIntermission, self, mission, nextMission, result)
        return true
    end

    return self:_advanceAfterWin(result)
end

function CampaignMT:_advanceAfterWin(result)
    local nextIndex = self.index + 1
    if nextIndex > #self.missions then
        self.totals.outcome = 'win'
        setState(self, 'credits')
        local totals = {
            elapsed = self.totals.elapsed,
            kills = self.totals.kills,
            secrets = self.totals.secrets,
            deaths = self.totals.deaths,
            missions = #self.missions,
            stats = self.stats,
        }
        fire(self.onCredits, self, totals)
        fire(self.onCampaignWin, self, totals)
        setState(self, 'won')
        return true
    end
    return self:_beginMission(nextIndex, { reason = 'advance' })
end

function CampaignMT:completeMission(reason, extra)
    return finalizeMission(self, 'win', reason or 'complete', extra)
end

function CampaignMT:failMission(reason, extra)
    return finalizeMission(self, 'lose', reason or 'fail', extra)
end

-- Skip intermission / force next (or credits).
function CampaignMT:advance()
    if self.state == 'intermission' then
        self.intermissionLeft = 0
        local result = self.pendingResult
        self.pendingResult = nil
        return self:_advanceAfterWin(result)
    end
    if self.state == 'mission' then
        return self:completeMission('advance')
    end
    return false, 'nothing to advance'
end

---------------------------------------------------------------------------
-- Tick
---------------------------------------------------------------------------

function CampaignMT:tick(dt, world, entities)
    dt = dt or 0
    if self.state == 'intermission' then
        self.elapsed = self.elapsed + dt
        self.intermissionLeft = self.intermissionLeft - dt
        if self.intermissionLeft <= 0 then
            local result = self.pendingResult
            self.pendingResult = nil
            self:_advanceAfterWin(result)
        end
        return
    end

    if self.state ~= 'mission' then return end
    self.elapsed = self.elapsed + dt
    self.missionElapsed = self.missionElapsed + dt
    local mission = self:currentMission()
    if not mission then return end

    -- Time limit.
    if mission.timeLimit and self.missionElapsed >= mission.timeLimit then
        self:failMission('time')
        return
    end

    -- Player death.
    if mission.loseOnPlayerDeath ~= false and self.getPlayer then
        local p = self.getPlayer(self)
        if playerIsOut(p) then
            self:addDeath(1)
            self:failMission('death')
            return
        end
    end

    -- Optional clear-all-enemies win.
    if mission.winWhenAllDead and entities then
        local any = false
        for i = 1, #entities do
            local e = entities[i]
            if self.enemyFilter(e) then
                any = true
                break
            end
        end
        if not any then
            self:completeMission('all_dead')
            return
        end
    end
end

---------------------------------------------------------------------------
-- Mode glue (optional)
---------------------------------------------------------------------------

--[[
    Wraps this campaign in a meatray.game.mode instance so host onStep can
    tick it like any other mode.
]]
function CampaignMT:asMode(Mode, extra)
    Mode = Mode or require('meatray.game.mode')
    extra = extra or {}
    local camp = self
    return Mode.new{
        name = extra.name or ('campaign:' .. self.id),
        data = { campaign = camp },
        onStart = function(m, world, entities)
            if extra.onStart then extra.onStart(m, world, entities) end
            if camp.state == 'idle' then camp:start() end
        end,
        onTick = function(m, dt, world, entities)
            camp:tick(dt, world, entities)
            if extra.onTick then extra.onTick(m, dt, world, entities) end
        end,
        onStop = function(m, reason)
            if extra.onStop then extra.onStop(m, reason) end
        end,
        onPlayerJoin = extra.onPlayerJoin,
        onPlayerLeave = extra.onPlayerLeave,
        onCommand = extra.onCommand,
        onEvent = extra.onEvent,
    }
end

return Campaign
