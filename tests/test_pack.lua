--[[
    B13: asset packs — a manifest parses and validates, hostile paths are
    refused, and a registry mounts packs, honours dependency order, refuses id
    collisions, and resolves an asset id to its absolute file path.
]]

return function(t)
    local Pack = require('meatray.game.pack')
    local Game = require('meatray.game')

    t.eq(Game.pack, Pack, 'Game.pack is the module')

    ---------------------------------------------------------------------
    t.describe('a well-formed manifest validates')

    local good = {
        id = 'basemaps', name = 'Base Maps', version = '1.0.0',
        maps   = { arena = 'maps/arena.map' },
        graphs = { waves = 'graphs/waves.graph.json' },
    }
    local ok, errs = Pack.validate(good)
    t.ok(ok, 'valid manifest passes')
    t.eq(#errs, 0, 'no errors')

    ---------------------------------------------------------------------
    t.describe('required fields are enforced')

    t.ok(not Pack.validate({ version = '1' }), 'missing id fails')
    t.ok(not Pack.validate({ id = 'x' }), 'missing version fails')
    t.ok(not Pack.validate({ id = 'has space', version = '1' }),
         'id with a space fails')
    t.ok(Pack.validate({ id = 'ok.pack-1_2', version = '1' }),
         'id of [A-Za-z0-9-_.] passes')

    ---------------------------------------------------------------------
    t.describe('path traversal is refused — the security check')

    for _, bad in ipairs({
        '../secret', 'a/../../etc/passwd', '/etc/passwd',
        'C:\\Windows\\system32', '\\\\host\\share\\x', 'a/b/../../../x',
    }) do
        t.ok(not Pack.safeAssetPath(bad), 'rejects ' .. bad)
    end
    for _, okp in ipairs({ 'maps/a.map', 'a/b/c.map', './here/x', 'a/./b' }) do
        t.ok(Pack.safeAssetPath(okp), 'allows ' .. okp)
    end

    -- A hostile path inside a manifest makes the whole manifest invalid.
    local hostile = { id = 'evil', version = '1',
                      maps = { pwn = '../../etc/passwd' } }
    t.ok(not Pack.validate(hostile), 'manifest with escaping path is invalid')

    ---------------------------------------------------------------------
    t.describe('parse decodes JSON then validates')

    local m = Pack.parse('{"id":"p","version":"1","maps":{"a":"maps/a.map"}}')
    t.ok(m, 'good JSON parses')
    t.eq(m.id, 'p', 'fields survive the round trip')
    t.ok(not Pack.parse('{not json'), 'bad JSON is rejected, not thrown')
    t.ok(not Pack.parse('{"version":"1"}'), 'valid JSON, invalid manifest')

    ---------------------------------------------------------------------
    t.describe('a registry mounts and resolves')

    local reg = Pack.Registry.new()
    t.ok(reg:mount(good, '/packs/base'), 'first mount succeeds')
    local path, from = reg:resolve('map', 'arena')
    t.eq(path, '/packs/base/maps/arena.map', 'resolves to absolute path')
    t.eq(from, 'basemaps', 'names the providing pack')
    t.eq(reg:resolve('graph', 'waves'), '/packs/base/graphs/waves.graph.json',
         'graphs resolve too')
    t.eq(reg:resolve('map', 'nope'), nil, 'unknown id resolves to nil')

    ---------------------------------------------------------------------
    t.describe('a duplicate pack id is refused')

    t.ok(not reg:mount(good, '/elsewhere'), 'same id twice is refused')

    ---------------------------------------------------------------------
    t.describe('dependencies must be mounted first')

    local dependent = {
        id = 'extra', version = '1', depends = { 'missing' },
        maps = { extra = 'maps/extra.map' },
    }
    t.ok(not reg:mount(dependent, '/packs/extra'),
         'unmet dependency blocks the mount')
    -- With the dep present it goes through.
    reg:mount({ id = 'missing', version = '1' }, '/packs/missing')
    t.ok(reg:mount(dependent, '/packs/extra'), 'met dependency allows it')

    ---------------------------------------------------------------------
    t.describe('asset id collisions across packs are refused, atomically')

    local collide = { id = 'other', version = '1',
                      maps = { arena = 'maps/mine.map', fresh = 'maps/fresh.map' } }
    t.ok(not reg:mount(collide, '/packs/other'),
         'a colliding asset id blocks the whole mount')
    -- ...and the non-colliding asset from that pack did NOT leak in.
    t.eq(reg:resolve('map', 'fresh'), nil, 'partial mount left nothing behind')
    t.ok(not reg:isMounted('other'), 'the pack itself is not registered')

    ---------------------------------------------------------------------
    t.describe('listing and mounted introspection')

    local maps = reg:list('map')
    t.ok(#maps >= 2, 'lists mounted maps')
    t.eq(maps[1].id, 'arena', 'sorted by id')
    local mounted = reg:mounted()
    t.eq(mounted[1].id, 'basemaps', 'mounted list is in mount order')
    t.ok(reg:isMounted('basemaps'), 'isMounted true for a mounted pack')
    t.ok(not reg:isMounted('ghost'), 'isMounted false otherwise')
end
