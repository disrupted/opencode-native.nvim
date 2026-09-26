local M = {}

---@return number
local function now_ms()
  local seconds, microseconds = vim.uv.gettimeofday()
  return (seconds * 1000) + math.floor(microseconds / 1000)
end

M.now_ms = now_ms

---@param value? any
---@return number
local function parse_time(value)
  if type(value) == 'number' then
    return value
  end
  if type(value) == 'string' and value ~= '' then
    local normalized = value:gsub('%.%d+', '')
    for _, format in ipairs({ '%Y-%m-%dT%H:%M:%SZ', '%Y-%m-%dT%H:%M:%S' }) do
      local ok, seconds = pcall(vim.fn.strptime, format, normalized)
      if ok and type(seconds) == 'number' and seconds > 0 then
        return seconds * 1000
      end
    end
  end
  return now_ms()
end

---@param info table
---@return table
function M.mapped_session(info)
  if type(info) ~= 'table' or type(info.sessionId) ~= 'string' then
    error('ACP session info is missing sessionId', 0)
  end
  local cwd = type(info.cwd) == 'string' and info.cwd or vim.fn.getcwd()
  local updated = parse_time(info.updatedAt)
  return {
    id = info.sessionId,
    title = type(info.title) == 'string' and info.title or '',
    location = { directory = cwd },
    time = { created = updated, updated = updated },
  }
end

---@param file table
---@return table|nil
local function file_block(file)
  if type(file) ~= 'table' or type(file.media_type) ~= 'string' then
    return nil
  end
  if file.bytes ~= nil then
    if type(file.bytes) ~= 'string' then
      return nil
    end
    local encoded = vim.base64.encode(file.bytes)
    if file.media_type:match('^image/') then
      return { type = 'image', data = encoded, mimeType = file.media_type }
    end
    return {
      type = 'resource',
      resource = { uri = 'data:' .. file.media_type .. ';base64,' .. encoded, mimeType = file.media_type, blob = encoded },
    }
  end
  if type(file.server_uri) == 'string' then
    return { type = 'resource_link', uri = file.server_uri, name = file.name, mimeType = file.media_type }
  end
  return nil
end

