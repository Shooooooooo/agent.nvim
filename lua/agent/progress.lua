---@mod agent.progress The agent's work as a Neovim progress message
---
--- While the agent works on a prompt, a progress message runs (|progress-message|: nvim_echo() with
--- kind = 'progress', source 'agent.nvim', the agent's name as its title) and 'busy' is 1 in its
--- terminal buffer. Neovim shows them: the default 'statusline' (vim.ui.progress_status() in the
--- current window, ◐ in the windows of a 'busy' buffer), the host terminal's progress bar (OSC 9;4,
--- from the TUI's Progress handler, augroup nvim.progress) and the command line ('messagesopt'
--- "progress:c"). The message ends (success) when the agent is idle or waits for the user, and when
--- it exits (failed when it exits with an error), is stopped, or Neovim quits.
---
--- What the agent does is read from its terminal, by one buffer-local TermRequest autocmd per agent
--- (TermRequest also gets the title sequences):
---  * Claude Code and Gemini CLI by the glyph their title starts with (M.GLYPHS). Their own OSC
---    9;4, when they send one, is ignored: Claude Code keeps it busy during a permission prompt.
---  * every other agent by the OSC 9;4 progress it sends itself (Copilot CLI does, in the terminals
---    it recognizes).
--- An idle signal ends the message only when no busy signal follows within M.IDLE_MS. A message is
--- sent only when the agent starts or stops working (or its percentage changes).
---
--- The lifecycle comes from agent.terminal's User events: AgentTerminalOpen starts reading the
--- agent's terminal, AgentTerminalExit ends its message (`stopped`: agent.nvim stopped it). Both
--- run from the main loop, where a message replaces the previous one instead of piling up into a
--- hit-enter prompt. VimLeavePre ends a running message too: Neovim leaves the host terminal's bar
--- as it is when it exits.
---
--- Neovim 0.12 gives a message without percentage `percent = 0`, and its TUI handler draws an empty
--- bar for it (OSC 9;4;1;0). A Progress autocmd of ours, defined after that handler (Neovim's
--- defaults create it at startup), follows it with the busy state that has no percentage (OSC
--- 9;4;3). Where Neovim leaves `percent` out, it sends that state itself and ours does nothing.
local config = require('agent.config')
local log = require('agent.log')

local api = vim.api

local M = {}

---The source of the messages: the pattern of a Progress autocmd for them.
M.SOURCE = 'agent.nvim'
---An idle signal ends the message only when no busy signal follows within this many ms.
M.IDLE_MS = 300

---Agent kinds read by their title: the glyph it starts with means busy (true) or idle (false;
---waiting for the user included).
M.GLYPHS = {
  -- Claude Code: ◐ and ◑ alternate while it works, ✳ otherwise (always ✳ under tmux, screen or
  -- zellij).
  claude = { ['◐'] = true, ['◑'] = true, ['◒'] = true, ['◓'] = true, ['✳'] = false },
  -- Gemini CLI: ✦ working, ⏲ a shell command running, ◇ ready, ✋ action required.
  gemini = { ['✦'] = true, ['⏲'] = true, ['◇'] = false, ['✋'] = false },
}

---The texts of the messages.
M.TEXT = {
  busy = 'working',
  idle = 'waiting for input',
  stopped = 'stopped',
  exited = 'exited',
  off = 'progress off',
}

local GROUP = 'agent.progress'
---OSC 9;4 state 3: busy, with no percentage.
local BAR_BUSY = '\027]9;4;3\027\\'
---The first UTF-8 character.
local FIRST_CHAR = '^[^\128-\191][\128-\191]*'

---@class agent.ProgressState
---@field buf integer           the agent's terminal buffer
---@field name string           the agent: the title of the message
---@field kind string|nil       its kind (agent.agents), nil for a name with no definition
---@field pid integer|nil
---@field session_id string|nil
---@field id string             the message id: 'agent.nvim.<buf>'
---@field busy boolean          its message is running (also while an idle signal waits)
---@field percent integer|nil   from the agent's OSC 9;4; nil: no percentage
---@field idle table|nil        the token of the idle signal that waits
---@field au integer|nil        its TermRequest autocmd

---The agents read, by terminal buffer.
---@type table<integer, agent.ProgressState>
local states = {}
local augroup = nil ---@type integer|nil
local primed = false

