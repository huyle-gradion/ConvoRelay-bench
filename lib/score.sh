#!/usr/bin/env bash
# The checker both arms are scored by: the same deterministic checks on the result commit of each.
#
#   score.sh --task ID --repo DIR --commit SHA --attempt ATTEMPT [--wall SECONDS] [--no-report] [--no-review]
#            [--review-dir DIR] [--out FILE]
#
# 1. Clones DIR at SHA into a fresh directory. Nothing the arm left outside the commit counts.
# 2. bench-unit         the product's unit tier (products.json `unit`), on the commit as the arm left it.
# 3. hidden-acceptance  tasks/ID/hidden/ is copied over the checkout, then the product's hidden command
#                       runs. It passes only when the command exits 0 and every TestHidden* function of
#                       the task ran and passed (a run that found no tests cannot pass).
# 4. review             the shared review (lib/review.sh): two read-only Claude Opus 5.5 sessions on the
#                       final diff, bugs and security, and quality. Passes only when both approve. It calls
#                       a paid model; --no-review leaves it out (prove.sh does, it proves the tasks).
# 5. checks.d/*.sh      extra checks, see checks.d/README.md. None ships yet; none is faked.
#
# Each check is reported as one FactoryBench `gate` event on ATTEMPT (key bench:<name>, so a re-score
# replaces nothing) unless --no-report or FACTORYBENCH_URL is unset. The verdict is printed as one JSON
# object (and written to --out). The exit status is 0 whatever the verdict: a failed check is a result.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
need git jq go timeout

task= repo= commit= attempt= wall= report=1 review=1 review_dir= out=
while [ $# -gt 0 ]; do
  case $1 in
    --task) task=$2; shift 2 ;;
    --repo) repo=$2; shift 2 ;;
    --commit) commit=$2; shift 2 ;;
    --attempt) attempt=$2; shift 2 ;;
    --wall) wall=$2; shift 2 ;;
    --no-report) report=0; shift ;;
    --no-review) review=0; shift ;;
    --review-dir) review_dir=$2; shift 2 ;;
    --out) out=$2; shift 2 ;;
    *) die "score.sh: unknown argument $1" ;;
  esac
