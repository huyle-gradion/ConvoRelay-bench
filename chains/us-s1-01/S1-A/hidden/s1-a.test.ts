import { describe, expect, it } from "vitest";

type Obj = Record<string, unknown>;

const direct = { id: "chat-1", type: "direct" };
const group = { id: "group-1", type: "group" };

function msg(at_ms: number, extra: Obj = {}): Obj {
  return { at_ms, kind: "message", chat: direct, sender: "Alice", text: "hi", ...extra };
}

function reaction(at_ms: number, extra: Obj = {}): Obj {
  return { at_ms, kind: "reaction", chat: direct, sender: "Bob", target: 1, emoji: "👍", ...extra };
}

function without(obj: Obj, key: string): Obj {
  const copy = { ...obj };
  delete copy[key];
  return copy;
}

const lines = (...rows: (Obj | string)[]): string =>
  rows.map((row) => (typeof row === "string" ? row : JSON.stringify(row))).join("\n");

async function load(text: string): Promise<unknown[]> {
  const { loadFixture } = await import("../fake/fixture.ts");
  return loadFixture(text);
}

async function failure(text: string): Promise<string> {
  let caught: unknown;
  try {
    await load(text);
  } catch (error) {
    caught = error;
  }
  expect(caught).toBeInstanceOf(Error);
  return (caught as Error).message;
}

