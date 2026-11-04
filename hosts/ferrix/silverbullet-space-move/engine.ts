import type { FileSnapshot, SpaceId, Transport } from "./types.ts";

/** UTF-16 offsets in patch.output; before/after contain one link, never a page. */
export interface InverseLinkEdit {
  from: number;
  to: number;
  before: string;
  after: string;
}
export interface MoveItem {
  source: FileSnapshot;
  destination: FileSnapshot | null;
  /** Defaults to source.path; must match destination.path when it exists. */
  destinationPath?: string;
  /** Final approved bytes, including link rewriting and any text merge. */
  output: Uint8Array;
  isBinary?: boolean;
}
export interface MovePatch {
  before: FileSnapshot;
  output: Uint8Array;
  /** Required for daily journals; edits must explain every changed byte. */
  inverseEdits?: InverseLinkEdit[];
}
export interface MovePlan {
  /** Stable operation identifier, restricted to [A-Za-z0-9_-], max 100 chars. */
  id: string;
  sourceSpace: SpaceId;
  destinationSpace: SpaceId;
  createdAt: string;
  /** Trusted browser location.origin; contains no credentials or settings. */
  origin?: string;
  items: MoveItem[];
  patches: MovePatch[];
}
export interface ItemState {
  sourcePath: string;
  destinationPath: string;
  sourceRevision: string;
  sourceDigest: string;
  outputDigest: string;
  destinationRevision?: string;
  destinationDigest?: string;
  isBinary: boolean;
  archivePath: string;
  destinationArchivePath?: string;
  archiveVerified: boolean;
  destinationVerified: boolean;
  sourceRemoved: boolean;
}
export interface PatchState {
  space: SpaceId;
  path: string;
  revision: string;
  beforeDigest: string;
  outputDigest: string;
  inverseEdits?: InverseLinkEdit[];
  verified: boolean;
}
export interface JournalState {
  space: SpaceId;
  path: string;
  verified: boolean;
}
export interface ChangeState {
  space: SpaceId;
  path: string;
  kind: "archive" | "destination" | "patch" | "remove";
  day: string;
}
export interface MoveManifest {
  // Deliberately no file bodies, HTTP settings, credentials, or raw errors.
  version: 1;
  id: string;
  sourceSpace: SpaceId;
  destinationSpace: SpaceId;
  createdAt: string;
  /** Trusted browser location.origin; contains no credentials or settings. */
  origin?: string;
  planDigest: string;
  items: ItemState[];
  patches: PatchState[];
  journals: JournalState[];
  changes: ChangeState[];
}
export interface MoveResult {
  status: "complete" | "partial" | "cancelled";
  manifest: MoveManifest;
  errors: { phase: string; message: string }[];
  counts: { destinations: number; patches: number; removed: number; journals: number };
}
export interface MoveOptions {
  signal?: AbortSignal;
  onProgress?: (event: { phase: string; manifest: MoveManifest }) => void;
  saveManifest?: (manifest: MoveManifest) => Promise<void>;
  /** Exact original plan or a hash-equivalent rebuilt plan; never authorizes a write. */
  manifest?: MoveManifest;
}
const same = (a: Uint8Array, b: Uint8Array) =>
  a.length === b.length && a.every((value, i) => value === b[i]);
