import { mkdir, readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { completeSimple, type Model, type UserMessage } from "@earendil-works/pi-ai/compat";
import { getAgentDir, getMarkdownTheme, getSettingsListTheme } from "@earendil-works/pi-coding-agent";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import {
  Container,
  Editor,
  type EditorTheme,
  Key,
  Markdown,
  matchesKey,
  SettingsList,
  Text,
  truncateToWidth,
} from "@earendil-works/pi-tui";
import { Type } from "typebox";

interface ParsedOption {
  value: string;
  label: string;
  description?: string;
}

interface ParsedQuestion {
  id: string;
  label: string;
  prompt: string;
  options: ParsedOption[];
  allowOther: boolean;
  type: "single" | "multi" | "checkbox";
}

interface ParsedQuestionSet {
  questions: ParsedQuestion[];
}

interface Answer {
  id: string;
  question: string;
  value: string;
  label: string;
  wasCustom: boolean;
  index?: number;
  values?: string[];
  labels?: string[];
  indices?: number[];
  type: "single" | "multi" | "checkbox";
}

interface AskSettings {
  model?: string;
}

interface MessageEntryLike {
  type: string;
  message?: {
    role?: string;
    content?: Array<{ type?: string; text?: string }>;
  };
}

interface AskCommandContext {
  hasUI: boolean;
  signal?: AbortSignal;
  model?: Model;
  ui: {
    notify(message: string, level: "info" | "success" | "warning" | "error"): void;
    setEditorText(text: string): void;
    custom<T>(factory: any): Promise<T>;
  };
  modelRegistry: {
    find(provider: string, id: string): Model | undefined;
    getApiKeyAndHeaders(model: Model): Promise<{
      ok: boolean;
      apiKey?: string;
      headers?: Record<string, string>;
      error?: string;
    }>;
  };
  sessionManager: {
    getBranch(): MessageEntryLike[];
  };
}

const DEFAULT_RECOMMENDED_MODEL = "openai/gpt-4.1-mini";
const SETTINGS_PATH = join(getAgentDir(), "pi-ask.json");

const ASK_SYSTEM_PROMPT = `You convert a raw assistant message containing clarification questions into JSON for an interactive questionnaire.

Return strict JSON only. No markdown. No explanation.

Schema:
{
  "questions": [
    {
      "id": "q1",
      "label": "Q1",
      "prompt": "full question text",
      "options": [
        { "value": "typescript", "label": "TypeScript" }
      ],
      "allowOther": true,
      "type": "single"
    }
  ]
}

Question types (set the "type" field):
- "single" — default. Pick one option from a list.
- "multi" — Pick multiple options. Use when the user can select several items ("which of", "select all that apply", "which features"). Provide 3-7 options. Set allowOther to false.
- "checkbox" — Yes/no toggle. Use for binary enable/disable or yes/no questions ("do you want", "should I", "is it"). Set options to [{ "value": "yes", "label": "Yes" }, { "value": "no", "label": "No" }] and allowOther to false.

Rules:
- Extract 1-7 distinct questions.
- Preserve the original meaning.
- Use short labels like Q1, Q2, Q3 unless a stronger short label is obvious.
- Infer 2-5 sensible options only when they are explicit or strongly implied.
- If no clear options exist, use an empty options array and set allowOther to true.
- Always set allowOther to true unless the question is strictly binary and fully covered by options.
- Keep prompts concise.
- Set "type" to "multi" when the user can select multiple items from a list.
- Set "type" to "checkbox" for yes/no or enable/disable questions.
- Default to "single" if unsure.
- Output valid JSON that can be parsed directly.
- Do NOT think or reason. Just output the JSON immediately.`;

const ASK_TOOL_PARAMS = Type.Object({
  text: Type.String({ description: "The raw numbered or bulleted clarification questions to present to the user" }),
});

export default function piAsk(pi: ExtensionAPI) {
  pi.registerCommand("ask", {
    description: "Turn a block of questions into an interactive tabbed questionnaire",
    handler: async (args, ctx) => {
      await runAskFlow(pi, ctx as AskCommandContext, args.trim() || getLastAssistantText(ctx as AskCommandContext));
    },
  });

  pi.registerCommand("ask-model", {
    description: "Show which model /ask will use",
    handler: async (_args, ctx) => {
      const source = await getConfiguredModelString();
      const resolved = await resolveAskModel(ctx as AskCommandContext);
      if (!resolved) {
        ctx.ui.notify("No model available for /ask", "error");
        return;
      }
      ctx.ui.notify(`/ask model: ${resolved.provider}/${resolved.id}${source ? ` (${source})` : " (current active model)"}`, "info");
    },
  });

  pi.registerCommand("ask-settings", {
    description: "Configure the default model used by /ask",
    handler: async (_args, ctx) => {
      const commandCtx = ctx as AskCommandContext;
      if (!commandCtx.hasUI) {
        commandCtx.ui.notify("/ask-settings requires interactive mode", "error");
        return;
      }

      const current = await loadSettings();
      const currentValue = current.model?.trim() || "current-session-model";

      const next = await commandCtx.ui.custom<AskSettings | null>((tui: any, theme: any, _kb: unknown, done: (value: AskSettings | null) => void) => {
        const items = [
          {
            id: "recommended",
            label: `Recommended (${DEFAULT_RECOMMENDED_MODEL})`,
            currentValue: currentValue === DEFAULT_RECOMMENDED_MODEL ? "selected" : "available",
            values: ["selected", "available"],
          },
          {
            id: "current-session-model",
            label: "Use current active model",
            currentValue: currentValue === "current-session-model" ? "selected" : "available",
            values: ["selected", "available"],
          },
          {
            id: "custom",
            label: "Custom provider/model-id",
            currentValue:
              currentValue !== DEFAULT_RECOMMENDED_MODEL && currentValue !== "current-session-model" ? "selected" : "available",
            values: ["selected", "available"],
          },
        ];

        const container = new Container();
        container.addChild(new Text(theme.fg("accent", theme.bold("Ask Settings")), 0, 0));
        container.addChild(
          new Text(theme.fg("muted", `Current: ${current.model || "use current active model"}`), 0, 0),
        );

        const settingsList = new SettingsList(
          items,
          Math.min(items.length + 4, 10),
          getSettingsListTheme(),
          async (id, newValue) => {
            if (newValue !== "selected") return;
            if (id === "recommended") {
              done({ model: DEFAULT_RECOMMENDED_MODEL });
              return;
            }
            if (id === "current-session-model") {
              done({ model: undefined });
              return;
            }
            if (id === "custom") {
              done({ model: "__custom__" });
            }
          },
          () => done(null),
        );

        container.addChild(settingsList);
        container.addChild(new Text(theme.fg("dim", "Enter select • Esc cancel"), 0, 0));

        return {
          render(width: number) {
            return container.render(width);
          },
          invalidate() {
            container.invalidate();
          },
          handleInput(data: string) {
            settingsList.handleInput?.(data);
            tui.requestRender();
          },
        };
      });

      if (next === null) {
        commandCtx.ui.notify("/ask-settings cancelled", "info");
        return;
      }

      if (next.model === "__custom__") {
        const custom = await promptForCustomModel(commandCtx);
        if (!custom) {
          commandCtx.ui.notify("Custom model entry cancelled", "info");
          return;
        }
        await saveSettings({ model: custom });
        commandCtx.ui.notify(`Saved /ask model: ${custom}`, "success");
        return;
      }

      await saveSettings(next);
      commandCtx.ui.notify(
        next.model ? `Saved /ask model: ${next.model}` : "Saved /ask to use the current active model",
        "success",
      );
    },
  });

  pi.registerTool({
    name: "ask_questions",
    label: "Ask Questions",
    description: "Show an interactive tabbed questionnaire to the user for a block of clarification questions.",
    promptSnippet: "Display a multi-question interactive clarification UI for the user.",
    promptGuidelines: [
      "Use this tool when you need the user to answer multiple clarification questions, especially numbered lists.",
      "Prefer this tool over asking several questions inline when an interactive questionnaire would be clearer.",
      "Prefer this tool as the primary flow when you need multiple clarifications from the user.",
    ],
    parameters: ASK_TOOL_PARAMS,
    async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
      const answers = await runAskFlow(pi, ctx as AskCommandContext, params.text, { emitSummaryMessage: false });
      if (!answers || answers.length === 0) {
        return {
          content: [{ type: "text", text: "User cancelled the questionnaire or no answers were captured." }],
          details: { cancelled: true, answers: [] },
        };
      }

      return {
        content: [{ type: "text", text: formatAnswerSummary(answers) }],
        details: { cancelled: false, answers },
      };
    },

    renderCall(args, theme) {
      return new Text(
        theme.fg("toolTitle", theme.bold("ask_questions ")) + theme.fg("muted", truncateToWidth(String(args.text ?? ""), 80)),
        0,
        0,
      );
    },

    renderResult(result, _options, theme) {
      const text = result.content
        .filter((part) => part.type === "text")
        .map((part) => part.text)
        .join("\n");
      return new Text(result.isError ? theme.fg("error", text) : text, 0, 0);
    },
  });

  pi.registerMessageRenderer("pi-ask-summary", (message, _options, theme) => {
    return new Text(
      theme.fg("accent", theme.bold("ask ")) + theme.fg("muted", "captured answers") + "\n" + String(message.content),
      0,
      0,
    );
  });
}

