-- Stable, credential-free RACS installer for OpenComputers/OpenOS.
-- This small file may be hosted on Pastebin. Release files come from GitHub.

local component = require("component")
local computer = require("computer")
local filesystem = require("filesystem")
local internet = require("internet")
local serialization = require("serialization")

local OWNER = "matesaman9910"
local REPOSITORY = "RACS"
local CHANNEL_REF = "main"
local MANIFEST_PATH = "racs-manifest.cfg"

if not component.isAvailable("internet") then
  io.stderr:write("An Internet Card is required.\n")
  return 1
end

local function encodePath(value)
  return (tostring(value):gsub("([^%w%-%._~/])", function(character)
    return string.format("%%%02X", string.byte(character))
  end))
end

local function rawUrl(reference, path)
  return "https://raw.githubusercontent.com/" .. OWNER .. "/" .. REPOSITORY
    .. "/" .. encodePath(reference) .. "/" .. encodePath(path)
end

local function download(url, maximumBytes)
  local okRequest, iterator = pcall(internet.request, url)
  if not okRequest then return nil, "request could not start" end
  local chunks, size = {}, 0
  local okRead = pcall(function()
    for chunk in iterator do
      size = size + #chunk
      if size > maximumBytes then error("download exceeds size limit") end
      chunks[#chunks + 1] = chunk
    end
  end)
  if not okRead then return nil, "download failed" end
  return table.concat(chunks)
end

local function ensureParent(path)
  local parent = filesystem.path(path)
  if filesystem.exists(parent) then return true end
  return filesystem.makeDirectory(parent)
end

local allowedTargets = {
  ["/usr/bin/racs.lua"] = true,
  ["/usr/bin/racs-dashboard.lua"] = true,
  ["/usr/lib/racs/util.lua"] = true,
  ["/usr/lib/racs/store.lua"] = true,
  ["/usr/lib/racs/inventory.lua"] = true,
  ["/usr/lib/racs/protocol.lua"] = true,
  ["/usr/lib/racs/app.lua"] = true,
  ["/etc/racs.cfg"] = true,
  ["/etc/racs-dashboard.cfg"] = true
}

print("RACS GitHub installer")
print("Repository: " .. OWNER .. "/" .. REPOSITORY)
print("Downloading release manifest...")

local manifestText, manifestReason = download(rawUrl(CHANNEL_REF, MANIFEST_PATH), 32768)
if not manifestText then
  io.stderr:write("Manifest download failed: " .. tostring(manifestReason) .. "\n")
  return 1
end

local okManifest, manifest = pcall(serialization.unserialize, manifestText)
if not okManifest or type(manifest) ~= "table" or manifest.format ~= 1
    or manifest.product ~= "RACS" or type(manifest.ref) ~= "string"
    or type(manifest.files) ~= "table" then
  io.stderr:write("The downloaded manifest is invalid.\n")
  return 1
end
if manifest.ref == "" or manifest.ref:find("..", 1, true)
    or not manifest.ref:match("^[%w%._/%-]+$") then
  io.stderr:write("The manifest release reference is unsafe.\n")
  return 1
end
if #manifest.files < 1 or #manifest.files > 32 then
  io.stderr:write("The manifest contains an unsafe number of files.\n")
  return 1
end

local staging = "/tmp/racs-install-" .. tostring(math.floor(computer.uptime() * 1000))
local okDirectory, directoryReason = filesystem.makeDirectory(staging)
if not okDirectory then
  io.stderr:write("Cannot create staging directory: " .. tostring(directoryReason) .. "\n")
  return 1
end

local staged = {}
for index = 1, #manifest.files do
  local entry = manifest.files[index]
  if type(entry) ~= "table" or type(entry.source) ~= "string"
      or type(entry.target) ~= "string" or not allowedTargets[entry.target]
      or entry.source:find("..", 1, true) or entry.source:sub(1, 1) == "/" then
    io.stderr:write("Manifest contains an unsafe file entry. Nothing installed.\n")
    filesystem.remove(staging)
    return 1
  end

  io.write(string.format("Downloading %d/%d... ", index, #manifest.files))
  local body, reason = download(rawUrl(manifest.ref, entry.source),
    tonumber(entry.maximumBytes) or 262144)
  if not body then
    print("failed")
    io.stderr:write(tostring(reason) .. "\nNothing installed.\n")
    filesystem.remove(staging)
    return 1
  end

  local stagedPath = filesystem.concat(staging, tostring(index) .. ".new")
  local handle, openReason = io.open(stagedPath, "wb")
  if not handle then
    io.stderr:write("Cannot stage a file: " .. tostring(openReason) .. "\n")
    filesystem.remove(staging)
    return 1
  end
  handle:write(body)
  handle:close()
  staged[#staged + 1] = {path = stagedPath, entry = entry}
  print("ok")
end

for index = 1, #staged do
  local entry = staged[index].entry
  local target = entry.target
  if entry.preserve and filesystem.exists(target) then
    print("Preserved existing " .. target)
  else
    local okParent, parentReason = ensureParent(target)
    if not okParent then error("cannot create target directory: " .. tostring(parentReason)) end
    local backup = target .. ".racs-backup"
    if filesystem.exists(backup) then filesystem.remove(backup) end
    if filesystem.exists(target) then
      local okBackup, backupReason = filesystem.copy(target, backup)
      if not okBackup then error("cannot back up " .. target .. ": " .. tostring(backupReason)) end
      filesystem.remove(target)
    end
    local okCopy, copyReason = filesystem.copy(staged[index].path, target)
    if not okCopy then
      if filesystem.exists(backup) then filesystem.copy(backup, target) end
      error("cannot install " .. target .. ": " .. tostring(copyReason))
    end
    print("Installed " .. target)
  end
end

filesystem.makeDirectory("/var/lib/racs")
filesystem.makeDirectory("/var/log/racs")
filesystem.remove(staging)

print("")
print("RACS " .. tostring(manifest.version or "unknown") .. " installed.")
print("Release: " .. manifest.ref)
print("Existing configuration files were preserved.")
print("Next: edit /etc/racs.cfg and run racs.")

