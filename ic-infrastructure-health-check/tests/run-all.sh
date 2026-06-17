#!/usr/bin/env bash
# Aggregate runner for the self-heal chaos test suite.
#
#   bash tests/run-all.sh                 # run every suite
#   bash tests/run-all.sh matrix chaos    # run a subset (regression|matrix|chaos)
#
# Each suite runs in its own process against its own throwaway sandbox; this
# wrapper tallies the per-suite results and returns non-zero if any failed.
#
# Safety: the suites are self-contained — dry-run for the unit matrix, and a
# mock init system for the chaos harness — so nothing here restarts, probes, or
# notifies a real service. (Even so, prefer a dedicated test box over a live
# multi-tenant host.)

set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

declare -A SUITES=(
    [regression]="test-self-heal.sh"
    [matrix]="test-self-heal-matrix.sh"
    [chaos]="chaos-harness.sh"
    [openrc]="test-health-openrc.sh"
)
ORDER=(regression matrix chaos openrc)

# --list: print available suites and exit (for CI introspection). Derived from
# ORDER so it can never drift out of sync with the registered suites.
if [[ "${1:-}" == "--list" ]]; then
    printf '%s\n' "${ORDER[*]}"
    exit 0
fi

# Resolve requested suites (default: all, in ORDER).
requested=("$@"); [[ ${#requested[@]} -eq 0 ]] && requested=("${ORDER[@]}")

total_pass=0 total_fail=0 any_fail=0
declare -A R_PASS R_FAIL R_RC

for name in "${requested[@]}"; do
    script="${SUITES[$name]:-}"
    if [[ -z "$script" ]]; then
        echo "WARNING: unknown suite '$name' (known: ${ORDER[*]})" >&2
        any_fail=1; continue
    fi
    printf '\n\033[1m━━━ %s (%s) ━━━\033[0m\n' "$name" "$script"
    out="$(bash "$DIR/$script" 2>&1)"; rc=$?
    printf '%s\n' "$out"

    line="$(grep -E '^[0-9]+ passed, [0-9]+ failed' <<<"$out" | tail -1)"
    p="${line%% passed*}"; f="${line#*passed, }"; f="${f%% failed*}"
    [[ "$p" =~ ^[0-9]+$ ]] || p=0
    [[ "$f" =~ ^[0-9]+$ ]] || f=0
    R_PASS[$name]=$p; R_FAIL[$name]=$f; R_RC[$name]=$rc
    total_pass=$((total_pass + p)); total_fail=$((total_fail + f))
    [[ "$rc" -ne 0 ]] && any_fail=1
done

printf '\n\033[1m━━━ summary ━━━\033[0m\n'
printf '%-12s %8s %8s %8s\n' "suite" "pass" "fail" "exit"
for name in "${requested[@]}"; do
    [[ -n "${SUITES[$name]:-}" ]] || continue
    printf '%-12s %8s %8s %8s\n' "$name" "${R_PASS[$name]:-?}" "${R_FAIL[$name]:-?}" "${R_RC[$name]:-?}"
done
printf '%-12s %8s %8s\n' "TOTAL" "$total_pass" "$total_fail"

if [[ "$any_fail" -eq 0 ]]; then
    printf '\n\033[32mAll suites green.\033[0m\n'
else
    printf '\n\033[31mSome suites failed.\033[0m\n'
fi
exit "$any_fail"
