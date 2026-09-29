---@mod agent agent.nvim: a coding-agent CLI in a Neovim terminal, with IDE integration
---
--- setup() wires the modules together:
---  * agent.terminal runs one agent at a time. Its launcher (below) starts the agent's IDE provider,
---    asks it for launch info and builds the launch spec with agent.agents.build_launch (which also
---    registers the $NVIM controller MCP server). Starting another agent asks before it replaces
---    the running one. When the agent stops (M.stop(), a replace, or its process exits), its
---    provider stops too, unless config.auto_start keeps every provider running for agents started
---    outside Neovim.
---  * :AgentSend (M.send()) at-mentions the current buffer, or lines of it, in the agent's prompt
---    (through its provider, or typed), then focuses the agent's terminal, starting the agent if
---    needed.
---  * agent.editor.selection runs while a provider runs (the providers' tools read it), and with
---    config.selection.track (off by default) its events are forwarded to every running provider.
---  * VimLeavePre stops the agent (SIGTERM to its whole process tree, see agent.terminal.stop()) and
---    every provider, and removes temp files.
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

local state = {
  setup_done = false,
  ---@type integer|nil
  augroup = nil,
  ---@type fun()|nil  selection subscription
  unsubscribe = nil,
  ---@type agent.Mention[]  mentions waiting for delivery, oldest first (M.send(), drain())
  mentions = {},
  ---@type boolean  a poll() of the mentions is scheduled
  polling = false,
  ---@type integer|nil  the pid of the agent told that its mentions wait for its IDE connection
  waiting_pid = nil,
}

local function scoped()
  return log.scope('init')
end

---@param msg string
---@param level integer|nil
local function notify(msg, level)
  vim.notify('agent.nvim: ' .. msg, level or vim.log.levels.INFO)
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

---Automatic context following (config.selection.track, off by default): selection events are
---pushed to the providers. Selection tracking itself runs either way, for the tools an agent calls.
---@return boolean
local function tracking()
  return config.get().selection.track == true
end

---Forward one selection event to every running provider (only with config.selection.track).
---@param s agent.Selection|nil
local function forward_selection(s)
  if not s or not tracking() then
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

---Start selection tracking (once): the providers' tools read it (Claude's getCurrentSelection,
---Copilot's get_selection), and with config.selection.track its events are forwarded.
local function ensure_selection()
  if state.unsubscribe then
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
  if not was_running and tracking() then
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

---Why the agent's CLI cannot be started (empty command, executable not found), or nil.
---@param def agent.AgentDef
---@return string|nil err
local function cli_error(def)
  local exe = type(def.cmd) == 'table' and def.cmd[1] or nil
  if type(exe) ~= 'string' or exe == '' then
    return def.name .. ': empty command'
  end
  if vim.fn.executable(exe) ~= 1 then
    return ("%s: executable '%s' not found"):format(def.name, exe)
  end
  return nil
end

---Stop the provider of agent `name` (its IDE server, lock and discovery files; pending diffs are
---closed) when the agent has stopped. Kept when config.auto_start is on (agents started outside
---Neovim may use it), and when the agent now in the terminal uses it.
---@param name string
local function stop_provider_of(name)
  if config.get().auto_start then
    return
  end
  local agents = require('agent.agents')
  local def = agents.get(name)
  local P = def and loaded_provider(def.provider)
  if not P or not P.is_running() then
    return
  end
  local cur = terminal.is_running() and agents.get(terminal.name())
  if cur and cur.provider == def.provider then
    return
  end
  local ok, err = pcall(P.stop)
  if not ok then
    scoped().error('stopping provider %s failed: %s', def.provider, tostring(err))
  end
end

---Stop the agent in the terminal (running, or finished with its terminal left open) and its provider.
---@return string|nil name  the agent that was stopped
local function stop_agent()
  local name = terminal.name()
  if not name then
    return nil
  end
  terminal.stop()
  stop_provider_of(name)
  return name
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
  local cerr = cli_error(def)
  if cerr then
    return nil, cerr
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
      scoped().debug('%s exited with code %d', name, code)
      -- Also after a stop or a replace (then the provider is already stopped, or in use again).
      stop_provider_of(name)
      vim.schedule(reload_changed_buffers)
    end,
  })
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
  -- Leaving the agent terminal (its window, or Terminal mode) shows the files it may have changed.
  -- BufLeave: with the 'current' layout, the window stays when the terminal is hidden in it.
  vim.api.nvim_create_autocmd({ 'WinLeave', 'TermLeave', 'BufLeave' }, {
    group = state.augroup,
    callback = function(ev)
      if vim.b[ev.buf].agent_nvim_agent then
        vim.schedule(reload_changed_buffers)
      end
    end,
  })

  for _, name in ipairs(M.PROVIDERS) do
    local P = loaded_provider(name)
    if P and P.is_running() then
      ensure_selection()
      break
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

