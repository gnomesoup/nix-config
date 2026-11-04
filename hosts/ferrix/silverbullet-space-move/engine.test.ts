import test from "node:test";
import assert from "node:assert/strict";
import { executeMove, stripJournalEntryCandidates } from "./engine.ts";
import type { MovePlan, MoveManifest } from "./engine.ts";
import type { FileSnapshot, SpaceId, Transport, WritePolicy } from "./types.ts";

const bytes = (text: string) => new TextEncoder().encode(text);
const text = (data: Uint8Array) => new TextDecoder().decode(data);
const key = (space: SpaceId, path: string) => `${space}:${path}`;
class MemoryTransport implements Transport {
  files = new Map<string, FileSnapshot>();
  mutations: string[] = [];
  nextRevision = 0;
  hook?: (action: string, space: SpaceId, path: string) => void;
  seed(space: SpaceId, path: string, content: string | Uint8Array): FileSnapshot {
    const data = typeof content === "string" ? bytes(content) : content;
    const file = {
      space,
      path,
      bytes: data.slice(),
      size: data.length,
      revision: `r${++this.nextRevision}`,
    };
    this.files.set(key(space, path), file);
    return structuredClone(file);
  }
  async list(space: SpaceId) {
    return [...this.files.values()].filter((f) => f.space === space);
  }
  async read(space: SpaceId, path: string) {
    this.hook?.("read", space, path);
    return structuredClone(this.files.get(key(space, path)) ?? null);
  }
  async write(space: SpaceId, path: string, data: Uint8Array, policy: WritePolicy) {
    this.hook?.("write", space, path);
    const before = this.files.get(key(space, path));
    if (before?.readOnly) throw new Error("readonly");
    if ("create" in policy ? !!before : before?.revision !== policy.revision)
      throw new Error("revision conflict");
    this.mutations.push(`write ${space}:${path}`);
    return this.seed(space, path, data);
  }
  async remove(space: SpaceId, path: string, revision: string) {
    this.hook?.("remove", space, path);
    if (this.files.get(key(space, path))?.revision !== revision)
      throw new Error("revision conflict");
    this.mutations.push(`remove ${space}:${path}`);
    this.files.delete(key(space, path));
  }
}
function setup() {
  const transport = new MemoryTransport();
  const source = transport.seed("personal", "Topic.md", "selected original");
  const before = transport.seed(
    "personal",
    "Index.md",
    "private unrelated text [[Topic]]",
  );
  const plan: MovePlan = {
    id: "test-move",
    sourceSpace: "personal",
    destinationSpace: "ksp",
    createdAt: "2026-11-03T14:00:00Z",
    items: [{ source, destination: null, output: bytes("selected rewritten") }],
    patches: [{ before, output: bytes("private unrelated text [[ksp/Topic]]") }],
  };
  return { transport, plan };
}

test("rejects unsafe plans before any mutation", async () => {
  const badPaths = [
    "/root.md",
    "../x",
    "a/../x",
    "a/./x",
    "a//x",
    "a/.hidden/x",
    "Library/x",
    "Repositories/x",
    ".client/x",
    "Trash/x",
    "C:/x",
    "a\\\\x",
    "a%2fx",
    "a\nsecret",
    "SETTINGS.md",
    "PLUGS.md",
    "CONFIG.md",
    "_plug/x",
    "_config/x",
    "Space Moves/x",
    "SETTINGS/x.md",
    "Folder/SETTINGS",
    "Folder/SETTINGS/x.md",
  ];
  for (const path of badPaths) {
    const { transport, plan } = setup();
    const original = plan.items[0].source;
    plan.items[0].source = { ...original, path };
    await assert.rejects(executeMove(transport, plan), /invalid|unsafe|managed/i, path);
    assert.equal(transport.mutations.length, 0);
  }
  for (const mutate of [
    (p: MovePlan) => {
      p.destinationSpace = p.sourceSpace;
    },
    (p: MovePlan) => {
      p.id = "../escape";
    },
    (p: MovePlan) => {
      p.items.push(p.items[0]);
    },
    (p: MovePlan) => {
      p.items[0].destinationPath = "Index.md";
      p.destinationSpace = "personal";
    },
  ]) {
    const { transport, plan } = setup();
    mutate(plan);
    await assert.rejects(executeMove(transport, plan));
    assert.equal(transport.mutations.length, 0);
  }
});

