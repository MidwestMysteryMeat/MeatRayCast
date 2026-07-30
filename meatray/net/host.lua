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
local P           = require('meatray.net.protocol')

local Host = {}

Host.DEFAULT_PORT = 6789

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
        nextPeerId  = 1,
        localInput  = nil,
        localPlayer = nil,

        snapAccum   = 0,
        snapshotsSent = 0,
        worldSyncs  = 0,
        lastWorld   = {},
        stats       = { received = 0, dropped = 0, rejected = 0 },
    }, HostMT)

    self.clock  = Tick.new(self.tickRate)
    self.access = Access.new{
        password       = opts.password,
        onAuthenticate = opts.onAuthenticate,
        maxPlayers     = opts.maxPlayers or 8,
    }

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
        })
    end

    ---------------------------------------------------------------------
    -- Diagnostics, immediately and unprompted, because a host that nobody can
    -- reach must be told at the moment it starts rather than when a player asks.
    self.report = Diagnostics.classify{
        port       = self.port,
        bound      = bound and true or false,
        bindError  = bindError,
        lan        = self.beacon and self.beacon:active() or false,
        address    = opts.address or Diagnostics.localAddress(),
        external   = 'unknown',
        holePunch  = 'unsupported',
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

    for _, peer in pairs(self.peers) do
        if peer.joined and peer.entity and peer.input then
            self:_applyInput(peer.entity, peer.input, dt)
        end
    end

    if self.onStep then self.onStep(dt, self) end

    self.world:update(dt)
    self:reap()
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
                if peer.entity == e then peer.entity = nil end
            end
        end
    end
end

---------------------------------------------------------------------------
-- The frame
---------------------------------------------------------------------------

function HostMT:update(dt)
    dt = dt or 0

    self.transport:update(dt)
    self:pump()

    self.clock:advance(dt, function(step) self:step(step) end)

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

    if self.beacon then self.beacon:update(dt) end
end

function HostMT:sendSnapshot()
    local snapshot = {
        tick = self.clock.tickCount,
        e    = Rep.entitySnapshots(self.entities),
    }

    local packet = P.pack(P.SNAPSHOT, snapshot)
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

function HostMT:syncWorld()
    local current = self.world:snapshot()

    local delta
    for key, open in pairs(current) do
        if self.lastWorld[key] ~= open then
            delta = delta or {}
            delta[key] = open
        end
    end

    if not delta then return false end

    self.lastWorld = current
    self.worldSyncs = self.worldSyncs + 1
    self:broadcast(P.WORLD, { doors = delta })
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

    self.peers[key] = {
        key = key, handle = handle, address = address,
        joined = false, peerId = nil, entity = nil, input = nil, lastSeq = -1,
        name = nil,
    }
    self.peerCount = self.peerCount + 1
end

function HostMT:onDisconnect(handle)
    local key = self.transport:key(handle)
    local peer = self.peers[key]
    if not peer then return end

    self.peers[key] = nil
    self.peerCount = math.max(0, self.peerCount - 1)

    if peer.entity then peer.entity.dead = true end
    self:reap()

    if peer.joined then
        self:log(('%s left'):format(peer.name or tostring(peer.address)))
        if self.onPeerLeave then self.onPeerLeave(self, peer) end
    end
end

function HostMT:onReceive(handle, data, channel)
    local key = self.transport:key(handle)
    local peer = self.peers[key]
    if not peer then return end

    self.stats.received = self.stats.received + 1

    local kind, body, err = P.unpack(data)
    if not kind then
        self.stats.dropped = self.stats.dropped + 1
        return
    end

    if kind == P.JOIN then
        return self:handleJoin(peer, body)
    end

    -- Everything else requires a completed handshake. A peer that skips the join
    -- and starts sending inputs is either broken or probing; either way it gets
    -- nothing.
    if not peer.joined then
        self.stats.dropped = self.stats.dropped + 1
        return
    end

    if kind == P.INPUT then
        local seq = tonumber(body.seq) or 0
        -- Inputs travel unreliably, so an older one may still arrive after a
        -- newer one. Applying it would rewind the player by one interval.
        if seq >= peer.lastSeq then
            peer.lastSeq = seq
            peer.input = Rep.sanitiseInput(body)
        end

    elseif kind == P.COMMAND then
        if self.onCommand then
            local ok, result = pcall(self.onCommand, self, peer, body.name, body.body)
            if not ok then
                self:warn(('onCommand(%s) errored: %s'):format(tostring(body.name),
                                                               tostring(result)))
            end
        end

    elseif kind == P.CHAT then
        local text = tostring(body.text or ''):sub(1, 240)
        if text ~= '' then
            if self.onChat then self.onChat(self, peer, text) end
            self:broadcast(P.CHAT, { text = text, name = peer.name })
        end

    elseif kind == P.STATS then
        self:sendTo(peer, P.REPLY, self:statsReply())

    elseif kind == P.PING then
        self:sendTo(peer, P.PONG, { time = body.time }, P.CH_STREAM, false)

    elseif kind == P.LEAVE then
        self.transport:disconnect(peer.handle, 0)
        self:onDisconnect(peer.handle)
    end
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
    self:sendTo(peer, P.SNAPSHOT, {
        tick = self.clock.tickCount, e = Rep.entitySnapshots(self.entities),
    }, P.CH_RELIABLE, true)
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
