local assert = require('luassert')
local config = require('opencode.config')
local server_job = require('opencode.server_job')
local state = require('opencode.state')

describe('ACP config and acquisition', function()
  local original_values

  before_each(function()
    original_values = vim.deepcopy(config.values)
    state.jobs.clear_server()
  end)

  after_each(function()
    config.values = original_values
    state.jobs.clear_server()
  end)

  it('defaults to the opencode harness with ACP config present', function()
    assert.equals('opencode', config.defaults.harness)
    assert.equals(1, config.defaults.acp.protocol_version)
    assert.equals('opencode.nvim', config.defaults.acp.client_name)
    assert.same({}, config.defaults.acp.args)
  end)

  it('merges ACP settings', function()
    config.setup({ harness = 'acp', acp = { command = 'my-agent', args = { '--stdio' } } })
    assert.equals('acp', config.harness)
    assert.equals('my-agent', config.acp.command)
    assert.equals('--stdio', config.acp.args[1])
  end)

  it('rejects unknown harness values', function()
    assert.has_error(function()
      config.setup({ harness = 'nope' })
    end)
  end)

  it('routes ensure_server to the ACP agent job when harness is acp', function()
    config.setup({ harness = 'acp' })
    local acp_job = require('opencode.protocols.acp.job')
    local original_ensure = acp_job.ensure_agent
    local seen_opts
    acp_job.ensure_agent = function(opts)
      seen_opts = opts
      return 'stub'
    end
    local result = server_job.ensure_server({ force_health_check = true })
    acp_job.ensure_agent = original_ensure

    assert.equals('stub', result)
    assert.is_true(seen_opts.force_health_check)
  end)

  it('rejects acquisition when no agent command is configured', function()
    config.setup({ harness = 'acp', acp = { command = nil } })
    local pending = require('opencode.protocols.acp.job').ensure_agent()
    vim.wait(1000, function()
      return pending:is_resolved()
    end, 5)
    assert.is_true(pending:is_rejected())
  end)
end)
