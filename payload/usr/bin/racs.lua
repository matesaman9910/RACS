local function loadConfig(path)
  local chunk, reason = loadfile(path)
  if not chunk then return nil, reason end
  local ok, config = pcall(chunk)
  if not ok then return nil, config end
  if type(config) ~= "table" then return nil, "configuration must return a table" end
  return config
end

local config, reason = loadConfig("/etc/racs.cfg")
if not config then
  io.stderr:write("Cannot load /etc/racs.cfg: " .. tostring(reason) .. "\n")
  return 1
end

local required = {"inventory", "equipment", "data", "network"}
for i = 1, #required do
  if type(config[required[i]]) ~= "table" then
    io.stderr:write("Invalid config: missing table " .. required[i] .. "\n")
    return 1
  end
end
if type(config.equipment.name) ~= "string" or config.equipment.name == "" then
  io.stderr:write("Invalid config: equipment.name is required\n")
  return 1
end
if tonumber(config.network.port) == nil or config.network.port < 1 or config.network.port > 65535 then
  io.stderr:write("Invalid config: network.port must be 1..65535\n")
  return 1
end

local App = require("racs.app")
local app, appReason = App.new(config)
if not app then
  io.stderr:write("RACS startup failed: " .. tostring(appReason) .. "\n")
  return 1
end

local ok, runReason = xpcall(function() app:mainMenu() end, debug.traceback)
if not ok then
  if app.protocol then app.protocol:close() end
  io.stderr:write("RACS stopped by an unhandled error:\n" .. tostring(runReason) .. "\n")
  io.stderr:write("Do not move items until chest contents and saved records are reconciled.\n")
  return 1
end

