--[[
    meatray.net.host — the authoritative side, in listen mode or dedicated.

    One object, one simulation, two deployments. A listen host has a local player
    and a window; a dedicated host has neither. Nothing else differs, and that is
    load-bearing: `mode` selects whether a local player is created and nothing
    about how the world is stepped, so moving a game from listen to dedicated is a
    launch flag. The moment those two paths had separate step functions, a bug
    would be able to exist in one and not the other, and the dedicated path is the
    one nobody plays while developing.

    The host owns the clock. `host:update(dt)` advances a fixed-step Tick, calls
    step() once per whole tick, and then does its networking — so the tick rate is
    a property of the server rather than of whatever framerate the host machine
    happens to manage. Snapshots go out on their own slower timer.

    What the engine decides, and what it refuses to:

      * It decides: who is admitted, what a snapshot contains, when one is sent,
        how an input becomes movement, what a world payload looks like, and that
        world mutation replicates.
      * It refuses to decide: what a command means. Firing a weapon, opening a
        door, buying a hat — those are rules, and rules are the game's. COMMAND
        messages are handed to `onCommand` and the engine has no built-in gameplay
        verbs. The one exception is STATS, which reports on the engine's own state
        and is how a client, a netgraph, and the two-process test all ask the host
        what it thinks is true.

    Usage:

        local host = MeatRay.net.host{
            mode = 'listen', world = world, entities = entities,
            discovery = 'lan',
            onStep = function(dt, host) runAI(dt, host.entities) end,
            onCommand = function(host, peer, name, body) ... end,
        }

        function love.update(dt) host:update(dt) end

    HEADLESS: no love.graphics. A host with the loopback transport needs no LOVE
    at all, which is what the replication tests use.
]]

local Entity      = require('meatray.sim.entity')
local Tick        = require('meatray.sim.tick')
local Transport   = require('meatray.net.transport')
local Discovery   = require('meatray.net.discovery')
local Diagnostics = require('meatray.net.diagnostics')
local Access      = require('meatray.net.access')
local Rep         = require('meatray.net.replication')
local LagComp     = require('meatray.net.lagcomp')
local P           = require('meatray.net.protocol')

local Host = {}

Host.DEFAULT_PORT = 6789

---------------------------------------------------------------------------
-- Flood control defaults
---------------------------------------------------------------------------

-- Minimum spacing between two accepted INPUT packets from one peer. This is the
-- *silent* tier: excess is dropped and nothing is recorded against the sender.
--
-- 120 a second sits well above any client's send rate (the default is 30) and
-- well above the tick rate that consumes them, so a peer whose packets bunch up
-- after a stall loses nothing it was going to use, and a peer sending five
-- thousand a second costs the host the same as one sending 120. Raise it if a
-- game raises `inputRate`; it must stay above whatever clients actually send.
Host.INPUT_INTERVAL = 1 / 120

-- The penalising tier, per message type, because these have genuinely different
-- human rates. A chat line is typed; a command is a trigger pull, and a trigger
-- pull at twelve a second is a person with a mouse wheel bound to fire, not an
-- attack. Getting this wrong in the tight direction is how a server mutes its own
-- players for playing.
Host.FLOOD = {
    [P.JOIN]    = { limit = 5,  per = 10, penalty = 10 },
    [P.COMMAND] = { limit = 60, per = 5,  penalty = 3 },
    [P.CHAT]    = { limit = 8,  per = 10, penalty = 5 },
    [P.STATS]   = { limit = 5,  per = 5,  penalty = 5 },
    [P.PING]    = { limit = 20, per = 5,  penalty = 5 },
    [P.LEAVE]   = { limit = 3,  per = 5,  penalty = 5 },
}

local HostMT = {}
HostMT.__index = HostMT

---------------------------------------------------------------------------
-- Construction
---------------------------------------------------------------------------

