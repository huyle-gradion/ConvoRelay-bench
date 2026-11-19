# S1-A: Load a Fake Source fixture file

### Summary
Chat Bridge tests need chat traffic without a live WhatsApp or Zalo account. This adds the fixture file format of the Fake Source (US-S1-01, Scenario 1) and a loader that turns a file into an ordered list of events, each remembering the line it came from.

### Pointers
New module `chatbridge/src/fake/fixture.ts` exporting `loadFixture(text: string): FixtureEvent[]` and the type `FixtureEvent`. Copy the test style of `chatbridge/src/cli/main.test.ts` (Vitest, `describe` and `it`, plain `expect`).

### Decisions
- The format is JSON Lines: one event per line. A line that is empty or only whitespace is ignored. Line numbers are 1-based and count every line of the file, blank ones included.
- A line holds `at_ms` (a non-negative integer: milliseconds from the start of the replay), `kind` (`message` or `reaction`), `chat` (`{"id": string, "type": "direct" | "group"}`) and `sender` (a non-empty string). A `message` also has `text` (a string, empty allowed). A `reaction` also has `target` (a positive integer: the line number of the message it reacts to) and `emoji` (a non-empty string). Other keys are ignored and not returned.
- `FixtureEvent` is `{ line, at_ms, kind: "message", chat, sender, text }` or `{ line, at_ms, kind: "reaction", chat, sender, target, emoji }`. `line` (the file's 1-based line number) is added by the loader and never read from the file.
- OTP codes and 40,000-character texts are ordinary `message` events; nothing in the format marks them. "40,000 characters" means a `text` whose `String.length` is 40000.
- A failure throws an `Error` whose message starts with `line <n>: `. For a line that is not valid JSON it continues `not valid JSON`; for a field it names the field by its dotted path, for example `line 3: chat.type must be "direct" or "group"` or `line 2: sender is required`.

### Acceptance criteria
- [ ] Given a file with a direct message at 0 ms on line 1, a blank line, a group message at 500 ms on line 3 and a reaction at 900 ms on line 4, when it is loaded, then three events come back in file order with every field as written and `line` equal to 1, 3 and 4.
- [ ] Given a line that is not valid JSON, when the file is loaded, then loading fails with an error whose message starts with that line's number and says `not valid JSON`.
- [ ] Given a line that lacks a required field or holds a field of the wrong type or value, when the file is loaded, then loading fails with an error naming that line number and the field.
- [ ] Given an event whose `at_ms` is smaller than the event before it, when the file is loaded, then loading fails with an error naming that event's line number.
- [ ] Given a reaction whose `target` is not the line number of an earlier `message`, when the file is loaded, then loading fails with an error naming the reaction's line number.
- [ ] Given a message whose text is 40,000 `x` characters, when the file is loaded, then the event's text is exactly those 40,000 characters.

### Out of scope
Reading files from disk, replay timing and the CLI (S1-C, S1-D).

Touches: chatbridge/src/fake/fixture.ts, chatbridge/src/fake/fixture.test.ts
