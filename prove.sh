#!/usr/bin/env bash
# Proves the tasks: every hidden test fails on the base and passes on the reference solution.
#
#   prove.sh [--task ID|all]
#
# For each task it
#   1. checks that task.json says what issue.md says (title, criteria, touches) and that the issue passes
#      the factory's own `t12-adapter spec-check` (when bin/t12-adapter is built);
#   2. scores the untouched base with lib/score.sh: the unit tier must pass, and EVERY hidden test must
#      fail (not just the package);
#   3. applies reference.patch to a fresh base, commits it, scores again: the unit tier and every hidden
#      test must pass.
# Nothing is reported to FactoryBench. Exit status 1 if any task breaks a rule. Takes a minute or two
# per factory task (it runs the factory's unit tier twice).
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
need git jq go

task=all
while [ $# -gt 0 ]; do
  case $1 in
    --task) task=$2; shift 2 ;;
    *) die "usage: prove.sh [--task ID|all]" ;;
  esac
done
if [ "$task" = all ]; then mapfile -t tasks < <(all_tasks); else tasks=("$task"); fi

tmp=$(mktemp -d "${TMPDIR:-/tmp}/bench-prove.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
bad=0
printf '%-18s %-10s %6s  %-20s %-20s %s\n' task product hidden "base (unit / hidden)" "reference (unit / hidden)" text-vs-task.json
printf '%-18s %-10s %6s  %-20s %-20s %s\n' ------ ------- ------ -------------------- -------------------- ---------------

# issue_title, issue_criteria, issue_touches read issue.md the way the intake does.
issue_title() { sed -n 's/^# //p' "$1" | head -1; }
issue_criteria() { awk '/^## Acceptance criteria/ {on = 1; next} /^## / {on = 0} on && /^- / {sub(/^- /, ""); print}' "$1"; }
issue_touches() { sed -n 's/^Touches: *//p' "$1" | head -1 | tr ',' '\n' | sed 's/^ *//; s/ *$//'; }

verdict() { # JSON -> "pass|FAIL n/m"
  jq -r '(.checks[] | select(.name == "bench-unit") | if .passed then "pass" else "FAIL" end) + " / " +
    (.checks[] | select(.name == "hidden-acceptance") | if .passed then "pass" else "\(.passed_tests)/\(.total_tests)" end)' <<<"$1"
}

for t in "${tasks[@]}"; do
  tdir=$(task_dir "$t")
  problems=()

  # 1. text vs task.json
  [ "$(issue_title "$tdir/issue.md")" = "$(jq -r .title "$tdir/task.json")" ] || problems+=("title differs")
  [ "$(issue_criteria "$tdir/issue.md")" = "$(jq -r '.acceptance_criteria[]' "$tdir/task.json")" ] || problems+=("criteria differ")
  [ "$(issue_touches "$tdir/issue.md")" = "$(jq -r '.touches[]' "$tdir/task.json")" ] || problems+=("touches differ")
  [ "$(jq -r .id "$tdir/task.json")" = "$t" ] || problems+=("task id is not the directory name")
  [ "$(jq -r .max_lanes "$tdir/task.json")" = 1 ] || problems+=("max_lanes is not 1")
  jq -e '.source.ref | test("^bench/[A-Za-z0-9_.-]+#[0-9]+$")' "$tdir/task.json" >/dev/null || problems+=("source.ref is not bench/<product>#<n>")
  if [ -x "$FACTORY_DIR/bin/t12-adapter" ]; then
    "$FACTORY_DIR/bin/t12-adapter" spec-check --forge github <"$tdir/issue.md" >"$tmp/spec.json" 2>&1 || problems+=("spec-check refuses the issue: $(jq -rc .refusals "$tmp/spec.json" 2>/dev/null)")
  fi
  product=$(task_product "$t")

  # 2. base
  repo=$tmp/$t
  base=$(product_repo "$t" "$repo")
  base_json=$("$BENCH_DIR/lib/score.sh" --task "$t" --repo "$repo" --commit "$base" --attempt "" --no-report --no-review)
  [ "$(jq -r '.checks[] | select(.name == "bench-unit") | .passed' <<<"$base_json")" = true ] || problems+=("unit tier fails on the base")
  [ "$(jq -r '.checks[] | select(.name == "hidden-acceptance") | .passed_tests' <<<"$base_json")" = 0 ] || problems+=("a hidden test passes on the base")
  [ "$(jq -r '.checks[] | select(.name == "hidden-acceptance") | .total_tests' <<<"$base_json")" -gt 0 ] || problems+=("no hidden tests")

  # 3. reference
  if git -C "$repo" apply "$tdir/reference.patch" 2>"$tmp/apply.err"; then
    git -C "$repo" -c user.name=bench -c user.email=bench@localhost add -A
    git -C "$repo" -c user.name=bench -c user.email=bench@localhost -c commit.gpgsign=false commit -q -m "reference"
    ref_json=$("$BENCH_DIR/lib/score.sh" --task "$t" --repo "$repo" --commit "$(git -C "$repo" rev-parse HEAD)" --attempt "" --no-report --no-review)
    [ "$(jq -r .passed <<<"$ref_json")" = true ] || problems+=("the reference does not pass every check: $(jq -rc '[.checks[] | select(.passed | not) | .name + ": " + .reason]' <<<"$ref_json")")
  else
    ref_json='{"checks":[{"name":"bench-unit","passed":false},{"name":"hidden-acceptance","passed":false,"passed_tests":0,"total_tests":0}]}'
    problems+=("reference.patch does not apply: $(head -c 200 "$tmp/apply.err")")
  fi

  total=$(jq -r '.checks[] | select(.name == "hidden-acceptance") | .total_tests' <<<"$base_json")
  printf '%-18s %-10s %6s  %-20s %-20s %s\n' "$t" "$product" "$total" "$(verdict "$base_json")" "$(verdict "$ref_json")" \
    "$([ ${#problems[@]} -eq 0 ] && echo ok || echo "PROBLEM: ${problems[*]}")"
  [ ${#problems[@]} -eq 0 ] || bad=1
  rm -rf "$repo"
done
exit $bad
