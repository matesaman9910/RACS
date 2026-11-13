local component = require("component")
local serialization = require("serialization")

local Protocol = {}
Protocol.__index = Protocol

local function safeUnserialize(payload)
  local ok, decoded = pcall(serialization.unserialize, payload)
  if not ok or type(decoded) ~= "table" then return nil end
  return decoded
end

function Protocol.new(config, callbacks)
  local instance = setmetatable({
    enabled = config.enabled == true,
    config = config,
    callbacks = callbacks or {},
    modem = nil
  }, Protocol)
  if not instance.enabled then return instance end
  if not component.isAvailable("modem") then
    return nil, "network enabled but no modem component is available"
  end
  instance.modem = component.getPrimary("modem")
  local okOpen, opened = pcall(instance.modem.open, config.port)
  if not okOpen then return nil, "cannot open modem port: " .. tostring(opened) end
  if instance.modem.isWireless and instance.modem.isWireless() and config.strength then
    pcall(instance.modem.setStrength, config.strength)
  end
  return instance
end

function Protocol:send(address, packet)
  if not self.enabled or not self.modem then return false end
  local okSerialize, payload = pcall(serialization.serialize, packet)
  if not okSerialize then return false end
  local maximum = self.modem.maxPacketSize and self.modem.maxPacketSize() or 8192
  if #payload > maximum then return false end
  local okSend, sent = pcall(self.modem.send, address, self.config.port, payload)
  return okSend and sent == true
end

function Protocol:response(request, ok, data, errorMessage)
  return {
    protocol = "RACS",
    version = 1,
    type = "response",
    id = tostring(request.id or ""),
    ok = ok == true,
    data = data,
    error = errorMessage
  }
end

function Protocol:handleSignal(signal)
  if not self.enabled or signal[1] ~= "modem_message" then return false end
  local sender = signal[3]
  local port = signal[4]
  local payload = signal[6]
  if tonumber(port) ~= tonumber(self.config.port) or type(payload) ~= "string" then return false end
  if #payload > (tonumber(self.config.maxRequestBytes) or 4096) then return true end

  local request = safeUnserialize(payload)
  if not request or request.protocol ~= "RACS" or request.version ~= 1 or request.type ~= "request" then
    return true
  end

  local action = tostring(request.action or "")
  if action == "DISCOVER" and self.config.allowDiscovery then
    self:send(sender, self:response(request, true, self.callbacks.discover()))
    return true
  end

  if self.config.readToken == "CHANGE_ME_READ_TOKEN" or request.token ~= self.config.readToken then
    self:send(sender, self:response(request, false, nil, "unauthorized"))
    return true
  end

  local callback = self.callbacks[string.lower(action)]
  if type(callback) ~= "function" or action == "DISCOVER" then
    self:send(sender, self:response(request, false, nil, "unsupported action"))
    return true
  end

  local ok, data = pcall(callback)
  if ok then
    self:send(sender, self:response(request, true, data))
  else
    self:send(sender, self:response(request, false, nil, "request failed"))
  end
  return true
end

function Protocol:close()
  if self.enabled and self.modem then pcall(self.modem.close, self.config.port) end
end

return Protocol

