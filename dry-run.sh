#!/usr/bin/env bash
# Dry run of both arms with fakes, against a throwaway local FactoryBench. No model, no network, no money.
#
#   dry-run.sh
#
# 1. Starts `factorybench serve` on a free loopback port with a temporary database and three factories,
#    bench-t12, bench-t12-deep and bench-baseline. A fake `claude` goes first on PATH, before anything runs (a real one would
#    spend money: the baseline arm and the checker's reviewers both call it).
# 2. Arm t12 runs the toy task dry-greet through the real t12-runner with ConvoRelay factory/tests/support's fake omp and
#    fake model; arm t12-deep runs it again with a deep Engineer (one engineer session instead of the
#    analyzer, red, green and refactor); arm baseline runs the same task with the fake `claude`, which applies the reference patch.
#    Both are then scored by the shared checker, whose two reviewers are the fake `claude` too.
# 3. Arm baseline runs three real tasks: tl-crlf (the fake applies the reference, both reviewers approve),
#    tl-date (the fake fails and changes nothing) and tl-tag-filter (reference, but the quality reviewer says
#    `changes`), to show passing and failing checks.
# 4. Checks what the fakes were given: the baseline's session loaded the pinned pstack and started with
#    /poteto-mode; both reviewers were read-only Opus 5.5 sessions on medium without the hidden tests; the t12
#    arm's omp sessions got sonnet for the workers and Opus 5.5 with medium thinking for the reviewer. Any
#    mismatch fails the run.
# 5. Prints FactoryBench's reports, then kills the server and removes every temporary file.
# What it proves: the harness, the reporting, the checker and the wiring of models and skills work end to
# end. It says nothing about either arm's quality: the fakes are scripted.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
. "$(dirname "${BASH_SOURCE[0]}")/lib/skills.sh"
need factorybench jq go git curl

tmp=$(mktemp -d "${TMPDIR:-/tmp}/bench-dry.XXXXXX")
server=
cleanup() {
  [ -z "$server" ] || kill "$server" 2>/dev/null
  wait 2>/dev/null
  if [ -n "${DRY_KEEP:-}" ]; then log "kept $tmp"; else rm -rf "$tmp"; fi
}
trap cleanup EXIT

# The fake claude first of all: nothing below may reach a real one.
mkdir -p "$tmp/bin" "$tmp/fakepath"
ln -s "$BENCH_DIR/testdata/fake-claude.sh" "$tmp/fakepath/claude"
export PATH=$tmp/fakepath:$PATH
[ "$(command -v claude)" = "$tmp/fakepath/claude" ] || die "the fake claude is not first on PATH; refusing to go on"
export FAKE_CLAUDE_LOG=$tmp/claude.log
: >"$FAKE_CLAUDE_LOG"

# Nothing of the caller's FactoryBench setup may leak into, or out of, the dry run.
for v in $(env | sed -n 's/^\(FACTORYBENCH_[A-Z0-9_]*\)=.*/\1/p'); do unset "$v"; done
db=$tmp/fb.db
add_factory() { factorybench factory add "$1" --commit-email "$1@example.invalid" --db "$db" | head -1; }
tok_t12=$(add_factory bench-t12)
tok_deep=$(add_factory bench-t12-deep)
tok_base=$(add_factory bench-baseline)
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
export FACTORYBENCH_URL=http://127.0.0.1:$port FACTORYBENCH_TOKEN_T12=$tok_t12 FACTORYBENCH_TOKEN_T12_DEEP=$tok_deep FACTORYBENCH_TOKEN_BASELINE=$tok_base
log "FactoryBench on $FACTORYBENCH_URL, database $db"

# Fakes: the t12 programs and the fake omp and model come from this tree; `claude` is the fake script.
go -C "$FACTORY_DIR" build -o "$tmp/bin/" ./cmd/t12 ./cmd/t12-queue ./cmd/t12-adapter ./cmd/t12-runner \
  ./tests/support/bin/fakeomp ./tests/support/bin/fakemodel || die "go build failed"
