local Promise = require('opencode.promise')
local normalize = require('opencode.protocols.acp.normalize')

local M = {}

---@param value any
---@return Promise<any>
local function resolved(value)
  return Promise.new():resolve(value)
end

---@param name string
---@return Promise<any>
local function unsupported(name)
  return Promise.new():reject('ACP does not support ' .. name)
end

---@param connection OpencodeAcpConnection
---@return OpencodeAcpTransport|nil
local function transport(connection)
  return connection.transport
end

---@param connection OpencodeAcpConnection
---@param session table
local function remember_session(connection, session)
  connection._acp_sessions[session.id] = vim.deepcopy(session)
end

---Merge ACP config options, keyed by id so repeated session/new responses do not duplicate.
---@param connection OpencodeAcpConnection
---@param options? table
local function remember_config_options(connection, options)
  if type(options) ~= 'table' then
    return
  end
  local by_id = {}
  for _, option in ipairs(connection._acp_config_options or {}) do
    if type(option) == 'table' and type(option.id) == 'string' then
      by_id[option.id] = option
    end
  end
  for _, option in ipairs(options) do
    if type(option) == 'table' and type(option.id) == 'string' then
      by_id[option.id] = vim.deepcopy(option)
    end
  end
  local merged = {}
  for _, option in pairs(by_id) do
    merged[#merged + 1] = option
  end
  table.sort(merged, function(a, b)
    return a.id < b.id
  end)
  connection._acp_config_options = merged
end

---@param connection OpencodeAcpConnection
---@param modes? table
local function remember_modes(connection, modes)
  if type(modes) ~= 'table' or type(modes.availableModes) ~= 'table' then
    return
  end
  local options = {}
  for _, mode in ipairs(modes.availableModes) do
    if type(mode) == 'table' and type(mode.id) == 'string' then
      options[#options + 1] = { id = mode.id, name = mode.name, category = 'mode' }
    end
  end
  remember_config_options(connection, options)
end

---@param connection OpencodeAcpConnection
---@param location? OpencodeLocation
---@param input? table
---@return Promise<table>
function M.create_session(connection, location, input)
  local agent = transport(connection)
  if not agent then
    return unsupported('create_session on a closed connection')
  end
  local cwd = type(location) == 'table' and location.directory or vim.fn.getcwd()
  local params = { cwd = cwd, mcpServers = {} }
  return agent:request('session/new', params):and_then(function(result)
    if type(result) ~= 'table' or type(result.sessionId) ~= 'string' then
      error('ACP session/new returned an invalid response', 0)
    end
    local session = normalize.mapped_session({
      sessionId = result.sessionId,
      cwd = cwd,
      title = type(input) == 'table' and input.title or nil,
    })
    remember_session(connection, session)
    remember_modes(connection, result.modes)
    remember_config_options(connection, result.configOptions)
    return session
  end)
end

---@param connection OpencodeAcpConnection
---@param session_id string
---@param location? OpencodeLocation
---@return Promise<table>
function M.get_session(connection, session_id, location)
  local cached = connection._acp_sessions[session_id]
  if cached then
    return resolved(vim.deepcopy(cached))
  end
  return M.list_sessions_project(connection, location or { directory = vim.fn.getcwd() }):and_then(function(sessions)
    for _, session in ipairs(sessions) do
      if session.id == session_id then
        remember_session(connection, session)
        return session
      end
    end
    local fallback = normalize.mapped_session({
      sessionId = session_id,
      cwd = type(location) == 'table' and location.directory or vim.fn.getcwd(),
    })
    remember_session(connection, fallback)
    return fallback
  end)
end

---@param connection OpencodeAcpConnection
---@return boolean
local function supports_session_list(connection)
  local capabilities = connection.capabilities
  local session_capabilities = type(capabilities) == 'table' and capabilities.sessionCapabilities or nil
  return type(session_capabilities) == 'table' and session_capabilities.list == true
end

---@param connection OpencodeAcpConnection
---@param cwd? string
---@return Promise<table[]>
local function list_sessions(connection, cwd)
  if not supports_session_list(connection) then
    return resolved({})
  end
  local agent = transport(connection)
  if not agent then
    return unsupported('list_sessions on a closed connection')
  end
  local params = {}
  if cwd then
    params.cwd = cwd
  end
  return agent:request('session/list', params):and_then(function(result)
    local list = type(result) == 'table' and result.sessions or nil
    if type(list) ~= 'table' then
      return {}
    end
    local mapped = {}
    for _, info in ipairs(list) do
      local session = normalize.mapped_session(info)
      remember_session(connection, session)
      mapped[#mapped + 1] = session
    end
    return mapped
  end)
end

---@param connection OpencodeAcpConnection
---@param location OpencodeLocation
---@return Promise<table[]>
function M.list_sessions_project(connection, location)
  return list_sessions(connection, type(location) == 'table' and location.directory or nil)
end

---@param connection OpencodeAcpConnection
---@return Promise<table[]>
function M.list_sessions_global(connection)
  return list_sessions(connection, nil)
end

---Send session/prompt and hand back the long-lived turn request. The response
---resolves at the end of the turn with a stopReason.
---@param connection OpencodeAcpConnection
---@param session_id string
---@param input table
---@return Promise<{turn: Promise<table>}>
function M.submit(connection, session_id, input)
  local agent = transport(connection)
  if not agent then
    return unsupported('submit on a closed connection')
  end
  local prompt = normalize.prompt_blocks(input)
  local turn = agent:request('session/prompt', { sessionId = session_id, prompt = prompt })
  return resolved({ turn = turn })
end

---@param connection OpencodeAcpConnection
---@param session_id string
---@return Promise<boolean>
function M.interrupt(connection, session_id)
  local agent = transport(connection)
  if not agent then
    return unsupported('interrupt on a closed connection')
  end
  agent:notify('session/cancel', { sessionId = session_id })
  return resolved(true)
end

---@param connection OpencodeAcpConnection
---@param session_id string
---@param request_id string
---@param answer {reply: 'once'|'always'|'reject'}
---@return Promise<boolean>
function M.reply_permission(connection, session_id, request_id, answer)
  local pending = connection._pending_permissions[request_id]
  if not pending then
    return unsupported('reply to an unknown permission request')
  end
  local option_id = pending.options[answer.reply]
  local outcome = option_id and { outcome = 'selected', optionId = option_id } or { outcome = 'cancelled' }
  connection:resolve_permission(request_id, { outcome = outcome })
  return resolved(true)
end

---@param connection OpencodeAcpConnection
---@param session_id string
---@return Promise<boolean>
function M.delete_session(connection, session_id)
  local capabilities = connection.capabilities
  local session_capabilities = type(capabilities) == 'table' and capabilities.sessionCapabilities or nil
  if not (type(session_capabilities) == 'table' and session_capabilities.delete == true) then
    return unsupported('delete_session')
  end
  local agent = transport(connection)
  if not agent then
    return unsupported('delete_session on a closed connection')
  end
  connection._acp_sessions[session_id] = nil
  return agent:request('session/delete', { sessionId = session_id }):and_then(function()
    return true
  end)
end

---@param connection OpencodeAcpConnection
---@return table[]
local function mode_options(connection)
  local options = connection._acp_config_options or {}
  local modes = {}
  for _, option in ipairs(options) do
    if type(option) == 'table' and option.category == 'mode' and type(option.id) == 'string' then
      modes[#modes + 1] = option
    end
  end
  return modes
end

---ACP has no agent catalog; expose config-option modes when the agent advertises
---them and otherwise a single neutral mode so the mode pipeline degrades quietly.
---@param connection OpencodeAcpConnection
---@return table[]
local function agents(connection)
  local list = {}
  for _, option in ipairs(mode_options(connection)) do
    list[#list + 1] = { id = option.id, name = option.name or option.id, mode = 'primary' }
  end
  if #list == 0 then
    list[1] = { id = 'agent', name = 'agent', mode = 'primary' }
  end
  return list
end

---@param connection OpencodeAcpConnection
---@return Promise<table[]>
function M.list_agents(connection)
  return resolved(agents(connection))
end

---@param connection OpencodeAcpConnection
---@return Promise<string[]>
function M.list_primary_agents(connection)
  local ids = {}
  for _, agent in ipairs(agents(connection)) do
    ids[#ids + 1] = agent.id
  end
  table.sort(ids)
  return resolved(ids)
end

---@return Promise<string[]>
function M.list_subagents()
  return resolved({})
end

---@param connection OpencodeAcpConnection
---@param location? OpencodeLocation
---@param session_id string
---@param config_id string
---@param value string
---@return Promise<boolean>
local function set_config_option(connection, session_id, config_id, value)
  local agent = transport(connection)
  if not agent then
    return unsupported('session/set_config_option on a closed connection')
  end
  return agent:request('session/set_config_option', {
    sessionId = session_id,
    configId = config_id,
    value = value,
  }):and_then(function()
    return true
  end)
end

---@param connection OpencodeAcpConnection
---@param session_id string
---@param agent string
---@return Promise<boolean>
function M.set_session_agent(connection, session_id, agent)
  for _, option in ipairs(mode_options(connection)) do
    return set_config_option(connection, session_id, option.id, agent)
  end
  return unsupported('set_session_agent')
end

---@param connection OpencodeAcpConnection
---@param session_id string
---@param model table
---@return Promise<boolean>
function M.set_session_model(connection, session_id, model)
  for _, option in ipairs(connection._acp_config_options or {}) do
    if type(option) == 'table' and option.category == 'model' and type(option.id) == 'string' then
      local value = model.providerID and model.id and (model.providerID .. '/' .. model.id)
        or (model.modelID or model.id)
      return set_config_option(connection, session_id, option.id, value)
    end
  end
  return unsupported('set_session_model')
end

---@param connection OpencodeAcpConnection
---@return Promise<table[]>
function M.list_models()
  return resolved({})
end

---@return Promise<table>
function M.get_model_catalog()
  return resolved({ providers = {}, default = {} })
end

---@return Promise<nil>
function M.get_default_model()
  return resolved(nil)
end

---@return Promise<table>
function M.get_config()
  return resolved({ model = '', agent = {} })
end

---@return Promise<nil>
function M.get_current_project()
  return resolved(nil)
end

---@param connection OpencodeAcpConnection
---@return Promise<table<string, table>>
function M.get_user_commands(connection)
  local commands = {}
  for _, command in ipairs(connection._acp_commands or {}) do
    if type(command) == 'table' and type(command.name) == 'string' then
      commands[command.name] = {
        description = type(command.description) == 'string' and command.description or '',
        agent = '',
        model = '',
        template = type(command.input) == 'table' and (command.input.hint or '') or '',
      }
    end
  end
  return resolved(commands)
end

---@param connection OpencodeAcpConnection
---@return Promise<table[]>
function M.list_commands(connection)
  local commands = {}
  for _, command in ipairs(connection._acp_commands or {}) do
    if type(command) == 'table' and type(command.name) == 'string' then
      commands[#commands + 1] = { name = command.name, description = command.description }
    end
  end
  return resolved(commands)
end

---@return Promise<table[]>
function M.list_active_sessions()
  return resolved({})
end

---@return Promise<table[]>
function M.list_inbox()
  return resolved({})
end

---@return Promise<table[]>
function M.list_messages()
  return resolved({})
end

---@return Promise<table[]>
function M.list_permissions()
  return resolved({})
end

---@return Promise<table[]>
function M.list_questions()
  return resolved({})
end

---@return Promise<table[]>
function M.list_skills()
  return resolved({})
end

---@return Promise<table[]>
function M.list_mcp_servers()
  return resolved({})
end

---@return Promise<string[]>
function M.find_files()
  return resolved({})
end

---@return Promise<table[]>
function M.get_file_status()
  return resolved({})
end

---@return Promise<table[]>
function M.diff_session()
  return resolved({})
end

M.rename_session = function()
  return unsupported('rename_session')
end
M.summarize_session = function()
  return unsupported('summarize_session')
end
M.fork_session = function()
  return unsupported('fork_session')
end
M.revert_message = function()
  return unsupported('revert_message')
end
M.unrevert_messages = function()
  return unsupported('unrevert_messages')
end
M.share_session = function()
  return unsupported('share_session')
end
M.unshare_session = function()
  return unsupported('unshare_session')
end
M.init_session = function()
  return unsupported('init_session')
end
M.send_command = function()
  return unsupported('send_command')
end
M.reply_question = function()
  return unsupported('reply_question')
end
M.cancel_question = function()
  return unsupported('cancel_question')
end
M.connect_mcp = function()
  return unsupported('connect_mcp')
end
M.disconnect_mcp = function()
  return unsupported('disconnect_mcp')
end

return M
