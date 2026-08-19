# Sampling — hip hop, R&B, pop craft

## The workflow (any genre)

1. **Analyze first**: `analyze_audio.py` → BPM (state the half/double
   alternative), key, onset grid. Knowing the source key BEFORE chopping is
   what lets the flip sit with bass and melodies later (theory.md, Camelot).
2. **Chop at onsets**, not at grid lines — transients are where the groove
   lives. Slice with soundfile at the detected onset times (add ~5 ms
   pre-roll so attacks aren't clipped; fade the tail 10-20 ms to kill clicks).
3. **Re-order and re-pitch** chops — the flip IS the re-ordering. A chop
   played at 2x speed = +12 semitones; ±n semitones = rate × 2^(n/12)
   (scipy.signal.resample_poly for clean rate changes).
4. **Print and iterate**: resample the arranged flip, chop the print again —
   second-generation chops are where signature sounds come from.

## Genre playbooks

### Hip hop — boom bap (85-95 BPM)
Dusty soul/jazz sources; Re-Pitch warp so slowing darkens the sample
(the 45→33 move ≈ -5 semitones and slower — instant mood). Chops stay chunky:
1-2 bar phrases, few slices (4-8), swung placement — MPC swing 54-58% on
hats/snares, or nudge snares a few ms late by hand for the Dilla "drunk" feel
(deliberately NOT quantized; quantize kick, drag snare). Layer the sample's
drums with your own kit rather than replacing (EQ out the source kick below
~100 Hz, put yours under it). Lo-fi crunch: downsample to 12-bit/26 kHz
(SP-1200 aesthetic) — decimate in scipy or Redux in Live.

### Hip hop — trap (130-170 BPM, felt in half-time)
Sampling here is usually melodic loops (dark keys, bells, choirs), not
breaks: minor/phrygian sources, pitched DOWN 2-5 semitones for menace, heavy
low-pass or telephone-EQ the sample to leave room for 808s. The 808 IS the
bassline — tune it to the sample's key (808 root notes follow the chord
roots; slides between them). Hats do the rhythm work: 1/8 base, 1/16-1/32
rolls, triplet bursts; velocity-ramp the rolls.

### R&B / neo-soul (60-80 BPM ballad, 85-105 mid)
Sources: Rhodes/Wurli loops, quiet-storm strings, gospel chords. Keep chops
long and legato — R&B flips breathe; over-chopping kills it. Pitch vocals UP
for chipmunk-soul hooks (+3 to +7, keep formants in Complex Pro for modern,
drop formant correction for the classic 2000s sound). Chord extensions matter
more than in hip hop: if the sample is a plain triad loop, ADD the 7th/9th
with keys layered under it (theory.md voicings). Drums sit behind the beat —
2-8 ms late snares, ghost notes on snare, swing 56-62%.

### Pop (100-130 BPM)
Sampling in pop is usually interpolation (replaying the hook) or texture
(vinyl noise, one-shot vocal chops as instruments). Vocal-chop leads: chop a
phrase to single syllables, map chromatically in Simpler (Classic mode, root
= detected key), play a NEW melody in the song's key. Keep sampled material
diatonic to the song (theory.md) — pop tolerates far less harmonic clash
than hip hop. Tight quantize, minimal swing (50-54%).

## Making chops sit (mix moves)

- High-pass every chop (60-120 Hz) unless it carries the bass on purpose.
- Duck melodic samples under the vocal/lead: sidechain or -2 dB automation.
- Glue: one saturation/tape stage on the sample bus beats plugins on each chop.
- Mono below ~120 Hz; check the flip in mono once — phase-y stereo soul
  samples collapse.

## Legal note (say once, not preachy)

Releasing music with samples of commercial records requires clearance
(master + publishing); "under 4 bars" is a myth. Interpolation (replaying)
still needs publishing clearance. Royalty-free/own-recorded material has no
such constraint — prefer it for examples.
