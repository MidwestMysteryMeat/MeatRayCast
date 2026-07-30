--[[
    meatray.save.format — the save file envelope, its version, and migration.

    A save is a snapshot written to a file. The snapshot part is already solved:
    components declare `netFields`, entities derive their state from that
    declaration, and a world's mutable part is its doors. This module owns the
    other half — putting that state in a file that a later build can still read,
    and refusing, clearly, the files it cannot.

    The layout is a header line and two serialised sections:

        MEATRAYSAVE <metaBytes> <bodyBytes> <adler32>\n<meta><body>

    Three things follow from that shape, and each is a requirement rather than a
    decoration:

      * **Metadata is readable without the body.** A save browser listing twenty
        slots should not deserialise twenty worlds to print twenty dates. The
        header line is short and fixed, so a reader takes the first few hundred
        bytes of the file, learns how long the meta section is, and stops. The
        body is never touched. `Format.readMeta` is that path.

      * **Truncation is detectable, not guessable.** Both section lengths are
        declared up front, so a file cut short by a full disk or a killed process
        fails on arithmetic before a decoder is ever asked to interpret half a
        value. The message says how many bytes are missing.

      * **Corruption is detectable.** Adler-32 over both sections catches the
        flipped bytes that would otherwise still decode — a valid-looking save
        with a wrong number in it is the worst outcome available, because it is
        the one nothing reports. This is an integrity check and not a security
        one: a checksum stops accidents, and anyone editing a save on purpose can
        recompute it. Saves are not a trust boundary; the network is, and that is
        what meatray/net/protocol.lua validates.

    The version lives in the meta section, in exactly one place, and every save
    carries one from v1 onward. A format with no version is a format that can
    never change, because the first change makes every existing file
    indistinguishable from a corrupt one. `Format.migration` registers the
    upgrade from an older version to a newer, `Format.decode` applies the chain,
    and a version this build has never heard of is refused by name rather than
    read hopefully.

    The value encoding is meatray.net.serialize — the same serialiser the network
    uses. It already round-trips doubles bit-exactly (%.17g), length-prefixes
    strings so no byte needs escaping, caps its own recursion depth, and has a
    round-trip suite behind it. A second encoder written here would be a second
    set of those bugs to find.

    HEADLESS: no LOVE. This module is pure string handling, which is what lets
    almost all of the save system be tested under plain LuaJIT.
]]

local Serialize = require('meatray.net.serialize')

local Format = {}

local byte, sub, find = string.byte, string.sub, string.find
local floor = math.floor

---------------------------------------------------------------------------
-- Versioning
---------------------------------------------------------------------------

-- The version of the save *contents* — what keys the body carries and what they
-- mean. Bump it whenever an existing key changes shape, and register a migration
-- from the version before it in the same commit.
Format.VERSION = 1

-- The oldest version this build will still open, migrating forward as it goes.
-- Zero means "anything a migration chain can reach": a version below the current
-- one with no migration registered is already refused by name, so the floor
-- exists for the other case — deliberately dropping support for something
-- ancient, where the refusal should say so rather than complain about a missing
-- migration nobody intends to write.
Format.MIN_VERSION = 0

Format.MAGIC = 'MEATRAYSAVE'

-- Ceilings applied before anything is allocated. A header claiming four
-- gigabytes of metadata is a corrupt header, and finding that out by trying to
-- read four gigabytes is the failure mode these exist to prevent.
Format.MAX_META = 64 * 1024
Format.MAX_BODY = 32 * 1024 * 1024

-- Long enough for the header line plus a typical meta section, so listing a slot
-- is one read. A larger meta section costs a second read, never a wrong answer.
Format.PROBE_BYTES = 1024

---------------------------------------------------------------------------
-- Checksum
---------------------------------------------------------------------------

-- Adler-32, chosen because it needs no bit library and no lookup table: it is
-- arithmetic on integers small enough that a double holds them exactly. The
-- deferred modulo is the standard trick — 5552 is the largest block for which
-- the accumulators cannot overflow 32 bits, and staying inside that bound keeps
-- the result identical to any other implementation.
function Format.checksum(s)
    local a, b, n = 1, 0, #s
    local i = 1

    while i <= n do
        local stop = i + 5551
        if stop > n then stop = n end
        for j = i, stop do
            a = a + byte(s, j)
            b = b + a
        end
        a = a % 65521
        b = b % 65521
        i = stop + 1
    end

    return b * 65536 + a
