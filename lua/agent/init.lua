---@mod agent agent.nvim: coding-agent CLIs in Neovim terminals, with IDE integration
---
--- setup() wires the modules together:
---  * agent.terminal runs one terminal per agent. Its launcher (below) starts the agent's IDE
---    provider on first use, asks it for launch info and builds the launch spec with
---    agent.agents.build_launch (which also registers the $NVIM controller MCP server).
---  * agent.editor.selection is forwarded to every running provider (config.selection.track).
---  * VimLeavePre stops providers and terminals and removes temp files.
---
--- Commands are declared in plugin/agent.lua and implemented here (M._command). They call
--- setup({}) lazily when the user never called setup().
local config = require('agent.config')
local log = require('agent.log')
local terminal = require('agent.terminal')
local util = require('agent.util')

local uv = vim.uv or vim.loop

local M = {}

---IDE providers, in a stable order.
M.PROVIDERS = { 'claude', 'copilot', 'gemini' }

---Providers with an at-mention notification (gemini has none, so mentions are always typed).
local MENTION_PROVIDERS = { claude = true, copilot = true }

---After a launch, a provider mention that fails is retried this long (the agent is still
---connecting) before the reference is typed into the terminal instead.
M.MENTION_WAIT_MS = 15000
M.MENTION_POLL_MS = 250
---A reference typed into a terminal that was started less than this ago is delayed until then,
---so the agent's TUI is ready to receive input.
M.STARTUP_GRACE_MS = 3000

local state = {
  setup_done = false,
  ---@type integer|nil
  augroup = nil,
  ---@type fun()|nil  selection subscription
  unsubscribe = nil,
  ---@type table<string, number>  agent name -> util.now_ms() of its last launch
  launched = {},
}

local function scoped()
  return log.scope('init')
end

---@param name string
---@return table|nil provider module (loaded or not)
local function provider(name)
  local ok, P = pcall(require, 'agent.providers.' .. name)
  if not ok then
    scoped().error('cannot load provider %s: %s', name, tostring(P))
    return nil
  end
  return P
end

---@param name string
---@return table|nil provider module, only when it is already loaded
local function loaded_provider(name)
  local P = package.loaded['agent.providers.' .. name]
  return type(P) == 'table' and P or nil
end

---@param name string
---@return boolean
local function provider_enabled(name)
  local p = config.get().providers[name]
  return not (type(p) == 'table' and p.enabled == false)
end

---Forward one selection event to every running provider.
---@param s agent.Selection|nil
local function forward_selection(s)
  if not s or config.get().selection.track == false then
    return
  end
  for _, name in ipairs(M.PROVIDERS) do
    local P = loaded_provider(name)
    if P and P.is_running and P.is_running() and P.on_selection then
      local ok, err = pcall(P.on_selection, s)
      if not ok then
        scoped().error('%s.on_selection failed: %s', name, tostring(err))
      end
    end
  end
end

---Start selection tracking and forwarding (once), when config.selection.track is on.
local function ensure_selection()
  if state.unsubscribe or config.get().selection.track == false then
    return
  end
  local sel = require('agent.editor.selection')
  sel.start()
  state.unsubscribe = sel.subscribe(function(s)
    forward_selection(s)
  end)
end

local function stop_selection()
  if state.unsubscribe then
    state.unsubscribe()
    state.unsubscribe = nil
    pcall(function()
      require('agent.editor.selection').stop()
    end)
  end
end

---Start a provider (idempotent) and selection forwarding. A provider started now also gets the
---current selection, since the selection module only reports changes.
---@param name string
---@return table|nil provider, string|nil err  err is nil when the provider is disabled
local function start_provider(name)
  if not provider_enabled(name) then
    return nil, nil
  end
  local P = provider(name)
  if not P then
    return nil, 'cannot load provider ' .. name
  end
  local was_running = P.is_running()
  local ok, err = P.start()
  if not ok then
    return nil, err or ('cannot start provider ' .. name)
  end
  ensure_selection()
  if not was_running and config.get().selection.track ~= false then
    local sok, s = pcall(function()
      return (require('agent.editor.selection').current())
    end)
    if sok and s then
      pcall(P.on_selection, s)
    end
  end
  return P, nil
