--[[
    meatray.asset.registry — what the project thinks it has, and what it actually got.

    The engine needs zero files, and that must stay true after import exists. So
    the registry is built around one rule: **a lookup that misses falls back to
    something generated, and never raises.** A project with no assets runs. A
    project with half its assets runs and shows exactly which half is missing,
    because a placeholder that announces itself is worth more than a crash on the
    first frame that happened to reference the missing thing.

    That is not politeness. Two of this author's other projects ship broken-image
    or crash-on-missing behaviour, and in both cases the cause was a single load
    site that called straight into the loader with no guard. There is exactly one
    load site here, and it is wrapped.

    Four states, and the difference between the last two is the whole point:

        pending    declared, not loaded yet
        file       loaded from disk, as asked
        generated  no source path was ever given; procedural by design
        fallback   a source path was given and did not load; MISSING

    `generated` is a working sprite with no art yet. `fallback` is a bug or a bad
    filename. Collapsing them into one "not loaded" state is how a missing-asset
    report becomes noise nobody reads.

    HEADLESS: no love.* anywhere in this file. Loaders and fallback producers are
    injected by whoever has a graphics or audio context, which is what lets the
    resolution policy — the part with the interesting failure modes — be tested
    under plain LuaJIT with no LÖVE at all.
]]

local Registry = {}

local records = {}      -- [kind .. ':' .. name] = record
local loaders = {}      -- [kind] = function(record) -> value, err
local fallbacks = {}    -- [kind] = function(record) -> value

-- Names are namespaced per kind, so a project may have a `door` sprite and a
-- `door` sound without one replacing the other. That is not a hypothetical: it is
-- the first collision any real game hits, and a flat namespace resolves it by
-- silently overwriting whichever was declared first — a sprite that turns into a
-- sound and draws nothing, with no error anywhere.
--
-- The cost is that a lookup must say which kind it means. Every caller already
-- knows: Sound asks for sounds, Asset.sprite asks for sprites. Making it explicit
-- is cheaper than making it ambiguous.
local function keyFor(name, kind)
    assert(type(name) == 'string' and name ~= '', 'an asset needs a name')
    assert(type(kind) == 'string' and kind ~= '',
           ('looking up asset "%s" needs a kind: names are namespaced per kind')
               :format(tostring(name)))
    return kind .. ':' .. name
end

-- Kinds the engine ships. Not a closed set — declaring an unknown kind works and
-- simply has no loader, which resolves to a fallback. That is the correct
-- behaviour for a kind nobody has taught the registry about yet.
Registry.KINDS = { 'sprite', 'texture', 'sound', 'music', 'map', 'theme' }

-- Optional releaser: when an asset is unloaded, free host resources (Image,
-- Source, …). Injected so the headless registry never names love.
local releasers = {} -- [kind] = function(value, record)

function Registry.setReleaser(kind, fn)
    releasers[kind] = fn
end

function Registry.hasReleaser(kind) return releasers[kind] ~= nil end

-- Monotonic clock for LRU (seconds). Overridable in tests via Registry.now.
local clock = 0
function Registry.now()
    return clock
end

-- Advance the logical clock. Games may call this with love.timer.getTime() or
-- leave it alone and let touch() bump by 1 each resolve.
function Registry.tickClock(t)
    if type(t) == 'number' then
        clock = t
    else
        clock = clock + 1
    end
    return clock
end

function Registry.resetClock()
    clock = 0
end

---------------------------------------------------------------------------
-- Wiring
---------------------------------------------------------------------------

-- A loader turns a record into a value, or returns nil plus a reason. It may
-- also raise: resolve() calls it protected, because a loader that throws on a
-- corrupt file must degrade to a placeholder like any other failure, not take the
-- frame with it.
function Registry.setLoader(kind, fn)
    loaders[kind] = fn
end

