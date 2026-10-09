---@mod agent.providers.gemini Gemini CLI IDE companion server
---
--- Makes a `gemini` process running in a Neovim terminal enter IDE mode (specs/gemini.md):
---  * MCP Streamable HTTP on 127.0.0.1:<port>/mcp with Host, Origin and `Authorization: Bearer`
---    checks (agent.mcp.streamable_http), keep-alive comments on the GET stream;
---  * a discovery file `<tmpdir>/gemini/ide/gemini-ide-server-<nvim pid>-<port>.json` (0600) with
---    `ideInfo = {name='neovim', displayName='Neovim'}` and a workspacePath that contains the cwd of
---    every gemini job we launch;
---  * the tools `openDiff` (opens the diff UI and answers `{content: []}` at once; the user's
---    decision is sent later as `ide/diffAccepted {filePath, content}` / `ide/diffRejected {filePath}`
---    with filePath exactly as received) and `closeDiff` (returns the proposal text, user edits
---    included, as the JSON text `{"content": ...}`; never sends a notification);
---  * `ide/contextUpdate` snapshots of the recently focused files (config.selection.track), and of
---    what :AgentSend sent, debounced, and sent to every new GET stream.
--- Every outgoing notification is checked against Gemini's zod schemas first: one malformed
--- notification disconnects Gemini's IDE client for the rest of its life.
local McpServer = require('agent.mcp.server')
local streamable = require('agent.mcp.streamable_http')
local common = require('agent.net.common')
local diff = require('agent.editor.diff')
local selection = require('agent.editor.selection')
local context = require('agent.editor.context')
local util = require('agent.util')
local log = require('agent.log').scope('gemini')

local uv = vim.uv
local api = vim.api

local M = {}