end

---------------------------------------------------------------------------
-- Migration
---------------------------------------------------------------------------

--[[
    A migration takes a whole decoded document at version `from` and returns one
    at a higher version, or nil plus a reason. Documents are `{ version, meta,
    body }`, so a migration can move a field between sections, not only within
    the body.

    The registry is a plain table so a game can register migrations for its own
    progress data alongside the engine's, and so tests can pass a registry of
    their own to `decode` instead of mutating the global one.

    The engine ships no migrations today: version 1 is the first version there
    has ever been, and inventing a fake predecessor to have something in the
    table would be inventing history. What matters is that the mechanism is here,
    is exercised (tests/test_save_format.lua registers a v0 -> v1 migration and
    loads a v0 file through it), and is therefore known to work on the day the
    first real one is needed — rather than being designed on that day, against a
    file format already in the wild.
]]
Format.migrations = {}

function Format.migration(from, fn)
    assert(type(from) == 'number' and from == floor(from) and from >= 0,
           'a migration is registered against a whole version number')
    assert(type(fn) == 'function', 'a migration needs a function')
    Format.migrations[from] = fn
    return fn
end

-- Runs the chain from doc.version up to Format.VERSION. Returns the migrated
-- document, or nil plus a message naming the version it got stuck on.
function Format.migrate(doc, migrations)
    migrations = migrations or Format.migrations

    local guard = 0

    while doc.version < Format.VERSION do
        local from = doc.version
        local step = migrations[from]

        if not step then
            return nil, ('no migration from save version %d to %d; this build '
                         .. 'cannot upgrade it'):format(from, Format.VERSION)
        end

        local ok, migrated, err = pcall(step, doc)
        if not ok then
            return nil, ('the migration from save version %d failed: %s')
                        :format(from, tostring(migrated))
        end
        if not migrated then
            return nil, ('the migration from save version %d refused it: %s')
                        :format(from, tostring(err or 'no reason given'))
        end
        if type(migrated) ~= 'table' or type(migrated.version) ~= 'number' then
            return nil, ('the migration from save version %d returned something '
                         .. 'that is not a document'):format(from)
        end

        -- A migration that leaves the version alone would loop forever, and a
        -- loop inside a load is indistinguishable from a hang. Catch it on the
        -- first pass, with the version that caused it in the message.
        if migrated.version <= from then
            return nil, ('the migration from save version %d did not raise the '
                         .. 'version (still %d)'):format(from, migrated.version)
        end

        doc = migrated

        guard = guard + 1
        if guard > 256 then
            return nil, 'the migration chain did not terminate'
        end
    end

    return doc
end

---------------------------------------------------------------------------
-- Encoding
---------------------------------------------------------------------------

local function shallowCopy(t)
    local out = {}
    for k, v in pairs(t or {}) do out[k] = v end
    return out
end

