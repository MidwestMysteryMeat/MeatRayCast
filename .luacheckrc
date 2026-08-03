-- Luacheck configuration for MeatRayCast.
--
-- The point of linting HERE is not style — it is catching the one class of bug
-- that bit this engine repeatedly: a `local function` that references a name
-- defined later in the file resolves to a nil GLOBAL instead, and nothing fails
-- until that path runs. Luacheck flags exactly that as "accessing undefined
-- global" and "setting non-standard global", so those warnings stay ON while the
-- purely cosmetic ones are quieted.

std = "max"          -- both Lua 5.4 and LuaJIT built-ins; the suite runs both

-- love is injected by the framework, and a LÖVE app SETS its callback fields
-- (love.load, love.update, love.draw, love.keypressed, ...). Declaring it a
-- writable global rather than read-only is what stops every `function love.x()`
-- from being flagged as "setting a read-only field", without silencing the
-- undefined-GLOBAL check that found the real bug this config exists for.
globals = {
    "love",
    -- The demo (main.lua) publishes one debug handle the selftest reaches for.
    "MEATRAY_DEMO",
}

-- Cosmetic warnings, off. They bury the signal that matters.
ignore = {
    "211",   -- unused local variable / function (often kept for clarity)
    "212",   -- unused argument (self, dt, ctx are frequently unused by design)
    "213",   -- unused loop variable
    "231",   -- local never accessed (a value read only in one branch)
    "311",   -- value assigned to a local is never used
    "421",   -- shadowing a local — verified benign here (the outer is consumed
             -- before the shadow); the value class that matters is 111/113.
    "431",   -- shadowing an upvalue — the closure-based object factories in
             -- net/discovery declare `function self:m()` inside a factory whose
             -- own `self` they intentionally shadow; also reused math locals.
    "512",   -- "loop executed at most once" — the `for _ in pairs(t) do ...
             -- break end` empty-check and `for _,v in pairs(t) do return v end`
             -- first-value idioms, both intentional.
    "542",   -- empty if branch (documented no-op cases)
    "581",   -- 'not (x ~= y)' — a deliberate boolean-equality spelling in world.lua
    "611",   -- line contains trailing whitespace
    "612",   -- line contains trailing whitespace in a comment
    "614",   -- trailing whitespace in a string
    "621",   -- inconsistent indentation
    "631",   -- line is too long
}

max_line_length = false

-- The test files use a `t` harness and are written loosely on purpose: a long
-- test function re-declares `local world`/`local ok` per describe block, stubs
-- math.random and os.time to pin determinism, and uses a `_` throwaway. Those
-- are test idioms, not defects — relaxed here so the SHIPPING code stays strict.
files["tests/"] = {
    ignore = {
        "111",   -- `_ = ...` throwaway written as a global
        "121", "122",   -- stubbing math.random / os.time for determinism
        "411", "412", "413",   -- re-declaring a local in a long test function
    },
}
files["scripts/"] = {
    ignore = { "111", "121", "122", "411" },   -- dev tooling, same latitude
}

-- Generated / vendored / build output is not ours to lint.
exclude_files = {
    "build/",
    "**/love.exe",
}
