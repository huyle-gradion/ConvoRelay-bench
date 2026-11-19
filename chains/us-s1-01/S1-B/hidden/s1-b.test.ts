import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";

interface Ev {
  line: number;
  at_ms: number;
  kind: "message" | "reaction";
  chat: { id: string; type: string };
  sender: string;
  text?: string;
  target?: number;
  emoji?: string;
}

const fixtureUrl = new URL("../../fixtures/fake/standard.jsonl", import.meta.url);

async function standard(): Promise<Ev[]> {
  const { loadFixture } = await import("../fake/fixture.ts");
  const text = readFileSync(fileURLToPath(fixtureUrl), "utf8");
  return loadFixture(text) as Ev[];
}

function messages(events: Ev[]): Ev[] {
  return events.filter((event) => event.kind === "message");
}

describe("hidden S1-B standard fixture", () => {
  it("hidden S1-B holds exactly 8 events: 7 messages and 1 reaction", async () => {
    const events = await standard();
    expect(events).toHaveLength(8);
    expect(messages(events)).toHaveLength(7);
    expect(events.filter((event) => event.kind === "reaction")).toHaveLength(1);
  });

  it("hidden S1-B holds at least one direct and one group message", async () => {
    const events = messages(await standard());
    expect(events.some((event) => event.chat.type === "direct")).toBe(true);
    expect(events.some((event) => event.chat.type === "group")).toBe(true);
  });

  it.each([
    "Your OTP is 482910",
    "Mã xác thực Zalo: 991204",
    "Call me at +84 909 123 456",
    "Invoice total: 500000 VND",
  ])("hidden S1-B has the text %j exactly once", async (text) => {
    const events = messages(await standard());
    expect(events.filter((event) => event.text === text)).toHaveLength(1);
  });

  it("hidden S1-B has exactly one text of length 40000 and it is the last event", async () => {
    const events = await standard();
    const long = events.filter((event) => event.kind === "message" && event.text?.length === 40000);
    expect(long).toHaveLength(1);
    expect(events.at(-1)).toBe(long[0]);
    expect(long[0]?.text).toBe("x".repeat(40000));
  });

  it("hidden S1-B puts the events 1,000 ms apart starting at 0", async () => {
    const events = await standard();
    expect(events.map((event) => event.at_ms)).toEqual([0, 1000, 2000, 3000, 4000, 5000, 6000, 7000]);
  });

  it("hidden S1-B has the reaction target line 1, the message 'Hello from Customer A'", async () => {
    const events = await standard();
    const reactions = events.filter((event) => event.kind === "reaction");
    expect(reactions).toHaveLength(1);
    expect(reactions[0]?.target).toBe(1);
    const target = events.find((event) => event.line === 1);
    expect(target?.kind).toBe("message");
    expect(target?.text).toBe("Hello from Customer A");
  });

  it("hidden S1-B has the eight events in the decided order, chats and senders", async () => {
    const events = await standard();
    const customerA = { id: "customer-a", type: "direct" };
    expect(events.slice(0, 7)).toMatchObject([
      { line: 1, kind: "message", chat: customerA, sender: "Customer A", text: "Hello from Customer A" },
      { line: 2, kind: "message", chat: { id: "work-group", type: "group" }, sender: "Customer B", text: "Meeting at 3pm" },
      { line: 3, kind: "message", chat: customerA, sender: "Customer A", text: "Your OTP is 482910" },
      { line: 4, kind: "message", chat: customerA, sender: "Customer A", text: "Mã xác thực Zalo: 991204" },
      { line: 5, kind: "message", chat: customerA, sender: "Customer A", text: "Call me at +84 909 123 456" },
      { line: 6, kind: "message", chat: customerA, sender: "Customer A", text: "Invoice total: 500000 VND" },
      { line: 7, kind: "reaction", chat: customerA, sender: "Customer B", target: 1, emoji: "👍" },
    ]);
    expect(events[7]).toMatchObject({ line: 8, kind: "message", chat: customerA });
  });

  it("hidden S1-B stores one event per line with no blank lines", async () => {
    const text = readFileSync(fileURLToPath(fixtureUrl), "utf8");
    const rows = text.replace(/\r?\n$/, "").split(/\r?\n/);
    expect(rows).toHaveLength(8);
    expect(rows.every((row) => row.trim() !== "")).toBe(true);
    expect((await standard()).map((event) => event.line)).toEqual([1, 2, 3, 4, 5, 6, 7, 8]);
  });
});
