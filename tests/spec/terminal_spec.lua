local terminal = require('agent.terminal')
local agents = require('agent.agents')
local config = require('agent.config')
local util = require('agent.util')

local FIX = TEST_ROOT .. '/tests/fixtures/fake_agent.sh'

local tmp, notes
local orig_notify = vim.notify

local function read(path)
  local f = io.open(path, 'rb')
  if not f then
    return nil
  end
  local s = f:read('*a')
  f:close()
  return s
end

local function read_env(out)
  local env = {}
  for line in (read(out .. '.env') or ''):gmatch('[^\n]+') do
    local k, v = line:match('^([%w_]+)=(.*)$')
    if k then
      env[k] = v
    end
  end
  return env
end

local function read_args(out)
  local args = {}
  for line in (read(out .. '.args') or ''):gmatch('[^\n]+') do
    args[#args + 1] = line
  end
  return args
end

local function wait_ready(out)
  wait_for(function()
    return vim.fn.filereadable(out .. '.env') == 1
  end, 5000, out .. '.env')
end

local counter = 0
---A launcher returning a minimal spec for the fake agent. `extra` is merged into the spec, and
---`extra.env` into its env.
local function fake(extra)
  extra = extra or {}
  counter = counter + 1
  local out = tmp .. '/out' .. counter
  local launch = function(name)
    local env = vim.tbl_extend('force', { FAKE_AGENT_OUT = out }, extra.env or {})
    local spec = {
      name = name,
      argv = { FIX, 'arg one', 'two' },
      env = env,
      clear_env = false,
      cwd = tmp,
      cleanup = {},
      session_id = 'session-' .. counter,
      warnings = {},
      exit_hints = {},
    }
    for k, v in pairs(extra) do
      if k ~= 'env' then
        spec[k] = v
      end
    end
    return spec
  end
  return launch, out
end

local function has_note(pat)
  for _, n in ipairs(notes) do
    if n.msg:find(pat, 1, true) then
      return true
    end
  end
  return false
end

local function pid_alive(pid)
  local ok, ret = pcall(vim.uv.kill, pid, 0)
  return ok and ret == 0
end

-- Every job a test started (a stopped terminal is forgotten before its job has exited).
local pids = {}
vim.api.nvim_create_autocmd('User', {
  pattern = 'AgentTerminalOpen',
  callback = function(ev)
    pids[#pids + 1] = ev.data.pid
  end,
})

describe('terminal', function()
  before_each(function()
    tmp = util.realpath(vim.fn.tempname())
    util.mkdir_p(tmp, tonumber('700', 8))
    tmp = util.realpath(tmp)
    notes = {}
    vim.notify = function(msg, level)
      notes[#notes + 1] = { msg = msg, level = level }
    end
    -- A right split: the specs below check its width and edge (the default, below, is checked in
    -- init_spec.lua).
    config.setup({ terminal = { layout = 'split', split_side = 'right', auto_close = true, start_insert = false } })
    terminal.setup({})
  end)

  after_each(function()
    terminal.stop()
    wait_for(function()
      return not vim.iter(pids):any(pid_alive)
    end, 5000, 'all jobs exited')
    pids = {}
    vim.wait(50)
    vim.notify = orig_notify
    util.remove_dir(tmp)
  end)

  it('starts the agent in a right split with NVIM = v:servername, its env, args and cwd', function()
    local launch, out = fake({ env = { AGENT_TEST_VAR = 'hello' } })
    local prev = vim.api.nvim_get_current_win()
    local buf, err = terminal.open('fake', { launch = launch })
    assert.eq(nil, err)
    assert.truthy(buf)
    wait_ready(out)
    local env = read_env(out)
    assert.eq(vim.v.servername, env.NVIM)
    assert.eq('hello', env.AGENT_TEST_VAR)
    assert.eq('xterm-256color', env.TERM)
    assert.same({ 'arg one', 'two' }, read_args(out))
    assert.eq(tmp, vim.trim(read(out .. '.cwd')))
    assert.eq('terminal', vim.bo[buf].buftype)
    assert.eq('fake', vim.b[buf].agent_nvim_agent)
    assert.truthy(terminal.is_running())
    assert.truthy(terminal.is_visible())
    assert.eq('fake', terminal.name())
    assert.eq(buf, terminal.bufnr())
    -- focus=true by default: the terminal window is current, and it is a right split of 40% width.
    local win = vim.api.nvim_get_current_win()
    assert.truthy(win ~= prev)
    assert.eq(buf, vim.api.nvim_win_get_buf(win))
    assert.eq('', vim.api.nvim_win_get_config(win).relative)
    assert.eq(math.floor(vim.o.columns * 0.4), vim.api.nvim_win_get_width(win))
    assert.eq(vim.o.columns, vim.api.nvim_win_get_position(win)[2] + vim.api.nvim_win_get_width(win))
    local info = terminal.info()
    assert.eq('fake', info.name)
    assert.eq('session-1', info.session_id)
    assert.truthy(info.pid and info.pid > 0)
    assert.truthy(info.running)
  end)

  it('split_side = below: a full-width split at the bottom; hidden from there, back to the previous window', function()
    config.setup({ terminal = { layout = 'split', split_side = 'below', auto_close = true, start_insert = false } })
    local api = vim.api
    vim.cmd('silent! only!')
    local left = api.nvim_get_current_win()
    vim.cmd('rightbelow vsplit')
    local right = api.nvim_get_current_win()
    local launch, out = fake()
    local buf = terminal.open('fake', { launch = launch })
    wait_ready(out)
    local win = api.nvim_get_current_win()
    assert.eq(buf, api.nvim_win_get_buf(win))
    assert.same({ 'col', { { 'row', { { 'leaf', left }, { 'leaf', right } } }, { 'leaf', win } } }, vim.fn.winlayout())
    assert.eq(math.floor(vim.o.lines * 0.4), api.nvim_win_get_height(win))
    assert.truthy(vim.wo[win].winfixheight)
    -- Hidden from its window (toggle, close or stop): the cursor goes back to the right window,
    -- where it came from, not to the one Neovim picks for the space (the left one).
    for _, hide in ipairs({ 'toggle', 'close', 'stop' }) do
      if hide == 'toggle' then
        assert.eq(buf, terminal.toggle('fake'))
      elseif hide == 'close' then
        assert.truthy(terminal.close())
      else
        terminal.stop()
      end
      assert.falsy(api.nvim_win_is_valid(win), hide)
      assert.eq(right, api.nvim_get_current_win(), hide)
      if hide ~= 'stop' then
        assert.eq(buf, terminal.open('fake'))
        win = api.nvim_get_current_win()
        assert.eq(buf, api.nvim_win_get_buf(win))
      end
    end
    -- From another window, the cursor stays there.
    buf = terminal.open('fake', { launch = fake(), focus = false })
    api.nvim_set_current_win(left)
    assert.eq(buf, terminal.toggle('fake'))
    assert.eq(left, api.nvim_get_current_win())
    vim.cmd('silent! only!')
  end)

  it('opening a running agent reuses its terminal', function()
    local launch = fake()
    local buf = terminal.open('fake', { launch = launch })
    local job = terminal.info().job
    local buf2 = terminal.open('fake', { launch = function() error('must not relaunch') end })
    assert.eq(buf, buf2)
    assert.eq(job, terminal.info().job)
  end)

  it('opening another agent stops the running one: there is one terminal', function()
    local dir = tmp .. '/a-session'
    util.mkdir_p(dir, tonumber('700', 8))
    local la, outa = fake({ cleanup = { dir } })
    local lb, outb = fake()
    local exits = {}
    local au = vim.api.nvim_create_autocmd('User', {
      pattern = 'AgentTerminalExit',
      callback = function(ev)
        exits[#exits + 1] = ev.data.name
      end,
    })
    local bufa = terminal.open('a', { launch = la })
    wait_ready(outa)
    local pida = terminal.info().pid
    local bufb = terminal.open('b', { launch = lb })
    -- a is forgotten at once: its window is closed and its temp files are removed.
    assert.eq('b', terminal.name())
    assert.eq(bufb, terminal.bufnr())
    assert.eq(-1, vim.fn.bufwinid(bufa))
    assert.eq(0, vim.fn.isdirectory(dir))
    wait_ready(outb)
    wait_for(function()
      return not pid_alive(pida) and not vim.api.nvim_buf_is_valid(bufa)
    end, 5000, 'a exited and its buffer is wiped')
    vim.api.nvim_del_autocmd(au)
    assert.same({ 'a' }, exits)
    assert.truthy(terminal.is_running())
    assert.eq('b', terminal.info().name)
    -- One terminal window: b's.
    local terms = vim.tbl_filter(function(w)
      return vim.bo[vim.api.nvim_win_get_buf(w)].buftype == 'terminal'
    end, vim.api.nvim_list_wins())
    assert.eq(1, #terms)
    assert.eq(bufb, vim.api.nvim_win_get_buf(terms[1]))
  end)

  it('never lets an inherited NVIM reach the job (nested Neovim, clear_env)', function()
    config.setup({
      terminal = { layout = 'split', auto_close = true, start_insert = false },
      agents = { claude = { cmd = { FIX } } },
    })
    local out = tmp .. '/nested'
    vim.env.NVIM = '/fake/outer/nvim.sock'
    vim.env.AGENT_DROP_ME = 'inherited'
    local spec
    local ok, err = pcall(function()
      spec = assert(agents.build_launch('claude', {
        cwd = tmp,
        user_args = { '--resume' },
        env = { FAKE_AGENT_OUT = out, AGENT_DROP_ME = false },
        ide = { port = 45678 },
        sessions_dir = tmp .. '/sessions',
        claude_managed_dirs = { tmp .. '/managed' },
      }))
    end)
    vim.env.NVIM = nil
    vim.env.AGENT_DROP_ME = nil
    assert.truthy(ok, err)
    assert.eq(true, spec.clear_env)
    assert.eq(nil, spec.env.NVIM)
    local buf = terminal.open('claude', { launch = function() return spec end })
    assert.truthy(buf)
    wait_ready(out)
    local env = read_env(out)
    assert.eq(vim.v.servername, env.NVIM)
    assert.eq(nil, env.AGENT_DROP_ME)
    assert.eq('45678', env.CLAUDE_CODE_SSE_PORT)
    assert.eq('true', env.CLAUDE_CODE_IDE_SKIP_AUTO_INSTALL)
    assert.eq(spec.session_id, env.AGENT_NVIM_SESSION)
    local args = read_args(out)
    assert.eq('--resume', args[1])
    local mcp_file = args[2]:match('^%-%-mcp%-config=(.*)$')
    assert.truthy(mcp_file, 'mcp-config arg')
    assert.eq(1, vim.fn.filereadable(mcp_file))
    local cfg = vim.json.decode(read(mcp_file))
    assert.eq(vim.v.servername, cfg.mcpServers.nvim.env.NVIM)
    -- Stopping removes the per-session temp dir.
    terminal.stop()
    assert.falsy(terminal.is_running())
    assert.eq(0, vim.fn.isdirectory(spec.cleanup[1]))
    assert.eq(0, vim.fn.filereadable(mcp_file))
    wait_for(function()
      return not vim.api.nvim_buf_is_valid(buf)
    end, 5000, 'buffer wiped')
  end)

  it('does not inject NVIM itself when clear_env is off', function()
    local launch, out = fake({ env = { NVIM = '/some/inherited.sock' } })
    terminal.open('fake', { launch = launch })
    wait_ready(out)
    assert.eq(vim.v.servername, read_env(out).NVIM)
  end)

  it('starts a server when v:servername is empty', function()
    vim.fn.serverstop(vim.v.servername)
    assert.eq('', vim.v.servername)
    local launch, out = fake()
    assert.truthy(terminal.open('fake', { launch = launch }))
    assert.truthy(vim.v.servername ~= '')
    wait_ready(out)
    assert.eq(vim.v.servername, read_env(out).NVIM)
  end)

  it('toggle hides and shows the same terminal; close hides; the job keeps running', function()
    local launch = fake()
    local buf = terminal.open('fake', { launch = launch })
    local job = terminal.info().job
    assert.truthy(terminal.is_visible())
    terminal.toggle('fake')
    assert.falsy(terminal.is_visible())
    assert.truthy(terminal.is_running())
    assert.truthy(vim.api.nvim_buf_is_valid(buf))
    assert.eq(buf, terminal.toggle('fake'))
    assert.truthy(terminal.is_visible())
    assert.eq(job, terminal.info().job)
    assert.eq(buf, vim.api.nvim_get_current_buf())
    assert.truthy(terminal.close())
    assert.falsy(terminal.is_visible())
    assert.falsy(terminal.close())
    assert.truthy(terminal.is_running())
    assert.eq(job, terminal.info().job)
  end)

  it('stop ends the job, wipes the buffer and removes the cleanup paths', function()
    local dir = tmp .. '/session-dir'
    util.mkdir_p(dir, tonumber('700', 8))
    local exits = {}
    local launch = fake({
      cleanup = { dir },
      on_exit = function(code, info)
        exits[#exits + 1] = { code = code, name = info.name }
      end,
    })
    local events = {}
    local au = vim.api.nvim_create_autocmd('User', {
      pattern = { 'AgentTerminalOpen', 'AgentTerminalExit' },
      callback = function(ev)
        events[#events + 1] = ev.match .. ':' .. ev.data.name
      end,
    })
    local buf = terminal.open('fake', { launch = launch })
    assert.truthy(terminal.stop())
    assert.falsy(terminal.is_running())
    assert.eq(nil, terminal.name())
    assert.eq(nil, terminal.info())
    assert.eq(-1, vim.fn.bufwinid(buf), 'the window closes at once')
    wait_for(function()
      return not vim.api.nvim_buf_is_valid(buf)
    end, 5000, 'stopped')
    vim.api.nvim_del_autocmd(au)
    assert.eq(0, vim.fn.isdirectory(dir))
    assert.eq(1, #exits)
    assert.eq('fake', exits[1].name)
    assert.same({ 'AgentTerminalOpen:fake', 'AgentTerminalExit:fake' }, events)
    assert.falsy(terminal.stop())
  end)

  it('stop sends SIGTERM to the agent and every process it started, which a hangup does not end', function()
    if util.is_windows then
      return
    end
    -- hup_agent.sh and its child ignore SIGHUP (jobstop() hangs up the terminal), and the child
    -- runs in a process group of its own: Neovim's own SIGTERM, to the job's process group 2 s
    -- later, would miss it.
    local launch, out = fake({ argv = { TEST_ROOT .. '/tests/fixtures/hup_agent.sh' } })
    terminal.open('fake', { launch = launch })
    wait_for(function()
      return vim.fn.filereadable(out .. '.pids') == 1
    end, 5000, 'the fake agent and its child run')
    local agent_pid, child = (read(out .. '.pids') or ''):match('^(%d+) (%d+)')
    agent_pid, child = tonumber(agent_pid), tonumber(child)
    assert.eq(terminal.info().pid, agent_pid)
    assert.truthy(pid_alive(child))
    local ok = pcall(function()
      assert.truthy(terminal.stop())
      wait_for(function()
        return not pid_alive(agent_pid) and not pid_alive(child)
      end, 1500, 'the agent and its child ended')
    end)
    -- Never leave them behind, even when the test fails.
    for _, p in ipairs({ child, agent_pid }) do
      if pid_alive(p) then
        vim.uv.kill(p, 'sigkill')
      end
    end
    assert.truthy(ok, 'the agent and its child ended within 1.5 s of stop()')
  end)

  it('stop signals nothing when the job has already ended', function()
    -- A finished terminal left open: its pid may belong to another process by now.
    local launch = fake({ env = { FAKE_AGENT_EXIT = '3' } })
    terminal.open('fake', { launch = launch })
    wait_for(function()
      return terminal.info() and not terminal.info().running
    end, 5000, 'the job exited')
    local killed = {}
    local orig_kill = vim.uv.kill
    vim.uv.kill = function(pid, sig)
      killed[#killed + 1] = pid
      return orig_kill(pid, sig)
    end
    local ok, err = pcall(terminal.stop)
    vim.uv.kill = orig_kill
    assert.truthy(ok, err)
    assert.same({}, killed)
  end)

  it('process_tree lists a process and its descendants, only under the given parent', function()
    if util.is_windows then
      return
    end
    local launch, out = fake({ argv = { TEST_ROOT .. '/tests/fixtures/hup_agent.sh' } })
    terminal.open('fake', { launch = launch })
    wait_for(function()
      return vim.fn.filereadable(out .. '.pids') == 1
    end, 5000, 'the fake agent and its child run')
    local agent_pid, child = (read(out .. '.pids') or ''):match('^(%d+) (%d+)')
    agent_pid, child = tonumber(agent_pid), tonumber(child)
    local ok, err = pcall(function()
      assert.same({ agent_pid, child }, util.process_tree(agent_pid, { parent = vim.fn.getpid() }))
      assert.same({ child }, util.process_tree(child))
      -- Not a child of that parent (a pid reused since, say): nothing.
      assert.same({}, util.process_tree(child, { parent = vim.fn.getpid() }))
      -- Never this Neovim, nor pid 1.
      assert.same({}, util.process_tree(vim.fn.getpid()))
      assert.same({}, util.process_tree(1))
      -- Without ps: the same, through nvim_get_proc_children().
      local orig_system = vim.system
      vim.system = function()
        error('no ps')
      end
      local tok, tree = pcall(util.process_tree, agent_pid, { parent = vim.fn.getpid() })
      vim.system = orig_system
      assert.truthy(tok, tree)
      assert.same({ agent_pid, child }, tree)
    end)
    terminal.stop()
    for _, p in ipairs({ child, agent_pid }) do
      if pid_alive(p) then
        vim.uv.kill(p, 'sigkill')
      end
    end
    assert.truthy(ok, err)
  end)

  it('send types a bracketed paste, optionally followed by Enter', function()
    local launch, out = fake()
    terminal.open('fake', { launch = launch })
    wait_ready(out)
    assert.truthy(terminal.send('hello\nworld'))
    wait_for(function()
      return (read(out .. '.stdin') or '') == '\27[200~hello\nworld\27[201~'
    end, 3000, 'paste')
    assert.truthy(terminal.send('go', { submit = true }))
    local expected = '\27[200~hello\nworld\27[201~\27[200~go\27[201~\r'
    wait_for(function()
      return read(out .. '.stdin') == expected
    end, 3000, 'submit')
    -- Paste delimiters inside the text are stripped; bracketed = false sends raw text.
    assert.truthy(terminal.send('a\27[201~b'))
    assert.truthy(terminal.send('raw', { bracketed = false }))
    expected = expected .. '\27[200~ab\27[201~raw'
    wait_for(function()
      return read(out .. '.stdin') == expected
    end, 3000, 'raw')
  end)

  it('send fails when no agent runs', function()
    local ok, err = terminal.send('x')
    assert.falsy(ok)
    assert.eq('no agent is running', err)
    local launch, out = fake()
    terminal.open('fake', { launch = launch })
    wait_ready(out)
    assert.truthy(terminal.send('y'))
    wait_for(function()
      return read(out .. '.stdin') == '\27[200~y\27[201~'
    end, 3000, 'sent')
    terminal.stop()
    assert.falsy((terminal.send('z')))
  end)

  it('auto_close closes the terminal when the agent exits normally', function()
    local dir = tmp .. '/cleanup-me'
    util.mkdir_p(dir, tonumber('700', 8))
    local launch, out = fake({ env = { FAKE_AGENT_EXIT = '0' }, cleanup = { dir } })
    local buf = terminal.open('fake', { launch = launch })
    wait_for(function()
      return not vim.api.nvim_buf_is_valid(buf)
    end, 5000, 'auto close')
    assert.eq(1, vim.fn.filereadable(out .. '.env'))
    assert.falsy(terminal.is_running())
    assert.eq(0, vim.fn.isdirectory(dir))
    assert.eq(nil, terminal.info())
  end)

  it('keeps a terminal that failed at startup open, and relaunches on the next open', function()
    local launch = fake({ env = { FAKE_AGENT_EXIT = '3' } })
    local buf = terminal.open('fake', { launch = launch })
    wait_for(function()
      return not terminal.is_running()
    end, 5000, 'exit')
    assert.truthy(vim.api.nvim_buf_is_valid(buf))
    assert.eq('fake', terminal.name())
    assert.eq(3, terminal.info().exit_code)
    assert.truthy(has_note('fake exited with code 3'))
    local launch2, out2 = fake()
    local buf2 = terminal.open('fake', { launch = launch2 })
    assert.truthy(buf2 ~= buf)
    assert.falsy(vim.api.nvim_buf_is_valid(buf))
    wait_ready(out2)
    assert.truthy(terminal.is_running())
  end)

  it('opening another agent wipes a finished terminal left open', function()
    local launch = fake({ env = { FAKE_AGENT_EXIT = '3' } })
    local buf = terminal.open('a', { launch = launch })
    wait_for(function()
      return not terminal.is_running()
    end, 5000, 'exit')
    assert.truthy(vim.api.nvim_buf_is_valid(buf))
    local launch2, out2 = fake()
    terminal.open('b', { launch = launch2 })
    assert.falsy(vim.api.nvim_buf_is_valid(buf))
    wait_ready(out2)
    assert.eq('b', terminal.name())
  end)

  it('forgets a terminal wiped by hand right after start, without a "left open" warning', function()
    for _, auto_close in ipairs({ true, false }) do
      notes = {}
      config.setup({ terminal = { layout = 'split', auto_close = auto_close, start_insert = false } })
      local launch, out = fake()
      local buf = terminal.open('fake', { launch = launch })
      wait_ready(out)
      vim.cmd('bwipeout! ' .. buf)
      wait_for(function()
        return not terminal.is_running()
      end, 5000, 'exit')
      vim.wait(50)
      assert.falsy(has_note('left open'), vim.inspect(notes))
      assert.eq(nil, terminal.info())
    end
  end)

  it('with auto_close = false the finished terminal stays', function()
    config.setup({ terminal = { layout = 'split', auto_close = false, start_insert = false } })
    local launch = fake({ env = { FAKE_AGENT_EXIT = '0' } })
    local buf = terminal.open('fake', { launch = launch })
    wait_for(function()
      return not terminal.is_running()
    end, 5000, 'exit')
    vim.wait(50)
    assert.truthy(vim.api.nvim_buf_is_valid(buf))
    assert.eq(0, terminal.info().exit_code)
  end)

  it('shows an exit hint when the output matches soon after start', function()
    local launch = fake({
      env = { FAKE_AGENT_EXIT = '1', FAKE_AGENT_PRINT = 'Error: enterprise MCP config is present' },
      exit_hints = { { within_ms = 5000, patterns = { 'enterprise MCP config' }, message = 'HINT: set mcp = false' } },
    })
    terminal.open('fake', { launch = launch })
    wait_for(function()
      return has_note('HINT: set mcp = false')
    end, 5000, 'hint')
  end)

  it('refuses a missing executable with a clear error and cleans up', function()
    local dir = tmp .. '/unused'
    util.mkdir_p(dir, tonumber('700', 8))
    local wins = #vim.api.nvim_list_wins()
    local buf, err = terminal.open('fake', {
      launch = function()
        return { argv = { '/nonexistent/agent-bin' }, env = {}, cwd = tmp, cleanup = { dir } }
      end,
    })
    assert.eq(nil, buf)
    assert.eq("fake: executable '/nonexistent/agent-bin' not found", err)
    assert.truthy(has_note("executable '/nonexistent/agent-bin' not found"))
    assert.eq(0, vim.fn.isdirectory(dir))
    assert.eq(wins, #vim.api.nvim_list_wins())
    assert.eq(nil, terminal.info())
  end)

  it('reports launcher errors', function()
    local buf, err = terminal.open('fake', { silent = true, launch = function() return nil, 'no provider' end })
    assert.eq(nil, buf)
    assert.eq('no provider', err)
    buf, err = terminal.open('fake', { silent = true, launch = function() error('boom') end })
    assert.eq(nil, buf)
    assert.matches('launch failed: .*boom', err)
  end)

  it('supports float, tab and focus = false', function()
    local prev = vim.api.nvim_get_current_win()
    local launch = fake()
    local buf = terminal.open('f', { launch = launch, layout = 'float' })
    local win = vim.fn.bufwinid(buf)
    assert.eq('editor', vim.api.nvim_win_get_config(win).relative)
    assert.eq(win, vim.api.nvim_get_current_win())
    terminal.close()
    assert.falsy(terminal.is_visible())
    vim.api.nvim_set_current_win(prev)

    local tabs = #vim.api.nvim_list_tabpages()
    local launch2 = fake()
    local buf2 = terminal.open('t', { launch = launch2, layout = 'tab' })
    assert.eq(tabs + 1, #vim.api.nvim_list_tabpages())
    assert.eq(buf2, vim.api.nvim_get_current_buf())
    terminal.toggle('t')
    assert.eq(tabs, #vim.api.nvim_list_tabpages())
    vim.api.nvim_set_current_win(prev)

    local launch3 = fake()
    local buf3 = terminal.open('s', { launch = launch3, focus = false })
    assert.eq(prev, vim.api.nvim_get_current_win())
    assert.truthy(vim.fn.bufwinid(buf3) > 0)
  end)

  it('layout none does not start anything', function()
    local called = false
    local buf, err = terminal.open('fake', {
      silent = true,
      layout = 'none',
      launch = function()
        called = true
      end,
    })
    assert.eq(nil, buf)
    assert.matches('layout is "none"', err)
    assert.falsy(called)
  end)

  it('shows each launch warning once and runs before_spawn', function()
    local spawned = 0
    local launch = fake({
      warnings = { { id = 'w-once', msg = 'WARN-ONCE', level = vim.log.levels.WARN } },
      before_spawn = function()
        spawned = spawned + 1
      end,
    })
    terminal.open('fake', { launch = launch })
    terminal.stop()
    terminal.open('fake', { launch = launch })
    local count = 0
    for _, n in ipairs(notes) do
      if n.msg:find('WARN-ONCE', 1, true) then
        count = count + 1
      end
    end
    assert.eq(1, count)
    assert.eq(2, spawned)
  end)

  describe('with a second window (split_here)', function()
    local api = vim.api
    local function wins_in(buf, tab)
      return vim.tbl_filter(function(w)
        return api.nvim_win_get_buf(w) == buf
      end, api.nvim_tabpage_list_wins(tab or 0))
    end
    local function job_running()
      local info = terminal.info()
      return info ~= nil and vim.fn.jobwait({ info.job }, 0)[1] == -1
    end

    after_each(function()
      pcall(vim.cmd, 'silent! tabonly!')
      pcall(vim.cmd, 'silent! only!')
    end)

    it('opens one more split in this tab page, unfocused and as large as the terminal split', function()
      local launch, out = fake()
      local buf = terminal.open('fake', { launch = launch, focus = false })
      wait_ready(out)
      local main_win = vim.fn.bufwinid(buf)
      local job = terminal.info().job
      local tab1 = api.nvim_get_current_tabpage()
      vim.cmd('tabnew')
      local tab2 = api.nvim_get_current_tabpage()
      local cur = api.nvim_get_current_win()
      assert.falsy(terminal.is_visible())
      local win, why = terminal.split_here()
      assert.truthy(win, why)
      assert.eq(cur, api.nvim_get_current_win(), 'not entered')
      assert.eq(tab2, api.nvim_win_get_tabpage(win))
      assert.eq(buf, api.nvim_win_get_buf(win))
      assert.eq(api.nvim_win_get_width(main_win), api.nvim_win_get_width(win))
      assert.eq(vim.o.columns, api.nvim_win_get_position(win)[2] + api.nvim_win_get_width(win), 'on the right edge')
      assert.truthy(vim.wo[win].winfixwidth)
      assert.falsy(vim.wo[win].number)
      assert.falsy(vim.wo[win].wrap)
      assert.truthy(terminal.is_visible())
      -- Once per tab page.
      local again, why2 = terminal.split_here()
      assert.eq(nil, again)
      assert.matches('already shown', why2)
      -- The job is the same, and both windows show it.
      assert.eq(job, terminal.info().job)
      assert.same({ main_win, win }, vim.fn.win_findbuf(buf))
      -- Closing the extra window (or its tab page) hides nothing else and stops nothing.
      vim.cmd('tabclose')
      assert.eq(tab1, api.nvim_get_current_tabpage())
      assert.same({ main_win }, vim.fn.win_findbuf(buf))
      vim.wait(100)
      assert.truthy(job_running())
      assert.truthy(terminal.is_running())
      assert.truthy(terminal.is_visible())
    end)

    it('every window it opens follows the output (the cursor on the last line)', function()
      -- 60 lines, more than a window shows, then more output for each line sent (the tty echoes
      -- it and cat prints it).
      local launch = fake({ argv = { 'sh', '-c', 'i=1; while [ $i -le 60 ]; do echo "line $i"; i=$((i+1)); done; exec cat' } })
      local buf = terminal.open('fake', { launch = launch, focus = false })
      local function has_line(text)
        return vim.tbl_contains(api.nvim_buf_get_lines(buf, 0, -1, false), text)
      end
      wait_for(function()
        return has_line('line 60')
      end, 5000, 'the first output')
      local main_win = vim.fn.bufwinid(buf)
      local tab1 = api.nvim_get_current_tabpage()
      assert.truthy(api.nvim_buf_line_count(buf) > api.nvim_win_get_height(main_win), 'more lines than the window shows')
      ---"<first>-<last visible line>/<lines> cursor <line>": at the bottom, the last two are the line count.
      local function view(win)
        return api.nvim_win_call(win, function()
          return ('%d-%d/%d cursor %d'):format(vim.fn.line('w0'), vim.fn.line('w$'), api.nvim_buf_line_count(buf),
            api.nvim_win_get_cursor(win)[1])
        end)
      end
      local function at_bottom(win, what)
        local n = api.nvim_buf_line_count(buf)
        local v = view(win)
        assert.truthy(v:match('^%d+%-(%d+)/') == tostring(n) and v:match('cursor (%d+)$') == tostring(n),
          what .. ' shows the last line, with the cursor there: ' .. v)
      end
      local n = 0
      ---More output, while `wins` are shown: each of them keeps showing the last line.
      local function more(wins, what)
        n = n + 1
        local lines = api.nvim_buf_line_count(buf)
        assert.truthy(terminal.send('more ' .. n .. '\r', { bracketed = false }))
        wait_for(function()
          return has_line('more ' .. n) and api.nvim_buf_line_count(buf) > lines
        end, 5000, 'more output')
        vim.wait(50)
        for _, w in ipairs(wins) do
          at_bottom(w, what .. ' after more output')
        end
      end

      -- split_here() in another tab page (a diff's view of the agent).
      vim.cmd('tabnew')
      local tab2 = api.nvim_get_current_tabpage()
      local extra = assert(terminal.split_here())
      at_bottom(extra, 'split_here()')
      -- The terminal's own window, started without focus.
      at_bottom(main_win, 'the window of an unfocused start')
      more({ extra, main_win }, 'split_here() and the main window')
      -- Hidden here, shown again here (:AgentOpen) while it is shown in the first tab page; the user
      -- had scrolled both views back to the top.
      api.nvim_win_set_cursor(extra, { 1, 0 })
      api.nvim_win_set_cursor(main_win, { 1, 0 })
      assert.truthy(terminal.close())
      assert.eq(buf, terminal.open('fake', { focus = false }))
      local shown = wins_in(buf, tab2)[1]
      at_bottom(shown, 'open() in another tab page')
      more({ shown }, 'open() in another tab page')
      -- Hidden everywhere (last seen scrolled back to the top), more output, then shown again
      -- (:AgentToggle), in Normal mode (no start_insert).
      assert.truthy(terminal.close())
      api.nvim_set_current_tabpage(tab1)
      api.nvim_win_set_cursor(main_win, { 1, 0 })
      assert.truthy(terminal.close())
      assert.same({}, vim.fn.win_findbuf(buf))
      more({}, 'hidden')
      assert.eq(buf, terminal.toggle('fake'))
      assert.eq('nt', api.nvim_get_mode().mode, 'Normal mode in the terminal window')
      at_bottom(api.nvim_get_current_win(), 'toggle() of a hidden terminal')
      more({ api.nvim_get_current_win() }, 'toggle() of a hidden terminal')
      -- The other layouts.
      assert.truthy(terminal.close())
      assert.eq(buf, terminal.open('fake', { focus = false, layout = 'float' }))
      at_bottom(vim.fn.bufwinid(buf), 'a float')
      assert.truthy(terminal.close())
      assert.eq(buf, terminal.open('fake', { focus = false, layout = 'tab' }))
      local tab_win = vim.fn.win_findbuf(buf)[1]
      assert.truthy(api.nvim_win_get_tabpage(tab_win) ~= tab1, 'in a tab page of its own')
      at_bottom(tab_win, 'a tab page')
    end)

    it('declines without an agent terminal and for the float layout', function()
      local win, why = terminal.split_here()
      assert.eq(nil, win)
      assert.eq('no agent terminal', why)
      local launch = fake()
      terminal.open('fake', { launch = launch, layout = 'float', focus = false })
      vim.cmd('tabnew')
      win, why = terminal.split_here()
      assert.eq(nil, win)
      assert.matches('float', why)
    end)

    it('close() and toggle() act on the current tab page; close() elsewhere when not shown here', function()
      local launch, out = fake()
      local buf = terminal.open('fake', { launch = launch, focus = false })
      wait_ready(out)
      local main_win = vim.fn.bufwinid(buf)
      local job = terminal.info().job
      local tab1 = api.nvim_get_current_tabpage()
      vim.cmd('tabnew')
      local tab2 = api.nvim_get_current_tabpage()
      local extra = assert(terminal.split_here())

      -- close() in the second tab page closes its window only.
      assert.truthy(terminal.close())
      assert.falsy(api.nvim_win_is_valid(extra))
      assert.truthy(api.nvim_win_is_valid(main_win))
      assert.falsy(terminal.is_visible())
      assert.truthy(job_running())

      -- toggle() shows it here (a split, focused), and hides it here only.
      assert.eq(buf, terminal.toggle('fake'))
      local shown = wins_in(buf, tab2)[1]
      assert.truthy(shown)
      assert.eq(shown, api.nvim_get_current_win())
      assert.eq(api.nvim_win_get_width(main_win), api.nvim_win_get_width(shown))
      assert.eq(buf, terminal.toggle('fake'))
      assert.eq(0, #wins_in(buf, tab2))
      assert.truthy(api.nvim_win_is_valid(main_win))
      assert.eq(job, terminal.info().job)

      -- From the first tab page, where it is shown: only that window closes.
      extra = assert(terminal.split_here())
      api.nvim_set_current_tabpage(tab1)
      assert.truthy(terminal.close())
      assert.falsy(api.nvim_win_is_valid(main_win))
      assert.truthy(api.nvim_win_is_valid(extra))
      -- Not shown here any more: close() hides it everywhere else.
      assert.truthy(terminal.close())
      assert.falsy(api.nvim_win_is_valid(extra))
      assert.same({}, vim.fn.win_findbuf(buf))
      assert.falsy(terminal.close())
      assert.truthy(job_running())
      assert.truthy(api.nvim_buf_is_valid(buf))
    end)

    it('stop() and auto_close close every window, and only those', function()
      local launch = fake()
      local buf = terminal.open('fake', { launch = launch, focus = false })
      vim.cmd('tabnew')
      local other = api.nvim_get_current_win()
      vim.cmd('vsplit')
      local extra = assert(terminal.split_here())
      assert.eq(3, #api.nvim_tabpage_list_wins(0))
      assert.truthy(terminal.stop())
      assert.same({}, vim.fn.win_findbuf(buf))
      assert.falsy(api.nvim_win_is_valid(extra))
      assert.eq(2, #api.nvim_tabpage_list_wins(0))
      assert.truthy(api.nvim_win_is_valid(other))

      local launch2 = fake({ env = { FAKE_AGENT_EXIT = '0', FAKE_AGENT_SLEEP = '1' } })
      vim.cmd('tabprevious')
      buf = terminal.open('fake', { launch = launch2, focus = false })
      vim.cmd('tabnext')
      local extra2 = assert(terminal.split_here())
      assert.eq(2, #vim.fn.win_findbuf(buf))
      wait_for(function()
        return not vim.api.nvim_buf_is_valid(buf)
      end, 5000, 'auto close')
      assert.falsy(api.nvim_win_is_valid(extra2))
      assert.eq(2, #api.nvim_tabpage_list_wins(0), 'the other windows stay')
      assert.eq(nil, terminal.info())
      assert.falsy(has_note('left open'))
    end)

    it("with the 'tab' layout it matches no split, and show() goes to the terminal's own tab page", function()
      config.setup({
        terminal = { layout = 'tab', split_side = 'right', auto_close = true, start_insert = false, split_size = 0.3 },
      })
      local tab0 = api.nvim_get_current_tabpage()
      local launch = fake()
      local buf = terminal.open('fake', { launch = launch })
      local own_tab = api.nvim_get_current_tabpage()
      local own_win = api.nvim_get_current_win()
      assert.truthy(own_tab ~= tab0)
      -- A float in its tab page (a notification, say) does not make it a split.
      api.nvim_open_win(api.nvim_create_buf(false, true), false,
        { relative = 'editor', row = 1, col = 1, width = 10, height = 1 })
      -- A diff-like tab page next to it.
      vim.cmd('tabnew')
      local tab2 = api.nvim_get_current_tabpage()
      local extra = assert(terminal.split_here())
      assert.eq(math.floor(vim.o.columns * 0.3), api.nvim_win_get_width(extra))
      assert.eq(3, #api.nvim_list_tabpages())
      -- Hidden here, :AgentToggle goes to its own tab page instead of opening another one.
      assert.eq(buf, terminal.toggle('fake'))
      assert.falsy(api.nvim_win_is_valid(extra))
      assert.eq(tab2, api.nvim_get_current_tabpage())
      assert.eq(buf, terminal.toggle('fake'))
      assert.eq(own_win, api.nvim_get_current_win())
      assert.eq(own_tab, api.nvim_get_current_tabpage())
      assert.eq(3, #api.nvim_list_tabpages())
      -- From the editor's tab page too; focus = false leaves the cursor alone.
      api.nvim_set_current_tabpage(tab0)
      local cur = api.nvim_get_current_win()
      assert.eq(buf, terminal.open('fake', { focus = false }))
      assert.eq(cur, api.nvim_get_current_win())
      assert.eq(buf, terminal.open('fake'))
      assert.eq(own_win, api.nvim_get_current_win())
      assert.eq(3, #api.nvim_list_tabpages())
    end)
  end)

  describe("with the 'current' layout", function()
    local api = vim.api

    local function job_running()
      local info = terminal.info()
      return info ~= nil and info.running and vim.fn.jobwait({ info.job }, 0)[1] == -1
    end

    ---Edit `name` (a file of `n` lines "line <i>" in tmp) in the current window.
    ---@return integer bufnr
    local function edit(name, n)
      local lines = {}
      for i = 1, n or 3 do
        lines[i] = 'line ' .. i
      end
      vim.fn.writefile(lines, tmp .. '/' .. name)
      vim.cmd.edit(vim.fn.fnameescape(tmp .. '/' .. name))
      return api.nvim_get_current_buf()
    end

    local function buf_of(win)
      return api.nvim_win_get_buf(win)
    end

    before_each(function()
      -- split_side: the split it falls back to, and the view in a diff tab page, are on the right.
      config.setup({ terminal = { layout = 'current', split_side = 'right', auto_close = true, start_insert = false } })
      vim.cmd('silent! tabonly!')
      vim.cmd('silent! only!')
      vim.cmd('enew!')
      vim.cmd('silent! %bwipeout!')
    end)

    after_each(function()
      terminal.stop()
      for _, w in ipairs(api.nvim_list_wins()) do
        vim.wo[w].winfixbuf = false
        vim.wo[w].diff = false
      end
      vim.cmd('silent! tabonly!')
      vim.cmd('silent! only!')
    end)

    it('is a valid terminal.layout', function()
      assert.eq('current', config.get().terminal.layout)
      assert.error(function()
        config.setup({ terminal = { layout = 'window' } })
      end, "one of 'split','float','tab','current','none'")
    end)

    it('shows the agent in the current window in place of its buffer; toggle() and close() give it back', function()
      local file = edit('a.txt', 60)
      local win = api.nvim_get_current_win()
      vim.wo[win].number = true
      api.nvim_win_set_cursor(win, { 40, 2 })
      vim.cmd('normal! zt')
      assert.eq(40, vim.fn.line('w0'))
      local nwins = #api.nvim_list_wins()
      local launch, out = fake()
      local buf = terminal.open('fake', { launch = launch })
      wait_ready(out)
      assert.eq(win, api.nvim_get_current_win(), 'the same window, focused')
      assert.eq(buf, buf_of(win))
      assert.eq(nwins, #api.nvim_list_wins(), 'no new window')
      assert.eq('current', terminal.info().layout)
      assert.truthy(terminal.is_visible())
      local prev = vim.w[win].agent_nvim_prev
      assert.eq(file, prev.buf)
      assert.eq(buf, prev.term)
      assert.eq(40, prev.view.lnum)
      assert.eq(40, prev.view.topline)
      -- The terminal's window options are set for the terminal buffer only: the window keeps its own.
      assert.falsy(vim.wo[win].number)
      assert.falsy(vim.wo[win].wrap)
      assert.falsy(vim.wo[win].winfixwidth)
      assert.truthy(api.nvim_get_option_value('number', { scope = 'global', win = win }))
      local job = terminal.info().job

      -- toggle(): the file comes back, where it was; the job runs on in the hidden buffer.
      assert.eq(buf, terminal.toggle('fake'))
      assert.truthy(api.nvim_win_is_valid(win))
      assert.eq(file, buf_of(win))
      assert.eq(win, api.nvim_get_current_win())
      assert.eq(nwins, #api.nvim_list_wins())
      local view = vim.fn.winsaveview()
      assert.same({ 40, 2, 40 }, { view.lnum, view.col, view.topline }, 'cursor and scroll restored')
      assert.truthy(vim.wo[win].number)
      assert.eq(nil, vim.w[win].agent_nvim_prev)
      assert.falsy(terminal.is_visible())
      assert.truthy(api.nvim_buf_is_valid(buf))
      assert.eq('hide', vim.bo[buf].bufhidden)
      assert.truthy(job_running())
      assert.eq(job, terminal.info().job)

      -- toggle() again: in the current window again; close() gives the file back the same way.
      assert.eq(buf, terminal.toggle('fake'))
      assert.eq(buf, buf_of(win))
      assert.eq(win, api.nvim_get_current_win())
      assert.eq(nwins, #api.nvim_list_wins())
      assert.truthy(terminal.close())
      assert.eq(file, buf_of(win))
      assert.eq(40, vim.fn.line('w0'))
      assert.falsy(terminal.close())
      assert.eq(nwins, #api.nvim_list_wins())
      assert.truthy(job_running())
      assert.eq(job, terminal.info().job)
    end)

    it('the last window: stop() and auto_close keep it, with its previous buffer', function()
      local file = edit('a.txt', 60)
      local win = api.nvim_get_current_win()
      api.nvim_win_set_cursor(win, { 40, 0 })
      vim.cmd('normal! zt')
      assert.eq(1, #api.nvim_list_wins())
      local buf = terminal.open('fake', { launch = fake() })
      assert.eq(buf, buf_of(win))
      assert.truthy(terminal.stop())
      assert.same({ win }, api.nvim_list_wins())
      assert.eq(file, buf_of(win))
      assert.eq(40, vim.fn.line('w0'), 'its view too')
      assert.eq(nil, vim.w[win].agent_nvim_prev)
      wait_for(function()
        return not api.nvim_buf_is_valid(buf)
      end, 5000, 'the stopped terminal is wiped')
      assert.same({ win }, api.nvim_list_wins())
      assert.eq(file, buf_of(win))

      -- The agent exits: auto_close.
      local buf2 = terminal.open('fake', { launch = fake({ env = { FAKE_AGENT_EXIT = '0' } }) })
      assert.eq(buf2, buf_of(win))
      wait_for(function()
        return not api.nvim_buf_is_valid(buf2)
      end, 5000, 'auto close')
      assert.same({ win }, api.nvim_list_wins())
      assert.eq(file, buf_of(win))
      assert.eq(40, vim.fn.line('w0'), 'its view too')
      assert.eq(nil, vim.w[win].agent_nvim_prev)
      assert.eq(nil, terminal.info())
      assert.falsy(has_note('left open'))
    end)

    it('without auto_close the finished terminal stays shown; opening again restarts it in that window', function()
      config.setup({ terminal = { layout = 'current', auto_close = false, start_insert = false } })
      local file = edit('a.txt')
      local win = api.nvim_get_current_win()
      local buf = terminal.open('fake', { launch = fake({ env = { FAKE_AGENT_EXIT = '0' } }) })
      wait_for(function()
        return not terminal.is_running()
      end, 5000, 'exit')
      vim.wait(50)
      assert.eq(buf, buf_of(win))
      assert.eq(0, terminal.info().exit_code)
      local launch2, out2 = fake()
      local buf2 = terminal.open('fake', { launch = launch2 })
      wait_ready(out2)
      assert.falsy(api.nvim_buf_is_valid(buf))
      assert.same({ win }, api.nvim_list_wins())
      assert.eq(buf2, buf_of(win))
      assert.eq(file, vim.w[win].agent_nvim_prev.buf, 'the file is still the buffer to give back')
      assert.truthy(terminal.stop())
      assert.eq(file, buf_of(win))
    end)

    it('when its previous buffer was deleted meanwhile: the alternate buffer, else a new empty one', function()
      local a = edit('a.txt')
      local b = edit('b.txt') -- the window's alternate buffer is a.txt
      local win = api.nvim_get_current_win()
      local buf = terminal.open('fake', { launch = fake() })
      vim.cmd('bwipeout! ' .. b)
      assert.eq(buf, terminal.toggle('fake'))
      assert.eq(a, buf_of(win), 'the alternate buffer')
      assert.eq(buf, terminal.toggle('fake'))
      -- :bdelete (unlisted, still valid) counts as deleted; the alternate buffers are gone too.
      vim.cmd('bdelete! ' .. a)
      assert.truthy(api.nvim_buf_is_valid(a))
      assert.truthy(terminal.stop())
      assert.same({ win }, api.nvim_list_wins(), 'the last window stays')
      local e = buf_of(win)
      assert.truthy(e ~= a and e ~= b and e ~= buf, 'a new buffer')
      assert.eq('', api.nvim_buf_get_name(e))
      assert.eq('', vim.bo[e].buftype)
      assert.truthy(vim.bo[e].buflisted)
      assert.same({ '' }, api.nvim_buf_get_lines(e, 0, -1, false))

      -- A previous buffer that goes as soon as it is hidden ('bufhidden' = wipe).
      local scratch = api.nvim_create_buf(false, true)
      vim.bo[scratch].bufhidden = 'wipe'
      api.nvim_win_set_buf(win, scratch)
      local buf2 = terminal.open('fake', { launch = fake() })
      assert.falsy(api.nvim_buf_is_valid(scratch))
      assert.truthy(terminal.close())
      assert.eq(e, buf_of(win), 'the alternate buffer')
      assert.truthy(api.nvim_buf_is_valid(buf2))
    end)

    it('focuses its window in this tab page; shown only in another tab page, it comes into the current window', function()
      local a = edit('a.txt')
      local w1 = api.nvim_get_current_win()
      vim.cmd('rightbelow vsplit')
      local b = edit('b.txt')
      local w2 = api.nvim_get_current_win()
      api.nvim_set_current_win(w1)
      local buf = terminal.open('fake', { launch = fake() })
      assert.eq(buf, buf_of(w1))
      api.nvim_set_current_win(w2)
      assert.eq(buf, terminal.open('fake'))
      assert.eq(w1, api.nvim_get_current_win(), 'focus goes to its window')
      assert.eq(b, buf_of(w2), 'the other window keeps its buffer')
      -- toggle() from the other window: hidden in its window, the cursor stays.
      api.nvim_set_current_win(w2)
      assert.eq(buf, terminal.toggle('fake'))
      assert.eq(a, buf_of(w1))
      assert.eq(w2, api.nvim_get_current_win())
      assert.eq(buf, terminal.toggle('fake'))
      assert.eq(buf, buf_of(w2), 'shown again: in the current window')
      assert.eq(a, buf_of(w1))
      assert.eq(2, #api.nvim_list_wins())

      -- Shown only in another tab page: in the current window here too.
      vim.cmd('tabnew')
      local w3 = api.nvim_get_current_win()
      local empty = buf_of(w3)
      assert.falsy(terminal.is_visible())
      assert.eq(buf, terminal.open('fake'))
      assert.eq(w3, api.nvim_get_current_win())
      assert.eq(buf, buf_of(w3))
      assert.eq(1, #api.nvim_tabpage_list_wins(0))
      assert.eq(buf, buf_of(w2), 'still shown in the first tab page')
      -- toggle() here hides it here only.
      assert.eq(buf, terminal.toggle('fake'))
      assert.eq(empty, buf_of(w3))
      assert.eq(buf, buf_of(w2))
      -- close() where it is not shown: in every other tab page. No window closes.
      assert.truthy(terminal.close())
      assert.eq(b, buf_of(w2))
      assert.same({}, vim.fn.win_findbuf(buf))
      assert.eq(2, #api.nvim_list_tabpages())
      assert.eq(3, #api.nvim_list_wins())
      assert.truthy(job_running())
    end)

    it("a 'winfixbuf' or diff window is not taken: the main editor window is, else a split", function()
      local a = edit('a.txt')
      local w1 = api.nvim_get_current_win()
      vim.cmd('rightbelow vsplit')
      local b = edit('b.txt')
      local w2 = api.nvim_get_current_win()
      local buf = terminal.open('fake', { launch = fake() })
      assert.truthy(terminal.close())
      for _, case in ipairs({ 'winfixbuf', 'diff' }) do
        vim.wo[w2][case] = true
        api.nvim_set_current_win(w1)
        api.nvim_set_current_win(w2) -- w1 is the previous window
        assert.eq(buf, terminal.open('fake'), case)
        assert.eq(buf, buf_of(w1), case .. ': the main editor window')
        assert.eq(b, buf_of(w2), case)
        assert.eq(w1, api.nvim_get_current_win(), case .. ': focused')
        assert.eq(2, #api.nvim_list_wins(), case)
        assert.eq(a, vim.w[w1].agent_nvim_prev.buf)
        -- focus = false leaves the cursor where it was.
        assert.truthy(terminal.close())
        assert.eq(a, buf_of(w1))
        api.nvim_set_current_win(w2)
        assert.eq(buf, terminal.open('fake', { focus = false }), case)
        assert.eq(buf, buf_of(w1), case)
        assert.eq(w2, api.nvim_get_current_win(), case .. ': not focused')
        assert.truthy(terminal.close())
        vim.wo[w2][case] = false
      end

      -- No other window to take: a split on terminal.split_side, closed when hidden.
      api.nvim_win_close(w1, true)
      vim.wo[w2].winfixbuf = true
      assert.eq(buf, terminal.open('fake'))
      local s = api.nvim_get_current_win()
      assert.truthy(s ~= w2)
      assert.eq(buf, buf_of(s))
      assert.eq(b, buf_of(w2))
      assert.eq(2, #api.nvim_list_wins())
      assert.eq(math.floor(vim.o.columns * 0.4), api.nvim_win_get_width(s))
      assert.eq(vim.o.columns, api.nvim_win_get_position(s)[2] + api.nvim_win_get_width(s), 'on the right edge')
      assert.truthy(vim.wo[s].winfixwidth)
      assert.eq(nil, vim.w[s].agent_nvim_prev)
      assert.eq(buf, terminal.toggle('fake'))
      assert.falsy(api.nvim_win_is_valid(s))
      assert.same({ w2 }, api.nvim_list_wins())
      assert.eq(b, buf_of(w2))
      assert.truthy(job_running())
    end)

    it('replacing the agent: the new one takes the window, which still gets its buffer back', function()
      local a = edit('a.txt')
      local win = api.nvim_get_current_win()
      local la, outa = fake()
      local bufa = terminal.open('a', { launch = la })
      wait_ready(outa)
      local lb, outb = fake()
      local bufb = terminal.open('b', { launch = lb })
      wait_ready(outb)
      assert.eq('b', terminal.name())
      assert.same({ win }, api.nvim_list_wins())
      assert.eq(bufb, buf_of(win))
      assert.eq(win, api.nvim_get_current_win())
      assert.eq(a, vim.w[win].agent_nvim_prev.buf)
      assert.eq(bufb, vim.w[win].agent_nvim_prev.term)
      wait_for(function()
        return not api.nvim_buf_is_valid(bufa)
      end, 5000, 'a is wiped')
      assert.eq(bufb, buf_of(win))

      -- From another window: the first agent's window gets its buffer back, the new one takes this one.
      vim.cmd('rightbelow vsplit')
      local c = edit('c.txt')
      local w2 = api.nvim_get_current_win()
      local bufc = terminal.open('c', { launch = fake() })
      assert.eq(a, buf_of(win))
      assert.eq(bufc, buf_of(w2))
      assert.eq(c, vim.w[w2].agent_nvim_prev.buf)
      assert.truthy(terminal.stop())
      assert.eq(c, buf_of(w2))
      assert.eq(2, #api.nvim_list_wins())
    end)

    it('as the layout of one call, and another layout for one call', function()
      config.setup({ terminal = { layout = 'split', auto_close = true, start_insert = false } })
      local a = edit('a.txt')
      local win = api.nvim_get_current_win()
      local buf = terminal.open('fake', { launch = fake(), layout = 'current' })
      assert.same({ win }, api.nvim_list_wins())
      assert.eq(buf, buf_of(win))
      assert.eq('current', terminal.info().layout)
      -- Shown again the way it started.
      assert.eq(buf, terminal.toggle('fake'))
      assert.eq(a, buf_of(win))
      assert.eq(buf, terminal.toggle('fake'))
      assert.same({ win }, api.nvim_list_wins())
      assert.eq(buf, buf_of(win))
      -- A split for one call: closed when hidden.
      assert.truthy(terminal.close())
      assert.eq(buf, terminal.open('fake', { layout = 'split' }))
      local s = vim.fn.bufwinid(buf)
      assert.truthy(s ~= win)
      assert.eq(a, buf_of(win))
      assert.eq(buf, terminal.toggle('fake'))
      assert.same({ win }, api.nvim_list_wins())
      assert.eq(buf, terminal.toggle('fake', { layout = 'current' }))
      assert.same({ win }, api.nvim_list_wins())
      assert.eq(buf, buf_of(win))
      terminal.stop()
      assert.eq(a, buf_of(win))

      -- layout = 'current' in the config, a split for one start.
      config.setup({ terminal = { layout = 'current', auto_close = true, start_insert = false } })
      local buf2 = terminal.open('fake', { launch = fake(), layout = 'split' })
      assert.eq(2, #api.nvim_list_wins())
      assert.eq(a, buf_of(win))
      assert.eq('split', terminal.info().layout)
      assert.eq(buf2, terminal.toggle('fake'))
      assert.same({ win }, api.nvim_list_wins())
    end)

    ---The alternate buffer (#) of window `win`.
    local function alt_of(win)
      return api.nvim_win_call(win, function()
        return vim.fn.bufnr('#')
      end)
    end

    it("showing and hiding it leaves the window's alternate buffer (#) and its jumplist alone", function()
      local a = edit('a.txt')
      local w1 = api.nvim_get_current_win()
      vim.cmd('rightbelow vsplit')
      local b = edit('b.txt')
      local w2 = api.nvim_get_current_win()
      assert.eq(a, alt_of(w2))
      local jumps = vim.fn.getjumplist(w2)
      local buf = terminal.open('fake', { launch = fake() })
      assert.eq(buf, buf_of(w2))
      assert.eq(a, alt_of(w2), 'shown: # is still a.txt')
      assert.eq(buf, terminal.toggle('fake'))
      assert.eq(b, buf_of(w2))
      assert.eq(a, alt_of(w2), 'hidden: # is still a.txt, not the agent')
      assert.same(jumps, vim.fn.getjumplist(w2), 'no jumps into or out of the agent')
      -- CTRL-^ goes where it went before the agent came, never to the agent.
      vim.cmd('execute "normal! \\<C-^>"')
      assert.eq(a, buf_of(w2))
      assert.eq(b, alt_of(w2))
      -- :AgentToggle twice from there: # is b.txt again, and the window stays.
      assert.eq(buf, terminal.toggle('fake'))
      assert.eq(buf, buf_of(w2))
      assert.eq(buf, terminal.toggle('fake'))
      assert.eq(a, buf_of(w2))
      assert.eq(b, alt_of(w2))
      -- stop() too.
      assert.eq(buf, terminal.open('fake'))
      assert.truthy(terminal.stop())
      assert.eq(a, buf_of(w2))
      assert.eq(b, alt_of(w2))
      assert.same({ w1, w2 }, api.nvim_tabpage_list_wins(0))
    end)

    it('a window you showed the agent in yourself (CTRL-^, :buffer) is not closed: it shows its alternate buffer', function()
      local a = edit('a.txt')
      local w1 = api.nvim_get_current_win()
      vim.cmd('rightbelow vsplit')
      local b = edit('b.txt')
      local w2 = api.nvim_get_current_win()
      local buf = terminal.open('fake', { launch = fake() })
      assert.eq(buf, terminal.toggle('fake'))
      assert.eq(b, buf_of(w2))
      -- :buffer (as CTRL-^ would with the agent as #): w2 remembers no buffer.
      vim.cmd('buffer ' .. buf)
      assert.eq(buf, buf_of(w2))
      assert.eq(nil, vim.w[w2].agent_nvim_prev)
      assert.eq(b, alt_of(w2))
      assert.eq(buf, terminal.toggle('fake'))
      assert.truthy(api.nvim_win_is_valid(w2), 'not closed')
      assert.eq(b, buf_of(w2), 'its alternate buffer')
      assert.same({ w1, w2 }, api.nvim_tabpage_list_wins(0))
      assert.truthy(job_running())

      -- stop() the same way; with no alternate buffer left, a new empty buffer.
      vim.cmd('buffer ' .. buf)
      vim.cmd('bwipeout! ' .. b)
      assert.eq(buf, buf_of(w2))
      assert.truthy(terminal.stop())
      assert.same({ w1, w2 }, api.nvim_tabpage_list_wins(0))
      local e = buf_of(w2)
      assert.truthy(e ~= a and e ~= buf, 'a new buffer')
      assert.eq('', api.nvim_buf_get_name(e))
      assert.eq(a, buf_of(w1))

      -- A window split off the agent's window is one more view of it: it closes.
      vim.cmd.edit(vim.fn.fnameescape(tmp .. '/b.txt'))
      b = api.nvim_get_current_buf()
      local buf2 = terminal.open('fake', { launch = fake() })
      assert.eq(buf2, buf_of(w2))
      vim.cmd('split')
      local w3 = api.nvim_get_current_win()
      assert.eq(buf2, buf_of(w3))
      assert.eq(buf2, terminal.toggle('fake'))
      assert.falsy(api.nvim_win_is_valid(w3), 'the split closed')
      assert.eq(b, buf_of(w2))
      assert.same({ w1, w2 }, api.nvim_tabpage_list_wins(0))
    end)

    it('a window left with :edit is the user\'s again: a later hide shows what it showed last', function()
      edit('a.txt')
      vim.cmd('rightbelow vsplit')
      local b = edit('b.txt')
      local w2 = api.nvim_get_current_win()
      local buf = terminal.open('fake', { launch = fake() })
      assert.eq(buf, buf_of(w2))
      assert.eq(b, vim.w[w2].agent_nvim_prev.buf)
      -- The user leaves the agent by hand: the remembered b.txt is forgotten.
      local c = edit('c.txt')
      assert.eq(nil, vim.w[w2].agent_nvim_prev)
      -- CTRL-^ brings the agent back (it is # now); hiding it shows c.txt, not the stale b.txt.
      vim.cmd('execute "normal! \\<C-^>"')
      assert.eq(buf, buf_of(w2))
      assert.eq(buf, terminal.toggle('fake'))
      assert.truthy(api.nvim_win_is_valid(w2), 'not closed')
      assert.eq(c, buf_of(w2))
      assert.truthy(job_running())
    end)

    it('with the other layouts, only such a window alone in its tab page stays', function()
      config.setup({ terminal = { layout = 'split', auto_close = true, start_insert = false } })
      edit('a.txt')
      local b = edit('b.txt')
      local w1 = api.nvim_get_current_win()
      local buf = terminal.open('fake', { launch = fake(), focus = false })
      local s = vim.fn.bufwinid(buf)
      assert.truthy(s ~= w1)
      -- In w1 too: the terminal's split closes, and w1, alone then, shows its alternate buffer.
      vim.cmd('buffer ' .. buf)
      assert.eq(b, alt_of(w1))
      assert.eq(buf, terminal.toggle('fake'))
      assert.falsy(api.nvim_win_is_valid(s))
      assert.same({ w1 }, api.nvim_list_wins())
      assert.eq(b, buf_of(w1))

      -- The only window of another tab page: the tab page stays.
      vim.cmd('tabnew')
      local t2 = api.nvim_get_current_tabpage()
      local w2 = api.nvim_get_current_win()
      local empty = buf_of(w2)
      vim.cmd('buffer ' .. buf)
      assert.truthy(terminal.close())
      assert.truthy(api.nvim_tabpage_is_valid(t2), 'the tab page stays')
      assert.eq(empty, buf_of(w2))

      -- Not alone: closed, as the agent's own windows are.
      vim.cmd('vsplit')
      local w3 = api.nvim_get_current_win()
      vim.cmd('buffer ' .. buf)
      assert.truthy(terminal.close())
      assert.falsy(api.nvim_win_is_valid(w3))
      assert.same({ w2 }, api.nvim_tabpage_list_wins(t2))
      assert.eq(b, buf_of(w1))
      assert.truthy(job_running())
    end)

    it('a diff tab page gets a split_size view of the terminal (split_here)', function()
      edit('a.txt')
      vim.cmd('vsplit') -- the agent's window is narrower than the editor, but it is not a split to match
      local win = api.nvim_get_current_win()
      local buf = terminal.open('fake', { launch = fake(), focus = false })
      assert.eq(buf, buf_of(win))
      assert.truthy(api.nvim_win_get_width(win) < vim.o.columns)
      vim.cmd('tabnew')
      local extra, why = terminal.split_here()
      assert.truthy(extra, why)
      assert.eq(math.floor(vim.o.columns * 0.4), api.nvim_win_get_width(extra))
      assert.eq(vim.o.columns, api.nvim_win_get_position(extra)[2] + api.nvim_win_get_width(extra))
      assert.truthy(vim.wo[extra].winfixwidth)
      assert.eq(nil, vim.w[extra].agent_nvim_prev)
      -- Closing its tab page closes it; the agent's own window keeps it.
      vim.cmd('tabclose')
      assert.same({ win }, vim.fn.win_findbuf(buf))
      assert.truthy(job_running())
    end)
  end)

  it('removes the temp files of the running agent on VimLeavePre', function()
    local dir = tmp .. '/leave'
    util.mkdir_p(dir, tonumber('700', 8))
    local launch = fake({ cleanup = { dir } })
    terminal.open('fake', { launch = launch })
    vim.api.nvim_exec_autocmds('VimLeavePre', {})
    assert.eq(0, vim.fn.isdirectory(dir))
  end)
end)
