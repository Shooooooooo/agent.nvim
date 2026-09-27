---@mod agent.providers.copilot GitHub Copilot CLI `/ide` integration
---
--- Copilot CLI finds IDEs through lock files in `<COPILOT_HOME or ~/.copilot>/ide/<uuid>.lock` and
--- auto-connects to the one whose `workspaceFolders` contains its (physical) cwd. The lock names a
--- Unix-domain socket (a named pipe on Windows) on which this provider serves MCP Streamable HTTP at
--- `/mcp`, authenticated with `Authorization: Nonce <secret>`. Wire details: specs/copilot.md.
---
--- * One socket and one nonce per Neovim. One lock per workspace folder, written once and never
---   rewritten while the server lives: the CLI treats any event on its lock file as "IDE gone".
--- * Tools: get_vscode_info, get_selection, open_diff (held open until the user decides),
---   close_diff, get_diagnostics, update_session_name.
--- * Notifications, sent on the session's GET stream: selection_changed (to every session, and
---   replayed when a stream opens).
--- * The proposed side of a diff is read-only: after SAVED the CLI writes its own content.
local uv = vim.uv or vim.loop
local util = require('agent.util')
local log = require('agent.log').scope('copilot')
local McpServer = require('agent.mcp.server')
local streamable = require('agent.mcp.streamable_http')

local api = vim.api

local M = {}

M.IDE_NAME = 'Neovim'
M.SERVER_NAME = 'agent-nvim-copilot-cli'
M.SERVER_TITLE = 'Neovim Copilot CLI'
M.SERVER_VERSION = '0.0.1'
--- Versions echoed in `initialize`; anything else is answered with the first one (copilot.md §4.3).
M.PROTOCOL_VERSIONS = { '2025-11-25', '2025-06-18', '2025-03-26', '2024-11-05' }
--- `owner` of the diffs this provider opens (agent.editor.diff).
M.DIFF_OWNER = 'copilot'
M.SOCKET_NAME = 'm.sock'
--- Usable bytes of sockaddr_un.sun_path (104 on macOS/BSD, 108 on Linux, minus the NUL).
M.MAX_SOCKET_PATH = (function()
  local sys = uv.os_uname().sysname
  if sys == 'Linux' then
    return 107
  end
  return 103
end)()
--- How long to watch a file for the CLI's write after the terminal answered a diff.
M.RELOAD_WATCH_MS = 5000
--- Retry window for opening a diff while Neovim is in a state that forbids window changes.
M.OPEN_RETRY_MS = 30000

local SEVERITY = { [1] = 'error', [2] = 'warning', [3] = 'information', [4] = 'hint' }

---@class agent.copilot.Lock
---@field path string
---@field dir string
---@field folder string     realpath of the folder
---@field folders string[]  workspaceFolders written into the lock

---@class agent.copilot.PendingDiff
---@field tab_name string
---@field path string       original_file_path as received
---@field session agent.mcp.Session
---@field respond fun(result: any, err: any): boolean
---@field ui_open boolean
---@field settled boolean
---@field sig string        file_sig() of the original when open_diff arrived

---@type table|nil  running state (see M.start)
local state = nil

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

---@return table
local function cfg()
  local ok, c = pcall(function()
    return require('agent.config').get().providers.copilot
  end)
  return ok and type(c) == 'table' and c or {}
end

local function diff()
  return require('agent.editor.diff')
end

local function context()
  return require('agent.editor.context')
end

local function epoch_ms()
  local sec, usec = uv.gettimeofday()
  return sec * 1000 + math.floor(usec / 1000)
end

---One text content item holding `value` as JSON (the CLI JSON-parses the first text item).
---@param value any
---@return table
local function json_result(value)
  return { content = { { type = 'text', text = vim.json.encode(value) } } }
end

---@param pid integer
---@return boolean dead  true only when the process certainly does not exist
local function pid_dead(pid)
  local ok, _, code = uv.kill(pid, 0)
  return not ok and code == 'ESRCH'
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

