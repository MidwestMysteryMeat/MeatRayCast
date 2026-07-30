--[[
    Does the relay work over a real socket?

        love relaycheck                            relay, host and client in one
                                                   process, over real UDP
        love relaycheck --relay 127.0.0.1:6790     against a relay running
                                                   somewhere else
        love relaycheck --relay 1.2.3.4:6790 --timeout 60

    Exit 0 when every step passed, 1 otherwise, and every step prints what it did
    and how long it took.

    ## Why this exists beside the headless suite

    `tests/test_relay.lua` and `tests/test_net_relay.lua` drive the same relay,
    the same frame format and the same transport with `inner = 'loopback'`, which
    proves the logic and proves nothing about sockets. This proves the other
    half: that ENet really does terminate on both sides of the relay, that a
    payload at the engine's own snapshot cap crosses two hops in one datagram
    each, and that a real Host and a real Client complete a real handshake
    through a machine neither of them can address directly.

    `--relay` is the interesting mode. With it, the relay is a different process
    with a different socket, reached over the network stack, and the dial in
    meatray/net/transport/relay.lua is doing the blocking wait it was written for
    rather than being satisfied by an in-process pump. `scripts/relaycheck.ps1`
    runs it that way.

    ## Budgets, stated

    Every wait here has one and reports the time it actually spent. An
    under-waiting probe once read a working port as a blocked one in this project
    and produced four pointless firewall rules, so:

        the dial          15 s   (relay transport DIAL_TIMEOUT, raised)
        the handshake     20 s
        the whole run     45 s   (--timeout)
]]

package.path = './?.lua;./?/init.lua;' .. package.path

local RelayHost = require('masterserver.relayhost')
local Relay     = require('masterserver.relay')
local RelayT    = require('meatray.net.transport.relay')
local Net       = require('meatray.net')
local Worldgen  = require('meatray.sim.worldgen')
local P         = require('meatray.net.protocol')

local DIAL_TIMEOUT      = 15
local HANDSHAKE_TIMEOUT = 20

local state = {
    failures = {},
    checks   = 0,
    started  = 0,
    phase    = 'setup',
}

local function now()
    return love.timer and love.timer.getTime() or os.time()
end

local function say(text)
    print('[relaycheck] ' .. text)
end

