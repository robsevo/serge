---
name: office
description: Create, read, edit, and convert office documents — Excel spreadsheets (.xlsx/.csv), Word documents (.docx), PowerPoint decks (.pptx), and PDFs (create, merge, split, fill forms, extract text/tables). All local, deterministic, $0.
whenToUse: Use whenever a spreadsheet, document, deck, or PDF file is the input or the deliverable — the user mentions .xlsx/.csv/.docx/.pptx/.pdf, "spreadsheet", "Excel", "Word doc", "report as a file", "slides", "deck", "presentation", "PDF", "invoice", "form", or asks to convert between these formats. Do NOT use when the deliverable is code, a web page, or plain markdown.
---

# Office documents — the serge toolchain

Everything runs on the dedicated venv at `~/.serge/office-venv` (its `bin` is on
PATH in serge sessions, so plain `python3` and `markitdown` resolve to it) plus
two system tools: `soffice` (LibreOffice headless — format conversion and
formula recalc) and `pdftoppm` (PDF → images). All open-source, CPU-only, no
network. If an import fails, check the venv exists before debugging further:
`~/.serge/office-venv/bin/python -c "import openpyxl"`.

## Route by task

| Task | Tool | Detail file |
|---|---|---|
| Spreadsheets: read, analyze, create, edit, formulas, charts | `openpyxl` / `pandas` | read `xlsx.md` in this skill dir |
| Word documents: create, edit, extract | `python-docx` | read `docx.md` |
| Slide decks: create, edit, extract | `python-pptx` | read `pptx.md` |
| PDFs: create, merge/split, forms, extract text/tables | `reportlab` / `pypdf` / `pdfplumber` | read `pdf.md` |
| Quick "what's in this file?" look (xlsx/docx/pptx) | `markitdown file.ext` → markdown to stdout | — |
| Convert anything → PDF (or xlsx→csv, docx→txt…) | `soffice --headless --convert-to pdf --outdir DIR FILE` | — |

Before writing any generation/edit script, READ the detail file for that format
— each holds the gotchas that produce corrupt or wrong files when missed
(formula caching, XML namespaces, EMU coordinates, form-field quirks).

## Ground rules

- Deliverables are files on disk in the user's cwd (or where they asked), never
  inline dumps; report the absolute path when done.
- After creating or editing a file, VERIFY it: re-open it with the reading tool
  for that format (or `markitdown` it) and confirm the content landed — a
  script that exits 0 has not proven the document is right.
- Edits to an existing file work on a copy until verified, then replace the
  original — never corrupt the only copy.
- `soffice` runs one instance at a time — serialize conversions; a hung
  conversion usually means a stale LibreOffice lock (`~/.config/libreoffice/*/.lock`).
- Scanned-PDF OCR is NOT installed (no tesseract). Say so plainly if asked;
  text extraction works only on digital PDFs.
