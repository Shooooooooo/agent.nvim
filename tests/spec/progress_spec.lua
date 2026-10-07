local terminal = require('agent.terminal')
local progress = require('agent.progress')
local statusline = require('agent.statusline')
local config = require('agent.config')
local util = require('agent.util')

local BUSY, IDLE = '\27]9;4;3;\7', '\27]9;4;0;0\7'
local HAS_BUSY = vim.fn.exists('+busy') == 1

local tmp
local orig_notify = vim.notify

---A launcher for an agent that runs `script` (sh -c) with READY = <tmp>/ready.
local function launcher(script)
  return function(name)
    return {
      name = name,
      argv = { 'sh', '-c', script },
      env = { READY = tmp .. '/ready' },
      clear_env = false,
      cwd = tmp,
      cleanup = {},
      session_id = 'session-p',
      warnings = {},
      exit_hints = {},
    }
  end
end

---Start an agent that writes back what it is sent (a raw terminal): what terminal.send() sends
---is what the agent "prints".
---@return integer bufnr
local function start_echo(name)
  local buf = terminal.open(name or 'fake', {
    launch = launcher([[stty raw -echo 2>/dev/null; : > "$READY"; exec cat]]),
  })
  wait_for(function()
    return vim.fn.filereadable(tmp .. '/ready') == 1
  end, 5000, 'the agent is ready')
  return assert(buf)
end

---@param seq string
local function emit(seq)
  assert.truthy(terminal.send(seq, { bracketed = false }))
end

local function wait_state(state, percent)
  wait_for(function()
    local p = progress.get()
    return p ~= nil and p.state == state and p.percent == percent
  end, 5000, 'state ' .. state)
end

