--[[
    meatray.game.dialogue — a branching conversation, as a model (C20).

    The scaffold genres (rpg, turnrpg, vn) all want the same thing the FPS core
    never needed: a conversation that BRANCHES — a line, then a set of choices,
    each leading somewhere else, some gated on what happened earlier. This is
    that state machine, and only that. It holds no strings of its own: the text,
    the speaker names, the choice labels are CONTENT, authored by the game, and
    this module never invents a word of it. What it owns is the shape — which
    node is current, which choices are legal right now, where each one leads, and
    whether the conversation is over.

        local Dialogue = require('meatray.game.dialogue')

        local convo = Dialogue.new{
            start = 'greet',
            nodes = {
                greet = { speaker = 'guard', text = 'HALT.', choices = {
                    { text = 'ASK_PASS', to = 'pass' },
                    { text = 'LEAVE',    to = 'bye', set = 'rude' },
                } },
                pass = { text = 'PASS_LINE', to = 'bye' },
                bye  = { text = 'BYE_LINE', ['end'] = true },
            },
        }

        convo:begin()
        convo:current()            -- the node to show { id, speaker, text, ... }
        convo:choices()            -- the choices legal right now (gates applied)
        convo:choose(1)            -- take choice 1; advances
        convo:advance()            -- for a linear node (no choices), go to `to`
        convo:isOver()             -- reached an end node (or ran out)

    Gating and side effects are FLAGS, nothing more — a choice may carry `if` (a
    flag that must be set for the choice to appear) and `set` (a flag it sets
    when taken). A node may carry `set` too. Flags are the model's whole memory;
    what a flag MEANS (a quest state, an item, a relationship) belongs to the
    game, which seeds and reads them.

    Deterministic: no clock, no rng. `choose` takes an explicit index, so a bot,
    a demo and a replay drive a conversation the same way a player does.

    HEADLESS: pure Lua, no love.*. The renderer draws current()/choices(); this
    decides what they are.
]]

local Dialogue = {}
local DialogueMT = {}
DialogueMT.__index = DialogueMT

---------------------------------------------------------------------------
-- Validation — a conversation that dangles is caught before it is played
---------------------------------------------------------------------------

