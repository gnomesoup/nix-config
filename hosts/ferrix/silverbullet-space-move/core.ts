import type { FileSnapshot, SpaceConfig } from "./types.ts";

export interface Candidate {
  path: string;
  kind: "page" | "document";
  reasons: string[];
  selected: boolean;
  shared: boolean;
  depth: number;
  warnings: string[];
}

export function discoverCollection(
  root: string,
  files: FileSnapshot[],
  options: {
    maxDepth?: number;
    sharedThreshold?: number;
    maxFiles?: number;
  } = {},
): {
  candidates: Candidate[];
  backlinks: string[];
  warnings: string[];
  truncated: boolean;
} {
  const maxDepth = options.maxDepth ?? 2;
  const sharedThreshold = options.sharedThreshold ?? 10;
  const maxFiles = options.maxFiles ?? 1000;
  if (
    ![maxDepth, sharedThreshold, maxFiles].every(Number.isSafeInteger) ||
    maxDepth < 0 ||
    sharedThreshold < 1 ||
    maxFiles < 1
  ) {
    throw new Error("Invalid discovery limits");
  }
  const index = new Map(files.map((f) => [f.path, f]));
  const warnings = new Set<string>();
  const candidates = new Map<string, Candidate>();
  let truncated = false;
  if (index.size !== files.length) {
    return {
      candidates: [],
      backlinks: [],
      warnings: ["Duplicate snapshot paths; ambiguous collection"],
      truncated,
    };
  }
  if (!isManagedPath(root) || !index.has(root)) {
    return {
      candidates: [],
      backlinks: [],
      warnings: ["Root missing or not movable: " + root],
      truncated,
    };
  }
  const incoming = new Map<string, Set<string>>();
  for (const f of files)
    for (const link of f.links ?? []) {
      if (link.ambiguous || link.kind === "embed" || link.warning) continue;
      if (!incoming.has(link.target)) incoming.set(link.target, new Set());
      incoming.get(link.target)!.add(f.path);
    }
  const queue = [{ path: root, depth: 0, reason: "Selected root" }];
  for (let i = 0; i < queue.length; i++) {
    const { path, depth, reason } = queue[i];
    if (candidates.has(path)) {
      const reasons = candidates.get(path)!.reasons;
      if (!reasons.includes(reason)) reasons.push(reason);
      continue;
    }
    if (!isManagedPath(path)) {
      warnings.add("Non-movable path: " + path);
      continue;
    }
    const f = index.get(path);
    if (!f) {
      warnings.add("Missing target: " + path);
      continue;
    }
    if (candidates.size >= maxFiles) {
      warnings.add("Collection truncated at maxFiles=" + maxFiles);
      truncated = true;
      continue;
    }
    const journal =
      /(^|\/)(?:Journal|Journals|Daily)(?:\/|$)/i.test(path) ||
      /(^|\/)\d{4}-\d{2}-\d{2}\.md$/.test(path);
    const shared = journal || (incoming.get(path)?.size ?? 0) >= sharedThreshold;
    const kind = path.endsWith(".md") ? "page" : "document";
    candidates.set(path, {
      path,
      kind,
      reasons: [reason],
      depth,
      shared,
      selected: path === root || !shared,
      warnings: shared ? ["Shared hub or journal; review before selecting"] : [],
    });
    if (kind !== "page" || (shared && path !== root)) continue;
    for (const link of f.links ?? []) {
      if (link.ambiguous || link.kind === "embed" || link.warning) {
        warnings.add("Unsupported or ambiguous link in " + path);
        continue;
      }
      if (candidates.has(link.target)) continue;
      if (depth >= maxDepth) {
        warnings.add(
          "Collection truncated at maxDepth=" + maxDepth + ": " + link.target,
        );
        truncated = true;
      } else
        queue.push({
          path: link.target,
          depth: depth + 1,
          reason: "Linked from " + path,
        });
    }
  }
  const backlinks = files
    .filter(
      (f) =>
        !candidates.has(f.path) &&
        (f.links ?? []).some((l) => !l.ambiguous && candidates.has(l.target)),
    )
    .map((f) => f.path)
    .sort();
  return {
    candidates: [...candidates.values()],
    backlinks: [...new Set(backlinks)],
    warnings: [...warnings],
    truncated,
  };
}

