local assert = require('luassert')
local normalize = require('opencode.protocols.acp.normalize')

describe('ACP normalize', function()
  it('maps session info into the shared session fact shape', function()
    local session = normalize.mapped_session({ sessionId = 'ses-1', cwd = '/work', title = 'Hello' })
    assert.equals('ses-1', session.id)
    assert.equals('Hello', session.title)
    assert.equals('/work', session.location.directory)
    assert.is_number(session.time.updated)
  end)

  it('builds ContentBlocks from the shared submission input', function()
    local blocks = normalize.prompt_blocks({
      text = 'do it',
      context = { { text = 'context body' } },
      files = { { media_type = 'text/plain', server_uri = 'file:///tmp/a.txt', name = 'a.txt' } },
      agents = {},
    })
    assert.equals('text', blocks[1].type)
    assert.equals('context body', blocks[1].text)
    assert.equals('resource_link', blocks[2].type)
    assert.equals('file:///tmp/a.txt', blocks[2].uri)
    assert.equals('do it', blocks[#blocks].text)
  end)

  it('encodes image bytes as an image block', function()
    local blocks = normalize.prompt_blocks({
      text = '',
      context = {},
      files = { { media_type = 'image/png', bytes = '\137PNG' } },
    })
    assert.equals('image', blocks[1].type)
    assert.equals('image/png', blocks[1].mimeType)
    assert.is_string(blocks[1].data)
  end)

  it('maps tool calls to formatter-ready tool content', function()
    local tool = normalize.tool_content({
      toolCallId = 'call-1',
      title = 'Edit main.lua',
      kind = 'edit',
      status = 'in_progress',
      rawInput = { filePath = '/tmp/main.lua' },
      content = {
        { type = 'diff', path = '/tmp/main.lua', oldText = 'a\n', newText = 'b\n' },
        { type = 'content', content = { type = 'text', text = 'applied' } },
      },
    })
    assert.equals('call-1', tool.id)
    assert.equals('tool', tool.kind)
    assert.equals('edit', tool.name)
    assert.equals('running', tool.state)
    assert.equals('/tmp/main.lua', tool.target.path)
    assert.equals('/tmp/main.lua', tool.changes[1].path)
    assert.is_string(tool.changes[1].diff)
    assert.equals('applied', tool.result[1].text)
  end)

  it('maps ACP tool kinds onto plugin formatter names', function()
    assert.equals('bash', normalize.tool_name('execute'))
    assert.equals('grep', normalize.tool_name('search'))
    assert.equals('read', normalize.tool_name('read'))
    assert.equals('tool', normalize.tool_name('think'))
    assert.equals('tool', normalize.tool_name(nil))
  end)

  it('maps ACP tool statuses onto plugin states', function()
    assert.equals('running', normalize.tool_state('pending'))
    assert.equals('running', normalize.tool_state('in_progress'))
    assert.equals('completed', normalize.tool_state('completed'))
    assert.equals('error', normalize.tool_state('failed'))
    assert.equals('streaming', normalize.tool_state(nil))
  end)

  it('patch-merges tool_call_update without dropping prior content', function()
    local tool = normalize.tool_content({
      toolCallId = 'call-2',
      kind = 'edit',
      status = 'in_progress',
      rawInput = { path = '/tmp/x.lua' },
      content = { { type = 'diff', path = '/tmp/x.lua', oldText = 'one\n', newText = 'two\n' } },
    })
    normalize.apply_tool_update(tool, {
      toolCallId = 'call-2',
      status = 'completed',
      content = { { type = 'content', content = { type = 'text', text = 'done' } } },
    })
    assert.equals('completed', tool.state)
    assert.equals('/tmp/x.lua', tool.changes[1].path)
    assert.equals('done', tool.result[1].text)
    assert.is_number(tool.time.completed)
  end)

  it('maps permission options to plugin choices and option ids', function()
    local choices, option_ids = normalize.permission_choices({
      { optionId = 'a', name = 'Allow once', kind = 'allow_once' },
      { optionId = 'b', name = 'Always', kind = 'allow_always' },
      { optionId = 'c', name = 'Deny', kind = 'reject_once' },
    })
    assert.equals('once', choices[1].value)
    assert.equals('always', choices[2].value)
    assert.equals('reject', choices[3].value)
    assert.equals('a', option_ids.once)
    assert.equals('c', option_ids.reject)
  end)

  it('maps stop reasons to idle outcomes', function()
    assert.equals('succeeded', normalize.stop_outcome('end_turn'))
    assert.equals('succeeded', normalize.stop_outcome('max_tokens'))
    assert.equals('interrupted', normalize.stop_outcome('cancelled'))
    assert.equals('failed', normalize.stop_outcome('refusal'))
  end)
end)
