---
name: backend
description: Backend engineering — HTTP/JSON APIs (FastAPI), real streaming (SSE, chunked, WebSocket, HLS/media relay) with a verifier that proves an endpoint actually streams instead of buffering, and data engineering at scale (Polars lazy frames, DuckDB over Parquet, larger-than-memory queries). Plus caching, background jobs, rate limiting, pagination, idempotency and failure semantics. Free stack, every capability proven by a live run.
whenToUse: Use whenever the work is server-side — building or reviewing an API/endpoint, request/response schemas, auth on a service, streaming anything (SSE, chunked HTTP, WebSockets, video/HLS/IPTV relay), background jobs/queues, caching, rate limits, pagination, retries/timeouts/idempotency, database or query work, or data pipelines and transforms (CSV/Parquet/JSON at any size, aggregations, joins, larger-than-memory). Also for diagnosing 5xx, slow endpoints, stalled or buffered streams, and data-integrity bugs. Pair with `datasci` when the deliverable is analysis/charts rather than a service or pipeline.
---

# Backend — APIs, streaming, data engineering

## Runtime (installed + verified 2026-07-21)
Python stack lives in **`~/.serge/office-venv/bin/python`** (deliberately reusing the existing
PATH-wired venv — a second venv on PATH causes shadowed imports):
`fastapi 0.139.2 · uvicorn 0.51.0 · httpx 0.28.1 · polars 1.43.0 · duckdb 1.5.4 · pydantic 2.13.4 ·
websockets 16.1.1 · sse-starlette 3.4.6`. Also on the box: `ffmpeg`, `sqlite3`, `uv`, `curl`.
Install more with `uv pip install --python ~/.serge/office-venv/bin/python <pkg>`.

## Streaming — and proving it actually streams

**The bug that ships constantly**: an endpoint builds its whole body, then flushes at the end. It
looks identical to a real stream in curl output and in any test that only asserts the final
payload. The difference is only visible in TIME.

```bash
~/.serge/office-venv/bin/python ~/.serge/skills/backend/stream_check.py <url> [--sse]
```
Measures per-chunk arrival: **TTFB**, **chunk count**, and **spread** (arrival window ÷ total;
~0 means one terminal burst = buffered). Exit 0 = genuinely streaming, 1 = buffered/broken.
Measured on the reference app: chunked → 8 chunks, spread 0.64 ✓ · SSE → 9 events, TTFB 43ms,
spread 0.94 ✓ · the deliberately-buffered endpoint → 1 chunk, spread 0.00 ✗ (correctly rejected).
`./test_streaming.sh` is the negative-controlled regression (4/4) — run it if you touch the checker.

Reference patterns: `templates/streaming_api.py` (chunked · SSE · backpressure · and a
`/BUFFERED-WRONG` endpoint kept deliberately broken as the negative control).

**Rules that matter in production:**
- **Yield as work completes.** Never accumulate into a list and return it — that is not a stream.
- **No `Content-Length`** on a stream (that forces buffering); let chunked encoding do its job.
- **SSE headers**: `Cache-Control: no-cache`, `X-Accel-Buffering: no` (nginx buffers by default and
  will silently destroy your stream), `Connection: keep-alive`. Frame format is `data: …\n\n`.
- **Backpressure**: honor client disconnect (`await request.is_disconnected()`), bound queues, and
  drop or coalesce rather than growing memory without limit. A slow consumer must not OOM the server.
- **Heartbeats** on long-lived SSE/WS (`: keep-alive\n\n` or a ping frame) — idle proxies kill
  connections at 30–60s.
- **Media/HLS relay**: stream through with `ffmpeg` piping to the response; never buffer a segment
  in memory; expose upstream failures as a clean 502 instead of a hung socket.

## APIs (FastAPI)
- **Schemas at the boundary** — pydantic models for request AND response; validation failures are
  explicit 422s, never silent coercion. Type the response (`response_model=`) so drift is caught.
- **Async correctness** — `async def` only when the work is genuinely awaitable; a blocking call
  inside an async handler stalls the whole event loop. CPU-bound work → threadpool/process.