-- A fallback producer makes the stand-in value for a kind. Registering none is
-- allowed; the record simply resolves with a nil value and a stated problem,
-- which is still not an error.
function Registry.setFallback(kind, fn)
    fallbacks[kind] = fn
end

function Registry.hasLoader(kind) return loaders[kind] ~= nil end

---------------------------------------------------------------------------
-- Declaring
---------------------------------------------------------------------------

-- Registers intent. Declaring is deliberately separate from loading: the browser
-- wants to list everything a project expects before deciding what to open, and a
-- game wants to declare its assets at startup without paying for them until they
-- are drawn.
--
--   Registry.declare('imp', 'sprite', { path = 'assets/sprites/imp_a8_f4.png',
--                                       settings = { angles = 8, frames = 4 } })
--   Registry.declare('crystal', 'sprite')            -- procedural by design
--
-- Re-declaring a name replaces it and drops any loaded value, which is what makes
-- re-import and hot reload work without a separate invalidation path.
function Registry.declare(name, kind, opts)
    opts = opts or {}
    kind = kind or 'sprite'

    local record = {
        name = name,
        kind = kind,
        path = opts.path,
        settings = opts.settings or {},
        state = 'pending',
        value = nil,
        problem = nil,
        attempts = 0,
        declaredAt = opts.declaredAt,
        lastUsed = 0,
        pinned = opts.pinned and true or false,
    }

    records[keyFor(name, kind)] = record
    return record
end

function Registry.get(name, kind)
    return records[keyFor(name, kind)]
end

