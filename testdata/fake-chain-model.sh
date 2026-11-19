#!/usr/bin/env bash
# The delegate of the fake omp for chain-dry-run.sh (FAKE_OMP_DELEGATE). It reads the prompt on stdin and prints
# ONE JSON tool call for the role named by T12_ROLE, like ConvoRelay factory/tests/support/bin/fakemodel, which it hands every role to
# but one:
#
#   engineer   the deep Engineer: applies the task's reference.patch to the worktree (the cwd, named after the task)
#              and calls engineer_done. This stands in for a model that solves the task, so the dry run can show a
#              run reaching local-verified and being merged. It is the answer key: it exists only here.
#   every other role   ConvoRelay factory/tests/support/bin/fakemodel (the Go toy's scripted roles: reviewers approve, the verifier
#              passes, red writes a Go test that a ChatBridge worktree refuses, so the tdd arm pauses).
#
# FAKE_CHAIN_DIR is the chain directory (chains/<chain>), FAKE_CHAIN_FALLBACK the fakemodel binary.
set -uo pipefail
prompt=$(cat)
if [ "${T12_ROLE:-}" != engineer ]; then
  printf '%s' "$prompt" | exec "${FAKE_CHAIN_FALLBACK:?}"
fi
id=$(basename "$PWD")
patch=${FAKE_CHAIN_DIR:?}/$id/reference.patch
if [ -n "${FAKE_LOG:-}" ]; then
  jq -nc --arg role engineer --arg task "$id" --arg cwd "$PWD" '{role: $role, task: $task, cwd: $cwd}' >>"$FAKE_LOG"
fi
# The engineer's own retry (a finding it was sent back with) finds the patch already applied: nothing more to do.
if git apply --check "$patch" 2>/dev/null; then
  git apply "$patch" || { echo "fake chain model: cannot apply $patch" >&2; exit 1; }
fi
name=$(grep -o 'it("[^"]*' "$patch" | head -1 | sed 's/^it("//')
jq -nc --arg n "${name:-the reference tests}" '{tool: "engineer_done", args: {summary: "applied the reference solution", tests: [$n]}}'
