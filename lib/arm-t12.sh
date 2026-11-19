#!/usr/bin/env bash
# Arm t12: turbo-12f drives the task through its pipeline, lanes off (max_lanes 1 in task.json).
#
#   arm-t12.sh --task ID --work DIR [--model M] [--max-cost USD] [--omp-cmd CMD] [--engineer tdd|deep]
#
# --engineer deep is the arm t12-deep: the same pipeline with one deep Engineer session in place of the
# analyzer, red, green and refactor. It adds `"engineer": "deep"` to the queued task file; the runner then
# reports the attempt with `+engineer:deep` in its factory_config_version, and its token is
# FACTORYBENCH_TOKEN_T12_DEEP (else the shared FACTORYBENCH_TOKEN).
#
# Workers run on --model; t12's own reviewer role runs on Claude Opus 5.5 with medium thinking, the reviewers
# of the shared checker (common.sh). Lanes are off: the task must say `max_lanes: 1`.
#
# DIR holds `product/`, the fresh repository run.sh made. The runner reports the attempt itself
# (internal/adapters/fbreport) because task.json carries a `source` ref `bench/<product>#<n>`; this
# script only learns the attempt id by putting a `factorybench` wrapper first on the runner's PATH.
# Writes DIR/arm.json: {attempt, commit, phase, note}.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
need git jq go factorybench

task= work= model=claude-sonnet-5-5 max_cost=3 omp_cmd=omp engineer=tdd
while [ $# -gt 0 ]; do
  case $1 in
    --task) task=$2; shift 2 ;;
    --work) work=$2; shift 2 ;;
    --model) model=$2; shift 2 ;;
    --max-cost) max_cost=$2; shift 2 ;;
    --omp-cmd) omp_cmd=$2; shift 2 ;;
    --engineer) engineer=$2; shift 2 ;;
    *) die "arm-t12.sh: unknown argument $1" ;;
  esac
done
[ -n "$task" ] && [ -n "$work" ] || die "usage: arm-t12.sh --task ID --work DIR"
case $engineer in tdd) arm=t12 ;; deep) arm=t12-deep ;; *) die "arm-t12.sh: --engineer must be tdd or deep" ;; esac
tdir=$(task_dir "$task")
product=$work/product
id=$(jq -er .id "$tdir/task.json")
[ "$(jq -r '.max_lanes' "$tdir/task.json")" = 1 ] || die "task $task: lanes are off in the bench, task.json must say max_lanes: 1"
bin=${T12_BIN:-$FACTORY_DIR/bin}
for p in t12 t12-queue t12-adapter t12-runner; do
  [ -x "$bin/$p" ] || die "$bin/$p is missing: build with  go -C factory build -o bin/ ./cmd/...  (or set T12_BIN)"
done
case $model in */*) omp_model=$model ;; *) omp_model=anthropic/$model ;; esac
omp_reviewer=anthropic/$BENCH_REVIEW_MODEL

# t12 reads these inside its cage: the Go toolchain, bun for the factory's own guard gate, and the t12
# programs (the factory product's profile calls t12-tia).
toolchain=${BENCH_TOOLCHAIN_DIRS:-}
if [ -z "$toolchain" ]; then
  toolchain=$(go env GOROOT)
  if bun=$(command -v bun); then toolchain=$toolchain:$(dirname "$(dirname "$(readlink -f "$bun")")"); fi
fi

home=$work/state queue=$work/queue wrap=$work/fbwrap fblog=$work/attempts.log
mkdir -p "$queue" "$wrap"
# The task file is the intake's; the arm only says which Engineer runs it (the task's own key wins over the profile's).
jq -c --arg e "$engineer" 'if $e == "deep" then . + {engineer: "deep"} else . end' "$tdir/task.json" >"$queue/$id.json"
: >"$fblog"
cat >"$wrap/factorybench" <<WRAP
#!/bin/sh
# Records the type and attempt id of every "factorybench emit TYPE --attempt ID" call, then runs the real one.
att=; prev=
for a in "\$@"; do [ "\$prev" = --attempt ] && att=\$a; prev=\$a; done
printf '%s %s\n' "\$2" "\$att" >>"$fblog"
exec "$(command -v factorybench)" "\$@"
WRAP
chmod +x "$wrap/factorybench"

"$bin/t12" init --repo "$product" --home "$home" >"$work/init.log" 2>&1 || die "t12 init failed: $(cat "$work/init.log")"

runner=("$bin/t12-runner" --home "$home" --queue "$queue" --max 1 --omp-cmd "$omp_cmd"
  --omp-model "$omp_model" --role-model "reviewer-bugs=$omp_reviewer" --role-model "reviewer-quality=$omp_reviewer" --role-thinking "reviewer-bugs=$BENCH_REVIEW_EFFORT" --role-thinking "reviewer-quality=$BENCH_REVIEW_EFFORT" --omp-max-cost "$max_cost" --skills-cache "${BENCH_SKILLS_CACHE:-$HOME/.local/state/t12-bench/skills}")
log "$arm arm: ${runner[*]}"
FACTORYBENCH_TOKEN=$(arm_token "$arm") FACTORYBENCH_SPOOL=$work/fb-spool.jsonl \
  PATH=$wrap:$bin:$PATH T12_TOOLCHAIN_DIRS=$toolchain:$bin \
  "${runner[@]}" >"$work/runner.log" 2>&1
rc=$?
note="runner exit $rc"

rec=$home/runs/$id.json
attempt=$(awk '$1 == "attempt.started" {a = $2} END {print a}' "$fblog")
phase=none commit=
if [ -f "$rec" ]; then
  phase=$(jq -r '.phase' "$rec")
  commit=$(jq -r '.candidate.commit // empty' "$rec")
  if [ -z "$commit" ]; then
    tip=$(git -C "$product" rev-parse -q --verify "refs/heads/$(jq -r .branch "$rec")" || true)
    if [ -n "$tip" ] && [ "$tip" != "$(jq -r .base_commit "$rec")" ]; then
      commit=$tip
      note="$note; no candidate was pinned, scoring the branch tip"
    fi
  fi
  stop=$(jq -r '.stop_reason // empty | if type == "object" then tostring else . end' "$rec")
  [ -z "$stop" ] || note="$note; stopped: $stop"
else
  note="$note; no run record: the task was never admitted (see runner.log)"
fi
jq -nc --arg a "$attempt" --arg c "$commit" --arg p "$phase" --arg n "$note" '{attempt: $a, commit: $c, phase: $p, note: $n}' >"$work/arm.json"
