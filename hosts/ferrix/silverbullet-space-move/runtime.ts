import { syscall } from "@silverbulletmd/silverbullet/syscall";
import { discoverCollection, isManagedPath, type Candidate } from "./core.ts";
import {
  inspectSpaces,
  planMove,
  restoreMovePlan,
  type Inspection,
  type ReviewedPlan,
} from "./controller.ts";
import { executeMove, type MoveManifest } from "./engine.ts";
import { HttpTransport } from "./transport.ts";
import {
  DEFAULT_CONFIG,
  type FileSnapshot,
  type ParseNode,
  type SpaceId,
} from "./types.ts";

interface Boot {
  path: string;
  text: string;
}
interface Operation {
  version: 1;
  root: string;
  manifest: MoveManifest;
  status?: string;
}
const boot = (globalThis as unknown as { spaceMoveBoot: Boot }).spaceMoveBoot;
const parentUrl = new URL(globalThis.parent.location.href);
const origin = parentUrl.origin;
const config = structuredClone(DEFAULT_CONFIG);
const sourceId: SpaceId =
  parentUrl.pathname === "/ksp" || parentUrl.pathname.startsWith("/ksp/")
    ? "ksp"
    : "personal";
const transport = new HttpTransport({
  origin,
  spaces: config.spaces,
  maxBytes: config.maxBytes,
});
const parser = (text: string) =>
  syscall("markdown.parseMarkdown", text) as Promise<ParseNode>;
const byId = <T extends HTMLElement = HTMLElement>(id: string) =>
  document.getElementById(id)! as T;
const status = (message: string, error = false) => {
  byId("move-status").textContent = message;
  byId("move-status").className = error ? "error" : "";
};
const show = (id: string, visible: boolean) => {
  byId(id).hidden = !visible;
};
const button = (label: string, action: () => void | Promise<void>) => {
  const result = document.createElement("button");
  result.type = "button";
  result.textContent = label;
  result.addEventListener("click", () => {
    void Promise.resolve(action()).catch(report);
  });
  return result;
};
const report = (error: unknown) =>
  status(error instanceof Error ? error.message : String(error), true);
let scan: Inspection | undefined;
let candidates: Candidate[] = [];
const selection = new Map<string, boolean>();
const expanded = new Set<string>();
let reviewed: ReviewedPlan | undefined;
let operation: Operation | undefined;
let operationFile: FileSnapshot | null = null;
let working = false;
let transferring = false;
let abort: AbortController | undefined;

