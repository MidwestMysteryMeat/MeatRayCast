--[[
    meatray.net.client — the side that simulates nothing and is right anyway.

    A client receives full snapshots at the host's snapshot rate, interpolates
    between the last two so 20 Hz of state draws as continuous motion at any
    framerate, and predicts exactly one thing: where its own player is.

    What is predicted and what is not:

      * Predicted: the local player's position. Input latency is felt — a hundred
        milliseconds between pressing forward and moving is the difference between
        a game that feels responsive and one that feels broken — while a foot of
        positional error is invisible.
      * Not predicted: health, ammo, damage, death, anything another entity does.
        There is no code in this file that lowers a health value. A health bar that
        drops and then springs back is a lie the player can see, and it is worse
        than the same information arriving 50 ms later. When the host says 88, the
        client says 88.

    Correction, when the host disagrees with the prediction:

      * a small error is absorbed over several snapshots, so walking into a wall
        the client did not know about slides you out rather than snapping you;
      * a large error is taken immediately, because at that point the client is
        not slightly wrong, it is somewhere else, and easing towards the truth
        just means being wrong for longer.

    Aim is never corrected. The client owns its own facing because facing is an
    input, and a host that overwrote it would give every player a mouse that
    fights back.

    HEADLESS: no love.graphics. With the loopback transport this needs no LOVE at
    all — which is how the replication tests drive a real client.
]]

local Entity    = require('meatray.sim.entity')
local Tick      = require('meatray.sim.tick')
local Transport = require('meatray.net.transport')
local Rep       = require('meatray.net.replication')
local P         = require('meatray.net.protocol')

local Client = {}

Client.DEFAULT_PORT = 6789

local ClientMT = {}
ClientMT.__index = ClientMT

-- Beyond this many tiles of disagreement the prediction is not smoothed, it is
-- replaced. One tile is roughly a doorway.
Client.SNAP_THRESHOLD = 1.0

-- Fraction of the remaining error absorbed per snapshot. 0.25 clears a small
-- error in about a fifth of a second at 20 Hz, which is under the threshold of
-- being noticed as a slide.
Client.SMOOTHING = 0.25

---------------------------------------------------------------------------

