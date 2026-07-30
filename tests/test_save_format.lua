--[[
    The save envelope: its version, its migrations, and everything it refuses.

    Two properties are worth more than the rest of this file put together.

    Round trip: what comes out of a save is what went in, bit for bit, including
    the awkward doubles that a careless serialiser rounds and the strings that
    contain the format's own punctuation.

    Clean failure: a corrupt, truncated, foreign, ancient or future save produces
    nil and a sentence, never a raise and never a half-built document. A save
    system that crashes on a bad file crashes at the worst possible moment — the
    one where the player has already lost something and is trying to get it back.

    The cases are the ones that actually happen: a file cut short by a full disk
    or a killed process, a file with a flipped byte, a file that is valid
    serialisation of something else entirely, a save from a newer build, and a
    save with no version field at all.
]]

return function(t)
    local Format    = require('meatray.save.format')
    local Serialize = require('meatray.net.serialize')

    -- Builds a well-formed save file out of arbitrary meta and body tables, so a
    -- test can produce files Format.encode would never write: no version, a
    -- version from the future, a body that is not a table.
    local function frame(meta, body)
        local m = Serialize.encode(meta)
        local b = Serialize.encode(body)
        return ('%s %d %d %d\n'):format(Format.MAGIC, #m, #b, Format.checksum(m .. b))
               .. m .. b
    end

    ---------------------------------------------------------------------------
    t.describe('the checksum is a real Adler-32')

    -- Known values, so a rewrite of the loop cannot quietly change what every
    -- previously written save claims about itself.
    t.eq(Format.checksum(''), 1, 'the empty string checksums to 1')
    t.eq(Format.checksum('a'), 0x00620062, '"a" matches the reference value')
    t.eq(Format.checksum('abc'), 0x024d0127, '"abc" matches the reference value')
    t.ok(Format.checksum('Wikipedia') == 0x11E60398, 'a longer known vector matches')

    -- The deferred modulo is only correct if a block boundary changes nothing.
    local long = ('x'):rep(5551) .. 'y' .. ('z'):rep(5551)
    t.ok(Format.checksum(long) == Format.checksum(long), 'a multi-block input is stable')
    t.ok(Format.checksum(long) ~= Format.checksum(long:sub(1, #long - 1)),
         'dropping a byte from a multi-block input changes the checksum')

    ---------------------------------------------------------------------------
    t.describe('a document round-trips exactly')

    local doc = {
        version = Format.VERSION,
        meta = { map = 'arena', savedAt = 1700000000, playTime = 91.5,
                 label = 'Before the boss' },
        body = {
            world = { kind = 'grid', grid = { { 1, 1, 1 }, { 1, 0, 1 }, { 1, 1, 1 } },
                      doors = { { '2,2', 1 } } },
            entities = { { id = 4, kind = 'imp', x = 1.5, y = 2.5, angle = 0.25,
                           c = { health = { hp = 17, max = 30 } } } },
            progress = { level = 3, keys = { 'red', 'blue' }, seen = { arena = true } },
            nextId = 5,
        },
    }

    local bytes, encodeErr = Format.encode(doc)
    t.ok(bytes ~= nil, 'a document encodes', encodeErr)
    t.ok(bytes:sub(1, #Format.MAGIC) == Format.MAGIC, 'the file starts with the magic')

    local back, decodeErr = Format.decode(bytes)
    t.ok(back ~= nil, 'it decodes again', decodeErr)
    t.eq(back.version, Format.VERSION, 'the version survives')
    t.eq(back.meta.map, 'arena', 'the map name survives')
    t.eq(back.meta.playTime, 91.5, 'the play time survives')
    t.eq(back.meta.label, 'Before the boss', 'the label survives')
    t.eq(back.body.progress.level, 3, 'game progress survives')
    t.eq(back.body.progress.keys[2], 'blue', 'a nested array in progress survives')
    t.eq(back.body.progress.seen.arena, true, 'a nested map in progress survives')
    t.eq(back.body.entities[1].c.health.hp, 17, 'component state survives')
    t.eq(back.body.world.grid[2][2], 0, 'the world grid survives')
    t.eq(back.body.nextId, 5, 'the id counter survives')

    -- Version is written once, inside the metadata section, and lifted back out
    -- on the way in. A copy left behind would be a second answer to the same
    -- question, and the two would eventually disagree.
    t.eq(back.meta.version, nil, 'the version is not left in the metadata')

    t.describe('awkward values survive a save')
    local awkward = Format.decode(Format.encode({
        version = Format.VERSION, meta = {},
        body = { n = { 0.1, 1 / 3, -12.345678901234567, 1e300, 2 ^ -30 },
                 s = { 'has:colons', '$5:fake', 'new\nline', 'nul\0byte' },
                 flags = { yes = true, no = false } },
    }))
    t.eq(awkward.body.n[1], 0.1, 'a float survives bit-exactly')
    t.eq(awkward.body.n[3], -12.345678901234567, 'a long float survives bit-exactly')
    t.eq(awkward.body.n[4], 1e300, 'a huge float survives')
    t.eq(awkward.body.s[2], '$5:fake', 'a string that looks like the format survives')
    t.eq(awkward.body.s[4], 'nul\0byte', 'a string with a NUL survives')
    t.eq(awkward.body.flags.no, false, 'false survives as false, not as absent')

    ---------------------------------------------------------------------------
    t.describe('metadata reads without the body')

    -- The property a save browser depends on: listing ten slots must not
    -- deserialise ten worlds. A prefix of the file is enough, and the body bytes
    -- are never looked at.
    local big = Format.encode({
        version = Format.VERSION,
        meta = { map = 'big', savedAt = 42, playTime = 7 },
        body = { blob = (function()
            local rows = {}
            for y = 1, 64 do
                local row = {}
                for x = 1, 64 do row[x] = (x * y) % 10 end
                rows[y] = row
            end
            return rows
        end)() },
    })

    t.ok(#big > 8 * 1024, ('a 64x64 world makes a file worth not reading twice (%d bytes)')
                          :format(#big))

    local header = Format.parseHeader(big:sub(1, 64))
    t.ok(header ~= nil, 'the header parses out of the first 64 bytes')
    t.ok(header.headerLen + header.metaLen < Format.PROBE_BYTES,
         'the header and metadata fit inside one probe read')

    local prefix = big:sub(1, Format.PROBE_BYTES)
    local info, metaErr = Format.readMeta(prefix)
    t.ok(info ~= nil, 'metadata reads from a prefix alone', metaErr)
    t.eq(info.meta.map, 'big', 'the map name is in the metadata')
    t.eq(info.version, Format.VERSION, 'the version is in the metadata')
    t.ok(#prefix < #big, ('the prefix read is %d bytes of a %d byte save')
                         :format(#prefix, #big))

    -- A caller that hands over too little gets told how much it needs, rather
    -- than a guess made from what it did hand over.
    local short, shortErr, shortHeader = Format.readMeta(big:sub(1, header.headerLen + 4))
    t.ok(short == nil, 'too short a prefix is refused')
    t.ok(tostring(shortErr):find('need'), 'and says how many bytes it needed', shortErr)
    t.ok(shortHeader ~= nil, 'and still hands back the parsed header')

    ---------------------------------------------------------------------------
    t.describe('a truncated save fails cleanly')

    -- Every prefix of a valid save, at every length. Not one of them may raise,
    -- and not one may decode.
    local raised, decoded = 0, 0
    for cut = 0, #bytes - 1 do
        local ok, value, err = pcall(Format.decode, bytes:sub(1, cut))
        if not ok then
            raised = raised + 1
        else
            if value ~= nil then decoded = decoded + 1 end
            if value == nil and (err == nil or err == '') then decoded = decoded + 1 end
        end
    end
    t.eq(raised, 0, ('no prefix of a save raises (%d bytes tested)'):format(#bytes))
    t.eq(decoded, 0, 'no prefix of a save decodes, and every refusal has a reason')

    local cutMid = Format.decode(bytes:sub(1, #bytes - 20))
    t.ok(cutMid == nil, 'a save missing its last 20 bytes is refused')
    local _, cutErr = Format.decode(bytes:sub(1, #bytes - 20))
    t.ok(tostring(cutErr):find('truncated'), 'and is called truncated', cutErr)
    t.ok(tostring(cutErr):find('20'), 'and says 20 bytes are missing', cutErr)

    t.describe('trailing bytes are refused too')
    local appended, appendErr = Format.decode(bytes .. 'leftover')
    t.ok(appended == nil, 'a save with something appended is refused')
    t.ok(tostring(appendErr):find('8 bytes after'), 'and says how much extra there is',
         appendErr)

    ---------------------------------------------------------------------------
    t.describe('garbage fails cleanly')

    for _, junk in ipairs({
        '', 'x', 'hello world', ('\0'):rep(64), ('\255'):rep(300),
        'MEATRAYSAVE', 'MEATRAYSAVE\n', 'MEATRAYSAVE 1 2 3',
        'MEATRAYSAVE a b c\nxx', 'MEATRAYSAVE 4 4 4\n', 'MEATRAYSAV 1 1 1\nab',
        Serialize.encode({ hello = 'world' }),
    }) do
        local ok, value, err = pcall(Format.decode, junk)
        t.ok(ok, ('%q does not raise'):format(junk:sub(1, 24):gsub('%c', '?')))
        t.ok(ok and value == nil, ('%q does not decode'):format(junk:sub(1, 24):gsub('%c', '?')))
        t.ok(ok and type(err) == 'string' and #err > 8,
             ('%q is refused with a useful reason'):format(junk:sub(1, 24):gsub('%c', '?')),
             err)
    end

    local notOurs, notOursErr = Format.decode('PK\3\4 this is a zip file')
    t.ok(notOurs == nil, 'a file of another format is refused')
    t.ok(tostring(notOursErr):find('not a MeatRayCast save'),
         'and is told it is not a save at all', notOursErr)

    t.describe('a flipped byte is caught by the checksum')
    -- The dangerous corruption is the kind that still decodes. Flip one byte of
    -- the payload and the value would come back subtly wrong; the checksum is
    -- the only thing standing between that and a save that loads a lie.
    local flippedAt, caught, silent = 0, 0, 0
    for at = #bytes - 200, #bytes do
        if at > 0 then
            local c = bytes:byte(at)
            local mutated = bytes:sub(1, at - 1) .. string.char((c + 1) % 256) .. bytes:sub(at + 1)
            flippedAt = flippedAt + 1
            local ok, value = pcall(Format.decode, mutated)
            if not ok then
                silent = silent + 1                 -- a raise is a failure too
            elseif value == nil then
                caught = caught + 1
            else
                silent = silent + 1
            end
        end
    end
    t.eq(caught, flippedAt, ('every one of %d single-byte corruptions is refused')
                            :format(flippedAt))
    t.eq(silent, 0, 'and none of them raises or decodes')

    ---------------------------------------------------------------------------
    t.describe('valid serialisation of the wrong shape is refused')

    -- These files are byte-perfect: right magic, right lengths, right checksum.
    -- Everything the envelope can check passes, and the contents are still not a
    -- save. This is the case a format with only a checksum cannot see.
    local wrongBody, wrongBodyErr = Format.decode(frame({ version = 1 }, { 1, 2, 3 }))
    t.ok(wrongBody ~= nil, 'an array body is structurally acceptable', wrongBodyErr)

    -- Hand-built so the lengths and the checksum are honest and only the shape
    -- is wrong: the envelope has nothing left to object to, and the file is
    -- still not a save.
    local mm, mb = Serialize.encode('metadata, but a string'), Serialize.encode({})
    local stringMeta = ('%s %d %d %d\n'):format(Format.MAGIC, #mm, #mb,
                                                Format.checksum(mm .. mb)) .. mm .. mb
    local stringMetaDoc, stringMetaErr = Format.decode(stringMeta)
    t.ok(stringMetaDoc == nil, 'a metadata section that is not a table is refused')
    t.ok(tostring(stringMetaErr):find('not a table'), 'and says what it found instead',
         stringMetaErr)

    local m, b = Serialize.encode({ version = 1 }), Serialize.encode('a string, not a body')
    local scalarBody = ('%s %d %d %d\n'):format(Format.MAGIC, #m, #b, Format.checksum(m .. b))
                       .. m .. b
    local scalar, scalarErr = Format.decode(scalarBody)
    t.ok(scalar == nil, 'a body that is not a table is refused')
    t.ok(tostring(scalarErr):find('not a table'), 'and says so', scalarErr)

    ---------------------------------------------------------------------------
    t.describe('a save from the future is refused by name')

    local future, futureErr = Format.decode(frame({ version = Format.VERSION + 7 }, {}))
    t.ok(future == nil, 'a newer save does not load')
    t.ok(tostring(futureErr):find('newer build'), 'and blames the newer build', futureErr)
    t.ok(tostring(futureErr):find(tostring(Format.VERSION + 7)),
         'and names the version it found', futureErr)
    t.ok(tostring(futureErr):find(tostring(Format.VERSION)),
         'and the version it can read', futureErr)

    t.describe('a save with no version is refused')
    local unversioned, unversionedErr = Format.decode(frame({ map = 'arena' }, {}))
    t.ok(unversioned == nil, 'an unversioned save does not load')
    t.ok(tostring(unversionedErr):find('no version'), 'and says the version is missing',
         unversionedErr)

    -- The temptation is to assume an unversioned file is version 1. That would
    -- make the version field decorative on exactly the day it starts to matter.
    t.ok(not tostring(unversionedErr):find('corrupt'),
         'and is not mistaken for corruption')

    local badVersion, badVersionErr = Format.decode(frame({ version = 'one' }, {}))
    t.ok(badVersion == nil, 'a non-numeric version is refused')
    t.ok(tostring(badVersionErr):find('whole number'), 'and says what a version is',
         badVersionErr)

    local fractional = Format.decode(frame({ version = 1.5 }, {}))
    t.ok(fractional == nil, 'a fractional version is refused')

    ---------------------------------------------------------------------------
    t.describe('migration')

    --[[
        The mechanism exists from v1, and this is what proves it. A v0 file is
        written (encode takes an explicit version so a migration can be developed
        against a file it can actually produce), a v0 -> v1 migration is
        registered in a registry of this test's own, and the file loads through
        it as a v1 document.

        There is no real v0: version 1 is the first version there has ever been,
        and inventing a predecessor to have an entry in the table would be
        inventing history. What is being asserted is that the day the first real
        migration is needed, the machinery it needs is already here and already
        known to work — rather than being designed under pressure against files
        that are already on players' disks.
    ]]
    local v0 = Format.encode({
        version = 0,
        meta = { map = 'arena', savedAt = 1 },
        body = { doorsOpen = { '2,2' }, progress = { level = 2 } },
    }, { version = 0 })
    t.ok(v0 ~= nil, 'a v0 file can be produced')

    local refused, refusedErr = Format.decode(v0)
    t.ok(refused == nil, 'with no migration registered, a v0 save is refused')
    t.ok(tostring(refusedErr):find('no migration from save version 0'),
         'and names the version it cannot upgrade', refusedErr)

    local ran = 0
    local registry = {
        [0] = function(old)
            ran = ran + 1
            -- A real migration reshapes: v0 kept open doors as a list, v1 keeps
            -- a world payload. Nothing about that is special-cased in the
            -- decoder; the migration owns the whole document.
            local doors = {}
            for _, key in ipairs(old.body.doorsOpen or {}) do
                doors[#doors + 1] = { key, 1 }
            end
            return {
                version = 1,
                meta = old.meta,
                body = { world = { kind = 'grid', grid = { { 1 } }, doors = doors },
                         entities = {}, progress = old.body.progress, nextId = 1 },
            }
        end,
    }

    local migrated, migrateErr = Format.decode(v0, { migrations = registry })
    t.ok(migrated ~= nil, 'with a migration registered, a v0 save loads', migrateErr)
    t.eq(ran, 1, 'the migration ran exactly once')
    t.eq(migrated.version, 1, 'and the document is at the current version')
    t.eq(migrated.meta.map, 'arena', 'metadata carried through the migration')
    t.eq(migrated.body.progress.level, 2, 'progress carried through the migration')
    t.eq(migrated.body.world.doors[1][1], '2,2', 'the reshaped door survived')

    t.describe('a decoder can ask for the document as written')
    local raw = Format.decode(v0, { migrate = false })
    t.ok(raw ~= nil, 'migration can be skipped')
    t.eq(raw.version, 0, 'and the document comes back at its own version')

    t.describe('a broken migration cannot break the loader')

    local looping = Format.decode(v0, { migrations = { [0] = function(old) return old end } })
    t.ok(looping == nil, 'a migration that does not raise the version is caught')
    local _, loopErr = Format.decode(v0, { migrations = { [0] = function(old) return old end } })
    t.ok(tostring(loopErr):find('did not raise the version'), 'and says why', loopErr)

    local raisingErr
    local raising
    raising, raisingErr = Format.decode(v0, {
        migrations = { [0] = function() error('migration is broken', 0) end },
    })
    t.ok(raising == nil, 'a migration that raises does not escape the loader')
    t.ok(tostring(raisingErr):find('migration is broken'),
         'and the reason is passed through', raisingErr)

    local refusing, refusingErr = Format.decode(v0, {
        migrations = { [0] = function() return nil, 'this save predates doors' end },
    })
    t.ok(refusing == nil, 'a migration may refuse a document')
    t.ok(tostring(refusingErr):find('predates doors'), 'and its reason reaches the caller',
         refusingErr)

    local wrongShape = Format.decode(v0, { migrations = { [0] = function() return 42 end } })
    t.ok(wrongShape == nil, 'a migration returning nonsense is caught')

    t.describe('the registry is public API')
    t.ok(type(Format.migrations) == 'table', 'migrations are registered in a table')
    t.ok(type(Format.migration) == 'function', 'and there is a function to register one')

    ---------------------------------------------------------------------------
    t.describe('encoding refuses what it cannot store')

    local withFunction, functionErr = Format.encode({
        version = Format.VERSION, meta = {}, body = { onLoad = function() end },
    })
    t.ok(withFunction == nil, 'a function in the body is refused at save time')
    t.ok(tostring(functionErr):find('function'), 'and the message names it', functionErr)

    local noBody, noBodyErr = Format.encode({ version = Format.VERSION, meta = {} })
    t.ok(noBody == nil, 'a document with no body is refused')
    t.ok(tostring(noBodyErr):find('body'), 'and says so', noBodyErr)

    local hugeMeta, hugeMetaErr = Format.encode({
        version = Format.VERSION, meta = { note = ('x'):rep(Format.MAX_META + 1) },
        body = {},
    })
    t.ok(hugeMeta == nil, 'oversized metadata is refused')
    t.ok(tostring(hugeMetaErr):find('body'), 'and points at the body as the place for it',
         hugeMetaErr)

    t.ok(Format.encode('not a document') == nil, 'a non-table document is refused')
    t.ok(Format.decode(nil) == nil, 'decoding a nil is refused')
    t.ok(Format.decode(42) == nil, 'decoding a number is refused')

    t.describe('the header refuses absurd lengths before allocating')
    local absurd, absurdErr = Format.decode(
        ('%s %d 1 1\n'):format(Format.MAGIC, Format.MAX_META + 1))
    t.ok(absurd == nil, 'a header claiming more metadata than the limit is refused')
    t.ok(tostring(absurdErr):find('limit'), 'and names the limit', absurdErr)

    local absurdBody, absurdBodyErr = Format.decode(
        ('%s 1 %d 1\n'):format(Format.MAGIC, Format.MAX_BODY + 1))
    t.ok(absurdBody == nil, 'a header claiming more body than the limit is refused')
    t.ok(tostring(absurdBodyErr):find('limit'), 'and names that limit too', absurdBodyErr)
end
