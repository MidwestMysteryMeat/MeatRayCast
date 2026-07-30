--[[
    meatray.save — save slots: writing them, listing them, reading them back.

        local Save = require('meatray.save')

        Save.save(1, { world = world, entities = entities,
                       progress = { level = 3 }, map = 'arena',
                       playTime = session.elapsed, label = 'Before the boss' })

        for _, row in ipairs(Save.list()) do
            print(row.slot, row.map, os.date('%c', row.savedAt), row.playTime)
        end

        local state, err = Save.load(1)
        if not state then showMessage(err) else swapIn(state) end

    Three things this layer owns, and each is a decision rather than plumbing.

    **Listing does not open saves.** `Save.list` reads the first kilobyte of each
    file and stops. A browser showing ten slots deserialises no worlds, and the
    cost of the list is independent of how large the saves are. That is only
    possible because the format puts the metadata in its own length-declared
    section ahead of the body, which is why it does.

    **A save that cannot be read still appears in the list**, carrying the reason
    it cannot. Omitting it would be tidier and worse: the file is still there,
    still occupying the slot the player is trying to use, and a browser that
    pretends it does not exist offers no way to delete it. A corrupt save the
    player can see and remove is a smaller problem than a slot that silently
    refuses to be overwritten.

    **Writing goes through a temporary file, and reading knows about it.** What
    that buys is set out at `writeAtomically` below, including what it does not
    buy on a platform without a rename.

    HEADLESS: no LOVE. A dedicated server can persist a world through this.
]]

local Format  = require('meatray.save.format')
local Storage = require('meatray.save.storage')
local State   = require('meatray.save.state')

local Save = {}

Save.format  = Format
Save.storage = Storage
Save.state   = State

Save.VERSION   = Format.VERSION
Save.EXTENSION = '.sav'
Save.TEMP      = '.tmp'

-- Read a file back after writing it. It doubles the I/O of a save and it is
-- worth it: a short write is exactly the failure this system exists to survive,
-- and a disk that accepted 40 KB of a 60 KB file reports success on every call
-- involved. Turn it off only if profiling says to.
Save.verifyWrites = true

local directory = 'saves'
local backend = nil

---------------------------------------------------------------------------
-- Where saves live
---------------------------------------------------------------------------

function Save.setDirectory(dir)
    assert(type(dir) == 'string' and dir ~= '', 'a save directory must be a name')
    directory = (dir:gsub('[/\\]+$', ''))
    return directory
end

function Save.directory()
    return directory
end

-- Substituting a backend is how the tests reach the failure paths, and how a
-- game with its own storage (a console, a cloud save API) plugs in without this
-- module knowing what it is.
function Save.setBackend(b)
    backend = b
    return b
end

function Save.backend()
    if not backend then backend = Storage.detect() end
    return backend
end

-- A human-readable description of where saves are going, for a diagnostic line
-- or an editor panel. The LÖVE backend answers with the real absolute path,
-- which is otherwise the single most asked question about a sandboxed filesystem.
function Save.describe()
    local b = Save.backend()
    if b.describe then return b.describe(directory) end
    return directory
end

---------------------------------------------------------------------------
-- Slot names
---------------------------------------------------------------------------