---@param name string|nil  default: the running agent, else config.default_agent
---@return string|nil name, string|nil err
local function resolve(name)
  if name == nil or name == '' then
    name = terminal.is_running() and terminal.name() or config.get().default_agent
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
---@field confirm? boolean      ask before replacing another running agent (default true); false
---                             replaces it without asking

---Before `name` starts: when another agent is in the terminal, stop it (and its provider). A running
---one is replaced only when the user confirms (unless opts.confirm == false) and when `name`'s CLI
---can start; a finished one is just wiped.
---@param name string
---@param opts agent.OpenOpts
---@return boolean proceed, string|nil err  proceed = false, err = nil: the user declined
local function replace(name, opts)
  local cur = terminal.name()
  if not cur or cur == name then
    return true, nil
  end
  if terminal.is_running() then
    local def = require('agent.agents').get(name)
    local cerr = not opts.launch and def and cli_error(def)
    if cerr then
      return false, cerr
    end
    if opts.confirm ~= false
      and vim.fn.confirm(('Stop %s and start %s?'):format(cur, name), '&Yes\n&No', 2) ~= 1 then
      return false, nil
    end
  end
  stop_agent()
  return true, nil
end

---Resolve `name`, make room for it (replace()), then run fn(name, opts): terminal.open or terminal.toggle.
---@param fn fun(name: string, opts: agent.OpenOpts): integer|nil, string|nil
---@param name string|nil
---@param opts agent.OpenOpts|nil
---@return integer|nil bufnr, string|nil err
local function with_agent(fn, name, opts)
  ensure_setup()
  opts = opts or {}
  local n, err = resolve(name)
  if not n then
    return nil, err
  end
  local ok, rerr = replace(n, opts)
  if not ok then
    if rerr and not opts.silent then
      notify(rerr, vim.log.levels.ERROR)
    end
    return nil, rerr
  end
  return fn(n, opts)
end

---Open (start or show) the agent terminal. Starting an agent while another one runs asks
---(vim.fn.confirm) whether to stop that one; declined, nothing changes and nil, nil is returned.
---@param name string|nil  agent name (default: the running agent, else config.default_agent)
---@param opts agent.OpenOpts|nil
---@return integer|nil bufnr, string|nil err
function M.open(name, opts)
  return with_agent(terminal.open, name, opts)
end

---Toggle the agent terminal: hide it when `name` runs in it and it is visible in this tab page (its
---windows in other tab pages, such as a diff's, stay), else open and focus it (replacing another
---running agent like M.open()). With the 'current' layout it is shown in the current window, and
---hiding it there brings back the buffer that window showed before.
---@param name string|nil  agent name (default: the running agent, else config.default_agent)
---@param opts agent.OpenOpts|nil
---@return integer|nil bufnr, string|nil err
function M.toggle(name, opts)
  return with_agent(terminal.toggle, name, opts)
end

---Hide the agent terminal; the agent keeps running. Where it is shown in the current tab page, only
---there: in a diff's tab page (config.diff.show_terminal) the diff's view of the agent closes and
---the terminal's own window stays. Otherwise in every tab page. A window the 'current' layout took
---over is not closed: it shows its previous buffer again. See agent.terminal.close().
---@return boolean closed
function M.close()
  ensure_setup()
  return terminal.close()
end

---Stop the agent: end its job, wipe its terminal, delete its temp files, and stop its provider
---(IDE server, lock and discovery files; pending diffs are closed) unless config.auto_start is on.
---The Claude provider keeps its port and token for the next start.
---@return boolean stopped  false when there was no agent
function M.stop()
  ensure_setup()
  return stop_agent() ~= nil
