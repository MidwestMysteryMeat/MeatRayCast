--[[
    Runs the registry.

        love masterserver
        love masterserver --port 8080 --trusted-proxy 10.0.0.1

    A separate LÖVE entry point rather than a flag on the engine's own main.lua,
    because this is not the game: it runs on a small box somewhere and has no
    window, no graphics and no reason to load an engine.

    Its only dependency is LuaSocket, which ships with LÖVE. That is the whole
    deployment story on purpose -- a registry anyone can run is the point, and
    one that needs a toolchain first is one most people will not run.
]]

package.path = './?.lua;./?/init.lua;' .. package.path

local Server = require('masterserver.server')

local server

local function parseArgs(argv)
    local opts = { trustedProxies = {} }

    local function value(i)
        local next = argv[i + 1]
        -- A flag must not swallow the following flag as its value. That exact
        -- bug bit the engine's own argument parsing ("cannot read maps/--editor-tab").
        if next and next:sub(1, 2) ~= '--' then return next end
        return nil
    end

    for i, arg in ipairs(argv) do
        if arg == '--port' then
            opts.port = tonumber(value(i)) or opts.port
        elseif arg == '--challenge-port' then
            opts.challengePort = tonumber(value(i)) or 0
        elseif arg == '--trusted-proxy' then
            local address = value(i)
            if address then opts.trustedProxies[#opts.trustedProxies + 1] = address end
        end
    end

    if #opts.trustedProxies == 0 then opts.trustedProxies = nil end
    return opts
end

function love.load(argv)
    local opts = parseArgs(argv or {})

    server = Server.new(opts)

    local ok, err = server:start()
    if not ok then
        print('[registry] ' .. tostring(err))
        love.event.quit(1)
        return
    end

    if opts.trustedProxies then
        print(('[registry] trusting %d proxy address(es) for X-Forwarded-For')
              :format(#opts.trustedProxies))
    else
        -- Said out loud, because running behind a proxy without configuring this
        -- files every server under the proxy's address, and the symptom is that
        -- every listing looks like it is hosted in the same datacentre.
        print('[registry] no trusted proxies: using socket peer addresses')
    end
end

function love.update(dt)
    if server then server:update(dt) end
end

function love.draw() end

function love.quit()
    if server then server:stop() end
end
