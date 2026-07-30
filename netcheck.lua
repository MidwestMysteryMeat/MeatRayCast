--[[
    `love . --netcheck [--port N]` — is networking possible on this machine?

    Five questions, cheapest first, each independently useful. They are separate
    checks because they fail for different reasons and are fixed in different
    places, and collapsing them into "networking is broken" is exactly the advice
    that sends someone hunting a phantom bug in the handshake.

      1. Is LuaSocket present?      (LAN discovery needs it)
      2. Is lua-enet present?       (the transport needs it)
      3. Can a UDP datagram cross this machine to itself?
      4. Can the game port be bound?
      5. Can two ENet peers in this process complete a handshake over 127.0.0.1?

    Check 5 is the strong one. It exercises the same transport, the same channel
    counts and the same connect/service loop the game uses, with the game logic
    removed — so if it passes and a real join does not, the fault is above the
    transport, and if it fails, the fault is below it. That distinction is the
    entire value of running this before debugging anything else.

    Exit codes, so a script can act on the answer:
        0  everything works
        4  UDP is blocked on this machine (see the printed remedy)
        5  the game port could not be bound
        6  lua-enet or LuaSocket is missing
        7  UDP works and the port binds, but the ENet handshake did not complete
]]

local MeatRay = require('meatray')

return function(args)
    local Diagnostics = MeatRay.net.diagnostics
    local P           = MeatRay.net.protocol

    local port = (args and args.port) or MeatRay.net.DEFAULT_PORT
    local problems = {}

    local function say(text) print('[net] ' .. text) end
    local function bad(text) problems[#problems + 1] = text end

    say(('netcheck: port %d, protocol %d'):format(port, P.VERSION))
    print(('-'):rep(58))

    ---------------------------------------------------------------------
    say('1. LuaSocket (LAN discovery)')
    local hasSocket, socket = pcall(require, 'socket')
    if hasSocket and type(socket) == 'table' then
        say('   ok - ' .. tostring(socket._VERSION))
    else
        say('   MISSING - LAN discovery will be off; direct connection still works')
        bad('LuaSocket is missing')
    end

    ---------------------------------------------------------------------
    say('2. lua-enet (the UDP transport)')
    local hasEnet, enet = pcall(require, 'enet')
    if hasEnet and type(enet) == 'table' then
        say('   ok - bundled with LOVE, nothing to install')
    else
        say('   MISSING - there is no transport, so nothing can be hosted or joined')
        bad('lua-enet is missing')
        print(('-'):rep(58))
        print('NETCHECK FAILED')
        love.event.quit(6)
        return
    end

    ---------------------------------------------------------------------
    say('3. UDP to this machine, from this machine')
    local udpOk, udpError = Diagnostics.probeLoopbackUdp()
    if udpOk == true then
        say('   ok - a datagram made the round trip over 127.0.0.1')
    elseif udpOk == nil then
        say('   skipped - ' .. tostring(udpError))
    else
        say('   BLOCKED - ' .. tostring(udpError))
        Diagnostics.udpRemedy(function(line) print('[net]' .. line) end, port)
        bad('UDP is blocked on this machine')
        print(('-'):rep(58))
        print('NETCHECK FAILED')
        love.event.quit(4)
        return
    end

    ---------------------------------------------------------------------
    say(('4. binding UDP %d'):format(port))
    local boundOk, boundHost = pcall(enet.host_create, ('0.0.0.0:%d'):format(port),
                                     4, P.CHANNELS)
    if boundOk and boundHost then
        say('   ok')
    else
        say(('   FAILED - %s'):format(tostring(boundHost)))
        say('   the port is in use by something else, or a firewall refused the bind')
        say(('   try another: love . --netcheck --port %d'):format(port + 1))
        bad(('UDP %d could not be bound'):format(port))
        print(('-'):rep(58))
        print('NETCHECK FAILED')
        love.event.quit(5)
        return
    end

    ---------------------------------------------------------------------
    say('5. an ENet handshake over 127.0.0.1')
    -- Same transport, same channel count, same service loop as the game; the game
    -- logic is what is deliberately absent.
    local clientOk, clientHost = pcall(enet.host_create, nil, 1, P.CHANNELS)
    if not clientOk or not clientHost then
        say('   FAILED - could not create a client socket: ' .. tostring(clientHost))
        bad('a client socket could not be created')
    else
        local peer = clientHost:connect(('127.0.0.1:%d'):format(port), P.CHANNELS)
        local serverSaw, clientSaw, echoed = false, false, false

        local clock = (hasSocket and socket.gettime) or os.clock
        local deadline = clock() + 5

        while clock() < deadline and not echoed do
            local event = boundHost:service(0)
            while event do
                if event.type == 'connect' then
                    serverSaw = true
                    event.peer:send('netcheck', P.CH_RELIABLE, 'reliable')
                    event.peer:send('stream', P.CH_STREAM, 'unreliable')
                end
                event = boundHost:service(0)
            end

            local reply = clientHost:service(0)
            while reply do
                if reply.type == 'connect' then clientSaw = true end
                if reply.type == 'receive' and reply.data == 'netcheck' then echoed = true end
                reply = clientHost:service(0)
            end

            if socket and socket.sleep then socket.sleep(0.005) end
        end

        if serverSaw and clientSaw and echoed then
            say(('   ok - both peers connected and a reliable packet arrived (rtt %sms)')
                :format(tostring(peer and peer:round_trip_time())))
        else
            say(('   FAILED - server saw connect: %s, client saw connect: %s, '
                 .. 'packet arrived: %s'):format(tostring(serverSaw), tostring(clientSaw),
                                                 tostring(echoed)))
            say('   UDP works and the port binds, so this is not a firewall:')
            say('   the transport or the ENet build is at fault')
            bad('the ENet handshake did not complete over loopback')
        end

        clientHost = nil
    end

    ---------------------------------------------------------------------
    print(('-'):rep(58))
    if #problems == 0 then
        print('NETCHECK PASSED - this machine can host and join')
        love.event.quit(0)
    else
        for _, problem in ipairs(problems) do print('  - ' .. problem) end
        print('NETCHECK FAILED')
        love.event.quit(7)
    end
end
