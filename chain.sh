#!/usr/bin/env bash
# Runs a CHAIN of tasks on ONE product repository with one arm, merging each finished task before the next starts.
#
#   chain.sh --arm t12|t12-deep --chain us-s1-01 [--yes] [--model M] [--max-cost USD] [--first N] [--base REV] [--out DIR]
#
# What it does, in order:
#   1. builds ONE product repository (<run>/product) from the chain's base commit with `git archive` (without
#      factory/bench: no hidden test or reference patch can be in it), puts chatbridge/node_modules in it
#      (`npm ci --offline`, or a copy of BENCH_NODE_MODULES) so the profile's verify_deps exist, and runs `t12 init`;
#   2. for each task of chains/<chain>/order.json, in order:
#        queue   writes the task file (chains/<chain>/<ID>/task.json, plus "engineer": "deep" on the arm t12-deep)
#                into the queue directory and runs one `t12-queue` pass, which admits it through `t12 prepare`. A
#                `depends_on` entry whose task did not merge is dropped from the queued file (the chain continues
#                from main as it is); the others stay, and the queue checks them like the real intake flow does;
#        deps    copies chatbridge/node_modules into the task's worktree (the factory does not for a Node product);
#        run     `t12-runner` with the flags of lib/arm-t12.sh (workers on --model, reviewers Opus 5.5 medium,
#                the skills cache, T12_TOOLCHAIN_DIRS holding node and the t12 programs);
#        merge   when the run is local-verified, its candidate is merged into the product's main by fast-forward:
#                the human merge. A run that ends paused or stopped is stopped with `t12 stop` (so it holds no
#                slot) and recorded; the next task starts from main as it is;
#        score   on a fresh clone of main: the product's unit tier (the whole suite as main has it), then this
#                task's hidden tests (lib/chain-common.sh puts them in only now); wall time; phase; the
#                verdicts of t12's own reviewers from the run's event log; the FactoryBench cost of the attempt
#                (sum of cost_usd of its usage rows in FB_DB, default ~/.local/state/t12-bench/fb.db; "-" when
#                nothing is reported). Each check is also a FactoryBench `gate` event on the attempt, as lib/score.sh
#                does (bench:bench-unit, bench:hidden-acceptance).
#   3. scores ALL the chain's hidden tests on the final main, writes <run>/results.tsv and prints the summary.
#
# --arm       t12: the tdd Engineer; t12-deep: one deep Engineer session instead of analyzer, red, green, refactor.
#             Everything else is the same on both arms (README "Held equal"). Token: FACTORYBENCH_TOKEN_T12 or
#             FACTORYBENCH_TOKEN_T12_DEEP (else FACTORYBENCH_TOKEN); FACTORYBENCH_URL turns reporting on.
# --first N   only the first N tasks of the chain (the dry run uses 2).
# --base REV  the commit to build the product from; default: order.json's `base`.
# --max-cost  USD one worker session may spend (default 3), as for run.sh.
# --yes       go ahead and spend money. Without it the script prints what it would do and stops.
# Environment: CONVORELAY_DIR (the ConvoRelay checkout to benchmark, default ../ConvoRelay), BENCH_OMP_CMD replaces `omp` (the dry run uses a fake), T12_BIN is where the t12 programs are
# (default: built into $CONVORELAY_DIR/factory/bin), BENCH_NODE_MODULES, BENCH_NODE, BENCH_TOOLCHAIN_DIRS (extra toolchain
# directories after node's), BENCH_SKILLS_CACHE, BENCH_OUT (default .runs), FB_DB.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
. "$(dirname "${BASH_SOURCE[0]}")/lib/chain-common.sh"
need git jq go sqlite3 npm

arm= chain= model=claude-sonnet-5-5 max_cost=3 yes=0 first= base=
while [ $# -gt 0 ]; do
  case $1 in
    --arm) arm=$2; shift 2 ;;
    --chain) chain=$2; shift 2 ;;
    --model) model=$2; shift 2 ;;
    --max-cost) max_cost=$2; shift 2 ;;
    --first) first=$2; shift 2 ;;
    --base) base=$2; shift 2 ;;
    --out) BENCH_OUT=$2; shift 2 ;;
    --yes) yes=1; shift ;;
    -h | --help) sed -n '2,/^set -u/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument $1 (see --help)" ;;
  esac
