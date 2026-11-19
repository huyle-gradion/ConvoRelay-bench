import { createHash, createHmac } from "node:crypto";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import type { HttpHandler, HttpRequest, HttpResponse } from "../http.ts";
import { testIo } from "../cli/testing.ts";

interface Pair {
  secret: string;
  at_ms: number;
  request: HttpRequest;
  response: HttpResponse;
}

const contract = new URL("../../contract/margince/", import.meta.url);

function loadPair(name: string): Pair {
  return JSON.parse(readFileSync(fileURLToPath(new URL(`pairs/${name}.json`, contract)), "utf8"));
}

const USAGE = "mock-margince [--port <n>] --secret-env <VAR>";

interface Listen {
  host: string;
  port: number;
  handler: HttpHandler;
}

/** Runs `main` with a recording fake `listen` and a fake clock that the test can move. */
async function run(argv: string[], env: Record<string, string | undefined>, nowMs = 0) {
  const { main } = await import("../cli/main.ts");
  const calls: Listen[] = [];
  const clock = {
    ms: nowMs,
    now: () => clock.ms,
    sleep: () => Promise.resolve(),
  };
  const io = testIo({
    env,
    clock,
    listen: async (host, port, handler) => {
      calls.push({ host, port, handler });
    },
  });
  const code = await main(["mock-margince", ...argv], io);
  return { code, calls, io, clock, stdout: io.out.join(""), stderr: io.err.join("") };
}

/** A request signed per signing.md with Node's crypto, for the accepted pair's slug and headers. */
function signedWith(secret: string, timestampSeconds: number, nonce: string): HttpRequest {
  const base = loadPair("accepted").request;
  const slug = "acme-sales";
  const scope = "messages:write";
  const ref = "batch-0001";
  const canonical = [scope, slug, ref, String(timestampSeconds), nonce, createHash("sha256").update(base.body, "utf8").digest("hex")].join("\n");
  const signature = createHmac("sha256", secret).update(canonical, "utf8").digest("hex");
  return {
    ...base,
    headers: {
      ...base.headers,
      "x-margince-timestamp": String(timestampSeconds),
      "x-margince-nonce": nonce,
      "x-margince-signature": `sha256=${signature}`,
    },
  };
}

