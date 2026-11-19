# Add `t12 version` to the Go factory

There is no way to ask an installed `t12` which release it is. Add a `version` command and the usual
`--version` spelling, so a bug report or a CI log can say which build ran.

Touches: factory/internal/cli/cli.go, factory/internal/cli/version.go, factory/tests/unit/version_test.go

## Decisions

- The version is the string constant `Version = "0.3.0-dev"` in `internal/cli`.
- `version` takes no flag and no argument.

## Acceptance criteria

- Given any working directory and no state home, when `t12 version` runs, then it prints `t12 0.3.0-dev` and a newline on stdout, nothing on stderr, and exits 0
- Given the same, when `t12 --version` runs, then it prints exactly what `t12 version` prints and exits 0
- Given `t12 version extra`, when it runs, then it prints `usage: t12 version` on stderr, prints nothing on stdout and exits 2
- Given `t12` with no arguments, when it runs, then the usage on stderr lists `version` among the commands and exits 2
