local ADDON_NAME, ns = ...
local L = ns.L

-- update interval: slow when far from the edge, fast near it
local TICK_FAR    = 0.5
local TICK_NORMAL = 0.15
local TICK_NEAR   = 0.1
local FAR_MARGIN  = 10

local ACTION_WINDOW = 1.5     -- attacked within this = not a body pull
local SNAPSHOT_MAX_AGE = 0.75 -- keep above TICK_FAR or far pulls get missed

local issecret = ns.issecret

local function Say(message)
  print("|cff33ff99Safe Distance:|r " .. message)
end

-- target info, read once per target change
local target = {}
local estimates = {} -- [mode] = { radius, source, count }

local function ForgetEstimates()
  wipe(estimates)
  target.pack = nil
end
ns.OnDataChanged = ForgetEstimates

local function ReadTarget()
  wipe(target)
  ForgetEstimates()
  if not UnitExists("target") or UnitIsPlayer("target") then return end
  if not UnitCanAttack("player", "target") then return end

  target.valid = true
  target.guid = ns.Ask("UnitGUID", UnitGUID, "target")
  target.name = UnitName("target")
  target.level = UnitLevel("target")
  if target.guid then
    local unitType, _, _, _, _, npcID = strsplit("-", target.guid)
    if unitType == "Creature" or unitType == "Vehicle" then target.npc = tonumber(npcID) end
  end
end

local function Estimate(mode)
  local cached = estimates[mode]
  if not cached then
    cached = { ns.Estimate(target.npc, target.level, mode) }
    estimates[mode] = cached
  end
  return cached[1], cached[2], cached[3]
end

local function TargetIsPack()
  if target.pack == nil then
    target.pack = ns.settings.learn and ns.settings.pack and ns.IsPack(target.npc) or false
  end
  return target.pack
end

-- update loop, only runs with a hostile target out of combat

local ticker = CreateFrame("Frame")
ticker:Hide()

---@type { time: number, minR: number?, maxR: number?, stealthed: boolean?, mobWasFighting: boolean? }
local snapshot = { time = 0 }
local view = {}
local lastState, lastMode

-- returns the delay until the next update
local function Update()
  if not UnitExists("target") or UnitIsDeadOrGhost("target") then
    ns.HideDisplay()
    ticker:Hide()
    return TICK_FAR
  end

  local settings = ns.settings
  local stealthed = IsStealthed() and true or false
  local mode = (settings.stealthMode and stealthed) and "stealth" or "aggro"
  if mode ~= lastMode then lastState, lastMode = nil, mode end

  local reaction = UnitReaction("target", "player")
  if reaction and reaction >= 4 then
    ns.ShowMessage("neutral", L.neutral, L.neutralInfo)
    ns.SetMarker(nil)
    snapshot.time = 0
    return TICK_FAR
  end
  local mobFighting = ns.Ask("UnitAffectingCombat", UnitAffectingCombat, "target") and true or false
  if mobFighting and ns.Ask("UnitIsUnit", UnitIsUnit, "targettarget", "player") == false then
    ns.ShowMessage("busy", L.busy, L.busyInfo)
    ns.SetMarker(nil)
    snapshot.time = 0
    return TICK_FAR
  end

  local radius, source, count = Estimate(mode)
  local minR, maxR = ns.GetRange("target")

  local state
  if minR >= radius + settings.margin then
    state = "safe"    -- certainly outside
  elseif maxR and maxR <= radius then
    state = "danger"  -- certainly inside
  else
    state = "edge"    -- the measured band crosses the radius
  end

  view.state, view.mode, view.stealthed = state, mode, stealthed
  view.radius, view.minR, view.maxR = radius, minR, maxR
  view.source, view.count, view.pack = source, count, TargetIsPack()
  ns.ShowRuler(view)
  ns.SetMarker(state)

  snapshot.time = GetTime()
  snapshot.minR, snapshot.maxR, snapshot.stealthed = minR, maxR, stealthed
  snapshot.mobWasFighting = mobFighting

  if settings.sound and state == "edge" and lastState == "safe" then
    PlaySound(SOUNDKIT.RAID_WARNING, "Master")
  end
  lastState = state

  if state ~= "safe" then return TICK_NEAR end
  if minR >= radius + settings.margin + FAR_MARGIN then return TICK_FAR end
  return TICK_NORMAL