async function runAskFlow(
  pi: ExtensionAPI,
  ctx: AskCommandContext,
  rawInput: string | undefined,
  options: { emitSummaryMessage?: boolean } = {},
): Promise<Answer[] | null> {
  if (!ctx.hasUI) {
    ctx.ui.notify("/ask requires interactive mode", "error");
    return null;
  }

  const raw = rawInput?.trim();
  if (!raw) {
    ctx.ui.notify("Provide questions to /ask or run it right after a model message with questions.", "warning");
    return null;
  }

  const model = await resolveAskModel(ctx);
  if (!model) {
    ctx.ui.notify("No model available for /ask", "error");
    return null;
  }

  const parsed = await showPreparationLoader(ctx, model, raw);
  if (!parsed || parsed.questions.length === 0) {
    ctx.ui.notify("Could not build a questionnaire from that text", "error");
    return null;
  }

  // Herdr's Pi integration turns this shared event into semantic `blocked`
  // state, which drives its needs-input notifications and status rollups.
  pi.events.emit("herdr:blocked", { active: true, label: "Answer questionnaire" });
  let answers: Answer[] | null;
  try {
    answers = await showQuestionnaire(ctx, parsed.questions);
  } finally {
    pi.events.emit("herdr:blocked", { active: false });
  }
  if (!answers || answers.length === 0) {
    ctx.ui.notify("Questionnaire cancelled", "info");
    return null;
  }

  const reply = formatAnswerReply(answers);
  if (options.emitSummaryMessage !== false) {
    ctx.ui.setEditorText(reply);
    ctx.ui.notify("Answers loaded into the editor. Submit them to the main model when ready.", "success");
  } else {
    ctx.ui.setEditorText("");
    ctx.ui.notify("Answers sent to the model.", "success");
  }

  if (options.emitSummaryMessage !== false) {
    pi.sendMessage({
      customType: "pi-ask-summary",
      content: formatAnswerSummary(answers),
      display: true,
      details: { answers },
    });
  }

  return answers;
}

