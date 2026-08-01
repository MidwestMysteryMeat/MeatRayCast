--[[
    masterserver.relay — forwarding for the hosts a punch cannot reach, as pure
    logic.

    No sockets, no ENet, no clock. Links arrive as opaque keys, frames arrive as
    strings, and everything the relay wants done comes back as a list of actions
    for somebody else to execute. That is the same split masterserver/registry.lua
    uses and for the same reason: the interesting cases here are "a session that
    stopped talking two minutes ago", "a stranger guessing session ids" and "a
    host that just went over its byte budget", and none of them is worth testing
    if testing it means standing up a relay and waiting.

    The socket binding is masterserver/relayhost.lua and is deliberately thin.

    ## Why a relay exists at all

    Measured direct-connect success is 55-80%, not the 90% that gets quoted --
    libp2p's headline 70% is a per-network mean conditional on reaching the punch
    stage, pooled conditional is 57%, and end-to-end is 40%. So this is load
    bearing for something like a fifth to a half of hosts. See the success-rate
    section of docs/MASTERSERVER.md, which has the sources.

    ## The four things a relay must not become

    **An open proxy.** Every forward's destination comes out of the session
    table, and the session table only ever contains links that connected *to this
    relay* and passed a control handshake. No field of any frame ever names a
    destination. There is no input to this module that can make it send a packet
    to an address of the sender's choosing -- which is the property that a relay
    forwarding "whatever arrives" does not have.

    **An amplifier.** Unicast forwarding is one frame in, one frame out, minus
    nothing and plus nothing. Broadcast is one frame in and N out, so the byte
    budget is charged on **egress**: a broadcast to six clients costs six times
    its size against the session's bucket. The fan-out is bounded by the number
    of slots that voluntarily joined this session, and each of those completed an
    ENet handshake -- which is a round trip, so their source addresses are real.
    A frame from a link with no session is dropped in silence and answered with
    nothing at all; an error reply would itself be a small reflector and an
    oracle for guessing session ids.

    **Free.** Caps first and per-address before global, exactly as the registry
    does: the interesting abuse is one machine taking the whole relay, not the
    total getting large. Sessions expire on silence. Byte budgets are token
    buckets, per session and for the relay as a whole, and the defaults are
    derived from the engine's real snapshot rate rather than picked -- see
    SESSION_BYTES_PER_SEC below, which shows its working.

    **A way to hang.** Nothing in here waits. Every refusal is an answer, every
    timeout produces a close with a reason, and a relay that dies takes its links
    down as disconnects that both ends already know how to handle.

    ## What a relay operator can see

    Everything. ENet has no encryption and neither does this engine's protocol,
    so a relay operator can read and modify the traffic of any session running
    through their machine. That is stated here rather than buried: it is the
    reason the reference relay is something you run yourself, and the reason a
    ticket is a capability to occupy a slot rather than an identity. A player who
    would not hand their session to a stranger should use a relay they or their
    community runs. The fix is an end-to-end encrypted transport, which this is
    not and does not pretend to be.

    HEADLESS: no love, no socket, no os.time. Runs under plain LuaJIT.
]]

local Wire = require('meatray.net.relaywire')

local Relay = {}

---------------------------------------------------------------------------
-- Ceilings
---------------------------------------------------------------------------

-- Per-address before global, because one machine filling the relay is the abuse
-- that matters and the total getting large is merely success. Tighter than the
-- registry's four-per-address: a listing costs a table row, a relayed session
-- costs bandwidth for as long as it lives.
Relay.MAX_PER_ADDRESS = 2

-- A reference relay, not a service. Sixteen sessions at the per-session budget
-- below is already more than the default relay-wide budget allows to run flat
-- out, which is the intended shape: the byte budget binds before the slot count.
Relay.MAX_SESSIONS = 16

-- Clients per session. The engine's default maxPlayers is 8.
Relay.MAX_SLOTS = 8

-- Connections the relay will hold at once, bound or not.
Relay.MAX_LINKS = 64

