--[[
    app.args — the demo's command line, and the print tee.

    Second cut of un-god-filing main.lua. Everything about "what did the
    user type after `love .`" lives here: the defaults table, the flag
    parser, and the `--log` tee. main.lua keeps one table and two calls.

    The parser's one rule (learned the hard way): a flag's value is the
    next argv entry ONLY if it is not itself a flag — an optional-value
    flag that swallows the next option turns a parsing bug into a
    convincing "missing file" report.
]]

local Args = {}

function Args.new()
    return {
        selftest = false, nettest = false, browse = false, netcheck = false,
        netfrag = false, netproxy = false, punchcheck = false, fillers = nil,
        map = nil, mode = nil, connect = nil, port = nil,
        name = nil, password = nil, role = 'a', discovery = 'lan', log = nil,
        registries = nil,
    }
end

function Args.parse(args, argv)
    argv = argv or {}

    -- The argument after a flag, unless it is itself a flag.
    local function value(i, fallback)
        local nextArg = argv[i + 1]
        if nextArg == nil or nextArg:sub(1, 2) == '--' then return fallback end
        return nextArg
    end

    for i, a in ipairs(argv) do
        if a == '--selftest' then args.selftest = true
        elseif a == '--nettest' then args.nettest = true
        elseif a == '--browse' then args.browse = true
        elseif a == '--bench' then args.bench = true
        elseif a == '--bench-map' then args.benchMap = value(i, 'arena')
        elseif a == '--bench-frames' then args.benchFrames = value(i)
        elseif a == '--bench-label' then args.benchLabel = value(i)
        elseif a == '--bench-repeat' then args.benchRepeat = value(i)
        elseif a == '--bench-shot' then args.benchShot = value(i, 'bench')
        elseif a == '--bench-ceiling' then args.benchCeiling = true
        elseif a == '--bench-flat' then args.benchFlat = true
        elseif a == '--bench-lights' then args.benchLights = value(i, '4')
        elseif a == '--bench-flat-light' then args.benchFlatLight = true
        elseif a == '--bench-segments' then args.benchSegments = value(i, '8')
        elseif a == '--bench-ab' then args.benchAb = true
        elseif a == '--editor' then args.editor = value(i, true)
        elseif a == '--editor-shot' then args.editorShot = value(i, 'editor')
        elseif a == '--editor-tab' then args.editorTab = value(i)
        elseif a == '--browse-seconds' then args.browseSeconds = value(i)
        elseif a == '--browse-wait-all' then args.browseWaitAll = true
        -- D32: server-browser filters (mode/map/name/ping/lock/full) + sort.
        elseif a == '--filter-mode' then args.filterMode = value(i)
        elseif a == '--filter-map' then args.filterMap = value(i)
        elseif a == '--filter-name' then args.filterName = value(i)
        elseif a == '--max-ping' then args.maxPing = value(i)
        elseif a == '--hide-locked' then args.hideLocked = true
        elseif a == '--hide-full' then args.hideFull = true
        elseif a == '--sort' then args.sort = value(i)
        elseif a == '--netcheck' then args.netcheck = true
        elseif a == '--netfrag' then args.netfrag = true
        elseif a == '--netproxy' then args.netproxy = true
        elseif a == '--punchcheck' then args.punchcheck = true
        -- Repeatable, because one hard-coded registry URL is a single point of
        -- failure that reveals itself on the day it goes down. Naming one also
        -- turns master discovery on for a host and hole punching on for a join:
        -- there is no second flag to forget.
        elseif a == '--registry' then
            local url = value(i)
            if url then
                args.registries = args.registries or {}
                args.registries[#args.registries + 1] = url
            end
        -- Shared by the two halves of the snapshot measurement: the host spawns
        -- this many filler entities, and the probe expects to find them.
        elseif a == '--fillers' then args.fillers = tonumber(value(i))
        elseif a == '--seconds' then args.seconds = tonumber(value(i))
        elseif a == '--warmup' then args.warmup = tonumber(value(i))
        elseif a == '--label' then args.label = value(i)
        elseif a == '--forward' then args.forward = value(i)
        elseif a == '--bind' then args.bind = value(i)
        elseif a == '--loss' then args.loss = tonumber(value(i))
        elseif a == '--drop' then args.drop = value(i, 'down')
        elseif a == '--grace' then args.grace = tonumber(value(i))
        elseif a == '--seed' then args.seed = tonumber(value(i))
        elseif a == '--expect' then args.expect = value(i, 'under')
        elseif a == '--server' then args.mode = 'dedicated'
        elseif a == '--host' then args.mode = 'listen'
        elseif a == '--map' then args.map = value(i, 'arena')
        -- H1: run (or edit, with --editor) a game project folder.
        elseif a == '--project' then args.project = value(i)
        elseif a == '--meatgraph' then args.meatgraph = value(i, 'meatgraphs/demo.graph.json')
        -- Older flag names kept as synonyms so scripts do not break overnight.
        elseif a == '--graph' then args.meatgraph = value(i, 'meatgraphs/demo.graph.json')
        elseif a == '--blueprint' then args.meatgraph = value(i, 'meatgraphs/demo.graph.json')
        elseif a == '--connect' then args.connect = value(i)
        elseif a == '--port' then args.port = tonumber(value(i))
        elseif a == '--name' then args.name = value(i)
        elseif a == '--password' then args.password = value(i)
        elseif a == '--role' then args.role = value(i, 'a')
        elseif a == '--log' then args.log = value(i)
        elseif a == '--no-lan' then args.discovery = nil
        end
    end
    return args
end

-- `--log PATH` tees everything print() would say into a real file.
--
-- Two reasons, and the second is the one that made it necessary. A dedicated
-- server wants a log it can be asked about later. And on Windows, `lovec.exe`
-- reopens stdout onto the console, so a parent process redirecting stdout to a
-- file captures nothing at all — which makes an automated acceptance runner
-- impossible to write against stdout. An explicit file sidesteps the platform
-- entirely and works the same everywhere.
function Args.teeOutput(path)
    local file = io.open(path, 'w')
    if not file then
        print('could not open log file: ' .. tostring(path))
        return
    end

    local realPrint = print
    _G.print = function(...)
        realPrint(...)
        local parts = {}
        for i = 1, select('#', ...) do parts[i] = tostring((select(i, ...))) end
        file:write(table.concat(parts, '\t'), '\n')
        file:flush()          -- a log that is lost when the process is killed is not a log
    end
end

return Args
