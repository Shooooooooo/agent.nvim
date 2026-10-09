---@mod agent.net.http HTTP/1.1 server over TCP or a Unix domain socket / named pipe
---
--- Features: persistent (keep-alive) connections with pipelined requests answered in order,
--- Content-Length and chunked request bodies (trailers ignored), `Expect: 100-continue`,
--- fixed-length and streamed (chunked, or close-delimited for HTTP/1.0) responses, and SSE helpers.
---
--- Threading: parsing runs in libuv callbacks (fast context). `on_request` and `res:on_close`
--- callbacks are always invoked on the main loop through vim.schedule, so they may use vim.api.
--- The `res` methods may be called from any context.
local uv = vim.uv
local common = require('agent.net.common')
local log = require('agent.log').scope('http')

local M = {}

M.MAX_HEADER_SIZE = 64 * 1024
M.MAX_BODY_SIZE = 100 * 1024 * 1024

---@type table<integer, string>
M.STATUS_TEXT = {
  [100] = 'Continue', [101] = 'Switching Protocols',
  [200] = 'OK', [201] = 'Created', [202] = 'Accepted', [204] = 'No Content',
  [301] = 'Moved Permanently', [302] = 'Found', [304] = 'Not Modified',
  [400] = 'Bad Request', [401] = 'Unauthorized', [403] = 'Forbidden', [404] = 'Not Found',
  [405] = 'Method Not Allowed', [406] = 'Not Acceptable', [408] = 'Request Timeout', [409] = 'Conflict',
  [411] = 'Length Required', [413] = 'Content Too Large', [415] = 'Unsupported Media Type',
  [417] = 'Expectation Failed', [426] = 'Upgrade Required', [429] = 'Too Many Requests',
  [431] = 'Request Header Fields Too Large',
  [500] = 'Internal Server Error', [501] = 'Not Implemented', [503] = 'Service Unavailable',
  [505] = 'HTTP Version Not Supported',
}

M.constant_time_equals = common.constant_time_equals

-- Response header values must not smuggle extra header lines.
local function clean(v)
  return (tostring(v):gsub('[\r\n]', ''))
end

