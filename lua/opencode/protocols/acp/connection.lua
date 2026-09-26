local Promise = require('opencode.promise')
local log = require('opencode.log')

local M = {}

local AcpConnection = {}
AcpConnection.__index = AcpConnection

---A harness connection that mirrors the OpencodeServer surface consumed by the
---shared observation lifecycle and UI, but speaks ACP over stdio instead of HTTP.
---@return OpencodeAcpConnection
function M.new()
  local connection = setmetatable({
    job = nil,
    url = nil,
    port = nil,
    handle = nil,
    protocol = 'acp',
    version = nil,
    acp_protocol_version = 1,
    capabilities = {},
    agent_info = nil,
    server_identity = nil,
    credential = nil,
    operations = require('opencode.protocols.acp.operations'),
    observations = {},
    transport = nil,
    shutdown_promise = Promise.new(),
    _ready = false,
    _shutdown_requested = false,
    _release_process = nil,
    _stream = nil,
    _requests = {},
    _observe = nil,
    _close_observations = nil,
    _route = nil,
    _handle_request = nil,
    _pending_permissions = {},
    _acp_sessions = {},
    _acp_commands = {},
  }, AcpConnection)
  ---@cast connection OpencodeAcpConnection
  return connection
end

---@return boolean
function AcpConnection:is_ready()
  return self._ready
end

---@param release? fun()
function AcpConnection:set_process_release(release)
  if self._ready or self.shutdown_promise:is_resolved() then
    error('cannot change release behavior of a ready connection')
  end
  self._release_process = release
end

---@return boolean
function AcpConnection:can_release_process()
  return self._release_process ~= nil
end

---@return boolean
function AcpConnection:release_process()
  local release = self._release_process
  self._release_process = nil
  if not release then
    return false
  end
  release()
  return true
end

---@param stream? {shutdown: fun(self: table)}
function AcpConnection:set_stream(stream)
  if stream and self._stream then
    pcall(stream.shutdown, stream)
    error('Connection already owns a stream')
  end
  if stream and not self:is_ready() then
    pcall(stream.shutdown, stream)
    error('cannot attach a stream to a closed Connection')
  end
  self._stream = stream
end

---@param request {shutdown: fun(self: table)}
function AcpConnection:_track_request(request)
  if not self:is_ready() then
    pcall(request.shutdown, request)
    error('cannot attach a request to a closed Connection')
  end
  self._requests[request] = true
end

---@param request table
function AcpConnection:_untrack_request(request)
  self._requests[request] = nil
end

---Attach the spawned transport and route its inbound traffic into this connection.
---@param transport OpencodeAcpTransport
function AcpConnection:attach_transport(transport)
  self.transport = transport
end

---Select the protocol surface for a negotiated ACP version. ACP v1 is the only
---implemented surface today; a future `protocols/acp/v2/` plugs in here after
---`initialize` negotiates `acp_protocol_version`, without touching the UI.
---@param _version OpencodeAcpProtocolVersion
---@return OpencodeAcpSurface
local function surface_for(_version)
  return {
    operations = require('opencode.protocols.acp.operations'),
    observation = require('opencode.protocols.acp.observation'),
  }
end

---Publish the connection after the ACP initialize handshake succeeds.
---@param handshake OpencodeAcpHandshake
---@return OpencodeAcpConnection
function AcpConnection:mark_ready(handshake)
  if self._ready then
    return self
  end
  if self.shutdown_promise:is_resolved() then
    error('cannot ready a closed Connection')
  end
  local surface = surface_for(handshake.protocol_version)
  local observation = surface.observation
  self.version = handshake.version
  self.acp_protocol_version = handshake.protocol_version
  self.agent_info = handshake.agent_info
  self.capabilities = handshake.capabilities or {}
  self.server_identity = { version = handshake.version }
  self.operations = surface.operations
  self._observe = observation.new
  self._close_observations = observation.close
  self._route = observation.route_event
  self._handle_request = observation.handle_request
  self._ready = true
  return self
end

---@param ref {id: string, location?: OpencodeLocation, title?: string}
---@return OpencodeAcpObservation
function AcpConnection:observe(ref)
  if not self:is_ready() or not self._observe then
    error('cannot observe a session on a closed Connection')
  end
  if type(ref) ~= 'table' or type(ref.id) ~= 'string' or ref.id == '' then
    error('observe requires a session id')
  end
  local existing = self.observations[ref.id]
  if existing then
    return existing
  end
  local observation = self._observe(self, ref)
  self.observations[ref.id] = observation
  return observation
end

---@param message table
function AcpConnection:_on_notification(message)
  local route = self._route
  if route then
    route(self, message)
  end
end

---@param message table
function AcpConnection:_on_request(message)
  local handler = self._handle_request
  if handler then
    handler(self, message)
    return
  end
  if self.transport then
    self.transport:respond_error(message.id, -32601, 'Method not found')
  end
end

---@param result vim.SystemCompleted
function AcpConnection:_on_process_exit(result)
  if not self._shutdown_requested then
    log.warn(
      'ACP agent exited (code=%s, signal=%s)',
      tostring(result and result.code),
      tostring(result and result.signal)
    )
  end
  self:close()
end

---Answer a pending agent-to-client permission request.
---@param request_id string
---@param result table
---@return boolean
function AcpConnection:resolve_permission(request_id, result)
  local pending = self._pending_permissions[request_id]
  if not pending then
    return false
  end
  self._pending_permissions[request_id] = nil
  if self.transport then
    self.transport:respond(pending.rpc_id, result)
  end
  return true
end

---@return Promise<boolean>
function AcpConnection:check_health()
  return Promise.new():resolve(self:is_ready())
end

---@return Promise<boolean>
function AcpConnection:close()
  if self.shutdown_promise:is_resolved() then
    return self.shutdown_promise
  end

  self._shutdown_requested = true
  self._ready = false

  local close_observations = self._close_observations
  self._close_observations = nil
  if close_observations then
    close_observations(self)
  end

  local requests = self._requests
  self._requests = {}
  for request in pairs(requests) do
    pcall(request.shutdown, request)
  end

  local stream = self._stream
  self._stream = nil
  if stream then
    pcall(stream.shutdown, stream)
  end

  self._pending_permissions = {}

  local transport = self.transport
  self.transport = nil
  if transport then
    transport:close('ACP connection closed')
  end
  self:release_process()

  self.shutdown_promise:resolve(true)
  return self.shutdown_promise
end

---@return Promise<boolean>
function AcpConnection:shutdown()
  return self:close()
end

return M