function Client.new(opts)
    opts = opts or {}

    local address = opts.address
    if type(address) == 'table' then address = address.address end
    if type(address) ~= 'string' or address == '' then
        return nil, 'joining needs an address, either "host:port" or a server list entry'
    end

    local self = setmetatable({
        mode        = 'client',
        address     = address,
        state       = 'connecting',
        reason      = nil,

        name        = opts.name or 'player',
        password    = opts.password,
        credentials = opts.credentials,

        world       = nil,
        entities    = {},
        byId        = {},
        player      = nil,
        entityId    = nil,
        peerId      = nil,

        server      = { name = nil, map = nil, mode = nil },
        tickRate     = opts.tickRate or 60,
        snapshotRate = opts.snapshotRate or 20,
        moveSpeed    = opts.moveSpeed or Rep.DEFAULT_MOVE_SPEED,
        turnSpeed    = opts.turnSpeed or Rep.DEFAULT_TURN_SPEED,

        prediction  = opts.prediction ~= false,
        snapThreshold = opts.snapThreshold or Client.SNAP_THRESHOLD,
        smoothing   = opts.smoothing or Client.SMOOTHING,

        input       = { forward = 0, strafe = 0 },
        inputSeq    = 0,
        inputRate   = opts.inputRate or 30,
        inputAccum  = 0,

        -- A join that never completes must fail with an explanation rather than
        -- sitting on 'connecting' forever. ENet times a *connect attempt* out on
        -- its own, but a peer that connects and is then never answered — a host
        -- wedged mid-frame, a protocol mismatch that dropped the JOIN, a version of
        -- the game that is not this one — produces no ENet event at all. From the
        -- player's side that is indistinguishable from a hang, and "connecting..."
        -- forever is the least useful thing a client can say.
        joinTimeout = opts.joinTimeout or 15,
        connectingFor = 0,

        -- And a join that *completed* must not be able to sit on 'joined'
        -- forever either. A half-open connection — the host's process gone, a
        -- NAT mapping dropped, a cable out — produces no disconnect event on
        -- this side: the socket is fine, the peer is simply never heard from
        -- again. Left alone, the client renders a frozen world and reports
        -- itself as connected, indefinitely.
        --
        -- Two mechanisms, because one of them is not always available. The
        -- transport is told to give up (ENet has always been able to do this;
        -- it just has to be asked), and `now`/`lastHeard` below are the
        -- watchdog for transports that cannot. Both are honoured, and both are
        -- driven by the `timeout` option rather than by a constant.
        timeout     = opts.timeout or 15,
        timeoutLimit = opts.timeoutLimit or 32,
        timeoutMin  = opts.timeoutMin or 5000,
        timeoutMax  = opts.timeoutMax,

        now         = 0,
        lastHeard   = 0,

        snapAge     = 0,
        lastTick    = -1,
        snapshots   = 0,
        corrections = 0,
        rtt         = nil,
        stats       = nil,

        onEvent     = opts.onEvent,
        onChat      = opts.onChat,
        onJoin      = opts.onJoin,
        onReject    = opts.onReject,
        onSpawn     = opts.onSpawn,
        onDespawn   = opts.onDespawn,
        onStats     = opts.onStats,
        onWarning   = opts.onWarning,
        onLog       = opts.onLog,
        onTimeout   = opts.onTimeout,
        spawnEntity = opts.spawnEntity,

        dropped     = 0,     -- packets from the host that failed to parse
        rejected    = 0,     -- packets that parsed but failed their schema
        wrongWay    = 0,     -- the host sending client->host traffic
    }, ClientMT)

    self.timeoutMax = self.timeoutMax
                      or math.max(1000, math.floor((self.timeout or 15) * 1000))

    self.clock = Tick.new(self.tickRate)

    local transport, transportErr = Transport.new(opts.transport or 'enet', opts)
    if not transport then return nil, transportErr end
    self.transport = transport

    -- The hole punch, and the ONE thing about it that has to be right: it is
    -- asked for and then not waited on.
    --
    -- The order below is the design. Open the socket, so it has a port. Tell the
    -- registry that port, so it can tell the host where to punch. Then connect --
    -- on the next line, with no check of whether the registry answered and no
    -- check of whether the host is ready. Waiting for either is what makes a
    -- punch fail: whichever side sends second is the side whose packet arrives at
    -- a router that has not opened yet, and a client that waits for confirmation
    -- has volunteered to be that side. The registry says so too, by answering
    -- sendNow = true, and nothing in this file reads that field for a decision.
    --
    -- Our own connect is also our own punch. It leaves the game socket, which is
    -- the only socket whose mapping is worth anything (see EnetMT:punch), so
    -- there is nothing extra for this side to send.
    self:requestPunch(opts, address)

    local handle, connectErr = transport:connect(address)
    if not handle then
        -- The punch is closed too. It owns a TCP socket that nothing will ever
        -- advance once this constructor returns nil, and a leaked descriptor per
        -- failed join is the kind of leak that only shows up on the machine that
        -- retries in a loop.
        if self.punch then self.punch:close(); self.punch = nil end
        transport:close()
        return nil, connectErr
    end
    self.peer = handle

    -- ENet gives up on this connection on its own now, rather than holding it
    -- open forever. `minimum` cannot outrun `maximum`, which it would for any
    -- caller that asked for a timeout under five seconds.
    self.timeoutMin = math.min(self.timeoutMin, self.timeoutMax)
    if transport.setTimeout then
        transport:setTimeout(handle, self.timeoutLimit, self.timeoutMin, self.timeoutMax)
    end

    return self
end

---------------------------------------------------------------------------
-- Hole punching, from the side that is trying to get in
---------------------------------------------------------------------------

-- A punched join gets a longer budget than a direct one, and the number comes
-- from the other side's clock rather than from taste. The registry hands
-- introductions to a host on its heartbeat, and heartbeats are ten seconds
-- apart; the registry also nudges the host to heartbeat immediately, but that
-- nudge is one unacknowledged datagram and may be lost. So the worst honest case
-- is a full heartbeat interval before the host has even heard of us, plus the
-- punch, plus an ENet connect retransmission after it.
--
-- Thirty seconds covers that with room, and the cost of it being generous is
-- only ever felt on a join that was going to fail anyway. The cost of it being
-- tight is a working punch reported as a dead server -- this project has already
-- paid once for an impatient probe, which read as a blocked port and produced
-- four pointless firewall rules.
Client.PUNCH_JOIN_TIMEOUT = 30

