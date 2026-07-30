--[[
    The convenience layer may only use the public API.

    This is the rule that keeps `meatray.engine` a convenience rather than the only
    supported path. If it reaches into `meatray.sim.*` or `meatray.render.*`
    directly, it can do things a library user cannot, and the "you can always drop
    down to the library" promise quietly stops being true — which is how a library
    becomes a framework by accident, one privileged shortcut at a time.

    It is also a facade completeness check by proxy: anything the engine needs and
    the facade cannot express shows up here as a failing test rather than as a
    deep require nobody notices.
]]

return function(t)
    t.describe('the convenience layer requires only the facade')

    local f = io.open('meatray/engine.lua', 'r')
    t.ok(f ~= nil, 'meatray/engine.lua exists')
    if not f then return end

    local source = f:read('*a')
    f:close()

    -- Strip comments first. The header documents the rule and therefore contains
    -- example require lines; scanning raw source would flag the documentation and
    -- miss nothing else. This is the same trap the headless test hit.
    local code = source
        :gsub('%-%-%[%[.-%]%]', '')
        :gsub('%-%-[^\n]*', '')

    local requires = {}
    for path in code:gmatch("require%s*%(%s*['\"]([^'\"]+)['\"]%s*%)") do
        requires[#requires + 1] = path
    end

    t.ok(#requires > 0, 'it requires something at all')

    for _, path in ipairs(requires) do
        local isFacade = (path == 'meatray')
        local isDeep = path:match('^meatray%.') ~= nil

        t.ok(isFacade or not isDeep,
             ('requires "%s" through the facade, not directly'):format(path),
             isDeep and 'reaching past meatray/init.lua bypasses the public API' or nil)
    end

    t.describe('and it does not reach around require either')

    -- A deep path can also arrive through package.loaded or a relative dofile,
    -- which the require scan above would miss entirely.
    t.ok(not code:find('package%.loaded%s*%['), 'no package.loaded lookups')
    t.ok(not code:find('dofile'), 'no dofile')
    t.ok(not code:find('loadfile'), 'no loadfile')

    t.describe('the facade actually exposes what the engine uses')

    -- Every MeatRay.<name> the engine touches must exist on the facade. A typo or
    -- a rename would otherwise surface as a nil index at runtime, in a file whose
    -- whole purpose is to be the easy path.
    local MeatRay = require('meatray')
    local seen = {}

    for name in code:gmatch('MeatRay%.([%w_]+)') do
        if not seen[name] then
            seen[name] = true
            -- Render modules load lazily and need LOVE, so their absence here is
            -- expected under plain LuaJIT; what matters is that the facade knows
            -- the name rather than returning nil for a typo.
            local renderOnly = (name == 'raycaster' or name == 'sprites'
                                or name == 'textures' or name == 'themes'
                                or name == 'lighting')
            if not renderOnly then
                t.ok(MeatRay[name] ~= nil,
                     ('MeatRay.%s exists on the facade'):format(name))
            end
        end
    end

    local count = 0
    for _ in pairs(seen) do count = count + 1 end
    t.ok(count >= 5, ('the engine uses %d facade entries'):format(count))
end
