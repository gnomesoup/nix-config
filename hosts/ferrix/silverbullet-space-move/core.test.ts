import test from "node:test";
import assert from "node:assert/strict";
import type { FileSnapshot, LinkRef, SpaceConfig } from "./types.ts";
import {
  isManagedPath,
  discoverCollection,
  rewriteLinks,
  mergeMarkdown,
} from "./core.ts";

function file(path: string, text = "", links: LinkRef[] = []): FileSnapshot {
  return {
    path,
    text,
    links,
    bytes: new TextEncoder().encode(text),
    size: text.length,
    space: "personal",
    revision: "1",
  };
}
function ref(target: string): LinkRef {
  return {
    from: 0,
    to: 1,
    target,
    kind: target.endsWith(".md") ? "page" : "document",
    syntax: "wiki",
  };
}

test("discovery follows canonical outgoing links with cycles, shared hubs, docs, journals and backlinks", () => {
  assert.equal(typeof discoverCollection, "function");
  const files = [
    file("Root.md", "", [
      ref("Child.md"),
      ref("Hub.md"),
      ref("a.pdf"),
      ref("shared.pdf"),
      ref("Journal/2026-11-03.md"),
    ]),
    file("Child.md", "", [ref("Root.md"), ref("Grand.md")]),
    file("Grand.md", "", [ref("Deep.md")]),
    file("Deep.md"),
    file("Hub.md", "", [ref("Hidden.md")]),
    file("Hidden.md"),
    file("a.pdf"),
    file("shared.pdf"),
    file("Journal/2026-11-03.md"),
    file("Outside.md", "", [ref("Root.md"), ref("Hub.md"), ref("shared.pdf")]),
  ];
  const result = discoverCollection("Root.md", files, { sharedThreshold: 2 });
  const byPath = new Map(result.candidates.map((c) => [c.path, c]));
  assert.equal(byPath.get("Root.md")?.selected, true);
  assert.equal(byPath.get("a.pdf")?.selected, true);
  assert.equal(byPath.get("shared.pdf")?.selected, false);
  assert.equal(byPath.get("Hub.md")?.shared, true);
  assert.equal(byPath.get("Journal/2026-11-03.md")?.selected, false);
  assert.equal(byPath.get("Grand.md")?.depth, 2);
  assert.equal(byPath.has("Hidden.md"), false);
  assert.equal(byPath.has("Deep.md"), false);
  assert.deepEqual(result.backlinks, ["Outside.md"]);
  assert.match(result.warnings.join(" "), /depth/i);
  assert.equal(result.truncated, true);
  assert.equal(
    new Set(result.candidates.map((c) => c.path)).size,
    result.candidates.length,
  );
  const capped = discoverCollection("Root.md", files, { maxDepth: 8, maxFiles: 2 });
  assert.equal(capped.candidates.length, 2);
  assert.match(capped.warnings.join(" "), /maxFiles/);
  assert.equal(capped.truncated, true);
  assert.deepEqual(discoverCollection("Trash/no.md", files).candidates, []);
});

const source: SpaceConfig = { id: "personal", label: "Personal", prefix: "" };
const destination: SpaceConfig = { id: "ksp", label: "KSP", prefix: "/ksp" };
function rewriteOptions(location: "source" | "destination") {
  return {
    selected: new Set(["Moved.md", "Root.md"]),
    source,
    destination,
    location,
    origin: "https://notes.example",
    sourcePaths: new Set(["Moved.md", "Kept.md", "Root.md"]),
    destinationPaths: new Set<string>(),
  };
}
function linked(text: string, target: string, extra: Partial<LinkRef> = {}) {
  return file("Root.md", text, [
    { from: 0, to: text.length, target, kind: "page", syntax: "wiki", ...extra },
  ]);
}

test("optional link-edit collection exposes only exact narrow source spans", () => {
  const result = rewriteLinks(linked("[[Moved]]", "Moved.md"), {
    ...rewriteOptions("source"),
    collectEdits: true,
  });
  assert.deepEqual(result.edits, [
    { from: 0, to: 9, text: "[Moved](https://notes.example/ksp/Moved)" },
  ]);
});