-- Asks a registry to introduce us, and returns without waiting for the answer.
-- Every failure below is a log line and a `false`: a join that cannot be
-- introduced is still a join that can be attempted directly, which is exactly
-- what would have happened before any of this existed.
function ClientMT:requestPunch(opts, address)
    if opts.punch == false then return false end

    local registries = opts.registries
    if type(registries) == 'string' then registries = { registries } end
    if not registries or #registries == 0 then return false end

    local transport = self.transport

    -- A transport that cannot name its own port cannot be introduced on one.
    -- Note what is NOT required here: transport.punch. This side's punch is its
    -- own connect, which is already leaving the right socket.
    if not (transport.open and transport.localPort) then
        self:log(('the %s transport cannot say which UDP port to introduce, so '
                  .. 'this join is a direct attempt only')
                 :format(tostring(transport.name)))
        return false
    end

    local opened, openErr = transport:open()
    if not opened then
        self:log(('could not open a socket to be introduced on (%s); joining directly')
                 :format(tostring(openErr)))
        return false
    end

    local port = transport:localPort()
    if not port then
        self:log('the transport would not say what port it bound; joining directly')
        return false
    end

    -- Required lazily. The client has no business depending on a discovery
    -- backend at load time -- a game that never touches a registry should not
    -- pull one in to join by address.
    local Master = require('meatray.net.discovery.master')

    local host, hostPort = Transport.parseAddress(address, Client.DEFAULT_PORT)

    local punch, err = Master.punch{
        registries = registries,
        port     = port,
        host     = host,
        hostPort = hostPort,
        onLog    = function(text) self:log(text) end,
    }
    if not punch then
        self:log(('cannot ask for an introduction (%s); joining directly')
                 :format(tostring(err)))
        return false
    end

    self.punch = punch
    self.punchPort = port

    if not opts.joinTimeout then self.joinTimeout = Client.PUNCH_JOIN_TIMEOUT end

    -- And the transport is given the same budget, or the one above is a lie.
    -- ENet gives up on a connect attempt at `timeoutMax`, which defaults to 15
    -- seconds here -- so without this line a client that says it will wait 30
    -- seconds for a punch stops retransmitting at 15, half a heartbeat interval
    -- before the host has necessarily even heard of it. A budget the transport
    -- abandons first is not a budget.
    if not opts.timeoutMax then
        self.timeoutMax = math.max(self.timeoutMax, Client.PUNCH_JOIN_TIMEOUT * 1000)
    end

    self:log(('asking %s to introduce us to %s on UDP %d, and connecting in the '
              .. 'same moment rather than waiting to be told the host is ready')
             :format(registries[1], address, port))
    return true
end

---------------------------------------------------------------------------

function ClientMT:log(text)
    local line = ('[net] %s'):format(tostring(text))
    if self.onLog then self.onLog(line) else print(line) end
end

function ClientMT:warn(text)
    if self.onWarning then self.onWarning(text) end
    self:log('! ' .. tostring(text))
end

function ClientMT:joined()
    return self.state == 'joined'
end

-- Seconds since the last packet of any kind arrived from the host. A joined
-- client always has traffic in both directions — snapshots down at the snapshot
-- rate, inputs up at the input rate — so this stays near zero on a healthy link
-- and grows without bound on a half-open one.
function ClientMT:silentFor()
    return self.now - (self.lastHeard or 0)
end

---------------------------------------------------------------------------
-- Intent
---------------------------------------------------------------------------

-- Set every frame from whatever the game reads its controls from. Held state
-- only: triggers and one-shot actions go through command().
function ClientMT:setInput(input)
    self.input = input or { forward = 0, strafe = 0 }
end

-- A discrete action, on the reliable channel because losing it loses the action.
-- The host has no built-in verbs; what a name means is decided by the host's
-- onCommand.
function ClientMT:command(name, body)
    if self.state ~= 'joined' then return false end
    self.transport:send(self.peer, P.pack(P.COMMAND, { name = name, body = body }),
                        P.CH_RELIABLE, true)
    return true
end

function ClientMT:chat(text)
    if self.state ~= 'joined' then return false end
    self.transport:send(self.peer, P.pack(P.CHAT, { text = tostring(text) }),
                        P.CH_RELIABLE, true)
    return true
end

function ClientMT:requestStats()
    if self.state ~= 'joined' then return false end
    self.transport:send(self.peer, P.pack(P.STATS, {}), P.CH_RELIABLE, true)
    return true
end

function ClientMT:ping(at)
    if self.state ~= 'joined' then return false end
    self.transport:send(self.peer, P.pack(P.PING, { time = at or 0 }), P.CH_STREAM, false)
    return true
end

