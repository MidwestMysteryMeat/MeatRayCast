--[[
    meatray.save.storage — where save bytes actually go.

    Three backends behind one interface, because the save system has to work in
    three places that do not agree about what a filesystem is:

      love    LÖVE's sandboxed filesystem. Everything written goes under the save
              directory chosen by `t.identity` in conf.lua, which is the only
              place a shipped game may write at all.

      io      Plain Lua's `io` and `os`. This is what a dedicated server uses:
              `love . --server` still has love.filesystem, but the engine's
              simulation and net layers are runnable under bare LuaJIT, and a
              headless host that can simulate a world but cannot persist it is
              only half a server.

      memory  A table. It exists so the failure paths can be tested — a write
              that stops halfway through is a thing that happens on real disks
              and never happens on demand, so it has to be injectable. The
              interrupted-save tests drive this backend.

    What the interface deliberately does NOT assume is rename.

    LÖVE's filesystem is PhysFS underneath, and PhysFS has no rename or move: the
    write API is `love.filesystem.write`, `append`, `remove`, `read`, `getInfo`,
    `createDirectory`, `getDirectoryItems`, plus `love.filesystem.newFile` for
    handle-level `open`/`write`/`flush`/`close`. There is no atomic swap
    primitive available to a LÖVE game, and there is no point pretending
    otherwise. So `rename` is optional here: a backend that has one declares it
    (the io backend does, via `os.rename`), and meatray.save.slots uses it when
    it is there and falls back to a write-verify-recover sequence when it is not.
    What the fallback guarantees is written up at that call site, because the
    guarantee is the interesting part, not the primitive.

    Every function returns a value or nil plus a message. None of them raise:
    a missing directory, a full disk and a read-only file are all normal, and a
    save system that throws on them is a save system that crashes the game at the
    exact moment the player wanted their progress kept.

    HEADLESS: no LOVE required to load this file. The love backend is only ever
    reached when love.filesystem exists.
]]

local Storage = {}

local sub = string.sub

---------------------------------------------------------------------------
-- LÖVE
---------------------------------------------------------------------------

local loveBackend = {
    name = 'love',
    -- No rename: PhysFS does not offer one. See the note above.
    rename = nil,
}

function loveBackend.mkdir(dir)
    if dir == '' then return true end
    if love.filesystem.createDirectory(dir) then return true end
    return nil, ('could not create the directory %q in the save folder'):format(dir)
end

function loveBackend.info(path)
    local i = love.filesystem.getInfo(path)
    if not i then return nil end
    return { size = i.size or 0, modified = i.modtime, type = i.type }
end

function loveBackend.read(path, size)
    local data, err
    if size then
        data, err = love.filesystem.read(path, size)
    else
        data, err = love.filesystem.read(path)
    end
    if data == nil then return nil, tostring(err or ('could not read ' .. path)) end
    return data
end

function loveBackend.write(path, bytes)
    local ok, err = love.filesystem.write(path, bytes)
    if not ok then return nil, tostring(err or ('could not write ' .. path)) end
    return true
end

function loveBackend.remove(path)
    if love.filesystem.getInfo(path) == nil then return true end
    if love.filesystem.remove(path) then return true end
    return nil, ('could not remove %s'):format(path)
end

function loveBackend.list(dir)
    if love.filesystem.getInfo(dir) == nil then return {} end
    return love.filesystem.getDirectoryItems(dir)
end

function loveBackend.describe(dir)
    return (love.filesystem.getSaveDirectory and love.filesystem.getSaveDirectory()
            or '<save directory>') .. '/' .. dir
end

---------------------------------------------------------------------------
-- Plain io
---------------------------------------------------------------------------

local ioBackend = { name = 'io' }

local isWindows = package.config:sub(1, 1) == '\\'

function ioBackend.mkdir(dir)
    if dir == '' then return true end

    -- Probe first: os.execute spawns a shell, and doing that on every save when
    -- the directory already exists is a visible stall on some machines.
    local probe = io.open(dir .. '/.meatray-probe', 'wb')
    if probe then
        probe:close()
        os.remove(dir .. '/.meatray-probe')
        return true
    end

    local command = isWindows
        and ('mkdir "' .. dir:gsub('/', '\\') .. '" 2>nul')
        or ('mkdir -p "' .. dir .. '" 2>/dev/null')

    pcall(os.execute, command)

    local retry = io.open(dir .. '/.meatray-probe', 'wb')
    if retry then
        retry:close()
        os.remove(dir .. '/.meatray-probe')
        return true
    end

    return nil, ('could not create or write to the directory %q'):format(dir)
end

function ioBackend.info(path)
    local f = io.open(path, 'rb')
    if not f then return nil end
    local size = f:seek('end')
    f:close()
    return { size = size or 0, type = 'file' }
end

function ioBackend.read(path, size)
    local f, err = io.open(path, 'rb')
    if not f then return nil, tostring(err or ('could not open ' .. path)) end
    local data = f:read(size or '*a')
    f:close()
    if data == nil then return '' end     -- an empty file reads as nil, not ''
    return data
end

function ioBackend.write(path, bytes)
    local f, err = io.open(path, 'wb')
    if not f then return nil, tostring(err or ('could not open ' .. path .. ' for writing')) end

    local ok, writeErr = f:write(bytes)
    if ok then
        -- flush before close so a close that fails is reported here rather than
        -- silently leaving a short file behind.
        ok, writeErr = f:flush()
    end
    f:close()

    if not ok then return nil, tostring(writeErr or ('could not write ' .. path)) end
    return true
end

