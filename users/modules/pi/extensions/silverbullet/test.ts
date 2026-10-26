import assert from "node:assert/strict";
import { spawn } from "node:child_process";
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
const permissionPrompts: Array<{ title: string; options: string[] }> = [];
const permissionChoices: Array<string | undefined> = [];
const blockedEvents: Array<{ active: boolean; label?: string }> = [];
const sessionStartHandlers: Array<() => void> = [];
let tempDirectory: string;
let tokenFile: string;
let token: string;
let baseUrl: string;
let config: ResolvedConfig;
let server: ReturnType<typeof createServer>;
let failJournalWrites = false;
let failJournalReadAfterWrite = false;
const requests: Array<{ method: string; space: string; page?: string }> = [];
const rejectedWrites = new Set<string>();
let failNextJournalRead = false;
let pretendDelete = false;

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
  requests.push({ method: request.method ?? "", ...target });
  if (request.method === "PUT" && target.page?.startsWith("Journal/") && failJournalWrites) {
    send(response, 503, "journal unavailable");
    return;
  }
  if ((request.method === "PUT" || request.method === "DELETE") && rejectedWrites.has(target.page ?? "")) {
    send(response, 503, "write rejected");
    return;
  }
  if (request.method === "GET" && target.page?.startsWith("Journal/") && failNextJournalRead) {
    failNextJournalRead = false;
    send(response, 503, "journal verification unavailable");
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
    if (target.page.startsWith("Journal/") && failJournalReadAfterWrite) failNextJournalRead = true;
    send(response, 200, "OK");
    return;
  }
  if (request.method === "DELETE") {
    if (!existing) {
      send(response, 404, "404 page not found\n");
      return;
    }
    if (!pretendDelete) spaceFiles.delete(target.page);
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
    select: async (title: string, options: string[]) => {
      permissionPrompts.push({ title, options });
      return permissionChoices.length > 0 ? permissionChoices.shift() : "Allow once";
    },
  },
};

