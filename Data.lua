local _, ns = ...

--[[ SafeDistanceDB
  version  = 2
  settings = { only non-default values }
  debug    = { refusals = {}, pulls = {} }   only while /sd debug is on
  zones    = {
    ["z1438"] = { name = "Teldrassil", instance = true|nil, mobs = {
      [npcID] = { name, aggro = {...}, stealth = {...}, seen = n, packs = n },
    } },
  }
  Distances are stored at the player's level (level diff removed), rounded to 0.5,
  last 5 per mob. "z" = map id, "i" = instance id.
]]

ns.defaults = {
  margin      = 0,
  offset      = 0,
  sound       = true,
  locked      = false,
  learn       = true,
  scale       = 1.25,
  perZone     = true,
  stealthMode = true,
  plate       = true,
  pack        = true,
  announce    = false,
  debug       = false,
}

-- 20 is the usual center-to-center number; the rulers measure to the mob's edge,
-- and real pulls landed at 12-15
ns.KINDS = {
  aggro   = { base = 15,  min = 5,   max = 45, skull = 45 },
  stealth = { base = 7.5, min = 1.5, max = 30, skull = 30 },
}

local DB_VERSION          = 2
local SAMPLES_PER_MOB     = 5
local MIN_FOR_CALIBRATION = 3

---@type table
local db
local sorter, merged = {}, {}

local function median(list)
  local n = #list
  if n == 0 then return nil end
  wipe(sorter)
  for i = 1, n do sorter[i] = list[i] end
  table.sort(sorter)
  if n % 2 == 1 then return sorter[(n + 1) / 2] end
  return (sorter[n / 2] + sorter[n / 2 + 1]) / 2
end

local function roundToHalf(value)
  return math.floor(value * 2 + 0.5) / 2
end

local function append(into, list)
  if list then
    for i = 1, #list do into[#into + 1] = list[i] end
  end
end

-- settings

function ns.LoadDatabase()
  if type(SafeDistanceDB) ~= "table" or SafeDistanceDB.version ~= DB_VERSION then
    ---@diagnostic disable-next-line: global-in-non-module -- SavedVariables are globals
    SafeDistanceDB = { version = DB_VERSION, settings = {}, zones = {} }
  end
  db = SafeDistanceDB
  ns.settings = setmetatable(db.settings, { __index = ns.defaults })

  if ns.settings.language == nil then
    db.settings.language = (GetLocale() == "ptBR") and "pt" or "en"
  end
end

function ns.Set(key, value)
  if value == ns.defaults[key] then value = nil end
  rawset(db.settings, key, value)
end

function ns.ResetSettings()
  local language, point, debug = db.settings.language, db.settings.point, db.settings.debug
  wipe(db.settings)
  db.settings.language, db.settings.point, db.settings.debug = language, point, debug
end

function ns.DebugStore()
  db.debug = db.debug or { refusals = {}, pulls = {} }
  return db.debug
end

function ns.ClearDebugStore()
  db.debug = nil
end

function ns.SavedPullCount()
  return db.debug and #db.debug.pulls or 0
end

-- zones: one profile per instance, or per zone in the open world (subzones/caves roll up)

local zoneKey, zoneName, zoneIsInstance

function ns.InvalidateZone()
  zoneKey = nil
end

function ns.CurrentZone()
  if zoneKey then return zoneKey, zoneName, zoneIsInstance end

  local name, kind, _, _, _, _, _, instanceID = GetInstanceInfo()
  if kind and kind ~= "none" and instanceID then
    zoneKey, zoneName, zoneIsInstance = "i" .. instanceID, name, true
    return zoneKey, zoneName, zoneIsInstance
  end

  zoneIsInstance = false
  local mapID = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
  if mapID then
    local info = C_Map.GetMapInfo(mapID)
    local ZONE = Enum.UIMapType and Enum.UIMapType.Zone or 3
    while info and info.mapType and info.mapType > ZONE and (info.parentMapID or 0) > 0 do
      local parent = C_Map.GetMapInfo(info.parentMapID)
      if not parent then break end
      mapID, info = info.parentMapID, parent
    end
    zoneKey, zoneName = "z" .. mapID, info and info.name
  end

  zoneName = zoneName or GetRealZoneText() or "?"
  zoneKey = zoneKey or ("n" .. zoneName)
  return zoneKey, zoneName, zoneIsInstance
end

local function CurrentZoneRecord(create)
  local key, name, isInstance = ns.CurrentZone()
  local zone = db.zones[key]
  if not zone and create then
    zone = { mobs = {} }
    db.zones[key] = zone
  end
  if zone then
    zone.name = name
    zone.instance = isInstance or nil
  end
  return zone, name
end

local function MobRecord(zone, npc, name)
  local mob = zone.mobs[npc]
  if not mob then
    mob = {}
    zone.mobs[npc] = mob
  end
  mob.name = name or mob.name
  return mob
end

-- calibration = median of everything learned in a zone or in the open world

local calibration = {}

