---@mod agent.notifications The agent's desktop notifications, passed on to the host terminal
---
--- An agent asks its terminal for a desktop notification with an escape sequence: Claude Code sends
--- OSC 777 ("\27]777;notify;Claude Code;Claude is waiting for your input") when its notification
--- channel is Ghostty's, as it is by default in Ghostty. Neovim's terminal keeps the sequence to
--- itself (it only fires TermRequest), so no notification would show. agent.nvim passes the ones
--- from the agent's terminal on to the terminal Neovim runs in, terminated by ST, with
--- nvim_ui_send(): only a UI that writes to a terminal (stdout_tty, the TUI) gets them.
---
--- Only `777;notify;<title>;<body>` goes on: the other OSC 777 commands (VTE's precmd, preexec, ...)
--- are about the agent's terminal itself. Control characters in the title and body (C0, DEL, C1)
--- become spaces, as Claude Code does itself: nothing in them can end the sequence early, or start
--- another one.
---
--- nvim_ui_send() output goes out with the next flush of the screen, which Neovim's main loop does
--- after each event: at once, unless a hit-enter prompt waits. No flush is forced: :redraw and
--- nvim__redraw({ flush = true }) would drop that prompt.
local config = require('agent.config')

local api = vim.api

local M = {}

local GROUP = 'agent.notifications'
local NOTIFY = '\27]777;notify;'

---The sequence that passes on `seq`, or nil when it is no notification.
---@param seq string  a TermRequest sequence (no terminator), e.g. "\27]777;notify;Claude Code;Done"
---@return string|nil
local function pass_on(seq)
  if seq:sub(1, #NOTIFY) ~= NOTIFY then
    return nil
  end
  local text = seq:sub(#NOTIFY + 1):gsub('[%z\1-\31\127]', ' '):gsub('\194[\128-\159]', ' ')
  return NOTIFY .. text .. '\27\\'
end
M._pass_on = pass_on

---Whether a UI writes to a terminal (stdout_tty): where nvim_ui_send() sends the notifications.
---@return boolean
function M.host_terminal()
  for _, ui in ipairs(api.nvim_list_uis()) do
    if ui.stdout_tty then
      return true
    end
  end
  return false
end

---Pass the agent's notifications on (agent.setup() calls this). Safe to call again. With
---notifications.enabled = false, nothing is passed on.
function M.setup()
  local group = api.nvim_create_augroup(GROUP, { clear = true })
  if config.get().notifications.enabled == false then
    return
  end
  api.nvim_create_autocmd('TermRequest', {
    group = group,
    desc = "agent.nvim: pass the agent's desktop notifications on to the terminal Neovim runs in",
    callback = function(ev)
      local seq = type(ev.data) == 'table' and ev.data.sequence
      -- Not once agent.nvim has stopped or replaced the agent (its job may still be exiting).
      if type(seq) ~= 'string' or ev.buf ~= require('agent.terminal').bufnr() then
        return
      end
      local out = pass_on(seq)
      if out then
        pcall(api.nvim_ui_send, out)
      end
    end,
  })
end

return M
