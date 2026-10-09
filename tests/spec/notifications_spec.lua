-- agent.notifications: the agent's desktop notifications (OSC 777) passed on to the terminal Neovim
-- runs in, with nvim_ui_send().
local agent = require('agent')
local notifications = require('agent.notifications')
local terminal = require('agent.terminal')
local util = require('agent.util')

local api = vim.api

-- An agent that sends back what it reads: what a test chansend()s comes out of the agent's
-- terminal as if the agent had written it (raw mode: the bytes go through as they are, no echo).
local ECHO = { 'sh', '-c', 'stty raw -echo 2>/dev/null; printf R; exec cat' }

local OPTS = { terminal = { layout = 'split', start_insert = false } }
-- What Claude Code sends in Ghostty (it ends it with BEL), and what goes on to the host terminal.
local NOTE = '\27]777;notify;Claude Code;Claude is waiting for your input'
local NOTE_OUT = NOTE .. '\27\\'

local orig_ui_send = api.nvim_ui_send
local tmp
local sent = {} -- what nvim_ui_send() got

-- Keep the progress messages (a title below starts one) out of the test output.
vim.o.messagesopt = 'hit-enter,history:500'

-- Every job a test started.
local pids = {}
api.nvim_create_autocmd('User', {
  pattern = 'AgentTerminalOpen',
  callback = function(ev)
    pids[#pids + 1] = ev.data.pid
  end,
})

local function write(path, data)
  local f = assert(io.open(path, 'wb'))
  f:write(data)
  f:close()
end

---A launcher that runs the echo agent.
local function launch(name)
  return {
    name = name,
    argv = ECHO,
    env = {},
    clear_env = false,
    cwd = tmp,
    cleanup = {},
    session_id = 'session-' .. name,
    warnings = {},
    exit_hints = {},
  }
end

---Wait until terminal `buf` shows the echo agent's R.
local function wait_echo(buf)
  wait_for(function()
    return table.concat(api.nvim_buf_get_lines(buf, 0, -1, false)):find('R', 1, true) ~= nil
  end, 5000, 'the echo agent')
end

---Start agent `name` (its kind comes from the configuration), the echo agent, in a split it does
---not focus, replacing the running agent without asking.
---@return integer buf, integer job
local function start(name)
  local buf, err = agent.open(name, { launch = launch, focus = false, confirm = false })
  assert(buf, err)
  wait_echo(buf)
  return buf, terminal.info().job
end

-- A sequence sent after the others: once Neovim has read it, it has read them.
local DONE = '\27]1337;agent-nvim-test-done'

---Send `data` out of the job of terminal `buf`, and wait until Neovim has read it all (the
---TermRequest autocmds of agent.nvim, defined before this one, have run by then).
local function emit(buf, job, data)
  local done = false
  local au = api.nvim_create_autocmd('TermRequest', {
    buffer = buf,
    callback = function(ev)
      done = done or ev.data.sequence == DONE
    end,
  })
  vim.fn.chansend(job, data .. DONE .. '\7')
  wait_for(function()
    return done
  end, 3000, 'the sequences read')
  api.nvim_del_autocmd(au)
end

describe('notifications', function()
  before_each(function()
    tmp = util.realpath(vim.fn.tempname())
    util.mkdir_p(tmp, tonumber('700', 8))
    tmp = util.realpath(tmp)
    sent = {}
    api.nvim_ui_send = function(s)
      sent[#sent + 1] = s
    end
    agent.setup(OPTS)
  end)

  after_each(function()
    agent.teardown()
    wait_for(function()
      return not vim.iter(pids):any(pid_alive)
    end, 5000, 'every agent exited')
    pids = {}
    api.nvim_ui_send = orig_ui_send
    vim.cmd('silent! only')
    vim.cmd('silent! %bwipeout!')
    util.remove_dir(tmp)
  end)

  it("passes the agent's notifications on to the terminal Neovim runs in, terminated by ST", function()
    local buf, job = start('claude')
    emit(buf, job, NOTE .. '\7')
    assert.same({ NOTE_OUT }, sent)
    -- Any agent's, ST-terminated too.
    buf, job = start('copilot')
    emit(buf, job, '\27]777;notify;Copilot;Task done\27\\')
    assert.same({ NOTE_OUT, '\27]777;notify;Copilot;Task done\27\\' }, sent)
  end)

  it('passes nothing else on', function()
    local buf, job = start('claude')
    emit(buf, job, table.concat({
      '\27]0;◐ Claude Code\7', -- its title
      '\27]9;4;3;\7', -- its own progress bar
      '\27]9;Claude is waiting for your input\7', -- iTerm2's notification
      '\27]99;i=1:d=0:p=title;Claude Code\27\\', -- kitty's
      '\27]777;preexec\7', -- VTE's
      '\27]777;notifyx;a;b\7',
      '\27]7;file:///tmp\7',
    }))
    assert.same({}, sent)
  end)

  it('turns control characters in the title and body into spaces', function()
    local function pass_on(s)
      return notifications._pass_on('\27]777;notify;' .. s)
    end
    assert.eq('\27]777;notify;a b;c  d\27\\', pass_on('a\27b;c\1\127d'))
    -- C1 (U+0080 to U+009F), but not the bytes of other characters (✳ is \226\156\179).
    assert.eq('\27]777;notify;✳ Claude Code;a b c\27\\', pass_on('✳ Claude Code;a\194\156b\194\128c'))
    assert.eq('\27]777;notify;\27\\', pass_on(''))
    assert.eq(nil, notifications._pass_on('\27]777;preexec'))
    assert.eq(nil, notifications._pass_on('\27]0;✳ Claude Code'))
  end)

  it("reads only the agent's terminal", function()
    local buf = api.nvim_create_buf(false, false)
    local job
    api.nvim_buf_call(buf, function()
      job = vim.fn.jobstart(ECHO, { term = true })
    end)
    wait_echo(buf)
    emit(buf, job, NOTE .. '\7')
    vim.fn.jobstop(job)
    assert.same({}, sent)
  end)

  it('notifications.enabled = false passes nothing on; setup() again passes them on again', function()
    local buf, job = start('claude')
    agent.setup(vim.tbl_deep_extend('force', OPTS, { notifications = { enabled = false } }))
    assert.same({}, api.nvim_get_autocmds({ group = 'agent.notifications' }))
    emit(buf, job, NOTE .. '\7')
    assert.same({}, sent)
    agent.setup(OPTS)
    emit(buf, job, NOTE .. '\7')
    assert.same({ NOTE_OUT }, sent)
  end)

  it('a real TUI passes them on to its terminal at once', function()
    -- Neovim with agent.nvim, in a terminal of this one: what it sends to its terminal arrives here.
    -- It waits with timers, in its main loop, as it does in use: nvim_ui_send() goes out with the
    -- next flush of the screen, which the main loop does after each event (Neovim's own exit
    -- flushes too, so it must not quit before the notification is here).
    local script = tmp .. '/inner.lua'
    write(script, ([[
vim.opt.rtp:prepend(%q)
local agent = require('agent')
agent.setup({ terminal = { layout = 'split', start_insert = false } })
local buf = agent.open('claude', { focus = false, launch = function(name)
  return { name = name, argv = { 'sh', '-c', 'stty raw -echo 2>/dev/null; printf R; exec cat' }, env = {},
    cwd = %q, cleanup = {}, session_id = 'inner', warnings = {}, exit_hints = {} }
end })
local function ready()
  if not table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false)):find('R', 1, true) then
    return vim.defer_fn(ready, 50)
  end
  vim.fn.chansend(require('agent.terminal').info().job,
    '\27]777;notify;Claude Code;Claude is waiting for your input\7')
end
ready()
]]):format(TEST_ROOT, tmp))
    local buf = api.nvim_create_buf(false, false)
    local seqs = {}
    api.nvim_create_autocmd('TermRequest', {
      buffer = buf,
      callback = function(ev)
        if ev.data.sequence:find('^\27%]777;') then
          seqs[#seqs + 1] = ev.data.sequence
        end
      end,
    })
    local job, code
    api.nvim_buf_call(buf, function()
      job = vim.fn.jobstart({ vim.v.progpath, '-u', 'NONE', '-i', 'NONE', '-n', '-c', 'luafile ' .. script }, {
        term = true,
        on_exit = function(_, c)
          code = c
        end,
      })
    end)
    wait_for(function()
      return #seqs > 0
    end, 20000, 'the notification')
    assert.eq(nil, code, 'the inner Neovim runs on')
    vim.fn.chansend(job, '\28\14:qa!\r')
    wait_for(function()
      return code ~= nil
    end, 10000, 'the inner Neovim quit')
    vim.wait(100)
    assert.eq(0, code)
    assert.same({ NOTE }, seqs)
    -- (This Neovim runs no agent: it passed nothing on.)
    assert.same({}, sent)
  end)
end)