done
[ -n "$task" ] && [ -n "$repo" ] || die "usage: score.sh --task ID --repo DIR --commit SHA --attempt ATTEMPT [--wall S] [--no-report] [--no-review] [--review-dir DIR] [--out FILE]"
tdir=$(task_dir "$task")
product=$(task_product "$task")
: "${BENCH_CHECK_TIMEOUT:=900}"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/bench-score.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
co=$tmp/checkout
# The hidden tests only ever enter this fresh checkout, made after the arm has finished. Refuse a
# scoring directory inside the arm's repository (a TMPDIR pointed there would put them under its working dir).
repo_real=$(cd "$repo" && pwd -P)
case $(cd "$tmp" && pwd -P)/ in "$repo_real"/*) die "score.sh: the scoring directory $tmp is inside the arm's repository $repo" ;; esac
checks='[]'

record() { # NAME PASSED(true|false) REASON DURATION [PASSED_TESTS TOTAL_TESTS]
  local name=$1 passed=$2 reason=$3 dur=$4 pt=${5:-null} tt=${6:-null}
  checks=$(jq -c --arg n "$name" --argjson p "$passed" --arg r "$reason" --argjson d "$dur" \
    --argjson pt "$pt" --argjson tt "$tt" \
    '. + [{name: $n, passed: $p, reason: $r, duration_s: $d, passed_tests: $pt, total_tests: $tt}]' <<<"$checks")
  if [ "$report" = 1 ] && [ -n "$attempt" ]; then
    fb_emit gate "$attempt" "bench:$name" "$(jq -nc --arg n "$name" --argjson p "$passed" --arg r "$reason" '{name: $n, passed: $p, reason: $r}')"
  fi
}

review_json=null

fail_all() { # REASON: no checkout to run anything in
  record bench-unit false "$1" 0
  record hidden-acceptance false "$1" 0
  [ "$review" = 0 ] || record review false "$1" 0
}

# in_checkout CMD...: run CMD in the checkout with the module proxy off, so nothing can reach the network by go,
# and with an empty environment (PATH, a private HOME, the Go caches): the arm's code runs on this host and must
# not inherit FACTORYBENCH_TOKEN, ANTHROPIC_API_KEY or any other secret of the caller.
mkdir -p "$tmp/home"
gocache=$(go env GOCACHE) gomodcache=$(go env GOMODCACHE)
in_checkout() {
  (cd "$co" && env -i PATH="$PATH" HOME="$tmp/home" TMPDIR="${TMPDIR:-/tmp}" GOCACHE="$gocache" GOMODCACHE="$gomodcache" \
    GOPROXY=off GOFLAGS=-buildvcs=false GOTOOLCHAIN=local timeout "$BENCH_CHECK_TIMEOUT" "$@")
}

if [ -z "$commit" ]; then
  fail_all "the arm left no result commit"
elif ! git clone -q --no-checkout "$repo" "$co" 2>"$tmp/clone.err" || ! git -C "$co" checkout -q --detach "$commit" 2>>"$tmp/clone.err"; then
  fail_all "cannot check out $commit: $(head -c 200 "$tmp/clone.err" | tr '\n' ' ')"
else
  # unit: the arm's own tests and the product's, as left.
  mapfile -t unit_cmd < <(product_argv "$product" unit)
  t0=$(now)
  in_checkout "${unit_cmd[@]}" >"$tmp/unit.log" 2>&1
  rc=$?
  d=$(elapsed "$t0" "$(now)")
  if [ $rc -eq 0 ]; then
    record bench-unit true "unit tier passed" "$d"
  else
    record bench-unit false "unit tier exited $rc: $(grep -m1 -E '^(--- FAIL|FAIL|panic|.*\.go:[0-9]+:)' "$tmp/unit.log" | head -c 160)" "$d"
  fi

  # hidden-acceptance: the task's tests, placed at product paths only now.
  if [ -d "$tdir/hidden" ]; then
    want=$(grep -rhoE '^func TestHidden[A-Za-z0-9_]*' "$tdir/hidden" --include='*_test.go' | sort -u | wc -l)
    cp -a "$tdir/hidden/." "$co/"
    mapfile -t hidden_cmd < <(product_argv "$product" hidden)
    t0=$(now)
    in_checkout "${hidden_cmd[@]}" >"$tmp/hidden.json" 2>"$tmp/hidden.err"
    rc=$?
    d=$(elapsed "$t0" "$(now)")
    got=$(jq -R 'fromjson? | select(.Action == "pass" and .Test != null and (.Test | startswith("TestHidden")) and (.Test | contains("/") | not))' \
      "$tmp/hidden.json" 2>/dev/null | jq -s 'length')
    got=${got:-0}
    if [ $rc -eq 0 ] && [ "$got" -eq "$want" ] && [ "$want" -gt 0 ]; then
      record hidden-acceptance true "$got of $want hidden tests passed" "$d" "$got" "$want"
    else
      first=$(jq -rR 'fromjson? | select(.Action == "fail" and .Test != null) | .Test' "$tmp/hidden.json" 2>/dev/null | head -1)
      [ -n "$first" ] || first=$(jq -rR 'fromjson? | select(.Action == "output") | .Output' "$tmp/hidden.json" 2>/dev/null | grep -m1 -E 'FAIL|cannot|undefined|error' | head -c 160)
      record hidden-acceptance false "$got of $want hidden tests passed (exit $rc${first:+; $first})" "$d" "$got" "$want"
    fi
  else
    record hidden-acceptance false "task $task has no hidden/ directory" 0
  fi

  # review: the same two Opus 5.5 reviewers on every arm's final diff. review.sh clones the commit again,
  # so the hidden tests copied into $co above are not in what a reviewer can read.
  if [ "$review" = 1 ]; then
    t0=$(now)
    review_json=$("$BENCH_DIR/lib/review.sh" --task "$task" --repo "$repo" --commit "$commit" ${review_dir:+--out-dir "$review_dir"} 2>"$tmp/review.err")
    if [ -n "$review_json" ] && jq -e . >/dev/null 2>&1 <<<"$review_json"; then
      record review "$(jq '.passed' <<<"$review_json")" "$(jq -r '.reviewers | map(.name + "=" + .verdict) | join(" ")' <<<"$review_json")" "$(elapsed "$t0" "$(now)")"
    else
      review_json=null
      record review false "the review could not run: $(head -c 160 "$tmp/review.err" | tr '\n' ' ')" "$(elapsed "$t0" "$(now)")"
    fi
  fi
  # checks.d: one more check per executable, after the built-in ones. The checkout still holds the hidden tests.
  for hook in "$BENCH_DIR"/checks.d/*.sh; do
    [ -x "$hook" ] || continue
    name=$(basename "$hook" .sh | sed 's/^[0-9]*-//')
    t0=$(now)
    reason=$("$hook" "$task" "$co" 2>&1 | tail -1)
    rc=${PIPESTATUS[0]}
    record "$name" "$([ "$rc" -eq 0 ] && echo true || echo false)" "${reason:-exit $rc}" "$(elapsed "$t0" "$(now)")"
  done
fi

result=$(jq -nc --arg task "$task" --arg attempt "$attempt" --arg commit "$commit" --arg wall "$wall" --argjson checks "$checks" --argjson review "$review_json" \
  '{task: $task, attempt: $attempt, commit: $commit, wall_s: (if $wall == "" then null else ($wall | tonumber) end), checks: $checks,
    review: $review, passed: ($checks | all(.passed))}')
[ -z "$out" ] || echo "$result" >"$out"
echo "$result"
