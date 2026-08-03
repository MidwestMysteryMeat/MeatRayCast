--[[
    meatray.net.protocol — message types, channels, and the packet envelope.

    A packet is one tag byte followed by a serialised body. The tag is a byte and
    not a word because it is the one field that appears in every packet: at 20
    snapshots a second per player, a seven-character type name is bandwidth spent
    on saying the same thing over and over.

    Two channels, and which one a message takes is a design decision rather than
    a convenience:

      CH_RELIABLE  joins, world mutation, commands, chat, kicks. Anything where
                   losing the message loses information that cannot be recovered
                   from a later one. A door that failed to open stays wrong
                   forever; it must be resent.

      CH_STREAM    snapshots and inputs, sent unreliably. Both are *state*, not
                   events: the next one supersedes the last, so retransmitting a
                   stale one costs latency and buys nothing. A dropped snapshot
                   is one interpolation gap; a resent snapshot is a player seeing
                   the past.

    That is also why discrete actions (fire, use) travel as COMMAND on the
    reliable channel rather than as flags inside INPUT. A held movement key is
    state and can be sampled; a trigger pull is an event and must arrive.

    HEADLESS: no LOVE. Plain Lua so the replication tests need no sockets.
]]

local Serialize = require('meatray.net.serialize')
local SnapCodec = require('meatray.net.snapcodec')

local P = {}

-- Bumped whenever the wire format changes incompatibly. A client with the wrong
-- version is rejected with a message that says so, rather than desynchronising
-- in a way that looks like a gameplay bug.
--
--   2  snapshots are packed by meatray.net.snapcodec. This build reads a text
--      snapshot from an older peer, so the change is one-way — but a version 1
--      client cannot read a version 2 host's snapshots, and the failure mode
--      without this bump is the worst one available: the handshake succeeds, the
--      world builds, and then no entity ever appears, with 'ignoring unreadable
--      packets' in a log the player is not reading.
--   3  dirty-flag snapshots: the snapshot codec grew a header flag byte saying
--      whether a frame is a keyframe or a partial, and partials carry a trailing
--      removal list. Same failure mode as above and the same answer — a version 2
--      peer reads the flag byte as the first byte of the tick varint and decodes
--      a plausible-looking wrong world, which is exactly what a version check is
--      for.
--   4  snapcodec v3: angles are int32 fixed-point, and every frame carries a
--      keyframe generation so a client can detect a dropped keyframe and ask for
--      a reliable resync. A version 3 peer would mis-decode angles and miss the
--      generation field entirely.
--   5  snapcodec v4: optional entity storey (in-world layer index) on the wire
--      so clients track which floor a peer is on without re-deriving from z.
P.VERSION = 5

P.CHANNELS    = 2
P.CH_RELIABLE = 0
P.CH_STREAM   = 1

---------------------------------------------------------------------------
-- Message types
---------------------------------------------------------------------------

P.JOIN    = 'j'
P.INPUT   = 'i'
P.COMMAND = 'm'
P.CHAT    = 'c'
P.STATS   = 't'
P.PING    = 'p'
P.LEAVE   = 'l'

P.ACCEPT  = 'a'
P.REJECT  = 'r'
P.SNAPSHOT= 's'
P.WORLD   = 'w'
P.EVENT   = 'v'
P.REPLY   = 'u'
P.KICK    = 'k'
P.PONG    = 'o'
P.RESPAWN = 'n'
P.RCON    = 'x'
P.VOTE    = 'V'
P.MAPCHANGE = 'W'   -- B14: the host swapped maps; here is the whole new world

P.names = {
    [P.JOIN] = 'join', [P.INPUT] = 'input', [P.COMMAND] = 'command',
    [P.CHAT] = 'chat', [P.STATS] = 'stats', [P.PING] = 'ping', [P.LEAVE] = 'leave',
    [P.ACCEPT] = 'accept', [P.REJECT] = 'reject', [P.SNAPSHOT] = 'snapshot',
    [P.WORLD] = 'world', [P.EVENT] = 'event', [P.REPLY] = 'reply',
    [P.KICK] = 'kick', [P.PONG] = 'pong', [P.RESPAWN] = 'respawn',
    [P.RCON] = 'rcon', [P.VOTE] = 'vote', [P.MAPCHANGE] = 'mapchange',
}

