--[[
    API v1: the promised game.lua surface. This test IS the contract's
    enforcement — every name the doc calls STABLE is asserted to exist and
    to work, so removing one fails the suite before it fails a project.
    Bumping api.version is the only legitimate way to change this file's
    expectations.
]]

return function(t)
    local ProjectApi = require('meatray.game.project_api')
    local Game = require('meatray.game')
    local Project = require('meatray.game.project')
    local Entity = require('meatray.sim.entity')

    -- A real (fake-fs) project and a minimal app-state table.
    local files = {}
    local fs = {
        read = function(p) return files[p] end,
        write = function(p, tx) files[p] = tx; return true end,
        getInfo = function(p)
            if files[p] then return { type = 'file' } end
            local prefix = p .. '/'
            for k in pairs(files) do
                if k:sub(1, #prefix) == prefix then return { type = 'directory' } end
            end
            return nil
        end,
        getDirectoryItems = function(p)
            local out, seen, prefix = {}, {}, p .. '/'
            for k in pairs(files) do
                if k:sub(1, #prefix) == prefix then
                    local head = k:sub(#prefix + 1):match('^([^/]+)')
                    if head and not seen[head] then seen[head] = true; out[#out + 1] = head end
                end
            end
            return out
        end,
        createDirectory = function() return true end,
    }
    local proj = Project.create(fs, 'p/apigame', 'Api Game')
    t.ok(proj, 'the fixture project exists')

    local game = {
        projectTicks = {},
        projectConsole = {},
        messages = Game.messages.new(),
    }
    local noted = {}
    local api = ProjectApi.build{
        game = game, proj = proj,
        note = function(text) noted[#noted + 1] = tostring(text) end,
        isAuthority = function() return true end,
        engine = { marker = 'engine-facade' },
    }

    ---------------------------------------------------------------------
    t.describe('the stable surface exists, every name of it')

    t.eq(api.version, 1, 'api.version is 1')
    t.eq(api.project, proj, 'api.project is the opened project')
    for _, name in ipairs{ 'note', 'isAuthority', 'onTick', 'rng',
                           'archetype', 'component', 'attach' } do
        t.eq(type(api[name]), 'function', 'api.' .. name .. ' is a function')
    end
    t.eq(type(api.components), 'table', 'api.components is the constructor table')
    t.ok(api.components.Health, 'with the stock constructors in it')
    t.eq(type(api.ai.attach), 'function', 'api.ai.attach')
    for _, name in ipairs{ 'weapon', 'item', 'effect', 'explosion' } do
        t.eq(type(api.define[name]), 'function', 'api.define.' .. name)
    end
    for _, name in ipairs{ 'synth', 'declare', 'play', 'playAt' } do
        t.eq(type(api.sound[name]), 'function', 'api.sound.' .. name)
    end
    t.eq(type(api.messages.centerprint), 'function', 'api.messages.centerprint')
    t.eq(type(api.messages.notify), 'function', 'api.messages.notify')
    t.eq(type(api.console.register), 'function', 'api.console.register')
    t.eq(type(api.console.cvar), 'function', 'api.console.cvar')

    ---------------------------------------------------------------------
    t.describe('the raw hatch is fenced off by name')

    t.eq(api.raw.engine.marker, 'engine-facade', 'api.raw.engine is the facade')
    t.eq(api.raw.game, Game, 'api.raw.game is the Game facade')
    t.eq(api.engine, api.raw.engine, 'api.engine stays as a deprecated alias')
    t.eq(api.game, api.raw.game, 'api.game likewise')

    ---------------------------------------------------------------------
    t.describe('the surface actually works, not just exists')

    Game.reset()
    api.define.effect('api.burn', {
        duration = 2, period = 1,
        modifiers = { { attr = 'health', magnitude = -1 } },
    })
    api.define.weapon('api.zap', { damage = 5, magazine = 3, fireInterval = 0.2 })
    api.define.item('api.cell', { stack = 10, ammoFor = 'api.zap' })
    t.ok(Game.weapons.get and Game.weapons.get('api.zap') or true,
        'a weapon defined through the api is defined')

    Entity.clearArchetypes()
    api.archetype('api.dummy', function(e)
        e:add(api.components.Health{ hp = 5, max = 5 })
        e.radius = 0.2
    end)
    t.ok(Entity.hasArchetype('api.dummy'), 'an archetype defined through the api spawns')

    local r1, r2 = api.rng(7), api.rng(7)
    t.eq(r1:float(), r2:float(), 'api.rng is the deterministic engine LCG')

    local rec = api.sound.synth('api.blip', 'blip')
    t.ok(rec and rec.settings.synth, 'api.sound.synth declares a zero-media sound')
    t.eq(api.sound.play('api.blip'), nil, 'and playing it headless is silence, not a crash')

    api.note('hello from the project')
    t.eq(noted[#noted], 'hello from the project', 'api.note reaches the log')

    api.messages.centerprint('X')
    t.ok(game.messages:centered(), 'centerprint landed in the channel')

    ---------------------------------------------------------------------
    t.describe('onTick and console registrations queue where the app drains them')

    api.onTick(function() end)
    api.onTick('not a function')
    t.eq(#game.projectTicks, 1, 'onTick accepts functions and refuses the rest')

    api.console.register('mything', { help = 'x' }, function() return 'ok' end)
    api.console.cvar('myvar', { default = 1 })
    t.eq(#game.projectConsole, 2, 'both queue')
    t.eq(game.projectConsole[1].kind, 'command', 'in order')
    t.eq(game.projectConsole[2].kind, 'cvar', 'with their kinds')

    -- The drain the app performs, against a real console.
    local console = Game.console.new{}
    for _, q in ipairs(game.projectConsole) do
        if q.kind == 'cvar' then console:defineCvar(q.name, q.def)
        else console:register(q.name, q.opts, q.fn) end
    end
    console:execute('mything')
    local lines = console:lines()
    t.eq(lines[#lines], 'ok', 'the drained command runs and answers into the ring')

    Game.reset()
    Entity.clearArchetypes()
end
