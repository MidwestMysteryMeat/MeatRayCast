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

    Crypto.randomSource = nil
end