function ioBackend.remove(path)
    if not ioBackend.info(path) then return true end
    local ok, err = os.remove(path)
    if not ok then return nil, tostring(err or ('could not remove ' .. path)) end
    return true
end

-- Genuinely atomic on POSIX. On Windows `rename` fails when the destination
-- exists, so the destination is removed first — which reopens the window this
-- call is meant to close. That is why the caller still writes and verifies a
-- temporary file first, and why recovery from that temporary file is part of
-- reading rather than an afterthought: on Windows the atomic swap is a best
-- effort, and a save system that only survives on the platform with the better
-- primitive is not a save system.
function ioBackend.rename(from, to)
    local ok, err = os.rename(from, to)
    if ok then return true end

    if ioBackend.info(to) then
        os.remove(to)
        ok, err = os.rename(from, to)
        if ok then return true end
    end

    return nil, tostring(err or ('could not rename ' .. from .. ' to ' .. to))
end

--[[
    Plain Lua cannot list a directory: there is no opendir in the standard
    library and LuaJIT bundles no lfs. The options are a shell or nothing, and
    nothing means a dedicated server cannot enumerate its own saves.

    So: a shell, guarded on every axis. io.popen may be absent or disabled, the
    command may fail, and the output may be an error message rather than a
    listing — all three end as an empty list plus a reason, never as a raise.
    Under LÖVE this code is never reached, and LÖVE is where the game runs.
]]
function ioBackend.list(dir)
    if not io.popen then
        return {}, 'this Lua build has no io.popen, so saves cannot be listed '
                   .. 'without love.filesystem'
    end

    local command = isWindows
        and ('dir /b "' .. dir:gsub('/', '\\') .. '" 2>nul')
        or ('ls -1 "' .. dir .. '" 2>/dev/null')

    local ok, pipe = pcall(io.popen, command)
    if not ok or not pipe then
        return {}, 'could not list ' .. dir
    end

    local out = {}
    for line in pipe:lines() do
        line = line:gsub('[\r\n]+$', '')
        if line ~= '' then out[#out + 1] = line end
    end
    pipe:close()

    return out
end

function ioBackend.describe(dir)
    return dir
end

---------------------------------------------------------------------------
-- Memory
---------------------------------------------------------------------------

--[[
    A filesystem in a table, with the failures a real one has.

    `Storage.memory()` returns a fresh backend. Three injection points, and each
    exists for a test that cannot be written any other way:

      backend.readOnly[path]   a write to this path fails outright, as a
                               read-only file or a permissions error would.
      backend.shortWrite[path] the write reports success and stores only the
                               first N bytes: a disk that filled up, or a write
                               that was only partly flushed. The caller believes
                               it worked, which is what makes it dangerous.
      backend.killWrite[path]  the write stores the first N bytes and then
                               raises, standing in for the process being killed
                               mid-write. Nothing after that call runs — no
                               verification, no cleanup, no return value — which
                               is the difference between this and shortWrite,
                               and the only faithful way to test what a crash
                               leaves behind.
      backend.corrupt[path]    the next read of this path returns the stored
                               bytes with one flipped, standing in for the bit
                               rot that a checksum is supposed to catch.
]]
function Storage.memory()
    local files = {}

    local backend = {
        name = 'memory',
        files = files,
        readOnly = {},
        shortWrite = {},
        killWrite = {},
        corrupt = {},
        writes = 0,
    }

    function backend.mkdir()
        return true
    end

    function backend.info(path)
        local data = files[path]
        if data == nil then return nil end
        return { size = #data, type = 'file' }
    end

    function backend.read(path, size)
        local data = files[path]
        if data == nil then return nil, ('no such file: %s'):format(path) end

        local flip = backend.corrupt[path]
        if flip then
            backend.corrupt[path] = nil
            local at = math.min(flip, #data)
            if at >= 1 then
                local c = string.byte(data, at)
                data = sub(data, 1, at - 1)
                        .. string.char((c + 1) % 256)
                        .. sub(data, at + 1)
            end
        end

        if size then return sub(data, 1, size) end
        return data
    end

    function backend.write(path, bytes)
        if backend.readOnly[path] then
            return nil, ('%s is read-only'):format(path)
        end

        backend.writes = backend.writes + 1

        local killAt = backend.killWrite[path]
        if killAt then
            backend.killWrite[path] = nil
            files[path] = sub(bytes, 1, killAt)
            error(('the process died while writing %s'):format(path), 0)
        end

        local cut = backend.shortWrite[path]
        if cut then
            backend.shortWrite[path] = nil
            files[path] = sub(bytes, 1, cut)
            -- A killed process does not get to report an error, which is exactly
            -- what makes this case dangerous: the caller believes it succeeded.
            return true
        end

        files[path] = bytes
        return true
    end

    function backend.remove(path)
        files[path] = nil
        return true
    end

    function backend.list(dir)
        local prefix = dir .. '/'
        local out = {}
        for path in pairs(files) do
            if sub(path, 1, #prefix) == prefix then
                local rest = sub(path, #prefix + 1)
                if not rest:find('/', 1, true) then out[#out + 1] = rest end
            end
        end
        table.sort(out)
        return out
    end

    function backend.describe(dir)
        return '<memory>/' .. dir
    end

    return backend
end

---------------------------------------------------------------------------
-- Selection
---------------------------------------------------------------------------

Storage.love = loveBackend
Storage.io   = ioBackend

-- LÖVE when there is a LÖVE, plain io otherwise. Chosen on demand rather than at
-- load time, so requiring this module under bare LuaJIT is safe and so a test
-- can substitute a backend without the module having already committed to one.
function Storage.detect()
    if love and love.filesystem then return loveBackend end
    return ioBackend
end

return Storage
