--[[
    G1: the menu stack — navigation, every row kind's verbs, the two capture
    states, and that options:menuRows() drops in with no adapter.
]]

return function(t)
    local Menu    = require('meatray.game.menu')
    local Options = require('meatray.game.options')
    local Game    = require('meatray.game')

    t.eq(Game.menu, Menu, 'Game.menu is the menu module')

    ---------------------------------------------------------------------
    t.describe('stack: push, back, and the floor')

    local m = Menu.new()
    t.eq(m:isOpen(), false, 'closed until something is pushed')
    t.eq(m:back(), false, 'back on nothing consumes nothing')

    m:push{ id = 'title', rows = {
        { id = 'new', label = 'New Game', kind = 'action' },
        { id = 'options', label = 'Options', kind = 'action' },
        { id = 'quit', label = 'Quit', kind = 'action' },
    } }
    t.eq(m:isOpen(), true, 'open')
    t.eq(m:depth(), 1, 'one screen')
    t.eq(m:selectedRow().id, 'new', 'cursor starts at the top')

    m:push{ id = 'options', rows = { { id = 'x', label = 'X', kind = 'toggle' } } }
    t.eq(m:depth(), 2, 'a second screen stacks')
    t.eq(m:back(), true, 'back pops it')
    t.eq(m:current().id, 'title', 'to the one below')
    t.eq(m:back(), false, 'the bottom screen does not pop — the CALLER closes')
    t.eq(m:isOpen(), true, 'and it is still there')

    ---------------------------------------------------------------------
    t.describe('navigation wraps both ways')

    t.eq(m:navigate(1).id, 'options', 'down')
    t.eq(m:navigate(1).id, 'quit', 'down again')
    t.eq(m:navigate(1).id, 'new', 'and off the end wraps to the top')
    t.eq(m:navigate(-1).id, 'quit', 'up off the top wraps to the bottom')

    ---------------------------------------------------------------------
    t.describe('each row kind answers its verbs')

    local kinds = Menu.new()
    kinds:push{ id = 'k', rows = {
        { id = 'go', label = 'Go', kind = 'action' },
        { id = 'fog', label = 'Fog', kind = 'toggle', value = false },
        { id = 'vol', label = 'Vol', kind = 'slider', value = 0.5,
          min = 0, max = 1, step = 0.25 },
        { id = 'qual', label = 'Quality', kind = 'choice', value = 'low',
          choices = { 'low', 'high' } },
    } }

    local act = kinds:activate()
    t.eq(act.kind, 'action', 'action rows return themselves')
    t.eq(act.row.id, 'go', 'with the row')
    t.eq(kinds:adjust(1), nil, 'and ignore left/right')

    kinds:navigate(1)
    t.eq(kinds:activate().value, true, 'activating a toggle flips it')
    t.eq(kinds:adjust(1).value, true, 'so does adjusting (value not applied here)')

    kinds:navigate(1)
    t.near(kinds:adjust(1).value, 0.75, 1e-9, 'sliders step by their step')
    t.near(kinds:adjust(-1).value, 0.25, 1e-9, 'in both directions')
    kinds:selectedRow().value = 1
    t.near(kinds:adjust(1).value, 1, 1e-9, 'and clamp at their max')

    kinds:navigate(1)
    t.eq(kinds:adjust(1).value, 'high', 'choices cycle')
    kinds:selectedRow().value = 'high'
    t.eq(kinds:adjust(1).value, 'low', 'and wrap')

    ---------------------------------------------------------------------
    t.describe('bind capture: the next key is the answer')

    local bind = Menu.new()
    bind:push{ id = 'opts', rows = {
        { id = 'bind.fire', label = 'Fire', kind = 'bind', value = { 'mouse1' } },
    } }
    local cap = bind:activate()
    t.eq(cap.kind, 'capture', 'activating a bind row starts capture')
    t.eq(bind:capturing(), 'bind', 'and says so')
    t.eq(bind:navigate(1), nil, 'the cursor is frozen while capturing')

    local setKey = bind:feedKey('x')
    t.eq(setKey.kind, 'set', 'the next key is the answer')
    t.eq(setKey.value, 'x', 'verbatim')
    t.eq(bind:capturing(), nil, 'and capture ends')

    bind:activate()
    t.eq(bind:feedKey('escape').kind, 'cancelled', 'escape cancels a capture')
    bind:activate()
    t.eq(bind:back(), true, 'back during capture only ends the capture')
    t.eq(bind:depth(), 1, 'without popping the screen')

    ---------------------------------------------------------------------
    t.describe('text capture: edit, submit, cancel')

    local text = Menu.new()
    text:push{ id = 'join', rows = {
        { id = 'addr', label = 'Address', kind = 'text', value = '' },
    } }
    text:activate()
    text:feedText('meat')
    text:feedText(':6789')
    t.eq(text:selectedRow().value, 'meat:6789', 'typing appends')
    text:feedKey('backspace')
    t.eq(text:selectedRow().value, 'meat:678', 'backspace edits')
    local sub = text:feedKey('return')
    t.eq(sub.kind, 'submit', 'return submits')
    t.eq(sub.value, 'meat:678', 'what was typed')
    t.eq(text:capturing(), nil, 'and entry ends')

    text:activate()
    text:feedText('junk')
    t.eq(text:feedKey('escape').kind, 'cancelled', 'escape abandons the entry')

    ---------------------------------------------------------------------
    t.describe('options:menuRows() drops in with no adapter')

    local o = Options.new()
    local screen = Menu.new()
    screen:push{ id = 'options', rows = o:menuRows() }

    -- Walk to the quality row (a choice) and cycle it through menuSet, the
    -- way the shell does: the menu proposes, options disposes.
    local qualityRow
    for _, row in ipairs(screen:current().rows) do
        if row.id == 'graphics.quality' then qualityRow = row end
    end
    t.ok(qualityRow, 'the options rows include the quality choice')

    while screen:selectedRow().id ~= 'graphics.quality' do
        screen:navigate(1)
    end
    local proposal = screen:adjust(1)
    t.eq(proposal.kind, 'set', 'the menu proposes')
    t.ok(o:menuSet(proposal.row.id, proposal.value), 'options disposes')
    t.eq(o:getGraphics().quality, proposal.value, 'and the setting moved')

    -- A bind row captures and lands through the same split.
    while screen:selectedRow().id ~= 'bind.fire' do
        screen:navigate(1)
    end
    t.eq(screen:activate().kind, 'capture', 'a real bind row captures')
    local landed = screen:feedKey('mouse4')
    t.ok(o:menuSet(landed.row.id, landed.value), 'and the key lands in options')
    t.eq(o:keysOf('fire')[1], 'mouse4', 'as the new bind')
end