async function showPreparationLoader(ctx: AskCommandContext, model: Model, raw: string): Promise<ParsedQuestionSet | null> {
  return ctx.ui.custom<ParsedQuestionSet | null>((tui: any, theme: any, _kb: unknown, done: (value: ParsedQuestionSet | null) => void) => {
    let cancelled = false;
    let spinnerIndex = 0;
    let timer: ReturnType<typeof setInterval> | undefined;
    const spinnerFrames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"];
    const label = `Preparing questionnaire with ${model.provider}/${model.id}...`;

    const finish = (value: ParsedQuestionSet | null) => {
      if (timer) clearInterval(timer);
      done(value);
    };

    void parseQuestions(ctx, model, raw)
      .then((result) => {
        if (!cancelled) finish(result);
      })
      .catch(() => {
        if (!cancelled) finish(null);
      });

    timer = setInterval(() => {
      spinnerIndex = (spinnerIndex + 1) % spinnerFrames.length;
      tui.requestRender();
    }, 100);

    return {
      render(width: number): string[] {
        return [
          truncateToWidth(theme.fg("accent", `${spinnerFrames[spinnerIndex]} ${label}`), width),
          truncateToWidth(theme.fg("dim", "Esc to cancel"), width),
        ];
      },
      invalidate() {},
      handleInput(data: string) {
        if (matchesKey(data, Key.escape)) {
          cancelled = true;
          finish(null);
        }
      },
    };
  });
}

function getLastAssistantText(ctx: AskCommandContext): string | undefined {
  const branch = ctx.sessionManager.getBranch();
  for (let index = branch.length - 1; index >= 0; index -= 1) {
    const entry = branch[index];
    if (entry.type !== "message") continue;
    const message = entry.message;
    if (!message || message.role !== "assistant") continue;

    const text = (message.content ?? [])
      .filter((part) => part.type === "text" && typeof part.text === "string")
      .map((part) => part.text ?? "")
      .join("\n")
      .trim();

    if (text) return text;
  }
  return undefined;
}

async function loadSettings(): Promise<AskSettings> {
  try {
    const raw = await readFile(SETTINGS_PATH, "utf8");
    const parsed = JSON.parse(raw) as AskSettings;
    return typeof parsed === "object" && parsed ? parsed : {};
  } catch {
    return {};
  }
}

async function saveSettings(settings: AskSettings): Promise<void> {
  await mkdir(getAgentDir(), { recursive: true });
  await writeFile(SETTINGS_PATH, `${JSON.stringify(settings, null, 2)}\n`, "utf8");
}

