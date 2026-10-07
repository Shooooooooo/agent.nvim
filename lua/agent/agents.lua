---@mod agent.agents Agent definitions and launch specs
---
--- build_launch() turns an agent name plus provider launch info into everything jobstart needs:
--- argv, env, clear_env, cwd, and the temp files to delete afterwards. It follows
--- launch-and-mcp-registration.md §2 and §7: the $NVIM controller MCP server is registered per run
--- (never by editing user config), plugin options go after the user's args in `--opt=value` form,
--- and an inherited NVIM is never passed to the job.
local config = require('agent.config')
local nvim_mcp = require('agent.nvim_mcp')
local util = require('agent.util')

local uv = vim.uv or vim.loop

local M = {}

---Launch recipes, one per supported CLI.
M.KINDS = { 'claude', 'opencode', 'copilot', 'gemini' }

M.OPENCODE_SCHEMA = 'https://opencode.ai/config.json'
M.OPENCODE_MCP_TIMEOUT_MS = 600000
M.CLAUDE_EXIT_HINT_MS = 5000

local LOOPBACK = { 'localhost', '127.0.0.1', '::1' }

---Variables Gemini CLI reads to find an IDE companion (gemini.md §3.7).
local GEMINI_IDE_VARS = {
  'GEMINI_CLI_IDE_SERVER_PORT', 'GEMINI_CLI_IDE_WORKSPACE_PATH', 'GEMINI_CLI_IDE_AUTH_TOKEN',
  'GEMINI_CLI_IDE_PID', 'GEMINI_CLI_IDE_SERVER_STDIO_COMMAND', 'GEMINI_CLI_IDE_SERVER_STDIO_ARGS',
}

---Absolute path of the controller's entry point (agent.nvim_mcp.script_path()).
M.NVIM_MCP_MAIN = nvim_mcp.script_path()

local RESERVED_SERVER_NAMES = {
  ide = true, workspace = true, ['claude-in-chrome'] = true, ['computer-use'] = true,
  shell = true, write = true, url = true,
}

---@class agent.AgentDef: agent.AgentConfig
---@field name string
---@field kind 'claude'|'opencode'|'copilot'|'gemini'  Launch recipe

---@class agent.McpOpts
---@field enabled? boolean
---@field server_name? string
---@field command? string[]  argv of the controller (default: require('agent.nvim_mcp').command(addr))
---@field timeout_ms? integer

---@class agent.LaunchOpts
---@field cwd? string               Job cwd (default: getcwd())
---@field user_args? string[]       Per-launch args; placed after cmd and config args, before the plugin's args
---@field cmd? string[]             Override the configured cmd
---@field session_id? string        Default: a fresh UUID v4
---@field ide? table                Provider launch info: claude/opencode {port, token}; copilot {lock_folder}; gemini {port, token, pid}
---@field nvim_mcp? agent.McpOpts   Default: from config.nvim_mcp and agents.<name>.mcp
---@field auto_approve? boolean     Default: agents.<name>.auto_approve
---@field skip_trust? boolean       Gemini only. Default: agents.gemini.skip_trust
---@field scrub_vscode_env? boolean OpenCode only. Default: agents.opencode.scrub_vscode_env
---@field progress? boolean         Claude and Copilot only. Default: agents.<name>.progress (true unless false)
---@field env? table<string,string|false>  Extra env (false = unset); config env is applied too
---@field before_spawn? fun(spec: agent.LaunchSpec)  Called right before jobstart (e.g. touch the Claude lock for OpenCode)
---@field on_exit? fun(code: integer, info: table)    Called when the job exits
---@field servername? string        Parent address (default: v:servername, started if empty)
---@field environ? table<string,string>  Inherited environment (default: vim.fn.environ())
---@field sessions_dir? string      Parent of the per-session temp dir (default: util.run_dir('sessions'))
---@field gemini_extension_dir? string
---@field claude_managed_dirs? string[]  Claude managed-policy dirs to check (default: the OS location)
---@field gemini_system_settings_path? string
---@field gemini_system_defaults_path? string

---@class agent.LaunchWarning
---@field id string   Stable id; the terminal shows each id once per session
---@field msg string
---@field level integer vim.log.levels.*

---@class agent.ExitHint
---@field within_ms integer
---@field patterns string[]  Plain substrings searched in the terminal buffer
---@field message string

---@class agent.LaunchSpec
---@field name string
---@field kind string
---@field argv string[]
---@field env table<string,string>
---@field clear_env boolean
---@field cwd string
---@field cleanup string[]  Paths to delete (recursively) when the job exits
---@field session_id string
---@field warnings agent.LaunchWarning[]
---@field exit_hints agent.ExitHint[]
---@field mcp { registered: boolean, server_name: string|nil, file: string|nil }
---@field before_spawn? fun(spec: agent.LaunchSpec)
---@field on_exit? fun(code: integer, info: table)

