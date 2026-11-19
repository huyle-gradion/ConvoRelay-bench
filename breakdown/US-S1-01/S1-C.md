# S1-C: Replay fixture events at a configured speed

### Summary
The Fake Source must hand fixture events to the engine at a configured speed, and do it the same way every time so tests can repeat it. This adds the replay engine.

### Pointers
New module `chatbridge/src/fake/replay.ts` exporting `replay(events, options)` and the type `ReplayedEvent`. `events` is the `FixtureEvent[]` of `loadFixture` (S1-A, which keeps each event's `line`). `options` is `{ speed?: number; baseTime: string; clock: { sleep(ms: number): Promise<void> } }`. Copy the test style of `chatbridge/src/cli/main.test.ts`; the fake clock is a plain object whose `sleep` records its argument and resolves at once.

### Decisions
- `replay` is an async generator: `async function* replay(events, options): AsyncGenerator<ReplayedEvent>`. A caller reads it with `for await`. Nothing runs until the first `next()`.
- `speed` is a multiplier: before each event the replay calls `clock.sleep((at_ms - previous at_ms) / speed)`, where the previous `at_ms` of the first event is 0. Speed 1 is real time, 10 is ten times faster, and 0 means `sleep` is never called. The default is 1. A speed that is negative or not a finite number makes the first `next()` reject, before any event, with an `Error` whose message names `speed`.
- `baseTime` is a valid ISO 8601 time; the caller (S1-D) checks it. An emitted event has these keys, in this order: `id`, `time`, `kind`, `chat`, `sender`, then `text` for a message or `target` and `emoji` for a reaction. `id` is `fake:<line>` (the event's `line`). `time` is `new Date(Date.parse(baseTime) + at_ms).toISOString()`, so it always has milliseconds, for example `2026-01-01T00:00:01.500Z`. A reaction's `target` is the id of the message it reacts to, `fake:<target line>`.
- The replay never reads the system clock or a random number; waiting goes only through `options.clock`.

### Acceptance criteria
- [ ] Given events at 0, 1000 and 3000 ms and speed 1, when they are replayed with a fake clock, then the clock is asked to wait 0, 1000 and 2000 ms, in that order, and the three events are emitted in file order.
- [ ] Given the same events and speed 10, when they are replayed, then the waits are 0, 100 and 200 ms.
- [ ] Given the same events and speed 0, when they are replayed, then no wait is requested and all three events are emitted in order.
- [ ] Given base time `2026-01-01T00:00:00Z`, a message at 1500 ms on line 4 and a reaction on line 6 whose target is line 4, when they are replayed, then the message has id `fake:4` and time `2026-01-01T00:00:01.500Z` and the reaction has id `fake:6` and target `fake:4`.
- [ ] Given one fixture replayed twice with the same base time, when both outputs are compared, then they are identical, ids, times and key order included.
- [ ] Given a negative speed, when a replay starts, then it fails before emitting any event, with an error naming `speed`.

### Out of scope
The CLI and printing (S1-D), validating `baseTime`, stopping a replay early, and feeding events into the engine's chat picker.

Depends on: S1-A

Touches: chatbridge/src/fake/replay.ts, chatbridge/src/fake/replay.test.ts