---Build ACP ContentBlock[] from the shared submission input contract.
---@param input table
---@return table[]
function M.prompt_blocks(input)
  if type(input) ~= 'table' then
    error('ACP submit requires input', 0)
  end
  local blocks = {}
  for _, context in ipairs(input.context or {}) do
    if type(context) == 'table' and type(context.text) == 'string' then
      blocks[#blocks + 1] = { type = 'text', text = context.text }
    end
  end
  for _, file in ipairs(input.files or {}) do
    local block = file_block(file)
    if block then
      blocks[#blocks + 1] = block
    end
  end
  blocks[#blocks + 1] = { type = 'text', text = type(input.text) == 'string' and input.text or '' }
  return blocks
end

---@param block table
---@return string|nil
function M.content_text(block)
  if type(block) ~= 'table' then
    return nil
  end
  if block.type == 'text' and type(block.text) == 'string' then
    return block.text
  end
  return nil
end

---@type table<string, string>
local tool_names = {
  read = 'read',
  edit = 'edit',
  search = 'grep',
  execute = 'bash',
  fetch = 'webfetch',
}

---@param kind? string
---@return string
function M.tool_name(kind)
  return (kind and tool_names[kind]) or 'tool'
end

---@param status? string
---@return string
function M.tool_state(status)
  if status == 'pending' or status == 'in_progress' then
    return 'running'
  end
  if status == 'completed' then
    return 'completed'
  end
  if status == 'failed' then
    return 'error'
  end
  return 'streaming'
end

---@param old_text? string
---@param new_text? string
---@return string|nil
local function unified_diff(old_text, new_text)
  if type(old_text) ~= 'string' or type(new_text) ~= 'string' then
    return nil
  end
  local ok, diff = pcall(vim.diff, old_text, new_text, { result_type = 'unified', ctxlen = 3 })
  if not ok or type(diff) ~= 'string' or diff == '' then
    return nil
  end
  return diff
end

---@param content table
---@param path string
---@param diff string|nil
local function put_change(content, path, diff)
  content.changes = content.changes or {}
  for _, change in ipairs(content.changes) do
    if change.path == path then
      change.diff = diff or change.diff
      return
    end
  end
  content.changes[#content.changes + 1] = { path = path, diff = diff or '' }
end

---@param input table
local function apply_target(content, input)
  local path = input.filePath or input.path or input.file_path or input.file
  if type(path) == 'string' then
    content.target = { path = path }
  end
end

---Merge ACP ToolCallContent[] into a plugin tool content part.
---@param content table
---@param items? table
function M.apply_tool_content(content, items)
  if type(items) ~= 'table' then
    return
  end
  for _, item in ipairs(items) do
    if type(item) == 'table' and item.type == 'content' and type(item.content) == 'table' then
      local block = item.content
      if block.type == 'text' and type(block.text) == 'string' then
        content.result = content.result or {}
        content.result[#content.result + 1] = { kind = 'text', text = block.text }
      elseif (block.type == 'image' or block.type == 'audio') and type(block.uri) == 'string' then
        content.result = content.result or {}
        content.result[#content.result + 1] = { kind = 'file', uri = block.uri, media_type = block.mimeType or 'application/octet-stream' }
      end
    elseif type(item) == 'table' and item.type == 'diff' and type(item.path) == 'string' then
      put_change(content, item.path, unified_diff(item.oldText, item.newText))
    end
  end
end

---@param call table
---@return table
function M.tool_content(call)
  local content = {
    id = call.toolCallId,
    kind = 'tool',
    call_id = call.toolCallId,
    name = M.tool_name(call.kind),
    state = M.tool_state(call.status),
    time = { created = now_ms() },
  }
  if type(call.title) == 'string' then
    content.description = call.title
  end
  if type(call.rawInput) == 'table' then
    content.input = vim.deepcopy(call.rawInput)
    apply_target(content, call.rawInput)
  end
  M.apply_tool_content(content, call.content)
  if content.state == 'completed' or content.state == 'error' then
    content.time.completed = now_ms()
  end
  return content
end

---Patch-merge a tool_call_update into an existing tool content part.
---@param content table
---@param update table
function M.apply_tool_update(content, update)
  if type(update) ~= 'table' then
    return
  end
  if update.status ~= nil then
    content.state = M.tool_state(update.status)
  end
  if type(update.title) == 'string' then
    content.description = update.title
  end
  if type(update.rawInput) == 'table' then
    content.input = vim.deepcopy(update.rawInput)
    apply_target(content, update.rawInput)
  end
  M.apply_tool_content(content, update.content)
  content.time = content.time or { created = now_ms() }
  if content.state == 'completed' or content.state == 'error' then
    content.time.completed = now_ms()
  end
end

---@param kind? string
---@return 'once'|'always'|'reject'|nil
function M.permission_choice(kind)
  if kind == 'allow_once' then
    return 'once'
  end
  if kind == 'allow_always' then
    return 'always'
  end
  if kind == 'reject_once' or kind == 'reject_always' then
    return 'reject'
  end
  return nil
end

---@param options? table
---@return table[] choices, table<string, string> option_ids
function M.permission_choices(options)
  local choices, option_ids, seen = {}, {}, {}
  for _, option in ipairs(options or {}) do
    if type(option) == 'table' then
      local choice = M.permission_choice(option.kind)
      if choice and not seen[choice] then
        seen[choice] = true
        choices[#choices + 1] = { value = choice, label = type(option.name) == 'string' and option.name or choice }
        if type(option.optionId) == 'string' then
          option_ids[choice] = option.optionId
        end
      end
    end
  end
  return choices, option_ids
end

---Map an ACP stopReason to the plugin's idle outcome.
---@param stop_reason? string
---@return 'succeeded'|'failed'|'interrupted'
function M.stop_outcome(stop_reason)
  if stop_reason == 'cancelled' then
    return 'interrupted'
  end
  if stop_reason == 'refusal' then
    return 'failed'
  end
  return 'succeeded'
end

return M
