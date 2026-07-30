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

---------------------------------------------------------------------------
-- Flood control, in two tiers that must never be merged
---------------------------------------------------------------------------

--[[
    There are two kinds of "too many messages" and treating them as one kind is
    how a server bans its own players.

      * A **semantic command** — a join, a chat line, a fire — is something a
        person did. Fifty a second is not a person, so it is worth a penalty, and
        a penalty that escalates is what stops a bot that ignores the first one.

      * An **input stream** is not something a person did; it is the client's
        send rate. It is *supposed* to arrive dozens of times a second, and a
        machine under load or on a jittery link will bunch several into one
        frame. Run that through the penalising limiter and a burst of legitimate
        packets earns an escalating mute, then a ban, and the player is thrown
        out of the game for having a laggy connection.

    So: `Access.window` penalises and `Access.throttle` does not. The throttle
    drops the excess silently, records nothing against the sender, and can never
    be the reason anyone is muted or banned. Two objects, because one object with
    a flag is one refactor away from being one object without a flag.

    `check(key, now, skipViolation)` also takes the escape hatch directly, for
    the case where a *semantic* endpoint has a legitimate burst — the caller gets
    the refusal without the strike.

    Both are pure: the caller passes the clock, so a test can drive an hour of
    traffic without waiting an hour, and neither reaches for os.time.
]]

---------------------------------------------------------------------------
-- Tier 1: the silent throttle. No penalty, no memory, no ban.
---------------------------------------------------------------------------

local ThrottleMT = {}
ThrottleMT.__index = ThrottleMT

-- `interval` is the minimum spacing between two accepted messages from one key.
-- It must sit *above* the rate a legitimate client sends at, not at it: the point
-- is to bound what an abusive peer can cost, not to police a normal one.
function Access.throttle(opts)
    opts = opts or {}
    return setmetatable({
        interval = opts.interval or (1 / 120),
        last     = {},
        passed   = 0,
        skipped  = 0,
    }, ThrottleMT)
end

function ThrottleMT:allow(key, now)
    now = now or 0
    local last = self.last[key]
    if last and (now - last) < self.interval then
        self.skipped = self.skipped + 1
        return false
    end
    self.last[key] = now
    self.passed = self.passed + 1
    return true
end

function ThrottleMT:forget(key) self.last[key] = nil end

---------------------------------------------------------------------------
-- Tier 2: the penalising sliding window, with escalating backoff.
---------------------------------------------------------------------------

local WindowMT = {}
WindowMT.__index = WindowMT

-- opts:
--   limit       messages allowed inside the window          (default 20)
--   per         window length in seconds                    (default 10)
--   penalty     seconds muted on the first violation        (default 5)
--   escalate    multiplier applied per further violation    (default 2)
--   maxPenalty  ceiling on the backoff, in seconds          (default 300)
--   banAfter    violations before `check` asks for a ban    (default nil = never)
--
-- `banAfter` defaults to nil on purpose. Whether flooding is worth a ban is a
-- policy decision, and an engine that bans by default bans somebody's friend on
-- a bad hotel connection.
function Access.window(opts)
    opts = opts or {}
    return setmetatable({
        limit      = opts.limit or 20,
        per        = opts.per or 10,
        penalty    = opts.penalty or 5,
        escalate   = opts.escalate or 2,
        maxPenalty = opts.maxPenalty or 300,
        banAfter   = opts.banAfter,
        entries    = {},
        allowed    = 0,
        refused    = 0,
    }, WindowMT)
end

function WindowMT:entry(key)
    local e = self.entries[key]
    if not e then
        e = { stamps = {}, violations = 0, mutedUntil = 0 }
        self.entries[key] = e
    end
    return e
end

-- Returns ok, reason, retryAfter, violations, wantsBan.
--
-- `skipViolation` refuses without recording a strike — for a caller that knows a
-- burst is legitimate but still wants it shaped.
function WindowMT:check(key, now, skipViolation)
    now = now or 0
    local e = self:entry(key)

    if now < e.mutedUntil then
        self.refused = self.refused + 1
        return false, 'rate limited', e.mutedUntil - now, e.violations, false
    end

    local stamps, keep = e.stamps, {}
    for i = 1, #stamps do
        if (now - stamps[i]) < self.per then keep[#keep + 1] = stamps[i] end
    end
    e.stamps = keep

    if #keep < self.limit then
        keep[#keep + 1] = now
        self.allowed = self.allowed + 1
        return true
    end

    self.refused = self.refused + 1

    if skipViolation then
        return false, 'rate limited', self.per, e.violations, false
    end

    e.violations = e.violations + 1
    local backoff = math.min(self.penalty * (self.escalate ^ (e.violations - 1)),
                             self.maxPenalty)
    e.mutedUntil = now + backoff
    -- The window is cleared along with the mute, so the peer starts the next
    -- window clean rather than violating again on its first message back.
    e.stamps = {}

    local wantsBan = self.banAfter ~= nil and e.violations >= self.banAfter
    return false, 'rate limited', backoff, e.violations, wantsBan
end

function WindowMT:violations(key)
    local e = self.entries[key]
    return e and e.violations or 0
end

function WindowMT:mutedFor(key, now)
    local e = self.entries[key]
    if not e then return 0 end
    local left = e.mutedUntil - (now or 0)
    return left > 0 and left or 0
end

function WindowMT:forget(key) self.entries[key] = nil end

Access.ThrottleMT = ThrottleMT
Access.WindowMT   = WindowMT

return Access
