local _, ns = ...
local L = ns.L

local COLORS = {
  safe    = { 0.30, 0.90, 0.30 },
  edge    = { 1.00, 0.82, 0.00 },
  danger  = { 1.00, 0.20, 0.20 },
  neutral = { 0.75, 0.75, 0.75 },
  busy    = { 0.55, 0.70, 0.90 },
  combat  = { 0.60, 0.60, 0.60 },
}
local DANGER_ZONE = {
  aggro   = { 0.70, 0.12, 0.12 },
  stealth = { 0.45, 0.20, 0.65 },
}
local SOURCE_TEXT = {
  npcZone = "src_npcZone", npc = "src_npc", zone = "src_zone", global = "src_global", est = "src_est",
}

local BOX_WIDTH, RULER_WIDTH = 220, 196
local STATUSBAR = "Interface\\TargetingFrame\\UI-StatusBar"
local DEFAULT_POINT = { "BOTTOM", "BOTTOM", 0, 190 }
local BACKDROP = BackdropTemplateMixin and "BackdropTemplate" or nil

local box = CreateFrame("Frame", "SafeDistanceFrame", UIParent, BACKDROP)
box:SetSize(BOX_WIDTH, 56)
box:SetFrameStrata("LOW")
box:SetClampedToScreen(true)
box:SetMovable(true)
box:EnableMouse(true)
box:RegisterForDrag("LeftButton")
box:Hide()
box:SetBackdrop({
  bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
  edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
  tile = true, tileSize = 16, edgeSize = 14,
  insets = { left = 3, right = 3, top = 3, bottom = 3 },
})
box:SetBackdropColor(0.04, 0.04, 0.08, 0.85)

box:SetScript("OnDragStart", function(self)
  if not ns.settings.locked then self:StartMoving() end
end)
box:SetScript("OnDragStop", function(self)
  self:StopMovingOrSizing()
  local point, _, relativePoint, x, y = self:GetPoint()
  ns.Set("point", { point, relativePoint, x, y })
end)

local packText = box:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
packText:SetPoint("TOPRIGHT", -12, -10)
packText:SetTextColor(1, 0.6, 0.2)

local stateText = box:CreateFontString(nil, "OVERLAY", "GameFontNormal")
stateText:SetPoint("TOPLEFT", 12, -9)
stateText:SetPoint("RIGHT", packText, "LEFT", -4, 0)
stateText:SetJustifyH("LEFT")
stateText:SetWordWrap(false)

local ruler = CreateFrame("Frame", nil, box)
ruler:SetSize(RULER_WIDTH, 9)
ruler:SetPoint("TOPLEFT", 12, -27)

local rulerBackground = ruler:CreateTexture(nil, "BACKGROUND")
rulerBackground:SetAllPoints()
rulerBackground:SetColorTexture(0, 0, 0, 0.7)

local dangerZone = ruler:CreateTexture(nil, "BORDER")
dangerZone:SetTexture(STATUSBAR)
dangerZone:SetPoint("TOPLEFT")
dangerZone:SetPoint("BOTTOMLEFT")

local safeZone = ruler:CreateTexture(nil, "BORDER")
safeZone:SetTexture(STATUSBAR)
safeZone:SetVertexColor(0.15, 0.55, 0.15, 0.9)
safeZone:SetPoint("TOPLEFT", dangerZone, "TOPRIGHT")
safeZone:SetPoint("BOTTOMRIGHT")

local youBand = ruler:CreateTexture(nil, "ARTWORK")
youBand:SetColorTexture(1, 1, 1, 0.25)

local edgeLine = ruler:CreateTexture(nil, "ARTWORK", nil, 1)
edgeLine:SetColorTexture(1, 0.82, 0, 1)
edgeLine:SetSize(1, 13)

local spark = ruler:CreateTexture(nil, "OVERLAY")
spark:SetTexture("Interface\\CastingBar\\UI-CastingBar-Spark")
spark:SetBlendMode("ADD")
spark:SetSize(20, 26)

