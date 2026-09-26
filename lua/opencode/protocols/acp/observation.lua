local lifecycle = require('opencode.protocols.observation')
local entries = require('opencode.protocols.entries')
local submission = require('opencode.protocols.submission')
local normalize = require('opencode.protocols.acp.normalize')
local id = require('opencode.id')

local M = {}

---@param observation OpencodeAcpObservation
---@return table
local function read_state(observation)
  return observation:read()
end

---@param observation OpencodeAcpObservation
---@param entry table
---@return table
local function put_entry(observation, entry)
  local state = read_state(observation)
  local existing = state.entries_by_id[entry.id]
  local replaced = entries.replace(existing, entry)
  state.entries_by_id[entry.id] = replaced
  if not existing then
    state.entry_order[#state.entry_order + 1] = entry.id
  end
  return replaced
end

---@param observation OpencodeAcpObservation
---@param entry_id string
---@return table
local function create_assistant_entry(observation, entry_id)
  return put_entry(observation, {
    id = entry_id,
    session_id = observation._session_id,
    kind = 'assistant',
    time = { created = normalize.now_ms() },
    content = {},
  })
end

---Resolve the assistant entry for a chunk, preferring the turn opened at submit.
---@param observation OpencodeAcpObservation
---@param message_id? string
---@return table|nil
local function assistant_entry(observation, message_id)
  if type(message_id) == 'string' then
    local known = observation._acp_assistant_by_message[message_id]
    if known then
      return known
    end
  end
  local turn = observation._acp_turn
  if turn and turn.entry then
    if type(message_id) == 'string' then
      observation._acp_assistant_by_message[message_id] = turn.entry
    end
    return turn.entry
  end
  if type(message_id) == 'string' then
    local created = create_assistant_entry(observation, message_id)
    observation._acp_assistant_by_message[message_id] = created
    return created
  end
  return nil
end

---@param entry table
---@param kind 'text'|'reasoning'
---@param text string
local function append_content(entry, kind, text)
  local last = entry.content[#entry.content]
  if not last or last.kind ~= kind then
    last = { kind = kind, text = '' }
    if kind == 'reasoning' then
      last.time = { created = normalize.now_ms() }
    end
    entry.content[#entry.content + 1] = last
  end
  last.text = last.text .. text
end

---@param observation OpencodeAcpObservation
local function mark_messages(observation)
  read_state(observation).sync.messages = { state = 'current' }
  observation:_event_changed('messages')
end

---@param observation OpencodeAcpObservation
local function mark_session(observation)
  read_state(observation).sync.session = { state = 'current' }
  observation:_event_changed('session')
end

---@param observation OpencodeAcpObservation
---@param update table
local function handle_update(observation, update)
  local kind = update.sessionUpdate

  if kind == 'user_message_chunk' then
    local turn = observation._acp_turn
    local text = normalize.content_text(update.content)
    if turn and turn.user_entry and text then
      append_content(turn.user_entry, 'text', text)
      mark_messages(observation)
    end
  elseif kind == 'agent_message_chunk' or kind == 'agent_thought_chunk' then
    local entry = assistant_entry(observation, update.messageId)
    local text = normalize.content_text(update.content)
    if entry and text then
      append_content(entry, kind == 'agent_thought_chunk' and 'reasoning' or 'text', text)
      mark_messages(observation)
    end
  elseif kind == 'tool_call' then
    local entry = assistant_entry(observation, update.messageId)
    if entry and type(update.toolCallId) == 'string' then
      local content = normalize.tool_content(update)
      entry.content[#entry.content + 1] = content
      observation._acp_tools[update.toolCallId] = content
      mark_messages(observation)
    end
  elseif kind == 'tool_call_update' then
    local content = observation._acp_tools[update.toolCallId]
    if content then
      normalize.apply_tool_update(content, update)
      mark_messages(observation)
    end
  elseif kind == 'plan' then
    read_state(observation).session.plan = vim.deepcopy(update)
    mark_session(observation)
  elseif kind == 'available_commands_update' then
    observation._connection._acp_commands = vim.deepcopy(update.availableCommands or {})
  elseif kind == 'current_mode_update' then
    read_state(observation).session.mode = update.currentModeId
    mark_session(observation)
  elseif kind == 'config_option_update' then
    observation._connection._acp_config_options = vim.deepcopy(update.configOptions or {})
  elseif kind == 'session_info_update' then
    local session = read_state(observation).session
    if type(update.title) == 'string' then
      session.title = update.title
    end
    session.time = session.time or {}
    session.time.updated = normalize.now_ms()
    mark_session(observation)
  elseif kind == 'usage_update' then
    local session = read_state(observation).session
    session.usage = { used = update.used, size = update.size }
    if type(update.cost) == 'table' then
      session.cost = update.cost.amount
    end
    mark_session(observation)
  end
end

---Route one inbound ACP notification. Notifications arrive from the transport, not
---from an SSE stream, so this is the ACP analogue of a protocol event router.
---@param connection OpencodeAcpConnection
---@param message table
function M.route_event(connection, message)
  if type(message) ~= 'table' or message.method ~= 'session/update' then
    return
  end
  local params = message.params
  if type(params) ~= 'table' or type(params.sessionId) ~= 'string' or type(params.update) ~= 'table' then
    return
  end
  local observation = connection.observations[params.sessionId]
  if not observation then
    return
  end
  handle_update(observation, params.update)
end

---Handle an agent-to-client request. ACP v1 only requires session/request_permission.
---@param connection OpencodeAcpConnection
---@param message table
function M.handle_request(connection, message)
  local agent = connection.transport
  if message.method ~= 'session/request_permission' then
    if agent then
      agent:respond_error(message.id, -32601, 'Method not found')
    end
    return
  end
  local params = message.params
  if type(params) ~= 'table' or type(params.sessionId) ~= 'string' then
    if agent then
      agent:respond_error(message.id, -32602, 'Invalid params')
    end
    return
  end

  local request_id = tostring(message.id)
  local choices, option_ids = normalize.permission_choices(params.options)
  connection._pending_permissions[request_id] = {
    rpc_id = message.id,
    session_id = params.sessionId,
    options = option_ids,
  }

  local observation = connection.observations[params.sessionId]
  if not observation then
    return
  end

  local tool_call = type(params.toolCall) == 'table' and params.toolCall or {}
  observation._acp_pending_options[request_id] = true
  read_state(observation).permission_requests_by_id[request_id] = {
    id = request_id,
    session_id = params.sessionId,
    permission = tool_call.title or tool_call.kind or 'tool',
    message = tool_call.title,
    resources = tool_call.locations or {},
    choices = choices,
    status = 'pending',
  }
  read_state(observation).sync.permissions = { state = 'current' }
  observation:_event_changed('permissions')
end

---@param observation OpencodeAcpObservation
---@param input_id string
---@return table|nil
local function find_reply(observation, input_id)
  local entry_id = observation._acp_reply_by_input[input_id]
  if not entry_id then
    return nil
  end
  return read_state(observation).entries_by_id[entry_id]
end

---@param observation OpencodeAcpObservation
---@param reason string
local function fail_submissions(observation, reason)
  local turn = observation._acp_turn
  if turn then
    turn.finish(nil, reason)
  end
end

---@param observation OpencodeAcpObservation
---@param resource OpencodeObservedResource
---@return Promise<any>
local function request_resource(observation, resource)
  error('ACP resource is local: ' .. tostring(resource), 0)
end

---@param observation OpencodeAcpObservation
---@param resource OpencodeObservedResource
---@param value any
local function apply_resource(observation, resource, value)
  error('ACP resource is local: ' .. tostring(resource), 0)
end

---@param connection OpencodeAcpConnection
---@param ref {id: string, location?: OpencodeLocation, title?: string}
---@return OpencodeAcpObservation
function M.new(connection, ref)
  local location = type(ref.location) == 'table' and vim.deepcopy(ref.location) or { directory = vim.fn.getcwd() }
  local session = {
    id = ref.id,
    location = location,
    title = type(ref.title) == 'string' and ref.title or '',
    time = { created = normalize.now_ms(), updated = normalize.now_ms() },
  }
  local state = lifecycle.new_state(session, {
    children = 'ACP has no child sessions',
    inbox = 'ACP has no prompt queue',
    files = 'ACP has no file-status contract',
    questions = 'ACP does not advertise elicitation',
  })
  local observation = lifecycle.attach(connection, session, state, {
    name = 'ACP',
    operations_need_stream = false,
    stream_resource = function()
      return false
    end,
    local_resource = function(resource)
      return resource == 'session'
        or resource == 'messages'
        or resource == 'execution'
        or resource == 'permissions'
    end,
    refresh_after_event = function()
      return false
    end,
    request_resource = request_resource,
    apply_resource = apply_resource,
    route_event = M.route_event,
    find_reply = find_reply,
    on_stream_error = fail_submissions,
    on_close = function(current)
      fail_submissions(current, 'connection closed')
    end,
  })
  ---@cast observation OpencodeAcpObservation

  observation._acp_turn = nil
  observation._acp_reply_by_input = {}
  observation._acp_assistant_by_message = {}
  observation._acp_tools = {}
  observation._acp_pending_options = {}

  function observation.validate_message_options(_, opts, default_system)
    for _, setting in ipairs({ 'agent', 'model', 'variant' }) do
      if opts[setting] ~= nil then
        error('ACP submit does not support per-message ' .. setting)
      end
    end
    if opts.system ~= nil or default_system ~= nil then
      error('ACP submit does not support a per-message system prompt')
    end
  end

  ---@param input table
  ---@param selected? table
  ---@return Promise<OpencodeSubmission>
  function observation:submit(input, selected)
    if self._acp_turn then
      error('ACP supports one prompt turn at a time', 0)
    end

    local input_id = id.ascending('message')
    local finish = self:_begin_local_operation()
    local ok, admission = pcall(connection.operations.submit, connection, self._session_id, input)
    if not ok then
      finish()
      error(admission, 0)
    end

    local result = admission:and_then(function(payload)
      if not self:_is_current() then
        error('ACP submit response arrived after Observation release', 0)
      end
      if type(payload) ~= 'table' or not payload.turn then
        error('ACP submit returned an invalid admission', 0)
      end

      local user_entry = {
        id = input_id,
        session_id = self._session_id,
        kind = 'user',
        time = { created = normalize.now_ms() },
        content = { { kind = 'text', text = type(input.text) == 'string' and input.text or '' } },
      }
      put_entry(self, user_entry)
      local assistant = create_assistant_entry(self, input_id .. ':assistant')
      self._acp_reply_by_input[input_id] = assistant.id

      local release = self:_begin_local_operation()
      local record = { user_entry = user_entry, entry = assistant }
      local handle, complete = submission.new({ kind = 'accepted', input = { id = input_id } }, function()
        release()
      end)
      record.finish = complete
      self._acp_turn = record

      read_state(self).execution = { activity = 'running' }
      read_state(self).sync.execution = { state = 'current' }
      read_state(self).sync.messages = { state = 'current' }
      self:_notify('messages')
      self:_event_changed('execution')

      payload.turn
        :and_then(function(response)
          if self._acp_turn == record then
            self._acp_turn = nil
          end
          local outcome = normalize.stop_outcome(type(response) == 'table' and response.stopReason or nil)
          if self:_is_current() then
            read_state(self).execution = {
              activity = 'idle',
              last_outcome = outcome,
              last_idle = normalize.now_ms(),
            }
            self:_event_changed('execution')
          end
          complete({ kind = 'session_idle', outcome = outcome, idle_at = normalize.now_ms() })
        end)
        :catch(function(err)
          if self._acp_turn == record then
            self._acp_turn = nil
          end
          if self:_is_current() then
            read_state(self).execution = {
              activity = 'idle',
              last_outcome = 'failed',
              last_idle = normalize.now_ms(),
            }
            self:_event_changed('execution')
          end
          local message = type(err) == 'table' and (err.message or err.code) or err
          complete(nil, 'ACP prompt failed: ' .. tostring(message))
        end)

      return handle
    end)

    return result:finally(finish)
  end

  ---@return Promise<boolean>
  function observation:interrupt()
    for request_id in pairs(self._acp_pending_options) do
      if connection._pending_permissions[request_id] then
        connection:resolve_permission(request_id, { outcome = { outcome = 'cancelled' } })
        local fact = read_state(self).permission_requests_by_id[request_id]
        if fact then
          fact.status = 'answered'
          fact.answer = 'reject'
        end
      end
      self._acp_pending_options[request_id] = nil
    end
    self:_event_changed('permissions')
    return self:_start_action(connection.operations.interrupt, self._session_id)
  end

  ---@param request_id string
  ---@param answer {choice: 'once'|'always'|'reject', message?: string}|string
  ---@return Promise<boolean>
  function observation:reply_permission(request_id, answer)
    if type(answer) == 'string' then
      answer = { choice = answer }
    end
    local fact = read_state(self).permission_requests_by_id[request_id]
    if not fact or fact.status ~= 'pending' then
      error('ACP permission request is not pending', 0)
    end
    if answer.choice ~= 'once' and answer.choice ~= 'always' and answer.choice ~= 'reject' then
      error('invalid ACP permission answer', 0)
    end
    return self
      :_start_action(connection.operations.reply_permission, self._session_id, request_id, { reply = answer.choice })
      :and_then(function(value)
        fact.status = 'answered'
        fact.answer = answer.choice
        self._acp_pending_options[request_id] = nil
        self:_event_changed('permissions')
        return value
      end)
  end

  return observation
end

---@param connection OpencodeAcpConnection
function M.close(connection)
  lifecycle.close(connection)
end

return M
