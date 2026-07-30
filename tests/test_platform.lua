--[[
    Only the backend may name the host.

    "MeatRayCast is a Lua engine that runs on LÖVE" is only true if LÖVE is
    reachable through one seam. Without a test, that decays the ordinary way: one
    convenient `love.graphics.getFont()` at a time, each individually harmless,
    until a second backend means touching two hundred call sites instead of one
    file.

    This is the same shape as tests/test_headless.lua (which keeps the simulation
    love-free) and tests/test_engine_layering.lua (which keeps the convenience
    layer on the public API). Each replaces a rule someone has to remember with one
    a machine checks.
]]

return function(t)
    local Platform = require('meatray.platform')

    ---------------------------------------------------------------------
    t.describe('the interface says what a backend must supply')

    t.ok(type(Platform.REQUIRED) == 'table', 'the required surface is declared')

    local groups, total = 0, 0
    for group, names in pairs(Platform.REQUIRED) do
        groups = groups + 1
        total = total + #names
        t.ok(#names > 0, ('group "%s" lists functions'):format(group))
    end
    t.ok(groups >= 4, ('%d groups declared'):format(groups))
    t.ok(total >= 25, ('%d functions declared - enough to actually draw'):format(total))

    ---------------------------------------------------------------------
    t.describe('a partial backend is refused, not accepted and failed later')

    -- The failure this prevents: a backend that is 90% implemented works until the
    -- player reaches whichever feature is missing, and then fails somewhere with
    -- no obvious connection to the cause.
    local stub = { gfx = {}, fs = {}, input = {}, sys = {}, audio = {} }
    local ok, err = pcall(Platform.use, stub, 'stub')
    t.ok(not ok, 'an empty backend is rejected')
    t.ok(tostring(err):find('missing'), 'and the error says what is missing')

    local partial = {}
    for group, names in pairs(Platform.REQUIRED) do
        partial[group] = {}
        for _, fn in ipairs(names) do partial[group][fn] = function() end end
    end
    -- Remove exactly one, to prove the check is per-function and not per-group.
    partial.gfx.newQuad = nil

    local ok2, err2 = pcall(Platform.use, partial, 'partial')
    t.ok(not ok2, 'a backend missing one function is rejected')
    t.ok(tostring(err2):find('newQuad'), 'and names that function specifically')

    -- The same table with the hole filled must be accepted, so the rejection above
    -- was about the missing function and not about something incidental.
    partial.gfx.newQuad = function() end
    local ok3 = pcall(Platform.use, partial, 'partial')
    t.ok(ok3, 'and is accepted once complete')
    t.eq(Platform.name, 'partial', 'the installed backend is named')

    ---------------------------------------------------------------------
    t.describe('only the backend names the host')

    -- Every engine file except the backend must be free of `love`. The sim, game,
    -- net and save layers are already covered by test_headless; this widens it to
    -- render, ui and asset, which legitimately need a host but must reach it
    -- through the seam.
    local SCANNED = {
        'meatray/render/raycaster.lua',
        'meatray/render/sprites.lua',
        'meatray/render/textures.lua',
        'meatray/render/themes.lua',
        'meatray/render/lighting.lua',
        'meatray/ui/core.lua',
        'meatray/ui/rect.lua',
        'meatray/ui/shell.lua',
        'meatray/ui/reload.lua',
        'meatray/ui/panel_map.lua',
        'meatray/ui/panel_code.lua',
        'meatray/ui/panel_servers.lua',
        'meatray/asset/init.lua',
        'meatray/asset/image.lua',
        'meatray/asset/sound.lua',
        'meatray/asset/registry.lua',
        'meatray/asset/slice.lua',
        'meatray/asset/names.lua',
        'meatray/asset/spatial.lua',
        'meatray/engine.lua',
    }

    local offenders = {}

    for _, path in ipairs(SCANNED) do
        local f = io.open(path, 'r')
        if f then
            local source = f:read('*a')
            f:close()

            -- Strip comments first. Several of these files document the rule and
            -- therefore name the very thing they must not call; scanning raw
            -- source would flag the documentation and hide nothing. This exact
            -- trap already caught test_headless once.
            local code = source
                :gsub('%-%-%[%[.-%]%]', '')
                :gsub('%-%-[^\n]*', '')

            local hit = code:match('love%s*%.%s*[%a_]+')
            if hit then
                offenders[#offenders + 1] = ('%s (%s)'):format(path, hit)
            end
        end
    end

    t.eq(#offenders, 0,
         ('%d file(s) call the host directly: %s')
         :format(#offenders, table.concat(offenders, ', ')))

    ---------------------------------------------------------------------
    t.describe('the backend itself is allowed to, and does')

    local f = io.open('meatray/platform/love.lua', 'r')
    t.ok(f ~= nil, 'the love backend exists')
    if f then
        local source = f:read('*a')
        f:close()
        t.ok(source:find('love%.graphics'), 'and it is the file that talks to love')
    end

    ---------------------------------------------------------------------
    t.describe('the platform module itself stays host-agnostic')

    -- meatray/platform/init.lua selects a backend, so it may *check* for a host,
    -- but it must not call one. Otherwise the seam leaks at its own hinge.
    local p = io.open('meatray/platform/init.lua', 'r')
    if p then
        local code = p:read('*a')
        p:close()
        code = code:gsub('%-%-%[%[.-%]%]', ''):gsub('%-%-[^\n]*', '')
        t.ok(not code:find('love%s*%.%s*graphics'), 'no love.graphics in the selector')
        t.ok(not code:find('love%s*%.%s*filesystem'), 'no love.filesystem in the selector')
        t.ok(code:find("rawget%(_G, 'love'%)"),
             'it detects the host by presence, which is the one thing it may do')
    end
end