local rulerBorder = CreateFrame("Frame", nil, ruler, BACKDROP)
rulerBorder:SetPoint("TOPLEFT", -1, 1)
rulerBorder:SetPoint("BOTTOMRIGHT", 1, -1)
rulerBorder:SetBackdrop({ edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
rulerBorder:SetBackdropBorderColor(0, 0, 0, 1)

local distanceText = box:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
distanceText:SetJustifyH("LEFT")

local radiusText = box:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
radiusText:SetPoint("TOPRIGHT", ruler, "BOTTOMRIGHT", 0, -4)
radiusText:SetTextColor(0.8, 0.8, 0.8)

local shown = {} -- last painted values, to skip redundant redraws

---@type boolean?
local canStealth
local function CanStealth()
  if canStealth == nil then
    local _, class = UnitClass("player")
    local _, race = UnitRace("player")
    canStealth = class == "ROGUE" or class == "DRUID" or race == "NightElf"
  end
  return canStealth
end

function ns.RepaintDisplay()
  wipe(shown)
end

local function SetState(state, label)
  local color = COLORS[state]
  stateText:SetText(label)
  stateText:SetTextColor(color[1], color[2], color[3])
  box:SetBackdropBorderColor(color[1], color[2], color[3], 1)
end

local function FormatBand(minR, maxR)
  if maxR then return string.format("%d-%d %s", minR, maxR, L.yd) end
  if minR > 0 then return string.format("+%d %s", minR, L.yd) end
  return "?"
end

function ns.ShowMessage(state, label, info)
  if shown.kind == "message" and shown.state == state and shown.label == label then return end
  wipe(shown)
  shown.kind, shown.state, shown.label = "message", state, label

  SetState(state, label)
  packText:SetText("")
  ruler:Hide()
  radiusText:SetText("")
  distanceText:ClearAllPoints()
  distanceText:SetPoint("TOPLEFT", stateText, "BOTTOMLEFT", 0, -5)
  distanceText:SetText(info or "")
  box:SetHeight(info and 44 or 30)
  box:Show()
end

-- view: state, mode, stealthed, radius, minR, maxR, source, count, pack
function ns.ShowRuler(view)
  if shown.kind == "ruler" and shown.state == view.state and shown.mode == view.mode
    and shown.stealthed == view.stealthed and shown.radius == view.radius
    and shown.minR == view.minR and shown.maxR == view.maxR and shown.source == view.source
    and shown.count == view.count and shown.pack == view.pack then
    return
  end
  wipe(shown)
  shown.kind = "ruler"
  for key, value in pairs(view) do shown[key] = value end

  local state, mode, radius = view.state, view.mode, view.radius
  local stealthMode = (mode == "stealth")

  local label
  if stealthMode then
    label = L["stealth_" .. state]
  else
    label = L[state]
    if state == "edge" and not view.stealthed and CanStealth() then label = L.edge_stealth end
    if view.stealthed and state ~= "safe" then label = label .. L.stealthedSuffix end
  end
  SetState(state, label)
  packText:SetText(view.pack and L.packTag or "")

  local length = math.max(stealthMode and 20 or 40, radius + 15)
  local function toPixels(yards)
    return math.min(math.max(yards, 0), length) / length * RULER_WIDTH
  end

  local zone = DANGER_ZONE[mode]
  dangerZone:SetVertexColor(zone[1], zone[2], zone[3], 0.9)
  dangerZone:SetWidth(math.max(0.1, toPixels(radius)))
  edgeLine:SetPoint("CENTER", ruler, "LEFT", toPixels(radius), 0)

  local low, high = view.minR, view.maxR or length
  youBand:ClearAllPoints()
  youBand:SetPoint("TOPLEFT", ruler, "TOPLEFT", toPixels(low), 0)
  youBand:SetPoint("BOTTOMLEFT", ruler, "BOTTOMLEFT", toPixels(low), 0)
  youBand:SetWidth(math.max(1, toPixels(high) - toPixels(low)))

  local you = view.maxR and (low + view.maxR) / 2 or math.min(length, low + 5)
  spark:SetPoint("CENTER", ruler, "LEFT", toPixels(you), 0)

  ruler:Show()
  distanceText:ClearAllPoints()
  distanceText:SetPoint("TOPLEFT", ruler, "BOTTOMLEFT", 0, -4)
  distanceText:SetText(FormatBand(view.minR, view.maxR))

  local sourceText = L[SOURCE_TEXT[view.source]]
  if view.source == "npcZone" or view.source == "npc" then sourceText = sourceText:format(view.count) end
  radiusText:SetText((stealthMode and L.detection or L.aggro):format(radius, L.yd)
    .. "  |cff8a8a8a" .. sourceText .. "|r")

  box:SetHeight(56)
  box:Show()
end

function ns.HideDisplay()
  wipe(shown)
  box:Hide()
  ns.SetMarker(nil)
end

function ns.RestorePosition()
  local point = ns.settings.point or DEFAULT_POINT
  box:ClearAllPoints()
  box:SetPoint(point[1], UIParent, point[2], point[3], point[4])
end

function ns.ResetPosition()
  ns.Set("point", nil)
  ns.RestorePosition()
end

function ns.ApplyScale()
  box:SetScale(ns.settings.scale)
end

-- nameplate dot

local DOT_TEXTURE = {
  safe   = "Interface\\COMMON\\Indicator-Green",
  edge   = "Interface\\COMMON\\Indicator-Yellow",
  danger = "Interface\\COMMON\\Indicator-Red",
}
local dot = CreateFrame("Frame", nil, UIParent)
dot:SetSize(14, 14)
dot:SetFrameStrata("HIGH")
dot:Hide()
local dotTexture = dot:CreateTexture(nil, "OVERLAY")
dotTexture:SetAllPoints()

local dotPlate, dotState

-- cached until a plate is added/removed or the target changes
local targetPlate, targetPlateKnown = nil, false

function ns.ForgetPlate()
  targetPlateKnown = false
end

local function TargetPlate()
  if not targetPlateKnown then
    local plate = C_NamePlate and ns.Ask("GetNamePlateForUnit", C_NamePlate.GetNamePlateForUnit, "target")
    if plate and plate.IsForbidden and plate:IsForbidden() then plate = nil end
    targetPlate, targetPlateKnown = plate, true
  end
  return targetPlate
end

function ns.SetMarker(state)
  local plate = state and ns.settings.plate and DOT_TEXTURE[state] and TargetPlate()
  if not plate then
    dot:Hide()
    dotPlate, dotState = nil, nil
    return
  end

  if plate ~= dotPlate then
    -- custom nameplate addons may not have UnitFrame.healthBar
    local healthBar = plate.UnitFrame and plate.UnitFrame.healthBar
    dot:ClearAllPoints()
    if healthBar then
      dot:SetPoint("RIGHT", healthBar, "LEFT", -3, 0)
    else
      dot:SetPoint("BOTTOM", plate, "TOP", 0, 0)
    end
    dotPlate = plate
  end

  if state ~= dotState then
    dotTexture:SetTexture(DOT_TEXTURE[state])
    dotState = state
  end
  dot:Show()
end
