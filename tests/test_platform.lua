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

---------------------------------------------------------------------------
-- Reading Lua well enough to tell a call from a mention.
--
-- Every file here documents the rule it obeys, so every file necessarily *names*
-- the thing it must not call. Scanning raw source would flag the documentation
-- and hide nothing, which is why this test has always stripped comments first.
--
-- Stripping them with two gsubs is not enough, and the failure is not
-- theoretical: `--` inside a *string* looks exactly like the start of a comment
-- to a pattern. `meatray/ui/panel_servers.lua` prints
--
--     'run `love . --netcheck` to find out whether UDP works here'
--
-- and the naive strip deleted from `--netcheck` to the end of the line, leaving
-- `love .` glued to the `end` on the line below — a reported violation in a file
-- with no host call anywhere in it. A scanner that cries wolf gets ignored, and
-- an ignored rule is the rule this test exists to replace.
--
-- So: an actual scan, over comments, quoted strings and long brackets. It is
-- stricter about what counts as code, not looser about what counts as a
-- violation — a `love.graphics` in running code is caught exactly as before, and
-- the block below proves it on a sample containing every hiding place.
---------------------------------------------------------------------------
-- The Lua scan this test needs lives in tests/support/lua_source.lua, shared
-- with the registry test, which needs exactly the same thing for exactly the
-- same reason: a file must not fail a "does not name X" check because its own
-- header explains that it does not use X.
local stripNonCode = require('tests.support.lua_source').stripNonCode

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

    -- Installing a backend is global state, and this suite runs second of the
    -- thirty-six. Leaving a stub installed would hand every later suite a
    -- platform whose every function does nothing and returns nil — which the
    -- asset layer would read as "there is a host, ask it for a directory
    -- listing" and take a nil back. Put it away afterwards.
    local INSTALLED = { 'backend', 'name', 'gfx', 'fs', 'input', 'sys', 'audio' }
    local saved = {}
    for _, key in ipairs(INSTALLED) do saved[key] = rawget(Platform, key) end

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

    -- rawset every key, including back to nil: `saved` holds no entry for a key
    -- that was absent, so iterating `saved` alone would leave the stub in place.
    for _, key in ipairs(INSTALLED) do rawset(Platform, key, saved[key]) end
    t.eq(rawget(Platform, 'backend'), saved.backend,
         'and the stub is put away again afterwards')

    ---------------------------------------------------------------------
    t.describe('the scan reads code, and only code')

    -- The scanner is the thing enforcing the rule below, so it is asserted
    -- rather than trusted. Every line here hides `love.<something>` in a
    -- different place; only the last one is a call.
    local sample = table.concat({
        "-- love.mouse in a line comment",
        "--[[ love.filesystem in a block comment ]]",
        "local hint = 'run `love . --netcheck` to check UDP'",
        'local other = "love.audio in a string"',
        "local long = [[ love.window in a long string ]]",
        "local real = love.graphics.getWidth()",
    }, '\n')

    local stripped = stripNonCode(sample)

    t.ok(not stripped:find('love%s*%.%s*mouse'), 'a line comment is not a call')
    t.ok(not stripped:find('love%s*%.%s*filesystem'), 'a block comment is not a call')
    t.ok(not stripped:find('love%s*%.%s*audio'), 'a quoted string is not a call')
    t.ok(not stripped:find('love%s*%.%s*window'), 'a long string is not a call')
    t.ok(stripped:find('love%s*%.%s*graphics'), 'and a call still is one')

    -- The specific regression: `--netcheck` inside a string is not a comment, so
    -- the rest of that line must survive and nothing may be glued to the line
    -- after it. If this breaks, the first thing the scan finds is the wreckage of
    -- the hint string rather than the real call four lines down.
    t.eq(stripped:match('love%s*%.%s*[%a_]+'), 'love.graphics',
         'the only thing the scan finds in the sample is the real call')

    ---------------------------------------------------------------------
    t.describe('only the backend names the host')

    -- Every engine file except the backend must be free of `love`. The sim, game,
    -- net and save layers are already covered by test_headless; this widens it to
    -- render, ui and asset, which legitimately need a host but must reach it
    -- through the seam.
    --
    -- ONE FILE IS DELIBERATELY ABSENT: meatray/save/storage.lua. It is not an
    -- oversight and not a file waiting to be migrated -- it is itself a backend
    -- layer, structurally the same kind of thing as meatray/platform/love.lua. It
    -- selects between three filesystems (LOVE's sandbox, plain `io`, and a table
    -- for testing interrupted writes) because the save system runs in three places
    -- that disagree about what a filesystem is, and the `io` path is what lets a
    -- headless server persist a world at all. Routing it through the seam would
    -- put a second backend selector behind the first for no gain.
    --
    -- An unwritten exemption is indistinguishable from something nobody noticed,
    -- so it is written here and asserted below: the exemption holds only while its
    -- host use stays guarded and its fallbacks stay reachable.
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
        'meatray/ui/panel_assets.lua',
        'meatray/ui/panel_sprite.lua',
        'meatray/asset/init.lua',
        'meatray/asset/image.lua',
        'meatray/asset/sound.lua',
        'meatray/asset/sheet_image.lua',
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

            local hit = stripNonCode(source):match('love%s*%.%s*[%a_]+')
            if hit then
                offenders[#offenders + 1] = ('%s (%s)'):format(path, hit)
            end
        end
    end

    t.eq(#offenders, 0,
         ('%d file(s) call the host directly: %s')
         :format(#offenders, table.concat(offenders, ', ')))

    ---------------------------------------------------------------------
    ---------------------------------------------------------------------
    t.describe('the storage exemption holds only while it stays an exemption')

    -- storage.lua may name the host because it is a backend selector. That is only
    -- true while it still selects: the moment its `io` path goes, it stops being a
    -- module with a LOVE backend and becomes a module that requires LOVE, and a
    -- headless server silently loses the ability to save.
    local s = io.open('meatray/save/storage.lua', 'r')
    t.ok(s ~= nil, 'meatray/save/storage.lua exists')
    if s then
        local src = s:read('*a')
        s:close()
        local code = stripNonCode(src)

        t.ok(code:find('love%s*%.%s*filesystem'),
             'it does use the host filesystem, which is why it is exempt')
        t.ok(code:find('io%s*%.%s*open'),
             'and it still has the io fallback that earns the exemption')

        -- The three backends the header promises must all still be constructible,
        -- or the documentation and the code have drifted apart.
        for _, name in ipairs({ 'love', 'io', 'memory' }) do
            t.ok(code:find('function%s+Storage%.' .. name)
                 or code:find('Storage%.' .. name .. '%s*='),
                 ('the %s backend is still there'):format(name))
        end
    end

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
        local source = p:read('*a')
        p:close()

        local code = stripNonCode(source)
        t.ok(not code:find('love%s*%.%s*graphics'), 'no love.graphics in the selector')
        t.ok(not code:find('love%s*%.%s*filesystem'), 'no love.filesystem in the selector')

        -- Against the raw source, because the name it looks the host up by is a
        -- string literal and the scan above deliberately does not read strings.
        -- Naming the host in quotes is the one thing the selector may do; calling
        -- it is what it may not.
        t.ok(source:find("rawget%(_G, 'love'%)"),
             'it detects the host by presence, which is the one thing it may do')
    end
end
