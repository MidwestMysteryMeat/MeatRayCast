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

local P = {}

-- Bumped whenever the wire format changes incompatibly. A client with the wrong
-- version is rejected with a message that says so, rather than desynchronising
-- in a way that looks like a gameplay bug.
P.VERSION = 1

P.CHANNELS    = 2
P.CH_RELIABLE = 0
P.CH_STREAM   = 1

---------------------------------------------------------------------------
-- Message types
---------------------------------------------------------------------------

-- client -> host
P.JOIN    = 'j'   -- { version, name, password, credentials }
P.INPUT   = 'i'   -- { seq, forward, strafe, angle }
P.COMMAND = 'm'   -- { name, body }
P.CHAT    = 'c'   -- { text }
P.STATS   = 't'   -- {} : ask the host what it thinks the world looks like
P.PING    = 'p'   -- { time }
P.LEAVE   = 'l'   -- {}

-- host -> client
P.ACCEPT  = 'a'   -- { peerId, entityId, world, tickRate, snapshotRate, name, map }
P.REJECT  = 'r'   -- { reason }
P.SNAPSHOT= 's'   -- { tick, e = { entity snapshots } }
P.WORLD   = 'w'   -- { doors = { ['x,y'] = 0|1 } }
P.EVENT   = 'v'   -- { name, body }
P.REPLY   = 'u'   -- { players, entities, doorsOpen, tick } : answer to STATS
P.KICK    = 'k'   -- { reason }
P.PONG    = 'o'   -- { time }

P.names = {
    [P.JOIN] = 'join', [P.INPUT] = 'input', [P.COMMAND] = 'command',
    [P.CHAT] = 'chat', [P.STATS] = 'stats', [P.PING] = 'ping', [P.LEAVE] = 'leave',
    [P.ACCEPT] = 'accept', [P.REJECT] = 'reject', [P.SNAPSHOT] = 'snapshot',
    [P.WORLD] = 'world', [P.EVENT] = 'event', [P.REPLY] = 'reply',
    [P.KICK] = 'kick', [P.PONG] = 'pong',
}

---------------------------------------------------------------------------
-- Envelope
---------------------------------------------------------------------------

function P.pack(kind, body)
    return kind .. Serialize.encode(body or {})
end

-- Never raises: a malformed packet is an expected event on a public port, so it
-- returns nil plus a reason and the caller drops it.
function P.unpack(packet)
    if type(packet) ~= 'string' or #packet < 1 then
        return nil, nil, 'empty packet'
    end

    local kind = packet:sub(1, 1)
    if not P.names[kind] then
        return nil, nil, ('unknown message type %q'):format(kind)
    end

    local body, err = Serialize.decode(packet:sub(2))
    if body == nil then
        return nil, nil, ('bad %s body: %s'):format(P.names[kind], tostring(err))
    end

    return kind, body
end

return P