-- Silence, on every link of a session together, before the session is torn down.
-- Generous: the transport sends a keepalive every 20 seconds when a session is
-- otherwise idle, so this is six missed keepalives. An under-tight budget here
-- would drop a lobby that is sitting in a menu waiting for a friend, which is
-- precisely the session a relay exists to hold open.
Relay.SESSION_TIMEOUT = 120

-- A connection that has neither opened nor joined a session. Ten seconds is
-- generous against any real dial and tight against squatting on link slots.
Relay.LINK_TIMEOUT = 10

-- Wrong session id and wrong secret are the same answer (see NO_SESSION), so
-- guessing costs a connection. Three tries and the connection goes.
Relay.MAX_JOIN_ATTEMPTS = 3

-- Bytes the relay may EMIT on behalf of one session, per second, summed over
-- both directions. Derived rather than chosen:
--
--   downstream, per client   20 snapshots/s x 1365 B  = 27,300 B/s
--                            (snapshotRate 20 is the host's default; 1364 is
--                            P.MTU_SAFE_BYTES, the cap the codec is built to,
--                            plus the one-byte relay header)
--   upstream, per client     30 inputs/s x ~80 B      =  2,400 B/s
--                            (inputRate 30 is the client's default; P.limits
--                            caps an input at 512 B and a real one is ~60)
--   relay egress, per client 27,300 + 2,400           = 29,700 B/s
--   a full 8-slot session    8 x 29,700               = 237,600 B/s
--
-- 256 KiB/s = 262,144 B/s, about 10% over a session running flat out at every
-- one of the engine's own ceilings simultaneously, which no real session does.
-- A game that raises snapshotRate or entity count past those ceilings must raise
-- this too, and will see the throttle counter say so rather than guessing.
Relay.SESSION_BYTES_PER_SEC = 256 * 1024

-- Two seconds of burst. A snapshot stream is bursty by nature -- the host sends
-- every peer's copy in one frame of work -- and a bucket with no burst would
-- throttle a session that is inside its average.
Relay.SESSION_BURST_BYTES = 512 * 1024

-- And for the relay as a whole. 1 MiB/s sustained is 86 GB a day and 2.6 TB a
-- month, which is at or over the included transfer on most small VPS plans. That
-- number is the reason this default is not higher: an operator raising it should
-- do so having read this line, not discover it on an invoice.
Relay.TOTAL_BYTES_PER_SEC = 1024 * 1024
Relay.TOTAL_BURST_BYTES   = 2 * 1024 * 1024

-- Reliable frames are never dropped for budget -- dropping one breaks the
-- end-to-end reliable contract in a way neither peer can detect or repair, since
-- the sending hop already acknowledged it. They are forwarded and the bucket
-- goes negative instead, which throttles the unreliable stream first and counts
-- the debt. Past this many overruns the session is closed with a stated reason,
-- because a session that can only stay inside its budget by running a permanent
-- deficit is a session the operator is paying for twice.
Relay.OVERRUN_LIMIT = 64

-- Nothing legitimate is bigger. ENet's own MTU tops out well under this, and a
-- larger frame is either a bug or an attempt to make the relay allocate.
Relay.MAX_FRAME_BYTES = 1500

-- One string for "no such session" and for "wrong secret", deliberately. Two
-- strings would make the relay an oracle: an attacker could sweep the 32-bit
-- session space cheaply and only then start on the 128-bit secret. One string
-- means a wrong guess of either kind is indistinguishable and both cost a
-- connection.
Relay.NO_SESSION = 'no such relay session'

local RelayMT = {}
RelayMT.__index = RelayMT

---------------------------------------------------------------------------
-- Construction
---------------------------------------------------------------------------

