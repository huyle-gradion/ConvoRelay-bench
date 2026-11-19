#!/usr/bin/env bash
# Dry run of chain.sh with fakes: both arms over the first two tasks of a chain, no model, no network, no money.
#
#   chain-dry-run.sh [--chain us-s1-01] [--first 2]
#
# Starts `factorybench serve` on a loopback port with a temporary database and the factories bench-t12 and
# bench-t12-deep (the caller's FACTORYBENCH_* variables are cleared and FB_DB points at the temporary database),
# then runs chain.sh for each arm with ConvoRelay factory/tests/support's fake omp. The model behind it is
# testdata/fake-chain-model.sh: every role is the Go toy's scripted fakemodel, except the deep Engineer, which applies
# the task's reference.patch. So:
#   t12       cannot solve a ChatBridge task (red writes a Go test; the product refuses it): every task ends
#             paused, is stopped, and the chain goes on from main: this shows init, the cage with node, the queue,
#             the stop path and the scoring on an unchanged main.
#   t12-deep  solves the tasks with the answer key: every task reaches local-verified and its candidate is merged
#             into main by chain.sh, the next task starts from the merged main, and the scores show the unit tier and
#             the hidden tests passing: this shows the merge, the dependency check and the scoring.
# It then checks what the run did and prints FactoryBench's report. What it proves: the runner. It says nothing about
# either arm's quality, the fakes are scripted. Everything temporary is deleted at the end (DRY_KEEP=1 keeps it).
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
. "$(dirname "${BASH_SOURCE[0]}")/lib/chain-common.sh"
need factorybench jq go git curl sqlite3

chain=us-s1-01 first=2
while [ $# -gt 0 ]; do
  case $1 in
    --chain) chain=$2; shift 2 ;;
    --first) first=$2; shift 2 ;;
    *) die "usage: chain-dry-run.sh [--chain ID] [--first N]" ;;
  esac
done

tmp=$(mktemp -d "${TMPDIR:-/tmp}/bench-chain-dry.XXXXXX")
server=
cleanup() {
  [ -z "$server" ] || kill "$server" 2>/dev/null
  wait 2>/dev/null
  if [ -n "${DRY_KEEP:-}" ]; then log "kept $tmp"; else rm -rf "$tmp"; fi
}
trap cleanup EXIT

for v in $(env | sed -n 's/^\(FACTORYBENCH_[A-Z0-9_]*\)=.*/\1/p'); do unset "$v"; done
db=$tmp/fb.db
add_factory() { factorybench factory add "$1" --commit-email "$1@example.invalid" --db "$db" | head -1; }
tok_t12=$(add_factory bench-t12)
tok_deep=$(add_factory bench-t12-deep)
for _ in $(seq 1 50); do
  port=$((20000 + RANDOM % 30000))
  factorybench serve --db "$db" --addr "127.0.0.1:$port" >"$tmp/server.log" 2>&1 &
  server=$!
  # Our server must be alive when the port answers: a foreign server on the port must not get the tokens.
  for _ in $(seq 1 20); do
    sleep 0.25
    kill -0 "$server" 2>/dev/null || break
    curl -s -o /dev/null "http://127.0.0.1:$port/" && break 2
  done
  kill "$server" 2>/dev/null
  wait "$server" 2>/dev/null
  server=
done
[ -n "$server" ] || die "could not start factorybench serve: $(cat "$tmp/server.log")"
export FACTORYBENCH_URL=http://127.0.0.1:$port FACTORYBENCH_TOKEN_T12=$tok_t12 FACTORYBENCH_TOKEN_T12_DEEP=$tok_deep FB_DB=$db
log "FactoryBench on $FACTORYBENCH_URL, database $db"

mkdir -p "$tmp/bin" "$tmp/fake-state" "$tmp/snapshots"
go -C "$FACTORY_DIR" build -o "$tmp/bin/" ./cmd/t12 ./cmd/t12-queue ./cmd/t12-adapter ./cmd/t12-runner \
  ./tests/support/bin/fakeomp ./tests/support/bin/fakemodel || die "go build failed"
