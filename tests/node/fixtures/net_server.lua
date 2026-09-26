-- Test fixture for tests/node/net.test.mjs.
-- Usage: nvim --headless -u NONE -i NONE -n -l net_server.lua <repo_root> <socket_path> [token]
-- Prints one JSON line {http_port, pipe, ws_port} on stdout once listening.
-- stdin commands (one per line): "close" closes every server and prints {"closed":true,...};
-- "quit" (or EOF) closes everything and exits. Exits by itself after 180 s.
local root, sock, token = arg[1], arg[2], arg[3] or 'test-token-0123456789'
vim.opt.rtp:prepend(root)

local uv = vim.uv
local http = require('agent.net.http')
local websocket = require('agent.net.websocket')
local sha1 = require('agent.crypto.sha1')

local function out(tbl)
  io.stdout:write(vim.json.encode(tbl) .. '\n')
  io.stdout:flush()
end

local function err(msg)
  io.stderr:write('[net_server] ' .. msg .. '\n')
end

vim.notify = function(msg)
  err(tostring(msg))
end

local stats = { sse_closed = 0, requests = 0, ws_open = 0, ws_closes = {}, ws_messages = 0 }

local function json(res, status, tbl)
  res:write_head(status, { ['Content-Type'] = 'application/json' })
  res:finish(vim.json.encode(tbl))
end

local function on_request(req, res)
  stats.requests = stats.requests + 1
  local p = req.path
  if p == '/echo' then
    json(res, 200, {
      method = req.method,
      path = req.path,
      query = next(req.query) and req.query or vim.empty_dict(),
      headers = req.headers,
      version = req.version,
      conn = req.conn_id,
      transport = req.transport,
      body_len = #req.body,
      body_sha1 = sha1.hex(req.body),
      body = #req.body <= 4096 and req.body or nil,
    })
  elseif p == '/sse' then
    local count = tonumber(req.query.count) or 3
    local interval = tonumber(req.query.interval) or 20
    res:on_close(function()
      stats.sse_closed = stats.sse_closed + 1
    end)
    res:start_stream(200, {
      ['Content-Type'] = 'text/event-stream',
      ['Cache-Control'] = 'no-cache, no-transform',
      ['X-Conn'] = req.conn_id,
    })
    res:sse_comment('stream open')
    local i = 0
    local timer = uv.new_timer()
    timer:start(interval, interval, vim.schedule_wrap(function()
      if res.closed then
        timer:stop()
        timer:close()
        return
      end
      i = i + 1
      if i <= count then
        res:sse(vim.json.encode({ n = i }), { event = 'message' })
        if i == 1 then
          res:sse('first line\nsecond line', { event = 'multi', id = 'id-1' })
        end
      else
        timer:stop()
        timer:close()
        if req.query['end'] == '1' then
          res:finish()
        else
          res:sse_comment('keepalive')
        end
      end
    end))
  elseif p == '/stats' then
    json(res, 200, stats)
  elseif p == '/slow' then
    vim.defer_fn(function()
      json(res, 200, { conn = req.conn_id })
    end, tonumber(req.query.ms) or 200)
  elseif p == '/big' then
    res:write_head(200, { ['Content-Type'] = 'application/octet-stream' })
    res:finish(string.rep('b', tonumber(req.query.size) or 1024))
  else
    res:write_head(404, { ['Content-Type'] = 'text/plain' })
    res:finish('not found')
  end
end

local tcp_server, e1 = http.listen({ tcp = { host = '127.0.0.1', port = 0 }, on_request = on_request })
assert(tcp_server, e1)
local pipe_server, e2 = http.listen({ pipe = sock, on_request = on_request })
assert(pipe_server, e2)

local ws_server, e3 = websocket.listen({
  host = '127.0.0.1',
  port = 0,
  authenticate = function(headers)
    return websocket.constant_time_equals(headers['x-claude-code-ide-authorization'], token), 'Invalid authentication token'
  end,
  on_open = function()
    stats.ws_open = stats.ws_open + 1
  end,
  on_message = function(conn, text)
    stats.ws_messages = stats.ws_messages + 1
    local code = text:match('^close:(%d+)$')
    if code then
      conn:close(tonumber(code), 'requested')
    elseif text == 'stats' then
      conn:send(vim.json.encode(stats))
    elseif text == 'info' then
      conn:send(vim.json.encode({ protocol = conn.protocol or vim.NIL, id = conn.id }))
    else
      conn:send(text)
    end
  end,
  on_close = function(_, code, reason)
    table.insert(stats.ws_closes, { code = code, reason = reason })
  end,
})
assert(ws_server, e3)

out({ http_port = tcp_server.port, pipe = pipe_server.path, ws_port = ws_server.port })

local quit = false
local function close_all()
  tcp_server:close()
  pipe_server:close()
  ws_server:close()
end

local stdin = uv.new_pipe(false)
stdin:open(0)
local pending = ''
stdin:read_start(function(rerr, chunk)
  if rerr or not chunk then
    quit = true
    return
  end
  pending = pending .. chunk
  for line in pending:gmatch('([^\n]*)\n') do
    if line == 'close' then
      vim.schedule(function()
        close_all()
        out({ closed = true, socket_exists = uv.fs_stat(sock) ~= nil })
      end)
    elseif line == 'quit' then
      quit = true
    end
  end
  pending = pending:match('[^\n]*$')
end)

vim.wait(180000, function()
  return quit
end, 20)
close_all()
-- Let close frames and FINs go out.
vim.wait(100)
stdin:close()
