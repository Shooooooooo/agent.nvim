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

describe('terminal', function()
  before_each(function()
    tmp = util.realpath(vim.fn.tempname())
    util.mkdir_p(tmp, tonumber('700', 8))
    tmp = util.realpath(tmp)
    notes = {}
    vim.notify = function(msg, level)
      notes[#notes + 1] = { msg = msg, level = level }
    end
    config.setup({ terminal = { layout = 'split', auto_close = true, start_insert = false } })
    terminal.setup({})
  end)

  after_each(function()
    terminal.stop_all()
    wait_for(function()
      return #terminal.running() == 0
    end, 5000, 'all jobs stopped')
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
    assert.truthy(terminal.is_running('fake'))
    assert.truthy(terminal.is_visible('fake'))
    assert.same({ 'fake' }, terminal.running())
    -- focus=true by default: the terminal window is current, and it is a right split of 40% width.
    local win = vim.api.nvim_get_current_win()
    assert.truthy(win ~= prev)
    assert.eq(buf, vim.api.nvim_win_get_buf(win))
    assert.eq('', vim.api.nvim_win_get_config(win).relative)
    assert.eq(math.floor(vim.o.columns * 0.4), vim.api.nvim_win_get_width(win))
    assert.eq(vim.o.columns, vim.api.nvim_win_get_position(win)[2] + vim.api.nvim_win_get_width(win))
    local info = terminal.info('fake')
    assert.eq('session-1', info.session_id)
    assert.truthy(info.pid and info.pid > 0)
    assert.eq('fake', terminal.find_by_pid(info.pid))
    assert.eq('fake', terminal.find_by_session('session-1'))
  end)

  it('opening a running agent reuses its terminal', function()
    local launch = fake()
    local buf = terminal.open('fake', { launch = launch })
    local job = terminal.info('fake').job
    local buf2 = terminal.open('fake', { launch = function() error('must not relaunch') end })
    assert.eq(buf, buf2)
    assert.eq(job, terminal.info('fake').job)
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
    terminal.stop('claude')
    wait_for(function()
      return not terminal.is_running('claude') and vim.fn.isdirectory(spec.cleanup[1]) == 0
    end, 5000, 'cleanup')
    assert.eq(0, vim.fn.filereadable(mcp_file))
    assert.falsy(vim.api.nvim_buf_is_valid(buf))
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
    local job = terminal.info('fake').job
    assert.truthy(terminal.is_visible('fake'))
    terminal.toggle('fake')
    assert.falsy(terminal.is_visible('fake'))
    assert.truthy(terminal.is_running('fake'))
    assert.truthy(vim.api.nvim_buf_is_valid(buf))
    assert.eq(buf, terminal.toggle('fake'))
    assert.truthy(terminal.is_visible('fake'))
    assert.eq(job, terminal.info('fake').job)
    assert.eq(buf, vim.api.nvim_get_current_buf())
    assert.truthy(terminal.close('fake'))
    assert.falsy(terminal.is_visible('fake'))
    assert.truthy(terminal.is_running('fake'))
    assert.eq(job, terminal.info('fake').job)
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
    assert.truthy(terminal.stop('fake'))
    wait_for(function()
      return not terminal.is_running('fake') and not vim.api.nvim_buf_is_valid(buf)
    end, 5000, 'stopped')
    vim.api.nvim_del_autocmd(au)
    assert.eq(0, vim.fn.isdirectory(dir))
    assert.eq(nil, terminal.info('fake'))
    assert.same({}, terminal.running())
    assert.eq(1, #exits)
    assert.eq('fake', exits[1].name)
    assert.same({ 'AgentTerminalOpen:fake', 'AgentTerminalExit:fake' }, events)
    assert.falsy(terminal.stop('fake'))
  end)

  it('send types a bracketed paste, optionally followed by Enter', function()
    local launch, out = fake()
    terminal.open('fake', { launch = launch })
    wait_ready(out)
    assert.truthy(terminal.send('fake', 'hello\nworld'))
    wait_for(function()
      return (read(out .. '.stdin') or '') == '\27[200~hello\nworld\27[201~'
    end, 3000, 'paste')
    assert.truthy(terminal.send('fake', 'go', { submit = true }))
    local expected = '\27[200~hello\nworld\27[201~\27[200~go\27[201~\r'
    wait_for(function()
      return read(out .. '.stdin') == expected
    end, 3000, 'submit')
    -- Paste delimiters inside the text are stripped; bracketed = false sends raw text.
    assert.truthy(terminal.send('fake', 'a\27[201~b'))
    assert.truthy(terminal.send('fake', 'raw', { bracketed = false }))
    expected = expected .. '\27[200~ab\27[201~raw'
    wait_for(function()
      return read(out .. '.stdin') == expected
    end, 3000, 'raw')
  end)

  it('send defaults to the last focused agent and fails when nothing runs', function()
    local ok, err = terminal.send('fake', 'x')
    assert.falsy(ok)
    assert.matches('not running', err)
    assert.falsy((terminal.send(nil, 'x')))
    local launch, out = fake()
    terminal.open('fake', { launch = launch })
    wait_ready(out)
    assert.truthy(terminal.send(nil, 'y'))
    wait_for(function()
      return read(out .. '.stdin') == '\27[200~y\27[201~'
    end, 3000, 'default target')
  end)

  it('tracks the last focused agent', function()
    local la, outa = fake()
    local lb, outb = fake()
    local bufa = terminal.open('a', { launch = la })
    terminal.open('b', { launch = lb })
    wait_ready(outa)
    wait_ready(outb)
    assert.same({ 'a', 'b' }, terminal.running())
    assert.eq('b', terminal.last_focused())
    vim.api.nvim_set_current_win(vim.fn.bufwinid(bufa))
    assert.eq('a', terminal.last_focused())
    terminal.stop('a')
    wait_for(function()
      return not terminal.is_running('a')
    end, 5000)
    assert.eq('b', terminal.last_focused())
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
    assert.falsy(terminal.is_running('fake'))
    assert.eq(0, vim.fn.isdirectory(dir))
    assert.eq(nil, terminal.info('fake'))
  end)

  it('keeps a terminal that failed at startup open, and relaunches on the next open', function()
    local launch = fake({ env = { FAKE_AGENT_EXIT = '3' } })
    local buf = terminal.open('fake', { launch = launch })
    wait_for(function()
      return not terminal.is_running('fake')
    end, 5000, 'exit')
    assert.truthy(vim.api.nvim_buf_is_valid(buf))
    assert.eq(3, terminal.info('fake').exit_code)
    assert.truthy(has_note('fake exited with code 3'))
    local launch2, out2 = fake()
    local buf2 = terminal.open('fake', { launch = launch2 })
    assert.truthy(buf2 ~= buf)
    assert.falsy(vim.api.nvim_buf_is_valid(buf))
    wait_ready(out2)
    assert.truthy(terminal.is_running('fake'))
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
        return not terminal.is_running('fake')
      end, 5000, 'exit')
      vim.wait(50)
      assert.falsy(has_note('left open'), vim.inspect(notes))
      assert.eq(nil, terminal.info('fake'))
    end
  end)

  it('with auto_close = false the finished terminal stays', function()
    config.setup({ terminal = { layout = 'split', auto_close = false, start_insert = false } })
    local launch = fake({ env = { FAKE_AGENT_EXIT = '0' } })
    local buf = terminal.open('fake', { launch = launch })
    wait_for(function()
      return not terminal.is_running('fake')
    end, 5000, 'exit')
    vim.wait(50)
    assert.truthy(vim.api.nvim_buf_is_valid(buf))
    assert.eq(0, terminal.info('fake').exit_code)
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
    assert.same({}, terminal.running())
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
    terminal.close('f')
    assert.falsy(terminal.is_visible('f'))
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
    terminal.stop('fake')
    wait_for(function()
      return not terminal.is_running('fake')
    end, 5000)
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

  it('removes temp files of running agents on VimLeavePre', function()
    local dir = tmp .. '/leave'
    util.mkdir_p(dir, tonumber('700', 8))
    local launch = fake({ cleanup = { dir } })
    terminal.open('fake', { launch = launch })
    vim.api.nvim_exec_autocmds('VimLeavePre', {})
    assert.eq(0, vim.fn.isdirectory(dir))
  end)
end)
