---@mod agent.net.websocket RFC 6455 WebSocket server over TCP
---
--- Handshake validation follows claude-opencode.md §3.3 (in order: request line 404, Upgrade 400,
--- Connection 400, Sec-WebSocket-Key 400, Sec-WebSocket-Version 400, authenticate 401,
--- Origin 403). The first client-offered subprotocol we support is echoed (default `mcp`;
--- nothing is sent when none was offered). Extensions are always declined.
---
--- Frames: masked client frames (unmasked ones close with 1002 unless `require_mask = false`),
--- fragmentation with interleaved control frames, ping -> pong with the same payload, close
--- handshake echoing the peer's code, UTF-8 validation of text (1007), protocol errors (1002),
--- messages over `max_message_size` (default 100 MiB, 1009). Server frames are unmasked, FIN=1.
---
--- Threading: frames are parsed in libuv callbacks. `authenticate`, `on_open`, `on_message` and
--- `on_close` are always called on the main loop (vim.schedule), in order, so they may use vim.api.
--- `conn:send()` / `conn:close()` may be called from any context.
local uv = vim.uv
local bit = require('bit')
local common = require('agent.net.common')
local sha1 = require('agent.crypto.sha1')
local log = require('agent.log').scope('websocket')

local band, bor, bxor, rshift = bit.band, bit.bor, bit.bxor, bit.rshift

local M = {}

M.GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11'
M.MAX_MESSAGE_SIZE = 100 * 1024 * 1024
M.MAX_HEADER_SIZE = 16 * 1024
M.HANDSHAKE_TIMEOUT_MS = 10000
M.CLOSE_TIMEOUT_MS = 1000

M.OP = { CONTINUATION = 0x0, TEXT = 0x1, BINARY = 0x2, CLOSE = 0x8, PING = 0x9, PONG = 0xA }
M.CLOSE = {
  NORMAL = 1000, GOING_AWAY = 1001, PROTOCOL_ERROR = 1002, UNSUPPORTED_DATA = 1003,
  NO_STATUS = 1005, ABNORMAL = 1006, INVALID_PAYLOAD = 1007, POLICY_VIOLATION = 1008,
  MESSAGE_TOO_BIG = 1009, INTERNAL_ERROR = 1011,
}

M.constant_time_equals = common.constant_time_equals

---An `authenticate` function for a shared-secret header (claude-opencode.md §3.3): the header
---must be present, 10..500 characters long, and equal to `token` (constant-time compare).
---@param header string header name, any case (e.g. 'X-Claude-Code-Ide-Authorization')
---@param token string|fun(): string the expected value, or a function returning it
---@return fun(headers: table<string, string>): boolean, string|nil
function M.token_auth(header, token)
  local key = header:lower()
  return function(headers)
    local got = headers[key]
    if not got then
      return false, 'Missing authentication header'
    end
    if #got < 10 or #got > 500 then
      return false, 'Invalid authentication token'
    end
    local expected = type(token) == 'function' and token() or token
    if not common.constant_time_equals(got, expected) then
      return false, 'Invalid authentication token'
    end
    return true
  end
end

---Sec-WebSocket-Accept for a Sec-WebSocket-Key.
---@param key string
---@return string
function M.accept_key(key)
  return vim.base64.encode(sha1.digest(key .. M.GUID))
end

-- ---------------------------------------------------------------------------
-- Framing
-- ---------------------------------------------------------------------------

local has_ffi, ffi = pcall(require, 'ffi')

