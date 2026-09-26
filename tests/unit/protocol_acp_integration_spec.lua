local assert = require('luassert')
local config = require('opencode.config')
local state = require('opencode.state')
local job = require('opencode.protocols.acp.job')

local fake_agent = vim.fs.joinpath(vim.fn.getcwd(), 'tests/data/acp/fake_agent.lua')

describe('ACP integration with a real agent process', function()
  local original_values
  local connection

  before_each(function()
    original_values = vim.deepcopy(config.values)
    state.jobs.clear_server()
    config.setup({
      harness = 'acp',
      acp = {
        command = vim.v.progpath,
        args = { '--headless', '-u', 'NONE', '-i', 'NONE', '-l', fake_agent },
      },
    })
    connection = job.ensure_agent():wait()
  end)

  after_each(function()
    if connection then
      connection:close()
      connection = nil
    end
    config.values = original_values
    state.jobs.clear_server()
  end)

  it('performs the initialize handshake and creates a session', function()
    assert.is_true(connection:is_ready())
    assert.equals('0.0.1', connection.version)

    local session = connection.operations.create_session(connection, { directory = vim.fn.getcwd() }, {}):wait()
    assert.equals('ses-fake', session.id)
  end)

  it('streams a reply end to end', function()
    local session = connection.operations.create_session(connection, { directory = vim.fn.getcwd() }, {}):wait()
    local observed = connection:observe({ id = session.id, location = session.location })

    local submitted = observed:submit({ text = 'ping' }):wait()
    local completion = submitted.completion:wait(5000)
    assert.equals('session_idle', completion.kind)
    assert.equals('succeeded', completion.outcome)

    local reply = observed._runtime.find_reply(observed, submitted.input.id)
    assert.is_not_nil(reply)
    assert.equals('pong', reply.content[1].text)
  end)

  it('answers a permission request and finishes the turn', function()
    local session = connection.operations.create_session(connection, { directory = vim.fn.getcwd() }, {}):wait()
    local observed = connection:observe({ id = session.id, location = session.location })

    local submitted = observed:submit({ text = 'needs permission' }):wait()
    vim.wait(5000, function()
      return observed:read().permission_requests_by_id['4242'] ~= nil
    end, 10)

    local request = observed:read().permission_requests_by_id['4242']
    assert.is_not_nil(request)
    assert.equals('pending', request.status)

    observed:reply_permission('4242', { choice = 'once' }):wait()
    local completion = submitted.completion:wait(5000)
    assert.equals('succeeded', completion.outcome)

    local reply = observed._runtime.find_reply(observed, submitted.input.id)
    assert.equals('allowed', reply.content[1].text)
  end)
end)
