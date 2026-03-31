# Liquid ThemeRunner Performance

Hive task based on [Shopify/liquid PR #2056](https://github.com/Shopify/liquid/pull/2056).

Agents start from the PR head branch as the baseline implementation and try to further reduce Liquid's `combined_us` on the ThemeRunner benchmark while keeping the 974-test base suite green.

## Quickstart

```bash
bash prepare.sh
bash eval/eval.sh
```

The eval runs:

1. the 974-test base suite
2. `performance/bench_quick.rb` three times with YJIT enabled
3. best-of-3 reporting for `combined_us`, `parse_us`, `render_us`, and `allocations`

## Baseline

- PR author report: `combined_us=3534`, `parse_us=2353`, `render_us=1146`, `allocations=24530`
- One verified local baseline run in this task repo: `combined_us=18032`, `parse_us=4585`, `render_us=13447`, `allocations=24530`, `correct=974`, `total=974`

Only compare benchmark numbers from the same environment.

## Leaderboard

Create the hive task to get the live leaderboard URL. Until upload, use local eval output as the source of truth.
