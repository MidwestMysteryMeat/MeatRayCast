--[[
    meatray.net.transport.relay — the transport for the hosts a punch cannot
    reach.

        MeatRay.net.host{ transport = 'relay', relay = '198.51.100.20:6790' }
        MeatRay.net.join('relay://198.51.100.20:6790/3f2a19c4/8b1d...e0',
                         { transport = 'relay', punch = false })

    It wraps ENet rather than replacing it. There is exactly one real connection
    per process — to the relay — and every peer above this file is a virtual one
    living in a slot on that connection. Reliability, ordering, fragmentation,
    congestion control and connection management are ENet's, unchanged, on both
    hops; this file adds one byte (meatray/net/relaywire.lua) and a slot table.

    That the inner transport is a parameter is the reason any of this is
    testable: `inner = 'loopback'` puts a host, a relay and two clients in one
    LuaJIT process with no sockets at all, forwarding real frames through the
    real session logic.

    ## What it deliberately does not implement

    `punch` and `localPort` are absent, and their absence is the message. A relay
    session *is* the traversal, so a host running this transport reports hole
    punching as unsupported rather than arming an attempt nobody will make — the
    same shape the Steam transport will have, and the reason
    `meatray/net/transport.lua` made those methods optional in the first place.
    A client joining through a relay should pass `punch = false`; otherwise the
    client logs one line saying it cannot be introduced and joins anyway, which
    is true but noisy.

    ## Nothing here may hang

    Three failures, each with a budget and each ending in a reason:

      * **The relay is unreachable.** `listen` and `connect` dial it and wait
        DIAL_TIMEOUT seconds — ten by default, stated in the error along with the
        time actually spent, because this project has already paid once for an
        impatient probe that read a working port as a blocked one.
      * **The relay refuses.** Full, private, wrong version, no such session: the
        refusal arrives as a control frame during the dial and comes straight
        back out of `listen`/`connect` as the reason. No retry loop.
      * **The relay dies mid-session.** The one real connection drops, and every
        virtual peer becomes a `disconnect` event. A host sees every player
        leave; a client sees its session end with `the relay connection was
        lost`. Neither is left believing a dead session is healthy.

    And the standing rule for the whole subsystem holds by construction: this is
    a transport nobody selects unless they ask for it, so `direct` and `lan` are
    untouched by a relay being down. Nothing outside this file changed to add it.

    ## RTT is two hops and both halves are counted

    `rtt(peer)` returns this process's hop to the relay plus the relay's hop to
    that peer, which the relay reports once a second. Reporting only the near
    hop would halve the number lag compensation rewinds by, and shots would land
    behind moving targets — a bug that reads as bad aim rather than as a network
    fault.

    HEADLESS: no love. `require('socket')` happens inside a function, so this
    file loads under plain LuaJIT with no LOVE at all.
]]

local Transport = require('meatray.net.transport')
local Wire      = require('meatray.net.relaywire')
local P         = require('meatray.net.protocol')

local RelayT = {}

-- How long a dial may take. Generous on purpose: it covers a TCP-less UDP
-- handshake, the relay's own scheduling, and one ENet connect retransmission.
-- The cost of it being generous is only ever felt on a dial that was going to
-- fail; the cost of it being tight is a working relay reported as a dead one.
RelayT.DIAL_TIMEOUT = 10

-- How often an otherwise idle session says something, against the relay's
-- 120-second session timeout. Six missed keepalives before a lobby sitting in a
-- menu is torn down.
RelayT.KEEPALIVE = 20

-- How long the dial loop naps between service calls. Small enough not to add
-- meaningfully to the dial, large enough not to spin a core.
RelayT.DIAL_NAP = 0.005

local RelayMT = {}
RelayMT.__index = RelayMT

---------------------------------------------------------------------------
-- Construction
---------------------------------------------------------------------------

-- Wall time, for the dial budget only. Required inside a function rather than at
-- file scope: a top-level `require('socket')` would make this module — and with
-- it the whole transport registry — un-loadable under plain LuaJIT.
--
-- os.time as the fallback rather than os.clock, which measures CPU time and
-- would let a dial that spent ten seconds waiting on a socket look like a dial
-- that had barely started.
local function wallClock()
    local ok, socket = pcall(require, 'socket')
    if ok and type(socket) == 'table' and socket.gettime then
        return function() return socket.gettime() end,
               function(seconds) socket.sleep(seconds) end
    end
    return function() return os.time() end, function() end