end

ticker.wait = 0
ticker:SetScript("OnUpdate", function(self, elapsed)
  self.wait = self.wait - elapsed
  if self.wait > 0 then return end
  self.wait = Update()
end)

-- Decides whether the loop should run, and shows "In combat" when needed.
local function Refresh()
  lastState = nil
  if not target.valid then
    ticker:Hide()
    ns.HideDisplay()
  elseif UnitAffectingCombat("player") then
    ticker:Hide()
    ns.ShowMessage("combat", L.combat)
    ns.SetMarker(nil)
  else
    ticker.wait = 0
    ticker:Show()
  end
end

function ns.ApplySettings()
  ns.ApplyScale()
  ForgetEstimates()
  ns.RepaintDisplay()
  Refresh()
end

-- learning

---@type number
local lastAction = 0

-- log is nil unless /sd debug is on
local function Write(log, key, value)
  if log then log[key] = value end
end

local function TargetPulledUs(pull)
  if ns.Ask("UnitAffectingCombat", UnitAffectingCombat, "target") == false then
    return false, "target isn't in combat"
  end
  if ns.Ask("UnitIsUnit", UnitIsUnit, "targettarget", "player") == false then
    return false, "target is attacking someone else"
  end
  local guid = ns.Ask("UnitGUID", UnitGUID, "target")
  if guid and guid ~= pull.guid then return false, "you switched target" end
  return true
end

local function LearnDistance(pull, log)
  local pulledUs, why = TargetPulledUs(pull)
  if not pulledUs then return Write(log, "result", "not learned: " .. why) end

  -- middle of the last measured band
  local distance = (pull.minR > 0) and (pull.minR + pull.maxR) / 2 or pull.maxR
  local kind = pull.stealthed and "stealth" or "aggro"
  local count, zoneName = ns.RecordPull(pull.npc, pull.name, distance, pull.levelDiff, kind)
  Write(log, "result", ("learned %s %.1f yd"):format(kind, distance))
  if ns.settings.announce then
    Say((pull.stealthed and L.learnedStealth or L.learned):format(pull.name or "?", ns.Yards(distance), count,
      zoneName or "?"))
  end
end

local function LearnPack(pull, log)
  local attackers, couldSee = 0, false
  for i = 1, 40 do
    local unit = "nameplate" .. i
    if UnitExists(unit) and ns.Ask("UnitCanAttack", UnitCanAttack, "player", unit) then
      local onUs = ns.Ask("UnitIsUnit", UnitIsUnit, unit .. "target", "player")
      local threat = ns.Ask("UnitThreatSituation", UnitThreatSituation, "player", unit)
      if onUs ~= nil or threat ~= nil then couldSee = true end
      if onUs or threat then attackers = attackers + 1 end
    end
  end

  if not couldSee then return Write(log, "pack", "couldn't tell (game refused or no nameplates)") end
  if attackers == 0 then return Write(log, "pack", "no attackers found") end
  Write(log, "pack", attackers .. " attacker(s)")

  if ns.RecordPack(pull.npc, pull.name, attackers >= 2) and ns.settings.announce then
    Say(L.packLearned:format(pull.name or "?"))
  end
end

