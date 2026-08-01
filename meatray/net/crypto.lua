--[[
    meatray.net.crypto — end-to-end sealing for the relay data path.

    The relay sees every session that passes through it. ENet has no encryption
    and neither did this protocol: an operator could read and alter anything.
    That is the reason the reference relay is something you run yourself, and the
    reason a ticket is a capability rather than an identity.

    This module is the fix. It is pure Lua (no OpenSSL, no LOVE), so a dedicated
    server and the headless suite both get the same bytes. The construction is
    encrypt-then-MAC with SHA-256:

        stream block i  = SHA256(key || nonce || i)     -- i is a big-endian u32
        ciphertext      = plaintext XOR stream
        tag             = HMAC-SHA256(key, aad || nonce || ciphertext)[1..16]
        sealed          = nonce (12) || ciphertext || tag (16)

    The key never travels through the relay. The host generates it when the
    session opens and puts it in the ticket the client receives out of band
    (registry listing, chat, clipboard). The relay still sees the session secret
    that authorises a slot; it does not see the data key. Holding a full ticket
    still lets you join and decrypt — that is the capability model, unchanged.

    Overhead is SEAL_OVERHEAD (28) bytes per data frame. Control frames to the
    relay stay cleartext: the relay has to parse them.

    HEADLESS: no love, no socket. Randomness takes an injectable source for tests.
]]

local Crypto = {}

local byte, char, sub, rep = string.byte, string.char, string.sub, string.rep
local floor, abs = math.floor, math.abs
local concat = table.concat

-- 12-byte nonce + 16-byte tag. Stated so the MTU accounting and the tests pin
-- the same number rather than re-deriving it.
Crypto.NONCE_BYTES = 12
Crypto.TAG_BYTES   = 16
Crypto.KEY_BYTES   = 32
Crypto.SEAL_OVERHEAD = Crypto.NONCE_BYTES + Crypto.TAG_BYTES

---------------------------------------------------------------------------
-- SHA-256 (FIPS 180-4), pure Lua
---------------------------------------------------------------------------

local K = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
    0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
    0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
    0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
    0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
    0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
    0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
    0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

local function band(a, b)
    local r, bit = 0, 1
    for _ = 1, 32 do
        local aa, bb = a % 2, b % 2
        if aa + bb == 2 then r = r + bit end
        a, b, bit = (a - aa) / 2, (b - bb) / 2, bit * 2
    end
    return r
end

local function bxor(a, b)
    local r, bit = 0, 1
    for _ = 1, 32 do
        local aa, bb = a % 2, b % 2
        if aa ~= bb then r = r + bit end
        a, b, bit = (a - aa) / 2, (b - bb) / 2, bit * 2
    end
    return r
end

local function bnot(a)
    return 4294967295 - a
end

local function rrotate(x, n)
    n = n % 32
    local low = x % (2 ^ n)
    return (low * (2 ^ (32 - n)) + floor(x / (2 ^ n))) % 4294967296
end

local function rshift(x, n)
    return floor(x / (2 ^ n)) % 4294967296
end

local function w32(x)
    return x % 4294967296
end

local function wordsToBytes(words)
    local out = {}
    for i = 1, #words do
        local v = words[i]
        out[#out + 1] = char(
            floor(v / 16777216) % 256,
            floor(v / 65536) % 256,
            floor(v / 256) % 256,
            v % 256
        )
    end
    return concat(out)
end

local function min(a, b)
    return a < b and a or b
end

