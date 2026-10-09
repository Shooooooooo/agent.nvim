-- Integration of agent.nvim: plugin/agent.lua, setup(), the launcher wiring for every agent kind
-- (with the fake agent CLI), one agent at a time (replace, stop, provider lifecycle), :AgentSend
-- (the selection through the providers' IDE connection, typed when it is disabled), selection
-- forwarding, teardown.
local util = require('agent.util')
local uv = vim.uv

local FIX = TEST_ROOT .. '/tests/fixtures/fake_agent.sh'
local KINDS = { 'claude', 'copilot', 'gemini', 'opencode' }

local orig_notify = vim.notify
local orig_cwd = vim.fn.getcwd()
local orig_gemini_home = vim.env.GEMINI_CLI_HOME
local tmp, ws, notes

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

local function out_of(name)
  return tmp .. '/out-' .. name
end

local function wait_ready(name)
  wait_for(function()
    return vim.fn.filereadable(out_of(name) .. '.env') == 1
  end, 5000, name .. ' fake agent ready')
end

local function stdin_of(name)
  return read(out_of(name) .. '.stdin') or ''
end

local function wait_stdin(name, text)
  wait_for(function()
    return stdin_of(name):find(text, 1, true) ~= nil
  end, 5000, ('%s stdin to contain %q'):format(name, text))
end

local function pasted(text)
  return '\27[200~' .. text .. '\27[201~'
end

local function files_in(dir)
  local out = {}
  for name in vim.fs.dir(dir) do
    out[#out + 1] = name
  end
  table.sort(out)
  return out
end

local function base_opts()
  local agents = {}
  for _, k in ipairs(KINDS) do
    agents[k] = { cmd = { FIX }, env = { FAKE_AGENT_OUT = out_of(k) } }
  end
  agents.gemini.extension_dir = tmp .. '/gemini-ext'
  return {
    terminal = { layout = 'split', start_insert = false },
    providers = {
      claude = { lock_dir = tmp .. '/claude-ide' },
      copilot = { lock_dir = tmp .. '/copilot-ide' },
      gemini = { discovery_dir = tmp .. '/gemini-ide' },
    },
    agents = agents,
  }
end

local function setup(extra)
  return require('agent').setup(vim.tbl_deep_extend('force', base_opts(), extra or {}))
end

---Open a file of the workspace in a regular (non-terminal) window and make it current.
local function edit_in_main(path)
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.bo[vim.api.nvim_win_get_buf(w)].buftype == '' then
      vim.api.nvim_set_current_win(w)
      break
    end
  end
  vim.cmd.edit(vim.fn.fnameescape(path))
  return vim.api.nvim_get_current_buf()
end

local function term_win()
  local buf = require('agent.terminal').bufnr()
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_buf(w) == buf then
      return w
    end
  end
end

-- Every agent job a test started (a stopped agent is forgotten before its job has exited).
local pids = {}
vim.api.nvim_create_autocmd('User', {
  pattern = 'AgentTerminalOpen',
  callback = function(ev)
    pids[#pids + 1] = ev.data.pid
  end,
})

local function wait_exited(pid)
  wait_for(function()
    return not pid_alive(pid)
  end, 5000, 'pid ' .. tostring(pid) .. ' exited')
  vim.wait(50) -- the job's on_exit runs after the process is reaped
end

-- Runs first: nothing has called setup() in this process yet.
describe('plugin/agent.lua', function()
  it('defines the commands without calling setup(), and a command calls setup({}) lazily once', function()
    local agent = require('agent')
    assert.falsy(agent._state.setup_done)
    vim.cmd.runtime('plugin/agent.lua')
    assert.eq(1, vim.g.loaded_agent_nvim)
    local cmds = vim.api.nvim_get_commands({})
    for _, c in ipairs({ 'AgentToggle', 'AgentOpen', 'AgentSend', 'AgentClose', 'AgentStop', 'AgentDiffAccept',
      'AgentDiffReject', 'AgentStatus', 'AgentMcpConfig', 'AgentGeminiSetup' }) do
      assert.truthy(cmds[c], ':' .. c .. ' exists')
    end
    assert.eq('?', cmds.AgentSend.nargs)
    assert.truthy(cmds.AgentSend.range ~= nil and cmds.AgentSend.range ~= '', ':AgentSend takes a range')
    assert.falsy(cmds.AgentAdd, ':AgentAdd stays removed (:AgentSend without a range sends the whole file)')
    assert.falsy(cmds.Agent, ':Agent no longer exists (:AgentToggle replaced it)')
    assert.falsy(cmds.AgentStop.bang)
    assert.eq('0', cmds.AgentStop.nargs)
    assert.eq('0', cmds.AgentClose.nargs)
    assert.eq('?', cmds.AgentToggle.nargs)
    assert.eq('?', cmds.AgentOpen.nargs)
    assert.falsy(agent._state.setup_done, 'defining commands does not call setup()')
    -- The command line is recorded from the start: the first :'<,'>AgentSend (which runs setup())
    -- already tells the Visual area from other ranges.
    assert.eq(1, vim.fn.exists('#agent.nvim.cmdline#CmdlineLeave'))
    -- The load guard: sourcing again is a no-op.
    vim.cmd.runtime('plugin/agent.lua')

    local orig_setup, calls = agent.setup, 0
    agent.setup = function(opts)
      calls = calls + 1
      assert.same({}, opts)
      return orig_setup(opts)
    end
    local ok, err = pcall(function()
      vim.cmd('silent AgentStatus')
      vim.cmd('silent AgentStatus')
    end)
    agent.setup = orig_setup
    assert.truthy(ok, err)
    assert.eq(1, calls, 'setup({}) runs once')
    assert.truthy(agent._state.setup_done)
    assert.eq('claude', require('agent.config').get().default_agent)
    assert.same({ 'claude', 'copilot' }, vim.fn.getcompletion('AgentToggle c', 'cmdline'))
    assert.same({ 'gemini' }, vim.fn.getcompletion('AgentOpen g', 'cmdline'))
    assert.same({ 'copilot' }, vim.fn.getcompletion('AgentSend co', 'cmdline'))
    -- :AgentClose and :AgentStop take no name, so they complete nothing.
    assert.same({}, vim.fn.getcompletion('AgentClose ', 'cmdline'))
    assert.same({}, vim.fn.getcompletion('AgentStop c', 'cmdline'))
    -- Nothing was started.
    for _, s in pairs(agent.status().providers) do
      assert.falsy(s.running)
    end
  end)
end)

describe('agent', function()
  local agent, terminal

  before_each(function()
    agent = require('agent')
    terminal = require('agent.terminal')
    tmp = util.realpath(vim.fn.tempname())
    util.mkdir_p(tmp, tonumber('700', 8))
    tmp = util.realpath(tmp)
    ws = tmp .. '/ws'
    util.mkdir_p(ws, tonumber('700', 8))
    write(ws .. '/a.txt', 'one\ntwo\nthree\nfour\n')
    vim.env.GEMINI_CLI_HOME = tmp .. '/ghome'
    vim.cmd.cd(ws)
    notes = {}
    vim.notify = function(msg, level)
      notes[#notes + 1] = { msg = msg, level = level }
    end
    setup()
  end)

  after_each(function()
    agent.teardown()
    wait_for(function()
      return not vim.iter(pids):any(pid_alive)
    end, 5000, 'every agent process exited')
    pids = {}
    vim.wait(50)
    vim.cmd('silent! only')
    vim.cmd('silent! %bwipeout!')
    vim.cmd.cd(orig_cwd)
    vim.notify = orig_notify
    vim.env.GEMINI_CLI_HOME = orig_gemini_home
    util.remove_dir(tmp)
  end)

  describe('setup', function()
    it('applies options and rejects invalid ones', function()
      setup({ terminal = { layout = 'tab' }, log_level = 'error' })
      assert.eq('tab', require('agent.config').get().terminal.layout)
      setup({ terminal = { layout = 'current' } })
      assert.eq('current', require('agent.config').get().terminal.layout)
      assert.error(function()
        agent.setup({ terminal = { layout = 'window' } })
      end, 'terminal.layout')
      assert.error(function()
        agent.setup({ log_level = 'loud' })
      end, 'invalid configuration')
    end)

    it('auto_start starts every enabled provider', function()
      setup({ auto_start = true, providers = { gemini = { enabled = false } } })
      local s = agent.status().providers
      assert.truthy(s.claude.running)
      assert.truthy(s.copilot.running)
      assert.falsy(s.gemini.running)
      assert.falsy(s.gemini.enabled)
      assert.eq(1, #vim.tbl_filter(function(f)
        return f:match('%.lock$') ~= nil
      end, files_in(tmp .. '/claude-ide')))
    end)
  end)

  describe('launcher', function()
    it('claude: starts the provider and passes its port, the MCP config and the user args', function()
      local buf, err = agent.open('claude', { args = { '--model', 'x' } })
      assert.eq(nil, err)
      assert.truthy(buf)
      wait_ready('claude')
      local P = require('agent.providers.claude')
      assert.truthy(P.is_running())
      local env = read_env(out_of('claude'))
      assert.eq(tostring(P.status().port), env.CLAUDE_CODE_SSE_PORT)
      assert.eq('true', env.ENABLE_IDE_INTEGRATION)
      assert.eq('true', env.CLAUDE_CODE_IDE_SKIP_AUTO_INSTALL)
      assert.eq(vim.v.servername, env.NVIM)
      assert.eq(terminal.info().session_id, env.AGENT_NVIM_SESSION)
      local args = read_args(out_of('claude'))
      assert.eq('--model', args[1])
      assert.eq('x', args[2])
      local cfg_path = args[3]:match('^%-%-mcp%-config=(.+)$')
      assert.truthy(cfg_path, vim.inspect(args))
      assert.eq(3, #args)
      local mcp = vim.json.decode(read(cfg_path)).mcpServers.nvim
      assert.eq(vim.v.progpath, mcp.command)
      assert.eq(require('agent.nvim_mcp').script_path(), mcp.args[#mcp.args - 1])
      assert.eq(vim.v.servername, mcp.args[#mcp.args])
      assert.eq(vim.v.servername, mcp.env.NVIM)
      assert.eq('claude', mcp.env.AGENT_NVIM_AGENT)
      -- The lock lives in the overridden lock dir and lists the workspace.
      local lock = vim.json.decode(read(P.status().lock))
      assert.eq(tmp .. '/claude-ide', vim.fs.dirname(P.status().lock))
      assert.truthy(vim.tbl_contains(lock.workspaceFolders, ws))
    end)

    it('claude: auto_approve and mcp=false are honoured', function()
      setup({ agents = { claude = { auto_approve = true } } })
      agent.open('claude')
      wait_ready('claude')
      local args = read_args(out_of('claude'))
      assert.eq('--allowedTools=mcp__nvim', args[#args])
      local pid = terminal.info().pid
      agent.stop()
      wait_exited(pid)
      vim.fn.delete(out_of('claude') .. '.env')
      agent.open('claude', { mcp = false })
      wait_ready('claude')
      assert.same({}, read_args(out_of('claude')))
    end)

    it('opencode: shares the claude provider, blanks the SSE port vars and registers MCP by env', function()
      agent.open('opencode')
      wait_ready('opencode')
      local env = read_env(out_of('opencode'))
      assert.eq('', env.CLAUDE_CODE_SSE_PORT)
      assert.eq('', env.OPENCODE_EDITOR_SSE_PORT)
      local oc = vim.json.decode(env.OPENCODE_CONFIG_CONTENT)
      assert.eq(vim.v.progpath, oc.mcp.nvim.command[1])
      assert.eq(vim.v.servername, oc.mcp.nvim.command[#oc.mcp.nvim.command])
      local P = require('agent.providers.claude')
      assert.truthy(P.is_running())
      assert.truthy(vim.tbl_contains(vim.json.decode(read(P.status().lock)).workspaceFolders, ws))
    end)

    it('copilot: writes a lock for the job cwd and registers MCP with --additional-mcp-config', function()
      agent.open('copilot')
      wait_ready('copilot')
      local P = require('agent.providers.copilot')
      local st = P.status()
      assert.truthy(st.running)
      assert.eq(util.realpath(ws), vim.trim(read(out_of('copilot') .. '.cwd')))
      local args = read_args(out_of('copilot'))
      assert.eq('--additional-mcp-config', args[1])
      local mcp = vim.json.decode(read(args[2]:sub(2))).mcpServers.nvim
      assert.eq(vim.v.servername, mcp.args[#mcp.args])
      local found = false
      for _, f in ipairs(st.locks) do
        assert.eq(tmp .. '/copilot-ide', vim.fs.dirname(f))
        local lock = vim.json.decode(read(f))
        assert.eq(st.address, lock.socketPath)
        found = found or vim.tbl_contains(lock.workspaceFolders, util.realpath(ws))
      end
      assert.truthy(found, 'a lock lists the workspace')
    end)

    it('gemini: passes the companion port, token and workspace, and writes the extension manifest', function()
      agent.open('gemini')
      wait_ready('gemini')
      local P = require('agent.providers.gemini')
      local st = P.status()
      assert.truthy(st.running)
      local env = read_env(out_of('gemini'))
      assert.eq(tostring(st.port), env.GEMINI_CLI_IDE_SERVER_PORT)
      assert.eq(util.realpath(ws), env.GEMINI_CLI_IDE_WORKSPACE_PATH)
      assert.eq(tostring(vim.fn.getpid()), env.GEMINI_CLI_IDE_PID)
      assert.truthy(#env.GEMINI_CLI_IDE_AUTH_TOKEN > 0)
      assert.eq(tmp .. '/gemini-ide', vim.fs.dirname(st.lock))
      local manifest = vim.json.decode(read(tmp .. '/gemini-ext/gemini-extension.json'))
      assert.eq('${NVIM}', manifest.mcpServers.nvim.args[#manifest.mcpServers.nvim.args])
    end)

    it('gemini: enable_ide_mode() types /ide enable into the agent terminal only when it runs Gemini', function()
      local P = require('agent.providers.gemini')
      assert.same({ false, 'gemini is not running' }, { P.enable_ide_mode() })
      agent.open('claude', { focus = false })
      wait_ready('claude')
      assert.same({ false, 'gemini is not running' }, { P.enable_ide_mode() })
      agent.open('gemini', { focus = false, confirm = false })
      wait_ready('gemini')
      assert.truthy(P.enable_ide_mode())
      wait_for(function()
        return read(out_of('gemini') .. '.stdin') == '\27[200~/ide enable\27[201~\r'
      end, 3000, '/ide enable typed and submitted')
    end)

    it('a disabled provider launches the agent without IDE integration', function()
      setup({ providers = { claude = { enabled = false } } })
      agent.open('claude')
      wait_ready('claude')
      local env = read_env(out_of('claude'))
      assert.eq(nil, env.CLAUDE_CODE_SSE_PORT)
      assert.falsy(require('agent.providers.claude').is_running())
    end)

    it('an unknown agent is an error', function()
      local buf, err = agent.open('nope')
      assert.eq(nil, buf)
      assert.matches('unknown agent', err)
    end)

    it('a missing executable is an error and starts no provider', function()
      setup({ agents = { copilot = { cmd = { tmp .. '/no-such-cli' } } } })
      local buf, err = agent.open('copilot', { silent = true })
      assert.eq(nil, buf)
      assert.matches("executable '.*no%-such%-cli' not found", err)
      assert.falsy(require('agent.providers.copilot').is_running())
      assert.same({}, files_in(tmp .. '/copilot-ide'))
    end)
  end)

  describe('selection', function()
    it('with selection.track = true it is forwarded to every running provider, and not once it is off', function()
      setup({ selection = { track = true } })
      local got = { claude = {}, copilot = {}, gemini = {} }
      local originals = {}
      for name in pairs(got) do
        local P = require('agent.providers.' .. name)
        originals[name] = P.on_selection
        P.on_selection = function(s)
          table.insert(got[name], s)
        end
      end
      local ok, err = pcall(function()
        agent.open('claude', { focus = false })
        wait_ready('claude')
        edit_in_main(ws .. '/a.txt')
        vim.api.nvim_win_set_cursor(0, { 3, 1 })
        require('agent.editor.selection').flush()
        assert.truthy(#got.claude >= 1, 'claude got the selection')
        local s = got.claude[#got.claude]
        assert.eq(ws .. '/a.txt', s.path)
        assert.eq(2, s.start.line)
        assert.eq(0, #got.copilot, 'copilot is not running')
        assert.eq(0, #got.gemini, 'gemini is not running')

        setup({ selection = { track = false } })
        local n = #got.claude
        vim.api.nvim_win_set_cursor(0, { 1, 0 })
        require('agent.editor.selection').flush()
        assert.eq(n, #got.claude, 'no forwarding with selection.track = false')
      end)
      for name, fn in pairs(originals) do
        require('agent.providers.' .. name).on_selection = fn
      end
      assert.truthy(ok, err)
    end)
  end)

  describe('selection.track = false (the default)', function()
    it('pushes nothing, and the selection is still tracked for the tools the agent calls', function()
      assert.eq(false, require('agent.config').defaults.selection.track)
      assert.eq(false, require('agent.config').get().selection.track)
      local got, originals = { claude = 0, copilot = 0, gemini = 0 }, {}
      for name in pairs(got) do
        local P = require('agent.providers.' .. name)
        originals[name] = P.on_selection
        P.on_selection = function()
          got[name] = got[name] + 1
        end
      end
      local sel = require('agent.editor.selection')
      local ok, err = pcall(function()
        setup({ auto_start = true, selection = { debounce_ms = 20 } })
        agent.open('claude', { focus = false })
        wait_ready('claude')
        assert.truthy(sel.is_running(), 'selection tracking runs while a provider runs')
        edit_in_main(ws .. '/a.txt')
        vim.api.nvim_win_set_cursor(0, { 2, 0 })
        vim.api.nvim_feedkeys(vim.keycode('Vj'), 'x!', false)
        sel.flush()
        -- Straight from Visual mode to the agent: the selection is kept, and pushed to nobody.
        vim.api.nvim_feedkeys(vim.keycode('<C-w>j'), 'x', false)
        assert.eq(terminal.bufnr(), vim.api.nvim_get_current_buf())
        vim.wait(sel.DEMOTE_MS + 150)
        sel.flush()
        assert.same({ claude = 0, copilot = 0, gemini = 0 }, got, 'nothing forwarded')

        -- The tools the agent calls read it: Claude's getLatestSelection and getCurrentSelection,
        -- Copilot's get_selection; Gemini's context carries nothing.
        local function call(srv, tool, session)
          local box = {}
          srv:handle(session, { jsonrpc = '2.0', id = 1, method = 'tools/call',
            params = { name = tool, arguments = vim.empty_dict() } }, {
            on_response = function(r)
              box.r = r
            end,
            on_done = function() end,
          })
          return vim.json.decode(box.r.result.content[1].text)
        end
        local C = require('agent.providers.claude')
        local cs = C._state.srv:open_session({ send = function()
          return true
        end, info = {} })
        for _, tool in ipairs({ 'getLatestSelection', 'getCurrentSelection' }) do
          local r = call(C._state.srv, tool, cs)
          assert.eq('two\nthree', r.text, tool)
          assert.eq(ws .. '/a.txt', r.filePath, tool)
        end
        local K = require('agent.providers.copilot')
        local ks = K._state().srv:open_session({ send = function()
          return true
        end, info = {} })
        local r = call(K._state().srv, 'get_selection', ks)
        assert.eq('two\nthree', r.text)
        assert.eq(true, r.current)
        assert.same({ workspaceState = { openFiles = {} } }, require('agent.providers.gemini').build_context())
      end)
      for name, fn in pairs(originals) do
        require('agent.providers.' .. name).on_selection = fn
      end
      assert.truthy(ok, err)
    end)
  end)

  describe('selection and the agent terminal', function()
    for _, layout in ipairs({ 'split', 'current', 'tab' }) do
      it(('a Visual-mode mapping to <cmd>AgentToggle<cr> keeps the selection (layout = %s)'):format(layout), function()
        setup({ terminal = { layout = layout }, selection = { debounce_ms = 20 } })
        write(ws .. '/v.txt', 'one\ntwo\nthree\n')
        local sel = require('agent.editor.selection')
        local v = edit_in_main(ws .. '/v.txt')
        if layout == 'current' then
          vim.cmd('rightbelow vsplit') -- the agent takes this window over
        end
        vim.keymap.set('x', '<F9>', '<cmd>AgentToggle claude<cr>')
        local ok, err = pcall(function()
          vim.api.nvim_win_set_cursor(0, { 1, 0 })
          vim.api.nvim_feedkeys(vim.keycode('Vj'), 'x!', false)
          assert.eq('one\ntwo', sel.current().text)
          vim.api.nvim_feedkeys(vim.keycode('<F9>'), 'x', false)
          wait_ready('claude')
          assert.eq(require('agent.terminal').bufnr(), vim.api.nvim_get_current_buf())
          vim.wait(sel.DEMOTE_MS + 150)
          local s, live = sel.current()
          assert.falsy(live)
          assert.eq(v, s.bufnr)
          assert.eq('one\ntwo', s.text)
        end)
        pcall(vim.keymap.del, 'x', '<F9>')
        agent.stop()
        assert.truthy(ok, err)
      end)
    end
  end)

  describe(':AgentSend', function()
    local saved, stubs
    local orig_confirm = vim.fn.confirm
    local PROVIDER = { claude = 'claude', opencode = 'claude', copilot = 'copilot', gemini = 'gemini' }
    local waiting = ' has not connected to Neovim yet: the context will be sent when it connects'

    ---Replace provider functions for one test (restored in after_each).
    local function stub(provider, fns)
      local P = require('agent.providers.' .. provider)
      for k, fn in pairs(fns) do
        stubs[#stubs + 1] = { P, k, P[k] }
        P[k] = fn
      end
    end

    ---Stub the IDE client of a provider's agent: client_state() is 'ready' while c.ready, else
    ---c.state (c.asked: the opts it is given); send_context() records every selection it is given
    ---(c.tries) and has it delivered (c.calls: { s = selection, o = opts }) only while c.ready.
    local function client(provider, ready)
      local c = { ready = ready, state = nil, asked = {}, tries = {}, calls = {} }
      stub(provider, {
        client_state = function(o)
          c.asked[#c.asked + 1] = o
          return c.ready and 'ready' or c.state
        end,
        send_context = function(s, o)
          c.tries[#c.tries + 1] = s
          if not c.ready then
            return false
          end
          c.calls[#c.calls + 1] = { s = s, o = o }
          return true
        end,
      })
      return c
    end

    ---What a captured selection covers: { path, start_line, end_line, mode, text }.
    local function covers(s)
      return { s.path, s.start_line, s.end_line, s.mode, s.text }
    end

    ---The opts send_context() and client_state() get for the agent in the terminal: its kind, its
    ---job pid and when its terminal was started (util.now_ms()).
    local function for_agent(kind)
      local info = terminal.info()
      assert.eq('number', type(info.started))
      return { kind = kind, pid = info.pid, started = info.started }
    end

    ---The number of the notes (vim.notify) whose message contains `text`.
    local function noted(text)
      return #vim.tbl_filter(function(n)
        return n.msg:find(text, 1, true) ~= nil
      end, notes)
    end

    local function focused_agent()
      return terminal.bufnr() ~= nil and vim.api.nvim_get_current_buf() == terminal.bufnr()
    end

    ---Type `keys` (a ':' command line is then run as when typed: CmdlineLeave, then the command),
    ---without echoing the command line.
    local function type_keys(keys)
      vim.cmd(('silent call feedkeys(%s, "tx")'):format(vim.fn.string(vim.keycode(keys))))
    end

    ---Gemini's IDE mode, in the settings.json of the test's Gemini home (read when Gemini is
    ---launched). Without one it is off: the Gemini provider then never waits for a connection.
    local function gemini_ide(enabled)
      util.mkdir_p(tmp .. '/ghome/.gemini', tonumber('700', 8))
      write(tmp .. '/ghome/.gemini/settings.json', ('{"ide":{"enabled":%s}}'):format(tostring(enabled)))
    end

    ---What the Copilot or Gemini provider remembers of the last :AgentSend: the pid it is for, or
    ---false when it remembers nothing.
    local function context_pid(provider)
      local st = require('agent.providers.' .. provider)._state()
      if provider == 'copilot' then
        return st.context ~= nil and st.context.pid
      end
      return st.context ~= nil and st.context_pid
    end

    before_each(function()
      saved = { wait = agent.SEND_WAIT_MS, grace = agent.STARTUP_GRACE_MS, poll = agent.SEND_POLL_MS }
      stubs = {}
      -- The fake agents never connect: no notice and no startup grace unless a test says otherwise.
      agent.SEND_WAIT_MS, agent.STARTUP_GRACE_MS, agent.SEND_POLL_MS = 5000, 0, 20
      write(ws .. '/my file.txt', 'x\n')
    end)

    after_each(function()
      for i = #stubs, 1, -1 do
        local s = stubs[i]
        s[1][s[2]] = s[3]
      end
      vim.fn.confirm = orig_confirm
      pcall(vim.keymap.del, 'x', '<F9>')
      agent.SEND_WAIT_MS, agent.STARTUP_GRACE_MS, agent.SEND_POLL_MS = saved.wait, saved.grace, saved.poll
    end)

    it('goes through the provider to the IDE client in the agent terminal (its job pid), nothing typed', function()
      gemini_ide(true) -- else Gemini gets a typed reference
      for _, kind in ipairs(KINDS) do
        local c = client(PROVIDER[kind], true)
        agent.open(kind, { focus = false, confirm = false })
        wait_ready(kind)
        local pid = terminal.info().pid
        edit_in_main(ws .. '/a.txt')
        assert.same({ true, 'sent' }, { agent.send({ line1 = 3, line2 = 2 }) }, kind)
        assert.eq(1, #c.calls, kind)
        assert.same(for_agent(kind), c.calls[1].o, kind)
        assert.same({ ws .. '/a.txt', 2, 3, 'V', 'two\nthree' }, covers(c.calls[1].s), kind)
        -- No range: the file, as an empty selection at the cursor.
        edit_in_main(ws .. '/a.txt')
        assert.same({ true, 'sent' }, { agent.send() }, kind)
        assert.same(for_agent(kind), c.calls[2].o, kind)
        assert.same({ ws .. '/a.txt', 'n', '' }, { c.calls[2].s.path, c.calls[2].s.mode, c.calls[2].s.text }, kind)
        assert.eq(2, #c.tries, kind .. ': one attempt each')
        assert.truthy(#c.asked > 0, kind .. ': client_state() was asked')
        for _, o in ipairs(c.asked) do
          assert.same(for_agent(kind), o, kind .. ': client_state()')
        end
        vim.wait(100)
        assert.eq('', stdin_of(kind), kind .. ': nothing typed')
        assert.same({}, notes)
        agent.stop()
        wait_exited(pid)
      end
    end)

    it('sends the live Visual selection exactly, else the range, else the file; Visual mode ends', function()
      local c = client('claude', true)
      vim.keymap.set('x', '<F9>', '<cmd>AgentSend<cr>')
      agent.open('claude', { focus = false })
      wait_ready('claude')
      local pid = terminal.info().pid
      local a = edit_in_main(ws .. '/a.txt')
      local function last()
        return c.calls[#c.calls].s
      end
      -- Linewise, from Visual mode through a <cmd> mapping.
      vim.api.nvim_win_set_cursor(0, { 2, 0 })
      vim.api.nvim_feedkeys(vim.keycode('Vj'), 'x!', false)
      assert.eq('V', vim.api.nvim_get_mode().mode)
      vim.api.nvim_feedkeys(vim.keycode('<F9>'), 'x', false)
      assert.eq(1, #c.calls)
      assert.same({ ws .. '/a.txt', 2, 3, 'V', 'two\nthree' }, covers(last()))
      assert.eq(a, last().bufnr)
      assert.truthy(last().linewise)
      assert.same(for_agent('claude'), c.calls[1].o)
      assert.eq('nt', vim.api.nvim_get_mode().mode, 'Visual mode ended (Normal mode in the agent terminal)')
      assert.truthy(focused_agent())
      -- The '< and '> marks are the selection's, for gv.
      assert.same({ 2, 3 }, { vim.api.nvim_buf_get_mark(a, '<')[1], vim.api.nvim_buf_get_mark(a, '>')[1] })
      -- Charwise, upwards: the characters selected, not whole lines.
      edit_in_main(ws .. '/a.txt')
      vim.api.nvim_win_set_cursor(0, { 4, 1 })
      vim.api.nvim_feedkeys(vim.keycode('vkk'), 'x!', false)
      vim.api.nvim_feedkeys(vim.keycode('<F9>'), 'x', false)
      assert.same({ ws .. '/a.txt', 2, 4, 'v', 'wo\nthree\nfo' }, covers(last()))
      assert.same({ { line = 1, character = 1 }, { line = 3, character = 2 } }, { last().start, last().finish })
      -- Blockwise: the block.
      edit_in_main(ws .. '/a.txt')
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      vim.api.nvim_feedkeys(vim.keycode('<C-v>jjl'), 'x!', false)
      vim.api.nvim_feedkeys(vim.keycode('<F9>'), 'x', false)
      assert.same({ ws .. '/a.txt', 1, 3, '\22', 'on\ntw\nth' }, covers(last()))
      -- The '< and '> lines through vim.cmd() (not a ':' command line): those lines, even right
      -- after a charwise selection of them (a typed :'<,'>AgentSend is tested below).
      edit_in_main(ws .. '/a.txt')
      vim.api.nvim_win_set_cursor(0, { 1, 1 })
      vim.api.nvim_feedkeys(vim.keycode('vjl<Esc>'), 'x', false)
      vim.cmd("'<,'>AgentSend")
      assert.same({ ws .. '/a.txt', 1, 2, 'V', 'one\ntwo' }, covers(last()))
      assert.truthy(focused_agent())
      -- A range that is not the last Visual selection's lines: those lines.
      edit_in_main(ws .. '/a.txt')
      vim.cmd('2,3AgentSend')
      assert.same({ ws .. '/a.txt', 2, 3, 'V', 'two\nthree' }, covers(last()))
      edit_in_main(ws .. '/a.txt')
      vim.cmd('4AgentSend')
      assert.same({ ws .. '/a.txt', 4, 4, 'V', 'four' }, covers(last()))
      -- Neither: the file, as an empty selection at the cursor.
      edit_in_main(ws .. '/a.txt')
      vim.api.nvim_win_set_cursor(0, { 3, 2 })
      vim.cmd('AgentSend')
      assert.same({ ws .. '/a.txt', 3, 3, 'n', '' }, covers(last()))
      assert.truthy(last().is_empty)
      assert.same({ line = 2, character = 2 }, last().cursor)
      assert.eq(7, #c.calls)
      vim.wait(100)
      assert.eq('', stdin_of('claude'), 'nothing typed')
      assert.same({}, notes)
    end)

    it(":'<,'>AgentSend typed or from a ':' mapping in Visual mode: the selection as it was made", function()
      local c = client('claude', true)
      local sel = require('agent.editor.selection')
      -- ':' in Visual mode starts the command line with '<,'>.
      vim.keymap.set('x', '<F9>', ':AgentSend<CR>')
      write(ws .. '/b.txt', 'ab\nlonger\nc\n')
      agent.open('claude', { focus = false })
      wait_ready('claude')
      ---Select with `select` in `file` from the cursor `pos` (then CursorMoved, as the main loop runs
      ---it once typed keys have run; `nvim -l` does not), then type `keys`. With `cmd`, type it once
      ---the selection just left is no longer held by tracking (then the '< and '> marks tell it).
      ---Returns what was sent.
      local function run(file, pos, select, keys, cmd)
        edit_in_main(ws .. '/' .. file)
        vim.api.nvim_win_set_cursor(0, pos)
        local n = #c.calls
        vim.api.nvim_feedkeys(vim.keycode(select), 'x!', false)
        vim.api.nvim_exec_autocmds('CursorMoved', {})
        type_keys(keys)
        if cmd then
          vim.wait(sel.DEMOTE_MS + 100)
          type_keys(cmd)
        end
        assert.truthy(focused_agent(), select .. keys)
        assert.eq(n + 1, #c.calls, select .. keys)
        return covers(c.calls[#c.calls].s)
      end
      for _, how in ipairs({ ':AgentSend<CR>', '<F9>' }) do
        assert.same({ ws .. '/a.txt', 1, 2, 'v', 'ne\ntwo' }, run('a.txt', { 1, 1 }, 'vjl', how), how)
        assert.same({ ws .. '/a.txt', 1, 3, '\22', 'on\ntw\nth' }, run('a.txt', { 1, 0 }, '<C-v>jjl', how), how)
        -- A block made with $: to the end of every line.
        assert.same({ ws .. '/b.txt', 1, 3, '\22', 'ab\nlonger\nc' }, run('b.txt', { 1, 0 }, '<C-v>jj$', how), how)
        assert.same({ ws .. '/a.txt', 2, 3, 'V', 'two\nthree' }, run('a.txt', { 2, 1 }, 'Vj', how), how)
      end
      -- Typed once Visual mode has ended: :'<,'> and :* are the Visual area too.
      for _, range in ipairs({ "'<,'>", "'<, '>", '*' }) do
        local cmd = ':' .. range .. 'AgentSend<CR>'
        assert.same({ ws .. '/a.txt', 1, 2, 'v', 'ne\ntwo' }, run('a.txt', { 1, 1 }, 'vjl', '<Esc>' .. cmd), range)
        -- No longer held: from the marks, a block made with $ too.
        assert.same({ ws .. '/a.txt', 1, 2, 'v', 'ne\ntwo' }, run('a.txt', { 1, 1 }, 'vjl', '<Esc>', cmd), range)
        assert.same({ ws .. '/b.txt', 1, 3, '\22', 'ab\nlonger\nc' }, run('b.txt', { 1, 0 }, '<C-v>jj$', '<Esc>', cmd),
          range)
      end
      -- With 'virtualedit', where a block can end past its line without $: gv tells.
      vim.o.virtualedit = 'block'
      local ok, err = pcall(function()
        assert.same({ ws .. '/b.txt', 1, 3, '\22', 'ab\nlonger\nc' },
          run('b.txt', { 1, 0 }, '<C-v>jj$', ':AgentSend<CR>'))
        assert.same({ ws .. '/b.txt', 1, 3, '\22', 'ab\nlonger\nc' },
          run('b.txt', { 1, 0 }, '<C-v>jj$', '<Esc>', ":'<,'>AgentSend<CR>"))
        assert.same({ ws .. '/b.txt', 1, 3, '\22', 'ab\nlo\nc' },
          run('b.txt', { 1, 0 }, '<C-v>jjl', '<Esc>', ":'<,'>AgentSend<CR>"))
      end)
      vim.o.virtualedit = ''
      assert.truthy(ok, err)
      vim.wait(100)
      assert.eq('', stdin_of('claude'), 'nothing typed')
      assert.same({}, notes)
    end)

    it("another range is linewise, also right after a Visual selection or a typed :'<,'> command", function()
      local c = client('claude', true)
      write(ws .. '/b.txt', 'alpha beta\ngamma delta\n')
      agent.open('claude', { focus = false })
      wait_ready('claude')
      local function last()
        return covers(c.calls[#c.calls].s)
      end
      -- :.AgentSend typed after viwy: the line, not the word (the '< and '> marks are on it).
      edit_in_main(ws .. '/b.txt')
      vim.api.nvim_win_set_cursor(0, { 1, 7 })
      vim.api.nvim_feedkeys('viwy', 'x', false)
      assert.same({ 1, 7, 1, 10 }, { vim.fn.line("'<"), vim.fn.col("'<"), vim.fn.line("'>"), vim.fn.col("'>") })
      type_keys(':.AgentSend<CR>')
      assert.same({ ws .. '/b.txt', 1, 1, 'V', 'alpha beta' }, last())
      assert.truthy(focused_agent())
      -- :1AgentSend typed.
      edit_in_main(ws .. '/b.txt')
      type_keys(':1AgentSend<CR>')
      assert.same({ ws .. '/b.txt', 1, 1, 'V', 'alpha beta' }, last())
      -- vim.cmd() (as from a <cmd> mapping) and the Lua API, after a :'<,'> command typed from a
      -- Visual selection of the same line (the command history then ends with it): the line.
      for _, send in ipairs({
        function()
          vim.cmd('1AgentSend')
        end,
        function()
          assert.same({ true, 'sent' }, { agent.send({ line1 = 1 }) })
        end,
      }) do
        edit_in_main(ws .. '/b.txt')
        vim.api.nvim_win_set_cursor(0, { 1, 0 })
        type_keys('viw:s/alpha/alpha/<CR>')
        assert.eq("'<,'>s/alpha/alpha/", vim.fn.histget(':', -1))
        assert.same({ 1, 1 }, { vim.fn.line("'<"), vim.fn.line("'>") })
        vim.cmd('silent write')
        vim.wait(0) -- what the user does next runs in a later turn of the event loop
        local n = #c.calls
        send()
        assert.eq(n + 1, #c.calls)
        assert.same({ ws .. '/b.txt', 1, 1, 'V', 'alpha beta' }, last())
        assert.truthy(focused_agent())
      end
      -- Blank lines only: the file, as an empty selection at the range's first line.
      write(ws .. '/c.txt', 'x\n\n\ny\n')
      edit_in_main(ws .. '/c.txt')
      vim.api.nvim_win_set_cursor(0, { 4, 0 })
      vim.cmd('2,3AgentSend')
      assert.same({ ws .. '/c.txt', 2, 2, 'n', '' }, last())
      assert.truthy(c.calls[#c.calls].s.is_empty)
      assert.eq(5, #c.calls)
      vim.wait(100)
      assert.eq('', stdin_of('claude'), 'nothing typed')
      assert.same({}, notes)
    end)

    it('agent.send({ visual = true }) sends the Visual area as it was made when the range is its lines', function()
      local c = client('claude', true)
      local sel = require('agent.editor.selection')
      write(ws .. '/b.txt', 'ab\nlonger\nc\n')
      agent.open('claude', { focus = false })
      wait_ready('claude')
      local function send(file, pos, keys, range)
        edit_in_main(ws .. '/' .. file)
        vim.api.nvim_win_set_cursor(0, pos)
        vim.api.nvim_feedkeys(vim.keycode(keys), 'x', false)
        vim.wait(sel.DEMOTE_MS + 100) -- no longer held: the '< and '> marks
        assert.same({ true, 'sent' }, { agent.send(vim.tbl_extend('force', { visual = true }, range)) })
        return covers(c.calls[#c.calls].s)
      end
      assert.same({ ws .. '/a.txt', 2, 4, 'v', 'wo\nthree\nfo' },
        send('a.txt', { 4, 1 }, 'vkk<Esc>', { line1 = 2, line2 = 4 }))
      assert.same({ ws .. '/a.txt', 1, 3, '\22', 'on\ntw\nth' },
        send('a.txt', { 1, 0 }, '<C-v>jjl<Esc>', { line1 = 1, line2 = 3 }))
      -- A block made with $ ('virtualedit' is empty), the range upside down.
      assert.same({ ws .. '/b.txt', 1, 3, '\22', 'ab\nlonger\nc' },
        send('b.txt', { 1, 0 }, '<C-v>jj$<Esc>', { line1 = 3, line2 = 1 }))
      -- Other lines than the Visual area's: those lines.
      assert.same({ ws .. '/a.txt', 2, 4, 'V', 'two\nthree\nfour' },
        send('a.txt', { 2, 1 }, 'vjl<Esc>', { line1 = 2, line2 = 4 }))
      -- Without visual: those lines.
      edit_in_main(ws .. '/a.txt')
      vim.api.nvim_win_set_cursor(0, { 1, 1 })
      vim.api.nvim_feedkeys(vim.keycode('vjl<Esc>'), 'x', false)
      assert.same({ true, 'sent' }, { agent.send({ line1 = 1, line2 = 2 }) })
      assert.same({ ws .. '/a.txt', 1, 2, 'V', 'one\ntwo' }, covers(c.calls[#c.calls].s))
      assert.eq(5, #c.calls)
      assert.same({}, notes)
    end)

    it('a buffer that is not a file goes through the provider as its nvim://buffer/ id, not typed', function()
      gemini_ide(true) -- else Gemini gets a typed reference
      for _, name in ipairs({ 'claude', 'copilot', 'gemini' }) do
        local c = client(name, true)
        agent.open(name, { focus = false, confirm = false })
        wait_ready(name)
        local pid = terminal.info().pid
        edit_in_main(ws .. '/a.txt')
        vim.cmd('enew')
        local job = vim.fn.jobstart({ 'sh', '-c', 'echo one; echo two; exec sleep 30' }, { term = true })
        local shell = vim.api.nvim_get_current_buf()
        local shell_win = vim.api.nvim_get_current_win()
        wait_for(function()
          return vim.deep_equal({ 'one', 'two' }, vim.api.nvim_buf_get_lines(shell, 0, 2, false))
        end, 5000, 'the shell output')
        local id = ('nvim://buffer/%d/sh'):format(shell)
        vim.cmd('1,2AgentSend')
        assert.truthy(focused_agent())
        assert.eq(1, #c.calls, name)
        assert.same(for_agent(name), c.calls[1].o, name)
        assert.same({ id, 1, 2, 'V', 'one\ntwo' }, covers(c.calls[1].s), name)
        -- No range: the buffer, as an empty selection pinned to its start.
        vim.api.nvim_set_current_win(shell_win)
        vim.api.nvim_win_set_cursor(0, { 2, 1 })
        vim.cmd('AgentSend')
        assert.same({ id, 1, 1, 'n', '' }, covers(c.calls[2].s), name)
        assert.same({ line = 0, character = 0 }, c.calls[2].s.cursor, name)
        -- A scratch buffer.
        vim.api.nvim_set_current_win(shell_win)
        vim.cmd('enew')
        local scratch = vim.api.nvim_get_current_buf()
        vim.api.nvim_buf_set_lines(scratch, 0, -1, false, { 'a', 'b', 'c' })
        vim.cmd('3AgentSend')
        assert.same({ ('nvim://buffer/%d/scratch'):format(scratch), 3, 3, 'V', 'c' }, covers(c.calls[3].s), name)
        vim.wait(100)
        assert.eq('', stdin_of(name), name .. ': nothing typed')
        vim.fn.jobstop(job)
        vim.api.nvim_set_current_win(shell_win)
        vim.cmd('silent! bwipeout! ' .. shell .. ' ' .. scratch)
        agent.stop()
        wait_exited(pid)
      end
      assert.same({}, notes)
    end)

    it('focuses the agent terminal: shows it when hidden, starts default_agent when none runs', function()
      setup({ default_agent = 'copilot' })
      local c = client('copilot', true)
      local a = edit_in_main(ws .. '/a.txt')
      local main = vim.api.nvim_get_current_win()
      assert.falsy(terminal.is_running())
      vim.cmd('AgentSend')
      assert.eq('copilot', terminal.name(), 'default_agent was started')
      assert.truthy(focused_agent())
      assert.eq(1, #c.calls)
      assert.same({ ws .. '/a.txt', 'n' }, { c.calls[1].s.path, c.calls[1].s.mode })
      assert.same(for_agent('copilot'), c.calls[1].o)
      -- Hidden: shown again and focused.
      vim.cmd('AgentClose')
      assert.falsy(terminal.is_visible())
      assert.eq(main, vim.api.nvim_get_current_win())
      vim.cmd('2AgentSend')
      assert.truthy(terminal.is_visible())
      assert.truthy(focused_agent())
      assert.same({ ws .. '/a.txt', 2, 2, 'V', 'two' }, covers(c.calls[2].s))
      -- Visible but not focused: focused.
      vim.api.nvim_set_current_win(main)
      assert.eq(a, vim.api.nvim_get_current_buf())
      vim.cmd('AgentSend')
      assert.truthy(focused_agent())
      assert.eq(1, #vim.fn.win_findbuf(terminal.bufnr()), 'one window')
      assert.eq(3, #c.calls)
      assert.same({}, notes)
    end)

    it('refuses the agent terminal, a diff buffer, a floating window and an ignored buffer', function()
      local c = client('claude', true)
      local function refused(text)
        local n = noted(text)
        local win = vim.api.nvim_get_current_win()
        local running = terminal.is_running() and terminal.info().pid
        vim.cmd('AgentSend')
        vim.cmd('1AgentSend')
        assert.eq(n + 2, noted(text), text)
        assert.eq(vim.log.levels.WARN, notes[#notes].level)
        assert.eq(win, vim.api.nvim_get_current_win(), 'the focus stays')
        assert.eq(running, terminal.is_running() and terminal.info().pid, 'no agent started or stopped')
      end
      -- No agent yet: nothing is started.
      edit_in_main(ws .. '/a.txt')
      local diff = require('agent.editor.diff')
      assert.truthy(diff.open({ id = 'd1', path = ws .. '/a.txt', new_contents = 'new\n', on_resolve = function() end }))
      assert.truthy(vim.startswith(vim.api.nvim_buf_get_name(0), 'agent-diff://'))
      refused('nothing to send from a diff buffer')
      diff.reject_current()
      edit_in_main(ws .. '/a.txt')
      local float = vim.api.nvim_open_win(vim.api.nvim_get_current_buf(), true,
        { relative = 'editor', row = 1, col = 1, width = 30, height = 3 })
      refused('nothing to send from a floating window')
      vim.api.nvim_win_close(float, true)
      vim.cmd('enew')
      vim.b.agent_ignore = true
      refused('nothing to send: agent.nvim ignores this buffer')
      assert.falsy(terminal.is_running())
      -- From the agent's own terminal.
      agent.open('claude')
      wait_ready('claude')
      assert.truthy(focused_agent())
      refused('nothing to send from the agent terminal')
      vim.wait(100)
      assert.eq('', stdin_of('claude'))
      assert.eq(0, #c.tries, 'nothing sent')
      -- The Lua API returns the reason.
      assert.same({ false, 'nothing to send from the agent terminal: run :AgentSend in a file or another buffer' },
        { agent.send() })
    end)

    it('another agent than the running one goes through the replace question', function()
      local k, p = client('claude', true), client('copilot', true)
      agent.open('claude', { focus = false })
      wait_ready('claude')
      local pid = terminal.info().pid
      local asked = 0
      vim.fn.confirm = function()
        asked = asked + 1
        return 2
      end
      edit_in_main(ws .. '/a.txt')
      vim.cmd('AgentSend copilot')
      assert.eq(1, asked)
      assert.eq(pid, terminal.info().pid, 'declined: claude runs on')
      assert.same({}, notes, 'no message for a declined replace')
      assert.same({ 0, 0 }, { #k.tries, #p.tries }, 'nothing sent')
      vim.fn.confirm = function()
        asked = asked + 1
        return 1
      end
      vim.cmd('2AgentSend copilot')
      assert.eq(2, asked)
      assert.eq('copilot', terminal.name())
      assert.truthy(focused_agent())
      assert.eq(1, #p.calls)
      assert.same(for_agent('copilot'), p.calls[1].o)
      assert.same({ ws .. '/a.txt', 2, 2, 'V', 'two' }, covers(p.calls[1].s))
      -- Without a name: the running agent, never asked.
      edit_in_main(ws .. '/a.txt')
      vim.cmd('3AgentSend')
      assert.eq(2, asked)
      assert.eq(2, #p.calls)
      assert.same({ ws .. '/a.txt', 3, 3, 'V', 'three' }, covers(p.calls[2].s))
      assert.eq(0, #k.tries, 'never to claude')
      vim.wait(100)
      assert.eq('', stdin_of('claude') .. stdin_of('copilot'), 'nothing typed')
      wait_exited(pid)
    end)

    it('waits for the IDE connection however long it takes, retrying, with one notice after SEND_WAIT_MS', function()
      -- Nothing is typed meanwhile (a dialog, such as Claude's folder trust question, may hold the
      -- screen), for Gemini too once its IDE mode is on.
      agent.SEND_WAIT_MS = 400
      gemini_ide(true)
      for _, name in ipairs(KINDS) do
        local c = client(PROVIDER[name], false)
        notes = {}
        edit_in_main(ws .. '/a.txt')
        local t0 = util.now_ms()
        assert.same({ true, 'pending' }, { agent.send({ name = name, line1 = 1, line2 = 2, confirm = false }) })
        assert.eq(1, #c.tries, name .. ': tried at once')
        assert.eq(0, #notes, name .. ': no notice before SEND_WAIT_MS')
        wait_ready(name)
        local pid = terminal.info().pid
        if name == 'gemini' then
          assert.eq(false, require('agent.providers.gemini').ide_mode_off())
        end
        wait_for(function()
          return noted(name .. waiting) == 1
        end, 3000, name .. ': the notice')
        assert.truthy(util.now_ms() - t0 >= 400, name .. ': the notice once SEND_WAIT_MS is over')
        local n = #c.tries
        vim.wait(300)
        assert.truthy(#c.tries > n, name .. ': send_context is retried')
        assert.eq(0, #c.calls)
        assert.eq('', stdin_of(name), name .. ': nothing typed while it is not connected')
        assert.eq(1, #notes, name .. ': one notice')
        assert.eq('agent.nvim: ' .. name .. waiting, notes[1].msg)
        c.ready = true
        wait_for(function()
          return #c.calls == 1
        end, 2000, name .. ': sent once connected')
        assert.same(for_agent(name), c.calls[1].o, name)
        assert.same({ ws .. '/a.txt', 1, 2, 'V', 'one\ntwo' }, covers(c.calls[1].s), name)
        for _, o in ipairs(c.asked) do
          assert.same(for_agent(name), o, name .. ': client_state()')
        end
        n = #c.tries
        vim.wait(200)
        assert.eq(n, #c.tries, name .. ': no attempt once delivered')
        assert.eq(1, #c.calls, name)
        assert.eq('', stdin_of(name), name .. ': nothing typed')
        assert.eq(1, #notes)
        agent.stop()
        wait_exited(pid)
      end
    end)

    it('the notice: at once for an agent started long ago, SEND_WAIT_MS after the send while it connects', function()
      agent.SEND_WAIT_MS = 300
      local c = client('claude', false)
      agent.open('claude', { focus = false })
      wait_ready('claude')
      vim.wait(400) -- started longer ago than SEND_WAIT_MS
      -- Its client is connecting: the wait starts now.
      c.state = 'connecting'
      edit_in_main(ws .. '/a.txt')
      local t0 = util.now_ms()
      assert.same({ true, 'pending' }, { agent.send({ line1 = 1 }) })
      assert.same({}, notes)
      wait_for(function()
        return noted('claude' .. waiting) == 1
      end, 3000, 'the notice')
      assert.truthy(util.now_ms() - t0 >= 300, 'the notice once SEND_WAIT_MS after the send is over')
      -- Once for the agent: not for another send to it.
      edit_in_main(ws .. '/a.txt')
      assert.same({ true, 'pending' }, { agent.send({ line1 = 2 }) })
      vim.wait(500)
      assert.eq(1, #notes)
      c.ready = true
      wait_for(function()
        return #c.calls == 1
      end, 2000, 'sent once connected')
      assert.eq(2, c.calls[1].s.start_line, 'the newer one')
      -- Delivered, then not connected (a restarted client): the notice again, at once.
      c.ready, c.state = false, nil
      edit_in_main(ws .. '/a.txt')
      assert.same({ true, 'pending' }, { agent.send({ line1 = 3 }) })
      assert.eq(2, noted('claude' .. waiting))
      assert.eq(2, #notes)
      vim.wait(100)
      assert.eq('', stdin_of('claude'), 'nothing typed')
    end)

    it('a newer :AgentSend replaces the one waiting: only the newer is sent', function()
      local c = client('claude', false)
      edit_in_main(ws .. '/a.txt')
      assert.same({ true, 'pending' }, { agent.send({ line1 = 1 }) })
      wait_ready('claude')
      vim.wait(100)
      edit_in_main(ws .. '/a.txt')
      assert.same({ true, 'pending' }, { agent.send({ line1 = 3 }) })
      local n = #c.tries
      assert.eq(3, c.tries[n].start_line)
      vim.wait(100)
      c.ready = true
      wait_for(function()
        return #c.calls == 1
      end, 2000, 'sent once connected')
      vim.wait(200)
      assert.eq(1, #c.calls, 'the older one is not sent')
      assert.same({ ws .. '/a.txt', 3, 3, 'V', 'three' }, covers(c.calls[1].s))
      for i = n, #c.tries do
        assert.eq(3, c.tries[i].start_line, 'only the newer is tried')
      end
      assert.eq('', stdin_of('claude'))
      assert.same({}, notes)
    end)

    it('what waits for an agent that is replaced is dropped', function()
      agent.SEND_WAIT_MS = 1000
      local k, p = client('claude', false), client('copilot', true)
      edit_in_main(ws .. '/a.txt')
      assert.same({ true, 'pending' }, { agent.send() })
      wait_ready('claude')
      local pid = terminal.info().pid
      assert.truthy(agent.open('copilot', { confirm = false, focus = false }))
      wait_exited(pid)
      wait_ready('copilot')
      local n = #k.tries
      vim.wait(1200) -- past the wait: no notice either
      assert.eq(n, #k.tries, 'no longer tried')
      assert.eq(0, #p.tries, 'not sent to the new agent')
      assert.eq('', stdin_of('copilot'))
      assert.eq('', stdin_of('claude'))
      assert.same({}, notes, 'and no notice for it')
    end)

    it('what waits for an agent that stops is dropped, also for the next agent of that kind', function()
      edit_in_main(ws .. '/a.txt')
      local c = client('claude', false)
      c.state = 'connecting'
      assert.same({ true, 'pending' }, { agent.send() })
      wait_ready('claude')
      local pid = terminal.info().pid
      agent.stop()
      wait_exited(pid)
      local n = #c.tries
      vim.wait(300)
      assert.eq(n, #c.tries, 'no longer tried')
      c.ready = true
      agent.open('claude', { focus = false })
      vim.wait(300)
      assert.eq(0, #c.calls, 'not sent to the new claude')
      assert.eq(n, #c.tries)
      assert.eq('', stdin_of('claude'))
      assert.same({}, notes)
    end)

    it('an agent that stops, is replaced or exits: its provider forgets what was sent (clear_context(pid))', function()
      gemini_ide(true)
      local cleared = {}
      for _, name in ipairs({ 'claude', 'copilot', 'gemini' }) do
        stub(name, {
          clear_context = function(pid)
            cleared[#cleared + 1] = { name, pid }
          end,
        })
      end
      local function cleared_are(want, msg)
        wait_for(function()
          return #cleared >= #want
        end, 5000, msg)
        vim.wait(50)
        assert.same(want, cleared, msg)
      end
      -- Stopped: at once, and again when its job has exited.
      agent.open('claude', { focus = false })
      wait_ready('claude')
      local pid = terminal.info().pid
      agent.stop()
      assert.same({ { 'claude', pid } }, cleared, 'at once')
      wait_exited(pid)
      cleared_are({ { 'claude', pid }, { 'claude', pid } }, 'and from its on_exit')
      -- Replaced: the old agent's provider and pid, never the new agent's.
      cleared = {}
      agent.open('gemini', { focus = false })
      wait_ready('gemini')
      pid = terminal.info().pid
      assert.truthy(agent.open('opencode', { focus = false, confirm = false }))
      assert.same({ { 'gemini', pid } }, cleared, 'at once')
      wait_ready('opencode')
      wait_exited(pid)
      cleared_are({ { 'gemini', pid }, { 'gemini', pid } }, 'and from its on_exit')
      local oc = terminal.info().pid
      agent.stop()
      wait_exited(oc)
      cleared_are({ { 'gemini', pid }, { 'gemini', pid }, { 'claude', oc }, { 'claude', oc } }, 'opencode: claude')
      -- Exited on its own: from its on_exit.
      cleared = {}
      agent.open('copilot', { focus = false, env = { FAKE_AGENT_EXIT = '0', FAKE_AGENT_SLEEP = '1' } })
      pid = terminal.info().pid
      wait_ready('copilot')
      assert.same({}, cleared, 'running')
      wait_for(function()
        return terminal.info() == nil
      end, 5000, 'copilot exited')
      cleared_are({ { 'copilot', pid } }, 'from its on_exit')
      assert.same({}, notes)
    end)

    it('Copilot and Gemini forget what was sent only to the agent that ended (auto_start)', function()
      -- Agents that take a second to exit once stopped, so that the old job's exit comes after the
      -- next agent was started and sent to.
      local slow = tmp .. '/slow_agent.sh'
      write(slow, table.concat({
        '#!/bin/sh',
        "trap '' HUP",
        "trap 'sleep 1; exit 0' TERM",
        'env > "$FAKE_AGENT_OUT.env"',
        'while :; do sleep 0.1; done',
        '',
      }, '\n'))
      uv.fs_chmod(slow, tonumber('755', 8))
      gemini_ide(true) -- else Gemini gets a typed reference
      setup({ auto_start = true, agents = { copilot = { cmd = { slow } }, gemini = { cmd = { slow } } } })
      -- The real providers remember what is sent; it counts as delivered at once, so that nothing
      -- sends it again (each retry of a send that waits remembers it again).
      for _, name in ipairs({ 'copilot', 'gemini' }) do
        local send_context = require('agent.providers.' .. name).send_context
        stub(name, {
          send_context = function(s, o)
            send_context(s, o)
            return true
          end,
        })
      end
      for _, name in ipairs({ 'copilot', 'gemini' }) do
        edit_in_main(ws .. '/a.txt')
        assert.same({ true, 'sent' }, { agent.send({ name = name, line1 = 2, confirm = false }) }, name)
        wait_ready(name)
        local old = terminal.info().pid
        assert.eq(old, context_pid(name), name .. ': remembered for its client')
        agent.stop()
        assert.eq(false, context_pid(name), name .. ': forgotten once it stops')
        -- Started again and sent to before the old job has exited: its exit forgets nothing.
        edit_in_main(ws .. '/a.txt')
        assert.same({ true, 'sent' }, { agent.send({ name = name, line1 = 3 }) }, name)
        local new = terminal.info().pid
        assert.truthy(new ~= old)
        assert.eq(new, context_pid(name), name)
        assert.truthy(pid_alive(old), name .. ': the old job has not exited yet')
        wait_exited(old)
        assert.eq(new, context_pid(name), name .. ': kept when the old job exits')
        agent.stop()
        wait_exited(new)
        assert.eq(false, context_pid(name), name)
        assert.truthy(require('agent.providers.' .. name).is_running(), name .. ' runs on (auto_start)')
      end
      assert.eq(0, noted(waiting))
    end)

    it("two OpenCodes cannot be told apart ('ambiguous'): typed once SEND_WAIT_MS is over, no notice", function()
      agent.SEND_WAIT_MS = 600
      local c = client('claude', false)
      c.state = 'ambiguous'
      edit_in_main(ws .. '/a.txt')
      local t0 = util.now_ms()
      assert.same({ true, 'pending' }, { agent.send({ name = 'opencode', line1 = 1, line2 = 2 }) })
      assert.eq(1, #c.tries, 'tried through the provider at once')
      wait_ready('opencode')
      local pid = terminal.info().pid
      vim.wait(150)
      assert.eq('', stdin_of('opencode'), 'nothing typed before SEND_WAIT_MS')
      assert.truthy(#c.tries > 1, 'the provider is tried meanwhile')
      wait_stdin('opencode', pasted('@a.txt#1-2 '))
      assert.truthy(util.now_ms() - t0 >= 600, 'typed once SEND_WAIT_MS was over')
      assert.eq(0, #c.calls)
      -- Started longer ago than SEND_WAIT_MS: typed at once, after one try through the provider.
      edit_in_main(ws .. '/a.txt')
      local n = #c.tries
      assert.same({ true, 'typed' }, { agent.send({ line1 = 3 }) })
      assert.eq(n + 1, #c.tries)
      wait_stdin('opencode', pasted('@a.txt#1-2 ') .. pasted('@a.txt#3 '))
      -- Its client is ready after all: through the provider.
      c.ready = true
      edit_in_main(ws .. '/a.txt')
      assert.same({ true, 'sent' }, { agent.send({ line1 = 4 }) })
      assert.same(for_agent('opencode'), c.calls[1].o)
      assert.same({ ws .. '/a.txt', 4, 4, 'V', 'four' }, covers(c.calls[1].s))
      vim.wait(100)
      assert.eq(pasted('@a.txt#1-2 ') .. pasted('@a.txt#3 '), stdin_of('opencode'))
      assert.same({}, notes, 'no notice')
    end)

    it('Gemini with its IDE mode off: never through the provider, typed after STARTUP_GRACE_MS, no notice', function()
      gemini_ide(false)
      agent.SEND_WAIT_MS, agent.STARTUP_GRACE_MS = 200, 500
      -- Another Gemini is connected (one started outside Neovim): the agent's never connects, and
      -- the other one does not get what is sent to it.
      local c = client('gemini', true)
      edit_in_main(ws .. '/a.txt')
      local t0 = util.now_ms()
      assert.same({ true, 'pending' }, { agent.send({ name = 'gemini', line1 = 2, line2 = 3 }) })
      assert.eq(true, require('agent.providers.gemini').ide_mode_off(), 'found off when it was launched')
      wait_ready('gemini')
      wait_stdin('gemini', pasted('@a.txt (lines 2-3) '))
      assert.truthy(util.now_ms() - t0 >= 500, 'typed once the grace was over')
      -- Then at once.
      edit_in_main(ws .. '/my file.txt')
      assert.same({ true, 'typed' }, { agent.send() })
      wait_stdin('gemini', pasted('@my\\ file.txt '))
      edit_in_main(ws .. '/a.txt')
      assert.same({ true, 'typed' }, { agent.send({ line1 = 4 }) })
      wait_stdin('gemini', pasted('@a.txt (line 4) '))
      vim.wait(300) -- past SEND_WAIT_MS
      assert.eq(0, #c.tries, 'send_context() was never called')
      assert.eq(pasted('@a.txt (lines 2-3) ') .. pasted('@my\\ file.txt ') .. pasted('@a.txt (line 4) '),
        stdin_of('gemini'))
      assert.eq(0, noted(waiting), 'no notice')
    end)

    it('selection.track = true: another tracked selection drops what waits, the same one does not', function()
      local sel = require('agent.editor.selection')
      local c = client('claude', false)
      local events = {}
      stub('claude', {
        on_selection = function(s)
          events[#events + 1] = s
        end,
      })
      setup({ selection = { debounce_ms = 20 } })
      agent.open('claude', { focus = false })
      wait_ready('claude')
      local a = edit_in_main(ws .. '/a.txt')
      local main = vim.api.nvim_get_current_win()
      sel.flush()
      assert.same({ true, 'pending' }, { agent.send({ line1 = 2, line2 = 3 }) })
      local m = agent._state.pending
      assert.same({ ws .. '/a.txt', 2, 3, 'V', 'two\nthree' }, covers(m.selection))
      -- selection.track = false (the default): the selection moves on, and it still waits.
      vim.api.nvim_set_current_win(main)
      vim.api.nvim_win_set_cursor(0, { 4, 0 })
      sel.flush()
      assert.eq(4, sel.current().start_line)
      assert.eq(m, agent._state.pending, 'kept with selection.track = false')
      assert.eq(0, #events, 'nothing forwarded')
      -- selection.track = true: the same selection keeps it...
      setup({ selection = { track = true, debounce_ms = 20 } })
      vim.api.nvim_win_set_cursor(0, { 2, 0 })
      vim.api.nvim_feedkeys(vim.keycode('Vj'), 'x!', false)
      sel.flush()
      assert.same({ ws .. '/a.txt', 2, 3, 'V', 'two\nthree' }, covers(events[#events]))
      assert.eq(a, events[#events].bufnr)
      assert.eq(m, agent._state.pending, 'the same selection keeps it')
      -- ... and another one drops it: the agent gets the newer one (on_selection), not the older.
      vim.api.nvim_feedkeys('j', 'x!', false)
      sel.flush()
      assert.same({ ws .. '/a.txt', 2, 4, 'V', 'two\nthree\nfour' }, covers(events[#events]))
      assert.eq(nil, agent._state.pending, 'dropped')
      vim.api.nvim_feedkeys(vim.keycode('<Esc>'), 'x', false)
      local n = #c.tries
      c.ready = true
      vim.wait(200)
      assert.eq(n, #c.tries, 'no longer tried')
      assert.eq(0, #c.calls, 'never sent')
      assert.eq('', stdin_of('claude'))
      assert.same({}, notes)
    end)

    it('selection.track = true: the :AgentSend that starts the agent outlives the first selection event', function()
      setup({ selection = { track = true, debounce_ms = 20 } })
      local sel = require('agent.editor.selection')
      local c = client('claude', false)
      local events = {}
      stub('claude', {
        on_selection = function(s)
          events[#events + 1] = s
        end,
      })
      edit_in_main(ws .. '/a.txt')
      vim.api.nvim_win_set_cursor(0, { 4, 1 })
      assert.falsy(sel.is_running(), 'no provider runs yet: no tracking')
      -- Tracking starts with the agent's provider, its first event (the cursor on line 4) waiting
      -- for the debounce: it is older than the send, so it does not replace it.
      assert.same({ true, 'pending' }, { agent.send({ line1 = 2, line2 = 3 }) })
      assert.truthy(sel.is_running(), 'started with the agent')
      local m = agent._state.pending
      assert.truthy(m)
      assert.same({ ws .. '/a.txt', 2, 3, 'V', 'two\nthree' }, covers(m.selection))
      wait_ready('claude')
      vim.wait(200) -- well past the debounce
      assert.eq(m, agent._state.pending, 'still waiting')
      assert.truthy(#events >= 1)
      for _, s in ipairs(events) do
        assert.same({ ws .. '/a.txt', 4, 4, 'n', '' }, covers(s), 'only the cursor, before the send')
      end
      c.ready = true
      wait_for(function()
        return #c.calls == 1
      end, 2000, 'sent once connected')
      assert.same(for_agent('claude'), c.calls[1].o)
      assert.same({ ws .. '/a.txt', 2, 3, 'V', 'two\nthree' }, covers(c.calls[1].s))
      vim.wait(100)
      assert.eq(1, #c.calls)
      assert.eq(nil, agent._state.pending)
      assert.eq('', stdin_of('claude'))
      assert.same({}, notes)
    end)

    it('with its IDE server disabled: a reference typed in the agent\'s own syntax after STARTUP_GRACE_MS', function()
      setup({ providers = { claude = { enabled = false }, copilot = { enabled = false },
        gemini = { enabled = false } } })
      local ref = agent._reference
      local cases = {
        claude = { { 2, 4, '@a.txt#L2-4' }, { 3, 3, '@a.txt#L3' }, { nil, nil, '@a.txt' } },
        opencode = { { 2, 4, '@a.txt#2-4' }, { 3, 3, '@a.txt#3' }, { nil, nil, '@a.txt' } },
        copilot = { { 2, 4, '@a.txt:2-4' }, { 3, 3, '@a.txt:3' }, { nil, nil, '@a.txt' } },
        gemini = { { 2, 4, '@a.txt (lines 2-4)' }, { 3, 3, '@a.txt (line 3)' }, { nil, nil, '@a.txt' } },
      }
      for kind, list in pairs(cases) do
        for _, c in ipairs(list) do
          assert.eq(c[3], ref(kind, ws .. '/a.txt', c[1], c[2], ws), kind)
        end
        -- A buffer that is not a file: its id, for every agent.
        assert.eq('nvim://buffer/7/sh lines 1-2', ref(kind, 'nvim://buffer/7/sh', 1, 2, ws))
        assert.eq('nvim://buffer/7/sh line 4', ref(kind, 'nvim://buffer/7/sh', 4, 4, ws))
        assert.eq('nvim://buffer/7/sh', ref(kind, 'nvim://buffer/7/sh', nil, nil, ws))
      end
      -- Gemini escapes spaces; paths outside the agent's cwd stay absolute.
      assert.eq('@my\\ file.txt', ref('gemini', ws .. '/my file.txt', nil, nil, ws))
      assert.eq('@' .. tmp .. '/out.txt:1-2', ref('copilot', tmp .. '/out.txt', 1, 2, ws))

      -- Through :AgentSend, for each kind: once the terminal is STARTUP_GRACE_MS old, then at once.
      agent.STARTUP_GRACE_MS = 400
      local sent = { claude = { '@a.txt#L2-3', '@a.txt' }, opencode = { '@a.txt#2-3', '@a.txt' },
        copilot = { '@a.txt:2-3', '@a.txt' }, gemini = { '@a.txt (lines 2-3)', '@my\\ file.txt' } }
      for _, kind in ipairs(KINDS) do
        edit_in_main(ws .. '/a.txt')
        local t0 = util.now_ms()
        assert.same({ true, 'pending' }, { agent.send({ name = kind, line1 = 2, line2 = 3, confirm = false }) })
        wait_ready(kind)
        wait_stdin(kind, pasted(sent[kind][1] .. ' '))
        assert.truthy(util.now_ms() - t0 >= 400, kind .. ': typed once the grace was over')
        edit_in_main(kind == 'gemini' and ws .. '/my file.txt' or ws .. '/a.txt')
        assert.same({ true, 'typed' }, { agent.send() }, kind)
        wait_stdin(kind, pasted(sent[kind][2] .. ' '))
        local pid = terminal.info().pid
        -- A buffer that is not a file: typed as its id.
        if kind == 'claude' then
          edit_in_main(ws .. '/a.txt')
          vim.cmd('enew')
          local scratch = vim.api.nvim_get_current_buf()
          vim.api.nvim_buf_set_lines(scratch, 0, -1, false, { 'a', 'b', 'c' })
          local scratch_win = vim.api.nvim_get_current_win()
          vim.cmd('2,3AgentSend')
          wait_stdin(kind, pasted(('nvim://buffer/%d/scratch lines 2-3 '):format(scratch)))
          vim.api.nvim_set_current_win(scratch_win)
          vim.cmd('AgentSend')
          wait_stdin(kind, pasted(('nvim://buffer/%d/scratch '):format(scratch)))
          vim.api.nvim_set_current_win(scratch_win)
          vim.cmd('silent! bwipeout! ' .. scratch)
        end
        agent.stop()
        wait_exited(pid)
      end
      assert.same({}, notes)
    end)

    it('terminal.layout = none: sent to a connected agent started by hand, else a clear error', function()
      setup({ terminal = { layout = 'none' }, auto_start = true })
      edit_in_main(ws .. '/a.txt')
      local win = vim.api.nvim_get_current_win()
      -- The providers run, and no agent is connected: no provider remembers what was not sent (a
      -- client that connects later is not the one it was for).
      for _, kind in ipairs(KINDS) do
        assert.same({ false, ('no %s is connected to Neovim to send it to (terminal.layout is "none")'):format(kind) },
          { agent.send({ name = kind, line1 = 1 }) })
      end
      assert.eq(false, context_pid('copilot'))
      assert.eq(false, context_pid('gemini'))
      local c, g = client('claude', true), client('gemini', true)
      assert.same({ true, 'sent' }, { agent.send({ line1 = 1 }) })
      assert.same({ kind = 'claude' }, c.calls[1].o, 'no pid: no agent.nvim terminal')
      assert.same({ ws .. '/a.txt', 1, 1, 'V', 'one' }, covers(c.calls[1].s))
      assert.same({ true, 'sent' }, { agent.send({ name = 'gemini' }) })
      assert.same({ kind = 'gemini' }, g.calls[1].o)
      assert.same({ ws .. '/a.txt', 'n' }, { g.calls[1].s.path, g.calls[1].s.mode })
      -- A buffer that is not a file too.
      vim.cmd('enew')
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'x' })
      assert.same({ true, 'sent' }, { agent.send({ line1 = 1 }) })
      assert.same({ ('nvim://buffer/%d/scratch'):format(vim.api.nvim_get_current_buf()), 1, 1, 'V', 'x' },
        covers(c.calls[2].s))
      c.ready = false
      assert.same({ false, 'no claude is connected to Neovim to send it to (terminal.layout is "none")' },
        { agent.send() })
      assert.eq(2, #c.calls)
      assert.eq(win, vim.api.nvim_get_current_win(), 'the focus stays')
      assert.falsy(terminal.is_running(), 'nothing was started')
      assert.same({}, notes)
    end)

    it('terminal.layout = none: send_context is called only when the client is ready', function()
      setup({ terminal = { layout = 'none' }, auto_start = true })
      edit_in_main(ws .. '/a.txt')
      for _, kind in ipairs(KINDS) do
        local c = client(PROVIDER[kind], false)
        local err = ('no %s is connected to Neovim to send it to (terminal.layout is "none")'):format(kind)
        for _, state in ipairs({ 'none', 'connecting', 'ambiguous' }) do
          c.state = state ~= 'none' and state or nil
          assert.same({ false, err }, { agent.send({ name = kind, line1 = 2 }) }, kind .. ': ' .. state)
        end
        assert.eq(0, #c.tries, kind .. ': send_context was not called')
        c.ready = true
        assert.same({ true, 'sent' }, { agent.send({ name = kind, line1 = 2 }) }, kind)
        assert.eq(1, #c.tries, kind)
        assert.same({ kind = kind }, c.calls[1].o, kind)
        assert.same({ ws .. '/a.txt', 2, 2, 'V', 'two' }, covers(c.calls[1].s), kind)
      end
      vim.wait(100)
      assert.falsy(terminal.is_running(), 'nothing was started')
      assert.same({}, notes)
    end)

    it('terminal.layout = none with selection.track: the Visual selection sent stays (the focus stays in the file)', function()
      setup({ terminal = { layout = 'none' }, auto_start = true, selection = { track = true } })
      local sel = require('agent.editor.selection')
      assert.truthy(sel.is_running())
      local c = client('claude', true)
      edit_in_main(ws .. '/a.txt')
      vim.api.nvim_win_set_cursor(0, { 1, 1 })
      type_keys('vj:AgentSend<CR>')
      assert.eq(1, #c.calls)
      assert.same({ ws .. '/a.txt', 1, 2, 'v', 'ne\ntw' }, covers(c.calls[1].s))
      vim.wait(sel.DEMOTE_MS + 250)
      -- The grace period after Visual mode is over: tracking still has the selection sent.
      local s = sel.current()
      assert.same({ 'v', 'ne\ntw' }, { s.mode, s.text })
      -- Until the cursor moves.
      vim.api.nvim_win_set_cursor(0, { 3, 0 })
      assert.eq('n', sel.current().mode)
      assert.same({}, notes)
    end)

    it(":'<,'> is read from the command line once: a range run right after by vim.cmd() is linewise", function()
      local c = client('claude', true)
      agent.open('claude', { focus = false })
      wait_ready('claude')
      edit_in_main(ws .. '/a.txt')
      vim.api.nvim_win_set_cursor(0, { 1, 1 })
      -- In one run of keys, with no event-loop turn between (a mapping, a macro).
      type_keys('vj:AgentSend<CR>')
      edit_in_main(ws .. '/a.txt')
      vim.cmd('1,2AgentSend')
      assert.eq(2, #c.calls)
      assert.same({ 'v', 'ne\ntw' }, { c.calls[1].s.mode, c.calls[1].s.text })
      assert.same({ 'V', 'one\ntwo' }, { c.calls[2].s.mode, c.calls[2].s.text })
      -- Another command over the Visual area (not recorded), then a range run by vim.cmd().
      edit_in_main(ws .. '/a.txt')
      vim.api.nvim_win_set_cursor(0, { 1, 1 })
      type_keys("vj:s/one/one/e<CR>")
      vim.cmd('1,2AgentSend')
      assert.same({ 'V', 'one\ntwo' }, { c.calls[3].s.mode, c.calls[3].s.text })
    end)
  end)

  describe('commands and API', function()
    it(':AgentToggle toggles, :AgentClose hides, :AgentStop stops', function()
      vim.cmd('AgentToggle claude')
      wait_ready('claude')
      assert.truthy(terminal.is_visible())
      vim.cmd('AgentToggle')
      assert.falsy(terminal.is_visible())
      assert.truthy(terminal.is_running())
      vim.cmd('AgentOpen')
      assert.truthy(terminal.is_visible())
      vim.cmd('AgentClose')
      assert.falsy(terminal.is_visible())
      assert.truthy(terminal.is_running())
      local pid = terminal.info().pid
      vim.cmd('AgentStop')
      assert.falsy(terminal.is_running())
      wait_exited(pid)
      vim.cmd('AgentOpen nope')
      assert.matches('unknown agent', notes[#notes].msg)
      vim.cmd('AgentStop')
      assert.eq('agent.nvim: no agent is running', notes[#notes].msg)
    end)

    it(':Agent no longer exists: :AgentToggle [name] toggles in its place', function()
      -- No command is named Agent, not even an alias. 'Agent' is only a prefix of the Agent*
      -- commands: exists() gives 3 (several user commands match it), not 2 (a command of that
      -- name), and :Agent is ambiguous (E464), with or without a name.
      assert.falsy(vim.api.nvim_get_commands({}).Agent)
      assert.eq(3, vim.fn.exists(':Agent'))
      assert.eq(2, vim.fn.exists(':AgentToggle'))
      for _, cmd in ipairs({ 'Agent', 'Agent claude' }) do
        local ok, err = pcall(vim.cmd, cmd)
        assert.falsy(ok, cmd)
        assert.matches('E464', err)
      end
      assert.falsy(terminal.is_running(), ':Agent started nothing')
      assert.same({ 'claude', 'copilot' }, vim.fn.getcompletion('AgentToggle c', 'cmdline'))
      -- Without a name it starts default_agent; then it hides and shows the same agent.
      vim.cmd('AgentToggle')
      wait_ready('claude')
      assert.eq('claude', terminal.name())
      assert.truthy(terminal.is_visible())
      local pid = terminal.info().pid
      vim.cmd('AgentToggle')
      assert.falsy(terminal.is_visible())
      assert.truthy(terminal.is_running())
      vim.cmd('AgentToggle claude')
      assert.truthy(terminal.is_visible())
      vim.cmd('AgentToggle claude')
      assert.falsy(terminal.is_visible())
      assert.eq(pid, terminal.info().pid, 'the same agent throughout')
      assert.same({}, notes)
    end)

    it(':AgentClose and :AgentStop take no argument, and :AgentStop! no longer exists', function()
      agent.open('claude', { focus = false })
      wait_ready('claude')
      for _, cmd in ipairs({ 'AgentClose claude', 'AgentStop claude', 'AgentStop copilot' }) do
        local ok, err = pcall(vim.cmd, cmd)
        assert.falsy(ok, cmd)
        assert.matches('E488', err)
      end
      local ok, err = pcall(vim.cmd, 'AgentStop!')
      assert.falsy(ok)
      assert.matches('E477', err)
      assert.truthy(terminal.is_running(), 'nothing was stopped')
      assert.truthy(terminal.is_visible(), 'nothing was hidden')
      assert.truthy(require('agent.providers.claude').is_running())
    end)

    it('reloads unmodified file buffers changed on disk when focus leaves an agent or it exits', function()
      write(ws .. '/b.txt', 'b\n')
      agent.open('claude')
      wait_ready('claude')
      local a = edit_in_main(ws .. '/a.txt')
      local b = vim.fn.bufadd(ws .. '/b.txt')
      vim.fn.bufload(b)
      vim.api.nvim_buf_set_lines(b, 0, -1, false, { 'unsaved' })
      local main = vim.api.nvim_get_current_win()
      -- The agent edits both files without a diff (a shell command, an auto-approved edit). Each
      -- write gets a new mtime: Neovim compares mtimes, not sizes.
      local bump = 0
      local function agent_writes(path, text)
        write(path, text)
        bump = bump + 5
        uv.fs_utime(path, os.time() + bump, os.time() + bump)
      end
      agent_writes(ws .. '/a.txt', 'changed\n')
      agent_writes(ws .. '/b.txt', 'changed\n')
      vim.api.nvim_set_current_win(term_win())
      vim.api.nvim_set_current_win(main)
      wait_for(function()
        return vim.api.nvim_buf_get_lines(a, 0, -1, false)[1] == 'changed'
      end, 2000, 'a.txt reloaded')
      assert.same({ 'unsaved' }, vim.api.nvim_buf_get_lines(b, 0, -1, false), 'unsaved changes are kept')
      assert.truthy(vim.bo[b].modified)
      agent_writes(ws .. '/a.txt', 'again\n')
      agent.stop()
      wait_for(function()
        return vim.api.nvim_buf_get_lines(a, 0, -1, false)[1] == 'again'
      end, 5000, 'a.txt reloaded after the agent exited')
      vim.bo[b].modified = false
    end)

    it('the default layout is a split below: :AgentToggle opens the agent under the file, full width', function()
      local defaults = require('agent.config').defaults.terminal
      assert.same({ 'split', 'below', 0.4 }, { defaults.layout, defaults.split_side, defaults.split_size })
      local t = agent.setup({}).terminal
      assert.same({ 'split', 'below' }, { t.layout, t.split_side })
      -- No terminal options: only what keeps the run off the real CLIs and ~/.claude.
      local opts = base_opts()
      opts.terminal = nil
      t = agent.setup(opts).terminal
      assert.same({ 'split', 'below' }, { t.layout, t.split_side })
      local a = edit_in_main(ws .. '/a.txt')
      assert.eq(1, #vim.api.nvim_list_wins())
      local win = vim.api.nvim_get_current_win()
      vim.cmd('AgentToggle')
      -- start_insert (the default) would enter Terminal mode once this test returns.
      vim.cmd('stopinsert')
      wait_ready('claude')
      local buf = terminal.bufnr()
      local tw = vim.api.nvim_get_current_win()
      assert.eq('claude', terminal.name())
      assert.eq('split', terminal.info().layout)
      assert.truthy(tw ~= win, 'a window of its own, focused')
      assert.eq(buf, vim.api.nvim_win_get_buf(tw))
      assert.eq(a, vim.api.nvim_win_get_buf(win), 'a.txt stays in its window')
      -- a.txt above, the agent below it, as wide as the editor.
      assert.same({ 'col', { { 'leaf', win }, { 'leaf', tw } } }, vim.fn.winlayout())
      assert.eq(vim.o.columns, vim.api.nvim_win_get_width(tw))
      assert.eq(math.floor(vim.o.lines * 0.4), vim.api.nvim_win_get_height(tw), 'split_size of the height')
      assert.truthy(vim.wo[tw].winfixheight)
      -- :AgentToggle again hides it; the agent runs on.
      vim.cmd('AgentToggle')
      assert.falsy(vim.api.nvim_win_is_valid(tw))
      assert.same({ win }, vim.api.nvim_list_wins())
      assert.eq(a, vim.api.nvim_win_get_buf(win))
      assert.falsy(terminal.is_visible())
      assert.truthy(terminal.is_running())
    end)

    it("layout = 'current': :AgentToggle, :AgentClose and :AgentStop give the window its buffer back", function()
      setup({ terminal = { layout = 'current' } })
      write(ws .. '/b.txt', 'b\n')
      local a = edit_in_main(ws .. '/a.txt')
      local w1 = vim.api.nvim_get_current_win()
      vim.cmd('rightbelow vsplit')
      vim.cmd.edit(vim.fn.fnameescape(ws .. '/b.txt'))
      local b = vim.api.nvim_get_current_buf()
      local w2 = vim.api.nvim_get_current_win()
      assert.truthy(w1 ~= w2)
      vim.cmd('AgentToggle claude')
      wait_ready('claude')
      local buf = terminal.bufnr()
      assert.eq(buf, vim.api.nvim_win_get_buf(w2))
      assert.eq(a, vim.api.nvim_win_get_buf(w1))
      assert.eq(2, #vim.api.nvim_list_wins())
      assert.eq('current', terminal.info().layout)
      -- The agent writes a.txt; hiding it (the window stays, so neither WinLeave nor TermLeave)
      -- shows the change in the other window.
      write(ws .. '/a.txt', 'changed\n')
      uv.fs_utime(ws .. '/a.txt', os.time() + 5, os.time() + 5)
      vim.cmd('AgentToggle')
      assert.eq(b, vim.api.nvim_win_get_buf(w2))
      assert.eq(w2, vim.api.nvim_get_current_win())
      wait_for(function()
        return vim.api.nvim_buf_get_lines(a, 0, -1, false)[1] == 'changed'
      end, 2000, 'a.txt reloaded')
      assert.truthy(terminal.is_running())
      vim.cmd('AgentOpen')
      assert.eq(buf, vim.api.nvim_win_get_buf(w2))
      vim.cmd('AgentClose')
      assert.eq(b, vim.api.nvim_win_get_buf(w2))
      vim.cmd('AgentToggle')
      local pid = terminal.info().pid
      vim.cmd('AgentStop')
      assert.eq(b, vim.api.nvim_win_get_buf(w2))
      assert.eq(2, #vim.api.nvim_list_wins())
      wait_exited(pid)
    end)

    it('auto_start reports a provider that throws, and starts the others', function()
      local P = require('agent.providers.copilot')
      local orig = P.start
      P.start = function()
        error('boom')
      end
      local ok, err = pcall(setup, { auto_start = true })
      P.start = orig
      assert.truthy(ok, err)
      assert.truthy(require('agent.providers.claude').is_running())
      assert.truthy(require('agent.providers.gemini').is_running())
      wait_for(function()
        return vim.iter(notes):any(function(n)
          return n.msg:find('auto_start', 1, true) and n.msg:find('boom', 1, true)
        end)
      end, 1000, 'the auto_start warning')
    end)

    it('status() reports the agent and the providers', function()
      assert.eq(nil, agent.status().agent)
      local out = vim.api.nvim_exec2('AgentStatus', { output = true }).output
      assert.truthy(out:find('Agent:\n  none (default: claude)', 1, true), out)
      agent.open('opencode')
      wait_ready('opencode')
      local s = agent.status()
      assert.truthy(s.setup)
      assert.eq(vim.v.servername, s.servername)
      assert.eq('opencode', s.agent.name)
      assert.eq('opencode', s.agent.kind)
      assert.eq('claude', s.agent.provider)
      assert.truthy(s.agent.running)
      assert.truthy(s.agent.visible)
      assert.eq(terminal.info().pid, s.agent.pid)
      assert.eq(terminal.info().session_id, s.agent.session_id)
      assert.truthy(s.providers.claude.running)
      assert.eq(0, s.providers.claude.clients)
      assert.falsy(s.providers.copilot.running)
      out = vim.api.nvim_exec2('AgentStatus', { output = true }).output
      assert.truthy(out:find(('  opencode   running (pid %d), visible  [provider claude]'):format(s.agent.pid), 1, true), out)
    end)

    it('mcp_config() returns the manual registration entry for each agent kind', function()
      local nvim = require('agent.nvim_mcp').stable_nvim()
      assert.eq(nvim, agent.mcp_config('claude').mcpServers.nvim.command)
      assert.same({ '*' }, agent.mcp_config('copilot').mcpServers.nvim.tools)
      assert.eq('${NVIM}', agent.mcp_config('gemini').mcpServers.nvim.env.NVIM)
      assert.eq('https://opencode.ai/config.json', agent.mcp_config('opencode')['$schema'])
      local cfg, err = agent.mcp_config('nope')
      assert.eq(nil, cfg)
      assert.matches('unknown agent', err)
      local pretty = agent._pretty_json({ b = { 1, 2 }, a = vim.empty_dict(), c = 'x' })
      assert.eq('{\n  "a": {},\n  "b": [\n    1,\n    2\n  ],\n  "c": "x"\n}', pretty)
      vim.cmd('silent AgentMcpConfig copilot')
    end)

    it(':AgentMcpConfig claude prints a claude mcp add-json line with the inner server entry', function()
      local out = vim.api.nvim_exec2('AgentMcpConfig claude', { output = true }).output
      local json = out:match("\nclaude mcp add%-json nvim '([^'\n]+)'")
      assert.truthy(json, out)
      assert.same(agent.mcp_config('claude').mcpServers.nvim, vim.json.decode(json))
      out = vim.api.nvim_exec2('AgentMcpConfig copilot', { output = true }).output
      assert.falsy(out:find('add-json', 1, true), out)
    end)

    it('persisted configs use the nvim on PATH only when it is the running nvim', function()
      local saved = vim.env.PATH
      local ok, err = pcall(function()
        util.mkdir_p(tmp .. '/same', tonumber('700', 8))
        assert.truthy(uv.fs_symlink(vim.v.progpath, tmp .. '/same/nvim'))
        vim.env.PATH = tmp .. '/same:' .. saved
        assert.eq(tmp .. '/same/nvim', agent.mcp_config('claude').mcpServers.nvim.command)
        util.mkdir_p(tmp .. '/other', tonumber('700', 8))
        write(tmp .. '/other/nvim', '#!/bin/sh\necho "NVIM v0.6.1"\n')
        uv.fs_chmod(tmp .. '/other/nvim', tonumber('755', 8))
        vim.env.PATH = tmp .. '/other:' .. saved
        assert.eq(tmp .. '/other/nvim', vim.fn.exepath('nvim'))
        assert.eq(vim.v.progpath, agent.mcp_config('claude').mcpServers.nvim.command)
        assert.eq(vim.v.progpath, agent.mcp_config('gemini').mcpServers.nvim.command)
      end)
      vim.env.PATH = saved
      assert.truthy(ok, err)
    end)

    it('diff_accept() and diff_reject() resolve the current diff', function()
      local diff = require('agent.editor.diff')
      local res
      assert.truthy(diff.open({ id = 'd1', path = ws .. '/a.txt', new_contents = 'new\n', on_resolve = function(r)
        res = r
      end }))
      assert.truthy(agent.diff_accept())
      assert.eq('accepted', res.status)
      assert.eq('new\n', res.content)
      res = nil
      assert.truthy(diff.open({ id = 'd2', path = ws .. '/a.txt', new_contents = 'other\n', on_resolve = function(r)
        res = r
      end }))
      vim.cmd('AgentDiffReject')
      assert.eq('rejected', res.status)
      local ok = agent.diff_accept()
      assert.falsy(ok, 'no diff open')
    end)

    it(':checkhealth agent runs', function()
      vim.cmd('silent checkhealth agent')
      local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n')
      assert.matches('agent%.nvim: Neovim', text)
      assert.matches('agent%.nvim: %$NVIM controller', text)
      assert.falsy(text:find('ERROR', 1, true), text)
      vim.cmd('bwipeout!')
    end)

    it(':checkhealth agent reads Gemini settings from the home in agents.gemini.env', function()
      local home = tmp .. '/ghome2'
      util.mkdir_p(home .. '/.gemini/extensions/agent-nvim', tonumber('700', 8))
      write(home .. '/.gemini/settings.json', '{"ide":{"enabled":true}}')
      setup({ agents = { gemini = { env = { GEMINI_CLI_HOME = home } } } })
      vim.cmd('silent checkhealth agent')
      local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n')
      vim.cmd('bwipeout!')
      assert.truthy(text:find('ide.enabled is true (' .. home, 1, true), text)
      assert.truthy(text:find('extension is linked', 1, true), text)
    end)
  end)

  describe('one agent at a time', function()
    local orig_confirm = vim.fn.confirm
    local confirms = {}
    local LOCK_DIRS = { claude = 'claude-ide', copilot = 'copilot-ide', gemini = 'gemini-ide' }

    ---Answer vim.fn.confirm with `choice` (1 = Yes, 2 = No, 0 = Esc); nil: the test fails when asked.
    local function answer(choice)
      confirms = {}
      vim.fn.confirm = function(msg, choices, default)
        confirms[#confirms + 1] = { msg = msg, choices = choices, default = default }
        assert(choice, 'unexpected confirm: ' .. tostring(msg))
        return choice
      end
    end

    local function provider_files(name)
      return files_in(tmp .. '/' .. LOCK_DIRS[name])
    end

    after_each(function()
      vim.fn.confirm = orig_confirm
    end)

    it('starting another agent asks; confirmed, the old job and its provider stop and the new one starts', function()
      agent.open('claude')
      wait_ready('claude')
      local P = require('agent.providers.claude')
      local old = terminal.info()
      local session = vim.fs.dirname(read_args(out_of('claude'))[1]:match('^%-%-mcp%-config=(.+)$'))
      assert.eq(1, #provider_files('claude'))
      vim.cmd('AgentToggle') -- hidden: replacing it asks all the same
      assert.falsy(terminal.is_visible())
      answer(1)
      vim.cmd('AgentToggle copilot')
      assert.eq(1, #confirms)
      assert.eq('Stop claude and start copilot?', confirms[1].msg)
      assert.eq('&Yes\n&No', confirms[1].choices)
      assert.eq(2, confirms[1].default, 'No is the default')
      -- claude and its provider stopped before copilot started.
      assert.falsy(P.is_running())
      assert.same({}, provider_files('claude'))
      assert.eq(nil, uv.fs_stat(session), 'claude session dir removed')
      assert.eq('copilot', terminal.name())
      assert.truthy(terminal.is_running())
      assert.truthy(terminal.is_visible())
      wait_ready('copilot')
      wait_exited(old.pid)
      assert.falsy(vim.api.nvim_buf_is_valid(old.bufnr))
      assert.falsy(P.is_running(), 'still stopped after claude exited')
      assert.truthy(require('agent.providers.copilot').is_running())
      assert.eq(1, #provider_files('copilot'))
      assert.eq('copilot', agent.status().agent.name)
    end)

    it('declined (No or Esc), nothing changes', function()
      agent.open('claude')
      wait_ready('claude')
      local info = terminal.info()
      local lock = require('agent.providers.claude').status().lock
      for _, choice in ipairs({ 2, 0 }) do
        answer(choice)
        notes = {}
        vim.cmd('AgentToggle copilot')
        local buf, err = agent.open('gemini')
        assert.eq(nil, buf)
        assert.eq(nil, err)
        assert.eq(2, #confirms)
        assert.same({}, notes, 'no message for a declined replace')
        assert.eq('claude', terminal.name())
        assert.eq(info.pid, terminal.info().pid)
        assert.eq(info.bufnr, terminal.bufnr())
        assert.truthy(terminal.is_visible())
        assert.truthy(require('agent.providers.claude').is_running())
        assert.eq(1, vim.fn.filereadable(lock))
        assert.falsy(require('agent.providers.copilot').is_running())
        assert.falsy(require('agent.providers.gemini').is_running())
        assert.same({}, provider_files('copilot'))
        assert.same({}, provider_files('gemini'))
      end
      assert.truthy(pid_alive(info.pid))
    end)

    it('a replacement whose CLI is missing is refused before asking; the running agent stays', function()
      setup({ agents = { copilot = { cmd = { tmp .. '/no-such-cli' } } } })
      agent.open('claude')
      wait_ready('claude')
      local pid = terminal.info().pid
      answer(nil)
      local buf, err = agent.open('copilot', { silent = true })
      assert.eq(nil, buf)
      assert.matches("executable '.*no%-such%-cli' not found", err)
      assert.eq(pid, terminal.info().pid)
      assert.truthy(require('agent.providers.claude').is_running())
    end)

    it("layout = 'current': the replace asks the same, and the new agent takes the same window", function()
      setup({ terminal = { layout = 'current' } })
      local a = edit_in_main(ws .. '/a.txt')
      local win = vim.api.nvim_get_current_win()
      vim.cmd('AgentToggle claude')
      wait_ready('claude')
      local old = terminal.info()
      assert.eq(old.bufnr, vim.api.nvim_win_get_buf(win))
      answer(2)
      vim.cmd('AgentToggle copilot')
      assert.eq(1, #confirms)
      assert.eq('claude', terminal.name())
      assert.eq(old.bufnr, vim.api.nvim_win_get_buf(win))
      answer(1)
      vim.cmd('AgentToggle copilot')
      assert.eq(1, #confirms)
      assert.eq('Stop claude and start copilot?', confirms[1].msg)
      assert.eq('copilot', terminal.name())
      wait_ready('copilot')
      assert.same({ win }, vim.api.nvim_list_wins())
      assert.eq(terminal.bufnr(), vim.api.nvim_win_get_buf(win))
      assert.eq(a, vim.w[win].agent_nvim_prev.buf)
      wait_exited(old.pid)
      vim.cmd('AgentStop')
      assert.same({ win }, vim.api.nvim_list_wins())
      assert.eq(a, vim.api.nvim_win_get_buf(win))
    end)

    it('opts.confirm = false replaces without asking; claude -> opencode keeps the shared provider', function()
      local P = require('agent.providers.claude')
      agent.open('claude')
      wait_ready('claude')
      local port, pid = P.status().port, terminal.info().pid
      answer(nil)
      local buf, err = agent.open('opencode', { confirm = false })
      assert.truthy(buf, err)
      assert.eq('opencode', terminal.name())
      wait_ready('opencode')
      wait_exited(pid) -- claude's exit comes after opencode started: the provider is in use again
      assert.truthy(P.is_running())
      assert.eq(port, P.status().port)
      assert.eq(1, vim.fn.filereadable(P.status().lock))
      assert.truthy(vim.tbl_contains(vim.json.decode(read(P.status().lock)).workspaceFolders, ws))
    end)

    it(':AgentToggle with the name of the running agent toggles it without asking', function()
      answer(nil)
      vim.cmd('AgentToggle claude')
      wait_ready('claude')
      local pid = terminal.info().pid
      vim.cmd('AgentToggle claude')
      assert.falsy(terminal.is_visible())
      vim.cmd('AgentToggle claude')
      assert.truthy(terminal.is_visible())
      vim.cmd('AgentOpen claude')
      assert.truthy(terminal.is_visible())
      assert.truthy(agent.toggle('claude'))
      assert.falsy(terminal.is_visible())
      assert.truthy(agent.open('claude'))
      assert.truthy(terminal.is_visible())
      assert.eq(pid, terminal.info().pid)
      assert.same({}, notes)
    end)

    it('without a name, commands use the running agent, else default_agent', function()
      answer(nil)
      agent.open('copilot')
      wait_ready('copilot')
      vim.cmd('AgentToggle')
      assert.falsy(terminal.is_visible())
      assert.eq('copilot', terminal.name())
      vim.cmd('AgentOpen')
      assert.truthy(terminal.is_visible())
      assert.eq('copilot', terminal.name())
      local pid = terminal.info().pid
      agent.stop()
      wait_exited(pid)
      vim.cmd('AgentToggle')
      assert.eq('claude', terminal.name())
      wait_ready('claude')
    end)

    it('an agent that already exited is replaced without asking', function()
      answer(nil)
      agent.open('claude', { env = { FAKE_AGENT_EXIT = '3' } })
      wait_for(function()
        return terminal.name() == 'claude' and not terminal.is_running()
      end, 5000, 'claude exited')
      local buf = terminal.bufnr()
      assert.truthy(buf, 'a failed start leaves the terminal open')
      assert.falsy(require('agent.providers.claude').is_running(), 'its provider stopped')
      assert.truthy(agent.open('copilot'))
      assert.falsy(vim.api.nvim_buf_is_valid(buf))
      assert.eq('copilot', terminal.name())
      wait_ready('copilot')
    end)

    it(':AgentStop stops the agent and its provider (lock file removed)', function()
      agent.open('claude')
      wait_ready('claude')
      local P = require('agent.providers.claude')
      local lock = P.status().lock
      assert.eq(1, vim.fn.filereadable(lock))
      local pid = terminal.info().pid
      vim.cmd('AgentStop')
      assert.falsy(terminal.is_running())
      assert.falsy(P.is_running())
      assert.eq(0, vim.fn.filereadable(lock))
      assert.same({}, provider_files('claude'))
      wait_exited(pid)
      assert.falsy(P.is_running())
      assert.falsy(agent.stop())
    end)

    it('an agent exiting on its own stops its provider (lock or discovery file removed)', function()
      for _, k in ipairs({ 'claude', 'copilot', 'gemini' }) do
        agent.open(k, { env = { FAKE_AGENT_EXIT = '0', FAKE_AGENT_SLEEP = '1' } })
        wait_ready(k)
        local P = require('agent.providers.' .. k)
        assert.truthy(P.is_running(), k)
        assert.eq(1, #provider_files(k), k .. ' lock')
        wait_for(function()
          return terminal.info() == nil
        end, 5000, k .. ' exited')
        assert.falsy(P.is_running(), k .. ' provider stopped')
        assert.same({}, provider_files(k))
      end
    end)

    it('with auto_start every provider keeps running when the agent stops, is replaced or exits', function()
      setup({ auto_start = true })
      local function all_running(when)
        local s = agent.status().providers
        for _, name in ipairs(agent.PROVIDERS) do
          assert.truthy(s[name].running, name .. ' running ' .. when)
          assert.eq(1, #provider_files(name), name .. ' lock ' .. when)
        end
      end
      all_running('after setup')
      agent.open('claude')
      wait_ready('claude')
      local pid = terminal.info().pid
      answer(1)
      agent.open('copilot')
      assert.eq(1, #confirms)
      wait_ready('copilot')
      wait_exited(pid)
      all_running('after a replace')
      pid = terminal.info().pid
      agent.stop()
      wait_exited(pid)
      all_running('after stop()')
      agent.open('gemini', { env = { FAKE_AGENT_EXIT = '0' } })
      wait_for(function()
        return terminal.info() == nil
      end, 5000, 'gemini exited')
      all_running('after the agent exited')
    end)

    it('the Claude provider keeps its port and token across stop and start', function()
      local P = require('agent.providers.claude')
      agent.open('claude')
      wait_ready('claude')
      local port, token, lock = P.status().port, P._state.token, P.status().lock
      assert.eq(tostring(port), read_env(out_of('claude')).CLAUDE_CODE_SSE_PORT)
      assert.eq(token, vim.json.decode(read(lock)).authToken)
      local pid = terminal.info().pid
      agent.stop()
      assert.falsy(P.is_running())
      assert.eq(0, vim.fn.filereadable(lock))
      wait_exited(pid)
      vim.fn.delete(out_of('claude') .. '.env')
      agent.open('claude')
      wait_ready('claude')
      assert.truthy(P.is_running())
      assert.eq(port, P.status().port)
      assert.eq(token, P._state.token)
      assert.eq(lock, P.status().lock)
      assert.eq(token, vim.json.decode(read(lock)).authToken)
      assert.eq(tostring(port), read_env(out_of('claude')).CLAUDE_CODE_SSE_PORT)
    end)

    it('with selection.track = true selection events reach every running provider (auto_start)', function()
      local got, originals = { claude = 0, copilot = 0, gemini = 0 }, {}
      for name in pairs(got) do
        local P = require('agent.providers.' .. name)
        originals[name] = P.on_selection
        P.on_selection = function()
          got[name] = got[name] + 1
        end
      end
      local ok, err = pcall(function()
        setup({ auto_start = true, selection = { track = true } })
        agent.open('claude', { focus = false })
        wait_ready('claude')
        for name in pairs(got) do
          got[name] = 0
        end
        edit_in_main(ws .. '/a.txt')
        vim.api.nvim_win_set_cursor(0, { 2, 0 })
        require('agent.editor.selection').flush()
        for name, n in pairs(got) do
          assert.truthy(n >= 1, name .. ' got the selection')
        end
      end)
      for name, fn in pairs(originals) do
        require('agent.providers.' .. name).on_selection = fn
      end
      assert.truthy(ok, err)
    end)
  end)

  describe('teardown', function()
    ---Every provider running (auto_start) and the copilot agent: its session dir holds its MCP config.
    local function launch()
      setup({ auto_start = true })
      assert.truthy(agent.open('copilot', { focus = false }))
      wait_ready('copilot')
      local s = agent.status().providers
      for _, name in ipairs(agent.PROVIDERS) do
        assert.truthy(s[name].running, name .. ' running')
      end
      local cfg = read_args(out_of('copilot'))[2]:match('^@(.+)$')
      assert.truthy(cfg)
      return { terminal.info().pid }, s.copilot.address, { vim.fs.dirname(cfg) }
    end

    local function assert_clean(agent_pids, socket, sessions)
      assert.falsy(terminal.is_running())
      for _, name in ipairs(agent.PROVIDERS) do
        assert.falsy(require('agent.providers.' .. name).is_running(), name .. ' stopped')
      end
      assert.same({}, files_in(tmp .. '/claude-ide'))
      assert.same({}, files_in(tmp .. '/copilot-ide'))
      assert.same({}, files_in(tmp .. '/gemini-ide'))
      assert.eq(nil, uv.fs_stat(socket), 'copilot socket removed')
      assert.eq(nil, uv.fs_stat(vim.fs.dirname(socket)), 'copilot socket dir removed')
      for _, d in ipairs(sessions) do
        assert.eq(nil, uv.fs_stat(d), 'session dir removed: ' .. d)
      end
      assert.eq(nil, uv.fs_stat(vim.fs.joinpath(vim.fn.stdpath('run'), 'agent.nvim', tostring(vim.fn.getpid()))))
      wait_for(function()
        return not vim.iter(agent_pids):any(pid_alive)
      end, 5000, 'agent processes gone')
    end

    it('teardown() stops the agent and every provider (even with auto_start) and leaves no files', function()
      local agent_pids, socket, sessions = launch()
      agent.teardown()
      assert_clean(agent_pids, socket, sessions)
    end)

    it('VimLeavePre tears everything down', function()
      local agent_pids, socket, sessions = launch()
      vim.api.nvim_exec_autocmds('VimLeavePre', {})
      assert_clean(agent_pids, socket, sessions)
    end)

    it(':qa! ends the agent and every process it started, also ones that ignore the hangup', function()
      if util.is_windows then
        return
      end
      -- A nested Neovim quits right after starting the agent. Stopping the job only hangs up its
      -- terminal (SIGHUP), which hup_agent.sh and its child ignore; Neovim's own SIGTERM would
      -- come 2 s later, and never does once Neovim has exited.
      local out = tmp .. '/nested'
      local script = tmp .. '/quit.lua'
      write(script, ([[
        vim.opt.rtp:prepend(%q)
        require('agent').setup({
          providers = { claude = { enabled = false } },
          nvim_mcp = { enabled = false },
          agents = { claude = { cmd = { %q }, env = { FAKE_AGENT_OUT = %q } } },
        })
        require('agent').open('claude')
        assert(vim.wait(5000, function() return vim.fn.filereadable(%q) == 1 end), 'the fake agent runs')
        vim.cmd('qa!')
      ]]):format(TEST_ROOT, TEST_ROOT .. '/tests/fixtures/hup_agent.sh', out, out .. '.pids'))
      local t0 = uv.now()
      local r = vim.system({ vim.v.progpath, '--headless', '-u', 'NONE', '-i', 'NONE', '-n', '-l', script },
        { env = { NVIM = '' }, text = true }):wait(15000)
      local quit_ms = uv.now() - t0
      assert.eq(0, r.code, r.stderr)
      local agent_pid, child = (read(out .. '.pids') or ''):match('^(%d+) (%d+)')
      agent_pid, child = tonumber(agent_pid), tonumber(child)
      assert.truthy(agent_pid and child, 'pids recorded')
      local gone = vim.wait(1500, function()
        return not pid_alive(agent_pid) and not pid_alive(child)
      end, 20)
      for _, p in ipairs({ child, agent_pid }) do
        if pid_alive(p) then
          uv.kill(p, 'sigkill')
        end
      end
      assert.truthy(gone, 'the agent and its child ended with Neovim')
      assert.truthy(quit_ms < 5000, 'quitting took ' .. quit_ms .. ' ms')
    end)
  end)
end)