---------------------------------------------------------------------------
-- Direction, and why it is a table rather than a comment
---------------------------------------------------------------------------

--[[
    Which way a message legally travels used to live in two section headings —
    "client -> host" and "host -> client" — which is exactly the kind of fact
    that stops being true without anything failing. It had already stopped being
    true: CHAT was filed under "client -> host" as `{ text }`, while the host
    broadcast it and the client handled it, with a different payload in each
    direction. Nothing caught that, because a heading is not checkable.

    So direction is data now. `tests/test_net_contract.lua` reads this table and
    asserts that every tag the registry says a side must handle *is* handled by
    that side's dispatch table, and that no side handles a tag the registry does
    not list. A tag added here with no handler fails the suite; a handler added
    with no entry here fails the suite. Neither can be forgotten quietly.

    `P.shape` documents the payload per direction, and a `both` tag must document
    both — which is what makes the CHAT asymmetry visible instead of implied.
]]

P.C2S  = 'c2s'    -- client -> host only
P.S2C  = 's2c'    -- host -> client only
P.BOTH = 'both'   -- travels in both directions, payload may differ by direction

P.direction = {
    [P.JOIN]     = P.C2S,
    [P.INPUT]    = P.C2S,
    [P.COMMAND]  = P.C2S,
    [P.STATS]    = P.C2S,
    [P.PING]     = P.C2S,
    [P.LEAVE]    = P.C2S,

    [P.CHAT]     = P.BOTH,
    -- Up: a peer authenticates or issues a command. Down: the reply. Both
    -- directions exist, with different payloads — like CHAT.
    [P.RCON]     = P.BOTH,
    -- Up: call a vote or cast a ballot. Down: the vote's state broadcast to
    -- everyone. Different payloads each way, like CHAT and RCON.
    [P.VOTE]     = P.BOTH,

    [P.ACCEPT]   = P.S2C,
    [P.REJECT]   = P.S2C,
    [P.SNAPSHOT] = P.S2C,
    [P.WORLD]    = P.S2C,
    [P.EVENT]    = P.S2C,
    [P.REPLY]    = P.S2C,
    [P.KICK]     = P.S2C,
    [P.PONG]     = P.S2C,
    [P.RESPAWN]  = P.S2C,
    -- B14: only the host decides the map, and it re-sends the whole world when
    -- it changes — the one mid-session message that carries a full worldPayload
    -- rather than a diff.
    [P.MAPCHANGE] = P.S2C,
}

-- One entry per legal direction of every tag. A `both` tag has two, and they are
-- allowed to differ — CHAT does.
P.shape = {
    [P.JOIN]     = { c2s = '{ version, name, password, credentials }' },
    [P.INPUT]    = { c2s = '{ seq, forward, strafe, turn, angle }' },
    [P.COMMAND]  = { c2s = '{ name, body }  -- body is the game\'s, never read here' },
    [P.STATS]    = { c2s = '{}  -- ask the host what it thinks the world looks like' },
    [P.PING]     = { c2s = '{ time }' },
    [P.LEAVE]    = { c2s = '{}' },

    -- The one asymmetric tag. Up, a client says only what it typed; the host
    -- decides who said it. Down, the name is attached, because a client that was
    -- trusted to name the speaker could name anyone.
    [P.CHAT]     = { c2s = '{ text }', s2c = '{ text, name }' },
    [P.RCON]     = { c2s = '{ auth = password } | { cmd = line }',
                     s2c = '{ ok = bool, reply = text }' },
    [P.VOTE]     = { c2s = '{ call = kind, map, target } | { cast = yes|no }',
                     s2c = '{ state = status } | { result = pass|fail }' },

    [P.ACCEPT]   = { s2c = '{ peerId, entityId, world, tickRate, snapshotRate, '
                         .. 'moveSpeed, turnSpeed, idBase, name, map, mode }' },
    [P.REJECT]   = { s2c = '{ reason, detail }' },
    [P.SNAPSHOT] = { s2c = '{ tick, full, k = keyframe generation, '
                            .. 'e = { entity snapshots }, '
                            .. 'r = { removed ids, partials only } }' },
    [P.WORLD]    = { s2c = '{ doors = { ["x,y"| "s,x,y"] = 0|1 }, '
                         .. 'tiles = { ["x,y"| "s,x,y"] = 0|1 }, '
                         .. 'movers = { { id, z, target, moving } } }' },
    [P.EVENT]    = { s2c = '{ name, body }' },
    [P.REPLY]    = { s2c = '{ players, peers, entities, doorsOpen, tick, ... }' },
    [P.KICK]     = { s2c = '{ reason }' },
    [P.PONG]     = { s2c = '{ time }' },
    -- Your entity died and the host built you a new one. entityId is the
    -- whole message: the client rebinds off the next snapshot, exactly the
    -- way it bound the first entity off ACCEPT.
    [P.RESPAWN]  = { s2c = '{ entityId }' },
    -- B14: the same worldPayload ACCEPT carries, plus this peer's new entityId,
    -- because a fresh world means fresh entities and the old id is gone. The
    -- client rebuilds its world and rebinds off the next snapshot.
    [P.MAPCHANGE] = { s2c = '{ world = worldPayload, entityId, map }' },
}

