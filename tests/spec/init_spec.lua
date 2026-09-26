-- Integration of agent.nvim: plugin/agent.lua, setup(), the launcher wiring for every agent kind
-- (with the fake agent CLI), selection forwarding, at-mentions and their typed fallback, teardown.
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
      claude = { lock_dir = tmp .. '/claude-ide', mention_timeout_ms = 1 },
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

local function term_win(name)
  local buf = require('agent.terminal').bufnr(name)
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_buf(w) == buf then
      return w
    end
  end
end

local function pid_alive(pid)
  local ok, ret = pcall(uv.kill, pid, 0)
  return ok and ret == 0
end

-- Runs first: nothing has called setup() in this process yet.
describe('plugin/agent.lua', function()
  it('defines the commands without calling setup(), and a command calls setup({}) lazily once', function()
    local agent = require('agent')
    assert.falsy(agent._state.setup_done)
    vim.cmd.runtime('plugin/agent.lua')
    assert.eq(1, vim.g.loaded_agent_nvim)
    local cmds = vim.api.nvim_get_commands({})
    for _, c in ipairs({ 'Agent', 'AgentOpen', 'AgentClose', 'AgentStop', 'AgentSend', 'AgentAdd', 'AgentDiffAccept',
      'AgentDiffReject', 'AgentStatus', 'AgentMcpConfig', 'AgentGeminiSetup' }) do
      assert.truthy(cmds[c], ':' .. c .. ' exists')
    end
    assert.eq('?', cmds.AgentSend.nargs)
    assert.truthy(cmds.AgentSend.range ~= nil and cmds.AgentSend.range ~= '', ':AgentSend takes a range')
    assert.truthy(cmds.AgentStop.bang)
    assert.falsy(agent._state.setup_done, 'defining commands does not call setup()')
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
    assert.same({ 'claude', 'copilot' }, vim.fn.getcompletion('Agent c', 'cmdline'))
    assert.same({ 'gemini' }, vim.fn.getcompletion('AgentStop g', 'cmdline'))
    -- Nothing was started.
    for _, s in pairs(agent.status().providers) do
      assert.falsy(s.running)
    end
  end)
end)

