local Promise = require('opencode.promise')
local config = require('opencode.config')
local log = require('opencode.log')
local state = require('opencode.state')
local transport_mod = require('opencode.protocols.acp.transport')
local connection_mod = require('opencode.protocols.acp.connection')

local M = {}

local pending

---@return string[]
local function resolve_command()
  local acp = config.acp or {}
  local command = acp.command
  if type(command) ~= 'string' or command == '' then
    error('ACP harness requires config.acp.command (the agent executable)', 0)
  end
  local resolved = vim.fn.exepath(command)
  if resolved == '' then
    resolved = command
  end
  local argv = { resolved }
  for _, arg in ipairs(acp.args or {}) do
    argv[#argv + 1] = tostring(arg)
  end
  return argv
end

---@param acp OpencodeAcpConfig
---@return table<string, string>|nil
local function build_env(acp)
  local env = {}
  for key, value in pairs(acp.env or {}) do
    if type(key) == 'string' and type(value) == 'string' then
      env[key] = value
    end
  end
  return next(env) and env or nil
end

---@param connection OpencodeAcpConnection
---@return OpencodeAcpTransport
local function spawn(connection)
  local acp = config.acp or {}
  local transport = transport_mod.spawn({
    command = resolve_command(),
    cwd = vim.fn.getcwd(),
    env = build_env(acp),
    on_request = function(message)
      connection:_on_request(message)
    end,
    on_notification = function(message)
      connection:_on_notification(message)
    end,
    on_exit = function(result)
      connection:_on_process_exit(result)
    end,
  })
  connection:attach_transport(transport)
  connection:set_process_release(function()
    transport:close('ACP connection released')
  end)
  return transport
end

---Run the ACP initialize handshake and (when configured) protocol-driven auth.
---@param connection OpencodeAcpConnection
---@param transport OpencodeAcpTransport
---@return Promise<OpencodeAcpHandshake>
local function initialize(connection, transport)
  local acp = config.acp or {}
  local requested = acp.protocol_version or 1
  return transport
    :request('initialize', {
      protocolVersion = requested,
      clientCapabilities = {},
      clientInfo = { name = acp.client_name or 'opencode.nvim', version = '1.0.0' },
    })
    :and_then(function(result)
      if type(result) ~= 'table' then
        error('ACP initialize returned an invalid response', 0)
      end
      local negotiated = result.protocolVersion
      if type(negotiated) ~= 'number' then
        negotiated = requested
      end
      if negotiated ~= requested then
        log.warn('ACP negotiated protocol version %s (requested %s)', tostring(negotiated), tostring(requested))
      end

      local auth_methods = result.authMethods
      if type(auth_methods) == 'table' and #auth_methods > 0 and type(acp.auth_method) == 'string' then
        return transport:request('authenticate', { methodId = acp.auth_method }):and_then(function()
          return result
        end)
      end
      if type(auth_methods) == 'table' and #auth_methods > 0 then
        log.debug('ACP agent advertises auth methods; log in via the agent CLI if prompts are refused')
      end
      return result
    end)
    :and_then(function(result)
      local info = type(result.agentInfo) == 'table' and result.agentInfo or {}
      return {
        version = type(info.version) == 'string' and info.version or 'acp',
        protocol_version = type(result.protocolVersion) == 'number' and result.protocolVersion or requested,
        agent_info = info,
        capabilities = result.agentCapabilities,
      }
    end)
end

---Acquire a ready ACP connection, spawning and initializing the agent on demand.
---@param opts? {force_health_check?: boolean}
---@return Promise<OpencodeAcpConnection>
function M.ensure_agent(opts)
  local existing = state.opencode_server
  if existing and existing.protocol == 'acp' and existing:is_ready() then
    return Promise.new():resolve(existing --[[@as OpencodeAcpConnection]])
  end
  if pending then
    return pending
  end

  local result = Promise.new()
  pending = result

  Promise.spawn(function()
    local connection = connection_mod.new()
    local ok, handshake = pcall(function()
      local transport = spawn(connection)
      return initialize(connection, transport):await()
    end)
    if not ok then
      connection:close()
      error(handshake, 0)
    end
    if connection.shutdown_promise:is_resolved() then
      error('ACP connection closed during startup', 0)
    end
    connection:mark_ready(handshake --[[@as OpencodeAcpHandshake]])
    state.jobs.set_server(connection --[[@as OpencodeServer]])
    return connection
  end)
    :and_then(function(connection)
      pending = nil
      result:resolve(connection)
    end)
    :catch(function(err)
      pending = nil
      result:reject(err)
    end)

  return result
end

return M
