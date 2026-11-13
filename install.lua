local filesystem = require("filesystem")
local shell = require("shell")

local sourceRoot = shell.getWorkingDirectory()
local payload = filesystem.concat(sourceRoot, "payload")

local files = {
  {"usr/bin/racs.lua", "/usr/bin/racs.lua", true},
  {"usr/bin/racs-dashboard.lua", "/usr/bin/racs-dashboard.lua", true},
  {"usr/lib/racs/util.lua", "/usr/lib/racs/util.lua", true},
  {"usr/lib/racs/store.lua", "/usr/lib/racs/store.lua", true},
  {"usr/lib/racs/inventory.lua", "/usr/lib/racs/inventory.lua", true},
  {"usr/lib/racs/protocol.lua", "/usr/lib/racs/protocol.lua", true},
  {"usr/lib/racs/app.lua", "/usr/lib/racs/app.lua", true},
  {"etc/racs.cfg.example", "/etc/racs.cfg", false},
  {"etc/racs-dashboard.cfg.example", "/etc/racs-dashboard.cfg", false}
}

local function ensureParent(path)
  local parent = filesystem.path(path)
  if not filesystem.exists(parent) then
    local ok, reason = filesystem.makeDirectory(parent)
    if not ok then error("cannot create " .. parent .. ": " .. tostring(reason)) end
  end
end

local function copyFile(relative, destination, overwrite)
  local source = filesystem.concat(payload, relative)
  if not filesystem.exists(source) then error("missing payload file: " .. source) end
  ensureParent(destination)
  if filesystem.exists(destination) then
    if not overwrite then
      print("preserved " .. destination)
      return
    end
    local ok, reason = filesystem.remove(destination)
    if not ok then error("cannot replace " .. destination .. ": " .. tostring(reason)) end
  end
  local ok, reason = filesystem.copy(source, destination)
  if not ok then error("copy failed for " .. destination .. ": " .. tostring(reason)) end
  print("installed " .. destination)
end

if not filesystem.exists(payload) then
  io.stderr:write("Run install.lua from the unpacked RACS project root.\n")
  return 1
end

for i = 1, #files do
  copyFile(files[i][1], files[i][2], files[i][3])
end

filesystem.makeDirectory("/var/lib/racs")
filesystem.makeDirectory("/var/log/racs")

print("")
print("RACS v0.4 installed.")
print("Next: edit /etc/racs.cfg, then run: racs")
print("Keep both confirmation flags false until in-game diagnostics are complete.")

