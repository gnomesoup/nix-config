import { encodeRef, parseToRef, type Path } from "@silverbulletmd/silverbullet/lib/ref";
import {
  BasenameIndex,
  resolvePath,
} from "@silverbulletmd/silverbullet/lib/resolve_path";
import {
  isLocalURL,
  resolveMarkdownLink,
} from "@silverbulletmd/silverbullet/lib/resolve";
import type { LinkRef, ParseNode, SpaceConfig, SpaceId } from "./types.ts";

export interface ParseContext {
  origin: string;
  currentSpace: SpaceId;
  spaces: SpaceConfig[];
  paths: ReadonlyMap<SpaceId, Iterable<string>>;
}

function nodeText(node: ParseNode): string {
  return node.text ?? (node.children ?? []).map(nodeText).join("");
}

function find(node: ParseNode, type: string): ParseNode | undefined {
  if (node.type === type) return node;
  for (const child of node.children ?? []) {
    const found = find(child, type);
    if (found) return found;
  }
}

// Split literal reference delimiters before decoding. An encoded delimiter in
// the path must not turn into a metadata/fragment reference to a different file.
function decodeURLRef(raw: string): string {
  const boundary = raw.search(/[#@$]/);
  const encodedPath = boundary < 0 ? raw : raw.slice(0, boundary);
  if (/%(?:23|40|24|5e|7c|5b|5d|3c|3e)/i.test(encodedPath)) {
    throw new Error("Encoded reference delimiter in URL path");
  }
  const decodedPath = decodeURIComponent(encodedPath);
  if (/[\\\x00-\x1f\x7f]/.test(decodedPath)) throw new Error("Unsafe URL path");
  return decodedPath + (boundary < 0 ? "" : decodeURIComponent(raw.slice(boundary)));
}

export function parseLinks(
  path: string,
  text: string,
  tree: ParseNode,
  paths: Iterable<string>,
  context?: ParseContext,
): {
  links: LinkRef[];
  warnings: string[];
} {
  const links: LinkRef[] = [];
  const warnings: string[] = [];
  const index = new BasenameIndex();
  index.rebuild(paths);
  // SilverBullet's parse_tree.parse removes CR before assigning offsets.
  // Starts are right-biased; ends must not consume a following CR separator.
  const starts: number[] = [];
  const ends: number[] = [0];
  if (text.includes("\r")) {
    let normalized = 0;
    for (let original = 0; original < text.length; original++) {
      if (text[original] === "\r") continue;
      starts[normalized++] = original;
      ends[normalized] = original + 1;
    }
    starts[normalized] = text.length;
  }
  const walk = (
    node: ParseNode,
    frontMatterRef?: { raw: string; label?: string },
  ): void => {
    if (node.type === "FrontMatter") {
      // YAML has its own AST, not WikiLink nodes. Scan only this AST-bounded
      // region; never reinterpret arbitrary Markdown/code text as references.
      const code = find(node, "FrontMatterCode");
      if (code?.from !== undefined) {
        for (const match of nodeText(code).matchAll(
          /(?<![\\\[])\[\[([^\[\]\r\n]+)\]\](?!\])/g,
        )) {
          const [raw, ...alias] = match[1].split("|");
          const from = code.from + match.index;
          walk(
            { from, to: from + match[0].length },
            { raw, label: alias.length ? alias.join("|") : undefined },
          );
        }
      }
      return;
    }
    if (
      ["FencedCode", "CodeBlock", "InlineCode", "HTMLBlock", "LuaDirective"].includes(
        node.type ?? "",
      )
    )
      return;
    const wiki =
      node.type === "WikiLink"
        ? node
        : node.type === "Image"
          ? find(node, "WikiLink")
          : undefined;
    const unsupportedURL = ["NakedURL", "Autolink", "URL"].includes(node.type ?? "");
    if (
      wiki ||
      frontMatterRef ||
      node.type === "Link" ||
      node.type === "Image" ||
      node.type === "LinkReference" ||
      unsupportedURL
    ) {
      const from =
        node.from === undefined
          ? undefined
          : starts.length
            ? starts[node.from]
            : node.from;
      const to =
        node.to === undefined ? undefined : starts.length ? ends[node.to] : node.to;
      if (from === undefined || to === undefined || from < 0 || to > text.length) {
        throw new Error(
          "The upstream Markdown parser returned an invalid source span.",
        );
      }
      let raw = "";
      let label: string | undefined;
      let warning: string | undefined;
      let targetSpace = context?.currentSpace;
      if (frontMatterRef) {
        raw = frontMatterRef.raw;
        label = frontMatterRef.label;
        warning = "Frontmatter references cannot be rewritten across spaces.";
      } else if (wiki) {
        raw = nodeText(find(wiki, "WikiLinkPage") ?? {});
        const alias = find(wiki, "WikiLinkAlias");
        if (alias) label = nodeText(alias);
      } else {
        const url = node.type === "NakedURL" ? node : find(node, "URL");
        if (!url) {
          warnings.push(`Unresolved reference-style link in ${path}.`);
          return;
        }
        raw = nodeText(url);
        if (raw.startsWith("<") && raw.endsWith(">")) raw = raw.slice(1, -1);
        if (unsupportedURL && !/^https?:\/\//i.test(raw)) return;
        try {
          if (/^https?:\/\//i.test(raw)) {
            if (!context) return;
            const absolute = new URL(raw);
            if (absolute.origin !== context.origin) return;
            if (raw.split("#", 1)[0].includes("?"))
              warning = "Query-bearing references cannot be rewritten across spaces.";
            const space = [...context.spaces]
              .sort((a, b) => b.prefix.length - a.prefix.length)
              .find((candidate) =>
                absolute.pathname.startsWith(candidate.prefix + "/"),
              );
            if (!space) return;
            targetSpace = space.id;
            raw = decodeURLRef(
              absolute.pathname.slice(space.prefix.length + 1) + absolute.hash,
            );
          } else {
            if (raw.startsWith("//") || !isLocalURL(raw)) return;
            const hash = raw.indexOf("#");
            const query = raw.indexOf("?");
            if (query >= 0 && (hash < 0 || query < hash)) {
              warning = "Query-bearing references cannot be rewritten across spaces.";
              raw = raw.slice(0, query) + (hash < 0 ? "" : raw.slice(hash));
            }
            // Fragment-only URLs address this page, not a phantom folder file.
            if (!raw || /^[#@$]/.test(raw)) return;
            raw = resolveMarkdownLink(path.replace(/\.md$/, ""), decodeURLRef(raw));
          }
        } catch {
          warnings.push(`Invalid link encoding in ${path}.`);
          return;
        }
        const spelling = text.slice(from, to);
        const bracket = spelling.indexOf("](");
        label =
          bracket >= 0
            ? spelling.slice(spelling.startsWith("!") ? 2 : 1, bracket)
            : undefined;
      }
      const ref = parseToRef(raw);
      if (!ref) {
        warnings.push(`Unrecognized reference in ${path}: ${raw}`);
        return;
      }
      if (!ref.path) return;
      let targetIndex = index;
      if (context && targetSpace && targetSpace !== context.currentSpace) {
        targetIndex = new BasenameIndex();
        targetIndex.rebuild(context.paths.get(targetSpace) ?? []);
      }
      const resolved = resolvePath(ref.path, path as Path, targetIndex);
      const image = node.type === "Image";
      if (ref.meta)
        warning ??= "Metadata references cannot be rewritten across spaces.";
      if (node.type === "LinkReference")
        warning ??= "Reference-style definitions cannot be rewritten across spaces.";
      if (unsupportedURL)
        warning ??= "Naked URLs and autolinks cannot be rewritten across spaces.";
      links.push({
        from,
        to,
        target: resolved.path,
        fragment: ref.details
          ? encodeRef({ path: "", details: ref.details })
          : undefined,
        label,
        syntax: wiki || frontMatterRef ? "wiki" : "markdown",
        targetSpace,
        kind: image
          ? resolved.path.endsWith(".md")
            ? "embed"
            : "image"
          : resolved.path.endsWith(".md")
            ? "page"
            : "document",
        ambiguous: resolved.ambiguous,
        warning,
      });
      return;
    }
    for (const child of node.children ?? []) walk(child);
  };
  walk(tree);
  return { links, warnings };
}
