#!/usr/bin/env bash
# Proves a chain: its hidden tests fail on the base and pass on the reference solution, in chain order.
#
#   prove-chain.sh [--chain us-s1-01]
#
# Like prove.sh, for a chain. It builds the product from the chain's base commit (lib/chain-common.sh chain_repo,
# the same repository chain.sh gives an arm), then
#   1. checks the task files: each task.json is what build-tasks.sh writes from the sub-task markdown, the markdown
#      passes `t12-adapter spec-check` (when bin/t12-adapter is built), order.json's depends_on equals the file's,
#      every task has a hidden test file and a reference.patch that touches only chatbridge/;
#   2. for each task in chain order:
#        before  the task's hidden tests, run on the base commit AND on main as the earlier references leave it,
#                must fail one by one (0 of N pass, N equal to order.json's hidden_tests; a collection error is not N);
#        after   reference.patch is applied to main and committed; then the unit tier, tsc and ESLint must pass, the
#                task's hidden tests must all pass, and so must the hidden tests of every earlier task (regression).
# Nothing is reported to FactoryBench. Exit status 1 when any rule is broken. Needs node and a warm npm cache
# (or BENCH_NODE_MODULES=DIR).
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
. "$(dirname "${BASH_SOURCE[0]}")/lib/chain-common.sh"
need git jq node npm

chain=us-s1-01
while [ $# -gt 0 ]; do
  case $1 in
    --chain) chain=$2; shift 2 ;;
    *) die "usage: prove-chain.sh [--chain ID]" ;;
  esac
done
cdir=$(chain_dir "$chain")
mapfile -t ids < <(chain_ids "$chain")
base=$(chain_base "$chain")