done
case $arm in t12) engineer=tdd ;; t12-deep) engineer=deep ;; *) die "--arm must be t12 or t12-deep" ;; esac
[ -n "$chain" ] || die "--chain is required"
cdir=$(chain_dir "$chain")
mapfile -t ids < <(chain_ids "$chain")
[ -z "$first" ] || ids=("${ids[@]:0:$first}")
[ ${#ids[@]} -gt 0 ] || die "no tasks in chain $chain"
: "${base:=$(chain_base "$chain")}"
for id in "${ids[@]}"; do
  [ "$(jq -r '.max_lanes' "$cdir/$id/task.json")" = 1 ] || die "task $id: lanes are off in the bench, task.json must say max_lanes: 1"
done
case $model in */*) omp_model=$model ;; *) omp_model=anthropic/$model ;; esac
omp_reviewer=anthropic/$BENCH_REVIEW_MODEL
omp_cmd=${BENCH_OMP_CMD:-omp}

echo "bench: chain=$chain arm=$arm model=$model reviewers=$BENCH_REVIEW_MODEL/$BENCH_REVIEW_EFFORT max-cost=\$$max_cost base=$base tasks: ${ids[*]}" >&2
echo "bench: this calls paid models: per task about 40 worker and reviewer sessions of t12 (the deep arm fewer). The chain has no shared claude review." >&2
if [ $yes -ne 1 ] && [ "${BENCH_YES:-}" != 1 ]; then die "not running without --yes"; fi

if [ -z "${T12_BIN:-}" ]; then
  go -C "$FACTORY_DIR" build -o bin/ ./cmd/... || die "go build of the t12 programs failed"
fi
bin=${T12_BIN:-$FACTORY_DIR/bin}
for p in t12 t12-queue t12-adapter t12-runner; do [ -x "$bin/$p" ] || die "$bin/$p is missing (build with  go -C factory build -o bin/ ./cmd/...  or set T12_BIN)"; done

stamp=$(date -u +%Y%m%dT%H%M%S)-$$
work=$BENCH_OUT/chain-$chain-$arm-$stamp
mkdir -p "$work"
product=$work/product home=$work/state queue=$work/queue wrap=$work/fbwrap fblog=$work/attempts.log
mkdir -p "$queue" "$wrap"
tsv=$work/results.tsv
: >"$fblog"

toolchain=$(chain_node_dir)${BENCH_TOOLCHAIN_DIRS:+:$BENCH_TOOLCHAIN_DIRS}
fb_db=${FB_DB:-$HOME/.local/state/t12-bench/fb.db}

base_commit=$(chain_repo "$base" "$product") || die "cannot make the product repository from $base"
chain_deps "$product"
nm=$(cd "$product/chatbridge/node_modules" && pwd -P)
log "chain $chain, $arm: product at $product, base $base ($(echo "$base_commit" | cut -c1-8)), node $(chain_node)"
"$bin/t12" init --repo "$product" --home "$home" >"$work/init.log" 2>&1 || die "t12 init failed: $(cat "$work/init.log")"
git -C "$product" status --porcelain | grep -q . && die "the product repository is not clean after init: $(git -C "$product" status --porcelain | head -3)"

cat >"$wrap/factorybench" <<WRAP
#!/bin/sh
# Records the type and attempt id of every "factorybench emit TYPE --attempt ID" call, then runs the real one.
att=; prev=
for a in "\$@"; do [ "\$prev" = --attempt ] && att=\$a; prev=\$a; done
printf '%s %s\n' "\$2" "\$att" >>"$fblog"
exec "$(command -v factorybench || echo factorybench)" "\$@"
WRAP
chmod +x "$wrap/factorybench"

runner=("$bin/t12-runner" --home "$home" --max 1 --omp-cmd "$omp_cmd"
  --omp-model "$omp_model" --role-model "reviewer-bugs=$omp_reviewer" --role-model "reviewer-quality=$omp_reviewer"
  --role-thinking "reviewer-bugs=$BENCH_REVIEW_EFFORT" --role-thinking "reviewer-quality=$BENCH_REVIEW_EFFORT"
  --omp-max-cost "$max_cost" --skills-cache "${BENCH_SKILLS_CACHE:-$HOME/.local/state/t12-bench/skills}")
token=$(arm_token "$arm")

printf 'n\ttask\tarm\tphase\tmerged\twall_s\tunit_pass\tunit_total\thidden_pass\thidden_total\thidden_expected\treviews\tcost_usd\tattempt\tnote\n' >"$tsv"

merged_ids=()
n=0
for id in "${ids[@]}"; do
  n=$((n + 1))
  tdir=$cdir/$id
  note=
  rec=$home/runs/$id.json
  log "[$n/${#ids[@]}] $id: $arm starts from main $(git -C "$product" rev-parse --short main)"

  # queue: the intake's task file, engineer set by the arm, depends_on trimmed to what merged.
  jq -c --arg e "$engineer" --argjson merged "$(printf '%s\n' "${merged_ids[@]:-}" | jq -R . | jq -sc 'map(select(. != ""))')" '
      (if $e == "deep" then . + {engineer: "deep"} else . end)
      | .depends_on as $d | if $d == null then . else .depends_on = ($d | map(select(. as $x | $merged | index($x)))) end
      | if (.depends_on // []) == [] then del(.depends_on) else . end' "$tdir/task.json" >"$queue/$id.json"
  dropped=$(jq -r --slurpfile q "$queue/$id.json" '(.depends_on // []) - ($q[0].depends_on // []) | join(",")' "$tdir/task.json")
  [ -z "$dropped" ] || note="$note; dropped depends_on $dropped (not merged)"
  : >"$fblog"
  t0=$(now)
  PATH=$bin:$PATH T12_TOOLCHAIN_DIRS=$toolchain:$bin "$bin/t12-queue" --home "$home" --queue "$queue" --max 1 >"$work/$id.queue.log" 2>&1
  if [ -f "$rec" ]; then
    # deps: a real directory in the worktree, before any role runs.
    ct0=$(now)
    wt=$(jq -r .worktree "$rec")
    mkdir -p "$wt/chatbridge" && cp -a "$nm" "$wt/chatbridge/node_modules"
    copy_s=$(elapsed "$ct0" "$(now)")
    PATH=$wrap:$bin:$PATH T12_TOOLCHAIN_DIRS=$toolchain:$bin FACTORYBENCH_TOKEN=$token FACTORYBENCH_SPOOL=$work/fb-spool.jsonl \
      "${runner[@]}" >"$work/$id.runner.log" 2>&1
    rc=$?
    note="$note; runner exit $rc"
    wall=$(awk -v a="$(elapsed "$t0" "$(now)")" -v c="$copy_s" 'BEGIN { printf "%.1f", a - c }')
  else
    wall=$(elapsed "$t0" "$(now)")
    note="$note; no run record: the task was not admitted ($(tr '\n' ' ' <"$work/$id.queue.log" | head -c 200))"
  fi

  phase=none cand= merged=0
  if [ -f "$rec" ]; then
    phase=$(jq -r .phase "$rec")
    cand=$(jq -r '.candidate.commit // empty' "$rec")
    stop=$(jq -r '.stop_reason // empty | if type == "object" then tostring else . end' "$rec")
    [ -z "$stop" ] || note="$note; stopped: $stop"
    if [ "$phase" = local-verified ] && [ -n "$cand" ]; then
      # The human merge: main moves to the reviewed candidate.
      if git -C "$product" -c user.name=bench -c user.email=bench@localhost merge --ff-only -q "$cand" >"$work/$id.merge.log" 2>&1; then
        merged=1
        merged_ids+=("$id")
      else
        note="$note; merge of ${cand:0:8} failed: $(tr '\n' ' ' <"$work/$id.merge.log" | head -c 160)"
      fi
    elif [ "$phase" != stopped ]; then
      "$bin/t12" stop --home "$home" --task-id "$id" --reason "bench chain: the run ended in phase $phase; the chain goes on from main" >>"$work/$id.stop.log" 2>&1 ||
        note="$note; t12 stop failed (see $id.stop.log)"
    fi
  fi

  # score: a fresh clone of main as it is now.
  attempt=$(awk '$1 == "attempt.started" {a = $2} END {print a}' "$fblog")
  sdir=$work/score-$id
  mkdir -p "$sdir"
  main_tip=$(git -C "$product" rev-parse main)
  if chain_check_clone "$product" "$main_tip" "$sdir/co" "$nm"; then
    chain_vitest "$sdir/co" "$sdir/unit.json"
    unit_rc=$?
    read -r unit_pass unit_total < <(vitest_counts "$sdir/unit.json")
    chain_install_hidden "$chain" "$sdir/co" "$id"
    chain_vitest "$sdir/co" "$sdir/hidden.json" zz-hidden
    read -r hid_pass hid_total < <(vitest_counts "$sdir/hidden.json" hidden)
  else
    unit_rc=1 unit_pass=0 unit_total=0 hid_pass=0 hid_total=0
    note="$note; cannot clone main for scoring"
  fi
  want=$(chain_expected "$chain" "$id")
  [ "$hid_total" -ge "$want" ] || hid_total=$want # a test that did not even load counts as failed
  unit_ok=false; [ "$unit_rc" -eq 0 ] && [ "$unit_total" -gt 0 ] && unit_ok=true
  hid_ok=false; [ "$hid_pass" -eq "$want" ] && [ "$want" -gt 0 ] && hid_ok=true
  if [ -n "$attempt" ]; then
    FACTORYBENCH_TOKEN=$token FACTORYBENCH_SPOOL=$work/fb-spool.jsonl fb_emit gate "$attempt" "bench:bench-unit" \
      "$(jq -nc --argjson p "$unit_ok" --arg r "unit tier on main: $unit_pass of $unit_total tests passed" '{name: "bench-unit", passed: $p, reason: $r}')"
    FACTORYBENCH_TOKEN=$token FACTORYBENCH_SPOOL=$work/fb-spool.jsonl fb_emit gate "$attempt" "bench:hidden-acceptance" \
      "$(jq -nc --argjson p "$hid_ok" --arg r "$hid_pass of $want hidden tests passed on main" '{name: "hidden-acceptance", passed: $p, reason: $r}')"
  fi

  # t12's own reviewers: the last verdict of each role in the event log.
  reviews=-
  ev=$home/runs/$id.events.jsonl
  if [ -s "$ev" ]; then
    reviews=$(jq -rs '[.[] | select(.type == "reviewed") | .detail] | group_by(.role) | map(.[-1] | "\(.role)=\(.verdict)") | join(";")' "$ev")
    [ -n "$reviews" ] || reviews=-
  fi

  # cost: what FactoryBench priced for the attempt (the usage events travel asynchronously: wait a moment).
  cost=-
  if [ -n "$attempt" ] && [ -f "$fb_db" ] && [ -n "${FACTORYBENCH_URL:-}" ]; then
    sleep 2
    cost=$(sqlite3 "$fb_db" "select coalesce(round(sum(cost_usd), 4), 0) || case when sum(cost_usd is null) > 0 then ' (+' || sum(cost_usd is null) || ' unpriced)' else '' end from usage where attempt_id = '$attempt'" 2>/dev/null || echo -)
    [ -n "$cost" ] || cost=-
  fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$n" "$id" "$arm" "$phase" "$merged" "$wall" "$unit_pass" "$unit_total" \
    "$hid_pass" "$hid_total" "$want" "$reviews" "$cost" "${attempt:--}" "${note#; }" >>"$tsv"
  log "$id: phase=$phase merged=$merged wall=${wall}s unit=$unit_pass/$unit_total hidden=$hid_pass/$want reviews=$reviews cost=$cost"
done

# The whole chain's hidden tests on the final main.
fin=$work/score-final
mkdir -p "$fin"
if chain_check_clone "$product" "$(git -C "$product" rev-parse main)" "$fin/co" "$nm"; then
  chain_install_hidden "$chain" "$fin/co" "${ids[@]}"
  chain_vitest "$fin/co" "$fin/hidden.json" zz-hidden
  read -r all_pass all_total < <(vitest_counts "$fin/hidden.json" hidden)
else
  all_pass=0 all_total=0
fi
all_want=0
for id in "${ids[@]}"; do all_want=$((all_want + $(chain_expected "$chain" "$id"))); done

{
  echo
  printf '%-3s %-6s %-15s %-6s %8s  %-11s %-9s  %-46s %s\n' n task phase merged wall_s unit hidden reviews cost_usd
  tail -n +2 "$tsv" | while IFS=$'\t' read -r n id a phase merged wall up ut hp ht want reviews cost attempt note; do
    printf '%-3s %-6s %-15s %-6s %8s  %-11s %-9s  %-46s %s\n' "$n" "$id" "$phase" "$merged" "$wall" "$up/$ut" "$hp/$want" "$reviews" "$cost"
  done
  echo
  echo "arm $arm, chain $chain: $(tail -n +2 "$tsv" | awk -F'\t' '$5 == 1' | wc -l) of ${#ids[@]} tasks merged; all hidden tests on the final main: $all_pass of $all_want"
  echo "total wall: $(tail -n +2 "$tsv" | awk -F'\t' '{s += $6} END {printf "%.1f", s}')s"
  echo "results: $tsv (per-task logs, run records and clones under $work)"
} | tee "$work/summary.txt"
