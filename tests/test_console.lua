--[[
    F3: the console model — cvars, commands, cheat gating, history,
    completion, and a parser that survives quotes and garbage.
]]

return function(t)
    local Console = require('meatray.game.console')
    local Game    = require('meatray.game')

    t.eq(Game.console, Console, 'Game.console is the console module')

    ---------------------------------------------------------------------
    t.describe('tokenizing: spaces, quotes, and mess')

    local tok = Console.tokenize
    t.eq(#tok('give ammo 20'), 3, 'plain words split')
    t.eq(tok('give "boom stick" 2')[2], 'boom stick', 'quotes hold together')
    t.eq(#tok('  spaced   out  '), 2, 'runs of spaces collapse')
    t.eq(tok('say "unclosed')[2], 'unclosed', 'an unclosed quote takes the rest')
    t.eq(#tok(''), 0, 'empty is empty')

    ---------------------------------------------------------------------
    t.describe('cvars: typed, clamped, watched')

    local con = Console.new()
    con:defineCvar('cl_showfps', { default = true, help = 'fps readout' })
    con:defineCvar('r_scale', { default = 1, min = 0.25, max = 1 })
    con:defineCvar('name', { default = 'meat' })

    t.eq(con:get('cl_showfps'), true, 'bool default')
    t.eq(con:get('r_scale'), 1, 'number default')

    t.eq(con:set('cl_showfps', 'off'), false, 'off is false')
    t.eq(con:set('cl_showfps', '1'), true, '1 is true')
    t.eq(select(2, con:set('cl_showfps', 'maybe')), 'expected a boolean (1/0/on/off)',
         'garbage refuses with the accepted spellings')

    t.eq(con:set('r_scale', 9), 1, 'numbers clamp high')
    t.eq(con:set('r_scale', 0), 0.25, 'and low')
    t.eq(select(2, con:set('r_scale', 'wide')), 'expected a number', 'and type-check')

    local seen
    con:defineCvar('sv_gravity', {
        default = 800,
        onChange = function(name, v, old) seen = { name, v, old } end,
    })
    con:set('sv_gravity', 600)
    t.eq(seen[2], 600, 'onChange fires with the new value')
    t.eq(seen[3], 800, 'and the old one')
    seen = nil
    con:set('sv_gravity', 600)
    t.eq(seen, nil, 'setting the same value is not a change')

    t.eq(select(2, con:set('sv_nope', 1)), 'no such cvar: sv_nope', 'unknown refuses')

    ---------------------------------------------------------------------
    t.describe('execute: commands, bare cvars, cvar writes')

    local given
    con:register('give', { help = 'give <item> [count]' }, function(_, args)
        given = { args[1], tonumber(args[2]) or 1 }
        return 'gave ' .. given[2] .. ' ' .. given[1]
    end)

    local ok, out = con:execute('give ammo.pistol 20')
    t.eq(ok, true, 'a command runs')
    t.eq(out, 'gave 20 ammo.pistol', 'and reports')
    t.eq(given[1], 'ammo.pistol', 'with its arguments')

    ok, out = con:execute('r_scale')
    t.eq(ok, true, 'a bare cvar name prints')
    t.eq(out, 'r_scale = 0.25', 'its current value')

    con:execute('r_scale 0.5')
    t.eq(con:get('r_scale'), 0.5, 'name plus value sets')

    ok, out = con:execute('warp 1 2')
    t.eq(ok, false, 'unknown names refuse')
    t.ok(out:find('unknown'), 'and say so')

    ok = con:execute('')
    t.eq(ok, true, 'an empty line is fine and does nothing')

    con:register('boom', function() error('handler bug') end)
    ok, out = con:execute('boom')
    t.eq(ok, false, 'a handler that raises is caught')
    t.ok(out:find('handler bug'), 'and its message is printed, not swallowed')

    t.ok(#con:lines() > 0, 'everything echoed into the ring')
    con:clear()
    t.eq(#con:lines(), 0, 'clear clears')

    ---------------------------------------------------------------------
    t.describe('cheats stop working the moment the world is not yours')

    local mode = 'solo'
    local gated = Console.new{
        allowCheats = function()
            if mode == 'client' then
                return false, 'cheats are for your own world'
            end
            return true
        end,
    }
    local godOn = false
    gated:register('god', { cheat = true }, function()
        godOn = not godOn
        return 'god ' .. (godOn and 'on' or 'off')
    end)
    gated:defineCvar('sv_cheatspeed', { default = 1, cheat = true })

    t.eq(gated:execute('god'), true, 'solo may cheat')
    t.eq(godOn, true, 'and it took')

    mode = 'client'
    local refused, why = gated:execute('god')
    t.eq(refused, false, 'a client may not')
    t.eq(why, 'cheats are for your own world', 'told in the session\'s words')
    t.eq(godOn, true, 'and nothing changed')
    t.eq(select(2, gated:set('sv_cheatspeed', 3)), 'cheats are for your own world',
         'cheat CVARS are gated the same way')

    mode = 'solo'
    t.eq(gated:execute('god'), true, 'back in your own world, back in business')

    ---------------------------------------------------------------------
    t.describe('help knows everything registered')

    local h = Console.new()
    h:defineCvar('r_fog', { default = true, help = 'distance fog' })
    local _, helpOut = h:execute('help r_fog')
    t.ok(helpOut:find('distance fog'), 'help describes a cvar')
    _, helpOut = h:execute('help echo')
    t.ok(helpOut:find('echo'), 'and a command')
    _, helpOut = h:execute('help nothing_here')
    t.ok(helpOut:find('no such'), 'and admits ignorance')

    local _, listOut = h:execute('cvarlist')
    t.ok(tostring(listOut):find('r_fog') or (type(listOut) == 'table'
         and table.concat(listOut, '\n'):find('r_fog')), 'cvarlist lists')

    ---------------------------------------------------------------------
    t.describe('history walks like a shell')

    local sh = Console.new()
    sh:execute('echo one')
    sh:execute('echo two')
    sh:execute('echo three')
    t.eq(sh:historyPrev(), 'echo three', 'up: newest first')
    t.eq(sh:historyPrev(), 'echo two', 'up again: older')
    t.eq(sh:historyNext(), 'echo three', 'down: back toward now')
    t.eq(sh:historyNext(), '', 'past the newest is the empty prompt')
    t.eq(sh:historyPrev(), 'echo three', 'and up starts from the end again')

    ---------------------------------------------------------------------
    t.describe('completion extends and enumerates')

    local tc = Console.new()
    tc:defineCvar('cl_showfps', { default = true })
    tc:defineCvar('cl_showpos', { default = false })
    tc:register('clear_decals', function() end)

    local common, matches = tc:complete('cl_show')
    t.eq(common, 'cl_show', 'ambiguous prefix does not guess')
    t.eq(#matches, 2, 'but lists both')

    common, matches = tc:complete('cl_showf')
    t.eq(common, 'cl_showfps', 'a unique prefix completes fully')
    t.eq(#matches, 1, 'one candidate')

    common = tc:complete('cle')
    t.eq(common, 'clear_decals', 'commands complete too')

    common, matches = tc:complete('zz')
    t.eq(#matches, 0, 'no matches leaves the prefix alone')
    t.eq(common, 'zz', 'verbatim')
end