---@param name string
---@param a table
---@return string
local function kind_of(name, a)
  if a.kind then
    return a.kind
  end
  for _, k in ipairs(M.KINDS) do
    if k == name then
      return k
    end
  end
  return a.provider or 'claude'
end

---Agent definition from the configuration (a copy), or nil for an unknown agent.
---@param name string
---@return agent.AgentDef|nil
function M.get(name)
  local a = config.get().agents[name]
  if type(a) ~= 'table' then
    return nil
  end
  local def = vim.deepcopy(a)
  def.name = name
  def.kind = kind_of(name, def)
  return def
end

---Configured agent names, sorted.
---@return string[]
function M.list()
  local names = vim.tbl_keys(config.get().agents)
  table.sort(names)
  return names
end

---Parent address for children: v:servername, starting a server first when it is empty.
---@return string
function M.servername()
  if vim.v.servername == nil or vim.v.servername == '' then
    pcall(vim.fn.serverstart)
  end
  return vim.v.servername or ''
end

---@param name string
---@return boolean ok, string|nil err
function M.valid_server_name(name)
  if type(name) ~= 'string' or not name:match('^[A-Za-z0-9-]+$') or #name > 24 then
    return false, 'must match ^[A-Za-z0-9-]{1,24}$'
  end
  if RESERVED_SERVER_NAMES[name:lower()] then
    return false, 'is reserved'
  end
  return true, nil
end

