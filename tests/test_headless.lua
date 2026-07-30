--[[
    The headless rule: nothing under meatray/sim may depend on LÖVE.

    This is the test that keeps the architecture honest. If a simulation module
    ever reaches for love.graphics, a dedicated server stops being a config
    change and becomes a rewrite, and the sim stops being unit-testable — which
    matters more than it sounds, because a test suite that stubs love.graphics
    and never enters a draw path will report green while real bugs sit in the
    code it never executed.

    Two independent checks, because either alone is weak:
      1. Every sim module loads and runs with no `love` global at all.
      2. No sim source file mentions love.graphics/window/audio/keyboard/mouse,
         which catches a reference sitting on a branch this test never reaches.

    The same rule covers `meatray/net/` for the same reason twice over: a
    dedicated server draws nothing, and replication has to be testable without a
    window or a socket. The enet transport and the LAN discovery backend do need
    libraries that only ship with LÖVE, so each requires its own *inside* a
    constructor rather than at file scope — which is why even those two files load
    cleanly here with no `love` global at all. If either ever moved its require to
    the top of the file, this test would catch it.
]]

return function(t)
    local SIM_MODULES = {
        'meatray.sim.entity',
        'meatray.sim.world',
        'meatray.sim.collide',
        'meatray.sim.tick',
        'meatray.sim.components',
        'meatray.sim.worldgen',
        'meatray.sim.billboard',
        'meatray.sim.map',

        'meatray.net',
        'meatray.net.serialize',
        'meatray.net.protocol',
        'meatray.net.transport',
        'meatray.net.transport.loopback',
        'meatray.net.transport.enet',
        'meatray.net.replication',
        'meatray.net.host',
        'meatray.net.client',
        'meatray.net.discovery',
        'meatray.net.discovery.lan',
        'meatray.net.access',
        'meatray.net.diagnostics',
    }

    local SIM_FILES = {
        'meatray/sim/entity.lua',
        'meatray/sim/world.lua',
        'meatray/sim/collide.lua',
        'meatray/sim/tick.lua',
        'meatray/sim/components.lua',
        'meatray/sim/worldgen.lua',
        'meatray/sim/billboard.lua',
        'meatray/sim/map.lua',

        'meatray/net/init.lua',
        'meatray/net/serialize.lua',
        'meatray/net/protocol.lua',
        'meatray/net/transport.lua',
        'meatray/net/transport/loopback.lua',
        'meatray/net/transport/enet.lua',
        'meatray/net/replication.lua',
        'meatray/net/host.lua',
        'meatray/net/client.lua',
        'meatray/net/discovery.lua',
        'meatray/net/discovery/lan.lua',
        'meatray/net/access.lua',
        'meatray/net/diagnostics.lua',
    }

    -- 1. Loading with no love global present.
    t.describe('sim modules load with no love global')
    local savedLove = rawget(_G, 'love')
    rawset(_G, 'love', nil)

    for _, name in ipairs(SIM_MODULES) do
        package.loaded[name] = nil
        local ok, err = pcall(require, name)
        t.ok(ok, ('%s loads without love'):format(name), err)
    end

    rawset(_G, 'love', savedLove)

    -- 2. Source-level check for love.* references the loader would not hit.
    t.describe('sim sources never reference love drawing APIs')
    local FORBIDDEN = {
        'love%.graphics', 'love%.window', 'love%.audio',
        'love%.keyboard', 'love%.mouse', 'love%.image',
    }

    for _, path in ipairs(SIM_FILES) do
        local f = io.open(path, 'r')
        if not f then
            t.ok(false, ('%s is readable'):format(path))
        else
            local src = f:read('*a')
            f:close()

            -- Strip comments before scanning. Every one of these files opens
            -- with a doc block that states this very rule, so it necessarily
            -- names the APIs it forbids; scanning raw source would flag the
            -- documentation and never the code.
            local code = src
                :gsub('%-%-%[%[.-%]%]', '')   -- block comments
                :gsub('%-%-[^\n]*', '')       -- line comments

            local found
            for _, pattern in ipairs(FORBIDDEN) do
                local line = code:match('[^\n]*' .. pattern .. '[^\n]*')
                if line then
                    found = pattern:gsub('%%', '') .. ' in: ' .. line:sub(1, 60)
                    break
                end
            end

            t.ok(not found, ('%s is love-free'):format(path), found)
        end
    end

    -- 3. love.timer is the one tempting exception; the tick clock takes dt as an
    --    argument precisely so it does not need a clock of its own.
    t.describe('the tick clock takes time as an argument')
    local f = io.open('meatray/sim/tick.lua', 'r')
    local src = f:read('*a'); f:close()
    local code = src:gsub('%-%-%[%[.-%]%]', ''):gsub('%-%-[^\n]*', '')
    t.ok(not code:find('love%.timer'), 'tick.lua does not read love.timer')

    -- 4. The net layer takes dt as an argument too. A host that read a clock of
    --    its own could not be stepped by a test, and a server whose tick rate
    --    depends on wall time is a server that disagrees with its clients.
    t.describe('the net layer takes time as an argument')
    for _, path in ipairs({ 'meatray/net/host.lua', 'meatray/net/client.lua' }) do
        local handle = io.open(path, 'r')
        local source = handle:read('*a'); handle:close()
        local stripped = source:gsub('%-%-%[%[.-%]%]', ''):gsub('%-%-[^\n]*', '')
        t.ok(not stripped:find('love%.timer'), path .. ' does not read love.timer')
        t.ok(not stripped:find('os%.clock'), path .. ' does not read os.clock')
    end

    -- 5. The lazily-required libraries must stay lazy. `require('enet')` or
    --    `require('socket')` at file scope would make the whole net stack
    --    un-loadable under plain LuaJIT and take the replication tests with it.
    t.describe('LOVE-only libraries are required inside functions, not at file scope')
    for _, path in ipairs({ 'meatray/net/transport/enet.lua',
                            'meatray/net/discovery/lan.lua' }) do
        local handle = io.open(path, 'r')
        local source = handle:read('*a'); handle:close()
        local stripped = source:gsub('%-%-%[%[.-%]%]', ''):gsub('%-%-[^\n]*', '')
        -- A top-level require is one that starts at column zero.
        t.ok(not stripped:find('\nlocal [%w_]+ = require%(\'enet\'%)'),
             path .. ' does not require enet at file scope')
        t.ok(not stripped:find('\nlocal [%w_]+ = require%(\'socket\'%)'),
             path .. ' does not require socket at file scope')
    end
end
