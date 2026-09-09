import { afterEach, beforeEach, describe, expect, test, vi } from "vitest";
import { Vim } from "@replit/codemirror-vim";
import {
  COLEMAK_DH_LANGMAP,
  RETRY_DELAYS_MS,
  STORE_KEY,
  applyLayoutWithRetry,
  applyOnEditorLifecycle,
  langmapCommand,
  normalizeStoredLayout,
  selectColemakDh,
  selectQwerty,
  showLayout,
  toggleLayout,
} from "./vim-layout.ts";

function keyboardEvent(key: string): KeyboardEvent {
  return {
    key,
    altKey: false,
    ctrlKey: false,
    metaKey: false,
    shiftKey: key.toUpperCase() === key && key.toLowerCase() !== key,
  } as KeyboardEvent;
}

function newVimState(): { cm: any; vim: any } {
  const cm = {
    state: {},
    operation: (run: () => unknown) => run(),
    getCursor: () => ({ line: 0, ch: 0 }),
  } as any;
  const vim = Vim.maybeInitVimState_(cm);
  return { cm, vim };
}

function applyNativeEx(command: string): void {
  const { cm } = newVimState();
  Vim.handleEx(cm, command);
}

describe("native codemirror-vim langmap behavior", () => {
  afterEach(() => Vim.langmap("", undefined));

  test("translates normal, visual, and operator-pending command keys", () => {
    applyNativeEx(langmapCommand("colemak-dh"));

    for (const state of [
      { visualMode: false, operator: null },
      { visualMode: true, operator: null },
      { visualMode: false, operator: { name: "delete" } },
    ]) {
      const { vim } = newVimState();
      vim.visualMode = state.visualMode;
      vim.inputState.operator = state.operator;
      expect(Vim.vimKeyFromEvent(keyboardEvent("m"), vim)).toBe("h");
      expect(Vim.vimKeyFromEvent(keyboardEvent("n"), vim)).toBe("j");
    }
  });

  test.each([
    ["t", "f"],
    ["j", "t"],
  ])("keeps the target following physical %s / Vim %s literal", (physical, command) => {
    applyNativeEx(langmapCommand("colemak-dh"));
    const { cm, vim } = newVimState();
    const translatedCommand = Vim.vimKeyFromEvent(keyboardEvent(physical), vim);

    expect(translatedCommand).toBe(command);
    expect(Vim.handleKey(cm, translatedCommand!, "user")).toBe(true);
    expect(vim.expectLiteralNext).toBe(true);
    expect(Vim.vimKeyFromEvent(keyboardEvent("m"), vim)).toBe("m");
  });

  test("leaves ordinary insert input unhandled so CodeMirror inserts the physical key", () => {
    applyNativeEx(langmapCommand("colemak-dh"));
    const { cm, vim } = newVimState();
    vim.insertMode = true;
    const translated = Vim.vimKeyFromEvent(keyboardEvent("m"), vim);

    expect(translated).toBe("h");
    expect(Vim.handleKey(cm, translated!, "user")).toBeUndefined();
  });

  test("QWERTY Ex command clears the native langmap", () => {
    applyNativeEx(langmapCommand("colemak-dh"));
    const first = newVimState().vim;
    expect(Vim.vimKeyFromEvent(keyboardEvent("m"), first)).toBe("h");

    applyNativeEx(langmapCommand("qwerty"));
    const cleared = newVimState().vim;
    expect(Vim.vimKeyFromEvent(keyboardEvent("m"), cleared)).toBe("m");
  });
});

