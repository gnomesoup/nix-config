import {
  clientStore,
  editor,
} from "@silverbulletmd/silverbullet/syscalls";

export type VimLayout = "qwerty" | "colemak-dh";
export type ApplyResult =
  | { status: "applied"; attempts: number }
  | { status: "inactive"; attempts: 0 }
  | { status: "failed"; attempts: number; error: string };

export const STORE_KEY = "vim-layout.selection";
export const COLEMAK_DH_LANGMAP = "@colemakLangmap@";
export const RETRY_DELAYS_MS = [0, 50, 100, 200, 400, 800] as const;

const RETRYABLE_VIM_ERRORS = [
  "Vim module not loaded.",
  "Vim mode not active or not initialized.",
];

export interface ApplyDependencies {
  getVimMode(): Promise<boolean>;
  vimEx(command: string): Promise<unknown>;
  sleep(milliseconds: number): Promise<void>;
}

const runtimeDependencies: ApplyDependencies = {
  getVimMode: async () => Boolean(await editor.getUiOption("vimMode")),
  vimEx: (command) => editor.vimEx(command),
  sleep: (milliseconds) =>
    new Promise((resolve) => globalThis.setTimeout(resolve, milliseconds)),
};

let applyQueue: Promise<ApplyResult> = Promise.resolve({
  status: "inactive",
  attempts: 0,
});
let lifecycleApply: Promise<void> | undefined;

function layoutLabel(layout: VimLayout): string {
  return layout === "colemak-dh" ? "Colemak-DH" : "QWERTY";
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

function isRetryableVimError(error: unknown): boolean {
  const message = errorMessage(error);
  return RETRYABLE_VIM_ERRORS.some((candidate) => message.includes(candidate));
}

export function normalizeStoredLayout(value: unknown): VimLayout {
  return value === "colemak-dh" ? "colemak-dh" : "qwerty";
}

export function langmapCommand(layout: VimLayout): string {
  return `set langmap=${layout === "colemak-dh" ? COLEMAK_DH_LANGMAP : ""}`;
}

export async function applyLayoutWithRetry(
  layout: VimLayout,
  dependencies: ApplyDependencies,
  retryDelays: readonly number[] = RETRY_DELAYS_MS,
): Promise<ApplyResult> {
  if (!(await dependencies.getVimMode())) {
    return { status: "inactive", attempts: 0 };
  }

  let lastError = "Vim layout could not be applied.";
  for (let attempt = 0; attempt < retryDelays.length; attempt += 1) {
    if (retryDelays[attempt] > 0) {
      await dependencies.sleep(retryDelays[attempt]);
    }
    try {
      await dependencies.vimEx(langmapCommand(layout));
      return { status: "applied", attempts: attempt + 1 };
    } catch (error) {
      lastError = errorMessage(error);
      if (!isRetryableVimError(error)) {
        return { status: "failed", attempts: attempt + 1, error: lastError };
      }
    }
  }

  return {
    status: "failed",
    attempts: retryDelays.length,
    error: lastError,
  };
}

async function readSelectedLayout(): Promise<VimLayout> {
  return normalizeStoredLayout(await clientStore.get(STORE_KEY));
}

async function applySelectedLayout(): Promise<{
  layout: VimLayout;
  result: ApplyResult;
}> {
  const layout = await readSelectedLayout();
  const result = await applyLayoutWithRetry(layout, runtimeDependencies);
  return { layout, result };
}

function queueSelectedLayout(): Promise<{ layout: VimLayout; result: ApplyResult }> {
  const queued = applyQueue.then(applySelectedLayout, applySelectedLayout);
  applyQueue = queued.then(
    ({ result }) => result,
    (error) => ({ status: "failed", attempts: 0, error: errorMessage(error) }),
  );
  return queued;
}

async function reportCommandResult(
  layout: VimLayout,
  result: ApplyResult,
): Promise<void> {
  const label = layoutLabel(layout);
  if (result.status === "applied") {
    await editor.flashNotification(`Vim layout: ${label}`);
  } else if (result.status === "inactive") {
    await editor.flashNotification(
      `Vim layout saved as ${label}; it will apply when Vim mode is enabled.`,
    );
  } else {
    console.error(`Vim layout ${label} failed: ${result.error}`);
    await editor.flashNotification(
      `Vim layout ${label} could not be applied.`,
      "error",
    );
  }
}

async function selectLayout(layout: VimLayout): Promise<void> {
  await clientStore.set(STORE_KEY, layout);
  const applied = await queueSelectedLayout();
  await reportCommandResult(applied.layout, applied.result);
}

export async function selectQwerty(): Promise<void> {
  await selectLayout("qwerty");
}

export async function selectColemakDh(): Promise<void> {
  await selectLayout("colemak-dh");
}

export async function toggleLayout(): Promise<void> {
  const current = await readSelectedLayout();
  await selectLayout(current === "qwerty" ? "colemak-dh" : "qwerty");
}

export async function showLayout(): Promise<void> {
  const layout = await readSelectedLayout();
  await editor.flashNotification(
    `Vim layout: ${layoutLabel(layout)} (browser-local for this space)`,
  );
}

export function applyOnEditorLifecycle(): Promise<void> {
  if (lifecycleApply) return lifecycleApply;

  const run = (async () => {
    try {
      const { layout, result } = await queueSelectedLayout();
      if (result.status === "failed") {
        console.error(
          `Vim layout ${layoutLabel(layout)} lifecycle apply failed: ${result.error}`,
        );
      }
    } catch (error) {
      console.error(`Vim layout lifecycle apply failed: ${errorMessage(error)}`);
    }
  })();
  lifecycleApply = run;
  void run.finally(() => {
    if (lifecycleApply === run) lifecycleApply = undefined;
  });
  return run;
}