---Merge comma-separated host lists, keeping order and adding the loopback hosts.
---@return string
local function no_proxy_with_loopback(...)
  local entries, seen = {}, {}
  local function add(e)
    e = vim.trim(e)
    if e ~= '' and not seen[e] then
      seen[e] = true
      entries[#entries + 1] = e
    end
  end
  for i = 1, select('#', ...) do
    local v = select(i, ...)
    if type(v) == 'string' then
      for e in v:gmatch('[^,]+') do
        add(e)
      end
    end
  end
  for _, h in ipairs(LOOPBACK) do
    add(h)
  end
  return table.concat(entries, ',')
end

-- Order-preserving JSON for merging into an inherited OPENCODE_CONFIG_CONTENT. OpenCode keeps the
-- user's key order on purpose and resolves permission rules with findLast over it, so that text
-- must never round-trip through Lua tables. An object node is { keys = {..}, vals = {..}, raw = {..} }
-- (raw: the key's original JSON text); every other value stays as its original JSON text.

---Parse JSON text that vim.json.decode has already accepted.
---@param s string
---@return table|string|nil node, string|nil err
local function ojson_parse(s)
  local pos = 1
  local function ws()
    pos = s:find('[^ \t\r\n]', pos) or (#s + 1)
  end
  local function skip_string()
    local i = pos + 1
    while true do
      local j = s:find('["\\]', i)
      if not j then
        error('unterminated string')
      end
      if s:byte(j) == 92 then
        i = j + 2
      else
        pos = j + 1
        return
      end
    end
  end
  local value
  local function object()
    local node = { keys = {}, vals = {}, raw = {} }
    pos = pos + 1
    ws()
    if s:sub(pos, pos) == '}' then
      pos = pos + 1
      return node
    end
    while true do
      ws()
      local start = pos
      if s:sub(pos, pos) ~= '"' then
        error('expected a key at ' .. pos)
      end
      skip_string()
      local raw = s:sub(start, pos - 1)
      local key = vim.json.decode(raw)
      ws()
      if s:sub(pos, pos) ~= ':' then
        error("expected ':' at " .. pos)
      end
      pos = pos + 1
      ws()
      local v = value()
      if node.vals[key] == nil then -- a duplicate key keeps its first position, like JSON.parse
        node.keys[#node.keys + 1] = key
        node.raw[key] = raw
      end
      node.vals[key] = v
      ws()
      local c = s:sub(pos, pos)
      pos = pos + 1
      if c == '}' then
        return node
      elseif c ~= ',' then
        error("expected ',' or '}' at " .. (pos - 1))
      end
    end
  end
  function value()
    local c = s:sub(pos, pos)
    if c == '{' then
      return object()
    end
    local start = pos
    if c == '"' then
      skip_string()
    elseif c == '[' then
      local depth = 0
      repeat
        local j = s:find('[%[%]{}"]', pos)
        if not j then
          error('unterminated array')
        end
        pos = j
        local ch = s:sub(j, j)
        if ch == '"' then
          skip_string()
        else
          depth = depth + ((ch == '[' or ch == '{') and 1 or -1)
          pos = j + 1
        end
      until depth == 0
    else
      pos = s:find('[,}%]%s]', pos) or (#s + 1)
      if pos == start then
        error('expected a value at ' .. pos)
      end
    end
    return s:sub(start, pos - 1)
  end
  local ok, node = pcall(function()
    ws()
    local v = value()
    ws()
    if pos <= #s then
      error('trailing text at ' .. pos)
    end
    return v
  end)
  if not ok then
    return nil, tostring(node)
  end
  return node, nil
end

---Node for a Lua value of ours (map keys sorted, so the output is stable).
---@param v any
---@return table|string
local function ojson_from(v)
  if type(v) ~= 'table' or vim.islist(v) or next(v) == nil then
    return util.json_encode(v)
  end
  local node = { keys = vim.tbl_keys(v), vals = {}, raw = {} }
  table.sort(node.keys)
  for _, k in ipairs(node.keys) do
    node.vals[k] = ojson_from(v[k])
  end
  return node
end

---@param node table|string
---@return string
local function ojson_encode(node)
  if type(node) == 'string' then
    return node
  end
  local parts = {}
  for _, k in ipairs(node.keys) do
    parts[#parts + 1] = (node.raw[k] or util.json_encode(k)) .. ':' .. ojson_encode(node.vals[k])
  end
  return '{' .. table.concat(parts, ',') .. '}'
end

---Deep merge like remeda's mergeDeep, keeping key order: `a`'s keys stay where they are and new
---keys from `b` are appended; objects merge recursively, anything else from `b` wins.
---@param a table|string|nil
---@param b table|string
---@return table|string
local function ojson_merge(a, b)
  if type(a) ~= 'table' or type(b) ~= 'table' then
    return b
  end
  local out = { keys = vim.list_slice(a.keys), vals = {}, raw = {} }
  for k, v in pairs(a.vals) do
    out.vals[k] = v
    out.raw[k] = a.raw[k]
  end
  for _, k in ipairs(b.keys) do
    if out.vals[k] == nil then
      out.keys[#out.keys + 1] = k
      out.raw[k] = b.raw[k]
    end
    out.vals[k] = ojson_merge(out.vals[k], b.vals[k])
  end
  return out
end

---Merge our OpenCode config into an inherited OPENCODE_CONFIG_CONTENT as OpenCode would merge it
---as a later layer: the user's text keeps its key order, and a string `permission` is normalized
---to {"*": value} first (OpenCode does that per layer), so our rule is added after the user's.
---@param existing string  JSON text accepted by vim.json.decode
---@param cfg table
---@return string|nil merged  nil when `existing` is not a JSON object
function M._merge_opencode_content(existing, cfg)
  local base = ojson_parse(existing)
  if type(base) ~= 'table' then
    return nil
  end
  local ours = ojson_from(cfg)
  local perm = base.vals.permission
  if cfg.permission and type(perm) == 'string' and perm:sub(1, 1) == '"' then
    base.vals.permission = { keys = { '*' }, vals = { ['*'] = perm }, raw = {} }
  end
  local merged = ojson_encode(ojson_merge(base, ours))
  -- Belt and braces: never hand OpenCode a config it cannot parse.
  return pcall(vim.json.decode, merged) and merged or nil
end

---@param path string
---@return boolean
local function exists(path)
  return uv.fs_stat(path) ~= nil
end

---Claude's managed-policy directories (managed-mcp.json, managed-settings.json, managed-settings.d/).
---@param environ table|nil
---@return string[]
function M.claude_managed_dirs(environ)
  local sys = uv.os_uname().sysname
  local dirs
  if sys == 'Darwin' then
    dirs = { '/Library/Application Support/ClaudeCode' }
  elseif sys:find('Windows') then
    dirs = { 'C:\\Program Files\\ClaudeCode' }
  else
    dirs = { '/etc/claude-code' }
  end
  local extra = (environ or vim.fn.environ()).CLAUDE_CODE_MANAGED_SETTINGS_PATH
  if extra and extra ~= '' then
    dirs[#dirs + 1] = extra
  end
  return dirs
end

---@param path string
---@return table|nil
local function read_json_file(path)
  local fd = uv.fs_open(path, 'r', 0)
  if not fd then
    return nil
  end
  local st = uv.fs_fstat(fd)
  local data = st and uv.fs_read(fd, st.size, 0)
  uv.fs_close(fd)
  if not data then
    return nil
  end
  local ok, v = util.json_decode(data)
  return ok and type(v) == 'table' and v or nil
end

---Why Claude would refuse `--mcp-config` (it exits at startup), or nil. Checks managed-mcp.json
---(any existing file keeps exclusive control of MCP servers) and `disableSideloadFlags` in the
---managed settings file and its drop-in directory. MDM and server-managed policy cannot be read
---from here; the exit hint covers those.
---@param dirs string[]|nil
---@return string|nil reason
function M.claude_mcp_block_reason(dirs)
  for _, dir in ipairs(dirs or M.claude_managed_dirs()) do
    local mcp = vim.fs.joinpath(dir, 'managed-mcp.json')
    if exists(mcp) then
      return 'an enterprise MCP config is present (' .. mcp .. ')'
    end
    local files = { vim.fs.joinpath(dir, 'managed-settings.json') }
    local dropin = vim.fs.joinpath(dir, 'managed-settings.d')
    local names = {}
    for fname, ftype in vim.fs.dir(dropin) do
      if (ftype == 'file' or ftype == 'link') and fname:sub(-5) == '.json' and fname:sub(1, 1) ~= '.' then
        names[#names + 1] = fname
      end
    end
    table.sort(names)
    for _, fname in ipairs(names) do
      files[#files + 1] = vim.fs.joinpath(dropin, fname)
    end
    for _, f in ipairs(files) do
      local s = read_json_file(f)
      if s and s.disableSideloadFlags == true then
        return 'managed settings set disableSideloadFlags (' .. f .. ')'
      end
    end
  end
  return nil
end

---Collect the values of a yargs array option (`--opt v`, `--opt=v`, comma-separated) from argv.
---@param args string[]
---@param names table<string, boolean>  e.g. { ['-e'] = true, ['--extensions'] = true }
---@return string[]|nil values  nil when the option is absent
local function option_values(args, names)
  local vals
  local i = 1
  while i <= #args do
    local a = args[i]
    if a == '--' then
      break
    end
    local key, val = a:match('^(%-%-?[^=]+)=(.*)$')
    if key and names[key] then
      vals = vals or {}
      vals[#vals + 1] = val
    elseif names[a] then
      vals = vals or {}
      if args[i + 1] ~= nil then
        vals[#vals + 1] = args[i + 1]
        i = i + 1
      end
    end
    i = i + 1
  end
  if not vals then
    return nil
  end
  local out = {}
  for _, v in ipairs(vals) do
    for part in v:gmatch('[^,]+') do
      part = vim.trim(part)
      if part ~= '' then
        out[#out + 1] = part
      end
    end
  end
  return out
end
M._option_values = option_values

---@param list string[]
---@param value string
---@return boolean
local function contains_ci(list, value)
  for _, v in ipairs(list) do
    if v:lower() == value:lower() then
      return true
    end
  end
  return false
end

---@param args string[]
---@param flag string
---@return boolean
local function has_flag(args, flag)
  for _, a in ipairs(args) do
    if a == '--' then
      return false
    end
    if a == flag or a:sub(1, #flag + 1) == flag .. '=' then
      return true
    end
  end
  return false
end

local recipes = {}

---Make Claude Code or Copilot CLI report their progress (OSC 9;4, see agent.progress) to Neovim's
---terminal. Both send it only to terminals they know, ConEmu among them: ConEmuANSI=ON stands for
---it, unless the agent's env sets ConEmuANSI itself. Claude Code 2.1 also reports "conemu" as its
---terminal when no other variable names one; the commands the agent runs inherit it, and hardly
---any program outside Windows reads it.
---@param ctx table
local function report_progress(ctx)
  if ctx.progress and ctx.user_env.ConEmuANSI == nil then
    ctx.env.ConEmuANSI = 'ON'
  end
end

---@param ctx table
function recipes.claude(ctx)
  local env, argv = ctx.env, ctx.argv
  if ctx.ide then
    if ctx.ide.port then
      env.CLAUDE_CODE_SSE_PORT = tostring(ctx.ide.port)
    end
    env.FORCE_CODE_TERMINAL = 'true'
    env.ENABLE_IDE_INTEGRATION = 'true'
    local auto = ctx.getenv('CLAUDE_CODE_AUTO_CONNECT_IDE')
    if auto and (auto:lower() == 'false' or auto == '0') then
      ctx.warn('claude-auto-connect-off',
        'CLAUDE_CODE_AUTO_CONNECT_IDE=' .. auto .. ' is set: Claude will not connect to Neovim automatically (use /ide)')
    end
  end
  env.CLAUDE_CODE_IDE_SKIP_AUTO_INSTALL = 'true'
  local np = no_proxy_with_loopback(ctx.getenv('no_proxy'), ctx.getenv('NO_PROXY'))
  env.no_proxy, env.NO_PROXY = np, np
  report_progress(ctx)

  local mcp = ctx.mcp
  if not mcp then
    return
  end
  local reason = M.claude_mcp_block_reason(ctx.opts.claude_managed_dirs or M.claude_managed_dirs(ctx.lookup_env))
  if reason then
    ctx.warn('claude-mcp-managed',
      ('%s: not registering the Neovim MCP server because %s (Claude exits on --mcp-config). '
        .. 'Set agents.%s.mcp = false to silence this.'):format(ctx.spec.name, reason, ctx.spec.name))
    return
  end
  local entry = { type = 'stdio', command = mcp.command[1], args = mcp.args, env = mcp.env }
  local path = ctx.write('claude-mcp.json', util.json_encode({ mcpServers = { [mcp.server_name] = entry } }))
  if not path then
    return
  end
  argv[#argv + 1] = '--mcp-config=' .. path
  if ctx.auto_approve then
    argv[#argv + 1] = '--allowedTools=mcp__' .. mcp.server_name
  end
  ctx.registered(path)
  ctx.spec.exit_hints[#ctx.spec.exit_hints + 1] = {
    within_ms = M.CLAUDE_EXIT_HINT_MS,
    patterns = { 'enterprise MCP config', 'disableSideloadFlags' },
    message = ('%s: Claude refused --mcp-config because of a managed policy. Set agents.%s.mcp = false '
      .. 'to launch it without the Neovim MCP server.'):format(ctx.spec.name, ctx.spec.name),
  }
end

---@param ctx table
function recipes.copilot(ctx)
  local ide = ctx.ide or {}
  ctx.spec.cwd = ide.lock_folder or ide.workspace_folder or util.realpath(ctx.spec.cwd)
  report_progress(ctx)
  local mcp = ctx.mcp
  if not mcp then
    return
  end
  local entry = { type = 'stdio', command = mcp.command[1], args = mcp.args, env = mcp.env, tools = { '*' } }
  local path = ctx.write('copilot-mcp.json', util.json_encode({ mcpServers = { [mcp.server_name] = entry } }))
  if not path then
    return
  end
  local argv = ctx.argv
  argv[#argv + 1] = '--additional-mcp-config'
  argv[#argv + 1] = '@' .. path
  if ctx.auto_approve then
    argv[#argv + 1] = '--allow-tool=' .. mcp.server_name
  end
  ctx.registered(path)
end

---@param ctx table
function recipes.gemini(ctx)
  local gemini = require('agent.gemini_setup')
  local env, argv = ctx.env, ctx.argv
  local ide = ctx.ide
  local gopts = {
    environ = ctx.lookup_env,
    cwd = ctx.spec.cwd,
    system_settings_path = ctx.opts.gemini_system_settings_path,
    system_defaults_path = ctx.opts.gemini_system_defaults_path,
  }
  if ide and ide.port then
    env.GEMINI_CLI_IDE_SERVER_PORT = tostring(ide.port)
    env.GEMINI_CLI_IDE_WORKSPACE_PATH = util.realpath(ctx.spec.cwd)
    env.GEMINI_CLI_IDE_AUTH_TOKEN = ide.token and tostring(ide.token) or ''
    env.GEMINI_CLI_IDE_PID = tostring(ide.pid or vim.fn.getpid())
    env.GEMINI_CLI_IDE_SERVER_STDIO_COMMAND = ''
    if ctx.getenv('GEMINI_CLI_IDE_SERVER_STDIO_ARGS') then
      env.GEMINI_CLI_IDE_SERVER_STDIO_ARGS = ''
    end
    if not gemini.ide_enabled(gopts) then
      ctx.warn('gemini-ide-disabled',
        'gemini: IDE mode is off in your Gemini settings. Run /ide enable once in Gemini to connect it to Neovim.',
        vim.log.levels.INFO)
    end
  else
    -- No Gemini provider: blank what Neovim inherited (e.g. from a VS Code terminal), unless the
    -- agent config sets it. Gemini adds every GEMINI_CLI_IDE_WORKSPACE_PATH folder other than cwd to
    -- includeDirectories even without IDE mode; an empty value counts as unset for each of these.
    for _, k in ipairs(GEMINI_IDE_VARS) do
      if ctx.environ[k] ~= nil and ctx.user_env[k] == nil then
        env[k] = ''
      end
    end
  end

  local mcp = ctx.mcp
  if mcp then
    -- The persisted manifest must survive nvim upgrades and work outside this Neovim, so it uses a
    -- stable nvim path and "${NVIM}" (resolved by Gemini from its own environment) for the address.
    local command = vim.deepcopy(mcp.command)
    if command[1] == vim.v.progpath then
      command[1] = gemini.stable_nvim()
    end
    for i = 2, #command do
      if command[i] == mcp.addr then
        command[i] = '${NVIM}'
      end
    end
    local ok, perr = gemini.write_manifest({
      extension_dir = ctx.opts.gemini_extension_dir,
      server_name = mcp.server_name,
      command = command,
      timeout_ms = mcp.timeout_ms,
    })
    if not ok then
      ctx.warn('gemini-manifest', 'gemini: cannot write the extension manifest: ' .. tostring(perr)
        .. '. Launching without the Neovim MCP server.')
    else
      ctx.registered(perr)
      if not gemini.is_linked({ environ = ctx.lookup_env }) then
        ctx.warn('gemini-not-linked',
          'gemini: run :AgentGeminiSetup once to register the Neovim MCP server with Gemini CLI.',
          vim.log.levels.INFO)
      end
      local ext = option_values(argv, { ['-e'] = true, ['--extensions'] = true })
      if ext then
        if #ext == 1 and ext[1] == 'none' then
          ctx.warn('gemini-extensions-none', 'gemini: -e none disables the agent.nvim extension (no Neovim MCP server).')
        elseif not contains_ci(ext, gemini.EXTENSION_NAME) then
          ctx.fixups[#ctx.fixups + 1] = '--extensions=' .. gemini.EXTENSION_NAME
        end
      end
      local allowed = option_values(argv, { ['--allowed-mcp-server-names'] = true, ['--allowedMcpServerNames'] = true })
      if allowed then
        -- Gemini matches server names exactly here (isBlockedBySettings: allowed.includes(name)).
        if not vim.tbl_contains(allowed, mcp.server_name) then
          ctx.fixups[#ctx.fixups + 1] = '--allowed-mcp-server-names=' .. mcp.server_name
        end
      else
        local why = gemini.mcp_block_reason(mcp.server_name, gopts)
        if why then
          ctx.warn('gemini-mcp-blocked', ('gemini: your Gemini settings block the %q MCP server: %s. '
            .. 'Allow it there to use the Neovim tools.'):format(mcp.server_name, why), vim.log.levels.INFO)
        end
      end
      if ctx.auto_approve then
        -- --policy replaces the user policy dir and settings.policyPaths, so re-list them first
        -- unless the user passed --policy themselves.
        local paths, lerr = {}, nil
        if not has_flag(argv, '--policy') then
          paths, lerr = gemini.policy_locations(gopts)
        end
        if not paths then
          ctx.warn('gemini-policy', 'gemini: auto_approve skipped: ' .. tostring(lerr))
        else
          -- toolName is required by Gemini's TOML schema (0.61 and 0.63), despite its docs;
          -- with mcpName it expands to mcp_<server>_*.
          local toml = table.concat({
            '[[rule]]',
            'mcpName = "' .. mcp.server_name .. '"',
            'toolName = "*"',
            'decision = "allow"',
            'priority = 1',
            '',
          }, '\n')
          local tpath = ctx.write('agent-nvim.toml', toml)
          if tpath then
            for _, p in ipairs(paths) do
              ctx.fixups[#ctx.fixups + 1] = '--policy=' .. p
            end
            ctx.fixups[#ctx.fixups + 1] = '--policy=' .. tpath
          end
        end
      end
    end
  end
  if ctx.skip_trust then
    ctx.fixups[#ctx.fixups + 1] = '--skip-trust'
  end
end

---@param ctx table
function recipes.opencode(ctx)
  local env = ctx.env
  -- OpenCode connects without the auth token when either is set; "" is falsy there (§6.6).
  env.CLAUDE_CODE_SSE_PORT = ''
  env.OPENCODE_EDITOR_SSE_PORT = ''
  local np = no_proxy_with_loopback(ctx.getenv('no_proxy'), ctx.getenv('NO_PROXY'))
  env.no_proxy, env.NO_PROXY = np, np
  if ctx.scrub_vscode_env and ctx.getenv('TERM_PROGRAM') == 'vscode' then
    env.TERM_PROGRAM, env.TERM_PROGRAM_VERSION, env.GIT_ASKPASS = '', '', ''
  end

  local mcp = ctx.mcp
  if not mcp then
    return
  end
  local cfg = {
    ['$schema'] = M.OPENCODE_SCHEMA,
    mcp = {
      [mcp.server_name] = {
        type = 'local',
        command = util.concat({ mcp.command[1] }, mcp.args),
        environment = mcp.env,
        enabled = true,
        timeout = M.OPENCODE_MCP_TIMEOUT_MS,
      },
    },
  }
  if ctx.auto_approve then
    cfg.permission = { [mcp.server_name .. '_*'] = 'allow' }
  end
  local existing = ctx.getenv('OPENCODE_CONFIG_CONTENT')
  if existing == nil or vim.trim(existing) == '' then
    env.OPENCODE_CONFIG_CONTENT = util.json_encode(cfg)
    ctx.registered(nil)
    return
  end
  local merged = pcall(vim.json.decode, existing) and M._merge_opencode_content(existing, cfg) or nil
  if merged then
    env.OPENCODE_CONFIG_CONTENT = merged
    ctx.registered(nil)
    return
  end
  local oc = ctx.getenv('OPENCODE_CONFIG')
  if oc == nil or oc == '' then
    local path = ctx.write('opencode.json', util.json_encode(cfg))
    if path then
      env.OPENCODE_CONFIG = path
      ctx.registered(path)
    end
    return
  end
  ctx.warn('opencode-config',
    'opencode: OPENCODE_CONFIG_CONTENT is not plain JSON and OPENCODE_CONFIG is already set; '
      .. 'not registering the Neovim MCP server.')
end

---Resolve the MCP registration settings, or nil when disabled or impossible.
---@return table|nil
local function resolve_mcp(name, def, opts, cfg, warn)
  local o = opts.nvim_mcp or {}
  local enabled = o.enabled
  if enabled == nil then
    enabled = cfg.nvim_mcp.enabled ~= false and def.mcp ~= false
  end
  if not enabled then
    return nil
  end
  local server_name = o.server_name or cfg.nvim_mcp.server_name or 'nvim'
  local vok, verr = M.valid_server_name(server_name)
  if not vok then
    warn('mcp-server-name', ('invalid nvim_mcp.server_name %q (%s); not registering the MCP server'):format(
      tostring(server_name), verr))
    return nil
  end
  local addr = opts.servername or M.servername()
  if addr == '' then
    warn('mcp-no-server', 'Neovim has no server address (serverstart failed); not registering the MCP server')
    return nil
  end
  if addr:find('[%${}]') then
    warn('mcp-bad-addr', ('the Neovim server address %q contains $, { or }; not registering the MCP server'):format(addr))
    return nil
  end
  local command = o.command or nvim_mcp.command(addr)
  local args = {}
  for i = 2, #command do
    args[#args + 1] = command[i]
  end
  local timeout = o.timeout_ms or cfg.nvim_mcp.timeout_ms
  local env = nvim_mcp.env({ addr = addr, agent = def.kind, session = opts.session_id, timeout_ms = timeout })
  return {
    server_name = server_name,
    command = command,
    args = args,
    env = env,
    addr = addr,
    timeout_ms = timeout,
  }
end

---Build the launch spec for an agent. Pure apart from writing the per-session temp files (and the
---persisted Gemini extension manifest); it never starts processes or touches provider state.
---@param name string
---@param opts agent.LaunchOpts|nil
---@return agent.LaunchSpec|nil spec, string|nil err
function M.build_launch(name, opts)
  opts = vim.tbl_extend('force', {}, opts or {})
  local def = M.get(name)
  if not def then
    return nil, ('unknown agent %q'):format(tostring(name))
  end
  local recipe = recipes[def.kind]
  if not recipe then
    return nil, ('agent %q has an unknown kind %q'):format(name, tostring(def.kind))
  end
  local cfg = config.get()
  opts.session_id = opts.session_id or util.uuid()
  local environ = opts.environ or vim.fn.environ()

  -- User-supplied env layers (false = unset). The plugin's own values win over them, except for
  -- list-like variables that are merged (no_proxy, OPENCODE_CONFIG_CONTENT).
  local user_env = vim.tbl_extend('force', {}, def.env or {}, opts.env or {})
  local lookup_env = vim.tbl_extend('force', {}, environ)
  for k, v in pairs(user_env) do
    if v == false then
      lookup_env[k] = nil
    else
      lookup_env[k] = tostring(v)
    end
  end

  local spec = {
    name = name,
    kind = def.kind,
    argv = util.concat(opts.cmd or def.cmd, def.args, opts.user_args),
    env = {},
    clear_env = false,
    cwd = util.abspath(opts.cwd or vim.fn.getcwd()),
    cleanup = {},
    session_id = opts.session_id,
    warnings = {},
    exit_hints = {},
    mcp = { registered = false },
    before_spawn = opts.before_spawn,
    on_exit = opts.on_exit,
  }

  local function warn(id, msg, level)
    spec.warnings[#spec.warnings + 1] = { id = id, msg = msg, level = level or vim.log.levels.WARN }
  end

  local session_dir
  local function write(fname, data)
    if not session_dir then
      local dir
      if opts.sessions_dir then
        dir = vim.fs.joinpath(opts.sessions_dir, opts.session_id)
        local ok, made = pcall(util.mkdir_p, dir, tonumber('700', 8))
        if not ok or not made or vim.fn.isdirectory(dir) == 0 then
          dir = nil
        end
      else
        local ok, d = pcall(util.run_dir, 'sessions', opts.session_id)
        dir = ok and vim.fn.isdirectory(d) == 1 and d or nil
      end
      if not dir then
        warn('mcp-tempfile', name .. ': cannot create a private temp dir; launching without the Neovim MCP server')
        return nil
      end
      session_dir = dir
      spec.cleanup[#spec.cleanup + 1] = dir
    end
    local path = vim.fs.joinpath(session_dir, fname)
    local ok, err = util.atomic_write(path, data, tonumber('600', 8))
    if not ok then
      warn('mcp-tempfile', name .. ': cannot write ' .. path .. ' (' .. tostring(err)
        .. '); launching without the Neovim MCP server')
      return nil
    end
    return path
  end

  local mcp = resolve_mcp(name, def, opts, cfg, warn)
  if mcp then
    spec.mcp.server_name = mcp.server_name
  end

  local auto_approve = opts.auto_approve
  if auto_approve == nil then
    auto_approve = def.auto_approve == true
  end
  local skip_trust = opts.skip_trust
  if skip_trust == nil then
    skip_trust = def.skip_trust == true
  end
  local scrub = opts.scrub_vscode_env
  if scrub == nil then
    scrub = def.scrub_vscode_env ~= false
  end
  local report = opts.progress
  if report == nil then
    report = def.progress ~= false
  end

  local plugin_env = { AGENT_NVIM_SESSION = opts.session_id }
  local ctx = {
    spec = spec,
    opts = opts,
    argv = spec.argv,
    env = plugin_env,
    fixups = {},
    ide = opts.ide,
    mcp = mcp,
    auto_approve = auto_approve,
    skip_trust = skip_trust,
    scrub_vscode_env = scrub,
    progress = report,
    environ = environ,
    user_env = user_env,
    lookup_env = lookup_env,
    getenv = function(k)
      return lookup_env[k]
    end,
    warn = warn,
    write = write,
    registered = function(file)
      spec.mcp.registered = true
      spec.mcp.file = file
    end,
  }
  recipe(ctx)
  for _, a in ipairs(ctx.fixups) do
    spec.argv[#spec.argv + 1] = a
  end

  -- Final env: user layers, then the plugin's values. Never pass NVIM: Neovim sets it to
  -- v:servername for every job, but only when env has no NVIM key (§2.1).
  local final = {}
  for k, v in pairs(user_env) do
    if v == false then
      final[k] = false
    else
      final[k] = tostring(v)
    end
  end
  for k, v in pairs(plugin_env) do
    final[k] = v
  end
  final.NVIM = nil
  local drop = {}
  for k, v in pairs(final) do
    if v == false then
      drop[#drop + 1] = k
    end
  end
  if #drop > 0 then
    -- Unsetting needs clear_env with a full copy; the copy MUST NOT carry the inherited NVIM.
    local full = vim.tbl_extend('force', {}, environ)
    full.NVIM = nil
    for k, v in pairs(final) do
      if v == false then
        full[k] = nil
      else
        full[k] = v
      end
    end
    spec.env, spec.clear_env = full, true
  else
    spec.env = final
  end
  return spec, nil
end

---Delete a spec's temp files.
---@param spec agent.LaunchSpec|nil
function M.cleanup(spec)
  if not spec or not spec.cleanup then
    return
  end
  for _, p in ipairs(spec.cleanup) do
    util.remove_dir(p)
  end
end

---MCP config for manual registration (:AgentMcpConfig). The agent must run inside a Neovim
---terminal: the controller finds the parent through the inherited $NVIM.
---@param name string
---@return table|nil config, string|nil err
function M.manual_mcp_config(name)
  local def = M.get(name)
  if not def then
    return nil, ('unknown agent %q'):format(tostring(name))
  end
  local cfg = config.get()
  local server = cfg.nvim_mcp.server_name
  local nvim = nvim_mcp.stable_nvim()
  local args = nvim_mcp.base_args()
  if def.kind == 'opencode' then
    return {
      ['$schema'] = M.OPENCODE_SCHEMA,
      mcp = { [server] = { type = 'local', command = util.concat({ nvim }, args), enabled = true,
        timeout = M.OPENCODE_MCP_TIMEOUT_MS } },
    }
  elseif def.kind == 'gemini' then
    return { mcpServers = { [server] = { command = nvim, args = util.concat(args, { '${NVIM}' }),
      env = { NVIM = '${NVIM}' } } } }
  elseif def.kind == 'copilot' then
    return { mcpServers = { [server] = { type = 'stdio', command = nvim, args = args, tools = { '*' } } } }
  end
  return { mcpServers = { [server] = { type = 'stdio', command = nvim, args = args } } }
end

return M
