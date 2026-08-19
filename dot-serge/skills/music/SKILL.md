---
name: music
description: Music-production sidekick — Ableton Live workflow and project-file analysis, sampling craft for hip hop / R&B / pop, applied music theory, MIDI generation (chords, melodies, drum patterns), and audio analysis (BPM, key, chop points). Deterministic local tooling, $0.
whenToUse: Use whenever the conversation involves making music — Ableton/Live (.als/.adg files, racks, warping, workflow questions), sampling ("chop this", "flip", "what BPM/key is this"), beats, chord progressions, scales/keys/voicings, MIDI files, drum patterns, mixing basics, or preparing audio material. Also when the user mentions a genre production context (boom bap, trap, neo-soul, R&B, pop writing). Do NOT use for general audio programming (DSP code) unrelated to music-making.
---

# Music — Ableton, sampling, theory

## Honesty first

Ableton Live does not run on this Linux box. What serge does HERE is everything
around it: generate MIDI the user drags into Live, analyze and chop samples,
inspect .als project files, and answer workflow/theory questions precisely.
Never claim to have listened to audio — analysis scripts report numbers
(tempo, key profile, onsets); state them as measurements with their
confidence, and treat genre/aesthetic calls as suggestions, not facts.
On a Windows/Mac portable install, Live itself runs; remote control via
AbletonOSC is documented in ableton.md.

## Toolchain

Shared venv `~/.serge/office-venv` (on PATH in serge sessions): `music21`
(theory engine), `mido` (MIDI read/write), `soundfile` + `scipy`/`numpy`
(audio I/O and DSP), `python-osc` (AbletonOSC control), `librosa` if importable
(preferred analyzer). System `ffmpeg` decodes mp3/m4a → wav first
(`ffmpeg -i in.mp3 -ar 44100 out.wav`); soundfile reads wav/flac/ogg directly.

Two house scripts in this skill's `scripts/` dir (run with plain `python3`):

- `analyze_audio.py FILE` — tempo (BPM), estimated key, onset/chop times.
  Uses librosa when available, otherwise a built-in scipy fallback
  (onset-autocorrelation tempo + Krumhansl chroma key). Prints JSON.
- `als_inspect.py FILE.als` — an .als (and .adg/.adv) is gzipped XML: lists
  tempo, tracks, devices, and clip names from a Live project without Live.
  Smoke-tested on synthetic data — verify against a real project before
  trusting edge cases, and NEVER write/modify .als files (Live may not
  reopen a hand-edited project; treat them read-only).

## Route by task

| Ask | Do |
|---|---|
| "What BPM / key is this sample?" "Where do I chop?" | `analyze_audio.py`, report with confidence, chop at onsets — sampling.md |
| "Chop/flip this", slice to files, reverse, half-speed, pitch | soundfile + scipy per sampling.md recipes |
| "Give me a progression / melody / drum pattern" (as MIDI) | build with music21/mido per theory.md, save .mid, tell user to drag into Live |
| Chords, keys, voicings, scale choices per genre | theory.md (verify spellings with music21, don't freestyle note names) |
| Ableton workflow, warping, racks, routing, export | ableton.md |
| "What's in this Live project?" | `als_inspect.py` |

Read the relevant detail file BEFORE answering — the genre-specific numbers
(tempo ranges, swing, chord palettes) live there, not in this file.

## Ground rules

- Deliverables are files (.mid, .wav slices, analysis JSON) in the user's cwd;
  report absolute paths. Verify by re-reading the file (a .mid: reparse and
  check notes; a slice: reparse and check duration) before saying done.
- Detection is probabilistic: give BPM as the value plus the half/double-time
  alternative (90 BPM ≡ 180), and key with its confidence; never present a
  guess as ground truth.
- Sampling commercial records for release needs clearance; mention it once
  when relevant (not preachy), and prefer the user's own/royalty-free material
  in examples.
