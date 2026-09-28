---@mod agent.providers.claude Claude IDE protocol server (serves Claude Code and OpenCode)
---
--- Neovim listens on 127.0.0.1 (WebSocket, subprotocol `mcp`, header token
--- `X-Claude-Code-Ide-Authorization`) and advertises itself with `<lock_dir>/<port>.lock`.
--- Claude Code finds the lock through CLAUDE_CODE_SSE_PORT; OpenCode scans ~/.claude/ide and picks
--- the lock whose workspaceFolders contain its directory (claude-opencode.md §2, §9).
---
--- The port and token stay the same for the whole Neovim session: Claude reconnects to the same
--- URL and token after a drop, and a stop()/start() rebinds the same port (§7.2).
---
--- Each connection is an MCP session. The client kind comes from initialize.params.clientInfo.name:
--- 'opencode' gets 1-based lines (config.agents.opencode.line_offset) and immediate notifications;
--- everything else is treated as Claude Code: 0-based lines, notifications only after a short
--- delay once the connection is complete (Claude registers its handlers late, §6.3).
local uv = vim.uv or vim.loop
local config = require('agent.config')
local util = require('agent.util')
local log = require('agent.log').scope('claude')
local websocket = require('agent.net.websocket')
local common = require('agent.net.common')
local McpServer = require('agent.mcp.server')
local context = require('agent.editor.context')
local diff = require('agent.editor.diff')

local M = {}

M.IDE_NAME = 'Neovim'
M.SERVER_NAME = 'agent-nvim'
M.SERVER_VERSION = '0.1.0'
M.AUTH_HEADER = 'X-Claude-Code-Ide-Authorization'
--- Echoed when requested; anything else is answered with the fallback (Claude accepts it, §4.3).
M.PROTOCOL_VERSIONS = { '2025-11-25', '2025-06-18', '2025-03-26', '2024-11-05' }
M.FALLBACK_PROTOCOL_VERSION = '2024-11-05'
--- Delay between a Claude Code connection completing and the first notification (§6.3).
M.DEFAULT_NOTIFY_DELAY_MS = 600
M.DEFAULT_PORT_RANGE = { min = 10000, max = 65535 }

local SCHEMA = 'http://json-schema.org/draft-07/schema#'
local LOOPBACK = { 'localhost', '127.0.0.1', '::1' }

local state = {
  port = nil, ---@type integer|nil  kept across stop()/start()
  token = nil, ---@type string|nil  kept across stop()/start()
  ws = nil, ---@type agent.ws.Server|nil
  srv = nil, ---@type agent.mcp.Server|nil
  lock_path = nil, ---@type string|nil
  lock_json = nil, ---@type string|nil
  job_folders = {}, ---@type string[]  the launched agent's cwd: literal path and realpath
  diffs = {}, ---@type table<string, table>  tab_name -> pending openDiff
  last_selection = nil, ---@type agent.Selection|nil
  group = nil, ---@type integer|nil
}

-- ---------------------------------------------------------------------------
-- Options
-- ---------------------------------------------------------------------------

---@return table
local function opts()
  local cfg = config.get()
  return (cfg.providers and cfg.providers.claude) or {}
end

---@param key string
---@param default integer
---@return integer
local function opt_number(key, default)
  local v = opts()[key]
  return type(v) == 'number' and v or default
end

---config.selection.track: with false, no selection is pushed to clients (not even on connect).
---@return boolean
local function tracking()
  local sel = config.get().selection
  return not (type(sel) == 'table' and sel.track == false)
end

---Lines (and columns) sent to OpenCode are shifted by this much (claude-opencode.md §9.5-9.6, §10).
---@return integer
local function opencode_offset()
  local cfg = config.get()
  local oc = cfg.agents and cfg.agents.opencode
  local off = oc and oc.line_offset
  return type(off) == 'number' and off or 1
end

---The directory the lock file is written to: providers.claude.lock_dir, else ~/.claude/ide (the only
---directory OpenCode scans; Claude Code 2.1.x scans it even when CLAUDE_CONFIG_DIR is set, §2.1).
---@return string
function M.lock_dir()
  local dir = opts().lock_dir
  if type(dir) == 'string' and dir ~= '' then
    return util.abspath(dir)
  end
  return vim.fs.joinpath(util.home(), '.claude', 'ide')
end

-- ---------------------------------------------------------------------------
-- Small helpers
-- ---------------------------------------------------------------------------

local function text_item(s)
  return { type = 'text', text = s }
end

local function json_text(value)
  return { content = { text_item(vim.json.encode(value)) } }
end

