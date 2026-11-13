local component = require("component")
local computer = require("computer")
local event = require("event")
local serialization = require("serialization")
local term = require("term")

local function loadConfig(path)
  local chunk = loadfile(path)
  if not chunk then return {} end
  local ok, value = pcall(chunk)
  if ok and type(value) == "table" then return value end
  return {}
end

local config = loadConfig("/etc/racs-dashboard.cfg")
config.port = tonumber(config.port) or 42100
config.refreshSeconds = tonumber(config.refreshSeconds) or 5

if not component.isAvailable("modem") then
  io.stderr:write("No modem component detected.\n")
  return 1
end
local modem = component.getPrimary("modem")
modem.open(config.port)
if modem.isWireless and modem.isWireless() and config.strength then
  pcall(modem.setStrength, config.strength)
end

math.randomseed(math.floor(computer.uptime() * 1000))
local sequence = 0
local function requestId()
  sequence = sequence + 1
  return tostring(math.floor(computer.uptime() * 1000)) .. "-" .. tostring(sequence) .. "-" .. tostring(math.random(1000, 9999))
end

local function packet(action, token)
  return serialization.serialize({
    protocol = "RACS",
    version = 1,
    type = "request",
    id = requestId(),
    action = action,
    token = token
  })
end

local server = tostring(config.serverAddress or "")
if server == "" then
  print("Discovering RACS servers...")
  modem.broadcast(config.port, packet("DISCOVER", ""))
  local deadline = computer.uptime() + 5
  while computer.uptime() < deadline and server == "" do
    local signal = {event.pull(deadline - computer.uptime(), "modem_message")}
    if signal[1] and tonumber(signal[4]) == config.port and type(signal[6]) == "string" then
      local ok, response = pcall(serialization.unserialize, signal[6])
      if ok and type(response) == "table" and response.protocol == "RACS"
          and response.type == "response" and response.ok and response.data then
        server = signal[3]
        print("Found " .. tostring(response.data.node) .. " at " .. server)
      end
    end
  end
end

if server == "" then
  modem.close(config.port)
  io.stderr:write("No RACS server found. Set serverAddress in /etc/racs-dashboard.cfg.\n")
  return 1
end
if config.readToken == nil or config.readToken == "" or config.readToken == "CHANGE_ME_READ_TOKEN" then
  modem.close(config.port)
  io.stderr:write("Set the matching readToken in /etc/racs-dashboard.cfg.\n")
  return 1
end

local status, accountability, lastError
local function draw()
  term.clear()
  term.setCursor(1, 1)
  print("RACS read-only dashboard / server " .. server:sub(1, 8))
  print(string.rep("-", 55))
  if lastError then print("ERROR: " .. lastError) end
  if status then
    print("Node:          " .. tostring(status.node))
    print("Commissioned:  " .. tostring(status.commissioned))
    print("Lockdown:      " .. tostring(status.lockdown))
    print("Inside:        " .. tostring(status.inside))
    print("Active loans:  " .. tostring(status.activeLoans))
    print("Stock:         " .. tostring(status.stockEquipment))
    print("Public:        " .. tostring(status.publicEquipment))
    print("Alerts:        " .. tostring(status.alerts))
    print("Pending:       " .. tostring(status.pending))
    print("World time:    " .. tostring(status.worldTime))
  else
    print("Waiting for status...")
  end
  print("")
  print("Personnel recorded inside:")
  local people = accountability and accountability.people or {}
  if #people == 0 then print("  none") end
  for i = 1, #people do
    print("  " .. tostring(people[i].username) .. "  loan=" .. tostring(people[i].loanId))
  end
  print("")
  print("Read-only protocol. Ctrl+C to exit.")
end

local nextRefresh = 0
local running = true
while running do
  if computer.uptime() >= nextRefresh then
    modem.send(server, config.port, packet("STATUS", config.readToken))
    modem.send(server, config.port, packet("ACCOUNTABILITY", config.readToken))
    nextRefresh = computer.uptime() + config.refreshSeconds
  end
  local signal = {event.pull(0.5)}
  if signal[1] == "interrupted" then
    running = false
  elseif signal[1] == "modem_message" and signal[3] == server and tonumber(signal[4]) == config.port
      and type(signal[6]) == "string" then
    local ok, response = pcall(serialization.unserialize, signal[6])
    if ok and type(response) == "table" and response.protocol == "RACS" and response.type == "response" then
      if response.ok and type(response.data) == "table" then
        if response.data.node and response.data.activeLoans ~= nil then status = response.data end
        if response.data.people then accountability = response.data end
        lastError = nil
      else
        lastError = tostring(response.error or "request rejected")
      end
      draw()
    end
  end
end

modem.close(config.port)
term.clear()
term.setCursor(1, 1)
print("RACS dashboard stopped.")

