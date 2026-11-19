import { createHash, createHmac } from "node:crypto";
import { readFileSync } from "node:fs";
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

function loadPair(name: string): Pair {
  return JSON.parse(readFileSync(fileURLToPath(new URL(`pairs/${name}.json`, contract)), "utf8"));
}

const SECRET = "test-secret-chatbridge-0001";
const WRONG_SECRET = "some-other-secret-9999";
const T0 = 1794996012; // seconds; the clock of most recorded pairs
const IP = "198.51.100.23";

/** A receiver on a fake clock the test moves by hand. */
async function receiver(secret = SECRET) {
  const { createHandler } = await import("../mock-margince/handler.ts");
  const clock = { ms: T0 * 1000 };
  const handler: HttpHandler = createHandler({ secret, clock: { now: () => clock.ms } });
  return {
    clock,
    send(request: HttpRequest, atMs = clock.ms): HttpResponse {
      clock.ms = atMs;
      return handler(request);
    },
  };
}

interface Build {
  secret?: string;
  slug?: string;
  scope?: string;
  ref?: string;
  timestamp?: number | string;
  nonce?: string;
  body?: string;
  ip?: string;
  method?: string;
  path?: string;
  headers?: Record<string, string>;
}

/** Builds a request signed per signing.md with Node's crypto (not with the code under test). */
function build(options: Build = {}): HttpRequest {
  const slug = options.slug ?? "acme-sales";
  const scope = options.scope ?? "messages:write";
  const ref = options.ref ?? "batch-0001";
  const timestamp = String(options.timestamp ?? T0);
  const nonce = options.nonce ?? "a1b2c3d4e5f60718293a4b5c6d7e8f90";
  const body = options.body ?? '{"messages":[]}';
  const canonical = [scope, slug, ref, timestamp, nonce, createHash("sha256").update(body, "utf8").digest("hex")].join("\n");
  const signature = createHmac("sha256", options.secret ?? SECRET).update(canonical, "utf8").digest("hex");
  return {
    method: options.method ?? "POST",
    path: options.path ?? `/v1/workspaces/${slug}/batches`,
    headers: {
      "content-type": "application/json",
      "x-margince-scope": scope,
      "x-margince-ref": ref,
      "x-margince-timestamp": timestamp,
      "x-margince-nonce": nonce,
      "x-margince-signature": `sha256=${signature}`,
      ...options.headers,
    },
    body,
    ip: options.ip ?? IP,
  };
}

/** The answer must have the status, the body bytes and every header the pair lists. */
function expectAnswerOf(actual: HttpResponse, pair: Pair): void {
  expect(actual.status).toBe(pair.response.status);
  expect(actual.body).toBe(pair.response.body);
  for (const [name, value] of Object.entries(pair.response.headers)) {
    expect(actual.headers[name]).toBe(value);
  }
}

/** Replays a recorded pair on a fresh handler with the clock set per step. */
async function replay(name: string): Promise<{ actual: HttpResponse; pair: Pair }> {
  const pair = loadPair(name);
  const r = await receiver(pair.secret);
  for (const step of pair.preceding) r.send(step.request, step.at_ms);
  return { actual: r.send(pair.request, pair.at_ms), pair };
}

const SIGNING_HEADERS = [
  "x-margince-scope",
  "x-margince-ref",
  "x-margince-timestamp",
  "x-margince-nonce",
  "x-margince-signature",
] as const;

