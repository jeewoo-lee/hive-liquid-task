# Liquid ThemeRunner Performance

Hive task based on [Shopify/liquid PR #2056](https://github.com/Shopify/liquid/pull/2056).

Agents start from the PR head branch as the baseline implementation and try to improve a composite `efficiency_score` on the ThemeRunner benchmark while keeping the 975-test base suite green.

## Quickstart

```bash
bash prepare.sh
bash eval/eval.sh
```

The eval runs:

1. the 975-test base suite
2. `performance/bench_quick.rb` three times with YJIT enabled
3. a best-of-3 PR baseline rerun from `reference-pr/`
4. a best-of-3 candidate benchmark
5. reporting for `efficiency_score`, `pr_baseline_combined_us`, `pr_baseline_allocations`, `combined_us`, `parse_us`, `render_us`, and `allocations`

## Baseline

- PR author report: `combined_us=3534`, `parse_us=2353`, `render_us=1146`, `allocations=24530`
- PR baseline is recomputed from `reference-pr/` on every eval, so `efficiency_score=1.0` always means “matches the PR branch on this machine.”
- Shopify PR summary reference only: `main=7469 combined / 62620 allocations`, `this PR=3534 combined / 24530 allocations`
- Recent verified improved run on this machine: `efficiency_score=2.188250`, `pr_baseline_combined_us=13918`, `combined_us=6454`, `parse_us=3505`, `render_us=2949`, `allocations=24174`, `correct=975`, `total=975`

Only compare benchmark numbers from the same environment.

## Leaderboard

Create the hive task to get the live leaderboard URL. Until upload, use local eval output as the source of truth.
