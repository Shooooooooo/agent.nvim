---@mod agent.gemini_setup Gemini CLI extension manifest, :AgentGeminiSetup, and read-only settings helpers
---
--- Gemini CLI has no per-run way to add an MCP server, so agent.nvim ships a linked Gemini
--- extension whose manifest lives in a plugin-owned directory and is regenerated before every
--- launch (launch-and-mcp-registration.md §5.3). Linking it is a one-time, explicit user action
--- (:AgentGeminiSetup). Nothing in this module ever writes the user's Gemini settings.
local util = require('agent.util')

local uv = vim.uv or vim.loop

local M = {}

M.EXTENSION_NAME = 'agent-nvim'
M.MANIFEST_FILE = 'gemini-extension.json'
M.DESCRIPTION = 'Lets Gemini CLI control the Neovim instance that launched it (through the NVIM environment variable).'

local sysname = uv.os_uname().sysname

---@param environ table|nil
---@return table
local function env_of(environ)
  return environ or vim.fn.environ()
end

---@param path string|nil
---@return boolean
local function is_file(path)
  local st = path and uv.fs_stat(path)
  return st ~= nil and st.type == 'file'
end

---@param path string
---@return string|nil
local function read_file(path)
  local fd = uv.fs_open(path, 'r', 0)
  if not fd then
    return nil
  end
  local st = uv.fs_fstat(fd)
  local data = st and uv.fs_read(fd, st.size, 0) or nil
  uv.fs_close(fd)
  return data
end

---Directory of the plugin-owned extension (the link target).
---@param opts { extension_dir?: string }|nil
---@return string
function M.extension_dir(opts)
  if opts and opts.extension_dir then
    return opts.extension_dir
  end
  local ok, cfg = pcall(function()
    return require('agent.config').get().agents.gemini
  end)
  if ok and cfg and type(cfg.extension_dir) == 'string' and cfg.extension_dir ~= '' then
    return cfg.extension_dir
  end
  return vim.fs.joinpath(vim.fn.stdpath('data'), 'agent.nvim', 'gemini-extension')
end

---@param opts { extension_dir?: string }|nil
---@return string
function M.manifest_path(opts)
  return vim.fs.joinpath(M.extension_dir(opts), M.MANIFEST_FILE)
end

---A stable nvim path for the persisted manifest: agent.nvim_mcp.stable_nvim() (the `nvim` on PATH,
---which survives upgrades) when it resolves to the running binary, else v:progpath. Another nvim
---on PATH (an old distro build next to an AppImage or /opt install) may not run the controller.
---@return string
function M.stable_nvim()
  local stable = require('agent.nvim_mcp').stable_nvim()
  local prog = vim.v.progpath
  if prog == nil or prog == '' or stable == prog then
    return stable
  end
  local a, b = uv.fs_realpath(stable), uv.fs_realpath(prog)
  if a and a == b then
    return stable
  end
  return prog
end

---Default argv of the $NVIM controller as written into the persisted manifest.
---@return string[]
function M.default_command()
  local argv = require('agent.nvim_mcp').persistent_command()
  argv[1] = M.stable_nvim()
  return argv
end

