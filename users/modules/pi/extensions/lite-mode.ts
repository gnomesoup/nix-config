import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import type { Api, Model } from "@earendil-works/pi-ai";
import type {
	ExtensionAPI,
	ExtensionCommandContext,
	ExtensionContext,
} from "@earendil-works/pi-coding-agent";
import { getAgentDir } from "@earendil-works/pi-coding-agent";
import type { AutocompleteItem } from "@earendil-works/pi-tui";
import { Container, fuzzyFilter, Input, SelectList, Spacer, Text } from "@earendil-works/pi-tui";

const CONFIG_VERSION = 1;
const CONFIG_PATH = join(getAgentDir(), "lite-mode.json");
const STATE_ENTRY_TYPE = "lite-mode-state";
const STATUS_KEY = "lite-mode";
const WIDGET_KEY = "lite-mode";

interface ModelRef {
	provider: string;
	model: string;
}

interface LiteModeConfig extends ModelRef {
	version: number;
}

interface LiteModeState {
	enabled: boolean;
	mainModel?: ModelRef;
	liteModel?: ModelRef;
}

function modelRef(model: Model<Api>): ModelRef {
	return { provider: model.provider, model: model.id };
}

function modelKey(ref: ModelRef): string {
	return `${ref.provider}/${ref.model}`;
}

function sameModel(model: Model<Api> | undefined, ref: ModelRef | undefined): boolean {
	return model !== undefined && ref !== undefined && model.provider === ref.provider && model.id === ref.model;
}

function isModelRef(value: unknown): value is ModelRef {
	if (!value || typeof value !== "object") return false;
	const candidate = value as Partial<ModelRef>;
	return typeof candidate.provider === "string" && typeof candidate.model === "string";
}

function parseModelArgument(value: string): ModelRef | undefined {
	const separator = value.indexOf("/");
	if (separator <= 0 || separator === value.length - 1) return undefined;
	return {
		provider: value.slice(0, separator),
		model: value.slice(separator + 1),
	};
}

async function loadConfig(): Promise<ModelRef | undefined> {
	try {
		const parsed = JSON.parse(await readFile(CONFIG_PATH, "utf8")) as unknown;
		if (!parsed || typeof parsed !== "object") return undefined;
		const config = parsed as Partial<LiteModeConfig>;
		if (config.version !== CONFIG_VERSION || !isModelRef(config)) return undefined;
		return { provider: config.provider, model: config.model };
	} catch (error) {
		if ((error as NodeJS.ErrnoException).code === "ENOENT") return undefined;
		throw error;
	}
}

async function saveConfig(ref: ModelRef): Promise<void> {
	await mkdir(dirname(CONFIG_PATH), { recursive: true });
	const temporaryPath = `${CONFIG_PATH}.tmp-${process.pid}`;
	const config: LiteModeConfig = { version: CONFIG_VERSION, ...ref };
	await writeFile(temporaryPath, `${JSON.stringify(config, null, 2)}\n`, { mode: 0o600 });
	await rename(temporaryPath, CONFIG_PATH);
}

function latestSessionState(ctx: ExtensionContext): LiteModeState | undefined {
	const entries = ctx.sessionManager.getEntries();
	for (let index = entries.length - 1; index >= 0; index--) {
		const entry = entries[index] as {
			type?: string;
			customType?: string;
			data?: unknown;
		};
		if (entry.type !== "custom" || entry.customType !== STATE_ENTRY_TYPE) continue;
		if (!entry.data || typeof entry.data !== "object") return undefined;

		const data = entry.data as Partial<LiteModeState>;
		if (typeof data.enabled !== "boolean") return undefined;
		return {
			enabled: data.enabled,
			mainModel: isModelRef(data.mainModel) ? data.mainModel : undefined,
			liteModel: isModelRef(data.liteModel) ? data.liteModel : undefined,
		};
	}
	return undefined;
}