--[[
    A slot is a number or a name. Numbers become `slot3`, names are taken as
    given once they have proved they are only letters, digits, dash and
    underscore.

    That check is not politeness about tidy filenames. A slot name arriving from
    a text field with `../` in it is a path traversal, and under the io backend —
    the dedicated server, the one running unattended — it writes wherever it
    likes. LÖVE's sandbox would refuse it, but the save system is not entitled to
    assume it is running inside a sandbox.
]]
function Save.slotName(slot)
    if type(slot) == 'number' then
        if slot ~= math.floor(slot) or slot < 0 or slot > 999999 then
            return nil, ('%s is not a usable slot number'):format(tostring(slot))
        end
        return ('slot%d'):format(slot)
    end

    if type(slot) ~= 'string' or slot == '' then
        return nil, ('a slot is a number or a name, got %s'):format(type(slot))
    end
    if #slot > 48 then
        return nil, ('the slot name is %d characters, over the 48 limit'):format(#slot)
    end
    if not slot:match('^[%w][%w%-_]*$') then
        return nil, ('%q is not a usable slot name; use letters, digits, dashes '
                     .. 'and underscores'):format(slot)
    end

    return slot
end

function Save.path(slot)
    local name, err = Save.slotName(slot)
    if not name then return nil, err end
    return directory .. '/' .. name .. Save.EXTENSION, name
end

---------------------------------------------------------------------------
-- Writing
---------------------------------------------------------------------------

local function verify(b, path, bytes)
    if not Save.verifyWrites then return true end

    local back, err = b.read(path)
    if back == nil then
        return nil, ('wrote %s but could not read it back: %s'):format(path, tostring(err))
    end
    if #back ~= #bytes then
        return nil, ('wrote %d bytes to %s but only %d are there')
                    :format(#bytes, path, #back)
    end
    if back ~= bytes then
        return nil, ('%s does not contain what was written to it'):format(path)
    end
    return true
end

--[[
    Write to a temporary file, then put it in place.

    What this guarantees, on every backend: **at every instant there is a
    complete, valid save on disk** — the previous one, or the new one. An
    interrupted save never leaves the player with neither.

    How, and where the platforms differ:

      With a rename (the io backend, i.e. a dedicated server): write the
      temporary file, verify it, rename it over the target. On POSIX the rename
      is atomic and the guarantee is exact. On Windows `rename` refuses an
      existing destination, so the target is removed first and there is a window
      — narrow, but real — where neither file is in place. The temporary file
      still exists throughout it, which is what the reader below relies on.

      Without a rename (LÖVE): PhysFS, which is LÖVE's filesystem, has no rename
      and no move. The API available to a shipped game is write, append, read,
      remove, getInfo, createDirectory, getDirectoryItems and file handles with
      open/write/flush/close — and nothing in that list swaps two files. So the
      sequence is: write the temporary file, verify it, write the target,
      verify it, remove the temporary file. Interrupted during the first write,
      the previous save is untouched. Interrupted during the second, the target
      is short or empty and the temporary file holds a complete new save — which
      `Save.read` finds, checks, and uses, repairing the target as it goes.

    So the honest claim is not "atomic on LÖVE". It is that the failure is always
    detectable, always recoverable from a file that is still on disk, and never
    silent — and that the recovery is part of reading rather than a repair tool
    the player has to be told to run.
]]
local function writeAtomically(b, path, bytes)
    local tmp = path .. Save.TEMP

    local ok, err = b.write(tmp, bytes)
    if not ok then
        return nil, ('could not write the temporary save %s: %s'):format(tmp, tostring(err))
    end

    ok, err = verify(b, tmp, bytes)
    if not ok then
        b.remove(tmp)
        return nil, err
    end

    if b.rename then
        ok, err = b.rename(tmp, path)
        if ok then return true end
        -- Fall through: a failed rename is not a failed save, it is a save that
        -- has to be finished the other way.
    end

    ok, err = b.write(path, bytes)
    if not ok then
        -- The temporary file stays. It is complete, it has been verified, and
        -- Save.read prefers it to a target that will not decode.
        return nil, ('could not write %s: %s (an intact copy is in %s)')
                    :format(path, tostring(err), tmp)
    end

    ok, err = verify(b, path, bytes)
    if not ok then
        return nil, ('%s (an intact copy is in %s)'):format(tostring(err), tmp)
    end

    b.remove(tmp)
    return true
end

-- Writes an already-built document. Returns true, or nil plus a message.
function Save.write(slot, doc)
    local path, name = Save.path(slot)
    if not path then return nil, name end

    local bytes, err = Format.encode(doc)
    if not bytes then return nil, err end

    local b = Save.backend()

    local made, mkErr = b.mkdir(directory)
    if not made then return nil, mkErr end

    local ok, writeErr = writeAtomically(b, path, bytes)
    if not ok then return nil, writeErr end

    return true, #bytes
end

-- Capture and write in one call, which is what a game actually does.
-- `opts` is meatray.save.state.capture's.
function Save.save(slot, opts)
    local doc, err = State.capture(opts)
    if not doc then return nil, err end
    return Save.write(slot, doc)
end

---------------------------------------------------------------------------
-- Reading
---------------------------------------------------------------------------

function Save.exists(slot)
    local path = Save.path(slot)
    if not path then return false end
    return Save.backend().info(path) ~= nil
end

--[[
    Reads and decodes a save.

    Returns the document, or nil plus a message that names what is wrong with the
    file. Every failure is clean: a corrupt, truncated, foreign or future save
    returns nothing at all rather than a partly-populated document, so a caller
    that checks the first return value can never be holding half a save.

    When the target file will not decode and the temporary file beside it will,
    the temporary file is used and the target is rewritten from it. That is the
    interrupted-save case, and the recovered document carries `recovered` with a
    sentence saying so — a game that wants to tell the player "your last save was
    interrupted and has been repaired" has the string, and one that does not care
    ignores a field.
]]
function Save.read(slot, opts)
    local path, name = Save.path(slot)
    if not path then return nil, name end

    local b = Save.backend()
    local bytes = b.read(path)

    if bytes then
        local doc, err = Format.decode(bytes, opts)
        if doc then return doc end

        local tmp = path .. Save.TEMP
        local spare = b.read(tmp)
        if spare then
            local recovered = Format.decode(spare, opts)
            if recovered then
                recovered.recovered = ('the save in slot %q was incomplete (%s) and '
                                       .. 'has been repaired from the temporary file '
                                       .. 'an interrupted save left behind')
                                      :format(name, err)
                b.write(path, spare)
                b.remove(tmp)
                return recovered
            end
        end

        return nil, ('the save in slot %q cannot be read: %s'):format(name, err)
    end

    -- No target file at all. A complete temporary file means a save was
    -- interrupted before the target was ever written; using it is strictly
    -- better than telling the player there is nothing there.
    local tmp = path .. Save.TEMP
    local spare = b.read(tmp)
    if spare then
        local recovered, spareErr = Format.decode(spare, opts)
        if recovered then
            recovered.recovered = ('slot %q had no save file, only the temporary '
                                   .. 'file of an interrupted save; it was complete '
                                   .. 'and has been restored'):format(name)
            b.write(path, spare)
            b.remove(tmp)
            return recovered
        end
        return nil, ('slot %q holds only the leftovers of an interrupted save, and '
                     .. 'they cannot be read: %s'):format(name, spareErr)
    end

    return nil, ('there is no save in slot %q'):format(name)
end

-- Read, then rebuild live state. `opts` goes to meatray.save.state.restore.
function Save.load(slot, opts)
    local doc, err = Save.read(slot)
    if not doc then return nil, err end

    local state, restoreErr = State.restore(doc, opts)
    if not state then return nil, restoreErr end

    state.recovered = doc.recovered
    return state
end

function Save.delete(slot)
    local path, name = Save.path(slot)
    if not path then return nil, name end

    local b = Save.backend()
    local ok, err = b.remove(path)
    if not ok then return nil, err end
    b.remove(path .. Save.TEMP)
    return true
end

---------------------------------------------------------------------------
-- Listing
---------------------------------------------------------------------------

--[[
    The metadata of one slot, without decoding its body.

    One read of the first kilobyte covers the header line and any sane metadata
    section. A save whose metadata is larger than that costs a second read of the
    exact length the header declared — never a read of the whole file, and never
    a wrong answer.
]]
function Save.info(slot)
    local path, name = Save.path(slot)
    if not path then return nil, name end

    local b = Save.backend()

    local stat = b.info(path)
    if not stat then
        return nil, ('there is no save in slot %q'):format(name)
    end

    local prefix, readErr = b.read(path, Format.PROBE_BYTES)
    if prefix == nil then return nil, tostring(readErr) end

    local info, err, header = Format.readMeta(prefix)

    if not info and header and #prefix < header.headerLen + header.metaLen then
        local wider, wideErr = b.read(path, header.headerLen + header.metaLen)
        if wider == nil then return nil, tostring(wideErr) end
        prefix = wider
        info, err = Format.readMeta(prefix)
    end

    if not info then
        return nil, ('the save in slot %q cannot be read: %s'):format(name, err)
    end

    local meta = info.meta

    return {
        slot     = name,
        path     = path,
        bytes    = stat.size,
        version  = info.version,
        savedAt  = tonumber(meta.savedAt) or 0,
        map      = meta.map,
        playTime = tonumber(meta.playTime) or 0,
        label    = meta.label,
        theme    = meta.theme,
        entities = tonumber(meta.entities) or 0,
        meta     = meta,
    }
end

--[[
    Every slot on disk, newest first.

    Rows that could not be read carry `error` and a `slot` and nothing else. They
    are listed, not skipped: see the note at the top of this file. They sort
    last, because a browser should lead with the saves that work.
]]
function Save.list()
    local b = Save.backend()
    local names = b.list(directory) or {}

    local ext = Save.EXTENSION

    local rows = {}
    for _, file in ipairs(names) do
        -- Suffix compared rather than matched, so the temporary files an
        -- interrupted save leaves (`.sav.tmp`) are not listed as slots of their
        -- own — they are the recovery path for a slot that already exists.
        local slot
        if #file > #ext and file:sub(-#ext) == ext then
            slot = file:sub(1, #file - #ext)
        end

        if slot and Save.slotName(slot) then
            local info, err = Save.info(slot)
            rows[#rows + 1] = info or { slot = slot, error = err, savedAt = 0 }
        end
    end

    table.sort(rows, function(a, c)
        local aBroken, cBroken = a.error ~= nil, c.error ~= nil
        if aBroken ~= cBroken then return cBroken end
        if a.savedAt ~= c.savedAt then return a.savedAt > c.savedAt end
        return a.slot < c.slot
    end)

    return rows
end

---------------------------------------------------------------------------
-- Pure helpers, for callers that own their own I/O
---------------------------------------------------------------------------

Save.encode   = Format.encode
Save.decode   = Format.decode
Save.capture  = State.capture
Save.restore  = State.restore
Save.migration = Format.migration

return Save