end

---Reload the unmodified file buffers whose file changed on disk. Agents also change files without
---a diff (shell commands, auto-approved edits), and Neovim checks timestamps only on focus events
---and :checktime. Buffers with unsaved changes, and buffers whose 'autoread' is off, are left alone.
local function reload_changed_buffers()
  local context = require('agent.editor.context')
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) and not vim.bo[b].modified and context.is_file_buffer(b) then
      pcall(vim.api.nvim_buf_call, b, function()
        if vim.o.autoread then
          vim.cmd('silent! checktime ' .. b)
        end
      end)
    end
  end
end

---The terminal launcher: start the agent's provider, get its launch info, build the spec.
---@param name string
---@param open_opts agent.OpenOpts
---@return agent.LaunchSpec|nil spec, string|nil err
local function launcher(name, open_opts)
  local agents = require('agent.agents')
  local def = agents.get(name)
  if not def then
    return nil, ('unknown agent %q'):format(tostring(name))
  end
  local cfg = config.get()
  open_opts = open_opts or {}
  -- Checked here too (terminal.lua checks again), so a missing CLI never starts a provider.
  local exe = type(def.cmd) == 'table' and def.cmd[1] or nil
  if type(exe) ~= 'string' or exe == '' then
    return nil, name .. ': empty command'
  end
  if vim.fn.executable(exe) ~= 1 then
    return nil, ("%s: executable '%s' not found"):format(name, exe)
  end
  local cwd = util.abspath(open_opts.cwd or vim.fn.getcwd())
  local env = vim.tbl_extend('force', {}, def.env or {}, open_opts.env or {})

  local ide, before_spawn
  local P, perr = start_provider(def.provider)
  if P then
    local info, ierr = P.launch_info({ cwd = cwd, env = env, agent = name })
    if info then
      ide = info
      before_spawn = P.before_spawn
    else
      scoped().warn('%s: no IDE integration (%s)', name, tostring(ierr))
    end
  elseif perr then
    scoped().warn('%s: no IDE integration (%s)', name, tostring(perr))
  end

  local mcp_enabled = cfg.nvim_mcp.enabled ~= false and def.mcp ~= false
  if open_opts.mcp ~= nil then
    mcp_enabled = open_opts.mcp and true or false
  end
  local spec, err = agents.build_launch(name, {
    cwd = cwd,
    user_args = open_opts.args,
    env = open_opts.env,
    ide = ide,
    before_spawn = before_spawn,
    nvim_mcp = {
      enabled = mcp_enabled,
      server_name = cfg.nvim_mcp.server_name,
      timeout_ms = cfg.nvim_mcp.timeout_ms,
    },
    auto_approve = open_opts.auto_approve,
    on_exit = function(code)
      state.launched[name] = nil
      scoped().debug('%s exited with code %d', name, code)
      vim.schedule(reload_changed_buffers)
    end,
  })
  if spec then
    state.launched[name] = util.now_ms()
  end
  return spec, err
end

---Start every enabled provider (config.auto_start). A provider that fails (or throws) is reported
---and the others still start.
local function start_all_providers()
  for _, name in ipairs(M.PROVIDERS) do
    local ok, res, err = pcall(start_provider, name)
    if not ok then
      err = res
    end
    if err then
      scoped().warn('auto_start: %s', tostring(err))
    end
  end
end

---@return string
local function run_dir_path()
  return vim.fs.joinpath(vim.fn.stdpath('run'), 'agent.nvim', tostring(uv.os_getpid()))
end