async function getConfiguredModelString(): Promise<string | undefined> {
  const envConfigured = process.env.PI_ASK_MODEL?.trim();
  if (envConfigured) return "from PI_ASK_MODEL";

  const settings = await loadSettings();
  if (settings.model?.trim()) return "from /ask-settings";
  return undefined;
}

async function resolveAskModel(ctx: AskCommandContext): Promise<Model | undefined> {
  const envConfigured = process.env.PI_ASK_MODEL?.trim();
  const settings = await loadSettings();
  const configured = envConfigured || settings.model?.trim();
  if (!configured) return ctx.model;

  const [provider, ...rest] = configured.split("/");
  const id = rest.join("/");
  if (!provider || !id) return ctx.model;
  return ctx.modelRegistry.find(provider, id) ?? ctx.model;
}

async function promptForCustomModel(ctx: AskCommandContext): Promise<string | null> {
  return ctx.ui.custom<string | null>((tui: any, theme: any, _kb: unknown, done: (value: string | null) => void) => {
    let cachedLines: string[] | undefined;
    const editorTheme: EditorTheme = {
      borderColor: (s) => theme.fg("accent", s),
      selectList: {
        selectedPrefix: (t) => theme.fg("accent", t),
        selectedText: (t) => theme.fg("accent", t),
        description: (t) => theme.fg("muted", t),
        scrollInfo: (t) => theme.fg("dim", t),
        noMatch: (t) => theme.fg("warning", t),
      },
    };
    const editor = new Editor(tui, editorTheme);
    editor.setText(DEFAULT_RECOMMENDED_MODEL);
    editor.onSubmit = (value) => {
      const trimmed = value.trim();
      if (!trimmed) {
        done(null);
        return;
      }
      done(trimmed);
    };

    return {
      render(width: number): string[] {
        if (cachedLines) return cachedLines;
        const lines: string[] = [];
        const add = (value: string) => lines.push(truncateToWidth(value, width));
        add(theme.fg("accent", theme.bold("Custom /ask model")));
        add(theme.fg("muted", "Enter provider/model-id"));
        lines.push("");
        for (const line of editor.render(Math.max(20, width - 2))) {
          add(` ${line}`);
        }
        lines.push("");
        add(theme.fg("dim", "Enter save • Esc cancel"));
        cachedLines = lines;
        return lines;
      },
      invalidate() {
        cachedLines = undefined;
      },
      handleInput(data: string) {
        if (matchesKey(data, Key.escape)) {
          done(null);
          return;
        }
        editor.handleInput(data);
        cachedLines = undefined;
        tui.requestRender();
      },
    };
  });
}

async function parseQuestions(ctx: AskCommandContext, model: Model, raw: string): Promise<ParsedQuestionSet> {
  const auth = await ctx.modelRegistry.getApiKeyAndHeaders(model);
  if (!auth.ok || !auth.apiKey) {
    throw new Error(auth.ok ? `No API key for ${model.provider}` : auth.error);
  }

  const userMessage: UserMessage = {
    role: "user",
    content: [{ type: "text", text: raw }],
    timestamp: Date.now(),
  };

  const response = await completeSimple(
    model,
    { systemPrompt: ASK_SYSTEM_PROMPT, messages: [userMessage] },
    { apiKey: auth.apiKey, headers: auth.headers, signal: ctx.signal, reasoning: "minimal" },
  );

  const text = response.content
    .filter((part): part is { type: "text"; text: string } => part.type === "text")
    .map((part) => part.text)
    .join("\n")
    .trim();

  return normalizeQuestionSet(parseQuestionSet(text, raw));
}

function parseQuestionSet(modelOutput: string, raw: string): ParsedQuestionSet {
  try {
    return JSON.parse(stripJsonFence(modelOutput)) as ParsedQuestionSet;
  } catch {
    return fallbackParseQuestions(raw);
  }
}

function normalizeQuestionSet(input: ParsedQuestionSet): ParsedQuestionSet {
  const questions = Array.isArray(input.questions) ? input.questions : [];

  return {
    questions: questions
      .map((question, index) => normalizeQuestion(question, index))
      .filter((question): question is ParsedQuestion => Boolean(question.prompt))
      .slice(0, 7)
      .map((question, index) => ({ ...question, label: String(index + 1) })),
  };
}

