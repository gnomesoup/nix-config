import {
  editor,
  space,
  system,
} from "@silverbulletmd/silverbullet/syscalls";
import { panelStyles } from "@silverbulletmd/silverbullet/ui";

export const DEFAULT_JOURNAL_PREFIX = "Journal/";
export const OPEN_DATE_COMMAND = "Journal: Open Date";
export const PANEL_FUNCTION = "silverbullet-journal-navigation.openDate";

export interface CalendarModel {
  initialDate: string;
  existingDates: string[];
}

export interface OpenDateDependencies {
  hidePanel(): Promise<void>;
  invokeOpenDate(date: string): Promise<unknown>;
  notify(message: string, type?: "info" | "error"): Promise<void>;
}

const runtimeOpenDateDependencies: OpenDateDependencies = {
  hidePanel: () => editor.hidePanel("modal"),
  invokeOpenDate: (date) => system.invokeCommand(OPEN_DATE_COMMAND, [date]),
  notify: (message, type) => editor.flashNotification(message, type),
};

function pad(value: number): string {
  return String(value).padStart(2, "0");
}

export function localToday(now = new Date()): string {
  return `${now.getFullYear()}-${pad(now.getMonth() + 1)}-${pad(now.getDate())}`;
}

export function isValidIsoDate(value: unknown): value is string {
  if (typeof value !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(value)) {
    return false;
  }
  const [year, month, day] = value.split("-").map(Number);
  const parsed = new Date(Date.UTC(year, month - 1, day));
  return parsed.getUTCFullYear() === year &&
    parsed.getUTCMonth() === month - 1 && parsed.getUTCDate() === day;
}

export function dateFromJournalPage(
  pageName: string | undefined,
  prefix = DEFAULT_JOURNAL_PREFIX,
): string | undefined {
  if (!pageName?.startsWith(prefix)) return undefined;
  const candidate = pageName.slice(prefix.length);
  return isValidIsoDate(candidate) ? candidate : undefined;
}

export function calendarModel(
  currentPage: string | undefined,
  pageNames: readonly string[],
  prefix = DEFAULT_JOURNAL_PREFIX,
  now = new Date(),
): CalendarModel {
  const existingDates = Array.from(
    new Set(
      pageNames
        .map((pageName) => dateFromJournalPage(pageName, prefix))
        .filter((date): date is string => Boolean(date)),
    ),
  ).sort();
  return {
    initialDate: dateFromJournalPage(currentPage, prefix) ?? localToday(now),
    existingDates,
  };
}

function calendarScript(model: CalendarModel): string {
  const serialized = JSON.stringify(model);
  return `(() => {
    const model = ${serialized};
    const existing = new Set(model.existingDates);
    const initialParts = model.initialDate.split("-").map(Number);
    let shownYear = initialParts[0];
    let shownMonth = initialParts[1] - 1;
    const today = (() => {
      const now = new Date();
      const pad = (value) => String(value).padStart(2, "0");
      return now.getFullYear() + "-" + pad(now.getMonth() + 1) + "-" + pad(now.getDate());
    })();
    const title = document.querySelector("#journal-calendar-title");
    const grid = document.querySelector("#journal-calendar-grid");
    const status = document.querySelector("#journal-calendar-status");
    const pad = (value) => String(value).padStart(2, "0");
    const isoDate = (year, month, day) => year + "-" + pad(month + 1) + "-" + pad(day);

    const openDate = async (date) => {
      status.textContent = "Opening " + date + "…";
      document.querySelectorAll("button").forEach((button) => button.disabled = true);
      try {
        await syscall("system.invokeFunction", "${PANEL_FUNCTION}", date);
      } catch (error) {
        status.textContent = error instanceof Error ? error.message : String(error);
        document.querySelectorAll("button").forEach((button) => button.disabled = false);
      }
    };

    const render = () => {
      const first = new Date(shownYear, shownMonth, 1);
      const daysInMonth = new Date(shownYear, shownMonth + 1, 0).getDate();
      const leadingDays = first.getDay();
      title.textContent = first.toLocaleDateString(undefined, { month: "long", year: "numeric" });
      grid.replaceChildren();

      for (let index = 0; index < 42; index += 1) {
        const day = index - leadingDays + 1;
        const button = document.createElement("button");
        button.type = "button";
        button.className = "journal-calendar-day";
        if (day < 1 || day > daysInMonth) {
          button.classList.add("outside");
          button.disabled = true;
          button.setAttribute("aria-hidden", "true");
        } else {
          const date = isoDate(shownYear, shownMonth, day);
          button.textContent = String(day);
          button.setAttribute("aria-label", new Date(shownYear, shownMonth, day).toLocaleDateString());
          if (existing.has(date)) button.classList.add("exists");
          if (date === today) button.classList.add("today");
          if (date === model.initialDate) button.classList.add("selected");
          button.addEventListener("click", () => openDate(date));
        }
        grid.appendChild(button);
      }
    };

    document.querySelector("#journal-calendar-previous").addEventListener("click", () => {
      shownMonth -= 1;
      if (shownMonth < 0) {
        shownMonth = 11;
        shownYear -= 1;
      }
      render();
    });
    document.querySelector("#journal-calendar-next").addEventListener("click", () => {
      shownMonth += 1;
      if (shownMonth > 11) {
        shownMonth = 0;
        shownYear += 1;
      }
      render();
    });
    document.querySelector("#journal-calendar-today").addEventListener("click", () => openDate(today));
    document.querySelector("#journal-calendar-close").addEventListener("click", () => syscall("editor.hidePanel", "modal"));
    globalThis.addEventListener("keydown", (event) => {
      if (event.key === "Escape") syscall("editor.hidePanel", "modal");
    });
    render();
  })();`;
}

