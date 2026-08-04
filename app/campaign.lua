--[[
    app.campaign — the demo campaign (F4) and the intermission confirm.

    Fifth cut of un-god-filing main.lua. Three missions over the maps that
    ship: cross the arena, find the vault in the secrets map (its exit is
    INSIDE the secret — finding it is finishing), then clear the arena.
    Between missions the intermission model rolls the numbers up; fire
    hurries, fire continues.

    Returns { start, confirm }: start builds and starts the campaign;
    confirm is the intermission's two-press handler (true when the press
    belonged to the tally screen).
]]

return function(ctx)
    local game, Game, note = ctx.game, ctx.Game, ctx.note
    local activePlayer, loadAuthored = ctx.activePlayer, ctx.loadAuthored

    local M = {}

    function M.start()
        game.campaign = Game.campaign.new{
            id = 'demo',
            title = 'Meat Run',
            missions = {
                { id = 'arena', map = 'maps/arena.map', name = 'The Arena',
                  exitTiles = { tx1 = 19, ty1 = 16, tx2 = 20, ty2 = 17 },
                  parTime = 90, intermission = 3600, loseOnPlayerDeath = false },
                { id = 'secrets', map = 'maps/secrets.map', name = 'The Vault',
                  exitTiles = { tx1 = 3, ty1 = 10, tx2 = 4, ty2 = 10 },
                  parTime = 60, intermission = 3600, loseOnPlayerDeath = false },
                { id = 'finale', map = 'maps/arena.map', name = 'Clear It Out',
                  winWhenAllDead = true,
                  parTime = 180, intermission = 3600, loseOnPlayerDeath = false },
            },
            getPlayer = function() return activePlayer() end,
            onLoadMap = function(_, path)
                loadAuthored(path)
            end,
            onMissionStart = function(camp, mission)
                -- The kill denominator: how many brains the map woke up with.
                local total = 0
                for _, e in ipairs(game.entities) do
                    if e.components and e.components.brain then total = total + 1 end
                end
                game.campaignKillTotal = total
                game.campaignTriggers = camp:makeTriggers()
                -- F6: the mission name is a moment, not a log line.
                game.messages:centerprint(mission.name or mission.id,
                                          { size = 'big', hold = 2.5, priority = 3 })
            end,
            onMissionEnd = function(camp, mission, result)
                local secretsFound, secretsTotal = 0, 0
                if game.secretTracker then
                    secretsFound = game.secretTracker:found()
                    secretsTotal = game.secretTracker:total()
                end
                game.intermission:begin{
                    title = mission.name or mission.id,
                    result = result.outcome,
                    next_ = camp.missions[result.index + 1]
                            and (camp.missions[result.index + 1].name
                                 or camp.missions[result.index + 1].id) or nil,
                    stats = {
                        elapsed = result.stats.elapsed,
                        parTime = result.stats.parTime,
                        kills = result.stats.kills,
                        killsTotal = game.campaignKillTotal,
                        secrets = secretsFound,
                        secretsTotal = secretsTotal,
                        coverage = game.automap:coverage(game.world),
                        deaths = result.stats.deaths,
                    },
                }
            end,
            onCampaignWin = function(camp)
                game.campaignDone = true
                -- C23: bank the run into meta progression and persist it — totals
                -- climb, currency accrues, the completion unlock is granted once.
                if game.progression then
                    game.progression:recordRun{
                        won = true,
                        kills = camp.totals.kills,
                        reward = 100 + (camp.totals.secrets or 0) * 25,
                        time = camp.totals.elapsed,
                    }
                    game.progression:unlock('campaign.cleared')
                    game.progression:save(game.storage)
                end
                game.intermission:begin{
                    title = 'campaign complete',
                    result = 'win',
                    stats = {
                        elapsed = camp.totals.elapsed,
                        kills = camp.totals.kills,
                        secrets = camp.totals.secrets,
                        deaths = camp.totals.deaths,
                    },
                }
            end,
        }
        game.campaignDone = false
        game.campaign:start()
    end

    -- Fire / F while the tally is up: the first press hurries, the second
    -- continues. Returns true when the press belonged to the screen.
    function M.confirm()
        if not game.intermission:active() then return false end
        local what = game.intermission:confirm()
        if what == 'continued' then
            if game.campaignDone then
                game.campaign = nil
                game.campaignTriggers = nil
                game.campaignDone = false
                note('campaign over — sandbox resumes')
            elseif game.campaign then
                game.campaign:advance()
            end
            game.intermission:reset()
        end
        return true
    end

    return M
end