test("resumes from uncertain destination, patch, and deletion checkpoints without replaying writes", async () => {
  for (const checkpoint of ["destination", "patch", "cleanup"]) {
    const { transport, plan } = setup();
    let phase = "";
    let fail = true;
    const first = await executeMove(transport, plan, {
      onProgress: (event) => {
        phase = event.phase;
      },
      saveManifest: async (manifest) => {
        const hit =
          checkpoint === "destination"
            ? manifest.items.some((i) => i.destinationVerified)
            : checkpoint === "patch"
              ? manifest.patches.some((p) => p.verified)
              : manifest.items.some((i) => i.sourceRemoved);
        if (hit && fail) {
          fail = false;
          throw new Error("manifest storage unavailable");
        }
      },
    });
    assert.equal(first.status, "partial", phase);
    const writesBefore = transport.mutations.filter((m) =>
      /write (ksp:Topic|personal:Index)/.test(m),
    ).length;
    const resumed = await executeMove(transport, plan, {
      manifest: JSON.parse(JSON.stringify(first.manifest)),
    });
    assert.equal(resumed.status, "complete", checkpoint);
    const writesAfter = transport.mutations.filter((m) =>
      /write (ksp:Topic|personal:Index)/.test(m),
    ).length;
    assert.equal(writesAfter, 2);
    assert.ok(writesAfter >= writesBefore);
    assert.equal(await transport.read("personal", "Topic.md"), null);
    const noops = transport.mutations.length;
    const again = await executeMove(transport, plan, { manifest: resumed.manifest });
    assert.equal(again.status, "complete");
    assert.equal(transport.mutations.length, noops);
  }
});

test("cancellation stops at checkpoints without deleting or pretending rollback", async () => {
  for (const stop of ["before", "archive", "destination", "patch"]) {
    const { transport, plan } = setup();
    const controller = new AbortController();
    if (stop === "before") controller.abort();
    const result = await executeMove(transport, plan, {
      signal: controller.signal,
      onProgress: (event) => {
        if (event.phase === stop) controller.abort();
      },
    });
    assert.equal(result.status, "cancelled", stop);
    assert.ok(await transport.read("personal", "Topic.md"));
    assert.ok(!transport.mutations.some((m) => m.startsWith("remove")));
    if (stop === "before") assert.equal(transport.mutations.length, 0);
    if (stop === "destination") assert.ok(await transport.read("ksp", "Topic.md"));
  }
});

test("refuses binary collisions and transformed binary output before mutation", async () => {
  for (const explicit of [true, false]) {
    const { transport, plan } = setup();
    plan.items[0].source = transport.seed(
      "personal",
      "image.png",
      new Uint8Array([0, 1, 2]),
    );
    plan.items[0].destination = transport.seed(
      "ksp",
      "image.png",
      new Uint8Array([0, 1, 3]),
    );
    plan.items[0].isBinary = explicit;
    plan.items[0].output = plan.items[0].source.bytes;
    await assert.rejects(executeMove(transport, plan), /binary/i);
    assert.equal(transport.mutations.length, 0);
  }
  const { transport, plan } = setup();
  plan.items[0].isBinary = true;
  await assert.rejects(executeMove(transport, plan), /binary/i);
});

test("revalidates all outputs and archives immediately before cleanup", async () => {
  for (const changed of ["destination", "archive", "patch", "source"]) {
    const { transport, plan } = setup();
    let injected = false;
    const result = await executeMove(transport, plan, {
      onProgress: (event) => {
        if (event.phase !== "patch" || injected) return;
        injected = true;
        if (changed === "destination")
          transport.seed("ksp", "Topic.md", "concurrent destination edit");
        if (changed === "archive")
          transport.files.delete(
            key("personal", "Trash/Space Moves/test-move/Topic.md"),
          );
        if (changed === "patch")
          transport.seed("personal", "Index.md", "concurrent patch edit");
        if (changed === "source")
          transport.seed("personal", "Topic.md", "concurrent source edit");
      },
    });
    assert.equal(result.status, "partial", changed);
    assert.ok(await transport.read("personal", "Topic.md"), changed);
    assert.equal(result.counts.removed, 0);
  }
});

test("fails closed on corrupt readback, destination conflict, and readonly backlink", async () => {
  for (const failure of ["corrupt", "conflict", "readonly"]) {
    const { transport, plan } = setup();
    let injected = false;
    transport.hook = (action, space, path) => {
      if (injected) return;
      if (
        failure === "corrupt" &&
        action === "read" &&
        space === "ksp" &&
        path === "Topic.md" &&
        transport.files.has(key(space, path))
      ) {
        injected = true;
        transport.seed(space, path, "corrupt upload");
      }
      if (
        failure === "conflict" &&
        action === "write" &&
        space === "ksp" &&
        path === "Topic.md"
      ) {
        injected = true;
        transport.seed(space, path, "concurrent create");
      }
      if (failure === "readonly" && action === "write" && path === "Index.md") {
        injected = true;
        transport.files.get(key(space, path))!.readOnly = true;
      }
    };
    const result = await executeMove(transport, plan);
    assert.equal(result.status, "partial", failure);
    assert.ok(await transport.read("personal", "Topic.md"));
    assert.ok(result.errors.length);
    assert.equal(result.counts.removed, 0);
  }
});