---Whether Neovim draws progress messages as the host terminal's progress bar (the Progress handler
---of its TUI, augroup nvim.progress: Neovim started in a terminal).
---@return boolean
function M.host_bar()
  local ok, aus = pcall(api.nvim_get_autocmds, { group = 'nvim.progress', event = 'Progress' })
  return ok and #aus > 0
end

---What a sequence from the agent's terminal says.
---@param kind string|nil  the agent's kind
---@param seq string  a TermRequest sequence, e.g. "\27]0;✳ Claude Code", "\27]9;4;1;50"
---@return boolean|nil busy  nil: nothing
---@return integer|nil percent
local function read(kind, seq)
  local glyphs = kind and M.GLYPHS[kind]
  if glyphs then
    local title = seq:match('^\27%][02];(.*)')
    local c = title and title:match(FIRST_CHAR)
    if c then
      return glyphs[c], nil
    end
    return nil, nil
  end
  local s, n = seq:match('^\27%]9;4;(%d+);?(%d*)')
  if s == '0' then
    return false, nil
  elseif s == '3' then
    return true, nil
  elseif s == '1' or s == '2' or s == '4' then
    local p = tonumber(n)
    return true, p and math.max(0, math.min(100, p)) or nil
  end
  return nil, nil
end
M._read = read

---Send the message of `st` and set 'busy' in its terminal. 'busy' also redraws every statusline,
---the current window's vim.ui.progress_status() included: nvim_echo() redraws none.
---@param st agent.ProgressState
---@param status 'running'|'success'|'failed'
---@param text string
local function emit(st, status, text)
  local ok, err = pcall(api.nvim_echo, { { text } }, false, {
    kind = 'progress',
    id = st.id,
    source = M.SOURCE,
    title = st.name,
    status = status,
    percent = status == 'running' and st.percent or nil,
    data = { agent = st.name, kind = st.kind, bufnr = st.buf, pid = st.pid, session_id = st.session_id },
  })
  if not ok then
    log.scope('progress').debug('%s: nvim_echo failed: %s', st.name, tostring(err))
  end
  if api.nvim_buf_is_valid(st.buf) then
    pcall(function()
      vim.bo[st.buf].busy = status == 'running' and 1 or 0
    end)
  end
end

---A busy (true) or idle (false) signal from the agent. Busy starts the message, or updates its
---percentage; idle ends it, unless a busy signal comes within M.IDLE_MS.
---@param st agent.ProgressState
---@param busy boolean|nil
---@param percent integer|nil
local function signal(st, busy, percent)
  if busy == nil then
    return
  end
  if busy then
    st.idle = nil
    if not st.busy or st.percent ~= percent then
      st.busy, st.percent = true, percent
      emit(st, 'running', M.TEXT.busy)
    end
  elseif st.busy and not st.idle then
    local token = {}
    st.idle = token
    vim.defer_fn(function()
      if st.idle == token and states[st.buf] == st then
        st.idle, st.busy, st.percent = nil, false, nil
        emit(st, 'success', M.TEXT.idle)
      end
    end, M.IDLE_MS)
  end
end

---Read the agent's terminal: every OSC sequence it sends (TermRequest), its title included. Not
---once agent.nvim has stopped it or replaced it (its job may still be exiting).
---@param st agent.ProgressState
local function listen(st)
  if not augroup or not api.nvim_buf_is_valid(st.buf) then
    return
  end
  st.au = api.nvim_create_autocmd('TermRequest', {
    group = augroup,
    buffer = st.buf,
    desc = 'agent.nvim: whether the agent is working',
    callback = function(ev)
      local seq = type(ev.data) == 'table' and ev.data.sequence
      if type(seq) == 'string' and states[st.buf] == st and require('agent.terminal').bufnr() == st.buf then
        signal(st, read(st.kind, seq))
      end
    end,
  })
end

---vim.ui.progress_status() starts tracking messages at its first call, and the default 'statusline'
---calls it only once vim.ui is loaded: call it before the first message, so that it counts it.
local function prime()
  if primed then
    return
  end
  primed = true
  pcall(function()
    vim.ui.progress_status()
  end)
end

