--[[
    Crash report formatting. The formatter is pure (no love, no file), so the
    exact bytes a player would send are asserted here. install() names love
    and only runs in a packaged game, so it is not on this path.
]]

return function(t)
    local Crash = require('app.crash')

    ---------------------------------------------------------------------
    t.describe('a full report carries what a bug needs')

    local text = Crash.report{
        message = 'attempt to index a nil value',
        traceback = 'stack traceback:\n\tmain.lua:42',
        version = '1.0.0',
        loveVersion = '11.5',
        os = 'Windows',
        log = { 'newest', 'older', 'oldest' },
    }
    t.ok(text:find('crash report'), 'it announces itself')
    t.ok(text:find('1.0.0', 1, true), 'the build version is in it')
    t.ok(text:find('11.5', 1, true), 'the love version')
    t.ok(text:find('Windows', 1, true), 'the OS')
    t.ok(text:find('index a nil', 1, true), 'the error message')
    t.ok(text:find('main.lua:42', 1, true), 'the traceback')
    t.ok(text:find('newest', 1, true), 'the recent log')
    t.ok(text:sub(-1) == '\n', 'and ends with a newline')

    ---------------------------------------------------------------------
    t.describe('the log is capped and ordered newest-first')

    local many = {}
    for i = 1, 40 do many[i] = 'line' .. i end
    local capped = Crash.report{ message = 'x', log = many }
    local shown = 0
    for _ in capped:gmatch('line%d+') do shown = shown + 1 end
    t.eq(shown, Crash.MAX_LOG_LINES, 'no more than MAX_LOG_LINES ride along')
    t.ok(capped:find('line1\n', 1, true), 'starting from the newest')

    ---------------------------------------------------------------------
    t.describe('missing fields degrade to a still-useful report')

    local bare = Crash.report{}
    t.ok(bare:find('unknown', 1, true), 'unknown stands in for absent build info')
    t.ok(bare:find('no message', 1, true), 'and a missing message is named, not blank')
    t.ok(bare:find('crash report'), 'it is still a report')
end
