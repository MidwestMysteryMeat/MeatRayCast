--[[
    meatray.net.transport.sealed — every frame encrypted, as a decorator.

    Wraps ANY transport (enet, loopback, relay) and seals each data frame
    both directions with the relay path's proven construction
    (meatray.net.crypto: encrypt-then-MAC over SHA-256, random nonce per
    frame). The key is derived from the server password on both ends —
    Crypto.deriveSessionKey — so joining a sealed server IS the password
    proof, and the password itself never crosses the wire in any form, not
    even inside the handshake.

    A frame that does not open — plaintext client on a sealed server, a
    wrong password, a tampered packet, an attacker probing — is DROPPED and
    counted, never delivered: the host's parser only ever sees frames that
    authenticated. Connect/disconnect events pass through untouched (they
    carry no payload), and every other transport method forwards to the
    wrapped one with self remapped, so the host and client cannot tell the
    difference — which is the whole point of a decorator.

    The one honest cost: ~29 bytes per frame and one seal per send. The
    committed crypto.seal600 benchmark floor (2,000/s vs ~1,000/s needed
    for an 8-peer 60Hz session) is what makes this affordable — on LuaJIT.
    A plain-Lua 5.4 process seals at ~94/s and should not host sealed
    sessions; under LÖVE the interpreter is always LuaJIT, so in practice
    this concerns nobody, and now it is written down.

    HEADLESS: pure Lua; tested over loopback.
]]

local Crypto = require('meatray.net.crypto')

local Sealed = {}

Sealed.MAGIC = '\1'          -- first byte of every sealed frame
Sealed.AAD = 'mrseal1'       -- construction version, bound into every tag

-- One key for the whole session, derived — not the password, and not
-- reversible to it. The domain string means a captured MeatRayCast key can
-- never double as anything else derived from the same password.
function Sealed.deriveKey(password)
    if type(password) ~= 'string' or password == '' then
        return nil, 'a sealed session needs a password to derive its key from'
    end
    return Crypto.sha256('meatray-psk-v1' .. password)
end

-- Wraps `inner`. Returns a transport whose send seals and whose service
-- refuses what does not authenticate.
function Sealed.wrap(inner, key)
    if type(key) ~= 'string' or #key ~= Crypto.KEY_BYTES then
        return nil, 'sealed transport needs a 32-byte key'
    end

    -- NOT `self.key`: a transport already has a key() METHOD, and a data
    -- field of that name would shadow it (an instance field wins over the
    -- __index forward below). The session key lives in an upvalue instead,
    -- reachable by the two methods that need it and by nothing else.
    local sessionKey = key
    local self = {
        inner = inner,
        sealed = 0,          -- frames sealed out
        opened = 0,          -- frames opened in
        refused = 0,         -- frames dropped: no magic, bad tag, bad open
    }

    function self:send(peer, data, channel, reliable)
        local frame, err = Crypto.seal(sessionKey, data, Sealed.AAD)
        if not frame then
            -- The DRBG refused (no OS entropy). Silence, not plaintext:
            -- a sealed session must never quietly downgrade itself.
            return nil, err
        end
        self.sealed = self.sealed + 1
        return inner:send(peer, Sealed.MAGIC .. frame, channel, reliable)
    end

    function self:service()
        while true do
            local event = inner:service()
            if not event then return nil end

            -- Only a RECEIVE carries a sealed payload. connect/disconnect
            -- events carry a numeric code (ENet) or nothing (loopback) — the
            -- discriminator is the TYPE, never the presence of .data, because
            -- an ENet connect's .data is the integer 0, not nil. Getting this
            -- wrong swallows the handshake and the peer never joins.
            if event.type ~= 'receive' or type(event.data) ~= 'string' then
                return event
            end

            if event.data:sub(1, 1) == Sealed.MAGIC then
                local plain = Crypto.open(sessionKey, event.data:sub(2), Sealed.AAD)
                if plain then
                    self.opened = self.opened + 1
                    event.data = plain
                    return event
                end
            end
            -- Unsealed, tampered, or wrong-keyed: not our peer's words.
            self.refused = self.refused + 1
        end
    end

    -- Everything else — listen, connect, disconnect, key, setTimeout,
    -- close, whatever a given transport has — forwards with self remapped.
    -- Data never travels through these, so nothing here needs the key.
    return setmetatable(self, {
        __index = function(_, name)
            local v = inner[name]
            if type(v) == 'function' then
                return function(_, ...) return v(inner, ...) end
            end
            return v
        end,
    })
end

return Sealed
