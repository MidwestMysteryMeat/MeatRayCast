--[[
    D33: RCON — fails closed with no secret, constant-time auth with lockout,
    an unauthed session can do nothing but try, and the commands act on the
    host.
]]

return function(t)
    local Rcon = require('meatray.net.rcon')
    local Net  = require('meatray.net')

    t.eq(Net.rcon, Rcon, 'Net.rcon is the module')

    -- A mock host that records what RCON asked it to do, so the command tests
    -- assert intent without a live server.
    local function mockHost()
        local h = { said = {}, kicked = {}, banned = {}, players = 3 }
        function h:playerCount() return self.players end
        function h:chat(text, from) self.said[#self.said + 1] = { text, from } end
        function h:kick(who, reason)
            if who == 'ghost' then return false, 'no such peer' end
            self.kicked[#self.kicked + 1] = { who, reason }; return true
        end
        function h:ban(who, reason)
            self.banned[#self.banned + 1] = { who, reason }; return true
        end
        function h:rconStatus()
            return { { name = 'alice', peerId = 1, address = '10.0.0.5' } }
        end
        return h
    end

    ---------------------------------------------------------------------
    t.describe('no secret means RCON is off, fail closed')

    local off = Rcon.new{ host = mockHost() }
    t.eq(off:enabled(), false, 'disabled with no secret')
    local s = off:open('a')
    t.eq(off:auth(s, ''), false, 'an empty password does not unlock a blank secret')
    t.eq(off:auth(s, 'anything'), false, 'and neither does a guess')
    t.eq(select(2, off:auth(s, 'x')), 'rcon is disabled', 'it says it is disabled')
    t.eq(select(1, off:exec(s, 'status')), false, 'and nothing executes')

    ---------------------------------------------------------------------
    t.describe('auth: the right password unlocks, the wrong one counts down')

    local r = Rcon.new{ secret = 'hunter2', host = mockHost(), maxTries = 3 }
    t.eq(r:enabled(), true, 'enabled with a secret')
    local sess = r:open('admin')

    t.eq(r:isAuthed(sess), false, 'a fresh session is not authed')
    t.eq(select(1, r:exec(sess, 'status')), false, 'and cannot run commands')
    t.eq(select(2, r:exec(sess, 'status')), 'not authenticated', 'told so plainly')

    t.eq(r:auth(sess, 'wrong'), false, 'a wrong password fails')
    t.eq(r:auth(sess, 'hunter2'), true, 'the right one succeeds')
    t.eq(r:isAuthed(sess), true, 'and the session is now authed')

    ---------------------------------------------------------------------
    t.describe('lockout after too many tries')

    local lock = Rcon.new{ secret = 'sesame', maxTries = 3 }
    local ls = lock:open('bruteforcer')
    lock:auth(ls, 'a'); lock:auth(ls, 'b')
    t.eq(select(2, lock:auth(ls, 'c')), 'too many attempts; session locked',
         'the third miss locks the session')
    t.eq(select(2, lock:auth(ls, 'sesame')), 'session locked',
         'and even the RIGHT password is refused once locked')
    -- A new session is the only way back — which a transport can rate-limit.
    local fresh = lock:open('bruteforcer')
    t.eq(lock:auth(fresh, 'sesame'), true, 'a new session starts the count over')

    ---------------------------------------------------------------------
    t.describe('the commands act on the host')

    local host = mockHost()
    local admin = Rcon.new{ secret = 'pw', host = host,
                            onMap = function(name) host.requestedMap = name end }
    local a = admin:open('op')
    admin:auth(a, 'pw')

    local ok, reply = admin:exec(a, 'status')
    t.eq(ok, true, 'status runs')
    t.ok(reply:find('players: 3'), 'and reports the count')
    t.ok(reply:find('alice'), 'and the peer list')

    admin:exec(a, 'say server restarting')
    t.eq(host.said[1][1], 'server restarting', 'say reaches the host chat')
    t.eq(host.said[1][2], 'SERVER', 'as the server')

    ok, reply = admin:exec(a, 'kick alice trolling')
    t.eq(ok, true, 'kick runs')
    t.eq(host.kicked[1][1], 'alice', 'the named peer')
    t.eq(host.kicked[1][2], 'trolling', 'with the reason')

    ok, reply = admin:exec(a, 'kick ghost')
    t.ok(reply:find('kick failed'), 'a kick the host refuses is reported, not hidden')

    admin:exec(a, 'ban alice cheating')
    t.eq(host.banned[1][1], 'alice', 'ban reaches the host')

    admin:exec(a, 'map arena2')
    t.eq(host.requestedMap, 'arena2', 'map calls onMap rather than loading here')

    ok, reply = admin:exec(a, 'help')
    t.ok(reply:find('kick'), 'help lists the commands')

    ok, reply = admin:exec(a, 'nonsense')
    t.eq(ok, false, 'an unknown command is refused')
    t.ok(reply:find('unknown command'), 'by name')

    -- A command with no host method degrades to a message, not a crash.
    local hostless = Rcon.new{ secret = 'pw' }
    local h2 = hostless:open('x'); hostless:auth(h2, 'pw')
    t.ok(select(2, hostless:exec(h2, 'kick someone')):find('cannot kick'),
         'a hostless RCON says it cannot, rather than raising')
    t.ok(select(2, hostless:exec(h2, 'map x')):find('not wired'),
         'and map with no onMap says so')

    ---------------------------------------------------------------------
    t.describe('the compare is over digests, not raw strings')

    -- A near-miss the same length as the secret and a totally different length
    -- both simply fail — the point being that neither leaks how close it was,
    -- which we can only assert behaviourally: both are false.
    local cmp = Rcon.new{ secret = 'correct-horse' }
    local cs = cmp:open('c')
    t.eq(cmp:auth(cs, 'correct-horsx'), false, 'a one-char miss fails')
    cs = cmp:open('c')
    t.eq(cmp:auth(cs, 'x'), false, 'a length mismatch fails')
    cs = cmp:open('c')
    t.eq(cmp:auth(cs, 'correct-horse'), true, 'and the exact secret passes')
end
