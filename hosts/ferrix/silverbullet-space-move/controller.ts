import { isManagedPath, mergeMarkdown, rewriteLinks } from "./core.ts";
import { parseLinks } from "./parser.ts";
import {
  stripJournalEntryCandidates,
  type MoveManifest,
  type MovePlan,
  type PatchState,
} from "./engine.ts";
import type {
  FileMeta,
  FileSnapshot,
  MoveConfig,
  ParseNode,
  SpaceConfig,
  SpaceId,
  Transport,
} from "./types.ts";

export type MarkdownParser = (text: string) => Promise<ParseNode>;
export interface Inspection {
  config: MoveConfig;
  source: SpaceConfig;
  destination: SpaceConfig;
  inventory: Map<SpaceId, Map<string, FileMeta>>;
  snapshots: Map<SpaceId, Map<string, FileSnapshot>>;
  parser: MarkdownParser;
  warnings: string[];
  coverage: { pages: number; bytes: number };
}
export interface Preview {
  space: SpaceId;
  path: string;
  kind: "move" | "merge" | "link edit";
  before?: string;
  after?: string;
  size: number;
}
export interface ReviewedPlan {
  plan: MovePlan;
  previews: Preview[];
  warnings: string[];
}
const encode = (text: string) => new TextEncoder().encode(text);
const bytesEqual = (a: Uint8Array, b: Uint8Array) =>
  a.length === b.length && a.every((byte, index) => byte === b[index]);
const bomPrefix = (file: FileSnapshot) =>
  file.bytes[0] === 0xef &&
  file.bytes[1] === 0xbb &&
  file.bytes[2] === 0xbf &&
  !file.text?.startsWith("\uFEFF")
    ? "\uFEFF"
    : "";

export async function hashBytes(bytes: Uint8Array): Promise<string> {
  const hash = await crypto.subtle.digest("SHA-256", new Uint8Array(bytes));
  return [...new Uint8Array(hash)]
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}

async function approvedPatchSnapshot(
  file: FileSnapshot,
  patch: PatchState,
  id: string,
): Promise<FileSnapshot> {
  for (const bytes of stripJournalEntryCandidates(file.bytes, id)) {
    const hash = await hashBytes(bytes);
    if (hash === patch.beforeDigest || hash === patch.outputDigest) {
      return {
        ...file,
        bytes,
        size: bytes.length,
        text: new TextDecoder("utf-8", { fatal: true }).decode(bytes),
      };
    }
  }
  throw new Error(
    `Retained page changed since review: ${patch.space}:${patch.path}. Resume stopped.`,
  );
}

async function parsed(
  scan: Inspection,
  file: FileSnapshot,
  origin: string,
): Promise<FileSnapshot> {
  if (file.text === undefined) return file;
  const result = parseLinks(
    file.path,
    file.text,
    await scan.parser(file.text),
    scan.inventory.get(file.space)!.keys(),
    {
      origin,
      currentSpace: file.space,
      spaces: scan.config.spaces,
      paths: new Map(
        [...scan.inventory].map(([space, files]) => [space, files.keys()]),
      ),
    },
  );
  scan.warnings.push(...result.warnings);
  return { ...file, links: result.links };
}

