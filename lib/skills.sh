# The pinned skills of the bench: pstack (the baseline arm's whole stack, and the checker's thermo-nuclear
# reviewers) and ponytail-review (the checker's quality reviewer). Source it after common.sh.
# shellcheck shell=bash

: "${BENCH_PSTACK_CACHE:=$BENCH_DIR/.pstack}"

skills_pin() { sed -n "s/^$1=//p" "$BENCH_DIR/pstack.pin" | head -1; }

# tree_sha256 DIR: sha256 of the sorted `sha256sum` lines of every file under DIR.
tree_sha256() {
  (cd "$1" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum | sha256sum | awk '{print $1}')
}

# pstack_prepare: makes plugins/pstack of the pinned revision under $BENCH_PSTACK_CACHE/<rev> (if it is not
# there yet), checks its hash against the pin, and sets PSTACK_DIR, PSTACK_REV and PSTACK_TREE.
pstack_prepare() {
  local rev want repo tmp
  rev=$(skills_pin rev)
  want=$(skills_pin tree)
  [ -n "$rev" ] && [ -n "$want" ] || die "$BENCH_DIR/pstack.pin has no rev or tree"
  PSTACK_DIR=$BENCH_PSTACK_CACHE/$rev
  PSTACK_REV=$rev
  if [ ! -d "$PSTACK_DIR" ]; then
    need git tar
    for repo in "${BENCH_PSTACK_REPO:-}" "$HOME/.agents/pstack-claude"; do
      [ -n "$repo" ] && git -C "$repo" cat-file -e "$rev^{commit}" 2>/dev/null && break
      repo=
    done
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/bench-pstack.XXXXXX")
    if [ -z "$repo" ]; then
      log "fetching pstack $rev from $(skills_pin source)"
      git init -q --bare "$tmp/repo" && git -C "$tmp/repo" fetch -q --depth 1 "$(skills_pin source)" "$rev" || {
        rm -rf "$tmp"
        die "cannot fetch pstack $rev from $(skills_pin source); set BENCH_PSTACK_REPO to a clone that has it"
      }
      repo=$tmp/repo
    fi
    mkdir -p "$tmp/tree"
    git -C "$repo" archive "$rev" plugins/pstack | tar -x -C "$tmp/tree" --strip-components=2 || {
      rm -rf "$tmp"
      die "git archive of pstack $rev failed"
    }
    mkdir -p "$BENCH_PSTACK_CACHE"
    mv "$tmp/tree" "$PSTACK_DIR"
    rm -rf "$tmp"
  fi
  PSTACK_TREE=$(tree_sha256 "$PSTACK_DIR")
  [ "$PSTACK_TREE" = "$want" ] || die "pstack at $PSTACK_DIR hashes to $PSTACK_TREE, the pin says $want: delete $PSTACK_DIR (or fix pstack.pin on purpose)"
  [ -f "$PSTACK_DIR/skills/poteto-mode/SKILL.md" ] || die "pstack at $PSTACK_DIR has no poteto-mode skill"
}

# ponytail_plugin DEST: a one-skill Claude Code plugin `bench-review` holding the pinned ponytail-review
# skill (`bench-review:ponytail-review`), for `claude --plugin-dir DEST`.
ponytail_plugin() {
  local src=${BENCH_PONYTAIL_REVIEW:-$HOME/.agents/skills/ponytail-review/SKILL.md} want got
  want=$(skills_pin ponytail)
  [ -f "$src" ] || die "ponytail-review skill not found at $src (BENCH_PONYTAIL_REVIEW=PATH)"
  got=$(sha256sum "$src" | awk '{print $1}')
  [ "$got" = "$want" ] || die "$src hashes to $got, the pin says $want"
  mkdir -p "$1/.claude-plugin" "$1/skills/ponytail-review"
  printf '{"name":"bench-review","version":"1.0.0","description":"The ponytail-review skill, pinned by pstack.pin."}\n' >"$1/.claude-plugin/plugin.json"
  cp "$src" "$1/skills/ponytail-review/SKILL.md"
}
