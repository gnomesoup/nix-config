---
name: ask
description: Helps when the model has multiple clarification questions for the user, especially numbered lists like 1, 2, 3. Use this when the assistant should gather several user answers efficiently and route them through the /ask command for an interactive tabbed questionnaire.
license: MIT
---

# Ask

Use this skill when you need multiple clarifications from the user and a plain text reply would be clumsy.

## When to use

Use this skill when:

- you have 2 or more clarification questions
- the questions are naturally presented as a numbered list
- you want the user to answer in an interactive questionnaire instead of a long freeform reply

## Workflow

1. Write the questions as a concise numbered list.
2. Prefer using the `ask_questions` tool directly when it is available.
3. If direct tool use is not available, tell the user they can run `/ask` with that exact block.
4. Keep each question short, specific, and independent.
5. Prefer multiple-choice style wording when possible because the `/ask` rewriter will try to infer options.

## Preferred output pattern

```text
I need a few clarifications before I proceed:

1. Which framework should I target?
2. Do you want TypeScript or JavaScript?
3. Should I optimize for implementation speed or long-term maintainability?

If the `ask_questions` tool is available, I'll open an interactive questionnaire for these now. Otherwise, you can run `/ask` with the questions above.
```

## Question types

The questionnaire supports three question types:

### Single (default)
Pick one option from a list. Use for standard multiple-choice questions.

```text
1. Which framework should I use? React, Vue, Svelte
```

### Checkbox
Yes/no or enable/disable toggle. Use for binary questions.

```text
2. Do you want TypeScript?
3. Should I add tests?
```

Questions phrased as "Do you want", "Should I", "Would you like", "Is it" will be automatically
inferred as checkbox questions with Yes/No toggles.

### Multi-select
Pick multiple options from a list. Use when the user can select several items.

```text
4. Which features do you need? Select all that apply: dark mode, search, export, notifications
5. Which of the following should be included? Types, tests, docs, CI
```

Questions phrased as "Which of the following", "Select all that apply", "Which features" will be
automatically inferred as multi-select questions. Users navigate with arrows and toggle options
with Space, then confirm with Enter.

## Authoring guidance

- Aim for 2-7 questions.
- Avoid compound questions.
- If a question has obvious options, mention them explicitly.
- For binary yes/no questions, phrase them naturally ("Do you want...?") so they become checkbox toggles.
- For questions where multiple selections make sense, use "Select all that apply" or "Which of the following" phrasing.
- Do not ask unnecessary questions just to use this workflow.
- If only one clarification is needed, ask it normally instead of using `/ask`.
- Prefer `ask_questions` over asking the user to manually run `/ask` when the tool is available.