export async function inspectSpaces(
  transport: Transport,
  config: MoveConfig,
  sourceSpace: SpaceId,
  parser: MarkdownParser,
  options: {
    root?: string;
    expectedText?: string;
    origin?: string;
    onProgress?: (done: number, total: number) => void;
  } = {},
): Promise<Inspection> {
  const source = config.spaces.find((space) => space.id === sourceSpace);
  const destination = config.spaces.find((space) => space.id !== sourceSpace);
  if (!source || !destination) throw new Error("Both configured spaces are required.");
  const scan: Inspection = {
    config,
    source,
    destination,
    parser,
    warnings: [],
    coverage: { pages: 0, bytes: 0 },
    inventory: new Map(),
    snapshots: new Map(),
  };
  for (const space of config.spaces) {
    scan.inventory.set(
      space.id,
      new Map((await transport.list(space.id)).map((file) => [file.path, file])),
    );
    scan.snapshots.set(space.id, new Map());
  }
  const pages = [...scan.inventory].flatMap(([space, files]) =>
    [...files.values()]
      .filter(
        (file) =>
          file.path.endsWith(".md") &&
          !/^(?:Trash|Space Moves)(?:\/|$)/i.test(file.path) &&
          !file.path.split("/").some((part) => part.startsWith(".")),
      )
      .map((file) => ({ space, file })),
  );
  if (pages.length > config.maxFiles)
    throw new Error(
      `Discovery requires reading ${pages.length} pages; the visible scan limit is ${config.maxFiles}. Raise the scan limit and refresh; no files changed.`,
    );
  let next = 0;
  let failed = false;
  await Promise.all(
    Array.from({ length: Math.min(4, pages.length) }, async () => {
      while (!failed && next < pages.length) {
        const { space, file } = pages[next++];
        try {
          const snapshot = await transport.read(space, file.path);
          if (!snapshot)
            throw new Error(
              `Inventory changed during discovery: ${file.path}. Refresh.`,
            );
          scan.coverage.bytes += snapshot.bytes.length;
          if (scan.coverage.bytes > 134217728)
            throw new Error(
              "Discovery exceeds the 128 MiB total note limit. Narrow the spaces before moving.",
            );
          scan.snapshots.get(space)!.set(file.path, snapshot);
          scan.coverage.pages++;
          options.onProgress?.(scan.coverage.pages, pages.length);
        } catch (error) {
          failed = true;
          throw error;
        }
      }
    }),
  );
  if (options.root) {
    const root = scan.snapshots.get(sourceSpace)!.get(options.root);
    if (!root)
      throw new Error("The current page is missing or managed; no files changed.");
    if (options.expectedText !== undefined && root.text !== options.expectedText)
      throw new Error(
        "The editor and saved server page differ. Finish synchronization and reopen the mover.",
      );
  }
  for (const [space, snapshots] of scan.snapshots) {
    for (const [path, snapshot] of snapshots)
      snapshots.set(
        path,
        await parsed(scan, snapshot, options.origin ?? "https://invalid.example"),
      );
    // Document metadata participates in graph discovery without loading binary bodies.
    for (const [path, meta] of scan.inventory.get(space)!) {
      if (!snapshots.has(path) && !path.endsWith(".md") && isManagedPath(path)) {
        snapshots.set(path, {
          ...meta,
          space,
          bytes: new Uint8Array(),
          revision: "inventory",
          links: [],
        });
      }
    }
  }
  return scan;
}