function ClientMT:sendInput()
    if self.state ~= 'joined' then return false end

    self.inputSeq = self.inputSeq + 1
    local input = self.input or {}

    self.transport:send(self.peer, P.pack(P.INPUT, {
        seq     = self.inputSeq,
        forward = input.forward or 0,
        strafe  = input.strafe or 0,
        turn    = input.turn or 0,
        angle   = input.angle,
    }), P.CH_STREAM, false)

    return true
end

function ClientMT:leave()
    if self.transport and self.peer then
        self.transport:send(self.peer, P.pack(P.LEAVE, {}), P.CH_RELIABLE, true)
    end
    self:close('left')
end

function ClientMT:close(reason)
    if self.punch then self.punch:close(); self.punch = nil end
    if self.transport then
        self.transport:disconnect(self.peer, 0)
        self.transport:close()
        self.transport = nil
    end
    if self.state ~= 'rejected' and self.state ~= 'kicked' then
        self.state = 'disconnected'
        self.reason = self.reason or reason
    end
end

---------------------------------------------------------------------------
-- The frame
---------------------------------------------------------------------------

function ClientMT:update(dt)
    dt = dt or 0
    if not self.transport then return end

    self.now = self.now + dt

    self.transport:update(dt)

    -- Advanced, never waited on. The connect went out before this ever ran.
    if self.punch then
        self.punch:update(dt)
        if self.punch:done() then
            self.punchResult = self.punch:failed() and 'failed' or 'asked'
            self.punch = nil
        end
    end

    self:pump()

    if self.state == 'connecting' then
        self.connectingFor = self.connectingFor + dt
        if self.joinTimeout and self.connectingFor > self.joinTimeout then
            self.state = 'failed'
            self.reason = ('no answer from %s after %g seconds'):format(self.address,
                                                                       self.joinTimeout)
            self:warn(('%s - the address may be wrong, the host may be behind a '
                       .. 'firewall or NAT, or UDP may be blocked on this machine '
                       .. '(check with: love . --netcheck)'):format(self.reason))

            -- Said only when it is true, and said without inventing a cause. The
            -- punch was requested and both sides sent; whether any router opened
            -- is not knowable from here and is not guessed at. There is no relay
            -- to fall back to, so this is where a punched join that failed stops
            -- -- with a reason, rather than with a progress bar.
            if self.punchResult or self.punch then
                self:warn('an introduction was requested and the host was asked to '
                          .. 'punch back; it did not get through. There is no relay, '
                          .. 'so the host needs UDP forwarded, or a dedicated server')
            end
        end
        return
    end

    if self.state ~= 'joined' then return end

    -- The watchdog. A joined client that has heard nothing for `timeout` seconds
    -- says so and stops, rather than showing a frozen world and the word
    -- "connected" until the player closes the game.
    if self:silentFor() > self.timeout then
        self.state = 'disconnected'
        self.reason = ('the server stopped responding (nothing heard for %g seconds)')
                      :format(self.timeout)
        self:warn(self.reason)
        if self.onTimeout then self.onTimeout(self, self.reason) end
        self:close(self.reason)
        return
    end

    self.snapAge = self.snapAge + dt

    -- Prediction and local door animation run on a fixed tick, matching the
    -- host's, so the same input over the same number of ticks produces the same
    -- displacement on both sides.
    self.clock:advance(dt, function(step) self:predict(step) end)

    self.inputAccum = self.inputAccum + dt
    local interval = 1 / self.inputRate
    if self.inputAccum >= interval then
        self.inputAccum = self.inputAccum % interval
        self:sendInput()
    end
end

function ClientMT:predict(step)
    if self.world then
        -- Door openness is presentation state and every client can animate it
        -- itself; only the open/shut decision comes from the host.
        self.world:update(step)
    end

    if not self.prediction or not self.player then return end

    self.player:snapPrevious()
    Rep.applyInput(self.player, Rep.sanitiseInput(self.input), step, self.world, {
        moveSpeed = self.moveSpeed, turnSpeed = self.turnSpeed,
    })
end

-- How far the current frame sits between the last two snapshots, for drawing
-- entities the host owns.
function ClientMT:alpha()
    local interval = 1 / (self.snapshotRate or 20)
    local a = self.snapAge / interval
    if a < 0 then return 0 end
    if a > 1 then return 1 end
    return a
end

-- The tick alpha, for drawing the predicted local player.
function ClientMT:tickAlpha()
    return self.clock:alpha()
end

