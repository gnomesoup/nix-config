import { expect, it } from "vitest";
import { parse } from "../../client/markdown_parser/parse_tree.ts";
import { extendedMarkdownLanguage } from "../../client/markdown_parser/parser.ts";
import {
  DEFAULT_CONFIG,
  type FileSnapshot,
  type SpaceId,
  type Transport,
} from "./types.ts";
import { inspectSpaces, planMove, restoreMovePlan } from "./controller.ts";
import { executeMove } from "./engine.ts";

const encode = (text: string) => new TextEncoder().encode(text);
function fixture() {
  const files = new Map<string, FileSnapshot>();
  const put = (space: SpaceId, path: string, text: string) =>
    files.set(`${space}:${path}`, {
      space,
      path,
      text,
      bytes: encode(text),
      size: encode(text).length,
      revision: '"fixture"',
    });
  put("personal", "Root.md", "# Root\n[[Keep]]\n");
  put("personal", "Keep.md", "Personal content\n");
  put("personal", "Retained.md", "[[Root|work]]\n");
  put("ksp", "Root.md", "# Destination\nExisting text\n");
  let writes = 0;
  const transport: Transport = {
    list: async (space) =>
      [...files.values()]
        .filter((file) => file.space === space)
        .map(({ path, size }) => ({ path, size })),
    read: async (space, path) => structuredClone(files.get(`${space}:${path}`) ?? null),
    write: async (space, path, bytes, policy) => {
      const key = `${space}:${path}`;
      const before = files.get(key);
      if ("create" in policy ? !!before : before?.revision !== policy.revision)
        throw new Error("Revision conflict");
      writes++;
      const result: FileSnapshot = {
        space,
        path,
        bytes: new Uint8Array(bytes),
        size: bytes.length,
        revision: `"write-${writes}"`,
        text: path.endsWith(".md") ? new TextDecoder().decode(bytes) : undefined,
      };
      files.set(key, result);
      return structuredClone(result);
    },
    remove: async (space, path, revision) => {
      const key = `${space}:${path}`;
      if (files.get(key)?.revision !== revision) throw new Error("Revision conflict");
      writes++;
      files.delete(key);
    },
  };
  return { files, transport, writes: () => writes, put };
}
const markdown = async (text: string) => parse(extendedMarkdownLanguage, text);

it("previews a partial-selection merge and retained-page link edit without mutation", async () => {
  const sample = fixture();
  const scan = await inspectSpaces(
    sample.transport,
    DEFAULT_CONFIG,
    "personal",
    markdown,
    { root: "Root.md", expectedText: "# Root\n[[Keep]]\n" },
  );
  const reviewed = await planMove(sample.transport, scan, new Set(["Root.md"]), {
    origin: "https://notes.example",
    id: "fixture-operation",
    createdAt: "2026-11-03T12:00:00Z",
  });
  expect(reviewed.plan.items).toHaveLength(1);
  expect(new TextDecoder().decode(reviewed.plan.items[0].output)).toContain(
    "Existing text",
  );
  expect(new TextDecoder().decode(reviewed.plan.items[0].output)).toContain(
    "https://notes.example/Keep",
  );
  expect(reviewed.plan.patches.map((patch) => patch.before.path)).toEqual([
    "Retained.md",
  ]);
  expect(new TextDecoder().decode(reviewed.plan.patches[0].output)).toContain(
    "https://notes.example/ksp/Root",
  );
  expect(sample.writes()).toBe(0);
});

it("collects reversible journal link edits without copying unrelated text into metadata", async () => {
  const sample = fixture();
  const original = "\uFEFFPersonal journal text\r\n[[Root|work]] and [[Root]]\r\n";
  sample.put("personal", "Journal/2020-01-01.md", original);
  const scan = await inspectSpaces(
    sample.transport,
    DEFAULT_CONFIG,
    "personal",
    markdown,
    { origin: "https://notes.example" },
  );
  const reviewed = await planMove(sample.transport, scan, new Set(["Root.md"]), {
    origin: "https://notes.example",
  });
  expect(reviewed.plan).toMatchObject({ origin: "https://notes.example" });
  const patch = reviewed.plan.patches.find(
    (item) => item.before.path === "Journal/2020-01-01.md",
  )!;
  expect(patch.inverseEdits).toHaveLength(2);
  let restored = new TextDecoder("utf-8", { ignoreBOM: true }).decode(patch.output);
  for (const edit of [...patch.inverseEdits!].sort((a, b) => b.from - a.from)) {
    expect(restored.slice(edit.from, edit.to)).toBe(edit.after);
    restored = restored.slice(0, edit.from) + edit.before + restored.slice(edit.to);
  }
  expect(restored).toBe(original);
  expect(JSON.stringify(patch.inverseEdits)).not.toContain("Personal journal text");
});

