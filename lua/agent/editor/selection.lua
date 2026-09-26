---@mod agent.editor.selection Selection, cursor and recently-focused-file tracking
---
--- Tracks, for file buffers only (see context.is_file_buffer: terminals, `agent-diff://` and
--- other special buffers are ignored):
---  * the latest selection: a live visual/select-mode selection, the selection just left
---    (held until the cursor moves or the text changes), or the cursor position;
---  * the last selection of every buffer (get(), last_visual());
---  * the recently focused files with wall-clock focus timestamps (recent_files(); Gemini's
---    `openFiles`). This tracker lives here, not in context.lua, because it shares the autocmds.
--- Subscribers are called on the main loop after `config.selection.debounce_ms` of quiet.
local util = require('agent.util')
local context = require('agent.editor.context')

local M = {}

local api = vim.api
local uv = vim.uv or vim.loop

local GROUP = 'AgentSelection'
local MAX_TRACKED = 50

---@class agent.Position
---@field line integer       0-based
---@field character integer  0-based byte column

---@class agent.Selection
---@field path string          absolute path (the buffer name)
---@field bufnr integer
---@field text string          '' for a cursor-only position
---@field start agent.Position
---@field finish agent.Position  LSP-style end: exclusive column. Linewise: {last_line, #last_line_text}
---@field is_empty boolean     text == ''
---@field mode 'n'|'v'|'V'|'\22'  'n' = cursor only; select modes are reported as their visual equivalent
---@field linewise boolean
---@field cursor agent.Position  cursor position when captured
---@field start_line integer   1-based first line
---@field end_line integer     1-based last line (inclusive)

local function new_state()
  return {
    running = false,
    latest = nil, ---@type agent.Selection|nil
    emitted = nil, ---@type agent.Selection|nil
    files_dirty = false,
    per_buf = {}, ---@type table<integer, { selection: agent.Selection, visual: agent.Selection|nil }>
    held = nil, -- { bufnr, selection, pos = {row, col}, tick }: the selection just left, until the cursor moves
    visual_entry = nil, -- { bufnr, tick } at visual-mode entry, to detect operators that consumed the selection
    recent = {}, -- MRU of focused file buffers: { bufnr, path, timestamp }
    seeded = false,
    last_ts = 0,
    debounced = nil,
    cancel = nil,
  }
end

local state = new_state()
local subscribers = {} ---@type { fn: function, files: boolean }[]

---@param mode string
---@return 'v'|'V'|'\22'|nil
local function visual_kind(mode)
  local c = mode:sub(1, 1)
  if c == 'v' or c == 's' then
    return 'v'
  elseif c == 'V' or c == 'S' then
    return 'V'
  elseif c == '\22' or c == '\19' then
    return '\22'
  end
  return nil
end

---@param bufnr integer
---@return boolean
function M.is_trackable(bufnr)
  return context.is_file_buffer(bufnr) and api.nvim_buf_is_loaded(bufnr)
end

local function now_wall_ms()
  local ok, t = pcall(uv.clock_gettime, 'realtime')
  if ok and type(t) == 'table' then
    return t.sec * 1000 + math.floor(t.nsec / 1e6)
  end
  return os.time() * 1000
end

---Strictly increasing wall-clock milliseconds.
local function next_timestamp()
  local ts = math.max(now_wall_ms(), state.last_ts + 1)
  state.last_ts = ts
  return ts
end

---@param bufnr integer
---@param win integer
---@return agent.Selection
local function cursor_selection(bufnr, win)
  local pos = api.nvim_win_get_cursor(win)
  local p = { line = pos[1] - 1, character = pos[2] }
  return {
    path = api.nvim_buf_get_name(bufnr),
    bufnr = bufnr,
    text = '',
    start = p,
    finish = { line = p.line, character = p.character },
    is_empty = true,
    mode = 'n',
    linewise = false,
    cursor = { line = p.line, character = p.character },
    start_line = pos[1],
    end_line = pos[1],
  }
end

---Selection between two getpos()-style positions in the current buffer.
---@return agent.Selection|nil
local function region_selection(bufnr, win, p1, p2, kind)
  if p1[2] == 0 or p2[2] == 0 then
    return nil
  end
  local ok, segs = pcall(vim.fn.getregionpos, p1, p2, { type = kind })
  if not ok or type(segs) ~= 'table' or #segs == 0 then
    return nil
  end
  local tok, lines = pcall(vim.fn.getregion, p1, p2, { type = kind })
  if not tok or type(lines) ~= 'table' then
    return nil
  end
  local first, last = segs[1][1], segs[#segs][2]
  local start = { line = first[2] - 1, character = math.max(first[3] - 1, 0) }
  -- getregionpos() ends at the last byte of the last character (1-based), which is the
  -- exclusive 0-based end.
  local finish = { line = last[2] - 1, character = math.max(last[3], 0) }
  if kind == 'V' then
    start.character = 0
    local text = api.nvim_buf_get_lines(bufnr, finish.line, finish.line + 1, false)[1] or ''
    finish.character = #text
  end
  local text = table.concat(lines, '\n')
  local pos = api.nvim_win_get_cursor(win)
  return {
    path = api.nvim_buf_get_name(bufnr),
    bufnr = bufnr,
    text = text,
    start = start,
    finish = finish,
    is_empty = text == '',
    mode = kind,
    linewise = kind == 'V',
    cursor = { line = pos[1] - 1, character = pos[2] },
    start_line = start.line + 1,
    end_line = finish.line + 1,
  }
end

---@param s agent.Selection
local function remember(s)
  local entry = state.per_buf[s.bufnr] or {}
  entry.selection = s
  if not s.is_empty and s.mode ~= 'n' then
    entry.visual = s
  end
  state.per_buf[s.bufnr] = entry
end

---Selection in the current window, or nil when its buffer is not trackable.
---@return agent.Selection|nil
local function compute()
  local win = api.nvim_get_current_win()
  local buf = api.nvim_win_get_buf(win)
  if not M.is_trackable(buf) then
    return nil
  end
  local kind = visual_kind(api.nvim_get_mode().mode)
  if kind then
    state.held = nil
    return region_selection(buf, win, vim.fn.getpos('v'), vim.fn.getpos('.'), kind) or cursor_selection(buf, win)
  end
  local held = state.held
  if held then
    if held.bufnr == buf then
      local pos = api.nvim_win_get_cursor(win)
      if pos[1] == held.pos[1] and pos[2] == held.pos[2] and api.nvim_buf_get_changedtick(buf) == held.tick then
        return held.selection
      end
    end
    state.held = nil
  end
  return cursor_selection(buf, win)
end

---Recompute the latest selection from the current window (no events).
---@return agent.Selection|nil selection  nil when the current buffer is not trackable
local function refresh()
  local s = compute()
  if s then
    state.latest = s
    remember(s)
  end
  return s
end

---@param a agent.Selection|nil
---@param b agent.Selection|nil
local function same(a, b)
  if a == b then
    return true
  end
  if not a or not b then
    return false
  end
  return a.path == b.path and a.text == b.text
    and a.start.line == b.start.line and a.start.character == b.start.character
    and a.finish.line == b.finish.line and a.finish.character == b.finish.character
end

---Called when visual/select mode ends: capture the selection from the '< and '> marks right
---away, because the mode is already Normal (or Cmdline) by the time the debounce fires.
local function flush_visual()
  local win = api.nvim_get_current_win()
  local buf = api.nvim_win_get_buf(win)
  local entry = state.visual_entry
  state.visual_entry = nil
  if not M.is_trackable(buf) then
    return
  end
  -- An operator such as d/c/> changed the text: the marks no longer describe what was selected.
  if entry and entry.bufnr == buf and api.nvim_buf_get_changedtick(buf) ~= entry.tick then
    state.held = nil
    return
  end
  local kind = vim.fn.visualmode()
  if kind == '' then
    return
  end
  local s = region_selection(buf, win, vim.fn.getpos("'<"), vim.fn.getpos("'>"), visual_kind(kind) or 'v')
  if not s or s.is_empty then
    return
  end
  state.held = { bufnr = buf, selection = s, pos = api.nvim_win_get_cursor(win), tick = api.nvim_buf_get_changedtick(buf) }
  state.latest = s
  remember(s)
end

---@param bufnr integer
local function touch_recent(bufnr)
  if not M.is_trackable(bufnr) then
    return
  end
  local path = api.nvim_buf_get_name(bufnr)
  local top = state.recent[1]
  if top and top.bufnr == bufnr and top.path == path then
    return
  end
  for i = #state.recent, 1, -1 do
    if state.recent[i].bufnr == bufnr then
      table.remove(state.recent, i)
    end
  end
  table.insert(state.recent, 1, { bufnr = bufnr, path = path, timestamp = next_timestamp() })
  for i = #state.recent, MAX_TRACKED + 1, -1 do
    state.recent[i] = nil
  end
  state.files_dirty = true
end

---@param bufnr integer
local function forget(bufnr)
  for i = #state.recent, 1, -1 do
    if state.recent[i].bufnr == bufnr then
      table.remove(state.recent, i)
      state.files_dirty = true
    end
  end
  state.per_buf[bufnr] = nil
  if state.held and state.held.bufnr == bufnr then
    state.held = nil
  end
  if state.latest and state.latest.bufnr == bufnr then
    state.latest = nil
  end
end

---@param bufnr integer
local function renamed(bufnr)
  if not M.is_trackable(bufnr) then
    forget(bufnr)
    return
  end
  local path = api.nvim_buf_get_name(bufnr)
  for _, r in ipairs(state.recent) do
    if r.bufnr == bufnr and r.path ~= path then
      r.path = path
      state.files_dirty = true
    end
  end
  state.per_buf[bufnr] = nil
end

---Seed the focus list from the listed buffers ('lastused', seconds) and the current buffer.
local function seed()
  if state.seeded then
    return
  end
  state.seeded = true
  local infos = vim.fn.getbufinfo({ buflisted = 1, bufloaded = 1 })
  table.sort(infos, function(a, b)
    return (a.lastused or 0) > (b.lastused or 0)
  end)
  for _, info in ipairs(infos) do
    if M.is_trackable(info.bufnr) and #state.recent < MAX_TRACKED then
      state.recent[#state.recent + 1] = {
        bufnr = info.bufnr,
        path = api.nvim_buf_get_name(info.bufnr),
        timestamp = (info.lastused or 0) * 1000,
      }
    end
  end
  -- Oldest first, so that the timestamps keep increasing.
  for i = #state.recent, 1, -1 do
    local r = state.recent[i]
    r.timestamp = math.max(r.timestamp, state.last_ts + 1)
    state.last_ts = r.timestamp
  end
  touch_recent(api.nvim_get_current_buf())
end

---Deliver pending changes to subscribers.
local function fire()
  refresh()
  local s = state.latest
  local selection_changed = s ~= nil and not same(s, state.emitted)
  local files_changed = state.files_dirty
  state.files_dirty = false
  if selection_changed then
    state.emitted = s
  end
  if not selection_changed and not files_changed then
    return
  end
  local reason = selection_changed and 'selection' or 'files'
  for _, sub in ipairs(vim.list_slice(subscribers)) do
    if selection_changed or sub.files then
      local ok, err = pcall(sub.fn, s, reason)
      if not ok then
        require('agent.log').log('error', 'selection', 'subscriber failed: %s', tostring(err))
      end
    end
  end
end

local function schedule()
  if state.debounced then
    state.debounced()
  end
end

local function on_mode_changed()
  local ev = vim.v.event or {}
  local was = visual_kind(ev.old_mode or '')
  local is = visual_kind(ev.new_mode or '')
  if is and not was then
    local buf = api.nvim_get_current_buf()
    state.visual_entry = { bufnr = buf, tick = api.nvim_buf_get_changedtick(buf) }
  elseif was and not is then
    flush_visual()
  end
  schedule()
end

---Start tracking (idempotent). Reads `config.selection.debounce_ms`.
function M.start()
  if state.running then
    return
  end
  state.running = true
  local ms = 100
  local ok, cfg = pcall(function()
    return require('agent.config').get().selection.debounce_ms
  end)
  if ok and type(cfg) == 'number' then
    ms = cfg
  end
  state.debounced, state.cancel = util.debounce(ms, function()
    -- A fire already queued with vim.schedule when stop() ran is dropped.
    if state.running then
      fire()
    end
  end)
  local group = api.nvim_create_augroup(GROUP, { clear = true })
  api.nvim_create_autocmd({ 'CursorMoved', 'CursorMovedI', 'TextChanged', 'TextChangedI' }, {
    group = group,
    callback = schedule,
  })
  api.nvim_create_autocmd('ModeChanged', { group = group, callback = on_mode_changed })
  api.nvim_create_autocmd({ 'BufEnter', 'WinEnter' }, {
    group = group,
    callback = function()
      touch_recent(api.nvim_get_current_buf())
      schedule()
    end,
  })
  api.nvim_create_autocmd({ 'BufDelete', 'BufWipeout' }, {
    group = group,
    callback = function(ev)
      forget(ev.buf)
      schedule()
    end,
  })
  api.nvim_create_autocmd('BufFilePost', {
    group = group,
    callback = function(ev)
      renamed(ev.buf)
      schedule()
    end,
  })
  api.nvim_create_autocmd('BufWritePost', {
    group = group,
    callback = function()
      -- A new file now exists on disk, so recent_files() may include it.
      state.files_dirty = true
      schedule()
    end,
  })
  seed()
  schedule()
end

---Stop tracking and clear the tracked state (subscribers stay registered).
function M.stop()
  if not state.running then
    return
  end
  pcall(api.nvim_del_augroup_by_name, GROUP)
  if state.cancel then
    state.cancel()
  end
  state = new_state()
end

---@return boolean
function M.is_running()
  return state.running
end

---Subscribe to debounced changes.
---`fn(s, reason)`: `reason` is 'selection' when the selection changed (path, text, start or finish),
---or 'files' when only the recent-files list changed. Plain subscribers only get 'selection' events,
---and then `s` is never nil; subscribers with `opts.files = true` also get 'files' events (`s` may be nil).
---@param fn fun(s: agent.Selection|nil, reason: 'selection'|'files')
---@param opts? { files?: boolean }
---@return fun() unsubscribe
function M.subscribe(fn, opts)
  local sub = { fn = fn, files = opts and opts.files or false }
  subscribers[#subscribers + 1] = sub
  return function()
    for i, s in ipairs(subscribers) do
      if s == sub then
        table.remove(subscribers, i)
        return
      end
    end
  end
end

---Run the debounced update now (skips the wait). Subscribers are called if anything changed.
function M.flush()
  fire()
end

---The latest selection in a file buffer. When the current window shows a trackable buffer, the
---selection is computed now (`live` = true); otherwise (e.g. the agent terminal has focus) the last
---known selection is returned (`live` = false).
---@return agent.Selection|nil s, boolean live
function M.current()
  local s = refresh()
  if s then
    return s, true
  end
  return state.latest, false
end

---@param which integer|string|nil  bufnr or path; nil = current buffer
---@return integer|nil
local function resolve_buf(which)
  if which == nil or which == 0 then
    return api.nvim_get_current_buf()
  end
  if type(which) == 'number' then
    return which
  end
  return context.find_buf(which)
end

---Last selection (visual or cursor) recorded in a buffer.
---@param which integer|string|nil bufnr or path; nil = current buffer
---@return agent.Selection|nil
function M.get(which)
  local b = resolve_buf(which)
  if b == api.nvim_get_current_buf() then
    refresh()
  end
  local e = b and state.per_buf[b]
  return e and e.selection or nil
end

---Last non-empty visual selection recorded in a buffer (kept after the cursor moves on).
---@param which integer|string|nil bufnr or path; nil = current buffer
---@return agent.Selection|nil
function M.last_visual(which)
  local b = resolve_buf(which)
  if b == api.nvim_get_current_buf() then
    refresh()
  end
  local e = b and state.per_buf[b]
  return e and e.visual or nil
end

---Line range of the visual selection, for :AgentSend. In visual/select mode: the live selection.
---Otherwise the selection that was just left (until the cursor moves). When the current buffer is not
---a file (e.g. the agent terminal), the latest non-empty selection in a file buffer, except in
---visual/select mode: a selection in a buffer that is not a file gives nil.
---@return string|nil path, integer|nil start_line, integer|nil end_line  1-based, inclusive
function M.visual_range()
  local buf = api.nvim_get_current_buf()
  local visual = visual_kind(api.nvim_get_mode().mode) ~= nil
  if M.is_trackable(buf) then
    if visual then
      local a, b = vim.fn.line('v'), vim.fn.line('.')
      return api.nvim_buf_get_name(buf), math.min(a, b), math.max(a, b)
    end
    local s = refresh()
    if s and not s.is_empty then
      return s.path, s.start_line, s.end_line
    end
    return nil
  end
  if visual then
    return nil
  end
  local s = state.latest
  if s and not s.is_empty then
    return s.path, s.start_line, s.end_line
  end
  return nil
end

---The most recently focused file buffer that is still valid, if any.
---@return integer|nil bufnr
function M.last_focused_buf()
  for _, r in ipairs(state.recent) do
    if M.is_trackable(r.bufnr) then
      return r.bufnr
    end
  end
  if state.latest and M.is_trackable(state.latest.bufnr) then
    return state.latest.bufnr
  end
  return nil
end

---@param text string
---@param max integer UTF-16 code units
---@return string
local function truncate_utf16(text, max)
  if #text <= max then
    return text -- at most `max` bytes, so at most `max` UTF-16 units
  end
  local ok, len = pcall(vim.str_utfindex, text, 'utf-16')
  if ok and len <= max then
    return text
  end
  local bok, idx = pcall(vim.str_byteindex, text, 'utf-16', max, false)
  if not bok then
    idx = max
  end
  return text:sub(1, idx) .. '... [TRUNCATED]'
end

---Last known cursor of a buffer: from its tracked selection, else a window showing it, else the '" mark.
---@param bufnr integer
---@return agent.Position|nil
local function buf_cursor(bufnr)
  local e = state.per_buf[bufnr]
  if e and e.selection then
    return e.selection.cursor
  end
  for _, w in ipairs(api.nvim_list_wins()) do
    if api.nvim_win_get_buf(w) == bufnr then
      local p = api.nvim_win_get_cursor(w)
      return { line = p[1] - 1, character = p[2] }
    end
  end
  local m = api.nvim_buf_get_mark(bufnr, '"')
  if m[1] > 0 then
    return { line = m[1] - 1, character = m[2] }
  end
  return nil
end

---@class agent.RecentFile
---@field path string
---@field bufnr integer
---@field timestamp integer   wall-clock ms of the last focus (strictly increasing)
---@field is_active boolean|nil  true for the first (most recently focused) entry only
---@field cursor { line: integer, character: integer }|nil  active entry only; 1-BASED line and 1-BASED UTF-16 column
---@field selected_text string|nil  active entry only, when it has a non-empty selection; truncated

---Recently focused files, most recent first (Gemini `ide/contextUpdate.openFiles`). Only loaded file
---buffers whose file exists on disk. The first entry is the active file, even while the agent terminal
---has focus; it carries the cursor and the selected text.
---@param opts? { limit?: integer, max_selected?: integer }  defaults 10 and 16384 (UTF-16 units; '... [TRUNCATED]' is appended)
---@return agent.RecentFile[]
function M.recent_files(opts)
  opts = opts or {}
  local limit = opts.limit or 10
  local max_selected = opts.max_selected or 16384
  seed()
  touch_recent(api.nvim_get_current_buf())
  refresh()
  local out, seen = {}, {}
  for _, r in ipairs(state.recent) do
    if #out >= limit then
      break
    end
    if M.is_trackable(r.bufnr) and not seen[r.path] and context.file_exists(r.path) then
      seen[r.path] = true
      out[#out + 1] = { path = r.path, bufnr = r.bufnr, timestamp = r.timestamp }
    end
  end
  local active = out[1]
  if active then
    active.is_active = true
    local s = state.per_buf[active.bufnr] and state.per_buf[active.bufnr].selection
    local c = buf_cursor(active.bufnr)
    if c then
      local line = api.nvim_buf_get_lines(active.bufnr, c.line, c.line + 1, false)[1] or ''
      local ok, col16 = pcall(vim.str_utfindex, line, 'utf-16', math.min(c.character, #line), false)
      active.cursor = { line = c.line + 1, character = (ok and col16 or c.character) + 1 }
    end
    if s and not s.is_empty and s.mode ~= 'n' then
      active.selected_text = truncate_utf16(s.text, max_selected)
    end
  end
  return out
end

---Reset all state and subscribers (tests).
function M._reset()
  M.stop()
  state = new_state()
  subscribers = {}
end

return M
