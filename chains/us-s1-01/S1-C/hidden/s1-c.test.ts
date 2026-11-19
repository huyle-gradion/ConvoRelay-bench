import { describe, expect, it, vi } from "vitest";

type Chat = { id: string; type: "direct" | "group" };
type Ev =
  | { line: number; at_ms: number; kind: "message"; chat: Chat; sender: string; text: string }
  | { line: number; at_ms: number; kind: "reaction"; chat: Chat; sender: string; target: number; emoji: string };

const direct: Chat = { id: "chat-1", type: "direct" };
const BASE = "2026-01-01T00:00:00Z";

function message(line: number, at_ms: number, text = `m${line}`): Ev {
  return { line, at_ms, kind: "message", chat: direct, sender: "Alice", text };
}

function reaction(line: number, at_ms: number, target: number): Ev {
  return { line, at_ms, kind: "reaction", chat: direct, sender: "Bob", target, emoji: "👍" };
}

const three = (): Ev[] => [message(1, 0), message(2, 1000), message(3, 3000)];

function fakeClock() {
  const waits: number[] = [];
  return {
    waits,
    clock: {
      sleep: (ms: number): Promise<void> => {
        waits.push(ms);
        return Promise.resolve();
      },
    },
  };
}

async function run(events: Ev[], options: { speed?: number; baseTime?: string } = {}) {
  const { replay } = await import("../fake/replay.ts");
  const { waits, clock } = fakeClock();
  const out: unknown[] = [];
  for await (const event of replay(events, { baseTime: BASE, ...options, clock })) out.push(event);
  return { waits, out: out as Record<string, unknown>[] };
}

