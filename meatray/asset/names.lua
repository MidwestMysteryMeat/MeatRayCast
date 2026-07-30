--[[
    meatray.asset.names — logical names, file extensions and where to look.

    An asset has two identities: the logical name game code refers to
    (`Sprites.define('imp', ...)`, `Billboard{ sheet = 'imp' }`) and the file it
    happens to be loaded from. Keeping those separate is what lets a missing file
    fall back to a placeholder under the same name, and what lets art move on disk
    without editing gameplay code.

    The mapping between them is small, dull, and exactly the sort of thing that
    goes wrong quietly: a name derived with the extension still attached looks
    right in a log line and never matches a lookup. So it lives here and is
    asserted rather than assumed.

    Filename grid hints are supported because typing the same two numbers into a
    dialog every import is how the numbers end up wrong:

        imp_a8_f4.png     8 angle buckets, 4 frames  (explicit, preferred)
        imp_8x4.png       8 angle buckets, 4 frames  (rows x columns, as drawn)
        imp.png           no hint; the importer asks

    `8x4` reads rows-by-columns on purpose: that is the order the sheet is laid
    out in and the order `Sprites.define` takes them.

    HEADLESS: no love.* anywhere in this file.
]]

local Names = {}

---------------------------------------------------------------------------
-- Paths
---------------------------------------------------------------------------

-- Splits into directory and final component. Handles both separators, because a
-- path typed on Windows and a path read from love.filesystem do not agree.
function Names.split(path)
    path = tostring(path or ''):gsub('\\', '/')
    local dir, base = path:match('^(.*)/([^/]*)$')
    if not dir then return '', path end
    return dir, base
end

function Names.basename(path)
    local _, base = Names.split(path)
    return base
end

-- Lowercase extension without the dot, or '' when there is none. A trailing dot
-- is not an extension, and neither is a dot in a directory name — both of which
-- a naive `match('%.(%w+)$')` on the full path gets wrong.
function Names.ext(path)
    local base = Names.basename(path)
    local e = base:match('%.([%w]+)$')
    return e and e:lower() or ''
end

function Names.stripExt(path)
    local base = Names.basename(path)
    return (base:gsub('%.[%w]+$', ''))
end

function Names.isPathLike(s)
    s = tostring(s or '')
    return s:find('[/\\]') ~= nil or s:find('%.[%w]+$') ~= nil
end

-- Joins, tolerating a trailing separator on the left or an empty side.
function Names.join(a, b)
    a = tostring(a or ''):gsub('[/\\]+$', '')
    b = tostring(b or ''):gsub('^[/\\]+', '')
    if a == '' then return b end
    if b == '' then return a end
    return a .. '/' .. b
end

---------------------------------------------------------------------------
-- Logical names
---------------------------------------------------------------------------

-- Folds an arbitrary string into a name safe to key a registry with: lowercase,
-- alphanumerics and underscores only, no leading or trailing underscore, never
-- empty. Two files that differ only by case or by punctuation collapse to the
-- same name on purpose — they would collide in a lookup anyway, and colliding
-- loudly in the registry beats colliding silently at draw time.
function Names.normalise(name)
    local s = tostring(name or ''):lower()
    s = s:gsub('[^%w]+', '_')
    s = s:gsub('^_+', ''):gsub('_+$', '')
    if s == '' then return 'unnamed' end
    return s
end

-- Strips any recognised grid hint from a bare (extension-free) name.
local function stripHints(base)
    local s = base
    s = s:gsub('[_%-]a%d+[_%-]f%d+$', '')
    s = s:gsub('[_%-]f%d+[_%-]a%d+$', '')
    s = s:gsub('[_%-]%d+x%d+$', '')
    return s
end

-- The logical name a file should register under: its basename, minus extension,
-- minus grid hint, normalised.
--
--   assets/sprites/Imp_a8_f4.png  ->  imp
function Names.fromPath(path)
    return Names.normalise(stripHints(Names.stripExt(path)))
end

-- Grid hints parsed out of a filename, or nil when there are none. Never
-- guesses: an absent hint is nil, not a default, so the importer can tell "the
-- artist said 8 buckets" from "nobody said anything".
function Names.hints(path)
    local base = Names.stripExt(path):lower()

    local a, f = base:match('[_%-]a(%d+)[_%-]f(%d+)$')
    if a then return { angles = tonumber(a), frames = tonumber(f) } end

    f, a = base:match('[_%-]f(%d+)[_%-]a(%d+)$')
    if f then return { angles = tonumber(a), frames = tonumber(f) } end

    local rows, cols = base:match('[_%-](%d+)x(%d+)$')
    if rows then return { angles = tonumber(rows), frames = tonumber(cols) } end

    return nil
end

---------------------------------------------------------------------------
-- Kinds and search paths
---------------------------------------------------------------------------

-- Extensions this engine can actually load. WAV only for audio: LÖVE decodes it
-- natively, so importing one adds no dependency, and claiming OGG support that
-- rests on a library the build may not have is worse than not claiming it.
Names.EXTENSIONS = {
    image = { 'png' },
    sound = { 'wav' },
    map   = { 'map' },
}

function Names.kindFor(path)
    local e = Names.ext(path)
    for kind, list in pairs(Names.EXTENSIONS) do
        for _, candidate in ipairs(list) do
            if candidate == e then return kind end
        end
    end
    return nil
end

-- Default folders, one per kind. Nothing requires a project to use them — an
-- explicit path always wins — but a convention that exists is a convention the
-- import dialog can prefill.
Names.FOLDERS = {
    image = 'assets/sprites',
    sound = 'assets/sounds',
    map   = 'maps',
}

-- Where to look for `name` of `kind`, in order. A name that already looks like a
-- path is tried verbatim first, so an explicit path is never second-guessed.
function Names.candidates(name, kind, opts)
    opts = opts or {}
    local out = {}
    local seen = {}

    local function add(p)
        if p and p ~= '' and not seen[p] then
            seen[p] = true
            out[#out + 1] = p
        end
    end

    local raw = tostring(name or '')
    if Names.isPathLike(raw) then add((raw:gsub('\\', '/'))) end

    local exts = Names.EXTENSIONS[kind] or { }
    local folders = {}
    if opts.folder then folders[#folders + 1] = opts.folder end
    if Names.FOLDERS[kind] then folders[#folders + 1] = Names.FOLDERS[kind] end
    folders[#folders + 1] = 'assets'

    local bare = Names.stripExt(raw)
    if bare == '' then bare = raw end

    for _, folder in ipairs(folders) do
        for _, e in ipairs(exts) do
            add(Names.join(folder, bare .. '.' .. e))
        end
    end

    return out
end

return Names
