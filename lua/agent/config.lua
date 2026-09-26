---@mod agent.config Configuration defaults and validation
local M = {}

---@class agent.AgentConfig
---@field cmd string[]            Executable and fixed leading args, e.g. { 'claude' }
---@field args string[]           Extra args appended after `cmd` (before the plugin's own MCP args)
---@field env table<string,string> Extra environment for the terminal job
---@field provider string         IDE provider module: 'claude' | 'copilot' | 'gemini'
---@field mcp boolean             Register the $NVIM controller MCP server for this agent
---@field auto_approve boolean    Pre-approve the controller's tools for this agent

M.defaults = {
  ---@type 'trace'|'debug'|'info'|'warn'|'error'
  log_level = 'warn',
  ---@type string|nil  Optional file path; logs are appended there in addition to vim.notify (warn+)
  log_file = nil,

  ---@type string  Agent used by :Agent without an argument
  default_agent = 'claude',

  ---@type boolean  Start every enabled provider at setup(), so agents launched outside Neovim can connect with /ide
  auto_start = false,

  terminal = {
    ---@type 'split'|'float'|'tab'|'none'
    layout = 'split',
    ---@type 'right'|'left'|'below'|'above'
    split_side = 'right',
    ---@type number  Fraction of the editor width (vertical split) or height (horizontal split)
    split_size = 0.4,
    float = { width = 0.85, height = 0.85, border = 'rounded' },
    ---@type boolean  Enter terminal-insert mode when the terminal is focused
    start_insert = true,
    ---@type boolean  Close the terminal window when the agent process exits
    auto_close = true,
  },

  selection = {
    ---@type boolean  Push selection changes to connected agents
    track = true,
    ---@type integer
    debounce_ms = 100,
  },

  diff = {
    ---@type 'tab'|'current'  Where the diff view opens
    open_in = 'tab',
    keymaps = {
      accept = '<leader>aa',
      reject = '<leader>ad',
    },
  },

  ---@type table<string, agent.AgentConfig>
  agents = {
    claude = { cmd = { 'claude' }, args = {}, env = {}, provider = 'claude', mcp = true, auto_approve = false },
    opencode = {
      cmd = { 'opencode' }, args = {}, env = {}, provider = 'claude', mcp = true, auto_approve = false,
      ---@type integer  OpenCode reads at_mentioned/selection lines as 1-based; this offset is added to the 0-based wire values
      line_offset = 1,
      ---@type boolean  Unset TERM_PROGRAM/TERM_PROGRAM_VERSION/GIT_ASKPASS inherited from a VS Code terminal
      scrub_vscode_env = true,
    },
    copilot = { cmd = { 'copilot' }, args = {}, env = {}, provider = 'copilot', mcp = true, auto_approve = false },
    gemini = {
      cmd = { 'gemini' }, args = {}, env = {}, provider = 'gemini', mcp = true, auto_approve = false,
      ---@type boolean  Pass --skip-trust (trusts the folder for this run; needed for stdio MCP servers in untrusted folders)
      skip_trust = false,
    },
  },

  providers = {
    claude = {
      enabled = true,
      port_range = { min = 10000, max = 65535 },
    },
    copilot = {
      enabled = true,
      ---@type boolean  Write isTrusted=true into Copilot lock files. This makes Copilot CLI skip its folder-trust prompt
      --- and load the repository's own MCP servers and hooks without asking. Opt-in only.
      trust_workspace = false,
    },
    gemini = {
      enabled = true,
    },
  },

  --- The $NVIM controller: a stdio MCP server (run as `nvim --headless -l ...`) that lets agents drive Neovim.
  nvim_mcp = {
    enabled = true,
    ---@type string  MCP server name; must match ^[A-Za-z0-9-]{1,24}$ and must not be 'ide'
    server_name = 'nvim',
    ---@type integer  Per-request timeout for calls into the parent Neovim
    timeout_ms = 30000,
  },
}

---@type table
M.options = vim.deepcopy(M.defaults)

local RESERVED_SERVER_NAMES = {
  ide = true, workspace = true, ['claude-in-chrome'] = true, ['computer-use'] = true,
  shell = true, write = true, url = true,
}

---@param opts table
---@return boolean ok, string|nil err
function M.validate(opts)
  local ok, err = pcall(function()
    vim.validate('log_level', opts.log_level, function(v)
      return v == 'trace' or v == 'debug' or v == 'info' or v == 'warn' or v == 'error'
    end, "one of 'trace','debug','info','warn','error'")
    vim.validate('default_agent', opts.default_agent, 'string')
    vim.validate('auto_start', opts.auto_start, 'boolean')
    vim.validate('terminal', opts.terminal, 'table')
    vim.validate('terminal.layout', opts.terminal.layout, function(v)
      return v == 'split' or v == 'float' or v == 'tab' or v == 'none'
    end, "one of 'split','float','tab','none'")
    vim.validate('terminal.split_size', opts.terminal.split_size, function(v)
      return type(v) == 'number' and v > 0 and v < 1
    end, 'a number between 0 and 1')
    vim.validate('selection.debounce_ms', opts.selection.debounce_ms, 'number')
    vim.validate('agents', opts.agents, 'table')
    for name, a in pairs(opts.agents) do
      vim.validate('agents.' .. name .. '.cmd', a.cmd, 'table')
      vim.validate('agents.' .. name .. '.provider', a.provider, function(v)
        return v == 'claude' or v == 'copilot' or v == 'gemini'
      end, "one of 'claude','copilot','gemini'")
    end
    local range = opts.providers.claude.port_range
    vim.validate('providers.claude.port_range', range, function(r)
      return type(r) == 'table' and type(r.min) == 'number' and type(r.max) == 'number'
        and r.min >= 1 and r.max <= 65535 and r.min <= r.max
    end, 'a {min,max} range within 1..65535')
    local name = opts.nvim_mcp.server_name
    vim.validate('nvim_mcp.server_name', name, function(v)
      return type(v) == 'string' and v:match('^[A-Za-z0-9-]+$') ~= nil and #v <= 24
        and not RESERVED_SERVER_NAMES[v:lower()]
    end, "a name matching ^[A-Za-z0-9-]{1,24}$ that is not reserved (e.g. 'ide')")
  end)
  if not ok then
    return false, tostring(err)
  end
  return true, nil
end

---@param user table|nil
---@return table options
function M.setup(user)
  local merged = vim.tbl_deep_extend('force', vim.deepcopy(M.defaults), user or {})
  -- Lists must be replaced, not merged index by index.
  if user and user.agents then
    for name, a in pairs(user.agents) do
      if a.cmd then merged.agents[name].cmd = a.cmd end
      if a.args then merged.agents[name].args = a.args end
    end
  end
  local ok, err = M.validate(merged)
  if not ok then
    error('agent.nvim: invalid configuration: ' .. err, 0)
  end
  M.options = merged
  return merged
end

---@return table
function M.get()
  return M.options
end

return M