---Configure agent.nvim. Safe to call more than once (the latest options win). Commands work
---without it: they call setup({}) the first time.
---@param opts table|nil  see agent.config.defaults
---@return table options  the merged configuration
function M.setup(opts)
  local cfg = config.setup(opts)
  log.configure({ level = cfg.log_level, file = cfg.log_file })
  terminal.setup({ launcher = launcher })
  state.setup_done = true

  state.augroup = vim.api.nvim_create_augroup('agent.nvim', { clear = true })
  vim.api.nvim_create_autocmd('VimLeavePre', {
    group = state.augroup,
    callback = function()
      M.teardown()
    end,
  })
  -- Leaving an agent's terminal (its window, or Terminal mode) shows the files it may have changed.
  vim.api.nvim_create_autocmd({ 'WinLeave', 'TermLeave' }, {
    group = state.augroup,
    callback = function(ev)
      if vim.b[ev.buf].agent_nvim_agent then
        vim.schedule(reload_changed_buffers)
      end
    end,
  })

  if cfg.selection.track == false then
    stop_selection()
  else
    for _, name in ipairs(M.PROVIDERS) do
      local P = loaded_provider(name)
      if P and P.is_running() then
        ensure_selection()
        break
      end
    end
  end
  if cfg.auto_start then
    start_all_providers()
  end
  return cfg
end

---Call setup({}) unless setup() already ran.
local function ensure_setup()
  if not state.setup_done then
    M.setup({})
  end
end

---@param name string|nil
---@return string|nil name, string|nil err
local function resolve(name)
  if name == nil or name == '' then
    name = terminal.last_focused() or config.get().default_agent
  end
  if not require('agent.agents').get(name) then
    return nil, ('unknown agent %q'):format(tostring(name))
  end
  return name, nil
end

---@class agent.OpenOpts: agent.TermOpenOpts
---@field env? table<string, string|false>  extra environment for this launch (false = unset)
---@field mcp? boolean          register the $NVIM controller for this launch (default: config)
---@field auto_approve? boolean pre-approve the controller's tools (default: agents.<name>.auto_approve)

---Open (start or show) an agent terminal.
---@param name string|nil  agent name (default: the last focused agent, else config.default_agent)
---@param opts agent.OpenOpts|nil
---@return integer|nil bufnr, string|nil err
function M.open(name, opts)
  ensure_setup()
  local n, err = resolve(name)
  if not n then
    return nil, err
  end
  return terminal.open(n, opts)
end

---Toggle an agent terminal: hide it when visible in this tab, else open and focus it.
---@param name string|nil
---@param opts agent.OpenOpts|nil
---@return integer|nil bufnr, string|nil err
function M.toggle(name, opts)
  ensure_setup()
  local n, err = resolve(name)
  if not n then
    return nil, err
  end
  return terminal.toggle(n, opts)
end

---Hide an agent's terminal windows; the agent keeps running.
---@param name string|nil
---@return boolean closed
function M.close(name)
  ensure_setup()
  local n = resolve(name)
  return n ~= nil and terminal.close(n) or false
end

---Stop an agent: end its job, wipe its terminal and delete its temp files. Providers keep running
---(agents reconnect to the same port/socket); M.teardown() stops everything.
---@param name string|nil  default: the last focused running agent
---@return boolean stopped
function M.stop(name)
  ensure_setup()
  if name == nil or name == '' then
    name = terminal.last_focused()
    if not name then
      return false
    end
  end
  state.launched[name] = nil
  return terminal.stop(name)
end

---Stop every agent, every provider (their lock and discovery files are removed), selection
---tracking, and delete this Neovim's agent.nvim temp directory. Runs on VimLeavePre.
function M.teardown()
  pcall(terminal.stop_all)
  state.launched = {}
  for _, name in ipairs(M.PROVIDERS) do
    local P = loaded_provider(name)
    if P and P.stop then
      local ok, err = pcall(P.stop)
      if not ok then
        scoped().error('stopping provider %s failed: %s', name, tostring(err))
      end
    end
  end
  stop_selection()
  local dir = run_dir_path()
  util.remove_dir(dir)
  pcall(uv.fs_rmdir, vim.fs.dirname(dir))
end

-- ---------------------------------------------------------------------------
-- At-mentions
-- ---------------------------------------------------------------------------

---Gemini @-command path escaping (POSIX: backslash before special characters).
---@param p string
---@return string
local function gemini_escape(p)
  if util.is_windows then
    if p:find('[%s&()%[%]{}^=;!\'+,`~%%$@#]') then
      return '"' .. p .. '"'
    end
    return p
  end
  return (p:gsub('([ \t()%[%]{};|*?$`\'"#&<>!~\\])', '\\%1'))
end