---@param status integer
---@param headers table<string, string|number|string[]>
---@return string
local function build_head(status, headers)
  local out = { string.format('HTTP/1.1 %d %s\r\n', status, M.STATUS_TEXT[status] or 'Unknown') }
  for name, value in pairs(headers) do
    name = clean(name)
    if type(value) == 'table' then
      for _, v in ipairs(value) do
        out[#out + 1] = name .. ': ' .. clean(v) .. '\r\n'
      end
    elseif value ~= nil and value ~= false then
      out[#out + 1] = name .. ': ' .. clean(value) .. '\r\n'
    end
  end
  out[#out + 1] = '\r\n'
  return table.concat(out)
end

---Copy `headers`, dropping (case-insensitively) the names in `drop`.
---@return table copy, table<string, string> lower_to_name
local function merge_headers(base, extra, drop)
  local out, names = {}, {}
  for _, src in ipairs({ base or {}, extra or {} }) do
    for k, v in pairs(src) do
      local lk = k:lower()
      if not (drop and drop[lk]) then
        if names[lk] and names[lk] ~= k then
          out[names[lk]] = nil
        end
        out[k] = v
        names[lk] = k
      end
    end
  end
  return out, names
end

-- ---------------------------------------------------------------------------
-- Response
-- ---------------------------------------------------------------------------

---@class agent.http.Response
---@field closed boolean true once nothing more can be written (finished, or the connection is gone)
---@field finished boolean true after finish()
---@field headers_sent boolean
---@field streaming boolean
---@field status integer
---@field headers table
---@field keep_alive boolean
local Response = {}
Response.__index = Response

local function new_response(conn, req)
  local ka
  local connection = req.headers['connection']
  if req.version == '1.0' then
    ka = common.has_token(connection, 'keep-alive')
  else
    ka = not common.has_token(connection, 'close')
  end
  return setmetatable({
    _conn = conn,
    _req = req,
    _close_cbs = {},
    _aborted = false,
    status = 200,
    headers = {},
    keep_alive = ka,
    headers_sent = false,
    streaming = false,
    chunked = false,
    finished = false,
    closed = false,
  }, Response)
end

function Response:_write(data)
  local conn = self._conn
  if conn.closed then
    return false
  end
  return common.write(conn.handle, data)
end

---Set the status and headers used by finish() (nothing is sent yet).
---@param status integer
---@param headers table<string, string|number|string[]>|nil
---@return agent.http.Response self
function Response:write_head(status, headers)
  if self.headers_sent then
    log.debug('write_head after the head was sent (ignored)')
    return self
  end
  self.status = status or self.status
  if headers then
    self.headers = merge_headers(self.headers, headers)
  end
  return self
end

---Set one response header before the head is sent.
---@param name string
---@param value string|number|string[]|nil
function Response:set_header(name, value)
  self.headers = merge_headers(self.headers, { [name] = value or false })
end

---Send the whole response. Adds Content-Length (unless 1xx/204/304) and `Connection: close` when
---the connection will not be reused. On a stream, ends it (terminating chunk).
---@param body string|nil
---@return boolean ok false when the response was already finished or the peer is gone
function Response:finish(body)
  if self.finished or self.closed then
    return false
  end
  if self.streaming then
    if body and #body > 0 then
      self:write(body)
    end
    -- A HEAD response is just the head: there is no body to terminate.
    if self._req.method ~= 'HEAD' then
      if self.chunked then
        self:_write('0\r\n\r\n')
      else
        self.keep_alive = false
      end
    end
    self.finished, self.closed = true, true
    self._conn:response_done(self)
    return true
  end
  body = body or ''
  local status = self.status
  local no_body = status < 200 or status == 204 or status == 304
  local h, names = merge_headers(self.headers, nil, { ['transfer-encoding'] = true })
  if no_body then
    body = ''
    if names['content-length'] then
      h[names['content-length']] = nil
    end
  elseif not names['content-length'] then
    h['Content-Length'] = #body
  end
  if names['connection'] and common.has_token(tostring(h[names['connection']]), 'close') then
    self.keep_alive = false
  end
  if self._conn.server.closed then
    self.keep_alive = false
  end
  if not self.keep_alive then
    h[names['connection'] or 'Connection'] = 'close'
  elseif self._req.version == '1.0' then
    h[names['connection'] or 'Connection'] = 'keep-alive'
  end
  local head = build_head(status, h)
  if self._req.method == 'HEAD' or #body == 0 then
    self:_write(head)
  else
    self:_write({ head, body })
  end
  self.headers_sent, self.finished, self.closed = true, true, true
  self._conn:response_done(self)
  return true
end

---Send the head now and keep the response open for write()/sse(). HTTP/1.1 uses chunked
---transfer coding (the connection stays reusable after finish()); HTTP/1.0 is close-delimited.
---@param status integer|nil default: the status from write_head (200)
---@param headers table|nil merged over the headers from write_head
---@return boolean ok
function Response:start_stream(status, headers)
  if self.headers_sent or self.closed then
    return false
  end
  self.status = status or self.status
  local h, names = merge_headers(self.headers, headers, { ['content-length'] = true, ['transfer-encoding'] = true })
  if names['connection'] and common.has_token(tostring(h[names['connection']]), 'close') then
    self.keep_alive = false
  end
  if self._conn.server.closed then
    self.keep_alive = false
  end
  if self._req.version == '1.1' then
    h['Transfer-Encoding'] = 'chunked'
    self.chunked = true
  else
    self.keep_alive = false
  end
  if not self.keep_alive then
    h[names['connection'] or 'Connection'] = 'close'
  end
  self.headers_sent, self.streaming = true, true
  self:_write(build_head(self.status, h))
  if self._req.method == 'HEAD' then
    -- No body for HEAD: end right away (an empty chunked body is just the last-chunk).
    self:finish()
  end
  return true
end

---Write a body chunk on a stream (starts the stream with the pending head if needed).
---@param chunk string
---@return boolean ok
function Response:write(chunk)
  if self.closed then
    return false
  end
  if not self.headers_sent then
    self:start_stream()
    if self.closed then
      return false
    end
  end
  if not self.streaming then
    return false
  end
  if chunk == nil or #chunk == 0 or self._req.method == 'HEAD' then
    -- A zero-length chunk would terminate the chunked body; HEAD responses have no body.
    return true
  end
  if self.chunked then
    return self:_write({ string.format('%x\r\n', #chunk), chunk, '\r\n' })
  end
  return self:_write(chunk)
end

local SSE_HEADERS = { ['Content-Type'] = 'text/event-stream', ['Cache-Control'] = 'no-cache' }

local function ensure_sse(self)
  if not self.headers_sent then
    local _, names = merge_headers(self.headers)
    local extra = {}
    for k, v in pairs(SSE_HEADERS) do
      if not names[k:lower()] then
        extra[k] = v
      end
    end
    self:start_stream(nil, extra)
  end
end

local function one_line(v)
  return (tostring(v):gsub('[\r\n]', ' '))
end

---Send one Server-Sent Event. Multi-line data becomes several `data:` lines. A table is JSON-encoded.
---Starts the stream (200, text/event-stream, no-cache) when needed.
---@param data string|table
---@param opts { event?: string, id?: string|number, retry?: integer }|nil
---@return boolean ok
function Response:sse(data, opts)
  if self.closed then
    return false
  end
  ensure_sse(self)
  opts = opts or {}
  if type(data) == 'table' then
    data = vim.json.encode(data)
  end
  local out = {}
  if opts.event then
    out[#out + 1] = 'event: ' .. one_line(opts.event) .. '\n'
  end
  if opts.id ~= nil then
    out[#out + 1] = 'id: ' .. one_line(opts.id) .. '\n'
  end
  if opts.retry then
    out[#out + 1] = 'retry: ' .. math.floor(tonumber(opts.retry) or 0) .. '\n'
  end
  local text = tostring(data or ''):gsub('\r\n', '\n'):gsub('\r', '\n')
  for _, line in ipairs(vim.split(text, '\n', { plain = true })) do
    out[#out + 1] = 'data: ' .. line .. '\n'
  end
  out[#out + 1] = '\n'
  return self:write(table.concat(out))
end

---Send an SSE comment (`: text`), e.g. as a keep-alive. Clients ignore comments.
---@param text string|nil
---@return boolean ok
function Response:sse_comment(text)
  if self.closed then
    return false
  end
  ensure_sse(self)
  local out = {}
  local s = tostring(text or ''):gsub('\r\n', '\n'):gsub('\r', '\n')
  for _, line in ipairs(vim.split(s, '\n', { plain = true })) do
    out[#out + 1] = (line == '' and ':' or (': ' .. line)) .. '\n'
  end
  out[#out + 1] = '\n'
  return self:write(table.concat(out))
end

---Register `cb()` to run (on the main loop) if the connection goes away before finish():
---the peer disconnected, a socket error, or server:close(). Runs immediately (scheduled)
---when that already happened.
---@param cb fun()
function Response:on_close(cb)
  if self._aborted then
    vim.schedule(cb)
  elseif not self.finished then
    table.insert(self._close_cbs, cb)
  end
end

function Response:_abort()
  if self.finished or self._aborted then
    return
  end
  self._aborted, self.closed = true, true
  local cbs = self._close_cbs
  self._close_cbs = {}
  for _, cb in ipairs(cbs) do
    common.schedule_call(cb, function(err)
      log.error('on_close callback failed: %s', err)
    end)
  end
end

-- ---------------------------------------------------------------------------
-- Connection
-- ---------------------------------------------------------------------------

---@class agent.http.Conn
local Conn = {}
Conn.__index = Conn

local next_conn_id = 0

local function new_conn(server, handle, transport)
  next_conn_id = next_conn_id + 1
  local remote
  if transport == 'tcp' then
    local ok, peer = pcall(handle.getpeername, handle)
    remote = ok and peer or nil
  end
  return setmetatable({
    id = next_conn_id,
    server = server,
    handle = handle,
    transport = transport,
    remote = remote,
    buf = common.buffer(),
    state = 'head',
    closed = false,
    res = nil,
    requests = 0,
  }, Conn)
end

---Reply with an error and close the connection (used for protocol violations).
function Conn:fail(status, message)
  if self.closed then
    return
  end
  log.debug('conn %d: %d %s', self.id, status, message or '')
  self.state = 'closing'
  self.buf:clear()
  local body = (message or M.STATUS_TEXT[status] or 'Error') .. '\n'
  common.write(self.handle, build_head(status, {
    ['Content-Type'] = 'text/plain; charset=utf-8',
    ['Content-Length'] = #body,
    ['Connection'] = 'close',
  }) .. body)
  self:close(true)
end

---@param graceful boolean flush pending writes and send FIN instead of closing at once
function Conn:close(graceful)
  if self.closed then
    return
  end
  self.closed = true
  self.state = 'closing'
  self.server._conns[self.id] = nil
  local res = self.res
  self.res = nil
  if res then
    res:_abort()
  end
  if graceful then
    common.shutdown_close(self.handle)
  else
    pcall(self.handle.read_stop, self.handle)
    common.close_handle(self.handle)
  end
end

function Conn:on_read(err, chunk)
  if self.closed then
    return
  end
  if err then
    log.debug('conn %d: read error %s', self.id, err)
    self:close(false)
    return
  end
  if not chunk then
    -- EOF. HTTP clients do not half-close, so the peer is gone (this is also how an SSE
    -- subscriber that disconnected is detected). Probe connections end here quietly.
    self:close(false)
    return
  end
  self.buf:push(chunk)
  self:process()
end

local function parse_content_length(v)
  local n
  for part in v:gmatch('[^,]+') do
    local d = vim.trim(part)
    if not d:match('^%d+$') or #d > 15 then
      return nil
    end
    local x = tonumber(d)
    if n and n ~= x then
      return nil
    end
    n = x
  end
  return n
end

function Conn:begin_request(head)
  local h, perr = common.parse_head(head)
  if not h then
    return self:fail(400, perr)
  end
  if h.version ~= '1.1' and h.version ~= '1.0' then
    return self:fail(505)
  end
  local server = self.server
  local te, cl = h.headers['transfer-encoding'], h.headers['content-length']
  local req = h --[[@as agent.http.Request]]
  local abs = req.path:match('^%a[%w+.-]*://[^/]*(/.*)$')
  if abs then
    req.path = abs
  elseif req.path:match('^%a[%w+.-]*://[^/]*$') then
    req.path = '/'
  end
  req.query = common.parse_query(req.raw_query)
  req.conn_id = self.id
  req.transport = self.transport
  req.remote = self.remote
  req.body = ''
  self.req = req
  self.body_parts, self.body_len = {}, 0
  if te then
    if cl then
      -- Request smuggling guard (RFC 9112 §6.3): refuse both framings together.
      return self:fail(400, 'both Transfer-Encoding and Content-Length')
    end
    local codings = common.split_list(te)
    if #codings ~= 1 or codings[1]:lower() ~= 'chunked' or h.version ~= '1.1' then
      return self:fail(501, 'unsupported Transfer-Encoding')
    end
    self.state = 'chunk_size'
  else
    local n = 0
    if cl then
      n = parse_content_length(cl)
      if not n then
        return self:fail(400, 'invalid Content-Length')
      end
      if n > server.max_body_size then
        return self:fail(413, 'Request body too large')
      end
    end
    self.remaining = n
    self.state = 'body'
  end
  local expect = req.headers['expect']
  if expect and h.version == '1.1' then
    if expect:lower() ~= '100-continue' then
      return self:fail(417)
    end
    if self.state == 'chunk_size' or (self.remaining > 0 and self.buf.size < self.remaining) then
      common.write(self.handle, 'HTTP/1.1 100 Continue\r\n\r\n')
    end
  end
end

function Conn:dispatch()
  local req = self.req
  self.req, self.body_parts = nil, nil
  self.state = 'dispatched'
  self.requests = self.requests + 1
  local res = new_response(self, req)
  self.res = res
  local handler = self.server.on_request
  common.schedule_call(function()
    if res.closed then
      return -- the peer left before we got to it
    end
    if not handler then
      res:write_head(404, { ['Content-Type'] = 'text/plain' })
      res:finish('Not Found')
      return
    end
    handler(req, res)
  end, function(err)
    log.error('request handler failed for %s %s: %s', req.method, req.path, err)
    if not res.headers_sent and not res.closed then
      res.headers = {}
      res:write_head(500, { ['Content-Type'] = 'text/plain' })
      res:finish('Internal Server Error')
    elseif res.streaming and not res.closed then
      res:finish()
    end
  end)
end

---Parse as many complete requests as the buffer holds (one at a time: the next one waits
---until the current response has been finished).
function Conn:process()
  local server = self.server
  local buf = self.buf
  while not self.closed do
    local st = self.state
    if st == 'head' then
      -- Tolerate stray CRLFs between requests (RFC 9112 §2.2).
      while buf.size >= 2 and buf:peek(2) == '\r\n' do
        buf:skip(2)
      end
      if buf.size == 0 then
        return
      end
      local limit = server.max_header_size + 4
      local pos = buf:find('\r\n\r\n', limit)
      if not pos then
        if buf.size >= limit then
          return self:fail(431)
        end
        -- Reject garbage early instead of waiting for 64 KiB of it.
        local first = buf:peek(16)
        if not first:match('^%u') then
          return self:fail(400, 'malformed request line')
        end
        return
      end
      local head = buf:take(pos - 1)
      buf:skip(4)
      self:begin_request(head)
    elseif st == 'body' then
      if buf.size < self.remaining then
        return
      end
      self.req.body = buf:take(self.remaining)
      self:dispatch()
    elseif st == 'chunk_size' then
      local pos = buf:find('\r\n', 4096)
      if not pos then
        if buf.size >= 4096 then
          return self:fail(400, 'chunk size line too long')
        end
        return
      end
      local line = buf:take(pos - 1)
      buf:skip(2)
      local hex = line:match('^(%x+)[ \t]*$') or line:match('^(%x+)[ \t]*;')
      if not hex or #hex > 12 then
        return self:fail(400, 'invalid chunk size')
      end
      local size = tonumber(hex, 16)
      if size == 0 then
        self.trailer_bytes = 0
        self.state = 'trailer'
      else
        if self.body_len + size > server.max_body_size then
          return self:fail(413, 'Request body too large')
        end
        self.chunk_remaining = size
        self.state = 'chunk_data'
      end
    elseif st == 'chunk_data' then
      if buf.size < self.chunk_remaining + 2 then
        return
      end
      local data = buf:take(self.chunk_remaining)
      if buf:take(2) ~= '\r\n' then
        return self:fail(400, 'malformed chunk')
      end
      self.body_parts[#self.body_parts + 1] = data
      self.body_len = self.body_len + #data
      self.state = 'chunk_size'
    elseif st == 'trailer' then
      local pos = buf:find('\r\n', server.max_header_size + 2)
      if not pos then
        if buf.size >= server.max_header_size then
          return self:fail(431)
        end
        return
      end
      local line = buf:take(pos - 1)
      buf:skip(2)
      if line == '' then
        self.req.body = table.concat(self.body_parts)
        self:dispatch()
      else
        -- Trailer fields are accepted and ignored.
        self.trailer_bytes = self.trailer_bytes + #line
        if self.trailer_bytes > server.max_header_size then
          return self:fail(431)
        end
      end
    elseif st == 'dispatched' then
      -- A response is in flight; the next request stays buffered until it is finished.
      if buf.size > server.max_header_size + server.max_body_size + 65536 then
        log.debug('conn %d: too much pipelined data, closing', self.id)
        self:close(false)
      end
      return
    else
      return
    end
  end
end

---Called by Response:finish().
function Conn:response_done(res)
  if self.res ~= res or self.closed then
    return
  end
  self.res = nil
  if not res.keep_alive or self.server.closed then
    self:close(true)
    return
  end
  self.state = 'head'
  self:process()
end

-- ---------------------------------------------------------------------------
-- Server
-- ---------------------------------------------------------------------------

---@class agent.http.Request
---@field method string
---@field path string          request path without the query string (absolute-form targets reduced to their path)
---@field target string        raw request-target
---@field raw_query string|nil
---@field query table<string, string> decoded query parameters
---@field version string       '1.1' | '1.0'
---@field headers table<string, string> lowercased names; repeated fields joined with ', '
---@field header_list table    { {name, value}, ... } as received
---@field body string          full body ('' when none)
---@field conn_id integer      id of the underlying connection (same id = same keep-alive socket)
---@field transport 'tcp'|'pipe'
---@field remote table|nil     TCP peer { ip, port, family }

---@class agent.http.Server
---@field port integer|nil      TCP port (tcp listener)
---@field host string|nil       TCP host
---@field path string|nil       socket path (pipe listener)
---@field closed boolean
local Server = {}
Server.__index = Server

---@class agent.http.ListenOpts
---@field tcp { host?: string, port?: integer|table }|nil  host default '127.0.0.1'; port 0 = ephemeral, or a {min,max} range
---@field pipe string|nil          Unix socket path (or `\\.\pipe\name` on Windows)
---@field pipe_mode integer|nil    socket file mode (default 0600)
---@field on_request fun(req: agent.http.Request, res: agent.http.Response)
---@field max_header_size integer|nil default 64 KiB
---@field max_body_size integer|nil   default 100 MiB

---Start a server.
---@param opts agent.http.ListenOpts
---@return agent.http.Server|nil server, string|nil err
function M.listen(opts)
  vim.validate('opts', opts, 'table')
  if not opts.tcp and not opts.pipe then
    return nil, 'http.listen: one of tcp or pipe is required'
  end
  local server = setmetatable({
    on_request = opts.on_request,
    max_header_size = opts.max_header_size or M.MAX_HEADER_SIZE,
    max_body_size = opts.max_body_size or M.MAX_BODY_SIZE,
    closed = false,
    _conns = {},
  }, Server)

  local handle, err
  local function on_connection(lerr)
    if lerr then
      log.debug('listen error: %s', lerr)
      return
    end
    if server.closed then
      return
    end
    local client = server.transport == 'tcp' and uv.new_tcp() or uv.new_pipe(false)
    if not client then
      return
    end
    local ok = pcall(server.handle.accept, server.handle, client)
    if not ok then
      common.close_handle(client)
      return
    end
    if server.transport == 'tcp' then
      pcall(client.nodelay, client, true)
    end
    local conn = new_conn(server, client, server.transport)
    server._conns[conn.id] = conn
    local rok = pcall(client.read_start, client, function(rerr, chunk)
      conn:on_read(rerr, chunk)
    end)
    if not rok then
      conn:close(false)
    end
  end

  if opts.pipe then
    server.transport = 'pipe'
    local created
    handle, err, created = common.listen_pipe(opts.pipe, on_connection, { mode = opts.pipe_mode })
    if not handle then
      common.remove_created_dirs(created)
      return nil, err
    end
    server.path = opts.pipe
    server._created_dirs = created
  else
    server.transport = 'tcp'
    local host = opts.tcp.host or '127.0.0.1'
    local port
    handle, port = common.listen_tcp(host, opts.tcp.port or 0, on_connection)
    if not handle then
      return nil, string.format('listen %s:%s: %s', host, vim.inspect(opts.tcp.port or 0), tostring(port))
    end
    server.host, server.port = host, port
  end
  server.handle = handle
  log.debug('listening on %s', server.path or (server.host .. ':' .. server.port))
  return server, nil
end

---Number of open connections.
---@return integer
function Server:connection_count()
  local n = 0
  for _ in pairs(self._conns) do
    n = n + 1
  end
  return n
end

---Stop listening and close every connection. Open streams are ended gracefully (terminating
---chunk, then FIN) and their `res:on_close` callbacks run. A pipe's socket file is removed (and
---its directory, when listen() created it).
function Server:close()
  if self.closed then
    return
  end
  self.closed = true
  common.close_handle(self.handle) -- libuv unlinks a bound pipe path here
  if self.path and not common.is_windows_pipe(self.path) then
    local st = uv.fs_lstat(self.path)
    if st and st.type == 'socket' then
      pcall(uv.fs_unlink, self.path)
    end
    common.remove_created_dirs(self._created_dirs)
  end
  local conns = self._conns
  self._conns = {}
  for _, conn in pairs(conns) do
    local res = conn.res
    if res and res.streaming and res.chunked and not res.closed then
      common.write(conn.handle, '0\r\n\r\n')
    end
    conn:close(true)
  end
end

return M
