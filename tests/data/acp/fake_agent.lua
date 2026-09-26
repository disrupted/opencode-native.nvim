-- Minimal ACP agent used by integration tests. Speaks line-delimited JSON-RPC 2.0
-- on stdio and exercises text streaming plus a permission round-trip.
local function send(message)
  io.stdout:write(vim.json.encode(message) .. '\n')
  io.stdout:flush()
end

local pending_prompt

for line in io.lines() do
  local ok, message = pcall(vim.json.decode, line)
  if ok and type(message) == 'table' then
    if message.method == 'initialize' then
      send({
        jsonrpc = '2.0',
        id = message.id,
        result = {
          protocolVersion = 1,
          agentCapabilities = { sessionCapabilities = { list = true } },
          agentInfo = { name = 'fake', version = '0.0.1' },
        },
      })
    elseif message.method == 'session/new' then
      send({ jsonrpc = '2.0', id = message.id, result = { sessionId = 'ses-fake' } })
    elseif message.method == 'session/list' then
      send({
        jsonrpc = '2.0',
        id = message.id,
        result = {
          sessions = { { sessionId = 'ses-fake', cwd = message.params.cwd, title = 'Fake session' } },
        },
      })
    elseif message.method == 'session/prompt' then
      local session_id = message.params.sessionId
      local text = ''
      for _, block in ipairs(message.params.prompt or {}) do
        if block.type == 'text' then
          text = text .. (block.text or '')
        end
      end
      if text:find('permission', 1, true) then
        pending_prompt = message.id
        send({
          jsonrpc = '2.0',
          id = 4242,
          method = 'session/request_permission',
          params = {
            sessionId = session_id,
            toolCall = { toolCallId = 'call-1', title = 'Edit file', kind = 'edit' },
            options = {
              { optionId = 'allow', name = 'Allow once', kind = 'allow_once' },
              { optionId = 'deny', name = 'Deny', kind = 'reject_once' },
            },
          },
        })
      else
        send({
          jsonrpc = '2.0',
          method = 'session/update',
          params = {
            sessionId = session_id,
            update = { sessionUpdate = 'agent_message_chunk', content = { type = 'text', text = 'pong' } },
          },
        })
        send({ jsonrpc = '2.0', id = message.id, result = { stopReason = 'end_turn' } })
      end
    elseif message.id == 4242 and pending_prompt then
      send({
        jsonrpc = '2.0',
        method = 'session/update',
        params = {
          sessionId = 'ses-fake',
          update = { sessionUpdate = 'agent_message_chunk', content = { type = 'text', text = 'allowed' } },
        },
      })
      send({ jsonrpc = '2.0', id = pending_prompt, result = { stopReason = 'end_turn' } })
      pending_prompt = nil
    end
  end
end
