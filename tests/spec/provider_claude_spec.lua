-- Tests for lua/agent/providers/claude.lua (Claude IDE protocol server for Claude Code and OpenCode).
-- A raw WebSocket client replays the Claude Code 2.1.283 capture (claude-opencode.md §3.2, §4.2).
local uv = vim.uv
local ws = require('agent.net.websocket')
local config = require('agent.config')
local diff = require('agent.editor.diff')
local P = require('agent.providers.claude')

-- realpath: $TMPDIR is a symlink on macOS and Neovim resolves buffer names and the cwd.
local TMP = assert(uv.fs_realpath(assert(uv.fs_mkdtemp(uv.os_tmpdir() .. '/apc-XXXXXX'))))
local LOCK_DIR = TMP .. '/ide'

-- The exact messages Claude Code 2.1.283 sent on connect [probe:probe.log].
local CLAUDE_INITIALIZE = '{"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{"roots":'
  .. '{"listChanged":true},"elicitation":{}},"clientInfo":{"name":"claude-code","title":"Claude Code","version":'
  .. '"2.1.283","description":"Anthropic\'s agentic coding tool","websiteUrl":"https://claude.com/claude-code"}},'
  .. '"jsonrpc":"2.0","id":0}'
local CLAUDE_INITIALIZED = '{"jsonrpc":"2.0","method":"notifications/initialized"}'
local CLAUDE_TOOLS_LIST = '{"method":"tools/list","jsonrpc":"2.0","id":1}'
local OPENCODE_INITIALIZE = '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25",'
  .. '"capabilities":{},"clientInfo":{"name":"opencode","version":"0.0.0"}}}'

local function setup_config(extra)
  config.setup(vim.tbl_deep_extend('force', {
    providers = { claude = { lock_dir = LOCK_DIR, notify_delay_ms = 80 } },
  }, extra or {}))
end

local function read(path)
  local f = io.open(path, 'rb')
  if not f then
    return nil
  end
  local s = f:read('*a')
  f:close()
  return s
end

local function write(path, data)
  local f = assert(io.open(path, 'wb'))
  f:write(data)
  f:close()
end

-- ---------------------------------------------------------------------------
-- Raw WebSocket client
-- ---------------------------------------------------------------------------

