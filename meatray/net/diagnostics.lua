--[[
    meatray.net.diagnostics — telling a host the truth about who can reach it.

    An empty server list with no explanation is the single most common way
    self-hosting silently defeats people. The host is behind a router, the router
    drops unsolicited inbound UDP, and the game says nothing — so the conclusion
    the player reaches is "multiplayer is broken", which is both wrong and
    unfixable from where they are standing.

    So reachability is reported in three separable pieces, because they fail
    independently and conflating them is what makes the message useless:

      1. Did the socket bind at all? If not, nobody can reach you, and the reason
         is local: the port is in use or a firewall refused it.
      2. Can the LAN reach you? If the socket bound and the beacon is running,
         yes — and that is worth saying explicitly, because "LAN players can join
         but nobody else can" is a completely different situation from "nothing
         works" and needs a completely different response.
      3. Can the internet reach you? This cannot be determined from inside the
         machine. Something outside has to try. That is a master server's job, and
         the master server is not implemented, so the honest answer today is
         "unknown" plus what the player should do about it.

    The port number is always named, because "forward the port" is useless advice
    without it.

    classify() is a pure function of a facts table. That is not an accident: it
    means every message this system can produce is asserted in the headless test
    suite with no sockets involved, and a wrong word in a diagnostic is a wrong
    word a test can catch.
]]

local Diagnostics = {}

Diagnostics.PREFIX = '[net]'

---------------------------------------------------------------------------
-- Address classification
---------------------------------------------------------------------------

-- RFC1918, plus loopback and link-local. A host on one of these is behind NAT as
-- far as anyone outside is concerned.
function Diagnostics.isPrivateAddress(ip)
    if type(ip) ~= 'string' then return false end

    if ip == '::1' or ip:match('^fe80:') or ip:match('^f[cd]') then return true end

    local a, b = ip:match('^(%d+)%.(%d+)%.')
    a, b = tonumber(a), tonumber(b)
    if not a then return false end

    if a == 10 or a == 127 then return true end
    if a == 192 and b == 168 then return true end
    if a == 172 and b and b >= 16 and b <= 31 then return true end
    if a == 169 and b == 254 then return true end
    if a == 100 and b and b >= 64 and b <= 127 then return true end   -- carrier NAT

    return false
end

-- Best-effort local address, via a UDP socket that is never actually sent on:
-- connecting a datagram socket makes the OS choose a source interface, and that
-- choice is the address other machines on the LAN would use. Returns nil when
-- LuaSocket is absent, which is the plain-LuaJIT case.
function Diagnostics.localAddress()
    local ok, socket = pcall(require, 'socket')
    if not ok or not socket then return nil end

    local udp = socket.udp()
    if not udp then return nil end

    -- A routable address that is never contacted; only the routing decision
    -- matters.
    udp:setpeername('192.0.2.1', 9)
    local ip = udp:getsockname()
    udp:close()

    if ip == '0.0.0.0' or ip == '*' then return nil end
    return ip
end

---------------------------------------------------------------------------
-- Can this machine do UDP at all?
---------------------------------------------------------------------------

