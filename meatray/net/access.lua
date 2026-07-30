--[[
    meatray.net.access — who is allowed in, and who gets thrown out.

    Three levels, because a LAN co-op session and a public server have opposite
    correct defaults and an engine that picks one is wrong half the time:

      open       anything with the address gets in. The default.
      password   a shared secret. Enough for a private game, and it needs no
                 accounts, no database and no service to be running.
      identity   a hook, not an implementation. `onAuthenticate(peer, credentials)`
                 is called with whatever the client sent and the game answers.
                 Signed tokens, a Steam ticket, an allow-list read off disk — all
                 of those are the game's business, and building an auth service
                 into an engine is how you end up maintaining an auth service.

    Plus kick and ban-by-address, which need no identity system at all and which
    solve the actual common problem: one person ruining a session for five.

    A note on what a ban is worth. An address ban is defeated by a router reboot,
    and pretending otherwise would be dishonest. It is still the right primitive
    to ship, because it stops the person currently being a problem right now, and
    because the alternative — persistent identity — is exactly the subsystem the
    hook above exists to defer.

    HEADLESS: no LOVE, no sockets, no clock. Pure decisions, so the tests are
    plain function calls.
]]

local Transport = require('meatray.net.transport')

local Access = {}

local AccessMT = {}
AccessMT.__index = AccessMT

-- Rejection reasons are stable strings, not sentences, because a client shows
-- them to a player and a test asserts on them.
Access.BANNED     = 'banned'
Access.PASSWORD   = 'wrong password'
Access.NEEDS_PASSWORD = 'password required'
Access.FULL       = 'server is full'
Access.REFUSED    = 'refused'
Access.VERSION    = 'protocol version mismatch'

function Access.new(opts)
    opts = opts or {}

    return setmetatable({
        password       = opts.password,
        onAuthenticate = opts.onAuthenticate,
        maxPlayers     = opts.maxPlayers or 8,
        bans           = {},          -- [ip] = reason
    }, AccessMT)
end

function AccessMT:locked()
    return (self.password ~= nil and self.password ~= '') or self.onAuthenticate ~= nil
end

---------------------------------------------------------------------------
-- Bans
---------------------------------------------------------------------------

-- Takes either 'host:port' or a bare host, and always stores the host: a ban
-- pinned to a port would expire the moment the peer reconnected.
function Access.ipOf(address)
    if type(address) ~= 'string' then return nil end
    local host = Transport.parseAddress(address, 0)
    return host
end

function AccessMT:ban(address, reason)
    local ip = Access.ipOf(address)
    if not ip then return false, 'no address to ban' end
    self.bans[ip] = reason or Access.BANNED
    return true, ip
end

function AccessMT:unban(address)
    local ip = Access.ipOf(address)
    if not ip or not self.bans[ip] then return false end
    self.bans[ip] = nil
    return true
end

function AccessMT:isBanned(address)
    local ip = Access.ipOf(address)
    if not ip then return false end
    return self.bans[ip] ~= nil, self.bans[ip]
end

function AccessMT:banned()
    local out = {}
    for ip, reason in pairs(self.bans) do out[#out + 1] = { ip = ip, reason = reason } end
    table.sort(out, function(a, b) return a.ip < b.ip end)
    return out
end

---------------------------------------------------------------------------
-- Admission
---------------------------------------------------------------------------

-- `request` is { address, credentials, password, name, version }, `context` is
-- { players, version }. Returns ok plus a reason on refusal.
--
-- Order matters and is deliberate: a banned address is refused before the
-- password is even compared, so a ban cannot be probed for the password, and the
-- game's hook runs last so it sees only requests that already passed the cheap
-- checks.
function AccessMT:admit(request, context)
    request = request or {}
    context = context or {}

    local banned, why = self:isBanned(request.address)
    if banned then return false, Access.BANNED, why end

    if context.version and request.version and context.version ~= request.version then
        return false, Access.VERSION,
               ('server speaks protocol %d, client speaks %s')
               :format(context.version, tostring(request.version))
    end

    if (context.players or 0) >= self.maxPlayers then
        return false, Access.FULL
    end

    if self.password and self.password ~= '' then
        if request.password == nil or request.password == '' then
            return false, Access.NEEDS_PASSWORD
        end
        if request.password ~= self.password then
            return false, Access.PASSWORD
        end
    end

    if self.onAuthenticate then
        -- Wrapped: a game's auth hook is game code, and a crash in it must refuse
        -- the join rather than take the server down with it.
        local ok, allowed, reason = pcall(self.onAuthenticate, request, context)
        if not ok then
            return false, Access.REFUSED, 'onAuthenticate errored: ' .. tostring(allowed)
        end
        if allowed == false then
            return false, reason or Access.REFUSED
        end
    end

    return true
end

return Access
