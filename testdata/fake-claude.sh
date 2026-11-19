#!/usr/bin/env bash
# Stand-in for `claude` in the dry run: no model, no network. It accepts the flags lib/arm-baseline.sh and
# lib/review.sh pass, writes one JSON line about what it was given to FAKE_CLAUDE_LOG, and prints a
# stream-json transcript whose last line is a result with the usage of one model, the shape
# `factorybench claude-translate` reads. Like the real thing, its `init` line lists `<plugin>:<skill>` slash
# commands for the skills of every --plugin-dir it was given, so the baseline's check that pstack loaded runs.
#
# A work session (the baseline arm: the prompt starts with /pstack:poteto-mode) applies FAKE_CLAUDE_PATCH, the
# task's reference solution by the dry run's choice, to the working tree without committing. A review session
# (the prompt asks for a VERDICT line) changes nothing and answers `VERDICT: approve`.
#   FAKE_CLAUDE_PATCH   patch to apply in the current directory; unset or empty: change nothing
#   FAKE_CLAUDE_FAIL    set: a work session prints an error result (is_error true) after the work
#   FAKE_CLAUDE_VERDICT_BUGS, FAKE_CLAUDE_VERDICT_QUALITY   `changes` makes that review answer VERDICT: changes
#   FAKE_CLAUDE_LOG     file the one-line records go to (default: none)
if [ "${1:-}" = --version ]; then echo "2.1.325 (Claude Code)"; exit 0; fi
prompt= model=claude-sonnet-5-5 effort= sources= perm= allowed= disallowed= budget=
plugins=()
if [ "${1:-}" = -p ]; then prompt=$2; shift 2; fi
while [ $# -gt 0 ]; do
  case $1 in
    --model) model=$2; shift 2 ;;
    --effort) effort=$2; shift 2 ;;
    --setting-sources) sources=$2; shift 2 ;;
    --permission-mode) perm=$2; shift 2 ;;
    --allowedTools) allowed=$2; shift 2 ;;
    --disallowedTools) disallowed=$2; shift 2 ;;
    --max-budget-usd) budget=$2; shift 2 ;;
    --plugin-dir) plugins+=("$2"); shift 2 ;;
    *) shift ;;
  esac
done

json_array() { if [ $# -eq 0 ]; then echo '[]'; else printf '%s\n' "$@" | jq -R . | jq -sc .; fi; }
slash=()
for p in "${plugins[@]}"; do
  name=$(jq -r .name "$p/.claude-plugin/plugin.json" 2>/dev/null) || continue
  for s in "$p"/skills/*/SKILL.md; do [ -f "$s" ] && slash+=("$name:$(basename "$(dirname "$s")")"); done
done
slash_json=$(json_array "${slash[@]}")

first=${prompt%%$'\n'*}
kind=work
case $prompt in
  *"VERDICT:"*) case $first in */pstack:thermo-nuclear-review) kind=review-bugs-security ;; *) kind=review-quality ;; esac ;;
esac

if [ -n "${FAKE_CLAUDE_LOG:-}" ]; then
  jq -nc --arg kind "$kind" --arg model "$model" --arg effort "$effort" --arg sources "$sources" --arg perm "$perm" \
    --arg allowed "$allowed" --arg disallowed "$disallowed" --arg budget "$budget" --arg first "$first" --arg cwd "$PWD" \
    --argjson hidden "$(find . -name 'zz_hidden_*' -not -path './.git/*' | wc -l)" \
    --argjson plugins "$(json_array "${plugins[@]}")" --argjson slash "$slash_json" \
    '{kind: $kind, model: $model, effort: $effort, setting_sources: $sources, permission_mode: $perm, allowed: $allowed,
      disallowed: $disallowed, budget: $budget, first_line: $first, cwd: $cwd, hidden_files: $hidden, plugin_dirs: $plugins, skills_loaded: ($slash | length),
      poteto_mode: ($slash | index("pstack:poteto-mode") != null)}' >>"$FAKE_CLAUDE_LOG"
fi

text=done
case $kind in
  work) [ -z "${FAKE_CLAUDE_PATCH:-}" ] || git apply "$FAKE_CLAUDE_PATCH" || exit 1 ;;
  review-bugs-security) text="No findings in the diff.\\nVERDICT: ${FAKE_CLAUDE_VERDICT_BUGS:-approve}" ;;
  review-quality) text="Nothing to simplify.\\nVERDICT: ${FAKE_CLAUDE_VERDICT_QUALITY:-approve}" ;;
esac

sid=00000000-0000-4000-8000-000000000001
printf '{"type":"system","subtype":"init","session_id":"%s","model":"%s","slash_commands":%s}\n' "$sid" "$model" "$slash_json"
printf '{"type":"assistant","message":{"model":"%s","role":"assistant","content":[{"type":"text","text":"done"}]},"session_id":"%s"}\n' "$model" "$sid"
is_error=false subtype=success
[ "$kind" != work ] || [ -z "${FAKE_CLAUDE_FAIL:-}" ] || { is_error=true; subtype=error_max_turns; }
printf '{"type":"result","subtype":"%s","is_error":%s,"result":"%s","duration_ms":4200,"duration_api_ms":3800,"num_turns":6,"total_cost_usd":0.0421,"session_id":"%s","modelUsage":{"%s":{"inputTokens":1200,"outputTokens":800,"cacheReadInputTokens":45000,"cacheCreationInputTokens":6000,"webSearchRequests":0,"costUSD":0.0421,"thinkingTokens":0}}}\n' \
  "$subtype" "$is_error" "$text" "$sid" "$model"
