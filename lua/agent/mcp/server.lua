---@mod agent.mcp.server Transport-agnostic MCP (JSON-RPC 2.0) server core
---
--- A server owns a tool table and a set of sessions. A transport (WebSocket, Streamable HTTP, an
--- in-memory test double) opens one session per client, feeds it decoded messages with
--- `server:handle()`, and delivers whatever the session's `send` function receives.
---
--- Requests are answered through the `send` function by default. A transport that needs to route
--- responses itself (Streamable HTTP answers on the POST that carried the request) passes
--- `on_response`/`on_done` callbacks to `handle()`.
---
--- Threading: everything here runs on the main loop. Transports must call `handle()` and
--- `close_session()` from scheduled contexts (agent.net.http and agent.net.websocket already
--- invoke their callbacks that way), so handlers may use vim.api freely.
local util = require('agent.util')
local log = require('agent.log').scope('mcp')

local M = {}

M.PARSE_ERROR = -32700
M.INVALID_REQUEST = -32600
M.METHOD_NOT_FOUND = -32601
M.INVALID_PARAMS = -32602
M.INTERNAL_ERROR = -32603

local DEFAULT_MESSAGES = {
  [M.PARSE_ERROR] = 'Parse error',
  [M.INVALID_REQUEST] = 'Invalid Request',
  [M.METHOD_NOT_FOUND] = 'Method not found',
  [M.INVALID_PARAMS] = 'Invalid params',
  [M.INTERNAL_ERROR] = 'Internal error',
}

M.LATEST_PROTOCOL_VERSION = '2025-11-25'
--- Versions echoed by the default negotiation policy (newest first).
M.SUPPORTED_PROTOCOL_VERSIONS = { '2025-11-25', '2025-06-18', '2025-03-26', '2024-11-05' }

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local RpcError = {}
RpcError.__index = RpcError
RpcError.__tostring = function(e)
  return string.format('JSON-RPC error %d: %s', e.code, e.message)
end

---Build a JSON-RPC error object. Throw it from a handler (`error(M.rpc_error(...))`) or pass it
---to an async `respond(nil, err)`.
---@param code integer
---@param message string|nil default: the standard message for `code`
---@param data any
---@return { code: integer, message: string, data: any }
function M.rpc_error(code, message, data)
  return setmetatable({ code = code, message = message or DEFAULT_MESSAGES[code] or 'Error', data = data }, RpcError)
end

---Text content result: `{ content = { { type = 'text', text = ... } } }`. Tables are JSON-encoded.
---@param value string|table
---@return table
function M.text_result(value)
  local text = value
  if type(value) ~= 'string' then
    local ok, s = pcall(vim.json.encode, value)
    text = ok and s or tostring(value)
  end
  return { content = { { type = 'text', text = text } } }
end

---Tool-level failure (MCP style): `{ isError = true, content = { { type = 'text', text = message } } }`.
---@param message string
---@return table
function M.error_result(message)
  return { isError = true, content = { { type = 'text', text = tostring(message) } } }
end

---Normalize a tool handler's return value into a CallToolResult:
--- - nil -> `{ content = {} }`
--- - a string -> one text item
--- - a table whose `content` is a table (or that has `isError`/`structuredContent` without
---   `content`) -> used as the CallToolResult
--- - anything else (other tables, vim.NIL, numbers, booleans) -> one text item holding its JSON
---@param value any
---@return table
function M.tool_result(value)
  if value == nil then
    return { content = {} }
  end
  if type(value) == 'string' then
    return M.text_result(value)
  end
  if type(value) == 'table' and getmetatable(value) ~= getmetatable(vim.empty_dict()) then
    if type(value.content) == 'table' then
      return value
    end
    if value.content == nil and (value.isError ~= nil or value.structuredContent ~= nil) then
      local out = vim.tbl_extend('force', {}, value)
      out.content = {}
      return out
    end
  end
  return M.text_result(value)
end

---Pick the protocol version to answer `initialize` with: `requested` when it is in `supported`,
---else `fallback` (default: supported[1]).
---@param requested string|nil
---@param supported string[]
---@param fallback string|nil
---@return string
function M.negotiate_version(requested, supported, fallback)
  for _, v in ipairs(supported) do
    if v == requested then
      return v
    end
  end
  return fallback or supported[1]
end

---A protocol_version policy function for `M.new`.
---@param supported string[]
---@param fallback string|nil
---@return fun(requested: string|nil): string
function M.version_policy(supported, fallback)
  return function(requested)
    return M.negotiate_version(requested, supported, fallback)
  end
end

