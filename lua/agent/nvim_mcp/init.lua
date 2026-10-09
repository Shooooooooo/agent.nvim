---@mod agent.nvim_mcp Launch helpers for the $NVIM controller (stdio MCP server)
---
--- The controller runs as a separate `nvim --headless -l main.lua <addr>` process started by the
--- agent CLI. These helpers build its command line and environment for the launcher.
local M = {}

local uv = vim.uv

local FLAGS = { '--headless', '-u', 'NONE', '-i', 'NONE', '-n', '-l' }
---Flags that start the controller as a clean `nvim -l` script (a copy; callers may modify it).
M.FLAGS = vim.deepcopy(FLAGS)

---Absolute path of main.lua.
---@return string
function M.script_path()
  local src = debug.getinfo(1, 'S').source
  if src:sub(1, 1) == '@' then
    src = src:sub(2)
  end
  local dir = vim.fn.fnamemodify(src, ':p:h')
  return vim.fs.normalize(dir, { expand_env = false }) .. '/main.lua'
end

---This Neovim's RPC server address, starting a server when there is none.
---Returns nil and a message when the address cannot be passed literally to agent configs
---(it contains `$`, `{` or `}`, which config loaders may expand).
---@return string|nil addr, string|nil err
function M.address()
  local addr = vim.v.servername
  if addr == nil or addr == '' then
    local ok, started = pcall(vim.fn.serverstart)
    addr = ok and started or ''
  end
  if addr == '' then
    return nil, 'Neovim has no RPC server address (serverstart() failed)'
  end
  if addr:find('[%${}]') then
    return nil, 'the Neovim server address contains "$", "{" or "}": ' .. addr
  end
  return addr, nil
end

---Arguments after the nvim binary, without the parent address: the flags and main.lua.
---@return string[]
function M.base_args()
  local args = vim.deepcopy(FLAGS)
  args[#args + 1] = M.script_path()
  return args
end

---A stable nvim path for persisted configs: `exepath('nvim')` (not symlink-resolved) when it is
---the running nvim (same realpath), else v:progpath. v:progpath is a versioned Cellar path on
---Homebrew and goes stale; another nvim on PATH (an old distro build next to an AppImage or /opt
---install) may not run the controller.
---@return string
function M.stable_nvim()
  local exe = vim.fn.exepath('nvim')
  local prog = vim.v.progpath
  if prog == nil or prog == '' then
    return (exe ~= nil and exe ~= '') and exe or 'nvim'
  end
  if exe == nil or exe == '' or exe == prog then
    return prog
  end
  local a, b = uv.fs_realpath(exe), uv.fs_realpath(prog)
  if a and a == b then
    return exe
  end
  return prog
end

---argv for a per-launch MCP server entry: the running nvim binary, the controller script and
---the parent address as arg[1]. This is the one place that builds the controller's argv
---(agent.agents and agent.gemini_setup use it).
---@param addr string|nil  defaults to M.address(); omitted from argv when unavailable
---@return string[] argv
function M.command(addr)
  addr = addr or M.address()
  local exe = vim.v.progpath ~= '' and vim.v.progpath or 'nvim'
  local argv = { exe }
  vim.list_extend(argv, M.base_args())
  if addr then
    argv[#argv + 1] = addr
  end
  return argv
end

---argv for a persisted config (the Gemini extension manifest): a stable nvim path instead of
---the versioned v:progpath, and the literal placeholder "${NVIM}" as the address.
---@return string[] argv
function M.persistent_command()
  local argv = { M.stable_nvim() }
  vim.list_extend(argv, M.base_args())
  argv[#argv + 1] = '${NVIM}'
  return argv
end

---Environment for the MCP server entry (string values only).
---@param opts { addr?: string, agent?: string, session?: string, timeout_ms?: integer }|nil
---@return table<string, string>
function M.env(opts)
  opts = opts or {}
  local env = {}
  local addr = opts.addr or M.address()
  if addr then
    env.NVIM = addr
  end
  if opts.agent then
    env.AGENT_NVIM_AGENT = opts.agent
  end
  if opts.session then
    env.AGENT_NVIM_SESSION = opts.session
  end
  local timeout = opts.timeout_ms
  if not timeout then
    local ok, config = pcall(require, 'agent.config')
    timeout = ok and config.get().nvim_mcp and config.get().nvim_mcp.timeout_ms or nil
  end
  if timeout then
    env.AGENT_NVIM_TIMEOUT_MS = tostring(math.floor(timeout))
  end
  return env
end

---Names of the tools the controller exposes.
---@return string[]
function M.tool_names()
  local names = {}
  for _, t in ipairs(require('agent.nvim_mcp.server').tools()) do
    names[#names + 1] = t.name
  end
  return names
end

return M
