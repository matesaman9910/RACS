local util = {}

function util.trim(value)
  return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

function util.normalizeUser(value)
  return string.lower(util.trim(value))
end

function util.worldTime()
  return math.floor(tonumber(os.time()) or 0)
end

function util.worldTimeLabel(value)
  local total = math.floor(tonumber(value) or 0)
  local days = math.floor(total / 86400)
  local remainder = total % 86400
  local hours = math.floor(remainder / 3600)
  local minutes = math.floor((remainder % 3600) / 60)
  local seconds = remainder % 60
  return string.format("day %d %02d:%02d:%02d", days, hours, minutes, seconds)
end

function util.sanitizeLog(value)
  return tostring(value or "")
    :gsub("\r", " ")
    :gsub("\n", " ")
    :gsub("\t", " ")
end

function util.copyTable(source)
  local result = {}
  if type(source) ~= "table" then return result end
  for key, value in pairs(source) do
    if type(value) == "table" then
      result[key] = util.copyTable(value)
    else
      result[key] = value
    end
  end
  return result
end

function util.sortedKeys(source)
  local keys = {}
  for key in pairs(source or {}) do keys[#keys + 1] = key end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  return keys
end

function util.count(source)
  local count = 0
  for _ in pairs(source or {}) do count = count + 1 end
  return count
end

function util.clamp(value, minimum, maximum)
  value = tonumber(value) or minimum
  if value < minimum then return minimum end
  if value > maximum then return maximum end
  return value
end

return util