---Classify a decoded JSON-RPC message.
---@param msg any
---@return 'request'|'notification'|'response'|nil kind nil when it is not a valid JSON-RPC 2.0 message
function M.classify(msg)
  if type(msg) ~= 'table' or msg.jsonrpc ~= '2.0' then
    return nil
  end
  local id = msg.id
  if id ~= nil and type(id) ~= 'string' and type(id) ~= 'number' then
    return nil
  end
  if msg.method ~= nil then
    if type(msg.method) ~= 'string' then
      return nil
    end
    return id ~= nil and 'request' or 'notification'
  end
  if id ~= nil and (msg.result ~= nil or msg.error ~= nil) then
    return 'response'
  end
  return nil
end

---True for a JSON-RPC batch (a Lua list), including the empty one.
---@param msg any
---@return boolean
function M.is_batch(msg)
  return type(msg) == 'table' and msg.jsonrpc == nil and vim.islist(msg)
end

---Decode a JSON-RPC message or batch. JSON null becomes nil (util.json_decode), except a message's
---`"id": null`, which is kept as vim.NIL so that classify() rejects the message instead of taking
---it for a notification: in JSON-RPC 2.0 an id member makes a request, and MCP forbids null ids.
---@param text string
---@return boolean ok, any msg_or_err
function M.decode(text)
  local ok, msg = util.json_decode(text)
  if not ok or type(msg) ~= 'table' or not text:find('null', 1, true) then
    return ok, msg
  end
  local list = M.is_batch(msg) and msg or { msg }
  local suspect = false
  for _, m in pairs(list) do
    if type(m) == 'table' and m.id == nil then
      suspect = true
      break
    end
  end
  if not suspect then
    return ok, msg
  end
  -- Only messages without an id pay for this second decode (nulls in arrays still dropped, so
  -- batch indices match).
  local rok, raw = pcall(vim.json.decode, text, { luanil = { array = true } })
  if rok and type(raw) == 'table' then
    local raw_list = list == msg and raw or { raw }
    for i, m in pairs(list) do
      local r = raw_list[i]
      if type(m) == 'table' and m.id == nil and type(r) == 'table' and r.id == vim.NIL then
        m.id = vim.NIL
      end
    end
  end
  return ok, msg
end

---Encode a message for the wire.
---@param msg table
---@return string|nil json, string|nil err
function M.encode(msg)
  local ok, s = pcall(vim.json.encode, msg)
  if not ok then
    return nil, tostring(s)
  end
  return s, nil
end

local function id_key(id)
  return type(id) .. ':' .. tostring(id)
end

local function valid_id(id)
  return type(id) == 'string' or type(id) == 'number'
end

-- Empty Lua tables encode as `[]`. Capabilities and schema `properties` must be objects.
local function objectify(t)
  if type(t) ~= 'table' then
    return t
  end
  if next(t) == nil then
    return getmetatable(t) and t or vim.empty_dict()
  end
  for k, v in pairs(t) do
    if type(v) == 'table' then
      t[k] = objectify(v)
    end
  end
  return t
end

local SCHEMA_OBJECT_KEYS = { properties = true, patternProperties = true, definitions = true, ['$defs'] = true }

local function normalize_schema(schema)
  if type(schema) ~= 'table' then
    return schema
  end
  for k, v in pairs(schema) do
    if type(v) == 'table' then
      if SCHEMA_OBJECT_KEYS[k] and next(v) == nil and not getmetatable(v) then
        schema[k] = vim.empty_dict()
      else
        normalize_schema(v)
      end
    end
  end
  return schema
end

local function normalize_params(params)
  if type(params) == 'table' and next(params) == nil and not getmetatable(params) then
    return vim.empty_dict()
  end
  return params
end

local function to_error_object(err)
  if type(err) == 'table' and type(err.code) == 'number' then
    local out = { code = err.code, message = tostring(err.message or DEFAULT_MESSAGES[err.code] or 'Error') }
    if err.data ~= nil then
      out.data = err.data
    end
    return out
  end
  if type(err) == 'string' then
    return { code = M.INTERNAL_ERROR, message = 'Internal error: ' .. err }
  end
  return { code = M.INTERNAL_ERROR, message = 'Internal error' }
end

local function error_response(id, err)
  return { jsonrpc = '2.0', id = id, error = to_error_object(err) }
end

-- Keep intentional rpc errors quiet; show handler bugs (plain Lua errors) with a traceback.
local function on_handler_error(e)
  if type(e) ~= 'table' then
    log.error('handler failed: %s', debug.traceback(tostring(e), 2))
  end
  return e
end

