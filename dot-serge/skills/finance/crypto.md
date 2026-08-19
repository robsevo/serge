# Crypto / memecoins — on-chain due diligence

Run `token_eval.py MINT` first for any token ask (works on pump.fun launches,
Raydium/PumpSwap pairs, and EVM 0x tokens). Then interpret with this file.

## Sources ($0, no keys — all verified live)

| Source | Gives | Caveat |
|---|---|---|
| DexScreener API | price, pool composition, volume, buys/sells, FDV, pair age, all DEXes | aggregator; pre-launch bonding-curve tokens appear once trading |
| RugCheck API | mint/freeze authority, top holders with INSIDER graph clustering, LP lock %, risk list | Solana only; heuristic — treat as evidence, not verdict |
| Solana RPC (public) | supply, top-20 token accounts — raw chain truth | rate-limited; token accounts ≠ owners (LP vaults appear as holders) |
| GoPlus API | EVM honeypot/tax/mintable/pausable checks | EVM only; new contracts may be unscanned |
| Bubblemaps | the visual holder-cluster map | app is free to VIEW (link in tear sheet); its API is partner-only — the free clustering signal comes from rugcheck's insiderNetworks instead |

## "Is it bundled?" — what that means and how to read it

Bundled = the deployer split supply across many wallets funded from a common
source (often sniping their own launch in the same block), so "1,500 holders"
is really 12 people. Signals, strongest first:

1. `insider networks` + `insider-cluster %` in the tear sheet (rugcheck's
   funding-graph clustering — same idea as bubblemaps' linked bubbles).
2. Top-10 concentration excluding pools: >30% = one decision away from -80%.
3. Same-block or first-minute buys at launch (solscan the first txs of the
   pair when it matters).
4. Bubblemaps visual: interconnected bubble clusters around the deployer =
   the picture version of #1. Open the link from the tear sheet.

Clean signals do NOT mean organic — sophisticated bundlers fund through CEX
withdrawals which break the on-chain funding graph. Say so.

## The pool ("what's in the buy/sell pool, what's not")

- The pool line shows REAL exit capacity: `X TOKEN + Y SOL/USDC` — the quote
  side is all the money that can actually leave. FDV/mcap is a multiplication,
  not money; **liq/FDV < 2%** means the chart is theoretical.
- Supply NOT in the pool sits in wallets — that's overhang. Top-10 % is the
  measure of how much can hit the pool at once.
- LP locked/burned %: unlocked LP = the deployer can pull the quote side (the
  classic rug). On pump.fun the bonding curve holds liquidity pre-graduation
  (no LP to pull); the LP question starts AT graduation (~$69K mcap →
  PumpSwap/Raydium) — check lock status on the graduated pool.
- Price impact sanity: selling s% of supply into a pool holding p% of supply
  moves price roughly by 2·s/p (constant-product, small-trade approx) — a
  holder with 5% vs a pool with 2% is not an exit, it's a detonation.

## Pump.fun lifecycle specifics

curve launch (no LP-pull risk, but dev can dump their alloc) → graduation
~$69K mcap (curve liquidity migrates) → PumpSwap/Raydium pair (now LP lock,
concentration, and flow rules apply). `pump.fun lineage` in the tear sheet
means dexId history shows the curve. Dev/creator history: rugcheck's creator
field + their other tokens — a serial launcher with 40 dead tokens is the
base rate telling you the ending.

## Discipline (constitution register: direct, user decides)

- Flags are one-way evidence: any single ⚠ can justify "no"; zero ⚠ never
  justifies "safe" — memecoins are adversarial by construction.
- Numbers age in minutes here. Timestamp the eval, re-run before acting.
- Position framing: this class of asset is a lottery ticket with a shredder
  attached; size accordingly and say so plainly when asked for a read.
- Deeper digs: solscan.io for tx-level truth, the researcher agent for
  socials/dev-history narrative — the chain says what, the narrative says why.
