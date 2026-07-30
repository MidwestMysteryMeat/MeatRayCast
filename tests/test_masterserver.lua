--[[
    The server registry.

    Every rule that makes a public listing service survive contact with the
    internet is in here, and none of these tests open a port or wait for a
    timeout. That is the reason the logic is a pure module: the interesting cases
    are "an entry nobody heard from for thirty-one seconds" and "a host claiming
    to be at someone else's address", and neither is worth testing if testing it
    means standing up a server and sleeping.

    The forgery case is the one to read first. It is the difference between a
    server browser and a DDoS amplifier.
]]

return function(t)
    local Registry = require('masterserver.registry')

    -- Deterministic "randomness" so tokens and nonces are reproducible. Real
    -- deployments inject something better; the registry only needs the values
    -- to be unguessable in production, not in a test.
    local function fixedRandom()
        local n = 0
        return function()
            n = (n * 1103515245 + 12345) % 2147483648
            return (n % 1000) / 1000
        end
    end

    local function newRegistry(opts)
        opts = opts or {}
        opts.randomSource = opts.randomSource or fixedRandom()
        return Registry.new(opts)
    end

    local function goodPayload(over)
        local p = {
            name = 'Test Server', map = 'arena', port = 6789,
            players = 2, maxPlayers = 8, protocol = 2, locked = false,
        }
        for k, v in pairs(over or {}) do p[k] = v end
        return p
    end

    -- Announce and pass the challenge in one step, since most tests care about
    -- what happens to a listed server rather than about the handshake.
    local function listed(reg, address, over)
        local challenge = assert(reg:announce(address, goodPayload(over)))
        assert(reg:challengeReply(challenge.token, challenge.nonce))
        return challenge.token
    end

    ---------------------------------------------------------------------
    t.describe('a host does not get to say where it is')

    -- The single most important rule here. If a host could name its own address
    -- it could name a stranger's, and every client that clicked that entry would
    -- send traffic at them -- the browser becomes an amplifier.
    local reg = newRegistry()
    local challenge = reg:announce('198.51.100.7', goodPayload{
        address = '203.0.113.9',       -- a lie, and it must be ignored
        ip      = '203.0.113.9',
        host    = '203.0.113.9',
    })
    t.ok(challenge ~= nil, 'the announce is accepted')
    t.eq(challenge.address, '198.51.100.7', 'the challenge goes to the source address')

    reg:challengeReply(challenge.token, challenge.nonce)
    local entry = reg:get('198.51.100.7', 6789)
    t.ok(entry ~= nil, 'the entry is filed under the source address')
    t.eq(reg:get('203.0.113.9', 6789), nil, 'and not under the one it claimed')
    t.eq(reg:list()[1].address, '198.51.100.7', 'the listing shows the real address')

    ---------------------------------------------------------------------
    t.describe('nothing is listed until something answered')

    local c = newRegistry()
    local ch = c:announce('198.51.100.8', goodPayload())
    t.ok(ch.token and ch.nonce, 'an announce returns a token and a nonce')
    t.eq(c:count(), 0, 'but nothing is listed yet')
    t.eq(#c:list(), 0, 'and the browser shows nothing')

    t.ok(c:challengeReply(ch.token, ch.nonce) ~= nil, 'the right nonce lists it')
    t.eq(c:count(), 1, 'now it is listed')

    -- A wrong nonce burns the attempt rather than allowing another guess, so the
    -- challenge cannot be brute-forced by replying in a loop.
    local ch2 = c:announce('198.51.100.9', goodPayload())
    t.eq(c:challengeReply(ch2.token, 'wrong'), nil, 'a wrong nonce fails')
    t.eq(c:challengeReply(ch2.token, ch2.nonce), nil,
         'and the correct nonce no longer works either -- one attempt only')
    t.eq(c:count(), 1, 'so it never got listed')

    t.eq(c:challengeReply('no-such-token', 'x'), nil, 'an unknown token fails')

    -- An unanswered challenge does not sit around forever.
    local c3 = newRegistry{ challengeTimeout = 10 }
    local ch3 = c3:announce('198.51.100.10', goodPayload())
    c3:advance(11)
    t.eq(c3:challengeReply(ch3.token, ch3.nonce), nil, 'an expired challenge is gone')
    t.eq(c3.stats.failed, 1, 'and counted as failed')

    ---------------------------------------------------------------------
    t.describe('an entry that stops talking stops being listed')

    local e = newRegistry{ entryTimeout = 30 }
    local token = listed(e, '198.51.100.11')
    t.eq(e:count(), 1, 'listed')

    e:advance(29)
    t.eq(e:count(), 1, 'still listed just before the timeout')

    e:advance(2)                                   -- now 31
    t.eq(e:count(), 0, 'dropped once the timeout passes')
    t.eq(e.stats.expired, 1, 'and counted as expired')

    t.eq(e:heartbeat(token), nil, 'the old token no longer beats')

    -- A heartbeat keeps it alive indefinitely.
    local k = newRegistry{ entryTimeout = 30 }
    local kt = listed(k, '198.51.100.12')
    for _ = 1, 10 do
        k:advance(20)
        k:heartbeat(kt, { players = 3 })
    end
    t.eq(k:count(), 1, 'a server that keeps beating stays listed')
    t.eq(k:list()[1].players, 3, 'and its player count updates')

    ---------------------------------------------------------------------
    t.describe('a heartbeat cannot move a server')

    -- The address and port identify the entry. Letting a heartbeat change them
    -- would let a host that passed a challenge at one address relist itself at
    -- another without ever being challenged there.
    local m = newRegistry()
    local mt = listed(m, '198.51.100.13')
    m:heartbeat(mt, { address = '203.0.113.1', port = 9999, players = 1 })

    t.ok(m:get('198.51.100.13', 6789) ~= nil, 'the entry stays where it was')
    t.eq(m:get('203.0.113.1', 9999), nil, 'and does not appear at the claimed address')
    t.eq(m:list()[1].port, 6789, 'the listed port is unchanged')

    t.eq(m:heartbeat('not-a-token'), nil, 'an unknown token cannot beat')

    ---------------------------------------------------------------------
    t.describe('one machine cannot fill the browser')

    local f = newRegistry{ maxPerAddress = 4 }
    for port = 7000, 7003 do listed(f, '198.51.100.20', { port = port }) end
    t.eq(f:count(), 4, 'four from one address is allowed')

    local refused, why = f:announce('198.51.100.20', goodPayload{ port = 7004 })
    t.eq(refused, nil, 'the fifth is refused')
    t.ok(why:find('too many'), 'and says why: ' .. tostring(why))

    -- A different machine is unaffected by its neighbour hitting the cap.
    t.ok(f:announce('198.51.100.21', goodPayload()) ~= nil,
         'another address is still accepted')

    -- Pending challenges count toward the cap, or the limit is bypassed by
    -- announcing repeatedly and never answering.
    local g = newRegistry{ maxPerAddress = 2 }
    g:announce('198.51.100.22', goodPayload{ port = 7100 })
    g:announce('198.51.100.22', goodPayload{ port = 7101 })
    t.eq(g:announce('198.51.100.22', goodPayload{ port = 7102 }), nil,
         'unanswered challenges still occupy the quota')

    -- Re-announcing an address already listed is a refresh, so a host that
    -- restarts does not have to wait out its own stale entry.
    local r = newRegistry{ maxPerAddress = 1 }
    listed(r, '198.51.100.23', { port = 7200 })
    t.ok(r:announce('198.51.100.23', goodPayload{ port = 7200 }) ~= nil,
         'the same address and port may re-announce despite the cap')

    ---------------------------------------------------------------------
    t.describe('payloads are not trusted')

    local v = newRegistry()
    local bad = {
        { {}, 'a payload with no name' },
        { { name = 'x' }, 'no port' },
        { goodPayload{ port = 0 }, 'port 0' },
        { goodPayload{ port = 70000 }, 'port above 65535' },
        { goodPayload{ port = 80.5 }, 'a fractional port' },
        { goodPayload{ maxPlayers = 0 }, 'maxPlayers 0' },
        { goodPayload{ players = 9, maxPlayers = 8 }, 'more players than seats' },
        { goodPayload{ players = -1 }, 'negative players' },
        -- Built by removal, not by `goodPayload{ protocol = nil }`: a nil value
        -- is not iterated by pairs, so that form silently leaves the default in
        -- place and tests nothing.
        { (function() local p = goodPayload(); p.protocol = nil; return p end)(),
          'no protocol version' },
        { goodPayload{ name = '' }, 'an empty name' },
        { goodPayload{ port = 'six thousand' }, 'a non-numeric port' },
    }
    for _, case in ipairs(bad) do
        t.eq(v:announce('198.51.100.30', case[1]), nil, case[2] .. ' is refused')
    end
    t.eq(v:announce(nil, goodPayload()), nil, 'an announce with no source address is refused')
    t.eq(v:announce('', goodPayload()), nil, 'or an empty one')

    -- A name goes straight into a browser, so control characters come out.
    local n = newRegistry()
    local nt = listed(n, '198.51.100.31', { name = 'evil\r\nX-Injected: 1\tserver' })
    t.eq(n:list()[1].name, 'evilX-Injected: 1server',
         'control characters are stripped from a name')

    local long = string.rep('A', 500)
    n:heartbeat(nt, { name = long })
    t.ok(#n:list()[1].name <= Registry.MAX_NAME, 'and a name is length-capped')

    ---------------------------------------------------------------------
    t.describe('the listing')

    local l = newRegistry()
    listed(l, '198.51.100.40', { name = 'oldest', port = 7300 })
    l:advance(5)
    listed(l, '198.51.100.41', { name = 'newest', port = 7301 })

    local rows = l:list()
    t.eq(#rows, 2, 'both are listed')
    t.eq(rows[1].name, 'newest', 'most recently heard from comes first')
    t.eq(rows[1].age, 0, 'and its age is zero')
    t.eq(rows[2].age, 5, 'while the older one carries its age')

    -- No ping in the listing, on purpose: a registry-measured ping is the
    -- distance from the registry, not from the player.
    t.eq(rows[1].ping, nil, 'the registry publishes no ping')

    local fl = newRegistry()
    listed(fl, '198.51.100.50', { port = 7400, protocol = 2, players = 8, maxPlayers = 8 })
    listed(fl, '198.51.100.51', { port = 7401, protocol = 3, players = 1, maxPlayers = 8 })
    listed(fl, '198.51.100.52', { port = 7402, protocol = 2, players = 1, maxPlayers = 8, locked = true })

    t.eq(#fl:list{ protocol = 2 }, 2, 'filtering by protocol version works')
    t.eq(#fl:list{ notFull = true }, 2, 'and by "not full"')
    t.eq(#fl:list{ notLocked = true }, 2, 'and by "not locked"')
    t.eq(#fl:list{ protocol = 2, notLocked = true }, 1, 'and combined')

    ---------------------------------------------------------------------
    t.describe('introductions for hole punching')

    local p = newRegistry()
    local host = listed(p, '198.51.100.60', { port = 7500 })

    local intro = p:requestPunch('203.0.113.50', 40000, '198.51.100.60', 7500)
    t.ok(intro ~= nil, 'a client can ask to be introduced')
    t.eq(intro.address, '198.51.100.60', 'and is told where the host is')
    t.eq(intro.port, 7500, 'including the port')
    t.eq(intro.sendNow, true,
         'and to start sending immediately rather than waiting to be told the host is ready')

    local waiting = p:takePunches(host)
    t.eq(#waiting, 1, 'the host collects the waiting client')
    t.eq(waiting[1].address, '203.0.113.50', 'with its address')
    t.eq(waiting[1].port, 40000, 'and its port')

    t.eq(#p:takePunches(host), 0, 'and collecting is destructive -- no repeats')

    t.eq(p:requestPunch('203.0.113.50', 40000, '198.51.100.99', 7500), nil,
         'no introduction to a server that is not listed')
    t.eq(p:requestPunch('203.0.113.50', 0, '198.51.100.60', 7500), nil,
         'a nonsense client port is refused')
    t.eq(p:requestPunch(nil, 40000, '198.51.100.60', 7500), nil,
         'and so is a missing client address')

    -- A request nobody collected does not accumulate forever.
    local q = newRegistry{ challengeTimeout = 10 }
    local qh = listed(q, '198.51.100.61', { port = 7600 })
    q:requestPunch('203.0.113.60', 40001, '198.51.100.61', 7600)
    q:advance(11)
    t.eq(#q:takePunches(qh), 0, 'a stale introduction request is dropped')

    ---------------------------------------------------------------------
    t.describe('it runs with no host at all')

    -- The registry is the one part of this project that must run somewhere
    -- other than a game machine, so it may not quietly acquire a dependency on
    -- LOVE or on a socket library.
    local file = io.open('masterserver/registry.lua', 'r')
    t.ok(file ~= nil, 'the source is readable')
    if file then
        local source = file:read('*a')
        file:close()

        -- Comments and strings come out first. Without that, registry.lua's own
        -- HEADLESS header -- which says in prose that it uses no love, no
        -- socket and no os.time -- fails all three of these checks. A file being
        -- broken by its own accurate documentation is a scan bug, not a finding,
        -- and it has caught this project out twice now.
        local code = require('tests.support.lua_source').stripNonCode(source)

        t.ok(not code:find('[^%w_]love[^%w_]'), 'registry.lua does not name love')
        t.ok(not code:find("require%s*%(?%s*['\"]socket"), 'and does not require socket')
        t.ok(not code:find('os%.time'), 'and does not read a wall clock')

        -- Prove the stripper is not simply blanking the file, or all three
        -- assertions above would pass on an empty string.
        t.ok(code:find('function RegistryMT:announce'),
             'and the stripped source still contains real code')
    end
end