export T12_BIN=$tmp/bin BENCH_OMP_CMD=$tmp/bin/fakeomp BENCH_YES=1 BENCH_OUT=$tmp/runs
export FAKE_OMP_COST=0.01 FAKE_OMP_DELEGATE=$tmp/bin/fakemodel FAKE_LOG=$tmp/model.log FAKE_OMP_LOG=$tmp/omp.log
mkdir -p "$tmp/fake-state" "$tmp/snapshots"
export FAKE_STATE=$tmp/fake-state FAKE_OMP_STATE=$tmp/fake-state FAKE_OMP_SNAPSHOT=$tmp/snapshots

dry_tasks=$BENCH_DIR/testdata/tasks dry_products=$BENCH_DIR/testdata/products.json
echo "== all three arms, same toy task"
BENCH_TASKS_DIR=$dry_tasks BENCH_PRODUCTS=$dry_products "$BENCH_DIR/run.sh" --arm t12 --task dry-greet || log "t12 arm run failed"
BENCH_TASKS_DIR=$dry_tasks BENCH_PRODUCTS=$dry_products "$BENCH_DIR/run.sh" --arm t12-deep --task dry-greet || log "t12-deep arm run failed"
BENCH_TASKS_DIR=$dry_tasks BENCH_PRODUCTS=$dry_products \
  FAKE_CLAUDE_PATCH=$dry_tasks/dry-greet/reference.patch "$BENCH_DIR/run.sh" --arm baseline --task dry-greet || log "baseline run failed"
echo "== baseline arm, real tasks: one solved, one failed, one solved but not approved"
FAKE_CLAUDE_PATCH=$BENCH_TASKS_DIR/tl-crlf/reference.patch "$BENCH_DIR/run.sh" --arm baseline --task tl-crlf || log "baseline run failed"
FAKE_CLAUDE_FAIL=1 "$BENCH_DIR/run.sh" --arm baseline --task tl-date || log "baseline run failed"
FAKE_CLAUDE_PATCH=$BENCH_TASKS_DIR/tl-tag-filter/reference.patch FAKE_CLAUDE_VERDICT_QUALITY=changes \
  "$BENCH_DIR/run.sh" --arm baseline --task tl-tag-filter || log "baseline run failed"

sleep 1 # let the server finish storing
echo
echo "== factorybench report items"
factorybench report items --db "$db"
echo
echo "== factorybench report item bench/toy#1"
factorybench report item bench/toy#1 --db "$db"
echo
echo "== factorybench report factories"
factorybench report factories --db "$db"