function section(name: "selection" | "review" | "progress" | "result") {
  for (const [key, id] of [
    ["selection", "move-selection"],
    ["review", "move-review-panel"],
    ["progress", "move-progress-panel"],
    ["result", "move-result-panel"],
  ])
    show(id, key === name);
}
function graph() {
  if (!scan) return;
  const files = [...scan.snapshots.get(scan.source.id)!.values()].map((file) => ({
    ...file,
    links: file.links
      ?.filter((link) => !link.targetSpace || link.targetSpace === scan!.source.id)
      .map((link) =>
        link.kind === "embed" ? { ...link, kind: "page" as const } : link,
      ),
  }));
  const found = new Map<string, Candidate>();
  const warnings = new Set(scan.warnings);
  const incoming = new Set<string>();
  for (const root of [boot.path, ...expanded]) {
    const result = discoverCollection(root, files, {
      maxDepth: Number(byId<HTMLSelectElement>("move-depth").value),
      maxFiles: config.maxFiles,
      sharedThreshold: config.sharedThreshold,
    });
    result.candidates.forEach((candidate) => {
      if (!found.has(candidate.path)) found.set(candidate.path, candidate);
    });
    result.backlinks.forEach((path) => incoming.add(path));
    result.warnings.forEach((warning) => warnings.add(warning));
  }
  for (const path of incoming)
    if (!found.has(path)) {
      const file = scan.snapshots.get(scan.source.id)!.get(path)!;
      found.set(path, {
        path,
        kind: path.endsWith(".md") ? "page" : "document",
        reasons: ["Incoming reference; retained unless explicitly selected"],
        shared: true,
        selected: false,
        depth: 0,
        warnings: file.readOnly ? ["Readonly"] : [],
      });
    }
  candidates = [...found.values()];
  for (const candidate of candidates) {
    const file = scan.snapshots.get(scan.source.id)!.get(candidate.path)!;
    const blocked =
      !isManagedPath(candidate.path) ||
      /^Journal\/\d{4}-\d{2}-\d{2}\.md$/i.test(candidate.path) ||
      file.readOnly ||
      file.size > config.maxBytes;
    if (blocked) {
      selection.set(candidate.path, false);
      candidate.warnings.push(
        "Not movable: managed/daily-journal, readonly, or oversized file",
      );
    } else if (!selection.has(candidate.path))
      selection.set(candidate.path, candidate.selected);
  }
  byId("move-warnings").textContent = [...warnings].join("\n");
  show("move-warnings", warnings.size > 0);
  renderRows();
}
function visibleCandidates() {
  const phrase = byId<HTMLInputElement>("move-search").value.toLowerCase();
  const kind = byId<HTMLSelectElement>("move-kind").value;
  return candidates.filter(
    (candidate) =>
      candidate.path.toLowerCase().includes(phrase) &&
      (kind === "all" || candidate.kind === kind),
  );
}
function preview(title: string, content: string) {
  byId("move-preview-title").textContent = title;
  byId("move-preview-content").textContent = content;
  show("move-preview", true);
  byId<HTMLDetailsElement>("move-preview").open = true;
}
function renderRows() {
  const rows = byId("move-candidates");
  rows.replaceChildren();
  if (!scan) return;
  for (const candidate of visibleCandidates()) {
    const source = scan.snapshots.get(scan.source.id)!.get(candidate.path)!;
    const destination = scan.snapshots.get(scan.destination.id)!.get(candidate.path);
    const exists = scan.inventory.get(scan.destination.id)!.has(candidate.path);
    const row = document.createElement("tr");
    row.dataset.path = candidate.path;
    const choose = document.createElement("td");
    const checkbox = document.createElement("input");
    checkbox.type = "checkbox";
    checkbox.setAttribute("aria-label", `Move ${candidate.path}`);
    checkbox.checked = selection.get(candidate.path) ?? false;
    checkbox.disabled = candidate.warnings.some((warning) =>
      warning.startsWith("Not movable:"),
    );
    checkbox.addEventListener("change", () => {
      selection.set(candidate.path, checkbox.checked);
      reviewed = undefined;
      renderRows();
    });
    choose.append(checkbox);
    const path = document.createElement("td");
    path.textContent = candidate.path;
    const reason = document.createElement("small");
    reason.textContent = [...candidate.reasons, ...candidate.warnings].join(" · ");
    path.append(reason);
    const size = document.createElement("td");
    size.textContent = `${candidate.kind} · ${source.size.toLocaleString()} bytes`;
    const references = [...scan.snapshots.get(scan.source.id)!.values()].filter(
      (file) => file.links?.some((link) => link.target === candidate.path),
    ).length;
    const refs = document.createElement("small");
    refs.textContent = `${references} incoming pages`;
    size.append(refs);
    const state = document.createElement("td");
    state.textContent = !exists
      ? "New"
      : source.text !== undefined && destination?.text === source.text
        ? "Identical text"
        : candidate.kind === "page"
          ? "Automatic merge — review required"
          : "Exists — bytes must match";
    const inspect = document.createElement("td");
    inspect.append(
      button("Preview", () =>
        preview(
          candidate.path,
          source.text ??
            `Binary document: ${source.size.toLocaleString()} bytes; content is not rendered.`,
        ),
      ),
    );
    row.append(choose, path, size, state, inspect);
    rows.append(row);
  }
  const selected = candidates.filter((candidate) => selection.get(candidate.path));
  byId("move-selection-count").textContent =
    `${selected.length} selected; ${candidates.length} candidates. Complete inventory scan: ${scan.coverage.pages} pages, ${scan.coverage.bytes.toLocaleString()} bytes. Graph traversal remains bounded by the displayed depth.`;
  byId<HTMLButtonElement>("move-review").disabled = !selected.length || working;
}
async function refresh() {
  if (working) return;
  working = true;
  reviewed = undefined;
  operation = undefined;
  operationFile = null;
  section("selection");
  byId<HTMLButtonElement>("move-review").disabled = true;
  try {
    config.maxFiles = Number(byId<HTMLSelectElement>("move-limit").value);
    scan = await inspectSpaces(transport, config, sourceId, parser, {
      root: boot.path,
      expectedText: boot.text,
      origin,
      onProgress: (done, total) =>
        status(`Reading authorized note content: ${done}/${total}. No files changed.`),
    });
    byId("move-direction").textContent =
      `${scan.source.label} → ${scan.destination.label} · ${boot.path}`;
    graph();
    await listOperations();
    status(
      "Discovery ready. Inspect the selection, then review exact changes. No files changed.",
    );
  } catch (error) {
    scan = undefined;
    candidates = [];
    report(error);
  } finally {
    working = false;
    renderRows();
  }
}
function renderReview() {
  if (!reviewed) return;
  section("review");
  const list = byId("move-review-list");
  list.replaceChildren();
  for (const item of reviewed.previews) {
    const details = document.createElement("details");
    const summary = document.createElement("summary");
    summary.textContent = `${item.kind}: ${item.space}:${item.path} (${item.size.toLocaleString()} bytes)`;
    const content = document.createElement("pre");
    content.textContent =
      item.after === undefined
        ? "Binary content will be copied and verified byte-for-byte."
        : `BEFORE\n${item.before ?? "(new file)"}\n\nAFTER\n${item.after}`;
    details.append(summary, content);
    list.append(details);
  }
  byId("move-review-warnings").textContent = reviewed.warnings.join("\n");
  show("move-review-warnings", reviewed.warnings.length > 0);
  byId<HTMLInputElement>("move-acknowledge").checked = false;
  byId<HTMLButtonElement>("move-execute").disabled = true;
  status(
    `Review ${reviewed.plan.items.length} file moves and ${reviewed.plan.patches.length} link-only page edits. No transfer has started.`,
  );
}
async function review() {
  if (working || !scan) return;
  working = true;
  try {
    reviewed = await planMove(
      transport,
      scan,
      new Set(
        candidates
          .filter((candidate) => selection.get(candidate.path))
          .map((candidate) => candidate.path),
      ),
      { origin },
    );
    operation = undefined;
    operationFile = null;
    renderReview();
  } catch (error) {
    report(error);
  } finally {
    working = false;
    renderRows();
  }
}
function validOperation(value: unknown, id: string): Operation {
  const record = value as Operation;
  if (
    !record ||
    record.version !== 1 ||
    typeof record.root !== "string" ||
    !record.manifest ||
    record.manifest.id !== id ||
    !["personal", "ksp"].includes(record.manifest.sourceSpace) ||
    !["personal", "ksp"].includes(record.manifest.destinationSpace)
  )
    throw new Error("Invalid saved operation.");
  return record;
}
async function loadOperation(space: SpaceId, id: string) {
  if (working || !/^[A-Za-z0-9_-]{1,100}$/.test(id)) return;
  working = true;
  try {
    const file = await transport.read(space, `Space Moves/Operations/${id}.json`);
    if (!file || file.size > 10485760)
      throw new Error("Operation record missing or too large.");
    const record = validOperation(JSON.parse(new TextDecoder().decode(file.bytes)), id);
    if (record.manifest.sourceSpace !== space)
      throw new Error("Operation record is in the wrong source space.");
    reviewed = await restoreMovePlan(
      transport,
      config,
      record.manifest,
      parser,
      origin,
    );
    operation = record;
    operationFile = file;
    renderReview();
    status(
      "Recovered the approved plan from verified originals and output digests. Review again before resuming.",
    );
  } catch (error) {
    report(error);
  } finally {
    working = false;
  }
}
async function listOperations() {
  if (!scan) return;
  const list = byId("move-operation-list");
  list.replaceChildren();
  const entries = [...scan.inventory].flatMap(([space, files]) =>
    [...files.keys()]
      .filter((path) =>
        /^Space Moves\/Operations\/[A-Za-z0-9_-]{1,100}\.json$/.test(path),
      )
      .map((path) => ({ space, path })),
  );
  const note = document.createElement("p");
  note.className = "muted";
  note.textContent = `Showing up to 100 stored operations (${entries.length} records available). Enter an exact operation ID to open one not listed.`;
  list.append(note);
  const exact = document.createElement("input");
  exact.type = "text";
  exact.placeholder = "Exact operation ID";
  exact.setAttribute("aria-label", "Exact operation ID");
  const space = document.createElement("select");
  for (const candidate of config.spaces) {
    const option = document.createElement("option");
    option.value = candidate.id;
    option.textContent = candidate.label;
    space.append(option);
  }
  list.append(
    exact,
    space,
    button("Open operation", () => loadOperation(space.value as SpaceId, exact.value)),
  );
  for (const entry of entries.slice(0, 100)) {
    const id = entry.path.slice("Space Moves/Operations/".length, -5);
    const row = document.createElement("p");
    row.append(
      button(`${entry.space}: ${id} — Review / resume`, () =>
        loadOperation(entry.space, id),
      ),
    );
    list.append(row);
  }
  show("move-pending", true);
}
async function execute() {
  if (working || !reviewed || !byId<HTMLInputElement>("move-acknowledge").checked)
    return;
  working = true;
  transferring = true;
  abort = new AbortController();
  section("progress");
  const plan = reviewed.plan;
  const record: Operation = operation ?? {
    version: 1,
    root: boot.path,
    manifest: undefined as unknown as MoveManifest,
  };
  const recordPath = `Space Moves/Operations/${plan.id}.json`;
  const save = async (manifest: MoveManifest) => {
    record.manifest = manifest;
    const bytes = new TextEncoder().encode(JSON.stringify(record, null, 2) + "\n");
    operationFile = await transport.write(
      plan.sourceSpace,
      recordPath,
      bytes,
      operationFile ? { revision: operationFile.revision } : { create: true },
    );
  };
  try {
    const run = () =>
      executeMove(transport, plan, {
        manifest: operation?.manifest,
        signal: abort!.signal,
        saveManifest: save,
        onProgress: ({ phase, manifest }) => {
          status(`Operation ${plan.id}: ${phase}.`);
          byId("move-progress").textContent = manifest.items
            .map(
              (item) =>
                `${item.sourcePath}: recovery ${item.archiveVerified ? "verified" : "pending"}; destination ${item.destinationVerified ? "verified" : "pending"}; source ${item.sourceRemoved ? "removed" : "retained"}`,
            )
            .join("\n");
        },
      });
    const result = navigator.locks
      ? await navigator.locks.request(
          "silverbullet-space-move",
          { ifAvailable: true },
          (lock) => {
            if (!lock)
              throw new Error(
                "Another collection move is active in this browser. Finish or resume it first.",
              );
            return run();
          },
        )
      : await run();
    record.status = result.status;
    try {
      await save(result.manifest);
    } catch {
      result.status = "partial";
      result.errors.push({
        phase: "manifest",
        message:
          "Final operation record could not be verified. Resume by operation ID; do not repeat the move.",
      });
    }
    operation = record;
    section("result");
    byId("move-result-title").textContent =
      result.status === "complete"
        ? "Move complete"
        : result.status === "cancelled"
          ? "Stopped — recovery retained"
          : "Partially complete — originals or recovery copies retained";
    byId("move-result").textContent =
      `Operation: ${plan.id}\nVerified destinations: ${result.counts.destinations}/${plan.items.length}\nVerified link edits: ${result.counts.patches}/${plan.patches.length}\nRemoved sources: ${result.counts.removed}/${plan.items.length}\nVerified activity journals: ${result.counts.journals}\n` +
      result.errors.map((error) => `${error.phase}: ${error.message}`).join("\n");
    const links = byId("move-result-links");
    links.replaceChildren();
    const destination = config.spaces.find(
      (space) => space.id === plan.destinationSpace,
    )!;
    const anchor = document.createElement("a");
    anchor.textContent = `Open ${destination.label}`;
    anchor.href =
      origin +
      destination.prefix +
      "/" +
      record.root.replace(/\.md$/, "").split("/").map(encodeURIComponent).join("/");
    anchor.target = "_top";
    links.append(anchor);
    links.append(
      button("Review / resume this operation", () =>
        loadOperation(plan.sourceSpace, plan.id),
      ),
    );
    status(
      result.status === "complete"
        ? "All selected files, approved link edits, recovery copies and activity entries verified."
        : "Do not start a new move for these files. Resume this operation to inspect actual state.",
    );
  } catch (error) {
    section("review");
    report(error);
  } finally {
    working = false;
    transferring = false;
    byId<HTMLButtonElement>("move-cancel").disabled = false;
  }
}

