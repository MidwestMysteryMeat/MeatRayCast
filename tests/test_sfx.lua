--[[
    H3: parametric SFX synthesis. Params normalize with refusal and clamping;
    rendering is pure and deterministic (noise included, via the engine LCG);
    the WAV encoder writes a well-formed RIFF/PCM16 header; presets all render;
    a seeded randomize is one sound forever.
]]

return function(t)
    local Sfx = require('meatray.asset.sfx')

    ---------------------------------------------------------------------
    t.describe('params normalize: refuse the unrenderable, clamp the rest')

    t.ok(not Sfx.normalize(nil), 'nil params refused')
    local _, why = Sfx.normalize{ wave = 'wub' }
    t.ok(why and why:find('unknown wave'), 'an unknown waveform is refused with a reason')

    local p = Sfx.normalize{ wave = 'square', freq = 99999, gain = -3 }
    t.eq(p.freq, 4000, 'frequency clamps to the top of its range')
    t.eq(p.gain, 0, 'gain clamps to zero, not negative')
    t.eq(p.duty, 0.5, 'unset fields take their defaults')

    local original = { wave = 'sine', freq = 100000 }
    Sfx.normalize(original)
    t.eq(original.freq, 100000, 'normalize returns a copy, never mutates the input')

    local silent = Sfx.normalize{ wave = 'sine', attack = 0, sustain = 0, decay = 0 }
    t.ok(silent.decay > 0, 'an all-zero envelope is given a decay instead of zero samples')

    t.eq(Sfx.duration{ wave = 'sine', attack = 0.25, sustain = 0.25, decay = 0.5 }, 1,
        'duration is the envelope sum')

    ---------------------------------------------------------------------
    t.describe('rendering is pure and deterministic')

    local params = Sfx.preset('pickup')
    local a = Sfx.render(params)
    local b = Sfx.render(params)
    t.eq(#a, #b, 'same params, same sample count')
    local same = true
    for i = 1, #a do
        if a[i] ~= b[i] then same = false break end
    end
    t.ok(same, 'same params, identical samples')
    t.ok(#a > 100, 'a real preset renders a real number of samples')

    local inRange = true
    for i = 1, #a do
        if a[i] > 1 or a[i] < -1 then inRange = false break end
    end
    t.ok(inRange, 'every sample stays inside [-1, 1]')

    ---------------------------------------------------------------------
    t.describe('noise is seeded by the params, not by the machine')

    local n1 = Sfx.render{ wave = 'noise', freq = 800, decay = 0.1, seed = 5 }
    local n2 = Sfx.render{ wave = 'noise', freq = 800, decay = 0.1, seed = 5 }
    local n3 = Sfx.render{ wave = 'noise', freq = 800, decay = 0.1, seed = 6 }
    local match = true
    for i = 1, #n1 do
        if n1[i] ~= n2[i] then match = false break end
    end
    t.ok(match, 'same seed, same noise')
    local differ = #n1 ~= #n3
    for i = 1, math.min(#n1, #n3) do
        if n1[i] ~= n3[i] then differ = true break end
    end
    t.ok(differ, 'a different seed is a different sound')

    ---------------------------------------------------------------------
    t.describe('a downward slide ends the note at the frequency floor')

    local full = Sfx.render{ wave = 'saw', freq = 1200, sustain = 0.1, decay = 0.4 }
    local cut = Sfx.render{ wave = 'saw', freq = 1200, freqSlide = -6000,
                            freqLimit = 200, sustain = 0.1, decay = 0.4 }
    t.ok(#cut < #full, 'the laser tail is shorter than its envelope')

    ---------------------------------------------------------------------
    t.describe('the WAV encoder writes well-formed RIFF/PCM16 mono')

    local wav = Sfx.wav(params)
    t.eq(wav:sub(1, 4), 'RIFF', 'RIFF magic')
    t.eq(wav:sub(9, 12), 'WAVE', 'WAVE form type')
    t.eq(wav:sub(13, 16), 'fmt ', 'fmt chunk')
    t.eq(wav:sub(37, 40), 'data', 'data chunk')

    local function le32(s, at)
        local b1, b2, b3, b4 = s:byte(at, at + 3)
        return b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
    end
    local function le16(s, at)
        local b1, b2 = s:byte(at, at + 1)
        return b1 + b2 * 256
    end

    t.eq(le32(wav, 5), #wav - 8, 'RIFF size covers the file after the header')
    t.eq(le16(wav, 21), 1, 'format is PCM')
    t.eq(le16(wav, 23), 1, 'mono')
    t.eq(le32(wav, 25), Sfx.SAMPLE_RATE, 'sample rate recorded')
    t.eq(le16(wav, 35), 16, '16 bits per sample')
    t.eq(le32(wav, 41), #wav - 44, 'data size covers exactly the payload')
    t.eq((#wav - 44) / 2, #a, 'one 16-bit word per rendered sample')

    t.eq(Sfx.wav(params), wav, 'the same params produce byte-identical files')

    ---------------------------------------------------------------------
    t.describe('every preset normalizes and renders')

    local names = Sfx.presetNames()
    t.ok(#names >= 7, 'a real preset library ships')
    for _, name in ipairs(names) do
        local pp, err = Sfx.preset(name)
        t.ok(pp, ('preset %s resolves (%s)'):format(name, tostring(err)))
        local s = Sfx.render(pp)
        t.ok(s and #s > 0, ('preset %s renders samples'):format(name))
    end
    t.ok(not Sfx.preset('nope'), 'an unknown preset is refused')

    ---------------------------------------------------------------------
    t.describe('synth-declared sounds: procedural by design, silent headless')

    local Sound = require('meatray.asset.sound')
    local Registry = require('meatray.asset.registry')

    local rec = Sound.declareSynth('sfxtest.blip', 'blip', { volume = 0.5 })
    t.ok(rec, 'a preset name declares')
    t.ok(rec.settings.synth and rec.settings.synth.wave == 'square',
        'the preset was normalized into the record at declare time')
    t.eq(rec.settings.volume, 0.5, 'playback settings ride along')

    local custom = Sound.declareSynth('sfxtest.thud',
        { wave = 'square', freq = 150, decay = 0.2 })
    t.eq(custom.settings.synth.freq, 150, 'a params table declares too')

    local bad, why = Sound.declareSynth('sfxtest.bad', 'no-such-preset')
    t.ok(not bad and why:find('unknown preset'),
        'a typo is a reason at declare time, not silence at playtime')
    local badWave, whyWave = Sound.declareSynth('sfxtest.worse', { wave = 'wub' })
    t.ok(not badWave and whyWave:find('unknown wave'), 'bad params likewise')

    local resolved = Registry.resolve('sfxtest.blip', 'sound')
    t.eq(resolved.state, 'generated',
        'a synth sound is procedural-by-design, never missing')
    t.eq(resolved.value, nil, 'and headless it stays silent, without error')
    local missingNames = {}
    for _, m in ipairs(Registry.missing()) do missingNames[m.name] = true end
    t.ok(not missingNames['sfxtest.blip'],
        'the missing-asset report does not count it')

    t.ok(not Sound.buildSynth(rec.settings.synth),
        'buildSynth answers nil headless, never raises')

    ---------------------------------------------------------------------
    t.describe('a seeded variation is one sound forever')

    local v1 = Sfx.randomize('pickup', 42)
    local v2 = Sfx.randomize('pickup', 42)
    local v3 = Sfx.randomize('pickup', 43)
    t.eq(Sfx.wav(v1), Sfx.wav(v2), 'same seed, byte-identical variation')
    t.ok(Sfx.wav(v1) ~= Sfx.wav(v3), 'a different seed is a different variation')
    t.ok(v1.freq ~= Sfx.preset('pickup').freq, 'a variation actually moved the params')
end
