# Presenting — charts, tables, assembled reports

## Matplotlib defaults that look professional

```python
import matplotlib
matplotlib.use("Agg")          # headless box — always
import matplotlib.pyplot as plt
plt.rcParams.update({
    "figure.figsize": (10, 5.5), "figure.dpi": 150,
    "axes.spines.top": False, "axes.spines.right": False,
    "axes.grid": True, "grid.alpha": 0.25,
    "axes.titlesize": 13, "axes.titleweight": "bold",
    "font.size": 10.5,
})
fig.savefig(path, bbox_inches="tight")
```

- Title = the FINDING ("Revenue growth stalled in Q3"), not the variable
  name; axis labels carry units; caption/footnote carries source + as-of
  date + n. A chart that needs the surrounding text to be understood isn't
  done.
- Chart choice: time → line; comparison across categories → horizontal bar
  (sorted by value, not alphabet); distribution → histogram/box; relationship
  → scatter (+ trend line only if defensible); composition → stacked bar
  (pie only for ≤3 slices, and reluctantly).
- One message per chart. If a chart needs a paragraph of caveats, split it.
- Don't fabricate axis ranges: bar charts start at 0; truncated axes get an
  explicit break marker and a note.
- Color: one series = one color; highlight THE series, grey the context ones.

## Tables

- Small (≤10×6): render in the chat/report as aligned text.
- Bigger or user-facing: write xlsx via the office skill (frozen header,
  number formats, column widths — see office/xlsx.md); numbers right-aligned,
  human units (4.2M), consistent decimals.

## Assembled reports ("put it together")

Deliverable shapes, by ask:
- **Quick read** → chat: finding first, 1-2 charts saved as PNG (report the
  paths), tight prose interpretation.
- **Document** → office skill: .docx (headings, embedded PNGs via
  `add_picture`, tables) → optional PDF via soffice. Structure: Answer →
  Evidence (charts+tables) → Method & caveats → Appendix (data source,
  script path, fetch timestamp).
- **Workbook** → xlsx: Data sheet (raw), Analysis sheet (pivots/formulas),
  Summary sheet (the read) — analysts want to touch the numbers.

Method section is mandatory in any report: source, fetch date, n, what was
dropped and why, and where the script lives. The reader must be able to
distrust you efficiently.