describe("layout and retry policy", () => {
  test("uses the generated Colemak-DH langmap and defaults invalid storage to QWERTY", () => {
    expect(COLEMAK_DH_LANGMAP).toBe(
      "mh,nj,ek,il,kn,KN,li,LI,fe,FE,hm,tf,TF,jt,JT,NJ",
    );
    expect(normalizeStoredLayout(undefined)).toBe("qwerty");
    expect(normalizeStoredLayout("unexpected")).toBe("qwerty");
    expect(langmapCommand("qwerty")).toBe("set langmap=");
  });

  test("retries only initialization races and succeeds within the bound", async () => {
    const vimEx = vi
      .fn()
      .mockRejectedValueOnce(new Error("Vim module not loaded."))
      .mockRejectedValueOnce(
        new Error("Vim mode not active or not initialized."),
      )
      .mockResolvedValue(undefined);
    const sleep = vi.fn().mockResolvedValue(undefined);

    await expect(
      applyLayoutWithRetry("colemak-dh", {
        getVimMode: async () => true,
        vimEx,
        sleep,
      }),
    ).resolves.toEqual({ status: "applied", attempts: 3 });
    expect(vimEx).toHaveBeenCalledTimes(3);
    expect(sleep.mock.calls).toEqual([[50], [100]]);
  });

  test("bounds retry exhaustion and fails unexpected errors immediately", async () => {
    const retryable = vi
      .fn()
      .mockRejectedValue(new Error("Vim module not loaded."));
    const sleep = vi.fn().mockResolvedValue(undefined);
    const exhausted = await applyLayoutWithRetry("colemak-dh", {
      getVimMode: async () => true,
      vimEx: retryable,
      sleep,
    });
    expect(exhausted).toMatchObject({
      status: "failed",
      attempts: RETRY_DELAYS_MS.length,
    });
    expect(retryable).toHaveBeenCalledTimes(RETRY_DELAYS_MS.length);
    expect(sleep).toHaveBeenCalledTimes(RETRY_DELAYS_MS.length - 1);

    const fatal = vi.fn().mockRejectedValue(new Error("permission denied"));
    const fatalSleep = vi.fn();
    await expect(
      applyLayoutWithRetry("qwerty", {
        getVimMode: async () => true,
        vimEx: fatal,
        sleep: fatalSleep,
      }),
    ).resolves.toEqual({
      status: "failed",
      attempts: 1,
      error: "permission denied",
    });
    expect(fatal).toHaveBeenCalledTimes(1);
    expect(fatalSleep).not.toHaveBeenCalled();
  });

  test("does not retry while Vim mode is disabled", async () => {
    const vimEx = vi.fn();
    await expect(
      applyLayoutWithRetry("colemak-dh", {
        getVimMode: async () => false,
        vimEx,
        sleep: vi.fn(),
      }),
    ).resolves.toEqual({ status: "inactive", attempts: 0 });
    expect(vimEx).not.toHaveBeenCalled();
  });
});

describe("browser-local command persistence", () => {
  let store: Map<string, unknown>;
  let vimExCommands: string[];
  let notifications: string[];
  let vimError: Error | undefined;
  let vimGate: Promise<void> | undefined;

  beforeEach(() => {
    store = new Map();
    vimExCommands = [];
    notifications = [];
    vimError = undefined;
    vimGate = undefined;
    (globalThis as any).syscall = async (name: string, ...args: any[]) => {
      if (name === "clientStore.get") return store.get(args[0]);
      if (name === "clientStore.set") {
        store.set(args[0], args[1]);
        return;
      }
      if (name === "editor.getUiOption") return true;
      if (name === "editor.vimEx") {
        vimExCommands.push(args[0]);
        if (vimGate) await vimGate;
        if (vimError) throw vimError;
        return;
      }
      if (name === "editor.flashNotification") {
        notifications.push(args[0]);
        return;
      }
      throw new Error(`Unexpected syscall: ${name}`);
    };
  });

  test("toggle persists independently and returns to a cleared QWERTY langmap", async () => {
    await toggleLayout();
    expect(store.get(STORE_KEY)).toBe("colemak-dh");
    expect(vimExCommands.at(-1)).toBe(langmapCommand("colemak-dh"));

    await toggleLayout();
    expect(store.get(STORE_KEY)).toBe("qwerty");
    expect(vimExCommands.at(-1)).toBe("set langmap=");
  });

  test("lifecycle and Show default to QWERTY when storage is unset", async () => {
    await applyOnEditorLifecycle();
    expect(vimExCommands.at(-1)).toBe("set langmap=");

    await showLayout();
    expect(notifications.at(-1)).toContain("QWERTY");
  });

  test("coalesces overlapping lifecycle applications", async () => {
    let release!: () => void;
    vimGate = new Promise((resolve) => {
      release = resolve;
    });

    const first = applyOnEditorLifecycle();
    const second = applyOnEditorLifecycle();
    expect(second).toBe(first);
    release();
    await first;
    expect(vimExCommands).toEqual(["set langmap="]);
  });

  test("explicit QWERTY persists and clears the langmap", async () => {
    await selectQwerty();
    expect(store.get(STORE_KEY)).toBe("qwerty");
    expect(vimExCommands.at(-1)).toBe("set langmap=");
  });

  test("a command persists its choice and reports a non-retryable error", async () => {
    const consoleError = vi.spyOn(console, "error").mockImplementation(() => {});
    vimError = new Error("permission denied");

    await selectColemakDh();
    expect(store.get(STORE_KEY)).toBe("colemak-dh");
    expect(notifications.at(-1)).toContain("could not be applied");
    expect(consoleError).toHaveBeenCalledTimes(1);
    consoleError.mockRestore();
  });
});
