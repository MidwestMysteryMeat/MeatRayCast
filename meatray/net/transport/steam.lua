--[[
    meatray.net.transport.steam — Steam networking sockets, over the Steam
    Datagram Relay.

        MeatRay.net.host{ transport = 'steam' }
        MeatRay.net.join('steam:76561197960287930', { transport = 'steam' })

    ## Why this transport exists at all

    Every other transport in this engine needs a route between two machines. The
    direct one needs an inbound port; the punched one needs two routers to
    cooperate, which they do somewhere between 55% and 80% of the time; the relay
    one needs somebody to run a relay. This one needs none of them. `ConnectP2P`
    dials a *Steam account*, and Valve's relay network carries the session when a
    direct route cannot be found — measured from this machine, 25 usable relays
    across 32 points of presence, with no server of ours anywhere in it.

    That is also the one thing the open-source GameNetworkingSockets build
    explicitly cannot do: the code is the same, the relay network is not in it.
    So this file is not a fourth way of doing what enet already does. It is the
    only path here that works for a host who cannot open a port, will not run a
    relay, and has no intention of learning why either of those is a sentence.

    ## It is never required, and it must never be the reason a game will not run

    Nothing above this file mentions Steam. `transport = 'steam'` selects it and
    nothing else does, and every failure to reach Steam — no `luasteam` module, no
    Steam client running, no App ID, an old luasteam with no `ConnectP2P` — comes
    back out of `Steam.new` as a reason string, leaving `direct`, `lan`, `enet`
    and `relay` exactly as they were. Under plain LuaJIT with no Steam anywhere,
    constructing this transport is a two-line failure and the suite carries on.

    `require('luasteam')` is inside `available()`, never at file scope, so this
    module loads with no LOVE, no Steam and no DLL — which is what lets the
    headless test require it at all.

    ## Addresses are accounts, not endpoints

        steam:76561197960287930          the default virtual port
        steam:76561197960287930:6789     an explicit one
        76561197960287930                a bare SteamID64

    A Steam "virtual port" is not a UDP port. It is a number both ends agree on so
    one account can host more than one thing at once; nothing is bound and nothing
    is forwarded. `opts.port` is used as the virtual port when nothing more
    specific is given, so `net.host{ transport = 'steam' }` and a client joining
    `steam:<id>` meet on 6789 without either side saying so.

    `address(peer)` is `steam:<SteamID64>`, which makes ban-by-address a ban by
    *account*. That is strictly better than the IP bans the other transports can
    manage: an account survives a reconnect, a router reboot and a VPN, and two
    players behind one NAT are two accounts rather than one address.

    ## One byte of framing, and why

    Steam gives a connection one ordered reliable stream and one unreliable
    datagram service, with no channel number on either. This engine's protocol
    uses two channels, so each message carries its channel in a leading byte and
    the receiver strips it. The relay transport already sets this precedent
    (meatray/net/relaywire.lua) for the same reason.

    Reliability maps exactly; ordering does not, and the difference is stated
    rather than papered over. `CH_RELIABLE` is reliable and ordered on both. This
    transport's unreliable send is unordered, where ENet's is
    unreliable-*sequenced* and discards a packet that arrives after a newer one.
    Snapshots ride that channel, so a late one would show a player the past — and
    the client already refuses out-of-order snapshots by tick number, precisely
    because "a transport is allowed to be less careful than this one".

    ## What it deliberately does not implement

    `punch`, `open` and `localPort` are absent. Steam's traversal *is* the
    traversal, so a host on this transport reports hole punching as unsupported
    rather than arming an attempt nobody will make — the same shape the relay
    transport has, and the reason meatray/net/transport.lua made those methods
    optional. A client joining should pass `punch = false`.

    `ip(peer)` is absent too, and its absence is the honest answer: a Steam peer
    has no address this process can see, and inventing one would make a ban look
    like it was enforced against a machine when it was enforced against an
    account. `address(peer)` is the ban key.

    ## Process-wide state, held once

    `SteamAPI_Init` and the connection-status callback are per *process*, not per
    transport, and a listen server has a host and a client in one. So init is
    reference-counted here and the single status callback is a dispatcher that
    fans out to every live transport and then chains whatever the game had
    installed. A transport ignores connections that are not its own.

    If the game called `luasteam.Init()` itself before the first transport is
    built, this file notices — the interface tables are only populated by Init —
    and never claims ownership of it, because shutting down somebody else's Steam
    session would be a spectacular thing to do quietly.

    Closing the last transport does not shut Steam down either, and that one was
    paid for: `SteamAPI_Shutdown` followed by `SteamAPI_Init` in one process
    *segfaults* rather than failing, and that sequence is just "leave a server,
    join another one". Steam is started once and left running; `SteamT.shutdown()`
    stops it on the way out, and after that this transport refuses to be built
    again with a reason rather than taking the process with it.

    HEADLESS: no love, and no luasteam either until something asks for it.
]]