function Host.new(opts)
    opts = opts or {}

    if not opts.world then
        return nil, 'a host needs a world to be authoritative over'
    end

    local mode = opts.mode or 'listen'
    if mode ~= 'listen' and mode ~= 'dedicated' then
        return nil, ('a host runs in listen or dedicated mode, not %q'):format(tostring(mode))
    end

    -- Dirty-flag snapshots. A keyframe every `keyframeInterval` frames, partials
    -- in between, one shared baseline for every peer. `keyframeInterval = 1`
    -- turns it off outright: every frame becomes a keyframe, the baseline is
    -- never built, and the stream is byte for byte what it was before this
    -- existed — which is what the fragmentation probe wants when it is trying to
    -- measure a full snapshot.
    local keyframeInterval = tonumber(opts.keyframeInterval) or Rep.KEYFRAME_INTERVAL
    if keyframeInterval ~= keyframeInterval or keyframeInterval < 1 then
        keyframeInterval = 1
    end
    keyframeInterval = math.floor(keyframeInterval)

    local snapBaseline = nil
    if keyframeInterval > 1 then snapBaseline = Rep.newBaseline() end

    local self = setmetatable({
        mode        = mode,
        name        = opts.name or (mode == 'dedicated'
                        and 'MeatRayCast dedicated' or 'MeatRayCast listen'),
        map         = opts.map or 'procedural',
        port        = opts.port or Host.DEFAULT_PORT,

        world       = opts.world,
        entities    = opts.entities or {},
        worldSpec   = opts.worldSpec,

        tickRate     = opts.tickRate or 60,
        snapshotRate = opts.snapshotRate or 20,

        playerKind  = opts.playerKind or 'player',
        spawnPoint  = opts.spawnPoint,
        -- G3: how long a dead peer waits before the host builds them a new
        -- entity. false disables (a mode that wants elimination rounds owns
        -- its own deaths); the onPeerRespawn hook is where a game applies
        -- spawn protection, since the effect system is the game's, not ours.
        -- Written as a function, not an and/or chain: `false and x or y`
        -- yields y, which is exactly how respawn = false would have silently
        -- become "3 seconds".
        respawnDelay = (function()
            if opts.respawn == false then return false end
            if type(opts.respawn) == 'table' then
                return tonumber(opts.respawn.delay) or 3
            end
            return tonumber(opts.respawn) or 3
        end)(),
        onPeerRespawn = opts.onPeerRespawn,
        moveSpeed   = opts.moveSpeed or Rep.DEFAULT_MOVE_SPEED,
        turnSpeed   = opts.turnSpeed or Rep.DEFAULT_TURN_SPEED,

        onStep      = opts.onStep,
        onCommand   = opts.onCommand,
        onPeerJoin  = opts.onPeerJoin,
        onPeerLeave = opts.onPeerLeave,
        onChat      = opts.onChat,
        onWarning   = opts.onWarning,
        onLog       = opts.onLog,
        applyInput  = opts.applyInput,

        peers       = {},          -- [transport key] = peer record
        peerCount   = 0,
        punching    = {},          -- clients being punched at, and how many are left

        -- Position history for hit validation. On by default: a capture every
        -- 100ms of two numbers per entity is close to free, and a game that has
        -- to know to switch on "shots land where you aimed" will ship without it.
        -- Pass lagCompensation = false to turn it off.
        lagComp     = (opts.lagCompensation ~= false)
                        and LagComp.new{
                            interval = opts.lagCaptureInterval,
                            history  = opts.lagHistory,
                        } or nil,
        nextPeerId  = 1,
        localInput  = nil,
        localPlayer = nil,

        snapAccum   = 0,
        keyframeInterval = keyframeInterval,
        snapBaseline = snapBaseline,
        snapshotsSent = 0,
        -- Size of the last KEYFRAME on the wire, which is the number the
        -- fragment question is actually about: partials are smaller by
        -- construction, so a stream whose keyframes fit inside one datagram is a
        -- stream that never fragments. `snapshotPartialBytes` is the last partial
        -- and `snapshotByteTotal` divided by `snapshotsSent` is the average, for
        -- anyone measuring the win rather than the ceiling.
        snapshotBytes = 0,
        snapshotPartialBytes = 0,
        snapshotByteTotal = 0,
        keyframesSent = 0,
        snapshotFallbacks = 0,      -- snapshots the binary codec could not model
        worldSyncs  = 0,
        lastWorld   = {},
        lastTiles   = {},

        -- The host's own clock, in seconds since it came up. Everything that
        -- needs to know "how long ago" reads this rather than os.time, so the
        -- flood limiters and the liveness watchdog are both drivable by a test
        -- that never sleeps.
        now         = 0,

        stats       = {
            received = 0, dropped = 0, rejected = 0,
            malformed = 0,      -- failed to parse, or failed its schema
            wrongWay  = 0,      -- a client sending host->client traffic
            throttled = 0,      -- input dropped by the silent throttle
            limited   = 0,      -- semantic message refused by the penalising window
            stale     = 0,      -- an input that arrived after a newer one
            superseded = 0,     -- input replaced before a tick consumed it
            handlerErrors = 0,  -- a handler raised; always logged, never sent
            timedOut  = 0,
            punchesAsked = 0,   -- introductions the registry passed on
            punchesSent  = 0,   -- datagrams actually emitted at those clients
            punchesFailed = 0,  -- the transport refused to emit one
            punchesRefused = 0, -- more addresses at once than makes sense
        },
    }, HostMT)

    self.clock  = Tick.new(self.tickRate)
    self.access = Access.new{
        password       = opts.password,
        onAuthenticate = opts.onAuthenticate,
        maxPlayers     = opts.maxPlayers or 8,
    }

    ---------------------------------------------------------------------
    -- Liveness. Both of these are honoured; see HostMT:update and onConnect.
    --
    -- `peerTimeout` is deliberately long. ENet is already watching the link and
    -- will usually get there first; this is the backstop for a peer that is
    -- technically connected and has stopped saying anything, which ENet does not
    -- consider a fault. A joined client sends input at its input rate, so thirty
    -- seconds of silence really is a dead peer and not a slow one.
    self.peerTimeout  = opts.peerTimeout or 30
    self.timeoutLimit = opts.timeoutLimit or 32
    self.timeoutMin   = opts.timeoutMin or 5000
    self.timeoutMax   = opts.timeoutMax
                        or math.max(1000, math.floor(self.peerTimeout * 1000))

    ---------------------------------------------------------------------
    -- Flood control. Two tiers, and which tier a message goes through is fixed
    -- by the message, not by a runtime guess. See meatray/net/access.lua.
    self.inputThrottle = Access.throttle{
        interval = opts.inputInterval or Host.INPUT_INTERVAL,
    }

    self.floodBan = opts.floodBan or false
    self.onFlood  = opts.onFlood
    self.flood    = {}
    for kind, preset in pairs(Host.FLOOD) do
        local override = opts.flood and opts.flood[P.names[kind]]
        self.flood[kind] = Access.window{
            limit      = (override and override.limit)      or preset.limit,
            per        = (override and override.per)        or preset.per,
            penalty    = (override and override.penalty)    or preset.penalty or 5,
            escalate   = (override and override.escalate)   or preset.escalate or 2,
            maxPenalty = (override and override.maxPenalty) or preset.maxPenalty or 300,
            banAfter   = (override and override.banAfter)   or preset.banAfter,
        }
    end

    ---------------------------------------------------------------------
    -- Transport
    local transport, transportErr = Transport.new(opts.transport or 'enet', opts)
    if not transport then return nil, transportErr end
    self.transport = transport

    local bound, bindError = transport:listen{
        port     = self.port,
        bind     = opts.bind,
        maxPeers = self.access.maxPlayers + 4,   -- headroom for peers being refused
        channels = P.CHANNELS,
    }

    ---------------------------------------------------------------------
    -- Discovery. A failure here is never fatal: the host is already listening
    -- and direct connection by address cannot be broken by it.
    if bound and opts.discovery then
        self.beacon = Discovery.beacon(opts.discovery, {
            discoveryPort = opts.discoveryPort,
            info      = function() return self:info() end,
            onWarning = function(text) self:warn(text) end,

            -- Passed through rather than dropped. Without this the master
            -- backend has nowhere to announce to, degrades to unavailable, and
            -- the documented one-liner
            --
            --     net.host{ discovery = { 'lan', 'master' }, registries = {...} }
            --
            -- reports "needs at least one registry URL" about a URL the caller
            -- did supply. The whole feature was unreachable from the public API.
            registries = opts.registries,
            onLog      = function(text) self:log(text) end,

            -- A client asking to be introduced for a hole punch.
            --
            -- The default answer is to punch, because a host that is told
            -- somebody is trying to reach it and does nothing is the whole
            -- feature not happening. A game that supplies its own onPunch still
            -- wins outright -- it may be running a transport with its own
            -- traversal, or deliberately refusing strangers -- so this is a
            -- default and not a policy.
            onPunch    = opts.onPunch or function(peer) self:punch(peer) end,
        })
    end

    ---------------------------------------------------------------------
    -- Diagnostics, immediately and unprompted, because a host that nobody can
    -- reach must be told at the moment it starts rather than when a player asks.
    --
    -- The UDP self-test only runs once the port is bound, and only when it has not
    -- been answered already: it costs half a second in the worst case, which is
    -- worth paying at startup and not worth paying if the caller already knows.
    local udpOk, udpError = opts.udp, opts.udpError
    if bound and udpOk == nil then
        udpOk, udpError = Diagnostics.probeLoopbackUdp()
    end

    -- Whether a punch can happen at all, decided from facts rather than hoped
    -- for. It takes both halves: a discovery backend that started and can carry
    -- an introduction, and a transport that can emit a packet from the game
    -- socket. Either one missing and the host says punching is unsupported
    -- rather than quietly implying an attempt nobody will make.
    self.canPunch = (self.beacon and self.beacon.introduces
                     and self.transport.punch ~= nil) and true or false

    self.report = Diagnostics.classify{
        port       = self.port,
        bound      = bound and true or false,
        bindError  = bindError,
        udp        = udpOk,
        udpError   = udpError,
        lan        = self.beacon and self.beacon:active() or false,
        address    = opts.address or Diagnostics.localAddress(),
        external   = 'unknown',
        registry   = (self.beacon and self.beacon.introduces) and true or false,
        holePunch  = self.canPunch and 'armed' or 'unsupported',
        mode       = self.mode,
    }

    if not bound then
        -- Report before returning: the reason the port failed is the single most
        -- useful thing the caller can be told, and it is already formatted.
        self:log(self.report)
        if self.beacon then self.beacon:close() end
        transport:close()
        return nil, bindError or ('could not listen on UDP %d'):format(self.port)
    end

    self:log(self.report)
    self.lastWorld = self.world:snapshot()
    self.lastTiles = self.world:tileSnapshot()

    if self.mode == 'listen' and opts.localPlayer ~= false then
        self:addLocalPlayer(opts.localPlayer, opts.playerName)
    end

    return self
end

---------------------------------------------------------------------------
-- Logging
---------------------------------------------------------------------------

function HostMT:log(reportOrText)
    if type(reportOrText) == 'table' then
        for _, line in ipairs(Diagnostics.format(reportOrText)) do
            if self.onLog then self.onLog(line) else print(line) end
        end
        return
    end
    local line = ('%s %s'):format(Diagnostics.PREFIX, tostring(reportOrText))
    if self.onLog then self.onLog(line) else print(line) end
end

function HostMT:warn(text)
    if self.onWarning then self.onWarning(text) end
    self:log('! ' .. tostring(text))
end

---------------------------------------------------------------------------
-- Players
---------------------------------------------------------------------------

