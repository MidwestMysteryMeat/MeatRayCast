--[[
    meatray.game.i18n — one string table, and a lookup that never blanks (B15).

    Player-facing text scattered as string literals is text that cannot be
    translated and, worse, cannot be FOUND: a menu label, a mode name and a
    HUD prompt written three different places are three separate edits and
    two of them will be missed. This gathers them behind keys.

        local I18N = require('meatray.game.i18n')
        local L = I18N.new()

        L:define('en', {
            ['menu.new']   = 'New Game',
            ['hud.reload'] = 'reloading %d%%',
            ['mode.dm']    = 'Deathmatch',
        })
        L:define('fr', { ['menu.new'] = 'Nouvelle Partie' })

        L:use('fr')
        L:t('menu.new')                 -- 'Nouvelle Partie'
        L:t('hud.reload', 42)           -- 'reloading 42%'  (falls back to en)
        L:t('nothing.here')             -- 'nothing.here'   (the KEY, never blank)

    The rule that matters is the last one: a missing key returns the key, not
    an empty string. A blank label is a bug you ship and a player reports; a
    key on screen is a bug you see the instant you run it, and it still tells
    the player which button they are looking at. The fallback locale (default
    'en') fills gaps in a partial translation the same way — a half-translated
    French build shows English for the rest, never holes.

    Parameters go through string.format, but a format that throws on the given
    arguments (a %d handed a string) is caught and the raw template returned,
    because a console mod that mistypes a HUD string must not crash the frame
    drawing it.

    Storage is line-oriented `key=value`, so a translator edits a text file,
    and load/save use the same backend meatray.game.options does.

    HEADLESS: pure Lua.
]]

local I18N = {}
local I18NMT = {}
I18NMT.__index = I18NMT

---------------------------------------------------------------------------
-- Construction
---------------------------------------------------------------------------

-- opts.fallback: the locale gaps fall back to (default 'en').
--        current: the starting locale (default = fallback).
function I18N.new(opts)
    opts = opts or {}
    local fallback = tostring(opts.fallback or 'en')
    return setmetatable({
        fallback = fallback,
        current = tostring(opts.current or fallback),
        locales = {},          -- [locale] = { key = template }
    }, I18NMT)
end

---------------------------------------------------------------------------
-- Defining and choosing
---------------------------------------------------------------------------

-- Merges a table of key->template into a locale (repeated calls accumulate,
-- so a base table and a mod's additions coexist).
function I18NMT:define(locale, table_)
    locale = tostring(locale)
    local t = self.locales[locale] or {}
    for k, v in pairs(table_ or {}) do t[tostring(k)] = tostring(v) end
    self.locales[locale] = t
    return self
end

function I18NMT:use(locale)
    self.current = tostring(locale)
    return self
end

function I18NMT:locale()
    return self.current
end

function I18NMT:locales_()
    local out = {}
    for name in pairs(self.locales) do out[#out + 1] = name end
    table.sort(out)
    return out
end

-- Does the current locale (or `locale`) define this key itself, no fallback?
-- The editor's completeness check uses it to find untranslated keys.
function I18NMT:has(key, locale)
    local t = self.locales[locale or self.current]
    return t ~= nil and t[tostring(key)] ~= nil
end

---------------------------------------------------------------------------
-- Lookup
---------------------------------------------------------------------------

local function template(self, key)
    local cur = self.locales[self.current]
    if cur and cur[key] then return cur[key] end
    local fb = self.locales[self.fallback]
    if fb and fb[key] then return fb[key] end
    return nil
end

-- The translation for `key`, formatted with any extra args. A missing key
-- returns the key itself; a format that throws returns the raw template.
function I18NMT:t(key, ...)
    key = tostring(key)
    local tmpl = template(self, key)
    if not tmpl then return key end
    if select('#', ...) == 0 then return tmpl end
    local ok, formatted = pcall(string.format, tmpl, ...)
    return ok and formatted or tmpl
end

-- Which keys the current locale is missing relative to the fallback — the
-- translation to-do list. Sorted, so a diff between builds is readable.
function I18NMT:missing(locale)
    locale = locale or self.current
    local have = self.locales[locale] or {}
    local base = self.locales[self.fallback] or {}
    local out = {}
    for key in pairs(base) do
        if have[key] == nil then out[#out + 1] = key end
    end
    table.sort(out)
    return out
end

---------------------------------------------------------------------------
-- Persistence: key=value lines, one file per locale
---------------------------------------------------------------------------

local function trim(s) return (s:gsub('^%s+', ''):gsub('%s+$', '')) end

-- Parses `key=value` text into a locale. `\n` in a value is written and read
-- as the two characters backslash-n, so a multi-line template survives a
-- line-oriented file.
function I18NMT:loadText(locale, text)
    if type(text) ~= 'string' then return nil, 'string required' end
    local t = self.locales[tostring(locale)] or {}
    for line in (text .. '\n'):gmatch('([^\n]*)\n') do
        line = line:gsub('\r$', '')
        if line ~= '' and not line:match('^%s*#') then
            local k, v = line:match('^([^=]+)=(.*)$')
            if k then
                -- Both sides trimmed: a translator's stray trailing space is a
                -- mistake far more often than a meaningful pad, and a template
                -- that truly needs an edge space can encode it as \n-style is
                -- not offered here on purpose (keep the format boring).
                t[trim(k)] = (trim(v):gsub('\\n', '\n'))
            end
        end
    end
    self.locales[tostring(locale)] = t
    return true
end

function I18NMT:saveText(locale)
    local t = self.locales[tostring(locale)] or {}
    local keys = {}
    for k in pairs(t) do keys[#keys + 1] = k end
    table.sort(keys)
    local lines = { '# MeatRayCast locale ' .. tostring(locale) }
    for i = 1, #keys do
        lines[#lines + 1] = ('%s=%s'):format(keys[i], (t[keys[i]]:gsub('\n', '\\n')))
    end
    return table.concat(lines, '\n') .. '\n'
end

-- storage is the meatray.save.storage backend; path defaults to
-- 'locale.<name>.txt' beside the other config.
function I18NMT:load(storage, locale, path)
    if not storage or not storage.read then return nil, 'storage backend required' end
    path = path or ('locale.%s.txt'):format(locale)
    local bytes, err = storage.read(path)
    if not bytes then return nil, err or 'missing locale file' end
    return self:loadText(locale, bytes)
end

function I18NMT:save(storage, locale, path)
    if not storage or not storage.write then return nil, 'storage backend required' end
    path = path or ('locale.%s.txt'):format(locale)
    return storage.write(path, self:saveText(locale))
end

return I18N
