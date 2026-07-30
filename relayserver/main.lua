--[[
    Runs the relay.

        love relayserver
        love relayserver --port 6790
        love relayserver --port 6790 --secret my-community-secret
        love relayserver --max-sessions 4 --session-kbps 128 --total-kbps 512

    A separate LÖVE entry point rather than a flag on the registry, because they
    are different machines' jobs. A registry answers a few hundred bytes of HTTP
    a minute and can live anywhere; a relay carries every byte of every session
    it holds, in both directions, and its cost is bandwidth. Running one process
    would mean an outage of the cheap thing taking the expensive thing with it,
    and a bandwidth bill nobody can attribute.

    Its only dependency is lua-enet, which ships with LÖVE. That is the whole
    deployment story on purpose: a relay anyone can run is the point, and one
    that needs a toolchain first is one most people will not run.

    ## What it costs, before you start it

    A relayed session is charged on what the relay EMITS, both directions summed.
    At the engine's own ceilings -- snapshotRate 20, P.MTU_SAFE_BYTES 1364,
    inputRate 30 -- one client costs about 30 kB/s of relay egress, so:

        1 client    ~30 kB/s     ~2.6 GB/day
        4 clients  ~119 kB/s    ~10.3 GB/day
        8 clients  ~238 kB/s    ~20.5 GB/day    (the default per-session cap)

    The default relay-wide cap is 1 MiB/s, which is 86 GB/day and 2.6 TB/month
    at saturation -- at or over the included transfer on most small VPS plans.
    Raise it knowing that, with --total-kbps, rather than find out on an invoice.

    ## Being told the truth

    It logs what it is doing every ten seconds: sessions, slots, bytes forwarded,
    and how much was throttled. A relay that is silently dropping a fifth of a
    session's snapshots because the operator set the budget too low looks exactly
    like a game with a bad connection, and only the relay knows the difference.
]]

package.path = './?.lua;./?/init.lua;' .. package.path

local RelayHost = require('masterserver.relayhost')
local Relay     = require('masterserver.relay')

local relay
local reportAt = 0

local REPORT_INTERVAL = 10

-- Printed and flushed, every line.
--
-- This process is meant to run for weeks and be killed rather than to exit, and
-- on Windows `setvbuf('line')` is not honoured -- the C runtime treats _IOLBF as
-- full buffering on a redirected stream. So an unflushed relay's log appears
-- only when it dies, which is exactly when nobody can read it, and a relay that
-- has been forwarding happily for an hour looks like one that never started.
-- Observed: `Start-Process -RedirectStandardOutput` captured nothing at all from
-- this process until this call was added.
local function say(text)
    print(text)
    if io.stdout and io.stdout.flush then io.stdout:flush() end
end

local function parseArgs(argv)
    local opts = { relayOptions = {} }

    local function value(i)
        local next = argv[i + 1]
        -- A flag must not swallow the following flag as its value. That exact
        -- bug bit the engine's own argument parsing once already.
        if next and next:sub(1, 2) ~= '--' then return next end
        return nil
    end

    for i, arg in ipairs(argv) do
        if arg == '--port' then
            opts.port = tonumber(value(i)) or opts.port
        elseif arg == '--bind' then
            opts.bind = value(i) or opts.bind
        elseif arg == '--secret' then
            opts.relayOptions.allocationSecret = value(i)
        elseif arg == '--max-sessions' then
            opts.relayOptions.maxSessions = tonumber(value(i))
        elseif arg == '--max-slots' then
            opts.relayOptions.maxSlots = tonumber(value(i))
        elseif arg == '--session-kbps' then
            local kb = tonumber(value(i))
            if kb then
                opts.relayOptions.sessionBytesPerSec = math.floor(kb * 1024)
                opts.relayOptions.sessionBurstBytes  = math.floor(kb * 1024 * 2)
            end
        elseif arg == '--total-kbps' then
            local kb = tonumber(value(i))
            if kb then
                opts.relayOptions.totalBytesPerSec = math.floor(kb * 1024)
                opts.relayOptions.totalBurstBytes  = math.floor(kb * 1024 * 2)
            end
        end
    end

    return opts
end

function love.load(argv)
    local opts = parseArgs(argv or {})

    -- Seeded once, here, rather than inside the relay. Session secrets are the
    -- only thing standing between a stranger and somebody else's session, and
    -- an unseeded math.random hands out the same sequence on every boot.
    math.randomseed(os.time() + math.floor(os.clock() * 1000000))
    for _ = 1, 8 do math.random() end

    opts.onLog = say
    relay = RelayHost.new(opts)
    if not relay then
        say('[relay] could not create the relay')
        love.event.quit(1)
        return
    end

    local ok, err = relay:start()
    if not ok then
        say('[relay] ' .. tostring(err))
        love.event.quit(1)
        return
    end

    if not opts.relayOptions.allocationSecret then
        -- Said out loud. A public relay is a legitimate thing to run and also a
        -- thing somebody may not have realised they started.
        say('[relay] public: any host may open a session, within the caps above')
        say(('[relay] caps: %d sessions, %d per address, %d slots each')
              :format(Relay.MAX_SESSIONS, Relay.MAX_PER_ADDRESS, Relay.MAX_SLOTS))
    end
end

function love.update(dt)
    if not relay then return end

    relay:update(dt)

    if relay.now - reportAt >= REPORT_INTERVAL then
        reportAt = relay.now
        local s = relay.relay.stats
        say(('[relay] %d sessions, %d links, %d frames forwarded, '
            .. '%.1f MB out, %d throttled, %d dropped')
            :format(relay.relay:sessionCount(), relay.relay:linkCount(),
                    s.forwarded, s.bytesOut / 1048576, s.throttled, s.dropped))
    end
end

function love.draw() end

function love.quit()
    if relay then relay:stop() end
end