# What the fakes were given. Each failed expectation is a problem; any problem fails the dry run.
echo
echo "== what the fakes were given"
problems=()
count() { jq -s "[.[] | $1] | length" "$FAKE_CLAUDE_LOG"; }
expect() { # DESCRIPTION BASE-SELECTION FILTER: every record BASE selects must also pass FILTER
  local all n
  all=$(count "$2")
  n=$(count "$2 | $3")
  if [ "$all" -gt 0 ] && [ "$n" -eq "$all" ]; then echo "ok    $1 ($n of $all)"; else echo "FAIL  $1 ($n of $all)"; problems+=("$1"); fi
}
pstack_prepare
want_skills=$(find "$PSTACK_DIR/skills" -mindepth 1 -maxdepth 1 -type d | wc -l)
echo "pinned pstack: pstack-claude@${PSTACK_REV:0:12}, tree sha256 ${PSTACK_TREE:0:12}, $want_skills skills at $PSTACK_DIR"
works='select(.kind == "work")'
reviews='select(.kind != "work")'
# Four baseline runs; a review pair for each scored run that left a commit: the t12 toy run, the t12-deep toy
# run, the baseline's toy, tl-crlf and tl-tag-filter (tl-date left nothing, so its review fails without a
# session): 5 x 2.
[ "$(count "$works")" -eq 4 ] && echo "ok    4 baseline sessions" || { echo "FAIL  $(count "$works") baseline sessions, want 4"; problems+=("baseline sessions"); }
[ "$(count "$reviews")" -eq 10 ] && echo "ok    10 review sessions: 2 for each of the 5 runs that left a result commit" || { echo "FAIL  $(count "$reviews") review sessions, want 10"; problems+=("review sessions"); }
expect "baseline: prompt starts with /pstack:poteto-mode" "$works" "select(.first_line == \"/pstack:poteto-mode\")"
expect "baseline: the pinned pstack dir is the only plugin" "$works" "select(.plugin_dirs == [\"$PSTACK_DIR\"])"
expect "baseline: every pstack skill is loaded, poteto-mode among them" "$works" "select(.skills_loaded == $want_skills and .poteto_mode)"
expect "baseline: the user's own settings stay out (--setting-sources project)" "$works" "select(.setting_sources == \"project\")"
expect "baseline: worker model claude-sonnet-5-5" "$works" "select(.model == \"claude-sonnet-5-5\")"
expect "baseline: the session may call Skill and Agent" "$works" "select(.allowed | test(\"Skill\") and test(\"Agent\"))"
expect "reviews: claude-opus-5-5" "$reviews" "select(.model == \"claude-opus-5-5\")"
expect "reviews: medium thinking" "$reviews" "select(.effort == \"medium\")"
expect "reviews: bugs and security run /pstack:thermo-nuclear-review" "$reviews | select(.kind == \"review-bugs-security\")" "select(.first_line == \"/pstack:thermo-nuclear-review\")"
expect "reviews: quality runs thermo-nuclear-code-quality-review and loads the ponytail-review plugin" "$reviews | select(.kind == \"review-quality\")" "select(.first_line == \"/pstack:thermo-nuclear-code-quality-review\" and (.plugin_dirs | length) == 2)"
expect "reviews: read-only (dontAsk, no shell, no Edit/Write/NotebookEdit)" "$reviews" "select(.permission_mode == \"dontAsk\" and (.disallowed | test(\"Bash\") and test(\"Edit\") and test(\"Write\") and test(\"NotebookEdit\")) and (.allowed | test(\"Bash|Edit|Write\") | not))"
expect "reviews: the checkout holds no hidden test" "$reviews" "select(.hidden_files == 0)"

# t12's omp sessions: the argv of every real session is in omp.log.
omp_sessions=$(jq -sc '[.[] | select(.argv != null and (.argv | index("--mode") != null)) | {role: (.argv[(.argv | index("--session-dir")) + 1] | split("/") | last | split("-")[0]),
  model: .argv[(.argv | index("--model")) + 1], thinking: (if (.argv | index("--thinking")) then .argv[(.argv | index("--thinking")) + 1] else null end)}]' "$FAKE_OMP_LOG")