local Transport = require('meatray.net.transport')
local P         = require('meatray.net.protocol')

local SteamT = {}

-- The virtual port both ends default to. Deliberately the same number as the
-- engine's default UDP port, so the two topologies read the same in a log even
-- though only one of them involves a port at all.
SteamT.VIRTUAL_PORT = 6789

-- How many messages to lift out of the poll group per call, and how many times
-- to go round before giving the frame back. The product is the ceiling on
-- messages drained in one pump; it is high enough that no realistic session
-- reaches it and low enough that a peer flooding us cannot hold the loop.
SteamT.BATCH = 32
SteamT.MAX_BATCHES = 16

-- Steam reserves every close reason below 1000 for itself and only accepts
-- 1000..1999 from an application. This engine's disconnect codes are small
-- integers (0 for a normal leave, 1 for a kick), so they are shifted into the
-- application range rather than passed through, where Steam would reject them
-- and the far side would be told nothing at all.
SteamT.APP_END_MIN = 1000
SteamT.APP_END_MAX = 1999

local SteamMT = {}
SteamMT.__index = SteamMT

---------------------------------------------------------------------------
-- Process-wide state
---------------------------------------------------------------------------

local api          = nil    -- the luasteam module, once it has loaded
local refs         = 0      -- how many live transports are holding Steam open
local ownsInit     = false  -- did *we* start it, or did the game
local dispatching  = false  -- is our status callback installed
local chained      = nil    -- whatever callback the game had before us
local finished     = false  -- has Steam been shut down for good in this process
local live         = {}     -- [transport] = true

-- Loads luasteam without starting it. Separate from acquire() so a game can ask
-- "is this even possible here" without a side effect, and so the two very
-- different failures — no module, and a module that will not connect — get two
-- different sentences.
local function loadSteam()
    if api then return api end

    local ok, mod = pcall(require, 'luasteam')
    if not ok or type(mod) ~= 'table' then
        return nil, 'luasteam is unavailable: the Steam transport needs the '
                 .. 'luasteam module on package.cpath (luasteam.dll beside '
                 .. 'steam_api64.dll on Windows). Every other transport is '
                 .. 'unaffected; use enet, or relay.'
    end

    if type(mod.Init) ~= 'function' or type(mod.NetworkingSockets) ~= 'table' then
        return nil, 'the luasteam found on package.cpath is too old for this '
                 .. 'transport: it has no NetworkingSockets. Version 5 or later '
                 .. 'is needed.'
    end

    api = mod
    return api
end

-- True, or false plus a reason. Costs one `require` and nothing else.
function SteamT.available()
    local mod, err = loadSteam()
    if not mod then return false, err end
    return true
end

-- Was Steam already started by somebody else? The interface tables are empty
-- placeholders until Init fills them, so the presence of a real function on
-- NetworkingSockets is the signal — and it is a fact about the process rather
-- than a flag we set, which is what makes it trustworthy across a reload.
local function alreadyStarted(mod)
    return type(mod.NetworkingSockets.ConnectP2P) == 'function'