local function Calibration(scope, kind)
  local cacheKey = scope .. ":" .. kind
  local cached = calibration[cacheKey]
  if cached == nil then
    wipe(merged)
    if scope == "world" then
      for _, zone in pairs(db.zones) do
        if not zone.instance then
          for _, mob in pairs(zone.mobs) do append(merged, mob[kind]) end
        end
      end
    elseif db.zones[scope] then
      for _, mob in pairs(db.zones[scope].mobs) do append(merged, mob[kind]) end
    end
    cached = (#merged >= MIN_FOR_CALIBRATION) and { median(merged), #merged } or false
    calibration[cacheKey] = cached
  end
  if cached then return cached[1], cached[2] end
end

local function DataChanged()
  wipe(calibration)
  if ns.OnDataChanged then ns.OnDataChanged() end
end

-- estimates, most specific first: this mob here, this mob anywhere,
-- this zone, open world (never inside dungeons)

local function LearnedBase(npc, kind)
  local settings = ns.settings
  local key, _, isInstance = ns.CurrentZone()

  if npc then
    local here = settings.perZone and db.zones[key]
    local list = here and here.mobs[npc] and here.mobs[npc][kind]
    if list and #list > 0 then return median(list), "npcZone", #list end

    wipe(merged)
    for _, zone in pairs(db.zones) do
      local mob = zone.mobs[npc]
      if mob then append(merged, mob[kind]) end
    end
    if #merged > 0 then return median(merged), "npc", #merged end
  end

  if settings.perZone then
    local value, count = Calibration(key, kind)
    if value then return value, "zone", count end
  end

  if not (settings.perZone and isInstance) then
    local value, count = Calibration("world", kind)
    if value then return value, "global", count end
  end
end

function ns.Estimate(npc, mobLevel, kindName)
  local kind = ns.KINDS[kindName]
  local offset = (kindName == "aggro") and ns.settings.offset or 0

  if not mobLevel or mobLevel <= 0 then -- skull
    return math.max(1, kind.skull + offset), "est", 0
  end

  local base, source, count
  if ns.settings.learn then base, source, count = LearnedBase(npc, kindName) end
  if not base then base, source, count = kind.base, "est", 0 end

  local radius = base + (mobLevel - UnitLevel("player"))
  radius = math.min(kind.max, math.max(kind.min, radius))
  return math.max(1, radius + offset), source, count
end

local function LooksLikePack(mob)
  local packs = mob and mob.packs or 0
  return packs >= 2 and packs * 2 >= (mob.seen or 0)
end
ns.LooksLikePack = LooksLikePack

function ns.IsPack(npc)
  if not npc then return false end
  local here = ns.settings.perZone and db.zones[(ns.CurrentZone())]
  local mob = here and here.mobs[npc]
  if mob and mob.seen then return LooksLikePack(mob) end
  for _, zone in pairs(db.zones) do
    if LooksLikePack(zone.mobs[npc]) then return true end
  end
  return false
end

-- recording

function ns.RecordPull(npc, name, distance, levelDiff, kind)
  local zone, zoneLabel = CurrentZoneRecord(true)
  local mob = MobRecord(zone, npc, name)
  local list = mob[kind] or {}
  mob[kind] = list

  list[#list + 1] = roundToHalf(distance - levelDiff)
  if #list > SAMPLES_PER_MOB then table.remove(list, 1) end

  DataChanged()
  return #list, zoneLabel
end

-- returns true the moment the mob starts looking like a pack mob
function ns.RecordPack(npc, name, withCompany)
  local zone = CurrentZoneRecord(true)
  local mob = MobRecord(zone, npc, name)
  local wasPack = LooksLikePack(mob)
  mob.seen = (mob.seen or 0) + 1
  if withCompany then mob.packs = (mob.packs or 0) + 1 end
  DataChanged()
  return LooksLikePack(mob) and not wasPack
end

-- forgetting / summary

function ns.ForgetMob(npc, onlyZoneKey)
  local found = false
  for key, zone in pairs(db.zones) do
    if (not onlyZoneKey or key == onlyZoneKey) and zone.mobs[npc] then
      zone.mobs[npc] = nil
      found = true
      if not next(zone.mobs) then db.zones[key] = nil end
    end
  end
  if found then DataChanged() end
  return found
end

function ns.ForgetZone()
  local key, name = ns.CurrentZone()
  local found = db.zones[key] ~= nil
  db.zones[key] = nil
  if found then DataChanged() end
  return found, name
end

function ns.ForgetAll()
  wipe(db.zones)
  DataChanged()
end

function ns.Zones()
  return db.zones
end

function ns.Summary()
  local mobTypes, typesCount, zones, distances = {}, 0, 0, 0
  for _, zone in pairs(db.zones) do
    zones = zones + 1
    for npc, mob in pairs(zone.mobs) do
      if not mobTypes[npc] then mobTypes[npc] = true typesCount = typesCount + 1 end
      distances = distances + #(mob.aggro or {}) + #(mob.stealth or {})
    end
  end

  local here = db.zones[(ns.CurrentZone())]
  local hereTypes, hereDistances
  if here then
    hereTypes, hereDistances = 0, 0
    for _, mob in pairs(here.mobs) do
      hereTypes = hereTypes + 1
      hereDistances = hereDistances + #(mob.aggro or {}) + #(mob.stealth or {})
    end
  end
  return typesCount, zones, distances, hereTypes, hereDistances
end

ns.Median = median