-- Sends a datagram from one local socket to another and waits for it. Both ends
-- are on 127.0.0.1, so nothing about the network is involved: if this fails while
-- the game port bound successfully, something between the socket and the stack is
-- dropping datagrams — a firewall rule, an endpoint-protection product, or a VPN
-- client with a filtering driver.
--
-- Worth testing separately from the game port because the two fail differently
-- and are fixed differently. A bind failure is a port clash and the answer is a
-- different port; this is a policy decision made by other software and the answer
-- is a rule. Reporting either as "could not host" sends the player looking in the
-- wrong place, which is the failure mode this whole module exists to prevent.
--
-- Returns true, or false plus a reason, or nil when it cannot be determined
-- (LuaSocket absent, i.e. a plain-Lua run).
function Diagnostics.probeLoopbackUdp()
    local loaded, socket = pcall(require, 'socket')
    if not loaded or type(socket) ~= 'table' then
        return nil, 'LuaSocket is not available, so UDP cannot be self-tested'
    end

    local receiver = socket.udp()
    if not receiver then return nil, 'could not create a UDP socket' end
    receiver:settimeout(0)

    -- Explicitly IPv4: '*' resolves to '::' on LuaSocket 3, and an IPv6 socket
    -- cannot be sent to at an IPv4 literal — which fails in a way that looks
    -- exactly like a blocked port and is not one.
    local bound, bindErr = receiver:setsockname('127.0.0.1', 0)
    if not bound then
        receiver:close()
        return false, ('could not bind a loopback UDP socket: %s'):format(tostring(bindErr))
    end

    local _, portText = receiver:getsockname()
    local port = tonumber(portText)
    if not port then
        receiver:close()
        return false, 'a bound UDP socket reported no port'
    end

    local sender = socket.udp()
    sender:settimeout(0)
    sender:setsockname('0.0.0.0', 0)

    local payload = 'meatray-udp-probe'
    local sent, sendErr = sender:sendto(payload, '127.0.0.1', port)
    if not sent then
        sender:close(); receiver:close()
        return false, ('a UDP datagram to 127.0.0.1:%d was refused: %s')
            :format(port, tostring(sendErr))
    end

    -- Loopback delivery is immediate, but a busy machine is still allowed to take
    -- longer than zero, so this waits rather than testing once.
    local clock = socket.gettime or os.clock
    local deadline = clock() + 0.5
    local got
    repeat
        got = receiver:receivefrom()
        if got then break end
        if socket.sleep then socket.sleep(0.005) end
    until clock() > deadline

    sender:close(); receiver:close()

    if got ~= payload then
        return false, ('a UDP datagram sent to 127.0.0.1:%d never arrived'):format(port)
    end

    return true
end

-- The remedy lines for a machine where UDP does not work. Separated out so the
-- server browser, the host banner and the `--netcheck` command all print the same
-- words, and so the words themselves are asserted in the test suite.
function Diagnostics.udpRemedy(say, port)
    say('  the game port bound, but a UDP datagram could not cross this machine')
    say('  to itself - so no player can reach you, on the LAN or otherwise')
    say('  something is filtering UDP: a firewall rule, endpoint protection, or a VPN')
    say('  on Windows, allow LOVE through the firewall from an admin PowerShell:')
    say('    New-NetFirewallRule -DisplayName "LOVE UDP" -Direction Inbound '
        .. '-Program "<path to love.exe>" -Protocol UDP -Action Allow')
    say('    New-NetFirewallRule -DisplayName "LOVE UDP" -Direction Inbound '
        .. '-Program "<path to lovec.exe>" -Protocol UDP -Action Allow')
    say(('  then check it with:  love . --netcheck --port %s'):format(tostring(port)))
end

---------------------------------------------------------------------------
-- The report
---------------------------------------------------------------------------