end

local function acquire()
    if finished then
        return nil, 'Steam was shut down in this process and cannot be started '
                 .. 'again: SteamAPI_Init after SteamAPI_Shutdown crashes rather '
                 .. 'than failing. Restart the game to use the Steam transport, '
                 .. 'or use enet for this session.'
    end

    local mod, err = loadSteam()
    if not mod then return nil, err end

    if refs == 0 and not alreadyStarted(mod) then
        local ok, started = pcall(mod.Init)
        if not ok then
            return nil, ('luasteam raised while starting Steam: %s'):format(tostring(started))
        end
        if not started then
            return nil, 'Steam would not start. The client has to be running, '
                     .. 'under the same user account as the game, and the game '
                     .. 'needs an App ID it owns — a steam_appid.txt beside the '
                     .. 'executable when it is not launched from Steam.'
        end
        ownsInit = true
    end

    if not alreadyStarted(mod) then
        -- Started, and useless. Shut it down again rather than leaving a Steam
        -- session open that nothing is holding and nothing will ever close —
        -- and mark the process finished with it, because a second Init after a
        -- Shutdown is the crash described on release() below.
        if ownsInit then
            ownsInit = false
            finished = true
            pcall(mod.Shutdown)
        end
        return nil, 'this luasteam build has no NetworkingSockets.ConnectP2P, '
                 .. 'which is the whole reason for this transport. It was most '
                 .. 'likely built against a Steamworks SDK older than 1.53.'
    end

    refs = refs + 1
    return mod
end

-- Closing the last transport does NOT shut Steam down, and that is a decision
-- rather than an oversight.
--
-- Observed, not deduced: with the obvious implementation — Init on the first
-- transport, Shutdown on the last — the integration harness for this file
-- segfaulted the moment a second host was built after the first had closed,
-- against a real Steam client. `SteamAPI_Shutdown` followed by
-- `SteamAPI_Init` in one process crashes; it does not return false. And that is
-- not an exotic sequence, it is *leave a server and join another one*, which is
-- the single most ordinary thing a player does.
--
-- So Steam is started once and left running for the life of the process, which
-- is how Steamworks is meant to be used anyway. A game that wants it stopped at
-- exit calls SteamT.shutdown() explicitly, and after that this transport
-- refuses to be built again with a reason instead of taking the process down.
local function release()
    refs = refs - 1
    if refs < 0 then refs = 0 end
end

-- Stops Steam for good in this process. Call it on the way out, if at all.
-- Returns true when it did something.
function SteamT.shutdown()
    if finished or not api or not ownsInit then return false end

    -- Put back whatever the game had installed before us. Clearing the upvalue
    -- without restoring the field would leave our closure in place forwarding to
    -- nobody, which is a way to silently delete somebody else's callback.
    if dispatching and type(api.NetworkingSockets) == 'table' then
        api.NetworkingSockets.OnSteamNetConnectionStatusChangedCallback = chained
    end

    for transport in pairs(live) do live[transport] = nil end

    dispatching = false
    chained     = nil
    refs        = 0
    ownsInit    = false
    finished    = true

    pcall(api.Shutdown)
    return true
end

-- One callback for the whole process, fanned out. Installed on first use rather
-- than at load, because the NetworkingSockets table does not exist until Init.
local function installDispatcher(mod)
    if dispatching then return end
    dispatching = true

    local NS = mod.NetworkingSockets
    chained = NS.OnSteamNetConnectionStatusChangedCallback

    NS.OnSteamNetConnectionStatusChangedCallback = function(data)
        for transport in pairs(live) do
            -- pcall so one transport's bad frame cannot stop another transport
            -- from ever hearing that its peers disconnected.
            pcall(transport.onStatus, transport, data)
        end
        if chained then pcall(chained, data) end
    end
end

---------------------------------------------------------------------------
-- Addresses
---------------------------------------------------------------------------

