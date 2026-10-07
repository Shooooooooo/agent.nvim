---@mod agent.statusline A spinner for your statusline while the agent works
---
--- The agent tells its terminal when it is working (OSC 9;4, see agent.progress: Claude Code and
--- Copilot CLI do, OpenCode and Gemini CLI do not). get() is the text for a statusline: a spinner and
--- the agent's name while it works, else ''. heirline() is the same as a heirline.nvim component.
---
--- A statusline is drawn again only when something changes, so while the agent works this module
--- redraws the statuslines (and the window bars, and the tabline when there is one) every
--- INTERVAL_MS, and once more when it stops working. That starts when the module is first loaded
--- (by your statusline config): without it nothing is redrawn.
local progress = require('agent.progress')
local util = require('agent.util')

local uv = vim.uv or vim.loop

local M = {}

---The spinner's frames, one per INTERVAL_MS.
M.FRAMES = { '⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏' }
M.INTERVAL_MS = 100

---@type uv.uv_timer_t|nil  redraws the statuslines while the agent works
local timer = nil

---The spinner frame for now (from the clock: every statusline shows the same one).
---@return string
function M.frame()
  return M.FRAMES[math.floor(util.now_ms() / M.INTERVAL_MS) % #M.FRAMES + 1]
end

---The spinner and the agent's name (e.g. "⠹ claude") while the agent works, else ''. The text is
---not escaped for 'statusline' (see heirline()): use it as %{v:lua.require'agent.statusline'.get()}.
---@return string
function M.get()
  local p = progress.working() and progress.get()
  if not p then
    return ''
  end
  return M.frame() .. ' ' .. p.name
end

---A heirline.nvim component (a plain table: change or add fields as you like) that shows get()
---while the agent works, and nothing otherwise.
---@param opts { hl?: string|table|fun(self: table): (string|table|nil) }|nil  hl: its highlight
---@return table
function M.heirline(opts)
  opts = opts or {}
  return {
    condition = progress.working,
    provider = function()
      return (M.get():gsub('%%', '%%%%'))
    end,
    hl = opts.hl,
  }
end

local function redraw()
  pcall(vim.cmd, 'redrawstatus!')
  if vim.o.tabline ~= '' then
    pcall(vim.cmd, 'redrawtabline')
  end
end

---Start or stop the redraws as the agent starts or stops working.
local function update()
  local working = progress.working()
  if working and not timer then
    timer = uv.new_timer()
    timer:start(M.INTERVAL_MS, M.INTERVAL_MS, vim.schedule_wrap(function()
      if timer then
        redraw()
      end
    end))
  elseif not working and timer then
    timer:stop()
    timer:close()
    timer = nil
  end
  redraw()
end

---True while the statuslines are redrawn for the spinner (tests).
---@return boolean
function M._ticking()
  return timer ~= nil
end

vim.api.nvim_create_autocmd('User', {
  group = vim.api.nvim_create_augroup('agent.statusline', { clear = true }),
  pattern = 'AgentProgress',
  callback = update,
})
if progress.working() then
  update()
end

return M