-- facts = {
--   port        number
--   bound       boolean         did the transport get the socket
--   bindError   string          why not
--   lan         boolean         is a LAN beacon running
--   address     string          our local address, if known
--   external    'unknown' | 'reachable' | 'unreachable'
--   holePunch   nil | 'ok' | 'failed' | 'unsupported'
--   holePunchNote string        e.g. 'symmetric NAT'
--   mode        'listen' | 'dedicated'
-- }
--
-- Returns { reach = 'none'|'lan'|'internet'|'unknown', lines = { ... },
--           forwardPort = number|nil }
function Diagnostics.classify(facts)
    facts = facts or {}
    local port = facts.port
    local lines = {}
    local function say(text) lines[#lines + 1] = text end

    ---------------------------------------------------------------------
    -- 1. Did we bind?
    if facts.bound == false then
        say(('! cannot listen on UDP %s: %s')
            :format(tostring(port), facts.bindError or 'unknown reason'))
        say('  nobody can reach you - the port is in use, or a firewall refused it')
        say(('  try a different port: --port %d'):format((tonumber(port) or 6789) + 1))
        return { reach = 'none', lines = lines, forwardPort = nil }
    end

    say(('listening on UDP %s'):format(tostring(port)))

    ---------------------------------------------------------------------
    -- 1b. Does UDP work at all? A bound socket is not the same thing as a
    -- deliverable datagram, and on a machine where something is filtering UDP the
    -- two look identical from the outside: the server starts, says it is
    -- listening, and nobody can ever join. Naming it here is the difference
    -- between a five-minute fix and a day spent suspecting the handshake.
    if facts.udp == false then
        say('! UDP is being blocked on this machine, even to itself')
        if facts.udpError then say('  ' .. tostring(facts.udpError)) end
        Diagnostics.udpRemedy(say, port)
        return { reach = 'none', lines = lines, forwardPort = port, blocked = 'udp' }
    end

    ---------------------------------------------------------------------
    -- 2. Can the LAN reach us?
    if facts.lan then
        say('LAN beacon active - local players can join')
    else
        say(('LAN discovery off - players need your address: %s')
            :format(Diagnostics.addressText(facts)))
    end

    ---------------------------------------------------------------------
    -- 3. Can the internet reach us?
    local external = facts.external or 'unknown'
    local private = facts.address and Diagnostics.isPrivateAddress(facts.address)

    if external == 'reachable' then
        say(('reachable from outside on UDP %s'):format(tostring(port)))
        return { reach = 'internet', lines = lines, forwardPort = nil }
    end

    if external == 'unreachable' then
        say('! nobody outside your LAN can reach you')
        Diagnostics.holePunchLines(facts, say)
        say(('  forward UDP %s to this machine%s, or use a dedicated server')
            :format(tostring(port), facts.address and (' (' .. facts.address .. ')') or ''))
        -- LAN still works if the socket bound and the beacon is up. Saying so is
        -- the difference between a player giving up and a player playing with the
        -- people in the room.
        return { reach = facts.lan and 'lan' or 'none', lines = lines, forwardPort = port }
    end

    -- external == 'unknown'. Nothing outside has tried, so do not claim either
    -- way; say what is missing and what it would take.
    say('! external reachability unknown - no master server configured to test it')
    Diagnostics.holePunchLines(facts, say)

    if private then
        say(('  %s is a private address, so you are behind NAT'):format(facts.address))
        say(('  for players outside your LAN, forward UDP %s to this machine, '
             .. 'or use a dedicated server'):format(tostring(port)))
    elseif facts.address then
        say(('  %s looks publicly routable; outside players should be able to connect')
            :format(facts.address))
    else
        say(('  if outside players cannot connect, forward UDP %s to this machine')
            :format(tostring(port)))
    end

    return { reach = facts.lan and 'lan' or 'unknown', lines = lines, forwardPort = port }
end

function Diagnostics.addressText(facts)
    if facts.address then
        return ('%s:%s'):format(facts.address, tostring(facts.port))
    end
    return ('<this machine>:%s'):format(tostring(facts.port))
end

-- Hole punching is a phase 6 item. When it lands it reports through here, which
-- is why the shapes of its outcomes are already spelled out: a diagnostic added
-- after the fact is a diagnostic nobody reads.
function Diagnostics.holePunchLines(facts, say)
    if facts.holePunch == 'ok' then
        say('  hole punch succeeded')
    elseif facts.holePunch == 'failed' then
        say(('  hole punch attempted, failed%s')
            :format(facts.holePunchNote and (' (' .. facts.holePunchNote .. ')') or ''))
    elseif facts.holePunch == 'unsupported' then
        say('  hole punching needs a master server; none is configured')
    end
end

-- Formats a report for a log function. Every line is prefixed so networking
-- output is greppable in a server log that also contains gameplay noise.
function Diagnostics.format(report)
    local out = {}
    for i, line in ipairs(report.lines or {}) do
        out[i] = ('%s %s'):format(Diagnostics.PREFIX, line)
    end
    return out
end

function Diagnostics.print(report, log)
    log = log or print
    for _, line in ipairs(Diagnostics.format(report)) do log(line) end
    return report
end

return Diagnostics
