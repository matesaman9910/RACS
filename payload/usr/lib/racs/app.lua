local computer = require("computer")
local event = require("event")
local term = require("term")
local unicode = require("unicode")

local util = require("racs.util")
local Store = require("racs.store")
local Inventory = require("racs.inventory")
local Protocol = require("racs.protocol")

local App = {}
App.__index = App

local VERSION = "0.4.0"

local function newState()
  return {
    schema = 1,
    applicationVersion = VERSION,
    eventSequence = 0,
    nextLoanId = 1,
    lockdown = false,
    personnel = {},
    loans = {},
    pending = nil,
    activeAlerts = {},
    recentEvents = {}
  }
end

local function repairState(state)
  state.schema = tonumber(state.schema) or 1
  state.applicationVersion = VERSION
  state.eventSequence = tonumber(state.eventSequence) or 0
  state.nextLoanId = tonumber(state.nextLoanId) or 1
  state.lockdown = state.lockdown == true
  state.personnel = type(state.personnel) == "table" and state.personnel or {}
  state.loans = type(state.loans) == "table" and state.loans or {}
  state.activeAlerts = type(state.activeAlerts) == "table" and state.activeAlerts or {}
  state.recentEvents = type(state.recentEvents) == "table" and state.recentEvents or {}
  return state
end

local function itemDescription(stack)
  if not stack then return "none" end
  return string.format("%s x%d slot=%d damage=%d tag=%s label=%s",
    tostring(stack.name), tonumber(stack.size) or 0, tonumber(stack.slot) or 0,
    tonumber(stack.damage) or 0, tostring(stack.hasTag == true), tostring(stack.label))
end

function App.new(config)
  local store = Store.new(config.data)
  local state, source, primaryReason = store:load()
  local created = state == nil
  state = repairState(state or newState())

  local inventory, inventoryReason = Inventory.new({
    publicSide = config.inventory.publicSide,
    stockSide = config.inventory.stockSide,
    equipment = config.equipment
  })
  if not inventory then return nil, inventoryReason end

  local self = setmetatable({
    config = config,
    store = store,
    state = state,
    inventory = inventory,
    protocol = nil,
    running = true,
    fatal = nil,
    lastError = nil,
    lastMonitor = 0,
    expectedDeposit = false,
    stateSource = source,
    createdState = created
  }, App)

  local protocol, protocolReason = Protocol.new(config.network, {
    discover = function() return self:remoteDiscover() end,
    status = function() return self:remoteStatus() end,
    accountability = function() return self:remoteAccountability() end,
    events = function() return self:remoteEvents() end
  })
  if not protocol then return nil, protocolReason end
  self.protocol = protocol

  if created and (source ~= "not found" or primaryReason ~= "not found") then
    self:setAlert("DATA_RECOVERY_REQUIRED", "critical",
      "state could not be loaded; verify backups before live operation")
  elseif source == "backup" then
    self:setAlert("STATE_BACKUP_USED", "warning",
      "primary state was unreadable; loaded state.db.bak")
  end

  self:record("SYSTEM_START", "system", "RACS " .. VERSION .. " state=" .. tostring(source or "new"))
  self:recoverPending()
  return self
end

function App:commissioned()
  return self.config.inventory.sidesConfirmed == true and self.config.equipment.confirmed == true
end

