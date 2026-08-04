--[[
    meatray.game.project_api — the PROMISED surface a project's game.lua sees.

    H5 handed game.lua the raw engine facades, which meant every internal
    rename was a potential project break. This module is the fix: a curated,
    versioned api whose named surface is a semver commitment — from
    api.version = 1 on, removing or changing anything listed under STABLE
    below is a MAJOR engine version, the same promise the wire and save
    formats already keep.

    STABLE (promised):

        api.version                    this contract's number (1)
        api.project                    the opened project (id/name/dir,
                                       mapIds(), startMapId())
        api.note(text)                 the console log
        api.isAuthority()              "may my code mutate attributes here?"
        api.onTick(fn)                 function(dt) each fixed step; a raising
                                       hook is retired with a console line
        api.rng(seed)                  the engine LCG (float/int/next) — never
                                       math.random in anything deterministic
        api.archetype(name, builder)   define an entity kind
        api.component(name, def)       define a component
        api.components                 the stock component constructors
        api.attach(e, opts)            the ability/attribute container
        api.ai.attach(e, opts)         the monster brain (host-side step)
        api.define.weapon/item/effect/explosion(name, def)
        api.sound.synth(name, presetOrParams, opts)   zero-media audio
        api.sound.declare(name, opts)                 file-backed audio
        api.sound.play(name, opts) / api.sound.playAt(name, x, y, opts)
        api.messages.centerprint(text, opts) / api.messages.notify(text)
        api.console.register(name, opts, fn)   queued until the console
        api.console.cvar(name, def)            exists, then flushed in order

    UNPROMISED: api.raw.engine / api.raw.game are the full facades, there
    for the thing the curated surface has not named yet. Code against them
    knowingly: they track engine internals and may break on ANY release.
    (api.engine / api.game are deprecated aliases of the same tables, kept
    so pre-v1 projects keep loading.)

    HEADLESS: pure Lua; the sound half degrades to silence like everything
    else in the asset layer.
]]

local Game = require('meatray.game')
local Entity = require('meatray.sim.entity')
local C = require('meatray.sim.components')
local AI = require('meatray.sim.ai')
local Worldgen = require('meatray.sim.worldgen')
local Sound = require('meatray.asset.sound')

local ProjectApi = {}

ProjectApi.VERSION = 1

-- ctx: game (the app state table: messages, projectTicks, projectConsole),
-- proj (the opened project), note, isAuthority, engine (the MeatRay facade
-- for api.raw — passed in rather than required, so this module never pulls
-- the render stack into a headless test).
function ProjectApi.build(ctx)
    local game, proj = ctx.game, ctx.proj
    local note, isAuthority = ctx.note, ctx.isAuthority

    local api = {
        version = ProjectApi.VERSION,
        project = proj,
        note = note,
        isAuthority = isAuthority,

        rng = Worldgen.rng,

        archetype = Entity.archetype,
        component = Entity.component,
        components = C,
        attach = Game.attach,
        ai = { attach = AI.attach },

        define = {
            weapon = Game.weapons.define,
            item = Game.inventory.defineItem,
            effect = Game.effects.define,
            explosion = Game.explosion.define,
        },

        sound = {
            synth = Sound.declareSynth,
            declare = Sound.declare,
            play = Sound.play,
            playAt = Sound.playAt,
        },

        messages = {
            centerprint = function(text, opts)
                return game.messages:centerprint(text, opts)
            end,
            notify = function(text)
                return game.messages:notify(text)
            end,
        },

        -- The console is constructed AFTER projects mount (its commands close
        -- over a fully-built demo), so a project's registrations queue here
        -- and app/console.lua flushes them in order once it exists. From the
        -- project's side that is invisible: register and it will be there.
        console = {
            register = function(name, opts, fn)
                game.projectConsole[#game.projectConsole + 1] =
                    { kind = 'command', name = name, opts = opts, fn = fn }
            end,
            cvar = function(name, def)
                game.projectConsole[#game.projectConsole + 1] =
                    { kind = 'cvar', name = name, def = def }
            end,
        },

        onTick = function(fn)
            if type(fn) == 'function' then
                game.projectTicks[#game.projectTicks + 1] = fn
            end
        end,
    }

    -- The unpromised escape hatch, and its deprecated pre-v1 names.
    api.raw = { engine = ctx.engine, game = Game }
    api.engine = api.raw.engine
    api.game = api.raw.game

    return api
end

return ProjectApi
