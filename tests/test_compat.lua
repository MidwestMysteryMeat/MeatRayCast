--[[
    G6: the golden wire/save corpus. Every fixture is bytes a PAST build wrote
    (committed in tests/fixtures/compat_corpus.lua); this build must still
    decode all of them, and — while the format version is unchanged — must
    re-encode the same fixture to the same bytes.

    The two halves catch different failures:
      * decode-still-works is FORWARD compatibility: the reason a client is
        not silently kicked when the server ships a new build.
      * re-encode-matches is DRIFT detection: a change to the encoder that
        forgot to bump the version fails here, loudly, instead of shipping a
        format two builds disagree on.

    When a version IS bumped on purpose, `luajit scripts/gen_corpus.lua`
    regenerates the file — and the OLD entries stay, because the promise is
    that new builds read old bytes, not that old bytes vanish.
]]

return function(t)
    local Fixtures = require('tests.support.corpus_fixtures')
    local corpus = require('tests.fixtures.compat_corpus')

    Fixtures.pinBackend()

    local function fromHex(hex)
        return (hex:gsub('%x%x', function(pair)
            return string.char(tonumber(pair, 16))
        end))
    end

    local function toHex(s)
        local parts = {}
        for i = 1, #s do parts[i] = ('%02x'):format(s:byte(i)) end
        return table.concat(parts)
    end

    -- Index the fixtures by name so a corpus entry finds its checker.
    local byName = {}
    for _, fx in ipairs(Fixtures.all()) do byName[fx.name] = fx end

    t.ok(#corpus >= 5, ('the corpus has entries (%d)'):format(#corpus))

    ---------------------------------------------------------------------
    t.describe('every golden entry still decodes on this build')

    for _, entry in ipairs(corpus) do
        local fx = byName[entry.name]
        t.ok(fx ~= nil, entry.name .. ' still has a fixture definition')
        if fx then
            local bytes = fromHex(entry.bytes)
            local ok, why = Fixtures.decode(fx, bytes)
            t.eq(ok, true, ('%s decodes to sound data'):format(entry.name)
                 .. (ok and '' or (' — ' .. tostring(why))))
        end
    end

    ---------------------------------------------------------------------
    t.describe('unchanged formats have not drifted (semantic)')

    -- The text serializer walks tables with pairs(), so its key ORDER is not
    -- stable across two processes — a byte-exact golden match is impossible
    -- for the text-encoded fixtures and would fail for a reason that is not a
    -- bug. The sound check is semantic: decode the golden bytes, encode the
    -- fixture fresh and decode THAT, and the two decoded structures must be
    -- deeply equal. A dropped field, a changed number format, a renamed key —
    -- all move the decode; only key order, which nothing downstream can
    -- observe, is allowed to differ. Binary formats (snapshot) happen to be
    -- byte-stable too, and get that stronger check for free below.
    local P = require('meatray.net.protocol')
    local Format = require('meatray.save.format')

    local function deepEqual(a, b, path)
        path = path or 'v'
        if type(a) ~= type(b) then
            return false, ('%s: %s vs %s'):format(path, type(a), type(b))
        end
        if type(a) ~= 'table' then
            if a ~= b and not (a ~= a and b ~= b) then       -- NaN == NaN here
                return false, ('%s: %s vs %s'):format(path, tostring(a), tostring(b))
            end
            return true
        end
        for k, v in pairs(a) do
            local ok, why = deepEqual(v, b[k], path .. '.' .. tostring(k))
            if not ok then return false, why end
        end
        for k in pairs(b) do
            if a[k] == nil then return false, path .. '.' .. tostring(k) .. ' appeared' end
        end
        return true
    end

    local function decodeStruct(fx, bytes)
        if fx.kind == 'save' then
            local doc = Format.decode(bytes)
            return doc and doc.body
        end
        local _, body = P.unpack(bytes)
        return body
    end

    for _, entry in ipairs(corpus) do
        local fx = byName[entry.name]
        if fx then
            local current = (fx.kind == 'save') and Format.VERSION or P.VERSION
            if entry.version == current then
                local goldStruct = decodeStruct(fx, fromHex(entry.bytes))
                local freshStruct = decodeStruct(fx, fx.encode(fx.build()))
                local same, why = deepEqual(goldStruct, freshStruct)
                t.eq(same, true,
                     ('%s round-trips to the same data (format v%d unchanged) — '
                      .. 'if this fails the encoder drifted; bump the version and '
                      .. 'regenerate, do NOT just regenerate'):format(entry.name, current)
                     .. (same and '' or (' — ' .. tostring(why))))

                -- Binary formats are byte-stable; hold them to it, so a codec
                -- that quietly changes its layout is caught at the strongest
                -- possible resolution.
                if fx.kind == 'snapshot' or fx.name == 'packet.ping' then
                    t.eq(toHex(fx.encode(fx.build())), entry.bytes,
                         entry.name .. ' is byte-for-byte stable')
                end
            end
        end
    end
end
