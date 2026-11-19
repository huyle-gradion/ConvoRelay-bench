# Shared by run.sh, prove.sh and the arms. Source it; it sets nothing but variables and functions.
# shellcheck shell=bash

BENCH_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# The repository this bench benchmarks (ConvoRelay) lives next to this one by default; CONVORELAY_DIR=PATH names
# another clone. Task and chain bases are ConvoRelay commits, `git archive`d from it; the t12 programs are built
# from its factory/ module.
CONVORELAY_DIR=${CONVORELAY_DIR:-$BENCH_DIR/../ConvoRelay}
[ -d "$CONVORELAY_DIR" ] || { echo "bench: CONVORELAY_DIR=$CONVORELAY_DIR is not a directory (clone ConvoRelay next to this repository or set CONVORELAY_DIR=PATH)" >&2; exit 1; }
CONVORELAY_DIR=$(cd "$CONVORELAY_DIR" && pwd)
{ git -C "$CONVORELAY_DIR" rev-parse --git-dir >/dev/null 2>&1 && [ -f "$CONVORELAY_DIR/factory/go.mod" ]; } ||
  { echo "bench: CONVORELAY_DIR=$CONVORELAY_DIR is not a ConvoRelay checkout (a git repository with factory/go.mod); set CONVORELAY_DIR=PATH" >&2; exit 1; }
REPO_ROOT=$CONVORELAY_DIR
FACTORY_DIR=$CONVORELAY_DIR/factory
: "${BENCH_TASKS_DIR:=$BENCH_DIR/tasks}"
: "${BENCH_PRODUCTS:=$BENCH_DIR/products.json}"
: "${BENCH_OUT:=$BENCH_DIR/.runs}"

# Held equal on both arms (README "Held equal", decisions D4 and D14): the reviewers are Claude Opus 5.5 with
# medium thinking, whatever the arm. Not options on purpose.
BENCH_REVIEW_MODEL=claude-opus-5-5
BENCH_REVIEW_EFFORT=medium

die() { echo "bench: $*" >&2; exit 1; }
log() { echo "bench: $*" >&2; }

need() {
  local c
  for c in "$@"; do command -v "$c" >/dev/null || die "$c is not on PATH"; done
}

now() { date +%s.%N; }
elapsed() { awk -v a="$1" -v b="$2" 'BEGIN { printf "%.1f", b - a }'; }
utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Every task id under the tasks directory, sorted.
all_tasks() {
  local d
  for d in "$BENCH_TASKS_DIR"/*/; do [ -f "$d/task.json" ] && basename "$d"; done | sort
}

task_dir() {
  [ -f "$BENCH_TASKS_DIR/$1/task.json" ] || die "no task $1 under $BENCH_TASKS_DIR"
  echo "$BENCH_TASKS_DIR/$1"
}

# `product` of a task: "<product> <base>" on one line.
task_product() { awk '{print $1}' "$(task_dir "$1")/product"; }
task_base() { awk '{print $2}' "$(task_dir "$1")/product"; }

product_field() { jq -er --arg p "$1" --arg f "$2" '.[$p][$f]' "$BENCH_PRODUCTS"; }

# product_argv PRODUCT FIELD: an argv of products.json, one word per line (read it with mapfile -t).
product_argv() { jq -er --arg p "$1" --arg f "$2" '.[$p][$f][]' "$BENCH_PRODUCTS"; }

# product_repo TASK DEST: a fresh git repository on `main` with ONE commit holding the product at the
# task's base. No history of this repository comes along, so an arm cannot read the hidden tests,
# the reference patches or later commits out of `.git`.
product_repo() {
  local task=$1 dest=$2 product base kind
  product=$(task_product "$task")
  base=$(task_base "$task")
  kind=$(product_field "$product" kind)
  mkdir -p "$dest"
  case $kind in
    git) git -C "$REPO_ROOT" archive --format=tar "$base" | tar -x -C "$dest" ;;
    tree) cp -a "$(dirname "$BENCH_PRODUCTS")/$(product_field "$product" path)/." "$dest/" ;;
    *) die "product $product: unknown kind $kind" ;;
  esac
  git -C "$dest" init -q -b main
  git -C "$dest" -c user.name=bench -c user.email=bench@localhost add -A
  git -C "$dest" -c user.name=bench -c user.email=bench@localhost -c commit.gpgsign=false commit -q -m "base: $product $base"
  git -C "$dest" rev-parse HEAD
}

# fb_emit TOKEN_VAR TYPE ATTEMPT KEY JSON [TS]: one FactoryBench event; silent when FACTORYBENCH_URL is unset.
# factorybench always exits 0 and spools what it could not send.
fb_emit() {
  [ -n "${FACTORYBENCH_URL:-}" ] || return 0
  local type=$1 attempt=$2 key=$3 json=$4
  ${FB:-factorybench} emit "$type" --attempt "$attempt" --key "$key" --json "$json" || true
}

# The token of an arm: FACTORYBENCH_TOKEN_<ARM> (t12, t12-deep as T12_DEEP, baseline), else FACTORYBENCH_TOKEN.
arm_token() {
  local var="FACTORYBENCH_TOKEN_$(echo "$1" | tr a-z- A-Z_)"
  echo "${!var:-${FACTORYBENCH_TOKEN:-}}"
}
