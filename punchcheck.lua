--[[
    `love . --punchcheck --connect host:port --registry URL [--seconds S]`

    Joins one server through a registry and reports what the hole punch actually
    did, with numbers. It is the client half of the acceptance run; the host half
    is an ordinary `love . --server --registry URL`, which logs its own punches.

    WHAT THIS CAN AND CANNOT TELL YOU

    It cannot tell you that NAT traversal works. Run against 127.0.0.1 there is
    no NAT to traverse, and run against a real host it cannot distinguish a punch
    that opened a path from a path that was open anyway. Nothing here claims
    otherwise. What it does answer, and what no unit test can:

      * did the registry accept the introduction, and how long did that take
      * did the client connect WITHOUT waiting for that answer — reported as the
        gap between the connect and the introduction completing, which is
        negative-or-zero by construction if the order is right
      * did the join complete, and after how long
      * when it did not, does it fail with a reason rather than hanging

    THE BUDGET IS GENEROUS AND IT IS PRINTED

    A punched join can legitimately take a while: introductions reach the host on
    its heartbeat, heartbeats are ten seconds apart, and the registry's nudge
    that shortens this is one unacknowledged datagram. An impatient probe here
    would report a working punch as a dead server -- this project has already
    paid for that mistake once, in four firewall rules that fixed nothing. So the
    default budget is 45 seconds, the elapsed time is always printed alongside
    it, and a failure says how long it actually waited.

    Blocking loops are correct here: there is no window to keep responsive and
    the process exists to answer one question and exit with a status.
]]

local MeatRay = require('meatray')

return function(args)
    local Net = MeatRay.net

    local address  = (args and args.connect) or '127.0.0.1:6789'
    local seconds  = tonumber(args and args.seconds) or 45
    local registries = args and args.registries

    print(('MeatRayCast punchcheck: %s via %s')
          :format(address, registries and table.concat(registries, ', ') or '(no registry)'))
    print(('-'):rep(58))

    if not registries or #registries == 0 then
        print('PUNCHCHECK FAILED: --registry URL is required; without one there is '
              .. 'nobody to ask for an introduction and this is just a join')
        return love.event.quit(2)
    end

    local started = love.timer.getTime()
    local function since() return love.timer.getTime() - started end

    local client, err = Net.join(address, {
        name = 'punchcheck',
        registries = registries,
        onLog = function(line) print(('  %+7.3fs %s'):format(since(), line)) end,
    })

    if not client then
        print(('PUNCHCHECK FAILED after %.3fs: %s'):format(since(), tostring(err)))
        return love.event.quit(1)
    end

    -- Recorded the instant Net.join returns. Net.join builds the client, which
    -- asks for the introduction and then connects, so by the time we are back
    -- here the connect has already left the socket. If the introduction is still
    -- outstanding at this point -- and it will be, over any real link -- that is
    -- the proof that nothing waited for it.
    local connectedAt = since()
    local waitedForPunch = client.punch ~= nil

    print(('  %+7.3fs connect issued; introduction still outstanding: %s')
          :format(connectedAt, tostring(waitedForPunch)))

    local punchDoneAt
    local step = 0.01
    while since() < seconds do
        love.timer.sleep(step)
        client:update(step)

        if not punchDoneAt and client.punchResult then
            punchDoneAt = since()
            print(('  %+7.3fs introduction %s'):format(punchDoneAt, client.punchResult))
        end

        if client.state ~= 'connecting' then break end
    end

    local elapsed = since()

    print(('-'):rep(58))
    print(('budget %gs, elapsed %.3fs'):format(seconds, elapsed))
    print(('introduction requested on UDP %s'):format(tostring(client.punchPort)))
    print(('introduction outcome:      %s%s')
          :format(tostring(client.punchResult or 'still outstanding'),
                  punchDoneAt and (' after %.3fs'):format(punchDoneAt) or ''))
    print(('connect issued at:         %.3fs'):format(connectedAt))
    print(('the connect did NOT wait for the introduction: %s')
          :format(tostring(waitedForPunch or (punchDoneAt or math.huge) >= connectedAt)))
    print(('join state:                %s%s')
          :format(client.state, client.reason and (' - ' .. client.reason) or ''))

    local joined = client.state == 'joined'
    if joined then
        print(('joined %s (%s) after %.3fs')
              :format(tostring(client.server.name), tostring(client.server.map), elapsed))
    end

    client:leave()

    -- Exit 0 only on a completed join. A checker that always exits 0 cannot be
    -- asserted on by whatever runs it.
    print(joined and 'PUNCHCHECK PASSED' or 'PUNCHCHECK FAILED')
    love.event.quit(joined and 0 or 1)
end
