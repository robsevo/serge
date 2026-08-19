# PDFs — pypdf, pdfplumber, reportlab

## Extracting

- Text, layout-aware: `pdfplumber.open(path)` → `page.extract_text()`;
  TABLES: `page.extract_tables()` (returns rows of cells — feed to pandas).
  pdfplumber beats pypdf for anything where column/table structure matters.
- Fast plain text: `pypdf.PdfReader(path)` → `page.extract_text()`.
- A scanned PDF yields empty/garbage text from both — that needs OCR, which
  is NOT installed (no tesseract). Say so honestly; offer the page-image
  route (`pdftoppm -png -r 150 file.pdf out`) so at least the vision seat can
  look at pages.

## Assembling / transforming (pypdf)

- Merge: `writer = PdfWriter()`; `writer.append(path)` per input; write once.
- Split / reorder: `writer.add_page(reader.pages[i])` for the pages you keep.
- Rotate: `reader.pages[i].rotate(90)` then add to writer.
- Watermark/stamp: build a one-page overlay PDF with reportlab, then
  `page.merge_page(overlay_page)` on each target page.
- Encrypt: `writer.encrypt(user_password)`; decrypt by constructing
  `PdfReader(path)` and calling `reader.decrypt(pw)` before reading.

## Forms (the fiddly one)

- Inspect first: `reader.get_fields()` — real names, types, and for
  checkboxes the legal "on" state. Checkbox values are NOT the literal string
  "Yes"/"X": use the state name from the field's appearance dict (often
  `/Yes`, sometimes `/On` or `/1`), passed as e.g. `"/Yes"`.
- Fill: `writer.append(reader)` then
  `writer.update_page_form_field_values(writer.pages[i], {name: value},
  auto_regenerate=False)`.
- Set NeedAppearances or many viewers show blank fields despite the data
  being there: `writer.set_need_appearances_writer(True)` (older pypdf:
  set the `/NeedAppearances` bool on the AcroForm dict manually).
- Flatten (make fill-ins permanent/uneditable): merge the filled PDF's pages
  onto themselves via the overlay trick, or convert through
  `soffice --headless --convert-to pdf` as a last resort.
- Verify a fill by re-reading `get_fields()` on the OUTPUT file — not by
  trusting the write.

## Creating from scratch (reportlab)

- Documents (reports, invoices, letters): use platypus, not the raw canvas —
  `SimpleDocTemplate(path, pagesize=A4)` + flowables (`Paragraph(text,
  styles["..."])` from `getSampleStyleSheet()`, `Table(data)` +
  `TableStyle`, `Spacer`, `Image`). Repeating headers/footers/page numbers go
  in `onPage` callbacks passed to `build()`.
- Raw `canvas.Canvas` only for absolute-position work (stamps, labels,
  certificates).
- UNICODE gotcha: the built-in Helvetica/Times fonts are Latin-1 only —
  accented text beyond Latin-1, Cyrillic, CJK, or the € sign render as black
  boxes. Register a TTF first (`pdfmetrics.registerFont(TTFont("DejaVu",
  "/usr/share/fonts/TTF/DejaVuSans.ttf"))`) and use it in the styles.
- Text-heavy polished documents are often better built as .docx (python-docx
  styles) then converted: `soffice --headless --convert-to pdf` — see docx.md.

Verify before reporting done: re-open the produced PDF (pdfplumber page count
+ spot-check text, or thumbnail via pdftoppm) — zero-byte and single-blank-
page outputs are the classic silent failures.
