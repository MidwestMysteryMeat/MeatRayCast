--[[
    Save slots: the file operations, and the ones that go wrong halfway.

    Most of this runs against the in-memory backend, which exists precisely so
    the interesting failures are reachable. A write that stores only the first
    two hundred bytes of a save is what a full disk and a killed process both
    look like from inside the program, and it is not something a test can arrange
    on a real filesystem — so the backend can be told to do it on demand, and the
    recovery path is asserted rather than reasoned about.

    The last section is deliberately not simulated: it writes real files to a
    real temporary directory through the io backend, the one a dedicated server
    uses, and reads a world back out of them. A save system with no test that
    touches a disk is a save system with a plausible story.
]]

return function(t)
    local Save    = require('meatray.save')
    local Storage = require('meatray.save.storage')
    local Format  = require('meatray.save.format')
    local World   = require('meatray.sim.world')
    local Entity  = require('meatray.sim.entity')
    local C       = require('meatray.sim.components')

    local borrowedArchetypes = Entity.captureArchetypes()
    Entity.clearArchetypes()
    Entity.archetype('imp', function(e) e:add(C.Health{ hp = 30, max = 30 }) end)

    -- Big enough that a save is comfortably larger than one probe read, which is
    -- what makes the "listing does not read the body" measurement below mean
    -- anything: on an eight-tile room the probe would happen to cover the whole
    -- file and the test would pass without testing.
    local SIZE = 40

    local function makeWorld()
        local g = {}
        for y = 1, SIZE do
            g[y] = {}
            for x = 1, SIZE do
                g[y][x] = (x == 1 or y == 1 or x == SIZE or y == SIZE) and 1 or 0
            end
        end
        local world = World.new(g, { theme = 'dungeon' })
        world:addDoor(4, 1, false)
        return world
    end

    ---------------------------------------------------------------------------
    t.describe('the save system is headless')

    -- Not a sim module, so it is not on tests/test_headless.lua's lists, but it
    -- follows the same rule and for a concrete reason: a dedicated server that
    -- can simulate a world and not persist it is half a server. This suite is
    -- running under plain LuaJIT, so the fact that every module above loaded at
    -- all is the assertion — this just says so out loud.
    t.eq(rawget(_G, 'love'), nil, 'this suite runs with no love global')
    t.eq(Storage.detect().name, 'io', 'and storage falls back to plain io without one')
    t.ok(Save.backend() ~= nil, 'so a backend is still available')

    ---------------------------------------------------------------------------
    t.describe('slot names')

    t.eq(Save.slotName(1), 'slot1', 'a number becomes a slot name')
    t.eq(Save.slotName(0), 'slot0', 'including zero')
    t.eq(Save.slotName('quicksave'), 'quicksave', 'a name is taken as given')
    t.eq(Save.slotName('auto-2_b'), 'auto-2_b', 'dashes and underscores are allowed')

    -- Not tidiness: under the io backend a slot name reaches the filesystem
    -- directly, and a name arriving from a text field is untrusted input.
    for _, bad in ipairs({ '../evil', 'a/b', 'a\\b', '', '.', 'x y', 'x.sav',
                           'sav;rm -rf', '-leading', ('x'):rep(49) }) do
        local name, err = Save.slotName(bad)
        t.ok(name == nil, ('%q is refused as a slot name'):format(bad))
        t.ok(type(err) == 'string' and #err > 4, ('%q is refused with a reason'):format(bad), err)
    end

    t.ok(Save.slotName(1.5) == nil, 'a fractional slot number is refused')
    t.ok(Save.slotName(-1) == nil, 'a negative slot number is refused')
    t.ok(Save.slotName(nil) == nil, 'a nil slot is refused')
    t.ok(Save.slotName({}) == nil, 'a table slot is refused')

    ---------------------------------------------------------------------------
    -- Everything below drives a backend of the test's own.
    ---------------------------------------------------------------------------

    local mem = Storage.memory()

    -- Instrumented so the "listing does not read the body" claim is measured
    -- rather than asserted about the code that is supposed to implement it.
    local reads, bytesRead = 0, 0
    local rawRead = mem.read
    mem.read = function(path, size)
        local data, err = rawRead(path, size)
        if data then
            reads = reads + 1
            bytesRead = bytesRead + #data
        end
        return data, err
    end

    Save.setBackend(mem)
    Save.setDirectory('saves')

    local world = makeWorld()
    world:setDoorOpen(4, 1, true)
    local imp = Entity.spawn('imp', 3.5, 4.5)
    imp:get('health').hp = 11

    local function capture(label, playTime)
        return {
            world = world, entities = { imp },
            progress = { level = 2 }, map = 'arena',
            label = label, playTime = playTime or 60, savedAt = 1700000000,
        }
    end

    t.describe('a save round-trips through a slot')

    local ok, size = Save.save(1, capture('first'))
    t.ok(ok, 'writing slot 1 succeeds', size)
    t.ok(type(size) == 'number' and size > 0, ('and reports its size (%s bytes)')
                                              :format(tostring(size)))
    t.ok(Save.exists(1), 'the slot now exists')
    t.eq(mem.files['saves/slot1.sav'] ~= nil, true, 'the file is where the path says')
    t.eq(mem.files['saves/slot1.sav.tmp'], nil,
         'and the temporary file was cleaned up after a successful write')

    local state, loadErr = Save.load(1)
    t.ok(state ~= nil, 'the slot loads', loadErr)
    t.eq(state.world:doorAt(4, 1).open, true, 'with the door as it was left')
    t.eq(#state.entities, 1, 'with its entity')
    t.eq(state.byId[imp.id]:get('health').hp, 11, 'and its component state')
    t.eq(state.progress.level, 2, 'and its progress')
    t.eq(state.recovered, nil, 'and nothing needed recovering')

    ---------------------------------------------------------------------------
    t.describe('metadata is readable without loading the save')

    Save.save('quicksave', capture('quick', 125.5))
    Save.save('auto', capture('auto', 900))

    local fileBytes = #mem.files['saves/slot1.sav']

    reads, bytesRead = 0, 0
    local rows = Save.list()
    local listBytes = bytesRead

    t.eq(#rows, 3, 'three slots are listed')
    t.ok(listBytes < fileBytes * #rows,
         ('listing read %d bytes for %d saves of %d bytes each')
         :format(listBytes, #rows, fileBytes))
    t.ok(listBytes <= Format.PROBE_BYTES * #rows,
         'and no more than one probe read per slot')

    local byName = {}
    for _, row in ipairs(rows) do byName[row.slot] = row end

    t.ok(byName.slot1 ~= nil, 'slot1 is in the list')
    t.eq(byName.slot1.map, 'arena', 'with its map name')
    t.eq(byName.slot1.savedAt, 1700000000, 'its timestamp')
    t.eq(byName.slot1.playTime, 60, 'its play time')
    t.eq(byName.slot1.label, 'first', 'its label')
    t.eq(byName.slot1.version, Format.VERSION, 'its version')
    t.eq(byName.slot1.entities, 1, 'how many entities it holds')
    t.eq(byName.slot1.bytes, fileBytes, 'and how large the file is')
    t.eq(byName.quicksave.playTime, 125.5, 'quicksave reports its own play time')

    t.describe('and a single slot can be inspected on its own')
    local info = Save.info('quicksave')
    t.ok(info ~= nil, 'info reads one slot')
    t.eq(info.label, 'quick', 'with its label')
    t.eq(info.theme, 'dungeon', 'and the theme, for a browser thumbnail')
    t.ok(Save.info('nothing-here') == nil, 'a slot with no file has no info')
    t.ok(Save.info('../evil') == nil, 'and a bad slot name has none either')

    t.describe('metadata larger than one probe read still works')
    -- The probe is an optimisation, not a limit. A save with a long label costs
    -- a second read and must not cost a wrong answer.
    Save.write('wordy', {
        version = Format.VERSION,
        meta = { map = 'arena', savedAt = 5, note = ('n'):rep(Format.PROBE_BYTES * 2) },
        body = { world = { kind = 'grid', grid = { { 1 } } }, entities = {} },
    })
    local wordy = Save.info('wordy')
    t.ok(wordy ~= nil, 'a save with oversized metadata still lists')
    t.eq(#wordy.meta.note, Format.PROBE_BYTES * 2, 'and its metadata is complete')
    Save.delete('wordy')

    ---------------------------------------------------------------------------
    t.describe('an interrupted write cannot destroy the previous save')

    -- Case one: the process dies while the temporary file is being written. The
    -- real save has not been touched at all.
    local before = mem.files['saves/slot1.sav']
    mem.shortWrite['saves/slot1.sav.tmp'] = 40

    local failed, failErr = Save.save(1, capture('second'))
    t.ok(failed == nil, 'a short write to the temporary file fails the save')
    t.ok(type(failErr) == 'string' and failErr:find('bytes'),
         'with a message saying how much arrived', failErr)
    t.eq(mem.files['saves/slot1.sav'], before, 'and the previous save is byte-identical')

    local intact = Save.load(1)
    t.ok(intact ~= nil, 'which still loads')
    t.eq(intact.byId[imp.id]:get('health').hp, 11, 'with the state it had')

    t.describe('an interrupted write leaves something recoverable')

    -- Case two: the temporary file is written and verified, and the process dies
    -- while the real file is being overwritten. The real file is now short; the
    -- temporary file holds a complete save.
    imp:get('health').hp = 3
    mem.shortWrite['saves/slot1.sav'] = 60

    local halfWritten, halfErr = Save.save(1, capture('third'))
    t.ok(halfWritten == nil, 'the save reports failure')
    t.ok(tostring(halfErr):find('intact copy'), 'and says where the intact copy is', halfErr)
    t.ok(mem.files['saves/slot1.sav.tmp'] ~= nil, 'the temporary file is still there')
    t.ok(#mem.files['saves/slot1.sav'] == 60, 'and the real file is short')

    t.ok(Format.decode(mem.files['saves/slot1.sav']) == nil,
         'the short file does not decode, so nothing could load it by accident')

    local recovered, recoverErr = Save.load(1)
    t.ok(recovered ~= nil, 'and the slot still loads, from the temporary file', recoverErr)
    t.eq(recovered.byId[imp.id]:get('health').hp, 3, 'with the state of the interrupted save')
    t.ok(type(recovered.recovered) == 'string', 'and the load says it was recovered')
    t.ok(recovered.recovered:find('interrupted'), 'in words a player could be shown',
         recovered.recovered)

    t.ok(Format.decode(mem.files['saves/slot1.sav']) ~= nil,
         'reading repaired the real file rather than leaving it broken')
    t.eq(mem.files['saves/slot1.sav.tmp'], nil, 'and the temporary file is gone')

    local afterRepair = Save.load(1)
    t.eq(afterRepair.recovered, nil, 'so the next load needs no recovery')

    t.describe('a process killed mid-write is survivable')

    -- The worst case, and the reason verification alone is not the answer: a
    -- process that is killed never gets to check anything, report anything or
    -- clean anything up. The backend raises from inside the write, so nothing
    -- after that line in Save.write runs — which is exactly what a kill does,
    -- and is not something Save.verifyWrites can model.
    imp:get('health').hp = 27
    mem.killWrite['saves/slot1.sav'] = 55

    local survived, killErr = pcall(Save.save, 1, capture('fourth'))
    t.ok(not survived, 'the save does not return at all')
    t.ok(tostring(killErr):find('died while writing'), 'because the process died', killErr)
    t.ok(#mem.files['saves/slot1.sav'] == 55, 'leaving a short file where the save was')
    t.ok(mem.files['saves/slot1.sav.tmp'] ~= nil, 'and no chance to clean up the temporary file')

    local rescued, rescueErr = Save.load(1)
    t.ok(rescued ~= nil, 'the next load finds the complete copy', rescueErr)
    t.eq(rescued.byId[imp.id]:get('health').hp, 27, 'and it is the save that was being written')
    t.ok(type(rescued.recovered) == 'string', 'and says it was recovered')

    t.describe('a temporary file with no save beside it is still a save')
    Save.delete('orphan')
    mem.files['saves/orphan.sav.tmp'] = mem.files['saves/slot1.sav']
    local orphan, orphanErr = Save.read('orphan')
    t.ok(orphan ~= nil, 'an orphaned temporary file loads', orphanErr)
    t.ok(tostring(orphan.recovered):find('interrupted'), 'and is reported as recovered')
    t.ok(mem.files['saves/orphan.sav'] ~= nil, 'and is promoted to a real save')
    Save.delete('orphan')

    ---------------------------------------------------------------------------
    t.describe('corruption is refused, not loaded')

    Save.save('corrupt-me', capture('victim'))
    mem.corrupt['saves/corrupt-me.sav'] = 200

    local corrupted, corruptErr = Save.read('corrupt-me')
    t.ok(corrupted == nil, 'a flipped byte fails the load')
    t.ok(tostring(corruptErr):find('corrupt-me', 1, true), 'and the message names the slot',
         corruptErr)
    t.ok(tostring(corruptErr):find('checksum', 1, true), 'and says what is wrong with it',
         corruptErr)

    mem.corrupt['saves/corrupt-me.sav'] = 200
    local corruptState, corruptStateErr = Save.load('corrupt-me')
    t.ok(corruptState == nil, 'and load refuses it too, with nothing half-applied')
    t.ok(type(corruptStateErr) == 'string', 'with a reason', corruptStateErr)

    t.describe('a save that cannot be read is still listed')
    -- Omitting it would hide a file that is still occupying the slot, leaving a
    -- browser with no way to offer to delete it.
    mem.files['saves/garbage.sav'] = 'this is not a save at all'
    local listed = Save.list()
    local garbage
    for _, row in ipairs(listed) do if row.slot == 'garbage' then garbage = row end end
    t.ok(garbage ~= nil, 'the unreadable slot appears in the listing')
    t.ok(type(garbage.error) == 'string', 'carrying the reason it cannot be read',
         garbage and garbage.error)
    t.eq(listed[#listed].slot, 'garbage', 'and sorts last, behind the saves that work')

    t.describe('files that are not saves are not listed as slots')
    mem.files['saves/notes.txt'] = 'hello'
    mem.files['saves/slot1.sav.tmp'] = 'leftovers'
    local filtered = Save.list()
    for _, row in ipairs(filtered) do
        t.ok(row.slot ~= 'notes.txt' and row.slot ~= 'slot1.sav',
             ('%s is not listed as a slot'):format(row.slot))
    end
    mem.files['saves/slot1.sav.tmp'] = nil
    mem.files['saves/notes.txt'] = nil
    mem.files['saves/garbage.sav'] = nil

    t.describe('deleting a slot')
    t.ok(Save.delete('corrupt-me'), 'a slot deletes')
    t.ok(not Save.exists('corrupt-me'), 'and is gone')
    t.ok(Save.delete('never-existed'), 'deleting a slot that is not there is not an error')
    t.ok(Save.read('never-existed') == nil, 'and reading it says there is nothing there')
    local _, missingErr = Save.read('never-existed')
    t.ok(tostring(missingErr):find('no save'), 'in those words', missingErr)

    t.describe('a read-only slot fails the save rather than the game')
    mem.readOnly['saves/locked.sav.tmp'] = true
    local locked, lockedErr = Save.save('locked', capture('locked'))
    t.ok(locked == nil, 'a slot that cannot be written refuses the save')
    t.ok(tostring(lockedErr):find('read%-only'), 'with the reason from the filesystem',
         lockedErr)
    mem.readOnly['saves/locked.sav.tmp'] = nil

    t.describe('a bad slot name never reaches the filesystem')
    t.ok(Save.write('../escape', { version = 1, meta = {}, body = {} }) == nil,
         'writing to a traversing slot name is refused')
    local escaped = 0
    for path in pairs(mem.files) do
        if not path:find('^saves/') then escaped = escaped + 1 end
    end
    t.eq(escaped, 0, 'and nothing was written outside the save directory')

    ---------------------------------------------------------------------------
    t.describe('a real save, on a real disk, through the io backend')

    --[[
        The dedicated server path: no LÖVE, no love.filesystem, plain io and os.
        This writes actual files to the system temporary directory and reads a
        world back out of them, because every other test in this file runs
        against a filesystem that is a Lua table and would keep passing if the
        real one did not work at all.
    ]]
    local tempRoot = os.getenv('TEMP') or os.getenv('TMP') or os.getenv('TMPDIR') or '/tmp'
    tempRoot = tempRoot:gsub('\\', '/'):gsub('/+$', '')
    local tempDir = ('%s/meatray-save-test-%d-%d')
                    :format(tempRoot, os.time(), math.floor(os.clock() * 1e6) % 100000)

    Save.setBackend(Storage.io)
    Save.setDirectory(tempDir)

    local wrote, writeErr = Save.save('disk1', capture('on disk', 42))
    t.ok(wrote, ('a save writes to %s'):format(tempDir), writeErr)

    -- Read the file with io directly: the bytes must be on the disk, not in a
    -- buffer this process is holding.
    local handle = io.open(tempDir .. '/disk1.sav', 'rb')
    t.ok(handle ~= nil, 'the file is really there')
    if handle then
        local raw = handle:read('*a')
        handle:close()
        t.ok(#raw > 0, ('and holds %d bytes'):format(#raw))
        t.ok(raw:sub(1, #Format.MAGIC) == Format.MAGIC, 'starting with the save magic')
    end

    t.ok(io.open(tempDir .. '/disk1.sav.tmp', 'rb') == nil,
         'and the temporary file was renamed away rather than left behind')

    local diskState, diskErr = Save.load('disk1')
    t.ok(diskState ~= nil, 'it loads back off the disk', diskErr)
    if diskState then
        t.eq(diskState.world.width, SIZE, 'with the world it was given')
        t.eq(diskState.world:doorAt(4, 1).open, true, 'and the door state')
        t.eq(diskState.byId[imp.id]:get('health').hp, 27, 'and the entity state')
        t.eq(diskState.progress.level, 2, 'and the progress')
    end

    local diskInfo = Save.info('disk1')
    t.ok(diskInfo ~= nil, 'its metadata reads off the disk')
    t.eq(diskInfo and diskInfo.playTime, 42, 'without loading the body')

    Save.save('disk2', capture('second on disk', 7))
    local diskRows = Save.list()
    -- Listing needs a directory listing, which plain Lua does not have; the io
    -- backend shells out for it. If that is unavailable the list is empty and
    -- says so, which is a documented degradation rather than a crash.
    if #diskRows > 0 then
        t.eq(#diskRows, 2, 'both saves are listed from a real directory')
        t.eq(diskRows[1].slot, 'disk1', 'newest first, then by name')
    else
        t.ok(true, 'this build cannot list directories without love.filesystem')
    end

    t.ok(Save.delete('disk1'), 'a real file deletes')
    t.ok(io.open(tempDir .. '/disk1.sav', 'rb') == nil, 'and is gone from the disk')
    Save.delete('disk2')

    -- os.remove does not take a directory on every platform, so the empty one is
    -- swept up by the shell. Quietly, and best-effort: a test that fails because
    -- it could not tidy up would be reporting the wrong thing.
    os.remove(tempDir)
    pcall(os.execute, package.config:sub(1, 1) == '\\'
          and ('rmdir "' .. tempDir:gsub('/', '\\') .. '" 2>nul')
          or ('rmdir "' .. tempDir .. '" 2>/dev/null'))

    ---------------------------------------------------------------------------
    -- Put the module back the way it was found: backend and directory are
    -- process-wide, and a later suite has no reason to inherit this one's.
    Save.setBackend(nil)
    Save.setDirectory('saves')
    Entity.restoreArchetypes(borrowedArchetypes)
end
