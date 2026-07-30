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
        spawnEntity = opts.spawnEntity,
    }, ClientMT)

    self.clock = Tick.new(self.tickRate)

    local transport, transportErr = Transport.new(opts.transport or 'enet', opts)
    if not transport then return nil, transportErr end
    self.transport = transport

    local handle, connectErr = transport:connect(address)
    if not handle then
        transport:close()
        return nil, connectErr
    end
    self.peer = handle

    return self
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

    self.transport:update(dt)
    self:pump()

    if self.state ~= 'joined' then return end

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
            elseif self.state == 'joined' then
                self.state = 'disconnected'
                self.reason = self.reason or 'lost connection to the server'
            end

        elseif event.type == 'receive' then
            local kind, body = P.unpack(event.data)
            if kind then self:handle(kind, body) end
        end
    end
end

function ClientMT:handle(kind, body)
    if kind == P.ACCEPT then
        return self:handleAccept(body)

    elseif kind == P.REJECT then
        self.state = 'rejected'
        self.reason = body.reason or 'refused'
        self:log(('refused by the server: %s%s'):format(
            tostring(self.reason), body.detail and (' - ' .. body.detail) or ''))
        if self.onReject then self.onReject(self, self.reason, body.detail) end

    elseif kind == P.SNAPSHOT then
        return self:handleSnapshot(body)

    elseif kind == P.WORLD then
        if self.world and body.doors then self.world:applySnapshot(body.doors) end

    elseif kind == P.EVENT then
        if self.onEvent then self.onEvent(self, body.name, body.body) end

    elseif kind == P.CHAT then
        if self.onChat then self.onChat(self, body.name, body.text) end

    elseif kind == P.REPLY then
        self.stats = body
        if self.onStats then self.onStats(self, body) end

    elseif kind == P.KICK then
        self.state = 'kicked'
        self.reason = body.reason or 'kicked'
        self:log('kicked: ' .. tostring(self.reason))

    elseif kind == P.PONG then
        self.rtt = body.time
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
