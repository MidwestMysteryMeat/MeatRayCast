--[[
    meatray.net.rcon — remote administration of a dedicated server (D33).

    The dev console (meatray.game.console) is the operator's hand inside their
    OWN process. RCON is the opposite: an operator reaching a server they are
    not sitting at — kick a griefer, change the map, say something to everyone,
    read the status — over an authenticated channel. Source's model, and this
    follows it: a session presents the password once, and once authenticated may
    run commands; an unauthenticated session may do nothing but try to
    authenticate, and only so many times before it is locked out.

        local Rcon = require('meatray.net.rcon')
        local r = Rcon.new{ secret = os.getenv('RCON_SECRET'), host = host,
                            onMap = function(name) requestMapChange(name) end }

        local s = r:open('admin-1')      -- a session id (a peer key, a socket)
        r:auth(s, token)                 -- true / false
        r:exec(s, 'kick griefer trolling')
        r:exec(s, 'say server restarting in 5')
        r:exec(s, 'status')

    Security, stated because RCON is the thing an attacker most wants:

      * NO secret means RCON is OFF. A server with no password does not get a
        blank one it accepts — it refuses every auth, so forgetting to set the
        password fails closed, not open.
      * The compare is constant-time over SHA-256 digests, so the password
        cannot be recovered a byte at a time by timing, and comparing digests
        rather than raw strings hides the length too.
      * A session is locked after `maxTries` failures. Brute force costs a new
        session each guess, which a transport layer above can rate-limit.
      * An authed command never trusts the session's OWN claim of who it is;
        the host does the acting, and the host's own checks (a dedicated
        server refuses gameplay edits, etc.) still apply.

    The command SET is small and server-shaped: status, say, kick, ban, map,
    help. `map` does not swap the world here — that is the host/demo's job (and
    B14 hot-reload) — it calls `onMap(name)`, so the net layer stays out of
    world loading.

    HEADLESS: pure Lua.
]]

local Crypto = require('meatray.net.crypto')

local Rcon = {}
local RconMT = {}
RconMT.__index = RconMT

Rcon.MAX_TRIES = 5

---------------------------------------------------------------------------
-- Constant-time digest compare
---------------------------------------------------------------------------

-- Compares two strings by their SHA-256 digests, accumulating the difference
-- so the loop cannot short-circuit on the first mismatched byte. Equal-length
-- digests, so the raw lengths never leak either.
local function secretsMatch(a, b)
    if type(a) ~= 'string' or type(b) ~= 'string' then return false end
    local da, db = Crypto.sha256(a), Crypto.sha256(b)
    if #da ~= #db then return false end            -- both 32; a guard, not a leak
    local diff = 0
    for i = 1, #da do
        diff = diff + (da:byte(i) == db:byte(i) and 0 or 1)
    end
    return diff == 0
end

---------------------------------------------------------------------------
-- Construction
---------------------------------------------------------------------------

-- opts:
--   secret    the RCON password. Absent/empty => RCON is disabled (fail closed).
--   host      the server to act on (see the adapter methods used below).
--   onMap     function(name) -> the host/demo swaps maps; RCON does not.
--   maxTries  auth attempts before a session is locked (default 5).
function Rcon.new(opts)
    opts = opts or {}
    local secret = opts.secret
    if type(secret) ~= 'string' or secret == '' then secret = nil end
    return setmetatable({
        secret = secret,
        host = opts.host,
        onMap = opts.onMap,
        maxTries = tonumber(opts.maxTries) or Rcon.MAX_TRIES,
        sessions = {},         -- [id] = { authed, tries, locked }
    }, RconMT)
end

function RconMT:enabled()
    return self.secret ~= nil
end

---------------------------------------------------------------------------
-- Sessions and auth
---------------------------------------------------------------------------

function RconMT:open(id)
    id = tostring(id)
    self.sessions[id] = { authed = false, tries = 0, locked = false }
    return id
end

function RconMT:close(id)
    self.sessions[tostring(id)] = nil
end

