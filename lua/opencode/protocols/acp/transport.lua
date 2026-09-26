local Promise = require('opencode.promise')
local log = require('opencode.log')

local M = {}

local Transport = {}
Transport.__index = Transport

---@param line string
---@return table|nil
local function decode_line(line)
  local ok, message = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
  if not ok or type(message) ~= 'table' then
    return nil
  end
  return message
end

---Create a transport without spawning. `attach` binds the process handle.
---@param opts OpencodeAcpTransportOptions
---@return OpencodeAcpTransport
function M.new(opts)
  local transport = setmetatable({
    _pending = {},
    _next_id = 0,
    _buffer = '',
    _alive = true,
    _on_request = opts.on_request,
    _on_notification = opts.on_notification,
    _on_exit = opts.on_exit,
  }, Transport)
  ---@cast transport OpencodeAcpTransport
  return transport
end

---@param job vim.SystemObj
function Transport:attach(job)
  self._job = job
end

---Spawn an ACP agent and speak line-delimited JSON-RPC 2.0 over its stdio.
---@param opts OpencodeAcpTransportOptions
---@return OpencodeAcpTransport
function M.spawn(opts)
  local transport = M.new(opts)
  ---@cast transport OpencodeAcpTransport

  transport:attach(vim.system(opts.command, {
    cwd = opts.cwd,
    env = opts.env,
    stdin = true,
    stdout = function(err, data)
      transport:_on_stdout(err, data)
    end,
    stderr = function(err, data)
      if type(data) == 'string' and data ~= '' then
        log.debug('ACP agent stderr: %s', vim.trim(data))
      end
      if err then
        log.warn('ACP agent stderr error: %s', vim.inspect(err))
      end
    end,
  }, function(result)
    transport:_on_process_exit(result)
  end))

  return transport
end

---@param message table
---@return boolean
function Transport:_write(message)
  local job = self._job
  if not self._alive or not job then
    return false
  end
  local ok, err = pcall(job.write, job, vim.json.encode(message) .. '\n')
  if not ok then
    log.warn('ACP transport write failed: %s', vim.inspect(err))
    return false
  end
  return true
end

---@param err any
---@param data string|nil
function Transport:_on_stdout(err, data)
  if err then
    log.warn('ACP transport stdout error: %s', vim.inspect(err))
    return
  end
  if type(data) ~= 'string' or data == '' then
    return
  end
  self._buffer = self._buffer .. data
  while true do
    local newline = self._buffer:find('\n', 1, true)
    if not newline then
      break
    end
    local line = self._buffer:sub(1, newline - 1):gsub('\r$', '')
    self._buffer = self._buffer:sub(newline + 1)
    if line ~= '' then
      self:_handle_message(line)
    end
  end
end

---@param line string
function Transport:_handle_message(line)
  local message = decode_line(line)
  if not message then
    log.warn('ACP transport received invalid JSON-RPC message: %s', line)
    return
  end

  if message.id ~= nil and message.method ~= nil then
    if self._on_request then
      self._on_request(message)
    else
      self:respond_error(message.id, -32601, 'Method not found')
    end
    return
  end

  if message.id ~= nil then
    local pending = self._pending[message.id]
    if not pending then
      log.debug('ACP transport response for unknown id %s', tostring(message.id))
      return
    end
    self._pending[message.id] = nil
    if message.error ~= nil then
      pending:reject(message.error)
    else
      pending:resolve(message.result)
    end
    return
  end

  if message.method ~= nil and self._on_notification then
    self._on_notification(message)
  end
end

---@param method string
---@param params? table
---@return Promise<any>
function Transport:request(method, params)
  local promise = Promise.new()
  if not self._alive then
    promise:reject('ACP transport is closed')
    return promise
  end
  local id = self._next_id
  self._next_id = id + 1
  self._pending[id] = promise
  if not self:_write({ jsonrpc = '2.0', id = id, method = method, params = params }) then
    self._pending[id] = nil
    promise:reject('ACP transport is closed')
  end
  return promise
end

---@param method string
---@param params? table
---@return boolean
function Transport:notify(method, params)
  return self:_write({ jsonrpc = '2.0', method = method, params = params })
end

---@param id integer|string
---@param result table
---@return boolean
function Transport:respond(id, result)
  return self:_write({ jsonrpc = '2.0', id = id, result = result })
end

---@param id integer|string
---@param code integer
---@param message string
---@param data? any
---@return boolean
function Transport:respond_error(id, code, message, data)
  return self:_write({ jsonrpc = '2.0', id = id, error = { code = code, message = message, data = data } })
end

---@return boolean
function Transport:is_running()
  local job = self._job
  return self._alive and job ~= nil and job:is_alive()
end

---@return integer|nil
function Transport:pid()
  local job = self._job
  return job and job.pid or nil
end

---@param result vim.SystemCompleted
function Transport:_on_process_exit(result)
  local was_alive = self._alive
  self._alive = false
  self._job = nil
  local pending = self._pending
  self._pending = {}
  for _, promise in pairs(pending) do
    promise:reject('ACP agent process exited')
  end
  if was_alive and self._on_exit then
    self._on_exit(result)
  end
end

---@param reason? string
function Transport:close(reason)
  local job = self._job
  self._alive = false
  self._job = nil
  local pending = self._pending
  self._pending = {}
  for _, promise in pairs(pending) do
    promise:reject(reason or 'ACP transport closed')
  end
  if job then
    pcall(function()
      job:kill('sigterm')
    end)
    vim.defer_fn(function()
      if job:is_alive() then
        pcall(function()
          job:kill('sigkill')
        end)
      end
    end, 500)
  end
end

return M