local function OnCombatStart()
  local settings = ns.settings
  if not (settings.learn and target.npc) then return end
  local now = GetTime()

  local log = ns.LogPull({
    time = date("%m/%d %H:%M:%S"),
    mob = target.name,
    zone = select(2, ns.CurrentZone()),
    levels = ("%s vs you %d"):format(target.level or "?", UnitLevel("player")),
    band = ("%s-%s yd"):format(snapshot.minR or "?", snapshot.maxR or "?"),
    stealthed = snapshot.stealthed or nil,
  })

  if now - snapshot.time > SNAPSHOT_MAX_AGE then
    return Write(log, "result", "not learned: wasn't measuring the target right before combat")
  end
  if snapshot.mobWasFighting then
    return Write(log, "result", "not learned: mob was already fighting")
  end

  local pull = {
    guid = target.guid, npc = target.npc, name = target.name,
    levelDiff = (target.level or 0) - UnitLevel("player"),
    minR = snapshot.minR, maxR = snapshot.maxR, stealthed = snapshot.stealthed,
  }

  if settings.pack then
    C_Timer.After(1.5, function() LearnPack(pull, log) end)
  end

  if now - lastAction < ACTION_WINDOW then return Write(log, "result", "not learned: you attacked first") end
  if not pull.maxR then return Write(log, "result", "not learned: farther than every ruler") end
  if not target.level or target.level <= 0 then return Write(log, "result", "not learned: skull level mob") end
  if pull.stealthed and not settings.stealthMode then
    return Write(log, "result", "not learned: stealth mode is off")
  end
  Write(log, "result", "checking who pulled you...")
  C_Timer.After(0.4, function() LearnDistance(pull, log) end) -- let the mob pick its target first
end

-- events

local events = {}

function events.ADDON_LOADED(name)
  if name ~= ADDON_NAME then return end
  ns.LoadDatabase()
  ns.SetDebug(ns.settings.debug)
  ns.SetLanguage(ns.settings.language)
  ns.ApplyScale()
  ns.RestorePosition()
  ns.RegisterOptions()
end

function events.PLAYER_LOGIN()
  ns.RebuildRulers()
  ReadTarget()
  Refresh()
end

function events.SPELLS_CHANGED()
  ns.RebuildRulers()
end

function events.GET_ITEM_INFO_RECEIVED(itemID)
  if ns.IsRangeItem(itemID) then ns.RefreshRulersSoon() end
end

function events.PLAYER_TARGET_CHANGED()
  ReadTarget()
  ns.RefreshRulersSoon()
  ns.ForgetPlate()
  snapshot.time = 0
  Refresh()
end

function events.NAME_PLATE_UNIT_ADDED() ns.ForgetPlate() end
function events.NAME_PLATE_UNIT_REMOVED() ns.ForgetPlate() end

function events.UNIT_FACTION(unit)
  if unit == "target" then
    ReadTarget()
    Refresh()
  end
end

function events.PLAYER_LEVEL_UP()
  ForgetEstimates()
end

function events.PLAYER_REGEN_DISABLED()
  OnCombatStart()
  Refresh()
end

function events.PLAYER_REGEN_ENABLED()
  Refresh()
end

function events.PLAYER_ENTER_COMBAT() -- auto attack
  lastAction = GetTime()
end

function events.UNIT_SPELLCAST_SENT(_, spellTarget)
  -- only spells with a target count (not Stealth)
  if type(spellTarget) == "string" and not issecret(spellTarget)
    and spellTarget ~= "" and spellTarget ~= UnitName("player") then
    lastAction = GetTime()
  end
end

local function ZoneChanged()
  ns.InvalidateZone()
  ForgetEstimates()
end
function events.PLAYER_ENTERING_WORLD()
  ZoneChanged()
  ReadTarget()
  ns.ForgetPlate()
  Refresh()
end
events.ZONE_CHANGED_NEW_AREA = ZoneChanged
events.ZONE_CHANGED = ZoneChanged
events.ZONE_CHANGED_INDOORS = ZoneChanged

local eventFrame = CreateFrame("Frame")
for event in pairs(events) do
  if event == "UNIT_SPELLCAST_SENT" then
    eventFrame:RegisterUnitEvent(event, "player")
  else
    eventFrame:RegisterEvent(event)
  end
end
eventFrame:SetScript("OnEvent", function(_, event, ...) events[event](...) end)

