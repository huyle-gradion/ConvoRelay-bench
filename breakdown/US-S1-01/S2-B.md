# S2-B: Mock Margince validates signed batches

### Summary
Chat Bridge needs a local stand-in for Margince that refuses what Margince refuses (US-S1-01 Scenario 2). This adds the Mock Margince request handler: it checks the route, the signing headers, the signature, the timestamp window and the nonce of each batch, in the order the contract fixes.

### Pointers
The contract is `chatbridge/contract/margince/signing.md`, `pairs/*.json` and `vectors.json` (P0b, a stand-in for Margince's own: see the folder's README). `verify` in `chatbridge/src/margince/signature.ts` (S2-A). The request and response types are `HttpRequest`, `HttpResponse` and `HttpHandler` in `chatbridge/src/http.ts`, and the clock type is `Clock` in `chatbridge/src/clock.ts`. New module `chatbridge/src/mock-margince/handler.ts` exporting `createHandler({ secret, clock }: { secret: string; clock: Pick<Clock, "now"> }): HttpHandler`. Copy the test style of `chatbridge/src/cli/main.test.ts`; the test reads the pairs from the contract folder, resolved from the test file's own location, and sends a pair's `request` to a handler whose clock returns the pair's `at_ms`. To replay a pair, send each `preceding` request with the clock at its `at_ms`, then the pair's `request` with the clock at the pair's `at_ms`.

### Decisions
- Every rule comes from `signing.md`: the endpoint, the five headers, the `sha256=` prefix, the check order (route, headers, signature, timestamp, nonce; the rate limit between route and headers is S2-C), the window of 300 seconds either way, and the status and body of each answer. The handler never throws; a request that fits no row answers as the row it fails.
- A nonce is remembered only by an accepted request and is scoped to its slug, as `signing.md` says. Nonces are kept in memory until the timestamp of the request that used them is more than 300 seconds old.
- Time comes only from `clock.now()` (milliseconds since the epoch); the handler never reads the system clock. Tests call the handler directly and open no socket.
- Rate limits are not enforced here, so a pair that needs them (the `rate-limit*` pairs) is not part of this task.

### Acceptance criteria
- [ ] Given a batch signed with the shared secret inside the window, when the handler receives it, then it answers with the status, headers and body of `pairs/accepted.json`.
- [ ] Given a batch signed with another secret, when the handler receives it, then it answers as `pairs/bad-signature.json`, and also when its timestamp is stale too.
- [ ] Given a request missing one of the signing headers, or holding it empty, when the handler receives it, then it answers as `pairs/missing-header.json`, for each of the five headers.
- [ ] Given a correctly signed batch 300 seconds old and others 301 seconds old and 301 seconds ahead, when the handler receives them, then the first answers as `pairs/accepted-window-edge.json` and the others as `pairs/stale-timestamp.json` and `pairs/stale-timestamp-future.json`.
- [ ] Given a batch accepted once, when the same request arrives again within the window, then the handler answers as `pairs/reused-nonce.json`.
- [ ] Given a nonce used by an accepted batch on one slug, when a correctly signed batch with the same nonce arrives for another slug, then the handler answers as `pairs/nonce-per-slug.json`.
- [ ] Given a request refused for a bad signature, when a correctly signed batch with the same nonce arrives, then the handler answers as `pairs/nonce-not-burned.json`.
- [ ] Given a path that is not the batch endpoint, or the batch path with a method other than POST, when the handler receives it, then it answers as `pairs/not-found.json` and `pairs/not-found-wrong-method.json`.

### Out of scope
Rate limits (S2-C) and listening on a port (S2-E).

Depends on: S2-A

Touches: chatbridge/src/mock-margince/handler.ts, chatbridge/src/mock-margince/handler.test.ts
