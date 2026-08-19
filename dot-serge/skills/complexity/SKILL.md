---
name: complexity
description: Deterministic cost + correctness analyzer for backend code (algo_check.py — per-function Big-O with the evidence chain that produced it, off-by-one and boundary-slip detection including the same-operand `>` vs `>=` differential, and dead-weight measured in removable lines) plus the complexity-budget workflow, the container cost table, and the three-boundary checklist. Evidence-grounded — a model must not price its own algorithm by inspection any more than it may hand-evaluate a boolean.
whenToUse: Use whenever writing or reviewing anything with a loop, a lookup, a query, or recursion — endpoints and handlers, list/aggregate/join code, parsers, schedulers, batch jobs, anything over a collection that grows. Also for diagnosing a slow endpoint, a job that got slower with data volume, an N+1, a timeout under load, or a result that is wrong at exactly the boundary (first element, last element, empty input). And whenever the ask is to simplify, slim down, or delete code — `fluff` turns "this is bloated" into a line count.
---

# Complexity — price it, don't estimate it

## The rule (evidence, not vibes)

Two properties of model-written code drive this skill, and neither is fixed by care:

- **It carries more defects than human-written code**, concentrated in slips that read
  correctly: `>` where `>=` belongs, `<= arr.length`, an index shifted by one, a loop
  that never advances, a `catch` that eats the error it should raise. These survive
  self-review precisely because reviewing your own diff re-reads the intent you already
  had. A checker does not share the intent.
- **It is bulkier for the same behavior**, and bulk is not cosmetic — it is extra passes,
  extra copies, work re-derived inside loops, and N round trips where one would do.

So the same split the `logic` skill is built on applies here: **you write the code, the
tool prices it.** Never state a complexity you did not check, and never call an edit a
simplification without a line count.

```
python3 ~/.serge/skills/complexity/algo_check.py bigo   <file>...   # cost per function + evidence
python3 ~/.serge/skills/complexity/algo_check.py bounds <file>...   # off-by-one / boundary slips
python3 ~/.serge/skills/complexity/algo_check.py fluff  <file>...   # dead weight, in removable lines
python3 ~/.serge/skills/complexity/algo_check.py all    <file>...
```
Options: `--lines A-B,C-D` (report only these lines), `--min-sev certain|high|medium|low`
(default medium), `--json`, `--quiet`. Exit 0 = clean, 2 = findings, 1 = bad usage.
Python is parsed with the real `ast`; JS/TS/JSX/TSX with a comment/string/template/regex
-aware masker. Stdlib only, no network, ~16 ms per file.

**Cost propagates through calls.** A linear helper called *inside a loop* is O(n²) even
though neither function is quadratic alone — the single most common way real quadratic
behavior hides, because reading either function on its own shows nothing wrong:

```
enrichAll — est. O(n²)  [loop@7 over `orders` (O(n)) × calls `findUser()`@8 which is O(n)]
```

Pass several files in one run and this resolves **across** them. A call made *once* is
deliberately not propagated: it creates no new cost, and reporting it would name every
caller in the transitive closure instead of the one loop that is actually the problem.
A name defined twice in the analysed set does not resolve at all.

**It is already wired — you do not have to remember to run it.** `algo-gate.sh` fires on
every `Edit`/`Write`/`MultiEdit` of a source file, checks **only the lines that edit
touched**, and blocks the turn on a `bounds` or `bigo` finding. It also passes the edited
file's siblings as context, so a call out of the file resolves (~0.7s on a 450-file
directory). `complexity-directive.sh` injects the budget procedure on algorithm-shaped and
build-shaped prompts. Run the checker by hand for the whole-file or whole-package picture.

**What it cannot do.** The complexity is a *syntactic estimate* over loop structure and
known container costs — not a proof. It assumes a loop over a collection is O(n) unless it
can see the collection is a fixed literal; a runtime-bounded collection (`items.slice(0, 10)`)
still reads as n. It resolves calls by NAME, so a dynamic dispatch, a method on an object,
or a callee outside the analysed set is invisible. Past O(n⁴) it stops publishing an exact
exponent and says "or worse", because the exponent is no longer defensible — the nesting is
the finding, not the number. Every verdict prints the evidence chain that produced it, so
check the chain in one read. If it is wrong, say so in one line and move on; a tool you
cannot overrule is a tool that makes you stupid.

## The complexity budget — before the loop, not after

1. **Name n.** What actually grows: rows, users, files, requests — and its realistic
   size. This decides everything. O(n²) over 20 config entries is correct and simple;
   over 100k rows it is an outage. State the number.
2. **State the target and the naive cost** in one line before coding —
   `target O(n log n); the obvious nested scan is O(n²)`.
3. **Name the structure that buys it.** Almost every accidental O(n²) is one shape: a
   linear lookup inside a loop. Pre-index once, look up in O(1).
4. **Count round trips separately from CPU.** On a backend this usually dominates: a
   query or `await` inside a loop is N × RTT regardless of how tight the code is.
5. **Check the three boundaries** on every loop — empty, exactly one, exactly at the
   limit. The third is where off-by-one lives.
6. **Run the checker and cite it.** Not "this is O(n)" — `algo_check bigo` says so.

## Getting a BETTER algorithm (not a patch)

When the cost is too high, the reflex is to patch — add a cache, add an early return,
add a guard — and those leave the exponent exactly where it was. A memoising cache in
front of a linear scan is still O(n²) when the keys are distinct; that exact "fix" was
observed live, declared as "O(n) performance", and was not. **The exponent only moves
when the algorithm changes.** Deliberate in four lines before touching the code:

1. **n** — what actually grows, and its realistic size.
2. **now** — the current complexity, and *where* it comes from (a line, not a feeling).
3. **target** — the best this problem allows, and the technique that reaches it:

