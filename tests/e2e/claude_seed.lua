-- Seeds an isolated Claude Code config dir (CLAUDE_CONFIG_DIR), so that the real `claude` TUI
-- starts straight at its prompt: onboarding done, the workspaces trusted, the dummy API key
-- approved. Shared by tests/e2e/driver.lua and demo/record.sh.
--
-- As a module:  local seed = dofile('<repo>/tests/e2e/claude_seed.lua')
--               seed.write(config_dir, { workspace, ... }); seed.env(config_dir, base_url)
-- As a script:  nvim --headless -u NONE -i NONE -n -l tests/e2e/claude_seed.lua <config_dir> <workspace>...
--               (writes the config and prints the dummy API key)
local M = {}

-- A dummy key in the shape Claude Code expects. It only ever reaches the local fake model endpoint
-- (tests/e2e/fake_model.mjs); .claude.json approves it by its last 20 characters.
M.api_key = 'sk-ant-api03-' .. ('x'):rep(80) .. '-e2eAAA'

---Write <config_dir>/.claude.json. Workspaces must be real paths (see vim.uv.fs_realpath).
---@param config_dir string
---@param workspaces string[]
function M.write(config_dir, workspaces)
  local projects = {}
  for _, ws in ipairs(workspaces) do
    projects[ws] = { hasTrustDialogAccepted = true, hasCompletedProjectOnboarding = true }
  end
  vim.fn.mkdir(config_dir, 'p', tonumber('700', 8))
  local f = assert(io.open(config_dir .. '/.claude.json', 'wb'))
  f:write(vim.json.encode({
    hasCompletedOnboarding = true,
    theme = 'dark',
    numStartups = 5,
    autoUpdates = false,
    customApiKeyResponses = { approved = { M.api_key:sub(-20) }, rejected = {} },
    projects = projects,
  }))
  f:close()
end

---The environment that points `claude` at `config_dir` and at the model endpoint `base_url`.
---@param config_dir string
---@param base_url string  e.g. http://127.0.0.1:<port>
---@return table<string, string>
function M.env(config_dir, base_url)
  return {
    CLAUDE_CONFIG_DIR = config_dir,
    ANTHROPIC_BASE_URL = base_url,
    ANTHROPIC_API_KEY = M.api_key,
    CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = '1',
    DISABLE_TELEMETRY = '1',
    DISABLE_AUTOUPDATER = '1',
    DISABLE_ERROR_REPORTING = '1',
  }
end

-- Script mode (nvim -l): arg[0] is this file. When another script dofile()s it, arg[0] is that one.
if type(arg) == 'table' and type(arg[0]) == 'string' and arg[0]:match('claude_seed%.lua$') then
  assert(arg[1] and arg[2], 'usage: nvim -l claude_seed.lua <config_dir> <workspace>...')
  local workspaces = {}
  for i = 2, #arg do
    workspaces[#workspaces + 1] = arg[i]
  end
  M.write(arg[1], workspaces)
  io.stdout:write(M.api_key .. '\n')
end

return M