---Start reading the agent in terminal `d.bufnr`.
---@param d table  AgentTerminalOpen data (or the like): name, bufnr, pid, session_id
local function attach(d)
  if type(d) ~= 'table' or type(d.bufnr) ~= 'number' or states[d.bufnr] or not api.nvim_buf_is_valid(d.bufnr) then
    return
  end
  local ok, def = pcall(require('agent.agents').get, d.name)
  ---@type agent.ProgressState
  local st = {
    buf = d.bufnr,
    name = tostring(d.name),
    kind = ok and def and def.kind or nil,
    pid = d.pid,
    session_id = d.session_id,
    id = ('agent.nvim.%d'):format(d.bufnr),
    busy = false,
  }
  states[st.buf] = st
  listen(st)
  prime()
end

---Stop reading `st`'s agent and end its message, when it runs.
---@param st agent.ProgressState
---@param status 'success'|'failed'
---@param text string
local function finish(st, status, text)
  states[st.buf] = nil
  st.idle = nil
  if st.au then
    pcall(api.nvim_del_autocmd, st.au)
    st.au = nil
  end
  if st.busy then
    st.busy, st.percent = false, nil
    emit(st, status, text)
  end
end

---End every message, and stop reading the agents.
---@param text string
local function finish_all(text)
  for _, st in ipairs(vim.tbl_values(states)) do
    finish(st, 'success', text)
  end
end

---The agent's job has exited: end its message.
---@param d table  AgentTerminalExit data: name, code, bufnr, session_id, stopped
local function on_exit(d)
  local st = type(d) == 'table' and states[d.bufnr]
  if not st then
    return
  end
  if d.stopped then
    finish(st, 'success', M.TEXT.stopped)
  elseif d.code == 0 then
    finish(st, 'success', M.TEXT.exited)
  else
    finish(st, 'failed', ('exited with code %s'):format(tostring(d.code)))
  end
end

---Our message has just started (or changed) with `percent = 0`, the value Neovim 0.12 gives a
---message without one, and the TUI's handler (it runs first) has drawn an empty bar for it: draw
---the busy state with no percentage instead. Where Neovim leaves `percent` out, it does that itself.
---@param ev table  Progress event
local function follow_bar(ev)
  local d = ev.data
  if type(d) ~= 'table' or d.status ~= 'running' or d.percent ~= 0 then
    return
  end
  for _, st in pairs(states) do
    if st.id == d.id then
      if st.percent == nil and M.host_bar() then
        pcall(api.nvim_ui_send, BAR_BUSY)
      end
      return
    end
  end
end

---Read the agents (agent.setup() calls this, after agent.terminal.setup()). Safe to call again: a
---running agent is read on. With progress.enabled = false, the running message ends and nothing is
---read.
function M.setup()
  -- (Clearing the group also deletes the TermRequest autocmds: listen() again below.)
  augroup = api.nvim_create_augroup(GROUP, { clear = true })
  for _, st in pairs(states) do
    st.au = nil
  end
  if config.get().progress.enabled == false then
    finish_all(M.TEXT.off)
    return
  end
  api.nvim_create_autocmd('User', {
    group = augroup,
    pattern = 'AgentTerminalOpen',
    desc = "agent.nvim: read the agent's terminal for progress",
    callback = function(ev)
      attach(ev.data)
    end,
  })
  api.nvim_create_autocmd('User', {
    group = augroup,
    pattern = 'AgentTerminalExit',
    desc = "agent.nvim: end the agent's progress message",
    callback = function(ev)
      on_exit(ev.data)
    end,
  })
  api.nvim_create_autocmd('VimLeavePre', {
    group = augroup,
    desc = "agent.nvim: end the agent's progress message (and the terminal's progress bar)",
    callback = function()
      finish_all(M.TEXT.stopped)
    end,
  })
  api.nvim_create_autocmd('Progress', {
    group = augroup,
    pattern = M.SOURCE,
    desc = "agent.nvim: the terminal's progress bar without a percentage",
    callback = follow_bar,
  })
  for _, st in pairs(states) do
    listen(st)
  end
  local info = require('agent.terminal').info()
  if info and info.running then
    attach({ name = info.name, bufnr = info.bufnr, pid = info.pid, session_id = info.session_id })
  end
end

---The agents read, by terminal buffer (for tests).
M._states = states

return M