| The shape you have | The move | Gets you |
|---|---|---|
| lookup / membership inside a loop | build a dict/set/Map **once**, then O(1) lookups | O(n·m) → O(n+m) |
| pairs, duplicates, "closest", ordering | sort once, then ONE linear pass / two pointers | O(n²) → O(n log n) |
| contiguous run, "best window", running condition | sliding window / two pointers | O(n²) → O(n) |
| repeated range aggregate | prefix sums computed once | O(n) per query → O(1) |
| top-k of many | heap of size k | O(n log n) → O(n log k) |
| recursion with overlapping subproblems | memoise, or bottom-up DP | O(2ⁿ) → polynomial |
| grouping / connectivity | union-find, or one grouping pass | O(n²) → ~O(n) |
| a query or request per item | ONE batched query (IN/join) or a bulk call | N round trips → 1 |
| independent awaits in sequence | `Promise.all` / `asyncio.gather`, **bounded** | N×RTT → ~1×RTT |
| loop-invariant work (sort, regex compile, index build) | hoist it above the loop | ×n → ×1 |
| only need existence / the first hit | early exit, short-circuit | full scan → expected O(1) |

4. **implement that**, re-run the checker, and quote the new line. If the exponent did
   not drop, you patched it — say so and go back to step 3.

Two honest cases where the answer is "leave it": n is genuinely small and bounded (say
so, with the bound), or the lower bound is already met — comparison sorting cannot beat
O(n log n), and you must read every element at least once. Naming the lower bound is a
complete answer; guessing is not.

## Container costs — the table that prevents most of it

| Operation | Python | JS/TS | Note |
|---|---|---|---|
| membership | `set`/`dict` **O(1)** · `list` **O(n)** | `Set`/`Map` **O(1)** · `Array.includes/indexOf/find` **O(n)** | the single biggest source of accidental O(n²) |
| index by key | `dict[k]` O(1) | `Map.get` O(1) · `obj[k]` O(1) | build the index ONCE before the loop |
| append | `list.append` O(1) | `arr.push` O(1) | — |
| prepend / pop front | `list.insert(0,…)`/`pop(0)` **O(n)** → use `collections.deque` | `unshift`/`shift`/`splice(0,…)` **O(n)** | O(n²) when done in a loop |
| accumulate | `s += str` in a loop **O(n²)** → build a list, `"".join` | `[...acc, x]` / `{...acc}` in a `reduce` **O(n²)** → `push`, or mutate one object | the canonical bloat-becomes-slow pattern |
| sort | `sorted` O(n log n) | `.sort` O(n log n) | inside a loop it is O(n² log n) — hoist it |
| `Object.keys/values/entries` | — | **O(n)**, allocates | O(n²) when called per iteration |
| deep copy | `deepcopy` O(n) | `structuredClone` / `JSON.parse(JSON.stringify(x))` O(n) | never per iteration |

## Backend: the costs that are not CPU

- **N+1** — a query inside a loop. One query with an `IN`/join, or a bulk endpoint. This
  is the most common real backend complexity bug and it is invisible in a code read.
- **Serial `await`** — `for (const x of xs) { await f(x) }` is N × latency. If the
  iterations are independent, `Promise.all` / `asyncio.gather` with a **bounded**
  concurrency. If they must be sequential, write the comment saying why.
- **Unbounded anything** — a fetch with no limit, a queue with no cap, a retry with no
  ceiling. Complexity in n where n is attacker- or data-controlled is an availability bug.
- **Missing index** — an O(n) table scan per request. The query plan is the evidence.
- **Re-derived work per request** — parsing config, compiling a regex, rebuilding a
  lookup table. Hoist to module scope or a cache with an explicit invalidation trigger.

## The three boundaries

Every loop and every slice gets these, and they are cheap to state:

- **Empty** — zero elements. Does it return the right identity, or index `[0]` and throw?
- **One** — a single element. Pairwise logic (`items[i+1]`, `zip(xs, xs[1:])`) usually
  breaks here.
- **Exactly at the limit** — `n`, `len-1`, the retry cap, the page size. Decide whether
  the boundary value is IN or OUT, then use the SAME operator at every site that tests
  it. `bounds` reports it when two sites disagree — `>` in one place and `>=` in another
  over the same operands is the signature of a dropped `=`, and neither line looks wrong
  alone.

## Volume — subtraction is the deliverable (in CODE, not in thinking)

**Scope first**: this is about shipped code. Planning, brainstorming, design and
active reasoning on live code should be *detailed* — name the alternatives, price
them, say what breaks and what you would reject and why. That is where the expensive
decision gets made, and a thin plan is how a confident wrong design gets built.
`fluff` runs on source files and counts removable LINES; it has no opinion about how
much you thought. Trim the code, never the reasoning that produced it.

When the ask is "simplify", the measured failure is answering with MORE code. So:
count lines before and after and state both. `fluff` reports dead locals, wrappers that
only forward, `if c: return True else: return False`, try/except that re-raises
unchanged, comments that restate the line below them, and deep nesting — each with the
specific move and a removable-line count. If the count went up, you did not simplify;
say so rather than claiming you did.

## Anti-patterns

- Claiming "this is O(n)" in a summary without running `bigo`.
- Calling an edit a simplification with no before/after line count.
- Adding a `Map` "for performance" without naming n — indexing 5 items is noise.
- Fixing a flagged O(n²) by deleting the feature rather than the nesting.
- Treating a `fluff` finding as a bug, or a `bounds` finding as a nit — they are
  different severities for a reason.
- Silencing the gate (`SERGE_ALGO_GATE_DISABLE=1`) instead of fixing or refuting the
  finding. If the checker is wrong, say why in one line — that is a valid answer.
