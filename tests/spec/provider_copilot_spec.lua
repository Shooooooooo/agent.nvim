-- Tests for lua/agent/providers/copilot.lua (locks, socket, tools through the MCP core, diffs,
-- notifications). The wire protocol against a real HTTP client is covered by
-- tests/node/provider_copilot.test.mjs.
local uv = vim.uv
local api = vim.api
local config = require('agent.config')
local util = require('agent.util')
local diff = require('agent.editor.diff')
local P = require('agent.providers.copilot')

local tmp, ide_dir, ws
local saved_env
local notes = {}
vim.notify = function(msg)
  notes[#notes + 1] = msg
end

local function mkdtemp(prefix)
  return assert(uv.fs_mkdtemp(uv.os_tmpdir() .. '/' .. prefix .. '-XXXXXX'))
end

local function read_json(path)
  local f = assert(io.open(path, 'r'))
  local s = f:read('*a')
  f:close()
  return vim.json.decode(s)
end

local function write(path, text)
  local f = assert(io.open(path, 'w'))
  f:write(text)
  f:close()
end

local function mode_of(path)
  return bit.band(uv.fs_stat(path).mode, tonumber('777', 8))
end

local function list_locks(dir)
  local out = {}
  for name, typ in vim.fs.dir(dir) do
    if typ == 'file' and name:match('%.lock$') then
      out[#out + 1] = vim.fs.joinpath(dir, name)
    end
  end
  table.sort(out)
  return out
end

local function setup(extra)
  config.setup(vim.tbl_deep_extend('force', {
    providers = { copilot = { lock_dir = ide_dir } },
  }, extra or {}))
end

-- An in-memory MCP session on the provider's server (tool logic without HTTP).
local function open_session(info)
  local st = P._state()
  local sent = {}
  local session = st.srv:open_session({
    send = function(msg)
      sent[#sent + 1] = msg
      return true
    end,
    info = info or {},
  })
  return session, sent
end

local next_id = 100
local function call(session, name, args)
  next_id = next_id + 1
  local box = { done = false }
  local dispatch = P._state().srv:handle(session, {
    jsonrpc = '2.0',
    id = next_id,
    method = 'tools/call',
    params = { name = name, arguments = args or vim.empty_dict() },
  }, {
    on_response = function(r)
      box.response = r
    end,
    on_done = function()
      box.done = true
    end,
  })
  box.id = next_id
  box.dispatch = dispatch
  return box
end

-- The JSON text of a tool result.
local function result_json(box)
  assert.truthy(box.response, 'no response')
  assert.falsy(box.response.error, 'unexpected error ' .. vim.inspect(box.response.error))
  local content = box.response.result.content
  assert.eq(1, #content)
  assert.eq('text', content[1].type)
  return vim.json.decode(content[1].text, { luanil = { object = true, array = true } }), content[1].text
end

---Focus a scratch buffer in a floating window (a picker, a popup): ignored by selection tracking.
local function focus_float()
  local b = api.nvim_create_buf(false, true)
  return api.nvim_open_win(b, true, { relative = 'editor', row = 1, col = 1, width = 20, height = 3 })
end

local function request(session, method, params)
  next_id = next_id + 1
  local box = {}
  P._state().srv:handle(session, { jsonrpc = '2.0', id = next_id, method = method, params = params }, {
    on_response = function(r)
      box.response = r
    end,
    on_done = function() end,
  })
  return box.response
end

before_each(function()
  require('agent.editor.selection')._reset()
  saved_env = vim.env.COPILOT_HOME
  tmp = mkdtemp('acpt')
  ide_dir = tmp .. '/ide'
  ws = tmp .. '/ws'
  vim.fn.mkdir(ws, 'p')
  write(ws .. '/a.txt', 'hello world\n')
  setup()
end)

after_each(function()
  P.stop()
  diff.close_all()
  diff._stop_watchers()
  vim.cmd('silent! %bwipeout!')
  vim.env.COPILOT_HOME = saved_env
  config.setup({})
  vim.fn.delete(tmp, 'rf')
end)

describe('lock files and socket', function()
  it('start() listens on a short private socket and writes one lock for the cwd', function()
    assert.same({ true, nil }, { P.start() })
    local s = P.status()
    assert.truthy(s.running)
    assert.eq(0, s.clients)
    assert.truthy(#s.address <= P.MAX_SOCKET_PATH, 'socket path too long: ' .. s.address)
    assert.matches('/agentnvim%-%x+/m%.sock$', s.address)
    assert.eq('socket', uv.fs_stat(s.address).type)
    assert.eq(tonumber('700', 8), mode_of(vim.fs.dirname(s.address)))
    assert.eq(tonumber('600', 8), mode_of(s.address))

    local locks = list_locks(ide_dir)
    assert.same({ s.lock }, locks)
    assert.matches('/%x+%-%x+%-4%x+%-[89ab]%x+%-%x+%.lock$', s.lock)
    assert.eq(tonumber('600', 8), mode_of(s.lock))
    assert.eq(tonumber('700', 8), mode_of(ide_dir))

    local info = read_json(s.lock)
    assert.eq(s.address, info.socketPath)
    assert.eq('unix', info.scheme)
    assert.matches('^Nonce %x+$', info.headers.Authorization)
    assert.eq(64, #info.headers.Authorization - #'Nonce ')
    assert.same({ 'Authorization' }, vim.tbl_keys(info.headers))
    assert.eq(vim.fn.getpid(), info.pid)
    assert.eq('Neovim', info.ideName)
    local now = uv.gettimeofday() * 1000
    assert.truthy(math.abs(info.timestamp - now) < 5000, 'timestamp must be epoch milliseconds')
    assert.same({ util.realpath(vim.fn.getcwd()) }, info.workspaceFolders)
    assert.eq(false, info.isTrusted)
    local keys = vim.tbl_keys(info)
    table.sort(keys)
    assert.same({ 'headers', 'ideName', 'isTrusted', 'pid', 'scheme', 'socketPath', 'timestamp', 'workspaceFolders' }, keys)
  end)

  it('start() is idempotent', function()
    P.start()
    local a = P.status()
    assert.truthy(P.start())
    local b = P.status()
    assert.eq(a.address, b.address)
    assert.same(a.locks, b.locks)
    assert.eq(1, #list_locks(ide_dir))
  end)

  it('is disabled by providers.copilot.enabled = false', function()
    setup({ providers = { copilot = { enabled = false } } })
    local ok, err = P.start()
    assert.falsy(ok)
    assert.matches('disabled', err)
    assert.falsy(P.is_running())
    assert.same({}, list_locks(ide_dir))
  end)

  it('isTrusted comes from providers.copilot.trust_workspace (boolean or function)', function()
    setup({ providers = { copilot = { trust_workspace = true } } })
    P.start()
    assert.eq(true, read_json(P.status().lock).isTrusted)
    P.stop()
    local asked = {}
    setup({
      providers = {
        copilot = {
          trust_workspace = function(folder)
            asked[#asked + 1] = folder
            return folder == util.realpath(ws)
          end,
        },
      },
    })
    P.start()
    assert.eq(false, read_json(P.status().lock).isTrusted)
    local info = assert(P.launch_info({ cwd = ws }))
    assert.eq(true, read_json(info.lock).isTrusted)
    assert.truthy(vim.tbl_contains(asked, util.realpath(ws)))
  end)

  it('launch_info() returns the physical folder and adds one lock per folder, never rewritten', function()
    P.start()
    local info = assert(P.launch_info({ cwd = ws }))
    assert.eq(util.realpath(ws), info.lock_folder)
    assert.eq(ide_dir, info.lock_dir)
    assert.eq(P.status().address, info.socket)
    assert.eq(2, #list_locks(ide_dir))
    local lock = read_json(info.lock)
    assert.same({ util.realpath(ws) }, lock.workspaceFolders)
    assert.eq(read_json(P.status().lock).headers.Authorization, lock.headers.Authorization)
    assert.eq(P.status().address, lock.socketPath)

    local st1 = uv.fs_stat(info.lock)
    local before = table.concat(vim.fn.readfile(info.lock), '\n')
    vim.wait(30)
    local again = assert(P.launch_info({ cwd = ws .. '/' }))
    assert.eq(info.lock, again.lock)
    local st2 = uv.fs_stat(info.lock)
    assert.eq(st1.ino, st2.ino)
    assert.eq(st1.mtime.sec, st2.mtime.sec)
    assert.eq(st1.mtime.nsec, st2.mtime.nsec)
    assert.eq(before, table.concat(vim.fn.readfile(info.lock), '\n'))
    assert.eq(2, #list_locks(ide_dir))
  end)

  it('launch_info() starts the server on demand', function()
    assert.falsy(P.is_running())
    local info = assert(P.launch_info({ cwd = ws }))
    assert.truthy(P.is_running())
    assert.truthy(uv.fs_stat(info.lock))
  end)

  it('a symlinked folder is advertised as its physical path plus the literal path', function()
    local link = tmp .. '/link'
    assert(uv.fs_symlink(ws, link))
    P.start()
    local path = assert(P.ensure_lock(link))
    assert.same({ util.realpath(ws), util.abspath(link) }, read_json(path).workspaceFolders)
    -- launch_info resolves the cwd, so the job's cwd (= lock_folder) is the physical path.
    assert.eq(util.realpath(ws), P.launch_info({ cwd = link }).lock_folder)
  end)

  it('a lock that disappeared is recreated (under a new name)', function()
    P.start()
    local info = P.launch_info({ cwd = ws })
    os.remove(info.lock)
    local again = P.launch_info({ cwd = ws })
    assert.truthy(uv.fs_stat(again.lock))
    assert.truthy(again.lock ~= info.lock)
    assert.eq(2, #P.status().locks)
  end)

  it('honours COPILOT_HOME from the job env, then from Neovim, when no lock_dir is configured', function()
    config.setup({})
    local nvim_home = tmp .. '/nvim_home'
    local job_home = tmp .. '/job_home'
    vim.env.COPILOT_HOME = nvim_home
    P.start()
    assert.eq(nvim_home .. '/ide', vim.fs.dirname(P.status().lock))
    local info = assert(P.launch_info({ cwd = ws, env = { COPILOT_HOME = job_home } }))
    assert.eq(job_home .. '/ide', info.lock_dir)
    assert.eq(job_home .. '/ide', vim.fs.dirname(info.lock))
    -- false = unset in the job: the CLI falls back to ~/.copilot (not written here: lock_dir only).
    assert.eq(util.home() .. '/.copilot/ide', P.lock_dir({ COPILOT_HOME = false }))
    assert.eq(nvim_home .. '/ide', P.lock_dir({}))
    -- An empty value counts as unset, as in the CLI.
    assert.eq(util.home() .. '/.copilot/ide', P.lock_dir({ COPILOT_HOME = '' }))
    -- config.agents.copilot.env is used when no env is passed.
    config.setup({ agents = { copilot = { env = { COPILOT_HOME = job_home .. '2' } } } })
    local info2 = assert(P.launch_info({ cwd = ws }))
    assert.eq(job_home .. '2/ide', info2.lock_dir)
    P.stop()
    assert.same({}, list_locks(nvim_home .. '/ide'))
    assert.same({}, list_locks(job_home .. '/ide'))
    assert.same({}, list_locks(job_home .. '2/ide'))
  end)

  it('stop() removes every lock, the socket and its directory', function()
    P.start()
    P.launch_info({ cwd = ws })
    local s = P.status()
    assert.eq(2, #s.locks)
    P.stop()
    assert.falsy(P.is_running())
    assert.same({}, list_locks(ide_dir))
    assert.falsy(uv.fs_stat(s.address))
    assert.falsy(uv.fs_stat(vim.fs.dirname(s.address)))
    assert.same({ running = false, clients = 0, locks = {}, sessions = {}, pending_diffs = {} }, P.status())
    P.stop() -- idempotent
  end)

  it('removes stale Neovim locks (dead pid) and keeps live or foreign ones', function()
    vim.fn.mkdir(ide_dir, 'p')
    -- A pid that certainly is dead: a process that already exited.
    local job = vim.fn.jobstart({ 'true' })
    local dead = vim.fn.jobpid(job)
    vim.fn.jobwait({ job }, 5000)
    local function lock(name, tbl)
      write(ide_dir .. '/' .. name, vim.json.encode(tbl))
    end
    lock('stale.lock', { ideName = 'Neovim', pid = dead, socketPath = '/nonexistent', workspaceFolders = { ws } })
    lock('live.lock', { ideName = 'Neovim', pid = uv.os_getppid(), socketPath = '/x', workspaceFolders = { ws } })
    lock('vscode.lock', { ideName = 'Visual Studio Code', pid = dead, socketPath = '/y', workspaceFolders = { ws } })
    write(ide_dir .. '/broken.lock', '{not json')
    write(ide_dir .. '/other.txt', 'x')
    P.start()
    assert.falsy(uv.fs_stat(ide_dir .. '/stale.lock'))
    assert.truthy(uv.fs_stat(ide_dir .. '/live.lock'))
    assert.truthy(uv.fs_stat(ide_dir .. '/vscode.lock'))
    assert.truthy(uv.fs_stat(ide_dir .. '/broken.lock'))
    assert.truthy(uv.fs_stat(ide_dir .. '/other.txt'))
  end)

  it('socket_path() respects the sun_path limit', function()
    local short = assert(P.socket_path({ '/tmp' }))
    assert.matches('^/tmp/agentnvim%-%x%x%x%x%x%x%x%x%x%x%x%x/m%.sock$', short)
    local long = '/tmp/' .. string.rep('d', P.MAX_SOCKET_PATH)
    assert.matches('^/tmp/agentnvim', assert(P.socket_path({ long, '/tmp' })))
    local p, err = P.socket_path({ long })
    assert.falsy(p)
    assert.matches('at most ' .. P.MAX_SOCKET_PATH .. ' bytes', err)
    -- The configured socket_dir is honoured.
    setup({ providers = { copilot = { socket_dir = tmp } } })
    P.start()
    assert.eq(util.abspath(tmp), vim.fs.dirname(vim.fs.dirname(P.status().address)))
  end)

  it('a too-long socket_dir makes start() fail cleanly', function()
    setup({ providers = { copilot = { socket_dir = '/tmp/' .. string.rep('x', 120) } } })
    local ok, err = P.start()
    assert.falsy(ok)
    assert.matches('bytes', err)
    assert.falsy(P.is_running())
    assert.same({}, list_locks(ide_dir))
  end)

  it('DirChanged adds a lock for the new global cwd', function()
    local old = vim.fn.getcwd()
    P.start()
    vim.cmd('cd ' .. vim.fn.fnameescape(ws))
    local ok = pcall(function()
      assert.eq(2, #list_locks(ide_dir))
      local folders = {}
      for _, l in ipairs(list_locks(ide_dir)) do
        folders[#folders + 1] = read_json(l).workspaceFolders[1]
      end
      assert.truthy(vim.tbl_contains(folders, util.realpath(ws)))
    end)
    vim.cmd('cd ' .. vim.fn.fnameescape(old))
    assert.truthy(ok)
  end)

  it('env() is empty (discovery is by lock file and cwd only)', function()
    assert.same({}, P.env())
  end)
end)

describe('MCP handshake and tools', function()
  before_each(function()
    P.start()
  end)

  it('initialize: serverInfo, tools capability, version negotiation', function()
    local s = open_session()
    local r = request(s, 'initialize', { protocolVersion = '2025-11-25', capabilities = vim.empty_dict(),
      clientInfo = { name = 'copilot-cli', version = '1.0.88' } })
    assert.same({ name = 'agent-nvim-copilot-cli', title = 'Neovim Copilot CLI', version = '0.0.1' }, r.result.serverInfo)
    assert.eq('2025-11-25', r.result.protocolVersion)
    assert.eq(true, r.result.capabilities.tools.listChanged)
    local s2 = open_session()
    assert.eq('2025-03-26', request(s2, 'initialize', { protocolVersion = '2025-03-26' }).result.protocolVersion)
    local s3 = open_session()
    assert.eq('2025-11-25', request(s3, 'initialize', { protocolVersion = '2026-07-28' }).result.protocolVersion)
    assert.same(vim.empty_dict(), request(s, 'ping', vim.empty_dict()).result)
    assert.eq(-32601, request(s, 'server/discover', vim.empty_dict()).error.code)
  end)

  it('tools/list: the six Copilot tools with their schemas', function()
    local s = open_session()
    local r = request(s, 'tools/list', { _meta = { progressToken = 0 } })
    local names = vim.tbl_map(function(t)
      return t.name
    end, r.result.tools)
    assert.same({ 'get_vscode_info', 'get_selection', 'open_diff', 'close_diff', 'get_diagnostics', 'update_session_name' }, names)
    local by = {}
    for _, t in ipairs(r.result.tools) do
      by[t.name] = t
      assert.same({ taskSupport = 'forbidden' }, t.execution)
      assert.eq('object', t.inputSchema.type)
      assert.truthy(type(t.description) == 'string' and #t.description > 10)
    end
    assert.same({ 'original_file_path', 'new_file_contents', 'tab_name' }, by.open_diff.inputSchema.required)
    assert.eq(false, by.open_diff.inputSchema.additionalProperties)
    assert.eq('http://json-schema.org/draft-07/schema#', by.open_diff.inputSchema['$schema'])
    assert.same({ 'tab_name' }, by.close_diff.inputSchema.required)
    assert.same({ 'name' }, by.update_session_name.inputSchema.required)
    assert.eq(nil, by.get_diagnostics.inputSchema.required)
    -- Empty `properties` must be JSON objects.
    local json = vim.json.encode(r.result)
    assert.matches('"properties":{}', json)
    assert.falsy(json:find('"properties":%[%]'))
  end)

  it('get_vscode_info describes this Neovim', function()
    local s = open_session()
    local info = result_json(call(s, 'get_vscode_info'))
    local v = vim.version()
    assert.eq(string.format('%d.%d.%d', v.major, v.minor, v.patch), info.version)
    assert.eq('Neovim', info.appName)
    assert.eq('file', info.uriScheme)
    assert.eq(vim.o.shell, info.shell)
    assert.eq(P._state().instance_id, info.sessionId)
  end)

  it('update_session_name stores the name and fires User AgentSessionName', function()
    local s = open_session({ copilot_pid = 4242 })
    local got
    local id = api.nvim_create_autocmd('User', {
      pattern = 'AgentSessionName',
      callback = function(ev)
        got = ev.data
      end,
    })
    local data, text = result_json(call(s, 'update_session_name', { name = '@a.txt:3-5 PLEASE_EDIT now' }))
    api.nvim_del_autocmd(id)
    assert.same({ success = true }, data)
    assert.eq('{"success":true}', text)
    assert.eq('@a.txt:3-5 PLEASE_EDIT now', s.data.name)
    assert.eq('copilot', got.provider)
    assert.eq('@a.txt:3-5 PLEASE_EDIT now', got.name)
    assert.eq(4242, got.pid)
    assert.eq(nil, got.terminal)
  end)

  it('update_session_name names the agent terminal when it runs the CLI', function()
    local terminal = require('agent.terminal')
    local buf = assert(terminal.open('copilot', {
      focus = false,
      launch = function()
        return { argv = { 'sh', '-c', 'exec cat' }, env = {}, cwd = tmp, cleanup = {} }
      end,
    }))
    local pid = terminal.info().pid
    local got
    local id = api.nvim_create_autocmd('User', {
      pattern = 'AgentSessionName',
      callback = function(ev)
        got = ev.data
      end,
    })
    local ok, err = pcall(function()
      -- A CLI started outside Neovim (auto_start): not the terminal's.
      call(open_session({ copilot_pid = 4242, copilot_parent_pid = 4241 }), 'update_session_name', { name = 'outside' })
      assert.eq(nil, got.terminal)
      assert.eq(nil, vim.b[buf].agent_session_name)
      -- The terminal's job is the CLI's parent (a wrapper script), or the CLI itself.
      call(open_session({ copilot_pid = 4242, copilot_parent_pid = pid }), 'update_session_name', { name = 'inside' })
      assert.eq('copilot', got.terminal)
      assert.eq('inside', vim.b[buf].agent_session_name)
      call(open_session({ copilot_pid = pid }), 'update_session_name', { name = 'itself' })
      assert.eq('copilot', got.terminal)
      assert.eq('itself', vim.b[buf].agent_session_name)
    end)
    api.nvim_del_autocmd(id)
    terminal.stop()
    assert.truthy(vim.wait(5000, function()
      return not vim.api.nvim_buf_is_valid(buf)
    end, 10), 'the terminal job exited')
    assert.truthy(ok, err)
  end)

  it('missing required arguments are JSON-RPC errors; unknown tools too', function()
    local s = open_session()
    local box = call(s, 'update_session_name', vim.empty_dict())
    assert.eq(-32602, box.response.error.code)
    assert.eq(-32602, call(s, 'nope').response.error.code)
  end)
end)

describe('selection', function()
  before_each(function()
    P.start()
  end)

  it('selection_params: 0-based lines, UTF-16 characters, percent-encoded fileUrl', function()
    local path = ws .. '/sp ace.txt'
    write(path, 'aé😀bc\nsecond\n')
    vim.cmd('edit ' .. vim.fn.fnameescape(path))
    local buf = api.nvim_get_current_buf()
    local p = P.selection_params({
      path = api.nvim_buf_get_name(buf), bufnr = buf, text = '😀b',
      start = { line = 0, character = 3 }, finish = { line = 0, character = 8 }, is_empty = false,
    })
    assert.eq('😀b', p.text)
    assert.eq(api.nvim_buf_get_name(buf), p.filePath)
    assert.eq(vim.uri_from_fname(p.filePath), p.fileUrl)
    assert.matches('sp%%20ace%.txt$', p.fileUrl)
    assert.same({ start = { line = 0, character = 2 }, ['end'] = { line = 0, character = 5 }, isEmpty = false }, p.selection)
  end)

  it('get_selection: current editor, cached selection, or null', function()
    local s = open_session()
    -- A floating window is ignored: nothing known yet.
    local float = focus_float()
    local data, text = result_json(call(s, 'get_selection'))
    assert.eq(nil, data)
    assert.eq('null', text)
    api.nvim_win_close(float, true)

    vim.cmd('edit ' .. vim.fn.fnameescape(ws .. '/a.txt'))
    api.nvim_win_set_cursor(0, { 1, 6 })
    local cur = result_json(call(s, 'get_selection'))
    assert.eq(true, cur.current)
    assert.eq('', cur.text)
    assert.eq(api.nvim_buf_get_name(0), cur.filePath)
    assert.same({ start = { line = 0, character = 6 }, ['end'] = { line = 0, character = 6 }, isEmpty = true }, cur.selection)

    -- Focus on an ignored window: the last selection is returned with current=false.
    P.on_selection({ path = api.nvim_buf_get_name(0), bufnr = api.nvim_get_current_buf(), text = 'hello',
      start = { line = 0, character = 0 }, finish = { line = 0, character = 5 }, is_empty = false })
    focus_float()
    local cached = result_json(call(s, 'get_selection'))
    assert.eq(false, cached.current)
    assert.truthy(cached.filePath:match('a%.txt$'))
  end)

  it('get_selection: the file window stays the active editor while the agent terminal has focus', function()
    local selection = require('agent.editor.selection')
    selection.start()
    local s = open_session()
    local file = util.realpath(ws) .. '/a.txt'
    vim.cmd('edit ' .. vim.fn.fnameescape(file))
    local file_win = api.nvim_get_current_win()
    api.nvim_win_set_cursor(0, { 1, 0 })
    vim.cmd('normal! vllll')
    local sel = selection.current()
    vim.cmd('normal! \27')
    assert.eq('hello', sel.text)
    P.on_selection(sel)
    -- Focus moves to the agent terminal in another window; a.txt is still shown.
    vim.cmd('vsplit')
    vim.cmd('enew')
    local job = vim.fn.jobstart({ 'sleep', '20' }, { term = true })
    vim.b.agent_nvim_agent = 'copilot'
    local term_win = api.nvim_get_current_win()
    local ok, err = pcall(function()
      assert.eq('terminal', vim.bo.buftype)
      local data = result_json(call(s, 'get_selection'))
      assert.eq('hello', data.text)
      assert.eq(file, data.filePath)
      assert.eq(true, data.current)

      -- Without selection tracking the last focused file is unknown: a selection read earlier
      -- is only a cached one.
      selection.stop()
      api.nvim_set_current_win(file_win)
      assert.eq(true, result_json(call(s, 'get_selection')).current)
      api.nvim_set_current_win(term_win)
      data = result_json(call(s, 'get_selection'))
      assert.eq(file, data.filePath)
      assert.eq(false, data.current)

      -- Once a.txt is no longer shown, the selection is only a cached one.
      selection.start()
      api.nvim_set_current_win(file_win)
      api.nvim_set_current_win(term_win)
      assert.eq(true, result_json(call(s, 'get_selection')).current)
      api.nvim_win_close(file_win, true)
      assert.eq('terminal', vim.bo.buftype)
      data = result_json(call(s, 'get_selection'))
      assert.eq(file, data.filePath)
      assert.eq(false, data.current)
    end)
    vim.fn.jobstop(job)
    selection.stop()
    assert.truthy(ok, err)
  end)
end)

describe('diagnostics', function()
  before_each(function()
    P.start()
  end)

  it('get_diagnostics: Copilot shape, severity names, UTF-16 columns, file filter', function()
    local path = ws .. '/d.lua'
    write(path, 'local é = x\nprint(y)\n')
    vim.cmd('edit ' .. vim.fn.fnameescape(path))
    local buf = api.nvim_get_current_buf()
    local ns = api.nvim_create_namespace('copilot_spec')
    vim.diagnostic.set(ns, buf, {
      { lnum = 0, col = 11, end_lnum = 0, end_col = 12, message = 'undefined x', severity = 1, source = 'lua_ls', code = 'undefined-global' },
      { lnum = 1, col = 6, end_lnum = 1, end_col = 7, message = 'maybe y', severity = 2 },
      { lnum = 1, col = 0, message = 'info', severity = 3, code = 42 },
      { lnum = 1, col = 0, message = 'hint', severity = 4 },
    })
    vim.cmd('edit ' .. vim.fn.fnameescape(ws .. '/a.txt')) -- a file without diagnostics
    local s = open_session()
    local all = result_json(call(s, 'get_diagnostics'))
    assert.eq(1, #all)
    local f = all[1]
    local name = api.nvim_buf_get_name(buf)
    assert.eq(name, f.filePath)
    assert.eq(vim.uri_from_fname(name), f.uri)
    assert.eq(4, #f.diagnostics)
    assert.same({
      message = 'undefined x', severity = 'error', source = 'lua_ls', code = 'undefined-global',
      range = { start = { line = 0, character = 10 }, ['end'] = { line = 0, character = 11 } },
    }, f.diagnostics[1])
    local sev = vim.tbl_map(function(d)
      return d.severity
    end, f.diagnostics)
    table.sort(sev)
    assert.same({ 'error', 'hint', 'information', 'warning' }, sev)
    for _, d in ipairs(f.diagnostics) do
      if d.message == 'maybe y' then
        assert.eq(nil, d.source)
        assert.eq(nil, d.code)
      elseif d.message == 'info' then
        assert.eq(42, d.code)
      end
    end
    -- By URI (percent-encoded file URL) or plain path; a file without diagnostics gives [].
    assert.eq(1, #result_json(call(s, 'get_diagnostics', { uri = vim.uri_from_fname(name) })))
    assert.eq(1, #result_json(call(s, 'get_diagnostics', { uri = name })))
    local _, empty = result_json(call(s, 'get_diagnostics', { uri = vim.uri_from_fname(ws .. '/a.txt') }))
    assert.eq('[]', empty)
    local _, other = result_json(call(s, 'get_diagnostics', { uri = 'untitled:Untitled-1' }))
    assert.eq('[]', other)
    vim.diagnostic.reset(ns)
    local _, none = result_json(call(s, 'get_diagnostics'))
    assert.eq('[]', none)
  end)
end)

describe('open_diff / close_diff', function()
  local s
  before_each(function()
    P.start()
    s = open_session({ copilot_session_id = 'cid' })
  end)

  local function open(file, contents, tab)
    local box = call(s, 'open_diff', {
      original_file_path = file,
      new_file_contents = contents,
      tab_name = tab,
    })
    return box
  end

  it('accept -> SAVED/accepted_via_button; the proposal is read-only and not written by Neovim', function()
    local file = util.realpath(ws) .. '/b.txt'
    local tab = '[Copilot CLI] - b.txt (bdeb09)'
    local box = open(file, 'brand new file\n', tab)
    assert.falsy(box.done)
    assert.truthy(diff.is_open(tab))
    local d = diff.get(tab)
    assert.eq(false, d.editable)
    assert.eq(false, vim.bo[d.bufnr].modifiable)
    assert.same({ 'brand new file' }, api.nvim_buf_get_lines(d.bufnr, 0, -1, false))
    assert.same({ tab }, P.status().pending_diffs)
    assert.truthy(diff.accept(tab))
    assert.truthy(box.done)
    local data = result_json(box)
    assert.same({
      success = true,
      result = 'SAVED',
      trigger = 'accepted_via_button',
      tab_name = tab,
      message = 'User accepted changes for ' .. file,
    }, data)
    assert.falsy(diff.is_open(tab))
    assert.falsy(uv.fs_stat(file), 'the CLI writes the file, not Neovim')
    assert.same({}, P.status().pending_diffs)
  end)

  it(':w in the proposed buffer accepts', function()
    local file = util.realpath(ws) .. '/a.txt'
    local tab = '[Copilot CLI] - a.txt (000001)'
    local box = open(file, 'hello neovim\n', tab)
    local d = diff.get(tab)
    api.nvim_set_current_win(vim.fn.bufwinid(d.bufnr))
    vim.cmd('write')
    wait_for(function()
      return box.done
    end, 2000)
    assert.eq('SAVED', result_json(box).result)
    assert.eq('hello world', vim.fn.readfile(file)[1])
  end)

  it('reject -> REJECTED/rejected_via_button', function()
    local file = util.realpath(ws) .. '/a.txt'
    local tab = '[Copilot CLI] - a.txt (cbb44d)'
    local box = open(file, 'hello neovim\n', tab)
    assert.truthy(diff.reject(tab))
    assert.same({
      success = true,
      result = 'REJECTED',
      trigger = 'rejected_via_button',
      tab_name = tab,
      message = 'User rejected changes for ' .. file,
    }, result_json(box))
  end)

  it('close_diff while pending -> REJECTED/closed_via_tool, UI closed, buffer reloaded after the CLI writes', function()
    local file = util.realpath(ws) .. '/a.txt'
    vim.cmd('edit ' .. vim.fn.fnameescape(file))
    local buf = api.nvim_get_current_buf()
    local tab = '[Copilot CLI] - a.txt (e66943)'
    local box = open(file, 'hello neovim\n', tab)
    local close = call(s, 'close_diff', { tab_name = tab })
    assert.same({
      success = true,
      already_closed = false,
      tab_name = tab,
      message = 'Diff "' .. tab .. '" closed successfully',
    }, result_json(close))
    local data = result_json(box)
    assert.eq('REJECTED', data.result)
    assert.eq('closed_via_tool', data.trigger)
    assert.eq('User rejected changes for ' .. file, data.message)
    assert.falsy(diff.is_open(tab))
    -- The user said "Yes" in the terminal: the CLI writes the file, and the buffer follows.
    vim.wait(150)
    write(file, 'hello neovim\n')
    wait_for(function()
      return api.nvim_buf_get_lines(buf, 0, 1, false)[1] == 'hello neovim'
    end, 3000, 'buffer reload')
  end)

  it('close_diff still reloads the buffer when the CLI wrote the file before the handler ran', function()
    -- The CLI fires close_diff without waiting and writes the file 1-2 ms later: the write can land
    -- before Neovim gets to the close_diff handler.
    local file = util.realpath(ws) .. '/a.txt'
    vim.cmd('edit ' .. vim.fn.fnameescape(file))
    local buf = api.nvim_get_current_buf()
    local tab = '[Copilot CLI] - a.txt (7a3c01)'
    local box = open(file, 'hello neovim\n', tab)
    write(file, 'hello neovim\n')
    call(s, 'close_diff', { tab_name = tab })
    assert.eq('closed_via_tool', result_json(box).trigger)
    wait_for(function()
      return api.nvim_buf_get_lines(buf, 0, 1, false)[1] == 'hello neovim'
    end, 3000, 'buffer reload')
  end)

  it('close_diff reloads a new file the CLI created before the handler ran', function()
    local file = util.realpath(ws) .. '/new.txt'
    vim.cmd('edit ' .. vim.fn.fnameescape(file))
    local buf = api.nvim_get_current_buf()
    local tab = '[Copilot CLI] - new.txt (7a3c02)'
    open(file, 'created\n', tab)
    write(file, 'created\n')
    call(s, 'close_diff', { tab_name = tab })
    wait_for(function()
      return api.nvim_buf_get_lines(buf, 0, 1, false)[1] == 'created'
    end, 3000, 'buffer reload')
  end)

  it('close_diff for an unknown tab -> already_closed', function()
    local tab = '[Copilot CLI] - x.txt (ffffff)'
    assert.same({
      success = true,
      already_closed = true,
      tab_name = tab,
      message = 'No active diff found with tab name "' .. tab .. '" (may already be closed)',
    }, result_json(call(s, 'close_diff', { tab_name = tab })))
  end)

  it('closing the diff UI keeps the call pending until close_diff', function()
    local file = util.realpath(ws) .. '/a.txt'
    local tab = '[Copilot CLI] - a.txt (aaaaaa)'
    local box = open(file, 'hello neovim\n', tab)
    local d = diff.get(tab)
    vim.cmd('bwipeout! ' .. d.bufnr)
    wait_for(function()
      return not diff.is_open(tab)
    end, 1000)
    wait_for(function()
      return #notes > 0
    end, 1000, 'notification')
    assert.matches('still waiting', notes[#notes])
    assert.falsy(box.done)
    assert.same({ tab }, P.status().pending_diffs)
    local close = result_json(call(s, 'close_diff', { tab_name = tab }))
    assert.eq(false, close.already_closed)
    local data = result_json(box)
    assert.eq('REJECTED', data.result)
    assert.eq('closed_via_tool', data.trigger)
    assert.same({}, P.status().pending_diffs)
  end)

  it('the session ending dismisses its pending diff without an answer', function()
    local tab = '[Copilot CLI] - a.txt (bbbbbb)'
    local box = open(util.realpath(ws) .. '/a.txt', 'x\n', tab)
    P._state().srv:close_session(s, 'deleted')
    assert.truthy(box.done)
    assert.eq(nil, box.response)
    assert.falsy(diff.is_open(tab))
    assert.same({}, P.status().pending_diffs)
  end)

  it('notifications/cancelled dismisses the diff', function()
    local tab = '[Copilot CLI] - a.txt (cccccc)'
    local box = open(util.realpath(ws) .. '/a.txt', 'x\n', tab)
    P._state().srv:handle(s, { jsonrpc = '2.0', method = 'notifications/cancelled', params = { requestId = box.id } })
    assert.truthy(box.done)
    assert.eq(nil, box.response)
    assert.falsy(diff.is_open(tab))
  end)

  it('the HTTP client going away dismisses the diff', function()
    local tab = '[Copilot CLI] - a.txt (dddddd)'
    local box = open(util.realpath(ws) .. '/a.txt', 'x\n', tab)
    box.dispatch:cancel('disconnect')
    assert.falsy(diff.is_open(tab))
    assert.same({}, P.status().pending_diffs)
  end)

  it('stop() dismisses pending diffs', function()
    local tab = '[Copilot CLI] - a.txt (eeeeee)'
    open(util.realpath(ws) .. '/a.txt', 'x\n', tab)
    assert.truthy(diff.is_open(tab))
    P.stop()
    assert.falsy(diff.is_open(tab))
  end)

  it('a second open_diff with the same tab name answers the first', function()
    local file = util.realpath(ws) .. '/a.txt'
    local tab = '[Copilot CLI] - a.txt (121212)'
    local first = open(file, 'one\n', tab)
    local second = open(file, 'two\n', tab)
    local r1 = result_json(first)
    assert.eq('REJECTED', r1.result)
    assert.eq('closed_via_tool', r1.trigger)
    assert.falsy(second.done)
    assert.same({ 'two' }, api.nvim_buf_get_lines(diff.get(tab).bufnr, 0, -1, false))
    diff.accept(tab)
    assert.eq('SAVED', result_json(second).result)
  end)

  it('an unreadable original is an isError result', function()
    local box = open(ws, 'x\n', '[Copilot CLI] - ws (0)')
    assert.truthy(box.done)
    assert.eq(true, box.response.result.isError)
    assert.matches('^Failed to open diff: ', box.response.result.content[1].text)
    assert.same({}, P.status().pending_diffs)
    local bad = call(s, 'open_diff', { original_file_path = 1, new_file_contents = 'x', tab_name = 't' })
    assert.eq(true, bad.response.result.isError)
  end)

  it('retries opening the diff while Neovim forbids window changes (E565)', function()
    local real_open = diff.open
    local attempts = 0
    diff.open = function(o)
      attempts = attempts + 1
      if attempts <= 2 then
        error('Vim:E565: Not allowed to change text or change window')
      end
      return real_open(o)
    end
    local ok, err = pcall(function()
      local tab = '[Copilot CLI] - a.txt (565565)'
      local box = open(util.realpath(ws) .. '/a.txt', 'x\n', tab)
      assert.falsy(box.done)
      assert.falsy(diff.is_open(tab))
      wait_for(function()
        return diff.is_open(tab)
      end, 2000, 'diff opened after retries')
      assert.eq(3, attempts)
      assert.falsy(box.done)
      diff.accept(tab)
      assert.eq('SAVED', result_json(box).result)
    end)
    diff.open = real_open
    assert.truthy(ok, err)
  end)

  it('VimLeavePre-style disconnect answers REJECTED/client_disconnected', function()
    local tab = '[Copilot CLI] - a.txt (989898)'
    local box = open(util.realpath(ws) .. '/a.txt', 'x\n', tab)
    diff.close(tab, { resolve = true, trigger = 'disconnect' })
    local data = result_json(box)
    assert.eq('REJECTED', data.result)
    assert.eq('client_disconnected', data.trigger)
  end)
end)

describe('notifications', function()
  -- Register an in-memory session with the binding and pretend it has a GET stream.
  local function streaming_session(info)
    local st = P._state()
    local session, sent = open_session(info)
    session.initialized = true
    st.binding._sessions[session.id] = session
    st.binding._streams[session] = { res = { closed = false } }
    return session, sent
  end

  before_each(function()
    P.start()
  end)

  it('on_selection broadcasts selection_changed to streaming sessions and caches it', function()
    local a, sent_a = streaming_session({ last_activity = 1 })
    local _, sent_idle = open_session()
    local file = util.realpath(ws) .. '/a.txt'
    vim.cmd('edit ' .. vim.fn.fnameescape(file))
    P.on_selection({ path = file, bufnr = api.nvim_get_current_buf(), text = 'hello',
      start = { line = 0, character = 0 }, finish = { line = 0, character = 5 }, is_empty = false })
    assert.eq(1, #sent_a)
    assert.same({}, sent_idle)
    local msg = sent_a[1]
    assert.eq('selection_changed', msg.method)
    assert.same({
      text = 'hello', filePath = file, fileUrl = vim.uri_from_fname(file),
      selection = { start = { line = 0, character = 0 }, ['end'] = { line = 0, character = 5 }, isEmpty = false },
    }, msg.params)
    assert.eq(nil, msg.params.current)
    assert.truthy(P._state().last_selection)
    P.on_selection(nil)
    P.on_selection({ path = '' })
    assert.eq(1, #sent_a)
    a:close()
  end)

  it('a selection dropped by leaving Visual mode reaches the stream, the cache and get_selection', function()
    local selection = require('agent.editor.selection')
    selection.start()
    local unsubscribe = selection.subscribe(P.on_selection) -- as agent.nvim forwards it
    local a, sent = streaming_session()
    local ok, err = pcall(function()
      local file = util.realpath(ws) .. '/a.txt'
      vim.cmd('edit ' .. vim.fn.fnameescape(file))
      api.nvim_win_set_cursor(0, { 1, 0 })
      vim.cmd('normal! vllll')
      wait_for(function()
        return #sent > 0 and sent[#sent].params.text == 'hello'
      end, 2000, 'selection_changed with the selection')
      vim.cmd('normal! \27')
      wait_for(function()
        return sent[#sent].params.selection.isEmpty
      end, 2000, 'selection_changed with the cursor only')
      assert.eq('', sent[#sent].params.text)
      assert.eq(file, sent[#sent].params.filePath)
      assert.eq('', P._state().last_selection.text)
      local data = result_json(call(a, 'get_selection'))
      assert.eq('', data.text)
      assert.eq(true, data.current)
      -- An ignored window has focus: the cached selection is the dropped one too.
      focus_float()
      data = result_json(call(a, 'get_selection'))
      assert.eq('', data.text)
      assert.eq(file, data.filePath)
    end)
    unsubscribe()
    selection.stop()
    a:close()
    assert.truthy(ok, err)
  end)

  it('a terminal (not the agent\'s) goes by its nvim://buffer/ id, with UTF-16 columns from its lines', function()
    local selection = require('agent.editor.selection')
    selection.start()
    local unsubscribe = selection.subscribe(P.on_selection) -- as agent.nvim forwards it
    local a, sent = streaming_session()
    vim.cmd('botright vnew')
    local job = vim.fn.jobstart({ '/bin/sh', '-c', 'echo "héllo 😀 wörld"; exec sleep 30' }, { term = true })
    local term = api.nvim_get_current_buf()
    local ok, err = pcall(function()
      local id = ('nvim://buffer/%d/sh'):format(term)
      wait_for(function()
        return api.nvim_buf_get_lines(term, 0, 1, false)[1] == 'héllo 😀 wörld'
      end, 3000, 'terminal output')
      wait_for(function()
        return #sent > 0 and sent[#sent].params.filePath == id
      end, 2000, 'selection_changed for the terminal')
      assert.eq(id, sent[#sent].params.fileUrl)
      -- Its cursor goes at line 0, column 0: moving it (as it follows the output) sends nothing.
      local zero = { start = { line = 0, character = 0 }, ['end'] = { line = 0, character = 0 }, isEmpty = true }
      assert.same(zero, sent[#sent].params.selection)
      selection.flush()
      local n = #sent
      api.nvim_win_set_cursor(0, { 2, 0 })
      api.nvim_exec_autocmds('CursorMoved', {})
      selection.flush()
      vim.wait(100)
      assert.eq(n, #sent, 'no selection_changed for a cursor move')
      assert.same(zero, result_json(call(a, 'get_selection')).selection)
      -- From the emoji (byte 7, UTF-16 6: é is 2 bytes / 1 unit) to the end of the line.
      api.nvim_win_set_cursor(0, { 1, 7 })
      vim.cmd('normal! vg_')
      wait_for(function()
        return sent[#sent].params.text == '😀 wörld'
      end, 2000, 'selection_changed with the terminal selection')
      local want = {
        text = '😀 wörld', filePath = id, fileUrl = id,
        selection = { start = { line = 0, character = 6 }, ['end'] = { line = 0, character = 14 }, isEmpty = false },
      }
      assert.same(want, sent[#sent].params)
      want.current = true
      assert.same(want, result_json(call(a, 'get_selection')))
      assert.same(want, (function()
        -- Straight from Visual mode to an ignored window: the selection is kept, and the terminal
        -- is still the active editor.
        focus_float()
        vim.wait(selection.DEMOTE_MS + 100)
        return result_json(call(a, 'get_selection'))
      end)())
    end)
    vim.fn.jobstop(job)
    unsubscribe()
    selection.stop()
    a:close()
    assert.truthy(ok, err)
  end)

  describe('send_context (:AgentSend)', function()
    local selection = require('agent.editor.selection')
    local file

    before_each(function()
      file = util.realpath(ws) .. '/a.txt'
      write(file, 'one\ntwo\nthrée\nfour\n')
      vim.cmd('edit ' .. vim.fn.fnameescape(file))
    end)

    -- A connected CLI (initialized) without an event stream yet.
    local function connected_session(info)
      local session, sent = open_session(info)
      session.initialized = true
      P._state().binding._sessions[session.id] = session
      return session, sent
    end

    -- Its GET stream opens (again), as the binding reports it.
    local function open_stream(session)
      local b = P._state().binding
      b._streams[session] = { res = { closed = false } }
      b:_hook('on_stream_open', session, b)
    end

    it('sends selection_changed to the CLI in the agent terminal (its pid or its parent\'s), not to others', function()
      local s = selection.capture({ line1 = 2, line2 = 3 })
      local old, sent_old = streaming_session({ copilot_pid = 11, copilot_parent_pid = 10 })
      local new, sent_new = streaming_session({ copilot_pid = 21, copilot_parent_pid = 20 })
      local idle, sent_idle = connected_session({ copilot_pid = 12, copilot_parent_pid = 10 })

      -- The terminal job's pid (the CLI's parent): lines 2-3, UTF-16 end column.
      assert.truthy(P.send_context(s, { pid = 10 }))
      assert.eq(1, #sent_old)
      assert.eq('selection_changed', sent_old[1].method)
      assert.same({
        text = 'two\nthrée', filePath = file, fileUrl = vim.uri_from_fname(file),
        selection = { start = { line = 1, character = 0 }, ['end'] = { line = 2, character = 5 }, isEmpty = false },
      }, sent_old[1].params)
      assert.same({}, sent_new)
      assert.same({}, sent_idle, 'no stream: nothing')

      -- The CLI's own pid; the cursor only stands for the whole file.
      api.nvim_win_set_cursor(0, { 3, 5 }) -- after 'thré' (é is 2 bytes, 1 UTF-16 unit)
      assert.truthy(P.send_context(selection.capture(), { pid = 21 }))
      assert.same({
        text = '', filePath = file, fileUrl = vim.uri_from_fname(file),
        selection = { start = { line = 2, character = 4 }, ['end'] = { line = 2, character = 4 }, isEmpty = true },
      }, sent_new[1].params)

      -- Never to another CLI.
      assert.falsy(P.send_context(s, { pid = 999 }))
      assert.eq(1, #sent_old)
      assert.eq(1, #sent_new)
      -- No pid (no agent terminal, terminal.layout = 'none'): every CLI with a stream.
      assert.truthy(P.send_context(s))
      assert.eq(2, #sent_old)
      assert.eq(2, #sent_new)
      assert.same({}, sent_idle)
      for _, m in ipairs(vim.list_extend(vim.list_extend({}, sent_old), sent_new)) do
        assert.eq('selection_changed', m.method, 'add_file_reference is never sent')
      end
      old:close()
      new:close()
      idle:close()
    end)

    it('client_state: ready with an event stream, connecting without one, else nil', function()
      assert.eq(nil, P.client_state({ pid = 10 }))
      local s = connected_session({ copilot_pid = 11, copilot_parent_pid = 10 })
      assert.eq('connecting', P.client_state({ pid = 10 }))
      assert.eq(nil, P.client_state({ pid = 20 }))
      assert.falsy(P.send_context(selection.capture(), { pid = 10 }), 'no stream: not delivered')
      P._state().binding._streams[s] = { res = { closed = false } }
      assert.eq('ready', P.client_state({ pid = 10 }))
      assert.eq('ready', P.client_state())
      s:close()
    end)

    it('is replayed when a stream of that CLI opens (every reconnect); with selection.track = false, nothing else', function()
      local s = selection.capture({ line1 = 2 })
      local want = P.selection_params(s)
      assert.eq('two', want.text)
      assert.falsy(P.send_context(s, { pid = 10 }), 'no CLI yet')
      local a, sent_a = connected_session({ copilot_pid = 11, copilot_parent_pid = 10 })
      local b, sent_b = connected_session({ copilot_pid = 21, copilot_parent_pid = 20 })
      open_stream(a)
      open_stream(b)
      assert.eq(1, #sent_a)
      assert.eq('selection_changed', sent_a[1].method)
      assert.same(want, sent_a[1].params)
      assert.same({}, sent_b, 'another CLI')
      open_stream(a) -- the CLI clears its cache on every reconnect
      assert.eq(2, #sent_a)
      assert.same(want, sent_a[2].params)
      -- Sent with no pid: every CLI with a stream now, and replayed to those sessions only.
      assert.truthy(P.send_context(s))
      assert.eq(3, #sent_a)
      assert.eq(1, #sent_b)
      open_stream(b)
      assert.eq(2, #sent_b)
      assert.same(want, sent_b[2].params)
      local c, sent_c = connected_session({ copilot_pid = 31, copilot_parent_pid = 30 })
      open_stream(c)
      assert.same({}, sent_c, 'a session it was not sent to')
      a:close()
      b:close()
      c:close()
    end)

    it('sent with no pid (terminal.layout = \'none\'): replayed only to the sessions it was sent to', function()
      local s = selection.capture({ line1 = 2 })
      local want = P.selection_params(s)
      local a, sent_a = streaming_session({ copilot_pid = 11, copilot_parent_pid = 10 })
      local b, sent_b = streaming_session({ copilot_pid = 21, copilot_parent_pid = 20 })
      local idle, sent_idle = connected_session({ copilot_pid = 31, copilot_parent_pid = 30 })
      assert.truthy(P.send_context(s))
      assert.same({ want }, vim.tbl_map(function(m)
        return m.params
      end, sent_a))
      assert.eq(1, #sent_b)
      assert.same({}, sent_idle, 'no stream: not sent')
      -- A stream of a session it was sent to opens again (the CLI reconnects): it gets it again.
      open_stream(a)
      open_stream(b)
      assert.eq(2, #sent_a)
      assert.same(want, sent_a[2].params)
      assert.eq(2, #sent_b)
      -- A session that had no stream then, or a new one (even of the same CLI): nothing.
      open_stream(idle)
      assert.same({}, sent_idle)
      local new, sent_new = connected_session({ copilot_pid = 11, copilot_parent_pid = 10 })
      open_stream(new)
      assert.same({}, sent_new, 'a new session of the CLI in a: not sent to it')
      -- Sent again with a pid: its CLI's sessions, the new one included, from now on.
      assert.truthy(P.send_context(s, { pid = 10 }))
      assert.eq(3, #sent_a)
      assert.eq(1, #sent_new)
      assert.eq(2, #sent_b)
      open_stream(b)
      assert.eq(2, #sent_b, 'b: it is for the CLI with pid 10 now')
      open_stream(new)
      assert.eq(2, #sent_new)
      a:close()
      b:close()
      idle:close()
      new:close()
    end)

    it('with selection.track = true, it follows the tracked selection on replay until on_selection replaces it', function()
      setup({ selection = { track = true } })
      local buf = api.nvim_get_current_buf()
      local tracked = { path = file, bufnr = buf, text = 'one', start = { line = 0, character = 0 },
        finish = { line = 0, character = 3 }, is_empty = false }
      P.on_selection(tracked)
      local s = selection.capture({ line1 = 2 })
      local a, sent_a = streaming_session({ copilot_pid = 11, copilot_parent_pid = 10 })
      assert.truthy(P.send_context(s, { pid = 10 }))
      assert.eq('two', sent_a[1].params.text)
      -- A new stream of that CLI: the tracked selection, then what was sent (the latest).
      local b, sent_b = connected_session({ copilot_pid = 12, copilot_parent_pid = 10 })
      open_stream(b)
      assert.same({ 'one', 'two' }, vim.tbl_map(function(m)
        return m.params.text
      end, sent_b))
      -- The next selection event replaces it, for good.
      P.on_selection(vim.tbl_extend('force', tracked, { text = 'on', finish = { line = 0, character = 2 } }))
      assert.eq(nil, P._state().context)
      assert.eq('on', sent_a[2].params.text)
      local c, sent_c = connected_session({ copilot_pid = 13, copilot_parent_pid = 10 })
      open_stream(c)
      assert.same({ 'on' }, vim.tbl_map(function(m)
        return m.params.text
      end, sent_c))
      a:close()
      b:close()
      c:close()
    end)

    it('clear_context(pid) forgets it when the agent terminal with that job pid ends: no replay then', function()
      local s = selection.capture({ line1 = 2 })
      assert.falsy(P.send_context(s, { pid = 10 }))
      -- Another agent (terminal) ended: kept.
      P.clear_context(20)
      P.clear_context(nil)
      local a, sent_a = connected_session({ copilot_pid = 11, copilot_parent_pid = 10 })
      open_stream(a)
      assert.eq(1, #sent_a)
      assert.eq('two', sent_a[1].params.text)
      -- Its own ended: forgotten. The next stream of that CLI, or of the one started next, gets nothing.
      P.clear_context(10)
      assert.eq(nil, P._state().context)
      open_stream(a)
      assert.eq(1, #sent_a)
      local b, sent_b = connected_session({ copilot_pid = 12, copilot_parent_pid = 10 })
      open_stream(b)
      assert.same({}, sent_b)
      -- Sent with no pid (no agent terminal, terminal.layout = 'none'): a pid does not forget it.
      assert.truthy(P.send_context(s))
      assert.eq(1, #sent_b)
      P.clear_context(10)
      open_stream(b)
      assert.eq(2, #sent_b)
      P.clear_context(nil)
      open_stream(b)
      assert.eq(2, #sent_b)
      assert.eq(2, #sent_a, 'sent to every CLI once')
      -- Safe when stopped.
      a:close()
      b:close()
      P.stop()
      P.clear_context(10)
    end)

    it('returns false without a connected CLI or when stopped; stop() forgets it', function()
      local s = selection.capture()
      assert.falsy(P.send_context(s))
      assert.falsy(P.send_context(nil))
      assert.falsy(P.send_context({ path = '' }))
      assert.truthy(P._state().context, 'remembered for a CLI that connects later')
      P.stop()
      assert.falsy(P.send_context(s))
      assert.eq(nil, P.client_state())
      P.start()
      assert.eq(nil, P._state().context)
      local a, sent_a = connected_session({})
      open_stream(a)
      assert.same({}, sent_a)
      a:close()
    end)
  end)
end)
