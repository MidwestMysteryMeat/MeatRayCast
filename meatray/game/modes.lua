--[[
    meatray.game.modes — stock host-authoritative game rulesets.

    `meatray.game.mode` is the lifecycle shell (start/tick/stop, join/leave,
    command routing). This module fills it with reusable rules: scoring, round
    timer, frag limits, teams, co-op wipe, and single-player objectives.

        local Modes = require('meatray.game.modes')

        local dm = Modes.deathmatch{
            fragLimit = 20,
            timeLimit = 600,
            onRoundEnd = function(mode, result) ... end,
        }
        dm:start(world, entities)
        -- host authoritative kill:
        dm:recordKill(killerPeer, victimPeer)
        dm:tick(dt, world, entities)

        local tdm = Modes.teamDeathmatch{ teams = { 'red', 'blue' }, fragLimit = 50 }
        local coop = Modes.coop{ winWhenAllDead = true }
        local sp = Modes.singlePlayer{
            objectives = {
                { id = 'kills', type = 'kills', count = 5 },
                { id = 'extract', type = 'flag', key = 'at_exit' },
            },
        }

        Modes.byName('deathmatch', opts)  -- factory by string

    States live on the Mode instance:
      mode.data.rules   — frozen options for this ruleset
      mode.data.phase   — idle | warmup | live | post | ended
      mode.data.players — [peerId] = { peer, entity, team, frags, deaths, suicides, spectator }
      mode.data.teams   — [teamName] = { score, players = {peerId,...} }  (team modes)
      mode.data.objectives — SP/co-op objective progress

    Actual entity respawn / spawn-protect is A5 — these modes only record policy
    fields (respawnDelay) and fire onPlayerDeath / onRequestRespawn hooks.

    HEADLESS: pure Lua.
]]

local Mode = require('meatray.game.mode')

local Modes = {}

---------------------------------------------------------------------------
-- Shared plumbing
---------------------------------------------------------------------------

local function copyList(list)
    local out = {}
    for i = 1, #(list or {}) do out[i] = list[i] end
    return out
end

local function playerEntry(peer, entity, team)
    return {
        peer = peer,
        entity = entity,
        team = team,
        frags = 0,
        deaths = 0,
        suicides = 0,
        spectator = false,
        joinedAt = 0,
    }
end