describe("hidden S2-B Mock Margince validates signed batches", () => {
  it("hidden answers pairs/accepted.json for the recorded batch", async () => {
    const { actual, pair } = await replay("accepted");
    expectAnswerOf(actual, pair);
    expect(actual.status).toBe(202);
  });

  it("hidden accepts other correctly signed batches: another slug, scope, ref and an empty or UTF-8 body", async () => {
    const r = await receiver();
    const accepted = loadPair("accepted");
    const variants = [
      build({ slug: "beta-shop", nonce: "n-1", body: "" }),
      build({ scope: "contacts:write", ref: "ref/with:punctuation", nonce: "n-2", body: '{"text":"Mã xác thực ✓"}' }),
      build({ nonce: "n-3", body: "x".repeat(100_000) }),
    ];
    for (const request of variants) {
      expectAnswerOf(r.send(request), accepted);
    }
  });

  it("hidden answers pairs/bad-signature.json for the recorded batch signed with another secret", async () => {
    const { actual, pair } = await replay("bad-signature");
    expectAnswerOf(actual, pair);
    expect(actual.status).toBe(401);
  });

  it("hidden answers pairs/bad-signature.json for a batch signed with another secret whose timestamp is stale too", async () => {
    const r = await receiver();
    const pair = loadPair("bad-signature");
    for (const timestamp of [T0 - 1000, T0 + 1000, T0 - 301]) {
      expectAnswerOf(r.send(build({ secret: WRONG_SECRET, timestamp, nonce: `stale-${timestamp}` })), pair);
    }
  });

  it("hidden answers pairs/bad-signature.json for a signature header with another prefix, upper-case hex or a wrong length", async () => {
    const r = await receiver();
    const pair = loadPair("bad-signature");
    const good = build({ nonce: "shape" }).headers["x-margince-signature"] as string;
    const hex = good.slice("sha256=".length);
    for (const value of [hex, `sha512=${hex}`, `sha256=${hex.toUpperCase()}`, `sha256=${hex.slice(0, 63)}`, `sha256=${hex}0`, `sha256=${"z".repeat(64)}`]) {
      expectAnswerOf(r.send(build({ nonce: "shape", headers: { "x-margince-signature": value } })), pair);
    }
  });

  it("hidden answers pairs/missing-header.json for the recorded batch without its nonce header", async () => {
    const { actual, pair } = await replay("missing-header");
    expectAnswerOf(actual, pair);
    expect(actual.status).toBe(400);
  });

  it.each(SIGNING_HEADERS)("hidden answers pairs/missing-header.json when %s is absent and when it is empty", async (header) => {
    const pair = loadPair("missing-header");
    const r = await receiver();
    const absent = build({ nonce: "absent" });
    const withoutIt = { ...absent.headers };
    delete withoutIt[header];
    expectAnswerOf(r.send({ ...absent, headers: withoutIt }), pair);
    expectAnswerOf(r.send(build({ nonce: "empty", headers: { [header]: "" } })), pair);
  });

  it("hidden answers pairs/accepted-window-edge.json for a batch exactly 300 seconds old", async () => {
    const { actual, pair } = await replay("accepted-window-edge");
    expectAnswerOf(actual, pair);
    expect(actual.status).toBe(202);
  });

  it("hidden answers pairs/stale-timestamp.json for a batch 301 seconds old", async () => {
    const { actual, pair } = await replay("stale-timestamp");
    expectAnswerOf(actual, pair);
    expect(actual.status).toBe(401);
  });

  it("hidden answers pairs/stale-timestamp-future.json for a batch 301 seconds ahead", async () => {
    const { actual, pair } = await replay("stale-timestamp-future");
    expectAnswerOf(actual, pair);
    expect(actual.status).toBe(401);
  });

  it("hidden accepts a batch 300 seconds ahead and refuses far stale ones in both directions, on the receiver's clock", async () => {
    const r = await receiver();
    const accepted = loadPair("accepted");
    const stale = loadPair("stale-timestamp");
    expectAnswerOf(r.send(build({ timestamp: T0 + 300, nonce: "ahead-300" })), accepted);
    expectAnswerOf(r.send(build({ timestamp: T0 - 3600, nonce: "old-hour" })), stale);
    expectAnswerOf(r.send(build({ timestamp: T0 + 3600, nonce: "new-hour" })), stale);
  });

  it("hidden answers stale_timestamp when the clock moves, not the request: the same batch is fresh, then 301 seconds old", async () => {
    const r = await receiver();
    const stale = loadPair("stale-timestamp");
    const accepted = loadPair("accepted");
    expectAnswerOf(r.send(build({ nonce: "edge-a" }), (T0 + 300) * 1000), accepted);
    expectAnswerOf(r.send(build({ nonce: "edge-b" }), (T0 + 301) * 1000 + 999), stale);
  });

  it("hidden answers pairs/stale-timestamp.json for a timestamp header that is not decimal digits", async () => {
    const r = await receiver();
    expectAnswerOf(r.send(build({ timestamp: "abc", nonce: "nan" })), loadPair("stale-timestamp"));
  });

  it("hidden answers pairs/reused-nonce.json for the recorded repeat of an accepted batch", async () => {
    const { actual, pair } = await replay("reused-nonce");
    expectAnswerOf(actual, pair);
    expect(actual.status).toBe(409);
  });

  it("hidden answers reused_nonce for a replay up to 300 seconds after the timestamp and stale_timestamp from 301", async () => {
    const r = await receiver();
    const request = build({ nonce: "replayed" });
    expect(r.send(request).status).toBe(202);
    expectAnswerOf(r.send(request, (T0 + 300) * 1000), loadPair("reused-nonce"));
    expectAnswerOf(r.send(request, (T0 + 301) * 1000), loadPair("stale-timestamp"));
  });

  it("hidden answers pairs/nonce-per-slug.json for the same nonce on another slug", async () => {
    const { actual, pair } = await replay("nonce-per-slug");
    expectAnswerOf(actual, pair);
    expect(actual.status).toBe(202);
  });

  it("hidden keeps a nonce per slug: after both slugs used it, each refuses its own replay", async () => {
    const r = await receiver();
    const accepted = loadPair("accepted");
    const reused = loadPair("reused-nonce");
    expectAnswerOf(r.send(build({ slug: "acme-sales", nonce: "shared" })), accepted);
    expectAnswerOf(r.send(build({ slug: "beta-shop", nonce: "shared" })), accepted);
    expectAnswerOf(r.send(build({ slug: "acme-sales", nonce: "shared" })), reused);
    expectAnswerOf(r.send(build({ slug: "beta-shop", nonce: "shared" })), reused);
  });

  it("hidden answers pairs/nonce-not-burned.json after a bad signature used the nonce", async () => {
    const { actual, pair } = await replay("nonce-not-burned");
    expectAnswerOf(actual, pair);
    expect(actual.status).toBe(202);
  });

  it("hidden does not burn a nonce on a request refused as stale or for a missing header", async () => {
    const r = await receiver();
    const accepted = loadPair("accepted");
    expect(r.send(build({ timestamp: T0 - 301, nonce: "stale-first" })).status).toBe(401);
    expectAnswerOf(r.send(build({ nonce: "stale-first" })), accepted);
    expect(r.send(build({ nonce: "empty-first", headers: { "x-margince-ref": "" } })).status).toBe(400);
    expectAnswerOf(r.send(build({ nonce: "empty-first" })), accepted);
  });

  it("hidden answers pairs/not-found.json for a path that is not the batch endpoint", async () => {
    const { actual, pair } = await replay("not-found");
    expectAnswerOf(actual, pair);
    expect(actual.status).toBe(404);
  });

  it("hidden answers pairs/not-found-wrong-method.json for the batch path with a method other than POST", async () => {
    const { actual, pair } = await replay("not-found-wrong-method");
    expectAnswerOf(actual, pair);
    expect(actual.status).toBe(404);
  });

  it("hidden answers not_found for other methods, a trailing slash, bad slugs and other paths, even without headers", async () => {
    const r = await receiver();
    const notFound = loadPair("not-found");
    const bare = (method: string, path: string): HttpRequest => ({ method, path, headers: {}, body: "", ip: IP });
    const requests: Array<[string, HttpRequest]> = [
      ["PUT", build({ method: "PUT" })],
      ["DELETE", build({ method: "DELETE" })],
      ["trailing slash", build({ path: "/v1/workspaces/acme-sales/batches/" })],
      ["upper-case slug", build({ path: "/v1/workspaces/Acme/batches" })],
      ["slug with leading hyphen", build({ path: "/v1/workspaces/-acme/batches" })],
      ["slug with double hyphen", build({ path: "/v1/workspaces/acme--sales/batches" })],
      ["slug of 64 characters", build({ path: `/v1/workspaces/${"a".repeat(64)}/batches` })],
      ["no slug", build({ path: "/v1/workspaces//batches" })],
      ["root", bare("POST", "/")],
      ["other prefix", bare("POST", "/v2/workspaces/acme-sales/batches")],
      ["unsigned GET", bare("GET", "/v1/workspaces/acme-sales/batches")],
    ];
    const wrong: string[] = [];
    for (const [label, request] of requests) {
      const response = r.send(request);
      if (response.status !== notFound.response.status || response.body !== notFound.response.body) wrong.push(label);
    }
    expect(wrong).toEqual([]);
  });

  it("hidden accepts a slug of 63 characters", async () => {
    const r = await receiver();
    const response = r.send(build({ slug: "a".repeat(63), nonce: "long-slug" }));
    expectAnswerOf(response, loadPair("accepted"));
  });

  it("hidden answers as the earlier row when a request fails twice: missing header before signature, signature before timestamp and nonce", async () => {
    const r = await receiver();
    const missing = loadPair("missing-header");
    const badSignature = loadPair("bad-signature");
    const noNonce = build({ secret: WRONG_SECRET, timestamp: T0 - 1000, nonce: "x" });
    const withoutNonce = { ...noNonce.headers };
    delete withoutNonce["x-margince-nonce"];
    expectAnswerOf(r.send({ ...noNonce, headers: withoutNonce }), missing);
    const used = build({ nonce: "twice" });
    expect(r.send(used).status).toBe(202);
    expectAnswerOf(r.send(build({ nonce: "twice", secret: WRONG_SECRET })), badSignature);
  });
});
