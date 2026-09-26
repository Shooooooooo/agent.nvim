-- Test fixture for tests/node/mcp_streamable.test.mjs.
-- Usage: nvim --headless -u NONE -i NONE -n -l mcp_server.lua <repo_root> <socket_path>
-- Serves one agent.mcp.server core through four Streamable HTTP bindings:
--   gemini  - TCP, Host/Origin/Bearer checks, no DELETE, second GET replaces, response_mode auto
--   copilot - Unix socket, Nonce auth, X-Copilot-Session-Id policy, second GET rejected, auto
--   sse     - TCP, Bearer, response_mode sse
--   json    - TCP, Bearer, response_mode json
-- Prints one JSON line with the addresses once listening. stdin commands (one per line, one JSON
-- line printed per command): "stats", "broadcast <method>", "quit" (or EOF: close and exit).
local root, sock = arg[1], arg[2]
vim.opt.rtp:prepend(root)

local McpServer = require('agent.mcp.server')
local streamable = require('agent.mcp.streamable_http')

local TOKEN = 'gemini-token-0123456789abcdef'
local NONCE = 'Nonce copilot-nonce-0123456789abcdef'
local KEEPALIVE_MS = 100

local function out(tbl)
  io.stdout:write(vim.json.encode(tbl) .. '\n')
  io.stdout:flush()
end

vim.notify = function(msg)
  io.stderr:write('[mcp_server] ' .. tostring(msg) .. '\n')
end

local stats = {
  started = {},
  cancelled = {},
  session_closes = {},
  stream_opens = 0,
  stream_closes = {},
  notifications = {},
}

local srv = McpServer.new({
  name = 'agent.nvim-test',
  version = '0.1.0',
  capabilities = { tools = { listChanged = false }, logging = {} },
  on_notification = function(_, method)
    table.insert(stats.notifications, method)
  end,
  on_session_close = function(session, reason)
    table.insert(stats.session_closes, { id = session.id, reason = reason, profile = session.info.profile })
  end,
})

srv:add_tool({
  name = 'echo',
  description = 'Echo text back',
  inputSchema = { type = 'object', properties = { text = { type = 'string' } }, required = { 'text' } },
  handler = function(args)
    return args.text
  end,
})

srv:add_tool({
  name = 'add',
  description = 'Add two numbers (JSON result)',
  inputSchema = { type = 'object', properties = { a = { type = 'number' }, b = { type = 'number' } }, required = { 'a', 'b' } },
  handler = function(args)
    return { sum = args.a + args.b }
  end,
})

srv:add_tool({
  name = 'noargs',
  description = 'No arguments',
  inputSchema = { type = 'object', properties = {} },
  handler = function(_, ctx)
    return { session = ctx.session.id, protocol = ctx.session.protocol_version }
  end,
})

srv:add_tool({
  name = 'sleep',
  description = 'Answer after ms milliseconds',
  async = true,
  inputSchema = { type = 'object', properties = { ms = { type = 'number' } }, required = { 'ms' } },
  handler = function(args, _, respond)
    vim.defer_fn(function()
      respond('slept ' .. args.ms)
    end, args.ms)
  end,
})

srv:add_tool({
  name = 'block',
  description = 'Never answers; records how it was cancelled',
  async = true,
  inputSchema = { type = 'object', properties = { tag = { type = 'string' } }, required = { 'tag' } },
  handler = function(args, ctx)
    stats.started[args.tag] = true
    ctx.on_cancel(function(reason, detail)
      stats.cancelled[args.tag] = { reason = reason, detail = detail or vim.NIL }
    end)
  end,
})

srv:add_tool({
  name = 'progress',
  description = 'Send progress notifications, then answer',
  async = true,
  inputSchema = { type = 'object', properties = { steps = { type = 'number' }, ms = { type = 'number' } } },
  handler = function(args, ctx, respond)
    local steps, ms, i = args.steps or 2, args.ms or 30, 0
    local function tick()
      if not ctx.is_active() then
        return
      end
      i = i + 1
      if i > steps then
        respond('progressed ' .. steps)
        return
      end
      ctx.progress(i, steps, 'step ' .. i)
      vim.defer_fn(tick, ms)
    end
    vim.defer_fn(tick, ms)
  end,
})

srv:add_tool({
  name = 'notify',
  description = 'Send test/hello to the calling session (on its GET stream)',
  inputSchema = { type = 'object', properties = { text = { type = 'string' } } },
  handler = function(args, ctx)
    return { sent = ctx.session:notify('test/hello', { text = args.text or 'hi' }) }
  end,
})

srv:add_tool({
  name = 'fail',
  description = 'Always fails with a JSON-RPC error',
  handler = function()
    error(McpServer.rpc_error(-32000, 'intentional failure'))
  end,
})