-- Every record carrying this name, whatever its kind. The question a browser asks
-- ("is this name already taken, and by what?"), never the question gameplay asks.
function Registry.find(name)
    local out = {}
    for _, record in pairs(records) do
        if record.name == name then out[#out + 1] = record end
    end
    table.sort(out, function(a, b) return a.kind < b.kind end)
    return out
end

function Registry.forget(name, kind)
    records[keyFor(name, kind)] = nil
end

function Registry.clear()
    for _, record in pairs(records) do
        Registry._releaseValue(record)
    end
    records = {}
end

-- Loaders and fallbacks survive clear() on purpose — they are wiring, not
-- content. clearAll() drops them too, which only a test wants.
function Registry.clearAll()
    for _, record in pairs(records) do
        Registry._releaseValue(record)
    end
    records = {}
    loaders = {}
    fallbacks = {}
    releasers = {}
    clock = 0
end

function Registry._releaseValue(record)
    if not record or record.value == nil then return end
    local rel = releasers[record.kind]
    if rel then pcall(rel, record.value, record) end
end

---------------------------------------------------------------------------
-- Resolving — the one guarded load site
---------------------------------------------------------------------------

local function useFallback(record, problem)
    record.problem = problem
    local make = fallbacks[record.kind]
    if make then
        local ok, value = pcall(make, record)
        record.value = ok and value or nil
        if not ok then
            -- A fallback that itself throws is a bug in the fallback, and saying
            -- so beats reporting it as a missing file.
            record.problem = ('%s (and the %s placeholder failed: %s)')
                :format(tostring(problem), record.kind, tostring(value))
        end
    else
        record.value = nil
    end
    return record
end

-- Loads the record if it has not been loaded, and returns it. Never raises.
--
-- The record always comes back; check `record.state` and `record.value`. A caller
-- that wants only the value calls Registry.value().
function Registry.resolve(name, kind, force)
    local record = records[keyFor(name, kind)]
    if not record then return nil end
    if record.state ~= 'pending' and not force then
        Registry.touch(name, kind)
        return record
    end

    record.attempts = record.attempts + 1

    -- No path was ever given: this asset is procedural by design, not missing.
    if not record.path or record.path == '' then
        record.state = 'generated'
        record.problem = nil
        local make = fallbacks[record.kind]
        if make then
            local ok, value = pcall(make, record)
            record.value = ok and value or nil
            if not ok then record.problem = tostring(value) end
        end
        Registry.touch(name, kind)
        return record
    end

    local load = loaders[record.kind]
    if not load then
        record.state = 'fallback'
        return useFallback(record, ('no loader registered for kind "%s"'):format(tostring(record.kind)))
    end

    -- Drop the previous host value before a forced reload so we do not leak.
    if force and record.value ~= nil then
        Registry._releaseValue(record)
        record.value = nil
    end

    local ok, value, err = pcall(load, record)

    if not ok then
        record.state = 'fallback'
        return useFallback(record, tostring(value))
    end
    if value == nil then
        record.state = 'fallback'
        return useFallback(record, err and tostring(err)
                           or ('could not load ' .. tostring(record.path)))
    end

    record.state = 'file'
    record.value = value
    record.problem = nil
    Registry.touch(name, kind)
    return record
end

---------------------------------------------------------------------------
-- Streaming: touch / pin / unload / LRU evict
--
-- Campaigns with more sheets than VRAM (or more WAVs than RAM) declare
-- everything up front and resolve on demand. When the budget is hit, the least
-- recently used file-backed assets drop back to `pending` and reload next time
-- they are drawn. Pinned assets (HUD, current map theme) never evict.
---------------------------------------------------------------------------

function Registry.touch(name, kind)
    local record = records[keyFor(name, kind)]
    if not record then return nil end
    clock = clock + 1
    record.lastUsed = clock
    return record
end

function Registry.pin(name, kind, pinned)
    local record = records[keyFor(name, kind)]
    if not record then return nil end
    if pinned == nil then pinned = true end
    record.pinned = pinned and true or false
    return record
end

function Registry.isPinned(name, kind)
    local record = records[keyFor(name, kind)]
    return record and record.pinned or false
end

-- Drops the loaded value and returns the record to pending (file-backed) or
-- keeps generated/fallback with a cleared value as appropriate. Declaration and
-- path stay so the next resolve reloads from disk. Pinned assets refuse unless
-- force is true.
function Registry.unload(name, kind, force)
    local record = records[keyFor(name, kind)]
    if not record then return nil, 'unknown' end
    if record.pinned and not force then return record, 'pinned' end
    if record.value == nil and record.state == 'pending' then
        return record, 'already'
    end

    Registry._releaseValue(record)
    record.value = nil
    record.problem = nil

    if record.path and record.path ~= '' then
        -- Ready to load again on next resolve.
        record.state = 'pending'
    else
        -- Procedural: regenerate next time rather than leave a nil value cached.
        record.state = 'pending'
    end
    return record, 'unloaded'
end

-- How many records currently hold a loaded value.
-- opts.filesOnly (default false): count only state == 'file' (what eviction budgets).
function Registry.loadedCount(kind, opts)
    opts = opts or {}
    local filesOnly = opts.filesOnly
    local n = 0
    for _, record in pairs(records) do
        if (not kind or record.kind == kind) and record.value ~= nil then
            if filesOnly then
                if record.state == 'file' then n = n + 1 end
            elseif record.state == 'file' or record.state == 'generated' then
                n = n + 1
            end
        end
    end
    return n
end

--[[
    Evict least-recently-used file-backed assets until their count <= maxLoaded.
    Generated placeholders are free and never evicted. opts:
      kind     only consider this kind
      force    allow unpinning (default false)
    Returns the number of assets unloaded.
]]
function Registry.evict(maxLoaded, opts)
    opts = opts or {}
    maxLoaded = tonumber(maxLoaded) or 0
    if maxLoaded < 0 then maxLoaded = 0 end

    local candidates = {}
    for _, record in pairs(records) do
        if (not opts.kind or record.kind == opts.kind)
           and record.value ~= nil
           and record.state == 'file'
           and (opts.force or not record.pinned) then
            candidates[#candidates + 1] = record
        end
    end
    table.sort(candidates, function(a, b)
        local au, bu = a.lastUsed or 0, b.lastUsed or 0
        if au ~= bu then return au < bu end
        if a.kind ~= b.kind then return a.kind < b.kind end
        return a.name < b.name
    end)

    local unloaded = 0
    local function fileCount()
        return Registry.loadedCount(opts.kind, { filesOnly = true })
    end
    while fileCount() > maxLoaded and unloaded < #candidates do
        local rec = candidates[unloaded + 1]
        unloaded = unloaded + 1
        Registry.unload(rec.name, rec.kind, opts.force)
    end
    return unloaded
end

-- Resolve a list of names so they sit in memory (and get a fresh lastUsed).
-- Returns how many resolved to a non-nil value.
function Registry.preload(list, kind)
    local n = 0
    for i = 1, #(list or {}) do
        local name = list[i]
        if type(name) == 'table' then
            kind = name.kind or kind
            name = name.name
        end
        local rec = Registry.resolve(name, kind)
        if rec and rec.value ~= nil then n = n + 1 end
    end
    return n
end

-- The value, or the placeholder, or nil. Never an error, never a nil-index into
-- an unresolved record — this is the call gameplay code makes every frame.
function Registry.value(name, kind)
    local record = Registry.resolve(name, kind)
    return record and record.value or nil
end

function Registry.resolveAll()
    for _, record in pairs(records) do Registry.resolve(record.name, record.kind) end
end

---------------------------------------------------------------------------
-- Inventory
---------------------------------------------------------------------------

-- Sorted by kind then name, so a listing is stable frame to frame — one that
-- reshuffles as the hash order changes is unusable — and so two kinds sharing a
-- name stay next to each other rather than interleaved.
local function sortedRecords(filter)
    local out = {}
    for _, record in pairs(records) do
        if not filter or filter(record) then out[#out + 1] = record end
    end
    table.sort(out, function(a, b)
        if a.kind ~= b.kind then return a.kind < b.kind end
        return a.name < b.name
    end)
    return out
end

function Registry.records(kind)
    return sortedRecords(kind and function(r) return r.kind == kind end or nil)
end

-- Names of every declared asset, optionally of one kind. Without a kind the same
-- name can legitimately appear twice, once per kind — which is the point of the
-- namespacing, and why records() rather than list() is what a browser wants.
function Registry.list(kind)
    local out = {}
    for _, record in ipairs(Registry.records(kind)) do out[#out + 1] = record.name end
    return out
end

function Registry.count(kind)
    return #Registry.list(kind)
end

-- Everything that was asked for from a file and did not get it. This is the
-- "which half is missing" API, and it resolves pending records first: an asset
-- nobody has drawn yet is exactly the one whose absence you want to hear about
-- before you ship, not after.
function Registry.missing()
    Registry.resolveAll()
    return sortedRecords(function(r) return r.state == 'fallback' end)
end

-- A counted summary, per kind and overall. `missing` is the number that matters;
-- `generated` is the number that is fine.
function Registry.report()
    Registry.resolveAll()

    local summary = {
        total = 0, file = 0, generated = 0, fallback = 0, pending = 0,
        byKind = {},
    }

    for _, record in pairs(records) do
        summary.total = summary.total + 1
        summary[record.state] = (summary[record.state] or 0) + 1

        local k = summary.byKind[record.kind]
        if not k then
            k = { total = 0, file = 0, generated = 0, fallback = 0, pending = 0 }
            summary.byKind[record.kind] = k
        end
        k.total = k.total + 1
        k[record.state] = (k[record.state] or 0) + 1
    end

    summary.missing = summary.fallback
    return summary
end

-- One line per missing asset, ready for the console. Kept here rather than in the
-- panel so a headless build can print the same report at startup.
function Registry.missingLines()
    local out = {}
    for _, record in ipairs(Registry.missing()) do
        out[#out + 1] = ('%s (%s): %s -> %s')
            :format(record.name, record.kind, tostring(record.path),
                    tostring(record.problem or 'unknown reason'))
    end
    return out
end

return Registry