describe('agent', function()
  local agent, terminal, saved

  before_each(function()
    agent = require('agent')
    terminal = require('agent.terminal')
    tmp = util.realpath(vim.fn.tempname())
    util.mkdir_p(tmp, tonumber('700', 8))
    tmp = util.realpath(tmp)
    ws = tmp .. '/ws'
    util.mkdir_p(ws, tonumber('700', 8))
    write(ws .. '/a.txt', 'one\ntwo\nthree\nfour\n')
    write(ws .. '/my file.txt', 'x\n')
    vim.env.GEMINI_CLI_HOME = tmp .. '/ghome'
    vim.cmd.cd(ws)
    notes = {}
    vim.notify = function(msg, level)
      notes[#notes + 1] = { msg = msg, level = level }
    end
    saved = { wait = agent.MENTION_WAIT_MS, grace = agent.STARTUP_GRACE_MS, poll = agent.MENTION_POLL_MS }
    -- Mentions fall back to typing at once unless a test says otherwise.
    agent.MENTION_WAIT_MS, agent.STARTUP_GRACE_MS, agent.MENTION_POLL_MS = 0, 0, 20
    setup()
  end)

  after_each(function()
    agent.teardown()
    wait_for(function()
      return #terminal.running() == 0
    end, 5000, 'all agents stopped')
    vim.cmd('silent! only')
    vim.cmd('silent! %bwipeout!')
    vim.cmd.cd(orig_cwd)
    vim.notify = orig_notify
    vim.env.GEMINI_CLI_HOME = orig_gemini_home
    agent.MENTION_WAIT_MS, agent.STARTUP_GRACE_MS, agent.MENTION_POLL_MS = saved.wait, saved.grace, saved.poll
    util.remove_dir(tmp)
  end)

  describe('setup', function()
    it('applies options and rejects invalid ones', function()
      setup({ terminal = { layout = 'tab' }, log_level = 'error' })
      assert.eq('tab', require('agent.config').get().terminal.layout)
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
      assert.eq(terminal.info('claude').session_id, env.AGENT_NVIM_SESSION)
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
      agent.stop('claude')
      wait_for(function()
        return not terminal.is_running('claude')
      end, 5000, 'claude stopped')
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
    it('is forwarded to every running provider, and not when tracking is off', function()
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

  describe('at-mentions', function()
    it('go to the provider of the most recently focused agent, targeted by its terminal pid', function()
      local calls = {}
      local P = require('agent.providers.copilot')
      local orig = P.at_mention
      P.at_mention = function(path, l1, l2, o)
        calls[#calls + 1] = { path = path, l1 = l1, l2 = l2, o = o }
        return true
      end
      local ok, err = pcall(function()
        agent.open('claude')
        agent.open('copilot')
        wait_ready('claude')
        wait_ready('copilot')
        assert.eq('copilot', terminal.last_focused())
        local sent, how = agent.add_file(ws .. '/a.txt', 2, 3)
        assert.truthy(sent, how)
        assert.eq('sent', how)
        assert.eq(1, #calls)
        assert.eq(ws .. '/a.txt', calls[1].path)
        assert.eq(2, calls[1].l1)
        assert.eq(3, calls[1].l2)
        assert.eq(terminal.info('copilot').pid, calls[1].o.pid)
        assert.eq('copilot', calls[1].o.kind)
        -- Focusing claude's terminal retargets: claude's provider has no client, so the reference is typed.
        vim.api.nvim_set_current_win(term_win('claude'))
        assert.eq('claude', terminal.last_focused())
        local sent2, how2 = agent.add_file(ws .. '/a.txt', 2, 3)
        assert.truthy(sent2, how2)
        assert.eq('typed', how2)
        wait_stdin('claude', pasted('@a.txt#L2-3 '))
        assert.eq(1, #calls)
        assert.eq('', stdin_of('copilot'))
      end)
      P.at_mention = orig
      assert.truthy(ok, err)
    end)

    it('fall back to typing a reference in the agent\'s own syntax', function()
      local cases = {
        claude = { { 2, 4, '@a.txt#L2-4 ' }, { 3, 3, '@a.txt#L3 ' }, { nil, nil, '@a.txt ' } },
        opencode = { { 2, 4, '@a.txt#2-4 ' }, { 3, 3, '@a.txt#3 ' } },
        copilot = { { 2, 4, '@a.txt:2-4 ' }, { 3, 3, '@a.txt:3 ' } },
        gemini = { { nil, nil, '@a.txt ' }, { 2, 4, '@a.txt (lines 2-4) ' } },
      }
      for name, list in pairs(cases) do
        agent.open(name)
        wait_ready(name)
        for _, c in ipairs(list) do
          local ok, how = agent.mention(ws .. '/a.txt', c[1], c[2], { name = name })
          assert.truthy(ok, how)
          assert.eq('typed', how, name)
          wait_stdin(name, pasted(c[3]))
        end
      end
      -- Gemini escapes spaces; paths outside the agent's cwd stay absolute.
      agent.mention(ws .. '/my file.txt', nil, nil, { name = 'gemini' })
      wait_stdin('gemini', pasted('@my\\ file.txt '))
      agent.mention(tmp .. '/outside.txt', 1, 2, { name = 'copilot' })
      wait_stdin('copilot', pasted('@' .. tmp .. '/outside.txt:1-2 '))
    end)

    it('retry through the provider while a just-launched agent connects, then type', function()
      agent.MENTION_WAIT_MS = 400
      local ok, how = agent.mention(ws .. '/a.txt', 1, 1, { name = 'copilot' })
      assert.truthy(ok, how)
      assert.eq('pending', how)
      assert.truthy(terminal.is_running('copilot'), 'the agent was started')
      wait_ready('copilot')
      wait_stdin('copilot', pasted('@a.txt:1 '))
    end)

    it('without a running agent, start the default agent and deliver once it is up', function()
      agent.STARTUP_GRACE_MS = 800
      setup({ default_agent = 'gemini' })
      assert.eq(0, #terminal.running())
      local ok, how = agent.mention(ws .. '/a.txt')
      assert.truthy(ok, how)
      assert.eq('pending', how)
      assert.same({ 'gemini' }, terminal.running())
      wait_stdin('gemini', pasted('@a.txt '))
    end)

    it(':AgentSend sends the range, :AgentAdd a file with lines', function()
      agent.open('claude')
      wait_ready('claude')
      edit_in_main(ws .. '/a.txt')
      vim.cmd('2,3AgentSend')
      wait_stdin('claude', pasted('@a.txt#L2-3 '))
      vim.cmd('AgentAdd a.txt 1 4')
      wait_stdin('claude', pasted('@a.txt#L1-4 '))
      vim.cmd('AgentAdd')
      wait_stdin('claude', pasted('@a.txt '))
      vim.cmd('AgentAdd nosuch.txt')
      assert.truthy(vim.tbl_contains(vim.tbl_map(function(n)
        return n.msg:find('no such file', 1, true) ~= nil
      end, notes), true), 'an error is shown for a missing file')
    end)

    it(':AgentSend without a range uses the visual selection', function()
      agent.open('copilot')
      wait_ready('copilot')
      edit_in_main(ws .. '/a.txt')
      vim.api.nvim_win_set_cursor(0, { 2, 0 })
      vim.cmd('normal! Vj')
      assert.eq('V', vim.fn.mode())
      vim.cmd('AgentSend')
      wait_stdin('copilot', pasted('@a.txt:2-3 '))
    end)

    it(':AgentSend outside Visual mode uses the last visual selection, after the cursor moved', function()
      for _, track in ipairs({ true, false }) do
        setup({ selection = { track = track } })
        agent.open('claude')
        wait_ready('claude')
        edit_in_main(ws .. '/a.txt')
        vim.api.nvim_win_set_cursor(0, { 2, 0 })
        vim.api.nvim_feedkeys(vim.keycode('Vj<Esc>'), 'nx', false)
        vim.api.nvim_win_set_cursor(0, { 4, 0 })
        vim.cmd('AgentSend')
        wait_stdin('claude', pasted('@a.txt#L2-3 '))
        agent.stop('claude')
        wait_for(function()
          return not terminal.is_running('claude')
        end, 5000, 'claude stopped')
        vim.fn.delete(out_of('claude') .. '.env')
        vim.fn.delete(out_of('claude') .. '.stdin')
      end
    end)

    it(':AgentSend from the agent terminal uses the last selection of the last focused file', function()
      agent.open('claude')
      wait_ready('claude')
      edit_in_main(ws .. '/a.txt')
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      vim.api.nvim_feedkeys(vim.keycode('Vj<Esc>'), 'nx', false)
      vim.api.nvim_win_set_cursor(0, { 4, 0 })
      require('agent.editor.selection').flush()
      vim.api.nvim_set_current_win(term_win('claude'))
      vim.cmd('AgentSend')
      wait_stdin('claude', pasted('@a.txt#L1-2 '))
      -- A range means lines of the current buffer, and the terminal is not a file.
      local n = #notes
      vim.cmd('3,4AgentSend')
      assert.eq(n + 1, #notes)
      assert.matches('no selection in a file buffer', notes[#notes].msg)
      vim.wait(100)
      assert.falsy(stdin_of('claude'):find('L3-4', 1, true), 'nothing sent for a range in the terminal')
    end)
  end)

  describe('agents started by hand', function()
    local P, orig, calls, clients

    before_each(function()
      P = require('agent.providers.claude')
      orig = { at_mention = P.at_mention, status = P.status }
      calls, clients = {}, {}
      P.at_mention = function(path, l1, l2, o)
        calls[#calls + 1] = { path = path, l1 = l1, l2 = l2, o = o }
        return #clients > 0
      end
      P.status = function()
        local s = orig.status()
        s.clients, s.sessions = #clients, clients
        return s
      end
    end)

    after_each(function()
      P.at_mention, P.status = orig.at_mention, orig.status
    end)

    it('terminal.layout = none: mentions go to the connected agent, else a clear error', function()
      setup({ auto_start = true, terminal = { layout = 'none' } })
      assert.truthy(P.is_running())
      local ok, how = agent.add_file(ws .. '/a.txt', 1, 2)
      assert.falsy(ok)
      assert.matches('no claude is connected', how)
      assert.eq(0, #calls)
      -- A Claude the user started in their own terminal connects.
      clients[1] = { id = 's1', kind = 'claude', pid = 4242, ready = true }
      ok, how = agent.add_file(ws .. '/a.txt', 1, 2)
      assert.truthy(ok, how)
      assert.eq('sent', how)
      assert.same({ path = ws .. '/a.txt', l1 = 1, l2 = 2, o = { kind = 'claude' } }, calls[#calls])
      edit_in_main(ws .. '/a.txt')
      vim.cmd('2,3AgentSend')
      assert.same({ 2, 3 }, { calls[#calls].l1, calls[#calls].l2 })
      vim.cmd('AgentAdd')
      assert.eq(3, #calls)
      assert.eq(0, #terminal.running(), 'nothing was started')
      -- Another kind connected (OpenCode) does not count for claude.
      clients[1] = { id = 's2', kind = 'opencode', ready = true }
      ok, how = agent.add_file(ws .. '/a.txt')
      assert.falsy(ok)
      assert.matches('no claude is connected', how)
      assert.eq(3, #calls)
    end)

    it('a connected agent started by hand gets the mention instead of a new terminal', function()
      setup({ auto_start = true })
      clients[1] = { id = 's1', kind = 'claude', pid = 4242, ready = true }
      local ok, how = agent.add_file(ws .. '/a.txt')
      assert.truthy(ok, how)
      assert.eq('sent', how)
      assert.eq(nil, calls[1].o.pid)
      assert.eq(0, #terminal.running(), 'no second Claude was started')
    end)

    it('not while another agent of that kind runs in a terminal: its client cannot be told apart', function()
      setup({ agents = { claude2 = { cmd = { FIX }, provider = 'claude', kind = 'claude',
        env = { FAKE_AGENT_OUT = out_of('claude2') } } } })
      agent.open('claude2')
      wait_ready('claude2')
      clients[1] = { id = 's1', kind = 'claude', pid = terminal.info('claude2').pid, ready = true }
      local ok, how = agent.mention(ws .. '/a.txt', 1, 1, { name = 'claude' })
      assert.truthy(ok, how)
      assert.truthy(terminal.is_running('claude'), 'claude was started')
      assert.eq(terminal.info('claude').pid, calls[#calls].o.pid)
    end)
  end)

  describe('commands and API', function()
    it(':Agent toggles, :AgentClose hides, :AgentStop stops', function()
      vim.cmd('Agent claude')
      wait_ready('claude')
      assert.truthy(terminal.is_visible('claude'))
      vim.cmd('Agent')
      assert.falsy(terminal.is_visible('claude'))
      assert.truthy(terminal.is_running('claude'))
      vim.cmd('AgentOpen')
      assert.truthy(terminal.is_visible('claude'))
      vim.cmd('AgentClose claude')
      assert.falsy(terminal.is_visible('claude'))
      vim.cmd('AgentStop claude')
      wait_for(function()
        return not terminal.is_running('claude')
      end, 5000, 'claude stopped')
      vim.cmd('AgentOpen nope')
      assert.matches('unknown agent', notes[#notes].msg)
      vim.cmd('AgentStop')
      assert.eq('agent.nvim: no agent is running', notes[#notes].msg)
      vim.cmd('AgentStop claude')
      assert.eq('agent.nvim: claude is not running', notes[#notes].msg)
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
      vim.api.nvim_set_current_win(term_win('claude'))
      vim.api.nvim_set_current_win(main)
      wait_for(function()
        return vim.api.nvim_buf_get_lines(a, 0, -1, false)[1] == 'changed'
      end, 2000, 'a.txt reloaded')
      assert.same({ 'unsaved' }, vim.api.nvim_buf_get_lines(b, 0, -1, false), 'unsaved changes are kept')
      assert.truthy(vim.bo[b].modified)
      agent_writes(ws .. '/a.txt', 'again\n')
      agent.stop('claude')
      wait_for(function()
        return vim.api.nvim_buf_get_lines(a, 0, -1, false)[1] == 'again'
      end, 5000, 'a.txt reloaded after the agent exited')
      vim.bo[b].modified = false
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

    it('status() reports agents and providers', function()
      agent.open('claude')
      wait_ready('claude')
      local s = agent.status()
      assert.truthy(s.setup)
      assert.eq(vim.v.servername, s.servername)
      assert.truthy(s.agents.claude.running)
      assert.eq(terminal.info('claude').pid, s.agents.claude.pid)
      assert.falsy(s.agents.copilot.running)
      assert.eq('claude', s.agents.opencode.provider)
      assert.eq('opencode', s.agents.opencode.kind)
      assert.truthy(s.providers.claude.running)
      assert.eq(0, s.providers.claude.clients)
      assert.falsy(s.providers.copilot.running)
      vim.cmd('silent AgentStatus')
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

  describe('teardown', function()
    local function launch_all()
      for _, k in ipairs(KINDS) do
        assert.truthy(agent.open(k, { focus = false }))
      end
      for _, k in ipairs(KINDS) do
        wait_ready(k)
      end
      local pids = {}
      for _, k in ipairs(KINDS) do
        pids[#pids + 1] = terminal.info(k).pid
      end
      local s = agent.status().providers
      local sessions = {}
      for _, k in ipairs(KINDS) do
        -- The MCP config temp files live in the session dir.
        local args = read_args(out_of(k))
        for _, a in ipairs(args) do
          local p = a:match('^%-%-mcp%-config=(.+)$') or a:match('^@(.+)$')
          if p then
            sessions[#sessions + 1] = vim.fs.dirname(p)
          end
        end
      end
      assert.eq(2, #sessions, 'claude and copilot session dirs')
      return pids, s.copilot.address, sessions
    end

    local function assert_clean(pids, socket, sessions)
      wait_for(function()
        return #terminal.running() == 0
      end, 5000, 'all agents stopped')
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
        for _, pid in ipairs(pids) do
          if pid_alive(pid) then
            return false
          end
        end
        return true
      end, 5000, 'agent processes gone')
    end

    it('stop(name) stops one agent and removes its temp files; providers keep running', function()
      agent.open('claude')
      wait_ready('claude')
      local pid = terminal.info('claude').pid
      local cfg = read_args(out_of('claude'))[1]:match('^%-%-mcp%-config=(.+)$')
      assert.truthy(agent.stop('claude'))
      wait_for(function()
        return not terminal.is_running('claude') and not pid_alive(pid)
      end, 5000, 'claude stopped')
      wait_for(function()
        return uv.fs_stat(vim.fs.dirname(cfg)) == nil
      end, 2000, 'session dir removed')
      assert.truthy(require('agent.providers.claude').is_running())
      assert.falsy(agent.stop('claude'))
    end)

    it('teardown() stops every agent and provider and leaves no files', function()
      local pids, socket, sessions = launch_all()
      agent.teardown()
      assert_clean(pids, socket, sessions)
    end)

    it('VimLeavePre tears everything down', function()
      local pids, socket, sessions = launch_all()
      vim.api.nvim_exec_autocmds('VimLeavePre', {})
      assert_clean(pids, socket, sessions)
    end)

    it(':AgentStop! stops everything', function()
      local pids, socket, sessions = launch_all()
      vim.cmd('AgentStop!')
      assert_clean(pids, socket, sessions)
    end)
  end)
end)
