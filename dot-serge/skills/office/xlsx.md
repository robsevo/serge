# Spreadsheets — openpyxl + pandas

## Reading / understanding a sheet

- Quick look: `markitdown file.xlsx` → one markdown table per sheet. No cell
  coordinates — never plan an edit from this view alone.
- Analysis: `pandas.read_excel(path, sheet_name=None)` → dict of DataFrames
  (all sheets). Then describe(), groupby, pivot — real statistics, not eyeballing.
- Structure-faithful read: `openpyxl.load_workbook(path)`. THE core gotcha —
  formulas vs values are two different loads:
  - `data_only=False` (default): `cell.value` is the formula string `"=SUM(B2:B9)"`.
  - `data_only=True`: `cell.value` is the last CACHED result — which is `None`
    for any file that was written programmatically and never recalculated.
  To see both, load twice. To materialize values in a file you just wrote, run
  a recalc pass: `soffice --headless --convert-to xlsx --outdir /tmp/recalc file.xlsx`
  (LibreOffice recomputes on load/save), then read the converted copy.
- Merged ranges: only the top-left cell carries the value; the rest read `None`.
  Check `ws.merged_cells.ranges` before concluding data is missing.
- Huge files: `load_workbook(path, read_only=True)` streams; don't index cells
  randomly in that mode, iterate `ws.iter_rows()`.

## Creating / editing

- Edit in place: `wb = load_workbook(path)` → mutate → `wb.save(copy_path)`.
  Charts/images survive; pivot tables and VBA can be dropped — for .xlsm pass
  `keep_vba=True`, and always save to a COPY first, verify, then replace.
- Write formulas as plain strings: `ws["C2"] = "=A2*B2"`. They compute when
  opened in Excel/LibreOffice — but see the cached-value gotcha above if
  anything downstream reads the file programmatically.
- Numbers must be written as numbers, not strings — `ws["A1"] = "42"` produces
  the number-stored-as-text warning and breaks SUM ranges silently.
- Dates: write real `datetime` objects and give the cell a date `number_format`
  (e.g. `"yyyy-mm-dd"`); writing date-looking strings makes unusable text.
- Formatting: `from openpyxl.styles import Font, PatternFill, Alignment, Border, Side`;
  column width `ws.column_dimensions["B"].width = 18`; header freeze
  `ws.freeze_panes = "A2"`; money/percent via `cell.number_format`.
- Tables & charts: `openpyxl.worksheet.table.Table` for real Excel tables
  (gives filter arrows + structured refs); `openpyxl.chart` (BarChart,
  LineChart, PieChart) with `Reference` ranges for charts.
- Bulk data out: `df.to_excel(writer, sheet_name=..., index=False)` with
  `pd.ExcelWriter(path, engine="openpyxl")`; for appending to an existing
  workbook use `mode="a", if_sheet_exists="replace"`.

## CSV/TSV

pandas `read_csv` handles it; watch `encoding=` (try `utf-8-sig` when Excel
made the file) and `dtype=str` first when IDs must not lose leading zeros.

## Verify before reporting done

Re-open the saved file (`data_only` pass or markitdown) and confirm the shape:
row count, a spot-checked formula result after recalc, the sheet names. An
xlsx that "saved without error" can still be missing every computed value.
