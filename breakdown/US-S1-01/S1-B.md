# S1-B: Standard fixture covering every message kind

### Summary
Every later test of sources, filters and sinks needs the same realistic traffic. This commits one standard fixture with each kind of event US-S1-01 names, and a test that keeps it honest.

### Pointers
`loadFixture` in `chatbridge/src/fake/fixture.ts` (S1-A). The OTP and non-OTP texts come from the QA sheet `docs/qa/test-cases.xlsx` (TC-033, OTP vs phone numbers).

### Decisions
- The fixture is `chatbridge/fixtures/fake/standard.jsonl`, one event per line, no blank lines.
- It holds eight events, in this order, 1,000 ms apart starting at 0: (1) a direct message `Hello from Customer A` in chat `customer-a` from `Customer A`; (2) a group message `Meeting at 3pm` in chat `work-group` from `Customer B`; (3) the OTP message `Your OTP is 482910`; (4) the OTP message `Mã xác thực Zalo: 991204`; (5) `Call me at +84 909 123 456`; (6) `Invoice total: 500000 VND`; (7) a reaction `👍` from `Customer B` in chat `customer-a` whose target is line 1; (8) a direct message in chat `customer-a` whose text is `x` repeated 40,000 times (`String.length` 40000). Events 3 to 6 are direct messages in chat `customer-a` from `Customer A`.
- The test loads the file with `loadFixture` from the repository's `chatbridge/fixtures/fake/` folder, resolved from the test file's own location.

### Acceptance criteria
- [ ] Given the standard fixture, when it is loaded, then it contains exactly 8 events: 7 messages and 1 reaction, with at least one direct message and one group message.
- [ ] Given the standard fixture, when it is loaded, then the texts `Your OTP is 482910`, `Mã xác thực Zalo: 991204`, `Call me at +84 909 123 456` and `Invoice total: 500000 VND` each appear exactly once.
- [ ] Given the standard fixture, when it is loaded, then exactly one message text has `String.length` 40000 and it is the last event.
- [ ] Given the standard fixture, when it is loaded, then every event's `at_ms` is 1,000 more than the previous one, starting at 0.
- [ ] Given the standard fixture, when it is loaded, then its reaction targets line 1, the message `Hello from Customer A`.

### Out of scope
Changing the fixture format (S1-A), detecting OTPs (US-07), and noise events such as edits, typing and stories (later stories).

Depends on: S1-A

Touches: chatbridge/fixtures/fake/standard.jsonl, chatbridge/src/fake/standard.test.ts