echo "t12 omp sessions by role: $(jq -c 'group_by(.role) | map({(.[0].role): (map([.model, .thinking]) | unique | .[0])}) | add' <<<"$omp_sessions")"
n_rev=$(jq '[.[] | select((.role | startswith("reviewer")) and .model == "anthropic/claude-opus-5-5" and .thinking == "medium")] | length' <<<"$omp_sessions")
n_rev_all=$(jq '[.[] | select(.role | startswith("reviewer"))] | length' <<<"$omp_sessions")
n_other=$(jq '[.[] | select((.role | startswith("reviewer") | not) and .model == "anthropic/claude-sonnet-5-5" and .thinking == null)] | length' <<<"$omp_sessions")
n_other_all=$(jq '[.[] | select(.role | startswith("reviewer") | not)] | length' <<<"$omp_sessions")
if [ "$n_rev_all" -ge 1 ] && [ "$n_rev" -eq "$n_rev_all" ]; then echo "ok    t12: $n_rev reviewer sessions on anthropic/claude-opus-5-5, thinking medium"; else echo "FAIL  t12: reviewer sessions $n_rev of $n_rev_all on opus 5.5 medium"; problems+=("t12 reviewer model"); fi
if [ "$n_other_all" -ge 1 ] && [ "$n_other" -eq "$n_other_all" ]; then echo "ok    t12: $n_other worker sessions on anthropic/claude-sonnet-5-5, no thinking flag"; else echo "FAIL  t12: worker sessions $n_other of $n_other_all on sonnet 5.5"; problems+=("t12 worker model"); fi
n_lanes=$(jq -s '[.[] | select(.max_lanes != 1)] | length' "$BENCH_TASKS_DIR"/*/task.json "$dry_tasks"/*/task.json)
[ "$n_lanes" -eq 0 ] && echo "ok    t12: every task.json says max_lanes 1" || { echo "FAIL  $n_lanes tasks do not say max_lanes 1"; problems+=("max_lanes"); }

# The deep arm: its run records engineer deep, went through one engineer step and no tdd role, and
# FactoryBench knows its factory.
deep_home=$(ls -d "$BENCH_OUT"/*/dry-greet/t12-deep/state | head -1)
if [ "$(jq -r .engineer "$deep_home/runs/dry-greet.json")" = deep ]; then echo "ok    t12-deep: the run records engineer deep"; else echo "FAIL  t12-deep: the run does not record engineer deep"; problems+=("t12-deep engineer"); fi
deep_types=$(jq -r .type "$deep_home/runs/dry-greet.events.jsonl" | sort -u | tr '\n' ' ')
case $deep_types in
  *tdd-engineer*) case $deep_types in *tdd-red* | *tdd-green* | *tdd-list*) echo "FAIL  t12-deep: the run has tdd steps: $deep_types"; problems+=("t12-deep steps") ;; *) echo "ok    t12-deep: one engineer step, no analyzer, red, green or refactor" ;; esac ;;
  *) echo "FAIL  t12-deep: no tdd-engineer event: $deep_types"; problems+=("t12-deep steps") ;;
esac
# grep without -q reads all input: under pipefail, grep -q exiting early made the producer die of SIGPIPE and the check flaky.
if factorybench report factories --db "$db" 2>/dev/null | grep "bench-t12-deep" >/dev/null; then echo "ok    t12-deep: FactoryBench holds the factory bench-t12-deep"; else echo "FAIL  t12-deep: bench-t12-deep reported nothing"; problems+=("t12-deep factory"); fi

# Every scored run must have judged both reviewers, and a `changes` or a missing result must block.
runs=$(cat "$BENCH_OUT"/*/results.jsonl | jq -s .)
echo
echo "== review verdicts and checks per run"
jq -r '.[] | "\(.task) \(.arm): " + (.checks | map("\(.name)=\(if .passed then "pass" else "FAIL" end)") | join(" ")) + " | review: " + (.review // {} | .reviewers // [] | map("\(.name)=\(.verdict)") | join(" ")) + " | passed=\(.passed)"' <<<"$runs"
want=$(printf '%s\n' 'dry-greet t12 true' 'dry-greet t12-deep true' 'dry-greet baseline true' 'tl-crlf baseline true' 'tl-date baseline false' 'tl-tag-filter baseline false' | sort)
got=$(jq -r '.[] | "\(.task) \(.arm) \(.passed)"' <<<"$runs" | sort)
[ "$got" = "$want" ] && echo "ok    pass/fail per run as scripted" || { echo "FAIL  unexpected pass/fail per run: $got"; problems+=("results"); }

if [ ${#problems[@]} -gt 0 ]; then
  echo
  echo "DRY RUN FAILED: ${problems[*]}"
  exit 1
fi
echo
echo "DRY RUN PASSED for the three arms"