- **Errors**: map domain failures to precise status codes (400 vs 401 vs 403 vs 404 vs 409 vs 422),
  return a machine-readable body (`{"error": {"code", "message"}}`), and never leak stack traces.
- **Idempotency** for anything that mutates money/state: accept an idempotency key, dedupe on it.
- **Pagination**: cursor-based (opaque, stable under inserts) over offset for anything that grows.
- **Timeouts everywhere** — every outbound call needs one (see the `resilient-external-calls` skill);
  an unbounded client call is how one slow dependency takes the whole service down.
- **Rate limiting** at the edge (token bucket per key), with `Retry-After` on 429.

## Data engineering (Polars + DuckDB)
Verified live on 500k rows: Polars lazy group-by **12.6 ms**, DuckDB over Parquet **6.0 ms**, and
the two agree exactly (cross-engine known-answer check — do this whenever a result matters).

- **Polars over pandas** for pipelines: use the **lazy** API (`.lazy()…collect()`) so the optimizer
  can push filters/projections down; `scan_parquet`/`scan_csv` streams from disk instead of loading.
- **DuckDB for SQL over files** — `read_parquet('*.parquet')` queries larger-than-memory data with
  no server and no ingest step. Ideal for ad-hoc aggregation over a data lake of files.
- **Parquet, not CSV**, for anything persisted: typed, columnar, compressed, ~10× faster to scan.
- **Cross-check aggregates** between engines (or against a slow reference) before trusting a number.
- **Fail loudly on data gaps** — never silently default a missing column/row to zero or a mean;
  raise with context. Silent defaults are how bad numbers reach production.
- **Determinism**: sort before writing, pin seeds for sampling, so a rerun is diffable.

## Caching, jobs, reliability
- Cache with an explicit key schema + TTL, and a documented invalidation trigger; a cache without an
  invalidation story is a correctness bug waiting to happen.
- Background work: a queue + idempotent workers + a dead-letter path. At-least-once delivery is the
  realistic default — so handlers must be safe to run twice.
- Retries need **jitter + a cap** and must only retry idempotent operations; retrying a non-idempotent
  write is how you double-charge someone.
- Health endpoints: `/health` (liveness, cheap) separate from readiness (checks dependencies).

## Complexity — the backend costs that are not CPU

Every handler is an algorithm over a collection that grows. Price it before you write it,
the same way you prove a stream actually streams — see the **`complexity`** skill for the
full method, the container cost table and the checker:

```bash
python3 ~/.serge/skills/complexity/algo_check.py all <file>   # bigo · bounds · fluff
```

- **N+1 is the number-one real backend complexity bug** — a query inside a loop. The cost
  is N × round trip, so no amount of tight code fixes it. One query with an `IN`/join, or a
  bulk endpoint. It is invisible in a code read and obvious to the checker.
- **Serial `await`** in a `for` loop is N × latency. Independent iterations → `asyncio.gather` /
  `Promise.all` with a **bounded** concurrency; sequential-by-necessity → say so in a comment.
- **A linear lookup inside a loop** (`x in list`, `.find`, `.includes`, a repeated query) is
  where nearly every accidental O(n²) comes from. Build the dict/set/Map index once, before
  the loop.
- **Unbounded is an availability bug**, not a perf nit: a fetch with no limit, a queue with
  no cap, a retry with no ceiling. Complexity in an attacker-controlled n is a DoS.
- **Per-request re-derivation** — parsing config, compiling a regex, rebuilding a lookup —
  belongs at module scope or in a cache with an explicit invalidation trigger.
- **State the shipped complexity** in the summary, and never one you did not check. The
  edit gate (`algo-gate.sh`) checks this automatically on every source edit, scoped to the
  lines that edit touched.

## Anti-patterns
- Calling an endpoint "streaming" without running `stream_check.py` on it.
- `SELECT *` into pandas to compute one aggregate (use DuckDB/Polars lazy).
- Unbounded queues, unbounded retries, unbounded client calls.
- Catching a broad exception and returning 200 with an error-shaped body.
- Claiming an endpoint is O(n) without running `algo_check.py bigo` on it.
- Shipping a loop without testing its three boundaries (empty, one, exactly at the limit).
