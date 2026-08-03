-- Map linter CLI (B12).
--
--   luajit scripts/maplint.lua maps/arena.map maps/secrets.map
--   luajit scripts/maplint.lua maps/*.map          (shell-expanded)
--
-- Exit 0 when every map is free of errors; warnings print but do not fail.
-- Run from the repo root, the same working directory the suite uses.

package.path = './?.lua;./?/init.lua;' .. package.path

local Maplint = require('meatray.sim.maplint')

local paths = { ... }
if #paths == 0 then
    print('usage: luajit scripts/maplint.lua <map files...>')
    os.exit(2)
end

local failed = 0
for _, path in ipairs(paths) do
    local f = io.open(path, 'rb')
    if not f then
        print(('%-24s CANNOT OPEN'):format(path))
        failed = failed + 1
    else
        local text = f:read('*a')
        f:close()
        local report = Maplint.checkText(text)
        local tag = report.ok and 'ok' or 'FAIL'
        print(('%-24s %-4s  %d error(s), %d warning(s)')
              :format(path, tag, #report.errors, #report.warnings))
        for _, e in ipairs(report.errors) do
            print(('  ERROR   [%s] %s'):format(e.code, e.text))
        end
        for _, w in ipairs(report.warnings) do
            print(('  warning [%s] %s'):format(w.code, w.text))
        end
        if not report.ok then failed = failed + 1 end
    end
end

os.exit(failed == 0 and 0 or 1)