srv:add_tool({
  name = 'secret',
  description = 'Hidden but callable',
  hidden = true,
  handler = function()
    return 'hidden result'
  end,
})

local function stream_hooks(profile)
  return {
    on_stream_open = function(session)
      stats.stream_opens = stats.stream_opens + 1
      -- Like Gemini's initial ide/contextUpdate / Copilot's selection replay.
      session:notify('test/stream_open', { session = session.id })
    end,
    on_stream_close = function(session, reason)
      table.insert(stats.stream_closes, { id = session.id, reason = reason, profile = profile })
    end,
  }
end

local function tag_profile(profile, extra)
  return function(req, msg, binding)
    local info = { profile = profile }
    if extra then
      local a, b, c, d = extra(req, msg, binding)
      if a == false then
        return a, b, c, d
      end
      if type(a) == 'table' then
        info = vim.tbl_extend('force', info, a)
      end
    end
    return info
  end
end

local bindings = {}

local gemini
gemini = assert(streamable.attach({ tcp = { host = '127.0.0.1', port = 0 } }, srv, vim.tbl_extend('force', {
  authorize = streamable.all({
    streamable.check_host(function()
      return { '127.0.0.1:' .. gemini.port, 'localhost:' .. gemini.port }
    end),
    streamable.check_origin(),
    streamable.check_authorization('Bearer ' .. TOKEN),
  }),
  allow_delete = false,
  second_stream = 'replace',
  sse_keepalive_ms = KEEPALIVE_MS,
  idle_session_timeout_ms = 800,
  accept_initialize = tag_profile('gemini'),
}, stream_hooks('gemini'))))
bindings.gemini = gemini

bindings.copilot = assert(streamable.attach({ pipe = sock }, srv, vim.tbl_extend('force', {
  authorize = streamable.check_authorization(NONCE),
  accept_initialize = tag_profile('copilot', streamable.copilot_initialize_policy()),
  second_stream = 'reject',
  sse_keepalive_ms = KEEPALIVE_MS,
}, stream_hooks('copilot'))))

bindings.sse = assert(streamable.attach({ tcp = { host = '127.0.0.1', port = 0 } }, srv, vim.tbl_extend('force', {
  authorize = streamable.check_authorization('Bearer ' .. TOKEN),
  response_mode = 'sse',
  sse_keepalive_ms = KEEPALIVE_MS,
  accept_initialize = tag_profile('sse'),
}, stream_hooks('sse'))))

bindings.json = assert(streamable.attach({ tcp = { host = '127.0.0.1', port = 0 } }, srv, vim.tbl_extend('force', {
  authorize = streamable.check_authorization('Bearer ' .. TOKEN),
  response_mode = 'json',
  sse_keepalive_ms = KEEPALIVE_MS,
  accept_initialize = tag_profile('json'),
}, stream_hooks('json'))))

out({
  gemini_port = bindings.gemini.port,
  sse_port = bindings.sse.port,
  json_port = bindings.json.port,
  pipe = bindings.copilot.socket_path,
  token = TOKEN,
  nonce = NONCE,
  keepalive_ms = KEEPALIVE_MS,
})

local function session_list()
  local res = {}
  for name, b in pairs(bindings) do
    res[name] = {}
    for _, s in ipairs(b:sessions()) do
      table.insert(res[name], {
        id = s.id,
        stream_open = s.info.stream_open,
        pending = s:pending_count(),
        copilot_session_id = s.info.copilot_session_id or vim.NIL,
        client = s.client_info and s.client_info.name or vim.NIL,
      })
    end
  end
  return res
end

local quit = false
local function close_all()
  for _, b in pairs(bindings) do
    b:close()
  end
end

local stdin = vim.uv.new_pipe(false)
stdin:open(0)
local pending = ''
stdin:read_start(function(err, chunk)
  if err or not chunk then
    quit = true
    return
  end
  pending = pending .. chunk
  for line in pending:gmatch('([^\n]*)\n') do
    vim.schedule(function()
      if line == 'stats' then
        out(vim.tbl_extend('force', stats, { sessions = session_list() }))
      elseif line:match('^broadcast ') then
        out({ sent = srv:broadcast(line:sub(11), { via = 'broadcast' }) })
      elseif line:match('^ping ') then
        -- Server->client request on the session's GET stream; the client answers with a POST.
        local session = srv:get_session(line:sub(6))
        if not session then
          out({ error = 'no such session' })
          return
        end
        srv:request(session, 'ping', nil, function(result, perr)
          out({ result = result or vim.NIL, error = perr or vim.NIL })
        end, { timeout_ms = 3000 })
      elseif line == 'quit' then
        quit = true
      end
    end)
  end
  pending = pending:match('[^\n]*$')
end)

vim.wait(300000, function()
  return quit
end, 20)
close_all()
vim.wait(100)
stdin:close()