-- opts:
--   maxSessions / maxPerAddress / maxSlots / maxLinks
--   sessionTimeout / linkTimeout / maxJoinAttempts
--   sessionBytesPerSec / sessionBurstBytes
--   totalBytesPerSec / totalBurstBytes
--   overrunLimit / maxFrameBytes
--   allocationSecret  when set, a host must present it to open a session at all.
--                     The whole answer for "I want a relay for my community and
--                     not for the internet", in one config string. It travels as
--                     a field of a control line, so it must contain no spaces.
--   randomSource      function() -> [0,1). Injectable so tests are deterministic.
--                     Leave it unset: unset means session secrets come from the
--                     OS CSPRNG.
function Relay.new(opts)
    opts = opts or {}

    local total = {
        rate   = opts.totalBytesPerSec or Relay.TOTAL_BYTES_PER_SEC,
        burst  = opts.totalBurstBytes  or Relay.TOTAL_BURST_BYTES,
    }
    total.tokens = total.burst

    return setmetatable({
        sessions   = {},    -- [id] = session
        links      = {},    -- [key] = link
        perAddress = {},    -- [address] = number of sessions opened from it

        maxSessions     = opts.maxSessions     or Relay.MAX_SESSIONS,
        maxPerAddress   = opts.maxPerAddress   or Relay.MAX_PER_ADDRESS,
        maxSlots        = opts.maxSlots        or Relay.MAX_SLOTS,
        maxLinks        = opts.maxLinks        or Relay.MAX_LINKS,
        sessionTimeout  = opts.sessionTimeout  or Relay.SESSION_TIMEOUT,
        linkTimeout     = opts.linkTimeout     or Relay.LINK_TIMEOUT,
        maxJoinAttempts = opts.maxJoinAttempts or Relay.MAX_JOIN_ATTEMPTS,
        overrunLimit    = opts.overrunLimit    or Relay.OVERRUN_LIMIT,
        maxFrameBytes   = opts.maxFrameBytes   or Relay.MAX_FRAME_BYTES,

        sessionRate  = opts.sessionBytesPerSec or Relay.SESSION_BYTES_PER_SEC,
        sessionBurst = opts.sessionBurstBytes  or Relay.SESSION_BURST_BYTES,
        total        = total,

        allocationSecret = opts.allocationSecret,
        -- No math.random default: unset routes randomHex to the OS CSPRNG.
        randomSource     = opts.randomSource,

        -- Seconds since the relay came up. Everything that asks "how long ago"
        -- reads this, so a test drives expiry by assignment.
        now = 0,

        stats = {
            opened      = 0,
            joined      = 0,
            refused     = 0,
            expired     = 0,
            forwarded   = 0,   -- frames forwarded
            bytesIn     = 0,
            bytesOut    = 0,   -- what the relay is actually paying for
            dropped     = 0,   -- unbound, malformed or oversized frames
            throttled   = 0,   -- unreliable frames dropped for budget
            overruns    = 0,   -- reliable frames forwarded past the budget
            closedQuota = 0,
        },
    }, RelayMT)
end

---------------------------------------------------------------------------
-- Ids
---------------------------------------------------------------------------

local HEX = '0123456789abcdef'

-- Loaded lazily and defensively: the master server is otherwise standalone, and
-- a missing module should say so rather than fall back to something weaker.
local cryptoOk, Crypto = pcall(require, 'meatray.net.crypto')

-- A session secret is what authorises a slot on this relay. It used to be drawn
-- from math.random, which relayserver/main.lua seeded with os.time() -- so the
-- secret was a function of the second the process started and could be guessed
-- offline by anyone who knew roughly when that was. Deployments now take bytes
-- from the OS CSPRNG; randomSource stays injectable so tests keep their fixed
-- sequences.
function RelayMT:randomHex(bytes)
    if self.randomSource then
        local out = {}
        for i = 1, (bytes or 16) * 2 do
            local n = math.floor(self.randomSource() * 16) + 1
            if n < 1 then n = 1 elseif n > 16 then n = 16 end
            out[i] = HEX:sub(n, n)
        end
        return table.concat(out)
    end

    if not cryptoOk then
        error('relay: meatray.net.crypto is required for session secrets', 0)
    end
    local hex, why = Crypto.randomHex(bytes or 16)
    if not hex then
        -- Raised, not returned. A nil here would become a session with no
        -- secret, which is an authorisation bypass rather than a failed call.
        error('relay: no OS entropy for session secrets: ' .. tostring(why), 0)
    end
    return hex