export T12_BIN=$tmp/bin BENCH_YES=1 BENCH_OUT=$tmp/runs
export BENCH_OMP_CMD=$tmp/bin/fakeomp FAKE_OMP_COST=0.01 FAKE_OMP_DELEGATE=$BENCH_DIR/testdata/fake-chain-model.sh FAKE_CHAIN_FALLBACK=$tmp/bin/fakemodel
export FAKE_CHAIN_DIR=$BENCH_CHAINS_DIR/$chain FAKE_LOG=$tmp/model.log FAKE_OMP_LOG=$tmp/omp.log
export FAKE_STATE=$tmp/fake-state FAKE_OMP_STATE=$tmp/fake-state FAKE_OMP_SNAPSHOT=$tmp/snapshots

for arm in t12 t12-deep; do
  echo "== chain $chain, arm $arm, first $first tasks"
  "$BENCH_DIR/chain.sh" --arm "$arm" --chain "$chain" --first "$first" || log "$arm chain failed"
done

sleep 1
echo
echo "== factorybench report items"
factorybench report items --db "$db"
echo
echo "== factorybench report factories"
factorybench report factories --db "$db"

echo
echo "== what the run did"
problems=()
ok() { echo "ok    $1"; }
fail() { echo "FAIL  $1"; problems+=("$1"); }
mapfile -t ids < <(chain_ids "$chain")
ids=("${ids[@]:0:$first}")
for arm in t12 t12-deep; do
  run=$(ls -d "$BENCH_OUT"/chain-"$chain"-"$arm"-* | head -1)
  tsv=$run/results.tsv
  [ -f "$tsv" ] || { fail "$arm: no results.tsv"; continue; }
  rows=$(($(wc -l <"$tsv") - 1))
  [ "$rows" -eq "$first" ] && ok "$arm: $rows tasks recorded in results.tsv" || fail "$arm: $rows rows in results.tsv, want $first"
  product=$run/product
  for id in "${ids[@]}"; do
    row=$(awk -F'\t' -v t="$id" '$2 == t' "$tsv")
    phase=$(cut -f4 <<<"$row") merged=$(cut -f5 <<<"$row") hp=$(cut -f9 <<<"$row") want=$(cut -f11 <<<"$row") attempt=$(cut -f14 <<<"$row") reviews=$(cut -f12 <<<"$row")
    cost=$(cut -f13 <<<"$row")
    if [ "$arm" = t12 ]; then
      [ "$phase" = paused ] && [ "$merged" = 0 ] && [ "$(jq -r .phase "$run/state/runs/$id.json")" = stopped ] && ok "t12 $id: the fake model cannot solve it: the run paused, chain.sh stopped it, nothing merged" || fail "t12 $id: phase=$phase merged=$merged"
    else
      [ "$phase" = local-verified ] && [ "$merged" = 1 ] && ok "t12-deep $id: local-verified and merged into main" || fail "t12-deep $id: phase=$phase merged=$merged"
      [ "$hp" = "$want" ] && ok "t12-deep $id: all $want hidden tests pass on main" || fail "t12-deep $id: hidden $hp of $want"
      case $reviews in *reviewer-bugs=approve*reviewer-quality=approve* | *reviewer-quality=approve*reviewer-bugs=approve*) ok "t12-deep $id: reviewer verdicts read from the event log: $reviews" ;; *) fail "t12-deep $id: reviews '$reviews'" ;; esac
    fi
    [ -n "$attempt" ] && [ "$attempt" != - ] && ok "$arm $id: FactoryBench attempt $attempt, cost $cost" || fail "$arm $id: no attempt id"
    case $cost in - | "") fail "$arm $id: no cost from FactoryBench" ;; esac
  done
  # main
  if [ "$arm" = t12-deep ]; then
    n=$(git -C "$product" rev-list --count "$(git -C "$product" rev-list --max-parents=0 main | head -1)"..main)
    [ "$n" -ge "$first" ] && ok "t12-deep: main moved $n commits past the base" || fail "t12-deep: main moved $n commits, want at least $first"
    [ "$(jq -r '.engineer' "$run/state/runs/${ids[0]}.json")" = deep ] && ok "t12-deep: the run records engineer deep" || fail "t12-deep: the run does not record engineer deep"
  else
    [ "$(git -C "$product" rev-list --count main)" = 1 ] && ok "t12: main is still the base commit" || fail "t12: main moved"
    [ "$(jq -r '.engineer' "$run/state/runs/${ids[0]}.json")" = tdd ] && ok "t12: the run records engineer tdd" || fail "t12: engineer is not tdd"
  fi
  # the queue's dependency check ran: the second task of the chain depends on the first
  dep=$(jq -r '.depends_on // [] | join(",")' "$run/state/runs/${ids[1]}.json" 2>/dev/null)
  want_dep=$(jq -r --arg i "${ids[1]}" '.depends_on // [] | join(",")' "$BENCH_CHAINS_DIR/$chain/${ids[1]}/task.json")
  if [ "$arm" = t12-deep ]; then
    [ "$dep" = "$want_dep" ] && ok "t12-deep: ${ids[1]} was admitted with depends_on [$dep] after ${ids[0]} merged" || fail "t12-deep: ${ids[1]} depends_on '$dep', want '$want_dep'"
  else
    [ -z "$dep" ] && ok "t12: ${ids[1]}'s depends_on was dropped because ${ids[0]} did not merge" || fail "t12: ${ids[1]} depends_on '$dep'"
  fi
