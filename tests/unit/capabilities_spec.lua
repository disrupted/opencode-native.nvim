local assert = require('luassert')
local capabilities = require('opencode.capabilities')

describe('opencode capabilities', function()
  it('allows everything for the opencode HTTP harness', function()
    local connection = { protocol = 'v2' }
    assert.is_true(capabilities.supports(connection, 'children'))
    assert.is_true(capabilities.supports(connection, 'diff'))
    assert.is_true(capabilities.supports(connection, 'models'))
  end)

  it('gates opencode-only features off for ACP', function()
    local connection = { protocol = 'acp' }
    assert.is_false(capabilities.supports(connection, 'children'))
    assert.is_false(capabilities.supports(connection, 'files'))
    assert.is_false(capabilities.supports(connection, 'inbox'))
    assert.is_false(capabilities.supports(connection, 'questions'))
    assert.is_false(capabilities.supports(connection, 'diff'))
    assert.is_false(capabilities.supports(connection, 'fork'))
  end)

  it('requires a connection before allowing a feature', function()
    assert.is_false(capabilities.supports(nil, 'children'))
  end)

  it('notifies and blocks gated actions', function()
    local notified
    local original = vim.notify
    vim.notify = function(message)
      notified = message
    end
    local allowed = capabilities.require({ protocol = 'acp' }, 'diff', 'Diff review')
    vim.notify = original

    assert.is_false(allowed)
    assert.equals('Diff review is not supported by the active ACP agent', notified)
  end)
end)
