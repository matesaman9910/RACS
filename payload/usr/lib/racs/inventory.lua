local component = require("component")
local sides = require("sides")

local Inventory = {}
Inventory.__index = Inventory

local sideOrder = {"down", "up", "north", "south", "west", "east"}

local function sideNumber(name)
  if type(name) == "number" then return name end
  if type(name) ~= "string" or sides[name] == nil then
    error("invalid Transposer side: " .. tostring(name))
  end
  return sides[name]
end

local function normalizeStack(stack, slot)
  if type(stack) ~= "table" or not stack.name then return nil end
  local size = tonumber(stack.size) or 0
  if size <= 0 then return nil end
  return {
    slot = slot,
    name = tostring(stack.name),
    label = tostring(stack.label or stack.name),
    size = size,
    damage = tonumber(stack.damage) or 0,
    maxSize = tonumber(stack.maxSize) or 0,
    hasTag = stack.hasTag == true
  }
end

function Inventory.new(config, injectedProxy)
  local proxy = injectedProxy
  if not proxy then
    if not component.isAvailable("transposer") then
      return nil, "no Transposer component detected"
    end
    proxy = component.getPrimary("transposer")
  end
  local instance = setmetatable({
    transposer = proxy,
    publicSide = sideNumber(config.publicSide),
    stockSide = sideNumber(config.stockSide),
    publicSideName = tostring(config.publicSide),
    stockSideName = tostring(config.stockSide),
    equipment = config.equipment
  }, Inventory)
  if instance.publicSide == instance.stockSide then
    return nil, "publicSide and stockSide must be different"
  end
  return instance
end

function Inventory:scanSide(side)
  local okSize, sizeOrReason = pcall(self.transposer.getInventorySize, side)
  if not okSize or not sizeOrReason then
    return nil, okSize and "no adjacent inventory" or tostring(sizeOrReason)
  end
  local inventorySize = tonumber(sizeOrReason)
  if not inventorySize then return nil, "invalid inventory size" end

  local rawStacks
  local okIterator, iterator = pcall(self.transposer.getAllStacks, side)
  if okIterator and iterator and iterator.getAll then
    local okAll, all = pcall(iterator.getAll)
    if okAll and type(all) == "table" then rawStacks = all end
  end

  local stacks = {}
  for slot = 1, inventorySize do
    local raw = rawStacks and rawStacks[slot]
    if raw == nil and not rawStacks then
      local okStack, stack = pcall(self.transposer.getStackInSlot, side, slot)
      if not okStack then return nil, tostring(stack) end
      raw = stack
    end
    local normalized = normalizeStack(raw, slot)
    if normalized then stacks[#stacks + 1] = normalized end
  end

  local okName, inventoryName = pcall(self.transposer.getInventoryName, side)
  return {
    side = side,
    size = inventorySize,
    name = okName and tostring(inventoryName or "unknown") or "unknown",
    stacks = stacks
  }
end

function Inventory:scanPublic()
  return self:scanSide(self.publicSide)
end

function Inventory:scanStock()
  return self:scanSide(self.stockSide)
end

function Inventory:isEquipment(stack)
  if not stack or stack.name ~= self.equipment.name then return false end
  if self.equipment.damage ~= nil and tonumber(stack.damage) ~= tonumber(self.equipment.damage) then
    return false
  end
  if self.equipment.requireNoTag and stack.hasTag then return false end
  return true
end

function Inventory:classify(scan)
  local recognized, unexpected = {}, {}
  local recognizedCount, totalCount = 0, 0
  for i = 1, #(scan.stacks or {}) do
    local stack = scan.stacks[i]
    totalCount = totalCount + stack.size
    if self:isEquipment(stack) then
      recognized[#recognized + 1] = stack
      recognizedCount = recognizedCount + stack.size
    else
      unexpected[#unexpected + 1] = stack
    end
  end
  return {
    recognized = recognized,
    unexpected = unexpected,
    recognizedCount = recognizedCount,
    totalCount = totalCount,
    empty = totalCount == 0
  }
end

function Inventory:publicState()
  local scan, reason = self:scanPublic()
  if not scan then return nil, reason end
  return self:classify(scan), scan
end

function Inventory:stockState()
  local scan, reason = self:scanStock()
  if not scan then return nil, reason end
  return self:classify(scan), scan
end

function Inventory:equipmentCount(which)
  local state, scanOrReason
  if which == "public" then
    state, scanOrReason = self:publicState()
  else
    state, scanOrReason = self:stockState()
  end
  if not state then return nil, scanOrReason end
  return state.recognizedCount, state, scanOrReason
end

function Inventory:firstStockEquipment()
  local state, scan = self:stockState()
  if not state then return nil, scan end
  for i = 1, #state.recognized do
    if state.recognized[i].size > 0 then return state.recognized[i], state, scan end
  end
  return nil, "no configured equipment in secure stock"
end

function Inventory:transferStockToPublic(sourceSlot)
  return self.transposer.transferItem(self.stockSide, self.publicSide, 1, sourceSlot)
end

function Inventory:transferPublicToStock(sourceSlot)
  return self.transposer.transferItem(self.publicSide, self.stockSide, 1, sourceSlot)
end

function Inventory:listAdjacent()
  local result = {}
  for i = 1, #sideOrder do
    local name = sideOrder[i]
    local scan, reason = self:scanSide(sideNumber(name))
    result[#result + 1] = {
      side = name,
      scan = scan,
      reason = reason
    }
  end
  return result
end

return Inventory

