--[[
    app.crash — write a crash report instead of vanishing.

    A shipped game that dies shows LÖVE's blue error screen and leaves the
    player with nothing to send you. This captures the error, the traceback,
    the build version and the last lines of the in-game log into a file in
    the save directory, then hands control back to LÖVE's own error screen so
    the behaviour a player sees is unchanged — there is just now an artifact
    to attach to a bug report.

    No telemetry, no network: writing a file is the whole feature. Uploading a
    crash is a product/consent decision (and a server), deliberately not made
    here — a game that phones home the moment it breaks is a worse default
    than one that leaves a file for the player to choose to send.

    The formatter is pure and headless-tested; install() is the only part
    that names love, and only a packaged game ever calls it.
]]

local Crash = {}

Crash.MAX_LOG_LINES = 12

-- info: { message, traceback, version, loveVersion, os, log = { newest first } }
-- Returns the report text. Pure — the test asserts on this, not on a file.
function Crash.report(info)
    info = info or {}
    local lines = {
        '=== MeatRayCast crash report ===',
        'version:  ' .. tostring(info.version or 'unknown'),
        'love:     ' .. tostring(info.loveVersion or 'unknown'),
        'os:       ' .. tostring(info.os or 'unknown'),
        '',
        'error:    ' .. tostring(info.message or '(no message)'),
        '',
        'traceback:',
        tostring(info.traceback or '(none)'),
    }

    if info.log and #info.log > 0 then
        lines[#lines + 1] = ''
        lines[#lines + 1] = 'recent log (newest first):'
        for i = 1, math.min(Crash.MAX_LOG_LINES, #info.log) do
            lines[#lines + 1] = '  ' .. tostring(info.log[i])
        end
    end

    lines[#lines + 1] = ''
    lines[#lines + 1] = 'Please attach this file to a bug report.'
    return table.concat(lines, '\n') .. '\n'
end

-- Installs a love.errorhandler that writes the report, then defers to the
-- handler that was already there (LÖVE's blue screen) so the player-facing
-- behaviour is unchanged. `getLog` is optional and returns the game's recent
-- log lines (newest first).
function Crash.install(opts)
    opts = opts or {}
    if not (rawget(_G, 'love')) then return end

    local previous = love.errorhandler or love.errhand
    local path = opts.path or 'crash.txt'

    local function handler(msg)
        local ok, written = pcall(function()
            local info = {
                message = msg,
                traceback = debug.traceback('', 2),
                version = opts.version,
                loveVersion = love.getVersion and
                    table.concat({ love.getVersion() }, '.') or nil,
                os = love.system and love.system.getOS and love.system.getOS() or nil,
                log = opts.getLog and opts.getLog() or nil,
            }
            local text = Crash.report(info)
            if love.filesystem and love.filesystem.write then
                love.filesystem.write(path, text)
            end
            -- Also to stdout, so a headless/dedicated crash is on the console
            -- and in any --log file, not only in the save dir.
            io.write(text)
            return true
        end)
        -- A crash handler that crashes is the worst outcome: swallow anything
        -- the write raised and always fall through to the original screen.
        if not ok then pcall(io.write, 'crash-report write failed: ' .. tostring(written) .. '\n') end
        if previous then return previous(msg) end
    end

    love.errorhandler = handler
    love.errhand = handler          -- 0.10-era name, harmless to set
end

return Crash
