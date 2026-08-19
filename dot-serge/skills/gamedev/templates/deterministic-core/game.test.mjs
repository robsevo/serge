// Headless regression test for the deterministic game core — no GPU, no window, $0.
// This is the "backtest before shipping" gate for game logic: if a change breaks
// determinism or the frozen known-answer, a bug was introduced.  node game.test.mjs
import assert from 'node:assert'
import { run, createGame, step, generateDungeon, mulberry32 } from './game.mjs'

let n = 0, fail = 0
const t = (name, fn) => { n++; try { fn(); console.log(`✓ ${name}`) } catch (e) { fail++; console.log(`✗ ${name}\n    ${e.message}`) } }

const SCRIPT = ['right','right','down','down','left','up','right','down','down','right','right','up','left','wait','down','right','right','down','left','up']

// 1. KNOWN-ANSWER regression — frozen seed + frozen inputs => frozen output.
t('known-answer: seed 42 signature is frozen', () => {
  assert.strictEqual(run(42, SCRIPT).signature, '42|20|0|6|4,2|false')
})

// 2. DETERMINISM — same seed + inputs => byte-identical run, every time.
t('determinism: identical runs', () => {
  assert.strictEqual(run(7, SCRIPT).signature, run(7, SCRIPT).signature)
  const a = generateDungeon(99), b = generateDungeon(99)
  assert.deepStrictEqual(a, b)
})

// 3. SEED SENSITIVITY — different seeds diverge (not a constant generator).
t('seed sensitivity: distinct dungeons', () => {
  assert.notDeepStrictEqual(generateDungeon(1), generateDungeon(2))
})

// 4. RANGE/VALIDATION — PRNG in [0,1), dungeon is bordered walls, spawn walkable.
t('range: prng in [0,1) and dungeon is well-formed', () => {
  const rng = mulberry32(123)
  for (let i = 0; i < 1000; i++) { const v = rng(); assert.ok(v >= 0 && v < 1) }
  const g = generateDungeon(5, 10, 8)
  assert.strictEqual(g.length, 8); assert.strictEqual(g[0].length, 10)
  for (let x = 0; x < 10; x++) { assert.strictEqual(g[0][x], 1); assert.strictEqual(g[7][x], 1) }
  assert.strictEqual(g[1][1], 0) // spawn walkable
})

// 5. RULES — walls block movement; wait advances tick without moving.
t('rules: walls block, wait is a no-move', () => {
  const s = createGame(42)
  const before = { ...s.player }
  step(s, 'up') // into the top border wall
  assert.deepStrictEqual(s.player, before, 'wall should block')
  const tick0 = s.tick
  step(s, 'wait')
  assert.strictEqual(s.tick, tick0 + 1); assert.deepStrictEqual(s.player, before)
})

// 6. EDGE — coin collection scores, all-coins-collected wins, done state is frozen.
t('edge: coin collect → score+win, done is terminal', () => {
  const s = { grid: [[1,1,1],[1,0,0],[1,1,1]], w: 3, h: 3, player: { x: 1, y: 1 }, coins: new Set(['2,1']), score: 0, tick: 0, done: false }
  step(s, 'right')
  assert.strictEqual(s.score, 1); assert.strictEqual(s.coins.size, 0); assert.strictEqual(s.done, true)
  const frozen = s.tick
  step(s, 'left') // stepping a done game is a no-op
  assert.strictEqual(s.tick, frozen); assert.strictEqual(s.player.x, 2)
})

console.log(`\n${fail === 0 ? `✓ ALL ${n} PASS` : `✗ ${fail}/${n} FAILED`}`)
process.exit(fail === 0 ? 0 : 1)
