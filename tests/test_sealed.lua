--[[
    Sealed transport. The decorator seals every frame and drops what does
    not authenticate; a real host+client complete a sealed handshake over
    loopback; a plaintext client and a wrong-password client both fail to
    join a sealed server; a sealed server refuses to start without a
    password; the wrapped transport still forwards non-data methods.
]]

return function(t)
    local Sealed   = require('meatray.net.transport.sealed')
    local Crypto   = require('meatray.net.crypto')
    local Entity   = require('meatray.sim.entity')
    local C        = require('meatray.sim.components')
    local Worldgen = require('meatray.sim.worldgen')
    local Net      = require('meatray.net')
    local Loopback = require('meatray.net.transport.loopback')

    ---------------------------------------------------------------------
    t.describe('the primitive: seal round-trips, tamper and wrong key do not')

    local key = Sealed.deriveKey('hunter2')
    t.ok(type(key) == 'string' and #key == Crypto.KEY_BYTES, 'a key derives')
    t.ok(not Sealed.deriveKey(''), 'the empty password derives nothing')
    t.ok(Sealed.deriveKey('a') ~= Sealed.deriveKey('b'),
        'different passwords, different keys')

    local frame = Crypto.seal(key, 'the snapshot', Sealed.AAD)
    t.eq(Crypto.open(key, frame, Sealed.AAD), 'the snapshot', 'a good frame opens')
    t.ok(not Crypto.open(Sealed.deriveKey('wrong'), frame, Sealed.AAD),
        'the wrong key does not')
    local tampered = frame:sub(1, #frame - 1) .. string.char((frame:byte(#frame) + 1) % 256)
    t.ok(not Crypto.open(key, tampered, Sealed.AAD), 'a tampered frame does not')

    ---------------------------------------------------------------------
    t.describe('the decorator: a fake transport, sealed both ways')

    -- A minimal transport that just queues what is "sent" for "service".
    local function fakeTransport()
        local q = {}
        return {
            queue = q,
            send = function(_, _, data)
                q[#q + 1] = { type = 'receive', data = data }; return true
            end,
            service = function() return table.remove(q, 1) end,
            listen = function() return true end,
            key = function(_, h) return 'k:' .. tostring(h) end,
        }
    end

    local raw = fakeTransport()
    local sealed = Sealed.wrap(raw, key)
    sealed:send('peer', 'hello', 1, true)
    t.ok(raw.queue[1] and raw.queue[1].data:sub(1, 1) == Sealed.MAGIC,
        'what hit the wire is a magic-prefixed sealed frame')
    t.ok(not raw.queue[1].data:find('hello', 1, true), 'the plaintext is not on the wire')
    local got = sealed:service()
    t.eq(got.data, 'hello', 'and it opens back to the original on the way in')
    t.eq(sealed.sealed, 1, 'one sealed')
    t.eq(sealed.opened, 1, 'one opened')

    -- Consume the sealed frame the send above queued, then inject a plaintext
    -- RECEIVE: it is refused, not delivered.
    raw.queue[#raw.queue + 1] = { type = 'receive', data = 'plain injection' }
    t.eq(sealed:service(), nil, 'a plaintext frame is dropped, not delivered')
    t.eq(sealed.refused, 1, 'and counted')

    -- A connect event carries a NUMERIC code (ENet) — not a sealed payload —
    -- and must pass through by TYPE, or the handshake never happens.
    raw.queue[#raw.queue + 1] = { type = 'connect', data = 0 }
    t.eq(sealed:service().type, 'connect', 'a connect event passes through untouched')
    raw.queue[#raw.queue + 1] = { type = 'disconnect', data = 5 }
    t.eq(sealed:service().type, 'disconnect', 'and a disconnect, code and all')

    -- Forwarded method: key() reaches the inner transport with self remapped.
    t.eq(sealed:key('h'), 'k:h', 'non-data methods forward to the inner transport')

    ---------------------------------------------------------------------
    t.describe('a real host and client complete a sealed handshake')

    Entity.clearArchetypes()
    Entity.archetype('player', function(e)
        e:add(C.Player{ peerId = 0, name = '?' })
        e:add(C.Health{ hp = 100, max = 100 })
        e:add(C.Input{})
        e.radius = 0.24
    end)
    Entity.resetIds(1)
    Loopback.reset()

    local function pump(host, client, seconds)
        for _ = 1, math.ceil((seconds or 0.1) * 60) do
            if host then host:update(1 / 60) end
            if client then client:update(1 / 60) end
        end
    end

    local host = Net.Host.new{
        mode = 'listen', transport = 'loopback', port = 8600,
        world = Worldgen.box(20, 20), snapshotRate = 20, onLog = function() end,
        sealed = true, password = 'friends',
    }
    t.ok(host, 'a sealed host starts (it has a password)')
    t.ok(host.sealedTransport, 'and knows it is sealed')

    local client = Net.Client.new{
        address = 'loopback:8600', transport = 'loopback',
        name = 'ada', sealed = true, password = 'friends', onLog = function() end,
    }
    pump(host, client, 0.3)
    t.eq(client.state, 'joined', 'the right password joins')
    t.ok(client.world and client.world.width == 20, 'and gets the world through the seal')

    ---------------------------------------------------------------------
    t.describe('a plaintext or wrong-password client cannot join a sealed server')

    -- No Loopback.reset() here: it would drop the host's listener. A fresh
    -- client gets a fresh address from the loopback, so they do not collide.
    local plain = Net.Client.new{
        address = 'loopback:8600', transport = 'loopback',
        name = 'eve', onLog = function() end,      -- no sealing at all
    }
    pump(host, plain, 0.3)
    t.ok(plain.state ~= 'joined', 'a plaintext client never joins', plain.state)

    local wrong = Net.Client.new{
        address = 'loopback:8600', transport = 'loopback',
        name = 'mal', sealed = true, password = 'guessing', onLog = function() end,
    }
    pump(host, wrong, 0.3)
    t.ok(wrong.state ~= 'joined', 'a wrong-password client never joins', wrong.state)
    -- The host dropped their frames at the transport: they never reached the
    -- access check, so this is not a "rejected" — it is silence.
    t.ok(host.transport.refused > 0, 'the sealed transport refused their frames')

    ---------------------------------------------------------------------
    t.describe('a sealed server refuses to start without a password')

    local nopw, why = Net.Host.new{
        mode = 'listen', transport = 'loopback', port = 8601,
        world = Worldgen.box(8, 8), sealed = true, onLog = function() end,
    }
    t.ok(not nopw and tostring(why):find('password'),
        'no password, no sealed server — loud refusal, never a weak key')

    host:close()
    Entity.clearArchetypes()
    Entity.resetIds(1)
end
