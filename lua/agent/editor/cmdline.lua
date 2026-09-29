---@mod agent.editor.cmdline The ':' command line being run
---
--- :'<,'>AgentSend (typed, or from a ':' mapping in Visual mode) sends the Visual selection as it
--- was made; any other range sends its lines. A range reaches the command as line numbers only, so
--- the command line is recorded when it is left (CmdlineLeave), before the command runs. Started
--- by plugin/agent.lua, so that it is there before the first command (which runs setup()).
local M = {}

local GROUP = 'agent.nvim.cmdline'
local recorded = nil ---@type string|nil

---Start recording (idempotent).
function M.start()
  if vim.fn.exists('#' .. GROUP) == 1 then
    return
  end
  vim.api.nvim_create_autocmd('CmdlineLeave', {
    group = vim.api.nvim_create_augroup(GROUP, { clear = true }),
    pattern = ':',
    callback = function()
      if (vim.v.event or {}).abort then
        return
      end
      local line = vim.fn.getcmdline()
      -- (Only a line that can be :'<,'>AgentSend: most command lines cost one find.)
      if line:find('Agent', 1, true) then
        recorded = line
        vim.schedule(function()
          recorded = nil
        end)
      end
    end,
  })
end

---Whether the command being run is `name` over the Visual area (:'<,'>name, :*name), as recorded.
---The recording is used once: a command run later with a range (vim.cmd(), a <cmd> mapping)
---before it is cleared does not count.
---@param name string  the user command
---@return boolean
function M.take_visual(name)
  local line = recorded
  recorded = nil
  if not line then
    return false
  end
  if not (line:match("^[%s:]*'<%s*,%s*'>") or line:match('^[%s:]*%*')) then
    return false
  end
  local ok, parsed = pcall(vim.api.nvim_parse_cmd, line, {})
  return ok and type(parsed) == 'table' and parsed.cmd == name
end

return M