export async function planMove(
  transport: Transport,
  scan: Inspection,
  selected: ReadonlySet<string>,
  options: {
    origin: string;
    id?: string;
    createdAt?: string;
    manifest?: MoveManifest;
  },
): Promise<ReviewedPlan> {
  if (!selected.size) throw new Error("Select at least one file to move.");
  const sourcePaths = new Set(scan.inventory.get(scan.source.id)!.keys());
  const destinationPaths = new Set(scan.inventory.get(scan.destination.id)!.keys());
  const plan: MovePlan = {
    id: options.id ?? options.manifest?.id ?? crypto.randomUUID(),
    createdAt:
      options.createdAt ?? options.manifest?.createdAt ?? new Date().toISOString(),
    sourceSpace: scan.source.id,
    destinationSpace: scan.destination.id,
    origin: options.origin,
    items: [],
    patches: [],
  };
  const previews: Preview[] = [];
  const warnings = [...scan.warnings];
  const rewrite = (
    snapshot: FileSnapshot,
    location: "source" | "destination",
    links = snapshot.links ?? [],
  ) => {
    const relevant = links
      .filter((link) => !link.targetSpace || link.targetSpace === scan.source.id)
      .map((link) => {
        if (
          (link.warning || link.ambiguous) &&
          (location === "destination" || selected.has(link.target))
        ) {
          throw new Error(
            `Unsupported or ambiguous reference in ${snapshot.path}: ${link.target}. Repair it before moving; source deletion is blocked.`,
          );
        }
        if (link.kind !== "embed") return link;
        if ((location === "destination") !== selected.has(link.target)) {
          throw new Error(
            `Cross-space page embed in ${snapshot.path}: ${link.target}. Select both files or leave both in place; hyperlinks do not preserve transclusion.`,
          );
        }
        return { ...link, kind: "page" as const };
      });
    const result = rewriteLinks(
      { ...snapshot, links: relevant },
      {
        selected,
        source: scan.source,
        destination: scan.destination,
        location,
        origin: options.origin,
        sourcePaths,
        destinationPaths,
        collectEdits: true,
      },
    );
    warnings.push(...result.warnings.map((warning) => `${snapshot.path}: ${warning}`));
    return result;
  };
  for (const path of [...selected].sort()) {
    if (!isManagedPath(path) || /^Journal\/\d{4}-\d{2}-\d{2}\.md$/i.test(path))
      throw new Error(
        `Whole daily journals and managed files cannot be moved automatically: ${path}`,
      );
    const snapshot = scan.snapshots.get(scan.source.id)!.get(path);
    const source =
      snapshot && snapshot.revision !== "inventory"
        ? snapshot
        : await transport.read(scan.source.id, path);
    if (!source) throw new Error(`Missing selected source: ${path}`);
    if (source.readOnly) throw new Error(`Readonly selected source: ${path}`);
    const destination = await transport.read(scan.destination.id, path);
    const state = options.manifest?.items.find((item) => item.sourcePath === path);
    if (
      state &&
      destination &&
      (await hashBytes(destination.bytes)) === state.outputDigest
    ) {
      plan.items.push({
        source,
        destination,
        output: destination.bytes,
        isBinary: state.isBinary,
      });
      previews.push({
        space: scan.destination.id,
        path,
        kind: state.destinationDigest ? "merge" : "move",
        after: destination.text,
        size: destination.size,
      });
      continue;
    }
    if (
      state &&
      (destination
        ? (await hashBytes(destination.bytes)) !== state.destinationDigest
        : !!state.destinationDigest)
    ) {
      throw new Error(
        `Destination changed since the approved operation: ${path}. Resume stopped without writes.`,
      );
    }
    let output = source.bytes;
    let kind: Preview["kind"] = "move";
    if (source.text !== undefined) {
      const rewritten = rewrite(source, "destination");
      output =
        rewritten.text === source.text
          ? source.bytes
          : encode(bomPrefix(source) + rewritten.text);
      if (destination) {
        if (destination.text === undefined)
          throw new Error(`Destination is not readable Markdown: ${path}`);
        const destinationParsed = await parsed(scan, destination, options.origin);
        const destLinks =
          destinationParsed.links?.filter(
            (link) => link.targetSpace === scan.source.id && selected.has(link.target),
          ) ?? [];
        const destText = rewrite(destinationParsed, "destination", destLinks).text;
        const merged = mergeMarkdown(
          rewritten.text,
          destText,
          `${scan.source.label}/${path}`,
        );
        if (merged.conflicts.length)
          throw new Error(
            `${path}: automatic merge blocked: ${merged.conflicts.join("; ")}. Originals remain unchanged.`,
          );
        warnings.push(...merged.warnings);
        output =
          merged.text === destination.text
            ? destination.bytes
            : encode(bomPrefix(destination) + merged.text);
        if (!bytesEqual(output, source.bytes)) kind = "merge";
      }
    } else if (destination && !bytesEqual(destination.bytes, source.bytes))
      throw new Error(`Different binary already exists at destination: ${path}`);
    if (destination?.readOnly && !bytesEqual(output, destination.bytes))
      throw new Error(`Readonly destination: ${path}`);
    plan.items.push({
      source,
      destination,
      output,
      isBinary: source.text === undefined,
    });
    previews.push({
      space: scan.destination.id,
      path,
      kind,
      before: destination?.text,
      after: path.endsWith(".md") ? new TextDecoder().decode(output) : undefined,
      size: output.length,
    });
  }
  for (const [space, snapshots] of scan.snapshots)
    for (const snapshot of snapshots.values()) {
      if (snapshot.text === undefined || selected.has(snapshot.path)) continue;
      const relevant =
        snapshot.links?.filter(
          (link) =>
            (!link.targetSpace || link.targetSpace === scan.source.id) &&
            selected.has(link.target),
        ) ?? [];
      if (!relevant.length) continue;
      if (!isManagedPath(snapshot.path))
        throw new Error(
          `An incoming reference is in managed Markdown: ${space}:${snapshot.path}. Repair it declaratively before moving its target.`,
        );
      const result = rewrite(
        snapshot,
        space === scan.source.id ? "source" : "destination",
        space === scan.source.id ? snapshot.links : relevant,
      );
      if (result.text === snapshot.text) continue;
      if (snapshot.readOnly)
        throw new Error(
          `A retained reference page is readonly: ${space}:${snapshot.path}. Originals must remain until its links can be repaired.`,
        );
      const prefix = bomPrefix(snapshot);
      let offset = prefix.length;
      const inverseEdits = [...(result.edits ?? [])]
        .sort((a, b) => a.from - b.from)
        .map((edit) => {
          const from = edit.from + offset;
          offset += edit.text.length - (edit.to - edit.from);
          return {
            from,
            to: from + edit.text.length,
            before: snapshot.text!.slice(edit.from, edit.to),
            after: edit.text,
          };
        });
      plan.patches.push({
        before: snapshot,
        output: encode(prefix + result.text),
        inverseEdits,
      });
      previews.push({
        space,
        path: snapshot.path,
        kind: "link edit",
        before: snapshot.text,
        after: result.text,
        size: encode(result.text).length,
      });
    }
  if (options.manifest) {
    const saved = options.manifest;
    plan.items = saved.items.map((item) => {
      const rebuilt = plan.items.find(
        (candidate) => candidate.source.path === item.sourcePath,
      );
      if (!rebuilt)
        throw new Error("A saved selected source could not be reconstructed.");
      return rebuilt;
    });
    const approvedPatches = new Set(
      saved.patches.map((patch) => `${patch.space}:${patch.path}`),
    );
    if (
      plan.patches.some(
        (patch) => !approvedPatches.has(`${patch.before.space}:${patch.before.path}`),
      )
    ) {
      throw new Error(
        "New incoming references appeared after approval. Resolve them before resuming; no files changed.",
      );
    }
    const rebuiltPatches = [];
    for (const patch of saved.patches) {
      if (!isManagedPath(patch.path)) throw new Error("Invalid saved patch path.");
      const actual = await transport.read(patch.space, patch.path);
      if (!actual) throw new Error(`Missing retained reference page: ${patch.path}`);
      const current = await approvedPatchSnapshot(actual, patch, saved.id);
      const hash = await hashBytes(current.bytes);
      if (hash === patch.outputDigest) {
        rebuiltPatches.push({
          before: current,
          output: current.bytes,
          inverseEdits: patch.inverseEdits,
        });
        if (
          !previews.some(
            (preview) => preview.space === patch.space && preview.path === patch.path,
          )
        ) {
          previews.push({
            space: patch.space,
            path: patch.path,
            kind: "link edit",
            before: current.text,
            after: current.text,
            size: current.size,
          });
        }
      } else {
        const generated = plan.patches.find(
          (candidate) =>
            candidate.before.space === patch.space &&
            candidate.before.path === patch.path,
        );
        if (
          hash !== patch.beforeDigest ||
          !generated ||
          (await hashBytes(generated.output)) !== patch.outputDigest
        ) {
          throw new Error(
            `Retained page changed since review: ${patch.space}:${patch.path}. Resume stopped.`,
          );
        }
        rebuiltPatches.push(generated);
      }
    }
    plan.patches = rebuiltPatches;
    for (const [index, item] of plan.items.entries()) {
      if ((await hashBytes(item.output)) !== saved.items[index].outputDigest)
        throw new Error(
          "Rebuilt output differs from the approved plan. Manual reconciliation required.",
        );
    }
  }
  return { plan, previews, warnings: [...new Set(warnings)] };
}

