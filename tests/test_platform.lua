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
local function stripNonCode(src)
    local out, i, n = {}, 1, #src

    -- Skipped text is replaced by its own newlines, so line structure survives
    -- and nothing on either side of a comment is joined into a token.
    local function skipTo(from, to)
        out[#out + 1] = src:sub(from, to - 1):gsub('[^\n]', '')
        return to
    end

    while i <= n do
        local c = src:sub(i, i)

        if c == '-' and src:sub(i + 1, i + 1) == '-' then
            local eqs = src:match('^%[(=*)%[', i + 2)
            if eqs then                              -- --[[ block comment ]]
                local close = ']' .. eqs .. ']'
                local stop = src:find(close, i + 4 + #eqs, true)
                i = skipTo(i, stop and (stop + #close) or (n + 1))
            else                                     -- -- line comment
                i = skipTo(i, src:find('\n', i, true) or (n + 1))
            end

        elseif c == '[' and src:match('^%[(=*)%[', i) then
            local eqs = src:match('^%[(=*)%[', i)    -- [[ long string ]]
            local close = ']' .. eqs .. ']'
            local stop = src:find(close, i + 2 + #eqs, true)
            i = skipTo(i, stop and (stop + #close) or (n + 1))

        elseif c == '"' or c == "'" then             -- 'quoted' or "quoted"
            local from = i
            i = i + 1
            while i <= n do
                local ch = src:sub(i, i)
                if ch == '\\' then i = i + 2
                elseif ch == c then i = i + 1; break
                elseif ch == '\n' then break
                else i = i + 1 end
            end
            i = skipTo(from, i)

        else
            out[#out + 1] = c
            i = i + 1
        end
    end

    return table.concat(out)
end

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