// Link spans cover the complete syntax (including image "!") in this exact snapshot.
// Canonical targets and fragment delimiters come from the upstream parser adapter.
export function rewriteLinks(
  file: FileSnapshot,
  options: {
    selected: ReadonlySet<string>;
    source: SpaceConfig;
    destination: SpaceConfig;
    location: "source" | "destination";
    origin: string;
    sourcePaths: ReadonlySet<string>;
    destinationPaths: ReadonlySet<string>;
    collectEdits?: boolean;
  },
): {
  text: string;
  changes: number;
  warnings: string[];
  edits?: { from: number; to: number; text: string }[];
} {
  const text = file.text ?? "";
  const warnings: string[] = [];
  const edits: { from: number; to: number; text: string }[] = [];
  const origin = new URL(options.origin);
  if (
    !/^https?:$/.test(origin.protocol) ||
    origin.username ||
    origin.password ||
    origin.origin !== options.origin
  )
    throw new Error("Invalid origin");
  for (const space of [options.source, options.destination]) {
    if (
      space.prefix !== "" &&
      (!space.prefix.startsWith("/") ||
        space.prefix.endsWith("/") ||
        /[%?#\\\s()[\]<>"'`{}\u0000-\u001f\u007f]/.test(space.prefix) ||
        space.prefix.includes("//") ||
        space.prefix.split("/").some((p) => p === "." || p === ".."))
    )
      throw new Error("Invalid space prefix");
  }
  const links = [...(file.links ?? [])].sort((a, b) => a.from - b.from);
  let end = 0;
  for (const link of links) {
    if (
      !Number.isSafeInteger(link.from) ||
      !Number.isSafeInteger(link.to) ||
      link.from < 0 ||
      link.to <= link.from ||
      link.to > text.length ||
      link.from < end
    )
      throw new Error("Stale or overlapping link span/range in " + file.path);
    end = link.to;
    if (link.ambiguous || link.warning || link.kind === "embed") {
      warnings.push("Ambiguous or unsupported link retained: " + link.target);
      continue;
    }
    const raw = text.slice(link.from, link.to);
    const wiki = link.syntax === "wiki";
    const split = wiki ? -1 : markdownLabelEnd(raw);
    const suffix = wiki
      ? null
      : raw
          .slice(split + 2)
          .match(
            /^(<[^>\r\n]*>|[^\s]*?)(\s+(?:"[^"\r\n]*"|'[^'\r\n]*'|\([^\)\r\n]*\)))?\)$/,
          );
    if (
      wiki
        ? !/^!?\[\[(?:(?!\[\[|\]\])[\s\S])*\]\]$/.test(raw)
        : split < 1 || !suffix || !balancedUrl(suffix[1])
    )
      throw new Error("Stale link span in " + file.path);
    if (!safePath(link.target)) {
      warnings.push("Unsafe target retained: " + link.target);
      continue;
    }
    const inSource = options.sourcePaths.has(link.target);
    const inDestination = options.destinationPaths.has(link.target);
    if (!inSource && !inDestination) {
      warnings.push("Missing target retained: " + link.target);
      continue;
    }
    const targetMoved = inSource && options.selected.has(link.target);
    const hereMoved = options.location === "destination";
    const verifiedOther = !inSource && inDestination;
    if (!hereMoved && !targetMoved && !verifiedOther) continue;
    const path = link.kind === "page" ? link.target.replace(/\.md$/, "") : link.target;
    const encoded = path.split("/").map(encodeSegment).join("/");
    const rawFragment = link.fragment ?? "";
    const delimiter = /^[#$@]/.test(rawFragment) ? rawFragment[0] : "#";
    // Parser fragments are literal SDK reference text, never URI-decoded here.
    const fragment = /^[#$@]/.test(rawFragment) ? rawFragment.slice(1) : rawFragment;
    const anchor = rawFragment ? delimiter + encodeSegment(fragment) : "";
    const cross = hereMoved !== targetMoved || verifiedOther;
    const space = targetMoved || verifiedOther ? options.destination : options.source;
    const url = (cross ? options.origin + space.prefix : "") + "/" + encoded + anchor;
    let replacement: string;
    if (wiki) {
      const image = raw.startsWith("!") ? "!" : "";
      const inner = raw.slice(image ? 3 : 2, -2);
      const pipe = inner.indexOf("|");
      const label = link.label ?? (pipe >= 0 ? inner.slice(pipe + 1) : inner);
      // Wiki refs are literal SDK text; URI encoding would change their targets.
      replacement = cross
        ? `${image}[${escapeLabel(label)}](${url})`
        : `${image}[[/${path}${rawFragment ? delimiter + fragment : ""}${pipe >= 0 || link.label !== undefined || inner.replace(/[#$@].*$/, "") !== path ? "|" + label : ""}]]`;
    } else {
      replacement = raw.slice(0, split + 2) + url + (suffix![2] ?? "") + ")";
    }
    if (replacement !== raw)
      edits.push({ from: link.from, to: link.to, text: replacement });
  }
  let result = text;
  for (const edit of edits.sort((a, b) => b.from - a.from))
    result = result.slice(0, edit.from) + edit.text + result.slice(edit.to);
  return {
    text: result,
    changes: edits.length,
    warnings,
    ...(options.collectEdits ? { edits } : {}),
  };
}

function markdownLabelEnd(raw: string): number {
  const start = raw.startsWith("!") ? 1 : 0;
  if (raw[start] !== "[") return -1;
  let depth = 0;
  for (let i = start; i < raw.length; i++) {
    if (raw[i] === "\\") {
      i++;
      continue;
    }
    if (raw[i] === "[") depth++;
    else if (raw[i] === "]" && --depth === 0) return raw[i + 1] === "(" ? i : -1;
  }
  return -1;
}

function balancedUrl(url: string): boolean {
  if (url.startsWith("<")) return url.endsWith(">");
  let depth = 0;
  for (let i = 0; i < url.length; i++) {
    if (url[i] === "\\") {
      i++;
      continue;
    }
    if (url[i] === "(") depth++;
    else if (url[i] === ")" && --depth < 0) return false;
  }
  return depth === 0;
}

function encodeSegment(value: string): string {
  return encodeURIComponent(value).replace(
    /[!'()*]/g,
    (c) => "%" + c.charCodeAt(0).toString(16).toUpperCase(),
  );
}

function escapeLabel(value: string): string {
  return value
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/[\\[\]()*_`!]/g, (c) => "\\" + c)
    .replace(/[\r\n]/g, " ");
}

function safePath(path: string): boolean {
  return (
    !!path &&
    !path.startsWith("^") &&
    !/\.[A-Za-z0-9]+\.md$/.test(path) &&
    !/[\\:@#$|<>\u0000-\u001f\u007f]/.test(path) &&
    path.split("/").every((p) => !!p && !p.startsWith("."))
  );
}

const IMPORT_BEGIN = "<!-- Space Move: begin imported section -->";
const IMPORT_END = "<!-- Space Move: end imported section -->";
const PROVENANCE = "<!-- Space Move provenance: ";

function normalized(text: string): string {
  return text.replace(/\r\n/g, "\n");
}
function stripBlankEdges(text: string): string {
  return text.replace(/^\n+|\n+$/g, "");
}

// Only structural boundaries outside fenced code are considered. No prose is compared semantically.
function sections(text: string, allowImported = true): string[] {
  const chunks: string[] = [];
  let lines: string[] = [];
  let imported = false;
  let hasProvenance = false;
  let fence = "";
  let width = 0;
  const flush = () => {
    const chunk = stripBlankEdges(lines.join("\n"));
    if (chunk) chunks.push(chunk);
    lines = [];
  };
  for (const line of text.split("\n")) {
    const marker = line.match(/^ {0,3}(`{3,}|~{3,})(.*)$/);
    if (fence) {
      lines.push(line);
      if (
        marker &&
        marker[1][0] === fence &&
        marker[1].length >= width &&
        !marker[2].trim()
      )
        fence = "";
      continue;
    }
    if (marker) {
      fence = marker[1][0];
      width = marker[1].length;
      lines.push(line);
      continue;
    }
    if (line === IMPORT_BEGIN || line === IMPORT_END || line.startsWith(PROVENANCE)) {
      if (!allowImported)
        throw new Error(
          "Source contains reserved merge markers; manual review required",
        );
      if (line === IMPORT_BEGIN) {
        if (imported) throw new Error("Nested merge markers");
        flush();
        imported = true;
        hasProvenance = false;
      } else if (line === IMPORT_END) {
        if (!imported || !hasProvenance) throw new Error("Unbalanced merge markers");
        flush();
        imported = false;
      } else {
        if (!imported || hasProvenance || lines.length || !line.endsWith(" -->"))
          throw new Error("Invalid merge provenance marker");
        hasProvenance = true;
      }
      continue;
    }
    if (/^ {0,3}#{1,6}\s/.test(line)) flush();
    lines.push(line);
  }
  if (imported) throw new Error("Unbalanced merge markers");
  if (fence) throw new Error("Unclosed fenced code; automatic merge unsafe");
  flush();
  return chunks;
}

interface Frontmatter {
  lines: string[];
  entries: Map<
    string,
    { line: number; end: number; raw: string; value: string | string[] }
  >;
  body: string;
  present: boolean;
}

function yamlScalar(raw: string, requireString = false): string {
  if (/^"(?:[^"\\]|\\.)*"$/.test(raw)) {
    const value = JSON.parse(raw);
    if (typeof value !== "string" || /[\r\n\u0000]/.test(value))
      throw new Error("Unsupported YAML string");
    return value;
  }
  if (/^'(?:[^']|'')*'$/.test(raw)) return raw.slice(1, -1).replace(/''/g, "'");
  // A union is serialized as quoted strings: do not silently change YAML types.
  if (
    requireString &&
    /^(?:null|true|false|yes|no|on|off|~|[-+]?(?:0[xob][0-9a-f_]+|[0-9][0-9_]*(?:\.[0-9_]*)?(?:e[-+]?[0-9]+)?|\.[0-9]+(?:e[-+]?[0-9]+)?|\.inf|\.nan)|[0-9]{4}-[0-9]{2}-[0-9]{2}(?:[Tt ].*)?)$/i.test(
      raw,
    )
  )
    throw new Error("Non-string YAML union value: " + raw);
  if (/^[\p{L}\p{N}_ .\/@%+\-]+$/u.test(raw) && raw.trim()) return raw;
  throw new Error("Unsupported or dangerous YAML value: " + raw);
}

function yamlList(raw: string): string[] {
  const inner = raw.slice(1, -1).trim();
  if (!inner) return [];
  const tokens = inner.match(/"(?:[^"\\]|\\.)*"|'(?:[^']|'')*'|[^,]+/g) ?? [];
  // Reconstructing separators rejects malformed quoting or silently skipped punctuation.
  if (tokens.join(",").replace(/\s/g, "") !== inner.replace(/\s/g, ""))
    throw new Error("Unsupported YAML list");
  return tokens.map((token) => yamlScalar(token.trim(), true));
}

