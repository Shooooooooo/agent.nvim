-- agent.progress: the agent's work as a Neovim progress message (the Progress event, 'busy', the
-- default statusline, the terminal's progress bar), read from the agent's terminal.
local agent = require('agent')
local progress = require('agent.progress')
local terminal = require('agent.terminal')
local util = require('agent.util')

local api = vim.api

-- An agent that sends back what it reads: what a test chansend()s comes out of the agent's
-- terminal as if the agent had written it (raw mode: the bytes go through as they are, no echo).
local ECHO = { 'sh', '-c', 'stty raw -echo 2>/dev/null; printf R; exec cat' }
-- ◐ for printf in a shell script.
local HALF = [[\342\227\220]]

local OPTS = { terminal = { layout = 'split', start_insert = false } }

local orig_notify = vim.notify
local orig_ui_send = api.nvim_ui_send
local orig_idle = progress.IDLE_MS
local tmp
local events = {} -- the data of agent.nvim's Progress events
local timeline = {} -- 'progress:<status>' and 'notify:<message>', in order
local notes = {}

-- Keep the messages out of the test output (the Progress event still fires).
vim.o.messagesopt = 'hit-enter,history:500'

api.nvim_create_autocmd('Progress', {
  pattern = progress.SOURCE,
  callback = function(ev)
    events[#events + 1] = vim.deepcopy(ev.data)
    timeline[#timeline + 1] = 'progress:' .. ev.data.status
  end,
})

-- Every job a test started.
local pids = {}
api.nvim_create_autocmd('User', {
  pattern = 'AgentTerminalOpen',
  callback = function(ev)
    pids[#pids + 1] = ev.data.pid
  end,
})

local function pid_alive(pid)
  local ok, ret = pcall(vim.uv.kill, pid, 0)
  return ok and ret == 0
end

local function write(path, data)
  local f = assert(io.open(path, 'wb'))
  f:write(data)
  f:close()
end

---A launcher that runs `argv` (default: ECHO).
local function launch(argv)
  return function(name)
    return {
      name = name,
      argv = argv or ECHO,
      env = {},
      clear_env = false,
      cwd = tmp,
      cleanup = {},
      session_id = 'session-' .. name,
      warnings = {},
      exit_hints = {},
    }
  end
end

---Wait until terminal `buf` shows the echo agent's R.
local function wait_echo(buf)
  wait_for(function()
    return table.concat(api.nvim_buf_get_lines(buf, 0, -1, false)):find('R', 1, true) ~= nil
  end, 5000, 'the echo agent')
end

---Start agent `name` (its kind comes from the configuration) with `argv` (default: the echo agent,
---once it is ready), in a split it does not focus, replacing the running agent without asking.
---@return integer buf, integer job
local function start(name, argv)
  local buf, err = agent.open(name, { launch = launch(argv), focus = false, confirm = false })
  assert(buf, err)
  if not argv then
    wait_echo(buf)
  end
  return buf, terminal.info().job
end

---An OSC 0 title sequence.
local function title(t)
  return '\27]0;' .. t .. '\7'
end

---A Gemini CLI title: padded to 80 columns.
local function gemini_title(t)
  t = t .. ' (proj)'
  return title(t .. (' '):rep(80 - vim.fn.strchars(t)))
end

---status:text of every event.
local function seen()
  return vim.tbl_map(function(e)
    return e.status .. ':' .. table.concat(e.text, '')
  end, events)
end

local function wait_events(n)
  wait_for(function()
    return #events >= n
  end, 3000, n .. ' progress event(s), got ' .. vim.inspect(seen()))
end

---What Neovim's TUI does with Progress events (vim/_core/defaults.lua; a message without percent
---as Neovim 0.13 handles it), recording what it sends to the terminal instead. setup() again, so
---that agent.progress's autocmd comes after it, as it does after Neovim's.
---@return string[] sent
local function simulate_tui()
  local sent = {}
  api.nvim_ui_send = function(s)
    sent[#sent + 1] = s
  end
  api.nvim_create_autocmd('Progress', {
    group = api.nvim_create_augroup('nvim.progress', { clear = true }),
    callback = function(ev)
      if ev.data.status == 'running' then
        if ev.data.percent ~= nil then
          api.nvim_ui_send(('\27]9;4;1;%d\27\\'):format(ev.data.percent))
        else
          api.nvim_ui_send('\27]9;4;3\27\\')
        end
      else
        api.nvim_ui_send('\27]9;4;0;0\27\\')
      end
    end,
  })
  agent.setup(OPTS)
  return sent
end

describe('progress', function()
  before_each(function()
    tmp = util.realpath(vim.fn.tempname())
    util.mkdir_p(tmp, tonumber('700', 8))
    tmp = util.realpath(tmp)
    events, timeline, notes = {}, {}, {}
    vim.notify = function(msg, level)
      notes[#notes + 1] = { msg = msg, level = level }
      timeline[#timeline + 1] = 'notify:' .. msg
    end
    progress.IDLE_MS = 50
    agent.setup(OPTS)
  end)

  after_each(function()
    agent.teardown()
    wait_for(function()
      return not vim.iter(pids):any(pid_alive)
    end, 5000, 'every agent exited')
    pids = {}
    vim.wait(50)
    api.nvim_ui_send = orig_ui_send
    pcall(api.nvim_del_augroup_by_name, 'nvim.progress')
    progress.IDLE_MS = orig_idle
    vim.notify = orig_notify
    vim.cmd('silent! only')
    vim.cmd('silent! %bwipeout!')
    util.remove_dir(tmp)
  end)

  it("shows Claude Code's work from its title: running, 'busy', the statusline; idle again", function()
    local buf, job = start('claude')
    vim.fn.chansend(job, title('✳ Claude Code'))
    vim.wait(150)
    assert.same({}, events, 'idle from the start: no message')
    vim.fn.chansend(job, title('◐ Claude Code'))
    wait_events(1)
    local e = events[1]
    assert.eq('running', e.status)
    assert.eq('claude', e.title)
    assert.same({ 'working' }, e.text)
    assert.eq('agent.nvim', e.source)
    assert.eq('agent.nvim.' .. buf, e.id)
    assert.truthy(e.percent == 0 or e.percent == nil, 'no percentage')
    assert.same({ agent = 'claude', kind = 'claude', bufnr = buf, pid = terminal.info().pid,
      session_id = 'session-claude' }, e.data)
    assert.eq(1, vim.bo[buf].busy)
    -- (The first message of the process: vim.ui's tracker was started for it.)
    assert.eq('0%%(1) ', vim.ui.progress_status())
    vim.fn.chansend(job, title('◑ Claude Code'))
    vim.wait(150)
    assert.eq(1, #events, 'its animation is no news')
    vim.fn.chansend(job, title('✳ Fix the parser'))
    wait_events(2)
    assert.same({ 'running:working', 'success:waiting for input' }, seen())
    assert.eq(0, vim.bo[buf].busy)
    assert.eq('', vim.ui.progress_status())
  end)

  it('reads the title of Claude Code and Gemini CLI, and the OSC 9;4 of other agents', function()
    local function read(kind, seq)
      return { progress._read(kind, seq) }
    end
    local pad = (' '):rep(40)
    -- Claude Code: its title only.
    assert.same({ true }, read('claude', '\27]0;◐ Claude Code'))
    assert.same({ true }, read('claude', '\27]0;◑ Fix the parser'))
    assert.same({ true }, read('claude', '\27]2;◐ Claude Code'))
    assert.same({ false }, read('claude', '\27]0;✳ Claude Code'))
    assert.same({}, read('claude', '\27]0;Claude Code'))
    assert.same({}, read('claude', '\27]0;'))
    assert.same({}, read('claude', '\27]1;◐ Claude Code'))
    assert.same({}, read('claude', '\27]9;4;3;'))
    -- Gemini CLI: its title only (padded to 80 columns).
    assert.same({ true }, read('gemini', '\27]0;✦  Working… (proj)' .. pad))
    assert.same({ true }, read('gemini', '\27]0;⏲  Working… (proj)' .. pad))
    assert.same({ false }, read('gemini', '\27]0;◇  Ready (proj)' .. pad))
    assert.same({ false }, read('gemini', '\27]0;✋  Action Required (proj)' .. pad))
    assert.same({}, read('gemini', '\27]0;Gemini CLI (proj)' .. pad))
    -- Other agents: OSC 9;4 only.
    assert.same({ true }, read('copilot', '\27]9;4;3;0'))
    assert.same({ false }, read('copilot', '\27]9;4;0;0'))
    assert.same({ true, 42 }, read('copilot', '\27]9;4;1;42'))
    assert.same({ true, 100 }, read('copilot', '\27]9;4;1;250'))
    assert.same({ true }, read('copilot', '\27]9;4;2'))
    assert.same({ true, 7 }, read('copilot', '\27]9;4;4;7'))
    assert.same({}, read('copilot', '\27]9;4;7'))
    assert.same({}, read('copilot', '\27]0;GitHub Copilot'))
    assert.same({}, read('copilot', '\27]9;Copilot is done'))
    assert.same({}, read('opencode', '\27]0;OpenCode'))
    assert.same({ true }, read(nil, '\27]9;4;3'))
    assert.same({}, read(nil, '\27]8;;https://neovim.io'))
    assert.same({}, read(nil, '\27P+q544e\27\\'))
  end)

  it('an idle signal followed by a busy one within IDLE_MS changes nothing; other sequences say nothing',
    function()
      progress.IDLE_MS = 300
      local _, job = start('claude')
      vim.fn.chansend(job, title('◐ x'))
      wait_events(1)
      vim.fn.chansend(job, title('✳ x') .. title('◐ x'))
      vim.wait(500)
      assert.eq(1, #events)
      vim.fn.chansend(job, '\27]1;icon\7\27]8;;https://neovim.io\7link\27]8;;\7\27]7;file:///tmp\7' .. title('x'))
      vim.wait(400)
      assert.eq(1, #events)
      vim.fn.chansend(job, title('✳ x'))
      wait_events(2)
      assert.same({ 'running:working', 'success:waiting for input' }, seen())
    end)

  it("shows Gemini CLI's work from its title", function()
    local _, job = start('gemini')
    vim.fn.chansend(job, gemini_title('◇  Ready'))
    vim.wait(150)
    assert.same({}, events)
    vim.fn.chansend(job, gemini_title('✦  Working…'))
    wait_events(1)
    vim.fn.chansend(job, gemini_title('✋  Action Required'))
    wait_events(2)
    vim.fn.chansend(job, gemini_title('⏲  Working…'))
    wait_events(3)
    vim.fn.chansend(job, gemini_title('◇  Ready'))
    wait_events(4)
    vim.fn.chansend(job, title('Gemini CLI (proj)'))
    vim.wait(150)
    assert.same({ 'running:working', 'success:waiting for input', 'running:working', 'success:waiting for input' },
      seen())
    assert.eq('gemini', events[1].title)
  end)

  it('reads other agents from their OSC 9;4, with its percentage, and Claude Code from its title only', function()
    local _, job = start('claude')
    vim.fn.chansend(job, '\27]9;4;3;\7')
    vim.wait(150)
    assert.same({}, events, "Claude Code's own OSC 9;4 is ignored")
    _, job = start('copilot')
    vim.fn.chansend(job, title('◐ x'))
    vim.wait(150)
    assert.same({}, events, "Copilot CLI's title is ignored")
    vim.fn.chansend(job, '\27]9;4;3;0\7')
    wait_events(1)
    vim.fn.chansend(job, '\27]9;4;3;0\7')
    vim.wait(150)
    assert.eq(1, #events, 'the same state again is no news')
    vim.fn.chansend(job, '\27]9;4;1;30\7')
    wait_events(2)
    assert.eq(30, events[2].percent)
    vim.fn.chansend(job, '\27]9;4;1;30\7')
    vim.wait(150)
    assert.eq(2, #events)
    vim.fn.chansend(job, '\27]9;4;1;60\7')
    wait_events(3)
    assert.eq(60, events[3].percent)
    vim.fn.chansend(job, '\27]9;4;0;0\7')
    wait_events(4)
    assert.same({ 'running:working', 'running:working', 'running:working', 'success:waiting for input' }, seen())
    assert.eq('copilot', events[4].title)
    -- An agent with no definition (no kind): OSC 9;4.
    local buf = assert(terminal.open('custom', { launch = launch(), focus = false }))
    wait_echo(buf)
    vim.fn.chansend(terminal.info().job, title('◐ x') .. '\27]9;4;3\27\\')
    wait_events(5)
    assert.eq('custom', events[5].title)
    assert.eq(nil, events[5].data.kind)
    assert.eq(5, #events)
  end)

  it("shows in the default statusline: progress_status() in the current window, ◐ in the agent's", function()
    local buf, job = start('claude')
    local agent_win = vim.fn.bufwinid(buf)
    local cur = api.nvim_get_current_win()
    assert.truthy(agent_win ~= -1 and agent_win ~= cur)
    local function stl(win)
      return api.nvim_eval_statusline(vim.o.statusline, { winid = win, maxwidth = 200 }).str
    end
    vim.fn.chansend(job, title('◐ x'))
    wait_events(1)
    assert.truthy(stl(agent_win):find('◐ ', 1, true), stl(agent_win))
    assert.truthy(stl(cur):find('0%(1)', 1, true), stl(cur))
    vim.fn.chansend(job, title('✳ x'))
    wait_events(2)
    assert.falsy(stl(agent_win):find('◐', 1, true), stl(agent_win))
    assert.falsy(stl(cur):find('%(1)', 1, true), stl(cur))
  end)

  it('ends the message when the agent is stopped or replaced while it works', function()
    local busy_at_exit = {}
    local au = api.nvim_create_autocmd('User', {
      pattern = 'AgentTerminalExit',
      callback = function(ev)
        busy_at_exit[#busy_at_exit + 1] = vim.bo[ev.data.bufnr].busy
      end,
    })
    local buf, job = start('claude')
    vim.fn.chansend(job, title('◐ x'))
    wait_events(1)
    assert.truthy(agent.stop())
    wait_events(2)
    assert.same({ 'running:working', 'success:stopped' }, seen())
    assert.eq(nil, progress._states[buf])
    -- Replaced: its message ends, and the new agent is read on its own.
    local buf1, job1 = start('claude')
    vim.fn.chansend(job1, title('◐ x'))
    wait_events(3)
    local buf2, job2 = start('gemini')
    wait_events(4)
    assert.eq('success:stopped', seen()[4])
    assert.eq('agent.nvim.' .. buf1, events[4].id)
    vim.fn.chansend(job2, gemini_title('✦  Working…'))
    wait_events(5)
    assert.eq('gemini', events[5].title)
    assert.eq('agent.nvim.' .. buf2, events[5].id)
    -- Not working: no message.
    vim.fn.chansend(job2, gemini_title('◇  Ready'))
    wait_events(6)
    assert.truthy(agent.stop())
    vim.wait(300)
    assert.eq(6, #events)
    api.nvim_del_autocmd(au)
    -- (Our handler runs first: the agent's terminal is no longer busy for the ones after it.)
    assert.same({ 0, 0, 0 }, busy_at_exit)
  end)

  it('ends the message when the agent exits by itself while it works', function()
    agent.setup(vim.tbl_deep_extend('force', OPTS, { terminal = { auto_close = false } }))
    local script = "printf 'R\\033]0;%s Claude Code\\007'; sleep 0.3; exit %d"
    local buf = start('claude', { 'sh', '-c', script:format(HALF, 0) })
    wait_events(2)
    assert.same({ 'running:working', 'success:exited' }, seen())
    -- A finished terminal left open: not busy, no longer read.
    assert.truthy(api.nvim_buf_is_valid(buf))
    assert.eq(0, vim.bo[buf].busy)
    assert.same({}, api.nvim_get_autocmds({ group = 'agent.progress', event = 'TermRequest', buffer = buf }))
    agent.setup(OPTS)
    start('claude', { 'sh', '-c', script:format(HALF, 3) })
    wait_events(4)
    assert.same({ 'running:working', 'failed:exited with code 3' }, vim.list_slice(seen(), 3, 4))
    -- Before terminal.lua's notice, which replaces it in the command line.
    wait_for(function()
      return #notes > 0
    end, 2000, 'the notice')
    assert.same({ 'progress:running', 'progress:success', 'progress:running', 'progress:failed' },
      vim.list_slice(timeline, 1, 4))
    assert.matches('exited with code 3; its terminal is left open', timeline[5])
  end)

  it('ends the message of an agent whose terminal is wiped', function()
    local buf, job = start('claude')
    vim.fn.chansend(job, title('◐ x'))
    wait_events(1)
    vim.cmd('bwipeout! ' .. buf)
    wait_events(2)
    assert.eq('failed', events[2].status)
    assert.eq(nil, progress._states[buf])
    for _, n in ipairs(notes) do
      assert.truthy(n.level ~= vim.log.levels.ERROR, n.msg)
    end
  end)

  it('ends a running message when Neovim quits (VimLeavePre)', function()
    local buf, job = start('claude')
    vim.fn.chansend(job, title('◐ x'))
    wait_events(1)
    api.nvim_exec_autocmds('VimLeavePre', { group = 'agent.progress' })
    assert.same({ 'running:working', 'success:stopped' }, seen())
    assert.eq(0, vim.bo[buf].busy)
    assert.eq(nil, next(progress._states))
    vim.fn.chansend(job, title('◑ x'))
    assert.truthy(agent.stop())
    vim.wait(300)
    assert.eq(2, #events, 'nothing more, the exit included')
  end)

  it("draws the terminal's progress bar busy with no percentage, where Neovim 0.12 draws it empty", function()
    -- No progress bar (Neovim did not start in a terminal): nothing is sent.
    local sent = {}
    api.nvim_ui_send = function(s)
      sent[#sent + 1] = s
    end
    local buf, job = start('claude')
    vim.fn.chansend(job, title('◐ x'))
    wait_events(1)
    assert.same({}, sent)
    vim.fn.chansend(job, title('✳ x'))
    wait_events(2)
    -- With Neovim's handler (here the one of 0.13: an event without percent is already drawn busy).
    sent = simulate_tui()
    vim.fn.chansend(job, title('◐ x'))
    wait_events(3)
    vim.fn.chansend(job, title('✳ x'))
    wait_events(4)
    assert.same({ '\27]9;4;1;0\27\\', '\27]9;4;3\27\\', '\27]9;4;0;0\27\\' }, sent)
    -- A message that has no percent (Neovim 0.13): Neovim draws it busy, agent.nvim does nothing.
    local n = #sent
    api.nvim_exec_autocmds('Progress', {
      pattern = progress.SOURCE,
      data = { id = 'agent.nvim.' .. buf, status = 'running', source = progress.SOURCE, text = { 'working' } },
    })
    assert.same({ '\27]9;4;3\27\\' }, vim.list_slice(sent, n + 1))
    -- Another source's message: not ours to change.
    n = #sent
    local id = api.nvim_echo({ { 'x' } }, false, { kind = 'progress', source = 'other', status = 'running' })
    api.nvim_echo({ { 'x' } }, false, { kind = 'progress', source = 'other', status = 'success', id = id })
    assert.same({ '\27]9;4;1;0\27\\', '\27]9;4;0;0\27\\' }, vim.list_slice(sent, n + 1))
    -- An agent's own percentage is drawn as it is.
    _, job = start('copilot')
    n = #sent
    vim.fn.chansend(job, '\27]9;4;1;30\7')
    wait_for(function()
      return #sent > n
    end, 3000, 'the bar')
    vim.wait(100)
    assert.same({ '\27]9;4;1;30\27\\' }, vim.list_slice(sent, n + 1))
  end)

  it('setup() again reads on the running agent; progress.enabled = false ends the message and reads nothing',
    function()
      local buf, job = start('claude')
      agent.setup(OPTS)
      assert.eq(1, #api.nvim_get_autocmds({ group = 'agent.progress', event = 'TermRequest', buffer = buf }))
      vim.fn.chansend(job, title('◐ x'))
      wait_events(1)
      agent.setup(vim.tbl_deep_extend('force', OPTS, { progress = { enabled = false } }))
      assert.same({ 'running:working', 'success:progress off' }, seen())
      assert.eq(0, vim.bo[buf].busy)
      assert.eq(nil, next(progress._states))
      vim.fn.chansend(job, title('✳ x') .. title('◐ x'))
      vim.wait(200)
      assert.eq(2, #events)
      -- Enabled again: the running agent is read (idle until it says otherwise).
      agent.setup(OPTS)
      vim.fn.chansend(job, title('◐ x'))
      wait_events(3)
      assert.eq('running', events[3].status)
      -- A burst of updates: one message, and none in :messages.
      local burst = {}
      for i = 1, 50 do
        burst[#burst + 1] = title((i % 2 == 0 and '◐' or '◑') .. ' x')
      end
      vim.fn.chansend(job, table.concat(burst))
      vim.wait(300)
      assert.eq(3, #events)
      assert.falsy(vim.fn.execute('messages'):find('working', 1, true))
    end)

  it('reads only agent terminals', function()
    local buf = api.nvim_create_buf(false, false)
    local job
    api.nvim_buf_call(buf, function()
      job = vim.fn.jobstart(ECHO, { term = true })
    end)
    wait_echo(buf)
    vim.fn.chansend(job, title('◐ x') .. '\27]9;4;3\7')
    vim.wait(200)
    vim.fn.jobstop(job)
    assert.same({}, events)
  end)

  it("a real TUI draws the agent's work as the terminal's progress bar", function()
    -- Neovim with agent.nvim, in a terminal of this one: what it sends to its terminal arrives here.
    local script = tmp .. '/inner.lua'
    write(script, ([[
vim.opt.rtp:prepend(%q)
vim.o.messagesopt = 'hit-enter,history:500'
local agent = require('agent')
agent.setup({ terminal = { layout = 'split', start_insert = false } })
local buf = agent.open('claude', { focus = false, launch = function(name)
  return { name = name, argv = { 'sh', '-c', 'stty raw -echo 2>/dev/null; printf R; exec cat' }, env = {},
    cwd = %q, cleanup = {}, session_id = 'inner', warnings = {}, exit_hints = {} }
end })
vim.wait(5000, function()
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false)):find('R', 1, true) ~= nil
end)
local job = require('agent.terminal').info().job
local function title(t, ms)
  vim.fn.chansend(job, '\27]0;' .. t .. '\7')
  vim.wait(ms)
end
title('◐ Claude Code', 500)
title('✳ Claude Code', 800)
title('◐ Claude Code', 500)
vim.cmd('qa!')
]]):format(TEST_ROOT, tmp))
    local buf = api.nvim_create_buf(false, false)
    local seqs = {}
    api.nvim_create_autocmd('TermRequest', {
      buffer = buf,
      callback = function(ev)
        if ev.data.sequence:find('^\27%]9;4;') then
          seqs[#seqs + 1] = ev.data.sequence
        end
      end,
    })
    local code
    api.nvim_buf_call(buf, function()
      vim.fn.jobstart({ vim.v.progpath, '-u', 'NONE', '-i', 'NONE', '-n', '-c', 'luafile ' .. script }, {
        term = true,
        on_exit = function(_, c)
          code = c
        end,
      })
    end)
    wait_for(function()
      return code ~= nil
    end, 20000, 'the inner Neovim quit')
    vim.wait(100)
    assert.eq(0, code)
    -- Working (Neovim's empty bar, then ours), idle, working, and cleared when it quits.
    assert.same({ '\27]9;4;1;0', '\27]9;4;3', '\27]9;4;0;0', '\27]9;4;1;0', '\27]9;4;3', '\27]9;4;0;0' }, seqs)
  end)
end)