-- Returns ok, errors. Every `to` (node-level and per-choice) must name a node
-- that exists, and the start node must exist: a dead link is a conversation
-- that strands the player on a screen with no way forward.
function Dialogue.validate(script)
    local errs = {}
    if type(script) ~= 'table' then return false, { 'script is not a table' } end
    local nodes = script.nodes
    if type(nodes) ~= 'table' then return false, { 'script has no nodes' } end
    if not script.start or not nodes[script.start] then
        errs[#errs + 1] = 'start node ' .. tostring(script.start) .. ' does not exist'
    end
    for id, node in pairs(nodes) do
        if type(node) ~= 'table' then
            errs[#errs + 1] = ('node %s is not a table'):format(tostring(id))
        else
            if node.to ~= nil and not nodes[node.to] then
                errs[#errs + 1] = ('node %s links to missing node %s')
                    :format(tostring(id), tostring(node.to))
            end
            for i, c in ipairs(node.choices or {}) do
                if type(c) ~= 'table' then
                    errs[#errs + 1] = ('node %s choice %d is not a table')
                        :format(tostring(id), i)
                elseif not c.to or not nodes[c.to] then
                    errs[#errs + 1] = ('node %s choice %d links to missing node %s')
                        :format(tostring(id), i, tostring(c.to))
                end
            end
            -- A node with neither choices, a `to`, nor an end is a dead end the
            -- player cannot leave — flag it, since it is almost always a typo.
            local hasChoices = node.choices and #node.choices > 0
            if not hasChoices and node.to == nil and not node['end'] then
                errs[#errs + 1] = ('node %s has no choices, no `to`, and no `end` — '
                    .. 'the player would be stuck'):format(tostring(id))
            end
        end
    end
    return #errs == 0, errs
end

---------------------------------------------------------------------------
-- Construction
---------------------------------------------------------------------------

-- opts.flags: an initial flag set { name = true } the game seeds (quest state,
-- items). Copied, so the caller's table is not mutated as the convo runs.
function Dialogue.new(script, opts)
    opts = opts or {}
    local flags = {}
    for k, v in pairs(opts.flags or {}) do flags[k] = v end
    return setmetatable({
        script  = script,
        nodes   = (script and script.nodes) or {},
        startId = script and script.start,
        cur     = nil,
        flags   = flags,
        over    = false,
        visited = {},      -- [id] = times entered
    }, DialogueMT)
end

---------------------------------------------------------------------------
-- Flags
---------------------------------------------------------------------------

function DialogueMT:setFlag(name, value)
    if name ~= nil then self.flags[name] = (value == nil) and true or value end
end

function DialogueMT:hasFlag(name)
    return self.flags[name] and true or false
end

---------------------------------------------------------------------------
-- Playing
---------------------------------------------------------------------------

-- Enter a node: record the visit and apply its `set` flag. A node flagged
-- `once` that has already been entered is skipped straight to its `to`/end.
local function enter(self, id)
    local node = self.nodes[id]
    if not node then self.over = true; self.cur = nil; return end

    if node.once and (self.visited[id] or 0) > 0 then
        if node.to then return enter(self, node.to) end
        self.over = true; self.cur = nil; return
    end

    self.cur = id
    self.visited[id] = (self.visited[id] or 0) + 1
    if node.set then self:setFlag(node.set) end
    if node['end'] then self.over = true end
end

function DialogueMT:begin()
    self.over = false
    self.visited = {}
    if self.startId then enter(self, self.startId) else self.over = true end
    return self:current()
end

-- The node to display right now, or nil once there is nothing left to show. An
-- END node is still returned — its final line is shown, and isOver() is what
-- tells the game to close the box on the next input; the two are not the same
-- moment. current() only goes nil when the conversation ran off the end.
function DialogueMT:current()
    if not self.cur then return nil end
    local node = self.nodes[self.cur]
    if not node then return nil end
    return {
        id      = self.cur,
        speaker = node.speaker,
        text    = node.text,
        ['end'] = node['end'] and true or false,
    }
end

-- The choices legal right now: a choice with an `if` appears only when that
-- flag is set. Returns an array in author order, each { index, text, to }.
-- `index` is the ORIGINAL choice index, so choose() takes the same number the
-- author wrote regardless of which choices are hidden.
function DialogueMT:choices()
    local out = {}
    if self.over or not self.cur then return out end
    local node = self.nodes[self.cur]
    for i, c in ipairs((node and node.choices) or {}) do
        if not c['if'] or self:hasFlag(c['if']) then
            out[#out + 1] = { index = i, text = c.text, to = c.to }
        end
    end
    return out
end

-- Take a choice by its ORIGINAL index (the one choices() reports). Applies the
-- choice's `set` flag and moves to its `to`. Refuses a hidden or missing choice.
function DialogueMT:choose(index)
    if self.over or not self.cur then return false, 'conversation is over' end
    local node = self.nodes[self.cur]
    local c = node and node.choices and node.choices[index]
    if not c then return false, 'no such choice' end
    if c['if'] and not self:hasFlag(c['if']) then
        return false, 'choice is gated'
    end
    if c.set then self:setFlag(c.set) end
    enter(self, c.to)
    return true
end

-- Advance a LINEAR node (one with a `to` and no choices). A node with choices
-- refuses — the player must pick. Returns true if it moved.
function DialogueMT:advance()
    if self.over or not self.cur then return false end
    local node = self.nodes[self.cur]
    if node.choices and #node.choices > 0 then return false end
    if node.to then enter(self, node.to); return true end
    -- No `to` and no choices: an end (or a dead node) — nothing to advance to.
    self.over = true
    return false
end

function DialogueMT:isOver() return self.over end

-- How many times a node has been entered this run — for a graph or a game that
-- wants "first time you talk to X" without inventing its own bookkeeping.
function DialogueMT:timesVisited(id)
    return self.visited[id] or 0
end

return Dialogue
