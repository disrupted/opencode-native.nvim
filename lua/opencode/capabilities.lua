local M = {}

---Features that only the opencode HTTP API provides. ACP agents have no
---equivalent contract, so the UI must gate them off rather than fail obscurely.
---@alias OpencodeCapability
---| 'children'
---| 'files'
---| 'inbox'
---| 'questions'
---| 'diff'
---| 'fork'
---| 'revert'
---| 'share'
---| 'compact'
---| 'mcp'
---| 'skills'
---| 'models'

---@type table<string, boolean>
local acp_unsupported = {
  children = true,
  files = true,
  inbox = true,
  questions = true,
  diff = true,
  fork = true,
  revert = true,
  share = true,
  compact = true,
  mcp = true,
  skills = true,
  models = true,
}

---Whether the active connection can serve a feature.
---@param connection table|nil
---@param capability OpencodeCapability
---@return boolean
function M.supports(connection, capability)
  if not connection then
    return false
  end
  if connection.protocol ~= 'acp' then
    return true
  end
  return not acp_unsupported[capability]
end

---Gate an action, notifying the user when the active harness cannot serve it.
---@param connection table|nil
---@param capability OpencodeCapability
---@param action string Human-readable action name
---@return boolean allowed
function M.require(connection, capability, action)
  if M.supports(connection, capability) then
    return true
  end
  vim.notify(action .. ' is not supported by the active ACP agent', vim.log.levels.WARN)
  return false
end

return M
