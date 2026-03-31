# Liquid ThemeRunner Performance

Optimize Shopify Liquid's parser and renderer to minimize `combined_us` on the same ThemeRunner benchmark used in PR #2056, while preserving correctness on the 974-test base suite.

## Setup

1. **Read the in-scope files**:
   - `lib/**/*.rb` — the Liquid implementation you modify.
   - `performance/bench_quick.rb` — the fixed benchmark harness. Do not modify.
   - `performance/theme_runner.rb` — loads the real Shopify-like templates and data used by the benchmark. Do not modify.
   - `test/{integration,unit}/**/*_test.rb` — the 974-test correctness gate. Do not modify.
   - `eval/eval.sh` — runs the correctness + performance eval. Do not modify.
   - `prepare.sh` — installs Ruby dependencies. Do not modify.
2. **Run prepare**: `bash prepare.sh` to ensure Ruby 3.4 + YJIT is available and install the required gems.
3. **Verify setup**:
   - `ruby --version` should report Ruby 3.4 after `prepare.sh` updates your `PATH` for the current shell.
   - `bundle check` should succeed.
4. **Initialize results.tsv**: Create `results.tsv` with just the header row.
5. **Run baseline**: `bash eval/eval.sh > run.log 2>&1`

## The benchmark

This task uses the exact benchmark family cited in Shopify/liquid PR #2056: `performance/bench_quick.rb` on ThemeRunner, which renders real Shopify-like theme templates with production-style data. The eval first runs the 974-test base suite, then runs `bench_quick.rb` three times with `--yjit` and keeps the best combined parse+render time.

The benchmark reports four raw numbers:

- `combined_us` — parse + render time in microseconds for the best run. Lower is better.
- `parse_us` — parse-only time in microseconds for the best run.
- `render_us` — render-only time in microseconds for the best run.
- `allocations` — object allocations for one parse+render cycle from that same best run.

Reference points:

- PR #2056 reports **3,534us combined**, **2,353us parse**, **1,146us render**, **24,530 allocations** on the author's machine with Ruby 3.4 + YJIT.
- One verified local baseline run on this machine produced **18,032us combined**, **4,585us parse**, **13,447us render**, **24,530 allocations**, with **974 / 974 tests passing**.

Only compare scores produced on the same environment.

## Experimentation

**What you CAN modify:**

- Any Ruby implementation file under `lib/`
- You may add new Ruby files under `lib/` if they simplify or speed up the implementation

**What you CANNOT modify:**

- `eval/`
- `prepare.sh`
- `performance/`
- `test/`
- `.ruby-version`, `Gemfile`, `liquid.gemspec`, `Rakefile`

**The goal: minimize `combined_us`.** Lower is better. Correctness is a hard gate: if any of the 974 tests fail, the run is invalid.

Secondary signal: if two commits have similar `combined_us`, prefer the one with fewer `allocations`.

**Simplicity criterion**: all else being equal, simpler changes are better.

**Hive scoring note**: Hive sorts scores descending. Since this task minimizes `combined_us`, submit the negated metric as the score. Example: if `combined_us: 16500`, submit `--score -16500`.

## Output format

The eval prints:

```text
---
combined_us:      18032
parse_us:         4585
render_us:        13447
allocations:      24530
correct:          974
total:            974
valid:            true
```

## Logging results

Log each experiment to `results.tsv` (tab-separated):

```text
commit	combined_us	parse_us	render_us	allocations	status	description
a1b2c3d	18032	4585	13447	24530	keep	baseline from PR #2056 head
b2c3d4e	16220	4100	12120	24180	keep	faster condition evaluation fast path
c3d4e5f	ERROR	0	0	0	crash	broken tokenizer edge case
```

1. git commit hash (short, 7 chars)
2. `combined_us` or `ERROR`
3. `parse_us`
4. `render_us`
5. `allocations`
6. `status`: `keep`, `discard`, or `crash`
7. short description of the change

## The experiment loop

LOOP FOREVER:

1. **THINK** — inspect `results.tsv`, the hot paths in `lib/`, and the benchmark harness. Focus on parse and render allocations first.
2. Modify files under `lib/`.
3. git commit
4. Run: `bash eval/eval.sh > run.log 2>&1`
5. Read results: `grep "^combined_us:\|^allocations:\|^valid:" run.log`
6. If `valid: false` or the metric is missing, inspect `tail -n 100 run.log`.
7. Record the result in `results.tsv` (do not commit `results.tsv`).
8. Keep the commit only if `combined_us` improved and `valid: true`. Otherwise revert it.

## Optimization Ideas

- Reduce parser allocations in `Tokenizer`, `Variable`, `VariableLookup`, and the expression parsing stack.
- Reuse scanners or cursor-like objects instead of repeatedly constructing temporary state.
- Avoid unnecessary string copies and intermediate arrays.
- Fast-path common render cases for primitive values, short filter chains, and simple conditions.
- Use the benchmark's split between parse and render time to tell whether a change helps compilation, rendering, or both.
