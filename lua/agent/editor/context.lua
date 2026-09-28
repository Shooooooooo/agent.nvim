---@mod agent.editor.context Editor state helpers: buffers, open editors, diagnostics, workspace folders, windows
---
--- Everything here returns neutral data (absolute paths, 0-based positions, byte columns, numeric
--- severities). Providers turn it into their wire formats (URIs, severity names, 1-based lines).
local util = require('agent.util')

local M = {}

local api = vim.api
local uv = vim.uv or vim.loop

---@param name string
---@return boolean
local function is_url(name)
  return name:match('^%a[%w+.-]*://') ~= nil
end

---True for a buffer that holds a real file: normal buftype, a name that is a path (not a
---`term://`, `agent-diff://` or other URL-like name), and not marked with `b:agent_ignore`.
---The buffer does not have to be loaded, and the file does not have to exist on disk.
---@param bufnr integer
---@return boolean
function M.is_file_buffer(bufnr)
  if not bufnr or not api.nvim_buf_is_valid(bufnr) then
    return false
  end
  if vim.bo[bufnr].buftype ~= '' then
    return false
  end
  local name = api.nvim_buf_get_name(bufnr)
  if name == '' or is_url(name) then
    return false
  end
  if vim.b[bufnr].agent_ignore then
    return false
  end
  return true
end

---@param path string
---@return boolean
function M.file_exists(path)
  local st = uv.fs_stat(path)
  return st ~= nil and st.type == 'file'
end

---True for a buffer whose name is an absolute path to a file that exists on disk, whatever its
---'buftype' (a :help file has buftype "help"). Buffers marked with `b:agent_ignore` are excluded.
---@param bufnr integer
---@return boolean
function M.is_disk_file(bufnr)
  if not bufnr or not api.nvim_buf_is_valid(bufnr) or vim.b[bufnr].agent_ignore then
    return false
  end
  local name = api.nvim_buf_get_name(bufnr)
  if name == '' or is_url(name) or not (name:sub(1, 1) == '/' or name:match('^%a:[\\/]')) then
    return false
  end
  return M.file_exists(name)
end

--- Prefix of the identifiers under which buffers that are not files are reported to the agents.
M.BUFFER_URI_PREFIX = 'nvim://buffer/'

---The program a terminal buffer runs, from its name `term://<cwd>//<pid>:<cmd>`: the basename of the
---first word of <cmd> ("fish" for `/opt/homebrew/bin/fish -l`), or nil. An unquoted word ends at a
---";" too: toggleterm names its terminals `term://<cwd>//<pid>:<shell>;#toggleterm#<n>`.
---@param name string
---@return string|nil
local function terminal_program(name)
  local cmd = name:match('^term://.-//%d+:(.*)$')
  if not cmd then
    return nil
  end
  cmd = vim.trim(cmd)
  local q = cmd:sub(1, 1)
  local word
  if q == '"' or q == "'" then
    word = cmd:match('^' .. q .. '([^' .. q .. ']*)')
  else
    word = cmd:match('^([^%s;]+)')
  end
  if not word then
    return nil
  end
  return word:gsub('[/\\]+$', ''):match('([^/\\]*)$')
end

--- Longest label (in bytes) of a buffer that is not a file.
local MAX_LABEL = 64

