# Word documents — python-docx

## Reading / extracting

- Quick text: `markitdown file.docx` → markdown to stdout.
- Structured: `from docx import Document; doc = Document(path)`. GOTCHA:
  `doc.paragraphs` covers only top-level body text — tables (`doc.tables`,
  then `cell.paragraphs`), headers/footers (`section.header`), and text boxes
  are separate trees. Walk all of them before claiming "the document says X".
- Legacy `.doc`: python-docx cannot open it — convert first:
  `soffice --headless --convert-to docx --outdir DIR file.doc`.

## Creating

- `Document()` starts from the built-in template; refer to styles by their
  built-in names only — `add_heading("Title", level=1)`,
  `add_paragraph(text, style="Normal")`, `add_table(rows, cols,
  style="Table Grid")`. Naming a style the template doesn't define raises
  KeyError at save-open time, not at call time.
- Sizes come from `docx.shared`: `Inches`, `Pt`, `Cm`, `RGBColor`. Images:
  `add_picture(path, width=Inches(5.5))` — give ONE dimension so aspect ratio
  is preserved.
- Page setup lives on `doc.sections[0]` (margins, orientation, page size);
  headers/footers on `section.header.paragraphs[0]` / `.footer`.
- Table of contents: python-docx can't generate one natively. Insert the TOC
  field XML (`w:fldSimple` with `TOC \\o "1-3" \\h \\z \\u` instr) — and tell
  the user the field populates on first open (F9 in Word); or skip fields and
  write an explicit list of headings.

## Editing an existing file

- python-docx opens and edits real files (paragraph text, runs, tables).
  THE find-replace gotcha: Word splits a sentence across multiple runs at
  arbitrary points (spellcheck marks, formatting flips), so
  `run.text.replace(old, new)` silently misses matches spanning runs. Robust
  pattern: if `old in paragraph.text`, rewrite at paragraph level — join the
  runs' text, replace, put the result in the first run (keeping its
  formatting) and blank the rest. Accept the formatting simplification or do
  run-boundary surgery only where it matters.
- Tracked changes / comments: beyond python-docx. A .docx is a ZIP of XML —
  `unzip` → edit `word/document.xml` (parse with `defusedxml`, mind the `w:`
  namespace) → re-zip. Work on a copy; a malformed namespace produces a file
  Word refuses to open.
- Always save edits to a copy, open the copy to verify, then replace the
  original.

## Converting

- docx → PDF: `soffice --headless --convert-to pdf --outdir DIR file.docx`.
  This is also the best "polished PDF report" pipeline: build the document
  with python-docx (real styles, headers, page numbers), then convert —
  easier than hand-laying-out the same report in reportlab.
