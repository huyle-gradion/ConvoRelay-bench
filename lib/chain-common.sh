# Shared by chain.sh and prove-chain.sh: the chained benchmark over the ChatBridge product. Source it after common.sh.
# shellcheck shell=bash

: "${BENCH_CHAINS_DIR:=$BENCH_DIR/chains}"

chain_dir() {
  [ -f "$BENCH_CHAINS_DIR/$1/order.json" ] || die "no chain $1 under $BENCH_CHAINS_DIR"
  echo "$BENCH_CHAINS_DIR/$1"
}

# chain_ids CHAIN: the task ids in chain order, one per line.
chain_ids() { jq -r '.tasks[].id' "$(chain_dir "$1")/order.json"; }
chain_base() { jq -r '.base' "$(chain_dir "$1")/order.json"; }
# chain_expected CHAIN ID: how many hidden tests the task has (order.json, checked by prove-chain.sh).
chain_expected() { jq -er --arg i "$2" '.tasks[] | select(.id == $i) | .hidden_tests' "$(chain_dir "$1")/order.json"; }
chain_lower() { echo "$1" | tr 'A-Z' 'a-z'; }

# The node that runs the product's Vitest, tsc and ESLint, and the directory the cage must be told about
# (T12_TOOLCHAIN_DIRS): the install directory that holds bin/node, not a version manager's shim.
chain_node() {
  local n=${BENCH_NODE:-$(command -v node)}
  [ -n "$n" ] || die "node is not on PATH (BENCH_NODE=PATH names one)"
  readlink -f "$n"
}
chain_node_dir() { dirname "$(dirname "$(chain_node)")"; }

# chain_repo BASE DEST: a fresh git repository on `main` with ONE commit holding the product at BASE: the
# whole ConvoRelay repository at BASE. This bench no longer lives in ConvoRelay, but BASE commits before the move
# (the chain's default 550932e) still hold factory/bench with the hidden tests and reference patches, so it is
# left out: nothing of the bench can be in what an arm sees, whatever commit BASE is. The profile is the repo's own with the bare program `node` replaced by the node of this machine (its real install, not a shim),
# and without `intake` and `delivery`: a bench repo has no Asana project and no forge to push to.
chain_repo() {
  local base=$1 dest=$2 node
  node=$(chain_node)
  mkdir -p "$dest"
  git -C "$REPO_ROOT" archive --format=tar "$base" -- . ':(exclude)factory/bench' | tar -x -C "$dest"
  [ -f "$dest/.t12/project.json" ] || die "$base has no .t12/project.json"
  jq --arg node "$node" 'del(.intake, .delivery) | walk(if . == "node" then $node else . end)' \
    "$dest/.t12/project.json" >"$dest/.t12/project.json.new" && mv "$dest/.t12/project.json.new" "$dest/.t12/project.json"
  git -C "$dest" init -q -b main
  git -C "$dest" -c user.name=bench -c user.email=bench@localhost add -A
  git -C "$dest" -c user.name=bench -c user.email=bench@localhost -c commit.gpgsign=false commit -q -m "base: chatbridge $base"
  git -C "$dest" rev-parse HEAD
}

# chain_deps PRODUCT_DIR: chatbridge/node_modules as a real directory (the factory refuses a link out of the
# worktree). BENCH_NODE_MODULES=DIR copies that one (a checkout that had `npm ci`); otherwise `npm ci --offline`
# runs on the product's own lock file, which needs the npm cache to be warm.
chain_deps() {
  local product=$1
  if [ -n "${BENCH_NODE_MODULES:-}" ]; then
    [ -d "$BENCH_NODE_MODULES" ] || die "BENCH_NODE_MODULES=$BENCH_NODE_MODULES is not a directory"
    cp -a "$BENCH_NODE_MODULES" "$product/chatbridge/node_modules"
  else
    (cd "$product/chatbridge" && PATH=$(dirname "$(chain_node)"):$PATH npm ci --offline --ignore-scripts >"$product/../npm-ci.log" 2>&1) ||
      die "npm ci --offline failed in the product (log: $product/../npm-ci.log); warm the npm cache or set BENCH_NODE_MODULES"
  fi
  [ -d "$product/chatbridge/node_modules/vitest" ] || die "chatbridge/node_modules has no vitest"
}

# chain_vitest CHECKOUT OUT.json [FILTER...]: the product's Vitest in CHECKOUT (a checkout whose
# chatbridge/node_modules exists, linked or not), JSON report in OUT.json. Exit status is Vitest's.
# The arm's code runs on this host: only PATH, a private HOME and TMPDIR reach it, no secret of the caller.
chain_vitest() {
  local co=$1 out=$2 home node rc
  shift 2
  rm -f "$out"
  home=$(mktemp -d "${TMPDIR:-/tmp}/bench-vitest-home.XXXXXX") || return 1
  node=$(chain_node)
  (cd "$co" && env -i PATH="$PATH" HOME="$home" TMPDIR="${TMPDIR:-/tmp}" timeout "${BENCH_CHECK_TIMEOUT:-600}" "$node" \
    chatbridge/node_modules/vitest/vitest.mjs run --root chatbridge \
    --reporter=json --outputFile="$out" --configLoader runner "$@" >"$out.log" 2>&1)
  rc=$?
  rm -rf "$home"
  return "$rc"
}

# vitest_counts OUT.json [PREFIX]: "passed total" of the tests whose full name starts with PREFIX (all when
# empty); "0 0" when Vitest wrote no report (no test file found, a crash).
vitest_counts() {
  local out=$1 prefix=${2:-}
  [ -s "$out" ] || { echo "0 0"; return; }
  jq -r --arg p "$prefix" '[.testResults[].assertionResults[] | select(.fullName | startswith($p))] | "\(map(select(.status == "passed")) | length) \(length)"' "$out"
}

# chain_install_hidden CHAIN CHECKOUT ID...: the hidden tests of the tasks laid into the checkout. They only ever
# enter a scoring checkout made after the arm has finished; chatbridge/vitest.config.ts includes src/**/*.test.ts.
chain_install_hidden() {
  local chain=$1 co=$2 id f
  shift 2
  mkdir -p "$co/chatbridge/src/zz-hidden"
  for id in "$@"; do
    for f in "$(chain_dir "$chain")/$id"/hidden/*.test.ts; do
      [ -f "$f" ] || die "task $id has no hidden test"
      cp "$f" "$co/chatbridge/src/zz-hidden/"
    done
  done
}

# chain_check_clone REPO REV DEST NODE_MODULES: a clean checkout of REV for scoring, the dependencies linked in.
chain_check_clone() {
  local repo=$1 rev=$2 dest=$3 nm=$4
  git clone -q --no-checkout "$repo" "$dest" 2>/dev/null && git -C "$dest" checkout -q --detach "$rev" || return 1
  ln -s "$nm" "$dest/chatbridge/node_modules"
}