end

-- opts:
--   relay        'host:port' of the relay (a host needs this; a client may
--                instead pass the whole ticket as the join address)
--   inner        'enet' (default), 'loopback', or a transport instance
--   session      client side: which session to join
--   secret       client side: the session's secret
--   allocationSecret  host side: for a private relay
--   dialTimeout  seconds, default 10
--   clock/sleep  injectable, so a test needs no wall clock
--   pump         called once per dial iteration; a test uses it to advance an
--                in-process relay that would otherwise never run
function RelayT.new(opts)
    opts = opts or {}

    local innerName = opts.inner or 'enet'

    -- The inner transport gets the same channel count, and one peer slot: there
    -- is only ever one real connection, to the relay.
    local inner, err = Transport.new(innerName, {
        channels = opts.channels or P.CHANNELS,
        maxPeers = 1,
        clientAddress = opts.clientAddress,
    })
    if not inner then return nil, err end

    local clock, sleep = opts.clock, opts.sleep
    if not clock or not sleep then
        local defaultClock, defaultSleep = wallClock()
        clock = clock or defaultClock
        sleep = sleep or defaultSleep
    end

    return setmetatable({
        name  = 'relay',
        inner = inner,

        relayAddress = opts.relay,
        allocationSecret = opts.allocationSecret,
        wanted = (opts.session and opts.secret)
                 and { address = opts.relay, session = opts.session, secret = opts.secret }
                 or nil,

        role     = nil,         -- 'host' or 'client', decided by listen/connect
        link     = nil,         -- the one real peer: the relay
        session  = nil,
        secret   = nil,
        maxSlots = nil,

        slots   = {},           -- host side: [slot] = virtual peer
        peer    = nil,          -- client side: the virtual host peer
        pending = {},           -- events waiting to be drained by :service

        hopRtt  = 0,            -- relay -> far end, milliseconds, as reported
        idle    = 0,            -- seconds since anything was sent
        lost    = nil,          -- why the relay connection ended, once it has

        dialTimeout = opts.dialTimeout or RelayT.DIAL_TIMEOUT,
        clock = clock,
        nap   = sleep,
        pump  = opts.pump,

        -- host.lua passes its whole options table to Transport.new, so a host
        -- built the ordinary way gets its logger here for free. A caller that
        -- hands in a pre-built transport instead can set `t.onLog` afterwards.
        onLog = opts.onLog,

        stats = { sent = 0, received = 0, dropped = 0 },
    }, RelayMT)
end

---------------------------------------------------------------------------
-- Peers
---------------------------------------------------------------------------

-- A virtual peer. `key` must be stable for the life of the connection and never
-- reused by a later one, so the session id and a per-transport counter are both
-- in it: a slot number alone would be reused the moment a player left and
-- another joined, and the host's peer table is keyed by exactly this.
local function newPeer(self, slot, address)
    self.serial = (self.serial or 0) + 1
    return {
        slot    = slot,
        address = address or 'relay',
        key     = ('relay:%s:%d:%d'):format(tostring(self.session), slot, self.serial),
        rtt     = 0,
    }
end

