local _, ns = ...
local L = ns.L
local BACKDROP = BackdropTemplateMixin and "BackdropTemplate" or nil

-- /sd window

local window = CreateFrame("Frame", "SafeDistanceDataWindow", UIParent, BACKDROP)
window:SetSize(460, 400)
window:SetPoint("CENTER")
window:SetFrameStrata("DIALOG")
window:SetClampedToScreen(true)
window:SetMovable(true)
window:EnableMouse(true)
window:RegisterForDrag("LeftButton")
window:SetScript("OnDragStart", window.StartMoving)
window:SetScript("OnDragStop", window.StopMovingOrSizing)
window:SetBackdrop({
  bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
  edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
  tile = true, tileSize = 32, edgeSize = 32,
  insets = { left = 11, right = 12, top = 12, bottom = 11 },
})
window:Hide()
tinsert(UISpecialFrames, "SafeDistanceDataWindow")

local header = window:CreateTexture(nil, "ARTWORK")
header:SetTexture("Interface\\DialogFrame\\UI-DialogBox-Header")
header:SetSize(300, 64)
header:SetPoint("TOP", 0, 12)

local title = window:CreateFontString(nil, "OVERLAY", "GameFontNormal")
title:SetPoint("TOP", header, "TOP", 0, -14)

local closeButton = CreateFrame("Button", nil, window, "UIPanelCloseButton")
closeButton:SetPoint("TOPRIGHT", -6, -6)

local note = window:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
note:SetPoint("TOPLEFT", 22, -32)
note:SetPoint("RIGHT", window, "RIGHT", -22, 0)
note:SetJustifyH("LEFT")

local scroll = CreateFrame("ScrollFrame", "SafeDistanceDataScroll", window, "UIPanelScrollFrameTemplate")
scroll:SetPoint("TOPLEFT", 20, -50)
scroll:SetPoint("BOTTOMRIGHT", -40, 18)

local list = CreateFrame("Frame", nil, scroll)
list:SetSize(390, 1)
scroll:SetScrollChild(list)

local ROW_HEIGHT = 18
local rows = {}

local function GetRow(index)
  local row = rows[index]
  if row then return row end

  row = CreateFrame("Frame", nil, list)
  row:SetSize(390, ROW_HEIGHT)
  row:SetPoint("TOPLEFT", 0, -(index - 1) * ROW_HEIGHT)
  row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  row.text:SetJustifyH("LEFT")
  row.text:SetWordWrap(false)
  row.forget = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
  row.forget:SetSize(22, 16)
  row.forget:SetPoint("RIGHT")
  row.forget:SetText("x")
  rows[index] = row
  return row
end

