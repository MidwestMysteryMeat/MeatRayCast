--[[
    app.console — the demo's console: every cvar and command in one place.

    First cut of breaking up main.lua (the standing "no god files" debt):
    this module owns what the backtick console can do. It is wiring, not
    engine — meatray/ modules never know it exists — so it lives in app/,
    the demo-application layer beside main.lua.

    The contract: main.lua calls this once, inside love.load, with a ctx of
    the demo's own functions (spawnBot, loadAuthored, activePlayer, ...).
    Everything in ctx already exists by then — registration happens after
    every local in main.lua is assigned — so the ctx carries values, not
    promises. A command added later goes here, takes what it needs from
    ctx, and main.lua only grows by the ctx field.

    Behaviour is byte-for-byte what main.lua did; only the address changed.
]]

return function(ctx)
    local game, Game, MeatRay = ctx.game, ctx.Game, ctx.MeatRay
    local Inventory = ctx.Inventory
    local activePlayer, activeWorld = ctx.activePlayer, ctx.activeWorld
    local loadProcedural, loadAuthored = ctx.loadProcedural, ctx.loadAuthored
    local hostAdoptWorld, mountProject = ctx.hostAdoptWorld, ctx.mountProject
    local spawnBot, spawnNeurobot = ctx.spawnBot, ctx.spawnNeurobot
    local spawnCrowdAgent = ctx.spawnCrowdAgent
    local applyTemplate, startCampaign = ctx.applyTemplate, ctx.startCampaign

    -- F3: the console. Cheats are gated on a QUESTION answered at execute
    -- time — the same process moves between solo, hosting and joining, and
    -- god must stop working the moment the world stops being yours. A
    -- running demo also refuses cheats: a 'give' mid-recording forks the
    -- timeline the divergence check exists to protect.
    game.console = Game.console.new{
        allowCheats = function()
            if game.client then return false, 'cheats are for your own world' end
            if game.demoRec or game.demoPlay then
                return false, 'cheats would fork the demo'
            end
            return true
        end,
    }
    game.console:defineCvar('noclip', {
        default = false, cheat = true, help = 'walk through walls',
        onChange = function(_, v) game.noclip = v end,
    })
    game.console:register('god', {
        cheat = true, help = 'god — toggle damage immunity',
    }, function()
        local player = activePlayer()
        if not player then return 'no player' end
        if Game.effects.hasTag(player, 'status.god') then
            Game.effects.removeById(player, 'god')
            return 'god off'
        end
        local okG, why = Game.effects.applySpec(player, {
            id = 'god', duration = 1e9,
            grantedTags = { 'status.god' }, immunityTags = { 'damage' },
        })
        return okG and 'god on' or ('god failed: ' .. tostring(why))
    end)
    game.console:register('give', {
        cheat = true, help = 'give <item> [count]',
    }, function(_, cargs)
        local player = activePlayer()
        if not player then return 'no player' end
        if not cargs[1] then return 'give what?' end
        local n = tonumber(cargs[2]) or 1
        local okGive, why = Inventory.add(player, cargs[1], n)
        if not okGive then return 'refused: ' .. tostring(why) end
        return ('gave %d %s'):format(n, cargs[1])
    end)
    game.console:register('map', {
        cheat = true, help = 'map <name|procedural> [seed] — load a level',
    }, function(_, cargs)
        local which = cargs[1]
        if not which then return 'map what? (a maps/ name, or procedural)' end
        if which == 'procedural' or which == 'proc' then
            game.seed = tonumber(cargs[2]) or (game.seed + 1)
            loadProcedural()
            -- B14: live-swap on a running host.
            hostAdoptWorld('procedural')
            return 'procedural, seed ' .. game.seed
        end
        -- A mounted pack can provide a map by id; prefer it over maps/ so
        -- content ships without touching the demo's own map folder. `resolve`
        -- returns two values, so it cannot hide behind `and` — that truncates a
        -- multi-return to one and `fromPack` would always be nil (luacheck W221).
        local packPath, fromPack
        if game.packs then packPath, fromPack = game.packs:resolve('map', which) end
        if packPath then
            loadAuthored(packPath)
            hostAdoptWorld(which)
            return ('loaded %s from pack %s%s'):format(which, fromPack,
                game.host and ' (host re-synced)' or '')
        end
        loadAuthored('maps/' .. which .. '.map')
        hostAdoptWorld(which)
        return 'loaded ' .. which .. (game.host and ' (host re-synced)' or '')
    end)
    game.console:register('mover', {
        help = 'mover <id> [up|down|toggle] — drive an authored lift',
    }, function(_, cargs)
        if not game.movers then return 'this map has no movers' end
        local id = cargs[1]
        if not id then
            local ids = {}
            for _, m in ipairs(game.movers.list or {}) do ids[#ids + 1] = tostring(m.id) end
            return #ids > 0 and ('movers: ' .. table.concat(ids, ' ')) or 'no movers'
        end
        -- Ids authored in a .map are strings; a bare number is still a string here.
        if not game.movers:get(id) then return 'no mover "' .. id .. '"' end
        local how = cargs[2] or 'toggle'
        if how == 'up' then game.movers:call(id, true)
        elseif how == 'down' then game.movers:call(id, false)
        else game.movers:toggle(id) end
        return ('mover %s %s'):format(id, how)
    end)
    game.console:register('ambient', {
        help = 'ambient — the room-tone zone the player is standing in',
    }, function()
        if not game.ambient then return 'this map has no ambient zones' end
        return 'room tone: ' .. (game.ambient:currentSound() or 'silence')
    end)
    game.console:register('meta', {
        help = 'meta [reset] — show meta progression (currency, unlocks, stats)',
    }, function(_, cargs)
        local m = game.progression
        if not m then return 'no progression' end
        if cargs[1] == 'reset' then
            game.progression = Game.progression.new()
            game.progression:save(game.storage)
            return 'progression reset'
        end
        local lines = { ('currency: %d'):format(m:currencyAmount()) }
        local unlocks = m:unlockedList()
        lines[#lines + 1] = 'unlocks: ' .. (#unlocks > 0 and table.concat(unlocks, ' ') or '(none)')
        for _, name in ipairs({ 'runs', 'wins', 'kills', 'bestScore', 'bestTime' }) do
            if m:getStat(name) ~= 0 then
                lines[#lines + 1] = ('%s: %s'):format(name, tostring(m:getStat(name)))
            end
        end
        return lines
    end)
    game.console:register('rail', {
        help = 'rail [stop] — play a demo cutscene camera over this map',
    }, function(_, cargs)
        if cargs[1] == 'stop' then game.rail = nil; return 'rail stopped' end
        local w = activeWorld()
        if not w then return 'no world' end
        -- A scripted fly-through built from the map's own dimensions: corner,
        -- along a wall, into the middle (dwell), out to the far corner. Content-
        -- free — it demonstrates the rail, the author writes the real beats.
        local cx, cy = w.width * 0.5, w.height * 0.5
        game.rail = Game.rails.new({
            { x = 1.5, y = 1.5, angle = 0.7, hold = 0.4 },
            { x = cx, y = 1.5, angle = 1.2, travel = 1.5 },
            { x = cx, y = cy, angle = 2.4, travel = 1.5, hold = 0.4 },
            { x = w.width - 1.5, y = w.height - 1.5, angle = 3.9, travel = 1.8 },
        }, { ease = 'smooth' })
        game.rail:play()
        return 'rail playing (`rail stop` to cancel)'
    end)
    game.console:register('packs', {
        help = 'packs — list mounted asset packs and what they provide',
    }, function()
        local mounted = game.packs and game.packs:mounted() or {}
        if #mounted == 0 then return 'no packs mounted (drop folders in packs/)' end
        local lines = { ('%d pack(s) mounted:'):format(#mounted) }
        for _, p in ipairs(mounted) do
            lines[#lines + 1] = ('  %s v%s'):format(p.id, p.version or '?')
        end
        for _, kind in ipairs({ 'map', 'graph' }) do
            for _, a in ipairs(game.packs:list(kind)) do
                lines[#lines + 1] = ('  %s %s  <- %s'):format(kind, a.id, a.pack)
            end
        end
        return lines
    end)
    -- H1: mount a project mid-session; its maps join the `map <id>` pool.
    game.console:register('project', {
        help = 'project [dir] — mount a game project folder (no arg: show current)',
    }, function(_, cargs)
        local dir = cargs[1]
        if not dir then
            if not game.project then return 'no project (try: project projects/mygame)' end
            local m = game.project.manifest
            return ('%s v%s — %d map(s), start %s, at %s'):format(
                m.name, m.version or '?', #game.project:mapIds(),
                tostring(game.project:startMapId()), game.project.dir)
        end
        if mountProject(dir) then
            return 'mounted — `map ' .. tostring(game.project:startMapId()) .. '` to play'
        end
        return 'could not mount ' .. dir .. ' (see log)'
    end)
    game.console:register('bot', {
        cheat = true, help = 'bot [n] — add n computer players (default 1)',
    }, function(_, cargs)
        local n = math.max(1, math.min(16, math.floor(tonumber(cargs[1]) or 1)))
        local added = 0
        for _ = 1, n do if spawnBot() then added = added + 1 end end
        game.messages:notify(('%d bot(s) joined'):format(added))
        return ('added %d bot(s), %d total'):format(added, #game.bots)
    end)
    -- I2: same entity, same INPUT path, but the brain is a neural net —
    -- fresh random, or a file scripts/evolve.lua trained.
    game.console:register('neurobot', {
        cheat = true, help = 'neurobot [n] [brainfile] — add NN-driven players (default 1)',
    }, function(_, cargs)
        local n = math.max(1, math.min(16, math.floor(tonumber(cargs[1]) or 1)))
        local brainText
        if cargs[2] then
            local f = io.open(cargs[2], 'rb')
            if not f then return 'cannot read ' .. tostring(cargs[2]) end
            brainText = f:read('*a')
            f:close()
        end
        local added = 0
        for _ = 1, n do if spawnNeurobot(brainText) then added = added + 1 end end
        game.messages:notify(('%d neurobot(s) joined'):format(added))
        return ('added %d neurobot(s), %d bot-driven total'):format(added, #game.bots)
    end)
    -- I1: a flock that follows the player. Crowd members are imps with the
    -- monster brain removed, so they die and replicate like any entity.
    game.console:register('crowd', {
        cheat = true, help = 'crowd [n] — spawn n crowd agents that flock to you (default 8)',
    }, function(_, cargs)
        if not game.world then return 'no world' end
        local n = math.max(1, math.min(200, math.floor(tonumber(cargs[1]) or 8)))
        -- LOD on: agents beyond 10 tiles of the player stride 3:1, which is
        -- what makes a 200-strong flock affordable on the fixed tick.
        game.crowd = game.crowd or MeatRay.crowd.new(game.world, {
            seed = 42, lod = { radius = 10, stride = 3 },
        })
        game.crowdGoal = nil     -- re-aim at the player on the next tick
        local added = 0
        for _ = 1, n do if spawnCrowdAgent() then added = added + 1 end end
        return ('crowd: %d added, %d in the flock — they follow you'):format(
            added, game.crowd:count())
    end)
    game.console:register('template', {
        cheat = true,
        help = 'template [name] — list genres, or switch the demo to one',
    }, function(_, cargs)
        if not cargs[1] then
            local lines = { 'templates:' }
            for _, n in ipairs(Game.template.list()) do
                lines[#lines + 1] = '  ' .. Game.template.summary(n)
            end
            return lines
        end
        local ok, why = applyTemplate(cargs[1])
        return ok and ('switched to ' .. cargs[1]) or ('cannot: ' .. tostring(why))
    end)
    game.console:register('callvote', {
        help = 'callvote restart | map <name> | kick <peerId>',
    }, function(_, cargs)
        local kind = cargs[1]
        if not kind then return 'callvote restart | map <name> | kick <peerId>' end
        if game.client then
            game.client:callVote(kind, { map = cargs[2],
                                         target = tonumber(cargs[2]) })
            return 'vote called'
        elseif game.host and game.host.vote then
            -- A listen host votes as peer 0.
            local electorate = { 0 }
            for _, p in pairs(game.host.peers) do
                if p.joined then electorate[#electorate + 1] = p.peerId end
            end
            local ok, why = game.host.vote:call(kind,
                { by = 0, map = cargs[2], target = tonumber(cargs[2]) }, electorate)
            return ok and 'vote called' or ('cannot: ' .. tostring(why))
        end
        return 'voting needs a hosted or joined game'
    end)
    game.console:register('vote', {
        help = 'vote yes | no — answer the current vote',
    }, function(_, cargs)
        local yes = (cargs[1] == 'yes' or cargs[1] == 'y' or cargs[1] == '1')
        if game.client then game.client:castVote(yes)
        elseif game.host and game.host.vote then game.host.vote:cast(0, yes)
        else return 'no vote to answer' end
        return 'ballot cast'
    end)
    game.console:register('campaign', {
        cheat = true, help = 'campaign — start the three-mission demo campaign',
    }, function()
        startCampaign()
        return 'campaign started — reach the exit'
    end)
    game.console:register('stat', {
        help = 'stat net — connection and replication numbers',
    }, function(_, cargs)
        if cargs[1] ~= 'net' then return 'stat what? (net)' end
        if game.host then
            local h = game.host
            -- D34: the trust-boundary counters beside the connection line, so an
            -- op watches abuse being refused without tailing a log.
            local sec = h.securityStats and h:securityStats() or {}
            return {
                ('hosting on UDP %d — %d player(s)'):format(h.port, h:playerCount()),
                ('reach: %s'):format(tostring(h.report and h.report.reach)),
                ('refused: %d malformed, %d wrong-way, %d flood, %d throttled, %d rejected, %d bans')
                    :format(sec.malformed or 0, sec.wrongWay or 0, sec.limited or 0,
                            sec.throttled or 0, sec.rejected or 0, sec.bans or 0),
            }
        elseif game.client then
            local c = game.client
            return {
                ('client of %s (%s)'):format(c.address, c.state),
                ('snapshots %d, corrections %d'):format(c.snapshots, c.corrections),
            }
        end
        return 'solo: no network'
    end)
    game.console:register('quit', { help = 'quit — leave' }, function()
        love.event.quit()
        return 'bye'
    end)
end
