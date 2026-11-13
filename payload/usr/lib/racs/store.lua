local filesystem = require("filesystem")
local serialization = require("serialization")
local util = require("racs.util")

local Store = {}
Store.__index = Store

local function readAll(path)
  local handle, reason = io.open(path, "rb")
  if not handle then return nil, reason end
  local value = handle:read("*a")
  handle:close()
  return value
end

local function writeAll(path, value)
  local handle, reason = io.open(path, "wb")
  if not handle then return nil, reason end
  local ok, writeReason = handle:write(value)
  handle:close()
  if not ok then return nil, writeReason end
  return true
end

local function ensureParent(path)
  local parent = filesystem.path(path)
  if filesystem.exists(parent) then return true end
  return filesystem.makeDirectory(parent)
end

function Store.new(config)
  return setmetatable({
    statePath = assert(config.statePath, "statePath required"),
    logPath = assert(config.logPath, "logPath required")
  }, Store)
end

function Store:decode(path)
  if not filesystem.exists(path) then return nil, "not found" end
  local raw, reason = readAll(path)
  if not raw then return nil, reason end
  local ok, value = pcall(serialization.unserialize, raw)
  if not ok or type(value) ~= "table" then
    return nil, ok and "decoded state is not a table" or tostring(value)
  end
  return value
end

function Store:load()
  local state, reason = self:decode(self.statePath)
  if state then return state, "primary" end
  local backup, backupReason = self:decode(self.statePath .. ".bak")
  if backup then return backup, "backup", reason end
  return nil, reason, backupReason
end

function Store:save(state)
  local okSerialize, encoded = pcall(serialization.serialize, state)
  if not okSerialize then return nil, "serialize failed: " .. tostring(encoded) end

  local okParent, parentReason = ensureParent(self.statePath)
  if not okParent then return nil, "cannot create state directory: " .. tostring(parentReason) end

  local temporary = self.statePath .. ".tmp"
  if filesystem.exists(temporary) then filesystem.remove(temporary) end
  local okWrite, writeReason = writeAll(temporary, encoded)
  if not okWrite then return nil, "temporary write failed: " .. tostring(writeReason) end

  if filesystem.exists(self.statePath) then
    local backup = self.statePath .. ".bak"
    if filesystem.exists(backup) then filesystem.remove(backup) end
    local okBackup, backupReason = filesystem.copy(self.statePath, backup)
    if not okBackup then
      filesystem.remove(temporary)
      return nil, "backup failed: " .. tostring(backupReason)
    end
    local okRemove, removeReason = filesystem.remove(self.statePath)
    if not okRemove then
      filesystem.remove(temporary)
      return nil, "old state removal failed: " .. tostring(removeReason)
    end
  end

  local okRename, renameReason = filesystem.rename(temporary, self.statePath)
  if not okRename then
    local okCopy, copyReason = filesystem.copy(temporary, self.statePath)
    filesystem.remove(temporary)
    if not okCopy then
      return nil, "state promotion failed: " .. tostring(renameReason or copyReason)
    end
  end
  return true
end

function Store:appendEvent(event)
  local okParent, parentReason = ensureParent(self.logPath)
  if not okParent then return nil, parentReason end
  local isNew = not filesystem.exists(self.logPath)
  local handle, reason = io.open(self.logPath, "ab")
  if not handle then return nil, reason end
  if isNew then
    handle:write("sequence\tworldTime\ttype\tactor\tdetail\n")
  end
  local line = table.concat({
    util.sanitizeLog(event.sequence),
    util.sanitizeLog(event.worldTime),
    util.sanitizeLog(event.type),
    util.sanitizeLog(event.actor),
    util.sanitizeLog(event.detail)
  }, "\t") .. "\n"
  local ok, writeReason = handle:write(line)
  handle:close()
  if not ok then return nil, writeReason end
  return true
end

return Store

