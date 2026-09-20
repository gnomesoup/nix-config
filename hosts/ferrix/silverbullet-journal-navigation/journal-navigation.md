```space-lua
journalNavigation = journalNavigation or {}

function journalNavigation.pageDate(pageName)
  local prefix = config.get("journal.prefix", "Journal/")
  if type(pageName) ~= "string" or not pageName:startsWith(prefix) then
    return nil
  end
  local value = pageName:sub(#prefix + 1)
  local year, month, day = value:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
  if not year then return nil end
  local timestamp = os.time {
    year = tonumber(year),
    month = tonumber(month),
    day = tonumber(day),
    hour = 12,
  }
  if not timestamp or os.date("%Y-%m-%d", timestamp) ~= value then
    return nil
  end
  return value
end

function journalNavigation.entryLink(entry, direction)
  local entryDate = journalNavigation.pageDate(entry.name)
  if not entryDate then return nil end
  if direction == "previous" then
    return "[[" .. entry.name .. "|← " .. entryDate .. "]]"
  end
  return "[[" .. entry.name .. "|" .. entryDate .. " →]]"
end

command.define {
  name = "Journal: Open Date",
  hide = true,
  requireMode = "rw",
  run = function(args)
    local selectedDate = args and args[1]
    if type(selectedDate) ~= "string" or not journalNavigation.pageDate(config.get("journal.prefix", "Journal/") .. selectedDate) then
      editor.flashNotification("Journal calendar returned an invalid date", "error")
      return
    end
    journal.openOrCreate(selectedDate)
  end,
}

actionButton.define {
  icon = "calendar",
  description = "Open journal calendar",
  command = "Journal: Calendar",
  priority = 2.9,
  dropdown = false,
}

event.listen {
  name = "hooks:renderTopWidgets",
  run = function()
    if not journalNavigation.pageDate(editor.getCurrentPage()) then
      return
    end

    local links = {}
    local previous = journal.neighbor("previous")
    local next = journal.neighbor("next")
    if previous then
      table.insert(links, journalNavigation.entryLink(previous, "previous"))
    end
    if next then
      table.insert(links, journalNavigation.entryLink(next, "next"))
    end
    if #links == 0 then return end

    return widget.new {
      markdown = table.concat(links, " · "),
      display = "block",
      cssClasses = { "journal-day-navigation" },
    }
  end,
}
```

```space-style
.journal-day-navigation {
  display: block;
  margin: 0.25rem 0 0.75rem;
  padding: 0.45rem 0.75rem;
  border: 1px solid var(--editor-widget-border-color);
  border-radius: 0.4rem;
  text-align: center;
  font-size: 0.9rem;
}
```