local events
vim.api.nvim_create_autocmd('User', {
  pattern = 'AgentProgress',
  callback = function(ev)
    if events then
      events[#events + 1] = ev.data
    end
  end,
})

describe('progress', function()
  before_each(function()
    tmp = util.realpath(vim.fn.tempname())
    util.mkdir_p(tmp, tonumber('700', 8))
    tmp = util.realpath(tmp)
    vim.notify = function() end
    events = {}
    config.setup({ terminal = { layout = 'split', split_side = 'right', auto_close = true, start_insert = false } })
    terminal.setup({})
  end)

  after_each(function()
    terminal.stop()
    vim.wait(100)
    events = nil
    vim.notify = orig_notify
    util.remove_dir(tmp)
  end)

  it('parse reads the OSC 9;4 states and percentages', function()
    local function parse(s)
      return { progress.parse(s) }
    end
    assert.same({ 'busy' }, parse('\27]9;4;3;'))
    assert.same({ 'busy' }, parse('\27]9;4;3;0'))
    assert.same({ 'idle' }, parse('\27]9;4;0;'))
    assert.same({ 'idle' }, parse('\27]9;4;0'))
    assert.same({ 'progress', 42 }, parse('\27]9;4;1;42'))
    assert.same({ 'progress', 100 }, parse('\27]9;4;1;250'))
    assert.same({ 'progress', 0 }, parse('\27]9;4;1'))
    assert.same({ 'error', 7 }, parse('\27]9;4;2;7'))
    assert.same({ 'error' }, parse('\27]9;4;2'))
    assert.same({ 'paused', 50 }, parse('\27]9;4;4;50\7'))
    assert.same({}, parse('\27]9;4;5;1'))
    assert.same({}, parse('\27]9;4;'))
    assert.same({}, parse('\27]9;hello'))
    assert.same({}, parse('\27]0;title'))
    assert.same({}, parse(nil))
  end)

  it('follows what the agent reports: AgentProgress on each change, busy while it works', function()
    local buf = start_echo()
    local p = progress.get()
    assert.same({ name = 'fake', bufnr = buf, state = 'idle', working = false }, {
      name = p.name, bufnr = p.bufnr, state = p.state, working = p.working,
    })
    assert.falsy(progress.working())

    emit(BUSY)
    wait_state('busy', nil)
    assert.truthy(progress.working())
    if HAS_BUSY then
      assert.eq(1, vim.bo[buf].busy)
    end
    local since = progress.get().since
    -- Copilot repeats it every 5 s: no new event. Nor for other sequences.
    emit(BUSY .. '\27]0;a title\7\27]9;hello\7\27]9;4;1;42\27\\')
    wait_state('progress', 42)
    assert.truthy(progress.get().since >= since)
    emit('\27]9;4;1;60\7')
    wait_state('progress', 60)
    emit(IDLE)
    wait_state('idle', nil)
    assert.falsy(progress.working())
    if HAS_BUSY then
      assert.eq(0, vim.bo[buf].busy)
    end
    local seen = vim.tbl_map(function(e)
      return { e.state, e.percent, e.working, e.name, e.bufnr }
    end, events)
    assert.same({
      { 'busy', nil, true, 'fake', buf },
      { 'progress', 42, true, 'fake', buf },
      { 'progress', 60, true, 'fake', buf },
      { 'idle', nil, false, 'fake', buf },
    }, seen)

    emit('\27]9;4;2;5\7')
    wait_state('error', 5)
    assert.falsy(progress.working())
  end)

  it('status() and :AgentStatus show it', function()
    local agent = require('agent')
    agent.setup({ terminal = { layout = 'split', split_side = 'right', start_insert = false } })
    vim.cmd.runtime('plugin/agent.lua')
    start_echo()
    assert.eq('idle', agent.status().agent.progress.state)
    emit(BUSY)
    wait_state('busy', nil)
    local st = agent.status().agent.progress
    assert.eq('busy', st.state)
    assert.eq(true, st.working)
    assert.eq('number', type(st.since))
    local out = vim.api.nvim_exec2('AgentStatus', { output = true }).output
    assert.matches('running %(pid %d+%), visible, working', out)
  end)

  it('an agent that stops or exits is no longer working', function()
    start_echo()
    emit(BUSY)
    wait_state('busy', nil)
    assert.truthy(terminal.stop())
    assert.eq(nil, progress.get())
    assert.falsy(progress.working())
    assert.same({ true, false }, vim.tbl_map(function(e)
      return e.working
    end, events))

    events = {}
    terminal.open('fake', { launch = launcher([[printf '\033]9;4;3;\007'; sleep 1; exit 0]]) })
    wait_state('busy', nil)
    wait_for(function()
      return progress.get() == nil
    end, 5000, 'the exit')
    assert.same({ true, false }, vim.tbl_map(function(e)
      return e.working
    end, events))
  end)

  it("follows only the latest agent: a replaced agent's reports are ignored", function()
    local a = vim.api.nvim_create_buf(false, true)
    local b = vim.api.nvim_create_buf(false, true)
    local function request(buf, seq)
      vim.api.nvim_exec_autocmds('TermRequest', { buffer = buf, data = { sequence = seq, cursor = { 1, 0 } } })
    end
    progress.attach(a, 'one')
    request(a, BUSY)
    assert.truthy(progress.working())
    progress.attach(b, 'two')
    assert.eq('two', progress.get().name)
    assert.falsy(progress.working())
    request(a, BUSY)
    assert.falsy(progress.working())
    progress.detach(a)
    assert.eq('two', progress.get().name)
    request(b, BUSY)
    assert.truthy(progress.working())
    assert.same({ { 'one', true }, { 'one', false }, { 'two', true } }, vim.tbl_map(function(e)
      return { e.name, e.working }
    end, events))
    progress.detach(b)
    assert.eq(nil, progress.get())
    vim.api.nvim_buf_delete(a, { force = true })
    vim.api.nvim_buf_delete(b, { force = true })
  end)
end)

describe('statusline', function()
  local orig_now, orig_cmd = util.now_ms, vim.cmd

  before_each(function()
    tmp = util.realpath(vim.fn.tempname())
    util.mkdir_p(tmp, tonumber('700', 8))
    tmp = util.realpath(tmp)
    vim.notify = function() end
    events = {}
    config.setup({ terminal = { layout = 'split', split_side = 'right', auto_close = true, start_insert = false } })
    terminal.setup({})
  end)

  after_each(function()
    util.now_ms, vim.cmd = orig_now, orig_cmd
    terminal.stop()
    vim.wait(100)
    events = nil
    vim.notify = orig_notify
    util.remove_dir(tmp)
  end)

  it('get() is a spinner and the agent name while it works, else empty', function()
    assert.eq('', statusline.get())
    start_echo('my-agent')
    assert.eq('', statusline.get())
    emit(BUSY)
    wait_state('busy', nil)
    util.now_ms = function()
      return 1000
    end
    assert.eq(statusline.FRAMES[1] .. ' my-agent', statusline.get())
    util.now_ms = function()
      return 1000 + statusline.INTERVAL_MS
    end
    assert.eq(statusline.FRAMES[2] .. ' my-agent', statusline.get())
    assert.eq(statusline.FRAMES[2], statusline.frame())
    util.now_ms = orig_now
    emit(IDLE)
    wait_state('idle', nil)
    assert.eq('', statusline.get())
  end)

  it('heirline() is a component shown while the agent works, its text escaped', function()
    local c = statusline.heirline({ hl = 'DiagnosticInfo' })
    assert.eq('DiagnosticInfo', c.hl)
    assert.falsy(c.condition(c))
    start_echo('50%')
    assert.falsy(c.condition(c))
    emit(BUSY)
    wait_state('busy', nil)
    assert.truthy(c.condition(c))
    assert.matches('^' .. vim.pesc(statusline.frame()) .. ' 50%%%%$', c.provider(c))
    assert.eq(nil, statusline.heirline().hl)
  end)

  it('redraws the statuslines while the agent works, and once when it stops', function()
    local redraws = 0
    vim.cmd = setmetatable({}, {
      __call = function(_, c)
        if c == 'redrawstatus!' then
          redraws = redraws + 1
        end
        return orig_cmd(c)
      end,
      __index = orig_cmd,
    })
    start_echo()
    vim.wait(250)
    assert.eq(0, redraws)
    assert.falsy(statusline._ticking())
    emit(BUSY)
    wait_state('busy', nil)
    assert.truthy(statusline._ticking())
    wait_for(function()
      return redraws >= 3
    end, 2000, 'redraws while working')
    emit(IDLE)
    wait_state('idle', nil)
    assert.falsy(statusline._ticking())
    vim.wait(50)
    local n = redraws
    vim.wait(300)
    assert.eq(n, redraws)
  end)

  it('starts redrawing when it is loaded while the agent works', function()
    start_echo()
    -- The loaded module no longer follows the agent: a fresh copy is loaded below.
    vim.api.nvim_del_augroup_by_name('agent.statusline')
    emit(BUSY)
    wait_state('busy', nil)
    package.loaded['agent.statusline'] = nil
    local fresh = require('agent.statusline')
    assert.truthy(fresh._ticking())
    emit(IDLE)
    wait_state('idle', nil)
    assert.falsy(fresh._ticking())
    statusline = fresh
  end)
end)