end

-- A session id must be unique among live sessions; a collision would hand one
-- host's clients to another. Retried rather than assumed, because an injected
-- random source in a test is allowed to be terrible and a deployment's may be
-- worse than it looks.
function RelayMT:freshId()
    for _ = 1, 32 do
        local id = self:randomHex(4)
        if not self.sessions[id] then return id end
    end
    return nil
end

---------------------------------------------------------------------------
-- Token buckets
---------------------------------------------------------------------------

local function refill(bucket, now, rate, burst)
    local elapsed = now - (bucket.at or now)
    if elapsed > 0 then
        bucket.tokens = math.min(burst, (bucket.tokens or burst) + elapsed * rate)
    end
    bucket.at = now
end

-- Charges `bytes` of EGRESS against a session's budget and the relay's.
--
-- Returns true when the frame should be forwarded. Unreliable frames that do not
-- fit are refused; reliable ones are forwarded on credit and the debt is
-- recorded, because a dropped reliable frame is a hole in a stream that neither
-- peer can see or repair.
function RelayMT:spend(session, bytes, reliable)
    refill(session.bucket, self.now, self.sessionRate, self.sessionBurst)
    refill(self.total, self.now, self.total.rate, self.total.burst)

    local fits = session.bucket.tokens >= bytes and self.total.tokens >= bytes

    if fits then
        session.bucket.tokens = session.bucket.tokens - bytes
        self.total.tokens = self.total.tokens - bytes
        return true
    end

    if not reliable then
        self.stats.throttled = self.stats.throttled + 1
        session.throttled = (session.throttled or 0) + 1
        return false
    end

    session.bucket.tokens = session.bucket.tokens - bytes
    self.total.tokens = self.total.tokens - bytes
    session.overruns = (session.overruns or 0) + 1
    self.stats.overruns = self.stats.overruns + 1
    return true
end

---------------------------------------------------------------------------
-- Actions
--
-- The only two things this module ever asks for. The binding executes them and
-- nothing else, which is what keeps every rule above testable without a socket.
---------------------------------------------------------------------------

local function send(actions, key, text, channel, reliable)
    actions[#actions + 1] = {
        to = key, data = text,
        channel = channel or 0,
        reliable = reliable ~= false,
    }
    return actions
end

local function control(actions, key, text)
    return send(actions, key, Wire.control(text), 0, true)
end

