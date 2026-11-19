import { describe, expect, it } from "vitest";

type Obj = Record<string, unknown>;

const chat = { id: "chat-1", type: "direct" };
const USAGE = "run --fake <file> [--speed <number>] [--base-time <iso>]";

const row = (o: Obj): string => JSON.stringify(o);
const message = (at_ms: number, text: string): Obj => ({ at_ms, kind: "message", chat, sender: "Alice", text });

const FIXTURE = [
  row(message(0, "hello")),
  row({ at_ms: 1000, kind: "message", chat: { id: "g1", type: "group" }, sender: "Bob", text: "group" }),
  row({ at_ms: 3000, kind: "reaction", chat, sender: "Bob", target: 1, emoji: "👍" }),
].join("\n");

async function invoke(argv: string[], files: Record<string, string> = { "fixture.jsonl": FIXTURE }) {
  const { main } = await import("../cli/main.ts");
  const { testIo } = await import("../cli/testing.ts");
  const waits: number[] = [];
  const reads: string[] = [];
  const io = testIo({
    readFile: (path: string) => {
      reads.push(path);
      const text = files[path];
      return text === undefined ? Promise.reject(new Error("ENOENT")) : Promise.resolve(text);
    },
    clock: {
      now: () => {
        throw new Error("clock.now must not be used");
      },
      sleep: (ms: number) => {
        waits.push(ms);
        return Promise.resolve();
      },
    },
  });
  const code = await main(argv, io);
  return { code, stdout: io.out.join(""), stderr: io.err.join(""), waits, reads };
}

describe("hidden S1-D run --fake", () => {
  it("hidden S1-D prints one JSON line per event in fixture order and exits 0", async () => {
    const { code, stdout, stderr, reads } = await invoke(["run", "--fake", "fixture.jsonl", "--speed", "0"]);
    expect(code).toBe(0);
    expect(stderr).toBe("");
    expect(reads).toContain("fixture.jsonl");
    const lines = stdout.split("\n");
    expect(lines).toHaveLength(4);
    expect(lines[3]).toBe("");
    expect(lines.slice(0, 3).map((line) => (JSON.parse(line) as { id: string }).id)).toEqual(["fake:1", "fake:2", "fake:3"]);
  });

  it("hidden S1-D prints each event as JSON.stringify of the replay event with the default base time", async () => {
    const { stdout } = await invoke(["run", "--fake", "fixture.jsonl", "--speed", "0"]);
    const expected = [
      { id: "fake:1", time: "2026-01-01T00:00:00.000Z", kind: "message", chat, sender: "Alice", text: "hello" },
      {
        id: "fake:2",
        time: "2026-01-01T00:00:01.000Z",
        kind: "message",
        chat: { id: "g1", type: "group" },
        sender: "Bob",
        text: "group",
      },
      { id: "fake:3", time: "2026-01-01T00:00:03.000Z", kind: "reaction", chat, sender: "Bob", target: "fake:1", emoji: "👍" },
    ];
    expect(stdout).toBe(expected.map((event) => `${JSON.stringify(event)}\n`).join(""));
  });

  it("hidden S1-D prints byte for byte the same output when run twice", async () => {
    const argv = ["run", "--fake", "fixture.jsonl", "--speed", "0"];
    const first = await invoke(argv);
    const second = await invoke(argv);
    expect(first.stdout).not.toBe("");
    expect(second.stdout).toBe(first.stdout);
  });

  it("hidden S1-D waits on the injected clock at speed 1 by default", async () => {
    const { code, waits } = await invoke(["run", "--fake", "fixture.jsonl"]);
    expect(code).toBe(0);
    expect(waits).toEqual([0, 1000, 2000]);
  });

  it("hidden S1-D passes --speed on to the replay", async () => {
    const { code, waits } = await invoke(["run", "--fake", "fixture.jsonl", "--speed", "10"]);
    expect(code).toBe(0);
    expect(waits).toEqual([0, 100, 200]);
  });

  it("hidden S1-D never waits at --speed 0", async () => {
    const { code, waits } = await invoke(["run", "--fake", "fixture.jsonl", "--speed", "0"]);
    expect(code).toBe(0);
    expect(waits).toEqual([]);
  });

  it("hidden S1-D leaves stdout empty, names line 3 and exits 1 when the third line is invalid", async () => {
    const files = { "bad.jsonl": [row(message(0, "a")), row(message(1, "b")), "{oops"].join("\n") };
    const { code, stdout, stderr } = await invoke(["run", "--fake", "bad.jsonl", "--speed", "0"], files);
    expect(code).toBe(1);
    expect(stdout).toBe("");
    expect(stderr).toContain("line 3");
  });

  it("hidden S1-D names the line of a field error on stderr and exits 1 with empty stdout", async () => {
    const files = { "bad.jsonl": [row(message(0, "a")), row({ ...message(1, "b"), sender: "" })].join("\n") };
    const { code, stdout, stderr } = await invoke(["run", "--fake", "bad.jsonl", "--speed", "0"], files);
    expect(code).toBe(1);
    expect(stdout).toBe("");
    expect(stderr).toContain("line 2");
  });

  it("hidden S1-D names the path on stderr and exits 1 when the file cannot be read", async () => {
    const { code, stdout, stderr } = await invoke(["run", "--fake", "does/not/exist.jsonl", "--speed", "0"]);
    expect(code).toBe(1);
    expect(stdout).toBe("");
    expect(stderr).toContain("does/not/exist.jsonl");
  });

  it.each([
    ["no --fake", ["run"]],
    ["--speed without --fake", ["run", "--speed", "0"]],
    ["--speed abc", ["run", "--fake", "fixture.jsonl", "--speed", "abc"]],
    ["--speed negative", ["run", "--fake", "fixture.jsonl", "--speed", "-1"]],
    ["--speed Infinity", ["run", "--fake", "fixture.jsonl", "--speed", "Infinity"]],
    ["--base-time abc", ["run", "--fake", "fixture.jsonl", "--base-time", "abc"]],
  ])("hidden S1-D shows the usage line and exits 2 for %s", async (_name, argv) => {
    const { code, stdout, stderr } = await invoke(argv);
    expect(code).toBe(2);
    expect(stdout).toBe("");
    expect(stderr).toContain(USAGE);
  });

  it("hidden S1-D uses --base-time for the printed times", async () => {
    const { code, stdout } = await invoke([
      "run",
      "--fake",
      "fixture.jsonl",
      "--base-time",
      "2030-05-06T07:08:09Z",
      "--speed",
      "0",
    ]);
    expect(code).toBe(0);
    const first = JSON.parse(stdout.split("\n")[0] ?? "") as { time: string };
    expect(first.time).toBe("2030-05-06T07:08:09.000Z");
  });

  it("hidden S1-D lists run in the help text", async () => {
    const { main } = await import("../cli/main.ts");
    const { testIo } = await import("../cli/testing.ts");
    const io = testIo();
    expect(await main(["help"], io)).toBe(0);
    expect(io.out.join("")).toContain(USAGE);
  });
});