async function execute(name: string, params: Record<string, unknown>, ctx: any = context) {
  const tool = tools.get(name);
  assert.ok(tool, `tool ${name} was registered`);
  const defaults = ["silverbullet_create", "silverbullet_append", "silverbullet_update"].includes(name)
    ? { change_summary: "Updated test note" }
    : {};
  return tool.execute("test-call", { ...defaults, ...params }, undefined, undefined, ctx);
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
      on: (event: string, handler: () => void) => {
        if (event === "session_start") sessionStartHandlers.push(handler);
      },
      events: {
        emit: (event: string, data: { active: boolean; label?: string }) => {
          if (event === "herdr:blocked") blockedEvents.push(data);
        },
      },
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

describe("journal enforcement", () => {
  test("requires a brief summary before non-journal mutations", async () => {
    await assert.rejects(
      () => execute("silverbullet_create", { page: "Tests/MissingSummary", content: "note", change_summary: undefined }),
      /change_summary/,
    );
    assert.equal(files.personal.has("Tests/MissingSummary.md"), false);
  });

  test("no-op replacements do not write or journal or prompt", async () => {
    await execute("silverbullet_create", { page: "Tests/Noop", content: "unchanged" });
    const before = JSON.stringify([...files.personal]);
    const prompts = permissionPrompts.length;
    for (const params of [
      { action: "replace_page", content: "unchanged" },
      { action: "replace_text", find: "unchanged", replacement: "unchanged" },
    ]) {
      const result = await execute("silverbullet_update", { page: "Tests/Noop", ...params });
      assert.equal(result.details.changed, false);
      assert.equal(result.details.journal.status, "skipped_noop");
    }
    assert.equal(JSON.stringify([...files.personal]), before);
    assert.equal(permissionPrompts.length, prompts);
  });

  test("daily journal targets need no summary and never recurse", async () => {
    const result = await execute("silverbullet_create", { page: "Journal/2000-01-01", content: "direct entry", change_summary: undefined });
    assert.equal(result.details.journal.status, "exempt");
    assert.equal(files.personal.get("Journal/2000-01-01.md")?.content, "direct entry");
  });

  test("deletion is verified before recording activity", async () => {
    await execute("silverbullet_create", { page: "Tests/DeleteVerification", content: "keep" });
    const before = requests.length;
    pretendDelete = true;
    try {
      await assert.rejects(
        () => execute("silverbullet_update", { page: "Tests/DeleteVerification", action: "delete" }),
        /deletion verification failed/,
      );
    } finally {
      pretendDelete = false;
    }
    assert.equal(requests.slice(before).some((request) => request.page?.startsWith("Journal/")), false);
  });

  test("partial success returns a restart-safe journal-only retry payload", async () => {
    failJournalWrites = true;
    let result: any;
    try {
      result = await execute("silverbullet_append", { page: "Tests/Partial", content: "once", operation_id: "caller-partial-1" });
    } finally {
      failJournalWrites = false;
    }
    assert.equal(files.personal.get("Tests/Partial.md")?.content, "once");
    assert.equal(result.details.status, "partial_success");
    assert.equal(result.details.note_status, "succeeded");
    assert.equal(result.details.journal.status, "failed");
    assert.match(result.content[0].text, /Do not replay.*silverbullet_journal_retry/);
    assert.ok(result.content[0].text.includes(JSON.stringify({ retry: result.details.journal.retry })), "model-visible text includes the self-contained retry arguments");
    const retry = JSON.parse(JSON.stringify(result.details.journal.retry));
    assert.equal(retry.operation_id, "caller-partial-1");
    const fresh = await import(`./index.ts?retry=${Date.now()}`);
    fresh.registerSilverbullet({ registerTool: (tool: any) => { if (tool.name === "silverbullet_journal_retry") tools.set(tool.name, tool); }, on: () => {}, events: { emit: () => {} } } as any, config);
    const start = requests.length;
    // The child has no parent module state; only config and the saved payload.
    const loader = process.execArgv[process.execArgv.indexOf("--import") + 1];
    assert.ok(loader);
    const child = spawn(process.execPath, ["--import", loader, "--input-type=module", "--eval", `
      import { registerSilverbullet } from ${JSON.stringify(new URL("./index.ts", import.meta.url).href)};
      let input = "";
      for await (const chunk of process.stdin) input += chunk;
      const { config, retry } = JSON.parse(input);
      let retryTool;
      registerSilverbullet({ registerTool: tool => { if (tool.name === "silverbullet_journal_retry") retryTool = tool; }, on() {}, events: { emit() {} } }, config);
      const result = await retryTool.execute("child-retry", { retry }, undefined, undefined, { hasUI: false });
      console.log(JSON.stringify(result));
    `], { stdio: ["pipe", "pipe", "pipe"] });
    let output = "";
    let errors = "";
    child.stdout.on("data", (chunk) => { output += chunk; });
    child.stderr.on("data", (chunk) => { errors += chunk; });
    const finished = new Promise<void>((resolve, reject) => {
      child.on("error", reject);
      child.on("close", (code) => code === 0 ? resolve() : reject(new Error(`Retry child failed (${code}): ${errors}`)));
    });
    child.stdin.end(JSON.stringify({ config, retry }));
    await finished;
    assert.equal(JSON.parse(output).details.journal.status, "recorded");
    const retried = await execute("silverbullet_journal_retry", { retry }, { hasUI: false });
    assert.equal(retried.details.journal.status, "already_recorded");
    const again = await execute("silverbullet_journal_retry", { retry });
    assert.equal(again.details.journal.status, "already_recorded");
    assert.ok(requests.slice(start).every((request) => request.page === retry.journal_page));
    assert.equal(files.personal.get("Tests/Partial.md")?.content, "once");
    const journal = files.personal.get(retry.journal_page)?.content ?? "";
    assert.equal(journal.split(`<!-- inigo-journal:${retry.marker_id} -->`).length - 1, 1);
  });

  test("journal entries cannot inject markup through summary or unusual note names", async () => {
    const result = await execute("silverbullet_create", {
      page: "Tests/Brackets]]", content: "safe", change_summary: "Saved <!-- hidden --> [[Other]]",
    });
    const journal = files.personal.get(result.details.journal.page)?.content ?? "";
    assert.match(journal, /Tests\/Brackets%5D%5D/);
    assert.ok(journal.includes("](</Tests/Brackets%5D%5D.md>)"));
    assert.match(journal, /Saved &lt;!-- hidden --&gt;/);
    assert.doesNotMatch(journal, /\[\[Other\]\]/);
  });

  test("validates summaries and caller IDs before any mutation or approval", async () => {
    const before = requests.length;
    const prompts = permissionPrompts.length;
    for (const name of ["silverbullet_create", "silverbullet_append", "silverbullet_update"]) {
      for (const change_summary of [undefined, "", "  ", "two\nlines", "x".repeat(281)]) {
        await assert.rejects(() => execute(name, { page: "Tests/Invalid", content: "note", action: "delete", change_summary }), /change_summary/);
      }
      await assert.rejects(() => execute(name, { page: "Tests/Invalid", content: "note", action: "delete", operation_id: "invalid id" }), /operation_id/);
    }
    assert.equal(requests.length, before);
    assert.equal(permissionPrompts.length, prompts);
  });

  test("New York date boundaries and DST do not use the UTC or host date", async (t) => {
    t.mock.timers.enable({ apis: ["Date"], now: new Date("2026-01-02T04:59:59Z") });
    const cases = [
      ["2026-01-02T04:59:59Z", "2026-01-01"],
      ["2026-01-02T05:00:00Z", "2026-01-02"],
      ["2026-07-02T03:59:59Z", "2026-07-01"],
      ["2026-07-02T04:00:00Z", "2026-07-02"],
    ];
    for (const [instant, day] of cases) {
      t.mock.timers.setTime(new Date(instant).getTime());
      const result = await execute("silverbullet_create", { page: `Tests/Date-${instant.replaceAll(":", "-")}`, content: "date" });
      assert.equal(result.details.journal.page, `Journal/${day}.md`);
    }
  });

  test("failed and denied note writes never touch the journal", async () => {
    await execute("silverbullet_create", { page: "Tests/Failure", content: "original" });
    let start = requests.length;
    permissionChoices.push("Deny");
    await assert.rejects(() => execute("silverbullet_update", { page: "Tests/Failure", action: "delete" }), /cancelled/);
    assert.ok(requests.slice(start).every((request) => request.page === "Tests/Failure.md" && request.method === "GET"));
    rejectedWrites.add("Tests/Failure.md");
    start = requests.length;
    try {
      for (const [name, params] of [
        ["silverbullet_append", { content: "blocked" }],
        ["silverbullet_update", { action: "replace_page", content: "blocked" }],
        ["silverbullet_update", { action: "delete" }],
      ] as const) {
        await assert.rejects(() => execute(name, { page: "Tests/Failure", ...params }), /write rejected/);
      }
    } finally {
      rejectedWrites.delete("Tests/Failure.md");
    }
    assert.ok(requests.slice(start).every((request) => request.page === "Tests/Failure.md"));
    assert.equal(files.personal.get("Tests/Failure.md")?.content, "original");
    rejectedWrites.add("Tests/FailedCreate.md");
    try {
      await assert.rejects(() => execute("silverbullet_create", { page: "Tests/FailedCreate", content: "blocked" }), /write rejected/);
    } finally {
      rejectedWrites.delete("Tests/FailedCreate.md");
    }
    assert.equal(files.personal.has("Tests/FailedCreate.md"), false);
  });

  test("retry detects a persisted marker after journal commit but failed verification", async () => {
    failJournalReadAfterWrite = true;
    let result: any;
    try {
      result = await execute("silverbullet_create", { page: "Tests/AmbiguousJournal", content: "once" });
    } finally {
      failJournalReadAfterWrite = false;
    }
    assert.equal(result.details.status, "partial_success");
    const start = requests.length;
    const retried = await execute("silverbullet_journal_retry", { retry: result.details.journal.retry });
    assert.equal(retried.details.journal.status, "already_recorded");
    assert.deepEqual(requests.slice(start).map((request) => request.method), ["GET"]);
  });

  test("all mutation kinds return recoverable partial journal results without replay", async () => {
    await execute("silverbullet_create", { page: "Tests/PartialUpdate", content: "first" });
    for (const [name, params] of [
      ["silverbullet_create", { page: "Tests/PartialCreate", content: "first" }],
      ["silverbullet_update", { page: "Tests/PartialUpdate", action: "replace_page", content: "second" }],
      ["silverbullet_update", { page: "Tests/PartialUpdate", action: "replace_text", find: "second", replacement: "third" }],
      ["silverbullet_update", { page: "Tests/PartialUpdate", action: "delete" }],
    ] as const) {
      failJournalWrites = true;
      let result: any;
      try { result = await execute(name, params); } finally { failJournalWrites = false; }
      assert.equal(result.details.status, "partial_success");
      const retry = result.details.journal.retry;
      failJournalWrites = true;
      try {
        const failed = await execute("silverbullet_journal_retry", { retry });
        assert.equal(failed.details.status, "journal_failed");
        assert.deepEqual(failed.details.journal.retry, retry);
      } finally { failJournalWrites = false; }
      const retried = await execute("silverbullet_journal_retry", { retry });
      assert.equal(retried.details.journal.status, "recorded");
      if (retry.action === "delete") {
        const line = files.personal.get(retry.journal_page)!.content.split("\n").find((line) => line.includes(retry.marker_id))!;
        assert.match(line, /Deleted Tests\/PartialUpdate\.md — Updated test note/);
        assert.doesNotMatch(line, /\[\[/);
        assert.equal(files.personal.has("Tests/PartialUpdate.md"), false);
      }
    }
  });

  test("read-only journal yields partial success and retry preserves existing journal bytes", async () => {
    const seed = await execute("silverbullet_create", { page: "Tests/ReadonlySeed", content: "seed" });
    const page = seed.details.journal.page;
    const file = files.personal.get(page)!;
    const prefix = file.content;
    file.permission = "ro";
    let result: any;
    try {
      result = await execute("silverbullet_create", { page: "Tests/ReadonlyJournal", content: "saved" });
      assert.equal(result.details.status, "partial_success");
      assert.match(result.details.journal.error, /read-only/);
      assert.equal(files.personal.get(page)!.content, prefix);
    } finally { file.permission = "rw"; }
    await execute("silverbullet_journal_retry", { retry: result.details.journal.retry });
    assert.ok(files.personal.get(page)!.content.startsWith(prefix));
  });

  test("tampered retry payloads cannot cross spaces or write arbitrary paths", async () => {
    const result = await execute("silverbullet_create", { page: "Tests/RetryValidation", content: "saved" });
    const retry = result.details.journal.retry;
    const start = requests.length;
    for (const override of [
      { space: "ksp" }, { space: "missing" }, { page: "../escape.md" }, { page: "Library/Owned.md" },
      { journal_page: "Tests/Escape.md" }, { journal_page: "Journal/../Escape.md" },
      { marker_id: "0".repeat(64) }, { action: "execute" }, { change_summary: "different" }, { operation_id: "" },
    ]) {
      await assert.rejects(() => execute("silverbullet_journal_retry", { retry: { ...retry, ...override } }));
    }
    assert.equal(requests.length, start);
  });

  test("concurrent journal appends serialize and repeated caller IDs deduplicate journaling only", async () => {
    const results = await Promise.all(["A", "B", "C"].map((suffix) => execute("silverbullet_create", { page: `Tests/Concurrent${suffix}`, content: suffix })));
    const journal = files.personal.get(results[0].details.journal.page)!.content;
    for (const result of results) assert.ok(journal.includes(result.details.journal.retry.marker_id));
    const first = await execute("silverbullet_append", { page: "Tests/CallerId", content: "first", operation_id: "same-logical-operation" });
    const second = await execute("silverbullet_append", { page: "Tests/CallerId", content: "second", operation_id: "same-logical-operation" });
    assert.equal(second.details.journal.status, "already_recorded");
    assert.equal(first.details.journal.retry.marker_id, second.details.journal.retry.marker_id);
    assert.equal(files.personal.get("Tests/CallerId.md")!.content, "first\nsecond");
  });

  test("successful writes append a same-space link and brief summary to the New York journal", async () => {
    const date = new Intl.DateTimeFormat("en-CA", { timeZone: "America/New_York", year: "numeric", month: "2-digit", day: "2-digit" }).format(new Date());
    const personalBefore = files.personal.get(`Journal/${date}.md`)?.content;
    const result = await execute("silverbullet_create", {
      space: "ksp", page: "Tests/Journaled", content: "note", change_summary: "Recorded deployment decision",
    });
    assert.equal(result.details.journal.status, "recorded");
    assert.equal(result.details.journal.page, `Journal/${date}.md`);
    assert.match(files.ksp.get(`Journal/${date}.md`)?.content ?? "", /\[\[Tests\/Journaled\]\] — Recorded deployment decision/);
    assert.equal(files.personal.get(`Journal/${date}.md`)?.content, personalBefore);
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
    assert.match(permissionPrompts.at(-1)?.title ?? "", /KSP/);
    assert.match(permissionPrompts.at(-1)?.title ?? "", /Space: KSP \(ksp\)/);
    assert.deepEqual(permissionPrompts.at(-1)?.options, [
      "Allow once",
      "Allow all SilverBullet replacements/deletions for this session",
      "Deny",
    ]);
    assert.deepEqual(blockedEvents.slice(-2), [
      { active: true, label: "Approve SilverBullet update" },
      { active: false },
    ]);
    assert.match(files.ksp.get("Tests/Write.md")?.content ?? "", /updated-ksp/);
    assert.match(files.personal.get("Tests/Write.md")?.content ?? "", /created-personal/);
  });

  test("allows all later destructive updates only for the current session", async () => {
    const promptCount = permissionPrompts.length;
    permissionChoices.push("Allow all SilverBullet replacements/deletions for this session");
    await execute("silverbullet_update", {
      action: "replace_text",
      page: "Tests/Write",
      find: "created-personal",
      replacement: "session-personal",
    });
    await execute("silverbullet_update", {
      action: "replace_text",
      page: "Tests/Write",
      find: "session-personal",
      replacement: "session-personal-2",
    });
    assert.equal(permissionPrompts.length, promptCount + 1);

    for (const handler of sessionStartHandlers) handler();
    permissionChoices.push("Allow once");
    await execute("silverbullet_update", {
      action: "replace_text",
      page: "Tests/Write",
      find: "session-personal-2",
      replacement: "created-personal",
    });
    assert.equal(permissionPrompts.length, promptCount + 2);
  });

  test("fails closed without UI, on denial, and when the selector throws", async () => {
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

    permissionChoices.push("Deny");
    await assert.rejects(
      () => execute("silverbullet_update", { action: "delete", page: "Tests/Write" }),
      /cancelled by user/,
    );

    const blockedCount = blockedEvents.length;
    await assert.rejects(
      () =>
        execute(
          "silverbullet_update",
          { action: "delete", page: "Tests/Write" },
          { hasUI: true, ui: { select: async () => { throw new Error("selector failed"); } } },
        ),
      /selector failed/,
    );
    assert.deepEqual(blockedEvents.slice(blockedCount), [
      { active: true, label: "Approve SilverBullet update" },
      { active: false },
    ]);
    assert.equal(files.personal.get("Tests/Write.md")?.content, before);
  });

  test("deletes only after confirmation and never exposes the bearer token", async () => {
    const result = await execute("silverbullet_update", { space: "ksp", action: "delete", page: "Tests/Write" });
    assert.equal(files.ksp.has("Tests/Write.md"), false);
    assert.equal(files.personal.has("Tests/Write.md"), true);
    assert.equal(JSON.stringify({ result, permissionPrompts }).includes(token), false);

    await assert.rejects(
      () => execute("silverbullet_read", { page: "Reflect" }),
      (error: Error) => error.message.includes("[REDACTED]") && !error.message.includes(token),
    );
  });
});
