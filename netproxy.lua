--[[
    `love . --netproxy --port P --forward host:port [--loss F] [--seconds S]`

    A UDP relay that sits between a client and a host and throws some fraction of
    the datagrams away. It exists so the snapshot stream can be tested for the one
    property it is supposed to have — that a lost snapshot is *skipped* rather than
    retransmitted — which cannot be observed on a link that never loses anything.

    WHY A RELAY AND NOT A SHIM IN THE TRANSPORT

    A shim that dropped packets inside meatray/net/transport/enet.lua would test
    our code and nothing else: the datagram would never reach ENet, so ENet's
    retransmission, fragment reassembly and acknowledgement machinery would never
    run, and it is precisely that machinery whose behaviour is in question. This
    drops real datagrams between two real ENet sockets. Both ends see genuine loss
    and respond to it however they actually respond to it, which is the whole
    point. Nothing in meatray is modified, patched or aware that this exists.

    WHAT IT MEASURES ON THE WAY PAST

    Every datagram is counted and sized before it is forwarded or dropped, which
    makes this the only vantage point in the system that sees the wire rather than
    the packet. ENet reassembles fragments before lua-enet ever sees them, so a
    client cannot tell a fragmented packet from a whole one; the relay can, because
    a fragmented packet arrives here as several datagrams at the path MTU.

    DIRECTION

    `--drop down` (the default) discards only host -> client datagrams. That is
    the direction the snapshot stream travels, and leaving the upstream clean
    means the client's own traffic and its acknowledgements still arrive — so a
    host that decides to retransmit is deciding that because its packet was
    genuinely lost, not because its peer went quiet. `up` and `both` are there for
    completeness.

    DETERMINISM

    Drops are chosen by a seeded Park-Miller generator, never math.random, so a
    run reproduces exactly and a surprising result can be looked at twice. The
    seed is printed.

    GRACE

    Nothing is dropped for the first `--grace` seconds (default 3). ENet handles a
    lossy handshake perfectly well, but a handshake that took four retries makes
    every latency number afterwards harder to read, and the question here is about
    the steady state.

    ADDRESS FAMILY, EXPLICITLY

    The bind address is always spelled out and the bound socket name is printed.
    LuaSocket 3.0 resolves '*' to '::', which produces an IPv6-only socket that
    binds successfully and then never receives anything from an IPv4 peer. That
    failure looks exactly like a blocked port and has cost this project real time
    once already, so the family is reported rather than assumed.
]]

local socket_ok, socket = pcall(require, 'socket')