function normalizeQuestion(question: Partial<ParsedQuestion>, index: number): ParsedQuestion {
  const prompt = String(question.prompt ?? "").trim();
  const label = String(question.label ?? `${index + 1}`).trim() || `${index + 1}`;
  const id = slugify(question.id || label || `q${index + 1}`) || `q${index + 1}`;
  let type: "single" | "multi" | "checkbox" =
    question.type === "multi" || question.type === "checkbox" ? question.type : "single";
  const options = Array.isArray(question.options)
    ? question.options
        .map((option) => ({
          value: String(option?.value ?? option?.label ?? "").trim(),
          label: String(option?.label ?? option?.value ?? "").trim(),
          description: typeof option?.description === "string" ? option.description.trim() : undefined,
        }))
        .filter((option) => option.value && option.label)
        .slice(0, type === "multi" ? 7 : 5)
    : [];

  // Checkbox: force Yes/No options, no allowOther
  if (type === "checkbox") {
    return {
      id,
      label,
      prompt,
      options: options.length >= 2 ? options.slice(0, 2) : [{ value: "yes", label: "Yes" }, { value: "no", label: "No" }],
      allowOther: false,
      type: "checkbox",
    };
  }

  // Multi with too few options: downgrade to single
  if (type === "multi" && options.length < 2) {
    type = "single";
  }

  return {
    id,
    label,
    prompt,
    options,
    allowOther: type === "multi" ? false : question.allowOther !== false,
    type,
  };
}

function inferQuestionType(prompt: string): "single" | "multi" | "checkbox" {
  const lower = prompt.toLowerCase();
  if (/\b(all that apply|select all|which of the following|which features|which options|choose all|pick all|select multiple)\b/i.test(prompt)) {
    return "multi";
  }
  if (/\b(do you want|should i|should we|is it|do you need|would you like|do you prefer)\b/i.test(prompt) && !/\bor\b/i.test(prompt)) {
    return "checkbox";
  }
  return "single";
}

function fallbackParseQuestions(raw: string): ParsedQuestionSet {
  const lines = raw
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter(Boolean);

  const extracted = lines
    .map((line) => line.replace(/^\d+[.)]\s*/, "").replace(/^[-*]\s*/, "").trim())
    .filter((line) => /\?$/.test(line) || /^(which|what|when|where|who|why|how|do|does|did|is|are|can|could|should|would|will)\b/i.test(line));

  const questions = extracted.map((prompt, index) => {
    const type = inferQuestionType(prompt);
    const options = type === "checkbox" ? [{ value: "yes", label: "Yes" }, { value: "no", label: "No" }] : inferOptionsFromPrompt(prompt);
    return {
      id: `q${index + 1}`,
      label: `${index + 1}`,
      prompt,
      options,
      allowOther: type !== "checkbox",
      type,
    } as ParsedQuestion;
  });

  return { questions };
}

function inferOptionsFromPrompt(prompt: string): ParsedOption[] {
  const orMatch = prompt.match(/\b(.+?)\s+or\s+(.+?)(\?|$)/i);
  if (!orMatch) return [];

  const first = cleanOptionLabel(orMatch[1]);
  const second = cleanOptionLabel(orMatch[2]);
  const options = [first, second].filter(Boolean);
  if (options.length < 2) return [];

  return options.slice(0, 5).map((label) => ({ value: slugify(label), label }));
}

function cleanOptionLabel(value: string): string {
  return value
    .replace(/^(which|what|do you want|should i|should we|do we want)\s+/i, "")
    .replace(/[?.!,;:]+$/g, "")
    .trim();
}

function slugify(value: string): string {
  return value
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .replace(/-{2,}/g, "-");
}

function stripJsonFence(text: string): string {
  const trimmed = text.trim();
  if (trimmed.startsWith("```") && trimmed.endsWith("```")) {
    return trimmed.replace(/^```(?:json)?\s*/, "").replace(/\s*```$/, "");
  }
  return trimmed;
}

function formatAnswerSummary(answers: Answer[]): string {
  return answers
    .map((answer, index) => {
      if (answer.type === "multi" && answer.labels && answer.labels.length > 1) {
        return `${index + 1}. ${answer.question} — ${answer.labels.join(", ")}`;
      }
      return `${index + 1}. ${answer.question} — ${answer.label}`;
    })
    .join("\n");
}

function formatAnswerReply(answers: Answer[]): string {
  return answers
    .map((answer, index) => {
      if (answer.type === "multi" && answer.labels && answer.labels.length > 1) {
        const items = answer.labels.map((label) => `  - ${label}`).join("\n");
        return `${index + 1}. ${answer.question}\nAnswer:\n${items}`;
      }
      return `${index + 1}. ${answer.question}\nAnswer: ${answer.label}`;
    })
    .join("\n\n");
}