test("journals only real changes, preserves existing text, and retries logging without replay", async () => {
  const { transport, plan } = setup();
  const day = new Intl.DateTimeFormat("en-CA", {
    timeZone: "America/New_York",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).format(new Date());
  const path = `Journal/${day}.md`;
  transport.seed("personal", path, "# My existing journal\n\nKeep this intact.\n");
  let deny = true;
  transport.hook = (action, space, file) => {
    if (deny && action === "write" && space === "ksp" && file === path)
      throw new Error("journal readonly");
  };
  const first = await executeMove(transport, plan);
  assert.equal(first.status, "partial");
  assert.equal(first.counts.removed, 1);
  const originalMutations = transport.mutations.filter((m) => !m.includes("Journal/"));
  deny = false;
  const resumed = await executeMove(transport, plan, { manifest: first.manifest });
  assert.equal(resumed.status, "complete");
  assert.deepEqual(
    transport.mutations.filter((m) => !m.includes("Journal/")),
    originalMutations,
  );
  const journal = text((await transport.read("personal", path))!.bytes);
  assert.ok(journal.startsWith("# My existing journal\n\nKeep this intact.\n"));
  assert.equal(journal.split("<!-- space-move:test-move -->").length - 1, 1);
  assert.match(journal, /Index\.md/);
  assert.match(journal, /Trash\/Space Moves/);

  const untouched = setup();
  untouched.transport.seed(
    "personal",
    "Trash/Space Moves/test-move/Topic.md",
    "unrelated archive bytes",
  );
  const failed = await executeMove(untouched.transport, untouched.plan);
  assert.equal(failed.status, "partial");
  assert.equal(untouched.transport.mutations.length, 0);
  assert.equal(failed.manifest.journals.length, 0);
});

test("resume conflicts return partial reports without clobbering remote changes", async () => {
  const { transport, plan } = setup();
  const controller = new AbortController();
  const partial = await executeMove(transport, plan, {
    signal: controller.signal,
    onProgress: (event) => {
      if (event.phase === "destination") controller.abort();
    },
  });
  transport.seed("personal", "Topic.md", "new source edit after interruption");
  const mutations = transport.mutations.length;
  const resumed = await executeMove(transport, plan, { manifest: partial.manifest });
  assert.equal(resumed.status, "partial");
  assert.equal(
    text((await transport.read("personal", "Topic.md"))!.bytes),
    "new source edit after interruption",
  );
  assert.equal(transport.mutations.length, mutations);
});

test("manifest binds the complete plan and stores only explicitly permitted inverse link metadata", async () => {
  const { transport, plan } = setup();
  const after = "[[ksp/Topic]]";
  const from = text(plan.patches[0].output).indexOf(after);
  plan.patches[0].inverseEdits = [
    {
      from,
      to: from + after.length,
      before: "[[Topic]]",
      after,
      unselectedBody: "SECRET WHOLE PAGE",
    } as any,
  ];
  const controller = new AbortController();
  const first = await executeMove(transport, plan, {
    signal: controller.signal,
    onProgress: (event) => {
      if (event.phase === "archive") controller.abort();
    },
  });
  assert.ok(!JSON.stringify(first.manifest).includes("SECRET WHOLE PAGE"));
  assert.ok(!JSON.stringify(first.manifest).includes("private unrelated text"));
  assert.equal(first.manifest.patches[0].inverseEdits![0].before, "[[Topic]]");
  const changedPlan = structuredClone(plan);
  changedPlan.createdAt = "2026-11-04T14:00:00Z";
  await assert.rejects(
    executeMove(transport, changedPlan, { manifest: first.manifest }),
    /manifest/i,
  );
  plan.patches[0].inverseEdits![0].before = "complete unrelated page body";
  await assert.rejects(executeMove(transport, plan), /inverse|link/i);
});

test("inspects uncertain write and delete responses before reporting counts or retrying", async () => {
  for (const stage of ["archive", "destination", "patch", "remove"]) {
    const { transport, plan } = setup();
    const write = transport.write.bind(transport);
    const remove = transport.remove.bind(transport);
    let inject = true;
    transport.write = async (space, path, data, policy) => {
      const file = await write(space, path, data, policy);
      const hit =
        stage === "archive"
          ? path.includes("Trash/")
          : stage === "destination"
            ? space === "ksp" && path === "Topic.md"
            : stage === "patch" && path === "Index.md";
      if (inject && hit) {
        inject = false;
        throw new Error("response lost after successful write");
      }
      return file;
    };
    transport.remove = async (...args) => {
      await remove(...args);
      if (inject && stage === "remove") {
        inject = false;
        throw new Error("response lost after successful deletion");
      }
    };
    const first = await executeMove(transport, plan);
    assert.equal(first.status, "partial", stage);
    assert.ok(
      first.manifest.changes.some((c) => c.kind === stage),
      stage,
    );
    if (stage === "destination") assert.equal(first.counts.destinations, 1);
    if (stage === "patch") assert.equal(first.counts.patches, 1);
    if (stage === "remove") assert.equal(first.counts.removed, 1);
    const before = transport.mutations.filter((m) => !m.includes("Journal/")).length;
    const resumed = await executeMove(transport, plan, { manifest: first.manifest });
    assert.equal(resumed.status, "complete", stage);
    const all = transport.mutations.filter((m) => !m.includes("Journal/"));
    assert.equal(new Set(all).size, all.length, stage);
    assert.ok(all.length >= before);
  }
});

test("archives both originals before a merge and does not trust mutable caller plan data", async () => {
  for (const output of ["merged result", "destination original"]) {
    const { transport, plan } = setup();
    plan.items[0].destination = transport.seed(
      "ksp",
      "Topic.md",
      "destination original",
    );
    plan.items[0].output = bytes(output);
    const result = await executeMove(transport, plan, {
      onProgress: (event) => {
        if (event.phase === "archive") {
          plan.items[0].source.path = "../escape";
          plan.items[0].output.fill(0);
        }
      },
    });
    assert.equal(result.status, "complete");
    assert.equal(
      text(
        (await transport.read("ksp", "Trash/Space Moves/test-move/Topic.md"))!.bytes,
      ),
      "destination original",
    );
    assert.equal(text((await transport.read("ksp", "Topic.md"))!.bytes), output);
    assert.ok(!transport.mutations.some((m) => m.includes("escape")));
  }
});

test("cancellation during an archive read stops before its write", async () => {
  const { transport, plan } = setup();
  const controller = new AbortController();
  transport.hook = (action, _space, path) => {
    if (action === "read" && path.includes("Trash/")) controller.abort();
  };
  const result = await executeMove(transport, plan, { signal: controller.signal });
  assert.equal(result.status, "cancelled");
  assert.equal(transport.mutations.length, 0);
});

test("never removes readonly sources even when a transport would allow it", async () => {
  const { transport, plan } = setup();
  transport.files.get(key("personal", "Topic.md"))!.readOnly = true;
  const result = await executeMove(transport, plan);
  assert.equal(result.status, "partial");
  assert.ok(await transport.read("personal", "Topic.md"));
});

test("preflight checks every revision before mutation and resume requires archive evidence", async () => {
  for (const changed of ["source", "destination", "patch"]) {
    const { transport, plan } = setup();
    if (changed === "source") transport.seed("personal", "Topic.md", "changed");
    if (changed === "destination") transport.seed("ksp", "Topic.md", "changed");
    if (changed === "patch") transport.seed("personal", "Index.md", "changed");
    await assert.rejects(executeMove(transport, plan), /changed/i);
    assert.equal(transport.mutations.length, 0);
  }
  const { transport, plan } = setup();
  const completed = await executeMove(transport, plan);
  transport.files.delete(key("personal", "Trash/Space Moves/test-move/Topic.md"));
  const count = transport.mutations.length;
  const resumed = await executeMove(transport, plan, { manifest: completed.manifest });
  assert.equal(resumed.status, "partial");
  assert.equal(transport.mutations.length, count);
});

test("permits only reversible link edits in non-current daily journals and resumes body-free", async () => {
  for (const day of ["2000-01-01", "2099-01-01"]) {
    const { transport, plan } = setup();
    const old = "\uFEFF# Journal\r\nPrivate prose [[Topic]] untouched.\r\n";
    const output = old.replace("[[Topic]]", "[[ksp/Topic]]");
    const from = output.indexOf("[[ksp/Topic]]");
    plan.patches = [
      {
        before: transport.seed("personal", `Journal/${day}.md`, old),
        output: bytes(output),
        inverseEdits: [
          {
            from,
            to: from + "[[ksp/Topic]]".length,
            before: "[[Topic]]",
            after: "[[ksp/Topic]]",
          },
        ],
      },
    ];
    const controller = new AbortController();
    const first = await executeMove(transport, plan, {
      signal: controller.signal,
      onProgress: (e) => {
        if (e.phase === "patch") controller.abort();
      },
    });
    assert.equal(first.status, "cancelled");
    const rebuilt = structuredClone(plan);
    rebuilt.patches[0].before = (await transport.read(
      "personal",
      `Journal/${day}.md`,
    ))!;
    const resumed = await executeMove(transport, rebuilt, { manifest: first.manifest });
    assert.equal(resumed.status, "complete", JSON.stringify(resumed.errors));
    assert.deepEqual(
      (await transport.read("personal", `Journal/${day}.md`))!.bytes,
      bytes(output),
    );
  }
});

test("daily journal guards reject whole selections, prose changes and overlapping edits", async () => {
  for (const mode of ["selection", "destination", "prose", "missing", "overlap"]) {
    const { transport, plan } = setup();
    const path = "Journal/2000-01-01.md";
    const before = transport.seed("personal", path, "Private [[Topic]]");
    const output = "Private [[ksp/Topic]]";
    const from = output.indexOf("[[ksp/Topic]]");
    const edit = {
      from,
      to: output.length,
      before: "[[Topic]]",
      after: "[[ksp/Topic]]",
    };
    plan.patches = [{ before, output: bytes(output), inverseEdits: [edit] }];
    if (mode === "selection") {
      plan.items[0].source = before;
      plan.patches = [];
    }
    if (mode === "destination") {
      plan.items[0].destinationPath = path;
      plan.patches = [];
    }
    if (mode === "prose") plan.patches[0].output = bytes(output + " changed prose");
    if (mode === "missing") delete plan.patches[0].inverseEdits;
    if (mode === "overlap") plan.patches[0].inverseEdits!.push({ ...edit });
    await assert.rejects(
      executeMove(transport, plan),
      /managed|journal|overlap/i,
      mode,
    );
    assert.equal(transport.mutations.length, 0, mode);
  }
});

test("permits a link-only journal patch when preview rolls into its day", async () => {
  const RealDate = Date;
  let now = RealDate.parse("2026-11-03T23:59:59-05:00");
  globalThis.Date = class extends RealDate {
    constructor(...args: any[]) {
      super(args.length ? args[0] : now);
    }
    static now() {
      return now;
    }
  } as DateConstructor;
  try {
    const { transport, plan } = setup();
    const output = "[[ksp/Topic]]";
    plan.patches = [
      {
        before: transport.seed("personal", "Journal/2026-11-04.md", "[[Topic]]"),
        output: bytes(output),
        inverseEdits: [
          { from: 0, to: output.length, before: "[[Topic]]", after: output },
        ],
      },
    ];
    const result = await executeMove(transport, plan, {
      onProgress: (e) => {
        if (e.phase === "preflight") now = RealDate.parse("2026-11-04T00:00:01-05:00");
      },
    });
    assert.equal(result.status, "complete", JSON.stringify(result.errors));
    assert.ok(
      text(
        (await transport.read("personal", "Journal/2026-11-04.md"))!.bytes,
      ).startsWith(output),
    );
  } finally {
    globalThis.Date = RealDate;
  }
});

test("journal attachment links resolve from the space root", async () => {
  const { transport, plan } = setup();
  plan.items = [
    {
      source: transport.seed("personal", "assets/a b.pdf", new Uint8Array([0, 1])),
      destination: null,
      output: new Uint8Array([0, 1]),
    },
  ];
  plan.patches = [];
  const result = await executeMove(transport, plan);
  assert.equal(result.status, "complete");
  const journal = text(
    (await transport.read(
      "ksp",
      result.manifest.journals.find((j) => j.space === "ksp")!.path,
    ))!.bytes,
  );
  assert.ok(journal.includes("[assets/a b.pdf](</assets/a%20b.pdf>)"), journal);
});

test("identical binary destinations are verified without rewriting", async () => {
  const { transport, plan } = setup();
  const data = new Uint8Array([0, 255, 128, 3]);
  plan.items = [
    {
      source: transport.seed("personal", "image.png", data),
      destination: transport.seed("ksp", "image.png", data),
      output: data,
      isBinary: true,
    },
  ];
  plan.patches = [];
  const result = await executeMove(transport, plan);
  assert.equal(result.status, "complete");
  assert.ok(!transport.mutations.includes("write ksp:image.png"));
  assert.deepEqual((await transport.read("ksp", "image.png"))!.bytes, data);
});

test("journal recovery preserves BOM and uses surviving archive links for removed sources", async () => {
  const { transport, plan } = setup();
  const day = new Intl.DateTimeFormat("en-CA", {
    timeZone: "America/New_York",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).format(new Date());
  const path = `Journal/${day}.md`;
  transport.seed("personal", path, "\uFEFF# Existing\n");
  const write = transport.write.bind(transport);
  let once = true;
  transport.write = async (...args) => {
    const result = await write(...args);
    if (once && args[1] === path) {
      once = false;
      throw new Error("journal response lost");
    }
    return result;
  };
  const first = await executeMove(transport, plan);
  assert.equal(first.status, "partial");
  const originalWrites = transport.mutations.filter((m) => !m.includes("Journal/"));
  const second = await executeMove(transport, plan, { manifest: first.manifest });
  assert.equal(second.status, "complete");
  assert.deepEqual(
    transport.mutations.filter((m) => !m.includes("Journal/")),
    originalWrites,
  );
  const journal = new TextDecoder("utf-8", { ignoreBOM: true }).decode(
    (await transport.read("personal", path))!.bytes,
  );
  assert.ok(journal.startsWith("\uFEFF# Existing\n"));
  assert.match(journal, /\[\[Trash\/Space Moves\/test-move\/Topic\]\]/);
  assert.match(journal, /\[\[Index\]\]/);
  assert.equal(journal.split("<!-- space-move:test-move -->").length - 1, 1);
});

test("does not persist credential-bearing or embedded-data link edits", async () => {
  for (const link of [
    "[private](https://user:password@example.test/page)",
    "[private](data:text/plain,secret)",
    "[[https://example.test/page?token=secret]]",
  ]) {
    const { transport, plan } = setup();
    plan.patches[0].output = bytes(link);
    plan.patches[0].inverseEdits = [
      { from: 0, to: link.length, before: "[[Topic]]", after: link },
    ];
    await assert.rejects(executeMove(transport, plan), /inverse|link/i);
    assert.equal(transport.mutations.length, 0);
  }
});

test("resumes a body-free restart rebuilt from archives and current output snapshots", async () => {
  for (const merge of [false, true]) {
    const { transport, plan } = setup();
    if (merge)
      plan.items[0].destination = transport.seed(
        "ksp",
        "Topic.md",
        "destination original",
      );
    const controller = new AbortController();
    const first = await executeMove(transport, plan, {
      signal: controller.signal,
      onProgress: (event) => {
        if (event.phase === "patch") controller.abort();
      },
    });
    const m = JSON.parse(JSON.stringify(first.manifest)) as MoveManifest;
    const archive = (await transport.read(m.sourceSpace, m.items[0].archivePath))!;
    const currentDestination = (await transport.read(
      m.destinationSpace,
      m.items[0].destinationPath,
    ))!;
    const currentPatch = (await transport.read(m.patches[0].space, m.patches[0].path))!;
    const rebuilt: MovePlan = {
      id: m.id,
      sourceSpace: m.sourceSpace,
      destinationSpace: m.destinationSpace,
      createdAt: m.createdAt,
      items: [
        {
          source: { ...archive, path: m.items[0].sourcePath },
          destination: currentDestination,
          destinationPath: m.items[0].destinationPath,
          output: currentDestination.bytes,
        },
      ],
      patches: [{ before: currentPatch, output: currentPatch.bytes }],
    };
    const before = transport.mutations.filter((x) =>
      /write (ksp:Topic|personal:Index)/.test(x),
    );
    const result = await executeMove(transport, rebuilt, { manifest: m });
    assert.equal(result.status, "complete", JSON.stringify(result.errors));
    assert.equal(result.manifest.planDigest, m.planDigest);
    assert.deepEqual(
      transport.mutations.filter((x) => /write (ksp:Topic|personal:Index)/.test(x)),
      before,
    );
    assert.equal(await transport.read("personal", "Topic.md"), null);
  }
});

function currentJournalSetup() {
  const { transport, plan } = setup();
  const day = new Intl.DateTimeFormat("en-CA", {
    timeZone: "America/New_York",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).format(new Date());
  const path = `Journal/${day}.md`;
  const original = "\uFEFF# Private journal\r\nKeep [[Topic]] and my prose.\r\n";
  const output = original.replace("[[Topic]]", "[[ksp/Topic]]");
  const from = output.indexOf("[[ksp/Topic]]");
  plan.patches = [
    {
      before: transport.seed("personal", path, original),
      output: bytes(output),
      inverseEdits: [
        {
          from,
          to: from + "[[ksp/Topic]]".length,
          before: "[[Topic]]",
          after: "[[ksp/Topic]]",
        },
      ],
    },
  ];
  return { transport, plan, path, original, output };
}

test("current-day journal backlink patch retains BOM, CRLF, prose and exactly one activity entry", async () => {
  const { transport, plan, path, output } = currentJournalSetup();
  const first = await executeMove(transport, plan);
  assert.equal(first.status, "complete", JSON.stringify(first.errors));
  const journal = (await transport.read("personal", path))!.bytes;
  assert.deepEqual(journal.slice(0, bytes(output).length), bytes(output));
  assert.equal(text(journal).split("<!-- space-move:test-move -->").length - 1, 1);
  const again = await executeMove(transport, plan, { manifest: first.manifest });
  assert.equal(again.status, "complete", JSON.stringify(again.errors));
  assert.deepEqual((await transport.read("personal", path))!.bytes, journal);
});

test("body-free current-journal restart strips only own entry and reconstructs original inverse bytes", async () => {
  const { transport, plan, path, output } = currentJournalSetup();
  const write = transport.write.bind(transport);
  let fail = true;
  transport.write = async (...args) => {
    const result = await write(...args);
    if (
      fail &&
      args[0] === "personal" &&
      args[1] === path &&
      text(args[2]).includes("<!-- space-move:")
    ) {
      fail = false;
      throw new Error("journal response lost");
    }
    return result;
  };
  const first = await executeMove(transport, plan);
  assert.equal(first.status, "partial");
  assert.equal(first.counts.removed, 1);
  const current = (await transport.read("personal", path))!;
  const rebuilt = structuredClone(plan);
  rebuilt.patches = [{ before: current, output: current.bytes }];
  const second = await executeMove(transport, rebuilt, {
    manifest: JSON.parse(JSON.stringify(first.manifest)),
  });
  assert.equal(second.status, "complete", JSON.stringify(second.errors));
  assert.equal(second.manifest.planDigest, first.manifest.planDigest);
  assert.deepEqual(second.manifest.patches, first.manifest.patches);
  const journal = (await transport.read("personal", path))!.bytes;
  assert.deepEqual(journal.slice(0, bytes(output).length), bytes(output));
  assert.equal(text(journal).split("<!-- space-move:test-move -->").length - 1, 1);
  assert.ok(!JSON.stringify(second.manifest).includes("my prose"));
});

test("pending current-journal patch resumes around prior activity without ever dropping it", async () => {
  for (const interruption of ["cancel", "lost-response"]) {
    const { transport, plan, path, output } = currentJournalSetup();
    let fail = true;
    const first = await executeMove(transport, plan, {
      saveManifest: async (m) => {
        if (fail && m.items[0].destinationVerified) {
          fail = false;
          throw new Error("checkpoint unavailable");
        }
      },
    });
    assert.equal(first.status, "partial");
    const prior = (await transport.read("personal", path))!.bytes;
    assert.match(text(prior), /space-move:test-move/);
    assert.ok(!text(prior).includes("[[ksp/Topic]]"));
    const write = transport.write.bind(transport);
    let loseResponse = interruption === "lost-response";
    transport.write = async (...args) => {
      if (args[0] === "personal" && args[1] === path) {
        assert.equal(
          text(args[2]).split("<!-- space-move:test-move -->").length - 1,
          1,
          "a mutation must never temporarily remove durable prior activity",
        );
      }
      const written = await write(...args);
      if (loseResponse && args[0] === "personal" && args[1] === path) {
        loseResponse = false;
        throw new Error("patch response lost");
      }
      return written;
    };
    const controller = new AbortController();
    const second = await executeMove(transport, plan, {
      manifest: first.manifest,
      signal: controller.signal,
      onProgress: (e) => {
        if (interruption === "cancel" && e.phase === "patch") controller.abort();
      },
    });
    assert.equal(second.status, interruption === "cancel" ? "cancelled" : "partial");
    assert.equal(second.counts.patches, 1);
    assert.equal(second.counts.removed, 0);
    const during = (await transport.read("personal", path))!.bytes;
    assert.deepEqual(during.slice(0, bytes(output).length), bytes(output));
    assert.match(text(during), /space-move:test-move/);
    const rebuilt = structuredClone(plan);
    rebuilt.patches[0].before = (await transport.read("personal", path))!;
    rebuilt.patches[0].output = rebuilt.patches[0].before.bytes;
    const third = await executeMove(transport, rebuilt, { manifest: second.manifest });
    assert.equal(third.status, "complete", JSON.stringify(third.errors));
    assert.equal(third.manifest.planDigest, first.manifest.planDigest);
    assert.equal(
      third.manifest.patches[0].revision,
      first.manifest.patches[0].revision,
    );
    assert.equal(
      text((await transport.read("personal", path))!.bytes).split(
        "<!-- space-move:test-move -->",
      ).length - 1,
      1,
    );
    const fourth = await executeMove(transport, plan, { manifest: third.manifest });
    assert.equal(fourth.status, "complete");
  }
});

test("own journal normalization fails closed on unrelated outside edits and ambiguous markers", async () => {
  for (const mode of ["prefix", "suffix", "duplicate", "incomplete", "other-id"]) {
    const { transport, plan, path } = currentJournalSetup();
    const first = await executeMove(transport, plan);
    const approved = (await transport.read("personal", path))!.bytes;
    const decode = new TextDecoder("utf-8", { ignoreBOM: true });
    const journal = decode.decode(approved);
    const altered =
      mode === "prefix"
        ? journal.replace("my prose", "concurrent prose")
        : mode === "suffix"
          ? journal + "unrelated outside edit\n"
          : mode === "duplicate"
            ? journal +
              "<!-- space-move:test-move -->\n<!-- /space-move:test-move -->\n"
            : mode === "incomplete"
              ? journal.replace("<!-- /space-move:test-move -->", "")
              : journal.replaceAll("space-move:test-move", "space-move:other-move");
    transport.seed("personal", path, altered);
    const count = transport.mutations.length;
    const second = await executeMove(transport, plan, { manifest: first.manifest });
    assert.equal(second.status, "partial", mode);
    assert.match(second.errors[0].message, /patch changed/i, mode);
    assert.equal(transport.mutations.length, count, mode);
    assert.deepEqual((await transport.read("personal", path))!.bytes, bytes(altered));
  }
});

test("stripJournalEntryCandidates returns only exact byte prefixes with one unique terminal own block", () => {
  for (const prefix of [
    "",
    "plain",
    "plain\n",
    "\uFEFF# Journal\r\n",
    "nonascii Ω\n\n",
  ]) {
    const block = "<!-- space-move:own -->\n- activity\n<!-- /space-move:own -->\n";
    const raw = bytes(
      prefix + (prefix.endsWith("\n") || !prefix ? "" : "\n") + "\n" + block,
    );
    const candidates = stripJournalEntryCandidates(raw, "own");
    const original = bytes(prefix);
    assert.ok(
      candidates.some(
        (b) => b.length === original.length && b.every((v, i) => v === original[i]),
      ),
      prefix,
    );
    assert.deepEqual(candidates[0], raw);
    assert.equal(
      stripJournalEntryCandidates(bytes(text(raw) + block), "own").length,
      1,
    );
    assert.equal(
      stripJournalEntryCandidates(bytes(text(raw) + "outside\n"), "own").length,
      1,
    );
    assert.equal(stripJournalEntryCandidates(raw, "other").length, 1);
  }
});

test("own journal normalization rejects a separator the engine could not have appended", () => {
  const block = "<!-- space-move:own -->\n- activity\n<!-- /space-move:own -->\n";
  for (const [original, malformed] of [
    ["plain", "plain\n"],
    ["", "\n\n"],
    ["plain\n", "plain\n\n\n"],
  ]) {
    const candidates = stripJournalEntryCandidates(bytes(malformed + block), "own");
    assert.ok(
      !candidates.some((b) => text(b) === original),
      JSON.stringify({ original, malformed }),
    );
  }
});

test("trusted origin authorizes only same-origin public inverse URLs and fingerprints the origin", async () => {
  for (const origin of [
    "https://notes.example.test",
    "http://localhost:3000",
    "http://127.0.0.1:3000",
    "http://[::1]:3000",
  ]) {
    const { transport, plan } = setup();
    plan.origin = origin;
    const link = `[Topic](${origin}/ksp/Topic#section)`;
    plan.patches[0].output = bytes(link);
    plan.patches[0].before = transport.seed("personal", "Index.md", "[[Topic]]");
    plan.patches[0].inverseEdits = [
      { from: 0, to: link.length, before: "[[Topic]]", after: link },
    ];
    const first = await executeMove(transport, plan);
    assert.equal(first.status, "complete", JSON.stringify(first.errors));
    assert.equal(first.manifest.origin, origin);
    const again = await executeMove(transport, plan, { manifest: first.manifest });
    assert.equal(again.status, "complete");
    const altered = structuredClone(first.manifest);
    altered.origin = "https://other.example.test";
    await assert.rejects(
      executeMove(transport, plan, { manifest: altered }),
      /manifest|origin/i,
    );
  }
});

test("inverse URLs remain forbidden without trusted origin, and origin never permits credentials or foreign URLs", async () => {
  const badLinks = [
    "[Topic](https://other.example.test/Topic)",
    "[Topic](https://user:password@notes.example.test/Topic)",
    "[Topic](https://notes.example.test/Topic?view=1)",
    "[Topic](https://notes.example.test/Topic?)",
    "[Topic](https://@notes.example.test/Topic)",
    "[Topic](<https://notes.example.test/Topic>)[other](<https://notes.example.test/Other>)",
    "[Topic](data:text/plain,secret)",
    "[Topic](javascript:alert(1))",
    "[Topic](mailto:user@example.test)",
    "[Topic](//other.example.test/Topic)",
    "[[https://notes.example.test/Topic?token=secret]]",
    "[Topic](https://notes.example.test/Topic)[private](data:text/plain,secret)",
    "[Topic](https://notes.example.test/Topic)[other](https://notes.example.test/Other)",
    "[Topic](https://notes.example.test/Topic(data:text/plain,secret))",
  ];
  for (const link of badLinks) {
    const { transport, plan } = setup();
    plan.origin = "https://notes.example.test";
    plan.patches[0].output = bytes(link);
    plan.patches[0].inverseEdits = [
      { from: 0, to: link.length, before: "[[Topic]]", after: link },
    ];
    await assert.rejects(executeMove(transport, plan), /inverse|link/i, link);
    assert.equal(transport.mutations.length, 0);
  }
  for (const origin of [
    undefined,
    "http://notes.example.test",
    "https://user:pw@notes.example.test",
    "https://notes.example.test/path",
    "https://notes.example.test?token=secret",
    "data:text/plain,secret",
  ]) {
    const { transport, plan } = setup();
    plan.origin = origin;
    const link = "[Topic](https://notes.example.test/Topic)";
    plan.patches[0].output = bytes(link);
    plan.patches[0].inverseEdits = [
      { from: 0, to: link.length, before: "[[Topic]]", after: link },
    ];
    await assert.rejects(executeMove(transport, plan), /inverse|link|origin/i, origin);
    assert.equal(transport.mutations.length, 0);
  }
});

test("archives originals, verifies destinations and patches before removal, and journals both spaces", async () => {
  const { transport, plan } = setup();
  const manifests: MoveManifest[] = [];
  const result = await executeMove(transport, plan, {
    saveManifest: async (m) => {
      manifests.push(structuredClone(m));
    },
  });
  assert.equal(result.status, "complete");
  assert.equal(await transport.read("personal", "Topic.md"), null);
  assert.equal(
    text((await transport.read("ksp", "Topic.md"))!.bytes),
    "selected rewritten",
  );
  assert.equal(
    text(
      (await transport.read("personal", "Trash/Space Moves/test-move/Topic.md"))!.bytes,
    ),
    "selected original",
  );
  assert.equal(
    text((await transport.read("personal", "Index.md"))!.bytes),
    "private unrelated text [[ksp/Topic]]",
  );
  assert.ok(
    transport.mutations.indexOf("write personal:Index.md") <
      transport.mutations.indexOf("remove personal:Topic.md"),
  );
  assert.ok(!JSON.stringify(manifests).includes("private unrelated text"));
  for (const space of ["personal", "ksp"] as const) {
    const journals = (await transport.list(space)).filter((f) =>
      /^Journal\/\d{4}-\d{2}-\d{2}\.md$/.test(f.path),
    );
    assert.equal(journals.length, 1);
    assert.match(text(journals[0].bytes), /space-move:test-move/);
  }
});
