--[[
    masterserver.registry — the server list, as pure logic.

    No sockets, no HTTP, no JSON, no clock. Requests come in as tables and
    responses go out as tables, and time is advanced by the caller. That is
    deliberate and it is the same trick meatray/net/transport/loopback.lua plays
    on the replication code: a registry whose rules can only be exercised by
    standing up a real server and waiting thirty seconds for an entry to expire
    is a registry whose rules do not get tested.

    Everything awkward about running a public listing service is a rule in here,
    and every one of them is drivable from a test that never sleeps and never
    opens a port:

      * a host does not get to say where it is
      * nothing is listed until something answered at the address claimed
      * an entry that stops saying it is alive stops being listed
      * one machine cannot fill the list on its own

    The socket and HTTP binding lives in masterserver/server.lua and is
    deliberately thin, because everything worth getting right is here.

    HEADLESS: no love, no socket, no os.time. Runs under plain LuaJIT.
]]

local Registry = {}

-- How long after its last heartbeat an entry stays listed. Short on purpose: a
-- stale list is worse than a short one, because from a player's side a server
-- that cannot be joined is indistinguishable from a game that does not work.
Registry.ENTRY_TIMEOUT = 30

-- How long a host has to answer the challenge before its announce is discarded.
-- Generous relative to any real round trip -- an under-tight budget here reads
-- exactly like "your port is closed" to someone whose port is fine.
Registry.CHALLENGE_TIMEOUT = 10

-- Ceilings. Per-address first, because the interesting abuse is one machine
-- filling the browser rather than the total getting large.
Registry.MAX_PER_ADDRESS = 4
Registry.MAX_ENTRIES = 2048

-- Field limits. A name is shown in a browser, so it is length-capped and
-- stripped of control characters; everything else is a number with a range.
Registry.MAX_NAME = 48
Registry.MAX_MAP = 48

local RegistryMT = {}
RegistryMT.__index = RegistryMT

---------------------------------------------------------------------------
-- Construction
---------------------------------------------------------------------------

-- opts:
--   entryTimeout / challengeTimeout / maxPerAddress / maxEntries
--   randomSource  function() -> number in [0,1), injectable so tests are
--                 deterministic and so a deployment can supply something
--                 better than math.random
function Registry.new(opts)
    opts = opts or {}

    return setmetatable({
        entries = {},            -- [key] = entry, key is "ip:port"
        pending = {},            -- [token] = unverified announce
        byToken = {},            -- [token] = key, for heartbeats
        punches = {},            -- [key] = { [clientKey] = expiry }

        entryTimeout     = opts.entryTimeout or Registry.ENTRY_TIMEOUT,
        challengeTimeout = opts.challengeTimeout or Registry.CHALLENGE_TIMEOUT,
        maxPerAddress    = opts.maxPerAddress or Registry.MAX_PER_ADDRESS,
        maxEntries       = opts.maxEntries or Registry.MAX_ENTRIES,

        randomSource = opts.randomSource or math.random,

        -- Seconds since the registry came up. Everything that asks "how long
        -- ago" reads this, so a test drives expiry by assignment rather than by
        -- sleeping for half a minute.
        now = 0,

        stats = {
            announced = 0,
            listed    = 0,       -- announces that passed the challenge
            refused   = 0,       -- rejected before a challenge was issued
            expired   = 0,
            failed    = 0,       -- challenges that were never answered
        },
    }, RegistryMT)
end

---------------------------------------------------------------------------
-- Validation
---------------------------------------------------------------------------

local function cleanText(value, limit)
    if type(value) ~= 'string' then return nil end
    -- Control characters out: this string lands in a server browser, and a
    -- newline or an escape sequence in a name is someone probing whether the
    -- client renders it raw.
    local text = value:gsub('%c', '')
    if #text == 0 then return nil end
    if #text > limit then text = text:sub(1, limit) end
    return text
end

local function wholeInRange(value, low, high)
    if type(value) ~= 'number' then return nil end
    if value ~= math.floor(value) then return nil end
    if value < low or value > high then return nil end
    return value
end

