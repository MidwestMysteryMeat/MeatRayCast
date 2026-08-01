--[[
    End-to-end sealing: SHA-256, HMAC, seal/open, and the ticket field that
    carries the data key past the relay.
]]

return function(t)
    local Crypto = require('meatray.net.crypto')
    local Wire   = require('meatray.net.relaywire')

    -- Deterministic random for the suite: a fixed sequence, not the host clock.
    local n = 0
    Crypto.randomSource = function(len)
        local out = {}
        for i = 1, len do
            n = n + 1
            out[i] = string.char(n % 256)
        end
        return table.concat(out)
    end

    ---------------------------------------------------------------------
    t.describe('SHA-256 matches known vectors')

    t.eq(Crypto.sha256Hex(''),
         'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
         'empty string')
    t.eq(Crypto.sha256Hex('abc'),
         'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
         'abc')
    t.eq(Crypto.sha256Hex('abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq'),
         '248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1',
         'the 56-byte NIST vector')

    ---------------------------------------------------------------------
    t.describe('seal / open')

    local key = Crypto.randomKey()
    t.eq(#key, Crypto.KEY_BYTES, 'a random key is 32 bytes')

    local sealed, err = Crypto.seal(key, 'snapshot-body', 'ch0r')
    t.ok(sealed ~= nil, 'seal succeeds', err)
    t.eq(#sealed, #'snapshot-body' + Crypto.SEAL_OVERHEAD,
         'overhead is exactly SEAL_OVERHEAD')

    local plain = Crypto.open(key, sealed, 'ch0r')
    t.eq(plain, 'snapshot-body', 'open recovers the plaintext')

    t.eq(Crypto.open(key, sealed, 'wrong'), nil, 'wrong AAD fails the tag')
    t.eq(Crypto.open(string.rep('\0', 32), sealed, 'ch0r'), nil, 'wrong key fails')

    local tampered = sealed:sub(1, -2) .. string.char((sealed:byte(-1) + 1) % 256)
    t.eq(Crypto.open(key, tampered, 'ch0r'), nil, 'a flipped tag byte fails')

    local empty = assert(Crypto.seal(key, '', 'a'))
    t.eq(Crypto.open(key, empty, 'a'), '', 'empty plaintext round-trips')

    ---------------------------------------------------------------------
    t.describe('tickets carry the data key')

    local short = Wire.formatTicket{
        address = '198.51.100.20:6790',
        session = 'aabbccdd',
        secret  = '11223344556677889900aabbccddeeff',
    }
    t.ok(short and not short:find('//', 10, true), 'three-field ticket formats')
    local parsed = Wire.parseTicket(short)
    t.eq(parsed and parsed.dataKey, nil, 'three-field ticket has no data key')

    local dataHex = Crypto.toHex(key)
    t.eq(#dataHex, 64, 'hex key is 64 characters')
    local long = Wire.formatTicket{
        address = '198.51.100.20:6790',
        session = 'aabbccdd',
        secret  = '11223344556677889900aabbccddeeff',
        dataKey = dataHex,
    }
    t.ok(long and #long > #short, 'four-field ticket is longer')
    local full = Wire.parseTicket(long)
    t.eq(full and full.dataKey, dataHex, 'data key survives parse')
    t.eq(full.session, 'aabbccdd', 'session still parses')
    t.eq(full.secret, '11223344556677889900aabbccddeeff', 'relay secret still parses')

    local badKey = Wire.formatTicket{
        address = 'h:1', session = 'aa', secret = 'bb', dataKey = 'abcd',
    }
    t.eq(badKey, nil, 'a short data key is refused at format time')

    ---------------------------------------------------------------------
    t.describe('seal refuses a random source that misbehaves')

    local saved = Crypto.randomSource
    Crypto.randomSource = function() return 'short' end
    local refused, why = Crypto.seal(key, 'body', 'aad')
    t.eq(refused, nil, 'a wrong-length nonce refuses to seal')
    t.ok(why and why:find('length'), 'and says why', why)
    Crypto.randomSource = saved

    ---------------------------------------------------------------------
    -- From here the injected source is gone: these assertions are about the
    -- real generator. This is the regression guard for the LCG that used to
    -- live here, whose entire output followed from os.time().
    Crypto.randomSource = nil

    t.describe('randomness comes from the OS, not the clock')

    local source = Crypto.entropySource()
    t.ok(source ~= nil, 'an OS entropy source is available', tostring(source))

    local k1 = Crypto.randomKey()
    local k2 = Crypto.randomKey()
    t.eq(#k1, Crypto.KEY_BYTES, 'a real key is 32 bytes')
    t.ok(k1 ~= k2, 'two keys differ')
    t.ok(k1 ~= string.rep('\0', Crypto.KEY_BYTES), 'a key is not all zeroes')

    -- The decisive one. Freeze the clock: a clock-seeded generator reseeded
    -- twice under a frozen os.time() returns the same bytes both times, which is
    -- exactly how the old implementation failed. A generator seeded from the OS
    -- does not care what the clock says.
    local realTime = os.time
    os.time = function() return 1754000000 end
    assert(Crypto.reseed())
    local frozen1 = Crypto.randomKey()
    assert(Crypto.reseed())
    local frozen2 = Crypto.randomKey()
    os.time = realTime
    t.ok(frozen1 ~= frozen2,
         'reseeding under a frozen clock still yields different keys')

    -- Bit-level shape. The old generator emitted an LCG's low byte, whose
    -- lowest bit alternates with period two, so consecutive bytes disagreed in
    -- bit 0 essentially every time. Real bytes disagree about half the time.
    local sample = Crypto.randomBytes(2048)
    t.eq(#sample, 2048, 'the generator returns the length asked for')
    local flips, seen = 0, {}
    for i = 1, #sample do
        local b = sample:byte(i)
        seen[b] = true
        if i > 1 and (b % 2) ~= (sample:byte(i - 1) % 2) then
            flips = flips + 1
        end
    end
    local distinct = 0
    for _ in pairs(seen) do distinct = distinct + 1 end
    t.ok(distinct > 200, 'sample covers most byte values', distinct)
    t.ok(flips > 700 and flips < 1350,
         'low bit does not alternate on a fixed period', flips)

    ---------------------------------------------------------------------
    t.describe('master server secrets do not follow from math.randomseed')

    local Relay = require('masterserver.relay')

    -- Two relays built either side of an identical math.randomseed. When the
    -- secrets came from math.random these two lists were byte-for-byte equal,
    -- and relayserver/main.lua seeded from os.time() -- so the session secret
    -- that authorises a slot was guessable from the start time.
    local function secretsAfterSeed()
        math.randomseed(42)
        local r = Relay.new{}
        return { r:randomHex(16), r:randomHex(16) }
    end
    local runA = secretsAfterSeed()
    local runB = secretsAfterSeed()
    t.eq(#runA[1], 32, 'a 16-byte secret is 32 hex characters')
    t.ok(runA[1] ~= runB[1] and runA[2] ~= runB[2],
         'identical math.randomseed no longer reproduces relay secrets')
    t.ok(runA[1] ~= runA[2], 'successive secrets differ')

    -- The injected source still works, because the deterministic suites depend
    -- on it.
    local fixed = Relay.new{ randomSource = function() return 0.5 end }
    t.eq(fixed:randomHex(4), '88888888', 'an injected source is still honoured')
end
