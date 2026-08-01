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
        'meatray.sim.segments',
        'meatray.sim.pathfind',
        'meatray.sim.triggers',

        'meatray.net',
        'meatray.net.serialize',
        'meatray.net.snapcodec',
        'meatray.net.protocol',
        'meatray.net.transport',
        'meatray.net.transport.loopback',
        'meatray.net.transport.enet',
        'meatray.net.transport.steam',
        'meatray.net.replication',
        'meatray.net.host',
        'meatray.net.client',
        'meatray.net.discovery',
        'meatray.net.discovery.lan',
        'meatray.net.discovery.master',
        'meatray.net.access',
        'meatray.net.diagnostics',

        -- The ability system belongs here rather than beside the renderer for
        -- the reason the rule exists: a dedicated server runs every one of these
        -- modules. Attributes, effects and abilities are simulation — the host
        -- owns them and applies them inside the fixed tick — so they answer to
        -- the same constraint as meatray/sim and meatray/net, and would be a
        -- rewrite away from a dedicated server if they did not.
        -- Leaf-first, with the facade last. This loop clears each entry from
        -- package.loaded and requires it again, so a module listed before its
        -- own dependencies would be rebuilt against copies that the next
        -- iteration then replaces — leaving the facade holding one instance of a
        -- module while `require` hands everybody else another. Two registries,
        -- one of which quietly never receives a definition.
        'meatray.game.tags',
        'meatray.game.attributes',
        'meatray.game.effects',
        'meatray.game.abilities',
        'meatray.game.damage',
        'meatray.game.explosion',
        'meatray.game.projectiles',
        'meatray.game.weapons',
        'meatray.game.inventory',
        'meatray.game.gas',
        'meatray.game.mode',
        'meatray.game.modes',
        'meatray.game.campaign',
        'meatray.game.options',
        'meatray.game',
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
        'meatray/net/snapcodec.lua',
        'meatray/net/protocol.lua',
        'meatray/net/transport.lua',
        'meatray/net/transport/loopback.lua',
        'meatray/net/transport/enet.lua',
        'meatray/net/transport/steam.lua',
        'meatray/net/replication.lua',
        'meatray/net/host.lua',
        'meatray/net/client.lua',
        'meatray/net/discovery.lua',
        'meatray/net/discovery/lan.lua',
        'meatray/net/discovery/master.lua',
        'meatray/net/access.lua',
        'meatray/net/diagnostics.lua',

        'meatray/game/init.lua',
        'meatray/game/tags.lua',
        'meatray/game/attributes.lua',
        'meatray/game/effects.lua',
        'meatray/game/abilities.lua',
        'meatray/game/damage.lua',
        'meatray/game/explosion.lua',
        'meatray/game/projectiles.lua',
        'meatray/game/weapons.lua',
        'meatray/game/inventory.lua',
        'meatray/game/gas.lua',
        'meatray/game/mode.lua',
        'meatray/game/modes.lua',
        'meatray/game/campaign.lua',
    }

    local GAME_FILES = {
        'meatray/game/init.lua',
        'meatray/game/tags.lua',
        'meatray/game/attributes.lua',
        'meatray/game/effects.lua',
        'meatray/game/abilities.lua',
        'meatray/game/damage.lua',
        'meatray/game/explosion.lua',
        'meatray/game/projectiles.lua',
        'meatray/game/weapons.lua',
        'meatray/game/inventory.lua',
        'meatray/game/gas.lua',
        'meatray/game/mode.lua',
        'meatray/game/modes.lua',
        'meatray/game/campaign.lua',
    }

    -- 1. Loading with no love global present.
    t.describe('sim modules load with no love global')
    local savedLove = rawget(_G, 'love')
    rawset(_G, 'love', nil)

    -- SIDE EFFECT, and it has already cost a debugging session: clearing
    -- package.loaded and requiring again leaves TWO live instances of each of
    -- these modules. Anything loaded earlier still holds the original table,
    -- while `require` now returns the new one -- so after this test,
    --
    --     require('meatray.net.discovery') ~= require('meatray.net').discovery
    --
    -- A later test that wraps a function on one of these tables to observe a
    -- call will patch the instance nobody is using, and the symptom is a wrapper
    -- that never fires while the thing it wraps demonstrably works. Assert on
    -- observable behaviour rather than on interception, or re-require the whole
    -- chain yourself.
    --
    -- Left as-is rather than fixed: reloading with the global removed is the
    -- only way to prove these modules do not need it, and that proof is worth
    -- more than the tidiness.
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

    -- 4b. The ability system takes dt as an argument and rolls its dice with the
    --     engine's own rng. A duration measured against a wall clock is a
    --     duration that differs between a host and a client, and math.random's
    --     sequence differs between Lua 5.1, 5.3 and LuaJIT — so a proc rolled
    --     with it desynchronises two machines that agree about everything else.
    t.describe('the ability system reads no clock and rolls no math.random')
    for _, path in ipairs(GAME_FILES) do
        local handle = io.open(path, 'r')
        if not handle then
            t.ok(false, ('%s is readable'):format(path))
        else
            local source = handle:read('*a'); handle:close()
            local stripped = source:gsub('%-%-%[%[.-%]%]', ''):gsub('%-%-[^\n]*', '')
            t.ok(not stripped:find('love%.timer'), path .. ' does not read love.timer')
            t.ok(not stripped:find('os%.clock'), path .. ' does not read os.clock')
            t.ok(not stripped:find('os%.time'), path .. ' does not read os.time')
            t.ok(not stripped:find('math%.random'), path .. ' does not call math.random')
        end
    end

    -- 5. The lazily-required libraries must stay lazy. `require('enet')`,
    --    `require('socket')` or `require('luasteam')` at file scope would make
    --    the whole net stack un-loadable under plain LuaJIT and take the
    --    replication tests with it.
    --
    --    luasteam is the sharpest case of the three, because it is the only one
    --    that is missing on most machines rather than merely missing outside
    --    LOVE. A file-scope require there would mean a player without Steam
    --    could not load the networking module at all — a service being absent
    --    becoming the reason the game will not run.
    t.describe('LOVE-only libraries are required inside functions, not at file scope')
    for _, path in ipairs({ 'meatray/net/transport/enet.lua',
                            'meatray/net/transport/steam.lua',
                            'meatray/net/discovery/lan.lua',
                            'meatray/net/discovery/master.lua' }) do
        local handle = io.open(path, 'r')
        local source = handle:read('*a'); handle:close()
        local stripped = source:gsub('%-%-%[%[.-%]%]', ''):gsub('%-%-[^\n]*', '')
        -- A top-level require is one that starts at column zero.
        t.ok(not stripped:find('\nlocal [%w_]+ = require%(\'enet\'%)'),
             path .. ' does not require enet at file scope')
        t.ok(not stripped:find('\nlocal [%w_]+ = require%(\'socket\'%)'),
             path .. ' does not require socket at file scope')
        t.ok(not stripped:find('\nlocal [%w_]+ = require%(\'luasteam\'%)'),
             path .. ' does not require luasteam at file scope')
    end
end