local function safe_call(what, fn, ...)
  local ok, err = xpcall(fn, debug.traceback, ...)
  if not ok then
    log.error('%s failed: %s', what, err)
  end
  return ok, err
end

-- ---------------------------------------------------------------------------
-- Session
-- ---------------------------------------------------------------------------

---@class agent.mcp.Session
---@field id string
---@field server agent.mcp.Server
---@field info table              transport-owned data (e.g. request headers, stream state)
---@field data table              free slot for the provider
---@field created_at number       util.now_ms() at open
---@field initialized boolean     `initialize` was answered successfully (notifications may be sent)
---@field ready boolean           `notifications/initialized` was received
---@field closed boolean
---@field client_info table|nil   initialize params.clientInfo
---@field client_capabilities table|nil
---@field protocol_version string|nil  negotiated version
---@field requested_protocol_version string|nil
---@field send fun(msg: table): boolean|nil
local Session = {}
Session.__index = Session

---@param method string
---@param params table|nil
---@param opts { force?: boolean }|nil
---@return boolean sent
function Session:notify(method, params, opts)
  return self.server:notify(self, method, params, opts)
end

---@param reason string|nil
function Session:close(reason)
  self.server:close_session(self, reason)
end

---@return boolean
function Session:is_open()
  return not self.closed
end

---Number of client requests still being handled.
---@return integer
function Session:pending_count()
  local n = 0
  for _ in pairs(self._pending) do
    n = n + 1
  end
  return n
end

