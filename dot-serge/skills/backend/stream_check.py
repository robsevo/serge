#!/usr/bin/env python3
"""Prove an HTTP endpoint ACTUALLY streams — the check almost nobody runs.

A "streaming" endpoint that buffers its whole body and flushes at the end looks identical to a
real stream in curl output and in tests that only assert the final payload. It is only
distinguishable in TIME: a real stream delivers chunks incrementally, so inter-arrival gaps are
spread out; a buffered one delivers everything in one burst at the end.

This measures per-chunk arrival times and asserts genuine incremental delivery:
  - TTFB          — first byte arrives quickly (not after the whole body is built)
  - spread        — arrivals are distributed, not one terminal burst
  - chunk count   — the expected number of chunks/events actually arrived
  - termination   — the stream ends cleanly (no hang, no truncation)

Usage:
  stream_check.py <url> [--min-chunks 3] [--ttfb-ms 1500] [--spread 0.4] [--timeout 30] [--sse]

Exit 0 = genuinely streaming; 1 = buffered/broken (with the measured evidence).
"""
import argparse
import sys
import time

import httpx


def measure(url: str, timeout: float, sse: bool):
    """Return (chunk_times, total_elapsed, body_len, status). Times are seconds since request start."""
    times, body_len = [], 0
    t0 = time.perf_counter()
    status = None
    with httpx.Client(timeout=httpx.Timeout(timeout)) as c:
        with c.stream("GET", url) as r:
            status = r.status_code
            r.raise_for_status()
            if sse:
                for line in r.iter_lines():
                    if not line or not line.strip():
                        continue  # SSE keep-alive / separator
                    times.append(time.perf_counter() - t0)
                    body_len += len(line)
            else:
                for chunk in r.iter_bytes():
                    if not chunk:
                        continue
                    times.append(time.perf_counter() - t0)
                    body_len += len(chunk)
    return times, time.perf_counter() - t0, body_len, status


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("url")
    ap.add_argument("--min-chunks", type=int, default=3)
    ap.add_argument("--ttfb-ms", type=float, default=1500.0)
    # spread = (last_arrival - first_arrival) / total. Near 0 ⇒ one terminal burst (buffered).
    ap.add_argument("--spread", type=float, default=0.4)
    ap.add_argument("--timeout", type=float, default=30.0)
    ap.add_argument("--sse", action="store_true", help="parse as SSE lines instead of raw bytes")
    a = ap.parse_args()

    try:
        times, total, body_len, status = measure(a.url, a.timeout, a.sse)
    except Exception as e:  # fail loudly with context
        print(f"✗ stream_check: request failed — {type(e).__name__}: {e}")
        return 1

    if not times:
        print(f"✗ no chunks received (status={status}, body={body_len}B)")
        return 1

    ttfb_ms = times[0] * 1000
    spread = (times[-1] - times[0]) / total if total > 0 else 0.0
    fails = []

    print(f"  status      : {status}")
    print(f"  chunks      : {len(times)}")
    print(f"  bytes       : {body_len}")
    print(f"  ttfb        : {ttfb_ms:.0f} ms")
    print(f"  total       : {total*1000:.0f} ms")
    print(f"  spread      : {spread:.2f}  (arrival window / total; ~0 = buffered burst)")

    if len(times) < a.min_chunks:
        fails.append(f"only {len(times)} chunks (want ≥{a.min_chunks}) — endpoint may be buffering into one body")
    if ttfb_ms > a.ttfb_ms:
        fails.append(f"TTFB {ttfb_ms:.0f}ms > {a.ttfb_ms:.0f}ms — body built before sending (not streaming)")
    if spread < a.spread:
        fails.append(f"spread {spread:.2f} < {a.spread} — chunks arrived in one terminal burst (buffered)")

    if fails:
        print("\n✗ NOT STREAMING:")
        for f in fails:
            print(f"    - {f}")
        return 1
    print("\n✓ GENUINELY STREAMING (incremental delivery confirmed)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
