# Slide decks — python-pptx

## Reading / extracting

- Text: `markitdown deck.pptx` → markdown per slide.
- Structured: `from pptx import Presentation; prs = Presentation(path)`; walk
  `slide.shapes`, take `shape.text_frame.text` where `shape.has_text_frame`;
  speaker notes at `slide.notes_slide.notes_text_frame.text` (guard
  `slide.has_notes_slide`).
- Visual check (layout bugs are invisible in text): convert and thumbnail —
  `soffice --headless --convert-to pdf --outdir DIR deck.pptx` then
  `pdftoppm -png -r 80 DIR/deck.pdf DIR/slide`. Look at the images before
  declaring a deck done — overlapping text boxes and off-slide shapes are the
  #1 generated-deck failure.

## Creating

- Geometry is in EMU — never raw ints: `from pptx.util import Inches, Pt, Emu`.
  Default deck is 4:3; for 16:9 set `prs.slide_width = Inches(13.333)`,
  `prs.slide_height = Inches(7.5)` BEFORE adding slides.
- Slides come from layouts: `prs.slide_layouts[i]` — in the default template
  0 = title, 1 = title+content, 6 = blank. Layout indexes differ per template;
  when starting from a company template, print
  `[l.name for l in prs.slide_layouts]` first instead of assuming.
- Fill placeholders via `slide.placeholders[idx]` (idx from the layout, not
  positional order); free-form text via
  `slide.shapes.add_textbox(left, top, width, height)`.
- There is NO real autofit at generation time (autofit needs a renderer). Set
  explicit `Pt` font sizes and box dimensions; budget ~6 bullets of ~8 words
  per content slide, else text walks off the slide.
- Images: `add_picture(path, left, top, height=Inches(3))` — one dimension
  keeps aspect. Charts: `add_chart` with `CategoryChartData` beats pasting a
  matplotlib PNG when the user may edit numbers later; use the PNG route when
  visual fidelity to an existing plot matters.

## Editing an existing deck

- Text/shape edits: open, mutate text frames, `prs.save(copy)`.
- Deleting or reordering slides has no public API — it's XML surgery on the
  `sldIdLst` element via `prs.slides._sldIdLst` (drop the `sldId` entry and
  the relationship). Do it on a copy and verify the deck still opens in
  LibreOffice (a broken relationship makes PowerPoint "repair" the file).
- Template-based generation (the common office ask): copy the .pptx template,
  open the copy, fill its placeholders — don't rebuild the brand deck from
  scratch.

Verify before reporting done: reopen the saved file, count slides, and for
anything layout-sensitive run the thumbnail pass above.
