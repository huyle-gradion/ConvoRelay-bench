# S1-D: chat-bridge run --fake <fixture>

### Summary
US-S1-01 Scenario 1 asks for `chat-bridge run --fake <fixture-file>`. This adds the `run` command: it loads the fixture, replays it and prints each event as one JSON line.

### Pointers
`main(argv, io)` and its `commands` table in `chatbridge/src/cli/main.ts`; the `Io` type in `chatbridge/src/cli/io.ts` already holds `stdout`, `stderr`, `readFile` and `clock`, and `chatbridge/src/cli/bin.ts` already wires the real ones, so only `main.ts` gains an entry. Copy the test style of `chatbridge/src/cli/main.test.ts` and build `io` with `testIo` from `chatbridge/src/cli/testing.ts`. `loadFixture` (S1-A) and `replay` (S1-C, an async generator of events whose keys are already in output order).

### Decisions
- Usage: `chat-bridge run --fake <file> [--speed <number>] [--base-time <iso>]`; speed defaults to 1, base time to `2026-01-01T00:00:00Z`. The command registers itself in the `commands` table of `main.ts` with this usage line, so `chat-bridge help` lists it.
- A speed is accepted when it is a finite number that is 0 or more; a base time when `Date.parse` accepts it.
- The whole file is loaded before the first event is printed, so a load error leaves stdout empty.
- Each emitted event is printed to stdout as `JSON.stringify(event)` followed by a newline, in the order the replay emits them. The replay's time and ids are used as they are.
- Exit codes: 0 when the replay ends, 1 when the file cannot be read or loaded (the error on stderr, naming the path for a read failure), 2 for a usage error (the usage line on stderr).
- Tests call `main` in process with `testIo({ readFile, clock })`, a fake `readFile` and a fake clock; they start no process.

### Acceptance criteria
- [ ] Given a fixture with three events, when `run --fake fixture.jsonl --speed 0` runs, then stdout holds exactly three JSON lines in fixture order and the exit code is 0.
- [ ] Given the same fixture, when the command runs twice, then both stdouts are byte for byte the same.
- [ ] Given a fixture whose third line is invalid, when the command runs, then stdout is empty, stderr names line 3, and the exit code is 1.
- [ ] Given a path that cannot be read, when the command runs, then stderr names the path and the exit code is 1.
- [ ] Given `run` without `--fake`, or with `--speed abc`, or with `--base-time abc`, when the command runs, then stderr shows the usage line and the exit code is 2.
- [ ] Given a fixture whose first event is at 0 ms, `--base-time 2030-05-06T07:08:09Z` and `--speed 0`, when the command runs, then the first printed event's time is `2030-05-06T07:08:09.000Z`.

### Out of scope
Sending replayed events anywhere (filters, outbox, sinks) and the `--json` flag of other commands (US-18).

Depends on: S1-C

Touches: chatbridge/src/cli/main.ts, chatbridge/src/cli/run.ts, chatbridge/src/cli/run.test.ts
