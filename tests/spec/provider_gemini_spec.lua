-- Tests for lua/agent/providers/gemini.lua (the Gemini CLI IDE companion server).
-- The client side is a raw HTTP/1.1 client on vim.uv that sends what Gemini 0.61 sends
-- (specs/gemini.md §4.1, §5.1): initialize (2025-06-18), notifications/initialized, GET SSE,
-- tools/list, tools/call.
local P = require('agent.providers.gemini')
local diff = require('agent.editor.diff')
local selection = require('agent.editor.selection')
local config = require('agent.config')
local util = require('agent.util')

local uv = vim.uv
local api = vim.api

local handles = {}
local tmp

-- ---------------------------------------------------------------------------
-- Raw HTTP client
-- ---------------------------------------------------------------------------

local function send_raw(port, raw)
  local r = { chunks = {}, closed = false }
  local tcp = uv.new_tcp()
  r.tcp = tcp
  handles[#handles + 1] = tcp
  tcp:connect('127.0.0.1', port, function(err)
    if err then
      r.err, r.closed = err, true
      return
    end
    tcp:write(raw)
    tcp:read_start(function(rerr, chunk)
      if rerr or not chunk then
        r.closed = true
        if not tcp:is_closing() then
          tcp:close()
        end
        return
      end
      r.chunks[#r.chunks + 1] = chunk
    end)
  end)
  return r
end

local function request(port, method, path, headers, body)
  local h = { Host = '127.0.0.1:' .. port }
  for k, v in pairs(headers or {}) do
    h[k] = v
  end
  if body then
    h['Content-Length'] = tostring(#body)
  end
  local lines = { method .. ' ' .. path .. ' HTTP/1.1' }
  for k, v in pairs(h) do
    if v ~= false then
      lines[#lines + 1] = k .. ': ' .. v
    end
  end
  return send_raw(port, table.concat(lines, '\r\n') .. '\r\n\r\n' .. (body or ''))
end

-- Parse what arrived so far: { status, headers, body, complete }.
local function parse(r)
  local data = table.concat(r.chunks)
  local head_end = data:find('\r\n\r\n', 1, true)
  if not head_end then
    return nil
  end
  local head = data:sub(1, head_end - 1)
  local rest = data:sub(head_end + 4)
  local status = tonumber(head:match('^HTTP/1%.1 (%d+)'))
  local headers = {}
  for line in head:gmatch('[^\r\n]+') do
    local k, v = line:match('^([^:]+):%s*(.*)$')
    if k then
      headers[k:lower()] = v
    end
  end
  local body, complete
  if headers['transfer-encoding'] == 'chunked' then
    complete = false
    local parts, pos = {}, 1
    while true do
      local e = rest:find('\r\n', pos, true)
      if not e then
        break
      end
      local size = tonumber(rest:sub(pos, e - 1), 16)
      if not size then
        break
      end
      if size == 0 then
        complete = true
        break
      end
      if #rest < e + 1 + size + 2 then
        break
      end
      parts[#parts + 1] = rest:sub(e + 2, e + 1 + size)
      pos = e + 2 + size + 2
    end
    body = table.concat(parts)
  else
    local len = tonumber(headers['content-length'] or '')
    if len then
      body = rest:sub(1, len)
      complete = #rest >= len
    else
      body = rest
      complete = r.closed
    end
  end
  return { status = status, headers = headers, body = body, complete = complete }
end

local function close(r)
  if r.tcp and not r.tcp:is_closing() then
    r.tcp:close()
  end
end

local function fetch(port, method, path, headers, body)
  local r = request(port, method, path, headers, body)
  local res
  wait_for(function()
    res = parse(r)
    return (res and res.complete) or r.closed
  end, 5000, method .. ' ' .. path)
  res = res or parse(r) or { status = nil, headers = {}, body = '' }
  close(r)
  return res
end

-- SSE events of a GET stream: { events = {{event=, data=}}, comments = n }.
local function sse(r)
  local res = parse(r)
  local out = { events = {}, comments = 0, status = res and res.status, headers = res and res.headers or {},
    complete = res and res.complete }
  if not res then
    return out
  end
  for block in (res.body .. ''):gmatch('(.-)\n\n') do
    local ev = { data = {} }
    local is_comment = true
    for line in (block .. '\n'):gmatch('(.-)\n') do
      if line:sub(1, 1) == ':' then
        out.comments = out.comments + 1
      else
        is_comment = false
        local k, v = line:match('^(%w+): ?(.*)$')
        if k == 'data' then
          ev.data[#ev.data + 1] = v
        elseif k then
          ev[k] = v
        end
      end
    end
    if not is_comment then
      ev.data = table.concat(ev.data, '\n')
      ev.msg = vim.json.decode(ev.data)
      out.events[#out.events + 1] = ev
    end
  end
  return out
end

-- ---------------------------------------------------------------------------
-- A client that behaves like Gemini 0.61 (headers from specs/gemini.md §4.1)
-- ---------------------------------------------------------------------------

local Client = {}
Client.__index = Client

local function new_client(info)
  return setmetatable({ port = info.port, token = info.token, next_id = 0 }, Client)
end

function Client:headers(extra)
  local h = {
    Connection = 'keep-alive',
    Accept = 'application/json, text/event-stream',
    Authorization = 'Bearer ' .. self.token,
    ['Content-Type'] = 'application/json',
    ['accept-language'] = '*',
    ['sec-fetch-mode'] = 'cors',
    ['User-Agent'] = 'undici',
  }
  if self.sid then
    h['mcp-protocol-version'] = '2025-06-18'
    h['mcp-session-id'] = self.sid
  end
  for k, v in pairs(extra or {}) do
    h[k] = v
  end
  return h
end

function Client:post(msg, extra)
  return fetch(self.port, 'POST', '/mcp', self:headers(extra), vim.json.encode(msg))
end

function Client:call(method, params)
  local id = self.next_id
  self.next_id = id + 1
  local res = self:post({ method = method, params = params, jsonrpc = '2.0', id = id })
  res.json = res.body ~= '' and vim.json.decode(res.body) or nil
  return res
end

function Client:tool(name, args)
  return self:call('tools/call', { name = name, arguments = args })
end

function Client:connect(opts)
  local init = self:call('initialize', {
    protocolVersion = opts and opts.version or '2025-06-18',
    capabilities = vim.empty_dict(),
    clientInfo = { name = 'streamable-http-client', version = '0.61.0' },
  })
  self.init = init
  self.sid = init.headers['mcp-session-id']
  self.initialized = self:post({ method = 'notifications/initialized', jsonrpc = '2.0' })
  if not (opts and opts.no_stream) then
    self:open_stream()
  end
  return self
end

function Client:open_stream()
  local h = self:headers({ Accept = 'text/event-stream' })
  h['Content-Type'] = false
  self.stream = request(self.port, 'GET', '/mcp', h)
  wait_for(function()
    return parse(self.stream) ~= nil
  end, 5000, 'GET stream head')
  return self.stream
end

function Client:events(method)
  local all = sse(self.stream).events
  if not method then
    return all
  end
  return vim.tbl_filter(function(e)
    return e.msg.method == method
  end, all)
end

function Client:wait_event(method, n)
  n = n or 1
  wait_for(function()
    return #self:events(method) >= n
  end, 5000, method)
  return self:events(method)[n].msg
end

-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------

local function write(path, text)
  local f = assert(io.open(path, 'wb'))
  f:write(text)
  f:close()
end

local function readf(path)
  local f = io.open(path, 'rb')
  if not f then
    return nil
  end
  local d = f:read('*a')
  f:close()
  return d
end

local function start(opts)
  local ok, err = P.start(vim.tbl_extend('force', {
    discovery_dir = tmp .. '/disc',
    keepalive_ms = 20000,
    context_debounce_ms = 10,
    orphan_grace_ms = 200,
  }, opts or {}))
  assert.truthy(ok, err)
  local st = P._state()
  return { port = st.port, token = st.token, file = st.discovery_file }
end

local function diff_for(path)
  for _, id in ipairs(diff.list()) do
    local d = diff.get(id)
    if d and d.path == path then
      return d
    end
  end
  return nil
end

before_each(function()
  tmp = vim.fn.tempname()
  vim.fn.mkdir(tmp, 'p')
  tmp = util.realpath(tmp)
  config.setup({ diff = { open_in = 'tab' }, providers = { gemini = { discovery_dir = tmp .. '/disc' } },
    selection = { track = true } })
  selection._reset()
  P._reset()
end)

after_each(function()
  P._reset()
  diff.close_all()
  diff._stop_watchers()
  selection._reset()
  for _, h in ipairs(handles) do
    if not h:is_closing() then
      h:close()
    end
  end
  handles = {}
  vim.cmd('silent! %bwipeout!')
  vim.fn.delete(tmp, 'rf')
end)

-- ---------------------------------------------------------------------------
-- Tests
-- ---------------------------------------------------------------------------

describe('lifecycle and discovery', function()
  it('writes a 0600 discovery file with ideInfo neovim and the cwd, and removes it on stop', function()
    local info = start()
    assert.truthy(P.is_running())
    local name = vim.fs.basename(info.file)
    assert.eq(string.format('gemini-ide-server-%d-%d.json', vim.fn.getpid(), info.port), name)
    assert.truthy(name:match(P.FILE_PATTERN))
    local st = assert(uv.fs_stat(info.file))
    assert.eq(tonumber('600', 8), bit.band(st.mode, tonumber('777', 8)))
    assert.eq(tonumber('700', 8), bit.band(uv.fs_stat(tmp .. '/disc').mode, tonumber('777', 8)))
    local data = vim.json.decode(readf(info.file))
    assert.eq(info.port, data.port)
    assert.eq(info.token, data.authToken)
    assert.same({ name = 'neovim', displayName = 'Neovim' }, data.ideInfo)
    assert.eq(util.realpath(vim.fn.getcwd()), data.workspacePath)
    assert.truthy(#info.token >= 32, 'token has at least 128 bits')
    local status = P.status()
    assert.eq(true, status.running)
    assert.eq(info.file, status.lock)
    assert.eq('127.0.0.1:' .. info.port, status.address)
    P.stop()
    assert.falsy(P.is_running())
    assert.falsy(uv.fs_stat(info.file), 'discovery file removed')
    assert.eq(false, P.status().running)
  end)

  it('is idempotent and keeps port and token across a restart', function()
    local a = start()
    assert.truthy(P.start())
    assert.eq(a.port, P._state().port)
    P.stop()
    local b = start()
    assert.eq(a.port, b.port)
    assert.eq(a.token, b.token)
  end)

  it('env() sets all four connection variables and disables the stdio fallback', function()
    local info = start()
    local env = P.env({ cwd = tmp })
    assert.same({
      GEMINI_CLI_IDE_PID = tostring(vim.fn.getpid()),
      GEMINI_CLI_IDE_SERVER_PORT = tostring(info.port),
      GEMINI_CLI_IDE_AUTH_TOKEN = info.token,
      GEMINI_CLI_IDE_WORKSPACE_PATH = tmp,
      GEMINI_CLI_IDE_SERVER_STDIO_COMMAND = '',
    }, env)
    P.stop()
    assert.same({}, P.env())
  end)

  it('launch_info() returns port/token/pid/workspace and adds the cwd to workspacePath', function()
    local info = start()
    vim.fn.mkdir(tmp .. '/proj', 'p')
    local li = P.launch_info({ cwd = tmp .. '/proj' })
    assert.eq(info.port, li.port)
    assert.eq(info.token, li.token)
    assert.eq(vim.fn.getpid(), li.pid)
    assert.eq(tmp .. '/proj', li.workspace)
    local ws = vim.json.decode(readf(info.file)).workspacePath
    local parts = vim.split(ws, ':', { plain = true })
    assert.same({ util.realpath(vim.fn.getcwd()), tmp .. '/proj' }, parts)
    -- No duplicates, no empty segments.
    P.launch_info({ cwd = tmp .. '/proj' })
    assert.eq(ws, vim.json.decode(readf(info.file)).workspacePath)
    assert.falsy(ws:find('::', 1, true) or ws:sub(-1) == ':')
  end)

  it('writes workspace paths with % verbatim and skips paths containing ":"', function()
    -- Gemini URI-decodes both the workspace parts and its own cwd (resolveToRealPath), so only
    -- the verbatim path matches in a dir like "a%20b" (decoded to "a b" on both sides).
    local info = start()
    for _, d in ipairs({ '100%x', 'a%20b', 'a%25b', 'a:b' }) do
      vim.fn.mkdir(tmp .. '/' .. d, 'p')
      P.launch_info({ cwd = tmp .. '/' .. d })
    end
    local parts = vim.split(vim.json.decode(readf(info.file)).workspacePath, ':', { plain = true })
    for _, d in ipairs({ '100%x', 'a%20b', 'a%25b' }) do
      assert.truthy(vim.tbl_contains(parts, tmp .. '/' .. d), vim.inspect(parts))
    end
    assert.falsy(vim.tbl_contains(parts, tmp .. '/a%2520b'), vim.inspect(parts))
    -- "a:b" would show up split in two.
    assert.falsy(vim.tbl_contains(parts, tmp .. '/a') or vim.tbl_contains(parts, 'b'), vim.inspect(parts))
  end)

  it('before_spawn adds the job cwd, restores a deleted discovery file and covers a different TMPDIR', function()
    local info = start()
    vim.fn.mkdir(tmp .. '/job', 'p')
    os.remove(info.file)
    P.before_spawn({ cwd = tmp .. '/job', env = {}, warnings = { { id = 'gemini-ide-disabled' } } })
    local data = vim.json.decode((assert(readf(info.file))))
    assert.matches(vim.pesc(tmp .. '/job') .. '$', data.workspacePath)
    P.stop()
    -- Without a discovery_dir override the file goes to <tmpdir>/gemini/ide, and a child whose
    -- TMPDIR differs gets its own copy. Neovim's TMPDIR points into the test dir here, so the
    -- real $TMPDIR/gemini/ide is never touched.
    local saved_tmpdir = vim.env.TMPDIR
    vim.env.TMPDIR = tmp .. '/nvimtmp'
    config.setup({ diff = { open_in = 'tab' }, selection = { track = true } })
    local ok, err = pcall(function()
      assert.eq(tmp .. '/nvimtmp/gemini/ide', P.default_discovery_dir())
      assert.truthy(P.start({ keepalive_ms = 20000 }))
      local st = P._state()
      local own = st.discovery_file
      assert.eq(tmp .. '/nvimtmp/gemini/ide', vim.fs.dirname(own))
      local child_tmp = tmp .. '/childtmp'
      vim.fn.mkdir(child_tmp, 'p')
      P.before_spawn({ cwd = tmp, env = { TMPDIR = child_tmp .. '/' }, warnings = { { id = 'gemini-ide-disabled' } } })
      local extra = string.format('%s/gemini/ide/gemini-ide-server-%d-%d.json', child_tmp, st.pid, st.port)
      assert.truthy(uv.fs_stat(extra), 'discovery file in the child tmpdir')
      assert.eq(tonumber('600', 8), bit.band(uv.fs_stat(extra).mode, tonumber('777', 8)))
      -- Same TMPDIR as Neovim: no second file.
      P.before_spawn({ cwd = tmp, env = {}, warnings = { { id = 'gemini-ide-disabled' } } })
      assert.eq(2, vim.tbl_count(P._state().files))
      P.stop()
      assert.falsy(uv.fs_stat(extra))
      assert.falsy(uv.fs_stat(own))
    end)
    P.stop()
    vim.env.TMPDIR = saved_tmpdir
    assert.truthy(ok, err)
  end)

  it('caps the keep-alive interval at 30 s and follows :cd into workspacePath', function()
    local info = start({ keepalive_ms = 999999 })
    assert.eq(30000, P._state().cfg.keepalive_ms)
    local cwd = vim.fn.getcwd()
    vim.fn.mkdir(tmp .. '/cdhere', 'p')
    vim.cmd.cd(vim.fn.fnameescape(tmp .. '/cdhere'))
    local ws = vim.json.decode(readf(info.file)).workspacePath
    vim.cmd.cd(vim.fn.fnameescape(cwd))
    assert.matches(vim.pesc(':' .. tmp .. '/cdhere') .. '$', ws)
  end)

  it('removes only stale Neovim discovery files', function()
    local d = tmp .. '/disc'
    vim.fn.mkdir(d, 'p')
    -- A dead pid: find one that does not exist.
    local dead = 99999
    while uv.kill(dead, 0) == 0 do
      dead = dead - 1
    end
    local neovim = vim.json.encode({ port = 1, workspacePath = '/x', authToken = 't', ideInfo = { name = 'neovim', displayName = 'Neovim' } })
    write(d .. '/gemini-ide-server-' .. dead .. '-1111.json', neovim)
    write(d .. '/gemini-ide-server-' .. dead .. '-2222.json', vim.json.encode({ port = 2, workspacePath = '/x', authToken = 't' }))
    write(d .. '/gemini-ide-server-1-3333.json', neovim) -- pid 1 is alive (EPERM counts as alive)
    write(d .. '/gemini-ide-server-' .. dead .. '.json', neovim) -- legacy name: not ours to touch
    write(d .. '/notes.txt', 'x')
    start()
    assert.falsy(uv.fs_stat(d .. '/gemini-ide-server-' .. dead .. '-1111.json'), 'stale neovim file removed')
    assert.truthy(uv.fs_stat(d .. '/gemini-ide-server-' .. dead .. '-2222.json'), 'other IDE kept')
    assert.truthy(uv.fs_stat(d .. '/gemini-ide-server-1-3333.json'), 'live pid kept')
    assert.truthy(uv.fs_stat(d .. '/gemini-ide-server-' .. dead .. '.json'))
    assert.truthy(uv.fs_stat(d .. '/notes.txt'))
  end)

  it('shows the ide.enabled hint once unless the launcher already did', function()
    vim.wait(20) -- deliver notifications queued by earlier tests
    start()
    local home = tmp .. '/ghome'
    vim.fn.mkdir(home .. '/.gemini', 'p')
    write(home .. '/.gemini/settings.json', '{ // jsonc\n "ide": { "enabled": false } }')
    local shown = {}
    local orig = vim.notify
    vim.notify = function(msg)
      if msg:find('ide enable', 1, true) then
        shown[#shown + 1] = msg
      end
    end
    local env = { GEMINI_CLI_HOME = home, GEMINI_CLI_SYSTEM_DEFAULTS_PATH = tmp .. '/none.json', GEMINI_CLI_SYSTEM_SETTINGS_PATH = tmp .. '/none2.json' }
    P.before_spawn({ cwd = tmp, env = env, warnings = { { id = 'gemini-ide-disabled' } } })
    vim.wait(50)
    assert.eq(0, #shown, 'launcher already warned: ' .. table.concat(shown, ' | '))
    P._reset()
    start()
    P.before_spawn({ cwd = tmp, env = env, warnings = {} })
    P.before_spawn({ cwd = tmp, env = env, warnings = {} })
    vim.wait(50)
    vim.notify = orig
    assert.eq(1, #shown)
    assert.matches('/ide enable', shown[1])
    -- ide.enabled=true: no hint.
    write(home .. '/.gemini/settings.json', '{"ide":{"enabled":true}}')
    assert.truthy(P.ide_enabled({ environ = env }))
  end)

  it('exports the connection variables into Neovim only when export_env is set, and restores them', function()
    vim.env.GEMINI_CLI_IDE_PID = nil
    start()
    assert.eq(nil, vim.env.GEMINI_CLI_IDE_PID)
    P.stop()
    vim.env.GEMINI_CLI_IDE_AUTH_TOKEN = 'outer'
    local info = start({ export_env = true })
    assert.eq(tostring(vim.fn.getpid()), vim.env.GEMINI_CLI_IDE_PID)
    assert.eq(tostring(info.port), vim.env.GEMINI_CLI_IDE_SERVER_PORT)
    assert.eq(info.token, vim.env.GEMINI_CLI_IDE_AUTH_TOKEN)
    P.stop()
    assert.eq(nil, vim.env.GEMINI_CLI_IDE_PID)
    assert.eq('outer', vim.env.GEMINI_CLI_IDE_AUTH_TOKEN)
    vim.env.GEMINI_CLI_IDE_AUTH_TOKEN = nil
  end)
end)

describe('HTTP request validation', function()
  it('checks Host, Origin and Bearer in that order, refuses DELETE and other paths', function()
    local info = start()
    local c = new_client(info)
    local init = { method = 'initialize', params = { protocolVersion = '2025-06-18' }, jsonrpc = '2.0', id = 0 }
    local r = c:post(init, { Host = 'evil.example:' .. info.port })
    assert.eq(403, r.status)
    assert.same({ error = 'Invalid Host header' }, vim.json.decode(r.body))
    r = c:post(init, { Origin = 'http://127.0.0.1:' .. info.port })
    assert.eq(403, r.status)
    assert.same({ error = 'Request denied by CORS policy.' }, vim.json.decode(r.body))
    r = c:post(init, { Authorization = 'Bearer wrong' })
    assert.eq(401, r.status)
    assert.eq('Unauthorized', r.body)
    r = c:post(init, { Authorization = false })
    assert.eq(401, r.status)
    r = c:post(init, { Authorization = 'bearer ' .. info.token })
    assert.eq(401, r.status)
    r = c:post(init, { Host = 'localhost:' .. info.port })
    assert.eq(200, r.status)
    r = fetch(info.port, 'POST', '/other', c:headers(), vim.json.encode(init))
    assert.eq(404, r.status)
    c:connect({ no_stream = true })
    r = fetch(info.port, 'DELETE', '/mcp', c:headers())
    assert.eq(405, r.status)
  end)

  it('answers 400 for session-less and unknown-session requests', function()
    local info = start()
    local c = new_client(info)
    local r = c:post({ method = 'tools/list', jsonrpc = '2.0', id = 1 })
    assert.eq(400, r.status)
    c.sid = 'no-such-session'
    r = c:post({ method = 'tools/list', jsonrpc = '2.0', id = 1 })
    assert.eq(400, r.status)
    local h = c:headers({ Accept = 'text/event-stream' })
    r = fetch(info.port, 'GET', '/mcp', h)
    assert.eq(400, r.status)
    c.sid = nil
    r = fetch(info.port, 'POST', '/mcp', c:headers(), '{not json')
    assert.eq(400, r.status)
    assert.eq(-32700, vim.json.decode(r.body).error.code)
  end)
end)

describe('MCP handshake', function()
  it('initialize echoes 2025-06-18 with object capabilities and issues a session id', function()
    local info = start()
    local c = new_client(info):connect({ no_stream = true })
    assert.eq(200, c.init.status)
    assert.matches('^application/json', c.init.headers['content-type'])
    assert.truthy(c.sid and #c.sid > 0)
    local result = c.init.json.result
    assert.eq('2025-06-18', result.protocolVersion)
    assert.eq('agent.nvim-gemini-companion', result.serverInfo.name)
    assert.eq('string', type(result.serverInfo.version))
    -- Objects, never [] (an array here makes Gemini refuse the handshake).
    assert.truthy(c.init.body:find('"tools":{"listChanged":false}', 1, true), c.init.body)
    assert.truthy(c.init.body:find('"logging":{}', 1, true), c.init.body)
    assert.eq(202, c.initialized.status)
    assert.eq('', c.initialized.body)
  end)

  it('negotiates the protocol version like Gemini expects', function()
    local info = start()
    for requested, expected in pairs({
      ['2025-06-18'] = '2025-06-18',
      ['2025-03-26'] = '2025-03-26',
      ['2024-11-05'] = '2024-11-05',
      ['2024-10-07'] = '2024-10-07',
      ['2099-01-01'] = '2025-06-18',
    }) do
      local c = new_client(info):connect({ version = requested, no_stream = true })
      assert.eq(expected, c.init.json.result.protocolVersion, requested)
    end
  end)

  it('tools/list lists exactly openDiff and closeDiff with object schemas; ping answers {}', function()
    local info = start()
    local c = new_client(info):connect({ no_stream = true })
    local r = c:call('tools/list', vim.empty_dict())
    local tools = r.json.result.tools
    assert.eq(2, #tools)
    assert.eq('openDiff', tools[1].name)
    assert.eq('(IDE Tool) Open a diff view to create or modify a file. Returns a notification once the diff has been accepted or rejected.', tools[1].description)
    assert.same({ type = 'object', properties = { filePath = { type = 'string' }, newContent = { type = 'string' } }, required = { 'filePath', 'newContent' } }, tools[1].inputSchema)
    assert.eq('closeDiff', tools[2].name)
    assert.eq('(IDE Tool) Close an open diff view for a specific file.', tools[2].description)
    assert.same({ type = 'object', properties = { filePath = { type = 'string' }, suppressNotification = { type = 'boolean' } }, required = { 'filePath' } }, tools[2].inputSchema)
    r = c:call('ping')
    assert.eq('{}', r.body:match('"result":(%b{})'))
    r = c:call('no/such/method')
    assert.eq(-32601, r.json.error.code)
    r = c:post({ method = 'notifications/cancelled', params = { requestId = 99 }, jsonrpc = '2.0' })
    assert.eq(202, r.status)
  end)

  it('opens the GET stream with SSE headers and sends ide/contextUpdate first', function()
    local file = tmp .. '/a.lua'
    write(file, 'local x = 1\nlocal y = "é"\n')
    vim.cmd('edit ' .. vim.fn.fnameescape(file))
    api.nvim_win_set_cursor(0, { 2, 13 })
    local info = start()
    local c = new_client(info):connect()
    local head = parse(c.stream)
    assert.eq(200, head.status)
    assert.eq('text/event-stream', head.headers['content-type'])
    assert.eq('no-cache, no-transform', head.headers['cache-control'])
    assert.eq(c.sid, head.headers['mcp-session-id'])
    local msg = c:wait_event('ide/contextUpdate')
    local ev = c:events()[1]
    assert.eq('message', ev.event)
    assert.eq(nil, ev.id)
    assert.truthy(P.validate_notification(msg.method, msg.params))
    local f = msg.params.workspaceState.openFiles[1]
    assert.eq(file, f.path)
    assert.eq(true, f.isActive)
    -- Byte column 13 is after 'local y = "é' (é is 2 bytes, 1 UTF-16 unit): 1-based UTF-16 = 13.
    assert.same({ line = 2, character = 13 }, f.cursor)
    assert.eq(nil, f.selectedText)
    assert.eq(nil, msg.params.workspaceState.isTrusted)
    assert.eq('number', type(f.timestamp))
    assert.truthy(f.timestamp > 1.7e12, 'wall-clock ms')
  end)

  it('sends no files, cursor or selected text with selection.track = false', function()
    config.setup({ diff = { open_in = 'tab' }, selection = { track = false },
      providers = { gemini = { discovery_dir = tmp .. '/disc' } } })
    local file = tmp .. '/a.lua'
    write(file, 'local x = 1\n')
    vim.cmd('edit ' .. vim.fn.fnameescape(file))
    vim.cmd('normal! 0v$')
    local info = start()
    local c = new_client(info):connect()
    c:wait_event('ide/contextUpdate')
    vim.cmd('normal! \27')
    assert.truthy(c:events()[1].data:find('{"workspaceState":{"openFiles":[]}}', 1, true), c:events()[1].data)
    assert.same({ workspaceState = { openFiles = {} } }, P.build_context())
  end)

  it('sends {"workspaceState":{"openFiles":[]}} when no file is open', function()
    -- (The empty buffer that has focus would be the active entry itself, nvim://buffer/<n>/scratch.)
    vim.b.agent_ignore = true
    local info = start()
    local c = new_client(info):connect()
    c:wait_event('ide/contextUpdate')
    assert.truthy(c:events()[1].data:find('{"workspaceState":{"openFiles":[]}}', 1, true), c:events()[1].data)
  end)

  it('sends keep-alive comments on the GET stream', function()
    local info = start({ keepalive_ms = 60 })
    local c = new_client(info):connect()
    wait_for(function()
      return sse(c.stream).comments >= 2
    end, 3000, 'keep-alive comments')
    assert.truthy(table.concat(c.stream.chunks):find(': keepalive\n\n', 1, true))
  end)

  it('a second GET replaces the first stream, which ends gracefully', function()
    local info = start()
    local c = new_client(info):connect()
    local first = c.stream
    c:wait_event('ide/contextUpdate')
    c:open_stream()
    wait_for(function()
      local p = parse(first)
      return p and p.complete
    end, 3000, 'first stream terminated with 0-chunk')
    c:wait_event('ide/contextUpdate')
    assert.eq(1, P.status().streams)
  end)
end)

describe('openDiff / closeDiff', function()
  local info, c, file

  before_each(function()
    file = tmp .. '/hello.txt'
    write(file, 'old line\n')
    info = start()
    c = new_client(info):connect()
    c:wait_event('ide/contextUpdate')
  end)

  it('answers {content: []} at once and sends ide/diffAccepted with the edited text on accept', function()
    local r = c:tool('openDiff', { filePath = file, newContent = 'hello from model\n' })
    assert.eq(200, r.status)
    assert.truthy(r.body:find('"result":{"content":[]}', 1, true), r.body)
    local d = assert(diff_for(file))
    assert.eq(file, d.id)
    assert.same({ 'hello from model' }, api.nvim_buf_get_lines(d.bufnr, 0, -1, false))
    api.nvim_buf_set_lines(d.bufnr, -1, -1, false, { 'EDITED-IN-IDE' })
    assert.truthy(diff.accept(d.id))
    local msg = c:wait_event('ide/diffAccepted')
    assert.same({ filePath = file, content = 'hello from model\nEDITED-IN-IDE\n' }, msg.params)
    assert.eq('old line\n', readf(file), 'the provider never writes the file')
    assert.eq(0, #diff.list())
    assert.eq(0, P.status().diffs)
    -- No closeDiff follows an accept; a late one finds nothing.
    r = c:tool('closeDiff', { filePath = file, suppressNotification = true })
    assert.eq('{}', r.json.result.content[1].text)
  end)

  it('echoes filePath byte for byte (symlinked /tmp form, spaces, non-ASCII)', function()
    local odd = tmp .. '/dir with spaces/ünï cødé.txt'
    vim.fn.mkdir(vim.fs.dirname(odd), 'p')
    c:tool('openDiff', { filePath = odd, newContent = 'x\n' })
    assert.truthy(diff.accept(assert(diff_for(odd)).id))
    assert.eq(odd, c:wait_event('ide/diffAccepted').params.filePath)
    -- A non-realpath form of an existing file (e.g. /tmp vs /private/tmp on macOS) is echoed as sent.
    local alias = tmp .. '/./hello.txt'
    c:tool('openDiff', { filePath = alias, newContent = 'y\n' })
    assert.truthy(diff.reject(assert(diff_for(alias)).id))
    assert.eq(alias, c:wait_event('ide/diffRejected').params.filePath)
  end)

  it('sends ide/diffRejected {filePath} on reject and when the diff UI is closed', function()
    c:tool('openDiff', { filePath = file, newContent = 'a\n' })
    assert.truthy(diff.reject(assert(diff_for(file)).id))
    local msg = c:wait_event('ide/diffRejected')
    assert.same({ filePath = file }, msg.params)
    c:tool('openDiff', { filePath = file, newContent = 'b\n' })
    local d = assert(diff_for(file))
    vim.cmd('bwipeout! ' .. d.bufnr)
    msg = c:wait_event('ide/diffRejected', 2)
    assert.same({ filePath = file }, msg.params)
    assert.eq(0, #c:events('ide/diffAccepted'))
  end)

  it('replaces an open diff for the same path silently', function()
    c:tool('openDiff', { filePath = file, newContent = 'first\n' })
    c:tool('openDiff', { filePath = file, newContent = 'second\n' })
    assert.eq(1, #diff.list())
    local d = assert(diff_for(file))
    assert.same({ 'second' }, api.nvim_buf_get_lines(d.bufnr, 0, -1, false))
    vim.wait(100)
    assert.eq(0, #c:events('ide/diffRejected'))
    assert.eq(0, #c:events('ide/diffAccepted'))
    assert.truthy(diff.accept(d.id))
    assert.eq('second\n', c:wait_event('ide/diffAccepted').params.content)
  end)

  it('closeDiff returns the proposal with user edits as JSON text and sends nothing', function()
    c:tool('openDiff', { filePath = file, newContent = '{"content": "json file"}\n' })
    local d = assert(diff_for(file))
    api.nvim_buf_set_lines(d.bufnr, -1, -1, false, { 'user edit' })
    local r = c:tool('closeDiff', { filePath = file, suppressNotification = true })
    local content = r.json.result.content
    assert.eq(1, #content)
    assert.eq('text', content[1].type)
    assert.same({ content = '{"content": "json file"}\nuser edit\n' }, vim.json.decode(content[1].text))
    assert.eq(0, #diff.list())
    vim.wait(100)
    assert.eq(0, #c:events('ide/diffRejected') + #c:events('ide/diffAccepted'))
    -- Without suppressNotification (gemini exiting / /ide disable) and without an open diff.
    r = c:tool('closeDiff', { filePath = file })
    assert.eq('{}', r.json.result.content[1].text)
  end)

  it('refuses to accept an empty proposal (Gemini would write the model proposal)', function()
    c:tool('openDiff', { filePath = file, newContent = 'text\n' })
    local d = assert(diff_for(file))
    api.nvim_buf_set_lines(d.bufnr, 0, -1, false, {})
    vim.bo[d.bufnr].eol = false
    local ok = diff.accept(d.id)
    assert.falsy(ok)
    assert.truthy(diff_for(file), 'still open')
    vim.wait(50)
    assert.eq(0, #c:events('ide/diffAccepted'))
  end)

  it('opens a diff for a new file and rejects invalid arguments with -32602', function()
    local new = tmp .. '/sub/new.txt'
    local r = c:tool('openDiff', { filePath = new, newContent = 'fresh\n' })
    assert.same({ content = {} }, r.json.result)
    assert.truthy(diff_for(new))
    r = c:tool('openDiff', { filePath = new })
    assert.eq(-32602, r.json.error.code)
    r = c:tool('openDiff', { filePath = 42, newContent = 'x' })
    assert.eq(-32602, r.json.error.code)
    -- A path the UI cannot show (a directory) still answers {content: []}: the TUI decides.
    r = c:tool('openDiff', { filePath = tmp, newContent = 'x' })
    assert.same({ content = {} }, r.json.result)
    assert.falsy(diff_for(tmp))
  end)

  it('keeps diffs of two sessions for the same path apart', function()
    local c2 = new_client(info):connect()
    c2:wait_event('ide/contextUpdate')
    c:tool('openDiff', { filePath = file, newContent = 'one\n' })
    c2:tool('openDiff', { filePath = file, newContent = 'two\n' })
    assert.eq(2, #diff.list())
    local ids = diff.list()
    assert.eq(file, ids[1])
    assert.eq(file .. ' #2', ids[2])
    assert.truthy(diff.accept(ids[2]))
    assert.eq('two\n', c2:wait_event('ide/diffAccepted').params.content)
    vim.wait(50)
    assert.eq(0, #c:events('ide/diffAccepted'))
    local r = c:tool('closeDiff', { filePath = file })
    assert.eq('one\n', vim.json.decode(r.json.result.content[1].text).content)
  end)

  it('closes the diffs of a session whose stream is gone for good', function()
    c:tool('openDiff', { filePath = file, newContent = 'x\n' })
    assert.truthy(diff_for(file))
    close(c.stream)
    wait_for(function()
      return diff_for(file) == nil
    end, 3000, 'orphaned diff closed')
    assert.eq(0, P.status().diffs)
  end)

  it('keeps the diff when the stream is re-opened within the grace period', function()
    c:tool('openDiff', { filePath = file, newContent = 'x\n' })
    close(c.stream)
    vim.wait(20)
    c:open_stream()
    vim.wait(400)
    assert.truthy(diff_for(file))
    assert.truthy(diff.accept(diff_for(file).id))
    assert.eq(file, c:wait_event('ide/diffAccepted').params.filePath)
  end)

  it('stop() closes diffs without notifications and ends the stream gracefully', function()
    c:tool('openDiff', { filePath = file, newContent = 'x\n' })
    P.stop()
    assert.eq(0, #diff.list())
    wait_for(function()
      local p = parse(c.stream)
      return p and p.complete
    end, 3000, 'stream terminated')
    assert.eq(0, #c:events('ide/diffRejected'))
    assert.falsy(uv.fs_stat(info.file))
  end)
end)

describe('ide/contextUpdate', function()
  it('is debounced, deduplicated and follows focus, cursor and selection', function()
    local a, b = tmp .. '/a.txt', tmp .. '/b.txt'
    write(a, 'alpha\nbeta\ngamma\n')
    write(b, 'one\n')
    vim.cmd('edit ' .. vim.fn.fnameescape(a))
    local info = start({ context_debounce_ms = 30 })
    local c = new_client(info):connect()
    c:wait_event('ide/contextUpdate')
    for _ = 1, 5 do
      P.on_selection(nil)
    end
    vim.wait(150)
    assert.eq(1, #c:events('ide/contextUpdate'), 'identical snapshot not re-sent')
    vim.cmd('edit ' .. vim.fn.fnameescape(b))
    selection.flush()
    local msg = c:wait_event('ide/contextUpdate', 2)
    local files = msg.params.workspaceState.openFiles
    assert.eq(b, files[1].path)
    assert.eq(true, files[1].isActive)
    assert.eq(a, files[2].path)
    assert.eq(nil, files[2].isActive)
    assert.eq(nil, files[2].cursor)
    assert.truthy(files[1].timestamp > files[2].timestamp)
    -- A visual selection in a.
    vim.cmd('buffer ' .. vim.fn.bufnr(a))
    vim.cmd('normal! ggVj')
    selection.flush()
    msg = c:wait_event('ide/contextUpdate', 3)
    files = msg.params.workspaceState.openFiles
    assert.eq(a, files[1].path)
    assert.eq('alpha\nbeta', files[1].selectedText)
    vim.cmd('normal! \27')
    assert.eq(3, #c:events('ide/contextUpdate'))
    -- Leaving Visual mode in the file window drops the selection after a short grace period.
    msg = c:wait_event('ide/contextUpdate', 4)
    files = msg.params.workspaceState.openFiles
    assert.eq(a, files[1].path)
    assert.eq(true, files[1].isActive)
    assert.eq(nil, files[1].selectedText)
  end)

  it('sends a focused terminal as the active entry under its nvim://buffer/ id, never as a recent file', function()
    local a, b = tmp .. '/a.txt', tmp .. '/b.txt'
    write(a, 'alpha\n')
    write(b, 'beta\n')
    vim.cmd('edit ' .. vim.fn.fnameescape(a))
    vim.cmd('edit ' .. vim.fn.fnameescape(b))
    local file_win = api.nvim_get_current_win()
    local info = start({ context_debounce_ms = 10 })
    local c = new_client(info):connect()
    c:wait_event('ide/contextUpdate')
    vim.cmd('botright vnew')
    local job = vim.fn.jobstart({ '/bin/sh', '-c', 'echo "error: boom"; exec sleep 30' }, { term = true })
    local term = api.nvim_get_current_buf()
    local id = ('nvim://buffer/%d/sh'):format(term)
    ---The latest ide/contextUpdate, once its files satisfy `pred`.
    local function wait_ctx(pred, what)
      local found
      wait_for(function()
        local evs = c:events('ide/contextUpdate')
        local m = evs[#evs] and evs[#evs].msg
        if m and pred(m.params.workspaceState.openFiles) then
          found = m
          return true
        end
        return false
      end, 3000, what)
      return found
    end
    local ok, err = pcall(function()
      wait_for(function()
        return api.nvim_buf_get_lines(term, 0, 1, false)[1] == 'error: boom'
      end, 3000, 'terminal output')
      api.nvim_win_set_cursor(0, { 2, 0 }) -- wherever it is, its cursor is sent at 1:1
      selection.flush()
      local msg = wait_ctx(function(files)
        return files[1].path == id
      end, 'the terminal as the active entry')
      assert.truthy(P.validate_notification(msg.method, msg.params))
      local files = msg.params.workspaceState.openFiles
      assert.eq(3, #files)
      assert.eq(id, files[1].path)
      assert.eq(true, files[1].isActive)
      assert.same({ line = 1, character = 1 }, files[1].cursor)
      assert.eq(b, files[2].path)
      assert.eq(nil, files[2].isActive)
      assert.eq(nil, files[2].cursor)
      assert.eq(a, files[3].path)
      assert.truthy(files[1].timestamp > files[2].timestamp, 'the newest: Gemini sorts by timestamp')
      -- The cursor moving (as it follows a terminal's output) sends no update.
      local n = #c:events('ide/contextUpdate')
      api.nvim_win_set_cursor(0, { 3, 0 })
      api.nvim_exec_autocmds('CursorMoved', {})
      selection.flush()
      vim.wait(100)
      assert.eq(n, #c:events('ide/contextUpdate'), 'no update for a cursor move')
      assert.same({ line = 1, character = 1 }, P.build_context().workspaceState.openFiles[1].cursor)
      -- A selection in the terminal is its selectedText.
      api.nvim_win_set_cursor(0, { 1, 0 })
      vim.cmd('normal! vg_')
      selection.flush()
      msg = wait_ctx(function(list)
        return list[1].selectedText ~= nil
      end, 'the terminal selection')
      assert.eq(id, msg.params.workspaceState.openFiles[1].path)
      assert.eq('error: boom', msg.params.workspaceState.openFiles[1].selectedText)
      vim.cmd('normal! \27')
      -- Back in a file: the terminal is gone from the list.
      api.nvim_set_current_win(file_win)
      selection.flush()
      wait_for(function()
        local ctx = P.build_context()
        return ctx.workspaceState.openFiles[1].path == b
      end, 2000, 'the file active again')
      local ctx = P.build_context()
      assert.eq(2, #ctx.workspaceState.openFiles)
      assert.eq(true, ctx.workspaceState.openFiles[1].isActive)
      for _, f in ipairs(ctx.workspaceState.openFiles) do
        assert.falsy(f.path:find('nvim://', 1, true), 'no terminal among the recent files')
      end
    end)
    vim.fn.jobstop(job)
    assert.truthy(ok, err)
  end)

  it('truncates the selected text and lists at most 10 files', function()
    for i = 1, 12 do
      write(tmp .. '/f' .. i .. '.txt', 'x\n')
      vim.cmd('edit ' .. vim.fn.fnameescape(tmp .. '/f' .. i .. '.txt'))
    end
    local big = tmp .. '/big.txt'
    write(big, string.rep('é', 20000) .. '\n')
    vim.cmd('edit ' .. vim.fn.fnameescape(big))
    vim.cmd('normal! 0v$')
    local info = start()
    local c = new_client(info):connect()
    local msg = c:wait_event('ide/contextUpdate')
    local files = msg.params.workspaceState.openFiles
    assert.eq(10, #files)
    local text = files[1].selectedText
    assert.eq(string.rep('é', 16384) .. '... [TRUNCATED]', text)
    vim.cmd('normal! \27')
  end)

  it('never sends a notification that fails Gemini\'s schema', function()
    local v = P.validate_notification
    assert.truthy(v('ide/contextUpdate', { workspaceState = { openFiles = {} } }))
    assert.truthy(v('ide/contextUpdate', vim.empty_dict()))
    assert.falsy(v('ide/contextUpdate', {}))
    assert.falsy(v('ide/contextUpdate', { workspaceState = { openFiles = { { path = 'x' } } } }))
    assert.falsy(v('ide/contextUpdate', { workspaceState = { openFiles = { { path = 'x', timestamp = 1, cursor = { line = 1 } } } } }))
    assert.falsy(v('ide/contextUpdate', { workspaceState = { openFiles = { { path = 'x', timestamp = 0 / 0 } } } }))
    assert.falsy(v('ide/contextUpdate', { workspaceState = { isTrusted = 'yes' } }))
    assert.truthy(v('ide/diffAccepted', { filePath = '/a', content = '' }))
    assert.falsy(v('ide/diffAccepted', { filePath = '/a' }))
    assert.truthy(v('ide/diffRejected', { filePath = '/a' }))
    assert.falsy(v('ide/diffRejected', { filePath = 1 }))
    assert.falsy(v('ide/diffClosed', { filePath = '/a' }))
  end)

  it('replaces invalid UTF-8 in the selected text', function()
    local f = tmp .. '/latin1.txt'
    write(f, 'cafe ok\n')
    vim.cmd('edit ' .. vim.fn.fnameescape(f))
    -- Reading would convert latin1 to UTF-8; put the raw byte in the buffer directly.
    api.nvim_buf_set_lines(0, 0, -1, false, { 'caf\233 ok' })
    vim.cmd('normal! 0v$')
    local ctx = P.build_context()
    vim.cmd('normal! \27')
    local sel = ctx.workspaceState.openFiles[1].selectedText
    assert.truthy(sel)
    assert.truthy(require('agent.net.common').valid_utf8(sel), vim.inspect(sel))
    assert.truthy(sel:find('\239\191\189', 1, true))
  end)
end)

describe('send_context (:AgentSend)', function()
  local function track_off()
    config.setup({ diff = { open_in = 'tab' }, selection = { track = false },
      providers = { gemini = { discovery_dir = tmp .. '/disc' } } })
  end

  local function edit(path, text)
    write(path, text)
    vim.cmd('edit ' .. vim.fn.fnameescape(path))
    return path
  end

  ---The latest ide/contextUpdate of `c`, once its files satisfy `pred`; checked against Gemini's schema.
  local function wait_ctx(c, pred, what)
    local found
    wait_for(function()
      local evs = c:events('ide/contextUpdate')
      local m = evs[#evs] and evs[#evs].msg
      if m and pred(m.params.workspaceState.openFiles) then
        found = m
        return true
      end
      return false
    end, 3000, what)
    assert.truthy(P.validate_notification(found.method, found.params))
    return found.params.workspaceState.openFiles
  end

  it('with selection.track = false, lists the sent entry alone: path, isActive, 1-based UTF-16 cursor, selectedText', function()
    track_off()
    local b = edit(tmp .. '/b.lua', 'other\n')
    local a = edit(tmp .. '/a.lua', 'local x = 1\nlocal y = "é"\n')
    api.nvim_win_set_cursor(0, { 2, 13 })
    local c = new_client(start()):connect()
    assert.same({}, c:wait_event('ide/contextUpdate').params.workspaceState.openFiles)
    assert.truthy(P.send_context(selection.capture({ line1 = 1, line2 = 2 })))
    local msg = c:wait_event('ide/contextUpdate', 2)
    assert.truthy(P.validate_notification(msg.method, msg.params))
    local files = msg.params.workspaceState.openFiles
    assert.eq(1, #files, 'not ' .. b)
    local f = files[1]
    assert.truthy(f.timestamp > 1.7e12, 'wall-clock ms')
    -- A range: the cursor at the start of its last line (as a V selection made downwards has it).
    assert.same({ path = a, timestamp = f.timestamp, isActive = true, cursor = { line = 2, character = 1 },
      selectedText = 'local x = 1\nlocal y = "é"' }, f)
    assert.same(msg.params, P.build_context())
    -- The cursor only: the file, with no selectedText. Byte column 13 is after 'local y = "é' (é is
    -- 2 bytes, 1 UTF-16 unit): 1-based UTF-16 = 13.
    assert.truthy(P.send_context(selection.capture()))
    files = c:wait_event('ide/contextUpdate', 3).params.workspaceState.openFiles
    assert.same({ { path = a, timestamp = files[1].timestamp, isActive = true, cursor = { line = 2, character = 13 } } },
      files)
    assert.truthy(files[1].timestamp > f.timestamp)
    -- The selected text is truncated like the tracked one.
    edit(tmp .. '/big.txt', string.rep('é', 20000) .. '\n')
    assert.truthy(P.send_context(selection.capture({ line1 = 1 })))
    files = c:wait_event('ide/contextUpdate', 4).params.workspaceState.openFiles
    assert.eq(string.rep('é', 16384) .. '... [TRUNCATED]', files[1].selectedText)
  end)

  it('sends a buffer that is not a file by its nvim://buffer/ id, its cursor at 1:1', function()
    track_off()
    local c = new_client(start()):connect()
    c:wait_event('ide/contextUpdate')
    vim.cmd('enew')
    api.nvim_buf_set_lines(0, 0, -1, false, { 'error: boom', 'at line 2' })
    api.nvim_win_set_cursor(0, { 2, 3 })
    local id = ('nvim://buffer/%d/scratch'):format(api.nvim_get_current_buf())
    assert.truthy(P.send_context(selection.capture()))
    local msg = c:wait_event('ide/contextUpdate', 2)
    assert.truthy(P.validate_notification(msg.method, msg.params))
    local files = msg.params.workspaceState.openFiles
    assert.same({ { path = id, timestamp = files[1].timestamp, isActive = true, cursor = { line = 1, character = 1 } } },
      files)
    assert.truthy(P.send_context(selection.capture({ line1 = 1, line2 = 2 })))
    files = c:wait_event('ide/contextUpdate', 3).params.workspaceState.openFiles
    assert.eq(1, #files)
    assert.eq(id, files[1].path)
    assert.eq('error: boom\nat line 2', files[1].selectedText)
  end)

  it('with selection.track = true, puts the sent entry first and newest, the recent files after it as plain entries', function()
    local a = edit(tmp .. '/a.txt', 'alpha\nbeta\n')
    local b = edit(tmp .. '/b.txt', 'one\n')
    local c = new_client(start({ context_debounce_ms = 10 })):connect()
    c:wait_event('ide/contextUpdate')
    vim.cmd('buffer ' .. vim.fn.bufnr(a))
    api.nvim_win_set_cursor(0, { 2, 1 })
    selection.flush()
    wait_ctx(c, function(files)
      return files[1].path == a
    end, 'a focused')
    assert.truthy(P.send_context(selection.capture({ line1 = 1, line2 = 2 })))
    local files = wait_ctx(c, function(list)
      return list[1].selectedText ~= nil
    end, 'the sent entry')
    assert.eq(2, #files)
    assert.same({ path = a, timestamp = files[1].timestamp, isActive = true, cursor = { line = 2, character = 1 },
      selectedText = 'alpha\nbeta' }, files[1])
    assert.same({ path = b, timestamp = files[2].timestamp }, files[2])
    assert.truthy(files[1].timestamp > files[2].timestamp)
    -- A buffer that is not a file, focused now, is never listed behind it.
    vim.cmd('botright new')
    selection.flush()
    assert.matches('^nvim://buffer/', selection.recent_files({ buffers = true })[1].path)
    local ctx = P.build_context()
    assert.same({ a, b }, vim.tbl_map(function(x)
      return x.path
    end, ctx.workspaceState.openFiles))
    vim.cmd('close')
    -- The focus moves on to another file before the selection event reaches the provider: the sent
    -- entry stays first, and the newest (Gemini keeps isActive on the newest entry only).
    local c3 = edit(tmp .. '/c.txt', 'x\n')
    selection.flush()
    files = wait_ctx(c, function(list)
      return #list == 3
    end, 'c.txt listed')
    assert.same({ a, c3, b }, vim.tbl_map(function(x)
      return x.path
    end, files))
    assert.eq('alpha\nbeta', files[1].selectedText)
    assert.eq(true, files[1].isActive)
    assert.same({ path = c3, timestamp = files[2].timestamp }, files[2])
    assert.truthy(files[1].timestamp > files[2].timestamp)
    -- The selection event replaces it.
    P.on_selection(nil)
    assert.eq(nil, P._state().context)
    files = wait_ctx(c, function(list)
      return list[1].path == c3
    end, 'c.txt active')
    assert.eq(true, files[1].isActive)
    assert.same({ path = a, timestamp = files[2].timestamp }, files[2])
  end)

  it('is in the update each new stream gets, until the next :AgentSend or on_selection replaces it', function()
    track_off()
    local a = edit(tmp .. '/a.txt', 'alpha\nbeta\n')
    local info = start()
    assert.falsy(P.send_context(selection.capture({ line1 = 2 })), 'no stream yet')
    local c = new_client(info):connect()
    local c2 = new_client(info):connect()
    for _, x in ipairs({ c, c2 }) do
      local files = x:wait_event('ide/contextUpdate').params.workspaceState.openFiles
      assert.eq(1, #files)
      assert.eq(a, files[1].path)
      assert.eq('beta', files[1].selectedText)
    end
    -- The stream reopens (a reconnect): the update it gets has it too.
    c:open_stream()
    assert.eq('beta', c:wait_event('ide/contextUpdate').params.workspaceState.openFiles[1].selectedText)
    -- The next :AgentSend replaces it everywhere.
    assert.truthy(P.send_context(selection.capture({ line1 = 1 })))
    assert.eq('alpha', c:wait_event('ide/contextUpdate', 2).params.workspaceState.openFiles[1].selectedText)
    assert.eq('alpha', c2:wait_event('ide/contextUpdate', 2).params.workspaceState.openFiles[1].selectedText)
    -- A selection event: forgotten (with selection.track = false, no files at all).
    P.on_selection(nil)
    assert.same({}, c2:wait_event('ide/contextUpdate', 3).params.workspaceState.openFiles)
    assert.same({ workspaceState = { openFiles = {} } }, P.build_context())
    local c3 = new_client(info):connect()
    assert.same({}, c3:wait_event('ide/contextUpdate').params.workspaceState.openFiles)
  end)

  it('clear_context(pid) forgets it when the agent terminal with that job pid ends, and updates the Geminis', function()
    track_off()
    edit(tmp .. '/a.txt', 'alpha\nbeta\n')
    local info = start()
    local c = new_client(info):connect()
    c:wait_event('ide/contextUpdate')
    assert.truthy(P.send_context(selection.capture({ line1 = 2 }), { pid = 4242 }))
    assert.eq('beta', c:wait_event('ide/contextUpdate', 2).params.workspaceState.openFiles[1].selectedText)
    assert.eq(4242, P._state().context_pid)
    -- Another agent (terminal) ended: kept, nothing sent.
    P.clear_context(1111)
    P.clear_context(nil)
    vim.wait(100)
    assert.eq(2, #c:events('ide/contextUpdate'))
    assert.eq('beta', P.build_context().workspaceState.openFiles[1].selectedText)
    -- Its own: forgotten, and the connected Geminis get an update without it (with
    -- selection.track = false: no files).
    P.clear_context(4242)
    assert.eq(nil, P._state().context)
    assert.eq(nil, P._state().context_pid)
    assert.same({}, c:wait_event('ide/contextUpdate', 3).params.workspaceState.openFiles)
    local c2 = new_client(info):connect()
    assert.same({}, c2:wait_event('ide/contextUpdate').params.workspaceState.openFiles)
    -- Nothing left to forget: no update.
    P.clear_context(4242)
    vim.wait(100)
    assert.eq(3, #c:events('ide/contextUpdate'))
    -- Sent with no pid (no agent terminal, terminal.layout = 'none'): a pid does not forget it.
    assert.truthy(P.send_context(selection.capture({ line1 = 1 })))
    assert.eq('alpha', c:wait_event('ide/contextUpdate', 4).params.workspaceState.openFiles[1].selectedText)
    P.clear_context(4242)
    vim.wait(100)
    assert.eq(4, #c:events('ide/contextUpdate'))
    P.clear_context(nil)
    assert.same({}, c:wait_event('ide/contextUpdate', 5).params.workspaceState.openFiles)
    P.stop()
    P.clear_context(4242) -- safe when stopped
  end)

  it('clear_context keeps the recent files with selection.track = true', function()
    local a = edit(tmp .. '/a.txt', 'alpha\nbeta\n')
    local c = new_client(start()):connect()
    c:wait_event('ide/contextUpdate')
    selection.flush()
    assert.truthy(P.send_context(selection.capture({ line1 = 1 }), { pid = 4242 }))
    assert.eq('alpha', c:wait_event('ide/contextUpdate', 2).params.workspaceState.openFiles[1].selectedText)
    local n = #c:events('ide/contextUpdate')
    P.clear_context(4242)
    local files = c:wait_event('ide/contextUpdate', n + 1).params.workspaceState.openFiles
    assert.eq(a, files[1].path)
    assert.eq(true, files[1].isActive)
    assert.eq(nil, files[1].selectedText)
  end)

  it('ide_mode_off(): IDE mode was off when before_spawn last ran (the launcher\'s warning, else the settings), and still is', function()
    assert.falsy(P.ide_mode_off(), 'not running')
    start()
    assert.falsy(P.ide_mode_off(), 'not launched yet')
    local home = tmp .. '/ghome'
    vim.fn.mkdir(home .. '/.gemini', 'p')
    local settings = home .. '/.gemini/settings.json'
    local env = { GEMINI_CLI_HOME = home, GEMINI_CLI_SYSTEM_DEFAULTS_PATH = tmp .. '/none.json',
      GEMINI_CLI_SYSTEM_SETTINGS_PATH = tmp .. '/none2.json' }
    local orig = vim.notify
    vim.notify = function() end -- the one-time hint
    local ok, err = pcall(function()
      write(settings, '{"ide":{"enabled":true}}')
      P.before_spawn({ cwd = tmp, env = env, warnings = {} })
      assert.falsy(P.ide_mode_off())
      -- The launcher warned (it read the settings already); the settings are read again later.
      write(settings, '{"ide":{"enabled":false}}')
      P.before_spawn({ cwd = tmp, env = env, warnings = { { id = 'gemini-ide-disabled' } } })
      assert.truthy(P.ide_mode_off())
      -- /ide enable in the running Gemini writes the setting: no relaunch needed.
      write(settings, '{"ide":{"enabled":true}}')
      assert.falsy(P.ide_mode_off())
      -- Else the settings, as Gemini reads them with the job's environment.
      P.before_spawn({ cwd = tmp, env = env, warnings = { { id = 'another-warning' } } })
      assert.falsy(P.ide_mode_off())
      write(settings, '{ // jsonc\n "ide": { "enabled": false } }')
      P.before_spawn({ cwd = tmp, env = env, warnings = {} })
      assert.truthy(P.ide_mode_off())
      -- /ide enable, and the next launch.
      write(settings, '{"ide":{"enabled":true}}')
      P.before_spawn({ cwd = tmp, env = env, warnings = {} })
      assert.falsy(P.ide_mode_off())
      write(settings, '{"ide":{"enabled":false}}')
      P.before_spawn({ cwd = tmp, env = env })
      assert.truthy(P.ide_mode_off())
      -- A restart of the server forgets it.
      P.stop()
      assert.falsy(P.ide_mode_off())
      start()
      assert.falsy(P.ide_mode_off())
    end)
    vim.notify = orig
    assert.truthy(ok, err)
  end)

  it('returns false when stopped or with no stream open; stop() forgets it', function()
    track_off()
    edit(tmp .. '/a.txt', 'alpha\n')
    assert.falsy(P.send_context(selection.capture()), 'not running')
    local info = start()
    new_client(info):connect({ no_stream = true })
    assert.falsy(P.send_context(selection.capture()), 'no stream')
    assert.falsy(P.send_context(nil))
    P.stop()
    info = start()
    local c = new_client(info):connect()
    assert.same({}, c:wait_event('ide/contextUpdate').params.workspaceState.openFiles)
  end)
end)

describe('misc', function()
  it('on_selection is safe when stopped', function()
    P.on_selection(nil)
    assert.falsy(P.is_running())
  end)

  it('client_state: ready once a GET stream is open, connecting before, nil when stopped', function()
    assert.eq(nil, P.client_state())
    local info = start()
    assert.eq(nil, P.client_state())
    local c = new_client(info):connect({ no_stream = true })
    assert.eq('connecting', P.client_state())
    c:open_stream()
    wait_for(function()
      return P.client_state() == 'ready'
    end, 2000, 'ready')
    P.stop()
    assert.eq(nil, P.client_state())
  end)

  it('launch_info() starts the server lazily (config.providers.gemini.discovery_dir)', function()
    local li = assert(P.launch_info({ cwd = tmp }))
    assert.truthy(P.is_running())
    assert.eq(tmp .. '/disc', vim.fs.dirname(li.discovery_file))
    assert.eq(tmp, li.workspace)
    assert.truthy(uv.fs_stat(li.discovery_file))
  end)
end)
