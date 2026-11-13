-- RACS stable bootstrap for OpenComputers/OpenOS.
-- Suitable for a public Pastebin. This bootstrap intentionally accepts no
-- credentials; its source repository must be anonymously readable.

local component = require("component")
local computer = require("computer")
local filesystem = require("filesystem")
local internet = require("internet")
local serialization = require("serialization")
local term = require("term")

if not component.isAvailable("internet") then
  io.stderr:write("An Internet Card is required.\n")
  return 1
end

local function trim(value)
  return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function ask(label, default, secret)
  io.write(label)
  if default and default ~= "" then io.write(" [" .. default .. "]") end
  io.write(": ")
  local value
  if secret then
    value = term.read({}, true, nil, "*")
  else
    value = term.read()
  end
  value = trim(value)
  if value == "" then return default or "" end
  return value
end

local function encode(value, keepSlash)
  return (tostring(value):gsub("([^%w%-%._~" .. (keepSlash and "/" or "") .. "])",
    function(char) return string.format("%%%02X", string.byte(char)) end))
end

local function ensureParent(path)
  local parent = filesystem.path(path)
  if filesystem.exists(parent) then return true end
  return filesystem.makeDirectory(parent)
end

local baseUrl = ask("Gitea base URL", "https://gitea.example.com")
baseUrl = baseUrl:gsub("/+$", "")
local owner = ask("Repository owner or organization")
local repository = ask("Repository name")
local reference = ask("Branch, tag, or commit", "racs-v0.4.1")
local basePath = ask("RACS folder inside repository", "RACS-v0.4.1")
basePath = basePath:gsub("^/+", ""):gsub("/+$", "")

if not baseUrl:match("^https://") then
  io.stderr:write("Refusing non-HTTPS Gitea URL.\n")
  return 1
end
if owner == "" or repository == "" or reference == "" then
  io.stderr:write("Owner, repository, and reference are required.\n")
  return 1
end

local headers = {Accept = "application/octet-stream"}

local function rawUrl(path)
  return baseUrl .. "/api/v1/repos/" .. encode(owner, false) .. "/"
    .. encode(repository, false) .. "/raw/" .. encode(path, true)
    .. "?ref=" .. encode(reference, false)
end

local function download(path, maximumBytes)
  local url = rawUrl(path)
  local okRequest, iterator = pcall(internet.request, url, nil, headers)
  if not okRequest then return nil, "request failed: " .. tostring(iterator) end

  local responseCode
  local meta = getmetatable(iterator)
  if meta and meta.__index and type(meta.__index.response) == "function" then
    local okResponse, code = pcall(meta.__index.response)
    if okResponse then responseCode = tonumber(code) end
  end

  local chunks, size = {}, 0
  local okRead, readReason = pcall(function()
    for chunk in iterator do
      size = size + #chunk
      if size > maximumBytes then error("download exceeds size limit") end
      chunks[#chunks + 1] = chunk
    end
  end)
  if not okRead then return nil, tostring(readReason) end
  if responseCode and responseCode ~= 200 then
    return nil, "HTTP " .. tostring(responseCode)
  end
  return table.concat(chunks)
end

local manifestPath = (basePath ~= "" and (basePath .. "/") or "") .. "racs-manifest.cfg"
print("Downloading release manifest from " .. baseUrl .. "...")
local manifestText, manifestReason = download(manifestPath, 32768)
if not manifestText then
  io.stderr:write("Manifest download failed: " .. tostring(manifestReason) .. "\n")
    io.stderr:write("Check anonymous reachability, repository name, and release reference.\n")
  return 1
end

local okManifest, manifest = pcall(serialization.unserialize, manifestText)
if not okManifest or type(manifest) ~= "table" or manifest.format ~= 1
    or manifest.product ~= "RACS" or type(manifest.files) ~= "table" then
  io.stderr:write("The downloaded manifest is invalid.\n")
  return 1
end
if #manifest.files < 1 or #manifest.files > 32 then
  io.stderr:write("The manifest contains an unsafe number of files.\n")
  return 1
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
      or type(entry.target) ~= "string" or not allowedTargets[entry.target] then
    io.stderr:write("Manifest contains a disallowed target. Nothing installed.\n")
    filesystem.remove(staging)
    return 1
  end
  if entry.source:find("..", 1, true) or entry.source:sub(1, 1) == "/" then
    io.stderr:write("Manifest contains an unsafe source path. Nothing installed.\n")
    filesystem.remove(staging)
    return 1
  end
  local source = (basePath ~= "" and (basePath .. "/") or "") .. entry.source
  io.write(string.format("Downloading %d/%d... ", index, #manifest.files))
  local body, reason = download(source, tonumber(entry.maximumBytes) or 262144)
  if not body then
    print("failed")
    io.stderr:write(tostring(reason) .. "\nNothing installed; staged files were removed.\n")
    filesystem.remove(staging)
    return 1
  end
  local stagedPath = filesystem.concat(staging, tostring(index) .. ".new")
  local handle, openReason = io.open(stagedPath, "wb")
  if not handle then
    io.stderr:write("Cannot stage file: " .. tostring(openReason) .. "\n")
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
print("RACS " .. tostring(manifest.version or "unknown") .. " installed from " .. reference .. ".")
print("Existing configuration files were preserved.")
print("Next: edit /etc/racs.cfg and run racs.")

