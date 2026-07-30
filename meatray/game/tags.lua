--[[
    meatray.game.tags — hierarchical gameplay tags.

    A tag is a dotted string: `state.stunned`, `damage.type.fire`, `ability.dash`.
    The hierarchy is the whole point. Asking whether something is `damage.type`
    must answer yes for `damage.type.fire`, so a fire resistance is written once
    and keeps working when `damage.type.fire.greek` is invented later.

    This replaces the boolean-per-condition that every gameplay codebase grows:
    `stunned`, `rooted`, `silenced`, `burning`, `invulnerable`, each with its own
    field, its own accessor and its own bug where two systems disagree about who
    clears it. A tag container is one counted set, and "who cleared it" stops
    being a question because effects add and remove their own grants by count.

    Matching is deliberately asymmetric and deliberately strict:

        matches('damage.type.fire', 'damage.type')   -> true   (child of query)
        matches('damage.type',      'damage.type')   -> true   (exact)
        matches('damage.typeX',     'damage.type')   -> false  (NOT a child)
        matches('damage',           'damage.type')   -> false  (parent is not a
                                                                match for a more
                                                                specific query)

    The third case is the one that has to be tested rather than assumed. A prefix
    comparison alone says `damage.typeX` starts with `damage.type`, and a
    resistance written for `damage.type` would then silently soak a completely
    unrelated tag. The separator must be checked, not just the prefix.

    Counted, not boolean. Two effects granting `state.stunned` and one expiring
    must leave the target stunned; a set of booleans cannot express that and
    produces the classic "one dispel cleared two stuns" bug.

    HEADLESS: this module must not touch love.graphics or any love drawing API.
]]

local Tags = {}

---------------------------------------------------------------------------
-- Validation
---------------------------------------------------------------------------

-- Segments are letters, digits and underscores, and may not start with a digit.
-- A tag that fails this is refused at declaration time rather than stored: a
-- typo'd tag is invisible at runtime, because "nothing has this tag" and "this
-- tag is nonsense" look identical from a query.
local function validSegment(seg)
    return seg ~= '' and seg:match('^[%a_][%w_]*$') ~= nil
end

function Tags.valid(tag)
    if type(tag) ~= 'string' or tag == '' then return false end
    if tag:sub(1, 1) == '.' or tag:sub(-1) == '.' then return false end
    if tag:find('%.%.', 1) then return false end

    for seg in tag:gmatch('[^%.]+') do
        if not validSegment(seg) then return false end
    end

    return true
end

function Tags.check(tag)
    if Tags.valid(tag) then return tag end
    return nil, ('%q is not a usable tag (dotted words, e.g. damage.type.fire)')
                :format(tostring(tag))
end

---------------------------------------------------------------------------
-- Matching
---------------------------------------------------------------------------

-- Does `owned` satisfy a query for `query`? See the header for the four cases
-- that define this.
function Tags.matches(owned, query)
    if type(owned) ~= 'string' or type(query) ~= 'string' then return false end
    if owned == query then return true end

    local n = #query
    if #owned <= n then return false end
    if owned:sub(1, n) ~= query then return false end

    -- The separator check. Without it `damage.typeX` matches `damage.type`.
    return owned:sub(n + 1, n + 1) == '.'
end

-- The tag and every ancestor of it, most specific first.
--   ancestors('damage.type.fire') -> { 'damage.type.fire', 'damage.type', 'damage' }
function Tags.ancestors(tag)
    local out = {}
    if type(tag) ~= 'string' or tag == '' then return out end

    out[1] = tag
    local cut = tag:match('^(.*)%.[^%.]+$')
    while cut do
        out[#out + 1] = cut
        cut = cut:match('^(.*)%.[^%.]+$')
    end

    return out
end

function Tags.parent(tag)
    if type(tag) ~= 'string' then return nil end
    return tag:match('^(.*)%.[^%.]+$')
end

---------------------------------------------------------------------------
-- Containers
---------------------------------------------------------------------------

local Container = {}
Container.__index = Container

function Tags.newContainer()
    return setmetatable({ counts = {}, n = 0 }, Container)
end

function Tags.isContainer(c)
    return getmetatable(c) == Container
end

-- Adds `n` grants of a tag. Returns the new count, or nil plus a reason if the
-- tag is not usable.
function Container:add(tag, n)
    local ok, err = Tags.check(tag)
    if not ok then return nil, err end

    n = n or 1
    if type(n) ~= 'number' or n ~= n or n < 1 then n = 1 end
    n = math.floor(n)

    local before = self.counts[tag] or 0
    if before == 0 then self.n = self.n + 1 end
    self.counts[tag] = before + n

    return self.counts[tag]
end

-- Removes `n` grants. A tag never goes negative and disappears at zero.
function Container:remove(tag, n)
    local before = self.counts[tag]
    if not before then return 0 end

    n = n or 1
    if type(n) ~= 'number' or n ~= n or n < 1 then n = 1 end
    n = math.floor(n)

    local after = before - n
    if after <= 0 then
        self.counts[tag] = nil
        self.n = self.n - 1
        return 0
    end

    self.counts[tag] = after
    return after
end

function Container:count(tag)
    return self.counts[tag] or 0
end

-- Exact presence, no hierarchy. Rarely what you want; occasionally exactly what
-- you want (removing precisely the tag you granted).
function Container:hasExact(tag)
    return (self.counts[tag] or 0) > 0
end

-- Hierarchical presence: true if any owned tag matches the query.
function Container:has(query)
    if type(query) ~= 'string' then return false end
    if (self.counts[query] or 0) > 0 then return true end

    for owned in pairs(self.counts) do
        if Tags.matches(owned, query) then return true end
    end

    return false
end

function Container:hasAny(queries)
    for i = 1, #(queries or {}) do
        if self:has(queries[i]) then return true, queries[i] end
    end
    return false
end

function Container:hasAll(queries)
    for i = 1, #(queries or {}) do
        if not self:has(queries[i]) then return false, queries[i] end
    end
    return true
end

-- The first query in `queries` that the container satisfies, or nil. Used for
-- gating messages: a refusal that names the tag is worth writing.
function Container:firstMatch(queries)
    local found, which = self:hasAny(queries)
    if found then return which end
    return nil
end

function Container:isEmpty()
    return self.n == 0
end

-- Sorted, always. Anything that hashes tags and then iterates would produce a
-- different order on a different Lua build, and this list ends up on the wire.
function Container:list()
    local out = {}
    for tag in pairs(self.counts) do out[#out + 1] = tag end
    table.sort(out)
    return out
end

function Container:clear()
    self.counts = {}
    self.n = 0
    return self
end

---------------------------------------------------------------------------
-- Wire form
---------------------------------------------------------------------------

-- A space-separated, sorted string. Deliberately a *string* rather than a table:
-- a netFields value that is a table is shared by reference into the snapshot,
-- and in a listen-server session the host and the local client would then be
-- holding the same table. A string cannot be aliased and cannot be mutated from
-- the other end, which is worth more than the handful of bytes it costs.
function Container:toString()
    return table.concat(self:list(), ' ')
end

function Tags.fromString(s)
    local c = Tags.newContainer()
    if type(s) ~= 'string' then return c end
    for tag in s:gmatch('%S+') do c:add(tag, 1) end
    return c
end

-- Query a wire string without building a container. Cheap enough to call from a
-- client's gating check every frame.
function Tags.stringHas(s, query)
    if type(s) ~= 'string' or type(query) ~= 'string' then return false end
    for tag in s:gmatch('%S+') do
        if Tags.matches(tag, query) then return true end
    end
    return false
end

Tags.Container = Container

return Tags