return function(args)
    if not socket_ok or type(socket) ~= 'table' then
        print('NETPROXY FAILED: LuaSocket is missing; it ships with LOVE')
        return love.event.quit(1)
    end

    local port    = tonumber(args and args.port) or 6800
    local bind    = (args and args.bind) or '127.0.0.1'
    local forward = (args and args.forward) or '127.0.0.1:6789'
    local loss    = tonumber(args and args.loss) or 0
    local seconds = tonumber(args and args.seconds) or 45
    local grace   = tonumber(args and args.grace) or 3
    local seed    = tonumber(args and args.seed) or 20260730
    local drop    = (args and args.drop) or 'down'

    local upIp, upPortText = forward:match('^(.-):(%d+)$')
    if not upIp then
        print('NETPROXY FAILED: --forward wants host:port, got ' .. tostring(forward))
        return love.event.quit(1)
    end
    local upPort = tonumber(upPortText)

    -----------------------------------------------------------------------
    local state = seed % 2147483647
    if state <= 0 then state = state + 2147483646 end
    local function nextRandom()
        state = (state * 16807) % 2147483647
        return state / 2147483647
    end

    -----------------------------------------------------------------------
    local udp = socket.udp()
    if not udp then
        print('NETPROXY FAILED: could not create a UDP socket')
        return love.event.quit(1)
    end

    local bound, bindErr = udp:setsockname(bind, port)
    if not bound then
        print(('NETPROXY FAILED: could not bind %s:%d - %s')
              :format(bind, port, tostring(bindErr)))
        return love.event.quit(1)
    end
    udp:settimeout(0)

    local boundIp, boundPort = udp:getsockname()
    print(('[proxy] bound %s:%s  (family reported by getsockname, not assumed)')
          :format(tostring(boundIp), tostring(boundPort)))
    print(('[proxy] forwarding to %s:%d'):format(upIp, upPort))
    print(('[proxy] loss %.3f on %s, grace %gs, budget %gs, seed %d')
          :format(loss, drop, grace, seconds, seed))
    print(('-'):rep(58))

    local dropDown = (drop == 'down' or drop == 'both')
    local dropUp   = (drop == 'up'   or drop == 'both')

    -----------------------------------------------------------------------
    -- Counters. `bytes` is on the forwarded datagrams only; `sizes` keeps the
    -- distribution of everything seen, dropped or not, because the size question
    -- is about what the sender emitted.
    local function tally()
        return { seen = 0, dropped = 0, bytes = 0, max = 0, over1300 = 0, over1364 = 0,
                 buckets = {} }
    end
    local down, up = tally(), tally()

    local BUCKETS = { 64, 128, 256, 512, 768, 1024, 1200, 1300, 1364, 1392, 1500, 1e9 }

    local function record(t, size)
        t.seen = t.seen + 1
        if size > t.max then t.max = size end
        if size > 1300 then t.over1300 = t.over1300 + 1 end
        if size > 1364 then t.over1364 = t.over1364 + 1 end
        for i = 1, #BUCKETS do
            if size <= BUCKETS[i] then
                t.buckets[i] = (t.buckets[i] or 0) + 1
                break
            end
        end
    end

    -----------------------------------------------------------------------
    local started = love.timer.getTime()
    local clientIp, clientPort
    local firstSeen

    while love.timer.getTime() - started < seconds do
        local data, ip, fromPort = udp:receivefrom()

        if data then
            firstSeen = firstSeen or (love.timer.getTime() - started)
            local size = #data
            local fromHost = (ip == upIp and fromPort == upPort)
            local elapsed = love.timer.getTime() - started
            local mayDrop = elapsed >= grace

            if fromHost then
                record(down, size)
                if mayDrop and dropDown and nextRandom() < loss then
                    down.dropped = down.dropped + 1
                elseif clientIp then
                    down.bytes = down.bytes + size
                    udp:sendto(data, clientIp, clientPort)
                end
            else
                clientIp, clientPort = ip, fromPort
                record(up, size)
                if mayDrop and dropUp and nextRandom() < loss then
                    up.dropped = up.dropped + 1
                else
                    up.bytes = up.bytes + size
                    udp:sendto(data, upIp, upPort)
                end
            end
        else
            -- Nothing pending. Sleeping a millisecond keeps a core free without
            -- adding meaningful latency: the measurements downstream are in tens
            -- of milliseconds.
            love.timer.sleep(0.001)
        end
    end

    local elapsed = love.timer.getTime() - started
    udp:close()

    -----------------------------------------------------------------------
    local function report(label, t)
        print(('[proxy] %s: %d datagrams, %d dropped (%.1f%%), %.1f KB forwarded, '
               .. 'largest %d bytes')
              :format(label, t.seen, t.dropped,
                      t.seen > 0 and (100 * t.dropped / t.seen) or 0,
                      t.bytes / 1024, t.max))
        print(('[proxy]   %d were over 1300 bytes, %d over MTU_SAFE_BYTES (1364)')
              :format(t.over1300, t.over1364))
        local low = 0
        for i = 1, #BUCKETS do
            local n = t.buckets[i]
            if n then
                print(('[proxy]   %5d..%-5s %6d')
                      :format(low + 1,
                              BUCKETS[i] >= 1e9 and 'more' or tostring(BUCKETS[i]), n))
            end
            low = BUCKETS[i]
        end
    end

    print(('-'):rep(58))
    print(('[proxy] ran %.2f s (budget %g s), first datagram at %.2f s')
          :format(elapsed, seconds, firstSeen or -1))
    report('host -> client', down)
    report('client -> host', up)
    print(('[proxy] downstream datagram rate %.1f/s'):format(down.seen / elapsed))
    print('NETPROXY DONE')
    love.event.quit(0)
end
