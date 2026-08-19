import { readFile } from "node:fs/promises";
import { getSupportedThinkingLevels, clampThinkingLevel, type ModelThinkingLevel } from "@earendil-works/pi-ai";
import { getAgentDir, type ExtensionAPI, type ExtensionContext } from "@earendil-works/pi-coding-agent";
import { Container, fuzzyFilter, Input, SelectList, Spacer, Text, type AutocompleteItem } from "@earendil-works/pi-tui";

const THINKING_LEVEL_DESCRIPTIONS: Record<ModelThinkingLevel, string> = {
  off: "No reasoning",
  minimal: "Very brief reasoning (~1k tokens)",
  low: "Light reasoning (~2k tokens)",
  medium: "Moderate reasoning (~8k tokens)",
  high: "Deep reasoning (~16k tokens)",
  xhigh: "Extra-high reasoning (~32k tokens)",
  max: "Maximum reasoning"
};

function isThinkingLevel(value: unknown): value is ModelThinkingLevel {
  return typeof value === "string" && value in THINKING_LEVEL_DESCRIPTIONS;
}

async function configuredDefaultThinkingLevel(): Promise<ModelThinkingLevel | undefined> {
  try {
    const settings = JSON.parse(await readFile(`${getAgentDir()}/settings.json`, "utf8")) as {
      defaultThinkingLevel?: unknown;
    };
    return isThinkingLevel(settings.defaultThinkingLevel) ? settings.defaultThinkingLevel : undefined;
  } catch {
    return undefined;
  }
}

function scopedDefaultThinkingLevel(ctx: ExtensionContext): ModelThinkingLevel | undefined {
  const model = ctx.model;
  const scopedModel = model && ctx.scopedModels.find(
    (candidate) => candidate.model.provider === model.provider && candidate.model.id === model.id
  );
  return isThinkingLevel(scopedModel?.thinkingLevel) ? scopedModel.thinkingLevel : undefined;
}

function availableThinkingLevels(ctx: ExtensionContext): ModelThinkingLevel[] {
  return ctx.model ? getSupportedThinkingLevels(ctx.model) : [];
}

function findThinkingLevel(argument: string, levels: ModelThinkingLevel[]): ModelThinkingLevel | undefined {
  const query = argument.trim().toLowerCase();
  if (!query) return undefined;

  const exact = levels.find((level) => level === query);
  if (exact) return exact;

  const prefixMatches = levels.filter((level) => level.startsWith(query));
  if (prefixMatches.length === 1) return prefixMatches[0];

  const fuzzyMatches = fuzzyFilter(levels, query, (level) => level);
  return fuzzyMatches.length === 1 ? fuzzyMatches[0] : undefined;
}

export default function thinkExtension(pi: ExtensionAPI) {
  let completionLevels: ModelThinkingLevel[] = [];

  const refreshCompletionLevels = (ctx: ExtensionContext) => {
    completionLevels = availableThinkingLevels(ctx);
  };

  pi.registerCommand("think", {
    description: "Select the current model's thinking level",
    getArgumentCompletions: (prefix: string): AutocompleteItem[] | null => {
      const query = prefix.trim().toLowerCase();
      const matches = query
        ? fuzzyFilter(completionLevels, query, (level) => level)
        : completionLevels;
      return matches.length > 0 ? matches.map((level) => ({ value: level, label: level })) : null;
    },
    handler: async (args, ctx) => {
      const model = ctx.model;
      if (!model) {
        ctx.ui.notify("No model is selected.", "warning");
        return;
      }
      if (!model.reasoning) {
        ctx.ui.notify(`${model.id} does not support configurable thinking.`, "warning");
        return;
      }

      const levels = availableThinkingLevels(ctx);
      const configuredDefault = scopedDefaultThinkingLevel(ctx) ?? await configuredDefaultThinkingLevel();
      const defaultLevel = configuredDefault && clampThinkingLevel(model, configuredDefault);
      const argument = args.trim();

      if (argument) {
        const selected = findThinkingLevel(argument, levels);
        if (!selected) {
          const choices = levels.join(", ");
          ctx.ui.notify(`Unknown or ambiguous thinking level "${argument}". Choose: ${choices}.`, "warning");
          return;
        }
        pi.setThinkingLevel(selected);
        return;
      }

      if (!ctx.hasUI) {
        ctx.ui.notify(`Usage: /think <${levels.join("|")}>`, "warning");
        return;
      }

      if (ctx.mode !== "tui") {
        const selected = await ctx.ui.select("Select thinking level", levels);
        if (selected && isThinkingLevel(selected)) pi.setThinkingLevel(selected);
        return;
      }

      const selected = await ctx.ui.custom<ModelThinkingLevel | undefined>((tui, theme, keybindings, done) => {
        const container = new Container();
        const searchInput = new Input();
        const listContainer = new Container();
        let selectList: SelectList;

        const rebuildList = () => {
          const query = searchInput.getValue();
          const matchingLevels = query ? fuzzyFilter(levels, query, (level) => level) : levels;
          selectList = new SelectList(
            matchingLevels.map((level) => {
              const markers = [
                level === ctx.thinkingLevel ? "current" : undefined,
                level === defaultLevel ? "default" : undefined
              ].filter((marker): marker is string => marker !== undefined);
              return {
                value: level,
                label: markers.length > 0 ? `${level} (${markers.join(", ")})` : level,
                description: THINKING_LEVEL_DESCRIPTIONS[level]
              };
            }),
            Math.min(Math.max(matchingLevels.length, 1), 10),
            {
              selectedPrefix: (text) => theme.fg("accent", text),
              selectedText: (text) => theme.fg("accent", text),
              description: (text) => theme.fg("muted", text),
              scrollInfo: (text) => theme.fg("muted", text),
              noMatch: (text) => theme.fg("warning", text)
            }
          );
          const currentIndex = matchingLevels.indexOf(ctx.thinkingLevel as ModelThinkingLevel);
          if (!query && currentIndex >= 0) selectList.setSelectedIndex(currentIndex);
          selectList.onSelect = (item) => done(item.value as ModelThinkingLevel);
          selectList.onCancel = () => done(undefined);
          listContainer.clear();
          listContainer.addChild(selectList);
        };

        container.addChild(new Text(theme.fg("accent", theme.bold(`Thinking level — ${model.id}`)), 1, 0));
        container.addChild(new Text(theme.fg("muted", "Type to fuzzy search • ↑↓ navigate • enter select • esc cancel"), 1, 0));
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
          }
        };
      });

      if (selected) pi.setThinkingLevel(selected);
    }
  });

  pi.on("session_start", (_event, ctx) => {
    refreshCompletionLevels(ctx);
  });

  pi.on("model_select", (_event, ctx) => {
    refreshCompletionLevels(ctx);
  });
}
