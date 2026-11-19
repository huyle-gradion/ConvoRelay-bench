import { createHash, createHmac } from "node:crypto";
import { readdirSync, readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import type { HttpHandler, HttpRequest, HttpResponse } from "../http.ts";

interface Step {
  at_ms: number;
  request: HttpRequest;
  response: HttpResponse;
}

interface Pair {
  name: string;
  secret: string;
  preceding: Step[];
  at_ms: number;
  request: HttpRequest;
  response: HttpResponse;
}

const contract = new URL("../../contract/margince/", import.meta.url);
const pairsDir = fileURLToPath(new URL("pairs/", contract));

function loadPair(name: string): Pair {
  return JSON.parse(readFileSync(`${pairsDir}${name}.json`, "utf8"));
}

function allPairs(): Pair[] {
  return readdirSync(pairsDir)
    .filter((file) => file.endsWith(".json"))
    .sort()
    .map((file) => loadPair(file.slice(0, -".json".length)));
}

const SECRET = "test-secret-chatbridge-0001";
/** Second 0 of a UTC minute, in epoch milliseconds. */
const MINUTE = 1794996000000;
const IP = "198.51.100.23";

async function receiver(secret = SECRET) {
  const { createHandler } = await import("../mock-margince/handler.ts");
  const clock = { ms: MINUTE };
  const handler: HttpHandler = createHandler({ secret, clock: { now: () => clock.ms } });
  return {
    send(request: HttpRequest, atMs: number): HttpResponse {
      clock.ms = atMs;
      return handler(request);
    },
  };
}

interface Build {
  at: number;
  slug?: string;
  nonce: string;
  ip?: string;
  timestamp?: number;
  ref?: string;
  method?: string;
  path?: string;
  dropHeader?: string;
}

/** A request signed per signing.md with Node's crypto; its timestamp is the second of `at`. */
function build(options: Build): HttpRequest {
  const slug = options.slug ?? "acme-sales";
  const scope = "messages:write";
  const ref = options.ref ?? "batch-0001";
  const timestamp = String(options.timestamp ?? Math.floor(options.at / 1000));
  const body = '{"messages":[]}';
  const canonical = [scope, slug, ref, timestamp, options.nonce, createHash("sha256").update(body, "utf8").digest("hex")].join("\n");
  const signature = createHmac("sha256", SECRET).update(canonical, "utf8").digest("hex");
  const headers: Record<string, string> = {
    "content-type": "application/json",
    "x-margince-scope": scope,
    "x-margince-ref": ref,
    "x-margince-timestamp": timestamp,
    "x-margince-nonce": options.nonce,
    "x-margince-signature": `sha256=${signature}`,
  };
  if (options.dropHeader !== undefined) delete headers[options.dropHeader];
  return {
    method: options.method ?? "POST",
    path: options.path ?? `/v1/workspaces/${slug}/batches`,
    headers,
    body,
    ip: options.ip ?? IP,
  };
}

function expectAnswerOf(actual: HttpResponse, pair: Pair): void {
  expect(actual.status).toBe(pair.response.status);
  expect(actual.body).toBe(pair.response.body);
  for (const [name, value] of Object.entries(pair.response.headers)) {
    expect(actual.headers[name]).toBe(value);
  }
}

async function replay(name: string): Promise<{ actual: HttpResponse; pair: Pair }> {
  const pair = loadPair(name);
  const r = await receiver(pair.secret);
  for (const step of pair.preceding) r.send(step.request, step.at_ms);
  return { actual: r.send(pair.request, pair.at_ms), pair };
}

/** Sends `count` accepted requests from `ip`, all at `at`, with nonces `${prefix}-0` ... */
function fill(r: { send(request: HttpRequest, atMs: number): HttpResponse }, count: number, ip: string, at: number, prefix: string) {
  for (let i = 0; i < count; i++) {
    r.send(build({ at, ip, nonce: `${prefix}-${i}` }), at);
  }
}

const ACCEPTED = () => loadPair("accepted");

describe("hidden S2-C Mock Margince enforces Margince rate limits", () => {
  it("hidden answers pairs/rate-limited.json for the 61st request of one IP in one minute", async () => {
    const { actual, pair } = await replay("rate-limited");
    expectAnswerOf(actual, pair);
    expect(actual.status).toBe(429);
    expect(actual.headers["retry-after"]).toBe("19");
  });

  it("hidden answers pairs/rate-limited-counts-bad-requests.json after 60 bad-signature requests", async () => {
    const { actual, pair } = await replay("rate-limited-counts-bad-requests");
    expectAnswerOf(actual, pair);
    expect(actual.status).toBe(429);
  });

  it("hidden answers pairs/rate-limited-endpoint.json for a fourth IP after 120 requests from three IPs", async () => {
    const { actual, pair } = await replay("rate-limited-endpoint");
    expectAnswerOf(actual, pair);
    expect(actual.status).toBe(429);
  });

  it("hidden answers pairs/rate-limit-window-resets.json for the refused IP in the next minute", async () => {
    const pair = loadPair("rate-limit-window-resets");
    const r = await receiver(pair.secret);
    for (const step of pair.preceding) r.send(step.request, step.at_ms);
    // the IP is refused for the rest of the minute the earlier requests were sent in
    const lastStep = pair.preceding[pair.preceding.length - 1]!;
    expect(r.send(pair.request, lastStep.at_ms + 500).status).toBe(429);
    const actual = r.send(pair.request, pair.at_ms);
    expectAnswerOf(actual, pair);
    expect(actual.status).toBe(202);
  });

  it("hidden does not remember the nonce of a rate-limited request: sent again in the next minute it is accepted", async () => {
    const r = await receiver();
    fill(r, 60, IP, MINUTE + 10_000, "fill");
    const refused = build({ at: MINUTE + 41_000, nonce: "refused-nonce" });
    const first = r.send(refused, MINUTE + 41_000);
    expect(first.status).toBe(429);
    expectAnswerOf(r.send(refused, MINUTE + 65_000), ACCEPTED());
    // and now the nonce is remembered like any accepted one
    expect(r.send(refused, MINUTE + 66_000).status).toBe(409);
  });

  it.each([
    [0, "60"],
    [41_500, "19"],
    [59_999, "1"],
  ])("hidden sends retry-after for a request refused %i ms into the minute: %s", async (offset, retryAfter) => {
    const r = await receiver();
    const at = MINUTE + offset;
    fill(r, 60, IP, at, "fill");
    const refused = r.send(build({ at, nonce: "refused" }), at);
    expect(refused.status).toBe(429);
    expect(refused.body).toBe('{"error":"rate_limited"}');
    expect(refused.headers["content-type"]).toBe("application/json");
    expect(refused.headers["retry-after"]).toBe(retryAfter);
  });

  const countedRefusals: Array<[string, (i: number, at: number) => HttpRequest, number]> = [
    ["a missing header", (i, at) => build({ at, nonce: `miss-${i}`, dropHeader: "x-margince-nonce" }), 60],
    ["a stale timestamp", (i, at) => build({ at, nonce: `old-${i}`, timestamp: Math.floor(at / 1000) - 1000 }), 60],
    ["a reused nonce", (_i, at) => build({ at, nonce: "same-nonce-every-time" }), 60],
  ];

  it.each(countedRefusals)("hidden counts a request refused for %s toward the per-IP limit", async (_what, make, count) => {
    const r = await receiver();
    const at = MINUTE + 10_000;
    for (let i = 0; i < count; i++) {
      const response = r.send(make(i, at), at);
      expect(response.status).not.toBe(429);
    }
    const next = r.send(build({ at, nonce: "valid-after" }), at);
    expect(next.status).toBe(429);
    expect(next.body).toBe('{"error":"rate_limited"}');
  });

  it("hidden counts requests of every slug toward the one endpoint limit", async () => {
    const r = await receiver();
    const at = MINUTE + 10_000;
    for (let i = 0; i < 120; i++) {
      const ip = `203.0.113.${100 + (i % 3)}`;
      const slug = ["acme-sales", "beta-shop", "gamma-inc"][i % 3] as string;
      expect(r.send(build({ at, ip, slug, nonce: `e-${i}` }), at).status).toBe(202);
    }
    const refused = r.send(build({ at, ip: "203.0.113.200", slug: "delta-co", nonce: "fourth" }), at);
    expect(refused.status).toBe(429);
    expect(refused.headers["retry-after"]).toBe("50");
  });

  it("hidden keeps a separate count for each IP", async () => {
    const r = await receiver();
    const at = MINUTE + 10_000;
    fill(r, 60, "203.0.113.1", at, "a");
    expect(r.send(build({ at, ip: "203.0.113.1", nonce: "a-over" }), at).status).toBe(429);
    expectAnswerOf(r.send(build({ at, ip: "203.0.113.2", nonce: "b-first" }), at), ACCEPTED());
  });

  it("hidden uses windows aligned to the clock minute, not 60 seconds after the first request", async () => {
    const r = await receiver();
    fill(r, 60, IP, MINUTE + 59_000, "late");
    expect(r.send(build({ at: MINUTE + 59_900, nonce: "same-minute" }), MINUTE + 59_900).status).toBe(429);
    expectAnswerOf(r.send(build({ at: MINUTE + 60_000, nonce: "next-minute" }), MINUTE + 60_000), ACCEPTED());
  });

  it("hidden does not count requests answered 404", async () => {
    const r = await receiver();
    const at = MINUTE + 10_000;
    for (let i = 0; i < 150; i++) {
      const response = r.send(build({ at, nonce: `nf-${i}`, path: "/v1/messages" }), at);
      expect(response.status).toBe(404);
    }
    for (let i = 0; i < 150; i++) {
      const response = r.send(build({ at, nonce: `nm-${i}`, method: "GET" }), at);
      expect(response.status).toBe(404);
    }
    // all 60 requests the IP is allowed are still available, and the 61st is refused
    for (let i = 0; i < 60; i++) {
      expect(r.send(build({ at, nonce: `valid-${i}` }), at).status).toBe(202);
    }
    expect(r.send(build({ at, nonce: "valid-over" }), at).status).toBe(429);
  });

  it("hidden checks the route before the rate limit: a refused IP still gets 404 for other paths and methods", async () => {
    const r = await receiver();
    const at = MINUTE + 10_000;
    fill(r, 60, IP, at, "fill");
    expect(r.send(build({ at, nonce: "over" }), at).status).toBe(429);
    const notFound = loadPair("not-found");
    expectAnswerOf(r.send(build({ at, nonce: "x1", path: "/v1/messages" }), at), notFound);
    expectAnswerOf(r.send(build({ at, nonce: "x2", method: "GET" }), at), loadPair("not-found-wrong-method"));
  });

  it("hidden checks the rate limit before the signing headers: a refused IP gets 429, not 400, for a missing header", async () => {
    const r = await receiver();
    const at = MINUTE + 10_000;
    fill(r, 60, IP, at, "fill");
    const response = r.send(build({ at, nonce: "no-header", dropHeader: "x-margince-timestamp" }), at);
    expect(response.status).toBe(429);
    expect(response.body).toBe('{"error":"rate_limited"}');
  });

  it("hidden replays every pair in the folder to the recorded status", async () => {
    const pairs = allPairs();
    expect(pairs.length).toBeGreaterThanOrEqual(15);
    const wrong: string[] = [];
    for (const pair of pairs) {
      const r = await receiver(pair.secret);
      for (const step of pair.preceding) r.send(step.request, step.at_ms);
      const actual = r.send(pair.request, pair.at_ms);
      if (actual.status !== pair.response.status) wrong.push(`${pair.name} (got ${actual.status}, recorded ${pair.response.status})`);
    }
    expect(wrong, `pairs with another status: ${wrong.join("; ")}`).toEqual([]);
  });

  it("hidden replays every pair in the folder to the recorded body bytes", async () => {
    const pairs = allPairs();
    expect(pairs.length).toBeGreaterThanOrEqual(15);
    const wrong: string[] = [];
    for (const pair of pairs) {
      const r = await receiver(pair.secret);
      for (const step of pair.preceding) r.send(step.request, step.at_ms);
      const actual = r.send(pair.request, pair.at_ms);
      if (actual.body !== pair.response.body) wrong.push(`${pair.name} (got ${JSON.stringify(actual.body)}, recorded ${JSON.stringify(pair.response.body)})`);
    }
    expect(wrong, `pairs with another body: ${wrong.join("; ")}`).toEqual([]);
  });

  it("hidden replays every pair in the folder to the recorded value of each header the pair lists", async () => {
    const pairs = allPairs();
    expect(pairs.length).toBeGreaterThanOrEqual(15);
    const wrong: string[] = [];
    for (const pair of pairs) {
      const r = await receiver(pair.secret);
      for (const step of pair.preceding) r.send(step.request, step.at_ms);
      const actual = r.send(pair.request, pair.at_ms);
      for (const [name, value] of Object.entries(pair.response.headers)) {
        if (actual.headers[name] !== value) wrong.push(`${pair.name} (${name}: got ${JSON.stringify(actual.headers[name])}, recorded ${JSON.stringify(value)})`);
      }
    }
    expect(wrong, `pairs with another header: ${wrong.join("; ")}`).toEqual([]);
  });
});
