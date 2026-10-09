---@mod agent.nvim_mcp.server Stdio MCP server that forwards tool calls to the parent Neovim
---
--- Runs in the headless controller process (`nvim --headless -l main.lua <addr>`). Messages are
--- newline-delimited JSON-RPC 2.0 on stdin/stdout. Only protocol messages are written to stdout;
--- diagnostics go to stderr. Tool calls go to the parent over msgpack-RPC (see rpc.lua) and run
--- the code in remote.lua there.
local rpc = require('agent.nvim_mcp.rpc')

local uv = vim.uv

local M = {}

M.VERSION = '0.1.0'
M.LATEST_PROTOCOL_VERSION = '2025-11-25'
M.SUPPORTED_PROTOCOL_VERSIONS = { '2025-11-25', '2025-06-18', '2025-03-26', '2024-11-05' }
M.DEFAULT_TIMEOUT_MS = 30000

local EMPTY_DICT_MT = getmetatable(vim.empty_dict())

-- Tool definitions ------------------------------------------------------------------------------

local function obj(properties, required)
  return {
    type = 'object',
    properties = next(properties) and properties or vim.empty_dict(),
    required = required,
    additionalProperties = false,
  }
end

local BUFFER = {
  anyOf = { { type = 'integer' }, { type = 'string' } },
  description = 'Buffer number, a file path (absolute, or relative to the Neovim working directory), or an '
    .. 'IDE context path starting with nvim://buffer/ (e.g. nvim://buffer/12/fish).',
}

---@type { name: string, description: string, inputSchema: table }[]
local TOOLS = {
  {
    name = 'read_buffer',
    description = 'Read lines of a Neovim buffer, including unsaved changes. Returns a header line '
      .. '"<path> (lines a-b of N)" followed by numbered lines ("%6d<TAB>text"). Unloaded buffers are '
      .. 'loaded; a path with no buffer is read from disk. Defaults to the buffer in the main editor '
      .. 'window (the file the user is editing). Give buffer as a file path, or as a buffer number: '
      .. "to list buffers, call eval with map(getbufinfo({'buflisted': 1}), '[v:val.bufnr, v:val.name]') "
      .. '(returns [bufnr, path] pairs) or use exec_lua. An IDE context path starting with '
      .. 'nvim://buffer/ (e.g. nvim://buffer/12/fish) is a Neovim buffer that is not a file, such as a '
      .. 'terminal: pass it as buffer. For a terminal buffer, the default range is its last 200 lines '
      .. '(up to the last non-empty one).',
    inputSchema = obj({
      buffer = BUFFER,
      start_line = { type = 'integer', description = 'First line, 1-based (default 1).' },
      end_line = { type = 'integer', description = 'Last line, 1-based inclusive; -1 means the last line (default -1).' },
    }),
  },
  {
    name = 'open_file',
    description = 'Open a file in the main Neovim editor window (never in the agent terminal) and focus '
      .. 'it, optionally moving the cursor to line/column and visually selecting line..end_line.',
    inputSchema = obj({
      path = { type = 'string', description = 'File path (absolute, or relative to the Neovim working directory).' },
      line = { type = 'integer', description = 'Line to move the cursor to, 1-based.' },
      column = { type = 'integer', description = 'Column to move the cursor to, 1-based.' },
      end_line = { type = 'integer', description = 'Visually select from line to end_line (inclusive).' },
      split = {
        type = 'string',
        enum = { 'none', 'horizontal', 'vertical', 'tab' },
        description = 'Open in the main window (none, the default), a new split, or a new tab page.',
      },
    }, { 'path' }),
  },
  {
    name = 'execute_command',
    description = 'Run an Ex command in Neovim (as typed after ":") and return its output. The command runs '
      .. 'in the context of the main editor window.',
    inputSchema = obj({
      command = { type = 'string', description = 'Ex command, without the leading colon.' },
    }, { 'command' }),
  },
  {
    name = 'eval',
    description = 'Evaluate a Vimscript expression in Neovim and return its value as JSON. It is '
      .. "evaluated in the context of the main editor window, so e.g. expand('%:p') and line('.') give "
      .. "the user's file and cursor line, not the agent terminal's.",
    inputSchema = obj({
      expression = { type = 'string', description = 'Vimscript expression, e.g. "expand(\'%:p\')".' },
    }, { 'expression' }),
  },
  {
    name = 'exec_lua',
    description = 'Execute Lua code in Neovim and return its return value(s) as JSON (several values '
      .. 'become an array). The arguments are available as "..." in the chunk. The current window may '
      .. 'be the agent terminal. Use it for editor state that no other tool reports, e.g. '
      .. '"return vim.diagnostic.get()" for diagnostics (the Lua API keeps its own conventions, such '
      .. 'as 0-based diagnostic lines).',
    inputSchema = obj({
      code = { type = 'string', description = 'Lua chunk, e.g. "return vim.api.nvim_buf_line_count(...)".' },
      args = { type = 'array', items = vim.empty_dict(), description = 'Arguments passed to the chunk as "...".' },
    }, { 'code' }),
  },
  {
    name = 'notify',
    description = 'Show a notification to the user in Neovim (vim.notify).',
    inputSchema = obj({
      message = { type = 'string', description = 'Message text.' },
      level = { type = 'string', enum = { 'info', 'warn', 'error' }, description = 'Default info.' },
    }, { 'message' }),
  },
}