export async function restoreMovePlan(
  transport: Transport,
  config: MoveConfig,
  manifest: MoveManifest,
  parser: MarkdownParser,
  origin: string,
): Promise<ReviewedPlan> {
  if (manifest.origin && manifest.origin !== origin)
    throw new Error("Resume this operation from its original browser origin.");
  if (
    manifest.version !== 1 ||
    !/^[A-Za-z0-9_-]{1,100}$/.test(manifest.id) ||
    !["personal", "ksp"].includes(manifest.sourceSpace) ||
    !["personal", "ksp"].includes(manifest.destinationSpace) ||
    manifest.sourceSpace === manifest.destinationSpace ||
    !Array.isArray(manifest.items) ||
    !manifest.items.length ||
    manifest.items.length > config.maxFiles ||
    !Array.isArray(manifest.patches) ||
    manifest.patches.length > config.maxFiles
  ) {
    throw new Error("Invalid saved operation metadata.");
  }
  const scan = await inspectSpaces(transport, config, manifest.sourceSpace, parser, {
    origin,
  });
  for (const patch of manifest.patches) {
    if (
      !isManagedPath(patch.path) ||
      !config.spaces.some((space) => space.id === patch.space)
    )
      throw new Error("Invalid saved patch path or space.");
    const file = scan.snapshots.get(patch.space)!.get(patch.path);
    if (!file) throw new Error(`Missing retained reference page: ${patch.path}`);
    scan.snapshots
      .get(patch.space)!
      .set(patch.path, await approvedPatchSnapshot(file, patch, manifest.id));
  }
  const originals: FileSnapshot[] = [];
  for (const item of manifest.items) {
    if (
      !isManagedPath(item.sourcePath) ||
      item.destinationPath !== item.sourcePath ||
      !/^[a-f0-9]{64}$/.test(item.sourceDigest)
    )
      throw new Error("Invalid saved item path or digest.");
    let file = await transport.read(manifest.sourceSpace, item.sourcePath);
    if (!file || (await hashBytes(file.bytes)) !== item.sourceDigest) {
      file = await transport.read(
        manifest.sourceSpace,
        `Trash/Space Moves/${manifest.id}/${item.sourcePath}`,
      );
    }
    if (!file || (await hashBytes(file.bytes)) !== item.sourceDigest)
      throw new Error(
        `Original or verified recovery copy unavailable: ${item.sourcePath}`,
      );
    const original = { ...file, path: item.sourcePath, revision: item.sourceRevision };
    originals.push(original);
    scan.inventory.get(manifest.sourceSpace)!.set(item.sourcePath, original);
  }
  for (const original of originals)
    scan.snapshots
      .get(manifest.sourceSpace)!
      .set(original.path, await parsed(scan, original, origin));
  // Re-resolve retained short references with the original selected paths present.
  for (const [space, files] of scan.snapshots)
    for (const [path, file] of files) {
      if (file.text !== undefined) files.set(path, await parsed(scan, file, origin));
    }
  return planMove(
    transport,
    scan,
    new Set(manifest.items.map((item) => item.sourcePath)),
    { origin, manifest },
  );
}