function ClientMT:playerCount()
    local n = 0
    for i = 1, #self.entities do
        if self.entities[i]:has('player') then n = n + 1 end
    end
    return n
end

---------------------------------------------------------------------------
-- Receiving
---------------------------------------------------------------------------

function ClientMT:pump()
    while true do
        local event = self.transport:service()
        if not event then break end

        if event.type == 'connect' then
            -- The handshake starts here rather than at connect() because until
            -- this arrives there is no path to send it down.
            self.transport:send(self.peer, P.pack(P.JOIN, {
                version     = P.VERSION,
                name        = self.name,
                password    = self.password,
                credentials = self.credentials,
            }), P.CH_RELIABLE, true)

        elseif event.type == 'disconnect' then
            if self.state == 'connecting' then
                self.state = 'failed'
                self.reason = self.reason or 'the server closed the connection'
                -- A refusal, not a silence. Worth separating from the timeout
                -- path below, because a punched join that is REFUSED reached the
                -- host's machine and the punch is not the suspect -- saying
                -- "traversal failed" here would point at the wrong thing.
                if self.punchResult or self.punch then
                    self:log('(the introduction is not the problem: something '
                             .. 'answered at that address and refused)')
                end
            elseif self.state == 'joined' then
                self.state = 'disconnected'
                -- Say which kind of loss it was when the answer is knowable. A
                -- drop after a long silence is a host that went away; a drop
                -- with traffic still flowing a moment ago is something else, and
                -- telling them apart is most of diagnosing it.
                local silent = self:silentFor()
                self.reason = self.reason
                    or (silent > (self.timeout / 2)
                        and ('the server stopped responding (nothing heard for %.0f seconds)')
                            :format(silent))
                    or 'lost connection to the server'
            end

        elseif event.type == 'receive' then
            self.lastHeard = self.now
            self:receive(event.data)
        end
    end
end

-- One packet from the host. Parse failure and handler failure are separated here
-- exactly as they are on the host: P.unpack reports malformed input by returning
-- nil, and nothing else in this function is allowed to produce that verdict.
function ClientMT:receive(data)
    local kind, body, why = P.unpack(data)
    if not kind then
        self.dropped = self.dropped + 1
        -- Said once. A client talking to a host that is not this protocol would
        -- otherwise print a line per packet, at the snapshot rate, forever.
        if not self.saidDropped then
            self.saidDropped = true
            self:warn(('ignoring unreadable packets from the server: %s')
                      :format(tostring(why)))
        end
        return
    end

    -- The host sending client->host traffic is a host that is confused or is not
    -- this protocol. There is no handler for it.
    if not P.travels(kind, P.S2C) then
        self.wrongWay = self.wrongWay + 1
        return
    end

    local valid, badField = P.check(kind, body)
    if not valid then
        self.rejected = self.rejected + 1
        self:warn(('ignored a malformed %s from the server: %s')
                  :format(P.names[kind], tostring(badField)))
        return
    end

    self:handle(kind, body)
end

---------------------------------------------------------------------------

--[[
    The client's half of the contract, keyed by tag.

    Same reason as the host's: `tests/test_net_contract.lua` diffs these keys
    against `P.direction`, so a message the protocol says a client must handle
    and does not is a failing test rather than a packet that quietly does
    nothing. An if/elseif chain could not be asked what it handled without
    grepping for the comparisons, and a grep cannot see a branch that calls a
    helper.

    CHAT appears here *and* on the host. That is not a duplicate: chat is the one
    tag that legitimately travels both ways, with `{ text }` going up and
    `{ text, name }` coming down, and the registry now records that instead of
    filing it under one heading and hoping.
]]

local handlers = {}

handlers[P.ACCEPT] = function(self, body)
    self:handleAccept(body)
end

handlers[P.REJECT] = function(self, body)
    self.state = 'rejected'
    self.reason = body.reason or 'refused'
    self:log(('refused by the server: %s%s'):format(
        tostring(self.reason), body.detail and (' - ' .. body.detail) or ''))
    if self.onReject then self.onReject(self, self.reason, body.detail) end
end

handlers[P.SNAPSHOT] = function(self, body)
    self:handleSnapshot(body)
end

handlers[P.WORLD] = function(self, body)
    if not self.world then return end
    if body.doors then self.world:applySnapshot(body.doors) end
    if body.tiles then self.world:applyTileSnapshot(body.tiles) end
end

handlers[P.EVENT] = function(self, body)
    if self.onEvent then self.onEvent(self, body.name, body.body) end