local function unmask_lua(payload, mask)
  local m1, m2, m3, m4 = mask:byte(1, 4)
  local m = { [0] = m1, m2, m3, m4 }
  local out, n = {}, #payload
  local char, byte = string.char, string.byte
  -- Slices of 4096 keep unpack() well below LuaJIT's C stack limit.
  for i = 1, n, 4096 do
    local j = math.min(i + 4095, n)
    local bytes = { byte(payload, i, j) }
    for k = 1, #bytes do
      bytes[k] = bxor(bytes[k], m[(i + k - 2) % 4])
    end
    out[#out + 1] = char(unpack(bytes))
  end
  return table.concat(out)
end

local unmask_ffi
if has_ffi then
  unmask_ffi = function(payload, mask)
    local n = #payload
    local words = math.floor(n / 4)
    local buf = ffi.new('uint8_t[?]', words * 4 + 4)
    ffi.copy(buf, payload, n)
    local m32 = ffi.cast('const int32_t*', ffi.cast('const char*', mask))[0]
    local w = ffi.cast('int32_t*', buf)
    for i = 0, words - 1 do
      w[i] = bxor(w[i], m32)
    end
    for i = words * 4, n - 1 do
      buf[i] = bxor(buf[i], mask:byte(i % 4 + 1))
    end
    return ffi.string(buf, n)
  end
end

---XOR `payload` with the 4-byte `mask` (RFC 6455 §5.3).
---@param payload string
---@param mask string
---@param force_lua boolean|nil
---@return string
function M.unmask(payload, mask, force_lua)
  if #payload == 0 then
    return payload
  end
  if unmask_ffi and not force_lua and #payload >= 64 then
    return unmask_ffi(payload, mask)
  end
  return unmask_lua(payload, mask)
end

---Encode a frame header. Server frames are never masked.
---@param opcode integer
---@param len integer
---@param fin boolean|nil default true
---@param mask string|nil 4 bytes (only for building client frames, e.g. in tests)
---@return string
function M.frame_header(opcode, len, fin, mask)
  local b1 = bor(fin == false and 0 or 0x80, opcode)
  local mbit = mask and 0x80 or 0
  local h
  if len < 126 then
    h = string.char(b1, bor(mbit, len))
  elseif len < 65536 then
    h = string.char(b1, bor(mbit, 126), rshift(len, 8), band(len, 255))
  else
    local hi = math.floor(len / 4294967296)
    local lo = len - hi * 4294967296
    h = string.char(b1, bor(mbit, 127),
      band(rshift(hi, 24), 255), band(rshift(hi, 16), 255), band(rshift(hi, 8), 255), band(hi, 255),
      band(rshift(lo, 24), 255), band(rshift(lo, 16), 255), band(rshift(lo, 8), 255), band(lo, 255))
  end
  return mask and (h .. mask) or h
end

local function close_payload(code, reason)
  if not code then
    return ''
  end
  reason = reason or ''
  if #reason > 123 then
    reason = reason:sub(1, 123)
  end
  return string.char(band(rshift(code, 8), 255), band(code, 255)) .. reason
end

local function valid_close_code(code)
  return (code >= 1000 and code <= 1003) or (code >= 1007 and code <= 1014) or (code >= 3000 and code <= 4999)
end

-- ---------------------------------------------------------------------------
-- Connection
-- ---------------------------------------------------------------------------

---@class agent.ws.Conn
---@field id integer
---@field headers table<string, string> request headers, lowercased names
---@field path string request path (with query)
---@field protocol string|nil negotiated subprotocol
---@field remote table|nil TCP peer { ip, port, family }
---@field data table free slot for the owner
---@field state 'handshake'|'open'|'closing'|'closed'
local Conn = {}
Conn.__index = Conn

local next_id = 0

local function new_conn(server, handle)
  next_id = next_id + 1
  local ok, peer = pcall(handle.getpeername, handle)
  return setmetatable({
    id = next_id,
    server = server,
    handle = handle,
    remote = ok and peer or nil,
    buf = common.buffer(),
    state = 'handshake',
    headers = {},
    path = '/',
    data = {},
    last_seen = uv.now(),
    _opened = false,
  }, Conn)
end

---@return boolean
function Conn:is_open()
  return self.state == 'open'
end

function Conn:_send_frame(opcode, payload)
  payload = payload or ''
  local header = M.frame_header(opcode, #payload)
  if #payload == 0 then
    return common.write(self.handle, header)
  end
  return common.write(self.handle, { header, payload })
end

---Send a text message (one unfragmented frame).
---@param text string
---@return boolean ok, string|nil err
function Conn:send(text)
  if self.state ~= 'open' then
    return false, 'connection is ' .. self.state
  end
  if type(text) ~= 'string' then
    return false, 'text must be a string'
  end
  if not self:_send_frame(M.OP.TEXT, text) then
    return false, 'write failed'
  end
  return true, nil
end

---Send a binary message.
---@param data string
---@return boolean ok, string|nil err
function Conn:send_binary(data)
  if self.state ~= 'open' then
    return false, 'connection is ' .. self.state
  end
  if not self:_send_frame(M.OP.BINARY, data) then
    return false, 'write failed'
  end
  return true, nil
end

---Send a ping (payload at most 125 bytes).
---@param payload string|nil
---@return boolean ok
function Conn:ping(payload)
  if self.state ~= 'open' then
    return false
  end
  return self:_send_frame(M.OP.PING, (payload or ''):sub(1, 125))
end

---Close the TCP connection now and report on_close once.
---@param graceful boolean flush queued writes and send FIN first
function Conn:_finalize(graceful)
  if self.state == 'closed' then
    return
  end
  local was_open = self._opened
  self.state = 'closed'
  self.server._conns[self.id] = nil
  self.server._handshakes[self.id] = nil
  if self._timer then
    self._timer:stop()
    common.close_handle(self._timer)
    self._timer = nil
  end
  self.buf:clear()
  self._frag = nil
  if graceful then
    common.shutdown_close(self.handle, M.CLOSE_TIMEOUT_MS)
  else
    pcall(self.handle.read_stop, self.handle)
    common.close_handle(self.handle)
  end
  if was_open then
    local code, reason
    if self._recv_code then
      code, reason = self._recv_code, self._recv_reason
    elseif self._sent_code then
      code, reason = self._sent_code, self._sent_reason
    else
      code, reason = M.CLOSE.ABNORMAL, ''
    end
    self.close_code, self.close_reason = code, reason
    local on_close = self.server.opts.on_close
    common.schedule_call(on_close, function(err)
      log.error('on_close failed: %s', err)
    end, self, code, reason)
  end
end

local function start_timer(self, ms, fn)
  if self._timer then
    self._timer:stop()
  else
    self._timer = uv.new_timer()
  end
  self._timer:start(ms, 0, fn)
end

---Start the closing handshake: send Close(code, reason), then drop TCP when the peer answers
---or after about 1 s.
---@param code integer|nil default 1000
---@param reason string|nil
function Conn:close(code, reason)
  if self.state == 'handshake' then
    self:_finalize(false)
    return
  end
  if self.state ~= 'open' then
    return
  end
  code = code or M.CLOSE.NORMAL
  self.state = 'closing'
  self._sent_code, self._sent_reason = code, reason or ''
  self:_send_frame(M.OP.CLOSE, close_payload(code, reason))
  start_timer(self, M.CLOSE_TIMEOUT_MS, function()
    self:_finalize(false)
  end)
end

---Fail the connection (RFC 6455 §7.1.7): send Close(code) and drop TCP without waiting.
function Conn:_fail(code, reason)
  log.debug('conn %d: failing with %d %s', self.id, code, reason or '')
  if self.state == 'open' then
    self._sent_code, self._sent_reason = code, reason or ''
    self:_send_frame(M.OP.CLOSE, close_payload(code, reason))
  end
  self:_finalize(true)
end

function Conn:_deliver(opcode, payload)
  if opcode == M.OP.TEXT and not common.valid_utf8(payload) then
    return self:_fail(M.CLOSE.INVALID_PAYLOAD, 'invalid UTF-8')
  end
  local on_message = self.server.opts.on_message
  common.schedule_call(on_message, function(err)
    log.error('on_message failed: %s', err)
  end, self, payload, opcode == M.OP.BINARY)
end

function Conn:_on_control(opcode, payload)
  if opcode == M.OP.PING then
    if self.state == 'open' then
      self:_send_frame(M.OP.PONG, payload)
    end
  elseif opcode == M.OP.PONG then
    self.last_pong = uv.now()
  else -- CLOSE
    local code, reason
    if #payload == 0 then
      code, reason = M.CLOSE.NO_STATUS, ''
    elseif #payload == 1 then
      return self:_fail(M.CLOSE.PROTOCOL_ERROR, 'bad close payload')
    else
      local b1, b2 = payload:byte(1, 2)
      code = b1 * 256 + b2
      reason = payload:sub(3)
      if not valid_close_code(code) then
        return self:_fail(M.CLOSE.PROTOCOL_ERROR, 'invalid close code')
      end
      if not common.valid_utf8(reason) then
        return self:_fail(M.CLOSE.INVALID_PAYLOAD, 'invalid UTF-8 in close reason')
      end
    end
    self._recv_code, self._recv_reason = code, reason
    if self.state == 'open' then
      -- Echo the peer's code, then close TCP (the server closes first, §7.1.1).
      local echo = code ~= M.CLOSE.NO_STATUS and code or nil
      self._sent_code, self._sent_reason = echo, reason
      self:_send_frame(M.OP.CLOSE, close_payload(echo))
    end
    self:_finalize(true)
  end
end

---Parse and dispatch every complete frame in the buffer.
function Conn:_process_frames()
  local buf = self.buf
  local opts = self.server.opts
  local max = self.server.max_message_size
  while self.state == 'open' or self.state == 'closing' do
    if buf.size < 2 then
      return
    end
    local hdr = buf:peek(14)
    local b1, b2 = hdr:byte(1, 2)
    local fin = band(b1, 0x80) ~= 0
    local opcode = band(b1, 0x0f)
    local masked = band(b2, 0x80) ~= 0
    local len = band(b2, 0x7f)
    local hlen = 2
    if band(b1, 0x70) ~= 0 then
      return self:_fail(M.CLOSE.PROTOCOL_ERROR, 'reserved bits set')
    end
    if opcode >= 0x3 and opcode <= 0x7 or opcode > 0xA then
      return self:_fail(M.CLOSE.PROTOCOL_ERROR, 'unknown opcode')
    end
    local control = opcode >= 0x8
    if control and (not fin or len > 125) then
      return self:_fail(M.CLOSE.PROTOCOL_ERROR, 'invalid control frame')
    end
    if len == 126 then
      if #hdr < 4 then
        return
      end
      local x1, x2 = hdr:byte(3, 4)
      len = x1 * 256 + x2
      hlen = 4
    elseif len == 127 then
      if #hdr < 10 then
        return
      end
      local x = { hdr:byte(3, 10) }
      if x[1] >= 0x80 then
        return self:_fail(M.CLOSE.PROTOCOL_ERROR, 'invalid length')
      end
      len = 0
      for i = 1, 8 do
        len = len * 256 + x[i]
      end
      hlen = 10
    end
    if not masked then
      if opts.require_mask ~= false then
        return self:_fail(M.CLOSE.PROTOCOL_ERROR, 'unmasked client frame')
      end
      log.debug('conn %d: accepting an unmasked client frame', self.id)
    end
    if not control then
      local pending = self._frag and self._frag.len or 0
      if pending + len > max then
        return self:_fail(M.CLOSE.MESSAGE_TOO_BIG, 'message too big')
      end
    end
    local total = hlen + (masked and 4 or 0) + len
    if buf.size < total then
      return
    end
    local header = buf:take(hlen + (masked and 4 or 0))
    local payload = buf:take(len)
    if masked then
      payload = M.unmask(payload, header:sub(-4))
    end
    self.last_seen = uv.now()
    -- After our Close, data frames are discarded while we wait for the peer's Close.
    local discard = self.state == 'closing' and not control
    if discard then
      self._frag = nil
    elseif control then
      self:_on_control(opcode, payload)
    elseif opcode == M.OP.CONTINUATION then
      local frag = self._frag
      if not frag then
        return self:_fail(M.CLOSE.PROTOCOL_ERROR, 'unexpected continuation frame')
      end
      frag.parts[#frag.parts + 1] = payload
      frag.len = frag.len + #payload
      if fin then
        self._frag = nil
        self:_deliver(frag.opcode, table.concat(frag.parts))
      end
    else
      if self._frag then
        return self:_fail(M.CLOSE.PROTOCOL_ERROR, 'expected a continuation frame')
      end
      if fin then
        self:_deliver(opcode, payload)
      else
        self._frag = { opcode = opcode, parts = { payload }, len = #payload }
      end
    end
  end
end

-- ---------------------------------------------------------------------------
-- Handshake
-- ---------------------------------------------------------------------------

local REJECT_TEXT = {
  [400] = 'Bad Request', [401] = 'Unauthorized', [403] = 'Forbidden', [404] = 'Not Found',
  [426] = 'Upgrade Required', [500] = 'Internal Server Error', [503] = 'Service Unavailable',
}

function Conn:_reject(status, message, extra_headers)
  log.debug('conn %d: handshake rejected: %d %s', self.id, status, message or '')
  local body = message or REJECT_TEXT[status] or 'Error'
  local head = {
    string.format('HTTP/1.1 %d %s', status, REJECT_TEXT[status] or 'Error'),
    'Content-Type: text/plain',
    'Content-Length: ' .. #body,
    'Connection: close',
  }
  for k, v in pairs(extra_headers or {}) do
    head[#head + 1] = k .. ': ' .. v
  end
  self.state = 'closing'
  self.buf:clear()
  pcall(self.handle.read_stop, self.handle)
  common.write(self.handle, table.concat(head, '\r\n') .. '\r\n\r\n' .. body)
  self:_finalize(true)
end

local function choose_protocol(offered, supported)
  if type(supported) == 'function' then
    return supported(offered)
  end
  for _, p in ipairs(offered) do
    for _, s in ipairs(supported or {}) do
      if p == s then
        return p
      end
    end
  end
  return nil
end

---The protocol-level checks that need no callbacks (§3.3 rows 1-5).
---@return integer|nil status, string|nil message, table|nil extra_headers
local function validate_upgrade(h)
  if not h or h.method ~= 'GET' or h.version ~= '1.1' then
    return 404, 'WebSocket endpoint not found'
  end
  local headers = h.headers
  if not common.has_token(headers['upgrade'], 'websocket') then
    return 400, 'Bad WebSocket upgrade request: missing or invalid Upgrade header'
  end
  if not common.has_token(headers['connection'], 'upgrade') then
    return 400, 'Bad WebSocket upgrade request: missing or invalid Connection header'
  end
  local key = headers['sec-websocket-key']
  if not key or #key ~= 24 or not key:match('^[A-Za-z0-9+/]+==$') then
    return 400, 'Bad WebSocket upgrade request: missing or invalid Sec-WebSocket-Key'
  end
  if headers['sec-websocket-version'] ~= '13' then
    return 400, 'Bad WebSocket upgrade request: unsupported Sec-WebSocket-Version', { ['Sec-WebSocket-Version'] = '13' }
  end
  return nil
end

function Conn:_complete_handshake(h)
  local server = self.server
  local opts = server.opts
  if self.state ~= 'handshake' then
    return
  end
  if server.closed then
    return self:_reject(503, 'Server shutting down')
  end
  local headers = h.headers
  if opts.authenticate then
    local ok, aok, reason, status = pcall(opts.authenticate, headers, h)
    if not ok then
      log.error('authenticate failed: %s', aok)
      return self:_reject(500, 'Internal Server Error')
    end
    if not aok then
      return self:_reject(status or 401, reason or 'Unauthorized')
    end
  end
  local origin = headers['origin']
  if origin then
    local allow = opts.allow_origin
    if type(allow) == 'function' then
      local ok, res = pcall(allow, origin, headers)
      allow = ok and res
    end
    if not allow then
      return self:_reject(403, 'Forbidden: Origin not allowed')
    end
  end
  if self.state ~= 'handshake' then
    return -- a callback above ran the event loop and the peer went away meanwhile
  end
  local offered = common.split_list(headers['sec-websocket-protocol'])
  local protocol = #offered > 0 and choose_protocol(offered, opts.protocols or { 'mcp' }) or nil
  local lines = {
    'HTTP/1.1 101 Switching Protocols',
    'Upgrade: websocket',
    'Connection: Upgrade',
    'Sec-WebSocket-Accept: ' .. M.accept_key(headers['sec-websocket-key']),
  }
  if protocol then
    lines[#lines + 1] = 'Sec-WebSocket-Protocol: ' .. protocol
  end
  common.write(self.handle, table.concat(lines, '\r\n') .. '\r\n\r\n')
  if self._timer then
    self._timer:stop()
  end
  self.protocol = protocol
  self.state = 'open'
  self._opened = true
  self.last_seen = uv.now()
  server._handshakes[self.id] = nil
  server._conns[self.id] = self
  if opts.on_open then
    local ok, err = xpcall(opts.on_open, debug.traceback, self)
    if not ok then
      log.error('on_open failed: %s', err)
    end
  end
  if self.state == 'open' then
    self:_process_frames()
  end
end

function Conn:_process_handshake()
  local server = self.server
  local limit = server.max_header_size + 4
  local pos = self.buf:find('\r\n\r\n', limit)
  if not pos then
    if self.buf.size >= limit then
      self:_reject(400, 'Bad WebSocket upgrade request: header block too large')
    end
    return
  end
  local head = self.buf:take(pos - 1)
  self.buf:skip(4)
  local h, perr = common.parse_head(head)
  if not h and perr ~= 'malformed request line' then
    return self:_reject(400, 'Bad WebSocket upgrade request: ' .. perr)
  end
  local status, message, extra = validate_upgrade(h)
  if status then
    return self:_reject(status, message, extra)
  end
  self.headers = h.headers
  self.path = h.target
  -- Finish on the main loop (authenticate may use editor state); bytes that arrive in the
  -- meantime stay buffered.
  self._authenticating = true
  vim.schedule(function()
    self:_complete_handshake(h)
  end)
end

function Conn:_on_read(err, chunk)
  if self.state == 'closed' then
    return
  end
  if err or not chunk then
    self:_finalize(false)
    return
  end
  self.buf:push(chunk)
  if self.state == 'handshake' then
    if not self._authenticating then
      self:_process_handshake()
    elseif self.buf.size > self.server.max_message_size + 65536 then
      self:_finalize(false)
    end
  else
    self:_process_frames()
  end
end

-- ---------------------------------------------------------------------------
-- Server
-- ---------------------------------------------------------------------------

---@class agent.ws.Server
---@field host string
---@field port integer
---@field closed boolean
local Server = {}
Server.__index = Server

---@class agent.ws.ListenOpts
---@field host string|nil default '127.0.0.1'
---@field port integer|table|nil 0 (default) = ephemeral; or a {min,max} range tried randomly
---@field authenticate nil|fun(headers: table<string,string>, request: table): boolean, string|nil, integer|nil  return ok, reason, status (default 401)
---@field allow_origin nil|boolean|fun(origin: string, headers: table): boolean  default false: an Origin header gets 403
---@field protocols string[]|nil subprotocols we accept, in preference of the client's order (default { 'mcp' })
---@field on_open nil|fun(conn: agent.ws.Conn)
---@field on_message nil|fun(conn: agent.ws.Conn, text: string, is_binary: boolean)
---@field on_close nil|fun(conn: agent.ws.Conn, code: integer, reason: string)
---@field ping_interval_ms integer|false|nil default 30000; a client silent for 2 intervals is closed (1001)
---@field max_message_size integer|nil default 100 MiB
---@field max_header_size integer|nil default 16 KiB
---@field handshake_timeout_ms integer|nil default 10000
---@field require_mask boolean|nil default true

---Start a WebSocket server.
---@param opts agent.ws.ListenOpts
---@return agent.ws.Server|nil server, string|nil err
function M.listen(opts)
  vim.validate('opts', opts, 'table')
  local server = setmetatable({
    opts = opts,
    host = opts.host or '127.0.0.1',
    closed = false,
    max_message_size = opts.max_message_size or M.MAX_MESSAGE_SIZE,
    max_header_size = opts.max_header_size or M.MAX_HEADER_SIZE,
    _conns = {},
    _handshakes = {},
  }, Server)

  local handle, port
  handle, port = common.listen_tcp(server.host, opts.port or 0, function(lerr)
    if lerr or server.closed then
      return
    end
    local client = uv.new_tcp()
    if not client then
      return
    end
    if not pcall(server.handle.accept, server.handle, client) then
      common.close_handle(client)
      return
    end
    pcall(client.nodelay, client, true)
    local conn = new_conn(server, client)
    server._handshakes[conn.id] = conn
    start_timer(conn, opts.handshake_timeout_ms or M.HANDSHAKE_TIMEOUT_MS, function()
      if conn.state == 'handshake' then
        log.debug('conn %d: handshake timeout', conn.id)
        conn:_finalize(false)
      end
    end)
    if not pcall(client.read_start, client, function(err, chunk)
      conn:_on_read(err, chunk)
    end) then
      conn:_finalize(false)
    end
  end)
  if not handle then
    return nil, string.format('listen %s:%s: %s', server.host, vim.inspect(opts.port or 0), tostring(port))
  end
  server.handle, server.port = handle, port

  local interval = opts.ping_interval_ms
  if interval == nil then
    interval = 30000
  end
  if interval and interval > 0 then
    local last_tick = uv.now()
    server._ping_timer = uv.new_timer()
    server._ping_timer:start(interval, interval, function()
      local now = uv.now()
      local slept = now - last_tick > interval * 1.5
      last_tick = now
      for _, conn in pairs(server._conns) do
        if conn.state == 'open' then
          if slept then
            -- The machine was asleep: nobody could answer; start a fresh window.
            conn.last_seen = now
          end
          if now - conn.last_seen > interval * 2 then
            log.debug('conn %d: keepalive timeout', conn.id)
            conn:close(M.CLOSE.GOING_AWAY, 'keepalive timeout')
          else
            conn:ping('ping')
          end
        end
      end
    end)
  end
  log.debug('listening on %s:%d', server.host, server.port)
  return server, nil
end

---Open connections (handshake completed, not yet closed).
---@return agent.ws.Conn[]
function Server:connections()
  local out = {}
  for _, conn in pairs(self._conns) do
    if conn.state == 'open' then
      out[#out + 1] = conn
    end
  end
  table.sort(out, function(a, b)
    return a.id < b.id
  end)
  return out
end

---Send `text` to every open connection.
---@param text string
---@return integer sent
function Server:broadcast(text)
  local n = 0
  for _, conn in ipairs(self:connections()) do
    if conn:send(text) then
      n = n + 1
    end
  end
  return n
end

---Stop listening; close every connection with 1001 "Server shutting down" (the TCP sockets
---drop when the peers answer, or after about 1 s); abort pending handshakes.
function Server:close()
  if self.closed then
    return
  end
  self.closed = true
  if self._ping_timer then
    self._ping_timer:stop()
    common.close_handle(self._ping_timer)
    self._ping_timer = nil
  end
  common.close_handle(self.handle)
  for _, conn in pairs(self._handshakes) do
    conn:_finalize(false)
  end
  for _, conn in pairs(self._conns) do
    conn:close(M.CLOSE.GOING_AWAY, 'Server shutting down')
  end
end

return M
