---@mod agent.mcp.streamable_http MCP Streamable HTTP binding on top of agent.net.http
---
--- One endpoint (default `/mcp`):
--- - POST carries JSON-RPC messages. Only notifications/responses -> 202. Requests are answered
---   with `application/json`, or with `text/event-stream` (one `event: message` per response,
---   plus `: keepalive` comments while an async tool is pending). See `response_mode`.
--- - GET opens the session's standalone SSE stream for server->client messages.
--- - DELETE ends the session.
--- `Mcp-Session-Id` is issued on `initialize` and required afterwards.
---
--- Provider differences (Copilot CLI vs Gemini CLI) are options and hooks, not code paths:
--- `authorize` (Nonce/Bearer/Host/Origin checks, see the check_* helpers), `accept_initialize` and
--- `session_id` (Copilot's X-Copilot-Session-Id rules, see M.copilot_initialize_policy),
--- `discover` (session-less `server/discover`), `second_stream`, `response_mode`,
--- `protocol_versions`, the session status codes, `allow_delete` and the stream hooks.
---
--- All request handling runs on the main loop (agent.net.http schedules its callbacks).
local uv = vim.uv
local http = require('agent.net.http')
local common = require('agent.net.common')
local McpServer = require('agent.mcp.server')
local util = require('agent.util')
local log = require('agent.log').scope('mcp-http')

local M = {}

M.DEFAULT_KEEPALIVE_MS = 15000
M.DEFAULT_IDLE_SESSION_TIMEOUT_MS = 5 * 60 * 1000
--- Values accepted in the MCP-Protocol-Version request header by default.
M.HEADER_PROTOCOL_VERSIONS = { '2025-11-25', '2025-06-18', '2025-03-26', '2024-11-05', '2024-10-07' }

-- ---------------------------------------------------------------------------
-- HTTP helpers
-- ---------------------------------------------------------------------------

---JSON-RPC error body for HTTP-level failures (`id` null, as the MCP SDK sends them).
---@param code integer
---@param message string
---@return table
function M.error_body(code, message)
  return { jsonrpc = '2.0', error = { code = code, message = message }, id = vim.NIL }
end

-- body: string (text/plain) | table (JSON) | nil (empty)
local function send(res, status, body, headers)
  if res.closed then
    return
  end
  local h = {}
  for k, v in pairs(headers or {}) do
    h[k] = v
  end
  local has_type = false
  for k in pairs(h) do
    if k:lower() == 'content-type' then
      has_type = true
    end
  end
  if type(body) == 'table' then
    body = vim.json.encode(body)
    if not has_type then
      h['Content-Type'] = 'application/json'
    end
  elseif body ~= nil and body ~= '' and not has_type then
    h['Content-Type'] = 'text/plain; charset=utf-8'
  end
  res:write_head(status, h)
  res:finish(body or '')
end

local function media_types(accept)
  local out = {}
  for _, part in ipairs(common.split_list(accept)) do
    local t = part:match('^[^;]*'):gsub('%s', ''):lower()
    out[#out + 1] = t
  end
  return out
end

-- The client explicitly lists text/event-stream (a bare */* is not enough to switch a POST to SSE).
local function wants_sse(accept)
  for _, t in ipairs(media_types(accept)) do
    if t == 'text/event-stream' then
      return true
    end
  end
  return false
end

local function accepts(accept, media)
  if accept == nil or accept == '' then
    return true
  end
  local major = media:match('^[^/]+')
  for _, t in ipairs(media_types(accept)) do
    if t == media or t == '*/*' or t == major .. '/*' then
      return true
    end
  end
  return false
end

-- ---------------------------------------------------------------------------
-- Authorization helpers (compose them with M.all for `authorize`)
-- ---------------------------------------------------------------------------

---Require `Authorization` to equal `expected` exactly (constant-time), e.g. 'Nonce <secret>' for
---Copilot or 'Bearer <token>' for Gemini. Failure: 401 `Unauthorized`.
---@param expected string|fun(): string
---@return fun(req: agent.http.Request): boolean, integer?, string|table?
function M.check_authorization(expected)
  return function(req)
    local want = type(expected) == 'function' and expected() or expected
    if type(want) == 'string' and want ~= '' and common.constant_time_equals(req.headers['authorization'], want) then
      return true
    end
    return false, 401, 'Unauthorized'
  end
end

---Require the Host header to be one of `allowed` (case-insensitive, exact, port included).
---Failure: 403 (default body `{"error":"Invalid Host header"}`).
---@param allowed string[]|fun(req: agent.http.Request): string[]
---@param body string|table|nil
---@return fun(req: agent.http.Request): boolean, integer?, string|table?
function M.check_host(allowed, body)
  return function(req)
    local host = req.headers['host']
    local list = type(allowed) == 'function' and allowed(req) or allowed
    if host then
      host = host:lower()
      for _, h in ipairs(list or {}) do
        if host == h:lower() then
          return true
        end
      end
    end
    return false, 403, body or { error = 'Invalid Host header' }
  end
end

---Refuse browser requests: any Origin header not in `allowed` gets 403
---(default body `{"error":"Request denied by CORS policy."}`).
---@param allowed string[]|nil
---@param body string|table|nil
---@return fun(req: agent.http.Request): boolean, integer?, string|table?
function M.check_origin(allowed, body)
  return function(req)
    local origin = req.headers['origin']
    if origin == nil then
      return true
    end
    for _, o in ipairs(allowed or {}) do
      if origin == o then
        return true
      end
    end
    return false, 403, body or { error = 'Request denied by CORS policy.' }
  end
end

---Run checks in order; the first failure wins.
---@param checks (fun(req: agent.http.Request): boolean, integer?, string|table?, table?)[]
---@return fun(req: agent.http.Request): boolean, integer?, string|table?, table?
function M.all(checks)
  return function(req)
    for _, check in ipairs(checks) do
      local ok, status, body, headers = check(req)
      if not ok then
        return false, status, body, headers
      end
    end
    return true
  end
end

---`accept_initialize` policy implementing Copilot CLI's X-Copilot-Session-Id rules (copilot.md
---§4.5, the CLS takeover rule): the header is required (400); an existing session with the same
---Copilot session id is taken over (closed with reason 'takeover') when it has no open GET stream
---and either had one before or is at least `takeover_min_age_ms` old; otherwise 409 with a body
---containing "A connection for this session already exists". The accepted session gets
---info.copilot_session_id / copilot_pid / copilot_parent_pid.
---@param opts { header?: string, takeover_min_age_ms?: integer }|nil
---@return fun(req: agent.http.Request, msg: table, binding: agent.mcp.StreamableHttp): any, any, any
function M.copilot_initialize_policy(opts)
  opts = opts or {}
  local header = (opts.header or 'X-Copilot-Session-Id'):lower()
  local min_age = opts.takeover_min_age_ms or 30000
  return function(req, _, binding)
    local cid = req.headers[header]
    if not cid or cid == '' then
      return false, 400, M.error_body(-32000, 'Bad Request: X-Copilot-Session-Id header is required')
    end
    for _, s in ipairs(binding:sessions()) do
      if s.info.copilot_session_id == cid then
        local age = util.now_ms() - s.created_at
        if not s.info.stream_open and (s.info.ever_had_stream or age >= min_age) then
          binding:close_session(s, 'takeover')
        else
          return false, 409, M.error_body(-32000, 'Conflict: A connection for this session already exists')
        end
      end
    end
    return {
      copilot_session_id = cid,
      copilot_pid = tonumber(req.headers['x-copilot-pid']),
      copilot_parent_pid = tonumber(req.headers['x-copilot-parent-pid']),
    }
  end
end

-- ---------------------------------------------------------------------------
-- Binding
-- ---------------------------------------------------------------------------

---@class agent.mcp.StreamableHttpOpts
---@field path? string            endpoint path (default '/mcp'); other paths get 404
---@field authorize? fun(req: agent.http.Request): boolean, integer?, string|table?, table?
---   Runs first for every request: true, or false + status (default 401) + body + headers.
---@field allow_delete? boolean   DELETE ends a session (default true); false answers 405
---@field response_mode? 'auto'|'json'|'sse'|fun(req: agent.http.Request, msg: table, session: agent.mcp.Session): string
---   'auto' (default): JSON when every response is ready synchronously; otherwise an SSE stream
---   (headers at once, keep-alive comments until the answers). 'sse': always SSE. 'json': always
---   JSON (the POST waits without keep-alives). SSE is used only if Accept lists text/event-stream.
---@field sse_keepalive_ms? integer|false  comment interval on GET and pending POST streams (default 15000)
---@field second_stream? 'replace'|'reject'  a second GET for a session: end the old stream and
---   adopt the new one (default), or answer 409
---@field missing_session_status? integer  no Mcp-Session-Id on a non-initialize request (default 400)
---@field unknown_session_status? integer  an unknown Mcp-Session-Id (default 404)
---@field discover? 'method_not_found'|'reject'|fun(req: agent.http.Request, msg: table): any, any
---   A session-less `server/discover` request: 200 + JSON-RPC -32601 with no session header
---   (default), or treated like any session-less request ('reject'), or a function returning
---   (result, err) for a 200 JSON answer (both nil = reject).
---@field accept_initialize? fun(req: agent.http.Request, msg: table, binding: agent.mcp.StreamableHttp): any, any, any, any
---   Gate for `initialize`: true/nil to accept, a table to accept and merge into session.info,
---   or false + status (default 400) + body + headers to refuse.
---@field session_id? fun(req: agent.http.Request, msg: table): string  default: a random UUID
---@field protocol_versions? string[]|false|fun(version: string, req: agent.http.Request): boolean
---   Accepted MCP-Protocol-Version header values (400 otherwise); the header may be absent.
---   Default M.HEADER_PROTOCOL_VERSIONS; false disables the check.
---@field idle_session_timeout_ms? integer|false  close sessions whose GET stream went away (and
---   that have no pending request) after this long (default 5 min; false = never)
---@field on_stream_open? fun(session: agent.mcp.Session, binding: agent.mcp.StreamableHttp)
---   A GET stream was opened (notifications can be sent now), e.g. to replay the selection.
---@field on_stream_close? fun(session: agent.mcp.Session, reason: string, binding: agent.mcp.StreamableHttp)

---@class agent.mcp.StreamableHttp
---@field server agent.mcp.Server
---@field opts agent.mcp.StreamableHttpOpts
---@field http agent.http.Server|nil   set by attach()
---@field port integer|nil             TCP port (attach with tcp)
---@field host string|nil
---@field socket_path string|nil       Unix socket path (attach with pipe)
---@field endpoint string
---@field closed boolean
local Binding = {}
Binding.__index = Binding

---Create a binding without a listener; route requests to `binding:handle_request(req, res)`.
---@param server agent.mcp.Server
---@param opts agent.mcp.StreamableHttpOpts|nil
---@return agent.mcp.StreamableHttp
function M.new(server, opts)
  vim.validate('server', server, 'table')
  opts = opts or {}
  local keepalive = opts.sse_keepalive_ms
  if keepalive == nil then
    keepalive = M.DEFAULT_KEEPALIVE_MS
  end
  local idle = opts.idle_session_timeout_ms
  if idle == nil then
    idle = M.DEFAULT_IDLE_SESSION_TIMEOUT_MS
  end
  local self = setmetatable({
    server = server,
    opts = opts,
    endpoint = opts.path or '/mcp',
    keepalive_ms = keepalive,
    idle_timeout_ms = idle,
    second_stream = opts.second_stream or 'replace',
    missing_session_status = opts.missing_session_status or 400,
    unknown_session_status = opts.unknown_session_status or 404,
    closed = false,
    _sessions = {}, -- mcp session id -> session
    _streams = {}, -- session -> GET stream state
  }, Binding)
  if idle and idle > 0 then
    local interval = math.max(50, math.min(60000, math.floor(idle / 2)))
    self._sweeper = uv.new_timer()
    self._sweeper:start(interval, interval, vim.schedule_wrap(function()
      self:_sweep()
    end))
  end
  return self
end

---Listen with agent.net.http and serve MCP on it.
---@param listen_opts agent.http.ListenOpts  as for http.listen (its on_request is replaced)
---@param server agent.mcp.Server
---@param opts agent.mcp.StreamableHttpOpts|nil
---@return agent.mcp.StreamableHttp|nil binding, string|nil err
function M.attach(listen_opts, server, opts)
  local binding = M.new(server, opts)
  local lopts = vim.tbl_extend('force', {}, listen_opts or {})
  lopts.on_request = function(req, res)
    binding:handle_request(req, res)
  end
  local srv, err = http.listen(lopts)
  if not srv then
    binding:close()
    return nil, err
  end
  binding.http = srv
  binding.port, binding.host, binding.socket_path = srv.port, srv.host, srv.path
  return binding, nil
end

---Human-readable listen address.
---@return string|nil
function Binding:address()
  if self.socket_path then
    return self.socket_path
  end
  if self.port then
    return string.format('%s:%d', self.host or '127.0.0.1', self.port)
  end
  return nil
end

---Sessions of this binding, oldest first.
---@return agent.mcp.Session[]
function Binding:sessions()
  local out = {}
  for _, s in pairs(self._sessions) do
    out[#out + 1] = s
  end
  table.sort(out, function(a, b)
    return a._seq < b._seq
  end)
  return out
end

---@param id string  Mcp-Session-Id
---@return agent.mcp.Session|nil
function Binding:get_session(id)
  return self._sessions[id]
end

---@param session agent.mcp.Session
---@return boolean
function Binding:has_stream(session)
  local st = self._streams[session]
  return st ~= nil and not st.res.closed
end

---End a session (its GET stream is ended gracefully; pending requests are cancelled).
---@param session agent.mcp.Session
---@param reason string|nil
function Binding:close_session(session, reason)
  self.server:close_session(session, reason or 'closed')
end

---Close every session and, when attach() created it, the HTTP listener.
function Binding:close()
  if self.closed then
    return
  end
  self.closed = true
  if self._sweeper then
    self._sweeper:stop()
    if not self._sweeper:is_closing() then
      self._sweeper:close()
    end
    self._sweeper = nil
  end
  for _, s in ipairs(self:sessions()) do
    self:close_session(s, 'server_closed')
  end
  if self.http then
    self.http:close()
  end
end

function Binding:_hook(name, ...)
  local fn = self.opts[name]
  if fn then
    local ok, err = xpcall(fn, debug.traceback, ...)
    if not ok then
      log.error('%s hook failed: %s', name, err)
    end
  end
end

function Binding:_session_headers(session)
  if session and not session.closed then
    return { ['Mcp-Session-Id'] = session.id }
  end
  return {}
end

function Binding:_touch(session)
  session.info.last_activity = util.now_ms()
end

-- Keep-alive timers ---------------------------------------------------------------

function Binding:_start_keepalive(st)
  local ms = self.keepalive_ms
  if not ms or ms <= 0 or st.timer then
    return
  end
  local timer = uv.new_timer()
  st.timer = timer
  timer:start(ms, ms, vim.schedule_wrap(function()
    if st.timer ~= timer then
      return
    end
    if st.res.closed or not st.res:sse_comment('keepalive') then
      self:_stop_keepalive(st)
    end
  end))
end

function Binding:_stop_keepalive(st)
  local timer = st.timer
  st.timer = nil
  if timer then
    timer:stop()
    if not timer:is_closing() then
      timer:close()
    end
  end
end

local function write_event(res, msg)
  local text, err = McpServer.encode(msg)
  if not text then
    log.error('cannot encode message: %s', err)
    return false
  end
  return res:sse(text, { event = 'message' })
end

-- Request routing -------------------------------------------------------------------

---Serve one HTTP request (the on_request handler).
---@param req agent.http.Request
---@param res agent.http.Response
function Binding:handle_request(req, res)
  if self.closed then
    return send(res, 503, 'Service Unavailable', { Connection = 'close' })
  end
  if self.opts.authorize then
    local ok, allowed, status, body, headers = xpcall(self.opts.authorize, debug.traceback, req)
    if not ok then
      log.error('authorize failed: %s', allowed)
      return send(res, 500, 'Internal Server Error')
    end
    if not allowed then
      status = status or 401
      if body == nil then
        body = http.STATUS_TEXT[status] or 'Unauthorized'
      end
      return send(res, status, body, headers)
    end
  end
  if req.path ~= self.endpoint then
    return send(res, 404, 'Not Found')
  end
  local method = req.method
  if method == 'POST' then
    return self:_post(req, res)
  elseif method == 'GET' then
    return self:_get(req, res)
  elseif method == 'DELETE' and self.opts.allow_delete ~= false then
    return self:_delete(req, res)
  end
  local allow = self.opts.allow_delete ~= false and 'GET, POST, DELETE' or 'GET, POST'
  return send(res, 405, M.error_body(-32000, 'Method not allowed.'), { Allow = allow })
end

function Binding:_check_protocol_version(req, res)
  local v = req.headers['mcp-protocol-version']
  local policy = self.opts.protocol_versions
  if v == nil or policy == false then
    return true
  end
  local ok
  if type(policy) == 'function' then
    ok = policy(v, req)
  else
    ok = vim.tbl_contains(policy or M.HEADER_PROTOCOL_VERSIONS, v)
  end
  if ok then
    return true
  end
  send(res, 400, M.error_body(-32000, 'Bad Request: Unsupported protocol version: ' .. v))
  return false
end

-- Resolve Mcp-Session-Id or answer with the configured error status.
function Binding:_lookup(req, res)
  local sid = req.headers['mcp-session-id']
  if sid == nil or sid == '' then
    send(res, self.missing_session_status, M.error_body(-32000, 'Bad Request: Mcp-Session-Id header is required'))
    return nil
  end
  local session = self._sessions[sid]
  if not session or session.closed then
    send(res, self.unknown_session_status, M.error_body(-32001, 'Session not found'))
    return nil
  end
  if not self:_check_protocol_version(req, res) then
    return nil
  end
  return session
end

-- POST ------------------------------------------------------------------------------

function Binding:_post(req, res)
  local ok, msg = McpServer.decode(req.body)
  if not ok or type(msg) ~= 'table' then
    return send(res, 400, M.error_body(McpServer.PARSE_ERROR, 'Parse error: Invalid JSON'))
  end
  local batch = McpServer.is_batch(msg)
  local list = batch and msg or { msg }
  if #list == 0 then
    return send(res, 400, M.error_body(McpServer.INVALID_REQUEST, 'Invalid Request: empty batch'))
  end
  local has_requests, init = false, nil
  for _, m in ipairs(list) do
    local kind = McpServer.classify(m)
    if not kind then
      return send(res, 400, M.error_body(McpServer.INVALID_REQUEST, 'Invalid Request: not a JSON-RPC 2.0 message'))
    end
    if kind == 'request' then
      has_requests = true
      if m.method == 'initialize' then
        init = m
      end
    end
  end
  if init then
    if #list > 1 then
      return send(res, 400, M.error_body(McpServer.INVALID_REQUEST, 'Invalid Request: Only one initialization request is allowed'))
    end
    return self:_initialize(req, res, init)
  end
  local sid = req.headers['mcp-session-id']
  if not (sid and self._sessions[sid]) and #list == 1 and has_requests and self:_sessionless(req, res, list[1]) then
    return
  end
  local session = self:_lookup(req, res)
  if not session then
    return
  end
  self:_touch(session)
  if not has_requests then
    self.server:handle(session, msg)
    return send(res, 202, nil, self:_session_headers(session))
  end
  self:_respond(req, res, session, msg, batch, false)
end

-- A request that arrived without a (known) session: only `server/discover` is answered.
function Binding:_sessionless(req, res, m)
  local policy = self.opts.discover
  if policy == nil then
    policy = 'method_not_found'
  end
  if m.method ~= 'server/discover' or policy == 'reject' then
    return false
  end
  local body
  if type(policy) == 'function' then
    local ok, result, err = xpcall(policy, debug.traceback, req, m)
    if not ok then
      log.error('discover hook failed: %s', result)
      return false
    end
    if result == nil and err == nil then
      return false
    end
    if err ~= nil then
      body = { jsonrpc = '2.0', id = m.id, error = err }
    else
      body = { jsonrpc = '2.0', id = m.id, result = result }
    end
  else
    body = { jsonrpc = '2.0', id = m.id, error = { code = McpServer.METHOD_NOT_FOUND, message = 'Method not found' } }
  end
  -- Deliberately no Mcp-Session-Id: the client would carry it into its initialize (copilot.md §3.7).
  send(res, 200, body)
  return true
end

function Binding:_initialize(req, res, m)
  local extra_info
  if self.opts.accept_initialize then
    local ok, a, status, body, headers = xpcall(self.opts.accept_initialize, debug.traceback, req, m, self)
    if not ok then
      log.error('accept_initialize failed: %s', a)
      return send(res, 500, 'Internal Server Error')
    end
    if a == false then
      return send(res, status or 400, body == nil and M.error_body(-32000, 'Bad Request') or body, headers)
    end
    if type(a) == 'table' then
      extra_info = a
    end
  end
  -- A client re-initializing with its old session id replaces that session.
  local old = req.headers['mcp-session-id']
  if old and self._sessions[old] then
    self:close_session(self._sessions[old], 'reinitialized')
  end
  local sid = self.opts.session_id and self.opts.session_id(req, m) or util.uuid()
  if self._sessions[sid] then
    -- Remove the previous holder of this id before the new session takes it (copilot.md §4.4).
    self:close_session(self._sessions[sid], 'replaced')
  end
  local info = {
    transport = 'streamable_http',
    headers = req.headers,
    remote = req.remote,
    conn_id = req.conn_id,
    stream_open = false,
    ever_had_stream = false,
    last_activity = util.now_ms(),
  }
  for k, v in pairs(extra_info or {}) do
    info[k] = v
  end
  local session
  session = self.server:open_session({
    id = sid,
    info = info,
    send = function(msg)
      return self:_push(session, msg)
    end,
    on_close = function(s, reason)
      self:_session_closed(s, reason)
    end,
  })
  self._sessions[sid] = session
  self:_respond(req, res, session, m, false, true)
end

-- Dispatch the requests of one POST and answer them as JSON or SSE.
function Binding:_respond(req, res, session, msg, batch, is_init)
  local mode = self.opts.response_mode or 'auto'
  if type(mode) == 'function' then
    local ok, m = pcall(mode, req, msg, session)
    mode = ok and m or 'auto'
  end
  local st = {
    res = res,
    session = session,
    batch = batch,
    is_init = is_init,
    mode = nil, -- 'json' | 'sse' once decided
    can_sse = mode ~= 'json' and wants_sse(req.headers['accept']),
    collected = {},
    responses = nil,
    done = false,
    sync = true,
  }
  local dispatch = self.server:handle(session, msg, {
    on_response = function(resp)
      if st.mode == 'sse' then
        write_event(res, resp)
      else
        table.insert(st.collected, resp)
      end
    end,
    on_notify = function(note)
      if st.mode == nil and st.can_sse then
        self:_start_post_sse(st)
      end
      if st.mode == 'sse' then
        return write_event(res, note)
      end
      return false
    end,
    on_done = function(responses)
      st.done = true
      st.responses = responses
      if not st.sync then
        self:_finish_post(st)
      end
    end,
  })
  st.sync = false
  if not dispatch then
    return send(res, self.unknown_session_status, M.error_body(-32001, 'Session not found'))
  end
  if st.done then
    if is_init then
      self:_check_init(st)
    end
    if st.mode == nil and mode == 'sse' and st.can_sse then
      self:_start_post_sse(st)
    end
    return self:_finish_post(st)
  end
  if st.mode == nil then
    if st.can_sse then
      self:_start_post_sse(st)
    else
      st.mode = 'json'
    end
  end
  res:on_close(function()
    self:_stop_keepalive(st)
    if not st.done then
      dispatch:cancel('disconnect')
    end
  end)
end

-- A failed initialize must not leave a session behind (or announce its id).
function Binding:_check_init(st)
  local r = st.responses and st.responses[1]
  if (not r or r.error) and not st.session.closed then
    self:close_session(st.session, 'initialize_failed')
  end
end

function Binding:_start_post_sse(st)
  st.mode = 'sse'
  local h = self:_session_headers(st.session)
  h['Content-Type'] = 'text/event-stream'
  h['Cache-Control'] = 'no-cache, no-transform'
  st.res:start_stream(200, h)
  for _, r in ipairs(st.collected) do
    write_event(st.res, r)
  end
  st.collected = {}
  if not st.done then
    self:_start_keepalive(st)
  end
end

function Binding:_finish_post(st)
  self:_stop_keepalive(st)
  if st.is_init then
    self:_check_init(st)
  end
  local res = st.res
  if res.closed then
    return
  end
  if st.mode == 'sse' then
    res:finish()
    return
  end
  local headers = self:_session_headers(st.session)
  if #st.collected == 0 then
    -- Every request was cancelled: cancelled requests get no JSON-RPC response.
    return send(res, 202, nil, headers)
  end
  local text, err = McpServer.encode(st.batch and st.collected or st.collected[1])
  if not text then
    log.error('cannot encode response: %s', err)
    return send(res, 500, M.error_body(McpServer.INTERNAL_ERROR, 'Internal error: cannot encode response'))
  end
  headers['Content-Type'] = 'application/json'
  res:write_head(200, headers)
  res:finish(text)
end

-- GET -------------------------------------------------------------------------------

function Binding:_get(req, res)
  local accept = req.headers['accept']
  if accept and not accepts(accept, 'text/event-stream') then
    return send(res, 406, M.error_body(-32000, 'Not Acceptable: Client must accept text/event-stream'))
  end
  local session = self:_lookup(req, res)
  if not session then
    return
  end
  self:_touch(session)
  if self._streams[session] then
    if self.second_stream == 'reject' then
      return send(res, 409, M.error_body(-32000, 'Conflict: Only one SSE stream is allowed per session'))
    end
    self:_end_stream(session, 'replaced')
  end
  local h = self:_session_headers(session)
  h['Content-Type'] = 'text/event-stream'
  h['Cache-Control'] = 'no-cache, no-transform'
  if not res:start_stream(200, h) then
    return
  end
  local st = { res = res, session = session }
  self._streams[session] = st
  session.info.stream_open = true
  session.info.ever_had_stream = true
  self:_start_keepalive(st)
  res:on_close(function()
    self:_stop_keepalive(st)
    if self._streams[session] == st then
      self._streams[session] = nil
      session.info.stream_open = false
      session.info.stream_closed_at = util.now_ms()
      self:_hook('on_stream_close', session, 'disconnect', self)
    end
  end)
  self:_hook('on_stream_open', session, self)
end

function Binding:_end_stream(session, reason)
  local st = self._streams[session]
  if not st then
    return
  end
  self._streams[session] = nil
  self:_stop_keepalive(st)
  session.info.stream_open = false
  session.info.stream_closed_at = util.now_ms()
  st.res:finish()
  self:_hook('on_stream_close', session, reason, self)
end

-- session.send: server->client messages go on the GET stream (dropped when there is none).
function Binding:_push(session, msg)
  local st = session and self._streams[session]
  if not st or st.res.closed then
    log.debug('session %s has no SSE stream; %s dropped', session and session.id or '?', msg.method or 'message')
    return false
  end
  return write_event(st.res, msg)
end

-- DELETE ----------------------------------------------------------------------------

function Binding:_delete(req, res)
  local session = self:_lookup(req, res)
  if not session then
    return
  end
  self:close_session(session, 'deleted')
  send(res, 200, nil)
end

-- Session lifecycle -----------------------------------------------------------------

function Binding:_session_closed(session, reason)
  if self._sessions[session.id] == session then
    self._sessions[session.id] = nil
  end
  self:_end_stream(session, reason)
end

function Binding:_sweep()
  local timeout = self.idle_timeout_ms
  if self.closed or not timeout then
    return
  end
  local now = util.now_ms()
  for _, s in ipairs(self:sessions()) do
    local i = s.info
    if not i.stream_open and i.ever_had_stream and s:pending_count() == 0 then
      local idle_since = math.max(i.stream_closed_at or 0, i.last_activity or 0)
      if now - idle_since >= timeout then
        log.debug('session %s expired', s.id)
        self:close_session(s, 'expired')
      end
    end
  end
end

return M
