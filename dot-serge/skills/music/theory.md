# Applied theory — keys, chords, MIDI generation

Use `music21` to verify anything you assert (chord spellings, key
relationships) — compute, don't recite. Verify generated MIDI by reparsing it.

## Genre harmonic palettes

- **Hip hop / trap**: natural minor and harmonic minor (raised 7th for
  tension), phrygian for menace (b2 — e.g. F in E phrygian), dorian for the
  warmer boom-bap bounce (natural 6 over minor). Loops are short — 2-4 chords,
  i-VI-VII, i-iv-v, or a single minor vamp; movement comes from the flip, not
  the changes.
- **R&B / neo-soul**: extended and altered chords are the genre — min7/min9/
  min11, maj7/maj9, dominant 13ths, and chromatic passing chords. Staples:
  ii7-V7-Imaj7 with tritone subs, iv-to-IV borrowing, the "gospel 2-5-1" with
  a #11 on the maj7. Voicing rule: drop the root (bass has it), stack 3rd-7th-
  9th/11th in close position around middle C; 7th resolving to 3rd between
  chords = the smooth motion the genre lives on.
- **Pop**: diatonic function — I-V-vi-IV and vi-IV-I-V carry half the charts;
  pre-chorus lifts via ii or IV, bridge borrows (bVII, iv). Melody notes on
  chord tones at downbeats, tensions passing. Key changes: the truck-driver
  +1/+2 semitone final chorus, or the newer relative-minor verse → major chorus.

## Numbers that matter

- Tempo homes: boom bap 85-95, trap 130-170 (half-time feel), drill ~140-145,
  R&B ballad 60-80, neo-soul 85-105, pop 100-130, house 120-128.
- Swing: straight 50%, MPC feels 54-62% (hats/snare), J-Dilla = hand-placed
  late snares, not a swing dial.
- MIDI note numbers: C4 = 60 (middle C), A4 = 69 = 440 Hz; each semitone ±1;
  octave ±12. Key of a sample → transpose chops by (target - source) semitones,
  choosing the direction with the smaller absolute shift (≤6).
- Camelot wheel (key-compatible sampling/mixing): adjacent numbers or same
  number's A↔B are safe blends — 8A=Am, 8B=C, 9A=Em, 9B=G, 7A=Dm, 7B=F, etc.
  (same number A↔B = relative major/minor; ±1 = perfect fifth away).

## Generating MIDI (the executable part)

music21 for anything harmonic (it spells chords correctly):

```python
from music21 import stream, harmony, key, meter, note, tempo
s = stream.Stream()
s.append(tempo.MetronomeMark(number=88))
s.append(key.Key('f#', 'minor')); s.append(meter.TimeSignature('4/4'))
for sym in ['F#m9', 'Dmaj7', 'C#m7', 'Bm9']:
    c = harmony.ChordSymbol(sym); c.duration.quarterLength = 4
    s.append(c)
s.write('midi', fp='progression.mid')
```

mido for drum patterns (channel 9 = GM drums; kick 36, snare 38, closed hat
42, open hat 46). THE mido trap: message `time` is a DELTA from the previous
message, and simultaneous events (kick + hat on the same tick) make naive
bookkeeping go negative → `ValueError: message time must be non-negative`.
Always compose in ABSOLUTE ticks — build (abs_tick, note_on/off, note, vel)
tuples, sort by tick, then emit `time = tick - prev` while walking. 1/16 note
= ticks_per_beat//4; swing = shift every second 16th late by the swing ticks.

Rules for generated parts: keep progressions loop-friendly (2/4/8 bars),
velocities humanized (±10-15, accents on 2 and 4 for snares), and always
reparse the written .mid (mido) to verify note count/pitches before
reporting done. Tell the user the target key/BPM so their session matches,
and that dragging the .mid onto a Live MIDI track just works.