async function digest(data: Uint8Array): Promise<string> {
  const hash = await crypto.subtle.digest("SHA-256", new Uint8Array(data));
  return [...new Uint8Array(hash)].map((b) => b.toString(16).padStart(2, "0")).join("");
}
const encode = (text: string) => new TextEncoder().encode(text);
const journalDay = () =>
  new Intl.DateTimeFormat("en-CA", {
    timeZone: "America/New_York",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).format(new Date());
const target = (item: MoveItem) => item.destinationPath ?? item.source.path;
function journalLink(path: string): string {
  if (/\.md$/i.test(path) && !/[\[\]|#<>]/u.test(path))
    return `[[${path.slice(0, -3)}]]`;
  const label = path.replace(/[\\\[\]<>`]/gu, "\\$&");
  const href = path
    .split("/")
    .map((part) =>
      encodeURIComponent(part).replace(
        /[!'()*]/gu,
        (c) => `%${c.charCodeAt(0).toString(16).toUpperCase()}`,
      ),
    )
    .join("/");
  return `[${label}](</${href}>)`;
}
function binary(file: FileSnapshot): boolean {
  if (
    /\.(png|jpe?g|gif|webp|avif|ico|pdf|zip|gz|mp[34]|woff2?|sqlite|bin)$/i.test(
      file.path,
    ) ||
    file.bytes.includes(0)
  )
    return true;
  try {
    new TextDecoder("utf-8", { fatal: true }).decode(file.bytes);
    return false;
  } catch {
    return true;
  }
}
const archivePath = (plan: MovePlan, path: string) =>
  `Trash/Space Moves/${plan.id}/${path}`;
async function verify(
  transport: Transport,
  space: SpaceId,
  path: string,
  expected: Uint8Array,
) {
  const file = await transport.read(space, path);
  if (!file || !same(file.bytes, expected))
    throw new Error(`Verification failed: ${space}:${path}`);
  return file;
}
async function archive(
  transport: Transport,
  space: SpaceId,
  path: string,
  data: Uint8Array,
  checkpoint: () => void,
) {
  const existing = await transport.read(space, path);
  if (existing && !same(existing.bytes, data))
    throw new Error(`Archive conflict: ${space}:${path}`);
  if (!existing) {
    checkpoint();
    await transport.write(space, path, data, { create: true });
  }
  await verify(transport, space, path, data);
}

const dailyJournal = (path: string) => /^Journal\/\d{4}-\d{2}-\d{2}\.md$/i.test(path);
/**
 * Byte-preserving candidates only: callers MUST match an approved digest/bytes.
 * An engine entry is a unique terminal block, appended with one or two LF bytes.
 * Never normalize BOM, CRLF, other entries, or text outside this operation.
 */
export function stripJournalEntryCandidates(
  bytes: Uint8Array,
  id: string,
): Uint8Array[] {
  const candidates = [bytes.slice()];
  if (!/^[a-zA-Z0-9_-]{1,100}$/.test(id)) return candidates;
  let text: string;
  try {
    text = new TextDecoder("utf-8", { fatal: true, ignoreBOM: true }).decode(bytes);
  } catch {
    return candidates;
  }
  const startMarker = `<!-- space-move:${id} -->`;
  const endMarker = `<!-- /space-move:${id} -->`;
  const start = text.indexOf(startMarker);
  const end = text.indexOf(endMarker);
  if (
    start < 0 ||
    end < start ||
    text.indexOf(startMarker, start + 1) >= 0 ||
    text.indexOf(endMarker, end + 1) >= 0 ||
    text.slice(end + endMarker.length) !== "\n"
  )
    return candidates;
  const prefix = text.slice(0, start);
  for (const separator of ["\n", "\n\n"]) {
    if (!prefix.endsWith(separator)) continue;
    const original = prefix.slice(0, -separator.length);
    const appended = original.endsWith("\n") || !original ? "\n" : "\n\n";
    if (separator === appended) candidates.push(encode(original));
  }
  return candidates;
}
function restoreLinks(patch: MovePatch): Uint8Array {
  let restored = new TextDecoder("utf-8", { fatal: true, ignoreBOM: true }).decode(
    patch.output,
  );
  let boundary = restored.length;
  if (!patch.inverseEdits?.length)
    throw new Error("Daily journal patch requires narrow inverse link edits");
  for (const edit of [...patch.inverseEdits].sort((a, b) => b.from - a.from)) {
    if (edit.to > boundary || restored.slice(edit.from, edit.to) !== edit.after)
      throw new Error("Invalid overlapping inverse link edits");
    restored = restored.slice(0, edit.from) + edit.before + restored.slice(edit.to);
    boundary = edit.from;
  }
  return encode(restored);
}
function validatePath(path: string, allowDailyPatch = false): void {
  if (
    typeof path !== "string" ||
    !path ||
    /[\\\\:%\x00-\x1f\x7f?#]/u.test(path) ||
    path
      .split("/")
      .some((part) => !part || part.startsWith(".") || part.trim() !== part) ||
    /^(Library|Repositories|Trash|_plug|_config|Space Moves)(\/|$)/i.test(path) ||
    /(^|\/)(SETTINGS|PLUGS|CONFIG)(?:\.md)?(\/|$)/i.test(path) ||
    (!allowDailyPatch && dailyJournal(path))
  )
    throw new Error("Invalid or managed path");
}
function validateOrigin(origin: string): void {
  let url: URL;
  try {
    url = new URL(origin);
  } catch {
    throw new Error("Invalid trusted origin");
  }
  if (
    url.origin !== origin ||
    url.username ||
    url.password ||
    url.search ||
    url.hash ||
    !(
      url.protocol === "https:" ||
      (url.protocol === "http:" &&
        /^(?:localhost|127\.\d+\.\d+\.\d+|\[::1\])$/i.test(url.hostname))
    )
  )
    throw new Error("Invalid trusted origin");
}
function inverseLink(value: string, origin?: string): boolean {
  if (
    typeof value !== "string" ||
    value.length > 4096 ||
    /[\r\n\x00-\x1f\x7f]/u.test(value) ||
    /(?:\b(?:data|javascript|vbscript|file|blob):|[?&](?:token|password|secret|key)=)/iu.test(
      value,
    )
  )
    return false;
  const wiki = value.match(/^!?\[\[([^\[\]]+)\]\]$/u);
  const markdown = value.match(
    /^!?\[[^\[\]]*\]\((<[^>\r\n]*>|[^\s]+?)(?:\s+(?:"[^"\r\n]*"|'[^'\r\n]*'|\([^\)\r\n]*\)))?\)$/u,
  );
  if (!wiki && !markdown) return false;
  const rawTarget = wiki ? wiki[1].split("|")[0] : markdown![1];
  if (markdown && rawTarget.startsWith("<") && !/^<[^<>]*>$/u.test(rawTarget))
    return false;
  const target = rawTarget.startsWith("<") ? rawTarget.slice(1, -1) : rawTarget;
  if (markdown && !rawTarget.startsWith("<")) {
    let depth = 0;
    for (const character of target) {
      if (character === "(") depth++;
      else if (character === ")" && --depth < 0) return false;
    }
    if (depth) return false;
  }
  // Do not hide a second credential/scheme-bearing URL in a label or title.
  if (
    /[a-z][a-z0-9+.-]*:/iu.test(value.replace(rawTarget, "")) ||
    target.includes("\\")
  )
    return false;
  if (!/[a-z][a-z0-9+.-]*:/iu.test(target) && !target.startsWith("//")) return true;
  if (
    !origin ||
    !/^https?:\/\//iu.test(target) ||
    /^https?:\/\/[^/?#]*@/iu.test(target)
  )
    return false;
  try {
    const url = new URL(target);
    return (
      url.origin === origin &&
      !url.username &&
      !url.password &&
      !url.search &&
      !target.split("#")[0].includes("?")
    );
  } catch {
    return false;
  }
}
function validatePlan(plan: MovePlan, rebuilding = false): void {
  if (plan.origin !== undefined) validateOrigin(plan.origin);
  if (
    !/^[a-zA-Z0-9_-]{1,100}$/.test(plan.id) ||
    !Number.isFinite(Date.parse(plan.createdAt)) ||
    !["personal", "ksp"].includes(plan.sourceSpace) ||
    !["personal", "ksp"].includes(plan.destinationSpace) ||
    plan.sourceSpace === plan.destinationSpace ||
    !plan.items.length
  )
    throw new Error("Invalid move plan");
  const occupied = new Set<string>();
  const claim = (space: SpaceId, path: string, allowDailyPatch = false) => {
    validatePath(path, allowDailyPatch);
    const key = `${space}:${path}`;
    if (occupied.has(key)) throw new Error("Invalid duplicate path");
    occupied.add(key);
  };
  const snapshot = (file: FileSnapshot) => {
    if (
      !file.revision ||
      !(file.bytes instanceof Uint8Array) ||
      file.size !== file.bytes.length
    )
      throw new Error("Invalid snapshot");
  };
  for (const item of plan.items) {
    if (item.source.space !== plan.sourceSpace || !(item.output instanceof Uint8Array))
      throw new Error("Invalid item");
    snapshot(item.source);
    claim(plan.sourceSpace, item.source.path);
    claim(plan.destinationSpace, target(item));
    if (item.destination) {
      snapshot(item.destination);
      if (
        item.destination.space !== plan.destinationSpace ||
        item.destination.path !== target(item)
      )
        throw new Error("Invalid destination");
    }
    if (
      item.isBinary ||
      binary(item.source) ||
      (item.destination && binary(item.destination))
    ) {
      if (
        !same(item.source.bytes, item.output) ||
        (item.destination && !same(item.source.bytes, item.destination.bytes))
      ) {
        throw new Error("Binary conflict or transformed binary output");
      }
    }
  }
  for (const patch of plan.patches) {
    snapshot(patch.before);
    if (
      ![plan.sourceSpace, plan.destinationSpace].includes(patch.before.space) ||
      !(patch.output instanceof Uint8Array)
    )
      throw new Error("Invalid patch");
    claim(patch.before.space, patch.before.path, true);
    for (const edit of patch.inverseEdits ?? []) {
      if (
        !Number.isSafeInteger(edit.from) ||
        !Number.isSafeInteger(edit.to) ||
        edit.from < 0 ||
        edit.to < edit.from ||
        !inverseLink(edit.before, plan.origin) ||
        !inverseLink(edit.after, plan.origin) ||
        new TextDecoder("utf-8", { fatal: true, ignoreBOM: true })
          .decode(patch.output)
          .slice(edit.from, edit.to) !== edit.after
      )
        throw new Error("Invalid inverse link edit");
    }
    if (dailyJournal(patch.before.path)) {
      if (!rebuilding && !same(restoreLinks(patch), patch.before.bytes))
        throw new Error("Daily journal patch must change links only");
    }
  }
}

/**
 * No multi-file atomicity or rollback: originals survive until every output is
 * verified. Invalid plans/fresh preflight conflicts throw before any mutation;
 * interrupted/resumed operations return partial or cancelled results. Counters
 * describe verified states, not attempted requests. Transport owns HTTP safety.
 */
export async function executeMove(
  transport: Transport,
  plan: MovePlan,
  options: MoveOptions = {},
): Promise<MoveResult> {
  // Own the approved bytes throughout awaits and callbacks. A caller changing
  // its preview must not change paths or output after validation/fingerprinting.
  plan = structuredClone(plan);
  validatePlan(plan, options.manifest !== undefined);
  const saved = options.manifest;
  if (saved) {
    if (
      saved.version !== 1 ||
      saved.id !== plan.id ||
      saved.sourceSpace !== plan.sourceSpace ||
      saved.origin !== plan.origin ||
      saved.destinationSpace !== plan.destinationSpace ||
      saved.createdAt !== plan.createdAt ||
      saved.items.length !== plan.items.length ||
      saved.patches.length !== plan.patches.length
    )
      throw new Error("Invalid resume manifest");
    // Rebuilt snapshots can carry archive revisions or already-written output.
    // Bind them to original metadata without ever weakening remote revision guards.
    for (const [i, item] of plan.items.entries()) {
      const state = saved.items[i];
      if (
        state.sourcePath !== item.source.path ||
        state.destinationPath !== target(item) ||
        state.sourceDigest !== (await digest(item.source.bytes)) ||
        state.outputDigest !== (await digest(item.output)) ||
        state.archivePath !== archivePath(plan, item.source.path)
      )
        throw new Error("Invalid rebuilt item or resume manifest");
      item.source.revision = state.sourceRevision;
      item.isBinary = state.isBinary;
      if (item.destination) {
        const hash = await digest(item.destination.bytes);
        if (hash !== state.destinationDigest && hash !== state.outputDigest)
          throw new Error("Invalid rebuilt destination");
      }
      if (state.destinationRevision !== undefined) {
        let original = item.destination;
        if (!original || (await digest(original.bytes)) !== state.destinationDigest) {
          const path = archivePath(plan, target(item));
          if (state.destinationArchivePath !== path)
            throw new Error("Missing original destination archive metadata");
          original = await transport.read(plan.destinationSpace, path);
          if (!original || (await digest(original.bytes)) !== state.destinationDigest)
            throw new Error("Missing or changed destination recovery archive");
        }
        item.destination = {
          ...original,
          space: plan.destinationSpace,
          path: target(item),
          revision: state.destinationRevision,
        };
      } else item.destination = null;
    }
    for (const [i, patch] of plan.patches.entries()) {
      const state = saved.patches[i];
      const candidates = (bytes: Uint8Array) =>
        dailyJournal(patch.before.path)
          ? stripJournalEntryCandidates(bytes, plan.id)
          : [bytes];
      const approved = async (bytes: Uint8Array, hashes: string[]) => {
        for (const candidate of candidates(bytes))
          if (hashes.includes(await digest(candidate))) return candidate;
        throw new Error("Invalid rebuilt patch or resume manifest");
      };
      if (state.space !== patch.before.space || state.path !== patch.before.path)
        throw new Error("Invalid rebuilt patch or resume manifest");
      patch.output = await approved(patch.output, [state.outputDigest]);
      patch.before.bytes = await approved(patch.before.bytes, [
        state.beforeDigest,
        state.outputDigest,
      ]);
      patch.before.size = patch.before.bytes.length;
      const hash = await digest(patch.before.bytes);
      patch.before.revision = state.revision;
      patch.inverseEdits = state.inverseEdits?.map(({ from, to, before, after }) => ({
        from,
        to,
        before,
        after,
      }));
      if (patch.inverseEdits?.length && hash === state.outputDigest) {
        const original = restoreLinks(patch);
        if ((await digest(original)) !== state.beforeDigest)
          throw new Error("Invalid rebuilt patch original");
        patch.before.bytes = original;
        patch.before.size = original.length;
      }
    }
    validatePlan(plan);
  }
  const items = await Promise.all(
    plan.items.map(async (item) => ({
      sourcePath: item.source.path,
      destinationPath: target(item),
      sourceRevision: item.source.revision,
      sourceDigest: await digest(item.source.bytes),
      outputDigest: await digest(item.output),
      isBinary: !!item.isBinary,
      ...(item.destination
        ? {
            destinationRevision: item.destination.revision,
            destinationDigest: await digest(item.destination.bytes),
          }
        : {}),
      archivePath: archivePath(plan, item.source.path),
      ...(item.destination &&
      (!same(item.destination.bytes, item.output) ||
        !same(item.destination.bytes, item.source.bytes))
        ? { destinationArchivePath: archivePath(plan, target(item)) }
        : {}),
      archiveVerified: false,
      destinationVerified: false,
      sourceRemoved: false,
    })),
  );
  const patches = await Promise.all(
    plan.patches.map(async (patch, i) => ({
      space: patch.before.space,
      path: patch.before.path,
      revision: patch.before.revision,
      beforeDigest:
        saved?.patches[i].beforeDigest ?? (await digest(patch.before.bytes)),
      outputDigest: await digest(patch.output),
      ...(patch.inverseEdits
        ? {
            inverseEdits: patch.inverseEdits.map(({ from, to, before, after }) => ({
              from,
              to,
              before,
              after,
            })),
          }
        : {}),
      verified: false,
    })),
  );
  const manifest: MoveManifest = {
    version: 1,
    id: plan.id,
    sourceSpace: plan.sourceSpace,
    destinationSpace: plan.destinationSpace,
    ...(plan.origin !== undefined ? { origin: plan.origin } : {}),
    createdAt: plan.createdAt,
    planDigest: await digest(
      encode(
        JSON.stringify({
          id: plan.id,
          sourceSpace: plan.sourceSpace,
          destinationSpace: plan.destinationSpace,
          createdAt: plan.createdAt,
          ...(plan.origin !== undefined ? { origin: plan.origin } : {}),
          items,
          patches,
          binary: plan.items.map((i) => !!i.isBinary),
        }),
      ),
    ),
    items,
    patches,
    journals: [],
    changes: [],
  };
  const resuming = options.manifest !== undefined;
  if (
    resuming &&
    (options.manifest!.version !== 1 ||
      options.manifest!.id !== plan.id ||
      options.manifest!.sourceSpace !== plan.sourceSpace ||
      options.manifest!.destinationSpace !== plan.destinationSpace ||
      options.manifest!.planDigest !== manifest.planDigest)
  )
    throw new Error("Invalid resume manifest");
  // Runtime revision guards are deliberately separate from immutable fingerprint
  // metadata. Only an exact approved prefix plus our sole own block can rebase.
  const patchRevisions = new Map<MovePatch, string>();
  const readPatch = async (patch: MovePatch) => {
    const raw = await transport.read(patch.before.space, patch.before.path);
    if (!raw) return null;
    const candidates =
      resuming && dailyJournal(patch.before.path)
        ? stripJournalEntryCandidates(raw.bytes, plan.id)
        : [raw.bytes];
    const normalized =
      candidates.find((b) => same(b, patch.before.bytes) || same(b, patch.output)) ??
      raw.bytes;
    return { raw, bytes: normalized, ownBlock: normalized.length !== raw.bytes.length };
  };
  const verifyPatch = async (patch: MovePatch) => {
    const actual = await readPatch(patch);
    if (!actual || !same(actual.bytes, patch.output))
      throw new Error(
        `Verification failed: ${patch.before.space}:${patch.before.path}`,
      );
  };
  const allowedChanges = new Set<string>();
  for (const [i, item] of plan.items.entries()) {
    allowedChanges.add(`${plan.sourceSpace}:${items[i].archivePath}:archive`);
    allowedChanges.add(`${plan.destinationSpace}:${target(item)}:destination`);
    allowedChanges.add(`${plan.sourceSpace}:${item.source.path}:remove`);
    if (items[i].destinationArchivePath)
      allowedChanges.add(
        `${plan.destinationSpace}:${items[i].destinationArchivePath}:archive`,
      );
  }
  for (const patch of plan.patches)
    allowedChanges.add(`${patch.before.space}:${patch.before.path}:patch`);
  for (const change of options.manifest?.changes ?? []) {
    if (
      !allowedChanges.has(`${change.space}:${change.path}:${change.kind}`) ||
      !/^\d{4}-\d{2}-\d{2}$/.test(change.day)
    )
      throw new Error("Invalid manifest change");
    // Explicitly copy permitted metadata, never arbitrary manifest properties.
    manifest.changes.push({
      space: change.space,
      path: change.path,
      kind: change.kind,
      day: change.day,
    });
  }
  const changed = (space: SpaceId, path: string, kind: ChangeState["kind"]) => {
    if (
      !manifest.changes.some(
        (c) => c.space === space && c.path === path && c.kind === kind,
      )
    ) {
      manifest.changes.push({ space, path, kind, day: journalDay() });
    }
  };
  const errors: MoveResult["errors"] = [];
  let phase = "preflight";
  let preflightFailed = false;
  let pending:
    | {
        space: SpaceId;
        path: string;
        kind: ChangeState["kind"];
        expected: Uint8Array | null;
        verified: () => void;
      }
    | undefined;
  const checkpoint = () => {
    if (options.signal?.aborted) throw new Error("Cancelled");
  };
  const persist = async () => {
    checkpoint();
    await options.saveManifest?.(structuredClone(manifest));
    options.onProgress?.({ phase, manifest: structuredClone(manifest) });
    checkpoint();
  };
  try {
    checkpoint();
    for (const item of plan.items) {
      checkpoint();
      const source = await transport.read(plan.sourceSpace, item.source.path);
      const destination = await transport.read(plan.destinationSpace, target(item));
      if (!source) {
        if (!resuming || !destination || !same(destination.bytes, item.output))
          throw new Error("Missing source without verified destination");
        await verify(
          transport,
          plan.sourceSpace,
          archivePath(plan, item.source.path),
          item.source.bytes,
        );
      } else if (
        source.revision !== item.source.revision ||
        !same(source.bytes, item.source.bytes)
      )
        throw new Error("Source changed");
      const expectedDestination = item.destination
        ? destination?.revision === item.destination.revision &&
          same(destination.bytes, item.destination.bytes)
        : destination === null;
      if (
        !expectedDestination &&
        !(resuming && destination && same(destination.bytes, item.output))
      )
        throw new Error("Destination changed");
    }
    for (const patch of plan.patches) {
      checkpoint();
      const actual = await readPatch(patch);
      if (
        !(
          actual &&
          (actual.raw.revision === patch.before.revision || actual.ownBlock) &&
          same(actual.bytes, patch.before.bytes)
        ) &&
        !(resuming && actual && same(actual.bytes, patch.output))
      )
        throw new Error("Patch changed");
      patchRevisions.set(patch, actual!.raw.revision);
    }
    await persist();
    phase = "archive";
    for (const [i, item] of plan.items.entries()) {
      checkpoint();
      pending = {
        space: plan.sourceSpace,
        path: items[i].archivePath,
        kind: "archive",
        expected: item.source.bytes,
        verified: () => {
          items[i].archiveVerified = !items[i].destinationArchivePath;
        },
      };
      await archive(
        transport,
        plan.sourceSpace,
        items[i].archivePath,
        item.source.bytes,
        checkpoint,
      );
      changed(plan.sourceSpace, items[i].archivePath, "archive");
      pending = undefined;
      if (items[i].destinationArchivePath) {
        checkpoint();
        pending = {
          space: plan.destinationSpace,
          path: items[i].destinationArchivePath!,
          kind: "archive",
          expected: item.destination!.bytes,
          verified: () => {
            items[i].archiveVerified = true;
          },
        };
        await archive(
          transport,
          plan.destinationSpace,
          items[i].destinationArchivePath!,
          item.destination!.bytes,
          checkpoint,
        );
        changed(plan.destinationSpace, items[i].destinationArchivePath!, "archive");
        pending = undefined;
      }
      items[i].archiveVerified = true;
      await persist();
    }
    phase = "destination";
    for (const [i, item] of plan.items.entries()) {
      checkpoint();
      const current = await transport.read(plan.destinationSpace, target(item));
      if (!current || !same(current.bytes, item.output)) {
        if (current?.readOnly) throw new Error("Readonly destination");
        checkpoint();
        pending = {
          space: plan.destinationSpace,
          path: target(item),
          kind: "destination",
          expected: item.output,
          verified: () => {
            items[i].destinationVerified = true;
          },
        };
        await transport.write(
          plan.destinationSpace,
          target(item),
          item.output,
          item.destination ? { revision: item.destination.revision } : { create: true },
        );
      }
      await verify(transport, plan.destinationSpace, target(item), item.output);
      if (!item.destination || !same(item.destination.bytes, item.output))
        changed(plan.destinationSpace, target(item), "destination");
      items[i].destinationVerified = true;
      pending = undefined;
      await persist();
    }
    phase = "patch";
    for (const [i, patch] of plan.patches.entries()) {
      checkpoint();
      const current = await readPatch(patch);
      if (!current || !same(current.bytes, patch.output)) {
        if (
          !current ||
          !same(current.bytes, patch.before.bytes) ||
          current.raw.revision !== patchRevisions.get(patch)
        )
          throw new Error("Patch changed");
        if (current.raw.readOnly) throw new Error("Readonly backlink page");
        // Keep any prior activity durably present even if this write/response or
        // later cleanup fails; never temporarily remove it to simplify guards.
        const output = new Uint8Array(
          patch.output.length + current.raw.bytes.length - current.bytes.length,
        );
        output.set(patch.output);
        output.set(
          current.raw.bytes.subarray(current.bytes.length),
          patch.output.length,
        );
        checkpoint();
        pending = {
          space: patch.before.space,
          path: patch.before.path,
          kind: "patch",
          expected: output,
          verified: () => {
            patches[i].verified = true;
          },
        };
        await transport.write(patch.before.space, patch.before.path, output, {
          revision: patchRevisions.get(patch)!,
        });
      }
      await verifyPatch(patch);
      if (patches[i].beforeDigest !== patches[i].outputDigest)
        changed(patch.before.space, patch.before.path, "patch");
      patches[i].verified = true;
      pending = undefined;
      await persist();
    }
    phase = "cleanup";
    // Recheck the complete barrier, not just the last written file. The API is
    // not atomic: a later concurrent edit can still require manual recovery.
    const verifyBarrier = async () => {
      for (const [i, item] of plan.items.entries()) {
        items[i].archiveVerified = false;
        await verify(
          transport,
          plan.sourceSpace,
          items[i].archivePath,
          item.source.bytes,
        );
        if (items[i].destinationArchivePath)
          await verify(
            transport,
            plan.destinationSpace,
            items[i].destinationArchivePath!,
            item.destination!.bytes,
          );
        items[i].archiveVerified = true;
        items[i].destinationVerified = false;
        await verify(transport, plan.destinationSpace, target(item), item.output);
        items[i].destinationVerified = true;
      }
      for (const [i, patch] of plan.patches.entries()) {
        patches[i].verified = false;
        await verifyPatch(patch);
        patches[i].verified = true;
      }
    };
    for (const item of plan.items) {
      const current = await transport.read(plan.sourceSpace, item.source.path);
      if (current?.readOnly) throw new Error("Readonly source");
      if (
        current &&
        (current.revision !== item.source.revision ||
          !same(current.bytes, item.source.bytes))
      )
        throw new Error("Source changed");
    }
    for (const [i, item] of plan.items.entries()) {
      checkpoint();
      await verifyBarrier();
      const source = await transport.read(plan.sourceSpace, item.source.path);
      if (source) {
        if (source.readOnly) throw new Error("Readonly source");
        if (
          source.revision !== item.source.revision ||
          !same(source.bytes, item.source.bytes)
        )
          throw new Error("Source changed");
        checkpoint();
        pending = {
          space: plan.sourceSpace,
          path: item.source.path,
          kind: "remove",
          expected: null,
          verified: () => {
            items[i].sourceRemoved = true;
          },
        };
        await transport.remove(plan.sourceSpace, item.source.path, source.revision);
      }
      if (await transport.read(plan.sourceSpace, item.source.path))
        throw new Error("Source removal not verified");
      changed(plan.sourceSpace, item.source.path, "remove");
      items[i].sourceRemoved = true;
      pending = undefined;
      await persist();
    }
  } catch (error) {
    if (phase === "preflight") {
      if (!resuming && !options.signal?.aborted) throw error;
      preflightFailed = true;
    }
    errors.push({
      phase,
      message: error instanceof Error ? error.message : "Transfer failed",
    });
    // A failed response is not proof that the server did nothing. Inspect only
    // the uncertain target; never retry its mutation or proceed to cleanup here.
    if (pending) {
      try {
        const actual = await transport.read(pending.space, pending.path);
        if (
          pending.expected === null
            ? actual === null
            : actual && same(actual.bytes, pending.expected)
        ) {
          pending.verified();
          changed(pending.space, pending.path, pending.kind);
        }
      } catch {
        /* Unknown remains unverified; resume must inspect again. */
      }
    }
  }
  phase = "journal";
  const groups = new Map<string, ChangeState[]>();
  for (const change of manifest.changes) {
    const group = `${change.space}:${change.day}`;
    groups.set(group, [...(groups.get(group) ?? []), change]);
  }
  for (const changes of groups.values()) {
    const { space, day } = changes[0];
    const entry: JournalState = { space, path: `Journal/${day}.md`, verified: false };
    manifest.journals.push(entry);
    if (preflightFailed) continue;
    try {
      checkpoint();
      const current = await transport.read(space, entry.path);
      const marker = `<!-- space-move:${plan.id} -->`;
      const endMarker = `<!-- /space-move:${plan.id} -->`;
      const old = current
        ? new TextDecoder("utf-8", { fatal: true, ignoreBOM: true }).decode(
            current.bytes,
          )
        : "";
      const paths = [...changes]
        .sort((a, b) => `${a.kind}:${a.path}`.localeCompare(`${b.kind}:${b.path}`))
        .map(
          (c) =>
            `${c.kind} ${JSON.stringify(c.path)} (${journalLink(c.kind === "remove" ? archivePath(plan, c.path) : c.path)})`,
        )
        .join("; ");
      const moves = items
        .map(
          (i) =>
            `${JSON.stringify(i.sourcePath)} → ${JSON.stringify(i.destinationPath)}`,
        )
        .join("; ");
      const block = `${marker}\n- Space move ${plan.id}: ${plan.sourceSpace} → ${plan.destinationSpace}; ${moves}. ${paths}.\n${endMarker}`;
      const start = old.indexOf(marker);
      const end = old.indexOf(endMarker, start);
      if (start >= 0 && end < 0)
        throw new Error("Incomplete journal marker; manual reconciliation required");
      const body =
        start >= 0
          ? old.slice(0, start) + block + old.slice(end + endMarker.length)
          : `${old}${old.endsWith("\n") || !old ? "" : "\n"}\n${block}\n`;
      if (body !== old) {
        const data = encode(body);
        checkpoint();
        await transport.write(
          space,
          entry.path,
          data,
          current ? { revision: current.revision } : { create: true },
        );
        await verify(transport, space, entry.path, data);
      }
      entry.verified = true;
      await persist();
    } catch (error) {
      errors.push({
        phase,
        message: error instanceof Error ? error.message : "Journal failed",
      });
    }
  }
  return {
    status: options.signal?.aborted
      ? "cancelled"
      : errors.length
        ? "partial"
        : "complete",
    manifest,
    errors,
    counts: {
      destinations: items.filter((i) => i.destinationVerified).length,
      patches: patches.filter((p) => p.verified).length,
      removed: items.filter((i) => i.sourceRemoved).length,
      journals: manifest.journals.filter((j) => j.verified).length,
    },
  };
}
