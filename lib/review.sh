#!/usr/bin/env bash
# The review both arms get, held equal (decisions D4 and D14): two read-only Claude Code sessions on the final
# diff, in parallel, both on Claude Opus 5.5 with medium thinking.
#
#   review.sh --task ID --repo DIR --commit SHA [--out-dir DIR]
#
#   bugs-security  `pstack:thermo-nuclear-review`
#   quality        `bench-review:ponytail-review` and `pstack:thermo-nuclear-code-quality-review`
#
# Each session is read-only: it may read files (Read, Glob, Grep) and nothing else (no shell, no edit, no
# write, no test run, no subagent). It reviews `git diff BASE COMMIT` in a fresh clone of DIR at COMMIT, made
# without the task's hidden tests, so a reviewer never sees them. The verdict is `approve` only when both
# sessions end their reply with `VERDICT: approve`; a session that fails, runs out of budget, or ends without a
# verdict line is `unavailable` and counts against the diff (QC stays closed when a reviewer cannot run, D14).
# Prints one JSON object {passed, cost_usd, reviewers: [{name, verdict, cost_usd, reason}]}; with --out-dir each
# session's stream-json and final text are kept there. Exit status 0 whatever the verdict.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
. "$(dirname "${BASH_SOURCE[0]}")/skills.sh"

task= repo= commit= out_dir=
while [ $# -gt 0 ]; do
  case $1 in
    --task) task=$2; shift 2 ;;
    --repo) repo=$2; shift 2 ;;
    --commit) commit=$2; shift 2 ;;
    --out-dir) out_dir=$2; shift 2 ;;
    *) die "review.sh: unknown argument $1" ;;
  esac
done
[ -n "$task" ] && [ -n "$repo" ] && [ -n "$commit" ] || die "usage: review.sh --task ID --repo DIR --commit SHA [--out-dir DIR]"
tdir=$(task_dir "$task")
: "${BENCH_REVIEW_MAX_COST:=2}" # USD one review session may spend
need git jq claude
pstack_prepare

tmp=$(mktemp -d "${TMPDIR:-/tmp}/bench-review.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
co=$tmp/checkout
git clone -q --no-checkout "$repo" "$co" && git -C "$co" checkout -q --detach "$commit" && git -C "$co" remote remove origin ||
  die "review.sh: cannot check out $commit of $repo"
base=$(git -C "$co" rev-list --max-parents=0 "$commit" | tail -1)
ponytail_plugin "$tmp/ponytail"
[ -z "$out_dir" ] || mkdir -p "$out_dir"
# The reviewers get no shell: `git diff --output=PATH` writes anywhere the user can. The diff is a file in the clone instead.
diff_name=REVIEW.diff
git -C "$co" diff "$base" "$commit" >"$co/$diff_name" || die "review.sh: cannot diff $base $commit"

issue=$(cat "$tdir/issue.md")
common="You are reviewing a change in the git repository in the current directory. The diff \`git diff $base $commit\` is in the file $diff_name here (the base is $base, the change is checked out). You are read-only: read files; you have no shell, so do not try to edit, write, run git or run tests. The change was written for this issue:

$issue

When your review is done, end your final reply with exactly one last line, \`VERDICT: approve\` or \`VERDICT: changes\`. Use \`approve\` only if you found nothing that must change before this is merged; findings you would only suggest do not block. Use \`changes\` for anything you rate medium priority or higher."

prompt_bugs="/pstack:thermo-nuclear-review

$common

Scope: bugs, changes that break existing behaviour, and security problems in the added or modified code."
prompt_quality="/pstack:thermo-nuclear-code-quality-review

Also run the \`bench-review:ponytail-review\` skill (Skill tool) on the same diff and merge its findings into yours.

$common

Scope: maintainability, abstraction quality and needless code in the added or modified code. Whether the logic is right is the other reviewer's job."

# review NAME PROMPT: one read-only session; leaves NAME.json (the verdict object) in $tmp.
review() {
  local name=$1 prompt=$2 stream=$tmp/$1.jsonl text verdict cost reason rc
  (cd "$co" && claude -p "$prompt" --output-format stream-json --verbose --model "$BENCH_REVIEW_MODEL" \
    --effort "$BENCH_REVIEW_EFFORT" --setting-sources project --plugin-dir "$PSTACK_DIR" --plugin-dir "$tmp/ponytail" \
    --permission-mode dontAsk \
    --allowedTools "Read Glob Grep Skill" \
    --disallowedTools "Bash Edit Write NotebookEdit Agent Task" \
    --max-budget-usd "$BENCH_REVIEW_MAX_COST" --no-session-persistence) >"$stream" 2>"$tmp/$name.err"
  rc=$?
  text=$(jq -rs 'map(select(.type == "result")) | last | if . == null or .is_error then "" else (.result // "") end' "$stream" 2>/dev/null)
  cost=$(jq -rs 'map(select(.type == "result")) | last | (.total_cost_usd // 0)' "$stream" 2>/dev/null || echo 0)
  verdict=$(printf '%s\n' "$text" | grep -E '^[[:space:]]*\**VERDICT: (approve|changes)\**[[:space:]]*$' | tail -1 | sed -E 's/.*VERDICT: (approve|changes).*/\1/')
  if [ -n "$verdict" ]; then
    reason="$name: $verdict"
  else
    verdict=unavailable
    reason="$name: no verdict (claude exit $rc: $(head -c 120 "$tmp/$name.err" | tr '\n' ' '))"
  fi
  printf '%s\n' "$text" >"$tmp/$name.md"
  jq -nc --arg n "$name" --arg v "$verdict" --argjson c "${cost:-0}" --arg r "$reason" '{name: $n, verdict: $v, cost_usd: $c, reason: $r}' >"$tmp/$name.json"
}

review bugs-security "$prompt_bugs" &
review quality "$prompt_quality" &
wait

if [ -n "$out_dir" ]; then
  for n in bugs-security quality; do cp "$tmp/$n.jsonl" "$tmp/$n.md" "$out_dir/" 2>/dev/null || true; done
fi
jq -sc '{passed: all(.[]; .verdict == "approve"), cost_usd: (map(.cost_usd) | add), reviewers: .}' "$tmp/bugs-security.json" "$tmp/quality.json"