done
n_lanes=$(jq -s '[.[] | select(.max_lanes != 1)] | length' "$BENCH_CHAINS_DIR/$chain"/*/task.json)
[ "$n_lanes" -eq 0 ] && ok "every task.json says max_lanes 1" || fail "$n_lanes tasks do not say max_lanes 1"
# omp sessions: workers on sonnet with no thinking flag, reviewers on Opus 5.5 medium, on both arms
omp_sessions=$(jq -sc '[.[] | select(.argv != null and (.argv | index("--mode") != null)) | {role: (.argv[(.argv | index("--session-dir")) + 1] | split("/") | last | split("-")[0]),
  model: .argv[(.argv | index("--model")) + 1], thinking: (if (.argv | index("--thinking")) then .argv[(.argv | index("--thinking")) + 1] else null end)}]' "$FAKE_OMP_LOG")
n_rev_all=$(jq '[.[] | select(.role | startswith("reviewer"))] | length' <<<"$omp_sessions")
n_rev=$(jq '[.[] | select((.role | startswith("reviewer")) and .model == "anthropic/claude-opus-5-5" and .thinking == "medium")] | length' <<<"$omp_sessions")
n_other_all=$(jq '[.[] | select(.role | startswith("reviewer") | not)] | length' <<<"$omp_sessions")
n_other=$(jq '[.[] | select((.role | startswith("reviewer") | not) and .model == "anthropic/claude-sonnet-5-5" and .thinking == null)] | length' <<<"$omp_sessions")
{ [ "$n_rev_all" -ge 1 ] && [ "$n_rev" -eq "$n_rev_all" ] && ok "$n_rev reviewer sessions on anthropic/claude-opus-5-5, thinking medium"; } || fail "reviewer sessions $n_rev of $n_rev_all on opus 5.5 medium"
{ [ "$n_other_all" -ge 1 ] && [ "$n_other" -eq "$n_other_all" ] && ok "$n_other worker sessions on anthropic/claude-sonnet-5-5, no thinking flag"; } || fail "worker sessions $n_other of $n_other_all on sonnet 5.5"
factories=$(factorybench report factories --db "$db" 2>/dev/null)
if grep -q bench-t12-deep <<<"$factories"; then ok "FactoryBench holds the factory bench-t12-deep"; else fail "bench-t12-deep reported nothing"; fi
# no hidden test or answer key in either product repository
for arm in t12 t12-deep; do
  run=$(ls -d "$BENCH_OUT"/chain-"$chain"-"$arm"-* | head -1)
  leaked=$(git -C "$run/product" log --all --name-only --format= | grep -c 'bench/\|reference.patch\|zz-hidden' || true)
  [ "$leaked" -eq 0 ] && ok "$arm: no bench file, hidden test or reference patch in the product repository's history" || fail "$arm: $leaked leaked paths in the product repository"
  [ ! -e "$run/product/factory/bench" ] && ok "$arm: factory/bench is not in the product" || fail "$arm: factory/bench is in the product"
done

if [ ${#problems[@]} -gt 0 ]; then
  echo
  echo "DRY RUN FAILED: ${problems[*]}"
  exit 1
fi
echo
echo "DRY RUN PASSED for both arms over the first $first tasks of $chain"