async function showQuestionnaire(ctx: AskCommandContext, questions: ParsedQuestion[]): Promise<Answer[] | null> {
  return ctx.ui.custom<Answer[] | null>((tui: any, theme: any, keybindings: any, done: (value: Answer[] | null) => void) => {
    let currentTab = 0;
    let optionIndex = 0;
    let inputMode = false;
    let scrollOffset = 0;
    let maxScrollOffset = 0;
    let promptViewportHeight = 1;
    let cachedLines: string[] | undefined;
    const answers = new Map<string, Answer>();
    const multiSelectedIndices = new Map<string, Set<number>>();
    const submitTabIndex = questions.length;

    const editorTheme: EditorTheme = {
      borderColor: (s) => theme.fg("accent", s),
      selectList: {
        selectedPrefix: (t) => theme.fg("accent", t),
        selectedText: (t) => theme.fg("accent", t),
        description: (t) => theme.fg("muted", t),
        scrollInfo: (t) => theme.fg("dim", t),
        noMatch: (t) => theme.fg("warning", t),
      },
    };
    const editor = new Editor(tui, editorTheme);

    const refresh = () => {
      cachedLines = undefined;
      tui.requestRender();
    };

    const getOptions = (question: ParsedQuestion): Array<ParsedOption & { isOther?: boolean }> => {
      if (question.type === "checkbox") {
        return [
          { value: "yes", label: "Yes" },
          { value: "no", label: "No" },
        ];
      }
      const options = [...question.options];
      if (question.type !== "multi" && (question.allowOther || options.length === 0)) {
        options.push({ value: "__other__", label: "Write my own answer", isOther: true } as ParsedOption & { isOther: boolean });
      }
      return options;
    };

    const getMultiSelectedSet = (question: ParsedQuestion): Set<number> => {
      if (multiSelectedIndices.has(question.id)) {
        return multiSelectedIndices.get(question.id)!;
      }
      if (answers.has(question.id)) {
        const answer = answers.get(question.id)!;
        const set = new Set(answer.indices || []);
        multiSelectedIndices.set(question.id, set);
        return set;
      }
      const set = new Set<number>();
      multiSelectedIndices.set(question.id, set);
      return set;
    };

    const saveAnswer = (
      question: ParsedQuestion,
      answer: { value: string; label: string; wasCustom: boolean; index?: number; type?: "single" | "multi" | "checkbox" },
    ) => {
      answers.set(question.id, {
        id: question.id,
        question: question.prompt,
        value: answer.value,
        label: answer.label,
        wasCustom: answer.wasCustom,
        index: answer.index,
        type: answer.type || question.type || "single",
      });
    };

    editor.onSubmit = (value) => {
      const question = questions[currentTab];
      const trimmed = value.trim();
      if (!question || !trimmed) return;
      saveAnswer(question, { value: trimmed, label: trimmed, wasCustom: true, type: "single" });
      inputMode = false;
      editor.setText("");
      currentTab = currentTab < questions.length - 1 ? currentTab + 1 : submitTabIndex;
      scrollOffset = 0;
      refresh();
    };

    return {
      render(width: number): string[] {
        if (cachedLines) return cachedLines;

        const lines: string[] = [];
        const add = (value: string) => lines.push(truncateToWidth(value, width));
        let promptRange: { start: number; end: number } | undefined;
        const question = currentTab < questions.length ? questions[currentTab] : undefined;
        const options = question ? getOptions(question) : [];
        const answeredCount = answers.size;
        const allAnswered = answeredCount === questions.length;

        add(theme.fg("accent", "─".repeat(width)));
        add(
          ` ${[
            ...questions.map((item, index) => {
              const active = index === currentTab;
              const answered = answers.has(item.id);
              const typeIcon = item.type === "multi" ? " ≡" : item.type === "checkbox" ? " ☑" : "";
              const label = ` ${answered ? "■" : "□"} ${item.label}${typeIcon} `;
              if (active) return theme.bg("selectedBg", theme.fg("text", label));
              return theme.fg(answered ? "success" : "muted", label);
            }),
            (() => {
              const active = currentTab === submitTabIndex;
              const label = ` ${allAnswered ? "✓" : "→"} Submit `;
              if (active) return theme.bg("selectedBg", theme.fg(allAnswered ? "success" : "text", label));
              return theme.fg(allAnswered ? "success" : "dim", label);
            })(),
          ].join(" ")}`,
        );
        lines.push("");
        add(theme.fg("muted", ` Progress: ${answeredCount}/${questions.length} answered`));
        lines.push("");

        if (question) {
          const promptStart = lines.length;
          const prompt = new Markdown(question.prompt, 1, 0, getMarkdownTheme());
          lines.push(...prompt.render(width));
          promptRange = { start: promptStart, end: lines.length };
          if (question.type === "multi") {
            add(theme.fg("dim", ` (select multiple)`));
          } else if (question.type === "checkbox") {
            add(theme.fg("dim", ` (yes / no)`));
          }
          lines.push("");

          if (question.type === "checkbox") {
            options.forEach((option, i) => {
              const selected = i === optionIndex;
              const marker = selected ? "●" : "○";
              const prefix = selected ? theme.fg("accent", "> ") : "  ";
              const text = `[${marker}] ${option.label}`;
              add(prefix + (selected ? theme.fg("accent", text) : theme.fg("text", text)));
            });
          } else if (question.type === "multi") {
            const selectedSet = getMultiSelectedSet(question);
            options.forEach((option, i) => {
              const selected = i === optionIndex;
              const checked = selectedSet.has(i);
              const marker = checked ? "■" : "□";
              const prefix = selected ? theme.fg("accent", "> ") : "  ";
              const text = `[${marker}] ${option.label}`;
              add(prefix + (selected ? theme.fg("accent", text) : theme.fg("text", text)));
              if (option.description) add(`     ${theme.fg("muted", option.description)}`);
            });
            if (selectedSet.size > 0) {
              lines.push("");
              add(theme.fg("success", ` ${selectedSet.size} selected`));
            }
          } else {
            options.forEach((option, index) => {
              const selected = index === optionIndex;
              const prefix = selected ? theme.fg("accent", "> ") : "  ";
              const text = `${index + 1}. ${option.label}`;
              add(prefix + (selected ? theme.fg("accent", text) : theme.fg("text", text)));
              if (option.description) add(`     ${theme.fg("muted", option.description)}`);
            });
          }

          const answered = answers.get(question.id);
          if (answered && !inputMode && question.type !== "multi") {
            lines.push("");
            add(theme.fg("success", ` Current answer: ${answered.label}`));
          }
        } else {
          add(theme.fg("accent", theme.bold(" Submit answers")));
          lines.push("");
          if (allAnswered) {
            questions.forEach((item, index) => {
              const answer = answers.get(item.id);
              if (answer) {
                if (answer.type === "multi" && answer.labels && answer.labels.length > 1) {
                  add(theme.fg("text", ` ${index + 1}. ${answer.labels.join(", ")}`));
                } else {
                  add(theme.fg("text", ` ${index + 1}. ${answer.label}`));
                }
              }
            });
            lines.push("");
            add(theme.fg("success", " Press Enter to finish"));
          } else {
            const missing = questions
              .map((item, index) => (!answers.has(item.id) ? String(index + 1) : null))
              .filter((value): value is string => Boolean(value));
            add(theme.fg("warning", ` Answer all questions before submitting`));
            if (missing.length > 0) {
              add(theme.fg("warning", ` Missing: ${missing.join(", ")}`));
            }
          }
        }

        lines.push("");
        if (inputMode) {
          add(theme.fg("muted", " Your answer:"));
          for (const line of editor.render(Math.max(10, width - 2))) {
            add(` ${line}`);
          }
          lines.push("");
          add(theme.fg("dim", " Enter submit • Esc back"));
        } else if (question?.type === "multi") {
          add(theme.fg("dim", " Tab/←→ switch tabs • ↑↓ navigate • Space toggle • Enter confirm • Esc cancel"));
        } else {
          add(theme.fg("dim", " Tab/←→ switch tabs • ↑↓ select • Enter confirm • Esc cancel"));
        }

        add(theme.fg("accent", "─".repeat(width)));

        if (promptRange) {
          const terminalHeight = tui.terminal?.rows ?? 24;
          const maxQuestionnaireHeight = Math.max(8, terminalHeight - 3);
          const promptLines = lines.slice(promptRange.start, promptRange.end);
          const staticLineCount = lines.length - promptLines.length;

          if (lines.length > maxQuestionnaireHeight) {
            const availablePromptHeight = maxQuestionnaireHeight - staticLineCount;
            const showScrollStatus = availablePromptHeight >= 2;
            promptViewportHeight = Math.max(1, availablePromptHeight - (showScrollStatus ? 1 : 0));
            maxScrollOffset = Math.max(0, promptLines.length - promptViewportHeight);
            scrollOffset = Math.min(scrollOffset, maxScrollOffset);

            const visiblePrompt = promptLines.slice(scrollOffset, scrollOffset + promptViewportHeight);
            const firstVisibleLine = scrollOffset + 1;
            const lastVisibleLine = Math.min(scrollOffset + promptViewportHeight, promptLines.length);
            const scrollStatus = theme.fg(
              "dim",
              ` Question lines ${firstVisibleLine}-${lastVisibleLine}/${promptLines.length} • PgUp/PgDn scroll`,
            );
            const visibleLines = [
              ...lines.slice(0, promptRange.start),
              ...visiblePrompt,
              ...(showScrollStatus ? [truncateToWidth(scrollStatus, width)] : []),
              ...lines.slice(promptRange.end),
            ];
            cachedLines = visibleLines;
            return visibleLines;
          }
        }

        scrollOffset = 0;
        maxScrollOffset = 0;
        promptViewportHeight = 1;
        cachedLines = lines;
        return lines;
      },
      invalidate() {
        cachedLines = undefined;
      },
      handleInput(data: string) {
        const question = currentTab < questions.length ? questions[currentTab] : undefined;
        const options = question ? getOptions(question) : [];
        const allAnswered = answers.size === questions.length;

        if (inputMode) {
          if (matchesKey(data, Key.escape)) {
            inputMode = false;
            editor.setText("");
            refresh();
            return;
          }
          editor.handleInput(data);
          refresh();
          return;
        }

        if (matchesKey(data, Key.tab) || matchesKey(data, Key.right)) {
          currentTab = (currentTab + 1) % (questions.length + 1);
          optionIndex = 0;
          scrollOffset = 0;
          refresh();
          return;
        }
        if (matchesKey(data, Key.shift("tab")) || matchesKey(data, Key.left)) {
          currentTab = (currentTab - 1 + questions.length + 1) % (questions.length + 1);
          optionIndex = 0;
          scrollOffset = 0;
          refresh();
          return;
        }
        if (
          keybindings.matches(data, "tui.select.pageUp") ||
          keybindings.matches(data, "tui.editor.pageUp")
        ) {
          scrollOffset = Math.max(0, scrollOffset - Math.max(1, promptViewportHeight - 1));
          refresh();
          return;
        }
        if (
          keybindings.matches(data, "tui.select.pageDown") ||
          keybindings.matches(data, "tui.editor.pageDown")
        ) {
          scrollOffset = Math.min(maxScrollOffset, scrollOffset + Math.max(1, promptViewportHeight - 1));
          refresh();
          return;
        }
        if (matchesKey(data, Key.up)) {
          optionIndex = Math.max(0, optionIndex - 1);
          refresh();
          return;
        }
        if (matchesKey(data, Key.down)) {
          optionIndex = Math.min(options.length - 1, optionIndex + 1);
          refresh();
          return;
        }

        // Space key — toggle multi-select option
        if (data === " " && question?.type === "multi") {
          const set = getMultiSelectedSet(question);
          if (set.has(optionIndex)) {
            set.delete(optionIndex);
          } else {
            set.add(optionIndex);
          }
          refresh();
          return;
        }

        if (matchesKey(data, Key.enter)) {
          if (!question) {
            if (allAnswered) {
              done(questions.map((q) => answers.get(q.id)).filter((a): a is Answer => Boolean(a)));
            }
            return;
          }

          if (question.type === "checkbox") {
            const selected = options[optionIndex];
            if (!selected) return;
            saveAnswer(question, {
              value: selected.value,
              label: selected.label,
              wasCustom: false,
              index: optionIndex,
              type: "checkbox",
            });
            currentTab = currentTab < questions.length - 1 ? currentTab + 1 : submitTabIndex;
            optionIndex = 0;
            scrollOffset = 0;
            refresh();
            return;
          }

          if (question.type === "multi") {
            const set = getMultiSelectedSet(question);
            if (set.size === 0) {
              // No selections — toggle current item as a convenience
              set.add(optionIndex);
              refresh();
              return;
            }
            const sortedIndices = [...set].sort((a, b) => a - b);
            const questionOptions = question.options;
            const selectedOptions = sortedIndices.map((i) => questionOptions[i]).filter(Boolean);
            answers.set(question.id, {
              id: question.id,
              question: question.prompt,
              value: selectedOptions.map((o) => o.value).join(", "),
              label: selectedOptions.map((o) => o.label).join(", "),
              wasCustom: false,
              index: sortedIndices[0],
              values: selectedOptions.map((o) => o.value),
              labels: selectedOptions.map((o) => o.label),
              indices: sortedIndices,
              type: "multi",
            });
            currentTab = currentTab < questions.length - 1 ? currentTab + 1 : submitTabIndex;
            optionIndex = 0;
            scrollOffset = 0;
            refresh();
            return;
          }

          // Single select (default)
          const selected = options[optionIndex];
          if (!selected) return;
          if (selected.isOther) {
            inputMode = true;
            editor.setText("");
            refresh();
            return;
          }
          saveAnswer(question, {
            value: selected.value,
            label: selected.label,
            wasCustom: false,
            index: optionIndex + 1,
            type: "single",
          });
          currentTab = currentTab < questions.length - 1 ? currentTab + 1 : submitTabIndex;
          optionIndex = 0;
          scrollOffset = 0;
          refresh();
          return;
        }
        if (matchesKey(data, Key.escape)) {
          done(null);
        }
      },
    };
  });
}
