#!/usr/bin/env bash
# Writes <ID>/task.json for every sub-task of the chain from the sub-task markdown, the way the Asana intake
# (internal/adapters/intake/spec.go, SpecCheck and issueToTask) builds a task file from a task's text:
#
#   title                the task's title (the markdown's first heading without its "S1-A: ")
#   acceptance_criteria  the "- " items (a "[ ]" box is dropped) under the first "Acceptance criteria" heading
#   touches              the paths of the "Touches:" line, cleaned and sorted
#   depends_on           the ids of the "Depends on:" line, sorted (the S-ids stand for the Asana ids)
#   product              "chatbridge" (the Asana tag decides it in the real intake)
#   source               {adapter: bench, ref: bench/chatbridge#<n>}, n the place in the chain; that ref is what
#                        makes the runner report an attempt to FactoryBench
#
# The bench adds what the intake does not: base, max_lanes 1 (lanes are frozen, D3) and the budgets. The
# summary, Pointers, Decisions and Out of scope sections are not part of a task file; intake drops them too.
#
#   build-tasks.sh [--check]     --check writes nothing and fails when a task.json differs from what this would write
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
docs=${CHAIN_DOCS:-$(cd "$here/../.." && pwd)/breakdown/US-S1-01}
check=0
[ "${1:-}" = --check ] && check=1

mapfile -t ids < <(jq -r '.tasks[].id' "$here/order.json")
n=0
bad=0
for id in "${ids[@]}"; do
  n=$((n + 1))
  md=$docs/$id.md
  [ -f "$md" ] || { echo "build-tasks: no $md" >&2; exit 1; }
  title=$(sed -n '1s/^# [^:]*: *//p' "$md")
  criteria=$(awk '/^#+ +Acceptance criteria/ {on = 1; next} /^#+ / {on = 0} on && /^[-*] / {sub(/^[-*] +(\[[ xX]\] +)?/, ""); print}' "$md" | jq -Rs 'split("\n") | map(select(. != ""))')
  touches=$(sed -n 's/^[Tt]ouches: *//p' "$md" | tr ',' '\n' | sed 's/^ *//; s/ *$//' | { grep -v '^$' || true; } | sort -u | jq -Rs 'split("\n") | map(select(. != ""))')
  depends=$(sed -n 's/^[Dd]epends on: *//p' "$md" | tr ',' '\n' | sed 's/^ *//; s/ *$//' | { grep -vi '^none$' || true; } | { grep -v '^$' || true; } | sort -u | jq -Rs 'split("\n") | map(select(. != ""))')
  limits='{"time_limit_s": 3000, "op_limit": 300}'
  task=$(jq -n --arg id "$id" --arg title "$title" --argjson c "$criteria" --argjson t "$touches" --argjson d "$depends" --argjson n "$n" --argjson l "$limits" \
    '{id: $id, title: $title, product: "chatbridge", base: "main", acceptance_criteria: $c, touches: $t}
     + (if ($d | length) > 0 then {depends_on: $d} else {} end)
     + {source: {adapter: "bench", ref: "bench/chatbridge#\($n)"}, max_lanes: 1} + $l')
  mkdir -p "$here/$id"
  if [ $check = 1 ]; then
    [ "$(jq -S . "$here/$id/task.json")" = "$(jq -S . <<<"$task")" ] || { echo "build-tasks: $id/task.json differs from $md" >&2; bad=1; }
  else
    jq . <<<"$task" >"$here/$id/task.json"
  fi
done
exit $bad
