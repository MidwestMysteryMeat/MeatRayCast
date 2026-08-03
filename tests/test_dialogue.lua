--[[
    C20: the branching conversation model. Linear advance, branching choices,
    flag-gated choices, side-effect flags, once-nodes, and validation of dangling
    links. No authored text is asserted — the fixtures use placeholder tokens,
    because the model owns structure, not content.
]]

return function(t)
    local Dialogue = require('meatray.game.dialogue')
    local Game = require('meatray.game')

    t.eq(Game.dialogue, Dialogue, 'Game.dialogue is the module')

    ---------------------------------------------------------------------
    t.describe('validation catches dangling and stuck nodes')

    t.ok(Dialogue.validate{
        start = 'a', nodes = { a = { text = 'A', ['end'] = true } } },
        'a minimal valid script passes')

    local ok, errs = Dialogue.validate{
        start = 'a', nodes = { a = { text = 'A', to = 'ghost' } } }
    t.ok(not ok, 'a link to a missing node fails')
    t.ok(#errs >= 1, 'with a reason')

    t.ok(not Dialogue.validate{ start = 'missing', nodes = { a = {} } },
         'a missing start node fails')
    t.ok(not Dialogue.validate{
        start = 'a', nodes = { a = { text = 'stuck' } } },
        'a node with no choices/to/end is flagged as stuck')

    ---------------------------------------------------------------------
    t.describe('a linear conversation advances node to node')

    local linear = Dialogue.new{
        start = 'one',
        nodes = {
            one = { speaker = 's', text = 'ONE', to = 'two' },
            two = { text = 'TWO', to = 'three' },
            three = { text = 'THREE', ['end'] = true },
        },
    }
    local first = linear:begin()
    t.eq(first.id, 'one', 'begins at start')
    t.eq(first.speaker, 's', 'carries the speaker token verbatim')
    t.eq(#linear:choices(), 0, 'a linear node has no choices')
    t.ok(linear:advance(), 'advances')
    t.eq(linear:current().id, 'two', 'to the next node')
    linear:advance()
    t.eq(linear:current().id, 'three', 'and the next')
    t.ok(linear:isOver(), 'the end node ends it')
    t.eq(linear:current().id, 'three', 'the end line is still shown while over')
    t.ok(not linear:advance(), 'advancing past the end does nothing')

    ---------------------------------------------------------------------
    t.describe('branching: a choice moves to its target and sets a flag')

    local convo = Dialogue.new{
        start = 'greet',
        nodes = {
            greet = { text = 'HALT', choices = {
                { text = 'ASK', to = 'ask' },
                { text = 'RUDE', to = 'bye', set = 'angered' },
            } },
            ask = { text = 'PASS', to = 'bye' },
            bye = { text = 'BYE', ['end'] = true },
        },
    }
    convo:begin()
    t.eq(#convo:choices(), 2, 'both choices offered')
    t.eq(convo:choices()[1].index, 1, 'choice reports its original index')
    t.ok(convo:choose(2), 'take the rude choice')
    t.eq(convo:current().id, 'bye', 'moved to its target')
    t.ok(convo:hasFlag('angered'), 'and its set-flag stuck')
    t.ok(convo:isOver(), 'reached the end')

    -- Refusing bad choices.
    local c2 = Dialogue.new(convo.script)
    c2:begin()
    t.ok(not c2:choose(5), 'a nonexistent choice is refused')
    t.ok(not c2:advance(), 'and a node with choices refuses a blind advance')

    ---------------------------------------------------------------------
    t.describe('a choice can be gated on a flag')

    local gated = Dialogue.new({
        start = 'door',
        nodes = {
            door = { text = 'LOCKED', choices = {
                { text = 'KNOCK', to = 'door' },
                { text = 'USE_KEY', to = 'open', ['if'] = 'hasKey' },
            } },
            open = { text = 'OPEN', ['end'] = true },
        },
    }, { flags = {} })
    gated:begin()
    t.eq(#gated:choices(), 1, 'the gated choice is hidden without the flag')
    t.ok(not gated:choose(2), 'and cannot be taken')

    local withKey = Dialogue.new(gated.script, { flags = { hasKey = true } })
    withKey:begin()
    t.eq(#withKey:choices(), 2, 'the gated choice appears with the flag')
    t.ok(withKey:choose(2), 'and can be taken')
    t.eq(withKey:current().id, 'open', 'reaching the gated branch')

    ---------------------------------------------------------------------
    t.describe('a once-node is skipped on re-entry')

    local once = Dialogue.new{
        start = 'hub',
        nodes = {
            hub = { text = 'HUB', choices = {
                { text = 'INTRO', to = 'intro' },
                { text = 'DONE', to = 'done' },
            } },
            intro = { text = 'FIRST_TIME', once = true, to = 'hub' },
            done = { text = 'DONE', ['end'] = true },
        },
    }
    once:begin()
    once:choose(1)                       -- into intro (first time)
    t.eq(once:current().id, 'intro', 'the once-node shows the first time')
    once:advance()                       -- back to hub
    t.eq(once:current().id, 'hub', 'back at the hub')
    once:choose(1)                       -- into intro again -> skipped to hub
    t.eq(once:current().id, 'hub', 'the once-node is skipped on re-entry')
    t.eq(once:timesVisited('intro'), 1, 'and was only ever entered once')
end
