--[[
    Logical names, extensions and search paths.

    Dull arithmetic-free string work, and worth asserting for one reason: every
    failure here is silent. A name derived with its extension still attached looks
    correct in a log line and never matches a lookup, so the asset resolves to a
    placeholder and the only symptom is art that never appears. Getting this
    wrong costs an hour of looking at the renderer.
]]

return function(t)
    local Names = require('meatray.asset.names')

    ---------------------------------------------------------------------
    t.describe('splitting paths, on either separator')

    local dir, base = Names.split('assets/sprites/imp.png')
    t.eq(dir, 'assets/sprites', 'the directory comes back')
    t.eq(base, 'imp.png', 'and the final component')

    dir, base = Names.split('assets\\sprites\\imp.png')
    t.eq(dir, 'assets/sprites', 'a Windows path splits the same way')
    t.eq(base, 'imp.png', 'and gives the same basename')

    dir, base = Names.split('imp.png')
    t.eq(dir, '', 'a bare filename has no directory')
    t.eq(base, 'imp.png', 'and is entirely its own basename')

    t.eq(Names.basename(''), '', 'an empty path has an empty basename')
    t.eq(Names.basename(nil), '', 'and so does nil, rather than erroring')

    t.describe('extensions')
    t.eq(Names.ext('imp.png'), 'png', 'a simple extension')
    t.eq(Names.ext('IMP.PNG'), 'png', 'lowercased, so matching is case-insensitive')
    t.eq(Names.ext('a/b/c.wav'), 'wav', 'read from the basename, not the path')
    t.eq(Names.ext('archive.tar.gz'), 'gz', 'only the last one counts')
    t.eq(Names.ext('noextension'), '', 'no extension is an empty string, not nil')

    -- The trap: a dot in a directory name is not the file's extension.
    t.eq(Names.ext('my.assets/imp'), '', 'a dotted directory is not an extension')
    t.eq(Names.ext('my.assets/imp.png'), 'png', 'and does not confuse a real one')

    t.eq(Names.stripExt('assets/sprites/imp.png'), 'imp', 'stripExt returns the bare basename')
    t.eq(Names.stripExt('imp'), 'imp', 'and leaves an extension-free name alone')

    t.describe('joining')
    t.eq(Names.join('assets', 'imp.png'), 'assets/imp.png', 'a plain join')
    t.eq(Names.join('assets/', 'imp.png'), 'assets/imp.png', 'a trailing separator is not doubled')
    t.eq(Names.join('assets', '/imp.png'), 'assets/imp.png', 'nor a leading one')
    t.eq(Names.join('', 'imp.png'), 'imp.png', 'an empty left side yields the right')
    t.eq(Names.join('assets', ''), 'assets', 'and an empty right side yields the left')

    t.describe('what looks like a path')
    t.ok(Names.isPathLike('assets/imp.png'), 'a path with a separator')
    t.ok(Names.isPathLike('imp.png'), 'a bare filename with an extension')
    t.ok(Names.isPathLike('assets\\imp.png'), 'a Windows path')
    t.ok(not Names.isPathLike('imp'), 'a logical name is not a path')

    ---------------------------------------------------------------------
    t.describe('normalising a name')

    t.eq(Names.normalise('imp'), 'imp', 'an already-clean name is unchanged')
    t.eq(Names.normalise('Imp'), 'imp', 'case is folded')
    t.eq(Names.normalise('Imp Walk'), 'imp_walk', 'spaces become underscores')
    t.eq(Names.normalise('imp--walk!!'), 'imp_walk', 'runs of punctuation collapse to one')
    t.eq(Names.normalise('__imp__'), 'imp', 'leading and trailing underscores are trimmed')
    t.eq(Names.normalise(''), 'unnamed', 'an empty name still produces a usable key')
    t.eq(Names.normalise('!!!'), 'unnamed', 'and so does one made only of punctuation')
    t.eq(Names.normalise(nil), 'unnamed', 'nil does not error')

    ---------------------------------------------------------------------
    t.describe('logical names from paths')

    t.eq(Names.fromPath('assets/sprites/imp.png'), 'imp', 'the extension is dropped')
    t.eq(Names.fromPath('assets/sprites/Imp_a8_f4.png'), 'imp', 'and so is an explicit grid hint')
    t.eq(Names.fromPath('assets/sprites/imp_8x4.png'), 'imp', 'and a compact one')
    t.eq(Names.fromPath('assets/sprites/imp_f4_a8.png'), 'imp', 'in either order')
    t.eq(Names.fromPath('assets/sprites/imp-8x4.png'), 'imp', 'separated by a dash')
    t.eq(Names.fromPath('maps/arena.map'), 'arena', 'maps work the same way')

    -- A hint is only a hint when it is at the end. A name that happens to contain
    -- digits must survive intact, or `wall_2` becomes `wall`.
    t.eq(Names.fromPath('assets/sprites/wall_2.png'), 'wall_2', 'a trailing number is not a grid hint')
    t.eq(Names.fromPath('assets/sprites/imp8x4_idle.png'), 'imp8x4_idle',
         'a hint in the middle of a name is left alone')

    ---------------------------------------------------------------------
    t.describe('grid hints in filenames')

    local hint = Names.hints('imp_a8_f4.png')
    t.ok(hint ~= nil, 'the explicit form parses')
    t.eq(hint and hint.angles, 8, 'with the angle count')
    t.eq(hint and hint.frames, 4, 'and the frame count')

    hint = Names.hints('imp_f4_a8.png')
    t.eq(hint and hint.angles, 8, 'the reversed form gives the same angles')
    t.eq(hint and hint.frames, 4, 'and the same frames')

    -- Rows by columns, because that is the order the sheet is laid out in and the
    -- order Sprites.define takes them. Getting this backwards transposes the sheet.
    hint = Names.hints('imp_8x4.png')
    t.eq(hint and hint.angles, 8, 'the compact form reads rows first')
    t.eq(hint and hint.frames, 4, 'then columns')

    hint = Names.hints('IMP_A8_F4.PNG')
    t.eq(hint and hint.angles, 8, 'hints are case-insensitive')

    t.eq(Names.hints('imp.png'), nil, 'no hint is nil, never a default')
    t.eq(Names.hints('imp_walk.png'), nil, 'and a word is not a hint')
    t.eq(Names.hints('wall_2.png'), nil, 'nor is a single trailing number')

    ---------------------------------------------------------------------
    t.describe('kinds from extensions')

    t.eq(Names.kindFor('imp.png'), 'image', 'PNG is an image')
    t.eq(Names.kindFor('shot.wav'), 'sound', 'WAV is a sound')
    t.eq(Names.kindFor('arena.map'), 'map', 'and .map is a map')
    t.eq(Names.kindFor('song.ogg'), nil, 'OGG is not claimed, because WAV needs no decoder')
    t.eq(Names.kindFor('readme.txt'), nil, 'and an unknown extension is nil, not a guess')

    ---------------------------------------------------------------------
    t.describe('where to look for a name')

    local candidates = Names.candidates('imp', 'image')
    t.ok(#candidates >= 2, 'a bare name produces several candidates')
    t.eq(candidates[1], 'assets/sprites/imp.png', 'the conventional folder is tried first')
    t.eq(candidates[2], 'assets/imp.png', 'then the flat assets folder')

    -- An explicit path must never be second-guessed: it goes first, verbatim.
    local explicit = Names.candidates('art/monsters/imp.png', 'image')
    t.eq(explicit[1], 'art/monsters/imp.png', 'a path-like name is tried exactly as given')

    local withFolder = Names.candidates('imp', 'image', { folder = 'mygame/art' })
    t.eq(withFolder[1], 'mygame/art/imp.png', 'a caller-supplied folder wins')

    local sounds = Names.candidates('shot', 'sound')
    t.eq(sounds[1], 'assets/sounds/shot.wav', 'sounds look in their own folder')

    t.eq(#Names.candidates('imp', 'nonsense'), 0,
         'an unknown kind has no extensions, so no candidates')

    local deduped = Names.candidates('assets/sprites/imp.png', 'image')
    local seen = {}
    local dupes = 0
    for _, p in ipairs(deduped) do
        if seen[p] then dupes = dupes + 1 end
        seen[p] = true
    end
    t.eq(dupes, 0, 'no candidate is offered twice')
end
