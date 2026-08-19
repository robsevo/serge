#!/usr/bin/env node
// Serge PLAYTEST harness — automated verification that a game actually plays, headlessly.
//
// Unit tests prove the rules; this proves the GAME: it boots, survives sustained random play
// without crashing or corrupting state, stays deterministic, and steps fast enough to hit frame
// budget. This is the "verify it works for real, not theater" gate from the gamedev skill —
// run it before calling any game feature done.
//
// Contract: the game module must export createGame(seed, opts) and step(state, input).
// Optional: INPUTS (array of valid inputs) — otherwise pass --inputs a,b,c.
//
//   node playtest.mjs <game-module.mjs> [--seeds 5] [--frames 2000] [--budget-us 50] [--inputs up,down]
//
// Exit 0 = shippable; 1 = a real failure (with the seed + frame to reproduce it).

import { pathToFileURL } from 'node:url'
import { resolve } from 'node:path'

const argv = process.argv.slice(2)
const opt = (n, d) => { const i = argv.indexOf(n); return i !== -1 && argv[i + 1] ? argv[i + 1] : d }
const modPath = argv.find(a => !a.startsWith('--') && (argv.indexOf(a) === 0 || !argv[argv.indexOf(a) - 1]?.startsWith('--')))
if (!modPath) { console.error('usage: playtest.mjs <game-module.mjs> [--seeds N] [--frames N] [--budget-us N] [--inputs a,b]'); process.exit(2) }

const SEEDS = parseInt(opt('--seeds', '5'), 10)
const FRAMES = parseInt(opt('--frames', '2000'), 10)
const BUDGET_US = parseFloat(opt('--budget-us', '50'))   // per-step budget in microseconds
const mod = await import(pathToFileURL(resolve(modPath)).href)

if (typeof mod.createGame !== 'function' || typeof mod.step !== 'function') {
  console.error('playtest: module must export createGame(seed, opts) and step(state, input)')
  process.exit(2)
}
const INPUTS = (opt('--inputs', '') || '').split(',').filter(Boolean).length
  ? opt('--inputs', '').split(',').filter(Boolean)
  : (mod.INPUTS || Object.keys(mod.DIRS || {}))
if (!INPUTS.length) { console.error('playtest: no inputs — export INPUTS/DIRS or pass --inputs'); process.exit(2) }

let failures = 0
const fail = (name, detail) => { failures++; console.log(`✗ ${name}\n    ${detail}`) }
const pass = name => console.log(`✓ ${name}`)

// Deterministic input picker so a failure is reproducible from (seed, frame).
function lcg(seed) { let s = seed >>> 0; return () => (s = (Math.imul(s, 1664525) + 1013904223) >>> 0) / 4294967296 }

// Recursively assert no NaN / undefined / Infinity leaked into numeric state.
function findBadNumber(o, path = '', depth = 0) {
  if (depth > 6 || o == null) return null
  if (typeof o === 'number') return Number.isFinite(o) ? null : `${path}=${o}`
  if (Array.isArray(o)) { for (let i = 0; i < o.length; i++) { const r = findBadNumber(o[i], `${path}[${i}]`, depth + 1); if (r) return r } return null }
  if (o instanceof Set || o instanceof Map) return null
  if (typeof o === 'object') { for (const k of Object.keys(o)) { const r = findBadNumber(o[k], path ? `${path}.${k}` : k, depth + 1); if (r) return r } return null }
  return null
}

// 1. BOOT SMOKE — every seed constructs a usable initial state.
{
  let bad = null
  for (let s = 1; s <= SEEDS && !bad; s++) {
    try {
      const st = mod.createGame(s)
      if (!st || typeof st !== 'object') bad = `seed ${s}: createGame returned ${typeof st}`
      else { const n = findBadNumber(st); if (n) bad = `seed ${s}: non-finite in initial state (${n})` }
    } catch (e) { bad = `seed ${s}: createGame threw ${e.message}` }
  }
  bad ? fail('boot smoke', bad) : pass(`boot smoke (${SEEDS} seeds construct cleanly)`)
}

// 2. SUSTAINED PLAY — random-but-reproducible input for N frames; no crash, no state corruption.
{
  let bad = null
  for (let s = 1; s <= SEEDS && !bad; s++) {
    const rnd = lcg(s * 7919)
    let st
    try { st = mod.createGame(s) } catch (e) { bad = `seed ${s}: ${e.message}`; break }
    for (let f = 0; f < FRAMES; f++) {
      const input = INPUTS[Math.floor(rnd() * INPUTS.length)]
      try { st = mod.step(st, input) ?? st } catch (e) { bad = `seed ${s} frame ${f} input=${input}: threw ${e.message}`; break }
      if (!st) { bad = `seed ${s} frame ${f}: step returned nullish`; break }
      if (f % 250 === 0) { const n = findBadNumber(st); if (n) { bad = `seed ${s} frame ${f}: non-finite state (${n})`; break } }
    }
  }
  bad ? fail('sustained play', bad) : pass(`sustained play (${SEEDS}×${FRAMES} frames, no crash / no NaN)`)
}

// 3. DETERMINISM — identical (seed, input tape) ⇒ identical final state. The regression tripwire.
{
  const sig = (s) => {
    const rnd = lcg(s * 7919); let st = mod.createGame(s)
    for (let f = 0; f < Math.min(FRAMES, 500); f++) st = mod.step(st, INPUTS[Math.floor(rnd() * INPUTS.length)]) ?? st
    return JSON.stringify(st, (k, v) => v instanceof Set ? [...v].sort() : v instanceof Map ? [...v] : v)
  }
  let bad = null
  for (let s = 1; s <= SEEDS && !bad; s++) if (sig(s) !== sig(s)) bad = `seed ${s}: two identical runs diverged`
  bad ? fail('determinism', bad) : pass(`determinism (${SEEDS} seeds reproduce exactly)`)
}

// 4. INPUT RESPONSE — the game reacts to input (a sim that ignores input is broken, not "stable").
{
  const st = mod.createGame(1)
  const before = JSON.stringify(st, (k, v) => v instanceof Set ? [...v].sort() : v)
  let changed = false
  for (const inp of INPUTS) {
    const s2 = mod.createGame(1)
    for (let i = 0; i < 5; i++) mod.step(s2, inp)
    if (JSON.stringify(s2, (k, v) => v instanceof Set ? [...v].sort() : v) !== before) { changed = true; break }
  }
  changed ? pass('input response (inputs measurably change state)') : fail('input response', 'no input changed state — sim ignores input')
}

// 5. PERF BUDGET — per-step cost must fit the frame budget at target rate.
{
  const rnd = lcg(31337); let st = mod.createGame(1)
  const N = Math.max(FRAMES, 2000)
  const t0 = process.hrtime.bigint()
  for (let f = 0; f < N; f++) st = mod.step(st, INPUTS[Math.floor(rnd() * INPUTS.length)]) ?? st
  const us = Number(process.hrtime.bigint() - t0) / 1000 / N
  const perFrame60 = (16666 / us).toFixed(0)
  us <= BUDGET_US
    ? pass(`perf budget (${us.toFixed(2)}µs/step ≤ ${BUDGET_US}µs — ~${perFrame60} steps per 60fps frame)`)
    : fail('perf budget', `${us.toFixed(2)}µs/step exceeds ${BUDGET_US}µs budget`)
}

console.log(`\n${failures === 0 ? '✓ PLAYTEST PASSED — game is shippable' : `✗ PLAYTEST FAILED (${failures})`}`)
process.exit(failures === 0 ? 0 : 1)