describe("hidden S1-A loadFixture", () => {
  it("hidden S1-A loads events in file order with every field and the 1-based line number", async () => {
    const text = lines(
      { at_ms: 0, kind: "message", chat: direct, sender: "Customer A", text: "Hello" },
      "",
      { at_ms: 500, kind: "message", chat: group, sender: "Customer B", text: "Meeting at 3pm" },
      { at_ms: 900, kind: "reaction", chat: group, sender: "Customer A", target: 3, emoji: "👍" },
    );
    expect(await load(text)).toEqual([
      { line: 1, at_ms: 0, kind: "message", chat: direct, sender: "Customer A", text: "Hello" },
      { line: 3, at_ms: 500, kind: "message", chat: group, sender: "Customer B", text: "Meeting at 3pm" },
      { line: 4, at_ms: 900, kind: "reaction", chat: group, sender: "Customer A", target: 3, emoji: "👍" },
    ]);
  });

  it("hidden S1-A ignores empty and whitespace-only lines but still counts them", async () => {
    const text = `\n  \t \n${JSON.stringify(msg(0))}\n\n   \n${JSON.stringify(msg(10))}\n\n`;
    const events = (await load(text)) as { line: number }[];
    expect(events.map((event) => event.line)).toEqual([3, 6]);
  });

  it("hidden S1-A returns no events for an empty file", async () => {
    expect(await load("")).toEqual([]);
  });

  it("hidden S1-A allows an empty message text", async () => {
    const events = (await load(lines(msg(0, { text: "" })))) as { text: string }[];
    expect(events).toHaveLength(1);
    expect(events[0]?.text).toBe("");
  });

  it("hidden S1-A allows two events with the same at_ms", async () => {
    const events = await load(lines(msg(100), msg(100, { text: "again" })));
    expect(events).toHaveLength(2);
  });

  it("hidden S1-A ignores other keys and never reads line from the file", async () => {
    const text = lines(
      msg(0, { line: 99, note: "extra", target: 1, emoji: "x" }),
      reaction(5, { line: 77, text: "not for reactions", extra: { a: 1 } }),
    );
    expect(await load(text)).toEqual([
      { line: 1, at_ms: 0, kind: "message", chat: direct, sender: "Alice", text: "hi" },
      { line: 2, at_ms: 5, kind: "reaction", chat: direct, sender: "Bob", target: 1, emoji: "👍" },
    ]);
  });

  it("hidden S1-A rejects a line that is not valid JSON, naming the line", async () => {
    const message = await failure(lines(msg(0), msg(1), "{not json"));
    expect(message).toMatch(/^line 3: not valid JSON/);
  });

  it("hidden S1-A counts blank lines when it names a line that is not valid JSON", async () => {
    const message = await failure(`${JSON.stringify(msg(0))}\n\n\n{"at_ms":`);
    expect(message).toMatch(/^line 4: not valid JSON/);
  });

  it("hidden S1-A names the missing sender as 'line 2: sender is required'", async () => {
    const message = await failure(lines(msg(0), without(msg(1), "sender")));
    expect(message).toMatch(/^line 2: sender is required/);
  });

  it("hidden S1-A names an invalid chat.type as 'line 3: chat.type must be \"direct\" or \"group\"'", async () => {
    const message = await failure(lines(msg(0), msg(1), msg(2, { chat: { id: "c", type: "channel" } })));
    expect(message).toMatch(/^line 3: chat\.type must be "direct" or "group"/);
  });

  const bad: [string, Obj, string][] = [
    ["at_ms missing", without(msg(100), "at_ms"), "at_ms"],
    ["at_ms negative", msg(-1), "at_ms"],
    ["at_ms not an integer", msg(1.5), "at_ms"],
    ["at_ms a string", msg(100, { at_ms: "100" }), "at_ms"],
    ["kind missing", without(msg(100), "kind"), "kind"],
    ["kind unknown", msg(100, { kind: "edit" }), "kind"],
    ["chat missing", without(msg(100), "chat"), "chat"],
    ["chat.id missing", msg(100, { chat: { type: "direct" } }), "chat.id"],
    ["chat.id not a string", msg(100, { chat: { id: 5, type: "direct" } }), "chat.id"],
    ["chat.type missing", msg(100, { chat: { id: "c" } }), "chat.type"],
    ["chat.type not direct or group", msg(100, { chat: { id: "c", type: "channel" } }), "chat.type"],
    ["sender empty", msg(100, { sender: "" }), "sender"],
    ["sender not a string", msg(100, { sender: 5 }), "sender"],
    ["message text missing", without(msg(100), "text"), "text"],
    ["message text not a string", msg(100, { text: 5 }), "text"],
    ["reaction target missing", without(reaction(100), "target"), "target"],
    ["reaction target zero", reaction(100, { target: 0 }), "target"],
    ["reaction target negative", reaction(100, { target: -1 }), "target"],
    ["reaction target not an integer", reaction(100, { target: 1.5 }), "target"],
    ["reaction target a string", reaction(100, { target: "1" }), "target"],
    ["reaction emoji missing", without(reaction(100), "emoji"), "emoji"],
    ["reaction emoji empty", reaction(100, { emoji: "" }), "emoji"],
    ["reaction emoji not a string", reaction(100, { emoji: 5 }), "emoji"],
  ];

  it.each(bad)("hidden S1-A rejects %s with the line number and the field", async (_name, row, field) => {
    const message = await failure(lines(msg(0), row));
    expect(message).toMatch(/^line 2: /);
    expect(message).toContain(field);
  });

  it("hidden S1-A reports the failing line even after blank lines", async () => {
    const message = await failure(`${JSON.stringify(msg(0))}\n\n\n${JSON.stringify(msg(1, { sender: "" }))}`);
    expect(message).toMatch(/^line 4: /);
    expect(message).toContain("sender");
  });

  it("hidden S1-A rejects an event whose at_ms is smaller than the event before it", async () => {
    const message = await failure(lines(msg(1000), msg(2000), msg(1999)));
    expect(message).toMatch(/^line 3: /);
  });

  it("hidden S1-A compares at_ms with the previous event, not the previous line", async () => {
    const message = await failure(`${JSON.stringify(msg(0))}\n${JSON.stringify(msg(500))}\n\n${JSON.stringify(msg(300))}`);
    expect(message).toMatch(/^line 4: /);
  });

  it("hidden S1-A rejects a reaction aimed at a later message", async () => {
    const message = await failure(lines(msg(0), reaction(1, { target: 3 }), msg(2)));
    expect(message).toMatch(/^line 2: /);
  });

  it("hidden S1-A rejects a reaction aimed at a line that does not exist", async () => {
    const message = await failure(lines(msg(0), msg(1), reaction(2, { target: 99 })));
    expect(message).toMatch(/^line 3: /);
  });

  it("hidden S1-A rejects a reaction aimed at another reaction", async () => {
    const message = await failure(lines(msg(0), reaction(1), reaction(2, { target: 2 })));
    expect(message).toMatch(/^line 3: /);
  });

  it("hidden S1-A rejects a reaction aimed at a blank line", async () => {
    const message = await failure(`${JSON.stringify(msg(0))}\n\n${JSON.stringify(reaction(1, { target: 2 }))}`);
    expect(message).toMatch(/^line 3: /);
  });

  it("hidden S1-A rejects a reaction aimed at its own line", async () => {
    const message = await failure(lines(msg(0), reaction(1, { target: 2 })));
    expect(message).toMatch(/^line 2: /);
  });

  it("hidden S1-A accepts a reaction aimed at an earlier message across blank lines", async () => {
    const events = (await load(`${JSON.stringify(msg(0))}\n\n${JSON.stringify(reaction(1, { target: 1 }))}`)) as {
      line: number;
      target?: number;
    }[];
    expect(events.map((event) => event.line)).toEqual([1, 3]);
    expect(events[1]?.target).toBe(1);
  });

  it("hidden S1-A keeps a 40,000-character text exactly", async () => {
    const text = "x".repeat(40000);
    const events = (await load(lines(msg(0, { text })))) as { text: string }[];
    expect(events[0]?.text).toHaveLength(40000);
    expect(events[0]?.text).toBe(text);
  });
});
