import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";

interface Parts {
  scope: string;
  slug: string;
  ref: string;
  timestamp: number;
  nonce: string;
  body: string;
}

interface RawVector {
  name: string;
  secret: string;
  parts: Omit<Parts, "body"> & { body: string | { repeat: string; times: number } };
  signature: string;
}

interface Vector {
  name: string;
  secret: string;
  parts: Parts;
  signature: string;
}

// vectors.json spells a long body as {"repeat": text, "times": n}; every other body is the string itself.
const contract = new URL("../../contract/margince/", import.meta.url);
const rawVectors: RawVector[] = JSON.parse(
  readFileSync(fileURLToPath(new URL("vectors.json", contract)), "utf8"),
).vectors;
const vectors: Vector[] = rawVectors.map((v) => ({
  ...v,
  parts: { ...v.parts, body: typeof v.parts.body === "string" ? v.parts.body : v.parts.body.repeat.repeat(v.parts.body.times) },
}));

async function signature() {
  return import("../margince/signature.ts");
}

describe("hidden S2-A sign and verify Margince requests", () => {
  it("hidden sign returns the vector's signature for every vector", async () => {
    const { sign } = await signature();
    const wrong: string[] = [];
    for (const v of vectors) {
      if (sign(v.secret, v.parts) !== v.signature) wrong.push(v.name);
    }
    expect(wrong).toEqual([]);
  });

  it("hidden sign returns 64 lower-case hex characters without a prefix", async () => {
    const { sign } = await signature();
    for (const v of vectors) {
      expect(sign(v.secret, v.parts)).toMatch(/^[0-9a-f]{64}$/);
    }
  });

  it("hidden verify accepts every vector's parts with its signature", async () => {
    const { verify } = await signature();
    const wrong: string[] = [];
    for (const v of vectors) {
      if (verify(v.secret, v.parts, v.signature) !== true) wrong.push(v.name);
    }
    expect(wrong).toEqual([]);
  });

  const changes: Array<[string, (p: Parts) => Parts]> = [
    ["scope", (p) => ({ ...p, scope: `${p.scope}x` })],
    ["slug", (p) => ({ ...p, slug: `${p.slug}x` })],
    ["ref", (p) => ({ ...p, ref: `${p.ref}x` })],
    ["timestamp", (p) => ({ ...p, timestamp: p.timestamp + 1 })],
    ["nonce", (p) => ({ ...p, nonce: `${p.nonce.slice(0, -1)}${p.nonce.endsWith("0") ? "1" : "0"}` })],
    ["body", (p) => ({ ...p, body: `${p.body} ` })],
  ];

  it.each(changes)("hidden verify rejects a vector whose %s was changed", async (_field, change) => {
    const { verify } = await signature();
    const wrong: string[] = [];
    for (const v of vectors) {
      if (verify(v.secret, change(v.parts), v.signature) !== false) wrong.push(v.name);
    }
    expect(wrong).toEqual([]);
  });

  it("hidden verify rejects every vector checked with a different secret", async () => {
    const { verify } = await signature();
    const wrong: string[] = [];
    for (const v of vectors) {
      for (const other of [`${v.secret}x`, "some-other-secret-9999", v.secret.toUpperCase()]) {
        if (verify(other, v.parts, v.signature) !== false) wrong.push(`${v.name} / ${other}`);
      }
    }
    expect(wrong).toEqual([]);
  });

  it("hidden sign with another secret gives another signature", async () => {
    const { sign } = await signature();
    const v = vectors[0] as Vector;
    expect(sign("some-other-secret-9999", v.parts)).not.toBe(v.signature);
  });

  const badSignatures: Array<[string, (s: string) => string]> = [
    ["shorter by one character", (s) => s.slice(0, 63)],
    ["much shorter", (s) => s.slice(0, 8)],
    ["empty", () => ""],
    ["longer by one character", (s) => `${s}0`],
    ["twice as long", (s) => s + s],
    ["upper case", (s) => s.toUpperCase()],
    ["with the sha256= prefix", (s) => `sha256=${s}`],
    ["64 characters that are not hex", (s) => `${s.slice(0, 63)}g`],
  ];

  it.each(badSignatures)("hidden verify returns false and does not throw for a signature %s", async (_what, change) => {
    const { verify } = await signature();
    for (const v of vectors) {
      let result: unknown;
      expect(() => {
        result = verify(v.secret, v.parts, change(v.signature));
      }).not.toThrow();
      expect(result).toBe(false);
    }
  });
});