-- 'steam:<id>', 'steam://<id>', 'steam:<id>:<virtualPort>', or a bare SteamID64.
-- Returns the id as a *string*, because a SteamID64 needs 57 bits and a Lua 5.1
-- number carries 53 — passing one through tonumber() silently rounds it to a
-- different account.
function SteamT.parseAddress(address, defaultPort)
    if type(address) ~= 'string' or address == '' then
        return nil, 'a Steam address must be a string'
    end

    local text = address
    text = text:gsub('^steam://', '')
    text = text:gsub('^steam:', '')
    text = text:gsub('/+$', '')

    local id, port = text:match('^(%d+):(%d+)$')
    if not id then
        id = text:match('^(%d+)$')
        port = nil
    end

    if not id or #id < 10 then
        return nil, ('%q is not a Steam address; a Steam join needs '
                  .. 'steam:<SteamID64>'):format(tostring(address))
    end

    return id, tonumber(port) or defaultPort or SteamT.VIRTUAL_PORT
end

function SteamT.formatAddress(id, port)
    if port and port ~= SteamT.VIRTUAL_PORT then
        return ('steam:%s:%d'):format(tostring(id), port)
    end
    return 'steam:' .. tostring(id)
end

---------------------------------------------------------------------------
-- Construction
---------------------------------------------------------------------------

-- opts:
--   port               used as the virtual port when steamVirtualPort is absent
--   steamVirtualPort   the virtual port, explicitly
--   maxPeers           refused above this many, at connect
--   onLog              host.lua passes its whole options table through, so a
--                      host built the ordinary way gets its logger for free
function SteamT.new(opts)
    opts = opts or {}

    local mod, err = acquire()
    if not mod then return nil, err end

    installDispatcher(mod)

    local self = setmetatable({
        name     = 'steam',
        api      = mod,
        sockets  = mod.NetworkingSockets,
        utils    = mod.NetworkingUtils,

        vport    = opts.steamVirtualPort or opts.port or SteamT.VIRTUAL_PORT,
        maxPeers = opts.maxPeers or 32,
        channels = opts.channels or P.CHANNELS,

        listenSocket = nil,
        pollGroup    = nil,
        outgoing     = nil,     -- client side: the one peer we dialled

        peers   = {},           -- [key] = peer
        byConn  = {},           -- [HSteamNetConnection] = peer
        pending = {},           -- events waiting to be drained by :service
        serial  = 0,

        onLog = opts.onLog,
        stats = { sent = 0, received = 0, dropped = 0, refused = 0 },
    }, SteamMT)

    -- The relay network takes a few seconds to come up and nothing can be
    -- carried over it until it has. Asked for here rather than at the first
    -- connect, so the wait overlaps with the rest of startup instead of landing
    -- on the first player who tries to join.
    if self.utils and self.utils.InitRelayNetworkAccess then
        pcall(self.utils.InitRelayNetworkAccess)
    end

    self.identity = self:ownIdentity()

    live[self] = true
    return self
end

function SteamMT:log(text)
    if self.onLog then self.onLog('[steam] ' .. tostring(text)) end
end

-- This machine's SteamID64, as a string. nil when Steam will not say, which is
-- not fatal: it is only used to publish a join address.
function SteamMT:ownIdentity()
    local user = self.api.User
    if type(user) ~= 'table' or type(user.GetSteamID) ~= 'function' then return nil end

    local ok, id = pcall(user.GetSteamID)
    if not ok or id == nil then return nil end
    return tostring(id)
end

-- Everything a player needs to reach this host, as one string, for a chat
-- message or a server listing. nil before listen(), because there is nothing to
-- join yet and a join address for a host that is not listening is worse than
-- none at all.
function SteamMT:ticket()
    if not (self.listenSocket and self.identity) then return nil end
    return SteamT.formatAddress(self.identity, self.vport)
end

---------------------------------------------------------------------------
-- Peers
---------------------------------------------------------------------------

