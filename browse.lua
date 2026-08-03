--[[
    `love . --browse` — a LAN server browser with no GUI.

    The server browser UI belongs to roadmap phase 3, which needs the GUI toolkit.
    Discovery itself does not, so it ships now and prints. That is worth having on
    its own: it is how you check whether a host is actually beaconing before
    blaming the join, and it is what the two-process test asserts against.

    Runs headless (conf.lua turns window and graphics off for --browse), so it
    works over SSH on a machine with no display.
]]

local MeatRay = require('meatray')

local function pad(text, width)
    text = tostring(text or '')
    if #text >= width then return text:sub(1, width) end
    return text .. (' '):rep(width - #text)
end

return function(args)
    local Net = MeatRay.net

    local browser = Net.browse{
        discovery = 'lan',
        version = Net.VERSION,
        onWarning = function(text) print('[net] ! ' .. tostring(text)) end,
    }

    -- A generous ceiling, because the loop below stops the moment it finds
    -- something. The old default was a flat 3 seconds with no early exit, which
    -- against a 1s announce interval is about two chances to hear a beacon — and it
    -- spent those two chances at the exact moment three LOVE processes had just
    -- started and the host was still generating its map. Losing one datagram there
    -- reported "no servers found", which reads as broken discovery rather than as
    -- an impatient test.
    local seconds = tonumber(args and args.browseSeconds) or 15
    local waitAll = args and args.browseWaitAll

    print(('[net] searching the LAN for up to %g seconds...'):format(seconds))

    -- A blocking loop is right here and nowhere else: there is no window to keep
    -- responsive and nothing to draw, and the process exists only to answer one
    -- question.
    local step = 0.05
    local elapsed = 0
    local found = 0
    while elapsed < seconds do
        browser:update(step)
        love.timer.sleep(step)
        elapsed = elapsed + step

        found = #browser:servers()
        if found > 0 and not waitAll then
            -- One server answers the question this process exists to answer. Use
            -- --browse-wait-all to enumerate everything on a busy LAN instead.
            print(('[net] found a server after %.1fs'):format(elapsed))
            break
        end
    end

    local servers = browser:servers()

    -- D32: apply the filter row from CLI flags before printing, so `--browse`
    -- and the in-shell browser filter by the same model.
    local filter = {
        mode = args and args.filterMode,
        map = args and args.filterMap,
        search = args and args.filterName,
        maxPing = args and tonumber(args.maxPing),
        hideLocked = args and args.hideLocked or false,
        hideFull = args and args.hideFull or false,
        sort = (args and args.sort) or 'ping',
    }
    local hasFilter = filter.mode or filter.map or filter.search or filter.maxPing
                      or filter.hideLocked or filter.hideFull
    local total = #servers
    servers = MeatRay.net.browser.filter(servers, filter)
    if hasFilter then
        print(('[net] %d of %d server(s) match the filter'):format(#servers, total))
    end

    print(('[net] %d server(s) found'):format(#servers))
    if #servers > 0 then
        print(('  %s %s %s %s %s %s'):format(
            pad('ADDRESS', 24), pad('NAME', 24), pad('MAP', 12),
            pad('PLAYERS', 8), pad('PING', 6), 'FLAGS'))
        for _, s in ipairs(servers) do
            print(('  %s %s %s %s %s %s'):format(
                pad(s.address, 24), pad(s.name, 24), pad(s.map, 12),
                pad(('%d/%d'):format(s.players or 0, s.max or 0), 8),
                pad(s.ping and (s.ping .. 'ms') or '?', 6),
                (s.locked and '[locked] ' or '') .. '[' .. tostring(s.mode) .. ']'))
        end
    else
        print('  nothing is beaconing on this network.')
        print('  a host must be started with discovery = \'lan\' (the demo default),')
        print('  and UDP ' .. tostring(require('meatray.net.discovery.lan').PORT)
              .. ' must not be blocked. Direct connection by address still works.')
    end

    browser:close()

    -- Exit 0 when something was found, 3 when nothing was. A browser that always
    -- exits 0 cannot be asserted on.
    love.event.quit(#servers > 0 and 0 or 3)
end
