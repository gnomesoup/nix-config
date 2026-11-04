import { describe, expect, it } from "vitest";
import { extendedMarkdownLanguage } from "../../client/markdown_parser/parser.ts";
import { parse } from "../../client/markdown_parser/parse_tree.ts";
import { parseLinks } from "./parser.ts";

function links(path: string, text: string, paths: string[]) {
  return parseLinks(path, text, parse(extendedMarkdownLanguage, text), paths);
}

function contextualLinks(
  text: string,
  currentSpace: "personal" | "ksp" = "personal",
  paths = ["Root.md", "assets/a b.pdf", "Root%20Name.md"],
) {
  return parseLinks(
    "Journal/Today.md",
    text,
    parse(extendedMarkdownLanguage, text),
    paths,
    {
      origin: "https://notes.example",
      currentSpace,
      spaces: [
        { id: "personal", label: "Personal", prefix: "" },
        { id: "ksp", label: "KSP", prefix: "/ksp" },
      ],
      paths: new Map([
        ["personal", paths],
        ["ksp", paths],
      ]),
    },
  );
}

describe("upstream Markdown parser adapter", () => {
  it.each(["personal", "ksp"] as const)(
    "tracks each reused reference definition once in %s",
    (space) => {
      const text =
        "Intro\r\n[work][root] [again][root]\r\n\r\n[root]: /Root#Header\r\n";
      const result = contextualLinks(text, space);
      expect(result.links).toHaveLength(1);
      expect(result.links[0]).toMatchObject({
        target: "Root.md",
        targetSpace: space,
        kind: "page",
        fragment: "#Header",
        warning: expect.any(String),
      });
      expect(text.slice(result.links[0].from, result.links[0].to)).toBe(
        "[root]: /Root#Header",
      );
    },
  );
  it.each(["personal", "ksp"] as const)(
    "tracks naked URLs and autolinks to either prefix from %s without duplicates",
    (currentSpace) => {
      const forms = [
        "https://notes.example/Root#Header",
        "<https://notes.example/ksp/Root#Header>",
        "<https://notes.example/assets/a%20b.pdf>",
        "https://notes.example/ksp/Root",
      ];
      const text =
        "Intro\r\n" +
        forms.join("\r\n") +
        "\r\n[inline](https://notes.example/Root)\r\n";
      const result = contextualLinks(text, currentSpace);
      expect(result.links).toHaveLength(5);
      expect(result.links.map((link) => [link.target, link.targetSpace])).toEqual([
        ["Root.md", "personal"],
        ["Root.md", "ksp"],
        ["assets/a b.pdf", "personal"],
        ["Root.md", "ksp"],
        ["Root.md", "personal"],
      ]);
      result.links.slice(0, 4).forEach((link, i) => {
        expect(link.warning).toEqual(expect.any(String));
        expect(text.slice(link.from, link.to)).toBe(forms[i]);
      });
      expect(result.links[0].fragment).toBe("#Header");
      expect(result.links[1].fragment).toBe("#Header");
      expect(result.links[2].kind).toBe("document");
      expect(result.links[4].warning).toBeUndefined();
    },
  );

  it.each(["personal", "ksp"] as const)(
    "classifies query-bearing inline URLs without making them rewritable from %s",
    (currentSpace) => {
      const forms = [
        "[work](https://notes.example/Root?mode=edit#Head%20One)",
        "[work](https://notes.example/ksp/Root?mode=edit#Head%20One)",
      ];
      const text = "Intro\r\n" + forms.join("\r\n") + "\r\n";
      const result = contextualLinks(text, currentSpace);
      expect(result.links).toHaveLength(2);
      result.links.forEach((link, i) => {
        expect(link).toMatchObject({
          target: "Root.md",
          targetSpace: i ? "ksp" : "personal",
          fragment: "#Head One",
          warning: expect.stringMatching(/query/i),
        });
        expect(text.slice(link.from, link.to)).toBe(forms[i]);
      });
    },
  );

  it.each(["personal", "ksp"] as const)(
    "tracks explicit frontmatter wiki references and metadata references in %s",
    (currentSpace) => {
      const forms = ["[[Root#Header|work]]", "[[^Root]]", "[[assets/a b.pdf]]"];
      const text =
        "---\r\nrelated: '" +
        forms[0] +
        "'\r\nmeta: '" +
        forms[1] +
        "'\r\nfile: '" +
        forms[2] +
        "'\r\n---\r\n`[[Root]]`\r\n[[^Root]]\r\n";
      const result = contextualLinks(text, currentSpace);
      expect(result.links).toHaveLength(4);
      result.links.forEach((link, i) => {
        expect(link.targetSpace).toBe(currentSpace);
        expect(link.warning).toEqual(expect.any(String));
        expect(text.slice(link.from, link.to)).toBe(forms[i] ?? "[[^Root]]");
      });
      expect(result.links.map((link) => link.target)).toEqual([
        "Root.md",
        "Root.md",
        "assets/a b.pdf",
        "Root.md",
      ]);
      expect(result.links[0]).toMatchObject({ fragment: "#Header", label: "work" });
      expect(result.links[2].kind).toBe("document");
    },
  );

  it.each(["personal", "ksp"] as const)(
    "tracks absolute reference definitions for either prefix from %s",
    (currentSpace) => {
      const text =
        "[root]: https://notes.example/Root#Head\r\n\r\n[dest]: https://notes.example/ksp/Root#Head\r\n";
      const result = contextualLinks(text, currentSpace);
      expect(
        result.links.map((link) => [
          link.target,
          link.targetSpace,
          link.fragment,
          !!link.warning,
        ]),
      ).toEqual([
        ["Root.md", "personal", "#Head", true],
        ["Root.md", "ksp", "#Head", true],
      ]);
      expect(result.links.map((link) => text.slice(link.from, link.to))).toEqual(
        text.trimEnd().split("\r\n\r\n"),
      );
    },
  );

  it("decodes URI components once while preserving actual fragment delimiters", () => {
    const text =
      "[one](https://notes.example/Root%2520Name#Head%23Sub) [two](/Root%2520Name#Head%23Sub)";
    const result = contextualLinks(text);
    expect(result.links.map((link) => [link.target, link.fragment])).toEqual([
      ["Root%20Name.md", "#Head#Sub"],
      ["Root%20Name.md", "#Head#Sub"],
    ]);
  });

  it.each(["personal", "ksp"] as const)(
    "warns about malformed encodings and encoded reference delimiters without inventing targets from %s",
    (currentSpace) => {
      for (const prefix of ["", "/ksp"]) {
        for (const suffix of [
          "Root%ZZ",
          "Root%23Header",
          "Root%40L2",
          "%5ERoot",
          "Root%24anchor",
        ]) {
          const text = `[bad](https://notes.example${prefix}/${suffix})`;
          const result = contextualLinks(text, currentSpace);
          expect(result.links, text).toEqual([]);
          expect(result.warnings.length, text).toBeGreaterThan(0);
        }
      }
    },
  );

  it.each(["personal", "ksp"] as const)(
    "classifies angle-wrapped and case-insensitive same-origin URLs, including empty queries, from %s",
    (currentSpace) => {
      const forms = [
        "[angle](<https://notes.example/ksp/Root#Header>)",
        "[case](HTTPS://notes.example/Root#Header)",
        "[empty](https://notes.example/Root?#Header)",
      ];
      const text = forms.join("\r\n");
      const result = contextualLinks(text, currentSpace);
      expect(
        result.links.map((link) => [link.target, link.targetSpace, link.fragment]),
      ).toEqual([
        ["Root.md", "ksp", "#Header"],
        ["Root.md", "personal", "#Header"],
        ["Root.md", "personal", "#Header"],
      ]);
      expect(result.links[2].warning).toMatch(/query/i);
      expect(result.links.map((link) => text.slice(link.from, link.to))).toEqual(forms);
    },
  );

  it.each(["personal", "ksp"] as const)(
    "tracks local query-bearing URLs without treating queries as filenames in %s",
    (currentSpace) => {
      const text =
        "[query](/Root?mode=edit#Header) [empty](/Root?) [relative](../Root?mode=edit) [self](#Header)";
      const result = contextualLinks(text, currentSpace);
      expect(result.links).toHaveLength(3);
      result.links.forEach((link) =>
        expect(link).toMatchObject({
          target: "Root.md",
          targetSpace: currentSpace,
          warning: expect.stringMatching(/query/i),
        }),
      );
      expect(result.links[0].fragment).toBe("#Header");
    },
  );

  it("warns about unsafe control characters without inventing targets", () => {
    for (const suffix of [
      "Root%00",
      "Root#Header%0AInjected",
      "Root#Header%0DInjected",
      "Root%5CChild",
    ]) {
      const text = `[bad](https://notes.example/${suffix})`;
      const result = contextualLinks(text);
      expect(result.links, text).toEqual([]);
      expect(result.warnings.length, text).toBeGreaterThan(0);
    }
  });

  it("ignores unrelated URLs, emails and all code examples", () => {
    const text =
      "https://other.example/Root <https://other.example/Root> <a@b.com> [mail](mailto:a@b.com)\n`https://notes.example/Root <https://notes.example/Root> [[Root]]`\n\n```md\n[[Root]]\n[root]: /Root\nhttps://notes.example/Root\n```\n\n    [[Root]]\n    https://notes.example/Root\n";
    expect(contextualLinks(text).links).toEqual([]);
  });

  it("maps upstream CR-stripped offsets back to exact original CRLF spans", () => {
    const text = "\uFEFFJournal\r\n[[Root|work]] and [[Root]]\r\n";
    const result = links("Journal/2020-01-01.md", text, ["Root.md"]);
    expect(result.links.map((link) => text.slice(link.from, link.to))).toEqual([
      "[[Root|work]]",
      "[[Root]]",
    ]);
  });

  it("resolves wiki links, aliases, relative attachments and fragments without touching code", () => {
    const text =
      "[[Work/Note#Header|label]] [PDF](../assets/a%20b.pdf) `[[Skip]]`\n\n```md\n[[Skip]]\n```\n";
    const result = links("Journal/Today.md", text, [
      "Work/Note.md",
      "assets/a b.pdf",
      "Skip.md",
    ]);
    expect(result.links).toHaveLength(2);
    expect(result.links[0]).toMatchObject({
      target: "Work/Note.md",
      label: "label",
      fragment: "#Header",
      syntax: "wiki",
    });
    expect(result.links[1]).toMatchObject({
      target: "assets/a b.pdf",
      syntax: "markdown",
      kind: "document",
    });
    expect(text.slice(result.links[0].from, result.links[0].to)).toBe(
      "[[Work/Note#Header|label]]",
    );
  });

  it("distinguishes page transclusion, binary images and ambiguous basenames", () => {
    const result = links("Root.md", "![[Page]] ![image](/assets/a.png) [[Same]]", [
      "Page.md",
      "assets/a.png",
      "a/Same.md",
      "b/Same.md",
    ]);
    expect(result.links.map((link) => link.kind)).toEqual(["embed", "image", "page"]);
    expect(result.links[2].ambiguous).toBe(true);
  });

  it("recognizes explicit same-origin cross-space links for reverse moves", () => {
    const text =
      "[back](https://notes.example/ksp/Work/Note#Header) [web](https://other.example/Work/Note)";
    const result = parseLinks(
      "Retained.md",
      text,
      parse(extendedMarkdownLanguage, text),
      ["Retained.md"],
      {
        origin: "https://notes.example",
        currentSpace: "personal",
        spaces: [
          { id: "personal", label: "Personal", prefix: "" },
          { id: "ksp", label: "KSP", prefix: "/ksp" },
        ],
        paths: new Map([
          ["personal", ["Retained.md"]],
          ["ksp", ["Work/Note.md"]],
        ]),
      },
    );
    expect(result.links).toHaveLength(1);
    expect(result.links[0]).toMatchObject({
      target: "Work/Note.md",
      targetSpace: "ksp",
      fragment: "#Header",
    });
  });
});