export default function liteModeExtension(pi: ExtensionAPI) {
	let enabled = false;
	let mainModel: ModelRef | undefined;
	let liteModel: ModelRef | undefined;
	let internalModelChange = false;
	let availableModelKeys: string[] = [];

	function persistState(): void {
		pi.appendEntry(STATE_ENTRY_TYPE, {
			enabled,
			mainModel,
			liteModel,
		} satisfies LiteModeState);
	}

	function refreshAvailableModels(ctx: ExtensionContext): Model<Api>[] {
		const models = ctx.modelRegistry
			.getAvailable()
			.slice()
			.sort((left, right) => modelKey(modelRef(left)).localeCompare(modelKey(modelRef(right))));
		availableModelKeys = models.map((model) => modelKey(modelRef(model)));
		return models;
	}

	function updateUi(ctx: ExtensionContext): void {
		ctx.ui.setStatus(STATUS_KEY, undefined);
		if (!enabled || !liteModel) {
			ctx.ui.setWidget(WIDGET_KEY, undefined);
			return;
		}

		const label = modelKey(liteModel);
		ctx.ui.setWidget(WIDGET_KEY, (_tui, theme) =>
			new Text(
				theme.fg("warning", theme.bold(`⚡ LITE MODE — ${label}`)),
				1,
				0,
			),
		);
	}

	async function setModel(model: Model<Api>): Promise<boolean> {
		internalModelChange = true;
		try {
			return await pi.setModel(model);
		} finally {
			internalModelChange = false;
		}
	}

	async function enableLite(ctx: ExtensionCommandContext): Promise<void> {
		if (enabled) {
			ctx.ui.notify(`Lite Mode is already enabled (${liteModel ? modelKey(liteModel) : "model unavailable"})`, "info");
			return;
		}
		if (!liteModel) {
			ctx.ui.notify("No Lite model assigned. Run /lite-model first.", "warning");
			return;
		}

		const target = ctx.modelRegistry.find(liteModel.provider, liteModel.model);
		if (!target) {
			ctx.ui.notify(`Lite model ${modelKey(liteModel)} is no longer available. Run /lite-model again.`, "error");
			return;
		}
		if (!ctx.modelRegistry.hasConfiguredAuth(target)) {
			ctx.ui.notify(`No authentication configured for ${modelKey(liteModel)}.`, "error");
			return;
		}
		if (!ctx.model) {
			ctx.ui.notify("No main Pi model is currently selected.", "error");
			return;
		}

		await ctx.waitForIdle();
		const capturedMainModel = modelRef(ctx.model);
		if (!sameModel(ctx.model, liteModel) && !(await setModel(target))) {
			ctx.ui.notify(`Could not switch to ${modelKey(liteModel)}. Check its authentication.`, "error");
			return;
		}

		mainModel = capturedMainModel;
		enabled = true;
		persistState();
		updateUi(ctx);
		ctx.ui.notify(`Lite Mode enabled: ${modelKey(liteModel)}`, "info");
	}

	async function disableLite(ctx: ExtensionCommandContext): Promise<void> {
		if (!enabled) {
			ctx.ui.notify("Lite Mode is already disabled.", "info");
			return;
		}
		if (!mainModel) {
			ctx.ui.notify("The main model was not recorded; Lite Mode remains enabled.", "error");
			return;
		}

		const target = ctx.modelRegistry.find(mainModel.provider, mainModel.model);
		if (!target) {
			ctx.ui.notify(`Main model ${modelKey(mainModel)} is no longer available; Lite Mode remains enabled.`, "error");
			return;
		}

		await ctx.waitForIdle();
		if (!sameModel(ctx.model, mainModel) && !(await setModel(target))) {
			ctx.ui.notify(`Could not restore ${modelKey(mainModel)}; Lite Mode remains enabled.`, "error");
			return;
		}

		enabled = false;
		persistState();
		updateUi(ctx);
		ctx.ui.notify(`Lite Mode disabled: restored ${modelKey(mainModel)}`, "info");
	}

	async function assignLiteModel(ref: ModelRef, ctx: ExtensionCommandContext): Promise<void> {
		const target = ctx.modelRegistry.find(ref.provider, ref.model);
		if (!target) {
			ctx.ui.notify(`Unknown model ${modelKey(ref)}.`, "error");
			return;
		}
		if (!ctx.modelRegistry.hasConfiguredAuth(target)) {
			ctx.ui.notify(`No authentication configured for ${modelKey(ref)}.`, "error");
			return;
		}

		if (enabled && !sameModel(ctx.model, ref)) {
			await ctx.waitForIdle();
			if (!(await setModel(target))) {
				ctx.ui.notify(`Could not switch to ${modelKey(ref)}.`, "error");
				return;
			}
		}

		try {
			await saveConfig(ref);
		} catch (error) {
			ctx.ui.notify(`Failed to save Lite model: ${error instanceof Error ? error.message : String(error)}`, "error");
			return;
		}

		liteModel = ref;
		persistState();
		updateUi(ctx);
		ctx.ui.notify(`Lite model assigned: ${modelKey(ref)}`, "info");
	}

	pi.registerCommand("lite", {
		description: "Toggle Lite Mode or explicitly turn it on/off",
		getArgumentCompletions: (prefix: string): AutocompleteItem[] | null => {
			const options = ["on", "off", "toggle"]
				.filter((value) => value.startsWith(prefix))
				.map((value) => ({ value, label: value }));
			return options.length > 0 ? options : null;
		},
		handler: async (args, ctx) => {
			const action = args.trim().toLowerCase() || "toggle";
			if (!new Set(["on", "off", "toggle"]).has(action)) {
				ctx.ui.notify("Usage: /lite [on|off|toggle]", "warning");
				return;
			}

			const shouldEnable = action === "on" || (action === "toggle" && !enabled);
			if (shouldEnable) await enableLite(ctx);
			else await disableLite(ctx);
		},
	});

	pi.registerCommand("lite-model", {
		description: "Assign the model used by Lite Mode",
		getArgumentCompletions: (prefix: string): AutocompleteItem[] | null => {
			const matches = availableModelKeys
				.filter((value) => value.toLowerCase().includes(prefix.toLowerCase()))
				.map((value) => ({ value, label: value }));
			return matches.length > 0 ? matches : null;
		},
		handler: async (args, ctx) => {
			refreshAvailableModels(ctx);
			const argument = args.trim();
			if (argument) {
				const ref = parseModelArgument(argument);
				if (!ref) {
					ctx.ui.notify("Usage: /lite-model <provider>/<model-id>", "warning");
					return;
				}
				await assignLiteModel(ref, ctx);
				return;
			}

			if (!ctx.hasUI) {
				ctx.ui.notify("Usage: /lite-model <provider>/<model-id>", "warning");
				return;
			}
			const models = refreshAvailableModels(ctx);
			if (models.length === 0) {
				ctx.ui.notify("No authenticated models are available.", "warning");
				return;
			}

			if (ctx.mode !== "tui") {
				const selected = await ctx.ui.select(
					"Select the Lite model",
					models.map((model) => modelKey(modelRef(model))),
				);
				const ref = selected && parseModelArgument(selected);
				if (ref) await assignLiteModel(ref, ctx);
				return;
			}

			const orderedModels = [...models].sort((left, right) => {
				const leftIsCurrent = sameModel(left, liteModel);
				const rightIsCurrent = sameModel(right, liteModel);
				if (leftIsCurrent !== rightIsCurrent) return leftIsCurrent ? -1 : 1;
				return modelKey(modelRef(left)).localeCompare(modelKey(modelRef(right)));
			});
			const selected = await ctx.ui.custom<Model<Api> | undefined>((tui, theme, keybindings, done) => {
				const container = new Container();
				const searchInput = new Input();
				const listContainer = new Container();
				let selectList: SelectList;

				const rebuildList = () => {
					const query = searchInput.getValue();
					const matchingModels = query
						? fuzzyFilter(
								orderedModels,
								query,
								(model) => `${model.provider} ${modelKey(modelRef(model))} ${model.name ?? ""}`,
							)
						: orderedModels;
					selectList = new SelectList(
						matchingModels.map((model) => ({
							value: modelKey(modelRef(model)),
							label: model.id,
							description: `[${model.provider}]`,
						})),
						10,
						{
							selectedPrefix: (text) => theme.fg("accent", text),
							selectedText: (text) => theme.fg("accent", text),
							description: (text) => theme.fg("muted", text),
							scrollInfo: (text) => theme.fg("muted", text),
							noMatch: (text) => theme.fg("muted", text),
						},
					);
					const currentIndex = matchingModels.findIndex((model) => sameModel(model, liteModel));
					if (!query && currentIndex >= 0) selectList.setSelectedIndex(currentIndex);
					selectList.onSelect = (item) => {
						done(matchingModels.find((model) => modelKey(modelRef(model)) === item.value));
					};
					selectList.onCancel = () => done(undefined);
					listContainer.clear();
					listContainer.addChild(selectList);
				};

				container.addChild(new Text(theme.fg("accent", theme.bold("Select the Lite model")), 1, 0));
				container.addChild(new Text(theme.fg("muted", "Type to search • ↑↓ navigate • enter select • esc cancel"), 1, 0));
				container.addChild(new Spacer(1));
				container.addChild(searchInput);
				container.addChild(new Spacer(1));
				container.addChild(listContainer);
				rebuildList();

				return {
					get focused() {
						return searchInput.focused;
					},
					set focused(value: boolean) {
						searchInput.focused = value;
					},
					render: (width) => container.render(width),
					invalidate: () => container.invalidate(),
					handleInput: (data) => {
						if (
							keybindings.matches(data, "tui.select.up") ||
							keybindings.matches(data, "tui.select.down") ||
							keybindings.matches(data, "tui.select.confirm") ||
							keybindings.matches(data, "tui.select.cancel")
						) {
							selectList.handleInput(data);
						} else {
							searchInput.handleInput(data);
							rebuildList();
						}
						tui.requestRender();
					},
				};
			});
			if (selected) await assignLiteModel(modelRef(selected), ctx);
		},
	});

	pi.on("session_start", async (_event, ctx) => {
		refreshAvailableModels(ctx);
		try {
			liteModel = await loadConfig();
		} catch (error) {
			ctx.ui.notify(`Failed to load ${CONFIG_PATH}: ${error instanceof Error ? error.message : String(error)}`, "warning");
		}

		const restored = latestSessionState(ctx);
		if (restored?.liteModel) liteModel = restored.liteModel;
		mainModel = restored?.mainModel;
		enabled = restored?.enabled === true;

		if (enabled && !liteModel) {
			enabled = false;
			ctx.ui.notify("Could not restore Lite Mode because no Lite model was recorded.", "warning");
			persistState();
		} else if (enabled && liteModel) {
			const target = ctx.modelRegistry.find(liteModel.provider, liteModel.model);
			if (!target || (!sameModel(ctx.model, liteModel) && !(await setModel(target)))) {
				enabled = false;
				ctx.ui.notify(`Could not restore Lite Mode with ${modelKey(liteModel)}.`, "warning");
				persistState();
			}
		}
		updateUi(ctx);
	});

	pi.on("model_select", async (event, ctx) => {
		refreshAvailableModels(ctx);
		if (internalModelChange || event.source === "restore") return;

		if (enabled) {
			enabled = false;
			mainModel = modelRef(event.model);
			persistState();
			updateUi(ctx);
			ctx.ui.notify("Lite Mode disabled because the model was changed manually.", "info");
		}
	});
}