local function ensurePlayer(mode, peer, entity)
    local players = mode.data.players
    local p = players[peer]
    if not p then
        p = playerEntry(peer, entity, mode.data.defaultTeam)
        players[peer] = p
        mode.score[peer] = mode.score[peer] or 0
        if p.team and mode.data.teams and mode.data.teams[p.team] then
            local t = mode.data.teams[p.team]
            t.players[#t.players + 1] = peer
        end
    else
        if entity ~= nil then p.entity = entity end
    end
    return p
end

local function removeFromTeamList(mode, peer, team)
    local t = mode.data.teams and mode.data.teams[team]
    if not t then return end
    for i = #t.players, 1, -1 do
        if t.players[i] == peer then table.remove(t.players, i) end
    end
end

local function fire(fn, ...)
    if not fn then return end
    local ok, err = pcall(fn, ...)
    if not ok then error(err, 0) end
end

local function chain(userFn, stockFn)
    if not userFn then return stockFn end
    if not stockFn then return userFn end
    return function(...)
        stockFn(...)
        return userFn(...)
    end
end

local function livingPlayers(mode)
    local n, list = 0, {}
    for peer, p in pairs(mode.data.players) do
        if not p.spectator then
            n = n + 1
            list[n] = peer
        end
    end
    return n, list
end

local function defaultEnemyFilter(e)
    return e and not e.dead and e.components and e.components.ai
end

local function defaultPlayerFilter(e)
    return e and not e.dead and e.components and e.components.player
end

-- Rank players by score then frags then fewer deaths.
local function sortStandings(rows)
    table.sort(rows, function(a, b)
        if a.score ~= b.score then return a.score > b.score end
        if a.frags ~= b.frags then return a.frags > b.frags end
        if a.deaths ~= b.deaths then return a.deaths < b.deaths end
        return tostring(a.peer) < tostring(b.peer)
    end)
    return rows
end

local function attachCommon(mode, opts)
    opts = opts or {}
    mode.data.players = mode.data.players or {}
    mode.data.phase = mode.data.phase or 'idle'
    mode.data.phaseElapsed = 0
    mode.data.round = 0
    mode.data.winner = nil
    mode.data.result = nil
    mode.data.respawnDelay = opts.respawnDelay or 0

    function mode:getPlayer(peer)
        return self.data.players[peer]
    end

    function mode:playerCount(includeSpectators)
        local n = 0
        for _, p in pairs(self.data.players) do
            if includeSpectators or not p.spectator then n = n + 1 end
        end
        return n
    end

    function mode:setSpectator(peer, yes)
        local p = ensurePlayer(self, peer)
        p.spectator = yes and true or false
        return p
    end

    function mode:standings()
        local rows = {}
        for peer, p in pairs(self.data.players) do
            if not p.spectator then
                rows[#rows + 1] = {
                    peer = peer,
                    team = p.team,
                    score = self.score[peer] or 0,
                    frags = p.frags,
                    deaths = p.deaths,
                    suicides = p.suicides,
                }
            end
        end
        return sortStandings(rows)
    end

    function mode:teamStandings()
        if not self.data.teams then return {} end
        local rows = {}
        for name, t in pairs(self.data.teams) do
            rows[#rows + 1] = { team = name, score = t.score or 0, players = #t.players }
        end
        table.sort(rows, function(a, b)
            if a.score ~= b.score then return a.score > b.score end
            return a.team < b.team
        end)
        return rows
    end

    function mode:assignTeam(peer, team)
        local p = ensurePlayer(self, peer)
        if p.team and p.team ~= team then
            removeFromTeamList(self, peer, p.team)
        end
        p.team = team
        if team and self.data.teams then
            if not self.data.teams[team] then
                self.data.teams[team] = { score = 0, players = {} }
            end
            local list = self.data.teams[team].players
            local found = false
            for i = 1, #list do if list[i] == peer then found = true break end end
            if not found then list[#list + 1] = peer end
        end
        return p
    end

    function mode:phase()
        return self.data.phase
    end

    function mode:rules()
        return self.data.rules
    end

    -- End the current round (or match) with a structured result.
    function mode:endRound(reason, extra)
        if self.data.phase == 'ended' or self.state ~= 'running' then
            return self.data.result
        end
        local rules = self.data.rules
        local result = {
            reason = reason or 'end',
            kind = rules and rules.kind or self.name,
            elapsed = self.elapsed,
            round = self.data.round,
            standings = self:standings(),
            teamStandings = self.data.teams and self:teamStandings() or nil,
            winner = extra and extra.winner,
            winningTeam = extra and extra.winningTeam,
            extra = extra,
        }
        if not result.winner and result.standings[1] then
            result.winner = result.standings[1].peer
        end
        if not result.winningTeam and result.teamStandings and result.teamStandings[1] then
            result.winningTeam = result.teamStandings[1].team
        end
        self.data.result = result
        self.data.winner = result.winner
        self.data.winningTeam = result.winningTeam

        local post = rules and tonumber(rules.postDelay) or 0
        if post > 0 and self.data.phase == 'live' then
            self.data.phase = 'post'
            self.data.phaseElapsed = 0
            fire(opts.onRoundEnd, self, result)
            return result
        end

        self.data.phase = 'ended'
        fire(opts.onRoundEnd, self, result)
        self:stop(reason or 'end')
        return result
    end

    function mode:beginLive()
        self.data.phase = 'live'
        self.data.phaseElapsed = 0
        fire(opts.onLive, self)
    end

    return mode
end

local function stockTickPhases(mode, dt, opts)
    local rules = mode.data.rules
    local phase = mode.data.phase
    mode.data.phaseElapsed = (mode.data.phaseElapsed or 0) + (dt or 0)

    if phase == 'warmup' then
        local warm = tonumber(rules.warmup) or 0
        if mode.data.phaseElapsed >= warm then
            mode:beginLive()
        end
        return
    end

    if phase == 'post' then
        local post = tonumber(rules.postDelay) or 0
        if mode.data.phaseElapsed >= post then
            mode.data.phase = 'ended'
            mode:stop(mode.data.result and mode.data.result.reason or 'end')
        end
        return
    end

    if phase ~= 'live' then return end

    local timeLimit = rules.timeLimit
    if timeLimit and mode.data.phaseElapsed >= timeLimit then
        mode:endRound('time')
    end
end

local function wireJoinLeave(mode, opts)
    local userJoin = opts.onPlayerJoin
    local userLeave = opts.onPlayerLeave

    mode.onPlayerJoin = function(m, peer, entity)
        local p = ensurePlayer(m, peer, entity)
        p.joinedAt = m.elapsed
        if m.data.autoBalance and m.data.teams then
            -- Put new players on the smallest team when none assigned.
            if not p.team or p.team == m.data.defaultTeam then
                local best, bestN = nil, math.huge
                for name, t in pairs(m.data.teams) do
                    local n = #t.players
                    if n < bestN or (n == bestN and (not best or name < best)) then
                        best, bestN = name, n
                    end
                end
                if best then m:assignTeam(peer, best) end
            end
        end
        fire(userJoin, m, peer, entity)
    end

    mode.onPlayerLeave = function(m, peer)
        local p = m.data.players[peer]
        if p and p.team then removeFromTeamList(m, peer, p.team) end
        m.data.players[peer] = nil
        -- Keep score row for standings history unless opts say otherwise.
        if opts.forgetScoreOnLeave then m.score[peer] = nil end
        fire(userLeave, m, peer)
    end
end

---------------------------------------------------------------------------
-- Kill recording (DM / TDM)
---------------------------------------------------------------------------

local function attachKillScoring(mode, opts)
    local rules = mode.data.rules

    function mode:recordKill(killerPeer, victimPeer, info)
        info = info or {}
        if self.data.phase ~= 'live' and self.data.phase ~= 'warmup' then
            return nil, 'not live'
        end
        -- Kills during warmup do not score (optional allowWarmupKills).
        if self.data.phase == 'warmup' and not rules.allowWarmupKills then
            return nil, 'warmup'
        end

        local victim = victimPeer and ensurePlayer(self, victimPeer)
        if victim then
            victim.deaths = victim.deaths + 1
        end

        local suicide = (killerPeer == nil) or (killerPeer == victimPeer) or info.suicide
        if suicide then
            if victim then
                victim.suicides = victim.suicides + 1
                local delta = rules.scorePerSuicide or -1
                self:addScore(victimPeer, delta)
            end
            fire(opts.onKill, self, {
                killer = killerPeer,
                victim = victimPeer,
                suicide = true,
                info = info,
            })
            fire(opts.onPlayerDeath, self, victimPeer, { suicide = true, info = info })
            fire(opts.onRequestRespawn, self, victimPeer, self.data.respawnDelay)
            return self:checkFragLimits()
        end

        local killer = ensurePlayer(self, killerPeer)
        local teamKill = false
        if rules.teamsEnabled and killer.team and victim and killer.team == victim.team then
            teamKill = true
            local delta = rules.scorePerTeamKill or -1
            self:addScore(killerPeer, delta)
        else
            killer.frags = killer.frags + 1
            local delta = rules.scorePerKill or 1
            self:addScore(killerPeer, delta)
            if rules.teamsEnabled and killer.team and self.data.teams[killer.team] then
                local ts = rules.scorePerKill or 1
                self.data.teams[killer.team].score =
                    (self.data.teams[killer.team].score or 0) + ts
            end
        end

        fire(opts.onKill, self, {
            killer = killerPeer,
            victim = victimPeer,
            suicide = false,
            teamKill = teamKill,
            info = info,
        })
        fire(opts.onPlayerDeath, self, victimPeer, {
            killer = killerPeer,
            teamKill = teamKill,
            info = info,
        })
        fire(opts.onRequestRespawn, self, victimPeer, self.data.respawnDelay)

        return self:checkFragLimits()
    end

    function mode:checkFragLimits()
        local fragLimit = rules.fragLimit
        if not fragLimit or self.data.phase ~= 'live' then return nil end

        if rules.teamsEnabled and self.data.teams then
            for name, t in pairs(self.data.teams) do
                if (t.score or 0) >= fragLimit then
                    return self:endRound('fraglimit', { winningTeam = name })
                end
            end
            return nil
        end

        for peer, p in pairs(self.data.players) do
            if not p.spectator then
                local sc = self.score[peer] or 0
                -- Frag limit counts score by default; optional useFrags uses frags.
                local value = rules.limitUsesFrags and p.frags or sc
                if value >= fragLimit then
                    return self:endRound('fraglimit', { winner = peer })
                end
            end
        end
        return nil
    end
end

---------------------------------------------------------------------------
-- Deathmatch
---------------------------------------------------------------------------

function Modes.deathmatch(opts)
    opts = opts or {}
    local rules = {
        kind = 'deathmatch',
        fragLimit = opts.fragLimit,
        timeLimit = opts.timeLimit,
        scorePerKill = opts.scorePerKill or 1,
        scorePerSuicide = opts.scorePerSuicide or -1,
        warmup = opts.warmup or 0,
        postDelay = opts.postDelay or 0,
        allowWarmupKills = opts.allowWarmupKills and true or false,
        teamsEnabled = false,
        limitUsesFrags = opts.limitUsesFrags and true or false,
        respawnDelay = opts.respawnDelay or 0,
    }

    local mode = Mode.new{
        name = opts.name or 'deathmatch',
        data = { rules = rules },
        onStart = function(m, world, entities)
            m.data.round = (m.data.round or 0) + 1
            m.data.phaseElapsed = 0
            m.data.winner = nil
            m.data.result = nil
            m.data.phase = (rules.warmup > 0) and 'warmup' or 'live'
            -- Reset per-round combat stats; keep roster.
            for _, p in pairs(m.data.players) do
                p.frags, p.deaths, p.suicides = 0, 0, 0
            end
            if opts.resetScoresOnRound ~= false then
                for peer in pairs(m.score) do m.score[peer] = 0 end
            end
            fire(opts.onStart, m, world, entities)
        end,
        onTick = function(m, dt, world, entities)
            stockTickPhases(m, dt, opts)
            fire(opts.onTick, m, dt, world, entities)
        end,
        onStop = opts.onStop,
        onCommand = opts.onCommand,
        onEvent = opts.onEvent,
    }

    attachCommon(mode, opts)
    wireJoinLeave(mode, opts)
    attachKillScoring(mode, opts)
    return mode
end

---------------------------------------------------------------------------
-- Team deathmatch
---------------------------------------------------------------------------

function Modes.teamDeathmatch(opts)
    opts = opts or {}
    local teamNames = copyList(opts.teams or { 'red', 'blue' })
    if #teamNames < 2 then teamNames = { 'red', 'blue' } end

    local rules = {
        kind = 'team_deathmatch',
        fragLimit = opts.fragLimit,
        timeLimit = opts.timeLimit,
        scorePerKill = opts.scorePerKill or 1,
        scorePerSuicide = opts.scorePerSuicide or -1,
        scorePerTeamKill = opts.scorePerTeamKill or -1,
        warmup = opts.warmup or 0,
        postDelay = opts.postDelay or 0,
        allowWarmupKills = opts.allowWarmupKills and true or false,
        teamsEnabled = true,
        limitUsesFrags = false,
        respawnDelay = opts.respawnDelay or 0,
    }

    local teams = {}
    for i = 1, #teamNames do
        teams[teamNames[i]] = { score = 0, players = {} }
    end

    local mode = Mode.new{
        name = opts.name or 'team_deathmatch',
        data = {
            rules = rules,
            teams = teams,
            teamNames = teamNames,
            defaultTeam = teamNames[1],
            autoBalance = opts.autoBalance ~= false,
        },
        onStart = function(m, world, entities)
            m.data.round = (m.data.round or 0) + 1
            m.data.phaseElapsed = 0
            m.data.winner = nil
            m.data.winningTeam = nil
            m.data.result = nil
            m.data.phase = (rules.warmup > 0) and 'warmup' or 'live'
            for _, p in pairs(m.data.players) do
                p.frags, p.deaths, p.suicides = 0, 0, 0
            end
            for _, t in pairs(m.data.teams) do t.score = 0 end
            if opts.resetScoresOnRound ~= false then
                for peer in pairs(m.score) do m.score[peer] = 0 end
            end
            fire(opts.onStart, m, world, entities)
        end,
        onTick = function(m, dt, world, entities)
            stockTickPhases(m, dt, opts)
            fire(opts.onTick, m, dt, world, entities)
        end,
        onStop = opts.onStop,
        onCommand = opts.onCommand,
        onEvent = opts.onEvent,
    }

    attachCommon(mode, opts)
    wireJoinLeave(mode, opts)
    attachKillScoring(mode, opts)
    return mode
end

---------------------------------------------------------------------------
-- Objectives (shared by co-op and single-player)
---------------------------------------------------------------------------

local function normalizeObjectives(list)
    local out = {}
    for i = 1, #(list or {}) do
        local o = list[i] or {}
        out[i] = {
            id = o.id or ('obj_' .. i),
            type = o.type or 'flag',
            count = o.count,
            duration = o.duration,
            key = o.key or o.id,
            check = o.check,
            optional = o.optional and true or false,
            done = false,
            progress = 0,
            required = o.required, -- filled at runtime for survive etc.
        }
    end
    return out
end

local function objectivesAllRequiredDone(objs)
    for i = 1, #objs do
        if not objs[i].optional and not objs[i].done then return false end
    end
    return #objs > 0
end

local function attachObjectives(mode, opts)
    function mode:getObjectives()
        return self.data.objectives
    end

    function mode:objectiveProgress()
        local rows = {}
        for i = 1, #(self.data.objectives or {}) do
            local o = self.data.objectives[i]
            rows[i] = {
                id = o.id,
                type = o.type,
                done = o.done,
                progress = o.progress,
                count = o.count,
                duration = o.duration,
                optional = o.optional,
            }
        end
        return rows
    end

    function mode:setObjectiveFlag(key, value)
        if value == false then return false end
        local any = false
        for i = 1, #(self.data.objectives or {}) do
            local o = self.data.objectives[i]
            if (o.type == 'flag' or o.type == 'custom') and (o.key == key or o.id == key) then
                if not o.done then
                    o.done = true
                    o.progress = 1
                    any = true
                    fire(opts.onObjectiveComplete, self, o)
                end
            end
        end
        if any then self:checkObjectives() end
        return any
    end

    function mode:completeObjective(id)
        for i = 1, #(self.data.objectives or {}) do
            local o = self.data.objectives[i]
            if o.id == id and not o.done then
                o.done = true
                o.progress = o.count or o.duration or 1
                fire(opts.onObjectiveComplete, self, o)
                self:checkObjectives()
                return true
            end
        end
        return false
    end

    function mode:addObjectiveProgress(id, amount)
        amount = amount or 1
        for i = 1, #(self.data.objectives or {}) do
            local o = self.data.objectives[i]
            if o.id == id and not o.done then
                o.progress = (o.progress or 0) + amount
                local target = o.count or o.duration
                if target and o.progress >= target then
                    o.done = true
                    o.progress = target
                    fire(opts.onObjectiveComplete, self, o)
                    self:checkObjectives()
                end
                return o
            end
        end
        return nil
    end

    -- Kill credit for kill-count objectives (co-op / SP).
    function mode:recordKill(killerPeer, victimPeer, info)
        info = info or {}
        fire(opts.onKill, self, {
            killer = killerPeer,
            victim = victimPeer,
            info = info,
        })
        if victimPeer then
            fire(opts.onPlayerDeath, self, victimPeer, info)
            fire(opts.onRequestRespawn, self, victimPeer, self.data.respawnDelay)
        end
        -- Enemy kills: info.enemy or killer present without suicide.
        local enemyKill = info.enemy or (info.npc) or (killerPeer and victimPeer == nil)
        if info.enemy == false then enemyKill = false end
        if enemyKill or (info.kind == 'ai') or info.ai then
            for i = 1, #(self.data.objectives or {}) do
                local o = self.data.objectives[i]
                if o.type == 'kills' and not o.done then
                    o.progress = (o.progress or 0) + 1
                    if o.count and o.progress >= o.count then
                        o.done = true
                        o.progress = o.count
                        fire(opts.onObjectiveComplete, self, o)
                    end
                end
            end
            self:checkObjectives()
        end
        -- PvP-style frags still update score if host wants a hybrid.
        if killerPeer and victimPeer and killerPeer ~= victimPeer and not info.enemy then
            local p = ensurePlayer(self, killerPeer)
            p.frags = p.frags + 1
            self:addScore(killerPeer, (self.data.rules and self.data.rules.scorePerKill) or 1)
        end
        return true
    end

    function mode:checkObjectives()
        if self.data.phase ~= 'live' then return nil end
        local objs = self.data.objectives or {}
        if #objs == 0 then return nil end
        if objectivesAllRequiredDone(objs) then
            return self:endRound('objectives')
        end
        return nil
    end

    function mode:tickObjectives(dt, world, entities)
        if self.data.phase ~= 'live' then return end
        local objs = self.data.objectives or {}
        for i = 1, #objs do
            local o = objs[i]
            if not o.done then
                if o.type == 'survive' then
                    o.progress = (o.progress or 0) + (dt or 0)
                    if o.duration and o.progress >= o.duration then
                        o.done = true
                        o.progress = o.duration
                        fire(opts.onObjectiveComplete, self, o)
                    end
                elseif o.type == 'custom' and o.check then
                    local ok = o.check(self, world, entities)
                    if ok then
                        o.done = true
                        o.progress = 1
                        fire(opts.onObjectiveComplete, self, o)
                    end
                elseif o.type == 'kills' and o.count then
                    -- progress advanced via recordKill
                elseif o.type == 'flag' then
                    -- advanced via setObjectiveFlag
                end
            end
        end
        self:checkObjectives()
    end
end

local function countLivingMatching(entities, filter)
    local n = 0
    for i = 1, #(entities or {}) do
        if filter(entities[i]) then n = n + 1 end
    end
    return n
end

---------------------------------------------------------------------------
-- Co-op
---------------------------------------------------------------------------

function Modes.coop(opts)
    opts = opts or {}
    -- Default: clear-map win when no objectives listed; with objectives, host opts in.
    local winClear = opts.winWhenAllDead
    if winClear == nil then
        winClear = opts.objectives == nil
    end
    local rules = {
        kind = 'coop',
        timeLimit = opts.timeLimit,
        warmup = opts.warmup or 0,
        postDelay = opts.postDelay or 0,
        winWhenAllDead = winClear and true or false,
        failOnAllPlayersDead = opts.failOnAllPlayersDead ~= false,
        scorePerKill = opts.scorePerKill or 1,
        respawnDelay = opts.respawnDelay or 0,
        sharedScore = opts.sharedScore and true or false,
    }

    local enemyFilter = opts.enemyFilter or defaultEnemyFilter
    local playerFilter = opts.playerFilter or defaultPlayerFilter

    local mode = Mode.new{
        name = opts.name or 'coop',
        data = {
            rules = rules,
            objectives = normalizeObjectives(opts.objectives),
            defaultTeam = 'players',
            teams = { players = { score = 0, players = {} } },
        },
        onStart = function(m, world, entities)
            m.data.round = (m.data.round or 0) + 1
            m.data.phaseElapsed = 0
            m.data.result = nil
            m.data.winner = nil
            m.data.sawEnemy = false
            m.data.phase = (rules.warmup > 0) and 'warmup' or 'live'
            m.data.objectives = normalizeObjectives(opts.objectives)
            for _, p in pairs(m.data.players) do
                p.frags, p.deaths, p.suicides = 0, 0, 0
                p.team = 'players'
            end
            if m.data.teams then m.data.teams.players.score = 0 end
            if entities and countLivingMatching(entities, enemyFilter) > 0 then
                m.data.sawEnemy = true
            end
            fire(opts.onStart, m, world, entities)
        end,
        onTick = function(m, dt, world, entities)
            stockTickPhases(m, dt, opts)
            if m.data.phase == 'live' then
                m:tickObjectives(dt, world, entities)
                if rules.winWhenAllDead and entities then
                    local livingEnemies = countLivingMatching(entities, enemyFilter)
                    if livingEnemies > 0 then m.data.sawEnemy = true end
                    -- Require having seen an enemy this round so an empty boot does not auto-win.
                    if m.data.sawEnemy and livingEnemies == 0 then
                        m:endRound('clear')
                        fire(opts.onTick, m, dt, world, entities)
                        return
                    end
                end
                if rules.failOnAllPlayersDead then
                    local living = 0
                    if opts.getPlayers then
                        local list = opts.getPlayers(m) or {}
                        for i = 1, #list do
                            local e = list[i]
                            if e and not e.dead then living = living + 1 end
                        end
                    else
                        -- Roster is authoritative: entity lists often include only
                        -- AI, and must not look like a player wipe.
                        for _, p in pairs(m.data.players) do
                            if not p.spectator then
                                local e = p.entity
                                if not e or not e.dead then living = living + 1 end
                            end
                        end
                        if m:playerCount() == 0 and entities then
                            living = countLivingMatching(entities, playerFilter)
                        end
                    end
                    -- Only fail if someone has joined (avoid instant fail at boot).
                    if m:playerCount() > 0 and living == 0 then
                        m:endRound('wipe')
                        fire(opts.onTick, m, dt, world, entities)
                        return
                    end
                end
            end
            fire(opts.onTick, m, dt, world, entities)
        end,
        onStop = opts.onStop,
        onCommand = opts.onCommand,
        onEvent = opts.onEvent,
    }

    attachCommon(mode, opts)
    wireJoinLeave(mode, opts)
    attachObjectives(mode, opts)

    -- Co-op recordKill: enemy kills advance objectives + shared/individual score.
    local baseRecord = mode.recordKill
    function mode:recordKill(killerPeer, victimPeer, info)
        info = info or {}
        local enemyKill = info.enemy or info.ai or info.kind == 'ai'
        if enemyKill and killerPeer then
            local p = ensurePlayer(self, killerPeer)
            p.frags = p.frags + 1
            local delta = rules.scorePerKill or 1
            if rules.sharedScore then
                self:addScore(0, delta)
                if self.data.teams and self.data.teams.players then
                    self.data.teams.players.score =
                        (self.data.teams.players.score or 0) + delta
                end
            else
                self:addScore(killerPeer, delta)
            end
            -- Prevent attachObjectives from double-counting PvP score path.
            info = {
                enemy = true,
                ai = info.ai,
                kind = info.kind or 'ai',
                suicide = info.suicide,
            }
        end
        return baseRecord(self, killerPeer, victimPeer, info)
    end

    function mode:markPlayerDead(peer)
        local p = self.data.players[peer]
        if p and p.entity then p.entity.dead = true end
        if p then p.deaths = p.deaths + 1 end
        fire(opts.onPlayerDeath, self, peer, { wipeCheck = true })
    end

    return mode
end

---------------------------------------------------------------------------
-- Single-player objectives
---------------------------------------------------------------------------

function Modes.singlePlayer(opts)
    opts = opts or {}
    local rules = {
        kind = 'single_player',
        timeLimit = opts.timeLimit,
        warmup = opts.warmup or 0,
        postDelay = opts.postDelay or 0,
        failOnDeath = opts.failOnDeath ~= false,
        winWhenAllDead = opts.winWhenAllDead and true or false,
        scorePerKill = opts.scorePerKill or 1,
        respawnDelay = opts.respawnDelay or 0,
    }

    local enemyFilter = opts.enemyFilter or defaultEnemyFilter
    local peerId = opts.peerId or 0

    local mode = Mode.new{
        name = opts.name or 'single_player',
        data = {
            rules = rules,
            objectives = normalizeObjectives(opts.objectives),
            spPeer = peerId,
        },
        onStart = function(m, world, entities)
            m.data.round = (m.data.round or 0) + 1
            m.data.phaseElapsed = 0
            m.data.result = nil
            m.data.sawEnemy = false
            m.data.phase = (rules.warmup > 0) and 'warmup' or 'live'
            m.data.objectives = normalizeObjectives(opts.objectives)
            local ent = opts.player
            if not ent and m.data.players[peerId] then
                ent = m.data.players[peerId].entity
            end
            ensurePlayer(m, peerId, ent)
            m.score[peerId] = m.score[peerId] or 0
            local p = m.data.players[peerId]
            if p then p.frags, p.deaths, p.suicides = 0, 0, 0 end
            if entities and countLivingMatching(entities, enemyFilter) > 0 then
                m.data.sawEnemy = true
            end
            fire(opts.onStart, m, world, entities)
        end,
        onTick = function(m, dt, world, entities)
            stockTickPhases(m, dt, opts)
            if m.data.phase == 'live' then
                m:tickObjectives(dt, world, entities)

                if rules.winWhenAllDead and entities then
                    local livingEnemies = countLivingMatching(entities, enemyFilter)
                    if livingEnemies > 0 then m.data.sawEnemy = true end
                    if m.data.sawEnemy and livingEnemies == 0 then
                        m:endRound('clear')
                        fire(opts.onTick, m, dt, world, entities)
                        return
                    end
                end

                if rules.failOnDeath then
                    local e
                    if opts.getPlayer then
                        e = opts.getPlayer(m)
                    else
                        local pl = m.data.players[peerId]
                        e = pl and pl.entity
                    end
                    if e and e.dead then
                        m:endRound('death')
                        fire(opts.onTick, m, dt, world, entities)
                        return
                    end
                end
            end
            fire(opts.onTick, m, dt, world, entities)
        end,
        onStop = opts.onStop,
        onCommand = opts.onCommand,
        onEvent = opts.onEvent,
    }

    attachCommon(mode, opts)
    wireJoinLeave(mode, opts)
    attachObjectives(mode, opts)
    return mode
end

---------------------------------------------------------------------------
-- Registry
---------------------------------------------------------------------------

Modes.registry = {
    deathmatch = Modes.deathmatch,
    dm = Modes.deathmatch,
    team_deathmatch = Modes.teamDeathmatch,
    tdm = Modes.teamDeathmatch,
    coop = Modes.coop,
    co_op = Modes.coop,
    single_player = Modes.singlePlayer,
    sp = Modes.singlePlayer,
    objectives = Modes.singlePlayer,
}

function Modes.byName(name, opts)
    local key = tostring(name or ''):lower():gsub('%s+', '_'):gsub('-', '_')
    local factory = Modes.registry[key]
    if not factory then return nil, 'unknown mode: ' .. tostring(name) end
    return factory(opts)
end

function Modes.names()
    return { 'deathmatch', 'team_deathmatch', 'coop', 'single_player' }
end

return Modes
