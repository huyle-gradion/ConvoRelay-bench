# S2-C: Mock Margince enforces Margince rate limits

### Summary
Margince allows 60 requests a minute per IP and 120 a minute per endpoint (US-13). The Mock Margince must refuse the same requests so Chat Bridge's back-off can be tested offline. This adds the rate limiter to the handler.

### Pointers
`createHandler` in `chatbridge/src/mock-margince/handler.ts` (S2-B). The rule is the section "Rate limit" of `chatbridge/contract/margince/signing.md` (P0b, a stand-in for Margince's own: see the folder's README) and the pairs `pairs/rate-limited.json`, `rate-limited-counts-bad-requests.json`, `rate-limited-endpoint.json` and `rate-limit-window-resets.json`, which carry the earlier requests (`preceding`) each case needs. New module `chatbridge/src/mock-margince/ratelimit.ts`. Copy the test style of `chatbridge/src/cli/main.test.ts`; to replay a pair, send each `preceding` request with the clock at its `at_ms`, then the pair's `request` with the clock at the pair's `at_ms`.

### Decisions
- All of it is `signing.md`: two fixed windows aligned to the clock minute (`floor(milliseconds / 60000)`), 60 per IP string and 120 for the one endpoint, checked after the route and before the signing headers.
- A request that reaches the signing-header check counts toward both counters, even if it is then refused for a missing header, a bad signature, a stale timestamp or a reused nonce. A request answered 404 or 429 counts for nothing and changes no counter.
- `retry-after` is `60 - (now mod 60)` with `now` in whole seconds: the whole seconds left in the window, from 1 to 60.
- A request refused as rate limited does not remember its nonce (the rate limit runs before the nonce check).

### Acceptance criteria
- [ ] Given the 60 earlier requests of `pairs/rate-limited.json` from one IP in one minute, when its 61st arrives in the same minute, then the handler answers with the status, headers (including `retry-after`) and body of that pair.
- [ ] Given the 60 earlier bad-signature requests of `pairs/rate-limited-counts-bad-requests.json`, when a correctly signed request from the same IP arrives in the same minute, then the handler answers as that pair, 429.
- [ ] Given the 120 earlier requests of `pairs/rate-limited-endpoint.json` from three IPs in one minute, when a request from a fourth IP arrives, then the handler answers as that pair, 429.
- [ ] Given the earlier requests of `pairs/rate-limit-window-resets.json`, when a request from the refused IP arrives in the next minute, then the handler answers as that pair, 202.
- [ ] Given a request refused as rate limited, when the same request is sent again in the next minute, then it is accepted, because its nonce was not remembered.

### Out of scope
Rate limits on any endpoint other than the batch push, and Chat Bridge's own back-off (US-13).

Depends on: S2-B

Touches: chatbridge/src/mock-margince/ratelimit.ts, chatbridge/src/mock-margince/handler.ts, chatbridge/src/mock-margince/ratelimit.test.ts
