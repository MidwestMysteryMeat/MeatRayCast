--[[
    B15: the string table — the missing key returns the key (never blank),
    partial translations fall back cleanly, a bad format cannot crash a frame,
    and the file round-trips.
]]

return function(t)
    local I18N = require('meatray.game.i18n')
    local Game = require('meatray.game')

    t.eq(Game.i18n, I18N, 'Game.i18n is the module')

    ---------------------------------------------------------------------
    t.describe('lookup, and the rule that there is always something to show')

    local L = I18N.new()
    L:define('en', {
        ['menu.new']   = 'New Game',
        ['hud.reload'] = 'reloading %d%%',
        ['mode.dm']    = 'Deathmatch',
    })

    t.eq(L:t('menu.new'), 'New Game', 'a defined key translates')
    t.eq(L:t('hud.reload', 42), 'reloading 42%', 'and formats its params')
    t.eq(L:t('nothing.here'), 'nothing.here',
         'a MISSING key returns the key, never a blank a player would report')

    -- A format that cannot apply must not crash the frame drawing it.
    t.eq(L:t('hud.reload', 'notanumber'), 'reloading %d%%',
         'a bad format returns the raw template, not an error')
    t.eq(L:t('mode.dm', 1, 2, 3), 'Deathmatch',
         'extra args to a param-less template are harmless')

    ---------------------------------------------------------------------
    t.describe('partial translations fall back, never hole')

    L:define('fr', { ['menu.new'] = 'Nouvelle Partie' })
    L:use('fr')
    t.eq(L:t('menu.new'), 'Nouvelle Partie', 'the translated key wins')
    t.eq(L:t('mode.dm'), 'Deathmatch',
         'an untranslated key falls back to English, not to blank')
    t.eq(L:locale(), 'fr', 'the current locale is reported')

    t.eq(L:has('menu.new', 'fr'), true, 'has() sees a real translation')
    t.eq(L:has('mode.dm', 'fr'), false, 'and the gap in a partial one')

    local todo = L:missing('fr')
    t.eq(#todo, 2, 'missing() is the translation to-do list')
    t.eq(todo[1], 'hud.reload', 'sorted, so a diff is readable')
    t.eq(todo[2], 'mode.dm', 'both untranslated keys')

    ---------------------------------------------------------------------
    t.describe('define accumulates; use switches')

    L:define('fr', { ['mode.dm'] = 'Combat à Mort' })
    t.eq(L:t('mode.dm'), 'Combat à Mort', 'a second define adds without clearing')
    t.eq(L:t('menu.new'), 'Nouvelle Partie', 'the first stays')
    t.eq(#L:missing('fr'), 1, 'and the to-do shrinks')

    L:use('en')
    t.eq(L:t('menu.new'), 'New Game', 'switching back to the fallback locale')

    ---------------------------------------------------------------------
    t.describe('files round-trip, comments and multi-line survive')

    local M = I18N.new()
    M:loadText('en', table.concat({
        '# a comment line, ignored',
        'menu.quit=Quit',
        'hud.dead=You died\\non %s',      -- literal backslash-n in the file
        '',
        'weird.key = spaced value ',
    }, '\n'))

    t.eq(M:t('menu.quit'), 'Quit', 'a plain line loads')
    t.eq(M:t('hud.dead', 'Level 3'), 'You died\non Level 3',
         'backslash-n becomes a real newline, and params still format')
    t.eq(M:t('weird.key'), 'spaced value', 'keys and values are trimmed')

    local text = M:saveText('en')
    t.ok(text:find('menu.quit=Quit', 1, true), 'save emits the pairs')
    t.ok(text:find('You died\\non', 1, true), 'and re-escapes the newline')

    local N = I18N.new()
    N:loadText('en', text)
    t.eq(N:t('hud.dead', 'X'), 'You died\non X',
         'a saved file reloads to the same strings')

    t.eq(select(2, M:loadText('en', nil)), 'string required',
         'loading a non-string refuses')

    ---------------------------------------------------------------------
    t.describe('storage backend load/save')

    local Storage = require('meatray.save.storage')
    local mem = Storage.memory()
    local S = I18N.new()
    S:define('de', { ['menu.new'] = 'Neues Spiel' })
    t.ok(S:save(mem, 'de'), 'saves through the backend')

    local S2 = I18N.new()
    t.ok(S2:load(mem, 'de'), 'and loads back')
    S2:use('de')
    t.eq(S2:t('menu.new'), 'Neues Spiel', 'the string survived the trip')
    local missOk, missWhy = S2:load(mem, 'nonexistent')
    t.eq(missOk, nil, 'a missing locale file fails')
    t.ok(missWhy ~= nil, 'with a reason (the backend owns the wording), not a crash')
end