local function check(ok, label, detail)
    state.checks = state.checks + 1
    if ok then
        say(('  ok    %s'):format(label))
    else
        state.failures[#state.failures + 1] = label
        say(('  FAIL  %s%s'):format(label, detail and ('  [' .. tostring(detail) .. ']') or ''))
    end
    return ok
end

local function parseArgs(argv)
    local opts = { timeout = 45 }

    local function value(i)
        local next = argv[i + 1]
        if next and next:sub(1, 2) ~= '--' then return next end
        return nil
    end

    for i, arg in ipairs(argv) do
        if arg == '--relay' then
            opts.relay = value(i)
        elseif arg == '--port' then
            opts.port = tonumber(value(i))
        elseif arg == '--timeout' then
            opts.timeout = tonumber(value(i)) or opts.timeout
        end
    end

    return opts
end

---------------------------------------------------------------------------

function love.load(argv)
    local opts = parseArgs(argv or {})
    state.timeout = opts.timeout
    state.started = now()

    math.randomseed(os.time() + math.floor(os.clock() * 1000000))
    for _ = 1, 8 do math.random() end

    say('MeatRayCast relay check, over real UDP')

    ---------------------------------------------------------------------
    -- The relay: ours, or somebody else's.
    local relayAddress = opts.relay
    local pump = nil

    if not relayAddress then
        local port = opts.port or 6790
        local server, err = RelayHost.new{
            port = port, bind = '0.0.0.0',
            relay = Relay.new{},
            onLog = function(text) print(text) end,
        }
        if not server then
            check(false, 'the relay could be created', err)
            return
        end

        local ok, startErr = server:start()
        if not ok then
            check(false, 'the relay bound its port', startErr)
            return
        end

        state.server = server
        relayAddress = '127.0.0.1:' .. port
        -- In-process, so the relay needs a turn inside the dial loop. With an
        -- external relay this is nil and the dial does the real blocking wait.
        pump = function() server:update(0.001) end
        say('using an in-process relay on ' .. relayAddress)
    else
        say('using the relay at ' .. relayAddress .. ' (a different process)')
    end

    state.relayAddress = relayAddress
    state.pump = pump

    ---------------------------------------------------------------------
    -- A dedicated host, on the relay transport.
    local dialStart = now()

    local hostTransport, hostErr = RelayT.new{
        relay = relayAddress, dialTimeout = DIAL_TIMEOUT,
    }
    if not hostTransport then
        check(false, 'the relay transport was created', hostErr)
        return
    end
    hostTransport.pump = pump

    local server, serverErr = Net.Host.new{
        mode = 'dedicated',
        transport = hostTransport,
        port = 6789,
        world = Worldgen.box(16, 16),
        name = 'relaycheck',
        onLog = function(text) print('[host] ' .. tostring(text)) end,
        onWarning = function() end,
    }

    if not check(server ~= nil,
                 ('a dedicated host opened a relay session (%.2fs, budget %ds)')
                 :format(now() - dialStart, DIAL_TIMEOUT), serverErr) then
        return
    end
    state.server_ = server

    local ticket = hostTransport:ticket()
    check(ticket ~= nil, 'and got a ticket: ' .. tostring(ticket))
    if not ticket then return end

    -- A relay session IS the traversal, so the host must not claim it will
    -- punch. This is the field host.lua computes from the transport's shape.
    check(server.canPunch == false,
          'the host reports hole punching as unsupported, not armed')

    ---------------------------------------------------------------------
    -- A client, joining with nothing but that ticket.
    local joinStart = now()

    local clientTransport = RelayT.new{ dialTimeout = DIAL_TIMEOUT }
    clientTransport.pump = pump

    local client, clientErr = Net.Client.new{
        address = ticket,
        transport = clientTransport,
        name = 'ada',
        punch = false,
        onLog = function(text) print('[client] ' .. tostring(text)) end,
    }

    if not check(client ~= nil,
                 ('a client dialled the relay with the ticket (%.2fs, budget %ds)')
                 :format(now() - joinStart, DIAL_TIMEOUT), clientErr) then
        return
    end

    state.client = client
    state.host = server
    state.hostTransport = hostTransport
    state.handshakeStart = now()
    state.phase = 'handshake'
    say(('waiting for the handshake (budget %ds)'):format(HANDSHAKE_TIMEOUT))
end

---------------------------------------------------------------------------

local function finish()
    state.phase = 'done'

    local elapsed = now() - state.started
    say(('%d checks in %.2fs'):format(state.checks, elapsed))

    if #state.failures == 0 then
        say('PASS')
        love.event.quit(0)
    else
        say(('FAIL: %d of %d'):format(#state.failures, state.checks))
        for _, text in ipairs(state.failures) do say('  - ' .. text) end
        love.event.quit(1)
    end
end

-- A second session on the same relay, with nothing but two raw transports on it,
-- carrying the payload the one-byte header was argued for.
--
-- Its own session on purpose: injecting 1364 bytes of anything into the game
-- protocol makes the client report an unreadable packet, which is the client
-- being right and the probe being rude. Here there is no protocol to offend.
--
-- The claim being tested is the one the header arithmetic makes.
-- P.MTU_SAFE_BYTES is 1364 and the relay adds one byte; the real
-- single-datagram payload budget measured on this build is 1372. So a snapshot
-- at the engine's own cap should cross two ENet hops whole. If it did not, it
-- would still arrive -- ENet would fragment it and deliver it reliably -- which
-- is exactly the silent promotion the snapshot codec exists to avoid, so this
-- also checks that it arrived on the unreliable path by arriving at all under a
-- short budget.
local function startSizeProbe()
    state.phase = 'size'
    state.sizeStart = now()
    state.sizeDeadline = now() + 10

    local a, aErr = RelayT.new{ relay = state.relayAddress, dialTimeout = DIAL_TIMEOUT }
    if not a then
        check(false, 'a second relay transport was created', aErr)
        return finish()
    end
    a.pump = state.pump

    local ok, listenErr = a:listen{ maxPeers = 2, channels = P.CHANNELS }
    if not check(ok, 'a second session opens on the same relay', listenErr) then
        return finish()
    end

    local b = RelayT.new{ dialTimeout = DIAL_TIMEOUT }
    b.pump = state.pump

    local peer, joinErr = b:connect(a:ticket())
    if not check(peer ~= nil, 'and a raw client joins it', joinErr) then
        return finish()
    end

    state.sizeA, state.sizeB, state.sizeBPeer = a, b, peer
    state.payload = string.rep('S', P.MTU_SAFE_BYTES)
    state.sizeSent = false
end

local function pumpSizeProbe()
    local a, b = state.sizeA, state.sizeB

    a:update(0)
    b:update(0)

    while true do
        local event = a:service()
        if not event then break end
        if event.type == 'connect' and not state.sizeSent then
            state.sizeSent = true
            state.sizeAt = now()
            a:send(event.peer, state.payload, P.CH_STREAM, false)
        end
    end

    while true do
        local event = b:service()
        if not event then break end
        if event.type == 'receive' then
            check(#event.data == P.MTU_SAFE_BYTES,
                  ('a %d-byte payload crossed two real ENet hops whole in %.3fs')
                  :format(P.MTU_SAFE_BYTES, now() - (state.sizeAt or now())),
                  ('%d bytes'):format(#event.data))
            check(event.data == state.payload, 'byte for byte')

            local stats = state.server and state.server.relay.stats
            if stats then
                check(stats.forwarded > 0,
                      ('the relay forwarded %d frames, %d bytes out')
                      :format(stats.forwarded, stats.bytesOut))
                check(stats.throttled == 0,
                      'and throttled nothing across the whole run')
            end

            a:close(); b:close()
            return finish()
        end
    end

    if now() > state.sizeDeadline then
        check(false, ('a %d-byte payload arrived within 10s'):format(P.MTU_SAFE_BYTES))
        a:close(); b:close()
        finish()
    end
end

local function assertJoined()
    local client, host = state.client, state.host
    local waited = now() - state.handshakeStart

    check(true, ('the handshake completed in %.2fs'):format(waited))
    check(client.state == 'joined', 'the client is joined', client.state)
    check(host:playerCount() == 1, 'and the host counts one player',
          host:playerCount())

    local peer
    for _, row in pairs(host.peers or {}) do peer = row end

    if peer then
        -- The host's view of the client's address must be the client, not the
        -- relay, or one ban removes everybody on the relay.
        check(peer.address ~= nil and peer.address ~= state.relayAddress,
              'the host sees the client address, not the relay address',
              tostring(peer.address))
    else
        check(false, 'the host has a peer for the client')
    end

    -- Round trip time across both hops. Zero is a legitimate answer on loopback;
    -- nil is not, because lag compensation would then rewind by nothing.
    local rtt = peer and peer.handle and state.hostTransport:rtt(peer.handle)
    check(rtt ~= nil, 'the transport reports a round-trip time', tostring(rtt))

    state.phase = 'probe'
    state.probeDeadline = now() + 5
end

function love.update(dt)
    if state.phase == 'done' then return end

    if state.phase == 'setup' then
        -- love.load bailed before anything was built.
        finish()
        return
    end

    if state.server then state.server:update(dt) end
    if state.host then state.host:update(dt) end
    if state.server then state.server:update(0) end
    if state.client then state.client:update(dt) end
    if state.server then state.server:update(0) end

    if now() - state.started > state.timeout then
        check(false, ('the run finished inside its %ds budget'):format(state.timeout))
        finish()
        return
    end

    if state.phase == 'handshake' then
        if state.client.state == 'joined' and state.host:playerCount() >= 1 then
            assertJoined()
        elseif now() - state.handshakeStart > HANDSHAKE_TIMEOUT then
            check(false, ('the handshake completed inside %ds (state %s)')
                  :format(HANDSHAKE_TIMEOUT, tostring(state.client.state)))
            finish()
        end
        return
    end

    if state.phase == 'probe' then
        -- The client applies snapshots; lastTick only ever moves when one is.
        if state.client.lastTick > 0 then
            check(true, ('snapshots crossed the relay (tick %d)')
                  :format(state.client.lastTick))
            startSizeProbe()
        elseif now() > state.probeDeadline then
            check(false, 'a snapshot reached the client within 5s')
            finish()
        end
        return
    end

    if state.phase == 'size' then
        pumpSizeProbe()
        return
    end
end

function love.draw() end

function love.quit()
    if state.client then state.client:close() end
    if state.host then state.host:close() end
    if state.server then state.server:stop() end
end
