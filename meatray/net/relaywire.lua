--[[
    meatray.net.relaywire — the frame format a relayed session speaks.

    Two things need to agree on this: the relay (masterserver/relay.lua) and the
    transport that talks to it (meatray/net/transport/relay.lua). They live on
    opposite sides of the repository and in different processes, so the format
    lives in one file that neither of them owns and both of them require. A wire
    format defined twice is a wire format that disagrees with itself the first
    time somebody adds a field.

    ## One byte in front of every frame, and that byte is the whole header

    A relayed session is ENet on both hops — host to relay, relay to client — so
    ordering, fragmentation, congestion control and connection management are
    already solved and are not re-solved here. Two things the relay needs are not
    carried by an ENet payload: *which of the host's peers this belongs to*, and
    *whether it was sent reliably*. One byte says both:

        0x00            control frame; the rest of the frame is a text line
        0x01 .. 0x7E    reliable data for slot 0 .. 125
        0x7F            reliable broadcast, to every bound slot
        0x80 .. 0xFD    unreliable data for slot 0 .. 125
        0xFE            unreliable broadcast
        0xFF            reserved

    The reliability bit is not decoration. lua-enet's receive event says which
    *channel* a packet arrived on but not which flag it was sent with, so a relay
    that did not carry the bit would have to guess — and guessing wrong in the
    cheap direction turns the snapshot stream reliable, which is precisely the
    failure the whole snapshot codec exists to avoid (docs/NETWORKING.md
    measured it: 85 bytes of snapshot was the difference between losing a fifth
    of the stream and stalling in bursts). Guessing wrong in the other direction
    silently drops joins and chat. The channel *number* needs no header at all,
    because ENet reports it on delivery.

    One byte rather than a session id and a token on every packet, because the
    hot path is a 20 Hz snapshot stream and the engine's snapshot budget has
    seven bytes of slack in it. `P.MTU_SAFE_BYTES` is 1364; the largest datagram
    ENet was actually observed to emit on this build was 1400, giving a real
    single-datagram payload budget of 1372 (see docs/NETWORKING.md, which
    measured it). 1364 + 1 = 1365, so **a relayed snapshot at the engine's own
    cap still fits in one datagram** and does not trip the unreliable-fragment
    promotion. Two bytes would still fit. Eight would not, and a per-packet
    session token would not come close.

    Authorisation is therefore *not* in the frame. It is in the connection: a
    link is bound to a session once, over a control frame, and every data frame
    afterwards is trusted exactly as far as the connection it arrived on. That is
    the same reasoning as the registry's — the address a request came from is
    worth more than any address inside it — applied one layer down.

    ## Control lines

    Text, space separated, because that is what the rest of this subsystem
    already does (`meatray-challenge <nonce>`, `meatray-punch-waiting`) and
    because `curl`-grade debuggability was the reason the registry is HTTP and
    not a custom binary protocol. Ids and secrets are hex, validated as hex, so
    a control line cannot be injected through one.

        host -> relay   open <version> [<allocation secret>]
        relay -> host   opened <session> <secret> <maxSlots>
        client -> relay join <version> <session> <secret>
        relay -> client joined <session> <slot>
        relay -> both   refused <reason>
        relay -> host   peer <slot> <address>
        relay -> host   gone <slot> <reason>
        relay -> host   rtt <slot> <milliseconds>
        relay -> client rtt 0 <milliseconds>
        host -> relay   drop <slot> <reason>
        client -> relay leave
        both            ping / pong

    HEADLESS: no love, no socket, no clock. Runs under plain LuaJIT.
]]

local Wire = {}

-- Bumped only for a change that an old peer would misread. The relay refuses a
-- version it does not speak, with a reason, rather than half-understanding it.
Wire.VERSION = 1

Wire.HEADER_BYTES = 1

Wire.CONTROL = 0x00

-- Reliable data is 0x01 + slot; unreliable data is 0x80 + slot. Each range ends
-- in its own broadcast marker.
Wire.RELIABLE_BASE        = 0x01
Wire.RELIABLE_BROADCAST   = 0x7F
Wire.UNRELIABLE_BASE      = 0x80
Wire.UNRELIABLE_BROADCAST = 0xFE

-- 126 concurrent clients on one relayed host: fifteen times the relay's own
-- default slot cap and four times the engine's default maxPeers, so the header
-- byte is not the limit anything reaches first.
Wire.MAX_SLOT = 125

-- A control line is a handful of tokens. Capped so a peer cannot make the relay
-- hold a megabyte of text by calling it a control frame.
Wire.MAX_CONTROL = 512

---------------------------------------------------------------------------
-- Framing
---------------------------------------------------------------------------

-- `reliable` defaults to true, matching the transport interface, where only the
-- snapshot stream ever asks for the other thing.
function Wire.data(slot, payload, reliable)
    if type(slot) ~= 'number' or slot ~= math.floor(slot)
       or slot < 0 or slot > Wire.MAX_SLOT then
        return nil, ('slot must be 0..%d'):format(Wire.MAX_SLOT)
    end

    local base = (reliable == false) and Wire.UNRELIABLE_BASE or Wire.RELIABLE_BASE
    return string.char(base + slot) .. (payload or '')