-- Returns a normalised record, or nil plus the reason.
--
-- Note what is NOT read from the payload: the address. A host that could name
-- its own address could name someone else's, and the browser would then point
-- every client that clicked it at a third party. The caller supplies the source
-- address of the request and that is the only address the registry will use.
function Registry.validate(payload)
    if type(payload) ~= 'table' then return nil, 'payload must be a table' end

    local name = cleanText(payload.name, Registry.MAX_NAME)
    if not name then return nil, 'name is required' end

    local map = cleanText(payload.map, Registry.MAX_MAP) or 'unknown'

    local port = wholeInRange(payload.port, 1, 65535)
    if not port then return nil, 'port must be 1..65535' end

    local maxPlayers = wholeInRange(payload.maxPlayers, 1, 1024)
    if not maxPlayers then return nil, 'maxPlayers must be 1..1024' end

    local players = wholeInRange(payload.players, 0, maxPlayers)
    if not players then return nil, 'players must be 0..maxPlayers' end

    local protocol = wholeInRange(payload.protocol, 0, 65535)
    if not protocol then return nil, 'protocol is required' end

    -- Where to send the challenge, if not the game port.
    --
    -- This exists because of a real constraint rather than a preference: the
    -- game port belongs to ENet, which silently discards any datagram that is
    -- not ENet, so a host cannot hear a challenge sent there. The beacon
    -- therefore opens its own UDP socket and names it here.
    --
    -- The cost is stated rather than hidden. Challenging a different port still
    -- proves the announcer controls this ADDRESS, which is the defence that
    -- matters -- nobody can list a stranger's machine. It does NOT prove the
    -- game port is open, so such an entry is marked portVerified = false and a
    -- browser may say so. A host can therefore publish a wrong port, but only
    -- ever on its own address, pointing clients at itself.
    local challengePort = port
    local declared = wholeInRange(payload.challengePort, 1, 65535)
    if declared then challengePort = declared end

    return {
        name = name, map = map, port = port,
        players = players, maxPlayers = maxPlayers,
        protocol = protocol,
        locked = payload.locked and true or false,
        challengePort = challengePort,
        portVerified = (challengePort == port),
    }
end

---------------------------------------------------------------------------
-- Tokens and nonces
---------------------------------------------------------------------------

local HEX = '0123456789abcdef'

function RegistryMT:randomHex(bytes)
    local out = {}
    for i = 1, (bytes or 16) * 2 do
        local n = math.floor(self.randomSource() * 16) + 1
        if n < 1 then n = 1 elseif n > 16 then n = 16 end
        out[i] = HEX:sub(n, n)
    end
    return table.concat(out)
end

local function keyFor(address, port)
    return address .. ':' .. tostring(port)
end

---------------------------------------------------------------------------
-- Announce
---------------------------------------------------------------------------

function RegistryMT:countFor(address)
    local n = 0
    for _, entry in pairs(self.entries) do
        if entry.address == address then n = n + 1 end
    end
    for _, p in pairs(self.pending) do
        if p.address == address then n = n + 1 end
    end
    return n
end

-- A host announces. `address` is the source address of the request, supplied by
-- whatever accepted it -- never by the host.
--
-- Returns { token, nonce, port } for the challenge, or nil plus a reason. The
-- entry is NOT listed yet: the caller must send `nonce` to address:port over UDP
-- and feed the reply back through :challengeReply.
function RegistryMT:announce(address, payload)
    self.stats.announced = self.stats.announced + 1

    if type(address) ~= 'string' or #address == 0 then
        self.stats.refused = self.stats.refused + 1
        return nil, 'no source address'
    end

    local record, err = Registry.validate(payload)
    if not record then
        self.stats.refused = self.stats.refused + 1
        return nil, err
    end

    local key = keyFor(address, record.port)

    -- Re-announcing an address already listed is a refresh, not a new entry, so
    -- a host that restarts does not have to wait out its old listing.
    local existing = self.entries[key]
    if not existing and self:countFor(address) >= self.maxPerAddress then
        self.stats.refused = self.stats.refused + 1
        return nil, 'too many servers from this address'
    end

    local total = 0
    for _ in pairs(self.entries) do total = total + 1 end
    if not existing and total >= self.maxEntries then
        self.stats.refused = self.stats.refused + 1
        return nil, 'registry is full'
    end

    local token = self:randomHex(16)
    local nonce = self:randomHex(8)

    self.pending[token] = {
        address = address,
        key     = key,
        record  = record,
        nonce   = nonce,
        expires = self.now + self.challengeTimeout,
    }

    return { token = token, nonce = nonce, address = address,
             port = record.challengePort, gamePort = record.port }
