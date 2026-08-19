#!/usr/bin/env python3
"""Tests for steam_query.py — live keyless endpoints ($0, no key).

Contract: validation (bad input fails loudly), range (values sane), known-answer (stable facts
like TF2's appid/name), edge (free game has no price block), integration (search → app chain).
Network-dependent by design: this skill's whole value is live data, so a network failure is
reported as SKIP, never a silent pass.  python3 test_steam_query.py
"""
import json
import subprocess
import sys
import urllib.request
from pathlib import Path

CLI = str(Path(__file__).parent / "steam_query.py")
n = fail = skipped = 0


def net_up():
    try:
        urllib.request.urlopen("https://store.steampowered.com/api/appdetails?appids=440&filters=basic", timeout=15)
        return True
    except Exception:
        return False


def run(*args):
    return subprocess.run([sys.executable, CLI, *args], capture_output=True, text=True, timeout=60)


def t(name, fn):
    global n, fail
    n += 1
    try:
        fn()
        print(f"✓ {name}")
    except AssertionError as e:
        fail += 1
        print(f"✗ {name}\n    {e}")
    except Exception as e:
        fail += 1
        print(f"✗ {name}\n    {type(e).__name__}: {e}")


if not net_up():
    print("~ SKIP: no network to Steam (live-data skill; not a pass)")
    sys.exit(0)

# 1. KNOWN-ANSWER — TF2 (appid 440) is free and stably named.
def known_answer():
    r = run("app", "440")
    assert r.returncode == 0, r.stderr
    assert "Team Fortress 2" in r.stdout, r.stdout
    assert "Free" in r.stdout, r.stdout
t("known-answer: appid 440 → Team Fortress 2, Free", known_answer)

# 2. VALIDATION — bad appid fails loudly (non-zero + explicit message), never a silent default.
def validation_bad_appid():
    r = run("app", "999999999")
    assert r.returncode != 0, "expected non-zero exit for bad appid"
    assert "not found" in (r.stdout + r.stderr).lower(), (r.stdout + r.stderr)
t("validation: bad appid exits non-zero with a clear message", validation_bad_appid)

# 3. VALIDATION — unknown subcommand and missing arg both fail loudly.
def validation_bad_cmd():
    r = run("nonsense", "440")
    assert r.returncode != 0 and "unknown command" in (r.stdout + r.stderr).lower()
    r2 = run("app")
    assert r2.returncode != 0 and "needs an argument" in (r2.stdout + r2.stderr).lower()
t("validation: unknown command / missing arg fail loudly", validation_bad_cmd)

# 4. RANGE — player count is a non-negative int; review % within 0..100.
def range_checks():
    r = run("players", "440")
    assert r.returncode == 0, r.stderr
    num = int(r.stdout.split(":")[1].strip().replace(",", ""))
    assert 0 <= num < 5_000_000, f"implausible player count {num}"
    rv = run("reviews", "1145360")
    assert rv.returncode == 0, rv.stderr
    pct = float(rv.stdout.split("(")[1].split("%")[0])
    assert 0.0 <= pct <= 100.0, f"pct out of range: {pct}"
t("range: player count and review % are sane", range_checks)

# 5. EDGE — a free game reports Free (no price_overview block) and doesn't crash the formatter.
def edge_free_game():
    r = run("app", "440")
    assert r.returncode == 0 and "price       : Free" in r.stdout, r.stdout
t("edge: free game renders 'Free' rather than crashing on a missing price block", edge_free_game)

# 6. INTEGRATION — search returns an appid that then resolves via `app` (chained real calls).
def integration_search_then_app():
    s = run("search", "Team Fortress 2")
    assert s.returncode == 0 and s.stdout.strip(), s.stderr
    appid = s.stdout.strip().splitlines()[0].split()[0]
    assert appid.isdigit(), f"first search row had no appid: {s.stdout[:80]}"
    a = run("app", appid)
    assert a.returncode == 0 and "name" in a.stdout, a.stderr
t("integration: search → appid → app details chain works", integration_search_then_app)

print(f"\n{'✓ ALL %d PASS' % n if fail == 0 else '✗ %d/%d FAILED' % (fail, n)}")
sys.exit(0 if fail == 0 else 1)
