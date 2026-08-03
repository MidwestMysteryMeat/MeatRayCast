--[[
    B12: the map linter — each check has a map that trips it, a clean map
    lints clean, and every SHIPPED map is error-free forever after.
]]

return function(t)
    local Maplint = require('meatray.sim.maplint')
    local Map     = require('meatray.sim.map')

    local function lintText(lines, opts)
        return Maplint.checkText(table.concat(lines, '\n'), opts)
    end

    local function codes(list)
        local out = {}
        for _, item in ipairs(list) do out[item.code] = (out[item.code] or 0) + 1 end
        return out
    end

    ---------------------------------------------------------------------
    t.describe('a sound map lints clean')

    local clean = lintText{
        'name ok', 'spawn 2.5 2.5 0', '---',
        '########',
        '#......#',
        '#......#',
        '########',
    }
    t.eq(clean.ok, true, 'no errors')
    t.eq(#clean.warnings, 0, 'no warnings')
    t.ok(clean.reached and clean.reached > 0, 'and the flood ran')

    ---------------------------------------------------------------------
    t.describe('spawn defects are errors')

    -- Map.parse always fills a spawn (a grid @, else map centre), so the
    -- no-spawn error only reaches a hand-built table — which the editor's
    -- in-memory map is, before a first save.
    local raw = Map.blank(6, 4)
    raw.spawn = nil
    local noSpawn = Maplint.check(raw)
    t.eq(noSpawn.ok, false, 'a map table with no spawn fails')
    t.ok(codes(noSpawn.errors)['no-spawn'], 'named as such')

    local inWall = lintText{
        'name x', 'spawn 0.5 0.5 0', '---',
        '####', '#..#', '####',
    }
    t.ok(codes(inWall.errors)['spawn-in-solid'], 'a spawn inside a wall fails')

    ---------------------------------------------------------------------
    t.describe('sealed rooms warn; sealed exits fail')

    local sealed = lintText{
        'name x', 'spawn 2.5 2.5 0', '---',
        '#########',
        '#...#...#',
        '#...#...#',
        '#########',
    }
    t.eq(sealed.ok, true, 'a sealed room is a warning, not an error')
    t.ok(codes(sealed.warnings)['unreachable-floor'], 'and says which')

    local badExit = lintText{
        'name x', 'spawn 2.5 2.5 0', 'exit tiles 6 2 7 3', '---',
        '#########',
        '#...#...#',
        '#...#...#',
        '#########',
    }
    t.eq(badExit.ok, false, 'an exit behind an unbroken wall FAILS')
    t.ok(codes(badExit.errors)['exit-unreachable'], 'an exit is a promise')

    -- The same room with a door in the divider is fine: doors open.
    local doored = lintText{
        'name x', 'spawn 2.5 2.5 0', 'exit tiles 6 2 7 3', '---',
        '#########',
        '#...D...#',
        '#...#...#',
        '#########',
    }
    t.eq(doored.ok, true, 'a shut door is a path — that is what doors are for')

    ---------------------------------------------------------------------
    t.describe('entities: off-map and in-wall are errors, unknown warns')

    local badEnt = lintText({
        'name x', 'spawn 2.5 2.5 0', 'entity i imp', '---',
        '#####',
        '#.i.#',
        '#####',
    }, { archetypes = { 'crystal' } })
    -- The imp itself stands on floor; unknown-archetype should fire since
    -- only 'crystal' is registered.
    t.ok(codes(badEnt.warnings)['unknown-archetype'],
         'an unregistered kind warns when a registry was handed in')

    local noReg = lintText{
        'name x', 'spawn 2.5 2.5 0', 'entity i imp', '---',
        '#####',
        '#.i.#',
        '#####',
    }
    t.eq(codes(noReg.warnings)['unknown-archetype'], nil,
         'and lints clean without one — modded maps are not liars')

    ---------------------------------------------------------------------
    t.describe('locks, keys and push-walls')

    local lockNoDoor = lintText{
        'name x', 'spawn 2.5 2.5 0', 'lock 2 2 key.red', '---',
        '#####',
        '#...#',
        '#####',
    }
    t.ok(codes(lockNoDoor.errors)['lock-no-door'],
         'a lock with no door under it is an error')

    local keyless = lintText{
        'name x', 'spawn 2.5 1.5 0', 'lock 4 2 key.red', '---',
        '#######',
        '#..D..#',
        '#######',
    }
    t.eq(keyless.ok, true, 'a locked door with no key is a WARNING')
    t.ok(codes(keyless.warnings)['key-not-on-map'],
         'because locked is a puzzle and unreachable is a defect')

    local blockedPush = lintText{
        'name x', 'spawn 2.5 2.5 0', 'pushwall 3 1 0 -1 1', '---',
        '#####',
        '#...#',
        '#####',
    }
    t.eq(blockedPush.ok, false, 'a push-wall aimed off the map fails')
    t.ok(codes(blockedPush.errors)['pushwall-blocked'],
         'it cannot take its first step — the secrets.map draft bug, as a rule')

    local floatingPush = lintText{
        'name x', 'spawn 2.5 2.5 0', 'pushwall 2 2 1 0 1', '---',
        '#####',
        '#...#',
        '#####',
    }
    t.ok(codes(floatingPush.errors)['pushwall-not-solid'],
         'a push-wall on open floor is an error too')

    ---------------------------------------------------------------------
    t.describe('stairs and links keep their promises')

    local lonelyLink = lintText{
        'name x', 'spawn 2.5 2.5 0', 'link up maps/tower_upper.map', '---',
        '#####',
        '#...#',
        '#####',
    }
    t.ok(codes(lonelyLink.warnings)['link-no-stairs'],
         'a link with no stairs to take it warns')

    ---------------------------------------------------------------------
    t.describe('garbage in, report out')

    local garbage = Maplint.checkText('not a map at all')
    t.eq(garbage.ok, false, 'unparseable text fails')
    t.ok(codes(garbage.errors)['parse'], 'as a parse error, not a crash')
    t.eq(Maplint.check(nil).ok, false, 'nil is refused')

    ---------------------------------------------------------------------
    t.describe('every shipped map is error-free (the anti-rot gate)')

    local shipped = {
        'maps/arena.map', 'maps/secrets.map', 'maps/crouch.map',
        'maps/platforms.map', 'maps/stacked.map',
        'maps/tower.map', 'maps/tower_upper.map',
    }
    for _, path in ipairs(shipped) do
        local f = io.open(path, 'rb')
        t.ok(f ~= nil, path .. ' exists')
        if f then
            local text = f:read('*a')
            f:close()
            local report = Maplint.checkText(text)
            local detail = ''
            for _, e in ipairs(report.errors) do
                detail = detail .. ' [' .. e.code .. '] ' .. e.text
            end
            t.eq(report.ok, true, path .. ' lints without errors' .. detail)
        end
    end
end