end

-- The host answered the challenge. `nonce` must match what was sent.
--
-- This is the whole anti-abuse story and it is cheap. Without it the registry
-- lists whatever anyone claims, including an address chosen so that every client
-- who clicks it sends traffic at a stranger.
function RegistryMT:challengeReply(token, nonce)
    local p = self.pending[token]
    if not p then return nil, 'unknown or expired challenge' end

    if nonce ~= p.nonce then
        -- A wrong nonce discards the attempt rather than allowing a retry, so
        -- the challenge cannot be brute-forced by replying repeatedly.
        self.pending[token] = nil
        self.stats.failed = self.stats.failed + 1
        return nil, 'challenge failed'
    end

    self.pending[token] = nil

    local previous = self.entries[p.key]
    if previous and previous.token then self.byToken[previous.token] = nil end

    self.entries[p.key] = {
        address   = p.address,
        port      = p.record.port,
        record    = p.record,
        token     = token,
        listedAt  = previous and previous.listedAt or self.now,
        heardAt   = self.now,
    }
    self.byToken[token] = p.key
    self.stats.listed = self.stats.listed + 1

    return { token = token, expiresIn = self.entryTimeout }
end

-- A listed host says it is still there, and updates what changes: player count,
-- current map, whether it is locked.
--
-- The token proves it is the same host. It cannot move its address or port --
-- those identify the entry, and letting a heartbeat change them would let a
-- host that passed a challenge at one address quietly relist itself at another.
function RegistryMT:heartbeat(token, payload)
    local key = self.byToken[token]
    if not key then return nil, 'unknown token' end

    local entry = self.entries[key]
    if not entry then
        self.byToken[token] = nil
        return nil, 'entry expired, announce again'
    end

    entry.heardAt = self.now

    if type(payload) == 'table' then
        local maxPlayers = wholeInRange(payload.maxPlayers, 1, 1024)
        if maxPlayers then entry.record.maxPlayers = maxPlayers end

        local players = wholeInRange(payload.players, 0, entry.record.maxPlayers)
        if players then entry.record.players = players end

        local map = cleanText(payload.map, Registry.MAX_MAP)
        if map then entry.record.map = map end

        local name = cleanText(payload.name, Registry.MAX_NAME)
        if name then entry.record.name = name end

        if payload.locked ~= nil then entry.record.locked = payload.locked and true or false end
    end

    return { ok = true, expiresIn = self.entryTimeout }
end

function RegistryMT:delist(token)
    local key = self.byToken[token]
    if not key then return false end
    self.entries[key] = nil
    self.byToken[token] = nil
    return true
end

---------------------------------------------------------------------------
-- Time
---------------------------------------------------------------------------

-- Advances the clock and drops what has aged out. Called by the binding on a
-- timer; called directly by tests.
function RegistryMT:update(now)
    self.now = now or self.now

    for key, entry in pairs(self.entries) do
        if self.now - entry.heardAt > self.entryTimeout then
            self.entries[key] = nil
            if entry.token then self.byToken[entry.token] = nil end
            self.stats.expired = self.stats.expired + 1
        end
    end

    for token, p in pairs(self.pending) do
        if self.now > p.expires then
            self.pending[token] = nil
            self.stats.failed = self.stats.failed + 1
        end
    end

    for key, waiting in pairs(self.punches) do
        for clientKey, expires in pairs(waiting) do
            if self.now > expires then waiting[clientKey] = nil end
        end
        if next(waiting) == nil then self.punches[key] = nil end
    end

    return self
end

function RegistryMT:advance(dt)
    return self:update(self.now + (dt or 0))
end

---------------------------------------------------------------------------
-- Listing
---------------------------------------------------------------------------

