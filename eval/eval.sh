#!/usr/bin/env bash
# Evaluate Liquid on the same benchmark style used in Shopify/liquid PR #2056:
# 975 unit tests must pass, then performance/bench_quick.rb runs 3 times and the
# best combined parse+render time is reported.
set -uo pipefail

cd "$(dirname "$0")/.."

summary() {
    local efficiency_score="${1:-ERROR}"
    local combined_us="${2:-ERROR}"
    local parse_us="${3:-0}"
    local render_us="${4:-0}"
    local allocations="${5:-0}"
    local correct="${6:-0}"
    local total="${7:-0}"
    local valid="${8:-false}"
    echo "---"
    printf "efficiency_score: %s\n" "$efficiency_score"
    printf "combined_us:      %s\n" "$combined_us"
    printf "parse_us:         %s\n" "$parse_us"
    printf "render_us:        %s\n" "$render_us"
    printf "allocations:      %s\n" "$allocations"
    printf "correct:          %s\n" "$correct"
    printf "total:            %s\n" "$total"
    printf "valid:            %s\n" "$valid"
}

find_ruby_34() {
    if command -v ruby >/dev/null 2>&1 && ruby -e 'exit(RUBY_VERSION.start_with?("3.4.") ? 0 : 1)'; then
        command -v ruby
        return 0
    fi

    if [ -x "/opt/homebrew/opt/ruby@3.4/bin/ruby" ]; then
        echo "/opt/homebrew/opt/ruby@3.4/bin/ruby"
        return 0
    fi

    if command -v brew >/dev/null 2>&1; then
        local brew_ruby
        brew_ruby="$(brew --prefix ruby@3.4 2>/dev/null)/bin/ruby"
        if [ -x "$brew_ruby" ]; then
            echo "$brew_ruby"
            return 0
        fi
    fi

    return 1
}

if ! RUBY_BIN="$(find_ruby_34)"; then
    echo "ERROR: Ruby 3.4 not found. Run: bash prepare.sh" >&2
    summary "ERROR" "ERROR" "0" "0" "0" "0" "0" "false"
    exit 0
fi

export PATH="$(dirname "$RUBY_BIN"):$PATH"

if ! "$RUBY_BIN" --yjit -e 'exit(defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled? ? 0 : 1)'; then
    echo "ERROR: Ruby 3.4 with YJIT support is required. Run: bash prepare.sh" >&2
    summary "ERROR" "ERROR" "0" "0" "0" "0" "0" "false"
    exit 0
fi

if ! bundle check >/dev/null 2>&1; then
    echo "ERROR: Ruby gems are missing. Run: bash prepare.sh" >&2
    summary "ERROR" "ERROR" "0" "0" "0" "0" "0" "false"
    exit 0
fi

TEST_LOG="$(mktemp)"
trap 'rm -f "$TEST_LOG"' EXIT

echo "Running 975-test base gate..." >&2
TEST_EXIT=0
bundle exec ruby eval/run_base_test.rb >"$TEST_LOG" 2>&1 || TEST_EXIT=$?

RESULT_LINE="$(grep -E '^[0-9]+ runs, [0-9]+ assertions, [0-9]+ failures, [0-9]+ errors, [0-9]+ skips$' "$TEST_LOG" | tail -1 || true)"

if [ -n "$RESULT_LINE" ]; then
    TOTAL="$(echo "$RESULT_LINE" | sed -E 's/^([0-9]+) runs,.*/\1/')"
    FAILURES="$(echo "$RESULT_LINE" | sed -E 's/^[0-9]+ runs, [0-9]+ assertions, ([0-9]+) failures,.*/\1/')"
    ERRORS="$(echo "$RESULT_LINE" | sed -E 's/^[0-9]+ runs, [0-9]+ assertions, [0-9]+ failures, ([0-9]+) errors,.*/\1/')"
    SKIPS="$(echo "$RESULT_LINE" | sed -E 's/^[0-9]+ runs, [0-9]+ assertions, [0-9]+ failures, [0-9]+ errors, ([0-9]+) skips$/\1/')"
    CORRECT=$((TOTAL - FAILURES - ERRORS - SKIPS))
else
    TOTAL=0
    CORRECT=0
fi

if [ "$TEST_EXIT" -ne 0 ]; then
    echo "ERROR: Unit tests failed." >&2
    tail -n 40 "$TEST_LOG" >&2
    summary "ERROR" "ERROR" "0" "0" "0" "$CORRECT" "$TOTAL" "false"
    exit 0
fi

BEST_COMBINED=999999999
BEST_PARSE=0
BEST_RENDER=0
BEST_ALLOC=0

echo "Running ThemeRunner benchmark (best of 3)..." >&2
for i in 1 2 3; do
    OUT="$(bundle exec ruby --yjit performance/bench_quick.rb 2>&1)"
    PARSE_US="$(echo "$OUT" | awk -F= '/^parse_us=/{print $2}' | tail -1)"
    RENDER_US="$(echo "$OUT" | awk -F= '/^render_us=/{print $2}' | tail -1)"
    COMBINED_US="$(echo "$OUT" | awk -F= '/^combined_us=/{print $2}' | tail -1)"
    ALLOCATIONS="$(echo "$OUT" | awk -F= '/^allocations=/{print $2}' | tail -1)"

    if [ -z "$PARSE_US" ] || [ -z "$RENDER_US" ] || [ -z "$COMBINED_US" ] || [ -z "$ALLOCATIONS" ]; then
        echo "ERROR: Benchmark output was not parseable." >&2
        echo "$OUT" >&2
        summary "ERROR" "ERROR" "0" "0" "0" "$CORRECT" "$TOTAL" "false"
        exit 0
    fi

    echo "  run $i: combined=${COMBINED_US}us parse=${PARSE_US}us render=${RENDER_US}us allocations=${ALLOCATIONS}" >&2

    if [ "$COMBINED_US" -lt "$BEST_COMBINED" ]; then
        BEST_COMBINED="$COMBINED_US"
        BEST_PARSE="$PARSE_US"
        BEST_RENDER="$RENDER_US"
        BEST_ALLOC="$ALLOCATIONS"
    fi
done

# Normalize to the PR-head baseline used for this task on this machine,
# not Shopify main. The task starts from PR #2056 head, so score 1.0 means
# "matching the starting PR baseline under this eval environment".
PR_BASELINE_COMBINED_US=18032
PR_BASELINE_ALLOCATIONS=24530
EFFICIENCY_SCORE="$(awk -v bc="$PR_BASELINE_COMBINED_US" -v ba="$PR_BASELINE_ALLOCATIONS" -v cu="$BEST_COMBINED" -v al="$BEST_ALLOC" 'BEGIN { printf "%.6f", (bc * ba) / (cu * al) }')"

summary "$EFFICIENCY_SCORE" "$BEST_COMBINED" "$BEST_PARSE" "$BEST_RENDER" "$BEST_ALLOC" "$CORRECT" "$TOTAL" "true"