test("rewrite applies all four selection cases and canonical alias targets", () => {
  assert.equal(typeof rewriteLinks, "function");
  assert.equal(
    rewriteLinks(linked("[[Alias|label]]", "Moved.md"), rewriteOptions("destination"))
      .text,
    "[[/Moved|label]]",
  );
  assert.equal(
    rewriteLinks(linked("[[Kept]]", "Kept.md"), rewriteOptions("destination")).text,
    "[Kept](https://notes.example/Kept)",
  );
  assert.equal(
    rewriteLinks(linked("[[Moved]]", "Moved.md"), rewriteOptions("source")).text,
    "[Moved](https://notes.example/ksp/Moved)",
  );
  assert.deepEqual(
    rewriteLinks(linked("[[Kept]]", "Kept.md"), rewriteOptions("source")),
    { text: "[[Kept]]", changes: 0, warnings: [] },
  );
});

test("rewrite encodes fragments and URI segments, preserves images and escapes wiki labels", () => {
  const target = "Folder/A (100%) ü.md";
  const options = rewriteOptions("destination");
  options.sourcePaths.add(target);
  const f = linked(
    "[[Alias|<img src=x onerror=alert(1)> [evil](javascript:x)]]",
    target,
    { fragment: "Part%20one/é" },
  );
  const result = rewriteLinks(f, options);
  assert.equal(
    result.text,
    "[&lt;img src=x onerror=alert\\(1\\)&gt; \\[evil\\]\\(javascript:x\\)](https://notes.example/Folder/A%20(100%25)%20%C3%BC#Part%2520one%2F%C3%A9)".replace(
      "%20(100%25)",
      "%20%28100%25%29",
    ),
  );
  const image = linked('![A **label**](old.png "title")', "img/photo (1).png", {
    kind: "image",
    syntax: "markdown",
    fragment: "#spot",
  });
  options.sourcePaths.add("img/photo (1).png");
  assert.equal(
    rewriteLinks(image, options).text,
    '![A **label**](https://notes.example/img/photo%20%281%29.png#spot "title")',
  );
  const code = "`[[Kept]]`\n[[Kept]]\n```\n[[Kept]]\n```";
  const offset = code.indexOf("[[Kept]]", 5);
  const real = file("Root.md", code, [
    { from: offset, to: offset + 8, target: "Kept.md", kind: "page", syntax: "wiki" },
  ]);
  assert.equal(
    rewriteLinks(real, options).text,
    "`[[Kept]]`\n[Kept](https://notes.example/Kept)\n```\n[[Kept]]\n```",
  );
});

test("rewrite verifies missing targets, skips ambiguity and embeds, and rejects stale or overlapping spans", () => {
  const options = rewriteOptions("destination");
  options.destinationPaths.add("Other.md");
  assert.equal(
    rewriteLinks(linked("[[Other]]", "Other.md"), options).text,
    "[Other](https://notes.example/ksp/Other)",
  );
  for (const f of [
    linked("[[Absent]]", "Absent.md"),
    linked("[[Moved]]", "Moved.md", { ambiguous: true }),
    linked("![[Moved]]", "Moved.md", { kind: "embed" }),
  ]) {
    const result = rewriteLinks(f, options);
    assert.equal(result.text, f.text);
    assert.ok(result.warnings.length > 0);
  }
  for (const f of [
    linked("not a link", "Moved.md"),
    linked("[[Moved]]", "Moved.md", { from: -1 }),
    linked("[[Moved]]", "Moved.md", { to: 500 }),
  ]) {
    assert.throws(() => rewriteLinks(f, options), /stale|range|span/i);
  }
  const overlap = linked("[[Moved]]", "Moved.md");
  overlap.links!.push({ ...overlap.links![0] });
  assert.throws(() => rewriteLinks(overlap, options), /overlap|span/i);
});