local function push(self, event)
    self.pending[#self.pending + 1] = event
end

---------------------------------------------------------------------------
-- Control frames arriving from the relay
---------------------------------------------------------------------------

-- Returns 'dialled' once the thing the dial was waiting for has happened, or
-- 'refused' plus a reason. Everything else is handled and returns nil, which is
-- what the steady-state service loop wants.
function RelayMT:onControl(text)
    -- Verb first, then a pattern per verb. One generic tokeniser would split a
    -- reason like "this relay session is full" into four fields and hand the
    -- reader a table.concat; a reason is the tail of its line, and only the verb
    -- knows that.
    local words = Wire.words(text, 2)
    local verb, rest = words[1], words[2] or ''

    if verb == 'opened' then
        local id, secret, slots = rest:match('^(%x+)%s+(%x+)%s+(%d+)$')
        if not id then return 'refused', 'the relay sent a malformed session' end
        self.session  = id
        self.secret   = secret
        self.maxSlots = tonumber(slots)
        return 'dialled'
    end

    if verb == 'joined' then
        local id = rest:match('^(%x+)%s+%d+$')
        if not id then return 'refused', 'the relay sent a malformed session' end
        self.session = id
        return 'dialled'
    end

    if verb == 'refused' then
        return 'refused', (rest ~= '') and rest or 'the relay refused, without saying why'
    end

    if verb == 'closed' then
        self.lost = (rest ~= '') and rest or 'the relay closed the session'
        self:loseEveryone(self.lost)
        return nil
    end

    if verb == 'peer' then
        local slotText, address = rest:match('^(%d+)%s+(%S+)$')
        local slot = tonumber(slotText)
        if not slot or self.slots[slot] then return nil end
        local peer = newPeer(self, slot, address)
        self.slots[slot] = peer
        push(self, { type = 'connect', peer = peer })
        return nil
    end

    if verb == 'gone' then
        local slot = tonumber(rest:match('^(%d+)'))
        local peer = slot and self.slots[slot]
        if not peer then return nil end
        self.slots[slot] = nil
        push(self, { type = 'disconnect', peer = peer, data = 0 })
        return nil
    end

    if verb == 'rtt' then
        -- rtt <slot> <milliseconds>: the far hop, which only the relay can see.
        local slotText, msText = rest:match('^(%d+)%s+(%d+)$')
        local ms = tonumber(msText)
        if not ms then return nil end
        if self.role == 'client' then
            self.hopRtt = ms
        else
            local peer = self.slots[tonumber(slotText)]
            if peer then peer.rtt = ms end
        end
        return nil
    end

    -- 'pong' and anything a later relay adds: ignored, never answered.
    return nil
end

-- The relay went away, or said the session is over. Every virtual peer becomes a
-- disconnect, because a peer that is silently deleted is a player who vanishes
-- from a scoreboard with no event and no reason.
function RelayMT:loseEveryone(reason)
    self.lost = self.lost or reason

    for slot, peer in pairs(self.slots) do
        self.slots[slot] = nil
        push(self, { type = 'disconnect', peer = peer, data = 0 })
    end

    if self.peer then
        local peer = self.peer
        self.peer = nil
        push(self, { type = 'disconnect', peer = peer, data = 0 })
    end
end

---------------------------------------------------------------------------
-- Dialling
---------------------------------------------------------------------------

-- Waits for the relay to answer, with a budget it states and an elapsed time it
-- reports. Returns true, or nil plus a reason that a player can act on.
function RelayMT:dial(address, opening)
    local started = self.clock()
    local deadline = started + self.dialTimeout
    local sent = false

    while true do
        if self.pump then self.pump() end
        self.inner:update(0)

        while true do
            local event = self.inner:service()
            if not event then break end

            if event.type == 'connect' then
                self.inner:send(self.link, Wire.control(opening), 0, true)
                sent = true

            elseif event.type == 'disconnect' then
                return nil, ('the relay at %s closed the connection'):format(address)

            elseif event.type == 'receive' then
                local kind, body = Wire.parse(event.data)
                if kind == 'control' then
                    local verdict, why = self:onControl(body)
                    if verdict == 'dialled' then return true end
                    if verdict == 'refused' then
                        return nil, ('the relay at %s refused: %s'):format(address, why)
                    end
                end
            end
        end

        local elapsed = self.clock() - started
        if self.clock() > deadline then
            return nil, ('the relay at %s did not %s within %.1fs (waited %.1fs)')
                :format(address, sent and 'answer' or 'accept a connection',
                        self.dialTimeout, elapsed)
        end

        self.nap(RelayT.DIAL_NAP)
    end
end

---------------------------------------------------------------------------
-- Listening: a host opens a session on the relay
---------------------------------------------------------------------------

-- `opts.port` is accepted and ignored, deliberately. A relayed host has no
-- inbound port — that is the entire point of it — and refusing the field would
-- mean host.lua could not call this transport the same way it calls every other
-- one. The port it thinks it is on is reported by the relay ticket instead.
function RelayMT:listen(opts)
    opts = opts or {}

    local address = opts.relay or self.relayAddress
    if type(address) ~= 'string' or address == '' then
        return nil, 'the relay transport needs a relay address: '
                 .. 'net.host{ transport = "relay", relay = "host:port" }'
    end
    self.relayAddress = address

    local link, err = self.inner:connect(address)
    if not link then
        return nil, ('cannot reach the relay at %s: %s'):format(address, tostring(err))
    end
    self.link = link
    self.role = 'host'

    local opening = ('open %d'):format(Wire.VERSION)
    if self.allocationSecret then
        opening = opening .. ' ' .. tostring(self.allocationSecret)
    end

    local ok, why = self:dial(address, opening)
    if not ok then
        self.inner:close()
        self.link = nil
        return nil, why
    end

    -- Said out loud, because the relay's slot cap is the relay operator's number
    -- and not the host's, and a host that quietly seats fewer players than it
    -- was configured for finds out when somebody is refused. Stated rather than
    -- warned about: `maxPeers` here includes headroom for peers being refused,
    -- so comparing the two numbers would raise a false alarm on a default host.
    self:log(('session %s open on %s, up to %d players')
             :format(tostring(self.session), address, self.maxSlots or 0))

    return true
end

function RelayMT:log(text)
    if self.onLog then self.onLog('[relay] ' .. tostring(text)) end
end

-- Everything a client needs to reach this host, as one string. A host publishes
-- it: in a registry listing, in a chat message, on a command line.
--
-- The address in it is the address this host dialled the relay on. That is right
-- whenever the host reached the relay by a name a client can also reach it by,
-- which is every deployment where the relay has a public address — and wrong on
-- a relay reachable by one name from inside and another from outside, where the
-- operator must hand out the outside name themselves.
function RelayMT:ticket()
    if not (self.session and self.secret and self.relayAddress) then return nil end
    return Wire.formatTicket{
        address = self.relayAddress,
        session = self.session,
        secret  = self.secret,
    }
end

---------------------------------------------------------------------------
-- Connecting: a client joins a session on the relay
---------------------------------------------------------------------------

function RelayMT:connect(address)
    local ticket = Wire.parseTicket(address) or self.wanted

    if not ticket then
        return nil, ('%s is not a relay ticket; a relay join needs '
                  .. 'relay://host:port/session/secret'):format(tostring(address))
    end
    if not ticket.address or ticket.address == '' then
        return nil, 'a relay ticket needs the relay address'
    end

    self.relayAddress = ticket.address
    self.role = 'client'

    local link, err = self.inner:connect(ticket.address)
    if not link then
        return nil, ('cannot reach the relay at %s: %s')
            :format(ticket.address, tostring(err))
    end
    self.link = link

    local ok, why = self:dial(ticket.address,
        ('join %d %s %s'):format(Wire.VERSION, ticket.session, ticket.secret))
    if not ok then
        self.inner:close()
        self.link = nil
        return nil, why
    end

    self.peer = newPeer(self, 0, ticket.address)

    -- Queued rather than emitted, because client.lua starts its handshake on the
    -- connect event and there is no path to send it down until connect() has
    -- returned the peer it will send to.
    push(self, { type = 'connect', peer = self.peer })

    return self.peer
end

---------------------------------------------------------------------------
-- Traffic
---------------------------------------------------------------------------

function RelayMT:send(peer, data, channel, reliable)
    if not peer or not self.link then return false end

    local slot = (self.role == 'host') and peer.slot or 0
    local frame = Wire.data(slot, data, reliable ~= false)
    if not frame then return false end

    self.idle = 0
    self.stats.sent = self.stats.sent + 1
    return self.inner:send(self.link, frame, channel, reliable) and true or false
end

-- One frame for every client, not one per client. The host's uplink is the
-- constrained half of a relayed session — it is the side sending a snapshot
-- stream — and a broadcast that fanned out here would multiply it by the player
-- count before it ever left the machine.
--
-- The relay charges the fan-out against the session's byte budget, so the saving
-- is real for the host and not free for the relay, which is the honest split.
function RelayMT:broadcast(data, channel, reliable)
    if not self.link then return end

    if self.role ~= 'host' then
        if self.peer then self:send(self.peer, data, channel, reliable) end
        return
    end

    self.idle = 0
    self.stats.sent = self.stats.sent + 1
    self.inner:send(self.link, Wire.broadcast(data, reliable ~= false), channel, reliable)
end

function RelayMT:update(dt)
    self.inner:update(dt)

    if not self.link then return end

    -- A session with nothing to say still has to say so, or the relay's session
    -- timeout tears down a lobby that is merely waiting for a friend.
    self.idle = self.idle + (dt or 0)
    if self.idle >= RelayT.KEEPALIVE then
        self.idle = 0
        self.inner:send(self.link, Wire.control('ping'), 0, true)
    end
end

---------------------------------------------------------------------------
-- Receiving
---------------------------------------------------------------------------

function RelayMT:translate(event)
    if event.type == 'disconnect' then
        -- The one real connection. Everything above this file finds out as a
        -- disconnect per peer, which is the only event shape they know.
        self.link = nil
        self:loseEveryone('the relay connection was lost')
        return
    end

    if event.type ~= 'receive' then return end

    local kind, a, b = Wire.parse(event.data)
    if not kind then
        self.stats.dropped = self.stats.dropped + 1
        return
    end

    if kind == 'control' then
        self:onControl(a)
        return
    end

    if kind == 'broadcast' then
        -- A relay never sends one. Dropped rather than guessed at.
        self.stats.dropped = self.stats.dropped + 1
        return
    end

    local peer = (self.role == 'host') and self.slots[a] or self.peer
    if not peer then
        -- A slot that closed between the relay sending and us reading. Dropped:
        -- there is no peer to attribute it to and inventing one would hand
        -- host.lua a player it never saw join.
        self.stats.dropped = self.stats.dropped + 1
        return
    end

    self.stats.received = self.stats.received + 1
    push(self, { type = 'receive', peer = peer, data = b, channel = event.channel })
end

function RelayMT:service()
    if #self.pending > 0 then return table.remove(self.pending, 1) end
    if not self.link then return nil end

    while true do
        local event = self.inner:service()
        if not event then return nil end

        self:translate(event)
        if #self.pending > 0 then return table.remove(self.pending, 1) end
    end
end

---------------------------------------------------------------------------
-- Teardown
---------------------------------------------------------------------------

function RelayMT:disconnect(peer, code)
    if not peer then return end

    if self.role == 'host' then
        if self.link and self.slots[peer.slot] == peer then
            self.inner:send(self.link,
                Wire.control(('drop %d closed by the host'):format(peer.slot)), 0, true)
        end
        self.slots[peer.slot] = nil
        return
    end

    -- A client leaving says so, so the host is told at once rather than after
    -- the relay notices a dead connection.
    if self.link then
        self.inner:send(self.link, Wire.control('leave'), 0, true)
        self.inner:disconnect(self.link, code or 0)
        self.link = nil
    end
    self.peer = nil
end

function RelayMT:close()
    if self.link then
        self.inner:send(self.link, Wire.control('leave'), 0, true)
    end
    self.link = nil
    self.slots = {}
    self.peer = nil
    self.pending = {}
    self.inner:close()
end

---------------------------------------------------------------------------
-- Identity
---------------------------------------------------------------------------

function RelayMT:key(peer) return peer and peer.key end

-- The far end's REAL address, as the relay reported it, not the relay's. That is
-- what keeps ban-by-address working through a relay: a host banning a player
-- bans the player, and not the machine forwarding for everybody.
function RelayMT:address(peer) return peer and peer.address end

function RelayMT:ip(peer)
    local address = self:address(peer)
    if not address then return nil end
    local host = Transport.parseAddress(address, 0)
    return host
end

-- Both hops. See the note at the top of this file for why the near one alone
-- would be worse than useless.
function RelayMT:rtt(peer)
    if not self.link or not self.inner.rtt then return nil end

    local near = self.inner:rtt(self.link)
    if not near then return nil end

    local far = (self.role == 'host') and (peer and peer.rtt or 0) or self.hopRtt
    return near + (far or 0)
end

-- There is one real connection, so there is one timeout, and it is the relay's.
-- Applied to that rather than to a virtual peer, where it would mean nothing.
function RelayMT:setTimeout(peer, limit, minimum, maximum)
    if not self.link or not self.inner.setTimeout then return false end
    return self.inner:setTimeout(self.link, limit, minimum, maximum) and true or false
end

-- Deliberately absent: `punch` and `localPort`. A relay session is the
-- traversal, so a host on this transport reports hole punching as unsupported
-- rather than arming an attempt nobody will make. See the header.

RelayT.RelayMT = RelayMT

Transport.register('relay', RelayT.new)

return RelayT
