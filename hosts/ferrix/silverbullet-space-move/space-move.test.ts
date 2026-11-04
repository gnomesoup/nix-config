import { beforeEach, expect, it, vi } from "vitest";
import { runInNewContext } from "node:vm";
const mocks = vi.hoisted(() => ({
  save: vi.fn(async () => {}),
  getCurrentPath: vi.fn(async () => "Root.md"),
  getText: vi.fn(async () => "Content"),
  showPanel: vi.fn(async () => {}),
  readAsset: vi.fn(async (_plug: string, path: string) =>
    path.endsWith(".html")
      ? "<main id=space-move></main>"
      : "globalThis.started = true;",
  ),
}));
vi.mock("@silverbulletmd/silverbullet/syscalls", () => ({
  editor: mocks,
  asset: mocks,
}));
vi.mock("@silverbulletmd/silverbullet/ui", () => ({
  panelStyles: async () => "/* theme */",
}));
import { openMover } from "./space-move.ts";

beforeEach(() => vi.clearAllMocks());

it("saves the current note before opening the credential-free browser panel", async () => {
  mocks.getText.mockResolvedValueOnce(
    'Text "; globalThis.injected = true; // </script>',
  );
  await openMover();
  expect(mocks.save).toHaveBeenCalledOnce();
  expect(mocks.save.mock.invocationCallOrder[0]).toBeLessThan(
    mocks.showPanel.mock.invocationCallOrder[0],
  );
  const args = mocks.showPanel.mock.calls[0] as unknown as [
    string,
    number,
    string,
    string,
  ];
  expect(args[0]).toBe("modal");
  const context: Record<string, unknown> = {};
  runInNewContext(args[3], context);
  expect(context.started).toBe(true);
  expect(context.injected).toBeUndefined();
  expect(context.spaceMoveBoot).toMatchObject({
    path: "Root.md",
    text: expect.stringContaining("</script>"),
  });
});

it("does not open a migration panel when saving fails", async () => {
  mocks.save.mockRejectedValueOnce(new Error("Unsaved changes"));
  await expect(openMover()).rejects.toThrow("Unsaved changes");
  expect(mocks.showPanel).not.toHaveBeenCalled();
});
