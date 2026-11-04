import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { createServer } from "node:net";
import { join, resolve } from "node:path";
import { spawn, type ChildProcess } from "node:child_process";
import { chromium, expect, type Page } from "@playwright/test";

const plug = resolve("dist/silverbullet-space-move.plug.js");
assert.ok(existsSync(plug), "Build the collection mover plug before the browser test.");
assert.ok(process.env.SB_TEST_SERVER && process.env.SB_TEST_CHROMIUM);
process.umask(0o077);
const root = mkdtempSync(join(process.env.TMPDIR!, "space-move-browser-"));
const reservation = createServer();
await new Promise<void>((done) => reservation.listen(0, "127.0.0.1", done));
const address = reservation.address();
assert.ok(address && typeof address === "object");
const port = address.port;
await new Promise<void>((done) => reservation.close(() => done()));
const origin = `http://127.0.0.1:${port}`;
let server: ChildProcess;
const start = async () => {
  server = spawn(
    process.env.SB_TEST_SERVER!,
    ["-L", "127.0.0.1", "-p", String(port), root],
    { stdio: "ignore" },
  );
  for (let attempt = 0; attempt < 200; attempt++) {
    assert.equal(server.exitCode, null, "Fixture server exited early.");
    try {
      await fetch(origin);
      return;
    } catch {
      await new Promise((done) => setTimeout(done, 50));
    }
  }
  throw new Error("Fixture server startup timed out.");
};
const stop = async () => {
  if (server?.exitCode === null) {
    server.kill("SIGTERM");
    await new Promise<void>((done) => server.once("exit", () => done()));
  }
};
const username = "fixture-admin";
const password = randomUUID();
const personalId = randomUUID();
const kspId = randomUUID();
const folders = {
  personal: join(root, "spaces", personalId),
  ksp: join(root, "spaces", kspId),
};
const putFixture = (
  space: "personal" | "ksp",
  path: string,
  text: string | Uint8Array,
) => {
  const full = join(folders[space], path);
  mkdirSync(join(full, ".."), { recursive: true });
  writeFileSync(full, text);
};
const binary = new Uint8Array([37, 80, 68, 70, 0, 255, 10, 13, 129]);
let browser: Awaited<ReturnType<typeof chromium.launch>> | undefined;
const openMover = async (page: Page, prefix: string, note: string) => {
  await page.goto(`${origin}${prefix}/${note}?headless=1`);
  await expect(page.locator("#sb-editor .cm-content")).toBeVisible({ timeout: 30000 });
  // The server first renders a non-editable SSR shell with the same class.
  await expect(page.locator("#sb-editor .cm-content")).toHaveAttribute(
    "contenteditable",
    "true",
    { timeout: 60000 },
  );
  await page.waitForFunction(
    () =>
      (globalThis as unknown as { sbRuntime?: { ready: boolean } }).sbRuntime?.ready ===
      true,
    undefined,
    { timeout: 30000 },
  );
  await page.locator("#sb-editor .cm-content").focus();
  await expect(page.locator("#sb-editor .cm-content")).toBeFocused();
  await page.keyboard.press("Control+/");
  const command = page.locator("input.sb-nav-input[placeholder=Command]");
  await expect(command).toBeVisible();
  await command.fill("Space: Move linked collection…");
  await expect(page.locator(".sb-nav-row .sb-nav-primary").first()).toHaveText(
    "Space: Move linked collection…",
    { timeout: 30000 },
  );
  await page.keyboard.press("Enter");
  const frame = page.frameLocator('iframe[data-slot="modal"]');
  await expect(frame.locator("#move-selection")).toBeVisible({ timeout: 60000 });
  await expect(
    frame
      .locator(`tr[data-path="${note}.md"]`)
      .or(frame.locator("#move-status.error"))
      .first(),
  ).toBeVisible({ timeout: 60000 });
  if (await frame.locator("#move-status.error").count())
    throw new Error(
      (await frame.locator("#move-status").textContent()) ?? "Discovery failed",
    );
  await expect(frame.locator(`tr[data-path="${note}.md"]`)).toBeVisible({
    timeout: 60000,
  });
  return frame;
};
const execute = async (frame: ReturnType<Page["frameLocator"]>) => {
  await frame.locator("#move-review").click();
  await expect(frame.locator("#move-review-panel")).toBeVisible();
  await frame.locator("#move-acknowledge").check();
  await frame.locator("#move-execute").click();
  await expect(frame.locator("#move-result-title")).toHaveText("Move complete", {
    timeout: 60000,
  });
};
try {
  await start();
  const setup = await fetch(`${origin}/.setup/api/complete`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ adminUsername: username, adminPassword: password }),
  });
  assert.equal(setup.status, 200, "Isolated account setup failed.");
  await stop();
  const config: Record<string, unknown> = {};
  for (const [id, name, prefix] of [
    [personalId, "personal", "/"],
    [kspId, "ksp", "/ksp"],
  ]) {
    config[id] = {
      name,
      folder: `spaces/${id}`,
      binding: { prefix },
      access: "none",
      members: { [username]: { role: "write" } },
    };
  }
  writeFileSync(join(root, "spaces.json"), JSON.stringify(config));
  for (const space of ["personal", "ksp"] as const) {
    putFixture(space, "_plug/silverbullet-space-move.plug.js", readFileSync(plug));
    putFixture(space, "index.md", "Fixture index\n");
  }
  putFixture(
    "personal",
    "Root.md",
    "# Root\n[[Child#Heading|Child label]]\n[[Keep]]\n[PDF](/assets/proof.pdf)\n",
  );
  putFixture(
    "personal",
    "Child.md",
    "# Heading\nChild content\n[PDF](/assets/proof.pdf)\n`[[Keep]]`\n",
  );
  putFixture("personal", "Keep.md", "Keep this personal content exactly.\n");
  putFixture("personal", "Retained.md", "Keep this page; update [[Root|work]].\n");
  putFixture("personal", "ReturnRef.md", `[Child](${origin}/ksp/Child#Heading)\n`);
  putFixture("personal", "assets/proof.pdf", binary);
  putFixture(
    "ksp",
    "Root.md",
    "# Existing destination\nRetain existing destination content.\n",
  );
  await start();
  for (const prefix of ["", "/ksp"]) {
    const denied = await fetch(`${origin}${prefix}/.fs`, {
      headers: { "X-Sync-Mode": "true" },
      redirect: "manual",
    });
    assert.ok(
      [401, 403].includes(denied.status),
      "Fixture unexpectedly allowed anonymous note access.",
    );
  }
  browser = await chromium.launch({
    executablePath: process.env.SB_TEST_CHROMIUM,
    headless: true,
    args: ["--no-sandbox", "--disable-dev-shm-usage"],
  });
  const context = await browser.newContext();
  const login = await context.request.post(`${origin}/.dashboard/api/login`, {
    data: { username, password },
  });
  assert.equal(login.status(), 200, "Isolated browser-session login failed.");
  const page = await context.newPage();
  page.on("pageerror", (error) =>
    console.error("Isolated fixture JavaScript error:", error.message),
  );

  const authorizationHeaders: boolean[] = [];
  page.on("request", (request) => {
    if (request.url().includes("/.fs"))
      authorizationHeaders.push("authorization" in request.headers());
  });
  const first = await openMover(page, "", "Root").catch(async (error) => {
    console.error("Isolated browser failure:", error);
    if (!page.isClosed())
      console.error(
        "Isolated mover status:",
        await page
          .frameLocator('iframe[data-slot="modal"]')
          .locator("#move-status")
          .textContent({ timeout: 1000 })
          .catch(() => "Panel unavailable"),
      );
    throw error;
  });
  await first.locator('tr[data-path="Keep.md"] input[type=checkbox]').uncheck();
  await execute(first);
  assert.equal(existsSync(join(folders.personal, "Root.md")), false);
  assert.equal(existsSync(join(folders.personal, "Child.md")), false);
  assert.deepEqual(
    new Uint8Array(readFileSync(join(folders.ksp, "assets/proof.pdf"))),
    binary,
  );
  const rootText = readFileSync(join(folders.ksp, "Root.md"), "utf8");
  assert.ok(rootText.includes("Retain existing destination content."));
  assert.ok(rootText.includes("# Root"));
  assert.ok(rootText.includes(`${origin}/Keep`));
  assert.ok(
    readFileSync(join(folders.personal, "Retained.md"), "utf8").includes(
      `${origin}/ksp/Root`,
    ),
  );
  assert.equal(
    readFileSync(join(folders.personal, "Keep.md"), "utf8"),
    "Keep this personal content exactly.\n",
  );
  const match = (await first.locator("#move-result").innerText()).match(
    /Operation: ([A-Za-z0-9_-]+)/,
  );
  assert.ok(match, "The completion report omitted its recovery operation ID.");
  const operationId = match[1];
  const resume = await openMover(page, "", "index");
  await resume
    .getByRole("button", {
      name: `personal: ${operationId} — Review / resume`,
      exact: true,
    })
    .click();
  await expect(
    resume.locator("#move-review-panel:visible, #move-status.error"),
  ).toBeVisible({ timeout: 60000 });
  if (await resume.locator("#move-status.error").count())
    throw new Error(
      (await resume.locator("#move-status").textContent()) ?? "Resume failed",
    );
  await resume.locator("#move-acknowledge").check();
  await resume.locator("#move-execute").click();
  await expect(resume.locator("#move-result-title")).toHaveText("Move complete", {
    timeout: 60000,
  });
  assert.equal(
    readFileSync(join(folders.ksp, "Root.md"), "utf8"),
    rootText,
    "Restart recovery replayed or re-merged the note.",
  );
  const reverse = await openMover(page, "/ksp", "Child");
  await execute(reverse);
  assert.equal(existsSync(join(folders.ksp, "Child.md")), false);
  assert.ok(
    readFileSync(join(folders.personal, "Child.md"), "utf8").includes("Child content"),
  );
  assert.equal(
    readFileSync(join(folders.personal, "ReturnRef.md"), "utf8").includes("/ksp/Child"),
    false,
  );
  assert.ok(authorizationHeaders.length > 0);
  assert.equal(
    authorizationHeaders.some(Boolean),
    false,
    "A browser request carried a service credential.",
  );
  assert.ok((await context.cookies(origin)).some((cookie) => cookie.httpOnly));
  console.log(
    "PASS: authenticated native plug, reviewed selection, automatic merge, exact binary transfer, link repair, restart recovery, and reverse move.",
  );
} finally {
  await browser?.close();
  await stop();
  rmSync(root, { recursive: true, force: true });
}