byId("move-refresh").addEventListener("click", () => {
  void refresh();
});
byId("move-expand").addEventListener("click", () => {
  candidates
    .filter((candidate) => selection.get(candidate.path) && candidate.kind === "page")
    .forEach((candidate) => expanded.add(candidate.path));
  graph();
});
byId("move-search").addEventListener("input", renderRows);
byId("move-kind").addEventListener("change", renderRows);
for (const [id, value] of [
  ["move-select-all", true],
  ["move-select-none", false],
] as const)
  byId(id).addEventListener("click", () => {
    visibleCandidates()
      .filter(
        (candidate) =>
          !candidate.warnings.some((warning) => warning.startsWith("Not movable:")),
      )
      .forEach((candidate) => selection.set(candidate.path, value));
    reviewed = undefined;
    renderRows();
  });
byId("move-review").addEventListener("click", () => {
  void review();
});
byId("move-back").addEventListener("click", () => {
  reviewed = undefined;
  operation = undefined;
  operationFile = null;
  section("selection");
});
byId("move-acknowledge").addEventListener("change", () => {
  byId<HTMLButtonElement>("move-execute").disabled =
    !byId<HTMLInputElement>("move-acknowledge").checked;
});
byId("move-execute").addEventListener("click", () => {
  void execute();
});
byId("move-cancel").addEventListener("click", () => {
  abort?.abort();
  byId<HTMLButtonElement>("move-cancel").disabled = true;
  status("Stopping after the current request. Verified recovery data will remain.");
});
byId("move-close").addEventListener("click", () => {
  if (transferring) {
    abort?.abort();
    status("Stopping safely. Wait for the result before closing.");
  } else void syscall("editor.hidePanel", "modal");
});
globalThis.addEventListener("beforeunload", (event) => {
  if (transferring) {
    event.preventDefault();
    event.returnValue = "";
  }
});
void refresh().catch(report);