function frontmatter(text: string): Frontmatter {
  const lines = text.split("\n");
  if (lines[0] !== "---")
    return { lines: [], entries: new Map(), body: text, present: false };
  const end = lines.indexOf("---", 1);
  if (end < 0) throw new Error("Unclosed frontmatter");
  const header = lines.slice(1, end);
  const entries: Frontmatter["entries"] = new Map();
  for (let i = 0; i < header.length; i++) {
    const line = header[i];
    if (!line.trim() || /^\s*#/.test(line)) continue;
    const match = line.match(/^([A-Za-z_][A-Za-z0-9_-]*):\s*(.*)$/);
    if (!match || entries.has(match[1]))
      throw new Error("Unsupported YAML or duplicate metadata key: " + line);
    const [, key, value] = match;
    const raw = value.trim();
    const union = key === "aliases" || key === "tags";
    const start = i;
    if (!raw && union) {
      const values: string[] = [];
      let indentation: string | undefined;
      while (i + 1 < header.length) {
        const item = header[i + 1].match(/^( {0,2})- (.+)$/);
        if (!item) break;
        if (indentation !== undefined && indentation !== item[1])
          throw new Error("Inconsistent YAML sequence indentation");
        indentation = item[1];
        values.push(yamlScalar(item[2].trim(), true));
        i++;
      }
      if (!values.length) throw new Error("Unsupported empty YAML value: " + key);
      entries.set(key, { line: start, end: i, raw, value: values });
    } else {
      entries.set(key, {
        line: start,
        end: i,
        raw,
        value: union
          ? raw.startsWith("[") && raw.endsWith("]")
            ? yamlList(raw)
            : [yamlScalar(raw, true)]
          : (yamlScalar(raw), raw),
      });
    }
  }
  return {
    lines: header,
    entries,
    body: lines.slice(end + 1).join("\n"),
    present: true,
  };
}

function mergeFrontmatter(source: Frontmatter, destination: Frontmatter): string[] {
  const lines = [...destination.lines];
  for (const [key, entry] of source.entries) {
    const existing = destination.entries.get(key);
    if (!existing) {
      lines.push(...source.lines.slice(entry.line, entry.end + 1));
      continue;
    }
    if (Array.isArray(entry.value) && Array.isArray(existing.value)) {
      const union = [...new Set([...existing.value, ...entry.value])];
      if (JSON.stringify(union) !== JSON.stringify(existing.value)) {
        lines[existing.line] =
          `${key}: [${union.map((v) => JSON.stringify(v)).join(", ")}]`;
        for (let i = existing.line + 1; i <= existing.end; i++) lines[i] = "";
      }
    } else if (entry.value !== existing.value)
      throw new Error("Conflicting scalar metadata: " + key);
  }
  for (const line of source.lines)
    if (/^\s*#/.test(line) && !lines.includes(line)) lines.push(line);
  return lines;
}

function containsCompleteContent(destination: string, source: string): boolean {
  if (destination === source) return true;
  const lines = destination.split("\n");
  let fence = "";
  let width = 0;
  let offset = 0;
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (
      !fence &&
      (i === 0 || lines[i - 1] === "") &&
      destination.startsWith(source, offset)
    ) {
      const after = destination.slice(offset + source.length);
      if (after === "" || after.startsWith("\n\n")) return true;
    }
    const marker = line.match(/^ {0,3}(`{3,}|~{3,})(.*)$/);
    if (marker) {
      if (!fence) {
        fence = marker[1][0];
        width = marker[1].length;
      } else if (
        marker[1][0] === fence &&
        marker[1].length >= width &&
        !marker[2].trim()
      )
        fence = "";
    }
    offset += line.length + 1;
  }
  return false;
}

function anchors(text: string): string[] {
  const result: string[] = [];
  let fence = "";
  let previous = "";
  let width = 0;
  for (const line of text.split("\n")) {
    const marker = line.match(/^ {0,3}(`{3,}|~{3,})(.*)$/);
    if (fence) {
      if (
        marker &&
        marker[1][0] === fence &&
        marker[1].length >= width &&
        !marker[2].trim()
      )
        fence = "";
      previous = "";
      continue;
    }
    if (marker) {
      fence = marker[1][0];
      width = marker[1].length;
      previous = "";
      continue;
    }
    const heading = line.match(/^ {0,3}#{1,6}\s+(.+?)(?:\s+#+)?\s*$/);
    const title =
      heading?.[1] ??
      (/^ {0,3}(?:=+|-+)\s*$/.test(line) && previous.trim()
        ? previous.trim()
        : undefined);
    if (title)
      result.push("heading:" + title.toLowerCase().replace(/[^\p{L}\p{N}]+/gu, "-"));
    previous = line;
    // SilverBullet's NamedAnchor grammar; conservatively treat any occurrence outside fences as an anchor.
    for (const match of line.matchAll(/(?<!\\)\$([A-Za-z_][A-Za-z0-9_/:-]*)/g))
      result.push("anchor:" + match[1]);
    for (const match of line.matchAll(
      /(?:\{#([\w-]+)\}|\^([\w-]+)\s*$|<a\b[^>]*\b(?:id|name)=["']([^"']+)["'][^>]*>)/gi,
    ))
      result.push("anchor:" + (match[1] ?? match[2] ?? match[3]));
  }
  return result;
}

export function mergeMarkdown(
  source: string,
  destination: string,
  provenance = "source space",
): {
  text: string;
  changed: boolean;
  warnings: string[];
  conflicts: string[];
} {
  if (normalized(source) === normalized(destination))
    return { text: destination, changed: false, warnings: [], conflicts: [] };
  try {
    const src = frontmatter(normalized(source));
    const dst = frontmatter(normalized(destination));
    const header = mergeFrontmatter(src, dst);
    const known = sections(dst.body);
    const missing = sections(src.body, false).filter(
      (chunk) => !known.some((existing) => containsCompleteContent(existing, chunk)),
    );
    const usedAnchors = new Set<string>();
    for (const anchor of anchors(dst.body + "\n" + missing.join("\n"))) {
      if (usedAnchors.has(anchor)) throw new Error("Duplicate anchor: " + anchor);
      usedAnchors.add(anchor);
    }
    const eol =
      destination.includes("\r\n") || (!destination && source.includes("\r\n"))
        ? "\r\n"
        : "\n";
    let text =
      (src.present || dst.present ? ["---", ...header, "---", ""].join("\n") : "") +
      dst.body;
    text = text.replace(/\n/g, eol);
    if (missing.length) {
      const safeProvenance = provenance.replace(/[<>\r\n]/g, " ").replace(/--/g, "—");
      const additions = missing
        .map((chunk) =>
          [IMPORT_BEGIN, PROVENANCE + safeProvenance + " -->", chunk, IMPORT_END].join(
            "\n",
          ),
        )
        .join("\n\n")
        .replace(/\n/g, eol);
      text +=
        (text && !text.endsWith(eol + eol)
          ? text.endsWith(eol)
            ? eol
            : eol + eol
          : "") +
        additions +
        eol;
    }
    return { text, changed: text !== destination, warnings: [], conflicts: [] };
  } catch (error) {
    return {
      text: destination,
      changed: false,
      warnings: ["Automatic merge blocked; retain source"],
      conflicts: [error instanceof Error ? error.message : String(error)],
    };
  }
}

const reserved = new Set([
  "Library",
  "Repositories",
  "Trash",
  "_plug",
  "_config",
  "Space Moves",
]);

export function isManagedPath(path: string): boolean {
  return safePath(path) && !reserved.has(path.split("/")[0]);
}
