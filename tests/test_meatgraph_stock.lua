--[[
    C21: stock event nodes — the common script beats as ready-made events.

    EventOnTimer fires once per node, floatA seconds after the graph starts.
    EventOnAllDead fires once, the tick the last enemy dies (and never on a map
    that had no enemies to begin with). EventOnSecret is fired by an external
    producer and carries the secret's name. All three go through the same
    pump/fire path the trigger events do, and all stay inside the F9 sandbox.
]]

return function(t)
    local BP = require('meatray.game.meatgraph_ray')

    -- A tiny enemy stand-in: an entity with a brain component, alive unless
    -- flagged dead. countEnemies ignores players and pickups.
    local function enemy() return { dead = false, has = function(_, c) return c == 'brain' end } end
    local function player() return { dead = false, has = function(_, c) return c == 'player' end } end

    ---------------------------------------------------------------------
    t.describe('the new kinds are in the sandbox vocabulary as events')

    for _, k in ipairs({ 'EventOnAllDead', 'EventOnTimer', 'EventOnSecret' }) do
        t.eq(BP.KIND_CATEGORY[k], 'event', k .. ' is an event kind')
    end

    ---------------------------------------------------------------------
    t.describe('EventOnTimer fires once, after its delay')

    local timerGraph = BP.fromTable{
        name = 'timers',
        nodes = {
            { id = 1, kind = 'EventOnTimer', strA = 'wave1', floatA = 1.0 },
            { id = 2, kind = 'ActionLog', strA = 'wave one' },
            { id = 3, kind = 'EventOnTimer', strA = 'wave2', floatA = 3.0 },
            { id = 4, kind = 'ActionLog', strA = 'wave two' },
        },
        links = {
            { fromNode = 1, fromPin = 0, toNode = 2, toPin = 0 },
            { fromNode = 3, fromPin = 0, toNode = 4, toPin = 0 },
        },
    }
    t.ok(timerGraph, 'timer graph builds')
    t.ok(timerGraph:hasEvent('timer'), 'has the timer event')

    local notes = {}
    local api = BP.apiFor{ notes = notes }

    -- Half a second: nothing due yet.
    BP.pumpStockEvents(timerGraph, api, 0.5, {})
    t.eq(#notes, 0, 'no timer before its delay')

    -- Cross 1.0s: wave1 fires, wave2 does not.
    BP.pumpStockEvents(timerGraph, api, 0.6, {})
    t.eq(#notes, 1, 'wave1 fired at 1.1s')
    t.eq(notes[1], 'wave one', 'the right timer ran')

    -- Keep pumping past 1.0 but before 3.0: wave1 must NOT re-fire.
    BP.pumpStockEvents(timerGraph, api, 1.0, {})
    t.eq(#notes, 1, 'a fired timer does not repeat')

    -- Cross 3.0s total: wave2 fires.
    BP.pumpStockEvents(timerGraph, api, 1.5, {})   -- elapsed now 3.6
    t.eq(#notes, 2, 'wave2 fired')
    t.eq(notes[2], 'wave two', 'the second timer ran, once')

    ---------------------------------------------------------------------
    t.describe('EventOnAllDead fires once when the last enemy dies')

    local deadGraph = BP.fromTable{
        name = 'clear',
        nodes = {
            { id = 1, kind = 'EventOnAllDead' },
            { id = 2, kind = 'ActionLog', strA = 'room cleared' },
        },
        links = { { fromNode = 1, fromPin = 0, toNode = 2, toPin = 0 } },
    }
    local e1, e2 = enemy(), enemy()
    local ents = { e1, e2, player() }
    notes = {}
    api = BP.apiFor{ notes = notes }

    BP.pumpStockEvents(deadGraph, api, 0.1, { entities = ents })
    t.eq(#notes, 0, 'not cleared while enemies live')
    e1.dead = true
    BP.pumpStockEvents(deadGraph, api, 0.1, { entities = ents })
    t.eq(#notes, 0, 'still one enemy up')
    e2.dead = true
    BP.pumpStockEvents(deadGraph, api, 0.1, { entities = ents })
    t.eq(#notes, 1, 'cleared when the last one falls')
    t.eq(notes[1], 'room cleared', 'the all-dead chain ran')
    -- And never again.
    BP.pumpStockEvents(deadGraph, api, 0.1, { entities = ents })
    t.eq(#notes, 1, 'all-dead is one shot')

    ---------------------------------------------------------------------
    t.describe('all-dead does NOT trip on a map with no enemies')

    local emptyDead = BP.fromTable{
        name = 'empty',
        nodes = {
            { id = 1, kind = 'EventOnAllDead' },
            { id = 2, kind = 'ActionLog', strA = 'cleared' },
        },
        links = { { fromNode = 1, fromPin = 0, toNode = 2, toPin = 0 } },
    }
    notes = {}
    api = BP.apiFor{ notes = notes }
    for _ = 1, 5 do BP.pumpStockEvents(emptyDead, api, 0.1, { entities = { player() } }) end
    t.eq(#notes, 0, 'zero enemies from the start never fires all-dead')

    ---------------------------------------------------------------------
    t.describe('EventOnSecret carries the secret name to the graph')

    local secretGraph = BP.fromTable{
        name = 'secret',
        nodes = {
            { id = 1, kind = 'EventOnSecret' },
            { id = 2, kind = 'ActionLog' },   -- logs its message input (pin 2)
        },
        -- Wire the secret's name (EventOnSecret pin 1) into the log message pin.
        links = {
            { fromNode = 1, fromPin = 0, toNode = 2, toPin = 0 },
            { fromNode = 1, fromPin = 1, toNode = 2, toPin = 2 },
        },
    }
    notes = {}
    api = BP.apiFor{ notes = notes }
    local fired = secretGraph:fire('secret', api, { secret = 'vault' })
    t.eq(fired, true, 'secret event fires')
    t.eq(notes[1], 'vault', 'the secret name reached the log')

    ---------------------------------------------------------------------
    t.describe('a graph of only stock events passes the F9 sandbox')

    local ok = BP.validate(timerGraph)
    t.ok(ok, 'timer graph validates against the node allowlist')
    local hardened = BP.harden(deadGraph)
    t.ok(hardened, 'all-dead graph hardens (nothing outside the vocabulary)')
end
