import { test } from "node:test";
import assert from "node:assert/strict";
import { HttpTransport } from "./transport.ts";

const spaces = [
  { id: "personal" as const, label: "Personal", prefix: "" },
  { id: "ksp" as const, label: "KSP", prefix: "/ksp" },
];

test("the native browser fetch keeps its Window receiver", async () => {
  const original = globalThis.fetch;
  globalThis.fetch = async function () {
    assert.equal(
      this,
      globalThis,
      "Illegal invocation: native fetch requires its Window receiver",
    );
    return new Response("content", { headers: { ETag: '"native"' } });
  };
  try {
    const transport = new HttpTransport({ origin: "https://notes.example", spaces });
    assert.equal((await transport.read("personal", "Note.md"))?.text, "content");
  } finally {
    globalThis.fetch = original;
  }
});

test("binary reads use the browser session and preserve revision and bytes", async () => {
  const calls: Array<{ url: string; options: RequestInit }> = [];
  const body = new Uint8Array([0, 255, 10, 13]);
  const transport = new HttpTransport({
    origin: "https://notes.example",
    spaces,
    fetcher: async (url, options) => {
      calls.push({ url: String(url), options: options ?? {} });
      return new Response(body, {
        headers: {
          ETag: '"sha256:fixture"',
          "Content-Type": "application/pdf",
          "X-Last-Modified": "100",
        },
      });
    },
  });
  const result = await transport.read("ksp", "assets/a b.pdf");
  assert.deepEqual(result?.bytes, body);
  assert.equal(result?.revision, '"sha256:fixture"');
  assert.equal(calls[0].url, "https://notes.example/ksp/.fs/assets/a%20b%2Epdf");
  assert.equal(calls[0].options.credentials, "same-origin");
  assert.equal(calls[0].options.redirect, "error");
  assert.equal(new Headers(calls[0].options.headers).has("Authorization"), false);
});

test("create-only writes and conditional deletions verify the remote result", async () => {
  let current: Uint8Array | null = null;
  const writes: RequestInit[] = [];
  const transport = new HttpTransport({
    origin: "https://notes.example",
    spaces,
    fetcher: async (_url, options) => {
      const method = options?.method ?? "GET";
      if (method === "PUT") {
        writes.push(options!);
        assert.equal(new Headers(options?.headers).get("If-None-Match"), "*");
        current = new Uint8Array(options!.body as Uint8Array);
        return new Response(null, { status: 200 });
      }
      if (method === "DELETE") {
        assert.equal(new Headers(options?.headers).get("If-Match"), '"sha256:written"');
        current = null;
        return new Response(null, { status: 200 });
      }
      return current === null
        ? new Response(null, { status: 404 })
        : new Response(new Uint8Array(current), {
            headers: { ETag: '"sha256:written"' },
          });
    },
  });
  const written = await transport.write(
    "ksp",
    "Test.md",
    new TextEncoder().encode("hello"),
    { create: true },
  );
  assert.equal(written.text, "hello");
  assert.equal(writes.length, 1);
  await transport.remove("ksp", "Test.md", written.revision);
  assert.equal(await transport.read("ksp", "Test.md"), null);
});

test("inventory maps upstream metadata and refuses incomplete or malformed listings", async () => {
  const transport = new HttpTransport({
    origin: "https://notes.example",
    spaces,
    fetcher: async () =>
      new Response(
        JSON.stringify([
          { name: "Note.md", size: 12, contentType: "text/markdown", perm: "rw" },
          { name: "assets/a.pdf", size: 4, contentType: "application/pdf", perm: "ro" },
        ]),
      ),
  });
  const files = await transport.list("personal");
  assert.deepEqual(
    files.map((file) => file.path),
    ["Note.md", "assets/a.pdf"],
  );
  assert.equal(files[1].readOnly, true);
});

test("unsafe connection paths and missing revisions fail closed", async () => {
  let called = false;
  const transport = new HttpTransport({
    origin: "https://notes.example",
    spaces,
    fetcher: async () => {
      called = true;
      return new Response("data");
    },
  });
  for (const path of [
    "../outside",
    "/absolute",
    "a/../b",
    "a//b",
    "a\\b",
    "x\u0000.md",
  ]) {
    await assert.rejects(() => transport.read("personal", path), /Invalid/);
  }
  assert.equal(called, false);
  await assert.rejects(() => transport.read("personal", "Note.md"), /revision/);
});

test("authentication failures, redirects, and revision conflicts do not retry", async () => {
  for (const status of [401, 403, 302, 409, 412, 500]) {
    let calls = 0;
    const transport = new HttpTransport({
      origin: "https://notes.example",
      spaces,
      fetcher: async () => {
        calls++;
        return new Response(null, { status });
      },
    });
    await assert.rejects(() => transport.read("ksp", "Note.md"));
    assert.equal(calls, 1);
  }
});

test("streaming limits and corrupt upload readback are rejected", async () => {
  const limited = new HttpTransport({
    origin: "https://notes.example",
    spaces,
    maxBytes: 2,
    fetcher: async () =>
      new Response(new Uint8Array([1, 2, 3]), { headers: { ETag: '"x"' } }),
  });
  await assert.rejects(() => limited.read("personal", "a.pdf"), /limit/);
  const corrupt = new HttpTransport({
    origin: "https://notes.example",
    spaces,
    fetcher: async (_url, options) =>
      options?.method === "PUT"
        ? new Response(null)
        : new Response("wrong", { headers: { ETag: '"x"' } }),
  });
  await assert.rejects(
    () =>
      corrupt.write("ksp", "Note.md", new TextEncoder().encode("right"), {
        create: true,
      }),
    /verification/,
  );
});
