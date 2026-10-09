---@mod agent.nvim_mcp.rpc Async msgpack-RPC client for a Neovim server address
---
--- A small client on vim.uv + vim.mpack with per-request timeouts (vim.rpcrequest has none and
--- blocks the caller's event processing). Works over a Unix socket / named pipe or TCP.
--- All callbacks run in the main loop (vim.schedule), never in a fast context.
local uv = vim.uv

local M = {}

---@class agent.nvim_mcp.RpcError
---@field kind 'connect'|'timeout'|'remote'|'closed'|'encode'
---@field message string

---@class agent.nvim_mcp.Address
---@field type 'pipe'|'tcp'
---@field path? string
---@field host? string
---@field port? integer

---Classify a Neovim server address the way serverstart() does, but treat anything that
---looks like a path as a pipe even when it contains a colon.
---@param addr string
---@return agent.nvim_mcp.Address|nil address, string|nil err
function M.parse_address(addr)
  if type(addr) ~= 'string' or addr == '' then
    return nil, 'empty address'
  end
  local first = addr:sub(1, 1)
  if first == '/' or first == '.' or first == '~' or first == '\\' or addr:match('^%a:[\\/]') then
    return { type = 'pipe', path = addr }, nil
  end
  local host, port = addr:match('^(.+):(%d+)$')
  if host then
    host = host:match('^%[(.*)%]$') or host
    port = tonumber(port)
    if port < 1 or port > 65535 then
      return nil, 'invalid port in ' .. addr
    end
    return { type = 'tcp', host = host, port = port }, nil
  end
  return { type = 'pipe', path = addr }, nil
end

local function is_ip(host)
  return host:match('^%d+%.%d+%.%d+%.%d+$') ~= nil or host:find(':', 1, true) ~= nil
end

local EXT = {
  -- Buffer, Window and Tabpage handles arrive as msgpack EXT types; map them to plain ids,
  -- the same way vim.rpcrequest does.
  [0] = function(_, s) return vim.mpack.decode(s) end,
  [1] = function(_, s) return vim.mpack.decode(s) end,
  [2] = function(_, s) return vim.mpack.decode(s) end,
}

---@param err any msgpack-RPC error object ([type, message] from Neovim)
---@return string
local function error_message(err)
  if type(err) == 'table' then
    if type(err[2]) == 'string' then
      return err[2]
    end
    if type(err.message) == 'string' then
      return err.message
    end
    return vim.inspect(err)
  end
  return tostring(err)
end

---@class agent.nvim_mcp.RpcClient
---@field addr string
---@field private _handle uv.uv_stream_t|nil
---@field private _pending table<integer, {cb:function, timer:uv.uv_timer_t}>
---@field private _next_id integer
---@field private _connected boolean
---@field private _closed boolean
---@field private _opts table
local Client = {}
Client.__index = Client

local function deliver(cb, ...)
  local n, args = select('#', ...), { ... }
  vim.schedule(function()
    cb(unpack(args, 1, n))
  end)
end

local function close_handle(h)
  if h and not h:is_closing() then
    h:close()
  end
end

---Fail every pending request and close the transport. Safe to call more than once and from
---fast contexts.
---@param reason string
function Client:_teardown(reason)
  if self._closed then
    return
  end
  self._closed = true
  self._connected = false
  if self._handle then
    pcall(self._handle.read_stop, self._handle)
    close_handle(self._handle)
  end
  local pending = self._pending
  self._pending = {}
  for _, p in pairs(pending) do
    close_handle(p.timer)
    deliver(p.cb, { kind = 'closed', message = reason }, nil)
  end
  if self._opts.on_close then
    deliver(self._opts.on_close, reason)
  end
end

function Client:_on_message(msg)
  if type(msg) ~= 'table' then
    return
  end
  local mtype = msg[1]
  if mtype == 1 then
    local p = self._pending[msg[2]]
    if not p then
      return -- late response after a timeout
    end
    self._pending[msg[2]] = nil
    close_handle(p.timer)
    local err = msg[3]
    if err ~= nil and err ~= vim.NIL then
      deliver(p.cb, { kind = 'remote', message = error_message(err) }, nil)
    else
      deliver(p.cb, nil, msg[4])
    end
  elseif mtype == 0 then
    -- The peer called us. We expose no methods; answer so it never waits forever.
    local reply = { 1, msg[2], { 0, 'agent.nvim: method not supported: ' .. tostring(msg[3]) }, vim.NIL }
    local ok, data = pcall(vim.mpack.encode, reply)
    if ok and self._handle and not self._closed then
      self._handle:write(data)
    end
  elseif mtype == 2 then
    if self._opts.on_notification then
      deliver(self._opts.on_notification, msg[2], msg[3])
    end
  end
end

function Client:_start_reading()
  local unpacker = vim.mpack.Unpacker({ ext = EXT })
  self._handle:read_start(function(err, chunk)
    if err then
      return self:_teardown('read error: ' .. tostring(err))
    end
    if not chunk then
      return self:_teardown('connection closed by Neovim')
    end
    -- The unpacker is incremental: every chunk must be fed exactly once.
    local pos = 1
    while pos <= #chunk do
      local ok, msg, newpos = pcall(unpacker, chunk, pos)
      if not ok then
        return self:_teardown('msgpack decode error: ' .. tostring(msg))
      end
      pos = newpos
      if msg == nil then
        break
      end
      self:_on_message(msg)
    end
  end)
end

---True while the transport is open.
---@return boolean
function Client:is_connected()
  return self._connected and not self._closed
end

---Send a request. `cb(err, result)` runs in the main loop exactly once.
---A request that timed out may still execute in Neovim later.
---@param method string
---@param params any[]|nil  positional parameters (a Lua list)
---@param timeout_ms integer|nil  nil or <= 0 = no timeout
---@param cb fun(err: agent.nvim_mcp.RpcError|nil, result: any)
function Client:request(method, params, timeout_ms, cb)
  if not self:is_connected() then
    return deliver(cb, { kind = 'closed', message = 'not connected' }, nil)
  end
  local id = self._next_id
  self._next_id = id < 0x7fffffff and id + 1 or 1
  local ok, data = pcall(vim.mpack.encode, { 0, id, method, params or {} })
  if not ok then
    return deliver(cb, { kind = 'encode', message = tostring(data) }, nil)
  end
  local entry = { cb = cb }
  self._pending[id] = entry
  if timeout_ms and timeout_ms > 0 then
    local timer = uv.new_timer()
    entry.timer = timer
    timer:start(timeout_ms, 0, function()
      if self._pending[id] == entry then
        self._pending[id] = nil
        close_handle(timer)
        deliver(cb, { kind = 'timeout', message = string.format('no response to %s within %d ms', method, timeout_ms) }, nil)
      end
    end)
  end
  self._handle:write(data, function(werr)
    if werr then
      self:_teardown('write error: ' .. tostring(werr))
    end
  end)
end

---Send a notification (no response).
---@param method string
---@param params any[]|nil
---@return boolean ok
function Client:notify(method, params)
  if not self:is_connected() then
    return false
  end
  local ok, data = pcall(vim.mpack.encode, { 2, method, params or {} })
  if not ok then
    return false
  end
  self._handle:write(data)
  return true
end

---Blocking request for tests and simple scripts. Must not be called from a fast context.
---@param method string
---@param params any[]|nil
---@param timeout_ms integer|nil
---@return boolean ok, any result_or_err  (err is an agent.nvim_mcp.RpcError)
function Client:request_sync(method, params, timeout_ms)
  local done, rerr, rres = false, nil, nil
  self:request(method, params, timeout_ms, function(err, res)
    done, rerr, rres = true, err, res
  end)
  vim.wait(timeout_ms and timeout_ms + 1000 or 1e9, function()
    return done
  end, 5)
  if not done then
    return false, { kind = 'timeout', message = 'no response to ' .. method }
  end
  if rerr then
    return false, rerr
  end
  return true, rres
end

---Close the connection; pending requests fail with kind 'closed'.
function Client:close()
  self:_teardown('closed by client')
end

---@class agent.nvim_mcp.RpcConnectOpts
---@field timeout_ms? integer                         connect timeout (default 5000)
---@field on_close? fun(reason: string)               runs in the main loop
---@field on_notification? fun(method: string, params: any)

---Connect to a Neovim server address (as in $NVIM / v:servername).
---`cb(err, client)` runs in the main loop exactly once; err is an agent.nvim_mcp.RpcError.
---@param addr string
---@param opts agent.nvim_mcp.RpcConnectOpts|nil
---@param cb fun(err: agent.nvim_mcp.RpcError|nil, client: agent.nvim_mcp.RpcClient|nil)
---@return agent.nvim_mcp.RpcClient|nil client  the (not yet connected) client, nil on a bad address
function M.connect(addr, opts, cb)
  opts = opts or {}
  local parsed, perr = M.parse_address(addr)
  if not parsed then
    deliver(cb, { kind = 'connect', message = perr }, nil)
    return nil
  end
  local self = setmetatable({
    addr = addr,
    _pending = {},
    _next_id = 1,
    _connected = false,
    _closed = false,
    _opts = opts,
  }, Client)

  local finished = false
  local timer = uv.new_timer()
  local function finish(err)
    if finished then
      return
    end
    finished = true
    close_handle(timer)
    if err then
      self._closed = true
      close_handle(self._handle)
      deliver(cb, { kind = 'connect', message = err }, nil)
      return
    end
    self._connected = true
    self:_start_reading()
    deliver(cb, nil, self)
  end
  timer:start(opts.timeout_ms or 5000, 0, function()
    finish('timed out connecting to ' .. addr)
  end)

  local function on_connect(err)
    finish(err and ('cannot connect to ' .. addr .. ': ' .. tostring(err)) or nil)
  end

  if parsed.type == 'pipe' then
    self._handle = uv.new_pipe(false)
    local ok, err = pcall(self._handle.connect, self._handle, parsed.path, on_connect)
    if not ok then
      finish(tostring(err))
    end
  else
    -- Try each resolved address in turn (localhost may resolve to ::1 first).
    local last_err
    local function try_tcp(ips, i)
      if finished then
        return
      end
      if not ips[i] then
        return finish('cannot connect to ' .. addr .. ': ' .. tostring(last_err))
      end
      close_handle(self._handle)
      self._handle = uv.new_tcp()
      local ok, err = pcall(self._handle.connect, self._handle, ips[i], parsed.port, function(cerr)
        if cerr and ips[i + 1] then
          last_err = cerr
          return try_tcp(ips, i + 1)
        end
        on_connect(cerr)
      end)
      if not ok then
        last_err = err
        try_tcp(ips, i + 1)
      end
    end
    if is_ip(parsed.host) then
      try_tcp({ parsed.host }, 1)
    else
      uv.getaddrinfo(parsed.host, tostring(parsed.port), { socktype = 'stream' }, function(err, res)
        if err or not res or not res[1] then
          return finish('cannot resolve ' .. parsed.host .. ': ' .. tostring(err))
        end
        local ips = {}
        for _, r in ipairs(res) do
          ips[#ips + 1] = r.addr
        end
        try_tcp(ips, 1)
      end)
    end
  end
  return self
end

return M