-- Steam reuses connection handles once a connection is gone, so a handle alone
-- would key a new player's peer record to the one who just left. The serial
-- makes the key unique for the life of the transport, which is what
-- transport.lua requires of it.
function SteamMT:newPeer(conn, address)
    self.serial = self.serial + 1
    return {
        conn    = conn,
        address = address or 'steam:unknown',
        key     = ('steam:%d:%d'):format(conn, self.serial),
        rtt     = 0,
    }
end

function SteamMT:track(peer)
    self.peers[peer.key]  = peer
    self.byConn[peer.conn] = peer

    if self.pollGroup then
        pcall(self.sockets.SetConnectionPollGroup, peer.conn, self.pollGroup)
    end
end

function SteamMT:forget(peer)
    self.peers[peer.key] = nil
    if self.byConn[peer.conn] == peer then self.byConn[peer.conn] = nil end
    if self.outgoing == peer then self.outgoing = nil end
end

function SteamMT:count()
    local n = 0
    for _ in pairs(self.peers) do n = n + 1 end
    return n
end

local function push(self, event)
    self.pending[#self.pending + 1] = event
end

-- 'steam:<SteamID64>' for the far end of a connection, read from Steam rather
-- than from whatever the joiner claimed. It is the ban key, so it may not be
-- something the peer can choose.
function SteamMT:remoteAddress(conn)
    local ok, got, info = pcall(self.sockets.GetConnectionInfo, conn)
    if not ok or not got or not info then return 'steam:unknown' end

    local identity = info.m_identityRemote
    if not identity then return 'steam:unknown' end

    local gotId, id = pcall(function() return identity:GetSteamID64() end)
    if not gotId or id == nil then return 'steam:unknown' end

    return 'steam:' .. tostring(id)
end

---------------------------------------------------------------------------
-- Listening and connecting
---------------------------------------------------------------------------

-- `opts.port` is the virtual port, not a UDP port. See the header: nothing is
-- bound, so this cannot fail the way a port clash fails, and the failures it
-- does have are Steam refusing to make a socket at all.
function SteamMT:listen(opts)
    opts = opts or {}

    self.vport    = opts.steamVirtualPort or opts.port or self.vport
    self.maxPeers = opts.maxPeers or self.maxPeers
    self.channels = opts.channels or self.channels

    local ok, socket = pcall(self.sockets.CreateListenSocketP2P, self.vport, 0, nil)
    if not ok or not socket or socket == 0 then
        return nil, ('Steam would not open a P2P listen socket on virtual port '
                  .. '%d: %s'):format(self.vport,
                                      ok and 'no socket was returned' or tostring(socket))
    end

    self.listenSocket = socket
    self:ensurePollGroup()

    self:log(('listening as %s'):format(tostring(self:ticket() or 'an unknown account')))
    return true
end

function SteamMT:ensurePollGroup()
    if self.pollGroup then return self.pollGroup end

    local ok, group = pcall(self.sockets.CreatePollGroup)
    if ok and group and group ~= 0 then self.pollGroup = group end
    return self.pollGroup
end

function SteamMT:connect(address)
    local id, port = SteamT.parseAddress(address, self.vport)
    if not id then return nil, port or 'bad Steam address' end

    self:ensurePollGroup()

    local built, identity = pcall(function()
        local wanted = self.api.newSteamNetworkingIdentity{}
        wanted:SetSteamID64(self.api.Extra.ParseUint64(id))
        return wanted
    end)
    if not built or not identity then
        return nil, ('could not build a Steam identity for %s: %s')
            :format(id, tostring(identity))
    end

    -- ConnectP2P can fail two ways and both are handled, because the fast one is
    -- easy to miss. It returns an invalid handle immediately when Steam can
    -- already tell the dial is hopeless — observed against an account on this
    -- machine with nothing listening on the virtual port — and otherwise returns
    -- a live handle whose failure arrives later as a disconnect event. A caller
    -- that only handled the second would report the first as a crash.
    local ok, conn = pcall(self.sockets.ConnectP2P, identity, port, 0, nil)
    if not ok or not conn or conn == 0 then
        return nil, ('Steam would not dial %s on virtual port %d: %s')
            :format(id, port,
                    ok and 'no connection was returned, which usually means that '
                        .. 'account is not hosting on that virtual port'
                        or tostring(conn))
    end

    local peer = self:newPeer(conn, 'steam:' .. id)
    self:track(peer)
    self.outgoing = peer

    -- Deliberately no connect event here. Steam reports Connected through the
    -- status callback, exactly as ENet reports it through service(), and a
    -- connect event pushed now would tell the client it had arrived before the
    -- far end had agreed to anything.
    return peer
end

---------------------------------------------------------------------------
-- The status callback
---------------------------------------------------------------------------

-- Called for every connection in the process, ours or not. Anything that is
-- neither an inbound connection on our listen socket nor a connection we are
-- already tracking belongs to somebody else and is left completely alone —
-- including not being closed, because closing another transport's connection
-- would be a very hard bug to find from the other side.
function SteamMT:onStatus(data)
    local mod   = self.api
    local conn  = data.m_hConn
    local info  = data.m_info
    local state = info and info.m_eState

    local peer = self.byConn[conn]

    if state == mod.k_ESteamNetworkingConnectionState_Connecting then
        if peer then return end                                   -- our own dial
        if not self.listenSocket then return end
        if info.m_hListenSocket ~= self.listenSocket then return end

        if self:count() >= self.maxPeers then
            self.stats.refused = self.stats.refused + 1
            self:closeHandle(conn, SteamT.APP_END_MIN, 'server is full', false)
            return
        end

        -- AcceptConnection returns an EResult, and k_EResultOK is 1. A raise and
        -- a refusal are both failures to accept, and both have to close the
        -- handle: a connection nobody accepted and nobody closed sits in Steam's
        -- table for the life of the process.
        local called, result = pcall(self.sockets.AcceptConnection, conn)
        if not called or result ~= 1 then
            self:closeHandle(conn, SteamT.APP_END_MIN, 'could not be accepted', false)
            return
        end

        local joined = self:newPeer(conn, self:remoteAddress(conn))
        self:track(joined)
        return
    end

    if not peer then return end

    if state == mod.k_ESteamNetworkingConnectionState_Connected then
        if peer.linked then return end
        peer.linked  = true
        peer.address = self:remoteAddress(conn)
        push(self, { type = 'connect', peer = peer })
        return
    end

    if state == mod.k_ESteamNetworkingConnectionState_ClosedByPeer
    or state == mod.k_ESteamNetworkingConnectionState_ProblemDetectedLocally then
        -- The handle has to be closed even though the connection is already
        -- over: Steam holds the handle until the application acknowledges it,
        -- and a session that never does leaks one per player.
        self:closeHandle(conn, 0, '', false)
        self:forget(peer)

        -- Emitted even for a peer that never reached Connected, which is what
        -- ENet does and is the difference between a join failing in a second
        -- with a reason and a join sitting on "connecting..." for fifteen.
        -- client.lua turns a disconnect received while connecting into 'failed'
        -- plus a reason; host.lua looks a disconnect up by key and returns
        -- quietly when it does not know the peer, which is exactly this case.
        push(self, { type = 'disconnect', peer = peer, data = info.m_eEndReason or 0 })
    end
end

---------------------------------------------------------------------------
-- Traffic
---------------------------------------------------------------------------

local function frame(channel, data)
    return string.char((channel or 0) % 256) .. data
end

function SteamMT:sendFlags(reliable)
    local mod = self.api
    if reliable == false then return mod.k_nSteamNetworkingSend_Unreliable end
    return mod.k_nSteamNetworkingSend_Reliable
end

function SteamMT:send(peer, data, channel, reliable)
    if not peer or not peer.conn or peer.gone then return false end
    if type(data) ~= 'string' then return false end

    local payload = frame(channel, data)
    local ok, result = pcall(self.sockets.SendMessageToConnection,
                             peer.conn, payload, #payload, self:sendFlags(reliable))

    -- k_EResultOK is 1. Anything else is a real refusal — a closed connection,
    -- a full send buffer — and is reported as a failed send rather than
    -- swallowed, because host.lua counts sends and a silent zero reads as an
    -- idle player rather than a broken link.
    if not ok or result ~= 1 then
        self.stats.dropped = self.stats.dropped + 1
        return false
    end

    self.stats.sent = self.stats.sent + 1
    return true
end

-- Steam has no broadcast, so this is a loop, and it is honest about that: the
-- cost is one send per peer either way. (The relay transport's broadcast is one
-- frame because there is a relay in the middle to fan it out. There is no middle
-- here — the SDR carries the session, it does not duplicate it.)
function SteamMT:broadcast(data, channel, reliable)
    for _, peer in pairs(self.peers) do
        self:send(peer, data, channel, reliable)
    end
end

---------------------------------------------------------------------------
-- Receiving
---------------------------------------------------------------------------

-- Runs Steam's callbacks and lifts whatever has arrived into `pending`.
--
-- Callbacks first, because that is what turns a Connecting into a connect event
-- and a dead link into a disconnect event; messages second, so a message that
-- arrived in the same frame as the connection completing is delivered after the
-- connect event and not before it.
function SteamMT:pump()
    pcall(self.api.RunCallbacks)
    pcall(self.sockets.RunCallbacks)

    local group = self.pollGroup
    if not group then return end

    for _ = 1, SteamT.MAX_BATCHES do
        local ok, count, messages = pcall(self.sockets.ReceiveMessagesOnPollGroup,
                                          group, SteamT.BATCH)
        if not ok or not count or count <= 0 then return end

        for i = 1, count do
            local message = messages[i]
            if message then
                self:absorb(message)
                pcall(function() message:Release() end)
            end
        end

        -- A partial batch means the queue is empty. A full one means there may
        -- be more, so go round again — up to the ceiling above.
        if count < SteamT.BATCH then return end
    end
end

-- One message, released by the caller whatever happens here. A message that
-- cannot be attributed is still counted, because "we dropped things" and "the
-- peer sent nothing" have to be distinguishable in the stats.
function SteamMT:absorb(message)
    local gotConn, conn = pcall(function() return message:GetConnection() end)
    local gotData, data = pcall(function() return message:GetData() end)

    if not (gotConn and gotData) or type(data) ~= 'string' or #data < 1 then
        self.stats.dropped = self.stats.dropped + 1
        return
    end

    local peer = self.byConn[conn]
    if not peer then
        self.stats.dropped = self.stats.dropped + 1
        return
    end

    self.stats.received = self.stats.received + 1
    push(self, {
        type    = 'receive',
        peer    = peer,
        data    = data:sub(2),
        channel = string.byte(data, 1) or 0,
    })
end

-- Steam keeps its own clock and its own threads, so there is no time to advance.
-- It is pumped here anyway: a host with no peers still has to hear that somebody
-- is knocking, and pumping only from service() would make that depend on the
-- caller draining a queue that is empty.
function SteamMT:update()
    if not self.api then return end
    self:pump()
end

function SteamMT:service()
    if #self.pending > 0 then return table.remove(self.pending, 1) end
    if not self.api then return nil end

    -- Pumped again here so this transport works for a caller that drains
    -- service() without ever calling update() — which is what the client's
    -- connect wait does. Running callbacks twice in a frame costs a function
    -- call with nothing to deliver.
    self:pump()

    if #self.pending > 0 then return table.remove(self.pending, 1) end
    return nil
end

---------------------------------------------------------------------------
-- Teardown
---------------------------------------------------------------------------

-- Steam only accepts 1000..1999 as an application close reason. See the note on
-- APP_END_MIN: passing this engine's small codes straight through would have
-- them rejected and the far side told nothing.
function SteamT.endReason(code)
    local n = tonumber(code) or 0
    if n <= 0 then return SteamT.APP_END_MIN end

    n = SteamT.APP_END_MIN + n
    if n > SteamT.APP_END_MAX then return SteamT.APP_END_MAX end
    return n
end

function SteamMT:closeHandle(conn, reason, debugText, linger)
    pcall(self.sockets.CloseConnection, conn, reason or 0,
          tostring(debugText or ''), linger and true or false)
end

function SteamMT:disconnect(peer, code)
    if not peer or peer.gone then return end
    peer.gone = true

    -- Flushed, then closed with linger, for the reason enet.lua flushes before
    -- disconnecting: a kick reason is sent a moment before the disconnect, and a
    -- close that discards the send queue would leave the kicked player with an
    -- unexplained drop instead of the reason the host gave.
    pcall(self.sockets.FlushMessagesOnConnection, peer.conn)
    self:closeHandle(peer.conn, SteamT.endReason(code), 'closed by the application', true)

    self:forget(peer)
end

-- Idempotent, and it has to be: host.lua closes its transport on a failed bind
-- and again on shutdown, and a second release() would take the process-wide
-- reference count below zero and shut Steam down under a session that is still
-- running on it.
function SteamMT:close()
    if not self.api then return end

    for _, peer in pairs(self.peers) do
        peer.gone = true
        pcall(self.sockets.FlushMessagesOnConnection, peer.conn)
        self:closeHandle(peer.conn, SteamT.APP_END_MIN, 'session closed', true)
    end

    self.peers   = {}
    self.byConn  = {}
    self.pending = {}
    self.outgoing = nil

    if self.pollGroup then
        pcall(self.sockets.DestroyPollGroup, self.pollGroup)
        self.pollGroup = nil
    end

    if self.listenSocket then
        pcall(self.sockets.CloseListenSocket, self.listenSocket)
        self.listenSocket = nil
    end

    live[self] = nil
    self.api = nil
    release()
end

---------------------------------------------------------------------------
-- Identity and liveness
---------------------------------------------------------------------------

function SteamMT:key(peer)     return peer and peer.key end
function SteamMT:address(peer) return peer and peer.address end

function SteamMT:rtt(peer)
    if not peer or not peer.conn or not self.api then return nil end

    local ok, result, status = pcall(self.sockets.GetConnectionRealTimeStatus, peer.conn, 0)
    if not ok or result ~= 1 or not status then return nil end

    local ping = status.m_nPing
    if type(ping) ~= 'number' or ping < 0 then return nil end

    peer.rtt = ping
    return ping
end

-- Steam measures liveness itself, and this is the call that makes its numbers
-- the engine's numbers rather than two watchdogs disagreeing. `limit` has no
-- equivalent — there is no retransmission factor to set — so it is accepted and
-- ignored, and the two millisecond budgets are applied.
function SteamMT:setTimeout(peer, limit, minimum, maximum)
    if not peer or not peer.conn or not self.api then return false end

    local mod = self.api
    local NU  = self.utils
    if type(NU) ~= 'table' or type(NU.SetConnectionConfigValueInt32) ~= 'function' then
        return false
    end

    local initial   = tonumber(minimum) or 5000
    local connected = tonumber(maximum) or 30000

    local okInitial = pcall(NU.SetConnectionConfigValueInt32, peer.conn,
                            mod.k_ESteamNetworkingConfig_TimeoutInitial, initial)
    local okLive    = pcall(NU.SetConnectionConfigValueInt32, peer.conn,
                            mod.k_ESteamNetworkingConfig_TimeoutConnected, connected)

    return (okInitial and okLive) and true or false
end

-- Deliberately absent: `punch`, `open`, `localPort` and `ip`. See the header for
-- why each one would be a lie rather than a limitation.

SteamT.SteamMT = SteamMT

Transport.register('steam', SteamT.new)

return SteamT