-- The browsable list. Note what is absent: a ping. A registry-measured ping is
-- the distance from the registry to the host, which is not the number a player
-- cares about, and publishing it invites the client to display someone else's
-- latency as if it were their own. Clients measure their own.
function RegistryMT:list(filter)
    local out = {}

    for _, entry in pairs(self.entries) do
        local r = entry.record
        local keep = true

        if filter then
            if filter.protocol and r.protocol ~= filter.protocol then keep = false end
            if filter.notFull and r.players >= r.maxPlayers then keep = false end
            if filter.notLocked and r.locked then keep = false end
        end

        if keep then
            out[#out + 1] = {
                address = entry.address,
                port    = entry.port,
                name    = r.name,
                map     = r.map,
                players = r.players,
                maxPlayers = r.maxPlayers,
                protocol = r.protocol,
                locked  = r.locked,
                portVerified = r.portVerified,
                age     = self.now - entry.heardAt,
            }
        end
    end

    -- Most recently heard from first, so a list that is partly stale puts the
    -- entries most likely to still be up at the top.
    table.sort(out, function(a, b)
        if a.age ~= b.age then return a.age < b.age end
        return keyFor(a.address, a.port) < keyFor(b.address, b.port)
    end)

    return out
end

function RegistryMT:count()
    local n = 0
    for _ in pairs(self.entries) do n = n + 1 end
    return n
end

function RegistryMT:get(address, port)
    return self.entries[keyFor(address, port)]
end

---------------------------------------------------------------------------
-- Hole punching
--
-- The registry's whole role here is introduction: it tells each side where the
-- other is, both send at once, and each router sees an outbound packet before
-- the inbound one and lets it through. It does not relay and it does not verify
-- that the punch worked -- only the two peers can know that.
---------------------------------------------------------------------------

-- A client asks to be introduced to a listed host. Returns what the client needs
-- and records the request so the host learns about it on its next heartbeat.
function RegistryMT:requestPunch(clientAddress, clientPort, hostAddress, hostPort)
    local key = keyFor(hostAddress, hostPort)
    local entry = self.entries[key]
    if not entry then return nil, 'no such server' end

    if type(clientAddress) ~= 'string' or #clientAddress == 0 then
        return nil, 'no client address'
    end
    if not wholeInRange(clientPort, 1, 65535) then
        return nil, 'client port must be 1..65535'
    end

    self.punches[key] = self.punches[key] or {}
    self.punches[key][keyFor(clientAddress, clientPort)] = self.now + self.challengeTimeout

    return {
        address = entry.address,
        port    = entry.port,
        -- Both sides must send at once, so the client is told to start now
        -- rather than waiting to be told the host is ready. Waiting for
        -- confirmation is what makes a punch fail: whichever side sends second
        -- is the side whose packet arrives at a router that has not opened yet.
        sendNow = true,
    }
end

-- Where a listed host can be reached with a datagram, which is not where the
-- game is: it is the port the challenge was answered on.
--
-- This exists so a punch does not have to wait for the heartbeat that would
-- carry it anyway. Introductions ride back on the heartbeat, heartbeats are ten
-- seconds apart, and a client waiting an average of five seconds for the host to
-- even hear about it has lost the moment -- so the binding sends one datagram
-- here saying "ask now" and the host brings its next heartbeat forward.
--
-- It carries nothing and it is not the introduction. The client list still goes
-- over HTTP on the heartbeat the nudge provoked, so a forged nudge causes one
-- early heartbeat and cannot make a host send packets at an address of the
-- forger's choosing. A lost nudge costs nothing either: the heartbeat that was
-- always going to happen still carries the punch.
function RegistryMT:notifyEndpoint(hostAddress, hostPort)
    local entry = self.entries[keyFor(hostAddress, hostPort)]
    if not entry then return nil end
    return entry.address, entry.record.challengePort
end

-- A host collects the clients waiting to be introduced to it, and forgets them.
-- Returned on the heartbeat response so no extra request is needed.
function RegistryMT:takePunches(token)
    local key = self.byToken[token]
    if not key then return {} end

    local waiting = self.punches[key]
    if not waiting then return {} end

    local out = {}
    for clientKey in pairs(waiting) do
        local address, port = clientKey:match('^(.*):(%d+)$')
        if address then
            out[#out + 1] = { address = address, port = tonumber(port) }
        end
    end
    self.punches[key] = nil

    table.sort(out, function(a, b)
        if a.address ~= b.address then return a.address < b.address end
        return a.port < b.port
    end)

    return out
end

Registry.RegistryMT = RegistryMT

return Registry