function App:record(eventType, actor, detail)
  self.state.eventSequence = self.state.eventSequence + 1
  local entry = {
    sequence = self.state.eventSequence,
    worldTime = util.worldTime(),
    type = tostring(eventType),
    actor = tostring(actor or "system"),
    detail = tostring(detail or "")
  }
  self.state.recentEvents[#self.state.recentEvents + 1] = entry
  local limit = tonumber(self.config.data.recentEventLimit) or 30
  while #self.state.recentEvents > limit do table.remove(self.state.recentEvents, 1) end
  local ok, reason = self.store:save(self.state)
  if not ok then
    self.lastError = "STATE SAVE FAILED: " .. tostring(reason)
    return nil, self.lastError
  end
  local logOk, logReason = self.store:appendEvent(entry)
  if not logOk then self.lastError = "EVENT LOG FAILED: " .. tostring(logReason) end
  return true
end

function App:setAlert(code, severity, message)
  local existing = self.state.activeAlerts[code]
  if existing then
    existing.lastSeen = util.worldTime()
    existing.count = (tonumber(existing.count) or 1) + 1
    return
  end
  self.state.activeAlerts[code] = {
    code = code,
    severity = severity,
    message = message,
    openedAt = util.worldTime(),
    lastSeen = util.worldTime(),
    count = 1
  }
  self:record("ALERT_RAISED", "system", code .. ": " .. message)
end

function App:clearAlert(code, detail)
  if not self.state.activeAlerts[code] then return end
  self.state.activeAlerts[code] = nil
  self:record("ALERT_CLEARED", "system", code .. (detail and (": " .. detail) or ""))
end

function App:remoteDiscover()
  return {
    node = self.config.nodeName,
    application = "RACS",
    applicationVersion = VERSION,
    protocolVersion = 1,
    readOnly = true
  }
end

function App:remoteStatus()
  local stock = self.inventory:equipmentCount("stock")
  local public = self.inventory:equipmentCount("public")
  local inside = 0
  for _, person in pairs(self.state.personnel) do if person.inside then inside = inside + 1 end end
  return {
    node = self.config.nodeName,
    version = VERSION,
    worldTime = util.worldTime(),
    commissioned = self:commissioned(),
    lockdown = self.state.lockdown,
    inside = inside,
    stockEquipment = stock or -1,
    publicEquipment = public or -1,
    activeLoans = self:activeLoanCount(),
    alerts = util.count(self.state.activeAlerts),
    pending = self.state.pending and self.state.pending.kind or "none"
  }
end

function App:remoteAccountability()
  local people = {}
  for _, person in pairs(self.state.personnel) do
    if person.inside then
      people[#people + 1] = {
        username = person.username,
        loanId = person.activeLoanId or "",
        checkedInAt = person.checkedInAt or 0
      }
    end
  end
  table.sort(people, function(a, b) return a.username < b.username end)
  return {worldTime = util.worldTime(), people = people}
end

function App:remoteEvents()
  local events = {}
  local start = math.max(1, #self.state.recentEvents - 9)
  for i = start, #self.state.recentEvents do events[#events + 1] = util.copyTable(self.state.recentEvents[i]) end
  return {events = events}
end

function App:activeLoanCount()
  local count = 0
  for _, loan in pairs(self.state.loans) do if loan.status == "active" then count = count + 1 end end
  return count
end

function App:handleSignal(signal)
  if self.protocol then self.protocol:handleSignal(signal) end
end

function App:tick(force)
  local now = computer.uptime()
  local interval = tonumber(self.config.inventory.monitorInterval) or 2
  if not force and now - self.lastMonitor < interval then return end
  self.lastMonitor = now

  local public, scanOrReason = self.inventory:publicState()
  if not public then
    self:setAlert("PUBLIC_CHEST_UNAVAILABLE", "critical", tostring(scanOrReason))
    return
  end
  self:clearAlert("PUBLIC_CHEST_UNAVAILABLE")

  local expected = self.expectedDeposit
  if self.state.pending then
    expected = self.state.pending.kind == "issue_waiting_pickup"
      or self.state.pending.kind == "return_prepared"
      or self.state.pending.kind == "unassigned_return_prepared"
  end

  if #public.unexpected > 0 then
    self:setAlert("UNEXPECTED_PUBLIC_ITEM", "critical",
      "public chest contains " .. itemDescription(public.unexpected[1]))
  elseif expected and not public.empty and (public.recognizedCount ~= 1 or public.totalCount ~= 1) then
    self:setAlert("UNEXPECTED_PUBLIC_ITEM", "critical",
      "expected exactly one Geiger in public chest; found " .. tostring(public.totalCount) .. " items")
  elseif not expected and not public.empty then
    self:setAlert("UNEXPECTED_PUBLIC_ITEM", "warning",
      "public chest is not empty while idle: " .. itemDescription(public.recognized[1]))
  else
    self:clearAlert("UNEXPECTED_PUBLIC_ITEM", "public chest condition normalized")
  end

  if self.state.pending and self.state.pending.kind == "issue_waiting_pickup" and public.empty then
    local loanId = self.state.pending.loanId
    self.state.pending = nil
    self:record("ISSUE_PICKED_UP", "system", "loan=" .. tostring(loanId))
  end
end

function App:readLine(prompt, secret, default)
  term.write(prompt)
  local buffer = ""
  while self.running and not self.fatal do
    local signal = {event.pull(0.5)}
    if not signal[1] then
      self:tick(false)
    elseif signal[1] == "modem_message" then
      self:handleSignal(signal)
    elseif signal[1] == "key_down" then
      local char = tonumber(signal[3]) or 0
      local code = tonumber(signal[4]) or 0
      if code == 28 or char == 13 then
        term.write("\n")
        if buffer == "" and default ~= nil then return tostring(default), signal[5] end
        return buffer, signal[5]
      elseif code == 14 or char == 8 then
        if #buffer > 0 then
          buffer = buffer:sub(1, -2)
          term.write("\b \b")
        end
      elseif char == 3 then
        term.write("^C\n")
        return nil, signal[5]
      elseif char > 0 then
        local ok, text = pcall(unicode.char, char)
        if ok and text then
          buffer = buffer .. text
          term.write(secret and "*" or text)
        end
      end
    elseif signal[1] == "clipboard" then
      local text = tostring(signal[3] or ""):gsub("[\r\n]", "")
      buffer = buffer .. text
      term.write(secret and string.rep("*", tonumber(unicode.len(text)) or #text) or text)
    elseif signal[1] == "interrupted" then
      term.write("\n")
      return nil
    end
  end
  return nil
end

function App:pause()
  self:readLine("Press Enter to continue... ", false, "")
end

function App:header(title)
  term.clear()
  term.setCursor(1, 1)
  print(self.config.nodeName .. " / RACS " .. VERSION .. " / " .. title)
  print(string.rep("-", 55))
end

function App:registeredPerson(username)
  return self.state.personnel[util.normalizeUser(username)]
end

function App:registerPerson()
  self:header("Register personnel")
  local username = self:readLine("Minecraft username: ")
  username = util.trim(username)
  if username == "" then print("Cancelled."); return self:pause() end
  local key = util.normalizeUser(username)
  if self.state.personnel[key] then
    print("Already registered as " .. self.state.personnel[key].username)
    return self:pause()
  end
  self.state.personnel[key] = {
    username = username,
    registeredAt = util.worldTime(),
    inside = false,
    activeLoanId = nil,
    readings = {}
  }
  local ok, reason = self:record("PERSON_REGISTERED", username, "username=" .. username)
  print(ok and ("Registered " .. username .. ".") or tostring(reason))
  self:pause()
end

function App:transactionGate(allowLockdown)
  if self.fatal then return nil, self.fatal end
  if not self:commissioned() then return nil, "system is uncommissioned; use Diagnostics first" end
  if self.state.pending then return nil, "an unresolved transaction is active: " .. tostring(self.state.pending.kind) end
  if self.state.activeAlerts.RECOVERY_REQUIRED then return nil, "recovery is required" end
  if not allowLockdown and self.state.lockdown then return nil, "administrative lockdown blocks new check-ins" end
  local public, reason = self.inventory:publicState()
  if not public then return nil, "public chest unavailable: " .. tostring(reason) end
  if not public.empty then return nil, "public chest must be empty before starting" end
  return true
end

function App:exactPublicEquipment()
  local public, reason = self.inventory:publicState()
  if not public then return nil, "public chest unavailable: " .. tostring(reason) end
  if #public.unexpected > 0 then return nil, "unexpected public-chest item detected" end
  if public.recognizedCount ~= 1 or public.totalCount ~= 1 or #public.recognized ~= 1 then
    return nil, "expected exactly one configured Geiger in public chest"
  end
  return public.recognized[1]
end

function App:finalizeIssue(pending, recovery)
  local person = self.state.personnel[pending.userKey]
  if not person then return nil, "person record missing" end
  local loanId = tostring(pending.loanId)
  self.state.loans[loanId] = self.state.loans[loanId] or {
    id = loanId,
    username = person.username,
    status = "active",
    issuedAt = util.worldTime(),
    issueItem = pending.item
  }
  person.inside = true
  person.checkedInAt = self.state.loans[loanId].issuedAt
  person.activeLoanId = loanId
  self.state.nextLoanId = math.max(self.state.nextLoanId, (tonumber(loanId) or 0) + 1)
  self.state.pending = {
    kind = "issue_waiting_pickup",
    loanId = loanId,
    userKey = pending.userKey,
    startedAt = pending.startedAt,
    item = pending.item
  }
  return self:record(recovery and "ISSUE_RECOVERED" or "ISSUE_COMPLETED", person.username,
    "loan=" .. loanId .. " item=" .. tostring(pending.item.name))
end

function App:checkIn()
  self:header("Check in / issue Geiger")
  local ok, reason = self:transactionGate(false)
  if not ok then print("BLOCKED: " .. reason); return self:pause() end

  local username = self:readLine("Registered username: ")
  local key = util.normalizeUser(username)
  local person = self.state.personnel[key]
  if not person then print("Not registered."); return self:pause() end
  if person.inside or person.activeLoanId then print("Person already has an active check-in/loan."); return self:pause() end

  local stockItem, stockStateOrReason = self.inventory:firstStockEquipment()
  if not stockItem then print("No equipment available: " .. tostring(stockStateOrReason)); return self:pause() end
  local stockBefore = stockStateOrReason.recognizedCount
  local pending = {
    kind = "issue_prepared",
    loanId = tostring(self.state.nextLoanId),
    userKey = key,
    startedAt = util.worldTime(),
    stockBefore = stockBefore,
    item = util.copyTable(stockItem)
  }
  self.state.pending = pending
  local saved, saveReason = self:record("ISSUE_PREPARED", person.username,
    "loan=" .. pending.loanId .. " stockBefore=" .. tostring(stockBefore))
  if not saved then self.state.pending = nil; print(saveReason); return self:pause() end

  local publicNow, publicReason = self.inventory:publicState()
  local stockNow, stockScanOrReason = self.inventory:stockState()
  local sourceStillValid = false
  if stockNow then
    for i = 1, #stockNow.recognized do
      if stockNow.recognized[i].slot == stockItem.slot then sourceStillValid = true break end
    end
  end
  if not publicNow or not publicNow.empty or not sourceStillValid then
    self.state.pending = nil
    self:record("ISSUE_ABORTED", person.username,
      "pre-transfer revalidation failed: " .. tostring(publicReason or stockScanOrReason or "chest changed"))
    print("Chest contents changed before transfer. Nothing was moved.")
    return self:pause()
  end

  local moved, transferReason = self.inventory:transferStockToPublic(stockItem.slot)
  if tonumber(moved) ~= 1 then
    self.state.pending = nil
    self:record("ISSUE_FAILED", person.username, "transfer=" .. tostring(transferReason or moved))
    print("Transfer failed; no loan opened.")
    return self:pause()
  end

  local finalized, finalizeReason = self:finalizeIssue(pending, false)
  if not finalized then
    self.fatal = "item moved but state finalization failed: " .. tostring(finalizeReason)
    print("FATAL: " .. self.fatal)
    return self:pause()
  end

  print("One Geiger is in the public chest. Collect it now.")
  local deadline = computer.uptime() + (tonumber(self.config.inventory.issuePickupTimeout) or 30)
  while computer.uptime() < deadline and self.state.pending do
    local signal = {event.pull(0.5)}
    if signal[1] == "modem_message" then self:handleSignal(signal) end
    self:tick(true)
  end
  if self.state.pending then
    print("Pickup not confirmed. The loan is active; transaction remains pending.")
    print("Clear the public chest, then allow monitoring to confirm pickup.")
  else
    print("Pickup confirmed. " .. person.username .. " is recorded inside.")
  end
  self:pause()
end

function App:waitForReturnItem(timeout)
  self.expectedDeposit = true
  local deadline = computer.uptime() + timeout
  while computer.uptime() < deadline do
    local public, reason = self.inventory:publicState()
    if not public then self.expectedDeposit = false; return nil, "public chest unavailable: " .. tostring(reason) end
    if #public.unexpected > 0 then
      self:setAlert("UNEXPECTED_PUBLIC_ITEM", "critical", itemDescription(public.unexpected[1]))
      self.expectedDeposit = false
      return nil, "unexpected item detected; nothing moved"
    end
    if public.recognizedCount == 1 and public.totalCount == 1 and #public.recognized == 1 then
      self.expectedDeposit = false
      return public.recognized[1]
    end
    if public.totalCount > 1 then
      self.expectedDeposit = false
      return nil, "deposit exactly one configured Geiger"
    end
    local signal = {event.pull(0.5)}
    if signal[1] == "modem_message" then self:handleSignal(signal) end
    if signal[1] == "key_down" and tonumber(signal[4]) == 1 then
      self.expectedDeposit = false
      return nil, "cancelled"
    end
  end
  self.expectedDeposit = false
  return nil, "timed out waiting for deposit"
end

function App:finalizeAssignedReturn(pending, recovery)
  local person = self.state.personnel[pending.userKey]
  local loan = self.state.loans[tostring(pending.loanId)]
  if not person or not loan then return nil, "person or loan record missing" end
  loan.status = "returned"
  loan.returnedAt = util.worldTime()
  loan.returnItem = pending.item
  loan.selfReportedReading = pending.reading
  person.inside = false
  person.checkedOutAt = loan.returnedAt
  person.activeLoanId = nil
  person.readings = person.readings or {}
  person.readings[#person.readings + 1] = {
    worldTime = loan.returnedAt,
    text = pending.reading,
    loanId = tostring(pending.loanId),
    selfReported = true
  }
  self.state.pending = nil
  return self:record(recovery and "RETURN_RECOVERED" or "CHECK_OUT_COMPLETED", person.username,
    "loan=" .. tostring(pending.loanId) .. " reading=" .. tostring(pending.reading))
end

function App:checkOut()
  self:header("Check out / return Geiger")
  local ok, reason = self:transactionGate(true)
  if not ok then print("BLOCKED: " .. reason); return self:pause() end

  local username = self:readLine("Registered username: ")
  local key = util.normalizeUser(username)
  local person = self.state.personnel[key]
  if not person or not person.inside or not person.activeLoanId then
    print("No active check-in/loan for that person.")
    return self:pause()
  end
  local reading = util.trim(self:readLine("Self-reported radiation reading (free text): "))
  if reading == "" then print("A reading entry is required; use 'not available' if necessary."); return self:pause() end

  print("Place exactly one configured Geiger in the empty public chest.")
  print("Do not add any other item. Press Esc to cancel.")
  local item, waitReason = self:waitForReturnItem(tonumber(self.config.inventory.returnDepositTimeout) or 60)
  if not item then print("Return not processed: " .. tostring(waitReason)); return self:pause() end

  local stockBefore, stockReason = self.inventory:equipmentCount("stock")
  if stockBefore == nil then print("Secure stock unavailable: " .. tostring(stockReason)); return self:pause() end
  local pending = {
    kind = "return_prepared",
    userKey = key,
    loanId = tostring(person.activeLoanId),
    reading = reading,
    item = util.copyTable(item),
    stockBefore = stockBefore,
    startedAt = util.worldTime()
  }
  self.state.pending = pending
  local saved, saveReason = self:record("RETURN_PREPARED", person.username,
    "loan=" .. pending.loanId .. " stockBefore=" .. tostring(stockBefore))
  if not saved then self.state.pending = nil; print(saveReason); return self:pause() end

  local revalidated, revalidationReason = self:exactPublicEquipment()
  if not revalidated or revalidated.slot ~= item.slot then
    self.state.pending = nil
    self:record("RETURN_ABORTED", person.username,
      "pre-transfer revalidation failed: " .. tostring(revalidationReason or "slot changed"))
    print("Public chest changed before transfer. Nothing was moved.")
    return self:pause()
  end

  local moved, transferReason = self.inventory:transferPublicToStock(item.slot)
  if tonumber(moved) ~= 1 then
    self.state.pending = nil
    self:record("RETURN_FAILED", person.username, "transfer=" .. tostring(transferReason or moved))
    print("Transfer failed. The person remains inside and the loan remains active.")
    return self:pause()
  end
  local finalized, finalizeReason = self:finalizeAssignedReturn(pending, false)
  if not finalized then
    self.fatal = "item moved but return finalization failed: " .. tostring(finalizeReason)
    print("FATAL: " .. self.fatal)
  else
    print("Return confirmed. " .. person.username .. " is recorded outside.")
  end
  self:pause()
end

function App:equipmentOnlyReturn()
  self:header("Equipment-only return")
  local ok, reason = self:transactionGate(true)
  if not ok then print("BLOCKED: " .. reason); return self:pause() end
  print("This returns stock only and does not change personnel accountability.")
  print("Place exactly one configured Geiger in the public chest. Press Esc to cancel.")
  local item, waitReason = self:waitForReturnItem(tonumber(self.config.inventory.returnDepositTimeout) or 60)
  if not item then print("Return not processed: " .. tostring(waitReason)); return self:pause() end
  local stockBefore, stockReason = self.inventory:equipmentCount("stock")
  if stockBefore == nil then print("Secure stock unavailable: " .. tostring(stockReason)); return self:pause() end
  self.state.pending = {
    kind = "unassigned_return_prepared",
    item = util.copyTable(item),
    stockBefore = stockBefore,
    startedAt = util.worldTime()
  }
  local saved, saveReason = self:record("UNASSIGNED_RETURN_PREPARED", "operator",
    "stockBefore=" .. tostring(stockBefore))
  if not saved then self.state.pending = nil; print(saveReason); return self:pause() end
  local pending = self.state.pending
  local revalidated, revalidationReason = self:exactPublicEquipment()
  if not revalidated or revalidated.slot ~= item.slot then
    self.state.pending = nil
    self:record("UNASSIGNED_RETURN_ABORTED", "operator",
      "pre-transfer revalidation failed: " .. tostring(revalidationReason or "slot changed"))
    print("Public chest changed before transfer. Nothing was moved.")
    return self:pause()
  end
  local moved, transferReason = self.inventory:transferPublicToStock(item.slot)
  if tonumber(moved) ~= 1 then
    self.state.pending = nil
    self:record("UNASSIGNED_RETURN_FAILED", "operator", "transfer=" .. tostring(transferReason or moved))
    print("Transfer failed; item remains in public chest.")
  else
    self.state.pending = nil
    self:record("UNASSIGNED_RETURN_COMPLETED", "operator", "item=" .. tostring(pending.item.name))
    print("Equipment returned to secure stock. Accountability was not changed.")
  end
  self:pause()
end

function App:showAccountability()
  self:header("Personnel accountability")
  local people = {}
  for _, person in pairs(self.state.personnel) do if person.inside then people[#people + 1] = person end end
  table.sort(people, function(a, b) return a.username < b.username end)
  if #people == 0 then
    print("No personnel are currently recorded inside.")
  else
    for i = 1, #people do
      print(string.format("%2d. %-20s loan=%s since=%s", i, people[i].username,
        tostring(people[i].activeLoanId), util.worldTimeLabel(people[i].checkedInAt)))
    end
  end
  print("")
  print("Inside: " .. #people .. "  Active loans: " .. self:activeLoanCount())
  self:pause()
end

function App:showStatus()
  self:header("System status")
  local status = self:remoteStatus()
  print("Commissioned: " .. tostring(status.commissioned))
  print("Lockdown:     " .. tostring(status.lockdown))
  print("Inside:       " .. tostring(status.inside))
  print("Active loans: " .. tostring(status.activeLoans))
  print("Stock count:  " .. tostring(status.stockEquipment))
  print("Public count: " .. tostring(status.publicEquipment))
  print("Pending:      " .. tostring(status.pending))
  print("Alerts:       " .. tostring(status.alerts))
  if self.lastError then print("Last error:   " .. self.lastError) end
  local keys = util.sortedKeys(self.state.activeAlerts)
  for i = 1, #keys do
    local alert = self.state.activeAlerts[keys[i]]
    print("  [" .. alert.severity .. "] " .. alert.code .. ": " .. alert.message)
  end
  self:pause()
end

function App:diagnostics()
  self:header("Diagnostics / commissioning")
  print("Configured public side: " .. tostring(self.config.inventory.publicSide))
  print("Configured stock side:  " .. tostring(self.config.inventory.stockSide))
  print("Sides confirmed:        " .. tostring(self.config.inventory.sidesConfirmed))
  print("Configured item name:   " .. tostring(self.config.equipment.name))
  print("Item confirmed:         " .. tostring(self.config.equipment.confirmed))
  print("")
  print("Adjacent inventories (relative to the Transposer):")
  local adjacent = self.inventory:listAdjacent()
  for i = 1, #adjacent do
    local entry = adjacent[i]
    if entry.scan then
      print(string.format("  %-5s inventory=%s slots=%d occupied=%d", entry.side,
        entry.scan.name, entry.scan.size, #entry.scan.stacks))
    else
      print(string.format("  %-5s -- %s", entry.side, tostring(entry.reason)))
    end
  end
  print("")
  local public, scan = self.inventory:publicState()
  if not public then
    print("Public chest scan failed: " .. tostring(scan))
  elseif #scan.stacks == 0 then
    print("Public chest is empty. Put one known Geiger there to inspect it.")
  else
    print("Public chest stack details:")
    for i = 1, #scan.stacks do
      local stack = scan.stacks[i]
      print("  " .. itemDescription(stack))
      print("    matches configured equipment: " .. tostring(self.inventory:isEquipment(stack)))
    end
  end
  print("")
  print("RACS will not change confirmation flags automatically.")
  print("After proving the mapping and item name, empty the public chest,")
  print("stop RACS, edit /etc/racs.cfg, and restart.")
  self:pause()
end

function App:authenticateAdmin()
  if self.config.adminPin == "CHANGE_ME" or util.trim(self.config.adminPin) == "" then
    print("Admin functions disabled until adminPin is changed in /etc/racs.cfg.")
    return false
  end
  local pin = self:readLine("Admin PIN: ", true)
  if pin ~= self.config.adminPin then
    self:record("ADMIN_AUTH_FAILED", "operator", "console")
    print("Incorrect PIN.")
    return false
  end
  return true
end

function App:showRecentEvents()
  self:header("Recent events")
  for i = 1, #self.state.recentEvents do
    local entry = self.state.recentEvents[i]
    print(string.format("%d %s %-24s %s", entry.sequence,
      util.worldTimeLabel(entry.worldTime), entry.type, entry.detail))
  end
  self:pause()
end

function App:searchPersonnel()
  self:header("Personnel search")
  local query = util.normalizeUser(self:readLine("Username: "))
  local person = self.state.personnel[query]
  if not person then print("No record found."); return self:pause() end
  print("Username:       " .. person.username)
  print("Inside:         " .. tostring(person.inside))
  print("Active loan:    " .. tostring(person.activeLoanId or "none"))
  print("Registered:     " .. util.worldTimeLabel(person.registeredAt))
  print("Reading records: " .. tostring(#(person.readings or {})))
  for i = 1, #(person.readings or {}) do
    local reading = person.readings[i]
    print("  " .. util.worldTimeLabel(reading.worldTime) .. " loan=" .. tostring(reading.loanId)
      .. " SELF-REPORTED: " .. tostring(reading.text))
  end
  self:pause()
end

function App:resumePending()
  local pending = self.state.pending
  if not pending then print("No pending transaction."); return end
  if pending.kind == "issue_waiting_pickup" then
    self:tick(true)
    print(self.state.pending and "Still waiting for public chest to become empty." or "Pickup confirmed.")
    return
  end
  if pending.kind ~= "return_prepared" and pending.kind ~= "unassigned_return_prepared" then
    print("Pending transaction requires manual inspection: " .. tostring(pending.kind))
    return
  end
  local public, reason = self.inventory:publicState()
  if not public then print("Public chest unavailable: " .. tostring(reason)); return end
  if #public.unexpected > 0 or public.recognizedCount ~= 1 or public.totalCount ~= 1 then
    print("Expected exactly one configured Geiger and no other items in public chest.")
    return
  end
  local moved, transferReason = self.inventory:transferPublicToStock(public.recognized[1].slot)
  if tonumber(moved) ~= 1 then print("Transfer failed: " .. tostring(transferReason or moved)); return end
  if pending.kind == "return_prepared" then
    local ok, finalizeReason = self:finalizeAssignedReturn(pending, true)
    if not ok then
      self.fatal = "recovered transfer finalization failed: " .. tostring(finalizeReason)
      print("FATAL: " .. self.fatal)
      return
    end
  else
    self.state.pending = nil
    self:record("UNASSIGNED_RETURN_RECOVERED", "administrator", "item=" .. tostring(pending.item.name))
  end
  self:clearAlert("RECOVERY_REQUIRED", "pending return resumed")
  print("Pending return resumed and completed.")
end

function App:forceClearPending()
  if not self.state.pending then print("No pending transaction."); return end
  print("This does not move items or repair personnel/loan records.")
  local confirmation = self:readLine("Type CLEAR to acknowledge manual reconciliation: ")
  if confirmation ~= "CLEAR" then print("Cancelled."); return end
  local previous = self.state.pending.kind
  self.state.pending = nil
  self:record("PENDING_FORCE_CLEARED", "administrator", "previous=" .. tostring(previous))
  self:clearAlert("RECOVERY_REQUIRED", "administrator force-cleared pending state")
  print("Pending marker cleared. Verify physical counts and accountability now.")
end

function App:adminMenu()
  self:header("Administration")
  if not self:authenticateAdmin() then return self:pause() end
  while true do
    self:header("Administration")
    print("1  Toggle lockdown (currently " .. tostring(self.state.lockdown) .. ")")
    print("2  Search personnel")
    print("3  Show recent events")
    print("4  Resume/recheck pending transaction")
    print("5  Force-clear pending marker")
    print("B  Back")
    local choice = string.upper(util.trim(self:readLine("> ")))
    if choice == "1" then
      self.state.lockdown = not self.state.lockdown
      self:record("LOCKDOWN_CHANGED", "administrator", "enabled=" .. tostring(self.state.lockdown))
    elseif choice == "2" then self:searchPersonnel()
    elseif choice == "3" then self:showRecentEvents()
    elseif choice == "4" then self:header("Pending recovery"); self:resumePending(); self:pause()
    elseif choice == "5" then self:header("Force-clear pending"); self:forceClearPending(); self:pause()
    elseif choice == "B" then return end
  end
end

function App:recoverPending()
  local pending = self.state.pending
  if not pending then return end
  local stockCount, stockReason = self.inventory:equipmentCount("stock")
  local public, publicReason = self.inventory:publicState()
  if stockCount == nil or not public then
    self:setAlert("RECOVERY_REQUIRED", "critical",
      "cannot inspect inventories: " .. tostring(stockReason or publicReason))
    return
  end

  if pending.kind == "issue_prepared" then
    local stockDecreased = stockCount <= (tonumber(pending.stockBefore) or stockCount) - 1
    if stockDecreased or public.recognizedCount >= 1 then
      local ok, reason = self:finalizeIssue(pending, true)
      if not ok then self:setAlert("RECOVERY_REQUIRED", "critical", tostring(reason)) end
    elseif public.empty and stockCount == tonumber(pending.stockBefore) then
      self.state.pending = nil
      self:record("ISSUE_RECOVERY_CANCELLED", "system", "no transfer evidence")
    else
      self:setAlert("RECOVERY_REQUIRED", "critical", "ambiguous prepared issue")
    end
  elseif pending.kind == "issue_waiting_pickup" then
    if public.empty then
      self.state.pending = nil
      self:record("ISSUE_PICKUP_RECOVERED", "system", "loan=" .. tostring(pending.loanId))
    end
  elseif pending.kind == "return_prepared" or pending.kind == "unassigned_return_prepared" then
    local stockIncreased = stockCount >= (tonumber(pending.stockBefore) or stockCount) + 1
    if stockIncreased and public.empty then
      if pending.kind == "return_prepared" then
        local ok, reason = self:finalizeAssignedReturn(pending, true)
        if not ok then self:setAlert("RECOVERY_REQUIRED", "critical", tostring(reason)) end
      else
        self.state.pending = nil
        self:record("UNASSIGNED_RETURN_RECOVERED", "system", "stock count evidence")
      end
    elseif public.empty and stockCount == tonumber(pending.stockBefore) then
      self.state.pending = nil
      self:record("RETURN_RECOVERY_CANCELLED", "system", "no transfer evidence")
    elseif public.recognizedCount == 1 and #public.unexpected == 0 then
      self:setAlert("RECOVERY_REQUIRED", "warning", "pending return is still in public chest; admin may resume")
    else
      self:setAlert("RECOVERY_REQUIRED", "critical", "ambiguous prepared return")
    end
  else
    self:setAlert("RECOVERY_REQUIRED", "critical", "unknown pending transaction kind")
  end
end

function App:mainMenu()
  while self.running and not self.fatal do
    self:tick(true)
    self:header("Main terminal")
    local status = self:remoteStatus()
    print(string.format("Commissioned: %-5s  Lockdown: %-5s  Inside: %d  Stock: %d  Alerts: %d",
      tostring(status.commissioned), tostring(status.lockdown), status.inside,
      status.stockEquipment, status.alerts))
    if self.state.pending then print("PENDING: " .. tostring(self.state.pending.kind)) end
    print("")
    print("1  Register personnel")
    print("2  Check in / issue Geiger")
    print("3  Check out / return + self-reported reading")
    print("4  Equipment-only return")
    print("5  Personnel accountability")
    print("6  System status and alerts")
    print("7  Administration")
    print("8  Diagnostics / commissioning")
    print("Q  Quit")
    local choice = string.upper(util.trim(self:readLine("> ")))
    if choice == "1" then self:registerPerson()
    elseif choice == "2" then self:checkIn()
    elseif choice == "3" then self:checkOut()
    elseif choice == "4" then self:equipmentOnlyReturn()
    elseif choice == "5" then self:showAccountability()
    elseif choice == "6" then self:showStatus()
    elseif choice == "7" then self:adminMenu()
    elseif choice == "8" then self:diagnostics()
    elseif choice == "Q" then self.running = false end
  end

  if self.fatal then
    self:header("FATAL STOP")
    print(self.fatal)
    print("Do not move items. Preserve the disk and reconcile state/chest counts.")
  else
    self:record("SYSTEM_STOP", "operator", "normal exit")
  end
  if self.protocol then self.protocol:close() end
end

return App