---`s` with every byte that is not part of a valid UTF-8 sequence replaced by U+FFFD. Buffers and
---file names can hold any bytes (`++bin`, a failed 'fileencoding' conversion) and vim.json.encode
---passes them through, but a text frame must be valid UTF-8 or the client fails the connection
---(RFC 6455 §8.1). JSON's own syntax is ASCII, so repairing the encoded text is enough.
---@param s string
---@return string
local function utf8_safe(s)
  if common.valid_utf8(s) then
    return s
  end
  local out, i = {}, 1
  while true do
    local j = s:find('[\128-\255]', i)
    if not j then
      out[#out + 1] = s:sub(i)
      break
    end
    out[#out + 1] = s:sub(i, j - 1)
    local c = s:byte(j)
    local len = c >= 0xF0 and 4 or c >= 0xE0 and 3 or 2
    local seq = s:sub(j, j + len - 1)
    if c >= 0xC2 and c <= 0xF4 and common.valid_utf8(seq) then
      out[#out + 1] = seq
      i = j + len
    else
      out[#out + 1] = '\239\191\189'
      i = j + 1
    end
  end
  return table.concat(out)
end

---Expand a leading `~` only (vim.fn.expand would also touch `$name` in paths).
---@param path string
---@return string
local function expand_tilde(path)
  if path == '~' then
    return util.home()
  end
  if path:sub(1, 2) == '~/' then
    return util.home() .. path:sub(2)
  end
  return path
end

---@param path string
---@return string
local function abs_path(path)
  return util.abspath(expand_tilde(path))
end

---@param pid integer
---@return boolean
local function pid_alive(pid)
  local ok, res, _, name = pcall(uv.kill, pid, 0)
  if not ok or res == 0 then
    return true
  end
  return name ~= 'ESRCH'
end

---no_proxy with the loopback addresses appended (both casings are honored by Claude's proxy code).
---@return string
local function no_proxy_value()
  local parts, seen = {}, {}
  for _, v in ipairs({ vim.env.no_proxy or '', vim.env.NO_PROXY or '' }) do
    for item in v:gmatch('[^,%s]+') do
      if not seen[item] then
        seen[item] = true
        parts[#parts + 1] = item
      end
    end
  end
  for _, item in ipairs(LOOPBACK) do
    if not seen[item] then
      seen[item] = true
      parts[#parts + 1] = item
    end
  end
  return table.concat(parts, ',')
end

-- ---------------------------------------------------------------------------
-- Lock file
-- ---------------------------------------------------------------------------

---Folders for the lock's workspaceFolders: the literal cwd, its realpath, the LSP workspace folders,
---then the cwd of the agent we launched (OpenCode compares its physical cwd without realpath, §2.3).
---@return string[]
local function workspace_folders()
  local out, seen = {}, {}
  local function add(p)
    if p and p ~= '' and not seen[p] then
      seen[p] = true
      out[#out + 1] = p
    end
  end
  add(util.abspath(vim.fn.getcwd()))
  local ok, folders = pcall(context.workspace_folders)
  if ok then
    for _, f in ipairs(folders) do
      add(f)
    end
  end
  for _, f in ipairs(state.job_folders) do
    add(f)
  end
  return out
end

---Write (or rewrite) the lock atomically. Unchanged content is not rewritten unless `touch`.
---@param touch boolean|nil  rewrite even if unchanged (new mtime; OpenCode prefers the newest lock)
---@return boolean ok, string|nil err
local function write_lock(touch)
  if not state.ws then
    return false, 'not running'
  end
  local dir = M.lock_dir()
  local ok, err = util.mkdir_p(dir, tonumber('700', 8))
  if not ok then
    return false, err
  end
  local path = vim.fs.joinpath(dir, tostring(state.port) .. '.lock')
  local data = util.json_encode({
    pid = vim.fn.getpid(),
    workspaceFolders = workspace_folders(),
    ideName = M.IDE_NAME,
    transport = 'ws',
    authToken = state.token,
  })
  if not touch and path == state.lock_path and data == state.lock_json and uv.fs_stat(path) then
    return true, nil
  end
  if state.lock_path and state.lock_path ~= path then
    util.remove(state.lock_path)
  end
  ok, err = util.atomic_write(path, data, tonumber('600', 8))
  if not ok then
    return false, err
  end
  state.lock_path, state.lock_json = path, data
  return true, nil
end

---Delete locks left behind by crashed Neovims: ideName "Neovim" and a dead pid. Other IDEs' locks
---are never touched (§2.5).
---@param dir string
local function remove_stale_locks(dir)
  local handle = uv.fs_scandir(dir)
  if not handle then
    return
  end
  local me = vim.fn.getpid()
  while true do
    local name = uv.fs_scandir_next(handle)
    if not name then
      break
    end
    if name:match('^%d+%.lock$') then
      local path = vim.fs.joinpath(dir, name)
      local f = io.open(path, 'rb')
      local data = f and f:read('*a')
      if f then
        f:close()
      end
      local ok, lock = util.json_decode(data or '')
      if ok and type(lock) == 'table' and lock.ideName == M.IDE_NAME and type(lock.pid) == 'number'
        and lock.pid ~= me and not pid_alive(lock.pid) then
        log.debug('removing stale lock %s (pid %d)', path, lock.pid)
        util.remove(path)
      end
    end
  end
end

---Set the launched agent's cwd (literal path and realpath). One agent runs at a time: a new
---launch replaces the previous agent's folder.
---@param cwd string|nil
local function set_job_folder(cwd)
  if type(cwd) ~= 'string' or cwd == '' then
    return
  end
  local folders = {}
  for _, p in ipairs({ util.abspath(cwd), util.realpath(cwd) }) do
    if not vim.tbl_contains(folders, p) then
      folders[#folders + 1] = p
    end
  end
  local changed = not vim.deep_equal(folders, state.job_folders)
  state.job_folders = folders
  if changed and state.ws then
    local ok, err = write_lock()
    if not ok then
      log.warn('could not update the lock file: %s', err)
    end
  end
end

-- ---------------------------------------------------------------------------
-- Notifications (per-client rendering, §10)
-- ---------------------------------------------------------------------------

---@param s agent.Selection
---@param kind 'claude'|'opencode'
---@return table params
local function render_selection(s, kind)
  local start = { line = s.start.line, character = s.start.character }
  local finish = { line = s.finish.line, character = s.finish.character }
  if kind == 'opencode' then
    local off = opencode_offset()
    start.line, start.character = start.line + off, start.character + off
    finish.line, finish.character = finish.line + off, finish.character + off
  elseif not s.is_empty and finish.character == 0 and finish.line >= start.line then
    -- Claude treats an end at column 0 as exclusive and would drop the (empty) last line.
    finish = { line = finish.line + 1, character = 0 }
  end
  return {
    text = s.text or '',
    filePath = s.path,
    -- A buffer that is not a file (a terminal) goes by its nvim://buffer/<n>/<label> id in both
    -- (Claude shows the basename: "In fish"); the agent reads it with the controller's read_buffer.
    fileUrl = context.is_buffer_uri(s.path) and s.path or util.file_url(s.path),
    selection = { start = start, ['end'] = finish, isEmpty = s.is_empty and true or false },
  }
end

---@param session agent.mcp.Session
---@param s agent.Selection|nil
local function notify_selection(session, s)
  if not s or not s.path or not s.start or not s.finish then
    return
  end
  local params = render_selection(s, session.data.kind)
  local key = vim.json.encode(params)
  if key == session.data.sel_key then
    return
  end
  if session:notify('selection_changed', params) then
    session.data.sel_key = key
  end
end

---Open sessions that completed initialize and are ready for notifications.
---@return agent.mcp.Session[]
local function ready_sessions()
  local out = {}
  if not state.srv then
    return out
  end
  for _, s in ipairs(state.srv:sessions()) do
    if not s.closed and s.initialized and s.data.ready then
      out[#out + 1] = s
    end
  end
  return out
end

---The selection to send to a client that just became ready.
---@return agent.Selection|nil
local function current_selection()
  local ok, sel = pcall(require, 'agent.editor.selection')
  if ok then
    local cok, s = pcall(sel.current)
    if cok and s then
      return s
    end
  end
  return state.last_selection
end

---The client can take notifications now: send it the current selection.
---@param session agent.mcp.Session
local function mark_ready(session)
  local data = session.data
  if session.closed or data.ready then
    return
  end
  if data.ready_timer then
    data.ready_timer:stop()
    if not data.ready_timer:is_closing() then
      data.ready_timer:close()
    end
    data.ready_timer = nil
  end
  data.ready = true
  log.debug('session %s (%s) ready for notifications', session.id, tostring(data.client_name))
  if tracking() then
    notify_selection(session, current_selection())
  end
end

---(Re)arm the post-connect delay for a Claude Code client. Every connection-completing message
---(notifications/initialized, ide_connected, tools/list) restarts it, so the delay counts from
---the last of them.
---@param session agent.mcp.Session
local function arm_ready(session)
  local data = session.data
  if session.closed or data.ready or not session.initialized then
    return
  end
  local delay = opt_number('notify_delay_ms', M.DEFAULT_NOTIFY_DELAY_MS)
  if data.ready_timer then
    data.ready_timer:stop()
  else
    data.ready_timer = uv.new_timer()
  end
  data.ready_timer:start(delay, 0, function()
    vim.schedule(function()
      mark_ready(session)
    end)
  end)
end

-- ---------------------------------------------------------------------------
-- Tools (§5)
-- ---------------------------------------------------------------------------

---@param s agent.Selection
---@return table
local function selection_object(s)
  return render_selection(s, 'claude')
end

---@param severity integer
---@return string
local function severity_name(severity)
  return ({ 'Error', 'Warning', 'Info', 'Hint' })[severity] or 'Error'
end

---@param d agent.Diagnostic
---@return table
local function format_diagnostic(d)
  local out = {
    message = d.message,
    severity = severity_name(d.severity),
    range = {
      start = { line = d.range.start.line, character = d.range.start.character },
      ['end'] = { line = d.range['end'].line, character = d.range['end'].character },
    },
  }
  if d.source then
    out.source = d.source
  end
  if d.code ~= nil then
    out.code = tostring(d.code)
  end
  return out
end

---@param list agent.Diagnostic[]
---@return table[]
local function format_diagnostics(list)
  local out = {}
  for i, d in ipairs(list) do
    out[i] = format_diagnostic(d)
  end
  return out
end

---Visually select from (l1, c1) to (l2, c2) (0-based lines, 0-based inclusive byte columns) in
---the current window `win`.
---@param linewise boolean
local function select_range(win, linewise, l1, c1, l2, c2)
  if vim.api.nvim_get_current_win() ~= win then
    return
  end
  local mode = vim.api.nvim_get_mode().mode:sub(1, 1)
  if mode == 'v' or mode == 'V' or mode == '\22' then
    vim.cmd('normal! \27')
  end
  vim.api.nvim_win_set_cursor(win, { l1 + 1, c1 })
  vim.cmd('normal! ' .. (linewise and 'V' or 'v'))
  vim.api.nvim_win_set_cursor(win, { l2 + 1, c2 })
end

local tools = {}

tools[#tools + 1] = {
  name = 'openFile',
  description = 'Open a file in the editor and optionally select a range of text',
  inputSchema = {
    type = 'object',
    properties = {
      filePath = { type = 'string', description = 'Path to the file to open' },
      preview = { type = 'boolean', description = 'Whether to open the file in preview mode', default = false },
      startLine = { type = 'integer', description = 'Optional: Line number to start selection' },
      endLine = { type = 'integer', description = 'Optional: Line number to end selection' },
      startText = {
        type = 'string',
        description = 'Text pattern to find the start of the selection range. Selects from the beginning of this match.',
      },
      endText = {
        type = 'string',
        description = 'Text pattern to find the end of the selection range. Selects up to the end of this match. '
          .. 'If not provided, only the startText match will be selected.',
      },
      selectToEndOfLine = {
        type = 'boolean',
        description = 'If true, selection will extend to the end of the line containing the endText match.',
        default = false,
      },
      makeFrontmost = {
        type = 'boolean',
        description = 'Whether to make the file the active editor tab. If false, the file will be opened in the '
          .. 'background without changing focus.',
        default = true,
      },
    },
    required = { 'filePath' },
    additionalProperties = false,
    ['$schema'] = SCHEMA,
  },
  handler = function(args)
    if type(args.filePath) ~= 'string' or args.filePath == '' then
      error(McpServer.rpc_error(McpServer.INVALID_PARAMS, 'Invalid params', 'Missing filePath parameter'))
    end
    local path = abs_path(args.filePath)
    if not context.file_exists(path) then
      error(McpServer.rpc_error(-32000, 'File operation error', 'File not found: ' .. path))
    end
    local focus = args.makeFrontmost ~= false
    local start_line = type(args.startLine) == 'number' and args.startLine or nil
    local end_line = type(args.endLine) == 'number' and args.endLine or nil
    local bufnr, win = context.open_file(path, { focus = focus, preview = args.preview == true })
    if not bufnr then
      error(McpServer.rpc_error(-32000, 'File operation error', tostring(win)))
    end
    ---@cast win integer
    local message = 'Opened file: ' .. path
    local count = vim.api.nvim_buf_line_count(bufnr)
    if start_line or end_line then
      local l1 = math.max(1, math.min(start_line or 1, count))
      local l2 = math.max(l1, math.min(end_line or l1, count))
      pcall(vim.api.nvim_win_set_cursor, win, { l1, 0 })
      if focus then
        pcall(select_range, win, true, l1 - 1, 0, l2 - 1, 0)
      end
      message = 'Opened file and selected lines ' .. (start_line or 1) .. ' to ' .. (end_line or start_line or 1)
    end
    local start_text = type(args.startText) == 'string' and args.startText ~= '' and args.startText or nil
    local end_text = type(args.endText) == 'string' and args.endText ~= '' and args.endText or nil
    if start_text then
      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      local sl, sc
      for i, line in ipairs(lines) do
        local c = line:find(start_text, 1, true)
        if c then
          sl, sc = i - 1, c - 1
          break
        end
      end
      if not sl then
        message = 'Opened file, but text "' .. start_text .. '" not found'
      else
        local el, ec
        if end_text then
          for i = sl + 1, #lines do
            local c = lines[i]:find(end_text, i == sl + 1 and sc + 1 or 1, true)
            if c then
              el, ec = i - 1, c + #end_text - 2
              if args.selectToEndOfLine == true then
                ec = math.max(#lines[i] - 1, 0)
              end
              break
            end
          end
          if el then
            message = 'Opened file and selected text from "' .. start_text .. '" to "' .. end_text .. '"'
          else
            message = 'Opened file and positioned at "' .. start_text .. '" (end text "' .. end_text .. '" not found)'
          end
        else
          message = 'Opened file and selected text "' .. start_text .. '"'
        end
        if not el then
          el, ec = sl, sc + #start_text - 1
        end
        pcall(vim.api.nvim_win_set_cursor, win, { sl + 1, sc })
        if focus then
          pcall(select_range, win, false, sl, sc, el, ec)
        end
      end
    end
    if focus then
      return message
    end
    local ft = vim.bo[bufnr].filetype
    return json_text({
      success = true,
      filePath = path,
      languageId = ft ~= '' and ft or 'plaintext',
      lineCount = count,
    })
  end,
}

tools[#tools + 1] = {
  name = 'openDiff',
  description = 'Open a diff view comparing old file content with new file content',
  inputSchema = {
    type = 'object',
    properties = {
      old_file_path = { type = 'string', description = 'Path to the old file to compare' },
      new_file_path = { type = 'string', description = 'Path to the new file to compare' },
      new_file_contents = { type = 'string', description = 'Contents for the new file version' },
      tab_name = { type = 'string', description = 'Name for the diff tab/view' },
    },
    required = { 'old_file_path', 'new_file_path', 'new_file_contents', 'tab_name' },
    additionalProperties = false,
    ['$schema'] = SCHEMA,
  },
  async = true,
  -- Answered once, when the user decides (§5.1): FILE_SAVED + the final text, or DIFF_REJECTED + tab.
  handler = function(args, ctx, respond)
    local old_path, new_path = args.old_file_path, args.new_file_path
    local contents, tab = args.new_file_contents, args.tab_name
    if type(old_path) ~= 'string' or type(new_path) ~= 'string' or type(contents) ~= 'string'
      or type(tab) ~= 'string' then
      return respond(nil, McpServer.rpc_error(McpServer.INVALID_PARAMS, 'Invalid params',
        'old_file_path, new_file_path, new_file_contents and tab_name must be strings'))
    end
    local target = abs_path(old_path)
    if context.file_exists(target) and context.is_dirty(target) then
      return respond(nil, McpServer.rpc_error(-32000, 'Cannot create diff: file has unsaved changes',
        'Please save (:w) or discard (:e!) changes to ' .. old_path .. ' before creating diff'))
    end
    local session = ctx.session
    local rec = { tab_name = tab, session = session, path = target, done = false }
    local function forget()
      rec.done = true
      if state.diffs[tab] == rec then
        state.diffs[tab] = nil
      end
    end
    local ok, err = diff.open({
      id = tab,
      path = target,
      new_contents = contents,
      title = tab,
      owner = session.id,
      on_resolve = function(res)
        forget()
        if res.status == 'accepted' then
          respond({ content = { text_item('FILE_SAVED'), text_item(res.content or contents) } })
        else
          respond({ content = { text_item('DIFF_REJECTED'), text_item(tab) } })
        end
      end,
    })
    if not ok then
      return respond(nil, McpServer.rpc_error(-32000, 'Error opening diff', tostring(err)))
    end
    state.diffs[tab] = rec
    -- The client went away (or cancelled): nobody is waiting for the answer any more.
    ctx.on_cancel(function()
      if not rec.done then
        forget()
        diff.close(tab)
      end
    end)
  end,
}

tools[#tools + 1] = {
  name = 'getCurrentSelection',
  description = 'Get the current text selection in the editor',
  inputSchema = { type = 'object', additionalProperties = false, ['$schema'] = SCHEMA },
  handler = function()
    local s = current_selection()
    if s then
      local obj = selection_object(s)
      obj.success = true
      return json_text(obj)
    end
    -- (Selection tracking unavailable, or nothing reported yet while an ignored window such as the
    -- agent terminal has focus: never report that window by its raw name.)
    local name = vim.api.nvim_buf_get_name(0)
    if name == '' or not context.is_file_buffer(vim.api.nvim_get_current_buf()) then
      return json_text({ success = false, message = 'No active editor found' })
    end
    return json_text({
      success = true,
      text = '',
      filePath = name,
      fileUrl = util.file_url(name),
      selection = {
        start = { line = 0, character = 0 },
        ['end'] = { line = 0, character = 0 },
        isEmpty = true,
      },
    })
  end,
}

tools[#tools + 1] = {
  name = 'getLatestSelection',
  description = 'Get the most recent text selection (even if not in the active editor)',
  inputSchema = { type = 'object', additionalProperties = false, ['$schema'] = SCHEMA },
  handler = function()
    local s = current_selection()
    if not s then
      return json_text({ success = false, message = 'No selection available' })
    end
    return json_text(selection_object(s))
  end,
}

tools[#tools + 1] = {
  name = 'getOpenEditors',
  description = 'Get list of currently open files',
  inputSchema = { type = 'object', additionalProperties = false, ['$schema'] = SCHEMA },
  handler = function()
    local tab = vim.api.nvim_tabpage_get_number(0)
    local s = current_selection()
    local tabs = {}
    for _, e in ipairs(context.open_editors()) do
      local t = {
        uri = util.file_url_raw(e.path),
        isActive = e.is_active,
        isPinned = false,
        isPreview = false,
        isDirty = e.is_dirty,
        label = e.label,
        groupIndex = tab - 1,
        viewColumn = tab,
        isGroupActive = true,
        fileName = e.path,
        languageId = e.language_id,
        lineCount = e.line_count,
        isUntitled = e.is_untitled,
      }
      if e.is_active and s and s.path == e.path then
        local obj = selection_object(s)
        t.selection = { start = obj.selection.start, ['end'] = obj.selection['end'], isReversed = false }
      end
      tabs[#tabs + 1] = t
    end
    return json_text({ tabs = tabs })
  end,
}

tools[#tools + 1] = {
  name = 'getWorkspaceFolders',
  description = 'Get all workspace folders currently open in the IDE',
  inputSchema = { type = 'object', additionalProperties = false, ['$schema'] = SCHEMA },
  handler = function()
    local folders = {}
    local list = context.workspace_folders()
    for i, p in ipairs(list) do
      folders[i] = { name = vim.fs.basename(p), uri = util.file_url_raw(p), path = p }
    end
    return json_text({ success = true, folders = folders, rootPath = list[1] or vim.fn.getcwd() })
  end,
}

tools[#tools + 1] = {
  name = 'getDiagnostics',
  description = 'Get language diagnostics (errors, warnings) from the editor',
  inputSchema = {
    type = 'object',
    properties = {
      uri = {
        type = 'string',
        description = 'Optional file URI to get diagnostics for. If not provided, gets diagnostics for all open files.',
      },
    },
    additionalProperties = false,
    ['$schema'] = SCHEMA,
  },
  -- Must stay synchronous and fast: Claude gives it 500 ms before an edit and stops asking after
  -- three timeouts (§5.4). URIs are raw 'file://' .. path: Claude never percent-decodes.
  handler = function(args)
    local uri = args.uri
    if uri ~= nil and type(uri) ~= 'string' then
      error(McpServer.rpc_error(McpServer.INVALID_PARAMS, 'Invalid params', 'uri must be a string'))
    end
    local out = {}
    if uri and uri ~= '' then
      local path = context.path_from_uri(uri)
      local entry = path and context.diagnostics(path)[1]
      -- Claude takes this baseline right before every Edit/Write. Reload the open buffer when it
      -- writes the file, also when no diff decides it (auto-accept mode, or answered in the terminal).
      if entry and entry.bufnr then
        diff.watch(entry.path)
      end
      local echo = uri:sub(1, 7) == 'file://' and uri or (path and util.file_url_raw(path)) or uri
      out[1] = { uri = echo, diagnostics = entry and format_diagnostics(entry.diagnostics) or {} }
    else
      for _, e in ipairs(context.diagnostics(nil)) do
        out[#out + 1] = { uri = util.file_url_raw(e.path), diagnostics = format_diagnostics(e.diagnostics) }
      end
    end
    return { content = { text_item(vim.json.encode(out)) } }
  end,
}

tools[#tools + 1] = {
  name = 'checkDocumentDirty',
  description = 'Check if a document has unsaved changes (is dirty)',
  inputSchema = {
    type = 'object',
    properties = { filePath = { type = 'string', description = 'Path to the file to check' } },
    required = { 'filePath' },
    additionalProperties = false,
    ['$schema'] = SCHEMA,
  },
  handler = function(args)
    if type(args.filePath) ~= 'string' then
      error(McpServer.rpc_error(McpServer.INVALID_PARAMS, 'Invalid params', 'Missing filePath parameter'))
    end
    local path = abs_path(args.filePath)
    local dirty = context.is_dirty(path)
    if dirty == nil then
      return json_text({ success = false, message = 'Document not open: ' .. args.filePath })
    end
    return json_text({
      success = true,
      filePath = path,
      isDirty = dirty,
      isUntitled = not context.file_exists(path),
    })
  end,
}

tools[#tools + 1] = {
  name = 'saveDocument',
  description = 'Save a document with unsaved changes',
  inputSchema = {
    type = 'object',
    properties = { filePath = { type = 'string', description = 'Path to the file to save' } },
    required = { 'filePath' },
    additionalProperties = false,
    ['$schema'] = SCHEMA,
  },
  handler = function(args)
    if type(args.filePath) ~= 'string' then
      error(McpServer.rpc_error(McpServer.INVALID_PARAMS, 'Invalid params', 'Missing filePath parameter'))
    end
    local path = abs_path(args.filePath)
    if context.is_dirty(path) == nil then
      return json_text({ success = false, message = 'Document not open: ' .. args.filePath })
    end
    local ok, err = context.save(path)
    if not ok then
      return json_text({ success = false, message = 'Failed to save file: ' .. tostring(err), filePath = path })
    end
    return json_text({ success = true, filePath = path, saved = true, message = 'Document saved successfully' })
  end,
}

tools[#tools + 1] = {
  name = 'closeAllDiffTabs',
  description = 'Close all diff tabs in the editor',
  inputSchema = { type = 'object', additionalProperties = false, ['$schema'] = SCHEMA },
  -- Called at the start of every Claude turn: only this client's own pending diffs (§5.3).
  handler = function(_, ctx)
    local mine = {}
    for tab, rec in pairs(state.diffs) do
      if rec.session == ctx.session then
        mine[#mine + 1] = tab
      end
    end
    for _, tab in ipairs(mine) do
      diff.close(tab, { resolve = true, trigger = 'agent', watch = true })
    end
    return 'CLOSED_' .. #mine .. '_DIFF_TABS'
  end,
}

tools[#tools + 1] = {
  name = 'close_tab',
  description = 'Close a tab by name',
  inputSchema = {
    type = 'object',
    properties = { tab_name = { type = 'string', description = 'Name of the tab to close' } },
    required = { 'tab_name' },
    additionalProperties = false,
    ['$schema'] = SCHEMA,
  },
  hidden = true,
  validate = false,
  -- Claude sends it twice after every openDiff outcome; always TAB_CLOSED (§5.2). A pending diff is
  -- rejected (the user answered in the terminal); an accepted one is already gone (the diff module
  -- tears down at once and reloads the file after Claude writes it). The terminal answer may have
  -- been a yes, so the file is watched for Claude's write here too.
  handler = function(args)
    local tab = args.tab_name
    if type(tab) == 'string' and state.diffs[tab] then
      diff.close(tab, { resolve = true, trigger = 'agent', watch = true })
    end
    return 'TAB_CLOSED'
  end,
}

-- ---------------------------------------------------------------------------
-- MCP server and connections
-- ---------------------------------------------------------------------------

---@return agent.mcp.Server
local function new_mcp_server()
  local srv
  srv = McpServer.new({
    name = M.SERVER_NAME,
    version = M.SERVER_VERSION,
    protocol_version = { supported = M.PROTOCOL_VERSIONS, fallback = M.FALLBACK_PROTOCOL_VERSION },
    capabilities = { tools = { listChanged = true } },
    on_initialize = function(session, params)
      local ci = type(params.clientInfo) == 'table' and params.clientInfo or {}
      local data = session.data
      data.client_name = type(ci.name) == 'string' and ci.name or nil
      data.client_version = type(ci.version) == 'string' and ci.version or nil
      data.kind = data.client_name == 'opencode' and 'opencode' or 'claude'
      log.debug('initialize from %s %s', tostring(data.client_name), tostring(data.client_version))
      if data.kind == 'opencode' then
        -- OpenCode listens from the start; notify right after the initialize response.
        vim.schedule(function()
          mark_ready(session)
        end)
      end
    end,
    on_notification = function(session, method, params)
      if method == 'ide_connected' then
        if type(params) == 'table' and type(params.pid) == 'number' then
          session.data.pid = params.pid
        end
        arm_ready(session)
      elseif method == 'notifications/initialized' then
        arm_ready(session)
      end
    end,
    on_session_close = function(session, reason)
      local t = session.data.ready_timer
      if t then
        t:stop()
        if not t:is_closing() then
          t:close()
        end
        session.data.ready_timer = nil
      end
      log.debug('session %s closed: %s', session.id, reason)
    end,
  })
  for _, def in ipairs(tools) do
    srv:add_tool(def)
  end
  srv:add_method('tools/list', function(_, ctx)
    arm_ready(ctx.session)
    return { tools = srv:list_tools(ctx.session) }
  end)
  return srv
end

---@param srv agent.mcp.Server
---@return agent.ws.ListenOpts
local function listen_opts(srv)
  return {
    host = '127.0.0.1',
    authenticate = websocket.token_auth(M.AUTH_HEADER, function()
      return state.token
    end),
    protocols = { 'mcp' },
    on_open = function(conn)
      conn.data.session = srv:open_session({
        send = function(msg)
          local ok, text = pcall(vim.json.encode, msg)
          if not ok then
            log.error('could not encode a message: %s', tostring(text))
            return false
          end
          return (conn:send(utf8_safe(text)))
        end,
        info = { transport = 'ws', conn_id = conn.id, remote = conn.remote, headers = conn.headers },
      })
      conn.data.session.data.kind = 'claude'
      log.debug('connection %d open (subprotocol %s)', conn.id, tostring(conn.protocol))
    end,
    on_message = function(conn, text)
      local session = conn.data.session
      if session then
        srv:handle_json(session, text)
      end
    end,
    on_close = function(conn, code, reason)
      local session = conn.data.session
      if session then
        session:close('disconnect')
      end
      log.debug('connection %d closed: %s %s', conn.id, tostring(code), tostring(reason))
    end,
  }
end

local function setup_autocmds()
  state.group = vim.api.nvim_create_augroup('AgentProviderClaude', { clear = true })
  -- Keep workspaceFolders current for OpenCode's matching and Claude's /ide list (§2.5).
  vim.api.nvim_create_autocmd({ 'DirChanged', 'LspAttach', 'LspDetach' }, {
    group = state.group,
    callback = function()
      vim.schedule(function()
        if state.ws then
          local ok, err = write_lock()
          if not ok then
            log.warn('could not update the lock file: %s', err)
          end
        end
      end)
    end,
  })
  vim.api.nvim_create_autocmd('VimLeavePre', {
    group = state.group,
    callback = function()
      M.stop()
    end,
  })
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

---Start the server and write the lock file. Idempotent. After a stop() the previous port and
---token are reused, so running Claude sessions can reconnect.
---@return boolean ok, string|nil err
function M.start()
  if state.ws then
    return true, nil
  end
  local o = opts()
  if o.enabled == false then
    return false, 'the claude provider is disabled (providers.claude.enabled = false)'
  end
  state.token = state.token or util.random_hex(16)
  local srv = new_mcp_server()
  local lopts = listen_opts(srv)
  local server, err
  if state.port then
    lopts.port = state.port
    server, err = websocket.listen(lopts)
    if not server then
      log.warn('could not listen on port %d again (%s): agents started outside agent.nvim must '
        .. 'reconnect with /ide', state.port, tostring(err))
    end
  end
  if not server then
    lopts.port = o.port_range or M.DEFAULT_PORT_RANGE
    server, err = websocket.listen(lopts)
  end
  if not server then
    return false, 'could not start the Claude IDE server: ' .. tostring(err)
  end
  state.ws, state.srv, state.port = server, srv, server.port
  remove_stale_locks(M.lock_dir())
  local ok, lerr = write_lock(true)
  if not ok then
    state.ws, state.srv = nil, nil
    server:close()
    srv:close('server_closed')
    return false, 'could not write the Claude lock file: ' .. tostring(lerr)
  end
  setup_autocmds()
  log.debug('listening on 127.0.0.1:%d, lock %s', state.port, state.lock_path)
  return true, nil
end

---Stop the server: pending diffs are rejected (DIFF_REJECTED is sent best-effort), clients get
---close 1001, the lock file is removed. The port and token are kept for a later start().
function M.stop()
  local server, srv = state.ws, state.srv
  if not server then
    return
  end
  local pending = vim.tbl_keys(state.diffs)
  for _, tab in ipairs(pending) do
    diff.close(tab, { resolve = true, trigger = 'disconnect' })
  end
  state.diffs = {}
  state.ws, state.srv = nil, nil
  if srv then
    srv:close('server_closed')
  end
  server:close()
  util.remove(state.lock_path)
  state.lock_path, state.lock_json = nil, nil
  if state.group then
    pcall(vim.api.nvim_del_augroup_by_id, state.group)
    state.group = nil
  end
end

---@return boolean
function M.is_running()
  return state.ws ~= nil
end

---Environment for an agent terminal using this provider (claude-opencode.md §7.3, §11). Values
---are strings; OpenCode's port variables are "" (empty is unset there) so that it connects through
---the lock file, with the token.
---@param kind 'claude'|'opencode'|nil default 'claude'
---@return table<string, string>
function M.env(kind)
  local np = no_proxy_value()
  if kind == 'opencode' then
    return { CLAUDE_CODE_SSE_PORT = '', OPENCODE_EDITOR_SSE_PORT = '', NO_PROXY = np, no_proxy = np }
  end
  local env = { CLAUDE_CODE_IDE_SKIP_AUTO_INSTALL = 'true', NO_PROXY = np, no_proxy = np }
  if state.port and state.ws then
    env.CLAUDE_CODE_SSE_PORT = tostring(state.port)
    env.ENABLE_IDE_INTEGRATION = 'true'
    env.FORCE_CODE_TERMINAL = 'true'
  end
  return env
end

---Launch info for agents.build_launch (opts.ide). Starts the server if needed and puts the job's
---cwd in the lock's workspaceFolders (in place of the previous agent's).
---@param o { cwd?: string }|nil
---@return { port: integer, token: string, lock: string }|nil info, string|nil err
function M.launch_info(o)
  local ok, err = M.start()
  if not ok then
    return nil, err
  end
  if o and o.cwd then
    set_job_folder(o.cwd)
  end
  return { port = state.port, token = state.token, lock = state.lock_path }
end

---before_spawn hook (pass it for opencode): makes sure the job's cwd is in workspaceFolders and
---rewrites the lock so its mtime is the newest, which is OpenCode's tie-break between Neovims (§11).
---@param spec { cwd?: string }|nil
function M.before_spawn(spec)
  if not state.ws then
    return
  end
  if spec and spec.cwd then
    set_job_folder(spec.cwd)
  end
  local ok, err = write_lock(true)
  if not ok then
    log.warn('could not rewrite the lock file: %s', err)
  end
end

---@class agent.claude.ClientInfo
---@field id string       MCP session id
---@field kind 'claude'|'opencode'
---@field name string|nil clientInfo.name
---@field version string|nil
---@field pid integer|nil Claude's pid (ide_connected)
---@field ready boolean   notifications are delivered

---Connected clients that completed initialize.
---@return agent.claude.ClientInfo[]
function M.clients()
  local out = {}
  if not state.srv then
    return out
  end
  for _, s in ipairs(state.srv:sessions()) do
    if s.initialized then
      out[#out + 1] = {
        id = s.id,
        kind = s.data.kind,
        name = s.data.client_name,
        version = s.data.client_version,
        pid = s.data.pid,
        ready = s.data.ready == true,
      }
    end
  end
  return out
end

---@return { running: boolean, clients: integer, address: string|nil, lock: string|nil, port: integer|nil, sessions: agent.claude.ClientInfo[] }
function M.status()
  local clients = M.clients()
  return {
    running = state.ws ~= nil,
    clients = #clients,
    address = state.ws and ('ws://127.0.0.1:' .. state.port) or nil,
    lock = state.lock_path,
    port = state.port,
    sessions = clients,
  }
end

---Called for each debounced selection event: sends selection_changed to every ready client
---(rendered for its kind; unchanged selections are not resent). Ignored with selection.track = false.
---@param s agent.Selection|nil
function M.on_selection(s)
  if not s or not tracking() then
    return
  end
  state.last_selection = s
  for _, session in ipairs(ready_sessions()) do
    notify_selection(session, s)
  end
end

---Internal state, for tests.
M._state = state

---Forget the session-stable port and token (tests only; running clients could not reconnect).
function M._reset()
  M.stop()
  state.port, state.token = nil, nil
  state.job_folders = {}
  state.last_selection = nil
end

return M