-- /sd

local TOGGLES = {
  sound = "sound", learn = "learn", zones = "perZone",
  stealth = "stealthMode", plate = "plate", pack = "pack", chat = "announce",
}

local commands = {}

function commands.margin(number)
  if not number then return false end
  ns.Set("margin", number)
  ns.ApplySettings()
  Say(L.marginSet:format(number))
end

function commands.offset(number)
  if not number then return false end
  ns.Set("offset", number)
  ns.ApplySettings()
  Say(L.offsetSet:format(number))
end

function commands.size(number)
  if not number then return false end
  ns.Set("scale", math.max(0.5, math.min(2.5, number)))
  ns.ApplySettings()
  Say(L.scaleSet:format(ns.settings.scale))
end
commands.scale = commands.size

function commands.lock()
  ns.Set("locked", not ns.settings.locked)
  Say(ns.settings.locked and L.locked or L.unlocked)
end

function commands.options()
  if ns.OpenOptions() == false then Say(L.notInCombat) end
end
commands.config = commands.options

function commands.debug()
  local report = ns.RefusalReport()
  if #report == 0 then
    Say(L.debugNothing)
  else
    Say(L.debugReport)
    for _, line in ipairs(report) do print("  " .. line) end
  end

  local on = not ns.settings.debug
  ns.Set("debug", on)
  ns.SetDebug(on)
  Say(L.debugToggle:format(on and L.on or L.off))
  Say(on and L.debugSaving or L.debugCleared)
end

function commands.window() ns.ToggleWindow() end

function commands.lang(_, word)
  local code = (word == "pt" or word == "en") and word
    or (ns.settings.language == "pt" and "en" or "pt")
  ns.Set("language", code)
  ns.SetLanguage(code)
  ns.RefreshWindow()
  ns.ApplySettings()
  Say(L.language)
end
commands.language = commands.lang

function commands.data()
  local types, zones, distances, hereTypes, hereDistances = ns.Summary()
  Say(L.data:format(types, zones, distances))
  if hereTypes then
    Say(L.dataZone:format(select(2, ns.CurrentZone()), hereTypes, hereDistances))
  else
    Say(L.noZoneData)
  end
end

function commands.forget()
  if not target.npc then return Say(L.noTarget) end
  Say(ns.ForgetMob(target.npc) and L.forgot:format(target.name or "?") or L.noData)
  ns.RefreshWindow()
end

function commands.forgetzone()
  local found, zoneName = ns.ForgetZone()
  Say(found and L.forgot:format(zoneName) or L.noZoneData)
  ns.RefreshWindow()
end

function commands.forgetall()
  ns.ForgetAll()
  Say(L.forgotAll)
  ns.RefreshWindow()
end

function commands.reset()
  ns.ResetSettings()
  ns.ResetPosition()
  ns.ApplySettings()
  Say(L.reset)
end

function commands.info()
  ns.RebuildRulers()
  local total, working = ns.DescribeRulers("target")
  Say(L.info:format(total, #working > 0 and table.concat(working, ", ") or L.none))
end

local function ShowHelp()
  Say(L.help[1])
  print(L.help[2]:format(ns.settings.offset))
  print(L.help[3]:format(ns.settings.margin))
  for i = 4, #L.help do print(L.help[i]) end
end
commands.help = ShowHelp

SLASH_SAFEDISTANCE1 = "/sd"
SLASH_SAFEDISTANCE2 = "/safedistance"
SlashCmdList.SAFEDISTANCE = function(message)
  local name, argument = (message or ""):lower():match("^(%S*)%s*(.-)$")
  if name == "" then return commands.options() end

  local setting = TOGGLES[name]
  if setting then
    ns.Set(setting, not ns.settings[setting])
    ns.ApplySettings()
    return Say(L["toggle_" .. setting]:format(ns.settings[setting] and L.on or L.off))
  end

  local command = commands[name]
  if not command or command(tonumber(argument), argument) == false then
    ShowHelp()
  end
end
