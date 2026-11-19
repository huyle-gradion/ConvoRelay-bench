#!/usr/bin/env bash
# Arm baseline: ONE Claude Code session per task with the WHOLE pstack loaded, started with /poteto-mode.
# The strongest simple alternative to turbo-12f (decision D4): no phases, no gates, no external second opinion,
# but every skill, agent and routing hook of pstack, and the pattern of FactoryBench's scripts/claude-code-run.sh.
#
#   arm-baseline.sh --task ID --work DIR [--model M] [--max-cost USD]
#
# pstack is the plugin pinned by pstack.pin (lib/skills.sh builds it and checks its hash), loaded with
# --plugin-dir. --setting-sources project keeps the user's own settings, plugins and skills out of the session,
# so the pin is the only pstack it sees. The prompt is `/pstack:poteto-mode` and the issue text. The session
# is reported as one attempt: attempt.started, one usage event per model of the session (from the stream-json
# result line, via `factorybench claude-translate`), attempt.finished; its factory_config_version carries the
# Claude Code version, the model and the pstack revision and tree hash. This FactoryBench takes no OTLP, so
# none is sent. The session's model is --model; pstack routes its own subagents by its models.json.
# Writes DIR/arm.json: {attempt, commit, phase, note}.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
. "$(dirname "${BASH_SOURCE[0]}")/skills.sh"
need git jq claude factorybench

task= work= model=claude-sonnet-5-5 max_cost=6
while [ $# -gt 0 ]; do
  case $1 in
    --task) task=$2; shift 2 ;;
    --work) work=$2; shift 2 ;;
    --model) model=$2; shift 2 ;;
    --max-cost) max_cost=$2; shift 2 ;;
    *) die "arm-baseline.sh: unknown argument $1" ;;
  esac
done
[ -n "$task" ] && [ -n "$work" ] || die "usage: arm-baseline.sh --task ID --work DIR"
tdir=$(task_dir "$task")
product=$work/product
product_name=$(task_product "$task")
fb=${FB:-factorybench}
export FACTORYBENCH_TOKEN FACTORYBENCH_SPOOL=$work/fb-spool.jsonl
FACTORYBENCH_TOKEN=$(arm_token baseline)

ref=$(jq -er '.source.ref' "$tdir/task.json")
repo=${ref%#*} issue=${ref#*#}
att="cc-$(date -u +%Y%m%dT%H%M%S)-$$"
base=$(git -C "$product" rev-parse HEAD)
pstack_prepare
cfg="claude-code@$(claude --version | awk '{print $1}')+$model+pstack-claude@${PSTACK_REV:0:12}+tree-sha256:${PSTACK_TREE:0:12}+bench-baseline"
stream=$work/claude.jsonl
unit=$(product_argv "$product_name" unit | paste -sd' ' -)

# pstack leaves its decision trail and todo list in the work tree; they are not deliverables.
printf '%s\n' '.audit/' '/todo.md' >>"$product/.git/info/exclude"

prompt="/pstack:poteto-mode

You are working in the git repository in the current directory. Implement the issue below completely: change the code, and add or update tests for the behaviour it asks for, following the conventions you find in the repository. Before you finish, run the repository's unit tier ($unit) and make it pass. Commit your work on the current branch. Do not push. No person is available during this run: decide, act and report in your final message instead of asking.

$(cat "$tdir/issue.md")"

fb_emit attempt.started "$att" started \
  "$(jq -nc --arg r "$repo" --argjson i "$issue" --arg c "$cfg" --arg b "$base" \
    '{work_item: {repo: $r, issue: $i}, factory_config_version: $c, role: "full", base_commit: $b}')"

(cd "$product" && claude -p "$prompt" --output-format stream-json --verbose --model "$model" \
  --permission-mode acceptEdits --setting-sources project --plugin-dir "$PSTACK_DIR" \
  --allowedTools "Bash Edit Write Read Glob Grep Skill Agent Task TodoWrite TaskCreate TaskUpdate TaskList TaskGet" \
  --max-budget-usd "$max_cost" --no-session-persistence) >"$stream" 2>"$work/claude.err"
rc=$?
note="claude exit $rc"
# A baseline that did not load pstack is not the baseline: say so instead of scoring it as one.
if ! jq -e 'select(.type == "system" and .subtype == "init") | .slash_commands | index("pstack:poteto-mode")' "$stream" >/dev/null 2>&1; then
  note="$note; INVALID: pstack:poteto-mode is not among the session's slash commands, pstack did not load"
  pstack_loaded=0
fi

tr=$("$fb" claude-translate "$stream" 2>/dev/null || echo '{"usage":[],"finished":{"status":"failed","reason":"claude-translate failed"}}')
n=$(jq '.usage | length' <<<"$tr")
for ((i = 0; i < n; i++)); do
  fb_emit usage "$att" "usage:$((i + 1))" "$(jq -c ".usage[$i] + {phase: \"implement\"}" <<<"$tr")"
done

# The session may or may not have committed; what it left in the working tree is its result.
git -C "$product" add -A
git -C "$product" -c user.name=bench -c user.email=bench@localhost -c commit.gpgsign=false \
  commit -q -m "bench: baseline working tree" >/dev/null 2>&1 || true
commit=$(git -C "$product" rev-parse HEAD)
[ "$commit" != "$base" ] || { note="$note; the session changed nothing"; commit=; }

fb_emit attempt.finished "$att" finished "$(jq -c '.finished' <<<"$tr")"
phase=$(jq -r '.finished.status' <<<"$tr")
[ "${pstack_loaded:-1}" = 1 ] || phase=invalid
jq -nc --arg a "$att" --arg c "$commit" --arg p "$phase" --arg n "$note" '{attempt: $a, commit: $c, phase: $p, note: $n}' >"$work/arm.json"