end

handlers[P.CHAT] = function(self, body)
    if self.onChat then self.onChat(self, body.name, body.text) end
end

handlers[P.REPLY] = function(self, body)
    self.stats = body
    if self.onStats then self.onStats(self, body) end
end

handlers[P.KICK] = function(self, body)
    self.state = 'kicked'
    self.reason = body.reason or 'kicked'
    self:log('kicked: ' .. tostring(self.reason))
end

handlers[P.PONG] = function(self, body)
    self.rtt = body.time
end

Client.handlers = handlers

function ClientMT:handle(kind, body)
    local handler = handlers[kind]
    if not handler then return end

    local ok, err = pcall(handler, self, body)
    if not ok then
        self:warn(('the %s handler errored: %s'):format(P.names[kind], tostring(err)))
    end
end

function ClientMT:handleAccept(body)
    local world, err = Rep.buildWorld(body.world)
    if not world then
        self.state = 'failed'
        self.reason = err
        self:warn('could not build the server world: ' .. tostring(err))
        return
    end

    self.world        = world
    self.peerId       = body.peerId
    self.entityId     = body.entityId
    self.tickRate     = body.tickRate or self.tickRate
    self.snapshotRate = body.snapshotRate or self.snapshotRate
    self.moveSpeed    = body.moveSpeed or self.moveSpeed
    self.turnSpeed    = body.turnSpeed or self.turnSpeed
    self.server       = { name = body.name, map = body.map, mode = body.mode }
    self.clock        = Tick.new(self.tickRate)

    -- Rebase the local id counter past everything the host will ever assign, so
    -- anything this client spawns for itself (an effect, a decal, a debug marker)
    -- cannot collide with an authoritative id. No negotiation, so no race.
    Entity.resetIds(body.idBase or Rep.CLIENT_ID_BASE)

    self.state = 'joined'
    self:log(('joined %s (%s, map %s) as peer %s')
             :format(tostring(body.name), tostring(body.mode), tostring(body.map),
                     tostring(body.peerId)))

    if self.onJoin then self.onJoin(self) end
end

function ClientMT:handleSnapshot(body)
    local tick = tonumber(body.tick) or 0

    -- Snapshots arrive unreliably. A stale one must be dropped, not applied:
    -- applying it would move every entity backwards for one interval, which reads
    -- as a stutter and is often blamed on the renderer.
    if tick < self.lastTick then return end
    self.lastTick = tick

    self.snapshots = self.snapshots + 1
    self.snapAge = 0

    Rep.applyEntities(self, body.e or {}, {
        spawn = self.spawnEntity,
        apply = function(e, snap) self:applyToEntity(e, snap) end,
        onSpawn = function(e, snap)
            if snap.id == self.entityId then self.player = e end
            if self.onSpawn then self.onSpawn(self, e) end
        end,
        onDespawn = function(e)
            if e == self.player then self.player = nil end
            if self.onDespawn then self.onDespawn(self, e) end
        end,
        onUnknown = function(kindName, id)
            self:warn(('the server sent a %q (id %s) and this build has no such '
                       .. 'archetype; it will replicate as a position with no '
                       .. 'components'):format(tostring(kindName), tostring(id)))
        end,
    })

    if self.player and self.player.id ~= self.entityId then self.player = nil end
    if not self.player and self.entityId then self.player = self.byId[self.entityId] end
end

-- Applies one entity's snapshot. Everything the host owns is taken verbatim; the
-- local player is the single exception, and only for its transform.
function ClientMT:applyToEntity(e, snap)
    if e.id ~= self.entityId or not self.prediction then
        e:snapPrevious()
        e:applySnapshot(snap)
        return
    end

    local predX, predY, predAngle = e.x, e.y, e.angle

    -- Component state (health, ammo, anything a netFields declaration named) is
    -- applied unconditionally. This is the line that keeps "do not predict
    -- damage" true: the client has no other way to change these values.
    e:applySnapshot(snap)

    local errX, errY = e.x - predX, e.y - predY
    local errorDistance = math.sqrt(errX * errX + errY * errY)

    if errorDistance > self.snapThreshold then
        -- Take the host's answer outright and restart the interpolation from it.
        self.corrections = self.corrections + 1
        e:snapPrevious()
    else
        e.x = predX + errX * self.smoothing
        e.y = predY + errY * self.smoothing
    end

    -- Aim belongs to the client.
    e.angle = predAngle
end

Client.MT = ClientMT

return Client