end

function Wire.broadcast(payload, reliable)
    local head = (reliable == false) and Wire.UNRELIABLE_BROADCAST
                                     or Wire.RELIABLE_BROADCAST
    return string.char(head) .. (payload or '')
end

function Wire.control(text)
    text = tostring(text or '')
    if #text > Wire.MAX_CONTROL then text = text:sub(1, Wire.MAX_CONTROL) end
    return string.char(Wire.CONTROL) .. text
end

-- Returns kind plus three values, or nil plus a reason:
--
--     'control',   text, nil,     true
--     'data',      slot, payload, reliable
--     'broadcast', nil,  payload, reliable
--
-- An empty frame is a parse failure and never a control frame with an empty
-- line, because "the sender sent nothing" and "the sender said nothing" are
-- different events and only one of them is worth answering.
--
-- A control frame is always reliable. There is no such thing as a best-effort
-- "you have been dropped".
function Wire.parse(frame)
    if type(frame) ~= 'string' or #frame < 1 then return nil, 'empty frame' end

    local head = frame:byte(1)
    local body = frame:sub(2)

    if head == Wire.CONTROL then return 'control', body, nil, true end

    if head == Wire.RELIABLE_BROADCAST   then return 'broadcast', nil, body, true end
    if head == Wire.UNRELIABLE_BROADCAST then return 'broadcast', nil, body, false end

    if head < Wire.RELIABLE_BROADCAST then
        return 'data', head - Wire.RELIABLE_BASE, body, true
    end

    if head < Wire.UNRELIABLE_BROADCAST then
        return 'data', head - Wire.UNRELIABLE_BASE, body, false
    end

    -- 0xFF, reserved. Rejected rather than treated as the nearest thing, so a
    -- later version that means something by it cannot be half-understood by an
    -- older relay.
    return nil, 'reserved frame type'
end

---------------------------------------------------------------------------
-- Control lines
---------------------------------------------------------------------------

-- Splits a control line into at most `n` fields. The last field is the rest of
-- the line, spaces and all, so a human-readable reason can travel as the tail of
-- a message whose earlier fields are still positional. Splitting on every space
-- would turn "relay session is full" into four fields and a reader into a
-- table.concat.
function Wire.words(text, n)
    n = n or 8
    local out = {}
    local rest = tostring(text or '')

    while #out < n - 1 do
        local word, tail = rest:match('^(%S+)%s+(.*)$')
        if not word then break end
        out[#out + 1] = word
        rest = tail
    end

    if rest ~= '' then out[#out + 1] = rest end
    return out
end

-- Ids and secrets are hex and nothing else. Checked rather than trusted: these
-- values are pasted back into control lines, and a "session id" containing a
-- space would forge a second field in a message the relay wrote itself.
function Wire.isHex(value, minimum, maximum)
    if type(value) ~= 'string' then return false end
    if #value < (minimum or 1) then return false end
    if maximum and #value > maximum then return false end
    return value:match('^%x+$') ~= nil
end

-- A reason travels as the tail of a control line, so it must not contain a
-- newline or a control character -- and it must not be empty, because an empty
-- reason arrives as no field at all and the reader sees `nil`.
function Wire.reason(text)
    local out = tostring(text or ''):gsub('%c', ' ')
    if #out > 160 then out = out:sub(1, 160) end
    if out:match('^%s*$') then out = 'no reason given' end
    return out
end

---------------------------------------------------------------------------
-- Tickets
---------------------------------------------------------------------------

-- Everything a client needs to join a relayed host, in one string it can be
-- given by a registry listing, a chat message, or a command line:
--
--     relay://198.51.100.20:6790/3f2a19c4/8b1d...e0
--
-- The secret is in it, and that is deliberate: it is a capability, not an
-- identity. Whoever holds the ticket may occupy a slot on that session, and the
-- host's own access control (password, ban list, onAuthenticate) is what decides
-- whether they may play. Splitting those two would mean the relay needed to know
-- about the game's accounts, which is exactly the coupling the registry avoided.
function Wire.formatTicket(ticket)
    if type(ticket) ~= 'table' then return nil, 'a ticket is a table' end
    if type(ticket.address) ~= 'string' or ticket.address == '' then
        return nil, 'a ticket needs the relay address'
    end
    if not Wire.isHex(ticket.session) then return nil, 'a ticket needs a session id' end
    if not Wire.isHex(ticket.secret)  then return nil, 'a ticket needs a secret' end

    return ('relay://%s/%s/%s'):format(ticket.address, ticket.session, ticket.secret)
end

function Wire.parseTicket(text)
    if type(text) ~= 'string' then return nil, 'a ticket is a string' end

    local body = text:match('^relay://(.+)$')
    if not body then return nil, 'a relay ticket starts with relay://' end

    -- Greedy on the address so an IPv6 literal's colons and a bracketed form
    -- both survive; the last two slash-separated fields are the hex ones.
    local address, session, secret = body:match('^(.+)/(%x+)/(%x+)$')
    if not address then return nil, 'a relay ticket is relay://host:port/session/secret' end
    if address == '' then return nil, 'a relay ticket needs the relay address' end

    return { address = address, session = session, secret = secret }
end

return Wire
