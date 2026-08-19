#!/usr/bin/env python3
"""Analyze an audio file for sampling: tempo (BPM), estimated key, onset/chop points.

Usage: python3 analyze_audio.py FILE [--json OUT.json]
Prints JSON. Uses librosa when importable; otherwise a scipy/numpy fallback
(spectral-flux onsets, autocorrelation tempo, Krumhansl-Schmuckler key).
BPM is reported with its half/double-time alternative — pick by feel.
Non-wav/flac/ogg inputs are decoded through ffmpeg to a temp wav first.
"""
import json, subprocess, sys, tempfile
from pathlib import Path

import numpy as np
import soundfile as sf

KRUMHANSL_MAJOR = np.array([6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88])
KRUMHANSL_MINOR = np.array([6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17])
NOTE_NAMES = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]


def load_audio(path: Path, target_sr: int = 22050):
    try:
        y, sr = sf.read(path, always_2d=False)
    except Exception:
        tmp = Path(tempfile.mkstemp(suffix=".wav")[1])
        subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(path),
                        "-ar", str(target_sr), "-ac", "1", str(tmp)], check=True)
        y, sr = sf.read(tmp, always_2d=False)
        tmp.unlink(missing_ok=True)
    if y.ndim > 1:
        y = y.mean(axis=1)
    y = y.astype(np.float64)
    if sr != target_sr:
        from scipy.signal import resample_poly
        from math import gcd
        g = gcd(int(sr), target_sr)
        y = resample_poly(y, target_sr // g, int(sr) // g)
        sr = target_sr
    peak = np.max(np.abs(y)) or 1.0
    return y / peak, sr


def spectral_flux(y, sr, n_fft=2048, hop=512):
    from scipy.signal import stft
    _, _, Z = stft(y, fs=sr, nperseg=n_fft, noverlap=n_fft - hop, padded=False)
    mag = np.abs(Z)
    flux = np.maximum(mag[:, 1:] - mag[:, :-1], 0.0).sum(axis=0)
    flux = np.concatenate([[0.0], flux])
    if flux.max() > 0:
        flux = flux / flux.max()
    return flux, hop


def detect_onsets_scipy(y, sr):
    flux, hop = spectral_flux(y, sr)
    from scipy.ndimage import uniform_filter1d
    thresh = uniform_filter1d(flux, size=21) + 0.07
    min_gap = int(0.09 * sr / hop)  # 90 ms refractory
    onsets, last = [], -min_gap
    for i in range(1, len(flux) - 1):
        if flux[i] > thresh[i] and flux[i] >= flux[i - 1] and flux[i] >= flux[i + 1] and i - last >= min_gap:
            onsets.append(i)
            last = i
    return np.array(onsets) * hop / sr, flux, hop


def detect_tempo_scipy(flux, sr, hop):
    fps = sr / hop
    lo, hi = int(fps * 60 / 200), int(fps * 60 / 60)  # 200..60 BPM lags
    env = flux - flux.mean()
    ac = np.correlate(env, env, mode="full")[len(env) - 1:]
    if hi >= len(ac):
        hi = len(ac) - 1
    if lo >= hi:
        return None
    lag = lo + int(np.argmax(ac[lo:hi + 1]))
    return 60.0 * fps / lag


def chroma_scipy(y, sr, n_fft=4096, hop=1024):
    from scipy.signal import stft
    freqs, _, Z = stft(y, fs=sr, nperseg=n_fft, noverlap=n_fft - hop, padded=False)
    mag = np.abs(Z)
    chroma = np.zeros(12)
    valid = (freqs > 55) & (freqs < 4000)
    for f, m in zip(freqs[valid], mag[valid].sum(axis=1)):
        pc = int(round(12 * np.log2(f / 440.0) + 69)) % 12
        chroma[pc] += m
    return chroma / chroma.sum() if chroma.sum() else chroma


def estimate_key(chroma):
    best = None
    for tonic in range(12):
        rolled = np.roll(chroma, -tonic)
        for name, profile in (("major", KRUMHANSL_MAJOR), ("minor", KRUMHANSL_MINOR)):
            r = np.corrcoef(rolled, profile)[0, 1]
            if best is None or r > best[2]:
                best = (tonic, name, r)
    tonic, mode, r = best
    return f"{NOTE_NAMES[tonic]} {mode}", round(float(r), 3)


def analyze(path: Path):
    y, sr = load_audio(path)
    result = {"file": str(path), "duration_s": round(len(y) / sr, 2)}
    try:
        import librosa
        tempo, beats = librosa.beat.beat_track(y=y, sr=sr)
        onset_t = librosa.onset.onset_detect(y=y, sr=sr, units="time")
        chroma = librosa.feature.chroma_cqt(y=y, sr=sr).mean(axis=1)
        chroma = chroma / chroma.sum() if chroma.sum() else chroma
        result["engine"] = "librosa"
        bpm = float(np.atleast_1d(tempo)[0])
    except Exception:
        onset_t, flux, hop = detect_onsets_scipy(y, sr)
        bpm = detect_tempo_scipy(flux, sr, hop)
        chroma = chroma_scipy(y, sr)
        result["engine"] = "scipy-fallback"
    key, conf = estimate_key(chroma)
    result.update({
        "bpm": round(bpm, 1) if bpm else None,
        "bpm_alt_half_double": [round(bpm / 2, 1), round(bpm * 2, 1)] if bpm else None,
        "key_estimate": key,
        "key_confidence_r": conf,
        "n_onsets": int(len(onset_t)),
        "onsets_s": [round(float(t), 3) for t in list(onset_t)[:64]],
    })
    return result


if __name__ == "__main__":
    args = sys.argv[1:]
    if not args:
        sys.exit(__doc__)
    out = analyze(Path(args[0]))
    text = json.dumps(out, indent=2)
    if "--json" in args:
        Path(args[args.index("--json") + 1]).write_text(text)
    print(text)
