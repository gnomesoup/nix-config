import { describe, expect, it, vi } from "vitest";
import {
  calendarModel,
  dateFromJournalPage,
  isValidIsoDate,
  localToday,
  OPEN_DATE_COMMAND,
  openDateWithDependencies,
} from "./journal-navigation.ts";

describe("journal date handling", () => {
  it("accepts only real ISO calendar dates", () => {
    expect(isValidIsoDate("2024-02-29")).toBe(true);
    expect(isValidIsoDate("2023-02-29")).toBe(false);
    expect(isValidIsoDate("2026-13-01")).toBe(false);
    expect(isValidIsoDate("2026-04-31")).toBe(false);
    expect(isValidIsoDate("2026-4-01")).toBe(false);
    expect(isValidIsoDate("not-a-date")).toBe(false);
  });

  it("formats today in local time rather than UTC", () => {
    const localDate = new Date(2026, 8, 11, 23, 30);
    expect(localToday(localDate)).toBe("2026-09-11");
  });

  it("matches only an exact configured journal path", () => {
    expect(dateFromJournalPage("Journal/2026-09-11")).toBe("2026-09-11");
    expect(dateFromJournalPage("Journal/2026-09-11/Notes")).toBeUndefined();
    expect(dateFromJournalPage("Journal/2026-09-11 extra")).toBeUndefined();
    expect(dateFromJournalPage("Daily/2026-09-11", "Daily/")).toBe("2026-09-11");
  });

  it("uses the current journal date and de-duplicates existing dates", () => {
    expect(
      calendarModel(
        "Journal/2026-09-11",
        [
          "Journal/2026-09-10",
          "Journal/2026-09-10",
          "Journal/2026-09-11",
          "Journal/2026-09-11/Child",
          "Other/2026-09-09",
        ],
        "Journal/",
        new Date(2026, 0, 1),
      ),
    ).toEqual({
      initialDate: "2026-09-11",
      existingDates: ["2026-09-10", "2026-09-11"],
    });
  });

  it("falls back to today outside the journal", () => {
    expect(
      calendarModel("index", [], "Journal/", new Date(2026, 8, 11)),
    ).toEqual({ initialDate: "2026-09-11", existingDates: [] });
  });
});

describe("opening a selected date", () => {
  it("closes the modal and invokes the template-aware command", async () => {
    const calls: string[] = [];
    const result = await openDateWithDependencies("2026-09-11", {
      hidePanel: async () => {
        calls.push("hide");
      },
      invokeOpenDate: async (date) => {
        calls.push(`${OPEN_DATE_COMMAND}:${date}`);
      },
      notify: vi.fn(),
    });

    expect(result).toBe(true);
    expect(calls).toEqual(["hide", `${OPEN_DATE_COMMAND}:2026-09-11`]);
  });

  it("rejects invalid dates before closing or invoking", async () => {
    const hidePanel = vi.fn(async () => undefined);
    const invokeOpenDate = vi.fn(async () => undefined);
    const notify = vi.fn(async () => undefined);

    const result = await openDateWithDependencies("2026-02-30", {
      hidePanel,
      invokeOpenDate,
      notify,
    });

    expect(result).toBe(false);
    expect(hidePanel).not.toHaveBeenCalled();
    expect(invokeOpenDate).not.toHaveBeenCalled();
    expect(notify).toHaveBeenCalledWith(
      "Journal calendar returned an invalid date.",
      "error",
    );
  });

  it("reports command failures", async () => {
    const notify = vi.fn(async () => undefined);
    const result = await openDateWithDependencies("2026-09-11", {
      hidePanel: async () => undefined,
      invokeOpenDate: async () => {
        throw new Error("failure");
      },
      notify,
    });

    expect(result).toBe(false);
    expect(notify).toHaveBeenCalledWith(
      "Could not open journal entry 2026-09-11.",
      "error",
    );
  });
});