function HostMT:pickSpawn()
    if self.spawnPoint then
        local x, y, angle = self.spawnPoint(self)
        if x then return x, y, angle or 0 end
    end

    local spawn = self.world.spawn
    if spawn then return spawn.x, spawn.y, spawn.angle or 0 end

    for ty = 1, self.world.height do
        for tx = 1, self.world.width do
            if self.world:isWalkable(tx, ty) then return tx - 0.5, ty - 0.5, 0 end
        end
    end

    return 1.5, 1.5, 0
end

function HostMT:spawnPlayer(peerId, name)
    local x, y, angle = self:pickSpawn()

    local e
    if Entity.hasArchetype(self.playerKind) then
        e = Entity.spawn(self.playerKind, x, y)
    else
        self:warn(('no %q archetype is registered, so player %d is a bare entity')
                  :format(self.playerKind, peerId))
        e = Entity.new{ kind = self.playerKind, x = x, y = y }
    end

    e.angle = angle
    e:snapPrevious()

    local player = e:get('player')
    if player then
        player.peerId = peerId
        player.name = name or ('player %d'):format(peerId)
    end

    self.entities[#self.entities + 1] = e
    return e
end

-- The host's own avatar in listen mode. `existing` lets a game hand over an
-- entity it already made (the demo's world loader spawns one), so a listen host
-- does not end up with two players standing on the same tile.
function HostMT:addLocalPlayer(existing, name)
    local e = (type(existing) == 'table' and existing) or self:spawnPlayer(0, name or 'host')

    local player = e:get('player')
    if player then
        player.peerId = 0
        player.name = name or player.name or 'host'
    end

    local present = false
    for i = 1, #self.entities do
        if self.entities[i] == e then present = true; break end
    end
    if not present then self.entities[#self.entities + 1] = e end

    self.localPlayer = e
    return e
end

function HostMT:setLocalInput(input)
    self.localInput = input
end

function HostMT:players()
    local out = {}
    if self.localPlayer then
        out[#out + 1] = { peerId = 0, name = 'host', entity = self.localPlayer, local_ = true }
    end
    for _, peer in pairs(self.peers) do
        if peer.joined then
            out[#out + 1] = peer
        end
    end
    table.sort(out, function(a, b) return (a.peerId or 0) < (b.peerId or 0) end)
    return out
end

function HostMT:playerCount()
    local n = self.localPlayer and 1 or 0
    for _, peer in pairs(self.peers) do if peer.joined then n = n + 1 end end
    return n
end

-- D33: one row per connected peer, for RCON's `status`. Ordered by peer id so
-- an admin reading it twice sees the same list.
function HostMT:rconStatus()
    local rows = {}
    for _, peer in pairs(self.peers) do
        if peer.joined then
            rows[#rows + 1] = {
                name = peer.name, peerId = peer.peerId,
                address = peer.address,
            }
        end
    end
    table.sort(rows, function(a, b) return (a.peerId or 0) < (b.peerId or 0) end)
    return rows
end

function HostMT:info()
    return {
        name    = self.name,
        map     = self.map,
        players = self:playerCount(),
        max     = self.access.maxPlayers,
        port    = self.port,
        locked  = self.access:locked(),
        mode    = self.mode,
        version = P.VERSION,
    }
end

---------------------------------------------------------------------------
-- Simulation. One implementation, both modes.
---------------------------------------------------------------------------

function HostMT:step(dt)
    for i = 1, #self.entities do self.entities[i]:snapPrevious() end

    -- Local player first, so a listen host feels identical to a client that has
    -- prediction: both apply their own intent before anything else runs.
    if self.localPlayer and self.localInput then
        self:_applyInput(self.localPlayer, Rep.sanitiseInput(self.localInput), dt)
    end

    -- One input per peer per tick, and only ever one.
    --
    -- The input is *latched*, not queued: a peer sending at four times the tick
    -- rate overwrites its pending input three times and then has exactly one
    -- applied, so displacement follows the host's tick rate and not the sender's
    -- send rate. A queue would be the other obvious shape and it would be wrong
    -- twice over — a fast sender would bank movement, and a normal one would
    -- accumulate latency behind its own backlog.
    --
    -- The latch persisting across ticks is deliberate too: a held key that
    -- produced no packet this frame is still held.
    for _, peer in pairs(self.peers) do
        if peer.joined and peer.entity and peer.input then
            self:_applyInput(peer.entity, peer.input, dt)
            peer.inputsApplied = (peer.inputsApplied or 0) + 1
            peer.inputPending = false
        end
    end

    if self.onStep then self.onStep(dt, self) end

    self.world:update(dt)
    self:reap()
    self:stepRespawns(dt)

    -- F7: the vote clock runs on the fixed tick, so a paused host pauses it.
    -- update resolves the vote and fires its enact when it passes.
    if self.vote then self.vote:update(dt) end
end

function HostMT:_applyInput(entity, input, dt)
    if self.applyInput then
        return self.applyInput(entity, input, dt, self)
    end
    return Rep.applyInput(entity, input, dt, self.world, {
        moveSpeed = self.moveSpeed, turnSpeed = self.turnSpeed,
    })
end

-- Dead entities leave the authoritative list, which is all a client needs: an id
-- absent from a full snapshot is an id that is gone.
function HostMT:reap()
    for i = #self.entities, 1, -1 do
        local e = self.entities[i]
        if e.dead then
            table.remove(self.entities, i)
            if self.localPlayer == e then self.localPlayer = nil end
            for _, peer in pairs(self.peers) do
                if peer.entity == e then
                    peer.entity = nil
                    -- G3: the death starts the clock. The countdown runs on
                    -- the fixed tick (see step), so pausing the host pauses
                    -- the wait — the same rule the solo respawn keeps.
                    if self.respawnDelay then
                        peer.respawnIn = self.respawnDelay
                    end
                end
            end
        end
    end
end

-- G3: dead peers come back. Runs every fixed tick; a peer whose wait has
-- elapsed gets a fresh entity from the same spawnPlayer that made their
-- first, a targeted RESPAWN with the new id (the client rebinds off the next
-- snapshot exactly as it bound off ACCEPT), and the game's hook for spawn
-- protection. A peer who disconnected mid-wait is simply forgotten with the
-- rest of their record.
function HostMT:stepRespawns(dt)
    if not self.respawnDelay then return end
    for _, peer in pairs(self.peers) do
        if peer.joined and not peer.entity and peer.respawnIn then
            peer.respawnIn = peer.respawnIn - dt
            if peer.respawnIn <= 1e-9 then
                peer.respawnIn = nil
                peer.entity = self:spawnPlayer(peer.peerId, peer.name)
                self:sendTo(peer, P.RESPAWN, { entityId = peer.entity.id })
                if self.onPeerRespawn then self.onPeerRespawn(self, peer) end
                self:log(('%s respawned as entity %d')
                         :format(peer.name or peer.key, peer.entity.id))
            end
        end
    end
end

---------------------------------------------------------------------------
-- The frame
---------------------------------------------------------------------------

function HostMT:update(dt)
    dt = dt or 0
    self.now = self.now + dt

    self.transport:update(dt)
    self:pump()
    self:dropSilentPeers()

    self.clock:advance(dt, function(step) self:step(step) end)

    -- Remember where everything was, so a shot can be judged against the world
    -- the shooter actually saw rather than the one that exists by the time the
    -- packet lands. Captured after the step, so the newest frame is the state a
    -- snapshot would describe.
    if self.lagComp then self.lagComp:update(self.now, dt, self.entities) end

    -- World mutation is detected by diffing rather than by requiring gameplay
    -- code to announce it. A game that calls world:toggleDoor() directly — which
    -- is the obvious thing to write — replicates correctly without knowing the
    -- net layer exists.
    self:syncWorld()

    self.snapAccum = self.snapAccum + dt
    local interval = 1 / self.snapshotRate
    if self.snapAccum >= interval then
        -- Subtract rather than zero, so a slow frame does not silently lower the
        -- snapshot rate for the rest of the session.
        self.snapAccum = self.snapAccum % interval
        self:sendSnapshot()
    end

    -- Punches before the beacon, so a burst started by last frame's heartbeat is
    -- already going out when this frame's heartbeat adds to it.
    self:pumpPunches()
    if self.beacon then self.beacon:update(dt) end
end

-- The half-open connection: a peer that is technically still connected and has
-- stopped saying anything. ENet usually notices first, and this is the backstop
-- for the cases it does not — and for a transport that has no timeout of its own.
--
-- It is honoured, which is the whole point. A `timeout` field that nothing reads
-- is worse than no field: it documents behaviour the server does not have, and
-- the first person to find out is a player whose session filled up with ghosts.
function HostMT:dropSilentPeers()
    if not self.peerTimeout or self.peerTimeout <= 0 then return end

    local expired
    for _, peer in pairs(self.peers) do
        if (self.now - (peer.lastHeard or self.now)) > self.peerTimeout then
            expired = expired or {}
            expired[#expired + 1] = peer
        end
    end
    if not expired then return end

    for i = 1, #expired do
        local peer = expired[i]
        self.stats.timedOut = self.stats.timedOut + 1
        self:log(('%s stopped responding (%.0fs of silence); dropping it')
                 :format(peer.name or tostring(peer.address), self.peerTimeout))
        local handle = peer.handle
        self:onDisconnect(handle)
        self.transport:disconnect(handle, 1)
    end
end

---------------------------------------------------------------------------
-- Hole punching
--
-- The registry never relays and never confirms. All it does is tell this host
-- that somebody at an address is trying to reach it; the host's part is to send
-- one packet that way, from the game socket, so its own router has seen an
-- outbound packet on that port before the client's arrives. Whether that worked
-- is not knowable here and is not claimed anywhere -- the only evidence either
-- side ever gets is a connection that completes.
--
-- NOT IMPLEMENTED, and load bearing by its absence: there is no relay. When a
-- punch fails the client falls back to a plain direct attempt and then times out
-- with a reason. Measured success for direct connections is 55-80%, not the 90%
-- usually quoted (docs/MASTERSERVER.md has the sources), so this is a real
-- fraction of hosts and not a rounding error.
---------------------------------------------------------------------------

-- A punch is a single datagram, and a single datagram can be lost -- on a link
-- where the whole point is that nothing has got through yet, and where the cost
-- of losing it is a join that fails. So it is repeated a few times, spread out.
--
-- Four over three quarters of a second, chosen against the other clock in play:
-- the client's ENet peer retransmits its connect attempt for tens of seconds, so
-- the punch only has to land somewhere inside that window, and a burst wide
-- enough to survive a loss is worth more than one wide enough to survive an
-- outage.
Host.PUNCH_REPEATS = 4
Host.PUNCH_SPACING = 0.25

-- How many clients may be being punched at once, and why there is a ceiling at
-- all: an introduction makes this host send packets at an address it was handed.
-- That is a reflector. The registry is one the host chose, so this is not a hole
-- so much as a blast radius -- but a registry that is compromised, or simply
-- wrong, should not be able to turn every listed server into a packet source
-- pointed wherever it likes.
--
-- Bounding the concurrent targets bounds the rate, because every burst expires
-- in under a second: sixteen targets times four packets over 0.75s is about
-- eighty small datagrams a second and no amplification worth having (the
-- request that provokes each one is larger than the four it produces).
--
-- Sixteen, or the player cap if that is higher. A server admitting more
-- simultaneous joiners than it has slots inside three quarters of a second is
-- not a case worth sizing for.
Host.PUNCH_MAX_PENDING = 16

-- Called by the master beacon when the registry passes on an introduction.
-- `peer` is { address, port } -- the client's address as the REGISTRY saw it,
-- never as the client claimed it, which is the same rule that governs listings.
function HostMT:punch(peer)
    if type(peer) ~= 'table' or type(peer.address) ~= 'string' or peer.address == '' then
        return false
    end

    local port = tonumber(peer.port)
    if not port or port < 1 or port > 65535 then return false end

    self.stats.punchesAsked = self.stats.punchesAsked + 1

    if not self.transport.punch then
        -- Said once, and said as a limitation of the transport rather than as a
        -- failure of the network, because those have completely different fixes.
        if not self.saidNoPunch then
            self.saidNoPunch = true
            self:log(('the %s transport cannot hole punch, so clients that cannot '
                      .. 'reach UDP %d directly will not get in')
                     :format(tostring(self.transport.name), self.port))
        end
        return false
    end

    local address = Transport.formatAddress(peer.address, port)

    -- Re-requested before the burst finished: refill it rather than starting a
    -- second one. Two overlapping bursts at one address is twice the packets for
    -- no more chance of arriving.
    local pending = self.punching[address]
    if pending then
        pending.left = Host.PUNCH_REPEATS
        return true
    end

    local pendingCount = 0
    for _ in pairs(self.punching) do pendingCount = pendingCount + 1 end
    if pendingCount >= math.max(Host.PUNCH_MAX_PENDING, self.access.maxPlayers) then
        self.stats.punchesRefused = self.stats.punchesRefused + 1
        -- Once per second at most: whatever is producing these is producing a
        -- lot of them, and a log line per refusal would be the flood.
        if (self.now - (self.punchFloodLoggedAt or -1e9)) >= 1 then
            self.punchFloodLoggedAt = self.now
            self:warn(('being asked to punch at more addresses than makes sense '
                       .. '(%d at once); refusing the rest for now')
                      :format(pendingCount))
        end
        return false
    end

    self.punching[address] = { left = Host.PUNCH_REPEATS, nextAt = self.now }
    return self:emitPunch(address)
end

function HostMT:emitPunch(address)
    local entry = self.punching[address]
    if not entry then return false end

    entry.left = entry.left - 1
    entry.nextAt = self.now + Host.PUNCH_SPACING
    if entry.left <= 0 then self.punching[address] = nil end

    local ok, err = self.transport:punch(address)
    if not ok then
        self.stats.punchesFailed = self.stats.punchesFailed + 1
        self.punching[address] = nil
        self:warn(('could not punch towards %s: %s'):format(address, tostring(err)))
        return false
    end

    self.stats.punchesSent = self.stats.punchesSent + 1
    -- Logged on the first of a burst only. This is the one line that says the
    -- feature ran, so it is worth printing, and it is worth printing once.
    if entry.left == Host.PUNCH_REPEATS - 1 then
        self:log(('opening a path towards %s (%d packets); it may still fail, and '
                  .. 'nothing here can tell'):format(address, Host.PUNCH_REPEATS))
    end
    return true
end

function HostMT:pumpPunches()
    if next(self.punching) == nil then return end

    -- Collected before emitting: emitPunch removes finished entries, and
    -- mutating a table while iterating it with next() is undefined in Lua 5.1.
    local due
    for address, entry in pairs(self.punching) do
        if self.now >= entry.nextAt then
            due = due or {}
            due[#due + 1] = address
        end
    end
    if not due then return end

    table.sort(due)
    for i = 1, #due do self:emitPunch(due[i]) end
end

-- Snapshots are packed by the binary codec rather than the text serializer, and
-- the reason is delivery rather than bandwidth: past one MTU, ENet promotes a
-- fragmented unreliable packet to a reliable one, and a retransmitted snapshot is
-- strictly worse than a lost one. P.packSnapshot and P.MTU_SAFE_BYTES carry the
-- detail.
--
-- Most frames are partials: only what changed since the last keyframe, measured
-- against one baseline shared by every peer, so this is still ONE encode and one
-- packet for everybody and there is no per-peer acknowledgement state anywhere.
-- A keyframe is a full snapshot and is what a client converges on after any
-- amount of loss. See meatray/net/replication.lua for why the diff is against
-- the keyframe rather than the previous frame.
--
-- Two things are recorded rather than assumed. `snapshotBytes` is the last
-- keyframe, so a stats reply can be asked whether the stream is near the
-- fragment threshold instead of that being worked out from entity counts — the
-- keyframe is the largest frame the stream produces, so it is the one that
-- decides. `snapshotFallbacks` counts bodies the codec's layout could not model
-- and which therefore went out as text — normally zero forever, and if it is
-- not, the size guarantee is not holding and the first symptom would otherwise
-- be a latency report.
-- A full snapshot to one peer, reliable. Used for the join handoff and for a
-- client that noticed it dropped a keyframe and asked to be brought current
-- again. Deliberately does NOT touch the shared baseline: nobody else received
-- this frame, and folding it in would make the next partial depend on a peer
-- having seen a unicast.
--
-- `reason` is free-form diagnostics ('join', 'resync', …). Only 'resync' is
-- counted on the peer and host counters, so a join does not look like recovery.
function HostMT:sendKeyframeTo(peer, reason)
    if not peer or not peer.joined then return false end
    local baseline = self.snapBaseline
    local k = baseline and baseline.keyframes or 0
    local packet = P.packSnapshot({
        tick = self.clock.tickCount,
        e    = Rep.entitySnapshots(self.entities),
        full = true,
        k    = k,
    })
    self.transport:send(peer.handle, packet, P.CH_RELIABLE, true)
    if reason == 'resync' then
        peer.resyncs = (peer.resyncs or 0) + 1
        self.resyncsSent = (self.resyncsSent or 0) + 1
    end
    return true
end

function HostMT:sendSnapshot()
    local baseline = self.snapBaseline
    local full = Rep.keyframeDue(baseline, self.keyframeInterval)

    local list, removed, isKeyframe = Rep.snapshotFrame(self.entities, baseline, full)

    -- Keyframe generation the partials (or this keyframe) are measured against.
    -- After a keyframe, baseline.keyframes is the generation just written; after
    -- a partial it is still the generation of the last keyframe.
    local k = baseline and baseline.keyframes or 0

    local snapshot = { tick = self.clock.tickCount, e = list, full = isKeyframe, k = k }
    if not isKeyframe then snapshot.r = removed end

    local packet, compact, why = P.packSnapshot(snapshot)

    if not compact then
        self.snapshotFallbacks = self.snapshotFallbacks + 1
        if not self.saidFallback then
            self.saidFallback = true
            self:log(('snapshots are being sent as text because the binary codec '
                      .. 'cannot model this body (%s); they will fragment, and a '
                      .. 'fragmented snapshot is delivered reliably'):format(tostring(why)))
        end
    end

    if isKeyframe then
        self.snapshotBytes = #packet
        self.keyframesSent = self.keyframesSent + 1
    else
        self.snapshotPartialBytes = #packet
    end
    self.snapshotByteTotal = self.snapshotByteTotal + #packet

    local sent = 0
    for _, peer in pairs(self.peers) do
        if peer.joined then
            self.transport:send(peer.handle, packet, P.CH_STREAM, false)
            sent = sent + 1
        end
    end

    self.snapshotsSent = self.snapshotsSent + 1
    return sent
end

-- Diffs one keyed table of tile state against what was last sent. Doors and
-- destroyed tiles are two instances of the same shape, so they share the diff
-- rather than each growing their own copy of it.
local function diffKeyed(current, last)
    local delta
    for key, value in pairs(current) do
        if last[key] ~= value then
            delta = delta or {}
            delta[key] = value
        end
    end

    -- A key that disappeared is a change too: a door removed, or a wall repaired
    -- back to standing. Sending only the keys still present would leave a client
    -- that saw the wall come down believing it is still rubble forever.
    for key in pairs(last) do
        if current[key] == nil then
            delta = delta or {}
            delta[key] = 0
        end
    end

    return delta
end

function HostMT:syncWorld()
    local doors = self.world:snapshot()
    local tiles = self.world:tileSnapshot()

    local doorDelta = diffKeyed(doors, self.lastWorld)
    local tileDelta = diffKeyed(tiles, self.lastTiles)

    if not doorDelta and not tileDelta then return false end

    self.lastWorld = doors
    self.lastTiles = tiles
    self.worldSyncs = self.worldSyncs + 1

    -- Reliable, and deliberately so. A snapshot may be dropped because a newer
    -- one is always right behind it, but a world delta has no successor: miss
    -- the packet that says a wall came down and the client renders and collides
    -- against a wall that is not there until it reconnects.
    self:broadcast(P.WORLD, { doors = doorDelta, tiles = tileDelta })
    return true
end

-- B14: swap the whole world live. The demo rebuilds game.world/game.entities on
-- a map change and hands them here; the host adopts the new tables (it held the
-- old ones by reference, so a reassignment of the globals alone would strand
-- it), reseats its diff baselines, re-homes every player into the new world at
-- its spawn, and sends each client the full new world plus their new entity id.
--
-- opts.localPlayer  the listen host's own already-built avatar (kept, re-homed)
-- opts.map          the map name, for the client's server info line
-- opts.spawn        override spawn { x, y, angle }; else the world's own
function HostMT:changeWorld(world, entities, worldSpec, opts)
    if not world then return false, 'no world' end
    opts = opts or {}

    self.world     = world
    self.entities  = entities or {}
    self.worldSpec = worldSpec

    -- Fresh baselines, or the very next syncWorld would diff the new world
    -- against the old snapshot and broadcast a phantom delta.
    self.lastWorld = self.world:snapshot()
    self.lastTiles = self.world:tileSnapshot()

    -- Re-arm the pushwall -> resync hook on the new world (watchShape listeners
    -- live on the world object, so the old world's are gone with it).
    self.world:watchShape(function(_, _, _, kind)
        if kind == 'pushwall' then self:syncWorld() end
    end)

    -- Re-home the listen host's avatar: keep the entity the demo built, put it in
    -- the new list, and move it to the new spawn so it is not standing in a wall.
    if opts.localPlayer then
        local e = opts.localPlayer
        local present = false
        for i = 1, #self.entities do
            if self.entities[i] == e then present = true; break end
        end
        if not present then self.entities[#self.entities + 1] = e end
        local sx, sy, sa = self:pickSpawn()
        if opts.spawn then sx, sy, sa = opts.spawn.x, opts.spawn.y, opts.spawn.angle or 0 end
        e.x, e.y, e.angle = sx, sy, sa or 0
        e:snapPrevious()
        self.localPlayer = e
    end

    -- Every joined peer gets a brand-new entity in the new world; their old one
    -- died with the old entity list. Send each the full world and its new id.
    for _, peer in pairs(self.peers) do
        if peer.joined then
            peer.entity = self:spawnPlayer(peer.peerId, peer.name)
            self:sendTo(peer, P.MAPCHANGE, {
                world    = Rep.worldPayload(self.world, self.worldSpec),
                entityId = peer.entity.id,
                map      = opts.map,
            })
        end
    end

    self.worldSyncs = self.worldSyncs + 1
    return true
end

---------------------------------------------------------------------------
-- Sending
---------------------------------------------------------------------------

-- Reliable, to everyone who finished the handshake. A peer mid-join gets the
-- state it needs from its ACCEPT and first snapshot instead.
function HostMT:broadcast(kind, body)
    local packet = P.pack(kind, body)
    for _, peer in pairs(self.peers) do
        if peer.joined then
            self.transport:send(peer.handle, packet, P.CH_RELIABLE, true)
        end
    end
end

-- Runs `fn` against the world as `peer` saw it, then puts everything back.
--
--     host.onCommand = function(host, peer, name, body)
--         if name == 'fire' then
--             local hit = host:rewindFor(peer, function()
--                 return Collide.hitscan(host.world, x, y, dx, dy, host.entities)
--             end)
--         end
--     end
--
-- The engine supplies the rewind and refuses to decide what a hit means -- that
-- is a rule, and rules are the game's. It also refuses to take the client's word
-- for how far to rewind: the round trip comes from the transport, which measures
-- it, and the window is clamped inside lagcomp regardless.
--
-- Returns fn's result. With no history, or an unknown peer, fn still runs --
-- against the present, which is the honest degradation: worse aim compensation,
-- never a refusal to resolve the shot.
function HostMT:rewindFor(peer, fn)
    if not self.lagComp or not peer then return fn() end

    local rttMs = self.transport.rtt and self.transport:rtt(peer.handle) or nil
    local when = LagComp.aimTime(self.now, (rttMs or 0) / 1000, 1 / self.snapshotRate)

    return self.lagComp:withRewound(when, self.entities, fn)
end

-- What the host would rewind to for this peer, without doing it. For a netgraph
-- or a "why did that miss" diagnostic.
function HostMT:aimTimeFor(peer)
    if not peer then return self.now end
    local rttMs = self.transport.rtt and self.transport:rtt(peer.handle) or nil
    return LagComp.aimTime(self.now, (rttMs or 0) / 1000, 1 / self.snapshotRate)
end

function HostMT:sendTo(peer, kind, body, channel, reliable)
    self.transport:send(peer.handle, P.pack(kind, body),
                        channel or P.CH_RELIABLE, reliable ~= false)
end

-- Gameplay events: a shot was fired, something died, a pickup was taken. Reliable,
-- because they are events and not state — nothing later repeats them.
function HostMT:event(name, body, peer)
    if peer then
        self:sendTo(peer, P.EVENT, { name = name, body = body })
    else
        self:broadcast(P.EVENT, { name = name, body = body })
    end
end

function HostMT:chat(text, fromName)
    self:broadcast(P.CHAT, { text = text, name = fromName or self.name })
end

-- D33: turn RCON on. secret is the password (nil/empty leaves it off);
-- onMap(name) is called when an admin runs `map`. The Rcon acts on THIS host.
function HostMT:attachRcon(opts)
    opts = opts or {}
    local Rcon = require('meatray.net.rcon')
    self.rcon = Rcon.new{
        secret = opts.secret, host = self, onMap = opts.onMap,
        maxTries = opts.maxTries,
    }
    return self.rcon
end

-- F7: turn voting on. A passed vote is ENACTED by the host: kick removes the
-- target, map calls onMap, restart calls onRestart. The tally lives in
-- meatray.game.vote; this wires its onPass/onFail to real effects and the
-- wire. `update` must be called each tick (the host's step does it).
function HostMT:attachVote(opts)
    opts = opts or {}
    local Vote = require('meatray.game.vote')
    self.vote = Vote.new{
        duration = opts.duration, threshold = opts.threshold,
        cooldown = opts.cooldown,
        onPass = function(v)
            if v.kind == 'kick' then
                self:kick(v.args.target, 'vote-kicked')
            elseif v.kind == 'map' and opts.onMap then
                opts.onMap(v.args.map)
            elseif v.kind == 'restart' and opts.onRestart then
                opts.onRestart()
            end
            self:broadcast(P.VOTE, { result = 'pass', kind = v.kind })
        end,
        onFail = function(v)
            self:broadcast(P.VOTE, { result = 'fail', kind = v.kind })
        end,
    }
    return self.vote
end

---------------------------------------------------------------------------
-- World mutation helpers. Optional: the diff above catches direct mutation too.
---------------------------------------------------------------------------

function HostMT:setDoorOpen(tx, ty, open)
    local changed = self.world:setDoorOpen(tx, ty, open)
    if changed then self:syncWorld() end
    return changed
end

function HostMT:toggleDoor(tx, ty)
    local changed = self.world:toggleDoor(tx, ty)
    if changed then self:syncWorld() end
    return changed
end

function HostMT:spawn(kind, x, y, fields)
    local e = Entity.spawn(kind, x, y, fields)
    if not e then return nil, ('unknown archetype: %s'):format(tostring(kind)) end
    e:snapPrevious()
    self.entities[#self.entities + 1] = e
    return e
end

function HostMT:despawn(entity)
    if not entity then return false end
    entity.dead = true
    return true
end

---------------------------------------------------------------------------
-- Receiving
---------------------------------------------------------------------------

function HostMT:pump()
    while true do
        local event = self.transport:service()
        if not event then break end

        if event.type == 'connect' then
            self:onConnect(event.peer)
        elseif event.type == 'disconnect' then
            self:onDisconnect(event.peer)
        elseif event.type == 'receive' then
            self:onReceive(event.peer, event.data, event.channel)
        end
    end
end

function HostMT:onConnect(handle)
    local key = self.transport:key(handle)
    local address = self.transport:address(handle)

    -- A banned address is refused at connect, before it can send anything, so a
    -- ban costs the server one packet rather than a handshake.
    local banned, reason = self.access:isBanned(address)
    if banned then
        self:log(('refused %s: %s'):format(tostring(address), tostring(reason)))
        self.transport:send(handle, P.pack(P.REJECT, { reason = Access.BANNED }),
                            P.CH_RELIABLE, true)
        self.transport:disconnect(handle, 1)
        self.stats.rejected = self.stats.rejected + 1
        return
    end

    -- Told to give up on a silent peer, rather than holding the connection open
    -- forever waiting for one that is never coming back. Optional on the
    -- transport interface, so it is asked for rather than assumed.
    if self.transport.setTimeout then
        self.transport:setTimeout(handle, self.timeoutLimit,
                                  self.timeoutMin, self.timeoutMax)
    end

    self.peers[key] = {
        key = key, handle = handle, address = address,
        joined = false, peerId = nil, entity = nil, input = nil, lastSeq = -1,
        name = nil,
        lastHeard = self.now,
        inputPending = false,
        inputsReceived = 0, inputsApplied = 0, inputsSuperseded = 0,
    }
    self.peerCount = self.peerCount + 1
end

function HostMT:onDisconnect(handle)
    local key = self.transport:key(handle)
    local peer = self.peers[key]
    if not peer then return end

    self.peers[key] = nil
    self.peerCount = math.max(0, self.peerCount - 1)

    -- Drop the peer's flood bookkeeping with the peer. Keeping it would leak a
    -- table per connection for the life of the process, and a key is never
    -- reused by a later connection so there is nothing to remember. Bans are the
    -- thing that outlives a connection, and those live in Access.
    self.inputThrottle:forget(key)
    for _, window in pairs(self.flood) do window:forget(key) end

    if peer.entity then peer.entity.dead = true end
    self:reap()

    -- F7: a voter who leaves is removed from any live vote, so its threshold
    -- is of who is still here — otherwise a departed no-voter could sink a
    -- vote the room actually wanted.
    if self.vote and peer.peerId then self.vote:removeVoter(peer.peerId) end
    -- And RCON: their session dies with the connection.
    if self.rcon then self.rcon:close(key) end

    if peer.joined then
        self:log(('%s left'):format(peer.name or tostring(peer.address)))
        if self.onPeerLeave then self.onPeerLeave(self, peer) end
    end
end

---------------------------------------------------------------------------
-- Dispatch
---------------------------------------------------------------------------

--[[
    One entry per tag the host accepts, keyed by the tag itself.

    This was an if/elseif chain, and the chain had two properties worth losing.
    A tag that fell off the end did nothing, silently, with no way to notice
    short of reading the whole chain against the whole registry; and there was no
    way for a test to ask "what does the host handle?" without grepping for the
    comparisons, which is a text search standing in for a fact the program
    already knows.

    As a table, `meatray.net.protocol`'s direction registry and this set of keys
    are two lists that a test diffs directly — no regex, no allowlist for
    handlers that are one indirection away from a literal comparison, and an
    unhandled tag is a missing key rather than an invisible fallthrough.

    Every handler here runs having already been checked for direction, schema and
    rate. None of them validates; none of them needs to.
]]

local handlers = {}

handlers[P.JOIN] = function(self, peer, body)
    self:handleJoin(peer, body)
end

handlers[P.INPUT] = function(self, peer, body)
    -- Inputs travel unreliably, so an older one may still arrive after a newer
    -- one. Applying it would rewind the player by one interval.
    local seq = body.seq or 0
    if seq < peer.lastSeq then
        self.stats.stale = self.stats.stale + 1
        return
    end

    -- At most one input is consumed per tick (see HostMT:step). Anything that
    -- arrives between two ticks replaces the pending one rather than stacking
    -- behind it, so a client sending at four times the tick rate moves at the
    -- tick rate — and the three it wasted are counted rather than merely gone.
    if peer.inputPending then
        peer.inputsSuperseded = (peer.inputsSuperseded or 0) + 1
        self.stats.superseded = self.stats.superseded + 1
    end

    peer.lastSeq = seq
    peer.input = Rep.sanitiseInput(body)
    peer.inputPending = true
    peer.inputsReceived = (peer.inputsReceived or 0) + 1
end

handlers[P.COMMAND] = function(self, peer, body)
    -- Built-in: a client that detected a missed keyframe asks for one full
    -- snapshot on the reliable channel. Handled here rather than through
    -- onCommand so a game that supplies no command handler still recovers, and
    -- so a game handler cannot swallow or rename the request.
    if body.name == 'resync' then
        self:sendKeyframeTo(peer, 'resync')
        return
    end

    if not self.onCommand then return end
    -- The inner pcall stays so the log says *whose* code failed. The outer one in
    -- onReceive would only be able to say "the command handler errored", which
    -- points at the engine for a fault in the game.
    local ok, result = pcall(self.onCommand, self, peer, body.name, body.body)
    if not ok then
        self.stats.handlerErrors = self.stats.handlerErrors + 1
        self:warn(('onCommand(%s) errored: %s'):format(tostring(body.name),
                                                       tostring(result)))
    end
end

handlers[P.CHAT] = function(self, peer, body)
    local text = body.text:sub(1, 240)
    if text == '' then return end
    if self.onChat then self.onChat(self, peer, text) end
    -- Note the direction change in the payload: a client sends `{ text }` and the
    -- host broadcasts `{ text, name }`. The name is the host's to attach; a
    -- client trusted to name the speaker could name anyone.
    self:broadcast(P.CHAT, { text = text, name = peer.name })
end

-- D33: a peer authenticating to, or driving, RCON. The peer's transport key is
-- the session id, so an admin's auth state lives and dies with its connection.
-- Absent RCON (no secret set) refuses everything, so a server that never
-- enabled it cannot be administered by anyone.
handlers[P.RCON] = function(self, peer, body)
    if not self.rcon then
        self:sendTo(peer, P.RCON, { ok = false, reply = 'rcon not enabled' })
        return
    end
    local id = peer.key
    if self.rcon.sessions[id] == nil then self.rcon:open(id) end

    if body.auth ~= nil then
        local ok, why = self.rcon:auth(id, tostring(body.auth))
        self:sendTo(peer, P.RCON, { ok = ok, reply = ok and 'authenticated'
                                    or tostring(why) })
        if not ok then
            self:log(('rcon: failed auth from %s (%s)'):format(
                tostring(peer.address), tostring(why)))
        end
        return
    end

    if body.cmd ~= nil then
        local ok, reply = self.rcon:exec(id, tostring(body.cmd))
        self:sendTo(peer, P.RCON, { ok = ok, reply = tostring(reply) })
        if ok then
            self:log(('rcon: %s ran %q'):format(tostring(peer.address),
                                                tostring(body.cmd)))
        end
        return
    end

    self:sendTo(peer, P.RCON, { ok = false, reply = 'rcon: auth or cmd expected' })
end

-- F7: a peer calling a vote or casting a ballot. The host owns the tally
-- (meatray.game.vote), so a client cannot forge a result — it can only
-- propose and answer. Absent voting (not attached) refuses.
handlers[P.VOTE] = function(self, peer, body)
    if not self.vote then return end

    if body.call ~= nil then
        local electorate = {}
        for _, p in pairs(self.peers) do
            if p.joined then electorate[#electorate + 1] = p.peerId end
        end
        if self.localPlayer then electorate[#electorate + 1] = 0 end
        local args = { by = peer.peerId, map = body.map, target = body.target }
        local vote, why = self.vote:call(tostring(body.call), args, electorate)
        if not vote then
            self:sendTo(peer, P.VOTE, { error = tostring(why) })
        else
            self:broadcast(P.VOTE, { state = self.vote:status() })
        end
        return
    end

    if body.cast ~= nil then
        self.vote:cast(peer.peerId, body.cast == true or body.cast == 1)
        self:broadcast(P.VOTE, { state = self.vote:status() })
        return
    end
end

handlers[P.STATS] = function(self, peer)
    self:sendTo(peer, P.REPLY, self:statsReply())
end

handlers[P.PING] = function(self, peer, body)
    self:sendTo(peer, P.PONG, { time = body.time }, P.CH_STREAM, false)
end

handlers[P.LEAVE] = function(self, peer)
    self.transport:disconnect(peer.handle, 0)
    self:onDisconnect(peer.handle)
end

Host.handlers = handlers

---------------------------------------------------------------------------

-- Applies the tier appropriate to the tag. Returns true when the message may
-- proceed.
function HostMT:_permit(peer, kind)
    if kind == P.INPUT then
        -- Silent tier. No strike, no mute, no ban — ever. An input stream that
        -- bunches up after a stall is a laggy player, and running it through the
        -- penalising limiter below is how a server throws its own players out.
        if self.inputThrottle:allow(peer.key, self.now) then return true end
        self.stats.throttled = self.stats.throttled + 1
        return false
    end

    local window = self.flood[kind]
    if not window then return true end

    -- JOIN is limited by address rather than by connection, because a peer that
    -- reconnects to retry the handshake gets a new key every time.
    local subject = (kind == P.JOIN) and (peer.address or peer.key) or peer.key
    local ok, _, retryAfter, violations, wantsBan = window:check(subject, self.now)
    if ok then return true end

    self.stats.limited = self.stats.limited + 1

    -- Logged once per strike rather than once per refused packet, or the log
    -- becomes the flood.
    if violations and violations > (peer.floodStrikes or 0) then
        peer.floodStrikes = violations
        self:warn(('%s is sending %s faster than a person can; ignoring it for '
                   .. '%.0fs (strike %d)')
                  :format(peer.name or tostring(peer.address), P.names[kind],
                          retryAfter or 0, violations))
        if self.onFlood then
            self.onFlood(self, peer, P.names[kind], retryAfter, violations)
        end
        if wantsBan and self.floodBan then
            self:ban(peer, 'flooding')
        end
    end

    return false
end

function HostMT:onReceive(handle, data, channel)
    local key = self.transport:key(handle)
    local peer = self.peers[key]
    if not peer then return end

    self.stats.received = self.stats.received + 1
    peer.lastHeard = self.now

    -- Parse errors and handler errors are kept strictly apart, and this is the
    -- only place either is decided.
    --
    -- P.unpack never raises: it returns nil plus a reason for anything malformed,
    -- oversized or unknown, and that is what "malformed" means here and nowhere
    -- else. No pcall below produces the same shape, so a crash inside a handler
    -- can never be reported — to a player or to a log — as a bad packet. The
    -- alternative is one try block around both, which turns every server bug into
    -- a protocol complaint on somebody else's machine and logs neither.
    local kind, body, why = P.unpack(data, P.limits)
    if not kind then
        self.stats.malformed = self.stats.malformed + 1
        self.stats.dropped = self.stats.dropped + 1
        self:_noteMalformed(peer, why)
        return
    end

    -- A client sending host->client traffic is claiming to be the server. There
    -- is no handler for it and there must never be one.
    if not P.travels(kind, P.C2S) then
        self.stats.wrongWay = self.stats.wrongWay + 1
        self.stats.dropped = self.stats.dropped + 1
        return
    end

    -- Whole-message validation, before any handler sees a field. A body that
    -- fails is discarded entire; nothing is half-applied.
    local valid, badField = P.check(kind, body)
    if not valid then
        self.stats.malformed = self.stats.malformed + 1
        self.stats.dropped = self.stats.dropped + 1
        self:_noteMalformed(peer, ('%s: %s'):format(P.names[kind], badField))
        return
    end

    -- Everything but the join requires a completed handshake. A peer that skips
    -- the join and starts sending inputs is either broken or probing; either way
    -- it gets nothing.
    if kind ~= P.JOIN and not peer.joined then
        self.stats.dropped = self.stats.dropped + 1
        return
    end

    if not self:_permit(peer, kind) then return end

    local handler = handlers[kind]
    if not handler then
        -- Unreachable while the contract test passes; kept because "unreachable"
        -- is a claim about today's registry, not a property of the code.
        self.stats.dropped = self.stats.dropped + 1
        return
    end

    local ok, err = pcall(handler, self, peer, body)
    if not ok then
        -- Always logged, and always with the tag, because the one thing worse
        -- than a handler that crashes is a handler that crashes anonymously.
        self.stats.handlerErrors = self.stats.handlerErrors + 1
        self:warn(('the %s handler errored: %s'):format(P.names[kind], tostring(err)))
    end
end

-- Malformed traffic is normal on a public port and must not be able to fill a
-- disk. One line per peer per second, with a running count, says the same thing
-- for free.
function HostMT:_noteMalformed(peer, why)
    if (self.now - (peer.malformedLoggedAt or -1e9)) < 1 then
        peer.malformedSince = (peer.malformedSince or 0) + 1
        return
    end
    local extra = peer.malformedSince or 0
    peer.malformedLoggedAt = self.now
    peer.malformedSince = 0
    self:log(('dropped a bad packet from %s: %s%s')
             :format(tostring(peer.address), tostring(why),
                     extra > 0 and (' (+%d more since)'):format(extra) or ''))
end

function HostMT:handleJoin(peer, body)
    if peer.joined then return end

    local ok, reason, detail = self.access:admit({
        address     = peer.address,
        password    = body.password,
        credentials = body.credentials,
        name        = body.name,
        version     = body.version,
    }, {
        players = self:playerCount(),
        version = P.VERSION,
    })

    if not ok then
        self.stats.rejected = self.stats.rejected + 1
        self:log(('refused %s: %s%s'):format(tostring(peer.address), tostring(reason),
                                             detail and (' - ' .. detail) or ''))
        self:sendTo(peer, P.REJECT, { reason = reason, detail = detail })
        self.transport:disconnect(peer.handle, 1)
        self.peers[peer.key] = nil
        self.peerCount = math.max(0, self.peerCount - 1)
        return
    end

    peer.joined = true
    peer.peerId = self.nextPeerId
    self.nextPeerId = self.nextPeerId + 1
    peer.name = tostring(body.name or ('player %d'):format(peer.peerId)):sub(1, 32)
    peer.entity = self:spawnPlayer(peer.peerId, peer.name)

    self:sendTo(peer, P.ACCEPT, {
        peerId       = peer.peerId,
        entityId     = peer.entity.id,
        name         = self.name,
        map          = self.map,
        mode         = self.mode,
        tickRate     = self.tickRate,
        snapshotRate = self.snapshotRate,
        moveSpeed    = self.moveSpeed,
        turnSpeed    = self.turnSpeed,
        idBase       = Rep.CLIENT_ID_BASE,
        world        = Rep.worldPayload(self.world, self.worldSpec),
    })

    self:log(('%s joined from %s as peer %d')
             :format(peer.name, tostring(peer.address), peer.peerId))

    if self.onPeerJoin then self.onPeerJoin(self, peer) end

    -- An immediate snapshot rather than waiting up to 50 ms for the next tick:
    -- the join feels instant and the client has something to interpolate from
    -- before it draws a frame.
    -- Reliable, unlike the stream, because there is no successor to fall back on
    -- yet: this is the frame the client draws before the first stream snapshot
    -- arrives. Still packed by the binary codec, so a joining client and a playing
    -- one are decoding the same format rather than two.
    --
    -- A keyframe, necessarily — a client with no baseline can only be told
    -- everything — and one that deliberately does NOT touch the shared baseline,
    -- because nobody else received it. The next partial the joiner sees is a diff
    -- against an older keyframe than the frame it is holding, and that is
    -- harmless: a partial carries absolute values, so applying one to a fresher
    -- state leaves the state fresh.
    self:sendKeyframeTo(peer, 'join')
end

function HostMT:statsReply()
    local doorsOpen = 0
    for _, open in pairs(self.world:snapshot()) do
        if open == 1 then doorsOpen = doorsOpen + 1 end
    end

    return {
        players       = self:playerCount(),
        peers         = self.peerCount,
        entities      = #self.entities,
        doorsOpen     = doorsOpen,
        tick          = self.clock.tickCount,
        snapshotsSent = self.snapshotsSent,
        -- The last keyframe, which is the frame the fragment threshold is about.
        snapshotBytes = self.snapshotBytes,
        -- And the rest of what a bandwidth measurement needs, so the dirty-flag
        -- win can be read off a running server instead of reasoned about.
        snapshotPartialBytes = self.snapshotPartialBytes,
        snapshotByteTotal    = self.snapshotByteTotal,
        keyframesSent        = self.keyframesSent,
        keyframeInterval     = self.keyframeInterval,
        -- Reported rather than merely logged, so a peer measuring the snapshot
        -- stream can tell "small packets" from "small packets because the codec
        -- is working" without reading the host's console.
        snapshotFallbacks = self.snapshotFallbacks,
        worldSyncs    = self.worldSyncs,
        mode          = self.mode,
        map           = self.map,
        name          = self.name,
    }
end

---------------------------------------------------------------------------
-- Moderation
---------------------------------------------------------------------------

-- Accepts a peer record, a transport key, or a peerId, because at the point you
-- want to kick someone you have whichever of those the UI happened to hand you.
function HostMT:findPeer(which)
    if type(which) == 'table' then return which end
    if self.peers[which] then return self.peers[which] end
    for _, peer in pairs(self.peers) do
        if peer.peerId == which or peer.name == which then return peer end
    end
    return nil
end

function HostMT:kick(which, reason)
    local peer = self:findPeer(which)
    if not peer then return false, 'no such peer' end

    self:sendTo(peer, P.KICK, { reason = reason or 'kicked' })
    self:log(('kicked %s: %s'):format(peer.name or peer.key, reason or 'kicked'))

    local handle = peer.handle
    self:onDisconnect(handle)
    self.transport:disconnect(handle, 1)
    return true
end

function HostMT:ban(which, reason)
    local peer = self:findPeer(which)
    local address = peer and peer.address or which

    local ok, ip = self.access:ban(address, reason)
    if not ok then return false, ip end

    self:log(('banned %s: %s'):format(tostring(ip), reason or 'banned'))
    if peer then self:kick(peer, reason or Access.BANNED) end
    return true, ip
end

function HostMT:unban(address) return self.access:unban(address) end
function HostMT:bans() return self.access:banned() end

---------------------------------------------------------------------------

function HostMT:alpha()
    return self.clock:alpha()
end

function HostMT:close()
    if self.beacon then self.beacon:close(); self.beacon = nil end
    if self.transport then
        for _, peer in pairs(self.peers) do
            self.transport:send(peer.handle, P.pack(P.KICK, { reason = 'server closed' }),
                                P.CH_RELIABLE, true)
        end
        self.transport:close()
    end
    self.peers = {}
    self:log('server closed')
end

Host.MT = HostMT

return Host
