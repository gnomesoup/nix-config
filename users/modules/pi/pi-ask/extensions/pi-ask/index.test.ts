import assert from "node:assert/strict";
import { describe, test } from "node:test";
import { visibleWidth } from "@earendil-works/pi-tui";
import { getQuestionOptions, normalizeQuestion, wrapWithPrefix } from "./index.ts";

describe("custom answers", () => {
  for (const type of ["single", "multi", "checkbox"] as const) {
    test(`${type} questions always offer a custom answer`, () => {
      const question = normalizeQuestion(
        {
          id: type,
          label: type,
          prompt: `A ${type} question?`,
          options: [
            { value: "first", label: "First" },
            { value: "second", label: "Second" },
          ],
          allowOther: false,
          type,
        },
        0,
      );

      assert.equal(question.allowOther, true);
      const options = getQuestionOptions(question);
      assert.deepEqual(options.at(-1), {
        value: "__other__",
        label: "Write my own answer",
        isOther: true,
      });
    });
  }

  test("checkbox questions retain Yes and No before the custom answer", () => {
    const question = normalizeQuestion(
      {
        prompt: "Enable it?",
        type: "checkbox",
      },
      0,
    );

    assert.deepEqual(
      getQuestionOptions(question).map((option) => option.label),
      ["Yes", "No", "Write my own answer"],
    );
  });
});

describe("answer wrapping", () => {
  test("wraps long text without truncating it and preserves prefix indentation", () => {
    const text = "This is a deliberately long custom answer that must remain completely visible";
    const width = 24;
    const lines = wrapWithPrefix("> ", text, width);

    assert.ok(lines.length > 1);
    assert.ok(lines.every((line) => visibleWidth(line) <= width));
    assert.ok(lines.slice(1).every((line) => line.startsWith("  ")));
    assert.equal(
      lines.map((line) => line.slice(2).trim()).filter(Boolean).join(" "),
      text,
    );
    assert.ok(lines.every((line) => !line.includes("…") && !line.includes("...")));
  });
});
