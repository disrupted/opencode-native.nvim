local assert = require('luassert')
local Promise = require('opencode.promise')
local config = require('opencode.config')
local state = require('opencode.state')
local job = require('opencode.protocols.acp.job')
local transport_mod = require('opencode.protocols.acp.transport')

local function fake_agent(initialize_result)
  return {
    request = function(_, method)
      if method == 'initialize' then
        return Promise.new():resolve(initialize_result)
      end
      return Promise.new():resolve({})
    end,
    notify = function()
      return true
    end,
    respond = function()
      return true
    end,
    respond_error = function()
      return true
    end,
    close = function() end,
    is_running = function()
      return true
    end,
  }
end

describe('ACP job', function()
  local original_values

  before_each(function()
    original_values = vim.deepcopy(config.values)
    state.jobs.clear_server()
  end)

  after_each(function()
    config.values = original_values
    state.jobs.clear_server()
  end)

  it('spawns, initializes and marks the connection ready', function()
    config.setup({ harness = 'acp', acp = { command = 'fake-agent' } })
    local original_spawn = transport_mod.spawn
    local seen_opts
    transport_mod.spawn = function(opts)
      seen_opts = opts
      return fake_agent({
        protocolVersion = 1,
        agentCapabilities = { sessionCapabilities = { list = true } },
        agentInfo = { name = 'fake', version = '9.9.9' },
      })
    end

    local connection = job.ensure_agent():wait()
    transport_mod.spawn = original_spawn

    assert.equals('acp', connection.protocol)
    assert.equals('9.9.9', connection.version)
    assert.equals(1, connection.acp_protocol_version)
    assert.is_true(connection:is_ready())
    assert.is_true(connection.capabilities.sessionCapabilities.list)
    assert.same({ 'fake-agent' }, seen_opts.command)
    assert.is_true(state.opencode_server == connection)
  end)

  it('reuses a ready ACP connection', function()
    config.setup({ harness = 'acp', acp = { command = 'fake-agent' } })
    local original_spawn = transport_mod.spawn
    local spawns = 0
    transport_mod.spawn = function()
      spawns = spawns + 1
      return fake_agent({ protocolVersion = 1, agentInfo = { version = '1.0.0' } })
    end

    local first = job.ensure_agent():wait()
    local second = job.ensure_agent():wait()
    transport_mod.spawn = original_spawn

    assert.is_true(first == second)
    assert.equals(1, spawns)
  end)

  it('rejects when initialize fails', function()
    config.setup({ harness = 'acp', acp = { command = 'fake-agent' } })
    local original_spawn = transport_mod.spawn
    transport_mod.spawn = function()
      return {
        request = function()
          return Promise.new():reject({ message = 'handshake failed' })
        end,
        notify = function() end,
        respond = function() end,
        respond_error = function() end,
        close = function() end,
        is_running = function()
          return true
        end,
      }
    end

    local pending = job.ensure_agent()
    vim.wait(1000, function()
      return pending:is_resolved()
    end, 5)
    transport_mod.spawn = original_spawn

    assert.is_true(pending:is_rejected())
  end)
end)