function P.travels(kind, direction)
    local d = P.direction[kind]
    return d ~= nil and (d == direction or d == P.BOTH)
end

-- Sorted, so a test that iterates tags reports failures in a stable order.
function P.tags()
    local out = {}
    for kind in pairs(P.names) do out[#out + 1] = kind end
    table.sort(out)
    return out
end

---------------------------------------------------------------------------
-- Size limits
---------------------------------------------------------------------------

-- A hard ceiling for anything either side will decode. A join payload carrying a
-- hand-authored grid is the largest legitimate packet in the protocol, and it is
-- measured in tens of kilobytes.
P.MAX_PACKET = 256 * 1024

--[[
    The largest packet ENet will put in a single datagram at its default MTU:

        1392  ENET_HOST_DEFAULT_MTU
        -  4  ENetProtocolHeader (peer id, sent time)
        - 24  ENetProtocolSendFragment, the command header on a fragment
        ----
        1364

    A snapshot must stay under this, and not for bandwidth. ENet picks the
    delivery mode for a *fragmented* packet by testing the flags against
    UNRELIABLE_FRAGMENT; our unreliable send passes flags 0, that test is false
    for 0, and the fragment path then falls through to reliable, acknowledged,
    retransmitted, head-of-line-blocked delivery. So a snapshot one byte over this
    line silently stops being part of a snapshot stream. lua-enet exposes no
    string that maps to UNRELIABLE_FRAGMENT, so the flag cannot be corrected from
    Lua and the size is the only lever there is.

    This is the default. ENet negotiates the *minimum* MTU of the two peers, so a
    peer that came up at 576 gets a budget of 548 instead — which is why the
    snapshot codec aims well under this number rather than at it.

    MEASURED, NOT ONLY DERIVED

    The largest datagram observed leaving the LÖVE 11.4 ENet build on this
    machine is 1400 bytes, not 1392, so the true single-datagram payload budget
    is 1372 and this constant is eight bytes under it rather than at it. That is
    fine — under is the direction that matters — but the 1392 above is what the
    header says, not what was seen. See docs/NETWORKING.md and scripts/netfrag.ps1
    for the run that measured it, which also caught the promotion itself
    happening: at 1349 bytes a fifth of the snapshots were skipped under a fifth
    of induced datagram loss, and at 1434 bytes none of them were.
]]
P.MTU_SAFE_BYTES = 1364

-- Per-tag ceilings for traffic a *host* accepts, which is the direction that
-- arrives from an untrusted machine. They are generous against real messages and
-- tight against a peer trying to make the host allocate: an input is a handful of
-- numbers whatever the sender believes.
P.limits = {
    [P.JOIN]    = 4096,
    [P.INPUT]   = 512,
    [P.COMMAND] = 8192,
    [P.CHAT]    = 2048,
    [P.STATS]   = 128,
    [P.PING]    = 128,
    [P.LEAVE]   = 128,
    -- A password or a command line, both short. Small on purpose: an
    -- unauthenticated peer can send this, so the cheapest thing to reject is a
    -- fat one, before the auth even runs.
    [P.RCON]    = 512,
    [P.VOTE]    = 512,
}

---------------------------------------------------------------------------
-- Field validation
---------------------------------------------------------------------------

--[[
    Whole-message validation, before a single field is read by anything that
    keeps it.

    The failure this exists to prevent: a handler that assigns fields as it
    inspects them leaves the first few applied when the fourth turns out to be
    garbage. One `1e999` in a yaw then rides in every snapshot, to every player,
    forever — the sender is not the one it breaks. Validate first, assign after,
    and a bad message costs exactly one drop.

    A rule is { field, type, optional =, min =, max =, maxLen = }. Numbers must be
    finite: NaN is caught by `v ~= v` and the infinities by comparison against
    math.huge, because neither is excluded by `type(v) == 'number'` and both
    survive the wire format intact (it names them rather than emitting "inf",
    precisely so they arrive as themselves and can be rejected here).

    `any` means the engine never interprets the value — a command body and a set
    of credentials belong to the game and to its auth hook.
]]

local NUM, STR, ANY = 'number', 'string', 'any'

-- Larger than any angle a session accumulates (a player turning at 10 rad/s
-- would need 27 hours to reach it) and small enough that trigonometry on it
-- stays in the range where every libm agrees.
P.MAX_ANGLE = 1e6

P.schema = {
    [P.JOIN] = {
        { 'version',     NUM, optional = true, min = 0, max = 1e9 },
        { 'name',        STR, optional = true, maxLen = 64 },
        { 'password',    STR, optional = true, maxLen = 256 },
        { 'credentials', ANY, optional = true },
    },
    [P.INPUT] = {
        { 'seq',     NUM, optional = true, min = 0, max = 2 ^ 53 },
        { 'forward', NUM, optional = true, min = -1e6, max = 1e6 },
        { 'strafe',  NUM, optional = true, min = -1e6, max = 1e6 },
        { 'turn',    NUM, optional = true, min = -1e6, max = 1e6 },
        { 'angle',   NUM, optional = true, min = -P.MAX_ANGLE, max = P.MAX_ANGLE },
    },
    [P.COMMAND] = {
        { 'name', STR, maxLen = 64 },
        { 'body', ANY, optional = true },
    },
    [P.CHAT] = {
        { 'text', STR, maxLen = 1024 },
        { 'name', STR, optional = true, maxLen = 64 },
    },
    [P.STATS] = {},
    [P.PING]  = { { 'time', NUM, optional = true } },
    [P.LEAVE] = {},

    [P.ACCEPT] = {
        { 'peerId',       NUM, optional = true, min = 0, max = 1e9 },
        { 'entityId',     NUM, optional = true, min = 0, max = 1e12 },
        { 'tickRate',     NUM, optional = true, min = 1, max = 1000 },
        { 'snapshotRate', NUM, optional = true, min = 1, max = 1000 },
        { 'moveSpeed',    NUM, optional = true, min = 0, max = 1e4 },
        { 'turnSpeed',    NUM, optional = true, min = 0, max = 1e4 },
        { 'idBase',       NUM, optional = true, min = 0, max = 1e12 },
        { 'name',         STR, optional = true, maxLen = 64 },
        { 'map',          STR, optional = true, maxLen = 128 },
        { 'mode',         STR, optional = true, maxLen = 32 },
        { 'world',        ANY, optional = true },
    },
    [P.REJECT]   = { { 'reason', STR, optional = true, maxLen = 256 },
                     { 'detail', STR, optional = true, maxLen = 512 } },
    [P.SNAPSHOT] = { { 'tick', NUM, optional = true, min = 0, max = 2 ^ 53 },
                     { 'e', ANY, optional = true } },
    [P.WORLD]    = { { 'doors', ANY, optional = true } },
    [P.EVENT]    = { { 'name', STR, maxLen = 64 }, { 'body', ANY, optional = true } },
    [P.REPLY]    = {},
    [P.KICK]     = { { 'reason', STR, optional = true, maxLen = 256 } },
    [P.PONG]     = { { 'time', NUM, optional = true } },
    [P.MAPCHANGE] = {
        { 'entityId', NUM, optional = true, min = 0, max = 1e12 },
        { 'map',      STR, optional = true, maxLen = 128 },
        { 'world',    ANY, optional = true },
    },
}

local huge = math.huge

-- Returns true, or false plus a reason naming the offending field. Never raises
-- and never mutates the body: a caller may keep the message only after this says
-- yes, and may discard it whole when it says no.
function P.check(kind, body)
    if type(body) ~= 'table' then
        return false, 'body is not a table'
    end

    local rules = P.schema[kind]
    if not rules then return true end

    for i = 1, #rules do
        local rule = rules[i]
        local name, want = rule[1], rule[2]
        local v = body[name]

        if v == nil then
            if not rule.optional then
                return false, ('%s is missing'):format(name)
            end

        elseif want == ANY then
            -- Deliberately unchecked; the size cap is what bounds it.

        elseif type(v) ~= want then
            return false, ('%s should be a %s, got %s'):format(name, want, type(v))

        elseif want == NUM then
            if v ~= v then
                return false, ('%s is not a number (NaN)'):format(name)
            elseif v == huge or v == -huge then
                return false, ('%s is infinite'):format(name)
            elseif rule.min and v < rule.min then
                return false, ('%s is below %g'):format(name, rule.min)
            elseif rule.max and v > rule.max then
                return false, ('%s is above %g'):format(name, rule.max)
            end

        elseif want == STR then
            if rule.maxLen and #v > rule.maxLen then
                return false, ('%s is %d bytes, over the %d byte limit')
                              :format(name, #v, rule.maxLen)
            end
        end
    end

    return true
end

---------------------------------------------------------------------------
-- Envelope
---------------------------------------------------------------------------

function P.pack(kind, body)
    return kind .. Serialize.encode(body or {})
end

-- Snapshots, and only snapshots, go out through the binary codec: it is what
-- keeps them inside one datagram, which is what keeps them unreliable (see
-- P.MTU_SAFE_BYTES and meatray/net/snapcodec.lua). Everything else stays on the
-- text serializer, because everything else is reliable by intent and fragmenting
-- it is correct.
--
-- A body the codec's layout does not model — a test fixture, a game that builds
-- its own snapshot shape — falls back to P.pack rather than being refused. Losing
-- the size win is a regression in one property; dropping a field would be a
-- regression in a different and much worse one. The second return says which path
-- was taken, so a caller that cares can count the fallbacks.
function P.packSnapshot(body)
    local encoded, why = SnapCodec.encode(body or {})
    if encoded then return P.SNAPSHOT .. encoded, true end
    return P.pack(P.SNAPSHOT, body), false, why
end

-- Never raises: a malformed packet is an expected event on a public port, so it
-- returns nil plus a reason and the caller drops it.
--
-- `limits` is an optional table of tag -> maximum packet bytes, checked before
-- anything is decoded. A host passes P.limits; a client does not, because the
-- host is the side that sends the large payloads.
--
-- The three-value nil return is load-bearing. It is the *only* way a parse error
-- is reported, and no pcall anywhere in the stack is allowed to produce the same
-- shape — a handler that crashes must never be reported to a player as "malformed
-- message", which turns a server bug into a mystery on the other machine.
function P.unpack(packet, limits)
    if type(packet) ~= 'string' or #packet < 1 then
        return nil, nil, 'empty packet'
    end

    if #packet > P.MAX_PACKET then
        return nil, nil, ('packet is %d bytes, over the %d byte ceiling')
                         :format(#packet, P.MAX_PACKET)
    end

    local kind = packet:sub(1, 1)
    if not P.names[kind] then
        return nil, nil, ('unknown message type %q'):format(kind)
    end

    local cap = limits and limits[kind]
    if cap and #packet > cap then
        return nil, nil, ('%s is %d bytes, over its %d byte limit')
                         :format(P.names[kind], #packet, cap)
    end

    -- Which codec wrote the body is read off the body itself rather than
    -- negotiated, because the two are trivially distinguishable: the binary
    -- codec's magic byte is 0x01 and the text serializer's tags are all
    -- punctuation. That is what lets a peer running either one be understood,
    -- including the many fixtures and tools that still build snapshots with
    -- P.pack.
    local payload = packet:sub(2)
    local body, err
    if kind == P.SNAPSHOT and SnapCodec.isBinary(payload) then
        body, err = SnapCodec.decode(payload)
    else
        body, err = Serialize.decode(payload)
    end

    if body == nil then
        return nil, nil, ('bad %s body: %s'):format(P.names[kind], tostring(err))
    end

    return kind, body
end

return P
