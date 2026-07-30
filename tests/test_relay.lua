--[[
    The relay: the frame format, and every rule that decides whether a byte gets
    forwarded.

    None of these tests opens a port, and that is the reason the logic is a pure
    module. The cases worth testing are "a session nobody spoke on for two
    minutes", "a stranger guessing session ids", "a host that just went over its
    byte budget" and "one session's traffic must never reach another", and every
    one of them would need a running relay and a stopwatch otherwise.

    Read the cross-session and open-proxy sections first. They are the difference
    between a relay and an amplifier, which is the same distinction the registry
    tests draw between a server browser and a DDoS reflector.
]]

return function(t)
    local Wire  = require('meatray.net.relaywire')
    local Relay = require('masterserver.relay')
    local P     = require('meatray.net.protocol')

    -- Deterministic "randomness" so ids and secrets are reproducible. A real
    -- deployment injects something better; these rules only need the values to
    -- be unguessable in production, not in a test.
    local function fixedRandom(seed)
        local n = seed or 12345
        return function()
            n = (n * 1103515245 + 12345) % 2147483648
            return (n % 4093) / 4093
        end
    end

    local function newRelay(opts)
        opts = opts or {}
        opts.randomSource = opts.randomSource or fixedRandom(opts.seed)
        return Relay.new(opts)
    end

    -- Opens a session for `address` and returns the relay, the id and the secret.
    local function opened(r, key, address)
        assert(r:link(key, address))
        local actions = r:receive(key, Wire.control('open ' .. Wire.VERSION))
        local text = actions[1] and actions[1].data and actions[1].data:sub(2) or ''
        local id, secret = text:match('^opened (%x+) (%x+)')
        return id, secret
    end

    local function join(r, key, address, id, secret)
        assert(r:link(key, address))
        return r:receive(key, Wire.control(('join %d %s %s'):format(Wire.VERSION, id, secret)))
    end

    -- The control line an action carries, or nil when it is not a control frame.
    local function controlOf(action)
        if not action or not action.data then return nil end
        local kind, text = Wire.parse(action.data)
        if kind ~= 'control' then return nil end
        return text
    end

    local function findControl(actions, to, prefix)
        for _, action in ipairs(actions) do
            if action.to == to then
                local text = controlOf(action)
                if text and text:sub(1, #prefix) == prefix then return text end
            end
        end
        return nil
    end

    local function countTo(actions, to)
        local n = 0
        for _, action in ipairs(actions) do
            if action.to == to then n = n + 1 end
        end
        return n
    end

    -----------------------------------------------------------------------
    t.describe('the header is one byte and carries both things it must')

    -- One byte, because the hot path is a 20 Hz snapshot stream sized to the
    -- byte. If this ever grows, a relayed snapshot at the engine's own cap stops
    -- fitting in one datagram and the unreliable stream silently turns reliable
    -- -- the failure the whole snapshot codec exists to prevent.
    t.eq(Wire.HEADER_BYTES, 1, 'the relay header is one byte')
    t.eq(#Wire.data(0, '', true), 1, 'an empty reliable data frame is one byte')
    t.eq(#Wire.data(5, 'abcd', false), 5, 'a data frame is the payload plus one')
    t.eq(#Wire.control('ping'), 5, 'a control frame is the line plus one')
    t.eq(#Wire.broadcast('abcd', true), 5, 'a broadcast frame is the payload plus one')

    -- The arithmetic that says the byte is affordable. 1372 is the real
    -- single-datagram payload budget measured on this build (docs/NETWORKING.md);
    -- 1364 is what the codec targets.
    t.ok(P.MTU_SAFE_BYTES + Wire.HEADER_BYTES <= 1372,
         'a relayed snapshot at the engine cap still fits one datagram',
         ('%d + %d'):format(P.MTU_SAFE_BYTES, Wire.HEADER_BYTES))

    local kind, slot, payload, reliable = Wire.parse(Wire.data(7, 'body', true))
    t.eq(kind, 'data', 'a data frame parses as data')
    t.eq(slot, 7, 'the slot survives')
    t.eq(payload, 'body', 'the payload survives')
    t.eq(reliable, true, 'and so does reliable')

    kind, slot, payload, reliable = Wire.parse(Wire.data(7, 'body', false))
    t.eq(slot, 7, 'an unreliable frame keeps its slot')
    t.eq(reliable, false, 'and is marked unreliable')

    -- lua-enet's receive event does not report the flag a packet was sent with,
    -- so the relay cannot recover this by asking. If the bit were not in the
    -- frame the relay would have to guess, and guessing "reliable" for the
    -- snapshot stream is exactly the promotion that costs a fifth of it.
    t.ok(Wire.data(0, 'x', true) ~= Wire.data(0, 'x', false),
         'reliable and unreliable frames are distinguishable on the wire')

    kind, slot, payload, reliable = Wire.parse(Wire.broadcast('all', false))
    t.eq(kind, 'broadcast', 'a broadcast frame parses as broadcast')
    t.eq(payload, 'all', 'with its payload')
    t.eq(reliable, false, 'and its reliability')

    kind, payload = Wire.parse(Wire.control('open 1'))
    t.eq(kind, 'control', 'a control frame parses as control')
    t.eq(payload, 'open 1', 'with its line')

    t.eq(Wire.parse(''), nil, 'an empty frame is a parse failure, not empty control')
    t.eq(Wire.parse(nil), nil, 'and so is a non-string')
    t.eq(Wire.parse(string.char(0xFF)), nil,
         '0xFF is reserved and refused rather than treated as the nearest thing')

    t.eq(Wire.data(-1, 'x'), nil, 'a negative slot is refused')
    t.eq(Wire.data(Wire.MAX_SLOT + 1, 'x'), nil, 'a slot past the end is refused')
    t.ok(Wire.data(Wire.MAX_SLOT, 'x') ~= nil, 'the last slot is usable')

    -- Every slot in range must round-trip in both reliabilities. An off-by-one
    -- in the range split would send one player's traffic to another.
    local roundTripped = true
    for i = 0, Wire.MAX_SLOT do
        for _, flag in ipairs({ true, false }) do
            local k, s, _, r = Wire.parse(Wire.data(i, 'x', flag))
            if k ~= 'data' or s ~= i or r ~= flag then roundTripped = false end
        end
    end
    t.ok(roundTripped, 'every slot round-trips in both reliabilities')

    -----------------------------------------------------------------------
    t.describe('control lines keep a reason whole')

    local words = Wire.words('gone 3 the host closed the session', 3)
    t.eq(words[1], 'gone', 'the verb splits off')
    t.eq(words[2], '3', 'and so does the slot')
    t.eq(words[3], 'the host closed the session',
         'and the reason survives its own spaces')

    t.eq(#Wire.words('leave', 3), 1, 'a bare verb is one field')
    t.eq(Wire.words('ping', 2)[1], 'ping', 'and it is the verb')

    t.eq(Wire.isHex('deadbeef'), true, 'hex is hex')
    t.eq(Wire.isHex('dead beef'), false, 'a space is not')
    t.eq(Wire.isHex('deadbeeg'), false, 'nor is g')
    t.eq(Wire.isHex(''), false, 'nor is nothing')
    t.eq(Wire.isHex(nil), false, 'nor is nil')

    t.eq(Wire.reason('a\nb'), 'a b', 'a newline in a reason becomes a space')
    t.eq(Wire.reason(''), 'no reason given', 'an empty reason is still a reason')

    -----------------------------------------------------------------------
    t.describe('a ticket is a capability, and it round-trips')

    local ticket = Wire.formatTicket{
        address = '198.51.100.20:6790', session = 'cafe1234', secret = 'deadbeef',
    }
    t.eq(ticket, 'relay://198.51.100.20:6790/cafe1234/deadbeef', 'a ticket formats')

    local parsed = Wire.parseTicket(ticket)
    t.eq(parsed.address, '198.51.100.20:6790', 'the address comes back')
    t.eq(parsed.session, 'cafe1234', 'the session comes back')
    t.eq(parsed.secret, 'deadbeef', 'the secret comes back')

    -- An IPv6 relay address has colons and the parser must not confuse them with
    -- the separator. Greedy on the address, hex on the two fields after it.
    local v6 = Wire.parseTicket('relay://[2001:db8::1]:6790/aa11/bb22')
    t.eq(v6 and v6.address, '[2001:db8::1]:6790', 'a bracketed IPv6 relay survives')
    t.eq(v6 and v6.session, 'aa11', 'and the session after it')

    t.eq(Wire.parseTicket('198.51.100.20:6790'), nil, 'a bare address is not a ticket')
    t.eq(Wire.parseTicket('relay://'), nil, 'an empty ticket is refused')
    t.eq(Wire.parseTicket('relay://host/zz/yy'), nil, 'non-hex fields are refused')
    t.eq(Wire.parseTicket(nil), nil, 'nil is refused')
    t.eq(Wire.formatTicket{ session = 'aa', secret = 'bb' }, nil,
         'a ticket without an address is refused')

    -----------------------------------------------------------------------
    t.describe('allocation: a host asks, and the relay decides')

    local r = newRelay()
    local id, secret = opened(r, 'H1', '198.51.100.1')
    t.ok(Wire.isHex(id), 'a session id comes back, and it is hex')
    t.ok(Wire.isHex(secret), 'so does a secret')
    t.eq(#secret, 32, 'and the secret is sixteen bytes of it')
    t.eq(r:sessionCount(), 1, 'one session exists')
    t.eq(r.stats.opened, 1, 'and it is counted')

    -- The whole reason this is not a hole punch: nothing about this session is
    -- reachable except through connections the relay itself accepted.
    t.eq(r:slotCount(id), 0, 'a fresh session has nobody in it')

    -- A second open on the same connection is refused rather than leaking the
    -- first. One connection, one role, for the life of it.
    local twice = r:receive('H1', Wire.control('open ' .. Wire.VERSION))
    t.ok(findControl(twice, 'H1', 'refused') ~= nil, 'a link cannot open two sessions')
    t.eq(r:sessionCount(), 1, 'and no second session appeared')

    -- Version. Refused with a reason rather than half-understood.
    assert(r:link('HV', '198.51.100.2'))
    local badVersion = r:receive('HV', Wire.control('open 99'))
    t.ok(findControl(badVersion, 'HV', 'refused this relay speaks') ~= nil,
         'a version this relay does not speak is refused, with the version it does')

    -----------------------------------------------------------------------
    t.describe('one machine cannot take the whole relay')

    -- Per-address before global, exactly as the registry does it: the abuse that
    -- matters is one machine filling the relay, not the total getting large.
    local caps = newRelay{ maxPerAddress = 2, maxSessions = 3 }
    t.ok(opened(caps, 'a1', '203.0.113.1') ~= nil, 'the first session from an address')
    t.ok(opened(caps, 'a2', '203.0.113.1') ~= nil, 'the second')
    t.eq(opened(caps, 'a3', '203.0.113.1'), nil, 'the third is refused')
    t.eq(caps:sessionCount(), 2, 'and was never created')

    local refusal = caps:receive('a3', Wire.control('open ' .. Wire.VERSION))
    t.ok(findControl(refusal, 'a3', 'refused too many relay sessions') ~= nil,
         'and the host is told which limit it hit')

    -- A different address still gets in, up to the global cap.
    t.ok(opened(caps, 'b1', '203.0.113.2') ~= nil, 'another address may still open one')
    t.eq(caps:sessionCount(), 3, 'now at the global cap')
    t.eq(opened(caps, 'c1', '203.0.113.3'), nil, 'and the next is refused')

    -- Freeing an address's session frees its allowance. Otherwise a host that
    -- restarts twice is locked out of its own relay.
    caps:unlink('a1')
    t.eq(caps:sessionCount(), 2, 'a departed host frees its session')
    t.ok(opened(caps, 'a4', '203.0.113.1') ~= nil, 'and its address may open another')

    -- Connections themselves are capped, before any session exists.
    local links = newRelay{ maxLinks = 2 }
    t.ok(links:link('L1', '10.0.0.1'), 'the first link')
    t.ok(links:link('L2', '10.0.0.2'), 'the second')
    t.eq(links:link('L3', '10.0.0.3'), nil, 'the third is refused')
    t.eq(links:link('L1', '10.0.0.1'), nil, 'and a duplicate key is refused')

    -----------------------------------------------------------------------
    t.describe('a private relay')

    -- One config string is the whole answer to "I want a relay for my community
    -- and not for the internet".
    local private = newRelay{ allocationSecret = 'shibboleth' }
    assert(private:link('P1', '198.51.100.9'))
    local noSecret = private:receive('P1', Wire.control('open ' .. Wire.VERSION))
    t.ok(findControl(noSecret, 'P1', 'refused this relay is private') ~= nil,
         'a host with no secret is refused')
    t.eq(private:sessionCount(), 0, 'and nothing was allocated')

    assert(private:link('P2', '198.51.100.10'))
    local wrongSecret = private:receive('P2',
        Wire.control('open ' .. Wire.VERSION .. ' wrong'))
    t.ok(findControl(wrongSecret, 'P2', 'refused this relay is private') ~= nil,
         'and so is one with the wrong secret')

    assert(private:link('P3', '198.51.100.11'))
    local rightSecret = private:receive('P3',
        Wire.control('open ' .. Wire.VERSION .. ' shibboleth'))
    t.ok(findControl(rightSecret, 'P3', 'opened') ~= nil, 'the right secret opens one')

    -----------------------------------------------------------------------
    t.describe('authorisation: a stranger cannot get into a session')

    local auth = newRelay{ seed = 777 }
    local sid, ssecret = opened(auth, 'AH', '198.51.100.20')

    local good = join(auth, 'AC', '203.0.113.20', sid, ssecret)
    t.ok(findControl(good, 'AC', 'joined') ~= nil, 'the right ticket joins')
    t.eq(auth:slotCount(sid), 1, 'and occupies a slot')

    -- The host is told the CLIENT's address, not the relay's. Get this wrong and
    -- one ban removes everybody on the relay.
    t.eq(findControl(good, 'AH', 'peer'), 'peer 0 203.0.113.20',
         'the host is told the real client address, not the relay address')

    -- One string for a wrong id and for a wrong secret, deliberately. Two would
    -- make the relay an oracle: sweep the id space cheaply, then start on the
    -- 128-bit secret.
    assert(auth:link('BADID', '203.0.113.21'))
    local badId = auth:receive('BADID',
        Wire.control(('join %d 00000000 %s'):format(Wire.VERSION, ssecret)))

    assert(auth:link('BADSEC', '203.0.113.22'))
    local badSecret = auth:receive('BADSEC',
        Wire.control(('join %d %s 00000000000000000000000000000000')
                     :format(Wire.VERSION, sid)))

    t.eq(findControl(badId, 'BADID', 'refused'), 'refused ' .. Relay.NO_SESSION,
         'a wrong session id is refused')
    t.eq(findControl(badSecret, 'BADSEC', 'refused'), 'refused ' .. Relay.NO_SESSION,
         'a wrong secret is refused with exactly the same words')

    -- Guessing costs a connection. Three tries and the link goes.
    local brute = newRelay{ maxJoinAttempts = 3 }
    local bid = opened(brute, 'BH', '198.51.100.30')
    assert(brute:link('BRUTE', '203.0.113.30'))
    local closed = false
    for _ = 1, 4 do
        local acts = brute:receive('BRUTE',
            Wire.control(('join %d %s 0000'):format(Wire.VERSION, bid)))
        for _, action in ipairs(acts) do
            if action.close == 'BRUTE' then closed = true end
        end
    end
    t.ok(closed, 'a link that keeps guessing is closed')
    t.eq(brute.links['BRUTE'], nil, 'and is gone from the relay')

    -- A full session refuses rather than evicting.
    local small = newRelay{ maxSlots = 1 }
    local smallId, smallSecret = opened(small, 'SH', '198.51.100.40')
    join(small, 'S1', '203.0.113.40', smallId, smallSecret)
    local full = join(small, 'S2', '203.0.113.41', smallId, smallSecret)
    t.ok(findControl(full, 'S2', 'refused this relay session is full') ~= nil,
         'a full session refuses the next client')
    t.eq(small:slotCount(smallId), 1, 'and keeps the one it had')

    -----------------------------------------------------------------------
    t.describe('a link with no session may not send a byte')

    -- Silence, not an error. An error reply would make the relay a small
    -- reflector for anything that can complete a handshake with it, and would
    -- confirm to a prober that its guess reached a live relay.
    local quiet = newRelay()
    assert(quiet:link('LURKER', '203.0.113.50'))
    local sneak = quiet:receive('LURKER', Wire.data(0, 'payload', true))
    t.eq(#sneak, 0, 'data from an unbound link produces no action at all')
    t.eq(quiet.stats.dropped, 1, 'and is counted as dropped')

    local sneakBroadcast = quiet:receive('LURKER', Wire.broadcast('payload', true))
    t.eq(#sneakBroadcast, 0, 'and neither does a broadcast from one')

    -- An unknown control verb is also answered with nothing, so the relay cannot
    -- be used to probe for which verbs exist.
    local unknown = quiet:receive('LURKER', Wire.control('teapot please'))
    t.eq(#unknown, 0, 'an unknown control verb gets no answer')

    -- A frame from a key the relay has never heard of closes rather than
    -- forwards. That is a bug in the binding, not a peer being clever.
    local ghost = quiet:receive('NO-SUCH-LINK', Wire.data(0, 'x', true))
    t.eq(ghost[1] and ghost[1].close, 'NO-SUCH-LINK', 'an unknown link is closed')

    -- Oversized frames never reach the session table.
    local big = newRelay{ maxFrameBytes = 64 }
    local bigId, bigSecret = opened(big, 'GH', '198.51.100.60')
    join(big, 'GC', '203.0.113.60', bigId, bigSecret)
    local before = big.stats.forwarded
    local huge = big:receive('GC', Wire.data(0, string.rep('x', 128), true))
    t.eq(#huge, 0, 'an oversized frame is dropped')
    t.eq(big.stats.forwarded, before, 'and forwarded nothing')

    -----------------------------------------------------------------------
    t.describe('this is not an open proxy')

    -- The property, stated as a test: every destination comes out of the session
    -- table, and the session table only ever holds links the relay accepted. No
    -- field of any frame names a destination, so there is no input that makes
    -- the relay send a packet to an address of the sender's choosing.
    local proxy = newRelay{ seed = 4242 }
    local pid, psecret = opened(proxy, 'PH', '198.51.100.70')
    join(proxy, 'PC', '203.0.113.70', pid, psecret)

    local fromClient = proxy:receive('PC', Wire.data(0, 'up', true))
    t.eq(#fromClient, 1, 'a client frame produces exactly one forward')
    t.eq(fromClient[1].to, 'PH', 'and its only destination is its own host')

    -- A client naming a slot other than its own is trying to address a peer it
    -- has no business addressing. Dropped rather than remapped, because
    -- remapping would be indistinguishable from working.
    local wrongSlot = proxy:receive('PC', Wire.data(3, 'sideways', true))
    t.eq(#wrongSlot, 0, 'a client naming another slot is dropped')

    -- And a client cannot broadcast at all: that would be one client reaching
    -- every other client on the session.
    local clientBroadcast = proxy:receive('PC', Wire.broadcast('everyone', true))
    t.eq(#clientBroadcast, 0, 'a client cannot broadcast')

    -- A host frame naming a slot nobody occupies goes nowhere.
    local emptySlot = proxy:receive('PH', Wire.data(5, 'nobody', true))
    t.eq(#emptySlot, 0, 'a host frame for an empty slot goes nowhere')

    -----------------------------------------------------------------------
    t.describe('two sessions never touch')

    -- The failure this prevents is the worst one available: one game's traffic
    -- arriving in another game. It cannot happen by construction -- a link knows
    -- its session and a session knows its links -- and it is asserted anyway,
    -- because "by construction" is a claim about code that changes.
    local two = newRelay{ seed = 31337 }
    local idA, secretA = opened(two, 'HA', '198.51.100.80')
    local idB, secretB = opened(two, 'HB', '198.51.100.81')
    t.ok(idA ~= idB, 'two sessions get different ids')

    join(two, 'CA', '203.0.113.80', idA, secretA)
    join(two, 'CB', '203.0.113.81', idB, secretB)

    local aTraffic = two:receive('CA', Wire.data(0, 'for A', true))
    t.eq(countTo(aTraffic, 'HA'), 1, "A's client reaches A's host")
    t.eq(countTo(aTraffic, 'HB'), 0, "and never reaches B's host")
    t.eq(countTo(aTraffic, 'CB'), 0, "nor B's client")

    -- A's host broadcasting reaches only A's client, even though both sessions
    -- have a slot 0.
    local aBroadcast = two:receive('HA', Wire.broadcast('to mine', false))
    t.eq(countTo(aBroadcast, 'CA'), 1, "A's broadcast reaches A's client")
    t.eq(countTo(aBroadcast, 'CB'), 0, "and not B's, though both are slot 0")

    -- B's secret does not open A's session.
    assert(two:link('CX', '203.0.113.82'))
    local crossed = two:receive('CX',
        Wire.control(('join %d %s %s'):format(Wire.VERSION, idA, secretB)))
    t.eq(findControl(crossed, 'CX', 'refused'), 'refused ' .. Relay.NO_SESSION,
         "one session's secret does not open another")

    -----------------------------------------------------------------------
    t.describe('forwarding preserves what the sender chose')

    local fwd = newRelay{ seed = 55 }
    local fid, fsecret = opened(fwd, 'FH', '198.51.100.90')
    join(fwd, 'FC', '203.0.113.90', fid, fsecret)

    -- Channel is passed through untouched: the relay has no opinion about what a
    -- channel means, and reading one would be the relay knowing about the game.
    local onChannel = fwd:receive('FC', Wire.data(0, 'chatty', true), P.CH_RELIABLE)
    t.eq(onChannel[1].channel, P.CH_RELIABLE, 'the channel survives the hop')
    t.eq(onChannel[1].reliable, true, 'and so does reliable')

    local stream = fwd:receive('FH', Wire.data(0, 'snapshot', false), P.CH_STREAM)
    t.eq(stream[1].channel, P.CH_STREAM, 'the stream channel survives')
    t.eq(stream[1].reliable, false, 'and unreliable stays unreliable')

    -- A client always sees slot 0 on its own side; a host sees the real slot.
    local downKind, downSlot, downPayload = Wire.parse(stream[1].data)
    t.eq(downKind, 'data', 'the forwarded frame is data')
    t.eq(downSlot, 0, 'a client is always told slot 0 -- it has one peer')
    t.eq(downPayload, 'snapshot', 'and the payload is untouched')

    local upKind, upSlot, upPayload = Wire.parse(onChannel[1].data)
    t.eq(upKind, 'data', 'and so is the upstream one')
    t.eq(upSlot, 0, 'tagged with the slot the client occupies')
    t.eq(upPayload, 'chatty', 'payload untouched')

    -- Bytes are neither added nor lost. A relay that reshaped payloads would be
    -- a relay that could break a codec it has never heard of.
    local exact = ('\0\255\1binary\n\r payload')
    local through = fwd:receive('FC', Wire.data(0, exact, true))
    local _, _, got = Wire.parse(through[1].data)
    t.eq(got, exact, 'a payload with nulls and newlines survives byte for byte')

    -----------------------------------------------------------------------
    t.describe('bandwidth is charged on what the relay emits')

    -- 4 KiB/s with a 4 KiB burst, so the arithmetic is small enough to state.
    local budget = newRelay{
        seed = 88, sessionBytesPerSec = 4096, sessionBurstBytes = 4096,
        totalBytesPerSec = 1e9, totalBurstBytes = 1e9,
    }
    local qid, qsecret = opened(budget, 'QH', '198.51.100.100')
    join(budget, 'QC', '203.0.113.100', qid, qsecret)

    local body = string.rep('x', 1023)     -- 1024 bytes on the wire with the header
    local forwarded = 0
    for _ = 1, 4 do
        if #budget:receive('QH', Wire.data(0, body, false)) > 0 then
            forwarded = forwarded + 1
        end
    end
    t.eq(forwarded, 4, 'four kilobytes fit inside a four-kilobyte burst')

    local fifth = budget:receive('QH', Wire.data(0, body, false))
    t.eq(#fifth, 0, 'the fifth unreliable frame is throttled')
    t.eq(budget.stats.throttled, 1, 'and counted as throttled, not dropped')

    -- A reliable frame is never thrown away for budget. Dropping one is a hole
    -- in a stream that neither peer can see or repair, because the sending hop
    -- already acknowledged it. It is forwarded and the debt is recorded instead.
    local reliableOverrun = budget:receive('QH', Wire.data(0, body, true))
    t.eq(#reliableOverrun, 1, 'a reliable frame over budget is still forwarded')
    t.eq(budget.stats.overruns, 1, 'and the overrun is recorded')

    -- The bucket refills.
    budget:advance(2)
    local afterRefill = budget:receive('QH', Wire.data(0, body, false))
    t.eq(#afterRefill, 1, 'two seconds of refill lets unreliable traffic through again')

    -- Broadcast is the only place in the relay where one frame in is N frames
    -- out, so it is charged at N times its size. Otherwise the budget would be a
    -- budget on ingress and the relay would be an amplifier with a quota.
    local fan = newRelay{
        seed = 99, maxSlots = 4,
        sessionBytesPerSec = 1, sessionBurstBytes = 4096,
        totalBytesPerSec = 1e9, totalBurstBytes = 1e9,
    }
    local nid, nsecret = opened(fan, 'NH', '198.51.100.110')
    for i = 1, 4 do
        join(fan, 'NC' .. i, '203.0.113.11' .. i, nid, nsecret)
    end
    t.eq(fan:slotCount(nid), 4, 'four clients on one session')

    local before4 = fan:get(nid).bucket.tokens
    local fanout = fan:receive('NH', Wire.broadcast(string.rep('y', 99), true))
    t.eq(#fanout, 4, 'a broadcast produces one frame per bound slot')
    t.near(before4 - fan:get(nid).bucket.tokens, 400, 1e-6,
           'and is charged at four times its hundred bytes')

    -- Past the overrun limit the session is closed rather than run at a
    -- permanent deficit the operator is paying for.
    local ruin = newRelay{
        seed = 4, overrunLimit = 3,
        sessionBytesPerSec = 0, sessionBurstBytes = 0,
        totalBytesPerSec = 1e9, totalBurstBytes = 1e9,
    }
    local rid, rsecret = opened(ruin, 'RH', '198.51.100.120')
    join(ruin, 'RC', '203.0.113.120', rid, rsecret)
    for _ = 1, 5 do ruin:receive('RH', Wire.data(0, 'x', true)) end

    local closedActions = ruin:update(1)
    t.ok(findControl(closedActions, 'RH', 'closed over its relay bandwidth budget') ~= nil,
         'a session permanently over budget is closed, with a reason')
    t.eq(ruin:sessionCount(), 0, 'and freed')
    t.eq(ruin.stats.closedQuota, 1, 'and counted separately from a timeout')

    -- The relay-wide budget binds too, independently of any session's.
    local global = newRelay{
        seed = 5, sessionBytesPerSec = 1e9, sessionBurstBytes = 1e9,
        totalBytesPerSec = 1, totalBurstBytes = 100,
    }
    local gid, gsecret = opened(global, 'GH2', '198.51.100.130')
    join(global, 'GC2', '203.0.113.130', gid, gsecret)
    t.eq(#global:receive('GH2', Wire.data(0, string.rep('z', 99), false)), 1,
         'the first hundred bytes fit the relay-wide burst')
    t.eq(#global:receive('GH2', Wire.data(0, string.rep('z', 99), false)), 0,
         'the next is throttled by the relay-wide budget alone')

    -----------------------------------------------------------------------
    t.describe('the default budget is derived, not chosen')

    -- Stated as a test so the derivation cannot drift away from the engine it
    -- was derived from. 20 snapshots/s at the codec's cap plus 30 inputs/s of
    -- 80 bytes, per client, for eight clients.
    local perClient = 20 * (P.MTU_SAFE_BYTES + Wire.HEADER_BYTES) + 30 * 80
    local fullSession = perClient * Relay.MAX_SLOTS
    t.ok(Relay.SESSION_BYTES_PER_SEC >= fullSession,
         'the per-session budget covers a full session at every engine ceiling',
         ('%d vs %d'):format(Relay.SESSION_BYTES_PER_SEC, fullSession))
    t.ok(Relay.SESSION_BYTES_PER_SEC < fullSession * 2,
         'and is not so generous that it stops being a budget')
    t.ok(Relay.SESSION_BURST_BYTES >= Relay.SESSION_BYTES_PER_SEC,
         'the burst is at least a second of the rate')
    t.ok(Relay.TOTAL_BYTES_PER_SEC >= Relay.SESSION_BYTES_PER_SEC,
         'and the relay-wide budget is at least one session')

    -----------------------------------------------------------------------
    t.describe('nothing outlives its usefulness')

    -- A connection that arrived and never said what it wanted.
    local squat = newRelay{ linkTimeout = 10 }
    assert(squat:link('SQUAT', '203.0.113.140'))
    t.eq(#squat:update(5), 0, 'a fresh link is left alone')
    t.eq(squat:linkCount(), 1, 'and still there')

    local evicted = squat:update(11)
    t.ok(findControl(evicted, 'SQUAT', 'refused no session was opened') ~= nil,
         'a link that never opened a session is told why')
    local sawClose = false
    for _, action in ipairs(evicted) do
        if action.close == 'SQUAT' then sawClose = true end
    end
    t.ok(sawClose, 'and closed')
    t.eq(squat:linkCount(), 0, 'and gone')

    -- A bound link is never evicted by the link timeout, however quiet.
    local bound = newRelay{ linkTimeout = 10, sessionTimeout = 1000 }
    local bid2 = opened(bound, 'BH2', '198.51.100.150')
    bound:update(50)
    t.eq(bound:sessionCount(), 1, 'a session is not a squatter')
    t.ok(bound:get(bid2) ~= nil, 'and survives the link timeout')

    -- A session nobody spoke on. Generous, because the session a relay exists to
    -- hold open is often one sitting in a menu waiting for a friend.
    local stale = newRelay{ sessionTimeout = 120 }
    local staleId, staleSecret = opened(stale, 'TH', '198.51.100.160')
    join(stale, 'TC', '203.0.113.160', staleId, staleSecret)

    stale:update(119)
    t.eq(stale:sessionCount(), 1, 'still alive just before the timeout')

    local expired = stale:update(121)
    t.eq(stale:sessionCount(), 0, 'gone once it passes')
    t.eq(stale.stats.expired, 1, 'and counted')
    t.ok(findControl(expired, 'TH', 'closed relay session timed out') ~= nil,
         'the host is told why')
    t.ok(findControl(expired, 'TC', 'closed relay session timed out') ~= nil,
         'and so is the client -- a lobby that dies silently is worse')

    -- Traffic keeps it alive indefinitely.
    local kept = newRelay{ sessionTimeout = 100 }
    local keptId, keptSecret = opened(kept, 'KH', '198.51.100.170')
    join(kept, 'KC', '203.0.113.170', keptId, keptSecret)
    for step = 1, 10 do
        kept:update(step * 50)
        kept:receive('KH', Wire.control('ping'))
    end
    t.eq(kept:sessionCount(), 1, 'a keepalive holds a session open indefinitely')

    -----------------------------------------------------------------------
    t.describe('departures, in every direction')

    -- The host leaves. Its clients are told and dropped, because a lobby with
    -- nothing behind it looks alive and is not.
    local gone = newRelay{ seed = 61 }
    local gid2, gsecret2 = opened(gone, 'DH', '198.51.100.180')
    join(gone, 'DC1', '203.0.113.180', gid2, gsecret2)
    join(gone, 'DC2', '203.0.113.181', gid2, gsecret2)

    local hostLeft = gone:unlink('DH')
    t.ok(findControl(hostLeft, 'DC1', 'closed') ~= nil, 'the first client is told')
    t.ok(findControl(hostLeft, 'DC2', 'closed') ~= nil, 'and the second')
    t.eq(gone:sessionCount(), 0, 'the session is freed')
    t.eq(gone:linkCount(), 0, 'and every link with it')

    -- A client leaves: the host is told which slot, and nothing else changes.
    local one = newRelay{ seed = 62 }
    local oid, osecret = opened(one, 'OH', '198.51.100.190')
    join(one, 'OC1', '203.0.113.190', oid, osecret)
    join(one, 'OC2', '203.0.113.191', oid, osecret)
    t.eq(one:slotCount(oid), 2, 'two clients')

    local clientLeft = one:unlink('OC1')
    t.ok(findControl(clientLeft, 'OH', 'gone 0') ~= nil,
         'the host is told which slot left')
    t.eq(one:slotCount(oid), 1, 'and the other client is untouched')
    t.eq(one:sessionCount(), 1, 'and the session survives')

    -- The freed slot is reused, and the host is told about the new occupant.
    local reused = join(one, 'OC3', '203.0.113.192', oid, osecret)
    t.eq(findControl(reused, 'OH', 'peer'), 'peer 0 203.0.113.192',
         'the freed slot is handed to the next client')

    -- A polite leave and a dropped connection are the same event to the host.
    local polite = one:receive('OC2', Wire.control('leave'))
    t.ok(findControl(polite, 'OH', 'gone 1') ~= nil, 'a polite leave tells the host too')

    -- The host kicks. The client is told why before its connection goes, which
    -- is the difference between a kick and an unexplained drop.
    local kick = newRelay{ seed = 63 }
    local kid, ksecret = opened(kick, 'KH2', '198.51.100.200')
    join(kick, 'KC2', '203.0.113.200', kid, ksecret)

    local kicked = kick:receive('KH2', Wire.control('drop 0 you were flooding'))
    t.eq(findControl(kicked, 'KC2', 'closed'), 'closed you were flooding',
         'the kicked client is told the reason')
    local kickClosed = false
    for _, action in ipairs(kicked) do
        if action.close == 'KC2' then kickClosed = true end
    end
    t.ok(kickClosed, 'and then closed')
    t.eq(kick:slotCount(kid), 0, 'and the slot is free again')

    -- A client cannot kick. `drop` is a host verb and a client sending it is
    -- ignored, not obeyed.
    local usurp = newRelay{ seed = 64 }
    local uid, usecret = opened(usurp, 'UH', '198.51.100.210')
    join(usurp, 'UC1', '203.0.113.210', uid, usecret)
    join(usurp, 'UC2', '203.0.113.211', uid, usecret)
    local refused2 = usurp:receive('UC1', Wire.control('drop 1 get out'))
    t.eq(#refused2, 0, 'a client cannot drop another client')
    t.eq(usurp:slotCount(uid), 2, 'and both are still there')

    -- Unlinking something that is not there is a no-op rather than an error. A
    -- binding that reports a disconnect twice must not take the relay down.
    t.eq(#usurp:unlink('NOT-A-LINK'), 0, 'unlinking an unknown key does nothing')
    usurp:unlink('UC1')
    t.eq(#usurp:unlink('UC1'), 0, 'and unlinking twice does nothing the second time')

    -----------------------------------------------------------------------
    t.describe('round-trip time, which only the relay can measure')

    -- A relayed path is two hops and each end can only see its own. Lag
    -- compensation reads transport:rtt(); a host that reported only its hop to
    -- the relay would rewind by half the real latency and its players' shots
    -- would land behind their targets, which reads as bad aim rather than as a
    -- network fault.
    local rtt = newRelay{ seed = 71 }
    local rid2, rsecret2 = opened(rtt, 'XH', '198.51.100.220')
    join(rtt, 'XC', '203.0.113.220', rid2, rsecret2)

    local toHost = rtt:reportRtt('XC', 42)
    t.eq(findControl(toHost, 'XH', 'rtt'), 'rtt 0 42',
         "the client's hop is told to the host, tagged with its slot")

    local toClient = rtt:reportRtt('XH', 17)
    t.eq(findControl(toClient, 'XC', 'rtt'), 'rtt 0 17',
         "and the host's hop is told to every client")

    t.eq(#rtt:reportRtt('XC', -1), 0, 'a negative rtt is ignored')
    t.eq(#rtt:reportRtt('XC', 0 / 0), 0, 'and so is NaN')
    t.eq(#rtt:reportRtt('NOBODY', 5), 0, 'and an unknown link produces nothing')

    -----------------------------------------------------------------------
    t.describe('every entry point returns a list, never nil')

    -- The binding executes whatever comes back in a loop. One nil return and it
    -- raises on a request an attacker chose, which is a denial of service with a
    -- single packet -- the same trap masterserver/server.lua wraps in a pcall.
    local shapes = newRelay()
    local sid2 = opened(shapes, 'ZH', '198.51.100.230')
    local probes = {
        shapes:receive('ZH', ''),
        shapes:receive('ZH', nil),
        shapes:receive('ZH', string.char(0xFF)),
        shapes:receive('ZH', Wire.control('')),
        shapes:receive('ZH', Wire.control('   ')),
        shapes:receive('ZH', Wire.control('join')),
        shapes:receive('ZH', Wire.control('drop')),
        shapes:receive('ZH', Wire.control('drop notanumber')),
        shapes:update(1),
        shapes:reportRtt('ZH', nil),
        shapes:unlink('ZH'),
    }
    local allLists = true
    for _, value in ipairs(probes) do
        if type(value) ~= 'table' then allLists = false end
    end
    t.ok(allLists, 'malformed input of every shape returns a list')
    t.ok(sid2 ~= nil, 'and the session it was aimed at existed')

    -----------------------------------------------------------------------
    t.describe('the relay modules stay headless')

    -- Same rule as meatray/sim and the rest of meatray/net: a relay runs on a
    -- box with no window, and the wire format has to be testable with no LOVE.
    local RELAY_FILES = {
        'meatray/net/relaywire.lua',
        'meatray/net/transport/relay.lua',
        'masterserver/relay.lua',
        'masterserver/relayhost.lua',
    }

    local FORBIDDEN = {
        'love%.graphics', 'love%.window', 'love%.audio',
        'love%.keyboard', 'love%.mouse', 'love%.image', 'love%.timer',
    }

    for _, path in ipairs(RELAY_FILES) do
        local handle = io.open(path, 'r')
        if not handle then
            t.ok(false, ('%s is readable'):format(path))
        else
            local source = handle:read('*a')
            handle:close()

            -- Comments stripped first: every one of these files documents the
            -- rule and therefore names the APIs it forbids.
            local code = source
                :gsub('%-%-%[%[.-%]%]', '')
                :gsub('%-%-[^\n]*', '')

            local found
            for _, pattern in ipairs(FORBIDDEN) do
                local line = code:match('[^\n]*' .. pattern .. '[^\n]*')
                if line then found = line:sub(1, 60) break end
            end
            t.ok(not found, ('%s is love-free'):format(path), found)

            -- A top-level require is one that starts at column zero. `socket` at
            -- file scope would make the whole transport registry un-loadable
            -- under plain LuaJIT and take these tests with it.
            t.ok(not code:find("\nlocal [%w_]+ = require%('socket'%)"),
                 path .. ' does not require socket at file scope')
            t.ok(not code:find("\nlocal [%w_]+ = require%('enet'%)"),
                 path .. ' does not require enet at file scope')
        end
    end

    local savedLove = rawget(_G, 'love')
    rawset(_G, 'love', nil)
    for _, name in ipairs({ 'meatray.net.relaywire', 'masterserver.relay',
                            'masterserver.relayhost',
                            'meatray.net.transport.relay' }) do
        package.loaded[name] = nil
        local ok, err = pcall(require, name)
        t.ok(ok, ('%s loads without love'):format(name), err)
    end
    rawset(_G, 'love', savedLove)
end