describe("hidden S1-C replay", () => {
  it("hidden S1-C at speed 1 waits 0, 1000 and 2000 ms and emits the events in file order", async () => {
    const { waits, out } = await run(three(), { speed: 1 });
    expect(waits).toEqual([0, 1000, 2000]);
    expect(out.map((event) => event.id)).toEqual(["fake:1", "fake:2", "fake:3"]);
  });

  it("hidden S1-C waits before each event, not all at once", async () => {
    const { replay } = await import("../fake/replay.ts");
    const log: string[] = [];
    const clock = {
      sleep: (ms: number): Promise<void> => {
        log.push(`sleep ${ms}`);
        return Promise.resolve();
      },
    };
    for await (const event of replay(three(), { speed: 1, baseTime: BASE, clock })) {
      log.push(`emit ${(event as { id: string }).id}`);
    }
    expect(log).toEqual(["sleep 0", "emit fake:1", "sleep 1000", "emit fake:2", "sleep 2000", "emit fake:3"]);
  });

  it("hidden S1-C defaults to speed 1", async () => {
    const { waits } = await run(three());
    expect(waits).toEqual([0, 1000, 2000]);
  });

  it("hidden S1-C at speed 10 waits 0, 100 and 200 ms", async () => {
    const { waits, out } = await run(three(), { speed: 10 });
    expect(waits).toEqual([0, 100, 200]);
    expect(out.map((event) => event.id)).toEqual(["fake:1", "fake:2", "fake:3"]);
  });

  it("hidden S1-C divides by a fractional speed", async () => {
    const { waits } = await run(three(), { speed: 0.5 });
    expect(waits).toEqual([0, 2000, 4000]);
  });

  it("hidden S1-C measures the first wait from 0 ms", async () => {
    const { waits } = await run([message(1, 500), message(2, 700)], { speed: 1 });
    expect(waits).toEqual([500, 200]);
  });

  it("hidden S1-C at speed 0 never waits and emits all events in order", async () => {
    const { waits, out } = await run(three(), { speed: 0 });
    expect(waits).toEqual([]);
    expect(out.map((event) => event.id)).toEqual(["fake:1", "fake:2", "fake:3"]);
  });

  it("hidden S1-C gives a message the id fake:<line> and time base + at_ms with milliseconds", async () => {
    const { out } = await run([message(4, 1500, "hello")], { speed: 0 });
    expect(out).toEqual([
      { id: "fake:4", time: "2026-01-01T00:00:01.500Z", kind: "message", chat: direct, sender: "Alice", text: "hello" },
    ]);
  });

  it("hidden S1-C gives a reaction its own id and the target message id fake:<target line>", async () => {
    const { out } = await run([message(4, 1500), reaction(6, 2000, 4)], { speed: 0 });
    expect(out[1]).toEqual({
      id: "fake:6",
      time: "2026-01-01T00:00:02.000Z",
      kind: "reaction",
      chat: direct,
      sender: "Bob",
      target: "fake:4",
      emoji: "👍",
    });
  });

  it("hidden S1-C emits message keys in the order id, time, kind, chat, sender, text", async () => {
    const { out } = await run([message(1, 0)], { speed: 0 });
    expect(Object.keys(out[0] ?? {})).toEqual(["id", "time", "kind", "chat", "sender", "text"]);
  });

  it("hidden S1-C emits reaction keys in the order id, time, kind, chat, sender, target, emoji", async () => {
    const { out } = await run([message(1, 0), reaction(2, 1, 1)], { speed: 0 });
    expect(Object.keys(out[1] ?? {})).toEqual(["id", "time", "kind", "chat", "sender", "target", "emoji"]);
  });

  it("hidden S1-C always prints milliseconds and converts an offset base time to UTC", async () => {
    const { out } = await run([message(1, 0)], { speed: 0, baseTime: "2026-03-04T05:06:07+07:00" });
    expect(out[0]?.time).toBe("2026-03-03T22:06:07.000Z");
  });

  it("hidden S1-C keeps milliseconds of the base time", async () => {
    const { out } = await run([message(1, 1500)], { speed: 0, baseTime: "2026-01-01T00:00:00.250Z" });
    expect(out[0]?.time).toBe("2026-01-01T00:00:01.750Z");
  });

  it("hidden S1-C replays events that come from loadFixture", async () => {
    const { loadFixture } = await import("../fake/fixture.ts");
    const text = [
      JSON.stringify({ at_ms: 0, kind: "message", chat: direct, sender: "Alice", text: "hi" }),
      "",
      JSON.stringify({ at_ms: 250, kind: "reaction", chat: direct, sender: "Bob", target: 1, emoji: "🎉" }),
    ].join("\n");
    const { waits, out } = await run(loadFixture(text) as Ev[], { speed: 1 });
    expect(waits).toEqual([0, 250]);
    expect(out.map((event) => [event.id, event.time])).toEqual([
      ["fake:1", "2026-01-01T00:00:00.000Z"],
      ["fake:3", "2026-01-01T00:00:00.250Z"],
    ]);
    expect(out[1]?.target).toBe("fake:1");
  });

  it("hidden S1-C gives identical output, ids, times and key order, when replayed twice", async () => {
    const events = [message(1, 0), message(2, 40), reaction(3, 90, 2)];
    const first = await run(events, { speed: 0 });
    const second = await run(events, { speed: 0 });
    expect(second.out).toEqual(first.out);
    expect(JSON.stringify(second.out)).toBe(JSON.stringify(first.out));
  });

  it("hidden S1-C does not read the system clock or random numbers", async () => {
    const now = vi.spyOn(Date, "now");
    const random = vi.spyOn(Math, "random");
    try {
      await run([message(1, 0), reaction(2, 10, 1)], { speed: 1 });
      expect(now).not.toHaveBeenCalled();
      expect(random).not.toHaveBeenCalled();
    } finally {
      now.mockRestore();
      random.mockRestore();
    }
  });

  it("hidden S1-C does nothing until the first next()", async () => {
    const { replay } = await import("../fake/replay.ts");
    const { waits, clock } = fakeClock();
    const generator = replay(three(), { speed: 1, baseTime: BASE, clock });
    expect(typeof generator.next).toBe("function");
    expect(generator[Symbol.asyncIterator]()).toBe(generator);
    expect(waits).toEqual([]);
    const first = await generator.next();
    expect(first.done).toBe(false);
    expect((first.value as { id: string }).id).toBe("fake:1");
    expect(waits).toEqual([0]);
  });

  it("hidden S1-C rejects the first next() for a negative speed, naming speed, before any event", async () => {
    const { replay } = await import("../fake/replay.ts");
    const { clock } = fakeClock();
    const generator = replay(three(), { speed: -1, baseTime: BASE, clock });
    const error = await generator.next().then(
      () => undefined,
      (caught: unknown) => caught,
    );
    expect(error).toBeInstanceOf(Error);
    expect((error as Error).message).toContain("speed");
  });

  it("hidden S1-C emits no event for a negative speed", async () => {
    const { replay } = await import("../fake/replay.ts");
    const { clock } = fakeClock();
    const out: unknown[] = [];
    await expect(
      (async () => {
        for await (const event of replay(three(), { speed: -2, baseTime: BASE, clock })) out.push(event);
      })(),
    ).rejects.toThrow(/speed/);
    expect(out).toEqual([]);
  });

  it.each([Number.NaN, Number.POSITIVE_INFINITY, Number.NEGATIVE_INFINITY])(
    "hidden S1-C rejects the non-finite speed %s, naming speed",
    async (speed) => {
      const { replay } = await import("../fake/replay.ts");
      const { clock } = fakeClock();
      await expect(replay(three(), { speed, baseTime: BASE, clock }).next()).rejects.toThrow(/speed/);
    },
  );
});