function Crypto.sha256(message)
    message = tostring(message or '')
    local len = #message
    local bitLen = len * 8

    message = message .. char(0x80)
    while (#message % 64) ~= 56 do
        message = message .. char(0)
    end

    -- 64-bit big-endian bit length. Messages this large are not a concern here.
    local hi = floor(bitLen / 4294967296)
    local lo = bitLen % 4294967296
    message = message
        .. char(floor(hi / 16777216) % 256, floor(hi / 65536) % 256,
                floor(hi / 256) % 256, hi % 256)
        .. char(floor(lo / 16777216) % 256, floor(lo / 65536) % 256,
                floor(lo / 256) % 256, lo % 256)

    local h0, h1, h2, h3 = 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a
    local h4, h5, h6, h7 = 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19

    for off = 1, #message, 64 do
        local chunk = sub(message, off, off + 63)
        local w = {}
        for i = 0, 15 do
            local b1, b2, b3, b4 = byte(chunk, i * 4 + 1, i * 4 + 4)
            w[i] = b1 * 16777216 + b2 * 65536 + b3 * 256 + b4
        end
        for i = 16, 63 do
            local s0 = bxor(bxor(rrotate(w[i - 15], 7), rrotate(w[i - 15], 18)), rshift(w[i - 15], 3))
            local s1 = bxor(bxor(rrotate(w[i - 2], 17), rrotate(w[i - 2], 19)), rshift(w[i - 2], 10))
            w[i] = w32(w[i - 16] + s0 + w[i - 7] + s1)
        end

        local a, b, c, d = h0, h1, h2, h3
        local e, f, g, h = h4, h5, h6, h7

        for i = 0, 63 do
            local S1 = bxor(bxor(rrotate(e, 6), rrotate(e, 11)), rrotate(e, 25))
            local ch = bxor(band(e, f), band(bnot(e), g))
            local t1 = w32(h + S1 + ch + K[i + 1] + w[i])
            local S0 = bxor(bxor(rrotate(a, 2), rrotate(a, 13)), rrotate(a, 22))
            local maj = bxor(bxor(band(a, b), band(a, c)), band(b, c))
            local t2 = w32(S0 + maj)
            h, g, f, e = g, f, e, w32(d + t1)
            d, c, b, a = c, b, a, w32(t1 + t2)
        end

        h0 = w32(h0 + a); h1 = w32(h1 + b); h2 = w32(h2 + c); h3 = w32(h3 + d)
        h4 = w32(h4 + e); h5 = w32(h5 + f); h6 = w32(h6 + g); h7 = w32(h7 + h)
    end

    return wordsToBytes{ h0, h1, h2, h3, h4, h5, h6, h7 }
end

function Crypto.sha256Hex(message)
    local dig = Crypto.sha256(message)
    local out = {}
    for i = 1, #dig do
        out[i] = ('%02x'):format(byte(dig, i))
    end
    return concat(out)
end

---------------------------------------------------------------------------
-- HMAC-SHA256
---------------------------------------------------------------------------

function Crypto.hmacSha256(key, message)
    key = tostring(key or '')
    message = tostring(message or '')

    if #key > 64 then key = Crypto.sha256(key) end
    if #key < 64 then key = key .. rep('\0', 64 - #key) end

    local o, i = {}, {}
    for n = 1, 64 do
        local k = byte(key, n)
        o[n] = char(bxor(k, 0x5c))
        i[n] = char(bxor(k, 0x36))
    end
    return Crypto.sha256(concat(o) .. Crypto.sha256(concat(i) .. message))
end

---------------------------------------------------------------------------
-- Randomness
---------------------------------------------------------------------------

-- Seeded once from the operating system, then expanded by SHA-256. There is no
-- fallback to a clock-seeded PRNG, and that absence is the point.
--
-- What was here before was a 32-bit LCG whose state began at a literal constant
-- and was stirred with os.time(). os.time() moves once a second, so the first
-- call's state -- and therefore every byte of the 32-byte session data key that
-- relay.lua asks for -- was fixed by the second in which the session opened. An
-- attacker who knows the day has a few thousand candidates to try offline. It
-- also emitted the LCG's low byte, whose lowest bit alternates with period two.
-- The relay operator is precisely the attacker this module exists to stop, so a
-- key they can enumerate is the same as no encryption at all.
--
-- The rule this now follows: a security layer must never silently degrade. If
-- the OS will not give us entropy, randomBytes refuses and the caller refuses to
-- open a sealed session. Failing loudly is recoverable; shipping a guessable key
-- while reporting "end-to-end sealed" is not.

local osEntropySource   -- name of the source that seeded us, for diagnostics
local drbgState         -- 32 bytes, ratcheted after every request
local drbgCounter = 0

-- Each declaration is made once and guarded, because ffi.cdef raises on a
-- redefinition and this module may be required from several places.
local declared = {}
local function declareOnce(name, source)
    if declared[name] then return true end
    local ffiOk, ffi = pcall(require, 'ffi')
    if not ffiOk then return false end
    if not pcall(ffi.cdef, source) then return false end
    declared[name] = true
    return true
end

-- Windows, preferred: the documented modern CSPRNG. BCRYPT_USE_SYSTEM_PREFERRED_RNG
-- (2) means we do not have to open an algorithm provider first.
local function entropyFromBCrypt(n)
    local ok, ffi = pcall(require, 'ffi')
    if not ok or ffi.os ~= 'Windows' then return nil end
    if not declareOnce('bcrypt', [[
        int __stdcall BCryptGenRandom(void *hAlgorithm, unsigned char *pbBuffer,
                                      unsigned long cbBuffer,
                                      unsigned long dwFlags);
    ]]) then return nil end
    local loaded, bcrypt = pcall(ffi.load, 'bcrypt')
    if not loaded then return nil end
    local buf = ffi.new('uint8_t[?]', n)
    local called, status = pcall(bcrypt.BCryptGenRandom, nil, buf, n, 2)
    if not called or status ~= 0 then return nil end  -- 0 == STATUS_SUCCESS
    return ffi.string(buf, n), 'BCryptGenRandom'
end

-- Windows, fallback: older systems and stripped installs where bcrypt.dll will
-- not load. RtlGenRandom is exported under this name and needs no provider.
local function entropyFromRtlGenRandom(n)
    local ok, ffi = pcall(require, 'ffi')
    if not ok or ffi.os ~= 'Windows' then return nil end
    if not declareOnce('rtlgenrandom', [[
        int __stdcall SystemFunction036(void *RandomBuffer,
                                        unsigned long RandomBufferLength);
    ]]) then return nil end
    local loaded, advapi = pcall(ffi.load, 'advapi32')
    if not loaded then return nil end
    local buf = ffi.new('uint8_t[?]', n)
    local called, rc = pcall(advapi.SystemFunction036, buf, n)
    if not called or rc == 0 then return nil end
    return ffi.string(buf, n), 'RtlGenRandom'
end

-- Linux, preferred: no file descriptor to exhaust, works inside a chroot, and
-- blocks until the pool is initialised rather than returning weak bytes at boot.
-- glibc exposes it from 2.25; older libc falls through to the device below.
local function entropyFromGetrandom(n)
    local ok, ffi = pcall(require, 'ffi')
    if not ok or ffi.os ~= 'Linux' then return nil end
    if not declareOnce('getrandom', [[
        long getrandom(void *buf, size_t buflen, unsigned int flags);
    ]]) then return nil end
    local buf = ffi.new('uint8_t[?]', n)
    local called, got = pcall(function() return ffi.C.getrandom(buf, n, 0) end)
    if not called or tonumber(got) ~= n then return nil end
    return ffi.string(buf, n), 'getrandom'
end

-- POSIX fallback, and anything else exposing the device. Needs no FFI, so this
-- is also the path for a plain Lua host without LuaJIT.
local function entropyFromUrandom(n)
    local f = io.open('/dev/urandom', 'rb')
    if not f then return nil end
    local ok, bytes = pcall(f.read, f, n)
    f:close()
    if ok and type(bytes) == 'string' and #bytes == n then
        return bytes, '/dev/urandom'
    end
    return nil
end

-- Returns seed bytes and the source name, or nil when the host offers none.
local ENTROPY_SOURCES = {
    entropyFromGetrandom,
    entropyFromBCrypt,
    entropyFromRtlGenRandom,
    entropyFromUrandom,
}

local function osEntropy(n)
    for i = 1, #ENTROPY_SOURCES do
        local bytes, source = ENTROPY_SOURCES[i](n)
        if bytes and #bytes == n then return bytes, source end
    end
    return nil
end

-- Reseeds from the OS. Returns true, or nil plus a reason.
function Crypto.reseed()
    local seed, source = osEntropy(Crypto.KEY_BYTES)
    if not seed then
        drbgState, osEntropySource = nil, nil
        return nil, 'no OS entropy source (tried getrandom, BCryptGenRandom, '
                 .. 'RtlGenRandom, /dev/urandom)'
    end
    drbgState = Crypto.sha256(seed)
    drbgCounter = 0
    osEntropySource = source
    return true
end

-- Which OS source seeded the generator, or nil if it is not seeded. Exposed so
-- a server operator and the tests can both confirm this is not running on a
-- fallback that does not exist.
function Crypto.entropySource()
    if not drbgState then Crypto.reseed() end
    return osEntropySource
end

-- SHA-256 in counter mode, with the state ratcheted after each request so that
-- recovering it later does not reveal keys already handed out.
local function drbgBytes(n)
    if not drbgState then
        local ok, why = Crypto.reseed()
        if not ok then return nil, why end
    end

    local out, produced = {}, 0
    while produced < n do
        local block = Crypto.sha256(
            drbgState
            .. char(floor(drbgCounter / 16777216) % 256,
                    floor(drbgCounter / 65536) % 256,
                    floor(drbgCounter / 256) % 256,
                    drbgCounter % 256)
        )
        local take = min(32, n - produced)
        out[#out + 1] = sub(block, 1, take)
        produced = produced + take
        drbgCounter = drbgCounter + 1
    end

    drbgState = Crypto.sha256(drbgState .. '\1')
    return concat(out)
end

-- Tests inject this so the suite is deterministic. Production leaves it nil.
Crypto.randomSource = nil

-- Returns n bytes, or nil plus a reason. Callers must treat nil as fatal for
-- anything that protects a session.
function Crypto.randomBytes(n)
    n = floor(tonumber(n) or 0)
    if n <= 0 then return '' end
    if Crypto.randomSource then return Crypto.randomSource(n) end
    return drbgBytes(n)
end

function Crypto.randomKey()
    return Crypto.randomBytes(Crypto.KEY_BYTES)
end

-- Hex convenience for callers that hand secrets to humans or put them in
-- tickets. bytes is the byte count, so the string is twice that long.
function Crypto.randomHex(bytes)
    local raw, why = Crypto.randomBytes(bytes or 16)
    if not raw then return nil, why end
    return Crypto.toHex(raw)
end

function Crypto.toHex(bytes)
    local out = {}
    for i = 1, #bytes do out[i] = ('%02x'):format(byte(bytes, i)) end
    return concat(out)
end

function Crypto.fromHex(hex)
    if type(hex) ~= 'string' or #hex % 2 ~= 0 or not hex:match('^%x*$') then
        return nil, 'not hex'
    end
    local out = {}
    for i = 1, #hex, 2 do
        out[#out + 1] = char(tonumber(sub(hex, i, i + 1), 16))
    end
    return concat(out)
end

---------------------------------------------------------------------------
-- Seal / open
---------------------------------------------------------------------------

local function keystream(key, nonce, length)
    local out, generated, counter = {}, 0, 0
    while generated < length do
        local block = Crypto.sha256(
            key .. nonce
            .. char(floor(counter / 16777216) % 256,
                    floor(counter / 65536) % 256,
                    floor(counter / 256) % 256,
                    counter % 256)
        )
        local take = min(32, length - generated)
        out[#out + 1] = sub(block, 1, take)
        generated = generated + take
        counter = counter + 1
    end
    return concat(out)
end

local function xorBytes(a, b)
    local out = {}
    for i = 1, #a do
        out[i] = char(bxor(byte(a, i), byte(b, i)))
    end
    return concat(out)
end

-- Constant-time-ish compare: always walk the whole string so a wrong tag does
-- not short-circuit on the first mismatch. Lua cannot be truly constant-time;
-- this is still better than `a == b` stopping early in the interpreter.
local function tagsEqual(a, b)
    if #a ~= #b then return false end
    local diff = 0
    for i = 1, #a do
        diff = bxor(diff, bxor(byte(a, i), byte(b, i)))
    end
    return diff == 0
end

-- Returns sealed bytes, or nil plus a reason.
function Crypto.seal(key, plaintext, aad)
    if type(key) ~= 'string' or #key ~= Crypto.KEY_BYTES then
        return nil, 'key must be 32 bytes'
    end
    plaintext = tostring(plaintext or '')
    aad = tostring(aad or '')

    local nonce = Crypto.randomBytes(Crypto.NONCE_BYTES)
    if #nonce ~= Crypto.NONCE_BYTES then
        return nil, 'random source returned the wrong length'
    end

    local stream = keystream(key, nonce, #plaintext)
    local ct = xorBytes(plaintext, stream)
    local tag = sub(Crypto.hmacSha256(key, aad .. nonce .. ct), 1, Crypto.TAG_BYTES)
    return nonce .. ct .. tag
end

-- Returns plaintext, or nil plus a reason. Wrong tag, short input, and wrong
-- key all refuse rather than returning garbage — garbage would be applied as a
-- snapshot and look like a desync.
function Crypto.open(key, sealed, aad)
    if type(key) ~= 'string' or #key ~= Crypto.KEY_BYTES then
        return nil, 'key must be 32 bytes'
    end
    if type(sealed) ~= 'string' or #sealed < Crypto.SEAL_OVERHEAD then
        return nil, 'sealed payload too short'
    end
    aad = tostring(aad or '')

    local nonce = sub(sealed, 1, Crypto.NONCE_BYTES)
    local tag = sub(sealed, -Crypto.TAG_BYTES)
    local ct = sub(sealed, Crypto.NONCE_BYTES + 1, -(Crypto.TAG_BYTES + 1))

    local expect = sub(Crypto.hmacSha256(key, aad .. nonce .. ct), 1, Crypto.TAG_BYTES)
    if not tagsEqual(tag, expect) then
        return nil, 'authentication failed'
    end

    local stream = keystream(key, nonce, #ct)
    return xorBytes(ct, stream)
end

return Crypto
