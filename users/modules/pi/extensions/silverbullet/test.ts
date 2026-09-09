import assert from "node:assert/strict";
import { randomBytes } from "node:crypto";
import { chmod, mkdtemp, rm, writeFile } from "node:fs/promises";
import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, before, describe, test } from "node:test";
import type { AddressInfo } from "node:net";
import { parseConfig, registerSilverbullet, type ResolvedConfig } from "./index.ts";

interface MockFile {
  content: string;
  created: number;
  lastModified: number;
  permission: string;
}

const files = {
  personal: new Map<string, MockFile>(),
  ksp: new Map<string, MockFile>(),
};
const tools = new Map<string, any>();
const confirmations: Array<{ title: string; summary: string }> = [];
let tempDirectory: string;
let tokenFile: string;
let token: string;
let baseUrl: string;
let config: ResolvedConfig;
let server: ReturnType<typeof createServer>;

function send(response: ServerResponse, status: number, body = "", headers: Record<string, string> = {}) {
  response.writeHead(status, headers);
  response.end(body);
}

function route(request: IncomingMessage): { space: keyof typeof files; page?: string } | undefined {
  const url = new URL(request.url ?? "/", baseUrl);
  let remainder: string;
  let space: keyof typeof files;
  if (url.pathname === "/.fs" || url.pathname.startsWith("/.fs/")) {
    space = "personal";
    remainder = url.pathname.slice("/.fs".length);
  } else if (url.pathname === "/ksp/.fs" || url.pathname.startsWith("/ksp/.fs/")) {
    space = "ksp";
    remainder = url.pathname.slice("/ksp/.fs".length);
  } else {
    return undefined;
  }
  const encodedPage = remainder.replace(/^\//, "");
  return {
    space,
    page: encodedPage ? encodedPage.split("/").map(decodeURIComponent).join("/") : undefined,
  };
}

async function handle(request: IncomingMessage, response: ServerResponse) {
  if (request.headers.authorization !== `Bearer ${token}`) {
    send(response, 401, "Unauthorized", { Location: "/.auth" });
    return;
  }
  const target = route(request);
  if (!target) {
    send(response, 404, "not found");
    return;
  }
  const spaceFiles = files[target.space];
  if (request.method === "GET" && target.page === undefined) {
    const list = [...spaceFiles].map(([name, file]) => ({
      name,
      created: file.created,
      lastModified: file.lastModified,
      contentType: "text/markdown",
      size: Buffer.byteLength(file.content),
      perm: file.permission,
    }));
    send(response, 200, JSON.stringify(list), { "Content-Type": "application/json" });
    return;
  }
  if (!target.page) {
    send(response, 405, "method not allowed");
    return;
  }
  const existing = spaceFiles.get(target.page);
  if (request.method === "GET" && target.page === "Reflect.md") {
    send(response, 500, `reflected ${request.headers.authorization}`);
    return;
  }
  if (request.method === "GET") {
    if (!existing) {
      send(response, 404, "404 page not found\n");
      return;
    }
    send(response, 200, existing.content, {
      "Content-Type": "application/octet-stream",
      "X-Content-Type": "text/markdown",
      "X-Created": String(existing.created),
      "X-Last-Modified": String(existing.lastModified),
      "X-Content-Length": String(Buffer.byteLength(existing.content)),
      "X-Permission": existing.permission,
    });
    return;
  }
  if (request.method === "PUT") {
    assert.equal(request.headers["x-sync-mode"], "true");
    assert.equal(request.headers["x-permission"], "rw");
    const chunks: Buffer[] = [];
    for await (const chunk of request) chunks.push(Buffer.from(chunk));
    const now = Number(request.headers["x-last-modified"]);
    spaceFiles.set(target.page, {
      content: Buffer.concat(chunks).toString("utf8"),
      created: Number(request.headers["x-created"]),
      lastModified: now,
      permission: String(request.headers["x-permission"]),
    });
    send(response, 200, "OK");
    return;
  }
  if (request.method === "DELETE") {
    if (!existing) {
      send(response, 404, "404 page not found\n");
      return;
    }
    spaceFiles.delete(target.page);
    send(response, 200, "OK");
    return;
  }
  send(response, 405, "method not allowed");
}

function rawConfig(overrides: Record<string, unknown> = {}) {
  return {
    baseUrl,
    allowInsecureHttp: true,
    tokenFile,
    defaultSpace: "personal",
    spaces: {
      personal: { label: "Personal", path: "/" },
      ksp: { label: "KSP", path: "/ksp" },
    },
    ...overrides,
  };
}

const context = {
  hasUI: true,
  ui: {
    confirm: async (title: string, summary: string) => {
      confirmations.push({ title, summary });
      return true;
    },
  },
};

async function execute(name: string, params: Record<string, unknown>, ctx: any = context) {
  const tool = tools.get(name);
  assert.ok(tool, `tool ${name} was registered`);
  return tool.execute("test-call", params, undefined, undefined, ctx);
}

before(async () => {
  tempDirectory = await mkdtemp(join(tmpdir(), "silverbullet-pi-test-"));
  tokenFile = join(tempDirectory, "token");
  token = randomBytes(32).toString("hex");
  await writeFile(tokenFile, `${token}\n`, { mode: 0o600 });

  server = createServer((request, response) => void handle(request, response));
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const address = server.address() as AddressInfo;
  baseUrl = `http://127.0.0.1:${address.port}`;

  const stamp = 1_750_000_000_000;
  files.personal.set("Shared.md", { content: "AAA target\n", created: stamp, lastModified: stamp, permission: "rw" });
  files.ksp.set("Shared.md", { content: "BBB target\n", created: stamp, lastModified: stamp, permission: "rw" });
  config = parseConfig(rawConfig());
  registerSilverbullet(
    {
      registerTool: (tool: any) => tools.set(tool.name, tool),
      on: () => undefined,
    } as any,
    config,
  );
});

after(async () => {
  await new Promise<void>((resolve, reject) => server.close((error) => (error ? reject(error) : resolve())));
  await rm(tempDirectory, { recursive: true, force: true });
});

describe("configuration and path security", () => {
  test("resolves root and prefixed spaces with Personal as default", () => {
    assert.equal(config.defaultSpace, "personal");
    assert.equal(config.spaces.personal.baseUrl, baseUrl);
    assert.equal(config.spaces.ksp.baseUrl, `${baseUrl}/ksp`);
    const schema = tools.get("silverbullet_read").parameters.properties.space;
    assert.deepEqual(schema.enum, ["ksp", "personal"]);
    assert.equal(schema.default, "personal");
  });

  test("rejects unsafe origins, token files, defaults, and space prefixes", async () => {
    assert.throws(() => parseConfig(rawConfig({ baseUrl: `${baseUrl}/path` })), /must not contain a path/);
    assert.throws(() => parseConfig(rawConfig({ baseUrl: baseUrl.replace("http:", "ftp:") })), /HTTP or HTTPS/);
    assert.throws(() => parseConfig(rawConfig({ tokenFile: "relative-token" })), /absolute path/);
    assert.throws(() => parseConfig(rawConfig({ defaultSpace: "missing" })), /must name a configured space/);
    assert.throws(
      () => parseConfig(rawConfig({ spaces: { personal: { label: "Personal", path: "/../escape" } } })),
      /reserved or invalid segment/,
    );
    assert.throws(
      () => parseConfig(rawConfig({ spaces: { personal: { label: "Personal", path: "/ksp/" } } })),
      /canonical URL prefix/,
    );
    assert.throws(
      () =>
        parseConfig(
          rawConfig({
            spaces: {
              personal: { label: "Personal", path: "/" },
              ksp: { label: "KSP", path: "/ksp" },
              nested: { label: "Nested", path: "/ksp/private" },
            },
          }),
        ),
      /must not be nested/,
    );

    await chmod(tokenFile, 0o640);
    assert.throws(() => parseConfig(rawConfig()), /must not be accessible by group or other users/);
    await chmod(tokenFile, 0o600);
  });

  test("rejects cross-space and managed page paths", async () => {
    await assert.rejects(() => execute("silverbullet_read", { page: "/ksp/Shared.md" }), /relative path/);
    await assert.rejects(
      () => execute("silverbullet_create", { page: "../escape", content: "no" }),
      /invalid path segment/,
    );
    await assert.rejects(
      () => execute("silverbullet_create", { page: "Library/Owned", content: "no" }),
      /managed path is read-only/,
    );
    await assert.rejects(() => execute("silverbullet_read", { space: "other", page: "Shared" }), /Unknown.*space/);
  });
});

describe("MultiSpace tool integration", () => {
  test("lists and reads Personal by default and KSP only when selected", async () => {
    const personalList = await execute("silverbullet_search", {});
    assert.match(personalList.content[0].text, /Space: Personal \(personal\)/);
    assert.equal(personalList.details.space, "personal");

    const personalRead = await execute("silverbullet_read", { page: "Shared" });
    const kspRead = await execute("silverbullet_read", { space: "ksp", page: "Shared" });
    assert.match(personalRead.content[0].text, /AAA target/);
    assert.doesNotMatch(personalRead.content[0].text, /BBB target/);
    assert.match(kspRead.content[0].text, /Space: KSP \(ksp\)/);
    assert.match(kspRead.content[0].text, /BBB target/);
  });

  test("keeps same-path search caches isolated between spaces", async () => {
    const personal = await execute("silverbullet_search", { query: "AAA" });
    const ksp = await execute("silverbullet_search", { space: "ksp", query: "BBB" });
    assert.match(personal.content[0].text, /AAA target/);
    assert.match(ksp.content[0].text, /BBB target/);
  });

  test("creates and appends independently in both spaces", async () => {
    for (const space of ["personal", "ksp"] as const) {
      const selection = space === "personal" ? {} : { space };
      const created = await execute("silverbullet_create", {
        ...selection,
        page: "Tests/Write",
        content: `created-${space}`,
      });
      assert.equal(created.details.space, space);
      await execute("silverbullet_append", { ...selection, page: "Tests/Write", content: `appended-${space}` });
      assert.equal(files[space].get("Tests/Write.md")?.content, `created-${space}\nappended-${space}`);
      assert.equal(files[space].get("Tests/Write.md")?.permission, "rw");
    }
  });

  test("confirms updates with the selected space and changes only that space", async () => {
    await execute("silverbullet_update", {
      space: "ksp",
      action: "replace_text",
      page: "Tests/Write",
      find: "created-ksp",
      replacement: "updated-ksp",
    });
    assert.match(confirmations.at(-1)?.title ?? "", /KSP/);
    assert.match(confirmations.at(-1)?.summary ?? "", /Space: KSP \(ksp\)/);
    assert.match(files.ksp.get("Tests/Write.md")?.content ?? "", /updated-ksp/);
    assert.match(files.personal.get("Tests/Write.md")?.content ?? "", /created-personal/);
  });

  test("fails closed without UI and honors a rejected confirmation", async () => {
    const before = files.personal.get("Tests/Write.md")?.content;
    await assert.rejects(
      () =>
        execute(
          "silverbullet_update",
          { action: "replace_page", page: "Tests/Write", content: "blocked" },
          { hasUI: false },
        ),
      /require interactive user confirmation/,
    );
    await assert.rejects(
      () =>
        execute(
          "silverbullet_update",
          { action: "delete", page: "Tests/Write" },
          { hasUI: true, ui: { confirm: async () => false } },
        ),
      /cancelled by user/,
    );
    assert.equal(files.personal.get("Tests/Write.md")?.content, before);
  });

  test("deletes only after confirmation and never exposes the bearer token", async () => {
    const result = await execute("silverbullet_update", { space: "ksp", action: "delete", page: "Tests/Write" });
    assert.equal(files.ksp.has("Tests/Write.md"), false);
    assert.equal(files.personal.has("Tests/Write.md"), true);
    assert.equal(JSON.stringify({ result, confirmations }).includes(token), false);

    await assert.rejects(
      () => execute("silverbullet_read", { page: "Reflect" }),
      (error: Error) => error.message.includes("[REDACTED]") && !error.message.includes(token),
    );
  });
});