-- A close carries a reason and removes the link here and now, so the binding
-- never has to call back in and no follow-up action can arrive for a link that
-- is already gone. Recursion between "close this" and "and therefore close
-- that" is how a teardown path acquires a loop.
local function closeAction(actions, key, reason)
    actions[#actions + 1] = { close = key, reason = Wire.reason(reason) }
    return actions
end

---------------------------------------------------------------------------
-- Links
---------------------------------------------------------------------------

function RelayMT:linkCount()
    local n = 0
    for _ in pairs(self.links) do n = n + 1 end
    return n
end

function RelayMT:sessionCount()
    local n = 0
    for _ in pairs(self.sessions) do n = n + 1 end
    return n
end

-- A connection reached the relay. It has no session yet and may not send data.
function RelayMT:link(key, address)
    if type(key) ~= 'string' or key == '' then return nil, 'a link needs a key' end
    if self.links[key] then return nil, 'duplicate link' end

    if self:linkCount() >= self.maxLinks then
        self.stats.refused = self.stats.refused + 1
        return nil, 'relay is full'
    end

    self.links[key] = {
        key      = key,
        address  = (type(address) == 'string' and address ~= '') and address or 'unknown',
        openedAt = self.now,
        seenAt   = self.now,
        attempts = 0,
    }

    return true
end

-- Detaches a link from whatever it was bound to and returns the actions that
-- follow. Used by :unlink (the transport told us it went) and by every close
-- path in here, so there is exactly one place that knows what a departure means.
function RelayMT:detach(key, reason, actions)
    actions = actions or {}

    local link = self.links[key]
    if not link then return actions end
    self.links[key] = nil

    local session = link.session and self.sessions[link.session]
    if not session then return actions end

    if link.role == 'host' then
        -- The host is the session. Every client on it is told why and dropped;
        -- keeping them connected to a relay with nothing on the other end would
        -- be a lobby that looks alive and is not.
        for slot, clientKey in pairs(session.slots) do
            session.slots[slot] = nil
            local client = self.links[clientKey]
            if client then
                self.links[clientKey] = nil
                control(actions, clientKey, 'closed ' .. Wire.reason(reason))
                closeAction(actions, clientKey, reason)
            end
        end

        self.sessions[session.id] = nil
        local count = (self.perAddress[session.address] or 1) - 1
        self.perAddress[session.address] = count > 0 and count or nil

    elseif link.role == 'client' and link.slot then
        session.slots[link.slot] = nil
        if session.hostLink and self.links[session.hostLink] then
            control(actions, session.hostLink,
                    ('gone %d %s'):format(link.slot, Wire.reason(reason)))
        end
    end

    return actions
end

-- The reason travels to the OTHER end, so it is worded from there. "disconnected"
-- reads as a statement about the reader when it is a statement about their peer.
function RelayMT:unlink(key)
    return self:detach(key, 'the connection was lost', {})
end

---------------------------------------------------------------------------
-- Control verbs
---------------------------------------------------------------------------

local function refuse(self, actions, link, reason)
    self.stats.refused = self.stats.refused + 1
    return control(actions, link.key, 'refused ' .. Wire.reason(reason))
end

-- open <version> [<allocation secret>]
function RelayMT:open(link, rest, actions)
    local version, secret = rest:match('^(%S+)%s*(%S*)$')

    if link.role then
        return refuse(self, actions, link, 'this connection already has a session')
    end

    if tonumber(version) ~= Wire.VERSION then
        return refuse(self, actions, link,
                      ('this relay speaks relay protocol %d'):format(Wire.VERSION))
    end

    -- A private relay. Checked before the caps so that a stranger cannot learn
    -- how full a relay they may not use is.
    if self.allocationSecret and secret ~= self.allocationSecret then
        return refuse(self, actions, link, 'this relay is private')
    end

    if (self.perAddress[link.address] or 0) >= self.maxPerAddress then
        return refuse(self, actions, link, 'too many relay sessions from this address')
    end

    if self:sessionCount() >= self.maxSessions then
        return refuse(self, actions, link, 'relay is full')
    end

    local id = self:freshId()
    if not id then return refuse(self, actions, link, 'relay is full') end

    local session = {
        id       = id,
        secret   = self:randomHex(16),
        hostLink = link.key,
        address  = link.address,
        slots    = {},
        maxSlots = self.maxSlots,
        openedAt = self.now,
        heardAt  = self.now,
        bucket   = { tokens = self.sessionBurst, at = self.now },
        overruns = 0,
    }

    self.sessions[id] = session
    self.perAddress[link.address] = (self.perAddress[link.address] or 0) + 1

    link.role = 'host'
    link.session = id
    self.stats.opened = self.stats.opened + 1

    return control(actions, link.key,
                   ('opened %s %s %d'):format(id, session.secret, session.maxSlots))
end

-- join <version> <session> <secret>
function RelayMT:join(link, rest, actions)
    if link.role then
        return refuse(self, actions, link, 'this connection already has a session')
    end

    link.attempts = link.attempts + 1
    if link.attempts > self.maxJoinAttempts then
        self.stats.refused = self.stats.refused + 1
        control(actions, link.key, 'refused too many attempts')
        self:detach(link.key, 'too many join attempts', actions)
        return closeAction(actions, link.key, 'too many join attempts')
    end

    local version, id, secret = rest:match('^(%S+)%s+(%S+)%s+(%S+)$')

    if tonumber(version) ~= Wire.VERSION then
        return refuse(self, actions, link,
                      ('this relay speaks relay protocol %d'):format(Wire.VERSION))
    end

    -- One answer for a bad id and for a bad secret. See Relay.NO_SESSION.
    local session = Wire.isHex(id) and self.sessions[id] or nil
    if not session or session.secret ~= secret then
        return refuse(self, actions, link, Relay.NO_SESSION)
    end

    local slot
    for i = 0, session.maxSlots - 1 do
        if not session.slots[i] then
            slot = i
            break
        end
    end
    if not slot then
        return refuse(self, actions, link, 'this relay session is full')
    end

    session.slots[slot] = link.key
    session.heardAt = self.now
    link.role = 'client'
    link.session = session.id
    link.slot = slot
    self.stats.joined = self.stats.joined + 1

    control(actions, link.key, ('joined %s %d'):format(session.id, slot))

    -- The host is told the client's REAL address, not the relay's. That is what
    -- makes ban-by-address keep working through a relay: the host bans the
    -- player, not the machine forwarding for them. Getting this wrong would mean
    -- one ban removing everybody on the relay.
    return control(actions, session.hostLink,
                   ('peer %d %s'):format(slot, link.address))
end

-- drop <slot> <reason> -- the host kicking one of its own clients. The reason is
-- the tail of the line and may contain spaces, which is why the split here is a
-- pattern per verb rather than one generic tokeniser: a generic one would turn
-- "closed by the host" into three fields and hand the reader a table.concat.
function RelayMT:drop(link, rest, actions)
    if link.role ~= 'host' then return actions end

    local session = self.sessions[link.session]
    if not session then return actions end

    local slotText, reason = rest:match('^(%d+)%s*(.*)$')
    local slot = tonumber(slotText)
    if not slot then return actions end

    local clientKey = session.slots[slot]
    if not clientKey then return actions end

    if reason == '' then reason = 'closed by the host' end
    control(actions, clientKey, 'closed ' .. Wire.reason(reason))
    self:detach(clientKey, reason, actions)
    return closeAction(actions, clientKey, reason)
end

-- Named `handleControl` and not `control`, because `control` is already the
-- local that builds a control action and a method of the same name reads as one.
function RelayMT:handleControl(link, text, actions)
    local verb, rest = text:match('^(%S+)%s*(.*)$')

    if verb == 'open'  then return self:open(link, rest, actions) end
    if verb == 'join'  then return self:join(link, rest, actions) end
    if verb == 'drop'  then return self:drop(link, rest, actions) end

    if verb == 'leave' then
        -- Worded for whoever is told, which is never the sender: a host's
        -- goodbye reaches its clients and a client's reaches its host.
        local reason = (link.role == 'host') and 'the host left' or 'left'
        self:detach(link.key, reason, actions)
        return closeAction(actions, link.key, reason)
    end

    if verb == 'ping' then return control(actions, link.key, 'pong') end
    if verb == 'pong' then return actions end

    -- An unknown verb gets no answer at all. Answering would make the relay a
    -- reflector for anything that can complete a handshake with it, and would
    -- tell a prober which verbs exist.
    self.stats.dropped = self.stats.dropped + 1
    return actions
end

---------------------------------------------------------------------------
-- Forwarding
---------------------------------------------------------------------------

-- The only two destinations that exist. `session.hostLink` and `session.slots`
-- are the entire address book, and both were filled in by a connection that
-- reached this relay and passed a handshake. Nothing a frame contains can add an
-- entry to either -- which is the whole of "this is not an open proxy".
function RelayMT:forwardFromClient(link, payload, channel, reliable, actions)
    local session = self.sessions[link.session]
    if not session then return actions end

    local hostKey = session.hostLink
    if not hostKey or not self.links[hostKey] then return actions end

    local frame = Wire.data(link.slot, payload, reliable)
    if not frame then return actions end

    if not self:spend(session, #frame, reliable) then return actions end

    self.stats.forwarded = self.stats.forwarded + 1
    self.stats.bytesOut = self.stats.bytesOut + #frame
    return send(actions, hostKey, frame, channel, reliable)
end

function RelayMT:forwardFromHost(link, slot, payload, channel, reliable, actions)
    local session = self.sessions[link.session]
    if not session then return actions end

    local clientKey = session.slots[slot]
    if not clientKey or not self.links[clientKey] then return actions end

    -- Slot 0 on the client's side of the wire, always: a client has exactly one
    -- peer and never needs to be told which.
    local frame = Wire.data(0, payload, reliable)
    if not frame then return actions end

    if not self:spend(session, #frame, reliable) then return actions end

    self.stats.forwarded = self.stats.forwarded + 1
    self.stats.bytesOut = self.stats.bytesOut + #frame
    return send(actions, clientKey, frame, channel, reliable)
end

-- One frame in, N out -- the only place in the relay where that is true, and
-- therefore the only place amplification could live. It is charged at N times
-- its size, so the budget is a budget on what the relay emits rather than on
-- what it is asked to emit. The fan-out is bounded by the slots that joined this
-- session, every one of which completed a handshake from a real address.
function RelayMT:broadcastFromHost(link, payload, channel, reliable, actions)
    local session = self.sessions[link.session]
    if not session then return actions end

    local frame = Wire.data(0, payload, reliable)
    if not frame then return actions end

    local targets = {}
    for _, clientKey in pairs(session.slots) do
        if self.links[clientKey] then targets[#targets + 1] = clientKey end
    end
    if #targets == 0 then return actions end

    if not self:spend(session, #frame * #targets, reliable) then return actions end

    for _, clientKey in ipairs(targets) do
        self.stats.forwarded = self.stats.forwarded + 1
        self.stats.bytesOut = self.stats.bytesOut + #frame
        send(actions, clientKey, frame, channel, reliable)
    end

    return actions
end

---------------------------------------------------------------------------
-- Receiving
---------------------------------------------------------------------------

-- A frame arrived on a link. Returns the actions that follow, always a list and
-- never nil, so the binding needs no special case for "nothing to do".
--
-- `channel` is passed through untouched; the relay has no opinion about what a
-- channel means and reading one would be the relay knowing about the game.
-- Reliability comes out of the frame's own header rather than from the binding,
-- because lua-enet's receive event does not report the flag a packet was sent
-- with -- see meatray/net/relaywire.lua for what guessing it would cost.
function RelayMT:receive(key, frame, channel)
    local actions = {}

    local link = self.links[key]
    if not link then
        -- A frame from a link the relay does not know is a bug in the binding or
        -- a connection it already tore down. Closed rather than answered.
        return closeAction(actions, key, 'unknown link')
    end

    link.seenAt = self.now

    -- Anything at all from a link of this session counts as the session being
    -- alive, including a keepalive control frame. Counting only data frames
    -- would tear down a lobby sitting in a menu exactly when the keepalive was
    -- doing its job, which is the one case the keepalive exists for.
    local ownSession = link.session and self.sessions[link.session]
    if ownSession then ownSession.heardAt = self.now end

    if type(frame) ~= 'string' or #frame == 0 or #frame > self.maxFrameBytes then
        self.stats.dropped = self.stats.dropped + 1
        return actions
    end

    self.stats.bytesIn = self.stats.bytesIn + #frame

    local kind, a, b, reliable = Wire.parse(frame)
    if not kind then
        self.stats.dropped = self.stats.dropped + 1
        return actions
    end

    if kind == 'control' then
        return self:handleControl(link, a, actions)
    end

    -- Data from a link with no session. Silence, deliberately: an error reply
    -- would be a reflector and an oracle, and there is nothing useful to say to
    -- a sender that has not identified itself.
    if not ownSession then
        self.stats.dropped = self.stats.dropped + 1
        return actions
    end

    if link.role == 'client' then
        -- A client broadcasting would be a client reaching every other client on
        -- the session. It cannot: the host is a client's only destination, which
        -- is also the topology the engine already has.
        if kind == 'broadcast' then
            self.stats.dropped = self.stats.dropped + 1
            return actions
        end
        if a ~= 0 then
            -- A client naming a slot is a client trying to address a peer it has
            -- no business addressing. Dropped rather than remapped.
            self.stats.dropped = self.stats.dropped + 1
            return actions
        end
        return self:forwardFromClient(link, b, channel, reliable, actions)
    end

    if kind == 'broadcast' then
        return self:broadcastFromHost(link, b, channel, reliable, actions)
    end

    return self:forwardFromHost(link, a, b, channel, reliable, actions)
end

---------------------------------------------------------------------------
-- Round-trip time
--
-- A relayed path is two hops and each end can only measure its own. Lag
-- compensation reads transport:rtt(), and a relayed host that reported only its
-- hop to the relay would rewind by half the real latency and its players' shots
-- would land behind their targets -- a bug that looks like bad aim rather than
-- like a networking fault, which is the worst kind.
--
-- So the relay tells each end what the other hop costs, and the transport adds
-- the two. The relay is the only party that can measure both.
---------------------------------------------------------------------------

function RelayMT:reportRtt(key, milliseconds)
    local actions = {}

    local link = self.links[key]
    if not link or not link.session then return actions end

    local session = self.sessions[link.session]
    if not session then return actions end

    local ms = tonumber(milliseconds)
    if not ms or ms ~= ms or ms < 0 or ms > 60000 then return actions end
    ms = math.floor(ms)

    if link.role == 'client' then
        if session.hostLink and self.links[session.hostLink] then
            control(actions, session.hostLink, ('rtt %d %d'):format(link.slot, ms))
        end
        return actions
    end

    -- The host's hop, told to every client on the session.
    for _, clientKey in pairs(session.slots) do
        if self.links[clientKey] then
            control(actions, clientKey, ('rtt 0 %d'):format(ms))
        end
    end

    return actions
end

---------------------------------------------------------------------------
-- Time
---------------------------------------------------------------------------

-- Advances the clock and closes what has aged out or overspent. Returns actions.
function RelayMT:update(now)
    self.now = now or self.now
    local actions = {}

    -- Connections that arrived and never said what they wanted.
    for key, link in pairs(self.links) do
        if not link.role and (self.now - link.openedAt) > self.linkTimeout then
            self.links[key] = nil
            self.stats.expired = self.stats.expired + 1
            control(actions, key, 'refused no session was opened')
            closeAction(actions, key, 'no session was opened')
        end
    end

    -- Sessions nobody has said anything on. Collected first so the loop is not
    -- iterating a table that :detach is deleting from.
    local stale, over = {}, {}
    for id, session in pairs(self.sessions) do
        if (self.now - session.heardAt) > self.sessionTimeout then
            stale[#stale + 1] = id
        elseif (session.overruns or 0) > self.overrunLimit then
            over[#over + 1] = id
        end
    end

    for _, id in ipairs(stale) do
        local session = self.sessions[id]
        if session then
            self.stats.expired = self.stats.expired + 1
            local hostKey = session.hostLink
            control(actions, hostKey, 'closed relay session timed out')
            self:detach(hostKey, 'relay session timed out', actions)
            closeAction(actions, hostKey, 'relay session timed out')
        end
    end

    for _, id in ipairs(over) do
        local session = self.sessions[id]
        if session then
            self.stats.closedQuota = self.stats.closedQuota + 1
            local hostKey = session.hostLink
            control(actions, hostKey, 'closed over its relay bandwidth budget')
            self:detach(hostKey, 'over its relay bandwidth budget', actions)
            closeAction(actions, hostKey, 'over its relay bandwidth budget')
        end
    end

    return actions
end

function RelayMT:advance(dt)
    return self:update(self.now + (dt or 0))
end

---------------------------------------------------------------------------
-- Inspection
---------------------------------------------------------------------------

function RelayMT:get(id) return self.sessions[id] end

function RelayMT:slotCount(id)
    local session = self.sessions[id]
    if not session then return 0 end
    local n = 0
    for _ in pairs(session.slots) do n = n + 1 end
    return n
end

Relay.RelayMT = RelayMT

return Relay
