--[[
    C23: meta progression. Currency banks and spends all-or-nothing; unlocks are
    a set with first-time semantics; purchase is atomic; stats accumulate and keep
    bests; the whole thing round-trips through a storage backend.
]]

return function(t)
    local Progression = require('meatray.game.progression')
    local Storage = require('meatray.save.storage')
    local Game = require('meatray.game')

    t.eq(Game.progression, Progression, 'Game.progression is the module')

    ---------------------------------------------------------------------
    t.describe('currency banks and never goes negative')

    local m = Progression.new()
    t.eq(m:currencyAmount(), 0, 'starts empty')
    m:addCurrency(100)
    t.eq(m:currencyAmount(), 100, 'earned 100')
    m:addCurrency(-30)
    t.eq(m:currencyAmount(), 70, 'spent 30 by hand')
    m:addCurrency(-9999)
    t.eq(m:currencyAmount(), 0, 'clamps at zero, never negative')

    ---------------------------------------------------------------------
    t.describe('spend is all-or-nothing')

    m:addCurrency(50)
    t.ok(not m:canAfford(60), 'cannot afford 60 with 50')
    local ok, why = m:spend(60)
    t.ok(not ok and why == 'insufficient', 'refused, with a reason')
    t.eq(m:currencyAmount(), 50, 'and nothing was deducted')
    t.ok(m:spend(50), 'an affordable spend goes through')
    t.eq(m:currencyAmount(), 0, 'balance drops')

    ---------------------------------------------------------------------
    t.describe('unlocks are a set with first-time semantics')

    t.ok(not m:isUnlocked('weapon.plasma'), 'not unlocked yet')
    t.ok(m:unlock('weapon.plasma'), 'unlock returns true the first time')
    t.ok(not m:unlock('weapon.plasma'), 'and false the second (already had it)')
    t.ok(m:isUnlocked('weapon.plasma'), 'it is unlocked')

    ---------------------------------------------------------------------
    t.describe('purchase debits and unlocks atomically')

    m:addCurrency(200)
    t.ok(not m:isUnlocked('armor.heavy'), 'not owned')
    local bought = m:purchase('armor.heavy', 250)
    t.ok(not bought, 'cannot buy what you cannot afford')
    t.ok(not m:isUnlocked('armor.heavy'), 'and it stayed locked')
    t.eq(m:currencyAmount(), 200, 'no currency spent on a failed buy')

    t.ok(m:purchase('armor.heavy', 150), 'an affordable buy succeeds')
    t.ok(m:isUnlocked('armor.heavy'), 'now owned')
    t.eq(m:currencyAmount(), 50, 'and the cost was debited exactly once')

    local again, reason = m:purchase('armor.heavy', 10)
    t.ok(not again and reason == 'owned', 'buying something you own is refused')
    t.eq(m:currencyAmount(), 50, 'and costs nothing')

    ---------------------------------------------------------------------
    t.describe('stats accumulate and keep bests')

    m:addStat('kills', 5)
    m:addStat('kills', 3)
    t.eq(m:getStat('kills'), 8, 'kills accumulate')
    m:recordMax('bestScore', 1000)
    m:recordMax('bestScore', 800)
    t.eq(m:getStat('bestScore'), 1000, 'recordMax keeps the larger')
    m:recordMin('bestTime', 90)
    m:recordMin('bestTime', 75)
    t.eq(m:getStat('bestTime'), 75, 'recordMin keeps the smaller')

    ---------------------------------------------------------------------
    t.describe('recordRun banks a whole run at once')

    local r = Progression.new()
    r:recordRun{ won = true, kills = 12, score = 3400, reward = 50, time = 120 }
    t.eq(r:getStat('runs'), 1, 'one run played')
    t.eq(r:getStat('wins'), 1, 'and won')
    t.eq(r:getStat('kills'), 12, 'kills banked')
    t.eq(r:currencyAmount(), 50, 'reward banked')
    t.eq(r:getStat('bestScore'), 3400, 'best score set')
    t.eq(r:getStat('bestTime'), 120, 'best time set')
    r:recordRun{ won = false, kills = 4, score = 900, time = 200 }
    t.eq(r:getStat('runs'), 2, 'a second run counts')
    t.eq(r:getStat('wins'), 1, 'a loss does not add a win')
    t.eq(r:getStat('kills'), 16, 'kills keep adding')
    t.eq(r:getStat('bestScore'), 3400, 'a worse score does not lower the best')
    t.eq(r:getStat('bestTime'), 120, 'a slower time does not lower the best')

    ---------------------------------------------------------------------
    t.describe('it round-trips through storage')

    local store = Storage.memory()
    m:save(store)
    local loaded = Progression.new()
    t.ok(loaded:load(store), 'load succeeds')
    t.eq(loaded:currencyAmount(), 50, 'currency survived')
    t.ok(loaded:isUnlocked('weapon.plasma'), 'unlock survived')
    t.ok(loaded:isUnlocked('armor.heavy'), 'and the bought one')
    t.eq(loaded:getStat('kills'), 8, 'stats survived')
    t.eq(loaded:getStat('bestTime'), 75, 'and the bests')

    -- Byte-stable across a re-save.
    t.eq(m:serialize(), loaded:serialize(), 'serialisation is stable across a round trip')

    ---------------------------------------------------------------------
    t.describe('a missing file is a clean first run, not an error')

    local fresh = Progression.new()
    t.ok(fresh:load(Storage.memory()), 'loading an empty store just keeps defaults')
    t.eq(fresh:currencyAmount(), 0, 'still zero')
    t.eq(#fresh:unlockedList(), 0, 'nothing unlocked')
end