local function DistanceText(values)
  local middle = values and ns.Median(values)
  if not middle then return "-" end
  return L.win_value:format(ns.Yards(middle), #values)
end

local function MobText(mob)
  local text = (mob.name or "?") .. "  |cffaaaaaa"
    .. L.win_line:format(DistanceText(mob.aggro), DistanceText(mob.stealth)) .. "|r"
  if ns.LooksLikePack(mob) then text = text .. "  |cffff9933" .. L.packTag .. "|r" end
  return text
end

local function SortedKeys(tbl, nameOf)
  local keys = {}
  for key in pairs(tbl) do keys[#keys + 1] = key end
  table.sort(keys, function(a, b) return nameOf(a) < nameOf(b) end)
  return keys
end

function ns.RefreshWindow()
  if not window:IsShown() then return end
  title:SetText(L.win_title)
  note:SetText(L.win_note)

  local lines = {}
  local zones = ns.Zones()
  for _, zoneKey in ipairs(SortedKeys(zones, function(k) return zones[k].name or k end)) do
    local zone = zones[zoneKey]
    lines[#lines + 1] = { header = true, text = (zone.name or "?") .. (zone.instance and L.win_dungeon or "") }
    for _, npc in ipairs(SortedKeys(zone.mobs, function(k) return zone.mobs[k].name or "" end)) do
      lines[#lines + 1] = {
        text = MobText(zone.mobs[npc]),
        forget = function()
          ns.ForgetMob(npc, zoneKey)
          ns.RefreshWindow()
        end,
      }
    end
  end
  if #lines == 0 then lines[1] = { text = L.win_empty } end

  for index, line in ipairs(lines) do
    local row = GetRow(index)
    row.text:SetFontObject(line.header and GameFontNormal or GameFontHighlightSmall)
    row.text:ClearAllPoints()
    row.text:SetPoint("LEFT", line.header and 2 or 14, 0)
    row.text:SetPoint("RIGHT", -26, 0)
    row.text:SetText(line.text)
    row.forget:SetScript("OnClick", line.forget)
    row.forget:SetShown(line.forget ~= nil)
    row:Show()
  end
  for index = #lines + 1, #rows do rows[index]:Hide() end
  list:SetHeight(math.max(1, #lines * ROW_HEIGHT))
end
window:SetScript("OnShow", ns.RefreshWindow)

function ns.ToggleWindow()
  window:SetShown(not window:IsShown())
end

-- options panel

local panel = CreateFrame("Frame", "SafeDistanceOptions")
panel.name = "Safe Distance"
local category

local checkboxes, sliders, languageBoxes, buttons = {}, {}, {}, {}
local texts = {} -- { fontString, localeKey }

local function Label(font, key, point, x, y)
  local fontString = panel:CreateFontString(nil, "ARTWORK", font)
  fontString:SetPoint("TOPLEFT", point or panel, point and "BOTTOMLEFT" or "TOPLEFT", x, y)
  if key then texts[#texts + 1] = { fontString, key } end
  return fontString
end

local panelTitle = Label("GameFontNormalLarge", nil, nil, 16, -16)
panelTitle:SetText("Safe Distance")
local description = Label("GameFontHighlightSmall", "opt_desc", panelTitle, 0, -6)
description:SetPoint("RIGHT", panel, "RIGHT", -16, 0)
description:SetJustifyH("LEFT")
Label("GameFontNormal", "opt_general", nil, 16, -70)
Label("GameFontNormal", "opt_learning", nil, 16, -190)
Label("GameFontNormal", "opt_language", nil, 330, -262)

local function Checkbox(setting, x, y)
  local box = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
  box:SetSize(26, 26)
  box:SetPoint("TOPLEFT", x, y)
  box.label = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
  box.label:SetPoint("LEFT", box, "RIGHT", 4, 1)
  box.setting = setting
  box:SetScript("OnClick", function(self)
    ns.Set(setting, self:GetChecked() and true or false)
    ns.ApplySettings()
  end)
  checkboxes[#checkboxes + 1] = box
end

Checkbox("sound",       20, -90)
Checkbox("locked",      20, -116)
Checkbox("plate",       20, -142)
Checkbox("stealthMode", 20, -168)
Checkbox("learn",       20, -210)
Checkbox("perZone",     20, -236)
Checkbox("pack",        20, -262)
Checkbox("announce",    20, -288)

-- hand-built: slider templates differ between game versions
local function Slider(setting, x, y, minValue, maxValue, step, format)
  local slider = CreateFrame("Slider", nil, panel, BACKDROP)
  slider:SetOrientation("HORIZONTAL")
  slider:SetSize(220, 16)
  slider:SetPoint("TOPLEFT", x, y)
  slider:SetMinMaxValues(minValue, maxValue)
  slider:SetValueStep(step)
  slider:SetObeyStepOnDrag(true)
  slider:SetThumbTexture("Interface\\Buttons\\UI-SliderBar-Button-Horizontal")
  slider:SetBackdrop({
    bgFile = "Interface\\Buttons\\UI-SliderBar-Background",
    edgeFile = "Interface\\Buttons\\UI-SliderBar-Border",
    tile = true, tileSize = 8, edgeSize = 8,
    insets = { left = 3, right = 3, top = 6, bottom = 6 },
  })

  slider.label = slider:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
  slider.label:SetPoint("BOTTOMLEFT", slider, "TOPLEFT", 0, 3)
  slider.valueText = slider:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  slider.valueText:SetPoint("BOTTOMRIGHT", slider, "TOPRIGHT", 0, 3)

  local low = slider:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
  low:SetPoint("TOPLEFT", slider, "BOTTOMLEFT", 0, -1)
  low:SetText(format:format(minValue))
  local high = slider:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
  high:SetPoint("TOPRIGHT", slider, "BOTTOMRIGHT", 0, -1)
  high:SetText(format:format(maxValue))

  slider.setting, slider.format = setting, format
  slider:SetScript("OnValueChanged", function(self, value)
    if self.refreshing then return end
    value = math.floor(value / step + 0.5) * step
    ns.Set(setting, value)
    self.valueText:SetText(format:format(value))
    ns.ApplySettings()
  end)
  sliders[#sliders + 1] = slider
end

Slider("scale",  330, -100, 0.5, 2.5, 0.05, "%.2f")
Slider("offset", 330, -160, -10, 10, 1, "%+d")
Slider("margin", 330, -220, 0, 10, 1, "%d")

local function LanguageBox(code, name, x, y)
  local box = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
  box:SetSize(26, 26)
  box:SetPoint("TOPLEFT", x, y)
  local label = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
  label:SetPoint("LEFT", box, "RIGHT", 4, 1)
  label:SetText(name)
  box.code = code
  languageBoxes[#languageBoxes + 1] = box
end

LanguageBox("en", "English",   330, -280)
LanguageBox("pt", "Português", 450, -280)

local function Button(key, x, width, onClick)
  local button = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
  button:SetSize(width, 24)
  button:SetPoint("TOPLEFT", x, -320)
  button:SetScript("OnClick", onClick)
  button.key = key
  buttons[#buttons + 1] = button
end

local function RefreshPanel()
  local settings = ns.settings
  for _, entry in ipairs(texts) do entry[1]:SetText(L[entry[2]]) end
  for _, box in ipairs(checkboxes) do
    box:SetChecked(settings[box.setting])
    box.label:SetText(L["opt_" .. box.setting])
  end
  for _, slider in ipairs(sliders) do
    slider.refreshing = true
    slider:SetValue(settings[slider.setting])
    slider.refreshing = false
    slider.label:SetText(L["opt_" .. slider.setting])
    slider.valueText:SetText(slider.format:format(settings[slider.setting]))
  end
  for _, box in ipairs(languageBoxes) do box:SetChecked(settings.language == box.code) end
  for _, button in ipairs(buttons) do button:SetText(L[button.key]) end
end
panel:SetScript("OnShow", RefreshPanel)

for _, box in ipairs(languageBoxes) do
  box:SetScript("OnClick", function(self)
    ns.Set("language", self.code)
    ns.SetLanguage(self.code)
    RefreshPanel()
    ns.RefreshWindow()
    ns.ApplySettings()
  end)
end

Button("opt_window", 16, 180, function() ns.ToggleWindow() end)
Button("opt_resetPosition", 204, 150, function() ns.ResetPosition() end)
Button("opt_defaults", 362, 150, function()
  ns.ResetSettings()
  ns.ResetPosition()
  ns.ApplySettings()
  RefreshPanel()
end)

function ns.RegisterOptions()
  if Settings and Settings.RegisterCanvasLayoutCategory then
    category = Settings.RegisterCanvasLayoutCategory(panel, panel.name)
    Settings.RegisterAddOnCategory(category)
  elseif InterfaceOptions_AddCategory then
    InterfaceOptions_AddCategory(panel)
  end
end

-- false when in combat (settings panel is protected)
function ns.OpenOptions()
  if InCombatLockdown() then return false end
  if category then
    Settings.OpenToCategory(category.GetID and category:GetID() or category.ID)
  elseif InterfaceOptionsFrame_OpenToCategory then
    InterfaceOptionsFrame_OpenToCategory(panel)
    InterfaceOptionsFrame_OpenToCategory(panel) -- blizzard bug, needs two calls
  end
  return true
end