M.NAME = 'gemini'
M.SERVER_NAME = 'agent.nvim-gemini-companion'
M.VERSION = '0.1.0'
M.IDE_INFO = { name = 'neovim', displayName = 'Neovim' }
M.FILE_PATTERN = '^gemini%-ide%-server%-(%d+)%-(%d+)%.json$'
--- Protocol versions echoed back to the client (Gemini's SDK 1.23 accepts the last four).
M.PROTOCOL_VERSIONS = { '2025-11-25', '2025-06-18', '2025-03-26', '2024-11-05', '2024-10-07' }
M.DEFAULT_PROTOCOL_VERSION = '2025-06-18'
M.MAX_OPEN_FILES = 10
M.MAX_SELECTED_TEXT = 16384
M.MAX_WORKSPACES = 64

--- Defaults for `config.providers.gemini` (only `enabled` is in config.lua; the rest are optional).
M.defaults = {
  --- Directory of the discovery file. Default: <os tmpdir>/gemini/ide (what Gemini scans).
  ---@type string|nil
  discovery_dir = nil,
  --- Port to listen on; 0 = OS-assigned. A restart in the same Neovim reuses the previous port.
  port = 0,
  --- SSE keep-alive comment interval (capped at 30 s). Gemini's undici client drops a stream after
  --- 300 s of silence, and that disconnects its IDE mode for good.
  keepalive_ms = 20000,
  --- Debounce for ide/contextUpdate.
  context_debounce_ms = 50,
  --- Files listed in ide/contextUpdate (Gemini keeps at most 10).
  max_open_files = 10,
  --- Move the cursor into the diff when Gemini opens one (Gemini's TUI prompt stays usable).
  focus_diff = true,
  --- Close a session's diffs when its GET stream has been gone this long (Gemini exited or lost the connection).
  orphan_grace_ms = 5000,
  --- Forget sessions whose stream went away this long ago (Gemini never sends DELETE).
  idle_session_timeout_ms = 5 * 60 * 1000,
  --- Also export GEMINI_CLI_IDE_PID/SERVER_PORT/AUTH_TOKEN into Neovim's own environment, so a
  --- gemini started by hand in any :terminal connects to this Neovim deterministically.
  export_env = false,
}

---@type table|nil  running state
local state = nil
-- Kept for the whole Neovim session: Gemini reconnects (/ide enable) to the same port.
local last_port, last_token = nil, nil
local ide_hint_shown = false

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

---@param opts table|nil
---@return table
local function options(opts)
  local cfg = {}
  local ok, c = pcall(function()
    return require('agent.config').get().providers.gemini
  end)
  if ok and type(c) == 'table' then
    cfg = c
  end
  local o = vim.tbl_extend('force', vim.deepcopy(M.defaults), cfg, opts or {})
  -- Gemini's client drops a stream after 300 s without bytes; keep-alives go out at least every 30 s.
  if type(o.keepalive_ms) ~= 'number' or o.keepalive_ms <= 0 then
    o.keepalive_ms = M.defaults.keepalive_ms
  end
  o.keepalive_ms = math.min(o.keepalive_ms, 30000)
  return o
end

---@return boolean
local function track_selection()
  local ok, t = pcall(function()
    return require('agent.config').get().selection.track
  end)
  return not ok or t ~= false
end

local DELIMITER = util.is_windows and ';' or ':'

---Default discovery directory for a given tmpdir (Node's os.tmpdir() of the gemini process).
---@param tmpdir string|nil default: this Neovim's tmpdir
---@return string
function M.default_discovery_dir(tmpdir)
  tmpdir = tmpdir or uv.os_tmpdir() or '/tmp'
  if #tmpdir > 1 and tmpdir:sub(-1) == '/' then
    tmpdir = tmpdir:sub(1, -2)
  end
  return vim.fs.joinpath(tmpdir, 'gemini', 'ide')
end

---Replace invalid UTF-8 with U+FFFD so the JSON on the wire is valid UTF-8.
---@param s string
---@return string
local function utf8_clean(s)
  if common.valid_utf8(s) then
    return s
  end
  local out, i, n = {}, 1, #s
  while i <= n do
    local c = s:byte(i)
    local len = c < 0x80 and 1 or c >= 0xF0 and 4 or c >= 0xE0 and 3 or c >= 0xC2 and 2 or 0
    local piece = len > 0 and s:sub(i, i + len - 1) or nil
    if piece and #piece == len and common.valid_utf8(piece) then
      out[#out + 1] = piece
      i = i + len
    else
      out[#out + 1] = '\239\191\189'
      i = i + 1
    end
  end
  return table.concat(out)
end

---Create the discovery directory (missing components 0700). An existing directory is left alone.
---@param dir string
---@return boolean ok, string|nil err
local function ensure_dir(dir)
  if vim.fn.isdirectory(dir) == 1 then
    return true, nil
  end
  local ok = pcall(vim.fn.mkdir, dir, 'p', tonumber('700', 8))
  if not ok or vim.fn.isdirectory(dir) == 0 then
    return false, 'cannot create ' .. dir
  end
  return true, nil
end

---@param pid integer
---@return boolean
local function pid_alive(pid)
  local ok, err = uv.kill(pid, 0)
  if ok == 0 or ok == true then
    return true
  end
  return not (type(err) == 'string' and err:find('ESRCH', 1, true))
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

-- ---------------------------------------------------------------------------
-- Notification schemas (mirrors gemini-cli core/src/ide/types.ts)
-- ---------------------------------------------------------------------------

local function is_num(v)
  return type(v) == 'number' and v == v and v ~= math.huge and v ~= -math.huge
end

local function is_object(v)
  return type(v) == 'table' and (next(v) ~= nil or getmetatable(v) == getmetatable(vim.empty_dict()))
    and not vim.islist(v)
end

---@param f any
---@return boolean ok, string|nil err
local function valid_file(f)
  if type(f) ~= 'table' then
    return false, 'file entry is not an object'
  end
  if type(f.path) ~= 'string' or f.path == '' then
    return false, 'path must be a non-empty string'
  end
  if not is_num(f.timestamp) then
    return false, 'timestamp must be a number'
  end
  if f.isActive ~= nil and type(f.isActive) ~= 'boolean' then
    return false, 'isActive must be a boolean'
  end
  if f.selectedText ~= nil and type(f.selectedText) ~= 'string' then
    return false, 'selectedText must be a string'
  end
  if f.cursor ~= nil then
    if type(f.cursor) ~= 'table' or not is_num(f.cursor.line) or not is_num(f.cursor.character) then
      return false, 'cursor must be {line: number, character: number}'
    end
  end
  return true, nil
end

---Check a notification against Gemini's schema for it.
---@param method string
---@param params any
---@return boolean ok, string|nil err
function M.validate_notification(method, params)
  if not is_object(params) then
    return false, 'params must be a JSON object'
  end
  if method == 'ide/contextUpdate' then
    local ws = params.workspaceState
    if ws == nil then
      return true, nil
    end
    if not is_object(ws) then
      return false, 'workspaceState must be an object'
    end
    if ws.isTrusted ~= nil and type(ws.isTrusted) ~= 'boolean' then
      return false, 'isTrusted must be a boolean'
    end
    if ws.openFiles ~= nil then
      if type(ws.openFiles) ~= 'table' or not vim.islist(ws.openFiles) then
        return false, 'openFiles must be an array'
      end
      for _, f in ipairs(ws.openFiles) do
        local ok, err = valid_file(f)
        if not ok then
          return false, err
        end
      end
    end
    return true, nil
  elseif method == 'ide/diffAccepted' then
    if type(params.filePath) ~= 'string' or type(params.content) ~= 'string' then
      return false, 'filePath and content must be strings'
    end
    return true, nil
  elseif method == 'ide/diffRejected' then
    if type(params.filePath) ~= 'string' then
      return false, 'filePath must be a string'
    end
    return true, nil
  end
  return false, 'unknown notification ' .. tostring(method)
end

---Send a notification only when it passes the schema check.
---@param session agent.mcp.Session
---@param method string
---@param params table
---@return boolean sent
local function send_checked(session, method, params)
  local ok, err = M.validate_notification(method, params)
  if not ok then
    log.error('refusing to send a malformed %s: %s', method, err)
    return false
  end
  return session:notify(method, params)
end

-- ---------------------------------------------------------------------------
-- IDE context
-- ---------------------------------------------------------------------------

---The `ide/contextUpdate` params for the current editor state (never isTrusted): the recently
---focused files, with selection.track = true; what :AgentSend sent last (M.send_context()), as the
---active entry, ahead of them (and alone with selection.track = false: the files would carry the
---cursor and selected text). When the user was last in a buffer that is not a file (a terminal
---other than the agent's), it is the active entry, under its nvim://buffer/<n>/<label> id (Gemini
---passes it to the model as the activeFile, which the model reads with the controller's
---read_buffer); it never joins the recent files.
---@param opts { limit?: integer }|nil
---@return table params
function M.build_context(opts)
  local limit = opts and opts.limit or M.MAX_OPEN_FILES
  local sent = state and state.context
  local files = {}
  if track_selection() and limit > 0 then
    files = selection.recent_files({ limit = limit, max_selected = M.MAX_SELECTED_TEXT, buffers = true })
  end
  if sent and limit > 0 then
    -- Ahead of the others, and the newest (Gemini sorts by timestamp and keeps isActive only on
    -- the newest entry).
    local head = vim.deepcopy(sent)
    local rest = {}
    for _, f in ipairs(files) do
      -- (A buffer that is not a file is only ever the active entry.)
      if f.path ~= head.path and not context.is_buffer_uri(f.path) and #rest < limit - 1 then
        rest[#rest + 1] = { path = f.path, bufnr = f.bufnr, timestamp = f.timestamp }
        head.timestamp = math.max(head.timestamp, f.timestamp + 1)
      end
    end
    files = { head }
    vim.list_extend(files, rest)
  end
  local open = {}
  for _, f in ipairs(files) do
    -- A path that is not valid UTF-8 cannot be named in JSON.
    if type(f.path) == 'string' and f.path ~= '' and common.valid_utf8(f.path) then
      local item = { path = f.path, timestamp = math.floor(tonumber(f.timestamp) or 0) }
      if f.is_active then
        item.isActive = true
        if f.cursor and is_num(f.cursor.line) and is_num(f.cursor.character) then
          item.cursor = { line = math.floor(f.cursor.line), character = math.floor(f.cursor.character) }
        end
        if type(f.selected_text) == 'string' and f.selected_text ~= '' then
          item.selectedText = utf8_clean(f.selected_text)
        end
      end
      open[#open + 1] = item
    end
  end
  return { workspaceState = { openFiles = open } }
end

---@param session agent.mcp.Session
---@return table
local function sdata(session)
  local d = session.data.gemini
  if not d then
    d = { diffs = {} }
    session.data.gemini = d
  end
  return d
end

---@param session agent.mcp.Session
---@param force boolean send even when identical to the last snapshot
---@param params table|nil
---@param text string|nil
local function push_context(session, force, params, text)
  if not state or session.closed or not session.initialized or not state.binding:has_stream(session) then
    return false
  end
  if not params then
    local ok, p = pcall(M.build_context, { limit = state.cfg.max_open_files })
    if not ok then
      log.error('cannot build the IDE context: %s', p)
      return false
    end
    params = p
  end
  text = text or vim.json.encode(params)
  local sd = sdata(session)
  if not force and sd.last_context == text then
    return false
  end
  if send_checked(session, 'ide/contextUpdate', params) then
    sd.last_context = text
    return true
  end
  return false
end

---Send the current context to every session with an open stream (unchanged snapshots are skipped).
---@return integer sent
function M.broadcast_context()
  if not state then
    return 0
  end
  local ok, params = pcall(M.build_context, { limit = state.cfg.max_open_files })
  if not ok then
    log.error('cannot build the IDE context: %s', params)
    return 0
  end
  local text = vim.json.encode(params)
  local n = 0
  for _, s in ipairs(state.binding:sessions()) do
    if push_context(s, false, params, text) then
      n = n + 1
    end
  end
  return n
end

local function schedule_context()
  if state and state.debounced then
    state.debounced()
  end
end

-- ---------------------------------------------------------------------------
-- Diffs
-- ---------------------------------------------------------------------------

---@param entry table
local function forget(entry)
  if not state then
    return
  end
  if state.diffs[entry.id] == entry then
    state.diffs[entry.id] = nil
  end
  local sd = entry.session.data.gemini
  if sd and sd.diffs[entry.file_path] == entry then
    sd.diffs[entry.file_path] = nil
  end
end

---Close a diff without telling Gemini (closeDiff, silent replace, disconnect, stop).
---@param entry table
---@return string|nil content  the proposal text including the user's edits
local function close_silently(entry)
  entry.done = true
  forget(entry)
  return diff.close(entry.id)
end

---Deliver a diff decision: to the session that opened the diff; if that session cannot receive
---it, to the other connected sessions that have no diff of their own for the same path (a
---reconnected Gemini keeps its pending resolver). Returns the number of sessions reached.
---@param entry table
---@param method string
---@param params table
---@return integer
local function deliver(entry, method, params)
  if not state then
    return 0
  end
  local origin = entry.session
  if not origin.closed and state.binding:has_stream(origin) and send_checked(origin, method, params) then
    return 1
  end
  local n = 0
  for _, s in ipairs(state.binding:sessions()) do
    if s ~= origin and state.binding:has_stream(s) and not sdata(s).diffs[entry.file_path] then
      if send_checked(s, method, params) then
        n = n + 1
      end
    end
  end
  if n == 0 then
    log.warn('Gemini is not connected: the decision on %s was not delivered (answer in the Gemini terminal)',
      entry.file_path)
  end
  return n
end

---@param entry table
---@param res agent.DiffResult
local function on_resolved(entry, res)
  if entry.done then
    return
  end
  entry.done = true
  forget(entry)
  -- 'replaced'/'disconnect': not a user decision (Neovim is exiting, or the id was reused).
  if res.trigger == 'replaced' or res.trigger == 'disconnect' then
    return
  end
  if res.status == 'accepted' then
    local content = res.content
    if type(content) ~= 'string' or content == '' then
      -- Gemini writes the model's proposal for an empty content anyway.
      content = entry.new_content
    end
    deliver(entry, 'ide/diffAccepted', { filePath = entry.file_path, content = utf8_clean(content) })
  else
    deliver(entry, 'ide/diffRejected', { filePath = entry.file_path })
  end
end

---A diff id that no other diff (of any provider) uses: the path itself when possible.
---@param file_path string
---@return string
local function unique_id(file_path)
  if not diff.is_open(file_path) then
    return file_path
  end
  local n = 2
  while diff.is_open(file_path .. ' #' .. n) do
    n = n + 1
  end
  return file_path .. ' #' .. n
end

---@param session agent.mcp.Session
---@param file_path string  exactly as Gemini sent it
---@param new_content string
local function open_diff(session, file_path, new_content)
  local sd = sdata(session)
  local old = sd.diffs[file_path]
  if old then
    -- Same session, same path: replace silently (no ide/diffRejected).
    close_silently(old)
  end
  local entry = {
    id = unique_id(file_path),
    file_path = file_path,
    new_content = new_content,
    session = session,
    done = false,
  }
  sd.diffs[file_path] = entry
  state.diffs[entry.id] = entry
  local ok, err = diff.open({
    id = entry.id,
    path = file_path,
    new_contents = new_content,
    title = vim.fn.fnamemodify(file_path, ':~:.') .. ' (Gemini)',
    owner = 'gemini:' .. session.id,
    editable = true,
    focus = state.cfg.focus_diff ~= false,
    accept_empty = false,
    on_resolve = function(res)
      on_resolved(entry, res)
    end,
  })
  if not ok then
    -- Not fatal for the edit: Gemini's own prompt still decides (an isError would fail the tool).
    entry.done = true
    forget(entry)
    log.warn('cannot open a diff for %s: %s', file_path, tostring(err))
  end
end

---Find the diff closeDiff refers to: the session's own, else one for the same path left behind by
---a session that is gone or has no stream (Gemini reconnected with a new session).
---@param session agent.mcp.Session
---@param file_path string
---@return table|nil
local function find_diff(session, file_path)
  local own = sdata(session).diffs[file_path]
  if own then
    return own
  end
  for _, entry in pairs(state.diffs) do
    if entry.file_path == file_path and entry.session ~= session
      and (entry.session.closed or not state.binding:has_stream(entry.session)) then
      return entry
    end
  end
  return nil
end

---@param session agent.mcp.Session
---@param why string|nil  shown to the user when set
local function close_session_diffs(session, why)
  if not state then
    return
  end
  local closed = {}
  for _, entry in pairs(vim.tbl_values(sdata(session).diffs)) do
    close_silently(entry)
    closed[#closed + 1] = entry.file_path
  end
  if why and #closed > 0 then
    require('agent.log').notify(why .. ': closed the diff for ' .. table.concat(closed, ', '), vim.log.levels.INFO)
  end
end

-- ---------------------------------------------------------------------------
-- Tools
-- ---------------------------------------------------------------------------

local function add_tools(srv)
  srv:add_tool({
    name = 'openDiff',
    description = '(IDE Tool) Open a diff view to create or modify a file. Returns a notification once the diff has been accepted or rejected.',
    inputSchema = {
      type = 'object',
      properties = { filePath = { type = 'string' }, newContent = { type = 'string' } },
      required = { 'filePath', 'newContent' },
    },
    handler = function(args, ctx)
      if type(args.filePath) ~= 'string' or args.filePath == '' then
        error(McpServer.rpc_error(McpServer.INVALID_PARAMS, 'Invalid params: filePath must be a non-empty string'))
      end
      if type(args.newContent) ~= 'string' then
        error(McpServer.rpc_error(McpServer.INVALID_PARAMS, 'Invalid params: newContent must be a string'))
      end
      open_diff(ctx.session, args.filePath, args.newContent)
      return { content = {} }
    end,
  })
  srv:add_tool({
    name = 'closeDiff',
    description = '(IDE Tool) Close an open diff view for a specific file.',
    inputSchema = {
      type = 'object',
      properties = { filePath = { type = 'string' }, suppressNotification = { type = 'boolean' } },
      required = { 'filePath' },
    },
    handler = function(args, ctx)
      if type(args.filePath) ~= 'string' then
        error(McpServer.rpc_error(McpServer.INVALID_PARAMS, 'Invalid params: filePath must be a string'))
      end
      -- suppressNotification is deprecated and irrelevant: a closeDiff never sends a notification.
      local entry = find_diff(ctx.session, args.filePath)
      local content = entry and close_silently(entry) or nil
      local text = '{}'
      if type(content) == 'string' then
        text = vim.json.encode({ content = utf8_clean(content) })
      end
      return { content = { { type = 'text', text = text } } }
    end,
  })
end

-- ---------------------------------------------------------------------------
-- Discovery file and workspace folders
-- ---------------------------------------------------------------------------

---Workspace entry as written into workspacePath, or nil when it cannot be listed. The path is
---written verbatim: Gemini URI-decodes each part AND its own cwd (resolveToRealPath on both sides
---of validateWorkspacePath), so escaping '%' would break the match in a dir such as "a%20b".
---@param path string
---@return string|nil
local function workspace_entry(path)
  if path == '' or path:find(DELIMITER, 1, true) or path:find('%z') then
    return nil
  end
  return path
end

---@param path string|nil
---@return boolean changed
local function add_workspace(path)
  if not state or not path or path == '' then
    return false
  end
  local real = util.realpath(path)
  for _, w in ipairs(state.workspaces) do
    if w == real then
      return false
    end
  end
  if not workspace_entry(real) then
    if not state.unlisted[real] then
      state.unlisted[real] = true
      log.warn('cannot list %s as a Gemini workspace folder (it contains %q)', real, DELIMITER)
    end
    return false
  end
  table.insert(state.workspaces, real)
  while #state.workspaces > M.MAX_WORKSPACES do
    table.remove(state.workspaces, 1)
  end
  return true
end

---@return string
local function discovery_json()
  local parts = {}
  for _, w in ipairs(state.workspaces) do
    local e = workspace_entry(w)
    if e then
      parts[#parts + 1] = e
    end
  end
  return vim.json.encode({
    port = state.port,
    workspacePath = table.concat(parts, DELIMITER),
    authToken = state.token,
    ideInfo = { name = M.IDE_INFO.name, displayName = M.IDE_INFO.displayName },
  })
end

---@param dir string
---@return string
local function discovery_path(dir)
  return vim.fs.joinpath(dir, string.format('gemini-ide-server-%d-%d.json', state.pid, state.port))
end

---(Re)write the discovery file in `dir` (and remember it for removal).
---@param dir string
---@return boolean ok, string|nil err
local function write_discovery(dir)
  local ok, err = ensure_dir(dir)
  if not ok then
    return false, err
  end
  local path = discovery_path(dir)
  local wok, werr = util.atomic_write(path, discovery_json(), tonumber('600', 8))
  if not wok then
    return false, werr
  end
  state.files[path] = true
  return true, nil
end

---Rewrite every discovery file we own (after a workspace change).
local function rewrite_all()
  for path in pairs(state.files) do
    local ok, err = write_discovery(vim.fs.dirname(path))
    if not ok then
      log.warn('cannot write %s: %s', path, tostring(err))
    end
  end
end

---Remove discovery files of dead Neovims (owned by us, ideInfo.name == 'neovim') and our own
---leftovers. Files of other IDEs and of live processes are never touched.
---@param dir string
---@return integer removed
function M.cleanup_stale(dir)
  local removed = 0
  local handle = uv.fs_scandir(dir)
  if not handle then
    return 0
  end
  local uid, me = uv.getuid(), uv.os_getpid()
  while true do
    local name, typ = uv.fs_scandir_next(handle)
    if not name then
      break
    end
    local pid = name:match(M.FILE_PATTERN)
    pid = pid and tonumber(pid)
    if pid and (typ == 'file' or typ == nil) then
      local path = vim.fs.joinpath(dir, name)
      local st = uv.fs_stat(path)
      local current = state and state.files[path]
      if st and st.uid == uid and not current and (pid == me or not pid_alive(pid)) then
        local ok, data = pcall(vim.json.decode, read_file(path) or '')
        if ok and type(data) == 'table' and type(data.ideInfo) == 'table' and data.ideInfo.name == M.IDE_INFO.name then
          if uv.fs_unlink(path) then
            removed = removed + 1
          end
        end
      end
    end
  end
  return removed
end

---tmpdir of a child whose environment is `spec.env` over this Neovim's (Node's os.tmpdir()).
---@param spec table
---@return string
local function child_tmpdir(spec)
  local env = spec.env or {}
  local function get(k)
    local v = env[k]
    if v == false then
      return nil
    end
    if v == nil and not spec.clear_env then
      v = vim.env[k]
    end
    if v == '' then
      return nil
    end
    return v
  end
  local t = get('TMPDIR') or get('TMP') or get('TEMP') or '/tmp'
  if #t > 1 and t:sub(-1) == '/' then
    t = t:sub(1, -2)
  end
  return t
end

-- ---------------------------------------------------------------------------
-- Environment export (opt-in)
-- ---------------------------------------------------------------------------

local EXPORTED = { 'GEMINI_CLI_IDE_PID', 'GEMINI_CLI_IDE_SERVER_PORT', 'GEMINI_CLI_IDE_AUTH_TOKEN' }

local function export_env()
  state.saved_env = {}
  for _, k in ipairs(EXPORTED) do
    state.saved_env[k] = vim.env[k] or false
  end
  vim.env.GEMINI_CLI_IDE_PID = tostring(state.pid)
  vim.env.GEMINI_CLI_IDE_SERVER_PORT = tostring(state.port)
  vim.env.GEMINI_CLI_IDE_AUTH_TOKEN = state.token
end

local function restore_env(st)
  for k, v in pairs(st.saved_env or {}) do
    vim.env[k] = v ~= false and v or nil
  end
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

local GROUP = 'AgentGeminiProvider'

---@param requested string|nil
---@return string
local function negotiate(requested)
  return McpServer.negotiate_version(requested, M.PROTOCOL_VERSIONS, M.DEFAULT_PROTOCOL_VERSION)
end

---Start the companion server and write the discovery file (idempotent).
---@param opts table|nil  overrides of config.providers.gemini (see M.defaults)
---@return boolean ok, string|nil err
function M.start(opts)
  if state then
    return true, nil
  end
  local cfg = options(opts)
  local dir = cfg.discovery_dir or M.default_discovery_dir()
  local ok, err = ensure_dir(dir)
  if not ok then
    return false, 'gemini: ' .. tostring(err)
  end

  local token = last_token or util.random_hex(24)
  local st = {
    cfg = cfg,
    dir = dir,
    token = token,
    pid = vim.fn.getpid(),
    workspaces = {},
    unlisted = {},
    files = {},
    diffs = {},
    orphan_timers = {},
  }

  local srv = McpServer.new({
    name = M.SERVER_NAME,
    version = M.VERSION,
    protocol_version = function(requested)
      return negotiate(requested)
    end,
    capabilities = { tools = { listChanged = false }, logging = vim.empty_dict() },
    on_session_close = function(session)
      close_session_diffs(session)
    end,
  })
  add_tools(srv)
  -- Declared by the logging capability; accepted and ignored.
  srv:add_method('logging/setLevel', function()
    return vim.empty_dict()
  end)

  local binding
  local function allowed_hosts()
    return { '127.0.0.1:' .. binding.port, 'localhost:' .. binding.port }
  end
  local bopts = {
    path = '/mcp',
    authorize = streamable.all({
      streamable.check_host(allowed_hosts),
      streamable.check_origin(),
      streamable.check_authorization('Bearer ' .. token),
    }),
    allow_delete = false,
    response_mode = 'auto',
    sse_keepalive_ms = cfg.keepalive_ms,
    second_stream = 'replace',
    missing_session_status = 400,
    unknown_session_status = 400,
    idle_session_timeout_ms = cfg.idle_session_timeout_ms,
    on_stream_open = function(session)
      local timer = st.orphan_timers[session]
      if timer then
        st.orphan_timers[session] = nil
        timer:stop()
        timer:close()
      end
      if state == st then
        push_context(session, true)
      end
    end,
    on_stream_close = function(session)
      if state ~= st or session.closed or st.orphan_timers[session] then
        return
      end
      local timer = uv.new_timer()
      st.orphan_timers[session] = timer
      timer:start(cfg.orphan_grace_ms, 0, vim.schedule_wrap(function()
        if st.orphan_timers[session] == timer then
          st.orphan_timers[session] = nil
          timer:close()
        end
        if state == st and not session.closed and not binding:has_stream(session) then
          close_session_diffs(session, 'Gemini disconnected')
        end
      end))
    end,
  }
  local port = cfg.port ~= 0 and cfg.port or last_port or 0
  binding, err = streamable.attach({ tcp = { host = '127.0.0.1', port = port } }, srv, bopts)
  if not binding and port ~= 0 and cfg.port == 0 then
    binding, err = streamable.attach({ tcp = { host = '127.0.0.1', port = 0 } }, srv, bopts)
  end
  if not binding then
    return false, 'gemini: ' .. tostring(err)
  end
  st.server, st.binding, st.port = srv, binding, binding.port
  state = st
  last_port, last_token = st.port, token

  add_workspace(vim.fn.getcwd(-1, -1))
  M.cleanup_stale(dir)
  ok, err = write_discovery(dir)
  if not ok then
    M.stop()
    return false, 'gemini: cannot write the discovery file: ' .. tostring(err)
  end
  st.discovery_file = discovery_path(dir)

  st.debounced, st.cancel_debounce = util.debounce(cfg.context_debounce_ms, function()
    if state == st then
      M.broadcast_context()
    end
  end)
  if track_selection() then
    selection.start()
    st.unsubscribe = selection.subscribe(function()
      schedule_context()
    end, { files = true })
  end
  local group = api.nvim_create_augroup(GROUP, { clear = true })
  api.nvim_create_autocmd('DirChanged', {
    group = group,
    callback = function()
      if state == st and add_workspace(vim.fn.getcwd(-1, -1)) then
        rewrite_all()
      end
    end,
  })
  api.nvim_create_autocmd('VimLeavePre', {
    group = group,
    callback = function()
      M.stop()
    end,
  })
  if cfg.export_env then
    export_env()
  end
  log.debug('listening on 127.0.0.1:%d; discovery file %s', st.port, st.discovery_file)
  return true, nil
end

---Stop: close diffs silently (Gemini's own prompt still decides), end the SSE streams gracefully,
---close the listener, remove the discovery files.
function M.stop()
  local st = state
  if not st then
    return
  end
  state = nil
  pcall(api.nvim_del_augroup_by_name, GROUP)
  if st.unsubscribe then
    st.unsubscribe()
  end
  if st.cancel_debounce then
    st.cancel_debounce()
  end
  for session, timer in pairs(st.orphan_timers) do
    st.orphan_timers[session] = nil
    timer:stop()
    if not timer:is_closing() then
      timer:close()
    end
  end
  for _, entry in pairs(vim.tbl_values(st.diffs)) do
    entry.done = true
    st.diffs[entry.id] = nil
    diff.close(entry.id)
  end
  st.binding:close()
  for path in pairs(st.files) do
    util.remove(path)
  end
  restore_env(st)
end

---@return boolean
function M.is_running()
  return state ~= nil
end

---Environment for a gemini job (all four GEMINI_CLI_IDE_* connection variables; the stdio
---fallback is disabled with ""). Empty when the provider is not running.
---@param opts { cwd?: string }|nil
---@return table<string, string>
function M.env(opts)
  if not state then
    return {}
  end
  return {
    GEMINI_CLI_IDE_PID = tostring(state.pid),
    GEMINI_CLI_IDE_SERVER_PORT = tostring(state.port),
    GEMINI_CLI_IDE_AUTH_TOKEN = state.token,
    GEMINI_CLI_IDE_WORKSPACE_PATH = util.realpath(opts and opts.cwd or vim.fn.getcwd()),
    GEMINI_CLI_IDE_SERVER_STDIO_COMMAND = '',
  }
end

---What agents.build_launch expects in opts.ide. Starts the server if needed and adds `opts.cwd`
---(default: the current directory) to the discovery file's workspacePath, so Gemini's workspace
---check passes.
---@param opts { cwd?: string }|nil
---@return { port: integer, token: string, pid: integer, workspace: string, discovery_file: string }|nil info, string|nil err
function M.launch_info(opts)
  local ok, err = M.start()
  if not ok then
    return nil, err
  end
  local cwd = util.realpath(opts and opts.cwd or vim.fn.getcwd())
  if add_workspace(cwd) then
    rewrite_all()
  end
  return {
    port = state.port,
    token = state.token,
    pid = state.pid,
    workspace = cwd,
    discovery_file = state.discovery_file,
  }
end

---Whether Gemini's effective `ide.enabled` is on (read-only, via agent.gemini_setup).
---@param opts { environ?: table }|nil
---@return boolean enabled, string|nil source
function M.ide_enabled(opts)
  local ok, enabled, source = pcall(require('agent.gemini_setup').ide_enabled, opts)
  if not ok then
    return true, nil -- unreadable settings: do not nag
  end
  return enabled, source
end

---Hook for agents.build_launch's before_spawn: make sure the job's cwd is in workspacePath, the
---discovery file still exists (tmp cleaners), and there is one in the child's tmpdir when its
---TMPDIR differs from ours. Shows the one-time "run /ide enable" hint unless the launcher did.
---@param spec table  agent.LaunchSpec
function M.before_spawn(spec)
  if not state or type(spec) ~= 'table' then
    return
  end
  local changed = spec.cwd and add_workspace(spec.cwd) or false
  local missing = not uv.fs_stat(state.discovery_file)
  if changed or missing then
    rewrite_all()
  end
  if not state.cfg.discovery_dir then
    local dir = M.default_discovery_dir(child_tmpdir(spec))
    if dir ~= state.dir and not state.files[discovery_path(dir)] then
      local ok, err = write_discovery(dir)
      if not ok then
        log.warn('cannot write a discovery file for TMPDIR=%s: %s', vim.fs.dirname(vim.fs.dirname(dir)), tostring(err))
      end
    end
  end
  local warned = false
  for _, w in ipairs(spec.warnings or {}) do
    if w.id == 'gemini-ide-disabled' then
      warned = true
    end
  end
  local environ = vim.fn.environ()
  for k, v in pairs(spec.env or {}) do
    environ[k] = v ~= false and v or nil
  end
  local off = warned or not M.ide_enabled({ environ = environ })
  state.ide_off, state.ide_environ = off, environ
  if off and not warned and not ide_hint_shown then
    require('agent.log').notify('gemini: IDE mode is off in your Gemini settings. Run /ide enable once in Gemini to connect it to Neovim.',
      vim.log.levels.INFO)
  end
  if off then
    ide_hint_shown = true
  end
end

---Type `/ide enable` into the agent terminal when it runs Gemini (Gemini then persists
---ide.enabled=true itself).
---@return boolean ok, string|nil err
function M.enable_ide_mode()
  local term = require('agent.terminal')
  local def = term.is_running() and require('agent.agents').get(term.name())
  if not def or def.kind ~= 'gemini' then
    return false, 'gemini is not running'
  end
  return term.send('/ide enable', { submit = true })
end

---@return { running: boolean, clients: integer, streams: integer, address: string|nil, lock: string|nil, port: integer|nil, workspaces: string[], diffs: integer, ide_enabled: boolean }
function M.status()
  if not state then
    return { running = false, clients = 0, streams = 0, workspaces = {}, diffs = 0, ide_enabled = M.ide_enabled() }
  end
  local clients, streams = 0, 0
  for _, s in ipairs(state.binding:sessions()) do
    clients = clients + 1
    if state.binding:has_stream(s) then
      streams = streams + 1
    end
  end
  return {
    running = true,
    clients = clients,
    streams = streams,
    address = '127.0.0.1:' .. state.port,
    lock = state.discovery_file,
    port = state.port,
    workspaces = vim.deepcopy(state.workspaces),
    diffs = vim.tbl_count(state.diffs),
    ide_enabled = M.ide_enabled(),
  }
end

---The state of Gemini's IDE client: 'ready' (its event stream is open, so it takes a context update
---now), 'connecting' (a session without a stream yet), or nil.
---@return 'ready'|'connecting'|nil
function M.client_state()
  if not state then
    return nil
  end
  local any = false
  for _, s in ipairs(state.binding:sessions()) do
    if state.binding:has_stream(s) then
      return 'ready'
    end
    any = true
  end
  return any and 'connecting' or nil
end

---Send the selection :AgentSend captured to every Gemini connected (there is one per agent
---terminal): an ide/contextUpdate with it as the active file (a buffer that is not a file by its
---nvim://buffer/ id), its cursor and its text; with selection.track = true the recently focused
---files follow. It stays in every later update, and in the one each new stream gets, until the next
---:AgentSend or, with selection.track = true, the next selection event.
---@param s agent.Selection
---@return boolean sent  a Gemini with an open stream has it now
function M.send_context(s, opts)
  if not state or not s or type(s.path) ~= 'string' or s.path == '' then
    return false
  end
  state.context = selection.entry_of(s, M.MAX_SELECTED_TEXT)
  state.context_pid = opts and opts.pid
  local ok, params = pcall(M.build_context, { limit = state.cfg.max_open_files })
  if not ok then
    log.error('cannot build the IDE context: %s', params)
    return false
  end
  local text = vim.json.encode(params)
  local sent = false
  for _, session in ipairs(state.binding:sessions()) do
    if state.binding:has_stream(session) then
      local sd = sdata(session)
      if sd.last_context == text or push_context(session, false, params, text) then
        sent = true
      end
    end
  end
  return sent
end

---Forget what :AgentSend sent to the Gemini of the agent terminal with this job pid (it has ended),
---and update the other connected Geminis, if any.
---@param pid integer|nil
function M.clear_context(pid)
  if state and state.context and state.context_pid == pid then
    state.context, state.context_pid = nil, nil
    schedule_context()
  end
end

---Gemini's IDE mode was off in its settings when agent.nvim last launched it, and still is (then it
---never connects: :AgentSend types the reference instead). /ide enable turns it on in the settings.
---@return boolean
function M.ide_mode_off()
  if not state or not state.ide_off then
    return false
  end
  if M.ide_enabled({ environ = state.ide_environ }) then
    state.ide_off = false
  end
  return state.ide_off
end

---Selection events from init (coalesced with the provider's own subscription and debounced). They
---replace what :AgentSend sent.
---@param _ agent.Selection|nil
function M.on_selection(_)
  if state then
    state.context = nil
  end
  schedule_context()
end

---Internal state, for tests.
---@return table|nil
function M._state()
  return state
end

---Forget the remembered port/token and hint flag (tests).
function M._reset()
  M.stop()
  last_port, last_token, ide_hint_shown = nil, nil, false
end

return M