--[[
    Encodes a document to the bytes that go in a file.

    `doc` is { version =, meta = {}, body = {} }. `meta` is whatever a save
    browser needs to show a row — timestamp, map name, play time, a label — and
    `body` is the state itself. The split is not cosmetic: everything put in meta
    is paid for on every listing, and everything put in body is free until the
    save is actually opened.

    `opts.version` overrides the version written. It exists so a migration can be
    written against a file it can actually produce, and so a downgrade tool is
    possible later; normal saves leave it alone.
]]
function Format.encode(doc, opts)
    opts = opts or {}

    if type(doc) ~= 'table' then
        return nil, 'a save document must be a table'
    end
    if type(doc.body) ~= 'table' then
        return nil, ('a save needs a body table, got %s'):format(type(doc.body))
    end
    if doc.meta ~= nil and type(doc.meta) ~= 'table' then
        return nil, ('save metadata must be a table, got %s'):format(type(doc.meta))
    end

    local version = opts.version or doc.version or Format.VERSION
    if type(version) ~= 'number' or version ~= floor(version) or version < 0 then
        return nil, ('a save version must be a whole number, got %s')
                    :format(tostring(version))
    end

    -- Version travels inside the meta section rather than beside it, so there is
    -- exactly one copy on disk and therefore no way for two copies to disagree.
    local meta = shallowCopy(doc.meta)
    meta.version = version

    -- tryEncode rather than encode: a game that put a function in its progress
    -- table gets a message naming the problem, at the moment it saved, instead
    -- of an error out of a serialiser it has never heard of.
    local metaBytes, metaErr = Serialize.tryEncode(meta)
    if not metaBytes then
        return nil, 'save metadata could not be encoded: ' .. tostring(metaErr)
    end

    local bodyBytes, bodyErr = Serialize.tryEncode(doc.body)
    if not bodyBytes then
        return nil, 'save body could not be encoded: ' .. tostring(bodyErr)
    end

    if #metaBytes > Format.MAX_META then
        return nil, ('save metadata is %d bytes, over the %d byte limit; large '
                     .. 'values belong in the body'):format(#metaBytes, Format.MAX_META)
    end
    if #bodyBytes > Format.MAX_BODY then
        return nil, ('save body is %d bytes, over the %d byte limit')
                    :format(#bodyBytes, Format.MAX_BODY)
    end

    local payload = metaBytes .. bodyBytes

    return ('%s %d %d %d\n'):format(Format.MAGIC, #metaBytes, #bodyBytes,
                                    Format.checksum(payload)) .. payload
end

---------------------------------------------------------------------------
-- Decoding
---------------------------------------------------------------------------

-- Parses the header line out of a prefix of the file. Returns a table of
-- offsets, or nil plus a message. Never touches the body, and never needs to
-- have seen it: this is what makes listing cheap.
function Format.parseHeader(prefix)
    if type(prefix) ~= 'string' or #prefix == 0 then
        return nil, 'the save file is empty'
    end

    if sub(prefix, 1, #Format.MAGIC) ~= Format.MAGIC then
        return nil, 'this is not a MeatRayCast save (it does not start with '
                    .. Format.MAGIC .. ')'
    end

    local newline = find(prefix, '\n', 1, true)
    if not newline then
        -- Either a file truncated inside its own header, or one written by a
        -- build whose header line is longer than this one will read. Both are
        -- "cannot read", and saying which is not possible from here.
        return nil, ('the save header has no end of line in its first %d bytes, '
                     .. 'so the file is truncated or was written by a different '
                     .. 'build'):format(#prefix)
    end

    local metaLen, bodyLen, sum =
        sub(prefix, 1, newline - 1):match('^' .. Format.MAGIC .. ' (%d+) (%d+) (%d+)$')

    if not metaLen then
        return nil, 'the save header line is malformed: '
                    .. ('%q'):format(sub(prefix, 1, math.min(newline - 1, 120)))
    end

    metaLen, bodyLen, sum = tonumber(metaLen), tonumber(bodyLen), tonumber(sum)

    if metaLen > Format.MAX_META then
        return nil, ('the save header claims %d bytes of metadata, over the %d '
                     .. 'byte limit'):format(metaLen, Format.MAX_META)
    end
    if bodyLen > Format.MAX_BODY then
        return nil, ('the save header claims %d bytes of body, over the %d byte '
                     .. 'limit'):format(bodyLen, Format.MAX_BODY)
    end

    return {
        headerLen = newline,          -- bytes up to and including the newline
        metaLen   = metaLen,
        bodyLen   = bodyLen,
        checksum  = sum,
        totalLen  = newline + metaLen + bodyLen,
        metaAt    = newline + 1,
        bodyAt    = newline + 1 + metaLen,
    }
end

-- Pulls the version out of a decoded meta table and off it, so the caller gets
-- metadata that is purely the game's. A meta section with no version is refused
-- here rather than defaulted: guessing that an unversioned file is version 1 is
-- how a format with a version ends up behaving like one without.
local function liftVersion(meta)
    if type(meta) ~= 'table' then
        return nil, ('save metadata decoded to a %s, not a table'):format(type(meta))
    end

    local version = meta.version
    if version == nil then
        return nil, 'this save has no version field, so there is no way to tell '
                    .. 'what its contents mean'
    end
    if type(version) ~= 'number' or version ~= floor(version) or version < 0 then
        return nil, ('this save has version %s, which is not a whole number')
                    :format(tostring(version))
    end

    if version > Format.VERSION then
        return nil, ('this save is version %d; this build reads up to version %d '
                     .. '(it was written by a newer build)'):format(version, Format.VERSION)
    end
    if version < Format.MIN_VERSION then
        return nil, ('this save is version %d; this build no longer reads '
                     .. 'anything below version %d'):format(version, Format.MIN_VERSION)
    end

    meta.version = nil
    return version
end

--[[
    Reads the metadata of a save from a prefix of its bytes.

    Returns `meta, header` — where `meta.version` has been lifted onto the
    returned info table — or nil, message, header. The header comes back even on
    failure when it parsed, because a caller reading a prefix needs to know how
    many bytes to fetch on the second attempt.

    `wantBytes` on the returned header says how much of the file this function
    needed; a caller that passed less gets a `truncated` result rather than a
    guess.
]]
function Format.readMeta(prefix)
    local header, err = Format.parseHeader(prefix)
    if not header then return nil, err end

    local need = header.headerLen + header.metaLen
    if #prefix < need then
        return nil, ('need %d bytes to read this save\'s metadata, have %d')
                    :format(need, #prefix), header
    end

    local metaBytes = sub(prefix, header.metaAt, header.metaAt + header.metaLen - 1)
    local meta, decodeErr = Serialize.decode(metaBytes)
    if meta == nil then
        return nil, 'the save metadata is corrupt: ' .. tostring(decodeErr), header
    end

    local version, versionErr = liftVersion(meta)
    if not version then return nil, versionErr, header end

    return { version = version, meta = meta }, header
end

--[[
    Decodes a whole save.

    Every failure returns nil plus a sentence a player could be shown, and no
    failure leaves anything half-decoded: this function builds a document and
    returns it, or returns nothing at all. That is the same rule the hot reload
    path follows, for the same reason — a partly-applied save leaves the game in
    a state no file on disk describes, which is a bug that cannot be reproduced
    from a clean start.

    Order matters. Header, then lengths, then checksum, then version, then the
    sections. Checking the checksum before the version means a corrupt file is
    reported as corrupt rather than as "version 1717986918".
]]
function Format.decode(bytes, opts)
    opts = opts or {}

    if type(bytes) ~= 'string' then
        return nil, ('a save must be a string of bytes, got %s'):format(type(bytes))
    end

    local header, headerErr = Format.parseHeader(bytes)
    if not header then return nil, headerErr end

    if #bytes < header.totalLen then
        return nil, ('this save is truncated: the header describes %d bytes but '
                     .. 'the file is %d, so %d are missing')
                    :format(header.totalLen, #bytes, header.totalLen - #bytes)
    end

    -- Trailing bytes are as suspicious as missing ones: something appended to
    -- this file, or two saves were written over each other.
    if #bytes > header.totalLen then
        return nil, ('this save has %d bytes after the %d the header describes')
                    :format(#bytes - header.totalLen, header.totalLen)
    end

    local payload = sub(bytes, header.metaAt)
    local actual = Format.checksum(payload)
    if actual ~= header.checksum then
        return nil, ('this save is corrupt: the checksum over its %d bytes is %d, '
                     .. 'but the header says %d'):format(#payload, actual, header.checksum)
    end

    local info, metaErr = Format.readMeta(bytes)
    if not info then return nil, metaErr end

    local bodyBytes = sub(bytes, header.bodyAt, header.bodyAt + header.bodyLen - 1)
    local body, bodyErr = Serialize.decode(bodyBytes)
    if body == nil then
        return nil, 'the save body is corrupt: ' .. tostring(bodyErr)
    end
    if type(body) ~= 'table' then
        return nil, ('the save body decoded to a %s, not a table'):format(type(body))
    end

    local doc = { version = info.version, meta = info.meta, body = body }

    if opts.migrate == false then return doc end

    return Format.migrate(doc, opts.migrations)
end

return Format