end

---Stop the agent, every provider (their lock and discovery files are removed, even with
---config.auto_start), selection tracking, and delete this Neovim's agent.nvim temp directory.
---Runs on VimLeavePre.
function M.teardown()
  state.mentions = {}
  pcall(terminal.stop)
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
-- :AgentSend (at-mentions)
-- ---------------------------------------------------------------------------

---Providers with a mention notification: Claude and OpenCode (at_mentioned), Copilot
---(add_file_reference). Gemini has none: the reference is typed into its prompt.
local MENTION_PROVIDERS = { claude = true, copilot = true }

---A mention waits for the agent's IDE connection (polling every MENTION_POLL_MS). Claude, OpenCode
---and Copilot, while their provider runs: until the client connects, however long that takes
---(nothing is typed before, which could go into a dialog such as Claude's folder trust question);
---a notice says so once the agent was started this long ago (or its client has been connecting
---this long). Gemini: at most this long, then the reference is typed.
M.MENTION_WAIT_MS = 15000
M.MENTION_POLL_MS = 250
---A reference is typed only into a terminal at least this old, so that the agent's TUI takes it.
M.STARTUP_GRACE_MS = 3000

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

---The reference an agent understands when typed into its prompt. Paths inside `cwd` are relative
---to it, others absolute. Lines are 1-based and inclusive; nil means the whole file.
---  claude:   @path  @path#L3  @path#L3-5
---  opencode: @path  @path#3   @path#3-5
---  copilot:  @path  @path:3   @path:3-5
---  gemini:   @path  @path (lines 3-5)   (Gemini's @ includes whole files; paths are escaped)
---A buffer that is not a file is named by its nvim://buffer/<n>/<label> id, for every agent:
---`nvim://buffer/3/sh lines 1-2`. The model reads it with the controller's read_buffer. (Claude and
---Copilot make a mentioned path relative to their cwd, which turns the id into `@nvim:/buffer/3/sh`
---that nothing can read.)
---@param kind string  agent kind ('claude'|'opencode'|'copilot'|'gemini')
---@param path string  a file path, or an nvim://buffer/ id
---@param l1 integer|nil
---@param l2 integer|nil
---@param cwd string|nil  the agent's working directory
---@return string
local function reference(kind, path, l1, l2, cwd)
  l2 = l1 and (l2 or l1) or nil
  if require('agent.editor.context').is_buffer_uri(path) then
    if not l1 then
      return path
    end
    return path .. (l2 > l1 and (' lines %d-%d'):format(l1, l2) or (' line %d'):format(l1))
  end
  local abs = util.abspath(path)
  local rel = abs
  if cwd and cwd ~= '' then
    for _, c in ipairs({ { util.abspath(cwd), abs }, { util.realpath(cwd), util.realpath(abs) } }) do
      local base, p = c[1], c[2]
      if p ~= base and util.path_contains(base, p) then
        rel = p:sub(#base + (base:sub(-1) == '/' and 1 or 2))
        break
      end
    end
  end
  local range = ''
  if l1 then
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
M._reference = reference

---@class agent.Mention
---@field name string     the agent
---@field def agent.AgentDef
---@field path string     a file path, or the nvim://buffer/<n>/<label> id of another buffer
---@field l1 integer|nil  1-based first line; nil: the whole file or buffer
---@field l2 integer|nil  1-based last line (inclusive)
---@field pid integer|nil its terminal job's pid (nil: no agent.nvim terminal, terminal.layout = 'none')
---@field started number|nil  util.now_ms() when its terminal was started
---@field deadline number|nil util.now_ms() until which it waits for the IDE connection quietly
---  (Claude, OpenCode, Copilot: then with a notice, see M.MENTION_WAIT_MS), or at all (Gemini)
---@field sync boolean|nil   M.send() is delivering it now (see drain())
---@field how string|nil     'sent', 'typed', 'gone' or 'error' once out of the queue
---@field err string|nil     the error, for 'error'

---Deliver the mention through the agent's provider (to the client in its terminal, matched by
---pid). Never an nvim://buffer/ id (see reference()).
---@param m agent.Mention
---@return boolean sent
local function provider_mention(m)
  if not MENTION_PROVIDERS[m.def.provider] or require('agent.editor.context').is_buffer_uri(m.path) then
    return false
  end
  local P = loaded_provider(m.def.provider)
  if not P or not P.is_running() or not P.at_mention then
    return false
  end
  local ok, sent = pcall(P.at_mention, m.path, m.l1, m.l2, { kind = m.def.kind, pid = m.pid })
  if not ok then
    scoped().error('%s.at_mention failed: %s', m.def.provider, tostring(sent))
    return false
  end
  return sent == true
end

---The state of the agent's IDE client: 'ready', 'connecting', 'ambiguous' or nil (see the
---providers' client_state()); nil also when its provider is not running.
---@param m agent.Mention
---@return 'ready'|'connecting'|'ambiguous'|nil
local function client_state(m)
  local P = loaded_provider(m.def.provider)
  if not P or not P.is_running() or not P.client_state then
    return nil
  end
  local ok, s = pcall(P.client_state, { kind = m.def.kind, pid = m.pid })
  return ok and s or nil
end

---Tell the user, once for the agent in the terminal (until one of its mentions is delivered),
---that its mentions wait for its IDE connection.
---@param m agent.Mention
local function notify_waiting(m)
  if state.waiting_pid == m.pid then
    return
  end
  state.waiting_pid = m.pid
  notify(('%s has not connected to Neovim yet: the mention will be inserted when it connects'):format(m.name))
end

---One delivery attempt: through the provider; else typed into the prompt once the IDE client is
---ready and the terminal is old enough. Claude, OpenCode and Copilot are never typed into while
---their provider runs and the client is not ready, unless which client is the agent's cannot be
---told (two OpenCodes); Gemini is once the wait is over.
---@param m agent.Mention
---@return 'sent'|'typed'|'wait'|'gone'|'error' how, string|nil err
local function attempt(m)
  local info = terminal.info()
  if not info or not info.running or info.pid ~= m.pid then
    return 'gone', nil
  end
  if provider_mention(m) then
    state.waiting_pid = nil
    return 'sent', nil
  end
  local now = util.now_ms()
  local P = loaded_provider(m.def.provider)
  -- (A provider that is not running, disabled say, gets no connection to wait for.)
  local cs = P and P.is_running() and client_state(m) or nil
  if P and P.is_running() and cs ~= 'ready' then
    if MENTION_PROVIDERS[m.def.provider] and cs ~= 'ambiguous' then
      if now >= m.deadline then
        notify_waiting(m)
      end
      return 'wait', nil
    elseif now < m.deadline then
      return 'wait', nil
    end
  end
  if now - m.started < M.STARTUP_GRACE_MS then
    return 'wait', nil
  end
  local ok, err = terminal.send(reference(m.def.kind, m.path, m.l1, m.l2, info.cwd) .. ' ')
  if not ok then
    return 'error', err
  end
  state.waiting_pid = nil
  return 'typed', nil
end

---Deliver the queued mentions (state.mentions) in the order they were sent, until one has to wait.
---Each delivered or dropped one gets `how` (and `err`): an error is shown, except for the mention
---M.send() is delivering now (`m.sync`), which returns it.
local function drain()
  local q = state.mentions
  while #q > 0 do
    local m = q[1]
    local how, err = attempt(m)
    if how == 'wait' then
      return
    end
    table.remove(q, 1)
    m.how, m.err = how, err
    if how == 'error' and not m.sync then
      notify(tostring(err), vim.log.levels.WARN)
    elseif how == 'gone' then
      scoped().debug('mention of %s dropped: %s is no longer running', m.path, m.name)
    end
  end
end

---Poll the queued mentions every MENTION_POLL_MS while there are any.
local function poll()
  if state.polling or #state.mentions == 0 then
    return
  end
  state.polling = true
  vim.defer_fn(function()
    state.polling = false
    drain()
    poll()
  end, M.MENTION_POLL_MS)
end

---What :AgentSend sends from the current window: its buffer (a file by its path, another buffer
---by its nvim://buffer/<n>/<label> id), with the lines of the live Visual selection, else of
---`range`, else none (the whole buffer). Not the agent's terminal, a diff buffer, a floating
---window, or a buffer agent.nvim ignores (b:agent_ignore).
---@param range { line1: integer, line2?: integer }|nil
---@return { path: string, l1: integer|nil, l2: integer|nil }|nil target, string|nil err
local function send_target(range)
  local api = vim.api
  local win = api.nvim_get_current_win()
  local buf = api.nvim_win_get_buf(win)
  if vim.b[buf].agent_nvim_agent or buf == terminal.bufnr() then
    return nil, 'nothing to send from the agent terminal: run :AgentSend in a file or another buffer'
  end
  local bufname = api.nvim_buf_get_name(buf)
  if vim.b[buf].agent_diff_id ~= nil or vim.startswith(bufname, 'agent-diff://') then
    return nil, 'nothing to send from a diff buffer: run :AgentSend in the file'
  end
  if api.nvim_win_get_config(win).relative ~= '' then
    return nil, 'nothing to send from a floating window'
  end
  local selection = require('agent.editor.selection')
  local kind = selection.kind(buf, win)
  if not kind then
    return nil, 'nothing to send: agent.nvim ignores this buffer'
  end
  local path = kind == 'file' and bufname or require('agent.editor.context').buffer_uri(buf)
  local l1, l2
  if api.nvim_get_mode().mode:match('^[vVsS\22\19]') then
    l1, l2 = vim.fn.line('v'), vim.fn.line('.')
  elseif range and range.line1 then
    l1, l2 = range.line1, range.line2 or range.line1
  end
  if l1 then
    if l2 < l1 then
      l1, l2 = l2, l1
    end
    local n = api.nvim_buf_line_count(buf)
    l1 = math.min(math.max(1, math.floor(l1)), n)
    l2 = math.min(math.max(l1, math.floor(l2)), n)
  end
  return { path = path, l1 = l1, l2 = l2 }, nil
end

---@class agent.SendOpts
---@field name? string     target agent (default: the running agent, else config.default_agent)
---@field line1? integer   first line of a range of the current buffer (1-based; ignored in Visual
---                        mode, where the selection's lines are sent)
---@field line2? integer   last line of the range (default line1)
---@field confirm? boolean ask before replacing a different running agent (default true)

---At-mention the current file or buffer in the agent's prompt, then focus the agent's terminal:
---shown when it is hidden, started (config.default_agent, or opts.name) when no agent runs, as
---M.open() does (a different running agent is replaced only when the user confirms). In Visual
---mode the selected lines are mentioned (and Visual mode ends), with opts.line1 that range, else
---the whole file or buffer. Claude, OpenCode and Copilot get the mention through their IDE
---connection; Gemini, buffers that are not files, and agents whose IDE server is disabled get a
---typed reference (see reference()). Until the agent's IDE client connects the mention waits:
---for Claude, OpenCode and Copilot as long as it takes (with a notice after MENTION_WAIT_MS, and
---dropped when the agent stops or is replaced), for Gemini up to MENTION_WAIT_MS after its start.
---The mention is never submitted.
---@param opts agent.SendOpts|nil
---@return boolean ok, string|nil how_or_err  how: 'sent' (through the IDE connection), 'typed' or
---  'pending' (delivered once the agent is connected); err is nil when the user declined to replace
---  the running agent
function M.send(opts)
  ensure_setup()
  opts = opts or {}
  local target, terr = send_target(opts.line1 and { line1 = opts.line1, line2 = opts.line2 } or nil)
  if not target then
    return false, terr
  end
  local name, nerr = resolve(opts.name)
  if not name then
    return false, nerr
  end
  local def = require('agent.agents').get(name)
  ---@type agent.Mention
  local m = { name = name, def = def, path = target.path, l1 = target.l1, l2 = target.l2 }
  if config.get().terminal.layout == 'none' and not terminal.is_running() then
    -- No agent.nvim terminal: only an agent the user started, connected to the IDE server, and
    -- nothing typed (that needs a terminal agent.nvim opened).
    if provider_mention(m) then
      return true, 'sent'
    end
    local none = ', and terminal.layout is "none"'
    if not MENTION_PROVIDERS[def.provider] then
      return false, ('%s takes mentions only in a terminal agent.nvim opened'):format(name) .. none
    elseif require('agent.editor.context').is_buffer_uri(m.path) then
      return false, 'a buffer that is not a file is mentioned only in a terminal agent.nvim opened' .. none
    end
    return false, ('no %s is connected to Neovim to take the mention (terminal.layout is "none")')
      :format(name)
  end
  -- The focus moves to the agent terminal: leave Visual mode here, in the buffer.
  if vim.api.nvim_get_mode().mode:match('^[vVsS\22\19]') then
    vim.cmd('normal! \27')
  end
  local buf, oerr = M.open(name, { confirm = opts.confirm, silent = true })
  if not buf then
    return false, oerr
  end
  local info = terminal.info()
  if not info or not info.running then
    return false, name .. ' is not running'
  end
  m.pid, m.started = info.pid, info.started
  -- Quietly (Claude, OpenCode, Copilot) or at all (Gemini): after a start, and while the client is
  -- connecting.
  m.deadline = info.started + M.MENTION_WAIT_MS
  if client_state(m) == 'connecting' then
    m.deadline = math.max(m.deadline, util.now_ms() + M.MENTION_WAIT_MS)
  end
  -- Behind the mentions still waiting, if any: they arrive in the order they were sent.
  m.sync = true
  table.insert(state.mentions, m)
  drain()
  m.sync = nil
  if not m.how then
    poll()
    return true, 'pending'
  elseif m.how == 'error' then
    return false, m.err
  elseif m.how == 'gone' then
    return false, name .. ' is not running'
  end
  return true, m.how
end

-- ---------------------------------------------------------------------------
-- Status, MCP config, diffs
-- ---------------------------------------------------------------------------

---@class agent.AgentStatus
---@field name string
---@field kind string|nil
---@field provider string|nil
---@field running boolean      false: it exited and its terminal was left open
---@field visible boolean      shown in the current tab page
---@field pid integer|nil
---@field session_id string|nil
---@field cwd string|nil
---@field exit_code integer|nil

---@class agent.Status
---@field setup boolean
---@field servername string
---@field agent agent.AgentStatus|nil  the agent in the terminal, nil when there is none
---@field providers table<string, table>  provider status() plus `enabled`

---State of the agent and of every provider.
---@return agent.Status
function M.status()
  local out = {
    setup = state.setup_done,
    servername = vim.v.servername,
    agent = nil,
    providers = {},
  }
  local info = terminal.info()
  if info then
    local def = require('agent.agents').get(info.name)
    out.agent = {
      name = info.name,
      kind = def and def.kind,
      provider = def and def.provider,
      running = info.running,
      visible = terminal.is_visible(),
      pid = info.pid,
      session_id = info.session_id,
      cwd = info.cwd,
      exit_code = info.exit_code,
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
  local lines = { 'agent.nvim  (server ' .. (s.servername ~= '' and s.servername or 'none') .. ')', 'Agent:' }
  local a = s.agent
  if a then
    local line = ('  %-10s %s'):format(a.name, a.running and ('running (pid ' .. tostring(a.pid) .. ')')
      or ('exited' .. (a.exit_code and (' with code ' .. a.exit_code) or '')))
    if a.visible then
      line = line .. ', visible'
    end
    lines[#lines + 1] = line .. (a.provider and ('  [provider ' .. a.provider .. ']') or '')
  else
    lines[#lines + 1] = '  none (default: ' .. config.get().default_agent .. ')'
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

function commands.AgentToggle(o)
  local buf, err = M.toggle(arg1(o), { silent = true })
  report(buf ~= nil, err)
end

function commands.AgentOpen(o)
  local buf, err = M.open(arg1(o), { silent = true })
  report(buf ~= nil, err)
end

function commands.AgentSend(o)
  local opts = { name = arg1(o) }
  -- A <cmd> mapping in Visual mode has no range: M.send() reads the live selection.
  if o.range and o.range > 0 then
    opts.line1, opts.line2 = o.line1, o.line2
  end
  local ok, err = M.send(opts)
  if not ok and err then
    notify(tostring(err), vim.log.levels.WARN)
  end
end

function commands.AgentClose()
  M.close()
end

function commands.AgentStop()
  if not M.stop() then
    notify('no agent is running', vim.log.levels.WARN)
  end
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
