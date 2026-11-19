#!/usr/bin/env bash
# Run one arm on one task (or all) and score the result. See README.md.
#
#   run.sh --arm t12|t12-deep|baseline --task ID|all [--model M] [--max-cost USD] [--out DIR] [--no-score] [--yes]
#
# --arm            t12: turbo-12f's pipeline, lanes off. t12-deep: the same with one deep Engineer session
#                  (task.json gets "engineer": "deep"). baseline: one Claude Code session with the whole pstack.
# --task           a directory name under tasks, or `all`.
# --model          worker model of both arms, default claude-sonnet-5-5 (t12 gets it as anthropic/<model>). The
#                  reviewers are not an option: Claude Opus 5.5 with medium thinking on both arms, t12's own
#                  reviewer role and the checker's two sessions alike (lib/common.sh).
# --max-cost       USD one model session may spend (t12: per worker session, default 3; baseline: the one
#                  session, default 6). The checker's review sessions are capped by BENCH_REVIEW_MAX_COST (2).
# --out            where runs go, default .runs. Each run: <out>/<stamp>/<task>/<arm>/.
# --no-score       run the arm only; score later with lib/score.sh (see README, baseline isolation).
# --yes            go ahead and spend money. Without it the script prints what would run and stops.
#
# Environment: FACTORYBENCH_URL and FACTORYBENCH_TOKEN_T12 / FACTORYBENCH_TOKEN_T12_DEEP /
# FACTORYBENCH_TOKEN_BASELINE (or FACTORYBENCH_TOKEN) report to FactoryBench; unset URL reports nowhere.
# BENCH_OMP_CMD replaces `omp` for the t12 arms (the dry run uses a fake). T12_BIN is where the t12 programs are (default factory/bin).
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
need git jq go

arm= task= model=claude-sonnet-5-5 max_cost= yes=0 score=1
while [ $# -gt 0 ]; do
  case $1 in
    --arm) arm=$2; shift 2 ;;
    --task) task=$2; shift 2 ;;
    --model) model=$2; shift 2 ;;
    --max-cost) max_cost=$2; shift 2 ;;
    --out) BENCH_OUT=$2; shift 2 ;;
    --no-score) score=0; shift ;;
    --yes) yes=1; shift ;;
    -h | --help) sed -n '2,/^set -u/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument $1 (see --help)" ;;
  esac
done
case $arm in t12 | t12-deep | baseline) ;; *) die "--arm must be t12, t12-deep or baseline" ;; esac
: "${max_cost:=$([ "$arm" = baseline ] && echo 6 || echo 3)}"
[ -n "$task" ] || die "--task is required: a task id or all"
if [ "$task" = all ]; then mapfile -t tasks < <(all_tasks); else tasks=("$task"); fi
[ ${#tasks[@]} -gt 0 ] || die "no tasks under $BENCH_TASKS_DIR"
for t in "${tasks[@]}"; do task_dir "$t" >/dev/null; done

echo "bench: arm=$arm model=$model reviewers=$BENCH_REVIEW_MODEL/$BENCH_REVIEW_EFFORT max-cost=\$$max_cost tasks: ${tasks[*]}" >&2
echo "bench: this calls paid models: per task the arm (t12: about 40 sessions; baseline: one pstack session) and, when scored, two review sessions." >&2
if [ $yes -ne 1 ] && [ "${BENCH_YES:-}" != 1 ]; then
  die "not running without --yes"
fi

if [ "$arm" != baseline ] && [ -z "${T12_BIN:-}" ]; then
  go -C "$FACTORY_DIR" build -o bin/ ./cmd/... || die "go build of the t12 programs failed"
fi

stamp=$(date -u +%Y%m%dT%H%M%S)-$$
run_dir=$BENCH_OUT/$stamp
mkdir -p "$run_dir"
results=$run_dir/results.jsonl
: >"$results"

for t in "${tasks[@]}"; do
  work=$run_dir/$t/$arm
  mkdir -p "$work"
  base_commit=$(product_repo "$t" "$work/product") || die "cannot make the product repository for $t"
  log "$t: $arm starts on $(task_product "$t") @ ${base_commit:0:8}"
  t0=$(now)
  case $arm in
    t12 | t12-deep) "$BENCH_DIR/lib/arm-t12.sh" --task "$t" --work "$work" --model "$model" \
      --max-cost "$max_cost" ${BENCH_OMP_CMD:+--omp-cmd "$BENCH_OMP_CMD"} $([ "$arm" = t12-deep ] && echo --engineer deep) ;;
    baseline) "$BENCH_DIR/lib/arm-baseline.sh" --task "$t" --work "$work" --model "$model" --max-cost "$max_cost" ;;
  esac
  arm_rc=$?
  wall=$(elapsed "$t0" "$(now)")
  [ -f "$work/arm.json" ] || echo "{\"attempt\":\"\",\"commit\":\"\",\"phase\":\"crashed\",\"note\":\"the arm script exited $arm_rc without a result\"}" >"$work/arm.json"
  attempt=$(jq -r .attempt "$work/arm.json")
  commit=$(jq -r .commit "$work/arm.json")

  if [ $score -eq 0 ]; then
    log "$t: $arm done in ${wall}s, not scored (--no-score): lib/score.sh --task $t --repo $work/product --commit $commit --attempt $attempt"
    continue
  fi
  # Scored by the same checker for both arms, with this arm's token so the gates land on its attempt. Only
  # now do the task's hidden tests leave tasks/<id>/hidden: score.sh copies them into its own fresh clone
  # of the result commit, never into $work/product, where the arm worked.
  FACTORYBENCH_TOKEN=$(arm_token "$arm") FACTORYBENCH_SPOOL=$work/fb-spool.jsonl \
    "$BENCH_DIR/lib/score.sh" --task "$t" --repo "$work/product" --commit "$commit" --attempt "$attempt" \
    --wall "$wall" --review-dir "$work/review" --out "$work/score.json" >/dev/null
  jq -c --arg arm "$arm" --slurpfile a "$work/arm.json" '. + {arm: $arm, phase: $a[0].phase, note: $a[0].note}' "$work/score.json" >>"$results"
  log "$t: $arm done in ${wall}s: $(jq -r '.checks | map("\(.name)=\(if .passed then "pass" else "FAIL" end)") | join(" ")' "$work/score.json")"
done

echo
printf '%-18s %-9s %8s  %-10s %-6s  %-8s  %s\n' task arm wall_s bench-unit hidden review phase
jq -r '[.task, .arm, (.wall_s | tostring), (.checks | map(select(.name == "bench-unit"))[0].passed | if . then "pass" else "FAIL" end),
  (.checks | map(select(.name == "hidden-acceptance"))[0] | if .passed then "pass" else "FAIL \(.passed_tests)/\(.total_tests)" end),
  (.checks | map(select(.name == "review"))[0] | if . == null then "-" elif .passed then "approve" else "changes" end), .phase] | @tsv' "$results" |
  while IFS=$'\t' read -r a b c d e f g; do printf '%-18s %-9s %8s  %-6s %-6s  %-8s  %s\n' "$a" "$b" "$c" "$d" "$e" "$f" "$g"; done
echo "bench: results in $results"