---Build the extension manifest table.
---@param opts { server_name?: string, command?: string[], timeout_ms?: integer }|nil
---@return table
function M.manifest(opts)
  opts = opts or {}
  local name = opts.server_name or 'nvim'
  local command = opts.command or M.default_command()
  local env = {
    NVIM = '${NVIM}',
    AGENT_NVIM_AGENT = 'gemini',
    AGENT_NVIM_SESSION = '${AGENT_NVIM_SESSION}',
  }
  if opts.timeout_ms then
    env.AGENT_NVIM_TIMEOUT_MS = tostring(opts.timeout_ms)
  end
  local args = {}
  for i = 2, #command do
    args[#args + 1] = command[i]
  end
  return {
    name = M.EXTENSION_NAME,
    version = '1.0.0',
    description = M.DESCRIPTION,
    mcpServers = {
      [name] = { command = command[1], args = args, env = env },
    },
  }
end

---Write the manifest atomically (0700 dir, 0600 file). Skips the write when the content is unchanged.
---@param opts { extension_dir?: string, server_name?: string, command?: string[], timeout_ms?: integer }|nil
---@return boolean ok, string path_or_err
function M.write_manifest(opts)
  opts = opts or {}
  local dir = M.extension_dir(opts)
  local pok, ok, err = pcall(util.mkdir_p, dir, tonumber('700', 8))
  if not pok or not ok then
    return false, (pok and err or ok) or ('cannot create ' .. dir)
  end
  local path = vim.fs.joinpath(dir, M.MANIFEST_FILE)
  local data = util.json_encode(M.manifest(opts)) .. '\n'
  if read_file(path) == data then
    return true, path
  end
  local wok, werr = util.atomic_write(path, data, tonumber('600', 8))
  if not wok then
    return false, werr or ('cannot write ' .. path)
  end
  return true, path
end

---The environment Gemini runs with when agent.nvim launches it: `environ` (default: Neovim's)
---with `agents.gemini.env` applied (false unsets) and without NVIM, as agent.agents.build_launch
---does. Use it wherever the Gemini home matters (link check, :AgentGeminiSetup, health).
---@param environ table|nil
---@return table
function M.agent_environ(environ)
  local out = vim.tbl_extend('force', {}, env_of(environ))
  local ok, env = pcall(function()
    return require('agent.config').get().agents.gemini.env
  end)
  if ok and type(env) == 'table' then
    for k, v in pairs(env) do
      if v == false then
        out[k] = nil
      else
        out[k] = tostring(v)
      end
    end
  end
  out.NVIM = nil
  return out
end

---Gemini's home: `$GEMINI_CLI_HOME` if set, else the OS home directory.
---@param environ table|nil
---@return string
function M.gemini_home(environ)
  local home = env_of(environ).GEMINI_CLI_HOME
  if home and home ~= '' then
    return home
  end
  return util.home()
end

---@param environ table|nil
---@return string
function M.user_settings_path(environ)
  return vim.fs.joinpath(M.gemini_home(environ), '.gemini', 'settings.json')
end

---@param environ table|nil
---@return string
function M.user_policies_dir(environ)
  return vim.fs.joinpath(M.gemini_home(environ), '.gemini', 'policies')
end

---@param environ table|nil
---@return string
function M.system_settings_path(environ)
  local p = env_of(environ).GEMINI_CLI_SYSTEM_SETTINGS_PATH
  if p and p ~= '' then
    return p
  end
  if sysname == 'Darwin' then
    return '/Library/Application Support/GeminiCli/settings.json'
  elseif sysname:find('Windows') then
    return 'C:\\ProgramData\\gemini-cli\\settings.json'
  end
  return '/etc/gemini-cli/settings.json'
end

---@param environ table|nil
---@return string
function M.system_defaults_path(environ)
  local p = env_of(environ).GEMINI_CLI_SYSTEM_DEFAULTS_PATH
  if p and p ~= '' then
    return p
  end
  return vim.fs.joinpath(vim.fs.dirname(M.system_settings_path(environ)), 'system-defaults.json')
end

---Remove // and /* */ comments outside JSON strings (Gemini parses settings with strip-json-comments).
---@param s string
---@return string
function M.strip_json_comments(s)
  local out = {}
  local i, n = 1, #s
  local plain_start = 1
  while i <= n do
    local c = s:byte(i)
    if c == 34 then -- '"': skip the string, honoring escapes
      local j = i + 1
      while j <= n do
        local d = s:byte(j)
        if d == 92 then
          j = j + 2
        elseif d == 34 then
          break
        else
          j = j + 1
        end
      end
      i = j + 1
    elseif c == 47 and s:byte(i + 1) == 47 then -- //
      out[#out + 1] = s:sub(plain_start, i - 1)
      local j = s:find('\n', i + 2, true)
      i = j or (n + 1)
      plain_start = i
    elseif c == 47 and s:byte(i + 1) == 42 then -- /*
      out[#out + 1] = s:sub(plain_start, i - 1) .. ' '
      local _, e = s:find('*/', i + 2, true)
      i = e and (e + 1) or (n + 1)
      plain_start = i
    else
      i = i + 1
    end
  end
  out[#out + 1] = s:sub(plain_start)
  return table.concat(out)
end

---Read a Gemini settings file (JSONC), read-only.
---@param path string
---@return table|nil settings, string|nil err  -- (nil, nil) when the file does not exist
function M.read_settings(path)
  if not is_file(path) then
    return nil, nil
  end
  local data = read_file(path)
  if not data then
    return nil, 'cannot read ' .. path
  end
  data = data:gsub('^\239\187\191', '')
  if data:match('^%s*$') then
    return {}, nil
  end
  local ok, val = pcall(vim.json.decode, M.strip_json_comments(data), { luanil = { object = true, array = true } })
  if not ok or type(val) ~= 'table' then
    return nil, 'cannot parse ' .. path .. (ok and '' or (': ' .. tostring(val)))
  end
  return val, nil
end

---Whether Gemini (0.60+) loads a system settings or system defaults file. It skips one unless the
---file and every ancestor directory, of the path as given and of its realpath, are owned by root
---and not writable by group or others, and every symlink on the way is owned by root
---(loadSystemFile → isFileAndDirectorySecureSync, core/src/utils/security.ts). A missing file is
---"secure" (nothing is loaded). Not checked on Windows (Gemini uses ACLs there).
---@param path string
---@return boolean
function M.system_file_secure(path)
  if sysname:find('Windows') then
    return true
  end
  local function secure(p)
    local st = uv.fs_stat(p)
    if not st then
      return false
    end
    local lst = uv.fs_lstat(p)
    if lst and lst.type == 'link' and lst.uid ~= 0 then
      return false
    end
    return st.uid == 0 and bit.band(st.mode, tonumber('022', 8)) == 0
  end
  local function chain(p)
    while true do
      if not secure(p) then
        return false
      end
      local parent = vim.fs.dirname(p)
      if parent == nil or parent == p then
        return true
      end
      p = parent
    end
  end
  local abs = util.abspath(path)
  if not uv.fs_stat(abs) then
    return true
  end
  if not chain(abs) then
    return false
  end
  local real = uv.fs_realpath(abs)
  return real == nil or real == abs or chain(real)
end

---The system defaults, user and system settings files; a system file that Gemini would skip as
---insecure is nil.
---@param opts { environ?: table, system_settings_path?: string, system_defaults_path?: string }
---@return string|nil defaults, string user, string|nil system
local function scoped_files(opts)
  local environ = env_of(opts.environ)
  local defaults = opts.system_defaults_path or M.system_defaults_path(environ)
  local system = opts.system_settings_path or M.system_settings_path(environ)
  return M.system_file_secure(defaults) and defaults or nil, M.user_settings_path(environ),
    M.system_file_secure(system) and system or nil
end

---Settings files in Gemini's merge order (workspace omitted): system defaults < user < system
---overrides. System files that Gemini would skip as insecure are left out.
---@param opts { environ?: table, system_settings_path?: string, system_defaults_path?: string }|nil
---@return string[]
local function settings_files(opts)
  local defaults, user, system = scoped_files(opts)
  local files = {}
  files[#files + 1] = defaults
  files[#files + 1] = user
  files[#files + 1] = system
  return files
end

local case_insensitive = sysname == 'Darwin' or sysname:find('Windows') ~= nil

---Path as Gemini compares it for folder trust: absolute (relative to `cwd`), normalized,
---case-folded on macOS and Windows; `real` also resolves symlinks when the path exists.
---@param p string
---@param cwd string
---@param real boolean|nil
---@return string
local function trust_path(p, cwd, real)
  if p:sub(1, 1) ~= '/' and not p:match('^%a:[/\\]') then
    p = cwd .. '/' .. p
  end
  p = vim.fs.normalize(p)
  if real then
    p = uv.fs_realpath(p) or p
  end
  return case_insensitive and p:lower() or p
end

---@param parent string
---@param child string
---@return boolean
local function is_subpath(parent, child)
  if parent == child or parent == '/' then
    return true
  end
  return child:sub(1, #parent + 1) == parent .. '/'
end

---Whether Gemini trusts `cwd`, and so loads `<cwd>/.gemini/settings.json`. A read-only copy of
---checkPathTrust (core/src/utils/trust.ts) as loadSettings runs it: before `--skip-trust` takes
---effect and without an IDE override (the Gemini provider never sends isTrusted). An unknown
---folder is untrusted, and so is any doubt (an unreadable or invalid trustedFolders.json).
---@param opts { cwd: string, environ?: table, system_settings_path?: string, system_defaults_path?: string }
---@return boolean
function M.folder_trusted(opts)
  local environ = env_of(opts.environ)
  if environ.GEMINI_RESTRICTED_MODE == 'true' or environ.GEMINI_CLI_TRUST_WORKSPACE == 'false' then
    return false
  end
  if environ.GEMINI_CLI_TRUST_WORKSPACE == 'true' then
    return true
  end
  local trust_enabled = true
  for _, path in ipairs(settings_files(opts)) do
    local s, err = M.read_settings(path)
    if err then
      return false
    end
    local ft = s and type(s.security) == 'table' and s.security.folderTrust
    if type(ft) == 'table' and type(ft.enabled) == 'boolean' then
      trust_enabled = ft.enabled
    end
  end
  if not trust_enabled then
    return true
  end
  local file = environ.GEMINI_CLI_TRUSTED_FOLDERS_PATH
  if not file or file == '' then
    file = vim.fs.joinpath(M.gemini_home(environ), '.gemini', 'trustedFolders.json')
  end
  local rules = M.read_settings(file)
  if type(rules) ~= 'table' then
    return false
  end
  local cwd = util.abspath(opts.cwd)
  local location = trust_path(cwd, cwd, true)
  local best_len, best = -1, nil
  for raw, level in pairs(rules) do
    if type(raw) ~= 'string' or (level ~= 'TRUST_FOLDER' and level ~= 'TRUST_PARENT' and level ~= 'DO_NOT_TRUST') then
      return false -- Gemini refuses to start with an invalid file
    end
    local key = trust_path(raw, cwd)
    local effective = level == 'TRUST_PARENT' and vim.fs.dirname(key) or key
    if is_subpath(trust_path(effective, cwd, true), location)
      and (#key > best_len or (#key == best_len and level == 'DO_NOT_TRUST')) then
      best_len, best = #key, level
    end
  end
  return best == 'TRUST_FOLDER' or best == 'TRUST_PARENT'
end

---Whether Gemini's effective `ide.enabled` is true, computed read-only from the settings files
---(system defaults, user settings under `$GEMINI_CLI_HOME` or `~`, system overrides; last one wins).
---@param opts { environ?: table, system_settings_path?: string, system_defaults_path?: string }|nil
---@return boolean enabled, string|nil source  -- the file that decided the value, if any
function M.ide_enabled(opts)
  opts = opts or {}
  local value, source = nil, nil
  for _, path in ipairs(settings_files(opts)) do
    local s = M.read_settings(path)
    if s and type(s.ide) == 'table' and type(s.ide.enabled) == 'boolean' then
      value, source = s.ide.enabled, path
    end
  end
  return value == true, source
end

---Whether the extension has been linked into Gemini (`<gemini home>/.gemini/extensions/agent-nvim`).
---@param opts { environ?: table }|nil
---@return boolean
function M.is_linked(opts)
  opts = opts or {}
  local dir = vim.fs.joinpath(M.gemini_home(opts.environ), '.gemini', 'extensions', M.EXTENSION_NAME)
  return vim.fn.isdirectory(dir) == 1
end

---Expand $VAR, ${VAR} and ${VAR:-default} the way Gemini does for settings strings (missing: verbatim).
---@param s string
---@param environ table
---@return string
local function expand_env(s, environ)
  s = s:gsub('%${([%w_]+):%-([^}]*)}', function(k, d)
    local v = environ[k]
    return (v ~= nil and v ~= '') and v or d
  end)
  s = s:gsub('%${([%w_]+)}', function(k)
    return environ[k]
  end)
  s = s:gsub('%$([%a_][%w_]*)', function(k)
    return environ[k]
  end)
  return s
end

---The workspace settings file Gemini loads for `cwd`, or nil: none in the Gemini home, and none
---in a folder Gemini does not trust (settings.ts: `isTrusted ? workspace : {}`).
---@param opts { cwd?: string, environ?: table, system_settings_path?: string, system_defaults_path?: string }
---@return string|nil
local function workspace_settings(opts)
  if not opts.cwd then
    return nil
  end
  local home = M.gemini_home(env_of(opts.environ))
  if util.realpath(opts.cwd) == util.realpath(home) or not M.folder_trusted(opts) then
    return nil
  end
  return vim.fs.joinpath(opts.cwd, '.gemini', 'settings.json')
end

---Why Gemini's settings block the MCP server `name`, or nil: a non-empty `mcp.allowed` (the lists
---of the system, system defaults, user and trusted workspace files, intersected case-insensitively)
---that does not contain it, or an `mcp.excluded` that does (isBlockedBySettings,
---core/src/tools/mcp-client-manager.ts; both exact matches). `--allowed-mcp-server-names` replaces
---both. Admin MCP controls come from the server (file-based admin settings are ignored), so they
---cannot be checked here.
---@param name string
---@param opts { cwd?: string, environ?: table, system_settings_path?: string, system_defaults_path?: string }|nil
---@return string|nil reason
function M.mcp_block_reason(name, opts)
  opts = opts or {}
  local defaults, user, system = scoped_files(opts)
  local files = {}
  files[#files + 1] = system
  files[#files + 1] = defaults
  files[#files + 1] = user
  files[#files + 1] = workspace_settings(opts)
  local function strings(list)
    local out = {}
    for _, v in ipairs(list) do
      if type(v) == 'string' then
        out[#out + 1] = v
      end
    end
    return out
  end
  local function norm(v)
    return vim.trim(v):lower()
  end
  local allowed, allowed_in = nil, {}
  for _, path in ipairs(files) do
    local s = M.read_settings(path)
    local mcp = s and type(s.mcp) == 'table' and s.mcp or nil
    if mcp and type(mcp.excluded) == 'table' and vim.islist(mcp.excluded)
      and vim.tbl_contains(mcp.excluded, name) then
      return ('mcp.excluded lists it (%s)'):format(path)
    end
    if mcp and type(mcp.allowed) == 'table' and vim.islist(mcp.allowed) then
      local list = strings(mcp.allowed)
      if allowed == nil then
        allowed = list
      else
        local set = {}
        for _, v in ipairs(list) do
          set[norm(v)] = true
        end
        allowed = vim.tbl_filter(function(v)
          return set[norm(v)] == true
        end, allowed)
      end
      allowed_in[#allowed_in + 1] = path
    end
  end
  if allowed and #allowed > 0 and not vim.tbl_contains(allowed, name) then
    return ('mcp.allowed does not list it (%s)'):format(table.concat(allowed_in, ', '))
  end
  return nil
end

---Policy locations that `--policy` would otherwise replace: the user policy dir, then every
---`policyPaths` entry from the settings files Gemini loads. `<cwd>/.gemini/settings.json` counts
---only in a trusted folder: `--policy` paths load at the user tier, so re-listing an untrusted
---repository's policyPaths would let it auto-approve anything.
---@param opts { environ?: table, cwd?: string, system_settings_path?: string, system_defaults_path?: string }|nil
---@return string[]|nil paths, string|nil err  -- err when a settings file exists but cannot be parsed
function M.policy_locations(opts)
  opts = opts or {}
  local environ = env_of(opts.environ)
  local out, seen = {}, {}
  local function add(p)
    if type(p) == 'string' and p ~= '' and not seen[p] then
      seen[p] = true
      out[#out + 1] = p
    end
  end
  add(M.user_policies_dir(environ))
  local files = settings_files(opts)
  files[#files + 1] = workspace_settings(opts)
  for _, path in ipairs(files) do
    local s, err = M.read_settings(path)
    if err then
      return nil, err
    end
    if s and type(s.policyPaths) == 'table' then
      for _, p in ipairs(s.policyPaths) do
        if type(p) == 'string' then
          add(expand_env(p, environ))
        end
      end
    end
  end
  return out, nil
end

---:AgentGeminiSetup — confirm, write the manifest, then run `gemini extensions link <dir> --consent`
---in a terminal split. The link job, the link check and the Gemini home shown all use
---M.agent_environ(opts.environ), so a GEMINI_CLI_HOME set in agents.gemini.env is honoured.
---@param opts { confirm?: boolean, force?: boolean, cmd?: string[], extension_dir?: string, server_name?: string, command?: string[], environ?: table, on_exit?: fun(code: integer) }|nil
---@return boolean started, string|nil err
function M.run(opts)
  opts = opts or {}
  local config = require('agent.config').get()
  local gcfg = config.agents.gemini or {}
  local cmd = opts.cmd or gcfg.cmd or { 'gemini' }
  local dir = M.extension_dir(opts)
  local environ = M.agent_environ(opts.environ)

  local function fail(msg, level)
    vim.notify('agent.nvim: ' .. msg, level or vim.log.levels.ERROR)
    return false, msg
  end

  if vim.fn.executable(cmd[1]) ~= 1 then
    return fail(("gemini: executable '%s' not found"):format(cmd[1]))
  end

  if opts.confirm ~= false then
    local msg = table.concat({
      'Link the agent.nvim extension into Gemini CLI?',
      '',
      'This runs: ' .. table.concat(util.concat(cmd, { 'extensions', 'link', dir, '--consent' }), ' '),
      'Gemini records a link in ' .. vim.fs.joinpath(M.gemini_home(environ), '.gemini', 'extensions', M.EXTENSION_NAME),
      'so every Gemini session started from Neovim can use the "'
        .. (opts.server_name or config.nvim_mcp.server_name) .. '" MCP server.',
      'Your Gemini settings are not modified. Undo with: gemini extensions uninstall ' .. M.EXTENSION_NAME,
    }, '\n')
    if vim.fn.confirm(msg, '&Yes\n&No', 2) ~= 1 then
      vim.notify('agent.nvim: Gemini extension setup cancelled', vim.log.levels.INFO)
      return false, 'cancelled'
    end
  end

  local ok, path_or_err = M.write_manifest({
    extension_dir = dir,
    server_name = opts.server_name or config.nvim_mcp.server_name,
    command = opts.command,
    timeout_ms = config.nvim_mcp.timeout_ms,
  })
  if not ok then
    return fail('cannot write the Gemini extension manifest: ' .. tostring(path_or_err))
  end

  if M.is_linked({ environ = environ }) and not opts.force then
    vim.notify('agent.nvim: the Gemini extension is already linked; manifest updated at ' .. path_or_err,
      vim.log.levels.INFO)
    return true, nil
  end

  local argv = util.concat(cmd, { 'extensions', 'link', dir, '--consent' })
  local buf = vim.api.nvim_create_buf(false, false)
  vim.bo[buf].bufhidden = 'wipe'
  local win = vim.api.nvim_open_win(buf, true, {
    split = 'below',
    win = -1,
    height = math.max(8, math.floor(vim.o.lines * 0.3)),
  })
  local jok, job = pcall(vim.api.nvim_win_call, win, function()
    return vim.fn.jobstart(argv, {
      term = true,
      env = environ,
      clear_env = true,
      on_exit = function(_, code)
        if code == 0 then
          vim.notify('agent.nvim: Gemini extension linked. Restart running Gemini sessions to load it.',
            vim.log.levels.INFO)
        else
          vim.notify(('agent.nvim: `%s` exited with code %d'):format(table.concat(argv, ' '), code),
            vim.log.levels.ERROR)
        end
        if opts.on_exit then
          opts.on_exit(code)
        end
      end,
    })
  end)
  if not jok or type(job) ~= 'number' or job <= 0 then
    pcall(vim.api.nvim_win_close, win, true)
    return fail('cannot start ' .. table.concat(argv, ' ') .. (jok and '' or (': ' .. tostring(job))))
  end
  return true, nil
end

return M
