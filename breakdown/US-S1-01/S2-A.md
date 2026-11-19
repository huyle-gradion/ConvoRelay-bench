# S2-A: Sign and verify Margince requests

### Summary
Margince accepts only requests signed with HMAC-SHA256 over scope, slug, ref, timestamp, a one-time nonce and the body (US-13). Both the Mock Margince and the later push client need one implementation of that signature; this adds it.

### Pointers
The contract is `chatbridge/contract/margince/signing.md` (section "The signature") and its test vectors are `chatbridge/contract/margince/vectors.json`; both are on the branch already (P0b) and are a stand-in for Margince's own, as the folder's README says. New module `chatbridge/src/margince/signature.ts` exporting the type `SigningParts` and the functions `sign(secret, parts)` and `verify(secret, parts, signature)`. Copy the test style of `chatbridge/src/cli/main.test.ts`; the test reads `vectors.json` from the contract folder, resolved from the test file's own location.

### Decisions
- `SigningParts` is `{ scope: string; slug: string; ref: string; timestamp: number; nonce: string; body: string }`, `timestamp` in whole seconds, exactly the `parts` object of each vector.
- `sign` returns the 64-character lower-case hex signature, without the `sha256=` prefix; the vector's `signature` field is that value. The canonical string, the secret's encoding (UTF-8 text, not decoded) and the body hashing are exactly those in `signing.md`; nothing here overrides it.
- `verify(secret, parts, signature)` takes the hex signature without prefix, compares in constant time (Node's `crypto.timingSafeEqual`) and returns false, never throws, for a signature of the wrong length or with characters other than lower-case hex.

### Acceptance criteria
- [ ] Given each vector in `vectors.json`, when `sign` runs on its secret and parts, then the result equals the vector's `signature`.
- [ ] Given a vector's parts and its `signature`, when `verify` runs, then it returns true.
- [ ] Given a vector with any one of scope, slug, ref, timestamp, nonce or body changed, when `verify` runs with the original signature, then it returns false.
- [ ] Given a vector checked with a different secret, when `verify` runs, then it returns false.
- [ ] Given a signature that is shorter or longer than 64 characters, or upper case, when `verify` runs, then it returns false and does not throw.

### Out of scope
Nonce storage, the timestamp window and HTTP (S2-B); the push client (US-13).

Touches: chatbridge/src/margince/signature.ts, chatbridge/src/margince/signature.test.ts
