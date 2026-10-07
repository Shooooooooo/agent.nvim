---@mod agent.progress Whether the agent is working: its OSC 9;4 progress reports
---
--- Some agents tell their terminal when they are working with the ConEmu progress sequence OSC 9;4
--- (ESC ] 9 ; 4 ; <state> [; <percent>] BEL or ST), which terminals show as a progress bar or a tab
--- indicator: state 3 (indeterminate) while a turn runs (also while it waits on a permission
--- prompt), 0 when it ends. Claude Code sends it while its terminalProgressBarEnabled setting is on
--- (the default), Copilot CLI repeats state 3 every 5 s; OpenCode and Gemini CLI send none. Both
--- send it only to terminals they know (Claude Code 2.1: ConEmu, Ghostty 1.2+ and iTerm2 3.6.6+, by
--- $ConEmuANSI, $TERM_PROGRAM and $TERM_PROGRAM_VERSION, never with $WT_SESSION; Copilot CLI 1.0:
--- the terminals it recognizes from $TERM_PROGRAM, $TERM, $WT_SESSION or $ConEmuANSI=ON, not inside
--- tmux or Zellij): agent.agents sets ConEmuANSI=ON for them (agents.<name>.progress).
---
--- This module reads those sequences from the agent terminal (TermRequest), keeps what the agent in
--- the terminal reported last, fires User AgentProgress when that changes, and sets 'busy' on the
--- terminal buffer while the agent works (Neovim 0.12+; the default statusline shows it).
--- agent.terminal attaches each agent it starts and detaches it when it stops or exits.
local util = require('agent.util')

local M = {}

---The <state> of OSC 9;4 (ConEmu, Windows Terminal): 0 removes the progress, 1 sets a percentage,
---2 is an error, 3 indeterminate, 4 paused.
M.STATES = { [0] = 'idle', [1] = 'progress', [2] = 'error', [3] = 'busy', [4] = 'paused' }

---@alias agent.ProgressState 'idle'|'progress'|'error'|'busy'|'paused'

---@class agent.Progress
---@field name string                 the agent
---@field bufnr integer               its terminal buffer
---@field state agent.ProgressState
---@field percent integer|nil         0-100: with 'progress' (else 0), and with 'error' and 'paused' when given
---@field working boolean             state is 'busy' or 'progress'
---@field since number                util.now_ms() when the state began

---The agent in the terminal, from its start to its exit or stop.
---@type agent.Progress|nil
local current = nil

local GROUP = 'agent.progress'

---'busy' exists from Neovim 0.12 on.
local has_busy = vim.fn.exists('+busy') == 1

---The state and percentage of an OSC 9;4 sequence (as TermRequest gives it: no terminator needed).
---@param seq string|nil
---@return agent.ProgressState|nil state, integer|nil percent  nil for any other sequence
function M.parse(seq)
  if type(seq) ~= 'string' then
    return nil, nil
  end
  local st, pr = seq:match('^\27%]9;4;(%d+);?(%d*)')
  local state = M.STATES[tonumber(st) or -1]
  if not state then
    return nil, nil
  end
  local percent = tonumber(pr)
  if state == 'idle' or state == 'busy' then
    percent = nil
  elseif percent then
    percent = math.max(0, math.min(100, percent))
  elseif state == 'progress' then
    percent = 0
  end
  return state, percent
end

---@param pattern string
---@param data table
local function fire(pattern, data)
  pcall(vim.api.nvim_exec_autocmds, 'User', { pattern = pattern, data = data, modeline = false })
end

---@param p agent.Progress
local function set_busy(p)
  if has_busy and vim.api.nvim_buf_is_valid(p.bufnr) then
    pcall(vim.api.nvim_set_option_value, 'busy', p.working and 1 or 0, { buf = p.bufnr })
  end
end

---@param p agent.Progress
---@param state agent.ProgressState
---@param percent integer|nil
local function update(p, state, percent)
  if p.state == state and p.percent == percent then
    return
  end
  if p.state ~= state then
    p.since = util.now_ms()
  end
  local was = p.working
  p.state, p.percent, p.working = state, percent, state == 'busy' or state == 'progress'
  if p.working ~= was then
    set_busy(p)
  end
  fire('AgentProgress', {
    name = p.name, bufnr = p.bufnr, state = state, percent = percent, working = p.working,
  })
end

---Follow the progress reports of agent `name` in terminal buffer `bufnr`. It replaces the agent
---followed before (agent.terminal runs one at a time); that one's late reports are ignored.
---@param bufnr integer
---@param name string
function M.attach(bufnr, name)
  if current and current.bufnr ~= bufnr then
    M.detach(current.bufnr)
  end
  current = { name = name, bufnr = bufnr, state = 'idle', working = false, since = util.now_ms() }
  vim.api.nvim_create_autocmd('TermRequest', {
    group = vim.api.nvim_create_augroup(GROUP, { clear = false }),
    buffer = bufnr,
    callback = function(ev)
      local p = current
      if not p or p.bufnr ~= ev.buf then
        return
      end
      local state, percent = M.parse(type(ev.data) == 'table' and ev.data.sequence or nil)
      if state then
        update(p, state, percent)
      end
    end,
  })
end

---Stop following the agent in terminal buffer `bufnr` (it stopped or exited): it is no longer
---working (User AgentProgress, when it was), and get() returns nil.
---@param bufnr integer
function M.detach(bufnr)
  local p = current
  if not p or p.bufnr ~= bufnr then
    return
  end
  update(p, 'idle', nil)
  current = nil
  pcall(vim.api.nvim_clear_autocmds, { group = GROUP, buffer = bufnr })
end

---What the agent in the terminal reported last (a copy), or nil when no agent runs.
---@return agent.Progress|nil
function M.get()
  return current and vim.deepcopy(current)
end

---True while the agent in the terminal reports that it is working.
---@return boolean
function M.working()
  return current ~= nil and current.working
end

return M