describe("hidden S2-E chat-bridge mock-margince command", () => {
  it("hidden listens on 127.0.0.1:8787 with a handler, prints the address and exits 0", async () => {
    const result = await run(["--secret-env", "MOCK_SECRET"], { MOCK_SECRET: "s3cret" });
    expect(result.calls.length).toBe(1);
    const call = result.calls[0] as Listen;
    expect(call.host).toBe("127.0.0.1");
    expect(call.port).toBe(8787);
    expect(typeof call.handler).toBe("function");
    expect(result.stdout).toBe("listening on http://127.0.0.1:8787\n");
    expect(result.code).toBe(0);
  });

  it("hidden listens on the port given by --port and prints it", async () => {
    const result = await run(["--port", "9000", "--secret-env", "MOCK_SECRET"], { MOCK_SECRET: "s3cret" });
    expect(result.calls.length).toBe(1);
    expect(result.calls[0]?.host).toBe("127.0.0.1");
    expect(result.calls[0]?.port).toBe(9000);
    expect(result.stdout).toBe("listening on http://127.0.0.1:9000\n");
    expect(result.code).toBe(0);
  });

  it("hidden takes the options in either order", async () => {
    const result = await run(["--secret-env", "MOCK_SECRET", "--port", "9100"], { MOCK_SECRET: "s3cret" });
    expect(result.calls.map((c) => c.port)).toEqual([9100]);
    expect(result.code).toBe(0);
  });

  it.each([1, 65535])("hidden accepts the port %i at the edge of the range", async (port) => {
    const result = await run(["--port", String(port), "--secret-env", "MOCK_SECRET"], { MOCK_SECRET: "s3cret" });
    expect(result.calls.map((c) => c.port)).toEqual([port]);
    expect(result.code).toBe(0);
  });

  it("hidden reads the secret from the variable named by --secret-env, whatever its name", async () => {
    const secret = loadPair("accepted").secret;
    const result = await run(["--secret-env", "OTHER_NAME"], { OTHER_NAME: secret, MOCK_SECRET: "not-this-one" }, 1794996012000);
    expect(result.code).toBe(0);
    const handler = (result.calls[0] as Listen).handler;
    expect(handler(loadPair("accepted").request).status).toBe(202);
  });

  it("hidden does not listen, names the variable on stderr and exits 1 when the variable is unset", async () => {
    const result = await run(["--secret-env", "MOCK_SECRET"], {});
    expect(result.calls).toEqual([]);
    expect(result.stderr).toContain("MOCK_SECRET");
    expect(result.code).toBe(1);
  });

  it("hidden does not listen, names the variable on stderr and exits 1 when the variable is empty", async () => {
    const result = await run(["--secret-env", "MOCK_SECRET"], { MOCK_SECRET: "" });
    expect(result.calls).toEqual([]);
    expect(result.stderr).toContain("MOCK_SECRET");
    expect(result.code).toBe(1);
  });

  it("hidden does not listen, shows the usage line on stderr and exits 2 without --secret-env", async () => {
    const result = await run([], { MOCK_SECRET: "s3cret" });
    expect(result.calls).toEqual([]);
    expect(result.stderr).toContain(USAGE);
    expect(result.code).toBe(2);
  });

  it.each(["0", "65536", "-1", "abc", "80.5", "", "99999999"])(
    "hidden does not listen, shows the usage line on stderr and exits 2 for the port %j",
    async (port) => {
      const result = await run(["--port", port, "--secret-env", "MOCK_SECRET"], { MOCK_SECRET: "s3cret" });
      expect(result.calls).toEqual([]);
      expect(result.stderr).toContain(USAGE);
      expect(result.code).toBe(2);
    },
  );

  it("hidden lists the command and its usage line in the help text", async () => {
    const { main } = await import("../cli/main.ts");
    const io = testIo();
    expect(await main(["help"], io)).toBe(0);
    expect(io.out.join("")).toContain(USAGE);
  });

  it("hidden answers 202 to the accepted pair's request when the clock is at the pair's time", async () => {
    const pair = loadPair("accepted");
    const result = await run(["--secret-env", "MOCK_SECRET"], { MOCK_SECRET: pair.secret }, pair.at_ms);
    const handler = (result.calls[0] as Listen).handler;
    const response = handler(pair.request);
    expect(response.status).toBe(202);
    expect(response.body).toBe("");
  });

  it("hidden answers 401 to the bad-signature pair's request on the same handler", async () => {
    const accepted = loadPair("accepted");
    const bad = loadPair("bad-signature");
    const result = await run(["--secret-env", "MOCK_SECRET"], { MOCK_SECRET: accepted.secret }, bad.at_ms);
    const handler = (result.calls[0] as Listen).handler;
    const response = handler(bad.request);
    expect(response.status).toBe(401);
    expect(response.body).toBe(bad.response.body);
  });

  it("hidden answers 401 to a batch signed with another secret and 202 to one signed with the environment's secret", async () => {
    const pair = loadPair("accepted");
    const result = await run(["--secret-env", "MOCK_SECRET"], { MOCK_SECRET: "env-secret-0001" }, pair.at_ms);
    const handler = (result.calls[0] as Listen).handler;
    const seconds = Math.floor(pair.at_ms / 1000);
    expect(handler(signedWith("some-other-secret-9999", seconds, "n-other")).status).toBe(401);
    expect(handler(signedWith("env-secret-0001", seconds, "n-env")).status).toBe(202);
    expect(handler(pair.request).status).toBe(401);
  });

  it("hidden judges timestamps by the io clock: the same batch is refused once the clock has moved 301 seconds on", async () => {
    const pair = loadPair("accepted");
    const result = await run(["--secret-env", "MOCK_SECRET"], { MOCK_SECRET: pair.secret }, pair.at_ms + 301_000);
    const handler = (result.calls[0] as Listen).handler;
    const response = handler(pair.request);
    expect(response.status).toBe(401);
    expect(response.body).toBe('{"error":"stale_timestamp"}');
    result.clock.ms = pair.at_ms + 300_000;
    expect(handler(pair.request).status).toBe(202);
  });
});