tmp=$(mktemp -d "${TMPDIR:-/tmp}/bench-prove-chain.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
product=$tmp/product
bad=0
problems_all=()

base_commit=$(chain_repo "$base" "$product") || die "cannot make the product repository from $base"
chain_deps "$product"
nm=$(cd "$product/chatbridge/node_modules" && pwd -P)
node=$(chain_node)

# 1. task files
if ! "$cdir/build-tasks.sh" --check 2>"$tmp/tasks.err"; then problems_all+=("task.json differs from the markdown: $(head -c 300 "$tmp/tasks.err")"); fi
for id in "${ids[@]}"; do
  p=()
  [ "$(jq -r .id "$cdir/$id/task.json")" = "$id" ] || p+=("task id")
  [ "$(jq -c '.depends_on // []' "$cdir/$id/task.json")" = "$(jq -c --arg i "$id" '.tasks[] | select(.id == $i) | .depends_on' "$cdir/order.json")" ] || p+=("depends_on differs from order.json")
  jq -e '.max_lanes == 1 and .product == "chatbridge" and (.source.ref | test("^bench/chatbridge#[0-9]+$"))' "$cdir/$id/task.json" >/dev/null || p+=("max_lanes/product/source.ref")
  ls "$cdir/$id"/hidden/*.test.ts >/dev/null 2>&1 || p+=("no hidden test")
  [ -f "$cdir/$id/reference.patch" ] || p+=("no reference.patch")
  if [ -f "$cdir/$id/reference.patch" ] && grep '^+++ ' "$cdir/$id/reference.patch" | grep -qv '^+++ b/chatbridge/'; then p+=("reference.patch touches files outside chatbridge/"); fi
  if [ -x "$FACTORY_DIR/bin/t12-adapter" ] || [ -n "${T12_BIN:-}" ]; then
    "${T12_BIN:-$FACTORY_DIR/bin}/t12-adapter" spec-check --forge asana <"$BENCH_DIR/breakdown/US-S1-01/$id.md" >"$tmp/spec.json" 2>&1 ||
      p+=("spec-check refuses the sub-task: $(jq -rc .refusals "$tmp/spec.json" 2>/dev/null)")
  fi
  [ ${#p[@]} -eq 0 ] || problems_all+=("$id: ${p[*]}")
done

printf '%-6s %4s %5s  %-14s %-14s  %-8s %-8s %-8s %-10s %s\n' task exp N "skeleton (hid)" "before (hid)" unit tsc eslint after-hid "regression / problems"
printf '%-6s %4s %5s  %-14s %-14s  %-8s %-8s %-8s %-10s %s\n' ------ ---- ----- -------------- -------------- ---- --- ------ --------- ---------------------

# hidden_run REV IDS...: "pass total" of the hidden tests of IDS on a clone of REV (a commit of $product).
hidden_run() {
  local rev=$1 co
  shift
  co=$(mktemp -d "$tmp/co.XXXXXX")
  chain_check_clone "$product" "$rev" "$co" "$nm" || { echo "0 0"; return; }
  chain_install_hidden "$chain" "$co" "$@"
  chain_vitest "$co" "$co.json" zz-hidden
  vitest_counts "$co.json" hidden
}

done_ids=()
for id in "${ids[@]}"; do
  problems=()
  want=$(chain_expected "$chain" "$id")
  main_before=$(git -C "$product" rev-parse main)

  # before: on the skeleton and on main with the earlier references
  read -r sp st < <(hidden_run "$base_commit" "$id")
  read -r bp bt < <(hidden_run "$main_before" "$id")
  [ "$sp" = 0 ] && [ "$st" -gt 0 ] || problems+=("a hidden test passes or none ran on the skeleton ($sp/$st)")
  [ "$bp" = 0 ] && [ "$bt" -gt 0 ] || problems+=("a hidden test passes or none ran on main before ($bp/$bt)")
  [ "$bt" = "$want" ] || problems+=("order.json says $want hidden tests, the file has $bt")

  # after: the reference
  unit=- tsc=- lint=- ap=0 at=0 reg=ok
  if git -C "$product" apply "$cdir/$id/reference.patch" 2>"$tmp/apply.err"; then
    git -C "$product" -c user.name=bench -c user.email=bench@localhost add -A
    git -C "$product" -c user.name=bench -c user.email=bench@localhost -c commit.gpgsign=false commit -q -m "reference $id"
    co=$(mktemp -d "$tmp/ref.XXXXXX")
    chain_check_clone "$product" "$(git -C "$product" rev-parse HEAD)" "$co" "$nm"
    chain_vitest "$co" "$co.unit.json" && unit=pass || { unit=FAIL; problems+=("unit tier fails on the reference"); }
    (cd "$co" && "$node" chatbridge/node_modules/typescript/bin/tsc --noEmit -p chatbridge/tsconfig.json >"$tmp/tsc.log" 2>&1) && tsc=pass || { tsc=FAIL; problems+=("tsc: $(head -c 200 "$tmp/tsc.log" | tr '\n' ' ')"); }
    (cd "$co" && "$node" chatbridge/node_modules/eslint/bin/eslint.js --config chatbridge/eslint.config.js chatbridge >"$tmp/lint.log" 2>&1) && lint=pass || { lint=FAIL; problems+=("eslint: $(head -c 200 "$tmp/lint.log" | tr '\n' ' ')"); }
    chain_install_hidden "$chain" "$co" "$id"
    chain_vitest "$co" "$co.hid.json" zz-hidden
    read -r ap at < <(vitest_counts "$co.hid.json" hidden)
    [ "$ap" = "$want" ] && [ "$at" = "$want" ] || problems+=("hidden on the reference: $ap/$at, want $want/$want: $(jq -r '[.testResults[].assertionResults[] | select(.status != "passed") | .fullName] | .[0:3] | join(" | ")' "$co.hid.json" 2>/dev/null | head -c 300)")
    if [ ${#done_ids[@]} -gt 0 ]; then
      read -r rp rt < <(hidden_run "$(git -C "$product" rev-parse HEAD)" "${done_ids[@]}")
      wantreg=0
      for d in "${done_ids[@]}"; do wantreg=$((wantreg + $(chain_expected "$chain" "$d"))); done
      reg="$rp/$rt"
      [ "$rp" = "$wantreg" ] && [ "$rt" = "$wantreg" ] || problems+=("regression: earlier hidden tests $rp/$rt, want $wantreg")
    fi
  else
    problems+=("reference.patch does not apply: $(head -c 200 "$tmp/apply.err" | tr '\n' ' ')")
    git -C "$product" checkout -q -- . 2>/dev/null
  fi
  done_ids+=("$id")
  printf '%-6s %4s %5s  %-14s %-14s  %-8s %-8s %-8s %-10s %s\n' "$id" "$want" "$bt" "$sp/$st" "$bp/$bt" "$unit" "$tsc" "$lint" "$ap/$at" \
    "$([ ${#problems[@]} -eq 0 ] && echo "ok ($reg)" || echo "PROBLEM: ${problems[*]}")"
  [ ${#problems[@]} -eq 0 ] || bad=1
done

if [ ${#problems_all[@]} -gt 0 ]; then
  bad=1
  printf 'PROBLEM: %s\n' "${problems_all[@]}"
fi
if [ $bad -eq 0 ]; then echo "prove-chain: $chain ok: the base fails every hidden test set, the reference passes all ${#ids[@]} in order"; fi
exit $bad
