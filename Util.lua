local _, ns = ...

-- Forever (like Midnight) returns "secret values" from some calls in combat, and
-- using one errors. ns.Ask returns nil instead and counts the refusal for /sd debug.

local MAX_LOGGED_PULLS = 20

local issecret = issecretvalue or function() return false end
ns.issecret = issecret

ns.debug = false
---@type table<string, { secret: integer, error: integer, lastError: string? }>
local refusals = {} -- [label] = { secret, error, lastError }

local function Note(label, kind, message)
  local entry = refusals[label]
  if not entry then
    entry = { secret = 0, error = 0 }
    refusals[label] = entry
  end
  entry[kind] = entry[kind] + 1

  if kind == "error" then
    local isNew = entry.lastError ~= message
    entry.lastError = tostring(message)
    if ns.debug and isNew then
      print("|cffff8800Safe Distance debug:|r " .. label .. ": " .. tostring(message))
    end
  end
end

function ns.Ask(label, fn, ...)
  if not fn then return nil end
  local ok, value = pcall(fn, ...)
  if not ok then
    Note(label, "error", value)
    return nil
  end
  if issecret(value) then
    Note(label, "secret")
    return nil
  end
  return value
end

-- yards to the nearest half like "17" or "17.5"
function ns.Yards(value)
  local half = math.floor(value * 2 + 0.5) / 2
  if half % 1 == 0 then return ("%d"):format(half) end
  return (("%.1f"):format(half):gsub("%.", ns.L.decimal))
end

function ns.SetDebug(on)
  ns.debug = on
  if on then
    local store = ns.DebugStore()
    if next(store.refusals) == nil then store.refusals = refusals end
    refusals = store.refusals
  else
    ns.ClearDebugStore()
    refusals = {}
  end
end

-- returns the entry so the caller can fill in the outcome later; nil if debug is off
function ns.LogPull(entry)
  if not ns.debug then return nil end
  local pulls = ns.DebugStore().pulls
  pulls[#pulls + 1] = entry
  while #pulls > MAX_LOGGED_PULLS do table.remove(pulls, 1) end
  return entry
end

function ns.RefusalReport()
  local labels = {}
  for label in pairs(refusals) do labels[#labels + 1] = label end
  table.sort(labels)

  local lines = {}
  for _, label in ipairs(labels) do
    local entry = refusals[label]
    lines[#lines + 1] = ("%s - secret: %d, blocked: %d%s"):format(label, entry.secret, entry.error,
      entry.lastError and (" (" .. entry.lastError .. ")") or "")
  end
  return lines
end