export async function buildCalendarPanel(model: CalendarModel): Promise<{
  html: string;
  script: string;
}> {
  const styles = await panelStyles();
  return {
    html: `${styles}
<style>
  :root { color-scheme: light dark; }
  * { box-sizing: border-box; }
  body {
    min-height: 100vh;
    margin: 0;
    display: grid;
    place-items: center;
    background: var(--root-background-color, transparent);
    color: var(--root-color, inherit);
    font-family: system-ui, sans-serif;
  }
  .journal-calendar {
    width: min(25rem, calc(100vw - 1.5rem));
    padding: 1rem;
    border: 1px solid var(--editor-widget-border-color, #7776);
    border-radius: .75rem;
    background: var(--editor-widget-background-color, var(--root-background-color, Canvas));
    box-shadow: 0 .8rem 2.5rem #0004;
  }
  .journal-calendar-header,
  .journal-calendar-footer {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: .5rem;
  }
  .journal-calendar-header { margin-bottom: .75rem; }
  .journal-calendar-header strong { text-align: center; flex: 1; }
  .journal-calendar-weekdays,
  .journal-calendar-grid {
    display: grid;
    grid-template-columns: repeat(7, minmax(0, 1fr));
    gap: .25rem;
  }
  .journal-calendar-weekdays span {
    padding: .25rem 0;
    text-align: center;
    font-size: .75rem;
    opacity: .65;
  }
  button {
    border: 1px solid transparent;
    border-radius: .4rem;
    background: transparent;
    color: inherit;
    font: inherit;
    cursor: pointer;
  }
  button:hover:not(:disabled),
  button:focus-visible {
    border-color: var(--accent-color, Highlight);
    outline: none;
  }
  .journal-calendar-header button { width: 2.25rem; height: 2.25rem; font-size: 1.25rem; }
  .journal-calendar-day {
    position: relative;
    min-height: 2.5rem;
  }
  .journal-calendar-day.outside { cursor: default; }
  .journal-calendar-day.exists::after {
    content: "";
    position: absolute;
    left: 50%;
    bottom: .2rem;
    width: .3rem;
    height: .3rem;
    border-radius: 50%;
    background: var(--accent-color, Highlight);
    transform: translateX(-50%);
  }
  .journal-calendar-day.today { border-color: var(--accent-color, Highlight); }
  .journal-calendar-day.selected { font-weight: 700; background: color-mix(in srgb, var(--accent-color, Highlight) 18%, transparent); }
  .journal-calendar-footer { margin-top: .8rem; }
  .journal-calendar-footer button { padding: .45rem .7rem; }
  #journal-calendar-status { min-height: 1.25rem; font-size: .8rem; opacity: .7; }
</style>
<section class="journal-calendar" aria-labelledby="journal-calendar-title">
  <header class="journal-calendar-header">
    <button id="journal-calendar-previous" type="button" aria-label="Previous month">‹</button>
    <strong id="journal-calendar-title"></strong>
    <button id="journal-calendar-next" type="button" aria-label="Next month">›</button>
  </header>
  <div class="journal-calendar-weekdays" aria-hidden="true">
    <span>Sun</span><span>Mon</span><span>Tue</span><span>Wed</span><span>Thu</span><span>Fri</span><span>Sat</span>
  </div>
  <div id="journal-calendar-grid" class="journal-calendar-grid" role="grid"></div>
  <footer class="journal-calendar-footer">
    <button id="journal-calendar-today" type="button">Today</button>
    <span id="journal-calendar-status" role="status" aria-live="polite"></span>
    <button id="journal-calendar-close" type="button">Close</button>
  </footer>
</section>`,
    script: calendarScript(model),
  };
}

export async function openCalendar(): Promise<void> {
  const [currentPage, pages, configuredPrefix] = await Promise.all([
    editor.getCurrentPage(),
    space.listPages(),
    system.getConfig<string>("journal.prefix", DEFAULT_JOURNAL_PREFIX),
  ]);
  const prefix = typeof configuredPrefix === "string" && configuredPrefix
    ? configuredPrefix
    : DEFAULT_JOURNAL_PREFIX;
  const model = calendarModel(
    currentPage,
    pages.map((page) => page.name),
    prefix,
  );
  const panel = await buildCalendarPanel(model);
  await editor.showPanel("modal", 16, panel.html, panel.script);
}

export async function openDateWithDependencies(
  date: unknown,
  dependencies: OpenDateDependencies,
): Promise<boolean> {
  if (!isValidIsoDate(date)) {
    await dependencies.notify("Journal calendar returned an invalid date.", "error");
    return false;
  }
  await dependencies.hidePanel();
  try {
    await dependencies.invokeOpenDate(date);
    return true;
  } catch (error) {
    console.error("Journal calendar could not open the selected date:", error);
    await dependencies.notify(`Could not open journal entry ${date}.`, "error");
    return false;
  }
}

export async function openDate(date: unknown): Promise<boolean> {
  return openDateWithDependencies(date, runtimeOpenDateDependencies);
}
