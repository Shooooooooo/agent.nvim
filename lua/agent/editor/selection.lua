---@mod agent.editor.selection Selection, cursor and recently-focused-file tracking
---
--- Tracks the buffers the user works in (kind()):
---  * files ('file'): file buffers (context.is_file_buffer) and buffers named after a file that
---    exists on disk (:help files), reported by their path;
---  * other buffers ('buffer'): terminals, nofile, quickfix and prompt buffers, file explorers,
---    unnamed scratch buffers, reported as `nvim://buffer/<bufnr>/<label>` (context.buffer_uri(),
---    e.g. nvim://buffer/12/fish), which the $NVIM controller's read_buffer reads;
---  * ignored (nil): the agent's own terminal, agent.nvim's diff buffers (`agent-diff://`), buffers
---    marked with `b:agent_ignore`, and any other buffer in a floating window (pickers, popups,
---    notifications) or in the command-line window. Focusing them keeps the previous context.
--- and keeps:
---  * the latest selection: a live visual/select-mode selection, or the cursor position (always
---    line 0, column 0 in a buffer that is not a file: see cursor_selection());
---  * the last selection of every buffer (get(), last_visual());
---  * the recently focused files with wall-clock focus timestamps (recent_files(); Gemini's
---    `openFiles`; files only). This tracker lives here, not in context.lua, because it shares the
---    autocmds.
--- Subscribers are called on the main loop after `config.selection.debounce_ms` of quiet.
---
--- Leaving Visual mode ("demotion", as in claudecode.nvim): the selection is captured at once and
--- held for a grace period of M.DEMOTE_MS. When it ends, the selection is dropped (the cursor is
--- reported) if a reported window has focus: <Esc>, y, d, >, a click in the file, another file
--- window, a terminal other than the agent's (whose cursor is then reported). If the focus went to
--- an ignored window, typically straight from Visual mode to the agent terminal (<C-w>l, a
--- `<cmd>AgentToggle<cr>` mapping), the selection is kept for the agent until a reported window has
--- focus again. Re-entering Visual mode cancels the grace period. A command line opened from Visual
--- mode (':', which leaves Visual mode first, or a search, which does not), and the command-line
--- window opened from it (q:, <C-f>), pause it: the selection is kept while they are open, and the
--- same decision is made M.DEMOTE_MS after they close, once the command has run: dropped when it
--- left a file window focused (:'<,'>s/../../, a cancelled command line), kept when it moved to the
--- agent terminal. Mode changes inside the command-line window (Insert mode, Visual mode to edit
--- the command) keep it paused.
---
--- An edit decides whether the selection was consumed. When Visual mode ends, the buffer is compared
--- with its state when the selection was last seen in Visual mode (changedtick): an edit since then
--- is an operator that consumed it (d, c, >, J, p, ~...), and the selection is dropped at once, even
--- when an autosave wrote the buffer right after it. The text is not compared: keys typed in a burst
--- are not seen one by one, so the text last seen may be that of a smaller selection. Writes do not
--- count, and edits seen while Visual mode was still active (TextChanged: a formatter, a plugin, a
--- reload) do not either. An operator that changes nothing (u on lowercase text, y) keeps it. In a
--- buffer that is not 'modifiable' (a terminal, whose output changes it) no operator can consume it.
---
--- While the selection is held, extmarks track its region: a change to its text drops it (a command
--- run from Visual mode such as :'<,'>s or !sort, a block insert with I or $A, a formatter), a
--- change elsewhere keeps it where the text moved (a line inserted above). The text is read in the
--- window it was selected in ('list' changes the width of a tab in a block). A blockwise selection
--- made with $ extends to the end of every line, as y yanks it. A selection held in a terminal is
--- kept as it was captured: the user cannot edit a terminal, and its text changes with the output
--- and when its window is resized (lines reflow when the agent split opens).
local util = require('agent.util')
local context = require('agent.editor.context')

local M = {}

local api = vim.api
local uv = vim.uv or vim.loop

local GROUP = 'AgentSelection'
local MAX_TRACKED = 50
-- Extmarks tracking the region of the held selection.
local NS = api.nvim_create_namespace('agent.editor.selection')
local MAXCOL = vim.v.maxcol
-- getregion() width of a blockwise $ region that starts in the first column: to the end of every
-- line (region_type()).
local EOL_WIDTH = 1073741824

---Grace period (ms) after leaving Visual mode before the selection is dropped in a file window.
M.DEMOTE_MS = 50

---@class agent.Position
---@field line integer       0-based
---@field character integer  0-based byte column

---@class agent.Selection
---@field path string          absolute path (the buffer name) of a file; `nvim://buffer/<bufnr>/<label>`
---  for another buffer (context.buffer_uri(), context.is_buffer_uri())
---@field bufnr integer
---@field text string          '' for a cursor-only position
---@field start agent.Position
---@field finish agent.Position  LSP-style end: exclusive column. Linewise: {last_line, #last_line_text}
---@field is_empty boolean     text == ''
---@field mode 'n'|'v'|'V'|'\22'  'n' = cursor only; select modes are reported as their visual equivalent
---@field linewise boolean
---@field cursor agent.Position  cursor position when captured (line 0, column 0 for a cursor-only
---  position in a buffer that is not a file)
---@field start_line integer   1-based first line
---@field end_line integer     1-based last line (inclusive)

local function new_state()
  return {
    running = false,
    latest = nil, ---@type agent.Selection|nil
    emitted = nil, ---@type agent.Selection|nil
    files_dirty = false,
    per_buf = {}, ---@type table<integer, { selection: agent.Selection, visual: agent.Selection|nil }>
    -- The selection just left, during the grace period: { bufnr, win, selection, pos = {row, col},
    -- tick, kind, dollar, ps, pe, beyond, marks }. ps and pe are the first and last corners of its
    -- region (getpos()-style, with the buffer number) where it was last read, marks the extmarks
    -- that follow them (held_stale()).
    held = nil,
    demote_timer = nil, -- uv timer of the grace period (created on first use)
    demote_gen = 0, -- bumped on every (re)arm or stop, so that a callback already queued is ignored
    -- { bufnr, tick, modified, dollar }: the buffer state when the live selection was last seen in
    -- Visual mode, to detect an operator that consumed the selection (flush_visual())
    visual_entry = nil,
    recent = {}, -- MRU of focused file buffers: { bufnr, path, timestamp }
    -- { bufnr, timestamp }: the buffer of the latest selection and when it got it (recent_files()
    -- dates a non-file buffer with it)
    focus = nil,
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

---@param mode string
---@return boolean
local function is_cmdline(mode)
  return mode:sub(1, 1) == 'c'
end

---The command-line window (q:, <C-f> on the command line) is open.
---@return boolean
local function in_cmdwin()
  return vim.fn.getcmdwintype() ~= ''
end

---The agent's own terminal: the buffer of agent.terminal, or one it marked with b:agent_nvim_agent
---(also after the agent exited, while its terminal is left open).
---@param bufnr integer
---@return boolean
local function is_agent_terminal(bufnr)
  if vim.b[bufnr].agent_nvim_agent then
    return true
  end
  local term = package.loaded['agent.terminal']
  if type(term) ~= 'table' or type(term.bufnr) ~= 'function' then
    return false
  end
  local ok, b = pcall(term.bufnr)
  return ok and b == bufnr
end

---How a buffer is reported to the agents, when it has focus in window `win`:
---  'file'    a file buffer, or a buffer named after a file on disk (:help): by its path;
---  'buffer'  another buffer: as `nvim://buffer/<bufnr>/<label>`;
---  nil       ignored (not loaded, the agent's terminal, agent.nvim's diff buffers, b:agent_ignore,
---            the command-line window, or a non-file buffer in a floating window): focusing it
---            keeps the previous context.
---@param bufnr integer
---@param win? integer  the window showing it; without it, floating windows are not considered
---@return 'file'|'buffer'|nil
function M.kind(bufnr, win)
  if not bufnr or not api.nvim_buf_is_valid(bufnr) or not api.nvim_buf_is_loaded(bufnr) then
    return nil
  end
  if context.is_file_buffer(bufnr) then
    return 'file'
  end
  local b = vim.b[bufnr]
  if b.agent_ignore or b.agent_diff_id ~= nil or is_agent_terminal(bufnr)
    or vim.startswith(api.nvim_buf_get_name(bufnr), 'agent-diff://') then
    return nil
  end
  if context.is_disk_file(bufnr) then
    return 'file'
  end
  if win and api.nvim_win_is_valid(win) and api.nvim_win_get_config(win).relative ~= '' then
    return nil
  end
  if in_cmdwin() and bufnr == api.nvim_get_current_buf() then
    return nil
  end
  return 'buffer'
end

---A loaded file buffer (kind() 'file'): reported by its path, and listed in recent_files().
---@param bufnr integer
---@return boolean
function M.is_trackable(bufnr)
  return M.kind(bufnr) == 'file'
end

---The buffer in `win` is reported to the agents (kind() is not nil).
---@param bufnr integer
---@param win? integer
---@return boolean
local function reportable(bufnr, win)
  return M.kind(bufnr, win) ~= nil
end

---The path a buffer is reported under: its name for a file, context.buffer_uri() for another buffer.
---@param bufnr integer
---@return string
function M.path_of(bufnr)
  if M.is_trackable(bufnr) then
    return api.nvim_buf_get_name(bufnr)
  end
  return context.buffer_uri(bufnr)
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

---The cursor as an empty selection. In a buffer that is not a file it is always at line 0, column 0:
---where the cursor is means nothing to the agents (they read such a buffer whole, with read_buffer),
---and in a terminal it follows the output, which would send an event on every debounce.
---@param bufnr integer
---@param win integer|nil
---@param pos? integer[]  {row, col} (default: the cursor of `win`)
---@return agent.Selection
local function cursor_selection(bufnr, win, pos)
  local path = M.path_of(bufnr)
  if context.is_buffer_uri(path) then
    pos = { 1, 0 }
  end
  pos = pos or api.nvim_win_get_cursor(win)
  local p = { line = pos[1] - 1, character = pos[2] }
  return {
    path = path,
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

---A blockwise selection made with $ in the current window: it extends to the end of every line.
---@param kind string|nil
---@return boolean
local function dollar_block(kind)
  return kind == '\22' and vim.fn.getcurpos()[5] == MAXCOL
end

---Run `fn` in a window showing `buf`, `win` first (else any window showing it, else no window):
---getregion() depends on window options ('list' and 'listchars' for the width of a tab,
---'virtualedit'). Returns its first result (nvim_win_call()).
local function in_window(buf, win, fn)
  if not (win and api.nvim_win_is_valid(win) and api.nvim_win_get_buf(win) == buf) then
    win = vim.fn.win_findbuf(buf)[1]
  end
  if not win then
    return api.nvim_buf_call(buf, fn)
  end
  if win == api.nvim_get_current_win() then
    return (fn())
  end
  return api.nvim_win_call(win, fn)
end

---getregion()/getregionpos() type of the region between two positions in the current buffer, in
---the current window.
---@param dollar boolean  blockwise, made with $: every line to its end, as y yanks it
---@return string
local function region_type(p1, p2, kind, dollar)
  if kind ~= '\22' or not dollar then
    return kind
  end
  -- The width of the block, as y computes it: from the left corner to the end of the longest line.
  local ok, width = pcall(function()
    local s = math.min(vim.fn.virtcol({ p1[2], p1[3], p1[4] }, 1)[1], vim.fn.virtcol({ p2[2], p2[3], p2[4] }, 1)[1])
    local ve = api.nvim_get_option_value('virtualedit', {})
    if s <= 1 and not ve:find('all') and not ve:find('block') then
      -- From the first column, with no virtual editing: no line is padded, so any width that
      -- reaches the end of the longest line will do (saves reading every line).
      return EOL_WIDTH
    end
    -- A line that ends before the block starts is padded to the width of the block (and every
    -- line with virtual editing).
    local e = 0
    for l = math.min(p1[2], p2[2]), math.max(p1[2], p2[2]) do
      e = math.max(e, vim.fn.virtcol({ l, '$' }))
    end
    return e - s + 1
  end)
  if ok and type(width) == 'number' and width > 0 then
    return '\22' .. width
  end
  return kind
end

---Text between two getpos()-style positions (in buffer p1[1], 0 = the current one), in the current
---window, or nil when they no longer exist.
---@param rtype string  region_type()
---@return string|nil
local function region_text(p1, p2, rtype)
  local ok, lines = pcall(vim.fn.getregion, p1, p2, { type = rtype })
  if not ok or type(lines) ~= 'table' then
    return nil
  end
  return table.concat(lines, '\n')
end

---@param p integer[]
---@return string
local function vim_pos(p)
  return ('[%d,%d,%d,%d]'):format(p[1], p[2], p[3], p[4])
end

---First and last positions of a region (getregionpos() segment ends), or nil. Only the first and
---last lines matter: a large selection is not converted line by line.
---@return integer[]|nil first, integer[]|nil last
local function region_ends(buf, p1, p2, kind, rtype)
  if kind == 'V' then
    local l1, l2 = math.min(p1[2], p2[2]), math.max(p1[2], p2[2])
    if l1 < 1 or l2 > api.nvim_buf_line_count(buf) then
      return nil
    end
    local last = api.nvim_buf_get_lines(buf, l2 - 1, l2, false)[1] or ''
    return { buf, l1, 1, 0 }, { buf, l2, #last, 0 }
  end
  local ps, pe = p1, p2
  if pe[2] < ps[2] then
    ps, pe = pe, ps
  end
  -- (With 'selection' exclusive, a region that ends in column 1 may be empty.)
  if kind == 'v' and ps[2] ~= pe[2] and not (pe[3] <= 1 and vim.o.selection == 'exclusive') then
    -- The ends of a charwise region depend on its ends only: read them from two-line regions.
    local ok1, a = pcall(vim.fn.getregionpos, ps, { ps[1], ps[2] + 1, 1, 0 }, { type = 'v', exclusive = false })
    local ok2, b = pcall(vim.fn.getregionpos, { pe[1], pe[2] - 1, 1, 0 }, pe, { type = 'v' })
    if not ok1 or not ok2 or type(a) ~= 'table' or type(b) ~= 'table' or #a == 0 or #b == 0 then
      return nil
    end
    return a[1][1], b[#b][2]
  end
  -- Blockwise (the width of the block depends on both corners), or a single line.
  -- (Only the ends are converted to Lua.)
  local template = '{l -> empty(l) ? [] : [l[0][0], l[-1][1]]}(getregionpos(%s, %s, {"type": "%s"}))'
  local expr = template:format(vim_pos(p1), vim_pos(p2), (rtype:gsub('\22', '\\x16')))
  local ok, r = pcall(api.nvim_eval, expr)
  if not ok or type(r) ~= 'table' or #r ~= 2 then
    return nil
  end
  return r[1], r[2]
end

---Start and (exclusive) end of the region between two getpos()-style positions, in the current
---window.
---@return agent.Position|nil start, agent.Position|nil finish
local function region_bounds(buf, p1, p2, kind, rtype)
  local first, last = region_ends(buf, p1, p2, kind, rtype)
  if not first or not last then
    return nil
  end
  local start = { line = first[2] - 1, character = math.max(first[3] - 1, 0) }
  -- getregionpos() ends at the last byte of the last character (1-based), which is the
  -- exclusive 0-based end.
  local finish = { line = last[2] - 1, character = math.max(last[3], 0) }
  if kind == 'V' then
    start.character = 0
  end
  return start, finish
end

---@param buf integer
---@param text string
---@param kind 'v'|'V'|'\22'
---@param start agent.Position
---@param finish agent.Position
---@param cursor agent.Position
---@return agent.Selection
local function make_selection(buf, text, kind, start, finish, cursor)
  return {
    path = M.path_of(buf),
    bufnr = buf,
    text = text,
    start = start,
    finish = finish,
    is_empty = text == '',
    mode = kind,
    linewise = kind == 'V',
    cursor = cursor,
    start_line = start.line + 1,
    end_line = finish.line + 1,
  }
end

---Selection between two getpos()-style positions in the current buffer and window.
---@param dollar boolean  see region_type()
---@return agent.Selection|nil
local function region_selection(bufnr, win, p1, p2, kind, dollar)
  if p1[2] == 0 or p2[2] == 0 then
    return nil
  end
  local rtype = region_type(p1, p2, kind, dollar)
  local text = region_text(p1, p2, rtype)
  if not text then
    return nil
  end
  local start, finish = region_bounds(bufnr, p1, p2, kind, rtype)
  if not start or not finish then
    return nil
  end
  local pos = api.nvim_win_get_cursor(win)
  return make_selection(bufnr, text, kind, start, finish, { line = pos[1] - 1, character = pos[2] })
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

---Stop the grace-period timer. The held selection, if any, stays held.
local function stop_demote_timer()
  state.demote_gen = state.demote_gen + 1
  if state.demote_timer then
    state.demote_timer:stop()
  end
end

---The selection is no longer held: forget it and the extmarks that track its region.
local function release_held()
  local h = state.held
  state.held = nil
  if h and api.nvim_buf_is_valid(h.bufnr) then
    pcall(api.nvim_buf_clear_namespace, h.bufnr, NS, 0, -1)
  end
end

---End the grace period without a decision: the selection just left is no longer held.
local function cancel_demotion()
  stop_demote_timer()
  release_held()
end

---Place the extmarks that follow the corners of the held region (h.ps, h.pe). The first corner
---gets two: text inserted right where the region starts is in it (a block insert with I), whole
---lines inserted there are above it (tracked_region()).
---@param h table
local function mark_held(h)
  pcall(api.nvim_buf_clear_namespace, h.bufnr, NS, 0, -1)
  h.marks, h.beyond = {}, {}
  for i, spec in ipairs({ { h.ps, false }, { h.ps, true }, { h.pe, true } }) do
    local p = spec[1]
    local row = p[2] - 1
    local len = #(api.nvim_buf_get_lines(h.bufnr, row, row + 1, false)[1] or '')
    -- Past the end of the line: a linewise '> mark (v:maxcol), virtual editing.
    local beyond = p[3] - 1 > len
    local col = h.kind == 'V' and 0 or math.min(math.max(p[3] - 1, 0), len)
    local ok, id = pcall(api.nvim_buf_set_extmark, h.bufnr, NS, row, col, { right_gravity = spec[2] })
    h.marks[i] = ok and id or nil
    h.beyond[i] = beyond
  end
end

---The corners of the held region where the extmarks moved them, or nil when they are gone.
---`shifted`: whole lines were inserted right where the region starts, which is also what
---replacing its first line looks like.
---@param h table
---@return integer[]|nil ps, integer[]|nil pe, boolean|nil shifted
local function tracked_region(h)
  local function get(id)
    if not id then
      return nil
    end
    local ok, m = pcall(api.nvim_buf_get_extmark_by_id, h.bufnr, NS, id, {})
    return ok and m[1] and m or nil
  end
  local left, right, last = get(h.marks[1]), get(h.marks[2]), get(h.marks[3])
  if not left or not right or not last then
    return nil
  end
  local shifted = right[1] > left[1] and right[2] == 0
  local function pos(m, p, beyond)
    local col = (h.kind == 'V' or beyond) and p[3] or m[2] + 1
    return { h.bufnr, m[1] + 1, col, p[4] }
  end
  return pos(shifted and right or left, h.ps, h.beyond[1]), pos(last, h.pe, h.beyond[3]), shifted
end

---Remember the buffer state in which the live Visual selection in `buf` was seen: an edit after it
---is an operator that consumed the selection.
---@param buf integer
---@param kind 'v'|'V'|'\22'
local function snapshot(buf, kind)
  state.visual_entry = {
    bufnr = buf,
    tick = api.nvim_buf_get_changedtick(buf),
    modified = vim.bo[buf].modified,
    dollar = dollar_block(kind),
  }
end

---Visual mode is still active: whatever changed the buffer until now (a write, an autosave, a
---formatter, a reload) was not an operator consuming the selection.
local function note_visual()
  local entry = state.visual_entry
  local buf = api.nvim_get_current_buf()
  if not entry or entry.bufnr ~= buf then
    return
  end
  local kind = visual_kind(api.nvim_get_mode().mode)
  if kind then
    snapshot(buf, kind)
  end
end

---The buffer was edited since the snapshot `snap`, not just written. A write changes changedtick
---only when it resets 'modified', so at most once: from a modified buffer to an unmodified one.
---@param snap { tick: integer, modified: boolean }
---@param buf integer
---@return boolean
local function edited_since(snap, buf)
  local delta = api.nvim_buf_get_changedtick(buf) - snap.tick
  if delta == 0 then
    return false
  end
  return vim.bo[buf].modified or delta > (snap.modified and 1 or 0)
end

---Selection in the current window, or nil when it is ignored (kind()).
---@return agent.Selection|nil
local function compute()
  local win = api.nvim_get_current_win()
  local buf = api.nvim_win_get_buf(win)
  if not reportable(buf, win) then
    return nil
  end
  local mode = api.nvim_get_mode().mode
  local kind = visual_kind(mode)
  if kind then
    cancel_demotion()
    snapshot(buf, kind)
    local s = region_selection(buf, win, vim.fn.getpos('v'), vim.fn.getpos('.'), kind, state.visual_entry.dollar)
    return s or cursor_selection(buf, win)
  end
  local held = state.held
  if held then
    if held.bufnr == buf then
      if is_cmdline(mode) then
        -- ':' or a search from Visual mode: held while the command line is open, even though
        -- 'inccommand' and 'incsearch' may change the text or move the cursor meanwhile.
        return held.selection
      end
      local pos = api.nvim_win_get_cursor(win)
      if pos[1] == held.pos[1] and pos[2] == held.pos[2] and api.nvim_buf_get_changedtick(buf) == held.tick then
        return held.selection
      end
    end
    -- The cursor moved or the text changed (y, d, >, a click...), or another reported window has
    -- focus: the selection is dropped before the grace period ends.
    cancel_demotion()
  end
  return cursor_selection(buf, win)
end

---Note the buffer of the latest selection, and when it got it.
---@param bufnr integer
local function note_focus(bufnr)
  if not state.focus or state.focus.bufnr ~= bufnr then
    state.focus = { bufnr = bufnr, timestamp = next_timestamp() }
  end
end

---Recompute the latest selection from the current window (no events).
---@return agent.Selection|nil selection  nil when the current window is ignored
local function refresh()
  local s = compute()
  if s then
    state.latest = s
    remember(s)
    note_focus(s.bufnr)
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

---Called when visual/select mode ends: capture the selection right away, because the mode is
---already Normal (or Cmdline) by the time the debounce fires, and hold it for the grace period.
---@param kind 'v'|'V'|'\22'  the Visual mode that was left
---@param live boolean  Visual mode is still active underneath (a search from Visual mode): read
---  the live positions, as the '< and '> marks still describe the previous selection
---@return boolean held
local function flush_visual(kind, live)
  local win = api.nvim_get_current_win()
  local buf = api.nvim_win_get_buf(win)
  local snap = state.visual_entry
  state.visual_entry = nil
  release_held()
  if not reportable(buf, win) then
    return false
  end
  local p1, p2
  if live then
    p1, p2 = vim.fn.getpos('v'), vim.fn.getpos('.')
  else
    local vm = vim.fn.visualmode()
    if vm ~= '' then
      p1, p2, kind = vim.fn.getpos("'<"), vim.fn.getpos("'>"), visual_kind(vm) or 'v'
    end
  end
  local seen = snap ~= nil and snap.bufnr == buf
  -- $ is seen in the cursor's 'curswant', unless leaving moved the cursor (y): then in the snapshot.
  local dollar = kind == '\22' and (dollar_block(kind) or (seen and snap.dollar == true))
  -- An operator such as d/>/J consumed the selection: the buffer was edited since the selection was
  -- last seen in Visual mode. Only an edit counts, not a write (`:noautocmd write` by an autosave).
  -- The text is not compared: after keys typed in a burst, the selection last seen may be smaller
  -- than the one the operator consumed, and the region left may hold that text again by chance.
  -- No operator edits a buffer that is not 'modifiable' (a terminal changes with its output).
  local consumed = seen and vim.bo[buf].modifiable and edited_since(snap, buf)
  local s = p1 and not consumed and region_selection(buf, win, p1, p2, kind, dollar) or nil
  if not s or s.is_empty then
    -- Nothing to hold: report the cursor now, so that a switch to the agent terminal before the
    -- next debounce does not leave a stale selection behind.
    refresh()
    return false
  end
  p1[1], p2[1] = buf, buf -- held_stale() reads them again, maybe from another window
  local ps, pe = p1, p2
  if p2[2] < p1[2] or (p2[2] == p1[2] and p2[3] < p1[3]) then
    ps, pe = p2, p1
  end
  local h = {
    bufnr = buf,
    win = win,
    selection = s,
    pos = api.nvim_win_get_cursor(win),
    tick = api.nvim_buf_get_changedtick(buf),
    kind = kind,
    dollar = dollar,
    ps = ps,
    pe = pe,
  }
  mark_held(h)
  state.held = h
  state.latest = s
  remember(s)
  note_focus(buf)
  return true
end

---@param a integer[]
---@param b integer[]
---@return boolean
local function same_pos(a, b)
  return a[2] == b[2] and a[3] == b[3]
end

---The text of the held selection changed since it was captured: a command run from Visual mode
---(:'<,'>s, :'<,'>!sort), an Insert-mode edit after a block I or $A, a formatter. The text is read
---where the extmarks moved the region, in the window it was selected in. When the text is intact
---but moved (a line inserted above), the held selection follows it.
---@return boolean
local function held_stale()
  local h = state.held
  if not h then
    return false
  end
  if not api.nvim_buf_is_loaded(h.bufnr) then
    return true
  end
  if vim.bo[h.bufnr].buftype == 'terminal' and not vim.bo[h.bufnr].modifiable then
    -- The user cannot edit a (running) terminal, so nothing can consume the selection: its text
    -- changes with the output, and when its window is resized (the agent split opening: long lines
    -- reflow, blank rows below the prompt go). The selection is kept as it was captured. A finished
    -- terminal made 'modifiable' is checked like any other buffer.
    return false
  end
  local tick = api.nvim_buf_get_changedtick(h.bufnr)
  if tick == h.tick then
    return false
  end
  -- Where the extmarks moved it, else (or also) where it was.
  local candidates = {}
  local ps, pe, shifted = tracked_region(h)
  if ps and pe and pe[2] - ps[2] == h.pe[2] - h.ps[2] then
    candidates[1] = { ps, pe }
  end
  if not candidates[1] or shifted then
    -- The extmarks may have lost the region: its lines were replaced (by a filter, a reload, a
    -- plugin setting lines, even to the same text) or deleted.
    candidates[#candidates + 1] = { h.ps, h.pe }
  end
  -- (nvim_win_call() returns a single value)
  local ok, found = pcall(in_window, h.bufnr, h.win, function()
    for _, c in ipairs(candidates) do
      local rtype = region_type(c[1], c[2], h.kind, h.dollar)
      if region_text(c[1], c[2], rtype) == h.selection.text then
        if same_pos(c[1], h.ps) and same_pos(c[2], h.pe) then
          return { c[1], c[2], h.selection.start, h.selection.finish }
        end
        local start, finish = region_bounds(h.bufnr, c[1], c[2], h.kind, rtype)
        return start and finish and { c[1], c[2], start, finish } or false
      end
    end
    return false
  end)
  if not ok or type(found) ~= 'table' or not found[4] then
    return true
  end
  ps, pe = found[1], found[2]
  local start, finish = found[3], found[4]
  local moved = not same_pos(ps, h.ps) or not same_pos(pe, h.pe)
  h.tick = tick
  if moved then
    local win = api.nvim_win_is_valid(h.win) and api.nvim_win_get_buf(h.win) == h.bufnr and h.win or nil
    local old = h.selection
    local cursor = old.cursor
    if win then
      h.pos = api.nvim_win_get_cursor(win)
      cursor = { line = h.pos[1] - 1, character = h.pos[2] }
    end
    h.selection = make_selection(h.bufnr, old.text, h.kind, start, finish, cursor)
    h.ps, h.pe = ps, pe
    if state.latest == old then
      state.latest = h.selection
    end
    remember(h.selection)
  end
  mark_held(h)
  return false
end

---The cursor of the window the agent sees as the current one, other than one showing `except`: the
---current window when it is reported, else a window of the current tab page showing the most
---recently focused file.
---@param except integer
---@return agent.Selection|nil
local function fallback_cursor(except)
  local cur = api.nvim_get_current_win()
  local buf = api.nvim_win_get_buf(cur)
  if buf ~= except and reportable(buf, cur) then
    return cursor_selection(buf, cur)
  end
  local wins = api.nvim_tabpage_list_wins(0)
  for _, r in ipairs(state.recent) do
    if r.bufnr ~= except and M.is_trackable(r.bufnr) then
      for _, w in ipairs(wins) do
        if api.nvim_win_get_buf(w) == r.bufnr then
          return cursor_selection(r.bufnr, w)
        end
      end
    end
  end
  return nil
end

---`bufnr` is unloaded or deleted: the selection held in it, or last reported in it, is gone. Report
---the cursor of the current reported window or file window instead, or nothing when there is none,
---so that every consumer agrees.
---@param bufnr integer
local function lose(bufnr)
  if state.visual_entry and state.visual_entry.bufnr == bufnr then
    state.visual_entry = nil
  end
  if state.held and state.held.bufnr == bufnr then
    cancel_demotion()
  end
  if state.latest and state.latest.bufnr == bufnr then
    local ok, s = pcall(fallback_cursor, bufnr)
    state.latest = ok and s or nil
    if state.latest then
      remember(state.latest)
      note_focus(state.latest.bufnr)
    end
  end
end

---Drop the held selection now, wherever the focus is: report the cursor of its buffer, as the
---grace period would in a reported window.
local function drop_held()
  local h = state.held
  cancel_demotion()
  if refresh() or not h then
    return -- a reported window has focus: refresh() reported its cursor
  end
  if not reportable(h.bufnr) then
    lose(h.bufnr) -- unloaded
    return
  end
  local win = api.nvim_win_is_valid(h.win) and api.nvim_win_get_buf(h.win) == h.bufnr and h.win or nil
  local s = cursor_selection(h.bufnr, win, not win and h.pos or nil)
  state.latest = s
  remember(s)
  note_focus(h.bufnr)
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
  lose(bufnr)
  for i = #state.recent, 1, -1 do
    if state.recent[i].bufnr == bufnr then
      table.remove(state.recent, i)
      state.files_dirty = true
    end
  end
  state.per_buf[bufnr] = nil
end

---@param bufnr integer
local function renamed(bufnr)
  local kind = M.kind(bufnr)
  if not kind then
    forget(bufnr)
    return
  end
  -- A buffer that is no longer a file (a terminal started in it, say) leaves the recent files.
  local path = kind == 'file' and api.nvim_buf_get_name(bufnr) or nil
  for i = #state.recent, 1, -1 do
    local r = state.recent[i]
    if r.bufnr == bufnr and r.path ~= path then
      if path then
        r.path = path
      else
        table.remove(state.recent, i)
      end
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

---The grace period after leaving Visual mode is over: drop the held selection if a file window has
---focus (refresh() then reports its cursor), keep it (as the latest selection) otherwise.
local function resolve_demotion()
  local held = state.held
  if not held then
    return -- already dropped (the cursor moved, the text changed) or Visual mode again
  end
  if is_cmdline(api.nvim_get_mode().mode) or in_cmdwin() then
    -- A command line or the command-line window is open: decided once they close (on_mode_changed
    -- arms the timer again).
    return
  end
  if held_stale() then
    drop_held() -- a command changed the text, even though it moved to the agent terminal
  else
    release_held()
    refresh()
  end
  schedule()
end

---Start (or restart) the grace period.
local function arm_demotion()
  stop_demote_timer()
  local st, gen = state, state.demote_gen
  st.demote_timer = st.demote_timer or uv.new_timer()
  st.demote_timer:start(M.DEMOTE_MS, 0, function()
    vim.schedule(function()
      if state == st and st.running and st.demote_gen == gen then
        resolve_demotion()
      end
    end)
  end)
end

local function on_mode_changed()
  local ev = vim.v.event or {}
  local old, new = ev.old_mode or '', ev.new_mode or ''
  if state.held and in_cmdwin() then
    -- Editing the command in the command-line window (Insert mode, Visual mode, an operator on
    -- the command line): the selection stays held for the command, the grace period paused.
    stop_demote_timer()
    schedule()
    return
  end
  local was, is = visual_kind(old), visual_kind(new)
  if is then
    -- Visual mode entered, or still active (v -> V, back from a search): see flush_visual().
    local buf = api.nvim_get_current_buf()
    if reportable(buf, api.nvim_get_current_win()) then
      snapshot(buf, is)
    else
      state.visual_entry = nil
    end
    -- Visual mode again (gv, a new selection, back from a search): the live selection counts.
    cancel_demotion()
  elseif was then
    -- Cmdline mode straight from Visual mode (a search, input()) keeps Visual mode active
    -- underneath and returns to it: the selection is held with no grace period until then.
    -- (':' leaves Visual mode first: V -> n -> c.)
    local underneath = is_cmdline(new)
    if flush_visual(was, underneath) and not underneath then
      arm_demotion()
    end
  elseif state.held then
    if held_stale() then
      -- The text changed: a command from Visual mode ran (the terminal gets focus after
      -- :'<,'>s/a/b/), or Insert mode after a block I or $A ends.
      drop_held()
    elseif is_cmdline(new) or in_cmdwin() then
      -- ':' from Visual mode, then maybe the command-line window (c -> n in it, and back to c when
      -- it closes): keep the selection while they are open.
      stop_demote_timer()
    elseif is_cmdline(old) then
      arm_demotion() -- the command runs now: decide once it has
    end
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
    callback = function()
      -- TextChanged in Visual mode: a formatter, an edit by a plugin or a reload, not an operator
      -- (TextChanged after an operator comes once Visual mode has ended).
      note_visual()
      schedule()
    end,
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
  api.nvim_create_autocmd('BufUnload', {
    group = group,
    callback = function(ev)
      if vim.v.exiting ~= vim.NIL then
        return -- every buffer is unloaded on exit
      end
      -- :edit! unloads the buffer too, then reads it again: decide once it is done.
      local st, buf = state, ev.buf
      vim.schedule(function()
        if state == st and st.running and not api.nvim_buf_is_loaded(buf) then
          lose(buf)
          schedule()
        end
      end)
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
      -- A write in Visual mode (an autosave) bumps changedtick with no TextChanged.
      note_visual()
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
  local timer = state.demote_timer
  if timer then
    timer:stop()
    if not timer:is_closing() then
      timer:close()
    end
  end
  release_held()
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

---Whether two selections are the same: path, text and range.
M.same = same

---Keep the selection held since Visual mode ended (what :AgentSend just sent) when its grace
---period ends in a reported window: until the cursor moves or the text changes, as when the focus
---went to the agent terminal.
function M.keep_held()
  if state.held then
    stop_demote_timer()
  end
end

---Run the debounced update now (skips the wait). Subscribers are called if anything changed.
function M.flush()
  fire()
end

---The latest selection. When the current window is reported (kind()), the selection is computed
---now (`live` = true); otherwise (e.g. the agent terminal has focus) the last known selection is
---returned (`live` = false).
---@return agent.Selection|nil s, boolean live
function M.current()
  local s = refresh()
  if s then
    return s, true
  end
  return state.latest, false
end

---The buffer's last Visual selection was a block made with $ (to the end of every line): the marks
---cannot tell (a block may end past a short line without it), the 'curswant' it had can, and gv
---restores it. Read in the current window, which is then left as it was.
---@return boolean
local function visual_dollar()
  local view = vim.fn.winsaveview()
  local ok, want = pcall(function()
    vim.cmd('noautocmd silent normal! gv')
    local w = vim.fn.getcurpos()[5]
    vim.cmd('noautocmd silent normal! \27')
    return w
  end)
  vim.fn.winrestview(view)
  return ok and want == MAXCOL
end

---Only newlines: a range of blank lines, which stands for nothing more than the file.
---@param s agent.Selection|nil
---@return boolean
local function blank(s)
  return not s or s.text:match('^\n*$') ~= nil
end

---The selection :AgentSend sends from the current window, read now (tracking need not run): the
---live Visual selection; else the lines of `range` (linewise, the cursor on the last one), or, when
---the range is the Visual area (`range.visual`: :'<,'>AgentSend), the Visual selection as it was
---made (charwise, blockwise); else the cursor, an empty selection that stands for the file or
---buffer as a whole (at line 0, column 0 in a buffer that is not a file, as tracking reports it; at
---the first line of a range of blank lines). nil when the window is ignored (kind()).
---@param range { line1: integer, line2?: integer, visual?: boolean }|nil  1-based, inclusive
---@return agent.Selection|nil
function M.capture(range)
  local win = api.nvim_get_current_win()
  local buf = api.nvim_win_get_buf(win)
  if not reportable(buf, win) then
    return nil
  end
  local kind = visual_kind(api.nvim_get_mode().mode)
  if kind then
    local s = region_selection(buf, win, vim.fn.getpos('v'), vim.fn.getpos('.'), kind, dollar_block(kind))
    if s and not s.is_empty then
      return s
    end
    return cursor_selection(buf, win)
  end
  if not (range and range.line1) then
    return cursor_selection(buf, win)
  end
  local n = api.nvim_buf_line_count(buf)
  local l1 = math.min(math.max(1, math.floor(range.line1)), n)
  local l2 = math.min(math.max(1, math.floor(range.line2 or range.line1)), n)
  if l2 < l1 then
    l1, l2 = l2, l1
  end
  local s
  if range.visual then
    local vk = visual_kind(vim.fn.visualmode())
    local p1, p2 = vim.fn.getpos("'<"), vim.fn.getpos("'>")
    if vk and p1[2] == l1 and p2[2] == l2 then
      s = region_selection(buf, win, p1, p2, vk, vk == '\22' and visual_dollar())
    end
  end
  if blank(s) then
    s = region_selection(buf, win, { 0, l1, 1, 0 }, { 0, l2, 1, 0 }, 'V', false)
    if s then
      -- As a V selection made downwards would have it (Gemini gets the cursor, not the lines).
      s.cursor = { line = l2 - 1, character = 0 }
    end
  end
  if blank(s) then
    return cursor_selection(buf, win, { l1, 0 })
  end
  return s
end

---@param which integer|string|nil  bufnr, path or nvim://buffer/ id; nil = current buffer
---@return integer|nil
local function resolve_buf(which)
  if which == nil or which == 0 then
    return api.nvim_get_current_buf()
  end
  if type(which) == 'number' then
    return which
  end
  if context.is_buffer_uri(which) then
    return context.bufnr_from_uri(which)
  end
  return context.find_buf(which)
end

---Last selection (visual or cursor) recorded in a buffer.
---@param which integer|string|nil bufnr, path or nvim://buffer/ id; nil = current buffer
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
---@param which integer|string|nil bufnr, path or nvim://buffer/ id; nil = current buffer
---@return agent.Selection|nil
function M.last_visual(which)
  local b = resolve_buf(which)
  if b == api.nvim_get_current_buf() then
    refresh()
  end
  local e = b and state.per_buf[b]
  return e and e.visual or nil
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

---The buffer the agents see as the current one, also while an ignored window (the agent terminal)
---has focus: the buffer of the latest selection when it is not a file (a terminal, say), else the
---most recently focused file buffer (last_focused_buf()).
---@return integer|nil bufnr
function M.active_buf()
  local s = state.latest
  if s and context.is_buffer_uri(s.path) and reportable(s.bufnr) then
    return s.bufnr
  end
  return M.last_focused_buf()
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
---@field path string         absolute path; with opts.buffers, the first entry may be a nvim://buffer/ id
---@field bufnr integer
---@field timestamp integer   wall-clock ms of the last focus (strictly increasing)
---@field is_active boolean|nil  true for the first (most recently focused) entry only
---@field cursor { line: integer, character: integer }|nil  active entry only; 1-BASED line and 1-BASED UTF-16 column
---@field selected_text string|nil  active entry only, when it has a non-empty selection; truncated

---Recently focused files, most recent first (Gemini `ide/contextUpdate.openFiles`). Only loaded file
---buffers whose file exists on disk. The first entry is the active file, even while the agent terminal
---has focus; it carries the cursor and the selected text.
---With `opts.buffers`, when the latest selection is in a buffer that is not a file (a terminal
---other than the agent's, say), that buffer comes first instead, as the active entry, under its
---nvim://buffer/ id and with the newest timestamp; the files follow. It never enters the list of
---recent files: once a file has focus again, it is gone.
---@param opts? { limit?: integer, max_selected?: integer, buffers?: boolean }  defaults 10, 16384 (UTF-16 units; '... [TRUNCATED]' is appended), false
---@return agent.RecentFile[]
function M.recent_files(opts)
  opts = opts or {}
  local limit = opts.limit or 10
  local max_selected = opts.max_selected or 16384
  seed()
  touch_recent(api.nvim_get_current_buf())
  refresh()
  local out, seen = {}, {}
  local latest = state.latest
  local buffer = opts.buffers and limit > 0 and latest and context.is_buffer_uri(latest.path)
    and reportable(latest.bufnr) and latest.bufnr or nil
  if buffer then
    out[1] = { path = M.path_of(buffer), bufnr = buffer, timestamp = 0 }
  end
  for _, r in ipairs(state.recent) do
    if #out >= limit then
      break
    end
    if M.is_trackable(r.bufnr) and not seen[r.path] and context.file_exists(r.path) then
      seen[r.path] = true
      out[#out + 1] = { path = r.path, bufnr = r.bufnr, timestamp = r.timestamp }
    end
  end
  if buffer then
    -- The active entry must be the newest (Gemini sorts the entries by timestamp).
    local ts = state.focus and state.focus.bufnr == buffer and state.focus.timestamp or 0
    for i = 2, #out do
      ts = math.max(ts, out[i].timestamp + 1)
    end
    out[1].timestamp = ts
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

---The recent-files entry (Gemini `openFiles`) of a selection :AgentSend sent: the active entry,
---timestamped now, with the selection's cursor and its text, as recent_files() gives them.
---@param s agent.Selection
---@param max_selected? integer  UTF-16 units (default 16384; '... [TRUNCATED]' is appended)
---@return agent.RecentFile
function M.entry_of(s, max_selected)
  local e = { path = s.path, bufnr = s.bufnr, timestamp = next_timestamp(), is_active = true }
  local c = s.cursor
  if c then
    local line = api.nvim_buf_is_loaded(s.bufnr) and api.nvim_buf_get_lines(s.bufnr, c.line, c.line + 1, false)[1]
      or ''
    local ok, col16 = pcall(vim.str_utfindex, line, 'utf-16', math.min(c.character, #line), false)
    e.cursor = { line = c.line + 1, character = (ok and col16 or c.character) + 1 }
  end
  if not s.is_empty and s.mode ~= 'n' then
    e.selected_text = truncate_utf16(s.text, max_selected or 16384)
  end
  return e
end

---Reset all state and subscribers (tests).
function M._reset()
  M.stop()
  state = new_state()
  subscribers = {}
end

return M