---Byte column -> UTF-16 code units on a buffer line (VS Code positions). Falls back to the byte
---column when the buffer is not loaded.
---@param bufnr integer|nil
---@param line integer 0-based
---@param col integer byte column
---@return integer
local function utf16_col(bufnr, line, col)
  if not col or col <= 0 or not bufnr or not api.nvim_buf_is_loaded(bufnr) then
    return col or 0
  end
  local text = api.nvim_buf_get_lines(bufnr, line, line + 1, false)[1]
  if not text then
    return col
  end
  local ok, n = pcall(vim.str_utfindex, text, 'utf-16', math.min(col, #text), false)
  return ok and n or col
end

---@param bufnr integer|nil
---@param pos { line: integer, character: integer }
---@return { line: integer, character: integer }
local function position(bufnr, pos)
  return { line = pos.line, character = utf16_col(bufnr, pos.line, pos.character) }
end

-- ---------------------------------------------------------------------------
-- Paths: lock directory and socket
-- ---------------------------------------------------------------------------

---The Copilot home the CLI will use, given the job's extra env (a `false` value means unset).
---@param env table<string, string|false>|nil
---@return string
local function copilot_home(env)
  local v
  if env and env.COPILOT_HOME ~= nil then
    v = env.COPILOT_HOME
  else
    v = vim.env.COPILOT_HOME
  end
  if type(v) == 'string' and v ~= '' then
    return util.abspath(v)
  end
  return vim.fs.joinpath(util.home(), '.copilot')
end

---Directory the CLI scans for lock files: `providers.copilot.lock_dir` (tests), else
---`$COPILOT_HOME/ide` (from `env` when given, else Neovim's environment), else `~/.copilot/ide`.
---@param env table<string, string|false>|nil  the agent job's extra env
---@return string
function M.lock_dir(env)
  local override = cfg().lock_dir
  if type(override) == 'string' and override ~= '' then
    return util.abspath(override)
  end
  return vim.fs.joinpath(copilot_home(env), 'ide')
end

---Pick a socket path that fits in sun_path: `<base>/agentnvim-<random>/m.sock` for the first base
---that is short enough. The directory is created (0700) by agent.net.http and removed on close.
---@param bases string[]|nil  default: providers.copilot.socket_dir, else $TMPDIR, then /tmp
---@return string|nil path, string|nil err
function M.socket_path(bases)
  if util.is_windows then
    return '\\\\.\\pipe\\agentnvim-' .. util.random_hex(8), nil
  end
  if not bases then
    local override = cfg().socket_dir
    bases = type(override) == 'string' and override ~= '' and { override } or { uv.os_tmpdir(), '/tmp' }
  end
  local name = 'agentnvim-' .. util.random_hex(6)
  for _, base in ipairs(bases) do
    if type(base) == 'string' and base ~= '' then
      local p = vim.fs.joinpath(util.abspath(base), name, M.SOCKET_NAME)
      if #p <= M.MAX_SOCKET_PATH then
        return p, nil
      end
    end
  end
  return nil, string.format('no socket directory gives a path of at most %d bytes (tried %s)',
    M.MAX_SOCKET_PATH, table.concat(bases, ', '))
end

-- ---------------------------------------------------------------------------
-- Lock files
-- ---------------------------------------------------------------------------

---@param folder string realpath
---@return boolean
local function is_trusted(folder)
  local t = cfg().trust_workspace
  if type(t) == 'function' then
    local ok, v = pcall(t, folder)
    return ok and v == true
  end
  return t == true
end

---Remove our own stale locks: ideName Neovim and a pid that no longer exists (copilot.md §2.6).
---@param dir string
local function cleanup_stale(dir)
  local handle = uv.fs_scandir(dir)
  if not handle then
    return
  end
  local me = uv.os_getpid()
  while true do
    local name, typ = uv.fs_scandir_next(handle)
    if not name then
      break
    end
    if name:sub(-5) == '.lock' and (typ == nil or typ == 'file') then
      local p = vim.fs.joinpath(dir, name)
      local ok, info = util.json_decode(read_file(p) or '')
      if ok and type(info) == 'table' and info.ideName == M.IDE_NAME and type(info.pid) == 'number'
        and info.pid ~= me and pid_dead(info.pid) then
        log.debug('removing stale lock %s (pid %d)', p, info.pid)
        util.remove(p)
      end
    end
  end
end

---@param st table
---@param folders string[]
---@param trusted boolean
---@return string
local function lock_json(st, folders, trusted)
  return vim.json.encode({
    socketPath = st.socket,
    scheme = util.is_windows and 'pipe' or 'unix',
    headers = { Authorization = st.nonce },
    pid = uv.os_getpid(),
    ideName = M.IDE_NAME,
    timestamp = epoch_ms(),
    workspaceFolders = folders,
    isTrusted = trusted,
  })
end

---Make sure a lock advertising `folder` exists in the lock directory. A lock is written once per
---(directory, folder) and never rewritten; it is only recreated if the file disappeared.
---@param folder string
---@param opts { env?: table<string, string|false>, lock_dir?: string }|nil
---@return string|nil path, string|nil err
function M.ensure_lock(folder, opts)
  local st = state
  if not st then
    return nil, 'the copilot provider is not running'
  end
  opts = opts or {}
  local dir = opts.lock_dir or M.lock_dir(opts.env)
  local real = util.realpath(folder)
  local key = dir .. '\0' .. real
  local existing = st.locks[key]
  if existing and uv.fs_stat(existing.path) then
    return existing.path, nil
  end
  if vim.fn.isdirectory(dir) == 0 then
    local ok = pcall(vim.fn.mkdir, dir, 'p', tonumber('700', 8))
    if not ok or vim.fn.isdirectory(dir) == 0 then
      return nil, 'cannot create ' .. dir
    end
  end
  if not st.cleaned[dir] then
    st.cleaned[dir] = true
    cleanup_stale(dir)
  end
  -- The CLI compares against its physical cwd; also list the literal path when it differs (§2.8).
  local folders = { real }
  local literal = util.abspath(folder)
  if literal ~= real then
    folders[2] = literal
  end
  local path = vim.fs.joinpath(dir, util.uuid() .. '.lock')
  local ok, err = util.atomic_write(path, lock_json(st, folders, is_trusted(real)), tonumber('600', 8))
  if not ok then
    return nil, err
  end
  if not existing then
    st.lock_order[#st.lock_order + 1] = key
  end
  st.locks[key] = { path = path, dir = dir, folder = real, folders = folders }
  log.debug('lock %s for %s', path, real)
  return path, nil
end

-- ---------------------------------------------------------------------------
-- Selection
-- ---------------------------------------------------------------------------

---Convert an agent.editor.selection value into Copilot's SelectionInfo (0-based lines, UTF-16
---characters, percent-encoded fileUrl).
---@param s agent.Selection
---@return table
function M.selection_params(s)
  return {
    text = s.text or '',
    filePath = s.path,
    fileUrl = util.file_url(s.path),
    selection = {
      start = position(s.bufnr, s.start),
      ['end'] = position(s.bufnr, s.finish),
      isEmpty = s.is_empty == true,
    },
  }
end

---Whether a selection taken from a file window that no longer has focus still comes from the
---"active editor": its buffer is the last focused file buffer (known only while selection tracking
---runs) and is shown in the current tab page. VS Code keeps activeTextEditor while its terminal has
---focus (copilot.md §4.9).
---@param sel table agent.editor.selection
---@param s agent.Selection
---@return boolean
local function still_active(sel, s)
  local b = s.bufnr
  if not sel.is_running() or not b or not api.nvim_buf_is_loaded(b) or api.nvim_buf_get_name(b) ~= s.path
    or sel.last_focused_buf() ~= b then
    return false
  end
  for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
    if api.nvim_win_get_buf(win) == b then
      return true
    end
  end
  return false
end

---@param st table
---@return table|nil params, boolean current  current: from the active editor (live, or the file
---  window left for e.g. the agent terminal and still shown), not a cached selection
local function current_selection(st)
  local ok, s, current = pcall(function()
    local sel = require('agent.editor.selection')
    local s, live = sel.current()
    return s, live == true or (s ~= nil and still_active(sel, s))
  end)
  if ok and s and s.path and s.path ~= '' then
    return M.selection_params(s), current == true
  end
  return st.last_selection, false
end

local function tracking_enabled()
  local ok, track = pcall(function()
    return require('agent.config').get().selection.track
  end)
  return not ok or track ~= false
end

-- ---------------------------------------------------------------------------
-- Sessions
-- ---------------------------------------------------------------------------

---The agent terminal (agent.terminal) that runs this session's CLI, if any.
---@param s agent.mcp.Session
---@return string|nil name, integer|nil bufnr
local function terminal_of(s)
  local term = package.loaded['agent.terminal']
  if not term then
    return nil
  end
  for _, pid in ipairs({ s.info.copilot_parent_pid, s.info.copilot_pid }) do
    local name = term.find_by_pid(pid)
    if name then
      return name, term.bufnr(name)
    end
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- Diffs
-- ---------------------------------------------------------------------------

---Answer a pending open_diff (once).
---@param st table
---@param entry agent.copilot.PendingDiff
---@param result 'SAVED'|'REJECTED'
---@param trigger string
---@return boolean
local function settle(st, entry, result, trigger)
  if entry.settled then
    return false
  end
  entry.settled = true
  if st.pending[entry.tab_name] == entry then
    st.pending[entry.tab_name] = nil
  end
  local verb = result == 'SAVED' and 'accepted' or 'rejected'
  return entry.respond(json_result({
    success = true,
    result = result,
    trigger = trigger,
    tab_name = entry.tab_name,
    message = string.format('User %s changes for %s', verb, entry.path),
  }))
end

---Close the diff UI of a pending entry without resolving it.
---@param entry agent.copilot.PendingDiff
local function dismiss(entry)
  if entry.ui_open then
    entry.ui_open = false
    pcall(diff().close, entry.tab_name)
  end
end

---Stat signature of a file, to notice the CLI's write.
---@param path string
---@return string
local function file_sig(path)
  local s = uv.fs_stat(util.abspath(path))
  if not s then
    return 'missing'
  end
  return string.format('%d.%d:%d:%d', s.mtime.sec, s.mtime.nsec or 0, s.size, s.ino or 0)
end

---After the terminal answered a diff, the CLI may write the file: reload its buffers once the file
---differs from `before` (agent.editor.diff does this itself after an accept in Neovim). `before` is
---sampled when open_diff arrives: the CLI does not wait for close_diff before it writes, so the
---write can land before the close_diff handler runs.
---@param st table
---@param path string
---@param before string  file_sig() while the CLI was still waiting for the user
local function watch_reload(st, path, before)
  local abs = util.abspath(path)
  local timer = uv.new_timer()
  local elapsed = 0
  st.timers[timer] = true
  local function done()
    st.timers[timer] = nil
    timer:stop()
    if not timer:is_closing() then
      timer:close()
    end
  end
  timer:start(100, 100, vim.schedule_wrap(function()
    if timer:is_closing() then
      return
    end
    elapsed = elapsed + 100
    if file_sig(abs) ~= before then
      done()
      pcall(diff().reload, abs, { created = before == 'missing' })
    elseif elapsed >= M.RELOAD_WATCH_MS then
      done()
    end
  end))
end

---@param st table
---@param entry agent.copilot.PendingDiff
---@param res agent.DiffResult
local function on_diff_resolved(st, entry, res)
  if res.trigger == 'closed' then
    -- The user closed the diff without deciding. Like VS Code, keep the request pending: the
    -- terminal prompt stays authoritative, and close_diff answers it later (copilot.md §4.11 step 8).
    entry.ui_open = false
    if not entry.settled then
      log.debug('diff %s closed by the user; still pending', entry.tab_name)
      require('agent.log').notify('diff closed; Copilot is still waiting, answer its prompt in the terminal')
    end
    return
  end
  entry.ui_open = false
  if res.status == 'accepted' then
    settle(st, entry, 'SAVED', 'accepted_via_button')
  elseif res.trigger == 'disconnect' then
    settle(st, entry, 'REJECTED', 'client_disconnected')
  elseif res.trigger == 'replaced' then
    settle(st, entry, 'REJECTED', 'closed_via_tool')
  else
    settle(st, entry, 'REJECTED', 'rejected_via_button')
  end
end

---@param err any
local function is_window_lock_error(err)
  local s = tostring(err)
  return s:find('E565', 1, true) ~= nil or s:find('E11:', 1, true) ~= nil or s:find('textlock', 1, true) ~= nil
end

---@param st table
---@param entry agent.copilot.PendingDiff
---@param args table
---@param deadline number
local function show_diff(st, entry, args, deadline)
  if entry.settled then
    return
  end
  local ok, opened, err = pcall(diff().open, {
    id = entry.tab_name,
    path = entry.path,
    new_contents = args.new_file_contents,
    title = entry.tab_name,
    editable = false,
    owner = M.DIFF_OWNER,
    on_resolve = function(res)
      on_diff_resolved(st, entry, res)
    end,
  })
  if not ok then
    opened, err = false, opened
  end
  if opened then
    entry.ui_open = true
    return
  end
  -- Neovim is in a state that forbids window changes (e.g. the command-line window): retry.
  if is_window_lock_error(err) and util.now_ms() < deadline then
    vim.defer_fn(function()
      show_diff(st, entry, args, deadline)
    end, 100)
    return
  end
  if entry.settled then
    return
  end
  entry.settled = true
  if st.pending[entry.tab_name] == entry then
    st.pending[entry.tab_name] = nil
  end
  entry.respond(McpServer.error_result('Failed to open diff: ' .. tostring(err)))
end

-- ---------------------------------------------------------------------------
-- Tools
-- ---------------------------------------------------------------------------

local SCHEMA = 'http://json-schema.org/draft-07/schema#'
local NO_TASKS = { taskSupport = 'forbidden' }

---@param st table
---@param srv agent.mcp.Server
local function add_tools(st, srv)
  srv:add_tool({
    name = 'get_vscode_info',
    description = 'Get information about the current editor (Neovim) instance',
    inputSchema = { type = 'object', properties = {} },
    execution = NO_TASKS,
    handler = function()
      local v = vim.version()
      return json_result({
        version = string.format('%d.%d.%d', v.major, v.minor, v.patch),
        appName = 'Neovim',
        appRoot = vim.env.VIMRUNTIME or '',
        language = vim.v.lang or '',
        machineId = '',
        sessionId = st.instance_id,
        uriScheme = 'file',
        shell = vim.o.shell,
      })
    end,
  })

  srv:add_tool({
    name = 'get_selection',
    description = 'Get text selection. Returns current selection if an editor is active, otherwise returns the latest '
      .. 'cached selection. The "current" field indicates if this is from the active editor (true) or cached (false).',
    inputSchema = { type = 'object', properties = {} },
    execution = NO_TASKS,
    handler = function()
      local params, current = current_selection(st)
      if not params then
        return json_result(vim.NIL)
      end
      local out = vim.deepcopy(params)
      out.current = current
      return json_result(out)
    end,
  })

  srv:add_tool({
    name = 'open_diff',
    description = 'Opens a diff view comparing original file content with new content. Blocks until user accepts, '
      .. 'rejects, or closes the diff.',
    inputSchema = {
      ['$schema'] = SCHEMA,
      type = 'object',
      additionalProperties = false,
      properties = {
        original_file_path = { type = 'string', description = 'Path to the original file' },
        new_file_contents = { type = 'string', description = 'The new file contents to compare against' },
        tab_name = { type = 'string', description = 'Name for the diff tab' },
      },
      required = { 'original_file_path', 'new_file_contents', 'tab_name' },
    },
    execution = NO_TASKS,
    async = true,
    handler = function(args, ctx, respond)
      local path, contents, tab = args.original_file_path, args.new_file_contents, args.tab_name
      if type(path) ~= 'string' or path == '' or type(contents) ~= 'string' or type(tab) ~= 'string' or tab == '' then
        return respond(McpServer.error_result(
          'Failed to open diff: original_file_path, new_file_contents and tab_name must be non-empty strings'))
      end
      ---@type agent.copilot.PendingDiff
      local entry = {
        tab_name = tab,
        path = path,
        session = ctx.session,
        respond = respond,
        ui_open = false,
        settled = false,
        -- The CLI is blocked on the user's answer: it cannot have written the file yet.
        sig = file_sig(path),
      }
      local prev = st.pending[tab]
      if prev then
        settle(st, prev, 'REJECTED', 'closed_via_tool')
        dismiss(prev)
      end
      st.pending[tab] = entry
      ctx.on_cancel(function(reason, detail)
        -- The session ended (DELETE, takeover, expiry, server stop), the request was cancelled, or
        -- the CLI went away: nobody is left to answer, so only dismiss the UI.
        log.debug('open_diff %s cancelled: %s %s', tab, tostring(reason), tostring(detail))
        entry.settled = true
        if st.pending[tab] == entry then
          st.pending[tab] = nil
        end
        dismiss(entry)
      end)
      show_diff(st, entry, args, util.now_ms() + M.OPEN_RETRY_MS)
    end,
  })

  srv:add_tool({
    name = 'close_diff',
    description = 'Closes a diff tab by its tab name. Use this when the client rejects an edit to close the '
      .. 'corresponding diff view.',
    inputSchema = {
      ['$schema'] = SCHEMA,
      type = 'object',
      additionalProperties = false,
      properties = {
        tab_name = {
          type = 'string',
          description = 'The tab name of the diff to close (must match the tab_name used when opening the diff)',
        },
      },
      required = { 'tab_name' },
    },
    execution = NO_TASKS,
    handler = function(args)
      local tab = args.tab_name
      if type(tab) ~= 'string' then
        return McpServer.error_result('tab_name must be a string')
      end
      local entry = st.pending[tab]
      if not entry then
        return json_result({
          success = true,
          already_closed = true,
          tab_name = tab,
          message = string.format('No active diff found with tab name "%s" (may already be closed)', tab),
        })
      end
      settle(st, entry, 'REJECTED', 'closed_via_tool')
      dismiss(entry)
      -- The user answered in the terminal; after "Yes" the CLI writes the file itself, possibly
      -- before this handler ran.
      watch_reload(st, entry.path, entry.sig)
      return json_result({
        success = true,
        already_closed = false,
        tab_name = tab,
        message = string.format('Diff "%s" closed successfully', tab),
      })
    end,
  })

  srv:add_tool({
    name = 'get_diagnostics',
    description = 'Gets language diagnostics (errors, warnings, hints) from Neovim',
    inputSchema = {
      ['$schema'] = SCHEMA,
      type = 'object',
      additionalProperties = false,
      properties = {
        uri = {
          type = 'string',
          description = 'File URI to get diagnostics for. Optional. If not provided, returns diagnostics for all files.',
        },
      },
    },
    execution = NO_TASKS,
    handler = function(args)
      return json_result(M.diagnostics(args.uri))
    end,
  })

  srv:add_tool({
    name = 'update_session_name',
    description = 'Update the display name for the current CLI session',
    inputSchema = {
      ['$schema'] = SCHEMA,
      type = 'object',
      additionalProperties = false,
      properties = { name = { type = 'string', description = 'The new session name' } },
      required = { 'name' },
    },
    execution = NO_TASKS,
    handler = function(args, ctx)
      local name = type(args.name) == 'string' and args.name or tostring(args.name)
      local session = ctx.session
      session.data.name = name
      local term, bufnr = terminal_of(session)
      if bufnr and api.nvim_buf_is_valid(bufnr) then
        vim.b[bufnr].agent_session_name = name
      end
      pcall(api.nvim_exec_autocmds, 'User', {
        pattern = 'AgentSessionName',
        modeline = false,
        data = { provider = 'copilot', name = name, session = session.id, pid = session.info.copilot_pid, terminal = term },
      })
      return json_result({ success = true })
    end,
  })
end

---Diagnostics in Copilot's get_diagnostics shape: files with at least one diagnostic,
---`severity` as a lowercase name, UTF-16 characters, `source`/`code` omitted when absent.
---@param uri string|nil  file:// URI or absolute path; nil = every file
---@return table[]
function M.diagnostics(uri)
  local path
  if type(uri) == 'string' and uri ~= '' then
    path = context().path_from_uri(uri)
    if not path then
      return {}
    end
  end
  local out = {}
  for _, f in ipairs(context().diagnostics(path)) do
    if #f.diagnostics > 0 then
      local list = {}
      for _, d in ipairs(f.diagnostics) do
        list[#list + 1] = {
          message = d.message,
          severity = SEVERITY[d.severity] or 'error',
          range = { start = position(f.bufnr, d.range.start), ['end'] = position(f.bufnr, d.range['end']) },
          source = d.source,
          code = d.code,
        }
      end
      out[#out + 1] = { uri = util.file_url(f.path), filePath = f.path, diagnostics = list }
    end
  end
  return out
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

---@param st table
---@return agent.mcp.Server
local function build_server(st)
  local srv = McpServer.new({
    name = M.SERVER_NAME,
    title = M.SERVER_TITLE,
    version = M.SERVER_VERSION,
    protocol_version = { supported = M.PROTOCOL_VERSIONS, fallback = M.PROTOCOL_VERSIONS[1] },
    capabilities = { tools = { listChanged = true } },
    on_initialize = function(session, params)
      local ci = type(params.clientInfo) == 'table' and params.clientInfo or {}
      log.debug('initialize from %s %s (copilot session %s, pid %s)', tostring(ci.name), tostring(ci.version),
        tostring(session.info.copilot_session_id), tostring(session.info.copilot_pid))
    end,
    on_session_close = function(session, reason)
      log.debug('session %s closed: %s', session.id, reason)
    end,
  })
  add_tools(st, srv)
  return srv
end

---@param st table
---@param session agent.mcp.Session
local function replay_selection(st, session)
  if not tracking_enabled() then
    return
  end
  local params = st.last_selection or current_selection(st)
  if params then
    session:notify('selection_changed', params)
  end
end

---Start the server and write a lock for Neovim's cwd. Idempotent.
---@return boolean ok, string|nil err
function M.start()
  if state then
    return true, nil
  end
  local c = cfg()
  if c.enabled == false then
    return false, 'the copilot provider is disabled (providers.copilot.enabled = false)'
  end
  local sock, perr = M.socket_path()
  if not sock then
    return false, perr
  end
  local st = {
    nonce = 'Nonce ' .. util.random_hex(32),
    socket = sock,
    instance_id = util.uuid(),
    locks = {}, ---@type table<string, agent.copilot.Lock>
    lock_order = {}, ---@type string[]
    cleaned = {},
    pending = {}, ---@type table<string, agent.copilot.PendingDiff>
    timers = {},
    last_selection = nil,
  }
  st.srv = build_server(st)
  local binding, err = streamable.attach({ pipe = sock }, st.srv, {
    authorize = streamable.check_authorization(st.nonce),
    accept_initialize = streamable.copilot_initialize_policy(),
    on_stream_open = function(session)
      replay_selection(st, session)
    end,
  })
  if not binding then
    return false, string.format('cannot listen on %s: %s', sock, tostring(err))
  end
  st.binding = binding
  st.socket = binding.socket_path or sock
  state = st

  st.augroup = api.nvim_create_augroup('AgentProviderCopilot', { clear = true })
  api.nvim_create_autocmd('VimLeavePre', {
    group = st.augroup,
    callback = function()
      M.stop()
    end,
  })
  api.nvim_create_autocmd('DirChanged', {
    group = st.augroup,
    pattern = 'global',
    callback = function()
      if state == st and not vim.o.autochdir then
        local cwd = vim.v.event and vim.v.event.cwd or vim.fn.getcwd()
        local _, lerr = M.ensure_lock(cwd)
        if lerr then
          log.warn('cannot write a Copilot lock for %s: %s', cwd, lerr)
        end
      end
    end,
  })

  local _, lerr = M.ensure_lock(vim.fn.getcwd())
  if lerr then
    log.warn('cannot write the Copilot lock file: %s', lerr)
  end
  log.debug('listening on %s', st.socket)
  return true, nil
end

---Remove the locks, end every session (pending diffs are dismissed) and close the socket.
function M.stop()
  local st = state
  if not st then
    return
  end
  state = nil
  pcall(api.nvim_del_augroup_by_id, st.augroup)
  -- Locks first, so no CLI discovers a socket that is about to go away (copilot.md §2.5).
  for _, key in ipairs(st.lock_order) do
    local l = st.locks[key]
    if l then
      util.remove(l.path)
    end
  end
  st.locks, st.lock_order = {}, {}
  st.binding:close()
  for _, entry in pairs(st.pending) do
    entry.settled = true
    dismiss(entry)
  end
  st.pending = {}
  pcall(function()
    diff().close_all({ owner = M.DIFF_OWNER })
  end)
  for timer in pairs(st.timers) do
    timer:stop()
    if not timer:is_closing() then
      timer:close()
    end
  end
  st.timers = {}
end

---@return boolean
function M.is_running()
  return state ~= nil
end

---Environment for a Copilot terminal job. Copilot has no IDE environment variables: discovery is
---by lock file and cwd only (copilot.md §9).
---@return table<string, string|false>
function M.env()
  return {}
end

---Launch info for agents.build_launch (opts.ide): starts the server if needed and makes sure a lock
---exists for the launch folder, in the lock directory the CLI will scan (honouring COPILOT_HOME in
---the job's env). The job must run with `cwd = lock_folder` (the physical path) to auto-connect.
---@param opts { cwd?: string, env?: table<string, string|false>, agent?: string }|nil
---  env: the job's extra env; default config.agents[agent or 'copilot'].env
---@return { lock_folder: string, lock: string|nil, lock_dir: string, socket: string }|nil info, string|nil err
function M.launch_info(opts)
  opts = opts or {}
  local ok, err = M.start()
  if not ok then
    return nil, err
  end
  local env = opts.env
  if env == nil then
    local okc, def = pcall(function()
      return require('agent.config').get().agents[opts.agent or 'copilot']
    end)
    env = okc and type(def) == 'table' and def.env or nil
  end
  local folder = util.realpath(opts.cwd or vim.fn.getcwd())
  local dir = M.lock_dir(env)
  local lock, lerr = M.ensure_lock(folder, { lock_dir = dir })
  if not lock then
    log.warn('cannot write a Copilot lock for %s: %s', folder, tostring(lerr))
  end
  return { lock_folder = folder, lock = lock, lock_dir = dir, socket = state.socket }, nil
end

---@class agent.copilot.Status
---@field running boolean
---@field clients integer          sessions (connected CLIs)
---@field address string|nil       socket path
---@field lock string|nil          first lock file
---@field locks string[]
---@field sessions { id: string, copilot_session_id: string|nil, pid: integer|nil, streaming: boolean, name: string|nil }[]
---@field pending_diffs string[]   tab names of open_diff calls still waiting

---@return agent.copilot.Status
function M.status()
  local st = state
  if not st then
    return { running = false, clients = 0, locks = {}, sessions = {}, pending_diffs = {} }
  end
  local locks = {}
  for _, key in ipairs(st.lock_order) do
    locks[#locks + 1] = st.locks[key].path
  end
  local sessions = {}
  for _, s in ipairs(st.binding:sessions()) do
    sessions[#sessions + 1] = {
      id = s.id,
      copilot_session_id = s.info.copilot_session_id,
      pid = s.info.copilot_pid,
      streaming = st.binding:has_stream(s),
      name = s.data.name,
    }
  end
  local pending = vim.tbl_keys(st.pending)
  table.sort(pending)
  return {
    running = true,
    clients = #sessions,
    address = st.socket,
    lock = locks[1],
    locks = locks,
    sessions = sessions,
    pending_diffs = pending,
  }
end

---Push a selection to every connected CLI (selection_changed). Called by agent.nvim for each
---debounced selection event; the value is also cached for get_selection and stream replays.
---@param s agent.Selection|nil
function M.on_selection(s)
  local st = state
  if not st or not s or type(s.path) ~= 'string' or s.path == '' then
    return
  end
  local params = M.selection_params(s)
  st.last_selection = params
  st.srv:broadcast('selection_changed', params, function(session)
    return st.binding:has_stream(session)
  end)
end

---Internal state, for tests.
---@return table|nil
function M._state()
  return state
end

return M
