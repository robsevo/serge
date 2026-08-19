---
name: steam
description: Ship games to Steam and research the Steam market — Steamworks app/depot setup, steamcmd build upload, build manifests (VDF), achievements/stats/cloud, store-page requirements and launch checklist, plus keyless Steam Web/Store API queries (price, reviews, live player counts, news, search, competitive comparisons). Free tooling and keyless endpoints only; every number comes from a live API call.
whenToUse: Use whenever the task involves Steam — publishing or uploading a build, Steamworks/partner setup, depots, app builds, achievements, store page assets/requirements, launch or release checklists, Steam keys, or researching Steam games (price, player counts, reviews, genre/competition, "how is X doing on Steam", market research for a game idea). Pair with the `gamedev` skill for building the game itself.
---

# Steam — publish games, research the market

## What runs here right now (honest status)
- **Steam Web/Store API: WORKING, keyless** — verified live 2026-07-21 (Hades 98% of 283,511
  reviews; TF2 46,085 concurrent). Use `steam_query.py` below. No API key, no login, $0.
- **steamcmd: NOT installed.** It is a 32-bit binary and this Arch box has **no 32-bit loader**
  (`/lib/ld-linux.so.2` absent). Installing needs root: `sudo pacman -S --needed lib32-gcc-libs`
  then the tarball (below). Ask the user before any system install — don't assume sudo.
- **Uploading a build additionally requires a real Steamworks account** (a paid $100 app fee per
  title, Valve-side) — that is a business prerequisite Serge cannot create. Say so plainly rather
  than implying a build can be shipped for free from this box.

## Market research — `steam_query.py` ($0, keyless, live)

```bash
python3 ~/.serge/skills/steam/steam_query.py app 1145360      # name, price, discount, genres, dev/pub
python3 ~/.serge/skills/steam/steam_query.py players 440      # concurrent players right now
python3 ~/.serge/skills/steam/steam_query.py reviews 1145360  # total, % positive, score band
python3 ~/.serge/skills/steam/steam_query.py news 440 3       # latest news items
python3 ~/.serge/skills/steam/steam_query.py search "roguelite"   # name → appid lookup
python3 ~/.serge/skills/steam/steam_query.py compare 440,1145360  # side-by-side table
```

**Verified endpoints** (keyless): `store.../api/appdetails`, `store.../appreviews/<appid>?json=1`,
`api.../ISteamUserStats/GetNumberOfCurrentPlayers/v1/`, `api.../ISteamNews/GetNewsForApp/v2/`,
`store.../api/storesearch/`, `store.../api/featured/`.
**Does NOT work — do not guess at it**: `ISteamApps/GetAppList` returns **404** ("Method not found").
Endpoints needing a key (`ISteamUser/*`, `GetOwnedGames`, most `IPlayerService/*`) are out of scope
for keyless use — say so rather than inventing numbers.

Use it for real competitive analysis before building: what a genre's games charge, how many
reviews winners have, whether a niche has live players. Every claim traceable to a live call.

## Publishing pipeline (Steamworks)

1. **App setup** (partner.steamgames.com) — create the app, get the **AppID**, set store page,
   age rating, tags, capsule art. Depot IDs are usually `AppID+1` (content), one per platform.
2. **Install steamcmd** (needs the 32-bit loader, see above):
   ```bash
   sudo pacman -S --needed lib32-gcc-libs        # Arch prerequisite (ask the user first)
   mkdir -p ~/steamcmd && cd ~/steamcmd
   curl -sL https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz | tar zx
   ./steamcmd.sh +quit                            # self-updates on first run
   ```
3. **Build manifest** (VDF) — `app_build_<AppID>.vdf` + a depot file. Minimal shape:
   ```
   "appbuild" {
     "appid" "480"
     "desc"  "serge build"           // shows in the Steamworks build list
     "buildoutput" "output/"          // logs + chunk cache (gitignore this)
     "contentroot" "content/"         // where your exported game files live
     "setlive"  ""                    // NEVER auto-set-live; promote in the web UI after QA
     "depots" { "481" "depot_481.vdf" }
   }
   ```
   `depot_481.vdf` maps files in: `"FileMapping" { "LocalPath" "*" "DepotPath" "." "recursive" "1" }`
   plus `"FileExclusion"` lines for `*.pdb`, `.DS_Store`, source, etc.
4. **Upload**:
   ```bash
   ./steamcmd.sh +login <user> +run_app_build ../app_build_480.vdf +quit
   ```
   Use a **build account** with 2FA, never the primary; Steam Guard will prompt on first login.
5. **Promote** the build to a branch in the Steamworks UI (keep `setlive` empty in the VDF so a
   bad build can never go straight to `default`).

## Store page / launch checklist (what actually gates release)
- Capsule art at every required size, ≥5 screenshots, a trailer; short + long description.
- System requirements, supported languages, tags/genres, content survey + age rating.
- **Coming Soon page live ≥2 weeks before launch** (wishlists drive Valve's visibility).
- Build on `default` branch, tested from a fresh install; EULA if needed; pricing per region.
- Achievements/stats defined in Steamworks *before* they can be unlocked in-game.

## Steamworks SDK integration (in-game)
Achievements/stats/cloud/overlay need the **Steamworks SDK**: Godot → GodotSteam (GDExtension);
Rust/Bevy → `steamworks` crate; web/Electron → `steamworks.js`. Guard every call — the game must
run and be testable **without** Steam running (that's what keeps the headless tests from the
`gamedev` skill working). Ship a no-op stub when the API is unavailable; never hard-crash.

## Free alternatives worth naming
**itch.io** — free to publish, no $100 fee, `butler` CLI (`butler push build/ user/game:linux`)
is the fastest real distribution path from this box, and a legitimate launch platform for a first
title. Recommend it when the user wants to ship *now* without Steamworks onboarding.

## Anti-patterns
- Claiming a build "shipped" without a real steamcmd upload + a Steamworks build number.
- `setlive` in the VDF to auto-promote — one bad build hits every player.
- Quoting Steam numbers from memory: run `steam_query.py`; prices/players change daily.
- Assuming sudo. Installing 32-bit libs is a system change — ask.