it("scans active managed Markdown and blocks moves that would break its references", async () => {
  for (const path of ["_config/Retained.md", "Library/Retained.md"]) {
    const sample = fixture();
    sample.put("personal", path, "[[Root]]\n");
    const scan = await inspectSpaces(
      sample.transport,
      DEFAULT_CONFIG,
      "personal",
      markdown,
      { origin: "https://notes.example" },
    );
    expect(scan.snapshots.get("personal")!.has(path)).toBe(true);
    await expect(
      planMove(sample.transport, scan, new Set(["Root.md"]), {
        origin: "https://notes.example",
      }),
    ).rejects.toThrow(/managed/i);
    expect(sample.writes()).toBe(0);
  }
});

it("blocks unsupported incoming references instead of approving a broken source deletion", async () => {
  for (const text of [
    "[[^Root]]\n",
    "[work][root]\n\n[root]: /Root\n",
    "https://notes.example/Root\n",
    "<https://notes.example/Root>\n",
    "[work](https://notes.example/Root?foo=1)\n",
    '---\nrelated: "[[Root]]"\n---\n',
  ]) {
    const sample = fixture();
    sample.put("personal", "Unsupported.md", text);
    const scan = await inspectSpaces(
      sample.transport,
      DEFAULT_CONFIG,
      "personal",
      markdown,
      { origin: "https://notes.example" },
    );
    await expect(
      planMove(sample.transport, scan, new Set(["Root.md"]), {
        origin: "https://notes.example",
      }),
    ).rejects.toThrow(/unsupported|ambiguous/i);
    expect(sample.writes()).toBe(0);
  }
});

it("restores the frozen current-day journal patch after its own activity was appended", async () => {
  const sample = fixture();
  const day = new Intl.DateTimeFormat("en-CA", {
    timeZone: "America/New_York",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).format(new Date());
  const path = `Journal/${day}.md`;
  sample.put("personal", path, "\uFEFFPrivate journal prose\r\n[[Root]]\r\n");
  const scan = await inspectSpaces(
    sample.transport,
    DEFAULT_CONFIG,
    "personal",
    markdown,
    { origin: "https://notes.example" },
  );
  const reviewed = await planMove(sample.transport, scan, new Set(["Root.md"]), {
    origin: "https://notes.example",
    id: "journal-restart",
  });
  const result = await executeMove(sample.transport, reviewed.plan);
  expect(result.status).toBe("complete");
  const writes = sample.writes();
  const rebuilt = await restoreMovePlan(
    sample.transport,
    DEFAULT_CONFIG,
    result.manifest,
    markdown,
    "https://notes.example",
  );
  const resumed = await executeMove(sample.transport, rebuilt.plan, {
    manifest: result.manifest,
  });
  expect(resumed.status).toBe("complete");
  expect(sample.writes()).toBe(writes);
  expect(sample.files.get(`personal:${path}`)!.text).toContain("Private journal prose");
});

it("restores a moved binary from its verified archive after browser restart", async () => {
  const sample = fixture();
  const bytes = new Uint8Array([0, 255, 10, 13]);
  sample.files.set("personal:assets/a.pdf", {
    space: "personal",
    path: "assets/a.pdf",
    bytes,
    size: bytes.length,
    revision: '"binary"',
  });
  const scan = await inspectSpaces(
    sample.transport,
    DEFAULT_CONFIG,
    "personal",
    markdown,
    { origin: "https://notes.example" },
  );
  const reviewed = await planMove(
    sample.transport,
    scan,
    new Set(["Root.md", "assets/a.pdf"]),
    { origin: "https://notes.example", id: "binary-restart" },
  );
  const result = await executeMove(sample.transport, reviewed.plan);
  expect(result.status).toBe("complete");
  const rebuilt = await restoreMovePlan(
    sample.transport,
    DEFAULT_CONFIG,
    result.manifest,
    markdown,
    "https://notes.example",
  );
  expect(
    rebuilt.plan.items.find((item) => item.source.path === "assets/a.pdf")!.source
      .bytes,
  ).toEqual(bytes);
  expect(
    (await executeMove(sample.transport, rebuilt.plan, { manifest: result.manifest }))
      .status,
  ).toBe("complete");
});

it("rebuilds a body-free operation after restart without re-merging or replaying writes", async () => {
  const sample = fixture();
  const scan = await inspectSpaces(
    sample.transport,
    DEFAULT_CONFIG,
    "personal",
    markdown,
    { origin: "https://notes.example" },
  );
  const reviewed = await planMove(sample.transport, scan, new Set(["Root.md"]), {
    origin: "https://notes.example",
    id: "restart",
    createdAt: "2026-11-03T12:00:00Z",
  });
  const moved = await executeMove(sample.transport, reviewed.plan);
  expect(moved.status).toBe("complete");
  const count = sample.writes();
  const rebuilt = await restoreMovePlan(
    sample.transport,
    DEFAULT_CONFIG,
    moved.manifest,
    markdown,
    "https://notes.example",
  );
  expect(rebuilt.plan.items[0].output).toEqual(reviewed.plan.items[0].output);
  expect(rebuilt.plan.patches.map((patch) => patch.before.path)).toEqual([
    "Retained.md",
  ]);
  const resumed = await executeMove(sample.transport, rebuilt.plan, {
    manifest: moved.manifest,
  });
  expect(resumed.status).toBe("complete");
  expect(sample.writes()).toBe(count);
});