test("merge unions complete sections, retains divergent prose with provenance and is retry-idempotent", () => {
  assert.equal(typeof mergeMarkdown, "function");
  const src = "# Shared\nSame.\n\n# Source\nSource words.\n";
  const dest = "# Shared\nSame.\n\n# Destination\nDestination words.\n";
  const first = mergeMarkdown(src, dest, "personal/Root");
  assert.equal(first.conflicts.length, 0);
  assert.equal(first.changed, true);
  assert.ok(first.text.startsWith(dest));
  assert.equal(first.text.match(/# Shared/g)?.length, 1);
  assert.ok(first.text.includes("# Source\nSource words."));
  assert.ok(first.text.includes("personal/Root"));
  assert.deepEqual(mergeMarkdown(src, first.text, "personal/Root"), {
    text: first.text,
    changed: false,
    warnings: [],
    conflicts: [],
  });
  assert.equal(mergeMarkdown("Same", "Same").changed, false);
  const prose = mergeMarkdown("Source version.", "Destination version.");
  assert.ok(prose.text.includes("Source version."));
  assert.ok(prose.text.includes("Destination version."));
  assert.match(prose.text, /provenance/i);
  assert.equal(mergeMarkdown("Source version.", prose.text).changed, false);
});

test("merge reconciles simple metadata without duplicate frontmatter and blocks unsafe YAML", () => {
  const src =
    '---\naliases: ["Other", "Shared"]\ntags: research\nstatus: active\nnew: 3\n---\n# Source\nWords.\n';
  const dest =
    '---\naliases: ["First", "Shared"]\ntags: ["existing"]\nstatus: active\n---\n# Destination\nKept.\n';
  const result = mergeMarkdown(src, dest);
  assert.deepEqual(result.conflicts, []);
  assert.match(result.text, /aliases: \["First", "Shared", "Other"\]/);
  assert.match(result.text, /tags: \["existing", "research"\]/);
  assert.match(result.text, /new: 3/);
  assert.equal(result.text.match(/^---$/gm)?.length, 2);
  assert.equal(mergeMarkdown(src, result.text).changed, false);
  for (const bad of [
    "---\nstatus: inactive\n---\nOther",
    "---\nkey: &anchor value\n---\nOther",
    "---\nkey: |\n  block\n---\nOther",
    "---\nkey: { nested: true }\n---\nOther",
    "---\nkey: one\nkey: two\n---\nOther",
  ]) {
    const blocked = mergeMarkdown(bad, dest);
    assert.ok(blocked.conflicts.length > 0, bad);
    assert.equal(blocked.changed, false);
    assert.equal(blocked.text, dest);
  }
  const identical = "---\nstatus: active\n---\n";
  assert.deepEqual(
    mergeMarkdown(identical + "# New\nnew", identical + "# Old\nold").conflicts,
    [],
  );
});

test("merge preserves fenced code and CRLF, rejects duplicate anchors and unclosed fences", () => {
  const src = "# New\r\n```md\r\n# Not a heading\r\n^duplicate\r\n```\r\n";
  const dest = "# Old\r\nOld.\r\n";
  const first = mergeMarkdown(src, dest);
  assert.deepEqual(first.conflicts, []);
  assert.ok(first.text.includes(src));
  assert.equal(first.text.replace(/\r\n/g, "").includes("\n"), false);
  assert.equal(mergeMarkdown(src, first.text).changed, false);
  for (const [s, d] of [
    ["# Same\nSource", "# Same\nDestination"],
    ["Source ^block", "Destination ^block"],
    ['<a id="same"></a>\nSource', '<a id="same"></a>\nDest'],
    ["```\nUnclosed", "Dest"],
    ["Source", "~~~\nUnclosed"],
  ]) {
    const blocked = mergeMarkdown(s, d);
    assert.ok(blocked.conflicts.length > 0, s);
    assert.equal(blocked.text, d);
    assert.equal(blocked.changed, false);
  }
});

test("merge recognizes paragraph-boundary subsumption without mistaking code or prefixes for content", () => {
  assert.equal(mergeMarkdown("# A\nOne.", "# A\nOne.\n\nMore.").changed, false);
  assert.equal(mergeMarkdown("One.", "Prelude.\n\nOne.\n\nAfter.").changed, false);
  const codeOnly = "```md\n\nOne.\n\n```";
  assert.equal(mergeMarkdown("One.", codeOnly).changed, true);
  assert.equal(mergeMarkdown("One", "One hundred").changed, true);
  const d = '---\ntags: ["a", "a"]\n---\nDest';
  const result = mergeMarkdown('---\ntags: ["b"]\n---\nSource', d);
  assert.match(result.text, /tags: \["a", "b"\]/);
  for (const s of [
    "<!-- Space Move: begin imported section -->\nHidden",
    "<!-- Space Move provenance: Hidden -->\nText",
  ]) {
    const blocked = mergeMarkdown(s, "Destination");
    assert.ok(blocked.conflicts.length > 0);
    assert.equal(blocked.text, "Destination");
  }
});

test("rewrite preserves implicit alias labels and rejects spans covering multiple links", () => {
  const options = rewriteOptions("destination");
  assert.equal(
    rewriteLinks(linked("[[Alias]]", "Moved.md"), options).text,
    "[[/Moved|Alias]]",
  );
  for (const [raw, syntax] of [
    ["[[Moved]] text [[Kept]]", "wiki"],
    ["[Moved](Moved)[Kept](Kept)", "markdown"],
    ["[Moved](Moved) text [Kept](Kept)", "markdown"],
  ] as const) {
    assert.throws(
      () => rewriteLinks(linked(raw, "Moved.md", { syntax }), options),
      /span|range|stale/i,
    );
  }
  const result = rewriteLinks(
    linked("[**Move**](old)", "Moved.md", { syntax: "markdown" }),
    rewriteOptions("source"),
  );
  assert.equal(result.text, "[**Move**](https://notes.example/ksp/Moved)");
});

test("merge safely unions simple block aliases and detects setext heading collisions", () => {
  const src =
    "---\naliases:\n  - Second\n  - Shared\ntags:\n- new\n---\n# Source\nSource";
  const dest = "---\naliases:\n  - First\n  - Shared\n---\n# Destination\nDestination";
  const result = mergeMarkdown(src, dest);
  assert.deepEqual(result.conflicts, []);
  assert.match(result.text, /aliases: \["First", "Shared", "Second"\]/);
  assert.match(result.text, /tags:\n- new/);
  assert.equal(mergeMarkdown(src, result.text).changed, false);
  const blocked = mergeMarkdown("Title\n=====\nSource", "Title\n=====\nDestination");
  assert.ok(blocked.conflicts.length > 0);
  assert.equal(blocked.changed, false);
});

test("rewrite preserves SilverBullet heading, named-anchor and position delimiters", () => {
  for (const fragment of ["#Heading", "$anchor", "@123", "@L10C2"]) {
    const moved = rewriteLinks(
      linked("[[Moved" + fragment + "]]", "Moved.md", { fragment }),
      rewriteOptions("destination"),
    );
    assert.equal(moved.text, "[[/Moved" + fragment + "]]");
    const cross = rewriteLinks(
      linked("[[Moved" + fragment + "]]", "Moved.md", { fragment }),
      rewriteOptions("source"),
    );
    assert.ok(cross.text.endsWith("https://notes.example/ksp/Moved" + fragment + ")"));
  }
});

test("internal wiki references retain literal spaces, Unicode and percent sequences", () => {
  const options = rewriteOptions("destination");
  const target = "Folder/A (100%) ü.md";
  options.sourcePaths.add(target);
  options.selected.add(target);
  const fragment = "#Part%20one/é";
  const result = rewriteLinks(
    linked("[[Folder/A (100%) ü" + fragment + "]]", target, { fragment }),
    options,
  );
  assert.equal(result.text, "[[/Folder/A (100%) ü" + fragment + "]]");
});

test("external URL headings encode literal percent sequences exactly once", () => {
  for (const syntax of ["wiki", "markdown"] as const) {
    const raw =
      syntax === "wiki"
        ? "[[Moved#100%20 literal é]]"
        : "[label](Moved#100%2520%20literal%20%C3%A9)";
    const result = rewriteLinks(
      linked(raw, "Moved.md", { syntax, fragment: "#100%20 literal é" }),
      rewriteOptions("source"),
    );
    const url = new URL(result.text.slice(result.text.lastIndexOf("](") + 2, -1));
    assert.equal(decodeURIComponent(url.hash.slice(1)), "100%20 literal é");
  }
});

test("merge never coerces implicit YAML values in aliases or tags into strings", () => {
  const dest = '---\ntags: ["existing"]\n---\nDestination';
  for (const value of ["true", "FALSE", "null", "~", "42", "1.5", "0x10", ".inf"]) {
    const result = mergeMarkdown(`---\ntags: [${value}]\n---\nSource`, dest);
    assert.ok(result.conflicts.length > 0, value);
    assert.equal(result.text, dest);
    assert.equal(result.changed, false);
  }
});

test("discovery fails closed for duplicate snapshot paths instead of choosing a root", () => {
  const result = discoverCollection("Root.md", [
    file("Root.md", "", [ref("First.md")]),
    file("Root.md", "", [ref("Second.md")]),
    file("First.md"),
    file("Second.md"),
  ]);
  assert.deepEqual(result.candidates, []);
  assert.match(result.warnings.join(" "), /duplicate|ambiguous/i);
});

test("rewrite rejects percent-encoded routing prefixes that browsers normalize elsewhere", () => {
  for (const prefix of [
    "/%2e%2e/ksp",
    "/ksp%2fother",
    "/ksp%5cother",
    "/ksp%3fquery",
  ]) {
    const options = rewriteOptions("source");
    options.destination = { ...destination, prefix };
    assert.throws(
      () => rewriteLinks(linked("[[Moved]]", "Moved.md"), options),
      /prefix/i,
    );
  }
});

test("SDK reference metacharacters cannot be moved or reinterpreted as a target", () => {
  for (const target of [
    "A#Heading.md",
    "A$anchor.md",
    "A@123.md",
    "A|label.md",
    "^A.md",
    "A<unsafe>.md",
    "A.txt.md",
  ]) {
    assert.equal(isManagedPath(target), false, target);
    const root = discoverCollection(target, [file(target)]);
    assert.deepEqual(root.candidates, []);
    const options = rewriteOptions("destination");
    options.sourcePaths.add(target);
    options.selected.add(target);
    const result = rewriteLinks(linked("[[Alias]]", target), options);
    assert.equal(result.text, "[[Alias]]");
    assert.match(result.warnings.join(" "), /unsafe/i);
  }
});

test("routing prefixes cannot break out of a generated Markdown destination", () => {
  const options = rewriteOptions("source");
  options.destination = { ...destination, prefix: "/ksp)[x](javascript:alert(1))" };
  assert.throws(
    () => rewriteLinks(linked("[[Moved]]", "Moved.md"), options),
    /prefix/i,
  );
});

test("internal wiki rewriting retains support for legacy bare heading fragments", () => {
  const result = rewriteLinks(
    linked("[[Moved#Part one]]", "Moved.md", { fragment: "Part one" }),
    rewriteOptions("destination"),
  );
  assert.equal(result.text, "[[/Moved#Part one]]");
});

test("merge blocks duplicate SilverBullet dollar anchors", () => {
  const result = mergeMarkdown("Source $anchor", "Destination $anchor");
  assert.ok(result.conflicts.length > 0);
  assert.equal(result.text, "Destination $anchor");
  assert.equal(result.changed, false);
});

test("managed paths exclude reserved namespaces and unsafe components", () => {
  assert.equal(typeof isManagedPath, "function");
  for (const path of [
    "",
    "/A.md",
    "../A.md",
    "A/../B.md",
    "./A.md",
    "A/.x.md",
    "A//B.md",
    "C:\\A.md",
    "a\\b.md",
    "A\u0000.md",
    "Library/a.md",
    "Repositories/a",
    "Trash/a",
    "_plug/x",
    "_config/x",
    "Space Moves/log.md",
  ]) {
    assert.equal(isManagedPath(path), false, path);
  }
  for (const path of ["A.md", "Topic/a.pdf", "My notes/Hello.md", "Libraryish/A.md"])
    assert.equal(isManagedPath(path), true, path);
});
