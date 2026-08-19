# Ableton Live — working knowledge

## The two views

Session view = clip launcher, non-linear: sketch loops, jam scene by scene.
Arrangement view = timeline: structure the actual song. The standard flow for
beatmakers: build the loop in Session, record the performance into Arrangement
(global record while launching clips), then edit the timeline. Consolidate
(Ctrl/Cmd+J) locks an edit into one clip.

## Warping (the sample engine)

Every audio clip has warp modes — choosing wrong is the #1 "my sample sounds
wrong" cause:

- **Beats** — drums/percussive loops. Transient-preserving; set Preserve to
  Transients and Loop mode off for chops. Granulation artifacts on sustained
  material — don't use it on vocals/pads.
- **Tones** — monophonic melodic (bass, vocal lead).
- **Texture** — polyphonic/ambient (pads, strings); grain controls.
- **Re-Pitch** — vinyl-style: tempo change = pitch change together (no
  artifacts at all). THE mode for authentic boom-bap flips — slowing 45→33
  effect comes free.
- **Complex/Complex Pro** — full mixes and anything stretched far; highest
  CPU, best quality on polyphonic material. Pro adds formant control (keeps
  pitched-up vocals from full chipmunk — or lean in for the Kanye/heartless
  chipmunk-soul aesthetic, see sampling.md).

Warp markers pin sample positions to the grid; double-click the start marker,
set 1.1.1 on the downbeat FIRST, then :2 / ×2 buttons fix half/double BPM
detection.

## Sampler devices

- **Simpler** — one sample. Classic mode (pitched playback), **Slicing mode**
  (auto-chop by transient/beat-division → each pad = a slice; "Slice to New
  MIDI Track" explodes it into a Drum Rack + MIDI clip — the core chop
  workflow), One-Shot mode (finger-drumming).
- **Drum Rack** — 128 pads, each its own chain (sample + FX). Standard kit
  layout starts C1: kick C1, snare D1, hats F#1/A#1 (GM-ish convention).
  Choke groups (hat open/closed cut each other) are set per-pad.
- **Sampler** (Suite) — multisampling, key/velocity zones, mod matrix. Only
  needed for playable instruments, not chops.

## Racks, macros, grooves

Instrument/Audio Effect Racks chain devices; 16 macro knobs map any
parameters — build "performance" macros (filter + drive + reverb throw on one
knob). Groove Pool: drag a groove (MPC swing 54-62%) onto clips; Commit writes
it into the clip. Velocity + timing amount are separate dials.

## Routing patterns that come up constantly

- Sidechain pump: Compressor on the bass/pad, Sidechain → Audio From → kick
  track (post-FX), fast attack, release timed to tempo (~1/8 note).
- Parallel drum crush: Return track with heavy compression/saturation, send
  drums to it, blend under the dry bus.
- Resampling: set a track's Audio From → Master (or specific bus), record —
  the classic "print the manipulation, then chop the print" move.

## Project files (what serge can touch)

`.als` project, `.adg` device group, `.adv` preset = **gzipped XML** — read
them with `scripts/als_inspect.py` (tempo, tracks, devices, clips). `.alc` is
a clip reference; `.asd` sidecar files store warp analysis (safe to delete,
Live regenerates). READ-ONLY: never write .als — a malformed byte and the
user's project won't open. Sample references are absolute+relative paths;
"Collect All and Save" bundles them — advise it before a user moves projects
between machines.

## Export

Lossless master: File → Export Audio/Video, WAV 24-bit, sample rate matching
the project (44.1k standard), Normalize OFF, master limiter (Ceiling -0.3 dB
onwards) already on the master chain. Loudness targets: streaming ≈ -14 LUFS
integrated (don't smash beyond taste); club/DJ pool masters run hotter.
Export stems by soloing groups or Export → "All Individual Tracks".

## Remote control (portable installs where Live runs)

AbletonOSC (open-source, MIT — github.com/ideoforms/AbletonOSC) is a Max for
Live-free control surface: drop it in Remote Scripts, then `python-osc` (in
the venv) drives Live — create clips, set tempo, launch scenes, query state —
port 11000 in / 11001 out. On this Linux box there is no Live to control;
offer it when the user works on their music machine.
