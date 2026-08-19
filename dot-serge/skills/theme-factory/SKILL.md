---
name: theme-factory
description: Ten ready-made professional color/font themes (palette hex codes + font pairings) to style any deliverable — slide decks, docs, reports, landing pages, dashboards — plus a recipe for generating a custom theme on the fly.
whenToUse: Use when styling or theming a deliverable — pptx/docx/pdf from the office skill, an HTML page or report, a dashboard — especially when the user asks for "a professional look", "make it match", "pick nice colors", or offers no design direction at all. For full bespoke design direction on product UI, use frontend-design instead; this is for fast, consistent, good-enough-by-default theming of documents and pages.
---

# Theme factory — pick a theme, apply it everywhere

Ten curated themes live in `themes/`, one file each: a 4-color palette with
hex codes, header/body font pairing, and what it's best used for.

| Theme | Feel |
|---|---|
| ocean-depths | professional, calming, maritime — corporate/finance decks |
| sunset-boulevard | warm, vibrant — creative pitches |
| forest-canopy | natural, grounded earth tones |
| modern-minimalist | clean contemporary grayscale |
| golden-hour | rich autumnal warmth |
| arctic-frost | cool, crisp, wintry |
| desert-rose | soft dusty sophistication |
| tech-innovation | bold modern tech |
| botanical-garden | fresh organic greens |
| midnight-galaxy | dramatic cosmic dark |

Process:

1. If the user hasn't chosen, offer 2-3 themes fitting the content's audience
   (one line each: name + feel). If they want to *see* them, build a quick
   single-file HTML swatch sheet from the theme files and open/show it.
2. Read the chosen theme's file from `themes/` and apply its colors and fonts
   consistently across the WHOLE deliverable — headings, body, accents,
   backgrounds — keeping contrast readable (dark palettes need light text).
3. None fit? Generate a custom theme in the same format (4 named hex colors +
   header/body fonts + best-used-for), name it in the same spirit, show it for
   a nod, then apply. Save it to `themes/` only if the user wants it kept.

Fonts are suggestions, not hard dependencies — when a listed face isn't
available in the output medium (office docs render with system fonts), swap
in the closest installed equivalent and say so.

---
*Themes from [anthropics/skills](https://github.com/anthropics/skills)
`theme-factory` (Apache-2.0 — see LICENSE.txt); SKILL.md rewritten for serge.*