function RconMT:isAuthed(id)
    local s = self.sessions[tostring(id)]
    return s ~= nil and s.authed
end

-- Presents a password. Returns true on success, or false plus a reason. A
-- disabled RCON (no secret) refuses everything; a locked session stays locked.
function RconMT:auth(id, token)
    local s = self.sessions[tostring(id)]
    if not s then return false, 'no such session' end
    if not self.secret then return false, 'rcon is disabled' end
    if s.locked then return false, 'session locked' end

    if secretsMatch(self.secret, token) then
        s.authed = true
        s.tries = 0
        return true
    end

    s.tries = s.tries + 1
    if s.tries >= self.maxTries then
        s.locked = true
        return false, 'too many attempts; session locked'
    end
    return false, 'bad password'
end

---------------------------------------------------------------------------
-- Commands
---------------------------------------------------------------------------

local function tokenize(line)
    local out = {}
    for word in tostring(line or ''):gmatch('%S+') do out[#out + 1] = word end
    return out
end

-- Each command: fn(rcon, args) -> reply string. The host adapter is reached
-- through self.host; a command a mock host cannot serve returns a clear error
-- rather than raising.
local COMMANDS = {}

COMMANDS.help = function()
    return 'commands: status, say <text>, kick <who> [reason], '
        .. 'ban <who> [reason], map <name>, help'
end

COMMANDS.status = function(self)
    local h = self.host
    if not h then return 'no host attached' end
    local lines = {}
    lines[#lines + 1] = ('players: %d'):format(h.playerCount and h:playerCount() or 0)
    if h.rconStatus then
        for _, row in ipairs(h:rconStatus()) do
            lines[#lines + 1] = ('  %s  peer %s  %s'):format(
                tostring(row.name), tostring(row.peerId), tostring(row.address or '?'))
        end
    end
    return table.concat(lines, '\n')
end

COMMANDS.say = function(self, args)
    if #args == 0 then return 'say what?' end
    local text = table.concat(args, ' ')
    if self.host and self.host.chat then self.host:chat(text, 'SERVER') end
    return 'said: ' .. text
end

COMMANDS.kick = function(self, args)
    if #args == 0 then return 'kick who?' end
    local who = args[1]
    local reason = #args > 1 and table.concat(args, ' ', 2) or 'kicked by admin'
    if not (self.host and self.host.kick) then return 'host cannot kick' end
    local ok, why = self.host:kick(who, reason)
    return ok and ('kicked ' .. who) or ('kick failed: ' .. tostring(why))
end

COMMANDS.ban = function(self, args)
    if #args == 0 then return 'ban who?' end
    local who = args[1]
    local reason = #args > 1 and table.concat(args, ' ', 2) or 'banned by admin'
    if not (self.host and self.host.ban) then return 'host cannot ban' end
    local ok, why = self.host:ban(who, reason)
    return ok and ('banned ' .. who) or ('ban failed: ' .. tostring(why))
end

COMMANDS.map = function(self, args)
    if #args == 0 then return 'map to what?' end
    local name = args[1]
    if not self.onMap then return 'map changing is not wired on this server' end
    self.onMap(name)
    return 'map change requested: ' .. name
end

-- Runs one command line on an AUTHENTICATED session. Returns ok, reply. An
-- unauthenticated (or unknown) session is refused before the line is even
-- parsed — the whole point.
function RconMT:exec(id, line)
    local s = self.sessions[tostring(id)]
    if not s then return false, 'no such session' end
    if not s.authed then return false, 'not authenticated' end

    local args = tokenize(line)
    local name = table.remove(args, 1)
    if not name then return true, '' end

    local cmd = COMMANDS[name:lower()]
    if not cmd then return false, 'unknown command: ' .. name .. ' (try help)' end

    local ok, reply = pcall(cmd, self, args)
    if not ok then return false, 'error: ' .. tostring(reply) end
    return true, reply
end

-- Exposed so a host/demo can register more without editing this file.
Rcon.COMMANDS = COMMANDS

return Rcon
