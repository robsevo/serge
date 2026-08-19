#!/usr/bin/env python3
"""Reference streaming API — correct patterns, plus deliberately-wrong ones for verification.

Run:  ~/.serge/office-venv/bin/python streaming_api.py [port]
Then: stream_check.py http://127.0.0.1:<port>/stream/chunked
      stream_check.py http://127.0.0.1:<port>/stream/sse --sse
      stream_check.py http://127.0.0.1:<port>/stream/BUFFERED-WRONG   # must FAIL

The /BUFFERED-WRONG endpoint is the negative control: it looks like a stream in the code and in
final output, but builds the whole body first. If stream_check ever passes it, the checker is
broken. Real bugs of exactly this shape ship constantly.
"""
import asyncio
import json
import sys

from fastapi import FastAPI
from fastapi.responses import StreamingResponse, JSONResponse

app = FastAPI(title="serge streaming reference")

N = 8
DELAY = 0.08


@app.get("/health")
async def health():
    return {"ok": True}


# ---- CORRECT: chunked transfer, yields incrementally -------------------------------------
@app.get("/stream/chunked")
async def chunked():
    async def gen():
        for i in range(N):
            # Yield as work completes — never accumulate then return.
            yield f"chunk {i}\n".encode()
            await asyncio.sleep(DELAY)
    # No Content-Length ⇒ chunked transfer-encoding ⇒ the client can consume progressively.
    return StreamingResponse(gen(), media_type="text/plain")


# ---- CORRECT: SSE (server-sent events) ---------------------------------------------------
@app.get("/stream/sse")
async def sse():
    async def gen():
        for i in range(N):
            # SSE frame: "data: <payload>\n\n". Keep payloads small and flush per event.
            yield f"data: {json.dumps({'i': i, 'msg': f'event {i}'})}\n\n"
            await asyncio.sleep(DELAY)
        yield "data: [DONE]\n\n"
    return StreamingResponse(gen(), media_type="text/event-stream", headers={
        "Cache-Control": "no-cache",      # proxies must not buffer/cache an event stream
        "X-Accel-Buffering": "no",        # nginx: disable response buffering
        "Connection": "keep-alive",
    })


# ---- CORRECT: backpressure-aware — stops promptly when the client disconnects -------------
@app.get("/stream/backpressure")
async def backpressure(request_timeout: float = 0.05):
    async def gen():
        i = 0
        while i < N:
            yield f"tick {i}\n".encode()
            await asyncio.sleep(request_timeout)
            i += 1
    return StreamingResponse(gen(), media_type="text/plain")


# ---- WRONG (negative control): builds the entire body, then sends it in one burst ---------
@app.get("/stream/BUFFERED-WRONG")
async def buffered_wrong():
    parts = []
    for i in range(N):
        parts.append(f"chunk {i}\n")
        await asyncio.sleep(DELAY)      # work happens BEFORE anything is sent
    return JSONResponse(content={"body": "".join(parts)})


if __name__ == "__main__":
    import uvicorn
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8077
    uvicorn.run(app, host="127.0.0.1", port=port, log_level="warning")
