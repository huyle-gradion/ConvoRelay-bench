---
name: verify
description: "Drive tinyledger's `tl` command the way a user does: build it, feed it a plain-text ledger and read what balance, list and tags print. Use after changing anything under ledger/ or internal/cli/, or when asked to verify or smoke-test tl."
---

# Verify tinyledger

Surface: a **CLI**. `tl balance|list|tags [--file PATH]` reads a plain-text ledger from a file or stdin and prints a view of it. There is no server and no state: launch is a build, drive is a command.

## Launch

```sh
mkdir -p "$TMPDIR/tl-verify" && go build -buildvcs=false -o "$TMPDIR/tl-verify/tl" ./cmd/tl
```

Ready = the build exits 0 and `"$TMPDIR/tl-verify/tl"` with no arguments prints the usage line and exits 2. Teardown: `rm -rf "$TMPDIR/tl-verify"`.

## Doctor

`go version` works and `"$TMPDIR/tl-verify/tl"; echo $?` prints `usage: tl balance|list|tags [--file PATH]` then `2`. If not, rebuild before blaming the code.

## Drive

Write a ledger (one entry per line, the format in `ledger/entry.go`; read it first) into `$TMPDIR/tl-verify/ledger.txt`, then:

```sh
"$TMPDIR/tl-verify/tl" balance --file "$TMPDIR/tl-verify/ledger.txt"
"$TMPDIR/tl-verify/tl" list    --file "$TMPDIR/tl-verify/ledger.txt"
"$TMPDIR/tl-verify/tl" tags    --file "$TMPDIR/tl-verify/ledger.txt"
```

Exit codes: 0 ok, 1 the ledger could not be read, 2 usage. Feed the same ledger on stdin to check `--file` and stdin agree.

## Evidence

Keep each command, its stdout, stderr and exit code in `$TMPDIR/tl-verify/evidence.txt` and copy that file out before cleanup. Proof is the printed view matching the entries by hand arithmetic (balance) and order (list, tags), not just exit 0.

## Features

- **Smoke**: build, `tl balance` on a two-entry ledger prints the sum, exit 0.
- **balance / list / tags**: one run each on a ledger with several entries and tags; compare against the entries.
- **Bad input**: a missing file exits 1 with `tl: ...` on stderr; no command exits 2 with the usage line.

A change to `ledger/` is driven through the feature whose view it changes; a change to `internal/cli/` through the command it parses.
