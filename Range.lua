local _, ns = ...

-- No exact distance API for mobs, only "in range of X?". Ask a few fixed lengths
-- (items, spells, interact distances) and you get a band, e.g. 20-25 yd.

---@diagnostic disable-next-line: deprecated -- old API, only used when C_Item is missing
local ItemInRange  = (C_Item and C_Item.IsItemInRange) or IsItemInRange
local SpellInRange = (C_Spell and C_Spell.IsSpellInRange) or IsSpellInRange

-- classic items that exist in Forever (no need to own them). ranges from
-- LibRangeCheck-3.0's item list. several per length in case one is missing
local RANGE_ITEMS = {
  [5]  = { 8149, 15826, 16308 },  -- Voodoo Charm, Curative Animal Salve, Northridge Crowbar
  [10] = { 17626, 9606, 10699 },  -- Frostwolf Muzzle, Treant Muisek Vessel, Yeh'kinya's Bramble
  [15] = { 4559 },                -- CHU's Quest Item
  [20] = { 10645, 1191, 4388 },   -- Gnomish Death Ray, Bag of Marbles, Discombobulator Ray
  [25] = { 13289 },               -- Egan's Blaster
  [30] = { 835, 4941, 3434 },     -- Large Rope Net, Really Sticky Glue, Slumber Sand
  [35] = { 18904, 1399 },         -- Zorbin's Ultra-Shrinker, Magic Candle
  [40] = { 4945, 8348 },          -- Faintly Glowing Skull, Helm of Fire
  [45] = { 221316 },              -- Premo's Poise-Demanding Uniform
}

-- CheckInteractDistance: 3 = duel, 4 = follow
local INTERACT = { duel = 8, follow = 28 }
local INTERACT_BY_RACE = {
  Tauren  = { duel = 6, follow = 25 },
  Scourge = { duel = 7, follow = 27 },
}

local isRangeItem = {}
for _, ids in pairs(RANGE_ITEMS) do
  for _, id in ipairs(ids) do isRangeItem[id] = true end
end
function ns.IsRangeItem(itemID) return isRangeItem[itemID] end

local rulers = {} -- { { range = 5, checks = { {kind, id, label, range}, ... } }, ... } sorted
local active = {} -- per target: first check of each length that answers
local activeNeedsRefresh = true

-- true / false / nil (no answer)
local function Ask(check, unit)
  local result
  if check.kind == "item" then
    result = ns.Ask("IsItemInRange", ItemInRange, check.id, unit)
  elseif check.kind == "spell" then
    result = ns.Ask("IsSpellInRange", SpellInRange, check.id, unit)
  else
    result = ns.Ask("CheckInteractDistance", CheckInteractDistance, unit, check.id)
  end
  if result == true or result == 1 then return true end
  if result == false or result == 0 then return false end
  return nil
end

local function SpellRanges()
  local found = {}
  local function consider(name, spellID)
    if not name or found[name] then return end
    local maxRange
    if C_Spell and C_Spell.GetSpellInfo then
      local info = C_Spell.GetSpellInfo(spellID or name)
      maxRange = info and info.maxRange
    elseif GetSpellInfo then
      maxRange = select(6, GetSpellInfo(spellID or name))
    end
    if maxRange and maxRange > 0 and maxRange <= 60 then found[name] = maxRange end
  end

  if C_SpellBook and C_SpellBook.GetNumSpellBookSkillLines and Enum.SpellBookSpellBank then
    for tab = 1, C_SpellBook.GetNumSpellBookSkillLines() do
      local line = C_SpellBook.GetSpellBookSkillLineInfo(tab)
      if line then
        for slot = line.itemIndexOffset + 1, line.itemIndexOffset + line.numSpellBookItems do
          local item = C_SpellBook.GetSpellBookItemInfo(slot, Enum.SpellBookSpellBank.Player)
          if item and not item.isPassive and item.itemType == Enum.SpellBookItemType.Spell then
            consider(item.name, item.spellID)
          end
        end
      end
    end
  elseif GetNumSpellTabs then
    local book = BOOKTYPE_SPELL or "spell"
    for tab = 1, GetNumSpellTabs() do
      local _, _, offset, count = GetSpellTabInfo(tab)
      for slot = offset + 1, offset + count do
        local name, _, spellID = GetSpellBookItemName(slot, book)
        if name and not (IsPassiveSpell and IsPassiveSpell(slot, book)) then
          consider(name, spellID)
        end
      end
    end
  end
  return found
end

function ns.RebuildRulers()
  local byRange = {}
  local function add(range, kind, id, label)
    local group = byRange[range]
    if not group then
      group = { range = range, checks = {} }
      byRange[range] = group
    end
    group.checks[#group.checks + 1] = { kind = kind, id = id, label = label, range = range }
  end

  if ItemInRange then
    for range, ids in pairs(RANGE_ITEMS) do
      for _, id in ipairs(ids) do
        if C_Item and C_Item.RequestLoadItemDataByID then C_Item.RequestLoadItemDataByID(id) end
        add(range, "item", id, "item " .. id)
      end
    end
  end

  if CheckInteractDistance then
    local distances = INTERACT_BY_RACE[select(2, UnitRace("player"))] or INTERACT
    add(distances.duel, "interact", 3, "duel")
    add(distances.follow, "interact", 4, "follow")
  end

  if SpellInRange then
    for name, range in pairs(SpellRanges()) do add(range, "spell", name, name) end
  end

  wipe(rulers)
  for _, group in pairs(byRange) do rulers[#rulers + 1] = group end
  table.sort(rulers, function(a, b) return a.range < b.range end)
  activeNeedsRefresh = true
end

function ns.RefreshRulersSoon()
  activeNeedsRefresh = true
end

local function PickActiveRulers(unit)
  wipe(active)
  for _, group in ipairs(rulers) do
    for _, check in ipairs(group.checks) do
      if Ask(check, unit) ~= nil then
        active[#active + 1] = check
        break
      end
    end
  end
  activeNeedsRefresh = false
end

-- in range is monotonic (inside 20 means inside 25), so binary search: ~4 calls
-- instead of all of them. nil if a ruler stopped answering
local function Search(unit)
  local low, high = 1, #active
  while low <= high do
    local middle = math.floor((low + high) / 2)
    local inRange = Ask(active[middle], unit)
    if inRange == nil then return nil end
    if inRange then high = middle - 1 else low = middle + 1 end
  end
  local minR = (low > 1) and active[low - 1].range or 0
  local maxR = active[low] and active[low].range or nil
  return minR, maxR
end

-- maxR nil = farther than the longest ruler
function ns.GetRange(unit)
  if activeNeedsRefresh then PickActiveRulers(unit) end
  local minR, maxR = Search(unit)
  if minR == nil then
    PickActiveRulers(unit)
    minR, maxR = Search(unit)
  end
  return minR or 0, maxR
end

-- /sd info
function ns.DescribeRulers(unit)
  local total, working = 0, {}
  for _, group in ipairs(rulers) do
    for _, check in ipairs(group.checks) do
      total = total + 1
      if Ask(check, unit) ~= nil then
        working[#working + 1] = check.range .. " (" .. check.label .. ")"
      end
    end
  end
  return total, working
end
