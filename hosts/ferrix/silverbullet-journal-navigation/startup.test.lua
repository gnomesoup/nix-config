-- Execute the managed Space Lua with only the editor boundary stubbed.
local file = assert(io.open(arg[1], "r"))
local markdown = file:read("*a")
file:close()
local source = assert(markdown:match("```space%-lua\n(.-)\n```"))
local listeners = {}
local currentPage = "index"
local opened = {}
local today = "2026-11-05"

config = { get = function(_, default) return default end }
command = { define = function() end }
actionButton = { define = function() end }
event = {
  listen = function(definition)
    listeners[definition.name] = definition.run
  end,
}
editor = { getCurrentPage = function() return currentPage end }
date = { today = function() return today end }
journal = {
  openOrCreate = function(value)
    table.insert(opened, value)
    currentPage = "Journal/" .. value
  end,
}
assert(load(source, "journal-navigation.md"))()

local function emit(name)
  assert(listeners[name], "Missing startup redirect listener: " .. name)()
end

emit("editor:init")
assert(currentPage == "Journal/2026-11-05", "Startup must open today's journal")
emit("editor:pageLoaded")
assert(#opened == 1, "Loading the journal must not redirect again")

currentPage = "Projects/Example"
emit("editor:init")
emit("editor:pageLoaded")
assert(currentPage == "Projects/Example", "Direct note links must be preserved")
assert(#opened == 1, "Other notes must not open a journal")

currentPage = "index"
today = "2026-11-06"
emit("editor:pageLoaded")
assert(currentPage == "Journal/2026-11-06", "Home must resolve today's date anew")
assert(#opened == 2, "Returning home must open the journal once")
print("PASS: startup redirect, no redirect loop, direct links, and next-day home")