---The reference an agent understands when typed into its prompt, e.g. `@src/a.lua#L3-5`.
---Paths inside `cwd` are relative to it, others absolute. Lines are 1-based and inclusive; nil
---means the whole file.
---  claude:   @path  @path#L3  @path#L3-5
---  opencode: @path  @path#3   @path#3-5
---  copilot:  @path  @path:3   @path:3-5
---  gemini:   @path  @path (lines 3-5)   (Gemini's @ includes whole files; spaces are escaped)
---@param kind string  agent kind ('claude'|'opencode'|'copilot'|'gemini')
---@param path string
---@param l1 integer|nil
---@param l2 integer|nil
---@param cwd string|nil  the agent's working directory
---@return string
function M.reference(kind, path, l1, l2, cwd)
  local abs = util.abspath(path)
  local rel = abs
  if cwd and cwd ~= '' then
    local candidates = { { util.abspath(cwd), abs }, { util.realpath(cwd), util.realpath(abs) } }
    for _, c in ipairs(candidates) do
      local base, p = c[1], c[2]
      if p ~= base and util.path_contains(base, p) then
        rel = p:sub(#base + (base:sub(-1) == '/' and 1 or 2))
        break
      end
    end
  end
  local range = ''
  if l1 then
    l2 = l2 or l1
    if kind == 'gemini' then
      range = l2 > l1 and (' (lines %d-%d)'):format(l1, l2) or (' (line %d)'):format(l1)
    else
      local sep = ({ claude = '#L', opencode = '#', copilot = ':' })[kind] or '#L'
      range = sep .. l1 .. (l2 > l1 and ('-' .. l2) or '')
    end
  end
  if kind == 'gemini' then
    return '@' .. gemini_escape(rel) .. range
  end
  return '@' .. rel .. range
end

---Mention through the provider: to the client in the agent's terminal (by its job pid), or with no
---terminal running, to the connected clients of the agent's kind.
---@param def agent.AgentDef
---@param name string
---@return boolean sent
local function provider_mention(def, name, path, l1, l2)
  local P = loaded_provider(def.provider)
  if not P or not P.is_running() or not P.at_mention then
    return false
  end
  local info = terminal.info(name)
  local pid = info and info.running and info.pid or nil
  local ok, sent = pcall(P.at_mention, path, l1, l2, { kind = def.kind, pid = pid })
  if not ok then
    scoped().error('%s.at_mention failed: %s', def.provider, tostring(sent))
    return false
  end
  return sent == true
end

---Does the agent's provider have a client of the agent's kind (connected, maybe not ready yet)?
---@param def agent.AgentDef
---@return boolean
local function has_client(def)
  local P = loaded_provider(def.provider)
  if not MENTION_PROVIDERS[def.provider] or not P or not P.is_running() then
    return false
  end
  local ok, st = pcall(P.status)
  if not ok or type(st) ~= 'table' or (st.clients or 0) == 0 then
    return false
  end
  for _, s in ipairs(type(st.sessions) == 'table' and st.sessions or {}) do
    -- Claude sessions carry their kind (claude or opencode); Copilot's are all copilot.
    if s.kind == nil or s.kind == def.kind then
      return true
    end
  end
  return false
end

---Mention to an agent that runs outside agent.nvim's terminals (started by hand, e.g. with
---terminal.layout = 'none') and is connected to the IDE server. Not while another agent of the
---same kind runs in an agent.nvim terminal: its client could not be told apart.
---@param def agent.AgentDef
---@param name string  the target agent, not running in a terminal
---@return boolean sent
local function external_mention(def, name, path, l1, l2)
  if not has_client(def) then
    return false
  end
  local agents = require('agent.agents')
  for _, other in ipairs(terminal.running()) do
    local d = agents.get(other)
    if other ~= name and d and d.provider == def.provider and d.kind == def.kind then
      return false
    end
  end
  return provider_mention(def, name, path, l1, l2)
end

---@return boolean ok, string|nil err
local function type_reference(name, def, path, l1, l2)
  local info = terminal.info(name)
  local text = M.reference(def.kind, path, l1, l2, info and info.cwd) .. ' '
  return terminal.send(name, text)
end

local function retry_mention(name, def, path, l1, l2, deadline)
  vim.defer_fn(function()
    if not terminal.is_running(name) then
      return
    end
    if provider_mention(def, name, path, l1, l2) then
      return
    end
    if util.now_ms() < deadline then
      return retry_mention(name, def, path, l1, l2, deadline)
    end
    local ok, err = type_reference(name, def, path, l1, l2)
    if not ok then
      log.notify(tostring(err), vim.log.levels.WARN)
    end
  end, M.MENTION_POLL_MS)
end

---@class agent.MentionOpts
---@field name? string    target agent (default: the most recently focused agent; else
---                       config.default_agent, which is started)
---@field focus? boolean  focus the agent's terminal afterwards (default false)

---At-mention a file or a line range in an agent's prompt. The mention goes to the provider of the
---target agent (targeted by its terminal pid). When the provider cannot deliver it (not connected,
---or gemini, which has no mention notification) the reference is typed into the agent's terminal
---in the agent's own syntax instead (see M.reference).
---When the agent is not running in a terminal but an agent of its kind that the user started by
---hand is connected to the IDE server, the mention goes there. Otherwise the agent is started
---(except with terminal.layout = 'none', where that is an error).
---@param path string
---@param l1 integer|nil  1-based first line; nil = the whole file
---@param l2 integer|nil  1-based last line (inclusive)
---@param opts agent.MentionOpts|nil
---@return boolean ok, string how_or_err  'sent' | 'typed' | 'pending' (retried after a launch), or the error
function M.mention(path, l1, l2, opts)
  ensure_setup()
  opts = opts or {}
  if type(path) ~= 'string' or path == '' then
    return false, 'no file to mention'
  end
  path = util.abspath(path)
  if l1 then
    l2 = l2 or l1
    if l2 < l1 then
      l1, l2 = l2, l1
    end
    l1 = math.max(1, math.floor(l1))
    l2 = math.max(l1, math.floor(l2))
  else
    l2 = nil
  end
  local name = opts.name
  if name == nil or name == '' then
    name = terminal.last_focused() or config.get().default_agent
  end
  local agents = require('agent.agents')
  local def = agents.get(name)
  if not def then
    return false, ('unknown agent %q'):format(tostring(name))
  end
  if not terminal.is_running(name) then
    if external_mention(def, name, path, l1, l2) then
      return true, 'sent'
    end
    if config.get().terminal.layout == 'none' then
      if not MENTION_PROVIDERS[def.provider] then
        return false, ('%s is not running in Neovim and cannot take mentions (terminal.layout is "none")')
          :format(name)
      end
      return false, ('no %s is connected to Neovim (terminal.layout is "none": start it in your own terminal)')
        :format(name)
    end
    local buf, err = terminal.open(name, { focus = opts.focus == true, silent = true })
    if not buf then
      return false, err or (name .. ' is not running')
    end
  end

  local how
  if provider_mention(def, name, path, l1, l2) then
    how = 'sent'
  else
    local launched = state.launched[name]
    local since = launched and (util.now_ms() - launched) or math.huge
    if MENTION_PROVIDERS[def.provider] and provider_enabled(def.provider) and since < M.MENTION_WAIT_MS then
      retry_mention(name, def, path, l1, l2, launched + M.MENTION_WAIT_MS)
      how = 'pending'
    elseif since < M.STARTUP_GRACE_MS then
      vim.defer_fn(function()
        if terminal.is_running(name) then
          local ok, err = type_reference(name, def, path, l1, l2)
          if not ok then
            log.notify(tostring(err), vim.log.levels.WARN)
          end
        end
      end, math.max(0, math.floor(M.STARTUP_GRACE_MS - since)))
      how = 'pending'
    else
      local ok, err = type_reference(name, def, path, l1, l2)
      if not ok then
        return false, err
      end
      how = 'typed'
    end
  end
  if opts.focus then
    terminal.open(name, { focus = true })
  end
  return true, how
end

---The last visual selection of a file buffer: its '< and '> marks (what `gv` reselects).
---@param buf integer|nil
---@return string|nil path, integer|nil l1, integer|nil l2
local function last_visual_marks(buf)
  if not buf or not require('agent.editor.context').is_file_buffer(buf) then
    return nil
  end
  local ok1, a = pcall(vim.api.nvim_buf_get_mark, buf, '<')
  local ok2, b = pcall(vim.api.nvim_buf_get_mark, buf, '>')
  if not (ok1 and ok2) or a[1] == 0 or b[1] == 0 then
    return nil
  end
  return vim.api.nvim_buf_get_name(buf), math.min(a[1], b[1]), math.max(a[1], b[1])
end

---At-mention the selection. With `range`, lines line1..line2 of `range.path` (default: the
---current buffer, which must be a file); without it, the visual selection: the live one in visual
---mode, else the one just left, else (from a buffer that is not a file) the latest selection made
---in a file, else the last visual selection ('<,'>) of the current file or, from a buffer that is
---not a file, of the last focused file.
---@param range { path?: string, line1: integer, line2?: integer }|nil
---@param opts agent.MentionOpts|nil
---@return boolean ok, string how_or_err
function M.send_selection(range, opts)
  ensure_setup()
  local context = require('agent.editor.context')
  local buf = vim.api.nvim_get_current_buf()
  local path, l1, l2
  if range and range.line1 then
    path = range.path
    if not path then
      if not context.is_file_buffer(buf) then
        return false, 'no selection in a file buffer'
      end
      path = vim.api.nvim_buf_get_name(buf)
    end
    l1, l2 = range.line1, range.line2 or range.line1
  else
    local selection = require('agent.editor.selection')
    path, l1, l2 = selection.visual_range()
    if not path and not vim.api.nvim_get_mode().mode:match('^[vVsS\22\19]') then
      path, l1, l2 = last_visual_marks(context.is_file_buffer(buf) and buf or selection.last_focused_buf())
    end
  end
  if not path then
    return false, 'no selection in a file buffer'
  end
  return M.mention(path, l1, l2, opts)
end

---At-mention a file (or a directory), optionally a line range of it.
---@param path string|nil  default: the current buffer's file
---@param l1 integer|nil
---@param l2 integer|nil
---@param opts agent.MentionOpts|nil
---@return boolean ok, string how_or_err
function M.add_file(path, l1, l2, opts)
  ensure_setup()
  if path == nil or path == '' then
    local buf = vim.api.nvim_get_current_buf()
    if not require('agent.editor.context').is_file_buffer(buf) then
      return false, 'the current buffer is not a file'
    end
    path = vim.api.nvim_buf_get_name(buf)
  else
    path = vim.fn.fnamemodify(vim.fn.expand(path), ':p')
  end
  if not uv.fs_stat(path) then
    return false, 'no such file: ' .. path
  end
  return M.mention(path, l1, l2, opts)
end

-- ---------------------------------------------------------------------------
-- Status, MCP config, diffs
-- ---------------------------------------------------------------------------

---@class agent.Status
---@field setup boolean
---@field servername string
---@field last_focused string|nil
---@field agents table<string, { kind: string, provider: string, running: boolean, visible: boolean, pid: integer|nil, session_id: string|nil, cwd: string|nil, exit_code: integer|nil }>
---@field providers table<string, table>  provider status() plus `enabled`

---State of every configured agent and provider.
---@return agent.Status
function M.status()
  local agents = require('agent.agents')
  local out = {
    setup = state.setup_done,
    servername = vim.v.servername,
    last_focused = terminal.last_focused(),
    agents = {},
    providers = {},
  }
  for _, name in ipairs(agents.list()) do
    local def = agents.get(name)
    local info = terminal.info(name)
    out.agents[name] = {
      kind = def.kind,
      provider = def.provider,
      running = info ~= nil and info.running or false,
      visible = terminal.is_visible(name),
      pid = info and info.pid,
      session_id = info and info.session_id,
      cwd = info and info.cwd,
      exit_code = info and info.exit_code,
    }
  end
  for _, name in ipairs(M.PROVIDERS) do
    local P = loaded_provider(name)
    local st = { running = false, clients = 0 }
    if P then
      local ok, s = pcall(P.status)
      if ok and type(s) == 'table' then
        st = s
      end
    end
    st.enabled = provider_enabled(name)
    out.providers[name] = st
  end
  return out
end

---The MCP server entry for registering the $NVIM controller by hand (agents started inside a
---Neovim terminal find this Neovim through $NVIM).
---@param name string|nil  agent (default: config.default_agent)
---@return table|nil config, string|nil err
function M.mcp_config(name)
  ensure_setup()
  return require('agent.agents').manual_mcp_config(name or config.get().default_agent)
end

---Accept the current diff (the one in the current buffer, tab or window, else the only one).
---@return boolean ok, string|nil err
function M.diff_accept()
  return require('agent.editor.diff').accept_current()
end

---Reject the current diff.
---@return boolean ok, string|nil err
function M.diff_reject()
  return require('agent.editor.diff').reject_current()
end

-- ---------------------------------------------------------------------------
-- Commands (declared in plugin/agent.lua)
-- ---------------------------------------------------------------------------

---Pretty JSON with sorted keys (vim.json.encode has no indent option on 0.11).
---@param v any
---@param indent string|nil
---@return string
local function pretty_json(v, indent)
  indent = indent or ''
  if type(v) ~= 'table' then
    return vim.json.encode(v)
  end
  local inner = indent .. '  '
  local parts = {}
  local is_obj = getmetatable(v) == getmetatable(vim.empty_dict()) or (next(v) ~= nil and not vim.islist(v))
  if is_obj then
    local keys = vim.tbl_keys(v)
    table.sort(keys, function(a, b)
      return tostring(a) < tostring(b)
    end)
    for _, k in ipairs(keys) do
      parts[#parts + 1] = inner .. vim.json.encode(tostring(k)) .. ': ' .. pretty_json(v[k], inner)
    end
    if #parts == 0 then
      return '{}'
    end
    return '{\n' .. table.concat(parts, ',\n') .. '\n' .. indent .. '}'
  end
  for _, x in ipairs(v) do
    parts[#parts + 1] = inner .. pretty_json(x, inner)
  end
  if #parts == 0 then
    return '[]'
  end
  return '[\n' .. table.concat(parts, ',\n') .. '\n' .. indent .. ']'
end
M._pretty_json = pretty_json

local MCP_HINTS = {
  claude = 'Claude Code: merge this into .mcp.json, or run the command below (claude mcp add-json takes only '
    .. 'the inner server object; add --scope user to register it for every project):',
  copilot = 'Copilot CLI: merge this into $COPILOT_HOME/mcp-config.json (default ~/.copilot/mcp-config.json).',
  gemini = 'Gemini CLI: merge this into ~/.gemini/settings.json, or run :AgentGeminiSetup.',
  opencode = 'OpenCode: merge this into opencode.json.',
}

---@param msg string
---@param level integer|nil
local function notify(msg, level)
  vim.notify('agent.nvim: ' .. msg, level or vim.log.levels.INFO)
end

---@param lines string[]
local function echo(lines)
  local chunks = {}
  for i, l in ipairs(lines) do
    chunks[#chunks + 1] = { l .. (i < #lines and '\n' or '') }
  end
  vim.api.nvim_echo(chunks, true, {})
end

---@return string[]
local function status_lines()
  local s = M.status()
  local lines = { 'agent.nvim  (server ' .. (s.servername ~= '' and s.servername or 'none') .. ')', 'Agents:' }
  local names = vim.tbl_keys(s.agents)
  table.sort(names)
  for _, name in ipairs(names) do
    local a = s.agents[name]
    local line = ('  %-10s %s'):format(name, a.running and ('running (pid ' .. tostring(a.pid) .. ')') or 'stopped')
    if a.running and a.visible then
      line = line .. ', visible'
    end
    if name == s.last_focused then
      line = line .. ', last focused'
    end
    lines[#lines + 1] = line .. '  [provider ' .. a.provider .. ']'
  end
  lines[#lines + 1] = 'Providers:'
  for _, name in ipairs(M.PROVIDERS) do
    local p = s.providers[name]
    local line = ('  %-10s '):format(name)
    if not p.enabled then
      line = line .. 'disabled'
    elseif p.running then
      line = line .. ('running, %d client(s), %s'):format(p.clients or 0, tostring(p.address))
      if p.lock then
        line = line .. ', lock ' .. p.lock
      end
    else
      line = line .. 'stopped'
    end
    lines[#lines + 1] = line
  end
  return lines
end

local commands = {}

---@param o table
---@return string|nil
local function arg1(o)
  local a = o.fargs and o.fargs[1]
  return a ~= '' and a or nil
end

---Notify `err` when `ok` is false.
---@param ok any
---@param err any
---@param prefix string|nil
local function report(ok, err, prefix)
  if not ok and err then
    notify((prefix and (prefix .. ': ') or '') .. tostring(err), vim.log.levels.ERROR)
  end
end

function commands.Agent(o)
  local buf, err = M.toggle(arg1(o), { silent = true })
  report(buf ~= nil, err)
end

function commands.AgentOpen(o)
  local buf, err = M.open(arg1(o), { silent = true })
  report(buf ~= nil, err)
end

function commands.AgentClose(o)
  local n, err = resolve(arg1(o))
  if not n then
    return report(false, err)
  end
  M.close(n)
end

function commands.AgentStop(o)
  if o.bang then
    M.teardown()
    return notify('stopped all agents and providers')
  end
  local name = arg1(o)
  if name and not require('agent.agents').get(name) then
    return report(false, ('unknown agent %q'):format(name))
  end
  if not M.stop(name) then
    notify(name and (name .. ' is not running') or 'no agent is running', vim.log.levels.WARN)
  end
end

function commands.AgentSend(o)
  local range
  local visual = vim.fn.mode():match('^[vVsS\22\19]') ~= nil
  if o.range and o.range > 0 and not visual then
    range = { line1 = o.line1, line2 = o.line2 }
  end
  local ok, how = M.send_selection(range, { name = arg1(o) })
  if visual then
    vim.api.nvim_feedkeys(vim.keycode('<Esc>'), 'n', false)
  end
  report(ok, how)
end

function commands.AgentAdd(o)
  local file = o.fargs[1]
  local l1 = o.fargs[2] and tonumber(o.fargs[2])
  local l2 = o.fargs[3] and tonumber(o.fargs[3])
  if (o.fargs[2] and not l1) or (o.fargs[3] and not l2) then
    return report(false, 'usage: :AgentAdd [file] [start_line] [end_line]')
  end
  local ok, how = M.add_file(file, l1, l2)
  report(ok, how)
end

function commands.AgentDiffAccept()
  report(M.diff_accept())
end

function commands.AgentDiffReject()
  report(M.diff_reject())
end

function commands.AgentStatus()
  echo(status_lines())
end

function commands.AgentMcpConfig(o)
  local name = arg1(o) or config.get().default_agent
  local cfg, err = M.mcp_config(name)
  if not cfg then
    return report(false, err)
  end
  local kind = require('agent.agents').get(name).kind
  local lines = vim.split(pretty_json(cfg), '\n')
  table.insert(lines, 1, ('MCP config for %s (the agent must run inside Neovim, where $NVIM is set):'):format(name))
  lines[#lines + 1] = MCP_HINTS[kind] or ''
  if kind == 'claude' then
    local server = config.get().nvim_mcp.server_name
    lines[#lines + 1] = ('claude mcp add-json %s %s'):format(server, vim.fn.shellescape(
      vim.json.encode(cfg.mcpServers[server])))
  end
  echo(lines)
end

function commands.AgentGeminiSetup()
  require('agent.gemini_setup').run()
end

---Run a user command (plugin/agent.lua). Calls setup({}) first when needed.
---@param name string
---@param o table  nvim_create_user_command callback argument
function M._command(name, o)
  ensure_setup()
  local fn = commands[name]
  if not fn then
    return report(false, 'unknown command ' .. tostring(name))
  end
  local ok, err = pcall(fn, o or { fargs = {} })
  if not ok then
    report(false, err, name)
  end
end

---Complete agent names.
---@param lead string|nil
---@return string[]
function M._complete_agents(lead)
  lead = lead or ''
  local out = {}
  for _, name in ipairs(require('agent.agents').list()) do
    if name:sub(1, #lead) == lead then
      out[#out + 1] = name
    end
  end
  return out
end

---Internal state, for tests.
M._state = state

return M
