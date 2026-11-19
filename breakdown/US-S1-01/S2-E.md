# S2-E: chat-bridge mock-margince command

### Summary
Developers need to start the Mock Margince by hand to point a running Chat Bridge at it. This adds `chat-bridge mock-margince`, which serves the handler on localhost.

### Pointers
`main(argv, io)` and its `commands` table in `chatbridge/src/cli/main.ts`; `createHandler` in `chatbridge/src/mock-margince/handler.ts` (S2-B); `sign` in `chatbridge/src/margince/signature.ts` (S2-A) for the test. The `Io` type in `chatbridge/src/cli/io.ts` already has `env` and `listen(host, port, handler)`, and `chatbridge/src/cli/bin.ts` already wires the real ones (`node:http`), so only `main.ts` gains an entry. Copy the test style of `chatbridge/src/cli/main.test.ts` and build `io` with `testIo` from `chatbridge/src/cli/testing.ts`.

### Decisions
- Usage: `chat-bridge mock-margince [--port <n>] --secret-env <VAR>`; port defaults to 8787; the secret is read from the named environment variable (`io.env`), never from a flag. The command registers itself in the `commands` table of `main.ts` with this usage line.
- It always binds `127.0.0.1`, never another address. Once `listen` resolves it prints `listening on http://127.0.0.1:<port>` and a newline to stdout and returns 0 (the real `listen` keeps serving in the background).
- The handler it passes to `listen` is `createHandler({ secret, clock: io.clock })`.
- Tests pass a fake `listen` that records its arguments; they open no socket. Serving real traffic is checked by the verify skill and by a person.

### Acceptance criteria
- [ ] Given `MOCK_SECRET` set, when `mock-margince --secret-env MOCK_SECRET` runs, then `listen` is called with host `127.0.0.1`, port 8787 and a handler, stdout holds `listening on http://127.0.0.1:8787`, and the exit code is 0.
- [ ] Given `--port 9000`, when the command runs, then `listen` gets port 9000.
- [ ] Given the variable named by `--secret-env` is unset or empty, when the command runs, then `listen` is not called, stderr names the variable, and the exit code is 1.
- [ ] Given no `--secret-env`, or a port that is not a whole number from 1 to 65535, when the command runs, then `listen` is not called, stderr shows the usage line and the exit code is 2.
- [ ] Given a secret in the environment and a fake clock at `pairs/accepted.json`'s `at_ms`, when the handler passed to `listen` receives that pair's request signed with that secret, then it answers 202, and `pairs/bad-signature.json`'s request answers 401.

### Out of scope
TLS, other bind addresses, persisting nonces between runs and a real listener in a test.

Depends on: S2-B

Touches: chatbridge/src/cli/main.ts, chatbridge/src/cli/mock-margince.ts, chatbridge/src/cli/mock-margince.test.ts
