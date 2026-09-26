local assert = require('luassert')
local transport_module = require('opencode.protocols.acp.transport')

---@return table, table, table
local function fake_transport()
  local state = { writes = {}, killed = false, alive = true }
  local received = { requests = {}, notifications = {}, exits = 0 }
  local transport = transport_module.new({
    command = { 'fake-agent' },
    on_request = function(message)
      received.requests[#received.requests + 1] = message
    end,
    on_notification = function(message)
      received.notifications[#received.notifications + 1] = message
    end,
    on_exit = function()
      received.exits = received.exits + 1
    end,
  })
  transport:attach({
    write = function(_, data)
      state.writes[#state.writes + 1] = data
      return true
    end,
    kill = function()
      state.killed = true
    end,
    is_alive = function()
      return state.alive
    end,
  })
  return transport, state, received
end

local function last_message(state)
  local raw = state.writes[#state.writes]
  assert.is_not_nil(raw)
  return vim.json.decode(raw)
end

describe('ACP transport', function()
  it('correlates responses by JSON-RPC id', function()
    local transport, state = fake_transport()
    local promise = transport:request('initialize', { protocolVersion = 1 })

    local sent = last_message(state)
    assert.equals('2.0', sent.jsonrpc)
    assert.equals('initialize', sent.method)
    assert.equals(1, sent.params.protocolVersion)
    assert.is_number(sent.id)

    transport:_on_stdout(nil, vim.json.encode({ jsonrpc = '2.0', id = sent.id, result = { protocolVersion = 1 } }) .. '\n')

    assert.is_true(promise:is_resolved())
    assert.equals(1, promise:wait().protocolVersion)
  end)

  it('reassembles messages split across partial reads', function()
    local transport, state = fake_transport()
    local promise = transport:request('session/new', { cwd = '/tmp' })
    local id = last_message(state).id

    local payload = vim.json.encode({ jsonrpc = '2.0', id = id, result = { sessionId = 'sess-1' } }) .. '\n'
    transport:_on_stdout(nil, payload:sub(1, 5))
    assert.is_false(promise:is_resolved())
    transport:_on_stdout(nil, payload:sub(6))
    assert.is_true(promise:is_resolved())
    assert.equals('sess-1', promise:wait().sessionId)
  end)

  it('rejects pending requests when the agent reports an error', function()
    local transport, state = fake_transport()
    local promise = transport:request('session/prompt', {})
    local id = last_message(state).id

    transport:_on_stdout(nil, vim.json.encode({ jsonrpc = '2.0', id = id, error = { code = -32000, message = 'nope' } }) .. '\n')

    assert.is_true(promise:is_rejected())
    assert.equals('nope', promise._error.message)
  end)

  it('dispatches agent notifications', function()
    local transport, _, received = fake_transport()
    transport:_on_stdout(nil, vim.json.encode({ jsonrpc = '2.0', method = 'session/update', params = { sessionId = 's' } }) .. '\n')
    assert.equals(1, #received.notifications)
    assert.equals('session/update', received.notifications[1].method)
  end)

  it('dispatches agent-to-client requests', function()
    local transport, _, received = fake_transport()
    transport:_on_stdout(nil, vim.json.encode({ jsonrpc = '2.0', id = 7, method = 'session/request_permission' }) .. '\n')
    assert.equals(1, #received.requests)
    assert.equals(7, received.requests[1].id)
  end)

  it('responds with method not found when no request handler is installed', function()
    local transport, state = fake_transport()
    transport._on_request = nil
    transport:_on_stdout(nil, vim.json.encode({ jsonrpc = '2.0', id = 9, method = 'unknown' }) .. '\n')
    local sent = last_message(state)
    assert.equals(9, sent.id)
    assert.equals(-32601, sent.error.code)
  end)

  it('rejects pending requests and notifies on process exit', function()
    local transport, _, received = fake_transport()
    local promise = transport:request('initialize', {})
    transport:_on_process_exit({ code = 1, signal = 0 })

    assert.is_true(promise:is_rejected())
    assert.equals(1, received.exits)
    assert.is_false(transport:is_running())
  end)

  it('kills the agent and rejects pending requests on close', function()
    local transport, state = fake_transport()
    local promise = transport:request('initialize', {})
    transport:close('bye')

    assert.is_true(state.killed)
    assert.is_true(promise:is_rejected())
    assert.equals('bye', promise._error)
  end)

  it('ignores responses for unknown ids', function()
    local transport = fake_transport()
    assert.has_no.errors(function()
      transport:_on_stdout(nil, vim.json.encode({ jsonrpc = '2.0', id = 42, result = {} }) .. '\n')
    end)
  end)
end)
