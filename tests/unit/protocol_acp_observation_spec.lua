local assert = require('luassert')
local Promise = require('opencode.promise')
local acp_observation = require('opencode.protocols.acp.observation')
local operations = require('opencode.protocols.acp.operations')

---@return table, table
local function fake_connection(capabilities)
  local connection = {
    protocol = 'acp',
    capabilities = capabilities or {},
    observations = {},
    operations = operations,
    transport = nil,
    _ready = true,
    _pending_permissions = {},
    _acp_sessions = {},
    _acp_commands = {},
    _acp_config_options = {},
  }

  local transport = { requests = {}, notifications = {}, responses = {}, pending = {} }
  function transport:request(method, params)
    self.requests[#self.requests + 1] = { method = method, params = params }
    local promise = Promise.new()
    self.pending[method] = self.pending[method] or {}
    table.insert(self.pending[method], promise)
    return promise
  end
  function transport:notify(method, params)
    self.notifications[#self.notifications + 1] = { method = method, params = params }
    return true
  end
  function transport:respond(id, result)
    self.responses[#self.responses + 1] = { id = id, result = result }
    return true
  end
  function transport:respond_error(id, code, message)
    self.responses[#self.responses + 1] = { id = id, error = { code = code, message = message } }
    return true
  end
  function transport:close() end
  connection.transport = transport

  function connection:is_ready()
    return self._ready
  end
  function connection:resolve_permission(request_id, result)
    local pending = self._pending_permissions[request_id]
    if not pending then
      return false
    end
    self._pending_permissions[request_id] = nil
    self.transport:respond(pending.rpc_id, result)
    return true
  end
  function connection:observe(ref)
    local existing = self.observations[ref.id]
    if existing then
      return existing
    end
    local observation = acp_observation.new(self, ref)
    self.observations[ref.id] = observation
    return observation
  end
  return connection, transport
end

---@param transport table
---@param method string
---@param value any
local function resolve_request(transport, method, value)
  local list = transport.pending[method]
  assert.is_not_nil(list, 'no pending request for ' .. method)
  local promise = table.remove(list, 1)
  promise:resolve(value)
end

---@param connection table
---@param session_id string
---@param update table
local function send_update(connection, session_id, update)
  acp_observation.route_event(connection, {
    jsonrpc = '2.0',
    method = 'session/update',
    params = { sessionId = session_id, update = update },
  })
end

describe('ACP observation', function()
  it('seeds ACP-unsupported resources', function()
    local connection = fake_connection()
    local observed = connection:observe({ id = 'ses-1' })
    local sync = observed:read().sync
    assert.equals('unsupported', sync.children.state)
    assert.equals('unsupported', sync.inbox.state)
    assert.equals('unsupported', sync.files.state)
    assert.equals('unsupported', sync.questions.state)
    assert.is_nil(sync.permissions.error)
  end)

  it('streams text, reasoning and tool calls into one assistant reply', function()
    local connection, transport = fake_connection()
    local observed = connection:observe({ id = 'ses-1' })

    local submitted = observed:submit({ text = 'hello' }):wait()
    assert.equals('accepted', submitted.kind)
    assert.is_not_nil(submitted.input.id)

    send_update(connection, 'ses-1', {
      sessionUpdate = 'agent_thought_chunk',
      content = { type = 'text', text = 'thinking' },
    })
    send_update(connection, 'ses-1', {
      sessionUpdate = 'agent_message_chunk',
      content = { type = 'text', text = 'hi ' },
    })
    send_update(connection, 'ses-1', {
      sessionUpdate = 'tool_call',
      toolCallId = 't1',
      kind = 'execute',
      status = 'in_progress',
      rawInput = { command = 'ls' },
    })
    send_update(connection, 'ses-1', {
      sessionUpdate = 'tool_call_update',
      toolCallId = 't1',
      status = 'completed',
      content = { { type = 'content', content = { type = 'text', text = 'ok' } } },
    })
    send_update(connection, 'ses-1', {
      sessionUpdate = 'agent_message_chunk',
      content = { type = 'text', text = 'world' },
    })

    resolve_request(transport, 'session/prompt', { stopReason = 'end_turn' })
    local completion = submitted.completion:wait()
    assert.equals('session_idle', completion.kind)
    assert.equals('succeeded', completion.outcome)

    local reply = observed._runtime.find_reply(observed, submitted.input.id)
    assert.is_not_nil(reply)
    assert.equals('assistant', reply.kind)
    assert.equals('reasoning', reply.content[1].kind)
    assert.equals('thinking', reply.content[1].text)
    assert.equals('hi ', reply.content[2].text)
    assert.equals('tool', reply.content[3].kind)
    assert.equals('bash', reply.content[3].name)
    assert.equals('completed', reply.content[3].state)
    assert.equals('ok', reply.content[3].result[1].text)
    assert.equals('world', reply.content[4].text)

    assert.equals('idle', observed:read().execution.activity)
  end)

  it('reports interrupted when the agent cancels a turn', function()
    local connection, transport = fake_connection()
    local observed = connection:observe({ id = 'ses-1' })
    local submitted = observed:submit({ text = 'hello' }):wait()
    resolve_request(transport, 'session/prompt', { stopReason = 'cancelled' })
    local completion = submitted.completion:wait()
    assert.equals('interrupted', completion.outcome)
  end)

  it('reports failed when the turn request rejects', function()
    local connection, transport = fake_connection()
    local observed = connection:observe({ id = 'ses-1' })
    local submitted = observed:submit({ text = 'hello' }):wait()
    local list = transport.pending['session/prompt']
    table.remove(list, 1):reject({ message = 'boom' })
    vim.wait(500, function()
      return submitted.completion:is_resolved()
    end, 5)
    assert.is_true(submitted.completion:is_rejected())
  end)

  it('enforces one prompt turn at a time', function()
    local connection = fake_connection()
    local observed = connection:observe({ id = 'ses-1' })
    observed:submit({ text = 'first' }):wait()
    assert.has_error(function()
      observed:submit({ text = 'second' }):wait()
    end)
  end)

  it('records permission requests and answers them', function()
    local connection, transport = fake_connection()
    local observed = connection:observe({ id = 'ses-1' })

    acp_observation.handle_request(connection, {
      jsonrpc = '2.0',
      id = 900,
      method = 'session/request_permission',
      params = {
        sessionId = 'ses-1',
        toolCall = { title = 'Edit file', kind = 'edit' },
        options = {
          { optionId = 'o1', name = 'Allow once', kind = 'allow_once' },
          { optionId = 'o2', name = 'Deny', kind = 'reject_once' },
        },
      },
    })

    local request = observed:read().permission_requests_by_id['900']
    assert.is_not_nil(request)
    assert.equals('pending', request.status)
    assert.equals('once', request.choices[1].value)

    local ok = observed:reply_permission('900', { choice = 'once' }):wait()
    assert.is_true(ok)
    assert.equals('answered', observed:read().permission_requests_by_id['900'].status)
    assert.equals(900, transport.responses[1].id)
    assert.equals('selected', transport.responses[1].result.outcome.outcome)
    assert.equals('o1', transport.responses[1].result.outcome.optionId)
  end)

  it('cancels pending permission requests on interrupt', function()
    local connection, transport = fake_connection()
    local observed = connection:observe({ id = 'ses-1' })

    acp_observation.handle_request(connection, {
      id = 12,
      method = 'session/request_permission',
      params = {
        sessionId = 'ses-1',
        toolCall = { title = 'Edit file' },
        options = { { optionId = 'o1', name = 'Allow', kind = 'allow_once' } },
      },
    })

    assert.is_true(observed:interrupt():wait())
    assert.equals('session/cancel', transport.notifications[1].method)
    assert.equals('cancelled', transport.responses[1].result.outcome.outcome)
    assert.equals('answered', observed:read().permission_requests_by_id['12'].status)
  end)

  it('stores available commands and session info updates', function()
    local connection = fake_connection()
    local observed = connection:observe({ id = 'ses-1' })

    send_update(connection, 'ses-1', {
      sessionUpdate = 'available_commands_update',
      availableCommands = { { name = 'review', description = 'Review changes' } },
    })
    send_update(connection, 'ses-1', { sessionUpdate = 'session_info_update', title = 'Renamed' })

    assert.equals('review', connection._acp_commands[1].name)
    assert.equals('Renamed', observed:read().session.title)
  end)

  it('creates sessions through session/new', function()
    local connection, transport = fake_connection()
    local pending = operations.create_session(connection, { directory = '/work' }, { title = 'T' })
    assert.equals('session/new', transport.requests[1].method)
    assert.equals('/work', transport.requests[1].params.cwd)
    resolve_request(transport, 'session/new', { sessionId = 'ses-new' })
    local session = pending:wait()
    assert.equals('ses-new', session.id)
    assert.equals('T', session.title)
  end)

  it('lists sessions only when the agent advertises the capability', function()
    local connection = fake_connection()
    assert.equals(0, #operations.list_sessions_project(connection, { directory = '/work' }):wait())

    local capable, transport = fake_connection({ sessionCapabilities = { list = true } })
    local pending = operations.list_sessions_project(capable, { directory = '/work' })
    resolve_request(transport, 'session/list', {
      sessions = { { sessionId = 's1', cwd = '/work', title = 'One' } },
    })
    local sessions = pending:wait()
    assert.equals('s1', sessions[1].id)
  end)

  it('degrades the agent catalog to a single neutral mode', function()
    local connection = fake_connection()
    assert.same({ 'agent' }, operations.list_primary_agents(connection):wait())
  end)

  it('adopts modes and config options advertised by session/new', function()
    local connection, transport = fake_connection()
    local pending = operations.create_session(connection, { directory = '/work' }, {})
    resolve_request(transport, 'session/new', {
      sessionId = 'ses-1',
      modes = { currentModeId = 'plan', availableModes = { { id = 'plan', name = 'Plan' }, { id = 'build', name = 'Build' } } },
      configOptions = { { id = 'model', name = 'Model', category = 'model', type = 'select' } },
    })
    pending:wait()

    assert.same({ 'build', 'plan' }, operations.list_primary_agents(connection):wait())

    local model_pending = operations.set_session_model(connection, 'ses-1', { providerID = 'p', id = 'm' })
    local request = transport.requests[#transport.requests]
    assert.equals('session/set_config_option', request.method)
    assert.equals('model', request.params.configId)
    assert.equals('p/m', request.params.value)
    resolve_request(transport, 'session/set_config_option', {})
    assert.is_true(model_pending:wait())
  end)
end)