---Client requests still being handled.
---@return { id: string|number, method: string, tool: string|nil }[]
function Session:pending_requests()
  local out = {}
  for _, entry in pairs(self._pending) do
    out[#out + 1] = { id = entry.id, method = entry.method, tool = entry.ctx.tool }
  end
  return out
end

-- ---------------------------------------------------------------------------
-- Dispatch: the requests of one handle() call
-- ---------------------------------------------------------------------------

---@class agent.mcp.Dispatch
---@field batch boolean
---@field total integer        number of requests in the message
---@field pending integer      requests not yet answered or cancelled
---@field responses table[]    responses delivered so far
---@field done boolean
local Dispatch = {}
Dispatch.__index = Dispatch

function Dispatch:_deliver(response)
  if response then
    self.responses[#self.responses + 1] = response
    if self._on_response then
      safe_call('on_response', self._on_response, response)
    elseif not self._on_done and not self.batch then
      self._server:_send(self._session, response)
    end
  end
  self.pending = self.pending - 1
  if self.pending <= 0 then
    self:_complete()
  end
end

function Dispatch:_complete()
  if self.done then
    return
  end
  self.done = true
  if self._on_done then
    safe_call('on_done', self._on_done, self.responses)
  elseif not self._on_response and self.batch and #self.responses > 0 then
    self._server:_send(self._session, self.responses)
  end
end

---Cancel every request of this dispatch that is still pending (e.g. the HTTP client went away).
---Cancelled requests get no response; their ctx.on_cancel callbacks run with `reason`.
---@param reason string|nil default 'disconnect'
---@param detail any
function Dispatch:cancel(reason, detail)
  for _, entry in ipairs(self._entries) do
    self._server:_cancel_entry(entry, reason or 'disconnect', detail)
  end
end

-- ---------------------------------------------------------------------------
-- Server
-- ---------------------------------------------------------------------------

---@class agent.mcp.Server
---@field name string
---@field version string
---@field title string|nil
---@field instructions string|nil
---@field capabilities table
local Server = {}
Server.__index = Server

---@class agent.mcp.ServerOpts
---@field name string
---@field version string
---@field title? string
---@field instructions? string
---@field protocol_version? string|string[]|{ supported: string[], fallback?: string }|fun(requested: string|nil, session: agent.mcp.Session): string
---   A fixed string, a list of supported versions (echo when listed, else the first), or a function.
---   Default: echo one of M.SUPPORTED_PROTOCOL_VERSIONS, else M.LATEST_PROTOCOL_VERSION.
---@field capabilities? table  default { tools = { listChanged = false } }
---@field on_initialize? fun(session: agent.mcp.Session, params: table, result: table): table|nil
---   Runs before `initialize` is answered. May edit `result` or return fields merged into it;
---   may throw (e.g. M.rpc_error) to reject the handshake.
---@field on_notification? fun(session: agent.mcp.Session, method: string, params: table|nil)
---@field on_session_close? fun(session: agent.mcp.Session, reason: string)
---@field validate_arguments? boolean  check a tool's `inputSchema.required` before calling it (default true)

---Create a server.
---@param opts agent.mcp.ServerOpts
---@return agent.mcp.Server
function M.new(opts)
  vim.validate('opts', opts, 'table')
  vim.validate('opts.name', opts.name, 'string')
  vim.validate('opts.version', opts.version, 'string')
  local pv = opts.protocol_version
  local policy
  if pv == nil then
    policy = M.version_policy(M.SUPPORTED_PROTOCOL_VERSIONS, M.LATEST_PROTOCOL_VERSION)
  elseif type(pv) == 'string' then
    policy = function()
      return pv
    end
  elseif type(pv) == 'table' then
    policy = M.version_policy(pv.supported or pv, pv.fallback)
  elseif type(pv) == 'function' then
    policy = pv
  else
    error('agent.mcp.server: protocol_version must be a string, list, table or function')
  end
  return setmetatable({
    name = opts.name,
    version = opts.version,
    title = opts.title,
    instructions = opts.instructions,
    capabilities = opts.capabilities or { tools = { listChanged = false } },
    validate_arguments = opts.validate_arguments ~= false,
    _version_policy = policy,
    _on_initialize = opts.on_initialize,
    _on_notification = opts.on_notification,
    _on_session_close = opts.on_session_close,
    _tools = {},
    _tool_order = {},
    _methods = {},
    _sessions = {},
    _seq = 0,
  }, Server)
end

-- Tools ----------------------------------------------------------------------

local TOOL_INTERNAL_KEYS = { handler = true, async = true, hidden = true, validate = true }

---@class agent.mcp.ToolDef
---@field name string
---@field description? string
---@field title? string
---@field inputSchema? table   JSON Schema (type 'object'); empty `properties` are sent as `{}`
---@field outputSchema? table
---@field annotations? table
---@field hidden? boolean|fun(session: agent.mcp.Session): boolean  callable but left out of tools/list
---@field async? boolean       handler(args, ctx, respond) instead of handler(args, ctx)
---@field validate? boolean    per-tool override of the server's validate_arguments
---@field handler fun(args: table, ctx: agent.mcp.Context, respond?: fun(result: any, err: any): boolean): any
--- Any other key (e.g. `execution`, `_meta`) is passed through to tools/list unchanged.

---Register (or replace) a tool.
---A sync handler returns the result (see M.tool_result for accepted shapes) or throws: an
---M.rpc_error / `{code=,message=,data=}` table becomes that JSON-RPC error, anything else -32603.
---An async handler calls `respond(result)` or `respond(nil, err)` exactly once, now or later.
---@param def agent.mcp.ToolDef
function Server:add_tool(def)
  vim.validate('def', def, 'table')
  vim.validate('def.name', def.name, 'string')
  vim.validate('def.handler', def.handler, 'function')
  local spec = {}
  for k, v in pairs(def) do
    if not TOOL_INTERNAL_KEYS[k] then
      spec[k] = type(v) == 'table' and vim.deepcopy(v) or v
    end
  end
  local schema = spec.inputSchema or {}
  if schema.type == nil then
    schema.type = 'object'
  end
  if schema.properties == nil then
    schema.properties = vim.empty_dict()
  end
  spec.inputSchema = normalize_schema(schema)
  if spec.outputSchema then
    spec.outputSchema = normalize_schema(spec.outputSchema)
  end
  if not self._tools[def.name] then
    table.insert(self._tool_order, def.name)
  end
  self._tools[def.name] = { def = def, spec = spec }
end

---@param name string
---@return boolean removed
function Server:remove_tool(name)
  if not self._tools[name] then
    return false
  end
  self._tools[name] = nil
  for i, n in ipairs(self._tool_order) do
    if n == name then
      table.remove(self._tool_order, i)
      break
    end
  end
  return true
end

---@param name string
---@return agent.mcp.ToolDef|nil
function Server:get_tool(name)
  local t = self._tools[name]
  return t and t.def
end

---The tools/list entries visible to `session`, in registration order.
---@param session agent.mcp.Session|nil
---@return table[]
function Server:list_tools(session)
  local out = {}
  for _, name in ipairs(self._tool_order) do
    local t = self._tools[name]
    local hidden = t.def.hidden
    if type(hidden) == 'function' then
      local ok, h = pcall(hidden, session)
      hidden = ok and h
    end
    if not hidden then
      out[#out + 1] = t.spec
    end
  end
  return out
end

---Register a custom request method (it takes precedence over the built-in ones:
---initialize, ping, tools/list, tools/call).
---@param method string
---@param handler fun(params: table, ctx: agent.mcp.Context, respond?: fun(result: any, err: any): boolean): any
---@param opts { async?: boolean }|nil
function Server:add_method(method, handler, opts)
  vim.validate('method', method, 'string')
  vim.validate('handler', handler, 'function')
  self._methods[method] = { fn = handler, async = opts and opts.async or false }
end

-- Sessions -------------------------------------------------------------------

---@class agent.mcp.SessionOpts
---@field send fun(msg: table|table[]): boolean|nil  deliver a message to the client; return false when it could not be sent
---@field id? string          default: a random UUID
---@field info? table         transport data, stored as session.info
---@field on_close? fun(session: agent.mcp.Session, reason: string)  transport cleanup hook

---Open a session for a new client connection.
---@param opts agent.mcp.SessionOpts
---@return agent.mcp.Session
function Server:open_session(opts)
  vim.validate('opts', opts, 'table')
  vim.validate('opts.send', opts.send, 'function')
  self._seq = self._seq + 1
  local session = setmetatable({
    id = opts.id or util.uuid(),
    server = self,
    info = opts.info or {},
    data = {},
    send = opts.send,
    created_at = util.now_ms(),
    initialized = false,
    ready = false,
    closed = false,
    _seq = self._seq,
    _on_close = opts.on_close,
    _pending = {},
    _outgoing = {},
    _next_id = 0,
  }, Session)
  self._sessions[session] = true
  return session
end

---Open sessions, oldest first.
---@return agent.mcp.Session[]
function Server:sessions()
  local out = {}
  for s in pairs(self._sessions) do
    out[#out + 1] = s
  end
  table.sort(out, function(a, b)
    return a._seq < b._seq
  end)
  return out
end

---@param id string
---@return agent.mcp.Session|nil
function Server:get_session(id)
  for s in pairs(self._sessions) do
    if s.id == id then
      return s
    end
  end
  return nil
end

---Close a session: pending requests are cancelled (ctx.on_cancel callbacks run with reason
---'session_closed' and `reason` as detail; no responses are sent), outstanding server->client
---requests fail, then the transport's on_close and the server's on_session_close run.
---@param session agent.mcp.Session
---@param reason string|nil default 'closed'
function Server:close_session(session, reason)
  if not session or session.closed then
    return
  end
  reason = reason or 'closed'
  session.closed = true
  self._sessions[session] = nil
  local pending = {}
  for _, entry in pairs(session._pending) do
    pending[#pending + 1] = entry
  end
  table.sort(pending, function(a, b)
    return a.seq < b.seq
  end)
  for _, entry in ipairs(pending) do
    self:_cancel_entry(entry, 'session_closed', reason)
  end
  local outgoing = session._outgoing
  session._outgoing = {}
  for _, out in pairs(outgoing) do
    self:_finish_outgoing(out, nil, { code = -32000, message = 'Session closed' })
  end
  if session._on_close then
    safe_call('session on_close', session._on_close, session, reason)
  end
  if self._on_session_close then
    safe_call('on_session_close', self._on_session_close, session, reason)
  end
end

---Close every session.
---@param reason string|nil default 'server_closed'
function Server:close(reason)
  for _, s in ipairs(self:sessions()) do
    self:close_session(s, reason or 'server_closed')
  end
end

-- Outbound messages ------------------------------------------------------------

function Server:_send(session, msg)
  if session.closed then
    return false
  end
  local ok, sent = pcall(session.send, msg)
  if not ok then
    log.warn('send failed on session %s: %s', session.id, sent)
    return false
  end
  return sent ~= false
end

---Send a notification. Dropped (returns false) when the session is closed or has not completed
---`initialize` yet, unless opts.force.
---@param session agent.mcp.Session
---@param method string
---@param params table|nil empty tables are sent as `{}`
---@param opts { force?: boolean }|nil
---@return boolean sent
function Server:notify(session, method, params, opts)
  if not session or session.closed then
    return false
  end
  if not session.initialized and not (opts and opts.force) then
    log.debug('notification %s dropped: session %s is not initialized', method, session.id)
    return false
  end
  return self:_send(session, { jsonrpc = '2.0', method = method, params = normalize_params(params) })
end

---Notify every initialized session (optionally filtered).
---@param method string
---@param params table|nil
---@param filter fun(session: agent.mcp.Session): boolean|nil
---@return integer count sessions the notification was sent to
function Server:broadcast(method, params, filter)
  local n = 0
  for _, s in ipairs(self:sessions()) do
    if s.initialized and (not filter or filter(s)) then
      if self:notify(s, method, params) then
        n = n + 1
      end
    end
  end
  return n
end

function Server:_finish_outgoing(out, result, err)
  if out.finished then
    return
  end
  out.finished = true
  if out.timer and not out.timer:is_closing() then
    out.timer:stop()
    out.timer:close()
  end
  if out.cb then
    safe_call('request callback', out.cb, result, err)
  end
end

---Send a request to the client; `cb(result, err)` runs once with the response, a timeout error
---(-32001) or a session-closed error (-32000).
---@param session agent.mcp.Session
---@param method string
---@param params table|nil
---@param cb fun(result: any, err: table|nil)|nil
---@param opts { timeout_ms?: integer }|nil
---@return integer|nil id
function Server:request(session, method, params, cb, opts)
  if not session or session.closed then
    if cb then
      vim.schedule(function()
        cb(nil, { code = -32000, message = 'Session closed' })
      end)
    end
    return nil
  end
  session._next_id = session._next_id + 1
  local id = session._next_id
  local key = id_key(id)
  local out = { cb = cb }
  session._outgoing[key] = out
  local timeout = opts and opts.timeout_ms
  if timeout then
    out.timer = vim.defer_fn(function()
      if session._outgoing[key] == out then
        session._outgoing[key] = nil
        self:_finish_outgoing(out, nil, { code = -32001, message = 'Request timed out' })
      end
    end, timeout)
  end
  local sent = self:_send(session, { jsonrpc = '2.0', id = id, method = method, params = normalize_params(params) })
  if not sent then
    session._outgoing[key] = nil
    vim.schedule(function()
      self:_finish_outgoing(out, nil, { code = -32000, message = 'Could not send request' })
    end)
  end
  return id
end

-- Inbound messages -------------------------------------------------------------

---@class agent.mcp.HandleOpts
---@field on_response? fun(response: table)  each response, as soon as it is ready (instead of session.send)
---@field on_done? fun(responses: table[])   once every request of the message was answered or cancelled
---   (right away when there were none). Given alone, responses are not sent through session.send.
---@field on_notify? fun(notification: table): boolean  request-related notifications from ctx.notify/
---   ctx.progress; return false to fall back to session.send

---@class agent.mcp.Context
---@field server agent.mcp.Server
---@field session agent.mcp.Session
---@field request_id string|number
---@field method string
---@field tool string|nil              tools/call: the tool name
---@field meta table|nil               params._meta
---@field progress_token any           params._meta.progressToken
---@field cancelled boolean
---@field cancel_reason string|nil     'cancelled' (notifications/cancelled) | 'session_closed' | 'disconnect' | a transport's reason
---@field cancel_detail any            client-supplied reason text, or the session close reason
---@field on_cancel fun(cb: fun(reason: string, detail: any))  runs cb once if the request is cancelled (at once if it already was)
---@field notify fun(method: string, params: table|nil): boolean  notification related to this request
---@field progress fun(progress: number, total: number|nil, message: string|nil): boolean  notifications/progress (needs a progress token)
---@field is_active fun(): boolean     not yet answered or cancelled

---Handle one decoded message or batch from the client.
---Requests are answered through `opts` callbacks or, by default, through session.send (a batch is
---answered with one array once every request settled). Invalid messages that carry a usable id get
----32600; the others are logged and dropped (MCP clients reject responses with a null id).
---@param session agent.mcp.Session
---@param msg table
---@param opts agent.mcp.HandleOpts|nil
---@return agent.mcp.Dispatch|nil dispatch nil when the session is closed
function Server:handle(session, msg, opts)
  if not session or session.closed then
    log.debug('message for a closed session dropped')
    return nil
  end
  opts = opts or {}
  local batch = M.is_batch(msg)
  local list = batch and msg or { msg }
  local d = setmetatable({
    batch = batch,
    total = 0,
    pending = 0,
    responses = {},
    done = false,
    _server = self,
    _session = session,
    _entries = {},
    _on_response = opts.on_response,
    _on_done = opts.on_done,
    _on_notify = opts.on_notify,
  }, Dispatch)
  local kinds = {}
  for i, m in ipairs(list) do
    local kind = M.classify(m)
    kinds[i] = kind
    if kind == 'request' or (kind == nil and type(m) == 'table' and valid_id(m.id)) then
      d.total = d.total + 1
    end
  end
  if batch and #list == 0 then
    log.debug('empty batch dropped')
  end
  d.pending = d.total
  for i, m in ipairs(list) do
    local kind = kinds[i]
    if session.closed then
      -- A notification handler closed the session: remaining requests settle without answers.
      if kind == 'request' or (kind == nil and type(m) == 'table' and valid_id(m.id)) then
        d:_deliver(nil)
      end
    elseif kind == 'request' then
      self:_request(session, m, d)
    elseif kind == 'notification' then
      self:_notification(session, m)
    elseif kind == 'response' then
      self:_client_response(session, m)
    elseif type(m) == 'table' and valid_id(m.id) then
      d:_deliver(error_response(m.id, M.rpc_error(M.INVALID_REQUEST)))
    else
      log.debug('invalid JSON-RPC message dropped: %s', vim.inspect(m))
    end
  end
  if d.total == 0 then
    d:_complete()
  end
  return d
end

---Decode and handle a JSON text. Unparseable input is logged and dropped.
---@param session agent.mcp.Session
---@param text string
---@param opts agent.mcp.HandleOpts|nil
---@return agent.mcp.Dispatch|nil dispatch, string|nil err
function Server:handle_json(session, text, opts)
  local ok, msg = M.decode(text)
  if not ok or type(msg) ~= 'table' then
    log.debug('unparseable message dropped: %s', tostring(msg))
    return nil, 'parse error'
  end
  return self:handle(session, msg, opts)
end

---Cancel a pending client request (as notifications/cancelled does).
---@param session agent.mcp.Session
---@param id string|number
---@param reason string|nil default 'cancelled'
---@param detail any
---@return boolean cancelled
function Server:cancel_request(session, id, reason, detail)
  local entry = session and session._pending[id_key(id)]
  if not entry or entry.method == 'initialize' then
    return false
  end
  return self:_cancel_entry(entry, reason or 'cancelled', detail)
end

function Server:_settle(entry, response)
  if entry.settled then
    return false
  end
  entry.settled = true
  local session = entry.session
  if session._pending[entry.key] == entry then
    session._pending[entry.key] = nil
  end
  entry.dispatch:_deliver(response)
  return true
end

function Server:_cancel_entry(entry, reason, detail)
  if entry.settled then
    return false
  end
  local ctx = entry.ctx
  ctx.cancelled, ctx.cancel_reason, ctx.cancel_detail = true, reason, detail
  local cbs = entry.cancel_cbs
  entry.cancel_cbs = {}
  -- Settle first: a respond() from inside a cancel callback must not produce a response.
  self:_settle(entry, nil)
  log.debug('request %s (%s) cancelled: %s', tostring(entry.id), entry.method, reason)
  for _, cb in ipairs(cbs) do
    safe_call('on_cancel callback', cb, reason, detail)
  end
  return true
end

local entry_seq = 0

function Server:_make_ctx(entry, params)
  local meta = type(params) == 'table' and type(params._meta) == 'table' and params._meta or nil
  local ctx = {
    server = self,
    session = entry.session,
    request_id = entry.id,
    method = entry.method,
    meta = meta,
    progress_token = meta and meta.progressToken,
    cancelled = false,
  }
  function ctx.on_cancel(cb)
    if ctx.cancelled then
      safe_call('on_cancel callback', cb, ctx.cancel_reason, ctx.cancel_detail)
    elseif not entry.settled then
      table.insert(entry.cancel_cbs, cb)
    end
  end
  function ctx.notify(method, p)
    local note = { jsonrpc = '2.0', method = method, params = normalize_params(p) }
    local on_notify = entry.dispatch._on_notify
    if on_notify and not entry.settled then
      local ok, sent = xpcall(on_notify, debug.traceback, note)
      if ok and sent then
        return true
      end
    end
    return self:notify(entry.session, method, p)
  end
  function ctx.progress(progress, total, message)
    if ctx.progress_token == nil then
      return false
    end
    return ctx.notify('notifications/progress', {
      progressToken = ctx.progress_token,
      progress = progress,
      total = total,
      message = message,
    })
  end
  function ctx.is_active()
    return not entry.settled
  end
  return ctx
end

function Server:_request(session, m, d)
  local id = m.id
  local key = id_key(id)
  if session._pending[key] then
    return d:_deliver(error_response(id, M.rpc_error(M.INVALID_REQUEST, 'Invalid Request: duplicate request id')))
  end
  local params = m.params
  if params ~= nil and type(params) ~= 'table' then
    return d:_deliver(error_response(id, M.rpc_error(M.INVALID_PARAMS, 'Invalid params: params must be an object or array')))
  end
  entry_seq = entry_seq + 1
  local entry = {
    id = id,
    key = key,
    seq = entry_seq,
    method = m.method,
    session = session,
    dispatch = d,
    settled = false,
    cancel_cbs = {},
  }
  entry.ctx = self:_make_ctx(entry, params)
  table.insert(d._entries, entry)
  session._pending[key] = entry

  local function respond(result, err)
    if entry.settled then
      return false
    end
    if err ~= nil then
      return self:_settle(entry, error_response(id, err))
    end
    if result == nil then
      result = vim.empty_dict()
    end
    return self:_settle(entry, { jsonrpc = '2.0', id = id, result = result })
  end

  local custom = self._methods[m.method]
  local builtin = M.methods[m.method]
  if not custom and not builtin then
    return respond(nil, M.rpc_error(M.METHOD_NOT_FOUND, 'Method not found', 'Unknown method: ' .. m.method))
  end
  params = params or {}
  local ok, res
  if custom and not custom.async then
    ok, res = xpcall(custom.fn, on_handler_error, params, entry.ctx)
    if ok then
      respond(res)
    end
  elseif custom then
    ok, res = xpcall(custom.fn, on_handler_error, params, entry.ctx, respond)
  else
    ok, res = xpcall(builtin, on_handler_error, self, params, entry.ctx, respond)
  end
  if not ok then
    respond(nil, res)
  end
end

function Server:_notification(session, m)
  local method, params = m.method, m.params
  if method == 'notifications/initialized' then
    session.ready = true
  elseif method == 'notifications/cancelled' then
    local rid = type(params) == 'table' and params.requestId or nil
    if valid_id(rid) then
      local detail = type(params.reason) == 'string' and params.reason or nil
      self:cancel_request(session, rid, 'cancelled', detail)
    end
  end
  if self._on_notification then
    safe_call('on_notification(' .. method .. ')', self._on_notification, session, method, params)
  end
end

function Server:_client_response(session, m)
  local key = id_key(m.id)
  local out = session._outgoing[key]
  if not out then
    log.debug('response to an unknown request %s ignored', tostring(m.id))
    return
  end
  session._outgoing[key] = nil
  self:_finish_outgoing(out, m.result, m.error)
end

-- Built-in methods -------------------------------------------------------------

---Built-in request handlers: fn(server, params, ctx, respond).
M.methods = {}

M.methods['initialize'] = function(self, params, ctx, respond)
  local session = ctx.session
  local requested = type(params.protocolVersion) == 'string' and params.protocolVersion or nil
  local result = {
    protocolVersion = self._version_policy(requested, session),
    capabilities = objectify(vim.deepcopy(self.capabilities)),
    serverInfo = { name = self.name, version = self.version, title = self.title },
    instructions = self.instructions,
  }
  session.client_info = type(params.clientInfo) == 'table' and params.clientInfo or nil
  session.client_capabilities = type(params.capabilities) == 'table' and params.capabilities or nil
  session.requested_protocol_version = requested
  session.protocol_version = result.protocolVersion
  if self._on_initialize then
    local extra = self._on_initialize(session, params, result)
    if type(extra) == 'table' then
      for k, v in pairs(extra) do
        result[k] = v
      end
    end
  end
  session.initialized = true
  respond(result)
end

M.methods['ping'] = function(_, _, _, respond)
  respond(vim.empty_dict())
end

M.methods['tools/list'] = function(self, _, ctx, respond)
  respond({ tools = self:list_tools(ctx.session) })
end

local function missing_required(schema, args)
  if type(schema) ~= 'table' or type(schema.required) ~= 'table' then
    return nil
  end
  for _, name in ipairs(schema.required) do
    if args[name] == nil then
      return name
    end
  end
  return nil
end

M.methods['tools/call'] = function(self, params, ctx, respond)
  local name = params.name
  if type(name) ~= 'string' then
    return respond(nil, M.rpc_error(M.INVALID_PARAMS, 'Invalid params: tool name is required'))
  end
  local tool = self._tools[name]
  if not tool then
    return respond(nil, M.rpc_error(M.INVALID_PARAMS, 'Unknown tool: ' .. name))
  end
  local args = params.arguments
  if args == nil then
    args = {}
  elseif type(args) ~= 'table' then
    return respond(nil, M.rpc_error(M.INVALID_PARAMS, 'Invalid params: arguments must be an object'))
  end
  local def = tool.def
  local validate = def.validate
  if validate == nil then
    validate = self.validate_arguments
  end
  if validate then
    local missing = missing_required(tool.spec.inputSchema, args)
    if missing then
      return respond(nil, M.rpc_error(M.INVALID_PARAMS, 'Invalid params: missing required parameter: ' .. missing))
    end
  end
  ctx.tool = name
  if def.async then
    def.handler(args, ctx, function(result, err)
      if err ~= nil then
        return respond(nil, err)
      end
      return respond(M.tool_result(result))
    end)
  else
    respond(M.tool_result(def.handler(args, ctx)))
  end
end

return M