---The tool definitions exposed by the controller (when it has a Neovim address).
---@return { name: string, description: string, inputSchema: table }[]
function M.tools()
  return TOOLS
end

-- Code run in the parent ------------------------------------------------------------------------

-- Calls the installed remote module; reports { missing = true } when it is not installed
-- (first call, or the parent's _G was cleared).
local STUB = [[
local key, tool, args, ctx = ...
local reg = rawget(_G, '__agent_nvim_remote')
local mod = type(reg) == 'table' and type(reg.modules) == 'table' and reg.modules[key]
if not mod then
  return { missing = true }
end
return mod.dispatch(tool, args, ctx)
]]

local INSTALLER = [[
local key, src = ...
local chunk, err = (loadstring or load)(src, '=agent.nvim_mcp.remote')
if not chunk then
  error(err, 0)
end
local mod = chunk()
local reg = rawget(_G, '__agent_nvim_remote')
if type(reg) ~= 'table' then
  reg = {}
  rawset(_G, '__agent_nvim_remote', reg)
end
reg.modules = reg.modules or {}
reg.modules[key] = mod
if mod.setup then
  mod.setup()
end
return true
]]

local function read_file(path)
  local f = io.open(path, 'rb')
  if not f then
    return nil
  end
  local data = f:read('*a')
  f:close()
  return data
end

---Text of remote.lua (next to this file).
---@return string
function M.remote_source()
  local here = debug.getinfo(1, 'S').source:sub(2):match('^(.*)[/\\]') or '.'
  local src = read_file(here .. '/remote.lua')
  if not src then
    error('cannot read ' .. here .. '/remote.lua')
  end
  return src
end

-- Helpers ---------------------------------------------------------------------------------------

---Replace invalid UTF-8 sequences with U+FFFD so the JSON output stays valid.
---@param s string
---@return string
function M.utf8_clean(s)
  if not s:find('[\128-\255]') then
    return s
  end
  local out, i, n, run = {}, 1, #s, 1
  while i <= n do
    local c = s:byte(i)
    local len
    if c < 0x80 then
      len = 1
    elseif c >= 0xC2 and c <= 0xDF then
      len = 2
    elseif c >= 0xE0 and c <= 0xEF then
      len = 3
    elseif c >= 0xF0 and c <= 0xF4 then
      len = 4
    end
    local ok = len ~= nil and i + len - 1 <= n
    if ok and len > 1 then
      for k = 1, len - 1 do
        local b = s:byte(i + k)
        if b < 0x80 or b > 0xBF then
          ok = false
          break
        end
      end
      if ok then
        local b2 = s:byte(i + 1)
        if (c == 0xE0 and b2 < 0xA0) or (c == 0xED and b2 > 0x9F) or (c == 0xF0 and b2 < 0x90)
          or (c == 0xF4 and b2 > 0x8F) then
          ok = false
        end
      end
    end
    if ok then
      i = i + len
    else
      out[#out + 1] = s:sub(run, i - 1)
      out[#out + 1] = '\239\191\189'
      i = i + 1
      run = i
    end
  end
  out[#out + 1] = s:sub(run)
  return table.concat(out)
end

---Pick the parent address: the first candidate that is non-empty and not an unexpanded
---placeholder such as "${NVIM}" or "$NVIM".
---@param ... string|nil candidates in priority order (arg[1], then $NVIM)
---@return string|nil
function M.resolve_address(...)
  for i = 1, select('#', ...) do
    local v = select(i, ...)
    if type(v) == 'string' then
      v = vim.trim(v)
      if v ~= '' and v:sub(1, 1) ~= '$' then
        return v
      end
    end
  end
  return nil
end

local function is_array(v)
  if type(v) ~= 'table' or getmetatable(v) == EMPTY_DICT_MT then
    return false
  end
  local n = 0
  for k in pairs(v) do
    if type(k) ~= 'number' then
      return false
    end
    n = n + 1
  end
  return n == #v
end

local function is_object(v)
  if type(v) ~= 'table' then
    return false
  end
  if getmetatable(v) == EMPTY_DICT_MT or next(v) == nil then
    return true
  end
  return not is_array(v)
end

local function describe_schema(s)
  if s.anyOf then
    local parts = {}
    for _, alt in ipairs(s.anyOf) do
      parts[#parts + 1] = describe_schema(alt)
    end
    return table.concat(parts, ' or ')
  end
  local d = s.type == 'integer' and 'an integer' or s.type == 'array' and 'an array'
    or s.type == 'object' and 'an object' or ('a ' .. s.type)
  if s.enum then
    d = d .. ' (one of ' .. table.concat(s.enum, ', ') .. ')'
  end
  return d
end

---Check (and lightly coerce) one value against the schema subset used by TOOLS.
---@return boolean ok, any value
local function check_value(v, s)
  if s.anyOf then
    for _, alt in ipairs(s.anyOf) do
      local ok, cv = check_value(v, alt)
      if ok then
        return true, cv
      end
    end
    return false
  end
  local t = s.type
  if t == 'integer' then
    if type(v) == 'string' and v:match('^%s*%-?%d+%s*$') then
      v = tonumber(v)
    end
    if type(v) ~= 'number' or v ~= math.floor(v) or math.abs(v) > 2 ^ 53 then
      return false
    end
  elseif t == 'string' then
    if type(v) ~= 'string' then
      return false
    end
  elseif t == 'boolean' then
    if v == 'true' or v == 'false' then
      v = v == 'true'
    end
    if type(v) ~= 'boolean' then
      return false
    end
  elseif t == 'array' then
    if not (is_array(v) or (type(v) == 'table' and next(v) == nil)) then
      return false
    end
  elseif t == 'object' then
    if not is_object(v) then
      return false
    end
  end
  if s.enum and not vim.tbl_contains(s.enum, v) then
    return false
  end
  return true, v
end

---Validate tool arguments. JSON null counts as "not given".
---@param schema table
---@param args any
---@return table|nil args, string|nil err
function M.validate_arguments(schema, args)
  if args == nil or args == vim.NIL then
    args = {}
  end
  if not is_object(args) then
    return nil, 'arguments must be an object'
  end
  local out = {}
  for k, v in pairs(args) do
    local prop = type(k) == 'string' and schema.properties[k] or nil
    if not prop then
      return nil, string.format('unknown argument "%s"', tostring(k))
    end
    if v ~= vim.NIL then
      local ok, cv = check_value(v, prop)
      if not ok then
        return nil, string.format('argument "%s" must be %s', k, describe_schema(prop))
      end
      out[k] = cv
    end
  end
  for _, r in ipairs(schema.required or {}) do
    if out[r] == nil then
      return nil, string.format('missing required argument "%s"', r)
    end
  end
  return out, nil
end

local function tool_result(text, is_error)
  local res = { content = { { type = 'text', text = M.utf8_clean(text) } } }
  if is_error then
    res.isError = true
  end
  return res
end

local function id_key(id)
  return type(id) .. ':' .. tostring(id)
end

local function now_ms()
  return uv.hrtime() / 1e6
end

-- Server ----------------------------------------------------------------------------------------

---@class agent.nvim_mcp.ServerOpts
---@field addr? string              parent Neovim address; nil = no tools
---@field timeout_ms? integer       per tool call (default $AGENT_NVIM_TIMEOUT_MS or 30000)
---@field write fun(line: string)   writes one serialized message (without the newline)
---@field log? fun(msg: string)     diagnostics (stderr in the real process)
---@field agent? string             $AGENT_NVIM_AGENT
---@field session? string           $AGENT_NVIM_SESSION
---@field remote_source? string     override remote.lua text (tests)

---@class agent.nvim_mcp.Server
---@field addr string|nil
---@field timeout_ms integer
---@field client agent.nvim_mcp.RpcClient|nil
---@field closed boolean
local Server = {}
Server.__index = Server

---@param opts agent.nvim_mcp.ServerOpts
---@return agent.nvim_mcp.Server
function M.new(opts)
  local timeout = tonumber(opts.timeout_ms) or tonumber(vim.env.AGENT_NVIM_TIMEOUT_MS) or M.DEFAULT_TIMEOUT_MS
  if timeout <= 0 then
    timeout = M.DEFAULT_TIMEOUT_MS
  end
  local self = setmetatable({
    addr = opts.addr,
    timeout_ms = timeout,
    write = opts.write,
    log = opts.log or function() end,
    ctx = { agent = opts.agent, session = opts.session },
    closed = false,
    client = nil,
    _connect_waiters = nil,
    _inflight = {},
    _remote_src = opts.remote_source,
    _tools = {},
  }, Server)
  if self.addr then
    for _, t in ipairs(TOOLS) do
      self._tools[t.name] = t
    end
  end
  return self
end

function Server:_send(msg)
  local ok, line = pcall(vim.json.encode, msg)
  if not ok then
    self.log('cannot encode response: ' .. tostring(line))
    line = vim.json.encode({
      jsonrpc = '2.0',
      id = msg.id == nil and vim.NIL or msg.id,
      error = { code = -32603, message = 'Internal error: cannot encode response' },
    })
  end
  self.write(line)
end

local function response(id, result)
  return { jsonrpc = '2.0', id = id, result = result }
end

local function error_response(id, code, message)
  return { jsonrpc = '2.0', id = id == nil and vim.NIL or id, error = { code = code, message = message } }
end

---Handle one line of input (one JSON-RPC message or batch).
---@param line string
function Server:handle_line(line)
  if self.closed or line:match('^%s*$') then
    return
  end
  local ok, msg = pcall(vim.json.decode, line)
  if not ok then
    return self:_send(error_response(vim.NIL, -32700, 'Parse error'))
  end
  if type(msg) == 'table' and getmetatable(msg) ~= EMPTY_DICT_MT and vim.islist(msg) then
    return self:_handle_batch(msg)
  end
  self:handle_message(msg, function(resp)
    self:_send(resp)
  end)
end

local function expects_reply(msg)
  if type(msg) ~= 'table' then
    return true
  end
  return msg.method ~= nil and msg.id ~= nil
end

function Server:_handle_batch(list)
  if #list == 0 then
    return self:_send(error_response(vim.NIL, -32600, 'Invalid Request'))
  end
  local expected = 0
  for _, m in ipairs(list) do
    if expects_reply(m) then
      expected = expected + 1
    end
  end
  local replies = {}
  local function collect(resp)
    replies[#replies + 1] = resp
    if #replies == expected then
      self:_send(replies)
    end
  end
  for _, m in ipairs(list) do
    self:handle_message(m, collect)
  end
end

---Handle one decoded JSON-RPC message. `reply` is called at most once, never for
---notifications or client responses.
---@param msg any
---@param reply fun(resp: table)
function Server:handle_message(msg, reply)
  if type(msg) ~= 'table' then
    return reply(error_response(vim.NIL, -32600, 'Invalid Request'))
  end
  local method, id = msg.method, msg.id
  self.log(string.format('recv %s id=%s', tostring(method), tostring(id)))
  if method == nil then
    return -- a response to a request we never sent, or garbage: never answered
  end
  if id == nil then
    return self:_notification(method, msg.params)
  end
  if type(method) ~= 'string' then
    return reply(error_response(id, -32600, 'Invalid Request'))
  end
  local params = msg.params
  if params == vim.NIL then
    params = nil
  end
  if method == 'initialize' then
    return reply(response(id, self:_initialize(params)))
  elseif method == 'ping' then
    return reply(response(id, vim.empty_dict()))
  elseif method == 'tools/list' then
    local list = {}
    for _, t in ipairs(TOOLS) do
      if self._tools[t.name] then
        list[#list + 1] = t
      end
    end
    return reply(response(id, { tools = list }))
  elseif method == 'tools/call' then
    return self:_tools_call(id, params, reply)
  end
  -- Includes server/discover: never answer it with a success result.
  return reply(error_response(id, -32601, 'Method not found'))
end

function Server:_initialize(params)
  local requested = type(params) == 'table' and params.protocolVersion or nil
  local version = M.LATEST_PROTOCOL_VERSION
  if vim.tbl_contains(M.SUPPORTED_PROTOCOL_VERSIONS, requested) then
    version = requested
  end
  local instructions
  if self.addr then
    instructions = 'These tools control the Neovim instance that hosts this agent\'s terminal. '
      .. 'Line numbers in their arguments and results are 1-based and inclusive. read_buffer reads '
      .. 'live buffer contents, including unsaved changes; buffers can be given by number or file '
      .. 'path. An IDE context path starting with nvim://buffer/ is a Neovim buffer (e.g. a '
      .. 'terminal); read it with read_buffer using that path, not with your own file tools. For '
      .. 'editor state that no tool reports directly (the buffer list, windows, cursor, '
      .. 'diagnostics), use eval or exec_lua with the Neovim API. Make file edits with your own '
      .. 'editing tools.'
  else
    instructions = 'Not running inside Neovim ($NVIM is not set), so no Neovim tools are available.'
  end
  return {
    protocolVersion = version,
    capabilities = { tools = vim.empty_dict() },
    serverInfo = { name = 'agent.nvim', version = M.VERSION },
    instructions = instructions,
  }
end

function Server:_notification(method, params)
  if method == 'notifications/cancelled' and type(params) == 'table' and params.requestId ~= nil then
    local call = self._inflight[id_key(params.requestId)]
    if call then
      call.cancelled = true
      self.log('request ' .. tostring(params.requestId) .. ' cancelled by the client')
    end
  end
  -- notifications/initialized and anything else: nothing to do, never answered.
end

function Server:_tools_call(id, params, reply)
  params = type(params) == 'table' and params or {}
  local name = params.name
  local def = type(name) == 'string' and self._tools[name] or nil
  if not def then
    return reply(error_response(id, -32602, 'Unknown tool: ' .. tostring(name)))
  end
  local args, err = M.validate_arguments(def.inputSchema, params.arguments)
  if not args then
    return reply(response(id, tool_result('Invalid arguments for ' .. name .. ': ' .. err, true)))
  end
  local key = id_key(id)
  local call = { cancelled = false }
  self._inflight[key] = call
  self:call_tool(name, args, function(result)
    if self._inflight[key] == call then
      self._inflight[key] = nil
    end
    if call.cancelled or self.closed then
      return
    end
    reply(response(id, result))
  end)
end

---Connect (or reuse the connection) to the parent.
---@param timeout_ms integer
---@param cb fun(err: agent.nvim_mcp.RpcError|nil, client: agent.nvim_mcp.RpcClient|nil)
function Server:_connect(timeout_ms, cb)
  if self.client and self.client:is_connected() then
    return cb(nil, self.client)
  end
  if self._connect_waiters then
    table.insert(self._connect_waiters, cb)
    return
  end
  self._connect_waiters = { cb }
  rpc.connect(self.addr, {
    timeout_ms = timeout_ms,
    on_close = function(reason)
      self.log('connection to Neovim closed: ' .. tostring(reason))
    end,
  }, function(err, client)
    local waiters = self._connect_waiters
    self._connect_waiters = nil
    if client then
      self.client = client
      local attrs = {}
      if self.ctx.agent then
        attrs.agent = self.ctx.agent
      end
      if self.ctx.session then
        attrs.session = self.ctx.session
      end
      client:notify('nvim_set_client_info', {
        'agent.nvim-mcp',
        { major = 0, minor = 1, patch = 0 },
        'remote',
        vim.empty_dict(),
        next(attrs) and attrs or vim.empty_dict(),
      })
    end
    for _, w in ipairs(waiters) do
      w(err, client)
    end
  end)
end

function Server:_remote_key()
  if not self._key then
    self._remote_src = self._remote_src or M.remote_source()
    self._key = M.VERSION .. '-' .. vim.fn.sha256(self._remote_src):sub(1, 16)
  end
  return self._key
end

---Run a tool in the parent: connect, check for a blocking prompt, then dispatch (installing the
---remote module first when it is missing). `done(result)` gets an MCP CallToolResult.
---@param name string
---@param args table validated arguments
---@param done fun(result: table)
function Server:call_tool(name, args, done)
  local deadline = now_ms() + self.timeout_ms
  local function remaining()
    return math.max(1, math.floor(deadline - now_ms()))
  end
  local function fail(err, stage)
    local text
    if err.kind == 'timeout' then
      if stage == 'call' then
        text = string.format('Neovim did not finish %s within %d ms (it may be busy or waiting for input). '
          .. 'The request may still run later.', name, self.timeout_ms)
      else
        text = string.format('Neovim did not respond within %d ms (it may be busy running a blocking command). '
          .. 'Nothing was run.', self.timeout_ms)
      end
    elseif err.kind == 'connect' then
      text = 'Cannot connect to Neovim at ' .. tostring(self.addr) .. ': ' .. err.message
    elseif err.kind == 'closed' then
      text = 'Lost the connection to Neovim: ' .. err.message
    else
      text = err.message
    end
    done(tool_result(text, true))
  end

  local ok, key = pcall(self._remote_key, self)
  if not ok then
    return done(tool_result('agent.nvim: ' .. tostring(key), true))
  end

  self:_connect(remaining(), function(cerr, client)
    if cerr then
      return fail(cerr, 'connect')
    end
    client:request('nvim_get_mode', {}, remaining(), function(merr, mode)
      if merr then
        return fail(merr, 'mode')
      end
      if type(mode) == 'table' and mode.blocking then
        return done(tool_result(string.format(
          'Neovim is waiting for input at a prompt (mode "%s"), so nothing was run. Ask the user to '
            .. 'dismiss it in Neovim (press Enter or Esc), then retry.', tostring(mode.mode)), true))
      end
      local function dispatch(installed)
        client:request('nvim_exec_lua', { STUB, { key, name, args, self.ctx } }, remaining(), function(err, res)
          if err then
            return fail(err, 'call')
          end
          if type(res) == 'table' and res.missing then
            if installed then
              return fail({ kind = 'remote', message = 'agent.nvim: could not install the tool code in Neovim' })
            end
            return client:request('nvim_exec_lua', { INSTALLER, { key, self._remote_src } }, remaining(),
              function(ierr)
                if ierr then
                  return fail(ierr, 'install')
                end
                dispatch(true)
              end)
          end
          if type(res) ~= 'table' then
            return fail({ kind = 'remote', message = 'unexpected result from Neovim: ' .. vim.inspect(res) })
          end
          if res.ok then
            return done(tool_result(type(res.text) == 'string' and res.text or '', false))
          end
          done(tool_result(tostring(res.error), true))
        end)
      end
      dispatch(false)
    end)
  end)
end

---Stop handling input and close the connection to the parent.
function Server:close()
  self.closed = true
  if self.client then
    self.client:close()
    self.client = nil
  end
end

-- Stdio loop ------------------------------------------------------------------------------------

local function stderr_log(msg)
  io.stderr:write('[agent.nvim nvim_mcp] ', msg, '\n')
  io.stderr:flush()
end

local function stdout_write(line)
  io.stdout:write(line, '\n')
  io.stdout:flush()
end

---Serve MCP on stdin/stdout until stdin reaches EOF. Returns normally (exit status 0).
---@param opts { addr?: string, timeout_ms?: integer, agent?: string, session?: string }|nil
function M.run(opts)
  opts = opts or {}
  local debug_log = vim.env.AGENT_NVIM_MCP_DEBUG ~= nil and vim.env.AGENT_NVIM_MCP_DEBUG ~= ''
  local srv = M.new({
    addr = opts.addr,
    timeout_ms = opts.timeout_ms,
    agent = opts.agent or vim.env.AGENT_NVIM_AGENT,
    session = opts.session or vim.env.AGENT_NVIM_SESSION,
    write = stdout_write,
    log = debug_log and stderr_log or function() end,
  })
  if not srv.addr then
    -- Agents log MCP stderr as errors, so stay quiet unless debugging.
    srv.log('no Neovim address (arg 1 or $NVIM); serving zero tools')
  end

  local done = false
  local parts = {}
  local function on_data(chunk)
    local start = 1
    while true do
      local nl = chunk:find('\n', start, true)
      if not nl then
        if start <= #chunk then
          parts[#parts + 1] = chunk:sub(start)
        end
        return
      end
      parts[#parts + 1] = chunk:sub(start, nl - 1)
      local line = table.concat(parts):gsub('\r$', '')
      parts = {}
      vim.schedule(function()
        srv:handle_line(line)
      end)
      start = nl + 1
    end
  end
  local function on_eof()
    local rest = table.concat(parts)
    parts = {}
    vim.schedule(function()
      if rest ~= '' then
        srv:handle_line(rest)
      end
      done = true
    end)
  end

  local kind = uv.guess_handle(0)
  if kind == 'file' then
    on_data(io.stdin:read('*a') or '')
    on_eof()
  else
    local stdin = kind == 'tty' and uv.new_tty(0, true) or uv.new_pipe(false)
    if kind ~= 'tty' then
      stdin:open(0)
    end
    stdin:read_start(function(err, chunk)
      if err or not chunk then
        if err then
          stderr_log('stdin: ' .. tostring(err))
        end
        pcall(stdin.read_stop, stdin)
        return on_eof()
      end
      on_data(chunk)
    end)
  end

  while not done do
    vim.wait(1e9, function()
      return done
    end, 50)
  end
  -- Let calls already in flight answer (stdout may still be open), but exit well before clients
  -- that escalate to SIGTERM (the MCP SDK waits 2 s after closing stdin).
  vim.wait(math.min(srv.timeout_ms, 1500), function()
    return next(srv._inflight) == nil
  end, 10)
  srv:close()
end

return M