---`s` without the bytes that are not part of a valid UTF-8 sequence, and cut to at most `max`
---bytes on a character boundary.
---@param s string
---@param max integer
---@return string
local function utf8_prefix(s, max)
  local valid_utf8 = require('agent.net.common').valid_utf8
  if #s <= max and valid_utf8(s) then
    return s
  end
  local out, n, i = {}, 0, 1
  while i <= #s do
    local c = s:byte(i)
    local len = c < 0x80 and 1 or c >= 0xF0 and 4 or c >= 0xE0 and 3 or c >= 0xC2 and 2 or 0
    local seq = len > 0 and s:sub(i, i + len - 1) or ''
    if len > 0 and #seq == len and (len == 1 or valid_utf8(seq)) then
      if n + len > max then
        break
      end
      out[#out + 1] = seq
      n, i = n + len, i + len
    else
      i = i + 1 -- not UTF-8: dropped
    end
  end
  return table.concat(out)
end

---Remove what must not appear in a label: "/" and "\", C0 controls and DEL, C1 controls
---(U+0080-U+009F), U+200E/U+200F, U+2028/U+2029, U+202A-U+202E and U+2066-U+2069.
---@param s string
---@return string
local function sanitize_label(s)
  return (s:gsub('[%c/\\]', '')
    :gsub('\194[\128-\159]', '')
    :gsub('\226\128[\142\143\168\169\170-\174]', '')
    :gsub('\226\129[\166-\169]', ''))
end

---A short name for a buffer that is not a file: the program a terminal runs, else the 'filetype',
---else the basename of the buffer name, else "scratch". Valid UTF-8 of at most 64 bytes (cut on a
---character boundary), with no "/", "\", control characters (C0, DEL, C1), line or paragraph
---separators, or bidirectional formatting characters.
---@param bufnr integer
---@return string
function M.buffer_label(bufnr)
  local name = api.nvim_buf_get_name(bufnr)
  local candidates = {
    vim.bo[bufnr].buftype == 'terminal' and terminal_program(name) or nil,
    vim.bo[bufnr].filetype,
    (name:gsub('[/\\]+$', ''):match('([^/\\]*)$')),
  }
  for i = 1, 3 do
    local label = candidates[i] and utf8_prefix(sanitize_label(candidates[i]), MAX_LABEL) or ''
    if label ~= '' then
      return label
    end
  end
  return 'scratch'
end

---The identifier under which a buffer that is not a file is reported to the agents:
---`nvim://buffer/<bufnr>/<label>` (see buffer_label()). The $NVIM controller's read_buffer reads it.
---@param bufnr integer
---@return string
function M.buffer_uri(bufnr)
  return M.BUFFER_URI_PREFIX .. bufnr .. '/' .. M.buffer_label(bufnr)
end

---True for an identifier made by buffer_uri() (a reported path that is not a file).
---@param s any
---@return boolean
function M.is_buffer_uri(s)
  return type(s) == 'string' and s:sub(1, #M.BUFFER_URI_PREFIX) == M.BUFFER_URI_PREFIX
end

---The buffer number in `nvim://buffer/<bufnr>[/<label>]`, or nil for anything else (also for buffer
---number 0, which names no buffer). The buffer may no longer exist.
---@param s any
---@return integer|nil
function M.bufnr_from_uri(s)
  if not M.is_buffer_uri(s) then
    return nil
  end
  local n = s:sub(#M.BUFFER_URI_PREFIX + 1):match('^(%d+)/') or s:sub(#M.BUFFER_URI_PREFIX + 1):match('^(%d+)$')
  n = n and tonumber(n)
  return n ~= 0 and n or nil
end

---Absolute path with symlinks resolved. For a path that does not exist yet, the parent directory
---is resolved instead (so `/tmp/new.txt` and `/private/tmp/new.txt` compare equal on macOS).
---@param path string
---@return string
function M.resolve_path(path)
  local abs = util.abspath(path)
  local real = uv.fs_realpath(abs)
  if real then
    return real
  end
  local parent = vim.fs.dirname(abs)
  local rparent = parent and uv.fs_realpath(parent)
  if rparent then
    return vim.fs.joinpath(rparent, vim.fs.basename(abs))
  end
  return abs
end

---Find the buffer whose name is exactly `path` (never a pattern match like `bufnr()`).
---Falls back to comparing resolved paths, so a symlinked or `/tmp` vs `/private/tmp` name matches too.
---Only file buffers (see is_file_buffer) are considered.
---@param path string
---@param opts? { loaded?: boolean }  loaded=true: only loaded buffers
---@return integer|nil bufnr
function M.find_buf(path, opts)
  if not path or path == '' then
    return nil
  end
  local want_loaded = opts and opts.loaded
  local abs = util.abspath(path)
  local candidates = {}
  for _, b in ipairs(api.nvim_list_bufs()) do
    if M.is_file_buffer(b) and (not want_loaded or api.nvim_buf_is_loaded(b)) then
      local name = api.nvim_buf_get_name(b)
      if name == path or name == abs then
        return b
      end
      candidates[#candidates + 1] = { b, name }
    end
  end
  local real = M.resolve_path(abs)
  for _, c in ipairs(candidates) do
    if util.abspath(c[2]) == abs or M.resolve_path(c[2]) == real then
      return c[1]
    end
  end
  return nil
end

---Convert a URI or path from an agent into an absolute path.
---Accepts raw `file://<path>` (Claude), percent-encoded `file://` URIs (Copilot, VS Code) and plain
---paths. For `file://` input, the raw form is tried first and the decoded form second; whichever
---names an open buffer or an existing file wins. Other URI schemes return nil.
---@param s string
---@return string|nil path
function M.path_from_uri(s)
  if type(s) ~= 'string' or s == '' then
    return nil
  end
  if s:sub(1, 7) == 'file://' then
    local raw = s:sub(8)
    local ok, decoded = pcall(vim.uri_to_fname, s)
    if not ok then
      decoded = raw
    end
    if raw == decoded then
      return util.abspath(raw)
    end
    if M.find_buf(raw) or uv.fs_stat(raw) then
      return util.abspath(raw)
    end
    return util.abspath(decoded)
  end
  -- Any other scheme (`untitled:`, `git://`, ...); a one-letter "scheme" is a Windows drive.
  if s:match('^%a[%w+.-]+:') then
    return nil
  end
  return util.abspath(s)
end

---Workspace folders: the realpath of the cwd first, then the LSP clients' workspace folders (deduplicated).
---@param opts? { lsp?: boolean }  lsp=false: only the cwd
---@return string[]
function M.workspace_folders(opts)
  local out, seen = {}, {}
  local function add(p)
    if p and p ~= '' and not seen[p] then
      seen[p] = true
      out[#out + 1] = p
    end
  end
  add(util.realpath(vim.fn.getcwd()))
  if not (opts and opts.lsp == false) then
    local ok, clients = pcall(vim.lsp.get_clients)
    if ok then
      for _, client in ipairs(clients) do
        for _, wf in ipairs(client.workspace_folders or {}) do
          local pok, p = pcall(vim.uri_to_fname, wf.uri)
          if pok then
            add(util.realpath(p))
          end
        end
      end
    end
  end
  return out
end

---The buffer of the "active editor": the current buffer when it is a file buffer, otherwise the
---most recently focused file buffer (from agent.editor.selection), otherwise the buffer of the main window.
---@return integer|nil bufnr
function M.active_buf()
  local cur = api.nvim_get_current_buf()
  if M.is_file_buffer(cur) then
    return cur
  end
  local ok, sel = pcall(require, 'agent.editor.selection')
  if ok then
    local b = sel.last_focused_buf()
    if b then
      return b
    end
  end
  local win = M.main_window({ create = false })
  if win then
    local b = api.nvim_win_get_buf(win)
    if M.is_file_buffer(b) then
      return b
    end
  end
  return nil
end

---@class agent.OpenEditor
---@field path string         absolute path (the buffer name)
---@field bufnr integer
---@field is_active boolean   see active_buf()
---@field is_dirty boolean
---@field is_untitled boolean the file does not exist on disk yet
---@field language_id string  'filetype', or 'plaintext'
---@field label string        file name without directories
---@field line_count integer

---Listed, loaded file buffers, in buffer-number order.
---@return agent.OpenEditor[]
function M.open_editors()
  local active = M.active_buf()
  local out = {}
  for _, b in ipairs(api.nvim_list_bufs()) do
    if M.is_file_buffer(b) and api.nvim_buf_is_loaded(b) and vim.bo[b].buflisted then
      local path = api.nvim_buf_get_name(b)
      local ft = vim.bo[b].filetype
      out[#out + 1] = {
        path = path,
        bufnr = b,
        is_active = b == active,
        is_dirty = vim.bo[b].modified,
        is_untitled = not M.file_exists(path),
        language_id = ft ~= '' and ft or 'plaintext',
        label = vim.fs.basename(path),
        line_count = api.nvim_buf_line_count(b),
      }
    end
  end
  return out
end

---@class agent.Diagnostic
---@field message string
---@field severity integer  vim.diagnostic.severity: 1=ERROR, 2=WARN, 3=INFO, 4=HINT
---@field range { start: { line: integer, character: integer }, ['end']: { line: integer, character: integer } }  0-based; byte columns
---@field source string|nil
---@field code string|integer|nil

---@class agent.FileDiagnostics
---@field path string
---@field bufnr integer|nil  nil when the file has no buffer
---@field diagnostics agent.Diagnostic[]

---@param d vim.Diagnostic
---@return agent.Diagnostic
local function convert_diagnostic(d)
  local lnum, col = d.lnum or 0, d.col or 0
  local code = d.code
  if code == nil and type(d.user_data) == 'table' and type(d.user_data.lsp) == 'table' then
    code = d.user_data.lsp.code
  end
  if type(code) ~= 'string' and type(code) ~= 'number' then
    code = nil
  end
  return {
    message = d.message or '',
    severity = d.severity or vim.diagnostic.severity.ERROR,
    range = {
      start = { line = lnum, character = col },
      ['end'] = { line = d.end_lnum or lnum, character = d.end_col or col },
    },
    source = type(d.source) == 'string' and d.source or nil,
    code = code,
  }
end

---@param list agent.Diagnostic[]
local function sort_diagnostics(list)
  table.sort(list, function(a, b)
    local sa, sb = a.range.start, b.range.start
    if sa.line ~= sb.line then
      return sa.line < sb.line
    end
    if sa.character ~= sb.character then
      return sa.character < sb.character
    end
    return a.severity < b.severity
  end)
  return list
end

---Diagnostics grouped by file. Synchronous and fast (never waits for a language server).
---With `path`: exactly one entry for that file, with an empty list when it has no buffer or no
---diagnostics. Without `path`: every file buffer with at least one diagnostic, sorted by path.
---@param path string|nil absolute path (use path_from_uri() for URIs)
---@return agent.FileDiagnostics[]
function M.diagnostics(path)
  if path then
    local abs = util.abspath(path)
    local b = M.find_buf(abs)
    local list = {}
    if b then
      for _, d in ipairs(vim.diagnostic.get(b)) do
        list[#list + 1] = convert_diagnostic(d)
      end
    end
    return { { path = b and api.nvim_buf_get_name(b) or abs, bufnr = b, diagnostics = sort_diagnostics(list) } }
  end
  local by_buf, order = {}, {}
  for _, d in ipairs(vim.diagnostic.get(nil)) do
    local b = d.bufnr
    if b and M.is_file_buffer(b) then
      if not by_buf[b] then
        by_buf[b] = {}
        order[#order + 1] = b
      end
      table.insert(by_buf[b], convert_diagnostic(d))
    end
  end
  local out = {}
  for _, b in ipairs(order) do
    out[#out + 1] = { path = api.nvim_buf_get_name(b), bufnr = b, diagnostics = sort_diagnostics(by_buf[b]) }
  end
  table.sort(out, function(a, b)
    return a.path < b.path
  end)
  return out
end

---@param path string
---@return boolean|nil dirty  nil when the file has no loaded buffer
function M.is_dirty(path)
  local b = M.find_buf(path, { loaded = true })
  if not b then
    return nil
  end
  return vim.bo[b].modified
end

---Write the file's buffer to disk.
---@param path string
---@return boolean ok, string|nil err
function M.save(path)
  local b = M.find_buf(path, { loaded = true })
  if not b then
    return false, 'Document not open: ' .. tostring(path)
  end
  local ok, err = pcall(api.nvim_buf_call, b, function()
    vim.cmd('silent write')
  end)
  if not ok then
    return false, tostring(err)
  end
  return true, nil
end

---@param win integer
---@return boolean
local function is_editor_window(win)
  if not api.nvim_win_is_valid(win) then
    return false
  end
  if api.nvim_win_get_config(win).relative ~= '' then
    return false
  end
  local wo = vim.wo[win]
  if wo.diff or wo.previewwindow or wo.winfixbuf then
    return false
  end
  local b = api.nvim_win_get_buf(win)
  if vim.bo[b].buftype ~= '' then
    return false
  end
  local name = api.nvim_buf_get_name(b)
  return not is_url(name)
end

---A window for showing files: not floating, not a terminal, sidebar (non-empty 'buftype'),
---diff, preview or 'winfixbuf' window, in the current tab page. Prefers the current window, then
---the previous window (`wincmd p`), then the largest candidate. Without a candidate, a new
---window is split off (unless opts.create is false).
---@param opts? { create?: boolean }
---@return integer|nil winid
function M.main_window(opts)
  local cur = api.nvim_get_current_win()
  if is_editor_window(cur) then
    return cur
  end
  local prev = vim.fn.win_getid(vim.fn.winnr('#'))
  if prev ~= 0 and is_editor_window(prev) then
    return prev
  end
  local best, best_area
  for _, w in ipairs(api.nvim_tabpage_list_wins(0)) do
    if is_editor_window(w) then
      local area = api.nvim_win_get_width(w) * api.nvim_win_get_height(w)
      if not best or area > best_area then
        best, best_area = w, area
      end
    end
  end
  if best or (opts and opts.create == false) then
    return best
  end
  -- Split a new editor window off to the left of the current (e.g. terminal) window. The
  -- placeholder buffer disappears as soon as a file is shown in the window.
  local placeholder = api.nvim_create_buf(false, true)
  vim.bo[placeholder].bufhidden = 'wipe'
  local ok, win = pcall(api.nvim_open_win, placeholder, false, { split = 'left', win = cur })
  if not ok then
    ok, win = pcall(api.nvim_open_win, placeholder, false, { split = 'left', win = -1 })
  end
  if not ok then
    pcall(api.nvim_buf_delete, placeholder, { force = true })
    return nil
  end
  -- A scratch buffer's buftype would make the window look like a sidebar; mark it usable.
  vim.bo[placeholder].buftype = ''
  return win
end

---Open a file in the main editor window (never in a terminal, sidebar, floating or diff window).
---If the file is already shown in an editor window of the current tab page, that window is used.
---@param path string
---@param opts? { line?: integer, end_line?: integer, focus?: boolean, preview?: boolean }  lines are 1-based; end_line selects line..end_line linewise (only with focus)
---@return integer|nil bufnr, integer|string winid_or_err
function M.open_file(path, opts)
  opts = opts or {}
  local focus = opts.focus ~= false
  local abs = util.abspath(path)
  local b = M.find_buf(abs)
  if not b then
    b = vim.fn.bufadd(abs)
  end
  vim.bo[b].buflisted = true
  if not api.nvim_buf_is_loaded(b) then
    local ok, err = pcall(vim.fn.bufload, b)
    if not ok then
      return nil, tostring(err)
    end
  end

  local win
  for _, w in ipairs(api.nvim_tabpage_list_wins(0)) do
    if api.nvim_win_get_buf(w) == b and is_editor_window(w) then
      win = w
      break
    end
  end
  if not win then
    win = M.main_window()
    if not win then
      return nil, 'no window available to open ' .. abs
    end
    local ok, err = pcall(api.nvim_win_set_buf, win, b)
    if not ok then
      -- e.g. the window's buffer has changes and 'hidden' is off: open in a split instead
      local sok, swin = pcall(api.nvim_open_win, b, false, { split = 'above', win = win })
      if not sok then
        return nil, tostring(err)
      end
      win = swin
    end
  end

  if focus then
    local m = api.nvim_get_mode().mode:sub(1, 1)
    if m == 'i' or m == 't' or m == 'R' then
      vim.cmd('stopinsert')
    end
    api.nvim_set_current_win(win)
  end
  if opts.line then
    local count = api.nvim_buf_line_count(b)
    local first = math.max(1, math.min(opts.line, count))
    pcall(api.nvim_win_set_cursor, win, { first, 0 })
    if opts.end_line and focus then
      local last = math.max(first, math.min(opts.end_line, count))
      local mode = api.nvim_get_mode().mode:sub(1, 1)
      if mode == 'v' or mode == 'V' or mode == '\22' then
        vim.cmd('normal! \27')
      end
      vim.cmd(string.format('normal! %dGV%dG', first, last))
    end
    api.nvim_win_call(win, function()
      vim.cmd('normal! zz')
    end)
  end
  return b, win
end

return M