local function masked_frame(opcode, payload)
  local mask = '\7\1\9\3'
  return ws.frame_header(opcode, #payload, true, mask) .. ws.unmask(payload, mask)
end

---@param o { token?: string|false, protocol?: string|false, origin?: string, header_name?: string, port?: integer }
local function connect(o)
  o = o or {}
  local port = o.port or P.status().port
  local h = uv.new_tcp()
  local c = { buf = '', messages = {}, frames = {}, eof = false, handle = h }
  local connected, cerr = false, nil
  h:connect('127.0.0.1', port, function(err)
    cerr = err
    connected = not err
    if err then
      return
    end
    h:read_start(function(rerr, chunk)
      if rerr or not chunk then
        c.eof = true
        return
      end
      c.buf = c.buf .. chunk
    end)
  end)
  wait_for(function()
    return connected or cerr
  end, 2000, 'tcp connect')
  assert.falsy(cerr)
  local token = o.token
  if token == nil then
    token = P._state.token
  end
  local lines = {
    'GET / HTTP/1.1',
    'Host: 127.0.0.1:' .. port,
    'Connection: Upgrade',
    'Upgrade: websocket',
    'Sec-WebSocket-Version: 13',
    'Sec-WebSocket-Extensions: permessage-deflate; client_max_window_bits',
    'Sec-WebSocket-Key: RN20ewn815D8uHEla2DB/w==',
  }
  if o.protocol ~= false then
    lines[#lines + 1] = 'Sec-WebSocket-Protocol: ' .. (o.protocol or 'mcp')
  end
  lines[#lines + 1] = 'User-Agent: claude-code/2.1.283 (cli)'
  if token then
    lines[#lines + 1] = (o.header_name or 'X-Claude-Code-Ide-Authorization') .. ': ' .. token
  end
  if o.origin then
    lines[#lines + 1] = 'Origin: ' .. o.origin
  end
  h:write(table.concat(lines, '\r\n') .. '\r\n\r\n')
  wait_for(function()
    return c.buf:find('\r\n\r\n', 1, true) or c.eof
  end, 3000, 'handshake response')
  local he = c.buf:find('\r\n\r\n', 1, true)
  c.head = he and c.buf:sub(1, he - 1) or c.buf
  c.buf = he and c.buf:sub(he + 4) or ''
  c.status = tonumber(c.head:match('^HTTP/1%.1 (%d+)'))

  function c.pump()
    while #c.buf >= 2 do
      local b1, b2 = c.buf:byte(1, 2)
      local len, p = bit.band(b2, 0x7f), 3
      if len == 126 then
        if #c.buf < 4 then
          return
        end
        len = c.buf:byte(3) * 256 + c.buf:byte(4)
        p = 5
      elseif len == 127 then
        if #c.buf < 10 then
          return
        end
        len = 0
        for i = 3, 10 do
          len = len * 256 + c.buf:byte(i)
        end
        p = 11
      end
      if #c.buf < p + len - 1 then
        return
      end
      local payload = c.buf:sub(p, p + len - 1)
      c.buf = c.buf:sub(p + len)
      local opcode = bit.band(b1, 0x0f)
      c.frames[#c.frames + 1] = { opcode = opcode, payload = payload, masked = bit.band(b2, 0x80) ~= 0 }
      if opcode == 1 then
        c.messages[#c.messages + 1] = vim.json.decode(payload)
      elseif opcode == 8 then
        c.close_code = #payload >= 2 and payload:byte(1) * 256 + payload:byte(2) or 1005
      end
    end
  end
  function c.raw(text)
    h:write(masked_frame(1, text))
  end
  function c.send(msg)
    c.raw(vim.json.encode(msg))
  end
  local next_id = 100
  function c.request(method, params)
    next_id = next_id + 1
    c.send({ jsonrpc = '2.0', id = next_id, method = method, params = params })
    return next_id
  end
  ---Wait for (and remove) the first message matching pred.
  function c.wait(pred, ms, what)
    local found
    wait_for(function()
      c.pump()
      for i, m in ipairs(c.messages) do
        if pred(m) then
          found = table.remove(c.messages, i)
          return true
        end
      end
      return false
    end, ms or 3000, what or 'message')
    return found
  end
  function c.response(id, ms)
    return c.wait(function(m)
      return m.id == id and m.method == nil
    end, ms, 'response ' .. tostring(id))
  end
  function c.call(method, params, ms)
    return c.response(c.request(method, params), ms)
  end
  function c.tool(name, args, ms)
    local r = c.call('tools/call', { name = name, arguments = args or vim.empty_dict() }, ms)
    return r
  end
  function c.notifications(method)
    c.pump()
    local out = {}
    for _, m in ipairs(c.messages) do
      if m.method == method then
        out[#out + 1] = m
      end
    end
    return out
  end
  function c.take(method, ms)
    return c.wait(function(m)
      return m.method == method
    end, ms, method)
  end
  function c.clear()
    vim.wait(60) -- let in-flight frames arrive
    c.pump()
    c.messages = {}
  end
  function c.close()
    if not h:is_closing() then
      pcall(h.write, h, masked_frame(8, string.char(3, 232)))
      h:close()
    end
  end
  return c
end

---Replay Claude Code's connect sequence and wait until the provider marked it ready.
local function claude_client(o)
  local c = connect(o)
  assert.eq(101, c.status, c.head)
  c.raw(CLAUDE_INITIALIZE)
  local init = c.response(0)
  c.raw(CLAUDE_INITIALIZED)
  c.raw('{"jsonrpc":"2.0","method":"ide_connected","params":{"pid":' .. ((o and o.pid) or 5077) .. '}}')
  c.raw(CLAUDE_TOOLS_LIST)
  local list = c.response(1)
  c.init, c.list = init, list
  return c
end

local function opencode_client(o)
  o = vim.tbl_extend('force', { protocol = false, header_name = 'x-claude-code-ide-authorization' }, o or {})
  local c = connect(o)
  assert.eq(101, c.status, c.head)
  c.raw(OPENCODE_INITIALIZE)
  c.init = c.response(1)
  c.raw(CLAUDE_INITIALIZED)
  return c
end

local function wait_ready(n)
  wait_for(function()
    local ready = 0
    for _, cl in ipairs(P.clients()) do
      if cl.ready then
        ready = ready + 1
      end
    end
    return ready >= (n or 1)
  end, 3000, 'client ready')
end

local function text_of(resp, i)
  return resp.result.content[i or 1].text
end

local function sel(o)
  local s = {
    path = o.path or '/abs/file.lua',
    bufnr = 1,
    text = o.text or '',
    start = o.start or { line = 0, character = 0 },
    finish = o.finish or o.start or { line = 0, character = 0 },
    mode = o.mode or 'n',
    linewise = o.mode == 'V',
  }
  s.is_empty = s.text == ''
  return s
end

local clients = {}
local function track(c)
  clients[#clients + 1] = c
  return c
end

before_each(function()
  setup_config()
end)

after_each(function()
  P._state.last_selection = nil
  for _, c in ipairs(clients) do
    c.close()
  end
  clients = {}
  for _, id in ipairs(diff.list()) do
    diff.close(id)
  end
  P.stop()
  diff._stop_watchers()
  vim.cmd('silent! %bwipeout!')
end)

-- ---------------------------------------------------------------------------

describe('lock file', function()
  it('is written atomically with the protocol fields, 0600 in a 0700 dir', function()
    assert.truthy(P.start())
    local st = P.status()
    assert.truthy(st.running)
    assert.eq(LOCK_DIR .. '/' .. st.port .. '.lock', st.lock)
    assert.eq('ws://127.0.0.1:' .. st.port, st.address)
    local lock = vim.json.decode(read(st.lock))
    assert.eq(vim.fn.getpid(), lock.pid)
    assert.eq('Neovim', lock.ideName)
    assert.eq('ws', lock.transport)
    assert.matches('^%x+$', lock.authToken)
    assert.eq(32, #lock.authToken)
    assert.eq(vim.fs.normalize(vim.fn.getcwd()), lock.workspaceFolders[1])
    assert.truthy(vim.tbl_contains(lock.workspaceFolders, uv.fs_realpath(vim.fn.getcwd())))
    assert.eq(tonumber('600', 8), uv.fs_stat(st.lock).mode % 512)
    assert.eq(tonumber('700', 8), uv.fs_stat(LOCK_DIR).mode % 512)
    assert.truthy(st.port >= 10000 and st.port <= 65535)
    -- no temp files left beside it
    local names = {}
    for name in vim.fs.dir(LOCK_DIR) do
      names[#names + 1] = name
    end
    assert.same({ st.port .. '.lock' }, names)
  end)

  it('lists a symlinked job cwd both literally and as its realpath (OpenCode compares physical paths)', function()
    local real = TMP .. '/realdir'
    vim.fn.mkdir(real, 'p')
    local link = TMP .. '/linkdir'
    uv.fs_symlink(real, link)
    assert.truthy(P.launch_info({ cwd = link }))
    local folders = vim.json.decode(read(P.status().lock)).workspaceFolders
    assert.truthy(vim.tbl_contains(folders, link))
    assert.truthy(vim.tbl_contains(folders, real))
    assert.eq(vim.fn.getcwd(), folders[1])
  end)

  it("lists only the launched agent's cwd: the next launch replaces it (one agent at a time)", function()
    local a, b = TMP .. '/job-a', TMP .. '/job-b'
    vim.fn.mkdir(a, 'p')
    vim.fn.mkdir(b, 'p')
    assert.truthy(P.launch_info({ cwd = a }))
    local folders = vim.json.decode(read(P.status().lock)).workspaceFolders
    assert.truthy(vim.tbl_contains(folders, uv.fs_realpath(a)))
    assert.truthy(P.launch_info({ cwd = b }))
    folders = vim.json.decode(read(P.status().lock)).workspaceFolders
    assert.truthy(vim.tbl_contains(folders, uv.fs_realpath(b)))
    assert.falsy(vim.tbl_contains(folders, uv.fs_realpath(a)))
    assert.falsy(vim.tbl_contains(folders, a))
  end)

  it('is removed by stop(); start() again reuses the port and the token', function()
    assert.truthy(P.start())
    local st = P.status()
    local token = P._state.token
    P.stop()
    assert.falsy(P.is_running())
    assert.falsy(uv.fs_stat(st.lock))
    assert.truthy(P.start())
    assert.eq(st.port, P.status().port)
    assert.eq(token, P._state.token)
    assert.eq(token, vim.json.decode(read(P.status().lock)).authToken)
  end)

  it('start() is idempotent and honors providers.claude.enabled = false', function()
    assert.truthy(P.start())
    local port = P.status().port
    assert.truthy(P.start())
    assert.eq(port, P.status().port)
    P.stop()
    setup_config({ providers = { claude = { enabled = false } } })
    local ok, err = P.start()
    assert.falsy(ok)
    assert.matches('disabled', err)
  end)

  it('fails to start, and hands out no port, when the lock directory cannot be created', function()
    local blocker = TMP .. '/blocker-file'
    write(blocker, 'x')
    setup_config({ providers = { claude = { lock_dir = blocker .. '/ide' } } })
    local ok, err = P.start()
    assert.falsy(ok)
    assert.matches('E739', err)
    assert.falsy(P.is_running())
    for _ = 1, 3 do
      local info, ierr = P.launch_info({ cwd = TMP })
      assert.eq(nil, info)
      assert.matches('E739', ierr)
    end
    assert.falsy(P.is_running())
    os.remove(blocker)
  end)

  it('removes stale Neovim locks with dead pids and leaves other files alone', function()
    vim.fn.mkdir(LOCK_DIR, 'p')
    local function lock(port, tbl)
      write(LOCK_DIR .. '/' .. port .. '.lock', vim.json.encode(tbl))
    end
    lock(11111, { pid = 999999, ideName = 'Neovim', transport = 'ws', workspaceFolders = { '/' } })
    lock(11112, { pid = 999999, ideName = 'Visual Studio Code', transport = 'ws', workspaceFolders = { '/' } })
    lock(11113, { pid = 1, ideName = 'Neovim', transport = 'ws', workspaceFolders = { '/' } })
    write(LOCK_DIR .. '/11114.lock', 'not json')
    assert.truthy(P.start())
    assert.falsy(uv.fs_stat(LOCK_DIR .. '/11111.lock'))
    assert.truthy(uv.fs_stat(LOCK_DIR .. '/11112.lock'))
    assert.truthy(uv.fs_stat(LOCK_DIR .. '/11113.lock'))
    assert.truthy(uv.fs_stat(LOCK_DIR .. '/11114.lock'))
    for _, p in ipairs({ 11112, 11113, 11114 }) do
      os.remove(LOCK_DIR .. '/' .. p .. '.lock')
    end
  end)

  it('launch_info() starts the server and adds the job cwd; before_spawn() rewrites the lock', function()
    local job = TMP .. '/job'
    vim.fn.mkdir(job, 'p')
    local info = assert(P.launch_info({ cwd = job }))
    assert.eq(P.status().port, info.port)
    assert.eq(P._state.token, info.token)
    assert.eq(P.status().lock, info.lock)
    local folders = vim.json.decode(read(info.lock)).workspaceFolders
    assert.truthy(vim.tbl_contains(folders, uv.fs_realpath(job)))
    local before = uv.fs_stat(info.lock)
    vim.wait(20)
    P.before_spawn({ cwd = job })
    local after = uv.fs_stat(info.lock)
    assert.truthy(after.ino ~= before.ino or after.mtime.nsec ~= before.mtime.nsec or after.mtime.sec ~= before.mtime.sec,
      'lock rewritten')
  end)

  it('is rewritten on DirChanged with the same port and token', function()
    assert.truthy(P.start())
    local old = vim.fn.getcwd()
    local d = TMP .. '/other'
    vim.fn.mkdir(d, 'p')
    vim.cmd.cd(d)
    wait_for(function()
      return vim.json.decode(read(P.status().lock)).workspaceFolders[1] == d
    end, 2000, 'lock rewrite')
    vim.cmd.cd(old)
  end)
end)

describe('environment', function()
  it('env() follows claude-opencode.md §7.3 for claude and §11 for opencode', function()
    assert.truthy(P.start())
    local e = P.env()
    assert.eq(tostring(P.status().port), e.CLAUDE_CODE_SSE_PORT)
    assert.eq('true', e.ENABLE_IDE_INTEGRATION)
    assert.eq('true', e.FORCE_CODE_TERMINAL)
    assert.eq('true', e.CLAUDE_CODE_IDE_SKIP_AUTO_INSTALL)
    assert.matches('127%.0%.0%.1', e.no_proxy)
    assert.eq(e.no_proxy, e.NO_PROXY)
    local o = P.env('opencode')
    assert.eq('', o.CLAUDE_CODE_SSE_PORT)
    assert.eq('', o.OPENCODE_EDITOR_SSE_PORT)
    assert.matches('localhost', o.NO_PROXY)
  end)
end)

describe('handshake', function()
  before_each(function()
    assert.truthy(P.start())
  end)

  it('accepts the Claude 2.1.283 upgrade, echoes mcp and declines permessage-deflate', function()
    local c = track(connect())
    assert.eq(101, c.status, c.head)
    assert.matches('\r\nSec%-WebSocket%-Protocol: mcp', c.head)
    assert.falsy(c.head:find('Extensions', 1, true))
    assert.matches('Sec%-WebSocket%-Accept: ', c.head)
  end)

  it('sends no subprotocol when none was offered (OpenCode)', function()
    local c = track(connect({ protocol = false, header_name = 'x-claude-code-ide-authorization' }))
    assert.eq(101, c.status)
    assert.falsy(c.head:find('Sec-WebSocket-Protocol', 1, true))
  end)

  it('rejects a wrong or missing token with 401 and an Origin with 403', function()
    assert.eq(401, track(connect({ token = 'wrong-token-0123456789abcdef0123' })).status)
    assert.eq(401, track(connect({ token = false })).status)
    assert.eq(403, track(connect({ origin = 'http://evil.example' })).status)
  end)
end)

describe('MCP handshake', function()
  before_each(function()
    assert.truthy(P.start())
  end)

  it('answers the captured Claude initialize and tools/list', function()
    local c = track(claude_client())
    local r = c.init.result
    assert.eq('2025-11-25', r.protocolVersion)
    assert.same({ tools = { listChanged = true } }, r.capabilities)
    assert.eq('agent-nvim', r.serverInfo.name)
    assert.eq('string', type(r.serverInfo.version))
    assert.falsy(r.instructions)
    local names = {}
    for _, t in ipairs(c.list.result.tools) do
      names[#names + 1] = t.name
      assert.eq('object', t.inputSchema.type)
      assert.eq(false, t.inputSchema.additionalProperties)
      assert.eq('http://json-schema.org/draft-07/schema#', t.inputSchema['$schema'])
    end
    table.sort(names)
    assert.same({ 'checkDocumentDirty', 'closeAllDiffTabs', 'getCurrentSelection', 'getDiagnostics',
      'getLatestSelection', 'getOpenEditors', 'getWorkspaceFolders', 'openDiff', 'openFile', 'saveDocument' }, names)
    local open_diff
    for _, t in ipairs(c.list.result.tools) do
      if t.name == 'openDiff' then
        open_diff = t
      end
    end
    assert.same({ 'old_file_path', 'new_file_path', 'new_file_contents', 'tab_name' }, open_diff.inputSchema.required)
    local cl = P.clients()[1]
    assert.eq('claude', cl.kind)
    assert.eq('claude-code', cl.name)
    assert.eq('2.1.283', cl.version)
    assert.eq(5077, cl.pid)
    assert.eq(1, P.status().clients)
  end)

  it('answers an unsupported protocol version with 2024-11-05', function()
    local c = track(connect())
    c.send({ jsonrpc = '2.0', id = 0, method = 'initialize',
      params = { protocolVersion = '2099-01-01', capabilities = {}, clientInfo = { name = 'claude-code', version = 'x' } } })
    assert.eq('2024-11-05', c.response(0).result.protocolVersion)
  end)

  it('answers ping, rejects unknown methods, and handles close_tab although it is not listed', function()
    local c = track(claude_client())
    local p = c.call('ping')
    assert.same({}, p.result)
    local u = c.call('prompts/list')
    assert.eq(-32601, u.error.code)
    assert.eq('TAB_CLOSED', text_of(c.tool('close_tab', { tab_name = 'nope' })))
    assert.eq('TAB_CLOSED', text_of(c.tool('close_tab', {})))
    assert.eq(-32602, c.tool('nosuchtool', {}).error.code)
  end)

  it('recognizes OpenCode from clientInfo.name', function()
    local c = track(opencode_client())
    assert.eq('2025-11-25', c.init.result.protocolVersion)
    wait_ready(1)
    assert.eq('opencode', P.clients()[1].kind)
  end)
end)

describe('selection_changed', function()
  before_each(function()
    assert.truthy(P.start())
  end)

  it('reaches Claude only after the post-connect delay, 0-based, deduplicated', function()
    P.on_selection(sel({ path = '/p/a.lua', text = 'line five\nline six', start = { line = 4, character = 0 },
      finish = { line = 5, character = 8 }, mode = 'v' }))
    local c = track(connect())
    c.raw(CLAUDE_INITIALIZE)
    c.response(0)
    c.raw(CLAUDE_INITIALIZED)
    c.raw(CLAUDE_TOOLS_LIST)
    c.response(1)
    -- Nothing yet: Claude registers its handlers after the connection completes (§6.3).
    assert.eq(0, #c.notifications('selection_changed'))
    local n = c.take('selection_changed', 2000)
    assert.same({
      text = 'line five\nline six',
      filePath = '/p/a.lua',
      fileUrl = 'file:///p/a.lua',
      selection = { start = { line = 4, character = 0 }, ['end'] = { line = 5, character = 8 }, isEmpty = false },
    }, n.params)
    -- The same selection again is not resent; a new one is.
    P.on_selection(sel({ path = '/p/a.lua', text = 'line five\nline six', start = { line = 4, character = 0 },
      finish = { line = 5, character = 8 }, mode = 'v' }))
    P.on_selection(sel({ path = '/p/a.lua', start = { line = 7, character = 3 } }))
    local m = c.take('selection_changed')
    assert.same({ start = { line = 7, character = 3 }, ['end'] = { line = 7, character = 3 }, isEmpty = true },
      m.params.selection)
    assert.eq('', m.params.text)
    vim.wait(100)
    assert.eq(0, #c.notifications('selection_changed'))
  end)

  it('sends a linewise selection ending on an empty line as end={last+1,0} to Claude', function()
    local c = track(claude_client())
    wait_ready(1)
    c.clear()
    P.on_selection(sel({ path = '/p/a.lua', text = 'a\nb\n', start = { line = 2, character = 0 },
      finish = { line = 4, character = 0 }, mode = 'V' }))
    local n = c.take('selection_changed')
    assert.same({ line = 5, character = 0 }, n.params.selection['end'])
  end)

  it('adds line_offset to OpenCode lines and columns, and sends right after initialize', function()
    P.on_selection(sel({ path = '/p/a.lua', text = 'xyz', start = { line = 4, character = 2 },
      finish = { line = 4, character = 5 }, mode = 'v' }))
    local c = track(opencode_client())
    local n = c.take('selection_changed', 500)
    assert.same({ line = 5, character = 3 }, n.params.selection.start)
    assert.same({ line = 5, character = 6 }, n.params.selection['end'])
    assert.eq('xyz', n.params.text)
    assert.falsy(n.params.source)
    -- linewise, empty last line: OpenCode keeps end.line = last (+offset)
    P.on_selection(sel({ path = '/p/a.lua', text = 'a\n', start = { line = 2, character = 0 },
      finish = { line = 3, character = 0 }, mode = 'V' }))
    assert.same({ line = 4, character = 1 }, c.take('selection_changed').params.selection['end'])
  end)

  it('honors config.agents.opencode.line_offset = 0', function()
    setup_config({ agents = { opencode = { line_offset = 0 } } })
    local c = track(opencode_client())
    wait_ready(1)
    c.clear()
    P.on_selection(sel({ path = '/p/a.lua', start = { line = 4, character = 2 } }))
    assert.same({ line = 4, character = 2 }, c.take('selection_changed').params.selection.start)
  end)

  it('sends nothing, on connect or later, with selection.track = false', function()
    setup_config({ selection = { track = false } })
    local p = TMP .. '/secret.txt'
    write(p, 'password=hunter2\n')
    vim.cmd.edit(vim.fn.fnameescape(p))
    P._state.last_selection = sel({ path = p, text = 'password', finish = { line = 0, character = 8 }, mode = 'v' })
    local c = track(claude_client())
    local o = track(opencode_client())
    wait_ready(2)
    P.on_selection(sel({ path = p, start = { line = 0, character = 3 } }))
    vim.wait(150)
    assert.eq(0, #c.notifications('selection_changed'))
    assert.eq(0, #o.notifications('selection_changed'))
  end)

  it('replaces invalid UTF-8 with U+FFFD, so text frames stay valid', function()
    local c = track(claude_client())
    wait_ready(1)
    c.clear()
    c.frames = {}
    -- Latin-1 bytes from a `++bin` buffer and a file name that is not UTF-8; é is valid and kept.
    P.on_selection(sel({ path = '/p/caf\233.txt', text = 'caf\233 cr\232me \195\169 \195', mode = 'v',
      finish = { line = 0, character = 12 } }))
    local n = c.take('selection_changed')
    local f = c.frames[#c.frames]
    assert.eq(1, f.opcode)
    assert.truthy(require('agent.net.common').valid_utf8(f.payload), 'a text frame must be valid UTF-8')
    assert.eq('caf\239\191\189 cr\239\191\189me \195\169 \239\191\189', n.params.text)
    assert.eq('/p/caf\239\191\189.txt', n.params.filePath)
  end)
end)

describe('openDiff', function()
  local target, c
  before_each(function()
    assert.truthy(P.start())
    target = TMP .. '/target.txt'
    write(target, 'hello\nworld\n')
    c = track(claude_client())
  end)

  local function open_diff(tab, contents, path)
    return c.request('tools/call', { name = 'openDiff', arguments = {
      old_file_path = path or target, new_file_path = path or target,
      new_file_contents = contents or 'hello\nneovim\n', tab_name = tab } })
  end

  it('blocks until accepted, then answers FILE_SAVED with the final text (user edits included)', function()
    local tab = '✻ [Claude Code] target.txt (3f9a1c) ⧉'
    local id = open_diff(tab)
    wait_for(function()
      return diff.is_open(tab)
    end, 2000, 'diff open')
    vim.wait(50)
    c.pump()
    assert.falsy(vim.iter(c.messages):find(function(m)
      return m.id == id
    end))
    local info = diff.get(tab)
    vim.api.nvim_buf_set_lines(info.bufnr, 1, 2, false, { 'edited by user' })
    assert.truthy(diff.accept(tab))
    local r = c.response(id)
    assert.eq('FILE_SAVED', text_of(r, 1))
    assert.eq('hello\nedited by user\n', text_of(r, 2))
    assert.eq(2, #r.result.content)
    -- Claude then sends close_tab twice.
    assert.eq('TAB_CLOSED', text_of(c.tool('close_tab', { tab_name = tab })))
    assert.eq('TAB_CLOSED', text_of(c.tool('close_tab', { tab_name = tab })))
    -- The target is never written by Neovim.
    assert.eq('hello\nworld\n', read(target))
  end)

  it('answers DIFF_REJECTED with the tab name when the user rejects or closes the diff', function()
    local id = open_diff('tab-reject')
    wait_for(function()
      return diff.is_open('tab-reject')
    end, 2000)
    assert.truthy(diff.reject('tab-reject'))
    local r = c.response(id)
    assert.eq('DIFF_REJECTED', text_of(r, 1))
    assert.eq('tab-reject', text_of(r, 2))

    local id2 = open_diff('tab-close')
    wait_for(function()
      return diff.is_open('tab-close')
    end, 2000)
    vim.api.nvim_buf_delete(diff.get('tab-close').bufnr, { force = true })
    assert.eq('DIFF_REJECTED', text_of(c.response(id2), 1))
  end)

  it('works for a new file and accepts :w in the proposed buffer', function()
    local newfile = TMP .. '/new.txt'
    local id = open_diff('tab-new', 'fresh\n', newfile)
    wait_for(function()
      return diff.is_open('tab-new')
    end, 2000)
    vim.api.nvim_buf_call(diff.get('tab-new').bufnr, function()
      vim.cmd('write')
    end)
    local r = c.response(id)
    assert.eq('FILE_SAVED', text_of(r, 1))
    assert.eq('fresh\n', text_of(r, 2))
    assert.falsy(uv.fs_stat(newfile))
  end)

  it('rejects a pending diff on close_tab (the user answered in the terminal)', function()
    local id = open_diff('tab-term')
    wait_for(function()
      return diff.is_open('tab-term')
    end, 2000)
    local cid = c.request('tools/call', { name = 'close_tab', arguments = { tab_name = 'tab-term' } })
    assert.eq('DIFF_REJECTED', text_of(c.response(id), 1))
    assert.eq('TAB_CLOSED', text_of(c.response(cid), 1))
    assert.falsy(diff.is_open('tab-term'))
  end)

  it('reloads the target buffer when Claude writes the edit approved in its terminal', function()
    vim.cmd.edit(vim.fn.fnameescape(target))
    local b = vim.api.nvim_get_current_buf()
    local id = open_diff('tab-term-write')
    wait_for(function()
      return diff.is_open('tab-term-write')
    end, 2000)
    assert.eq('TAB_CLOSED', text_of(c.tool('close_tab', { tab_name = 'tab-term-write' })))
    assert.eq('TAB_CLOSED', text_of(c.tool('close_tab', { tab_name = 'tab-term-write' })))
    assert.eq('DIFF_REJECTED', text_of(c.response(id), 1))
    write(target, 'hello\nneovim\n') -- Claude writes the approved content itself
    wait_for(function()
      return vim.api.nvim_buf_get_lines(b, 0, -1, false)[2] == 'neovim'
    end, 3000, 'buffer reloaded')
  end)

  it('reloads the target buffer after an edit without a diff (auto-accept), watched from the baseline', function()
    vim.cmd.edit(vim.fn.fnameescape(target))
    local b = vim.api.nvim_get_current_buf()
    -- Claude takes a diagnostics baseline right before every Edit/Write (§5.4).
    text_of(c.tool('getDiagnostics', { uri = 'file://' .. target }))
    write(target, 'hello\nauto\n')
    wait_for(function()
      return vim.api.nvim_buf_get_lines(b, 0, -1, false)[2] == 'auto'
    end, 3000, 'buffer reloaded')
  end)

  it('closeAllDiffTabs closes only the caller\'s pending diffs', function()
    local other = track(claude_client({ pid = 4242 }))
    local mine = open_diff('mine-1')
    local mine2 = open_diff('mine-2', 'x\n')
    local theirs = other.request('tools/call', { name = 'openDiff', arguments = {
      old_file_path = target, new_file_path = target, new_file_contents = 'y\n', tab_name = 'theirs' } })
    wait_for(function()
      return diff.is_open('mine-1') and diff.is_open('mine-2') and diff.is_open('theirs')
    end, 2000)
    assert.eq('CLOSED_2_DIFF_TABS', text_of(c.tool('closeAllDiffTabs', {})))
    assert.eq('DIFF_REJECTED', text_of(c.response(mine), 1))
    assert.eq('DIFF_REJECTED', text_of(c.response(mine2), 1))
    assert.truthy(diff.is_open('theirs'))
    assert.eq('CLOSED_0_DIFF_TABS', text_of(c.tool('closeAllDiffTabs', {})))
    assert.truthy(diff.accept('theirs'))
    assert.eq('FILE_SAVED', text_of(other.response(theirs), 1))
  end)

  it('replacing a tab_name rejects the older request', function()
    local first = open_diff('same-tab', 'one\n')
    wait_for(function()
      return diff.is_open('same-tab')
    end, 2000)
    local second = open_diff('same-tab', 'two\n')
    assert.eq('DIFF_REJECTED', text_of(c.response(first), 1))
    wait_for(function()
      return diff.get('same-tab') ~= nil
    end, 2000)
    assert.truthy(diff.accept('same-tab'))
    assert.eq('two\n', text_of(c.response(second), 2))
  end)

  it('refuses a file whose buffer has unsaved changes (-32000)', function()
    vim.cmd.edit(vim.fn.fnameescape(target))
    vim.api.nvim_buf_set_lines(0, 0, 1, false, { 'dirty' })
    local r = c.response(open_diff('tab-dirty'))
    assert.eq(-32000, r.error.code)
    assert.eq('Cannot create diff: file has unsaved changes', r.error.message)
    assert.falsy(diff.is_open('tab-dirty'))
    vim.cmd('silent! bwipeout!')
  end)

  it('validates the required parameters (-32602)', function()
    local r = c.tool('openDiff', { old_file_path = target, new_file_path = target, tab_name = 'x' })
    assert.eq(-32602, r.error.code)
  end)

  it('tears the diff down when the client disconnects, and on stop() answers DIFF_REJECTED', function()
    open_diff('tab-gone')
    wait_for(function()
      return diff.is_open('tab-gone')
    end, 2000)
    c.close()
    wait_for(function()
      return not diff.is_open('tab-gone')
    end, 3000, 'diff closed on disconnect')

    local d = track(claude_client())
    local id = d.request('tools/call', { name = 'openDiff', arguments = {
      old_file_path = target, new_file_path = target, new_file_contents = 'z\n', tab_name = 'tab-stop' } })
    wait_for(function()
      return diff.is_open('tab-stop')
    end, 2000)
    P.stop()
    local r = d.response(id)
    assert.eq('DIFF_REJECTED', text_of(r, 1))
    wait_for(function()
      d.pump()
      return d.close_code ~= nil
    end, 3000, 'close frame')
    assert.eq(1001, d.close_code)
    assert.falsy(diff.is_open('tab-stop'))
  end)
end)

describe('getDiagnostics', function()
  local c, path, ns
  before_each(function()
    assert.truthy(P.start())
    c = track(claude_client())
    path = TMP .. '/dir with space/diag.lua'
    vim.fn.mkdir(vim.fs.dirname(path), 'p')
    write(path, 'local x = foo\nprint(x)\n')
    vim.cmd.edit(vim.fn.fnameescape(path))
    ns = vim.api.nvim_create_namespace('provider_claude_spec')
    vim.diagnostic.set(ns, 0, {
      { lnum = 0, col = 10, end_lnum = 0, end_col = 13, severity = vim.diagnostic.severity.WARN,
        message = "undefined global 'foo'", source = 'lua_ls', code = 'undefined-global' },
      { lnum = 1, col = 0, severity = vim.diagnostic.severity.ERROR, message = 'boom', code = 42 },
      { lnum = 1, col = 2, severity = vim.diagnostic.severity.INFO, message = 'info' },
      { lnum = 1, col = 3, severity = vim.diagnostic.severity.HINT, message = 'hint' },
    })
  end)

  after_each(function()
    vim.diagnostic.reset(ns)
  end)

  it('returns raw file:// URIs (no percent-encoding) with Claude severity names', function()
    local uri = 'file://' .. path
    local r = c.tool('getDiagnostics', { uri = uri })
    local list = vim.json.decode(text_of(r))
    assert.eq(1, #list)
    assert.eq(uri, list[1].uri)
    local d = list[1].diagnostics
    assert.eq(4, #d)
    assert.same({ message = "undefined global 'foo'", severity = 'Warning', source = 'lua_ls', code = 'undefined-global',
      range = { start = { line = 0, character = 10 }, ['end'] = { line = 0, character = 13 } } }, d[1])
    assert.eq('Error', d[2].severity)
    assert.eq('42', d[2].code)
    assert.same({ line = 1, character = 0 }, d[2].range['end'])
    assert.eq('Info', d[3].severity)
    assert.eq('Hint', d[4].severity)

    local all = vim.json.decode(text_of(c.tool('getDiagnostics', {})))
    assert.eq(1, #all)
    assert.eq('file://' .. path, all[1].uri)
    assert.falsy(all[1].uri:find('%20', 1, true))
  end)

  it('accepts percent-encoded URIs and plain paths', function()
    local enc = vim.uri_from_fname(path)
    local list = vim.json.decode(text_of(c.tool('getDiagnostics', { uri = enc })))
    assert.eq(4, #list[1].diagnostics)
    list = vim.json.decode(text_of(c.tool('getDiagnostics', { uri = path })))
    assert.eq('file://' .. path, list[1].uri)
    assert.eq(4, #list[1].diagnostics)
  end)

  it('returns an empty entry, echoing the uri, for a file that is not open', function()
    local uri = 'file://' .. TMP .. '/not open.lua'
    local list = vim.json.decode(text_of(c.tool('getDiagnostics', { uri = uri })))
    assert.eq(1, #list)
    assert.eq(uri, list[1].uri)
    assert.eq(0, #list[1].diagnostics)
    assert.matches('"diagnostics":%[%]', text_of(c.tool('getDiagnostics', { uri = uri })))
  end)

  it('is fast', function()
    local t0 = uv.hrtime()
    c.tool('getDiagnostics', { uri = 'file://' .. path })
    assert.truthy((uv.hrtime() - t0) / 1e6 < 200)
  end)
end)

describe('compatibility tools', function()
  local c, file
  before_each(function()
    assert.truthy(P.start())
    c = track(claude_client())
    file = TMP .. '/compat.txt'
    write(file, 'alpha\nbeta\ngamma\ndelta\n')
  end)

  it('checkDocumentDirty and saveDocument', function()
    local r = vim.json.decode(text_of(c.tool('checkDocumentDirty', { filePath = file })))
    assert.same({ success = false, message = 'Document not open: ' .. file }, r)
    vim.cmd.edit(vim.fn.fnameescape(file))
    r = vim.json.decode(text_of(c.tool('checkDocumentDirty', { filePath = file })))
    assert.same({ success = true, filePath = file, isDirty = false, isUntitled = false }, r)
    vim.api.nvim_buf_set_lines(0, 0, 1, false, { 'ALPHA' })
    r = vim.json.decode(text_of(c.tool('checkDocumentDirty', { filePath = file })))
    assert.eq(true, r.isDirty)
    r = vim.json.decode(text_of(c.tool('saveDocument', { filePath = file })))
    assert.same({ success = true, filePath = file, saved = true, message = 'Document saved successfully' }, r)
    assert.eq('ALPHA\nbeta\ngamma\ndelta\n', read(file))
    r = vim.json.decode(text_of(c.tool('saveDocument', { filePath = TMP .. '/nope.txt' })))
    assert.eq(false, r.success)
    assert.eq(-32602, c.tool('saveDocument', {}).error.code)
  end)

  it('getWorkspaceFolders and getOpenEditors', function()
    local r = vim.json.decode(text_of(c.tool('getWorkspaceFolders')))
    assert.eq(true, r.success)
    assert.eq(uv.fs_realpath(vim.fn.getcwd()), r.rootPath)
    assert.eq('file://' .. r.rootPath, r.folders[1].uri)
    assert.eq(vim.fs.basename(r.rootPath), r.folders[1].name)
    r = vim.json.decode(text_of(c.tool('getOpenEditors')))
    assert.same({ tabs = {} }, r)
    vim.cmd.edit(vim.fn.fnameescape(file))
    r = vim.json.decode(text_of(c.tool('getOpenEditors')))
    assert.eq(1, #r.tabs)
    local t = r.tabs[1]
    assert.eq('file://' .. file, t.uri)
    assert.eq(file, t.fileName)
    assert.eq('compat.txt', t.label)
    assert.eq(true, t.isActive)
    assert.eq(false, t.isDirty)
    assert.eq(4, t.lineCount)
    assert.eq(0, t.groupIndex)
    assert.eq(1, t.viewColumn)
  end)

  it('openFile opens, selects lines and reports not-found files', function()
    local r = c.tool('openFile', { filePath = file, startLine = 2, endLine = 3 })
    assert.eq('Opened file and selected lines 2 to 3', text_of(r))
    assert.eq(file, vim.api.nvim_buf_get_name(0))
    assert.eq('V', vim.api.nvim_get_mode().mode)
    assert.eq(2, vim.fn.line('v'))
    assert.eq(3, vim.fn.line('.'))
    vim.cmd('normal! \27')
    r = c.tool('openFile', { filePath = file, startText = 'gam' })
    assert.eq('Opened file and selected text "gam"', text_of(r))
    assert.eq('v', vim.api.nvim_get_mode().mode)
    vim.cmd('normal! \27')
    r = c.tool('openFile', { filePath = file, makeFrontmost = false })
    local ft = vim.bo[vim.fn.bufnr(file)].filetype
    assert.same({ success = true, filePath = file, languageId = ft ~= '' and ft or 'plaintext', lineCount = 4 },
      vim.json.decode(text_of(r)))
    r = c.tool('openFile', { filePath = TMP .. '/missing.txt' })
    assert.eq(-32000, r.error.code)
    assert.eq('File not found: ' .. TMP .. '/missing.txt', r.error.data)
    assert.eq('Opened file: ' .. file, text_of(c.tool('openFile', { filePath = file })))
  end)

  it('getCurrentSelection and getLatestSelection', function()
    vim.cmd.edit(vim.fn.fnameescape(file))
    vim.api.nvim_win_set_cursor(0, { 2, 1 })
    local r = vim.json.decode(text_of(c.tool('getCurrentSelection')))
    assert.eq(true, r.success)
    assert.eq(file, r.filePath)
    assert.same({ line = 1, character = 1 }, r.selection.start)
    assert.eq(true, r.selection.isEmpty)
    r = vim.json.decode(text_of(c.tool('getLatestSelection')))
    assert.eq(file, r.filePath)
    assert.falsy(r.success)
    vim.cmd('enew')
    r = vim.json.decode(text_of(c.tool('getCurrentSelection')))
    assert.eq(true, r.success) -- the latest file selection is kept
  end)
end)

describe('cleanup', function()
  it('removes the lock on VimLeavePre', function()
    assert.truthy(P.start())
    local lock = P.status().lock
    assert.truthy(uv.fs_stat(lock))
    vim.api.nvim_exec_autocmds('VimLeavePre', { group = 'AgentProviderClaude' })
    assert.falsy(uv.fs_stat(lock))
    assert.falsy(P.is_running())
  end)

  it('leaves no lock files behind', function()
    P.stop()
    local left = {}
    if uv.fs_stat(LOCK_DIR) then
      for name in vim.fs.dir(LOCK_DIR) do
        left[#left + 1] = name
      end
    end
    assert.same({}, left)
    P._reset()
    vim.fn.delete(TMP, 'rf')
    assert.falsy(uv.fs_stat(TMP))
  end)
end)
