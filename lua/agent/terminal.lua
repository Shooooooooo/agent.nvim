---@mod agent.terminal The agent terminal (one agent at a time)
---
--- The terminal knows nothing about providers. A launcher function (set with setup() or passed per
--- call) returns an agent.LaunchSpec (see agent.agents.build_launch); this module runs it with
--- jobstart(term=true), shows it in the configured layout, and cleans up on exit. There is a single
--- terminal: opening another agent stops the one it holds (agent.open() asks first).
---
--- One terminal buffer, possibly several windows: besides its own window (the split, float or tab
--- page of the layout, or the window the 'current' layout took over), a view that takes a tab page
--- of its own, like a diff, can show it in one more split (split_here()). Every window is just a
--- view of the buffer: "visible" means shown in the current tab page; toggle() and close() act on
--- the windows of the current tab page (close(): on every window when there is none here); stop()
--- and auto_close hide it in them all. Hiding it never stops the job (the buffer is 'bufhidden' =
--- hide). A window is hidden by closing it, except a window the 'current' layout took over: it
--- remembers the buffer it showed before (w:agent_nvim_prev) and gets that buffer back, and is
--- never closed (see take_window() and hide_window()). A window the user showed the terminal in
--- (CTRL-^, :buffer) is not closed either, with the 'current' layout or when it is the only window
--- of its tab page: it shows its alternate buffer (see keeps_window()). Showing or hiding the
--- terminal never changes a window's alternate buffer or jumplist (see switch_buf()). Neovim sizes
--- a terminal to its largest window, so an extra split is made as large as the terminal's own split
--- (see split_config), and the agent's TUI does not reflow. Every window opened here starts on the
--- last line, so that it follows the output (see follow()).
local config = require('agent.config')
local util = require('agent.util')

local M = {}

local PASTE_START, PASTE_END = '\27[200~', '\27[201~'
---A job that fails this quickly keeps its terminal open (despite auto_close) so the error stays readable.
M.FAIL_FAST_MS = 5000

---@class agent.Term
---@field name string
---@field bufnr integer
---@field job integer
---@field pid integer|nil
---@field spec agent.LaunchSpec
---@field layout string
---@field started number   util.now_ms() at start
---@field exited boolean
---@field exit_code integer|nil
---@field stopping boolean|nil
---@field cleaned boolean|nil

---The agent terminal: running, or finished with its terminal left open. A stopped terminal is
---forgotten at once (its job may still be exiting).
---@type agent.Term|nil
local current = nil

local state = {
  ---@type fun(name: string, opts: table): agent.LaunchSpec|nil, string|nil
  launcher = nil,
  ---@type table<string, boolean>
  notified = {},
  augroup = nil,
}

local info_of -- defined below M.info

local function notify(msg, level)
  vim.notify('agent.nvim: ' .. msg, level or vim.log.levels.INFO)
end

local function tcfg()
  return config.get().terminal
end

---@param t agent.Term|nil
---@return boolean
local function alive(t)
  return t ~= nil and not t.exited and t.job ~= nil
end

---@param t agent.Term|nil
---@return boolean
local function buf_valid(t)
  return t ~= nil and t.bufnr ~= nil and vim.api.nvim_buf_is_valid(t.bufnr)
end

---Windows showing `bufnr`: in the current tabpage when `current_tab`, else everywhere.
---@param bufnr integer
---@param current_tab boolean|nil
---@return integer[]
local function windows_of(bufnr, current_tab)
  local wins = current_tab and vim.api.nvim_tabpage_list_wins(0) or vim.api.nvim_list_wins()
  local out = {}
  for _, w in ipairs(wins) do
    if vim.api.nvim_win_is_valid(w) and vim.api.nvim_win_get_buf(w) == bufnr then
      out[#out + 1] = w
    end
  end
  return out
end

---@param win integer
---@return boolean
local function is_float(win)
  return vim.api.nvim_win_get_config(win).relative ~= ''
end

---The number of non-floating windows in tab page `tab`.
---@param tab integer
---@return integer
local function split_count(tab)
  local n = 0
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
    if not is_float(w) then
      n = n + 1
    end
  end
  return n
end

---The window variable of a window that the 'current' layout took over (see take_window()).
local PREV_VAR = 'agent_nvim_prev'

---@class agent.TermPrev  w:agent_nvim_prev
---@field term integer        the terminal buffer the window was given
---@field buf integer         the buffer it showed before
---@field listed boolean      whether that buffer was listed then (unlisted since: it was deleted)
---@field alt integer|nil     the window's alternate buffer then
---@field view table|nil      winsaveview() of the window then

---What `win` showed before the 'current' layout gave it terminal `term`, or nil.
---@param win integer
---@param term integer
---@return agent.TermPrev|nil
local function prev_of(win, term)
  local ok, prev = pcall(function()
    return vim.w[win][PREV_VAR]
  end)
  if ok and type(prev) == 'table' and prev.term == term then
    return prev
  end
  return nil
end

---The window variable of a window that is one more view of terminal `term`: a window this module
---opened for it (the layout's split, float or tab page, a split of the 'current' layout when it has
---no window to take, split_here()'s), or a window split off one showing it (:split, see
---ensure_autocmds()). Such a window closes when the terminal is hidden (hide_window()).
local VIEW_VAR = 'agent_nvim_view'

---@param win integer
---@param term integer
---@return boolean
local function is_view(win, term)
  local ok, v = pcall(function()
    return vim.w[win][VIEW_VAR]
  end)
  return ok and v == term
end

---Show buffer `buf` in `win`, as :buffer does, but leave the window's alternate buffer (#) and its
---jumplist alone: showing or hiding the agent is none of the user's navigation. (With the terminal
---as a window's #, CTRL-^ would bring the agent back into a window that remembers no buffer.)
---@param win integer
---@param buf integer
---@return boolean ok, string|nil err
local function switch_buf(win, buf)
  local ok, err
  local wok, werr = pcall(vim.api.nvim_win_call, win, function()
    -- :keepalt keepjumps buffer {buf}; its error ("Vim:E37: ...") without a Lua traceback.
    local cmd = { cmd = 'buffer', args = { tostring(buf) }, mods = { keepalt = true, keepjumps = true } }
    ok, err = pcall(vim.api.nvim_cmd, cmd, {})
  end)
  if not wok then
    ok, err = false, werr
  elseif ok and vim.api.nvim_win_get_buf(win) ~= buf then
    ok, err = false, 'the window shows another buffer'
  end
  return ok == true, not ok and tostring(err) or nil
end

---The alternate buffer (#) of `win`, or -1.
---@param win integer
---@return integer
local function alt_of(win)
  return vim.api.nvim_win_call(win, function()
    return vim.fn.bufnr('#')
  end)
end

---Show terminal `term` in `win` in place of the buffer it shows, and remember that buffer (and the
---view: cursor, scroll) in w:agent_nvim_prev, for hide_window().
---@param win integer
---@param term integer
---@return boolean ok, string|nil err
local function take_window(win, term)
  local api = vim.api
  local buf = api.nvim_win_get_buf(win)
  local prev = {
    term = term,
    buf = buf,
    listed = vim.bo[buf].buflisted,
    view = api.nvim_win_call(win, vim.fn.winsaveview),
  }
  local alt = alt_of(win)
  prev.alt = alt > 0 and alt or nil
  local ok, err = switch_buf(win, term)
  if not ok then
    return false, err
  end
  vim.w[win][PREV_VAR] = prev
  return true, nil
end

---A buffer that can come back into a window after the terminal: valid, still listed (unless it
---never was: :bdelete unlists), and not the terminal.
---@param buf integer|nil
---@param term integer
---@param listed boolean|nil  it was listed when remembered
---@return boolean
local function can_restore(buf, term, listed)
  return type(buf) == 'number' and buf > 0 and buf ~= term and vim.api.nvim_buf_is_valid(buf)
    and (listed == false or vim.bo[buf].buflisted)
end

---Show another buffer than terminal `term` in `win`: the first of `bufs` that can come back
---(can_restore(), listed), else a new empty buffer (as :enew would). The window's alternate buffer
---stays as it is (switch_buf()).
---@param win integer
---@param term integer
---@param bufs integer[]
---@return boolean ok
local function show_other(win, term, bufs)
  for _, b in ipairs(bufs) do
    if can_restore(b, term, true) and switch_buf(win, b) then
      return true
    end
  end
  -- Gone, or it cannot come back (e.g. 'winfixbuf' set since).
  local empty = vim.api.nvim_create_buf(true, false)
  if switch_buf(win, empty) then
    return true
  end
  pcall(vim.api.nvim_buf_delete, empty, { force = true })
  return false
end

---Give a window that the 'current' layout took over for terminal `term` the buffer it showed
---before, with its view; when that buffer is gone, the window's alternate buffer (now, else when it
---was taken over); else a new empty buffer. The window is never closed.
---@param win integer
---@param term integer
---@return boolean restored  false when `win` was not taken over for `term`
local function restore_window(win, term)
  local prev = prev_of(win, term)
  if not prev then
    return false
  end
  vim.w[win][PREV_VAR] = nil
  if can_restore(prev.buf, term, prev.listed) and switch_buf(win, prev.buf) then
    if prev.view then
      pcall(vim.api.nvim_win_call, win, function()
        vim.fn.winrestview(prev.view)
      end)
    end
    return true
  end
  local bufs = vim.tbl_filter(function(b)
    return b ~= prev.buf
  end, { alt_of(win), prev.alt })
  return show_other(win, term, bufs)
end

---True when hiding terminal `term` (started with `layout`) keeps `win` and gives it another
---buffer, rather than closing it: a window the 'current' layout took over (w:agent_nvim_prev), or a
---window the user showed the agent in (CTRL-^, :buffer: neither taken over nor a view, see
---VIEW_VAR) when `layout` is 'current' or it is the only (non-floating) window of its tab page.
---@param win integer
---@param term integer
---@param layout string|nil
---@return boolean
local function keeps_window(win, term, layout)
  if prev_of(win, term) then
    return true
  end
  if is_view(win, term) or is_float(win) then
    return false
  end
  return layout == 'current' or split_count(vim.api.nvim_win_get_tabpage(win)) == 1
end

---Hide terminal `term` in a window: a window the 'current' layout took over gets back the buffer it
---showed before (restore_window()); a window the user showed the agent in shows its alternate
---buffer, else a new empty buffer, when keeps_window() says so; any other window is closed, and
---when it is the last one, it shows another buffer instead.
---@param win integer
---@param term integer
---@param layout string|nil  the terminal's layout
local function hide_window(win, term, layout)
  if not vim.api.nvim_win_is_valid(win) then
    return
  end
  if restore_window(win, term) then
    return
  end
  if keeps_window(win, term, layout) and show_other(win, term, { alt_of(win) }) then
    return
  end
  if pcall(vim.api.nvim_win_close, win, true) then
    return
  end
  show_other(win, term, { alt_of(win) })
end

---Hide terminal `t` in windows `wins`: its views first, so that a window kept only as the last
---one of its tab page (keeps_window()) is seen as such. When that closes the current window, the
---cursor goes back to the previous window (CTRL-W p), not to the one Neovim picks by the layout:
---for a split below original | proposed (a diff's tab page), that would be the original, where
---`:w` does not accept.
---@param t agent.Term
---@param wins integer[]
local function hide_windows(t, wins)
  local cur = vim.api.nvim_get_current_win()
  local back
  if vim.tbl_contains(wins, cur) then
    back = vim.fn.win_getid(vim.fn.winnr('#'))
    if back == 0 or back == cur or vim.tbl_contains(wins, back) or is_float(back) then
      back = nil
    end
  end
  local views, others = {}, {}
  for _, w in ipairs(wins) do
    local view = vim.api.nvim_win_is_valid(w) and (is_view(w, t.bufnr) or is_float(w))
    local list = view and views or others
    list[#list + 1] = w
  end
  for _, w in ipairs(vim.list_extend(views, others)) do
    hide_window(w, t.bufnr, t.layout)
  end
  if back and not vim.api.nvim_win_is_valid(cur) and vim.api.nvim_win_is_valid(back)
    and vim.api.nvim_win_get_tabpage(back) == vim.api.nvim_get_current_tabpage() then
    pcall(vim.api.nvim_set_current_win, back)
  end
end

---@param spec agent.LaunchSpec|nil
local function cleanup_spec(spec)
  if spec and spec.cleanup then
    for _, p in ipairs(spec.cleanup) do
      util.remove_dir(p)
    end
  end
end

---@param t agent.Term
local function cleanup_term(t)
  if not t.cleaned then
    t.cleaned = true
    cleanup_spec(t.spec)
  end
end

---@param pattern string
---@param data table
local function fire(pattern, data)
  pcall(vim.api.nvim_exec_autocmds, 'User', { pattern = pattern, data = data, modeline = false })
end

---@param t agent.Term
local function hide_all(t)
  if buf_valid(t) then
    hide_windows(t, windows_of(t.bufnr))
  end
end

---Forget a terminal: hide it in its windows (hide_window()) and wipe its buffer.
---@param t agent.Term
local function discard(t)
  cleanup_term(t)
  if current == t then
    current = nil
  end
  hide_all(t)
  if buf_valid(t) then
    pcall(vim.api.nvim_buf_delete, t.bufnr, { force = true })
  end
end

local function ensure_autocmds()
  if state.augroup then
    return
  end
  state.augroup = vim.api.nvim_create_augroup('agent.terminal', { clear = true })
  vim.api.nvim_create_autocmd('VimLeavePre', {
    group = state.augroup,
    callback = function()
      if current then
        cleanup_term(current)
      end
    end,
  })
  -- A window split off a window on the terminal (:split, CTRL-W v, :tab split) starts as one more
  -- view of it (VIEW_VAR), and stops being one when it shows another buffer (:sbuffer from the
  -- terminal's window starts on the terminal too, then shows its own buffer).
  vim.api.nvim_create_autocmd('WinNew', {
    group = state.augroup,
    callback = function()
      local t = current
      if t and buf_valid(t) and vim.api.nvim_get_current_buf() == t.bufnr then
        vim.w[VIEW_VAR] = t.bufnr
      end
    end,
  })
  vim.api.nvim_create_autocmd('BufWinEnter', {
    group = state.augroup,
    callback = function(ev)
      local view = vim.w[VIEW_VAR]
      if view ~= nil and view ~= ev.buf then
        vim.w[VIEW_VAR] = nil
      end
      -- A window the 'current' layout took over that now shows another buffer (the user left the
      -- terminal with :edit, :buffer, ...) is the user's again: forget what it showed before.
      local prev = vim.w[PREV_VAR]
      if type(prev) == 'table' and prev.term ~= ev.buf then
        vim.w[PREV_VAR] = nil
      end
    end,
  })
end

---Ensure Neovim listens on a server address, so jobs get a usable $NVIM.
---@return string servername
function M.ensure_servername()
  if vim.v.servername == nil or vim.v.servername == '' then
    pcall(vim.fn.serverstart)
  end
  return vim.v.servername or ''
end

---Configure the module.
---@param opts { launcher?: fun(name: string, opts: table): agent.LaunchSpec|nil, string|nil }|nil
function M.setup(opts)
  opts = opts or {}
  if opts.launcher ~= nil then
    state.launcher = opts.launcher
  end
  ensure_autocmds()
end

---Set the function that builds launch specs. It receives (name, open_opts) and returns a spec or nil, err.
---@param fn fun(name: string, opts: table): agent.LaunchSpec|nil, string|nil
function M.set_launcher(fn)
  state.launcher = fn
end

---@param name string
---@param opts table
---@return agent.LaunchSpec|nil, string|nil
local function default_launcher(name, opts)
  return require('agent.agents').build_launch(name, { cwd = opts.cwd, user_args = opts.args })
end

---@param win integer
---@param layout string  'current': a window taken over (take_window()), which gets the user's buffer
---  back later: the options are set for the terminal buffer only (:setlocal), so that the window's
---  own values (for the buffers it shows next) stay the user's
local function style_window(win, layout)
  local wo = layout == 'current' and vim.wo[win][0] or vim.wo[win]
  wo.number = false
  wo.relativenumber = false
  wo.signcolumn = 'no'
  wo.foldcolumn = '0'
  wo.spell = false
  -- Like the window the terminal was started in (Neovim sets it there, not in later windows).
  wo.wrap = false
  if layout == 'split' then
    local side = tcfg().split_side
    if side == 'above' or side == 'below' then
      wo.winfixheight = true
    else
      wo.winfixwidth = true
    end
  end
end

---Put the cursor of `win` on the last line of its buffer, so that the window follows the output.
---Neovim scrolls a terminal window along with the output only while its cursor is on the last line
---(or while it is in Terminal mode); a new window on a terminal buffer starts on line 1 (or where
---a closed window left it), and would show old output and hide the agent's prompt.
---@param win integer
local function follow(win)
  pcall(vim.api.nvim_win_set_cursor, win, { vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(win)), 0 })
end

---nvim_open_win() config for a split of `buf` along the `side` edge of the current tab page.
---Its size is the size of a split that already shows `buf` (in another tab page; the largest, when
---the user resized one), else config.terminal.split_size of the editor. Neovim sizes a terminal
---to its largest window: a window of the same size keeps the agent's TUI from reflowing (or from
---being cut off). A window alone in its tab page (the 'tab' layout) is not a split and is not
---matched, and neither is a window the 'current' layout took over (it has the user's size, which
---can be most of the editor): as for 'tab', the split then shows part of a wider terminal.
---@param buf integer
---@param side string  'right'|'left'|'below'|'above'
---@return table
local function split_config(buf, side)
  local c = tcfg()
  local vertical = side ~= 'above' and side ~= 'below'
  local size
  for _, w in ipairs(windows_of(buf)) do
    if not is_float(w) and not prev_of(w, buf) and split_count(vim.api.nvim_win_get_tabpage(w)) > 1 then
      local width = vim.api.nvim_win_get_width(w)
      -- A split along the same kind of edge: narrower than the editor for left/right, as wide
      -- as the editor for above/below.
      if vertical and width < vim.o.columns then
        size = math.max(size or 0, width)
      elseif not vertical and width == vim.o.columns then
        size = math.max(size or 0, vim.api.nvim_win_get_height(w))
      end
    end
  end
  local wcfg = { split = side, win = -1 }
  if vertical then
    wcfg.width = size or math.max(10, math.floor(vim.o.columns * c.split_size))
  else
    wcfg.height = size or math.max(3, math.floor(vim.o.lines * c.split_size))
  end
  return wcfg
end

---True when the 'current' layout may show the terminal in `win` in place of its buffer: not when
---'winfixbuf' pins its buffer, and not in a diff window (an agent.nvim diff's original or proposal,
---which would break the diff, or any window in diff mode, which would diff the terminal).
---@param win integer
---@return boolean
local function can_take(win)
  if not vim.api.nvim_win_is_valid(win) then
    return false
  end
  local wo = vim.wo[win]
  if wo.winfixbuf or wo.diff then
    return false
  end
  return vim.b[vim.api.nvim_win_get_buf(win)].agent_diff_id == nil
end

---The window the 'current' layout shows the terminal in: the current window, else (see can_take())
---the main editor window of the current tab page (agent.editor.context.main_window(): the previous
---window, else the largest one showing a file). nil when there is none: a split is opened instead.
---@return integer|nil
local function current_target()
  local cur = vim.api.nvim_get_current_win()
  if can_take(cur) then
    return cur
  end
  local ok, main = pcall(function()
    return require('agent.editor.context').main_window({ create = false })
  end)
  if ok and type(main) == 'number' and can_take(main) then
    return main
  end
  return nil
end

---Open a window for `buf` without entering it (except for tabs, which are left again when needed),
---following the output. The 'current' layout takes over a window instead (current_target()); with
---none to take, it opens a split like the 'split' layout.
---@param buf integer
---@param layout string
---@param name string
---@return integer|nil win, string|nil err
local function open_window(buf, layout, name)
  local c = tcfg()
  local ok, win
  local target = layout == 'current' and current_target() or nil
  if target then
    local err
    ok, err = take_window(target, buf)
    win = ok and target or err
  elseif layout == 'float' then
    local f = c.float or {}
    local lines = vim.o.lines - vim.o.cmdheight
    local width = math.max(20, math.min(vim.o.columns - 2, math.floor(vim.o.columns * (f.width or 0.85))))
    local height = math.max(5, math.min(lines - 2, math.floor(lines * (f.height or 0.85))))
    ok, win = pcall(vim.api.nvim_open_win, buf, false, {
      relative = 'editor',
      width = width,
      height = height,
      row = math.max(0, math.floor((lines - height) / 2) - 1),
      col = math.max(0, math.floor((vim.o.columns - width) / 2)),
      border = f.border or 'rounded',
      style = 'minimal',
      title = ' ' .. name .. ' ',
      title_pos = 'center',
    })
  elseif layout == 'tab' then
    local prev = vim.api.nvim_get_current_win()
    ok, win = pcall(function()
      vim.cmd(('tab sbuffer %d'):format(buf))
      return vim.api.nvim_get_current_win()
    end)
    if ok and vim.api.nvim_win_is_valid(prev) then
      pcall(vim.api.nvim_set_current_win, prev)
    end
  else
    ok, win = pcall(vim.api.nvim_open_win, buf, false, split_config(buf, c.split_side or 'right'))
  end
  if not ok then
    return nil, tostring(win)
  end
  if not target then
    vim.w[win][VIEW_VAR] = buf
  end
  style_window(win, target and 'current' or (layout == 'current' and 'split' or layout))
  follow(win)
  return win, nil
end

---@param win integer
local function enter(win)
  vim.api.nvim_set_current_win(win)
  if tcfg().start_insert then
    vim.cmd.startinsert()
  end
end

---Neovim wipes a finished terminal on the next key typed in Terminal mode, and so closes the window
---it is in (unless it is the last one). A window that hiding the terminal keeps (keeps_window():
---one the 'current' layout took over, say) is never closed: a finished terminal there is not left
---in Terminal mode (:AgentClose or :AgentStop hide it).
---@param t agent.Term
local function leave_finished(t)
  local api = vim.api
  if t.exited and current == t and buf_valid(t) and api.nvim_get_current_buf() == t.bufnr
    and keeps_window(api.nvim_get_current_win(), t.bufnr, t.layout)
    and api.nvim_get_mode().mode == 't' then
    vim.cmd('stopinsert')
  end
end

---@param t agent.Term
---@param code integer
local function on_exit(t, code)
  if t.exited then
    return
  end
  t.exited, t.exit_code, t.job_ended = true, code, util.now_ms()
  local elapsed = t.job_ended - t.started
  cleanup_term(t)

  if not t.stopping and buf_valid(t) and t.spec.exit_hints then
    local text
    for _, hint in ipairs(t.spec.exit_hints) do
      if elapsed <= (hint.within_ms or 0) then
        text = text or table.concat(vim.api.nvim_buf_get_lines(t.bufnr, 0, -1, false), '\n')
        for _, pat in ipairs(hint.patterns or {}) do
          if text:find(pat, 1, true) then
            notify(hint.message, vim.log.levels.WARN)
            break
          end
        end
      end
    end
  end

  if t.spec.on_exit then
    local ok, err = pcall(t.spec.on_exit, code, info_of(t))
    if not ok then
      notify(t.name .. ': on_exit hook failed: ' .. tostring(err), vim.log.levels.ERROR)
    end
  end
  fire('AgentTerminalExit', { name = t.name, code = code, bufnr = t.bufnr, session_id = t.spec.session_id })

  -- A stopped terminal is already forgotten. A buffer wiped by hand (:bwipeout!) ends the job with
  -- SIGHUP: there is nothing left to keep open.
  if t.stopping or current ~= t or not buf_valid(t) then
    discard(t)
  elseif tcfg().auto_close then
    if code ~= 0 and elapsed < M.FAIL_FAST_MS then
      notify(('%s exited with code %d; its terminal is left open'):format(t.name, code), vim.log.levels.WARN)
    else
      discard(t)
    end
  end
  leave_finished(t)
end

---@param spec agent.LaunchSpec
---@return table|nil
local function job_env(spec)
  local env = {}
  for k, v in pairs(spec.env or {}) do
    if type(v) == 'string' or type(v) == 'number' then
      env[k] = tostring(v)
    end
  end
  -- Never override Neovim's own NVIM=v:servername with an inherited value (nested Neovim).
  if env.NVIM ~= nil and env.NVIM ~= vim.v.servername then
    env.NVIM = nil
  end
  if next(env) == nil then
    return nil
  end
  return env
end

---@param spec agent.LaunchSpec|nil
local function show_warnings(spec)
  for _, w in ipairs(spec and spec.warnings or {}) do
    local id = w.id or w.msg
    if not state.notified[id] then
      state.notified[id] = true
      notify(w.msg, w.level or vim.log.levels.WARN)
    end
  end
end

---@param name string
---@param opts table
---@return integer|nil bufnr, string|nil err
local function start(name, opts)
  local layout = opts.layout or tcfg().layout
  if layout == 'none' then
    return nil, ('terminal.layout is "none": start %s in your own terminal'):format(name)
  end
  M.ensure_servername()
  local launcher = opts.launch or state.launcher or default_launcher
  local ok, spec, lerr = pcall(launcher, name, opts)
  if not ok then
    return nil, ('%s: launch failed: %s'):format(name, tostring(spec))
  end
  if type(spec) ~= 'table' then
    return nil, lerr or (name .. ': launcher returned no launch spec')
  end
  local argv = spec.argv
  if type(argv) ~= 'table' or type(argv[1]) ~= 'string' or argv[1] == '' then
    cleanup_spec(spec)
    return nil, name .. ': empty command'
  end
  if vim.fn.executable(argv[1]) ~= 1 then
    cleanup_spec(spec)
    return nil, ("%s: executable '%s' not found"):format(name, argv[1])
  end
  local cwd = spec.cwd or vim.fn.getcwd()
  if vim.fn.isdirectory(cwd) ~= 1 then
    cleanup_spec(spec)
    return nil, ("%s: working directory '%s' does not exist"):format(name, cwd)
  end
  show_warnings(spec)

  local prev = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_create_buf(false, false)
  vim.bo[buf].bufhidden = 'hide'
  -- Marked before it shows up anywhere, so that selection tracking, which ignores the agent's
  -- terminal, never takes it for an empty scratch buffer to report.
  vim.b[buf].agent_nvim_agent = name
  local win, werr = open_window(buf, layout, name)
  if not win then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    cleanup_spec(spec)
    return nil, name .. ': cannot open a window: ' .. tostring(werr)
  end

  ---@type agent.Term
  local t = {
    name = name,
    bufnr = buf,
    spec = spec,
    layout = layout,
    started = util.now_ms(),
    exited = false,
  }
  if spec.before_spawn then
    local hok, herr = pcall(spec.before_spawn, spec)
    if not hok then
      notify(name .. ': before_spawn hook failed: ' .. tostring(herr), vim.log.levels.WARN)
    end
  end
  local job_opts = {
    term = true,
    cwd = cwd,
    clear_env = spec.clear_env == true,
    env = job_env(spec),
    on_exit = function(_, code)
      on_exit(t, code)
    end,
  }
  local jok, job = pcall(vim.api.nvim_win_call, win, function()
    return vim.fn.jobstart(argv, job_opts)
  end)
  if not jok or type(job) ~= 'number' or job <= 0 then
    hide_window(win, buf, layout)
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    cleanup_spec(spec)
    local why = not jok and tostring(job) or (job == -1 and 'not executable' or 'invalid arguments')
    return nil, ('%s: cannot start %s: %s'):format(name, argv[1], why)
  end
  t.job = job
  -- The terminal now fills the buffer with its screen's rows.
  follow(win)
  local pok, pid = pcall(vim.fn.jobpid, job)
  t.pid = pok and pid or nil
  current = t
  vim.b[buf].agent_nvim_session = spec.session_id
  vim.api.nvim_create_autocmd('TermEnter', {
    group = state.augroup,
    buffer = buf,
    callback = function()
      leave_finished(t)
    end,
  })

  if opts.focus ~= false then
    enter(win)
  elseif vim.api.nvim_win_is_valid(prev) then
    vim.api.nvim_set_current_win(prev)
  end
  fire('AgentTerminalOpen', { name = name, bufnr = buf, job = job, pid = t.pid, session_id = spec.session_id })
  return buf, nil
end

---Show a running terminal (opening a window if hidden) and focus it unless `focus == false`.
---With the 'tab' layout, from another tab page (a diff's, for one), that is its own tab page when
---it has one: a tab page with the terminal as its only (non-floating) window. With the 'current'
---layout, a terminal shown in another tab page only is shown in the current window too.
---@param t agent.Term
---@param opts table
---@return integer|nil bufnr, string|nil err
local function show(t, opts)
  local win = windows_of(t.bufnr, true)[1]
  if not win and (opts.layout or t.layout) == 'tab' then
    for _, w in ipairs(windows_of(t.bufnr)) do
      if not is_float(w) and split_count(vim.api.nvim_win_get_tabpage(w)) == 1 then
        if opts.focus == false then
          return t.bufnr, nil
        end
        win = w
        break
      end
    end
  end
  if not win then
    local err
    win, err = open_window(t.bufnr, opts.layout or t.layout, t.name)
    if not win then
      return nil, t.name .. ': cannot open a window: ' .. tostring(err)
    end
  end
  if opts.focus ~= false then
    enter(win)
  end
  return t.bufnr, nil
end

---@class agent.TermOpenOpts
---@field focus? boolean      Enter the terminal window (default true). With the 'current' layout the
---                           terminal comes into the current window anyway (unless it falls back to
---                           another one): false leaves the cursor there, without start_insert
---@field layout? 'split'|'float'|'tab'|'current'|'none'  Override config.terminal.layout
---@field args? string[]      Per-launch user args, passed to the launcher
---@field cwd? string         Passed to the launcher
---@field launch? fun(name: string, opts: table): agent.LaunchSpec|nil, string|nil  Override the launcher
---@field silent? boolean     Do not notify errors (they are still returned)

---Stop the agent's job and forget its terminal: its windows close now (a window the 'current'
---layout took over gets its previous buffer back instead), its temp files are removed, and its
---buffer is wiped once the job has exited. A finished terminal left open is wiped.
---@return boolean stopped  false when there was no terminal
function M.stop()
  local t = current
  if not t then
    return false
  end
  t.stopping = true
  if alive(t) then
    current = nil
    cleanup_term(t)
    hide_all(t)
    pcall(vim.fn.jobstop, t.job)
  else
    discard(t)
  end
  return true
end

---Show `name` when it is the agent in the terminal (and still running); otherwise stop the agent in
---the terminal, if any, and start `name`. agent.open() asks before replacing a running agent.
---@param name string
---@param opts agent.TermOpenOpts|nil
---@return integer|nil bufnr, string|nil err
function M.open(name, opts)
  opts = opts or {}
  ensure_autocmds()
  local t = current
  if t and t.name == name and alive(t) and buf_valid(t) then
    return show(t, opts)
  end
  M.stop()
  local buf, err = start(name, opts)
  if not buf and err and not opts.silent then
    notify(err, vim.log.levels.ERROR)
  end
  return buf, err
end

---Hide the terminal; the agent keeps running. When it is shown in the current tab page, only its
---windows there close: inside a diff's tab page, the diff's view of the agent goes and the
---terminal's own window stays. Otherwise its windows in every tab page close (e.g. its own tab
---page, seen from another). A window the 'current' layout took over is not closed: it gets back
---the buffer it showed before (see hide_window()).
---@return boolean closed  true when it was hidden in a window
function M.close()
  local t = current
  if not buf_valid(t) then
    return false
  end
  local wins = windows_of(t.bufnr, true)
  if #wins == 0 then
    wins = windows_of(t.bufnr)
  end
  hide_windows(t, wins)
  return #wins > 0
end

---Show the terminal in one more window, in the current tab page, without entering it: a split
---along the config.terminal.split_side edge, as large as the terminal's own split (see
---split_config: the agent's TUI keeps its size), following the output. For a view that takes a tab
---page of its own, like a diff (config.diff.show_terminal), so that the agent stays in sight. Only
---for the 'split', 'tab' and 'current' layouts: a float would cover the view, and 'none' has no
---terminal. With 'tab' and 'current' the terminal's own window is (usually) no split to match, so
---this one gets config.terminal.split_size, and shows part of a larger terminal. The window is one
---more view of the buffer: closing it (or its tab page) hides nothing else and never stops the
---agent; stop() and auto_close close it with the other windows of the terminal.
---@return integer|nil win, string|nil why  nil when there is no agent terminal (running, or
---  finished and left open), the layout is 'float' or 'none', the terminal is already shown in
---  this tab page, or the window cannot be opened
function M.split_here()
  local t = current
  if not buf_valid(t) then
    return nil, 'no agent terminal'
  end
  if t.layout ~= 'split' and t.layout ~= 'tab' and t.layout ~= 'current' then
    return nil, ('the terminal layout is %q'):format(t.layout)
  end
  if #windows_of(t.bufnr, true) > 0 then
    return nil, 'the terminal is already shown in this tab page'
  end
  local ok, win = pcall(vim.api.nvim_open_win, t.bufnr, false, split_config(t.bufnr, tcfg().split_side or 'right'))
  if not ok then
    return nil, tostring(win)
  end
  vim.w[win][VIEW_VAR] = t.bufnr
  style_window(win, 'split')
  follow(win)
  return win, nil
end

---Hide the terminal when `name` runs in it and it is visible in the current tabpage (its windows in
---the other tab pages stay); else M.open().
---@param name string
---@param opts agent.TermOpenOpts|nil
---@return integer|nil bufnr, string|nil err
function M.toggle(name, opts)
  local t = current
  if t and t.name == name and alive(t) and buf_valid(t) and #windows_of(t.bufnr, true) > 0 then
    hide_windows(t, windows_of(t.bufnr, true))
    return t.bufnr, nil
  end
  return M.open(name, opts)
end

---Type text into the agent's terminal as a bracketed paste.
---@param text string
---@param opts { submit?: boolean, bracketed?: boolean, submit_delay_ms?: integer }|nil
---@return boolean ok, string|nil err
function M.send(text, opts)
  opts = opts or {}
  local t = current
  if not alive(t) then
    return false, 'no agent is running'
  end
  text = text or ''
  local payload = text
  if opts.bracketed ~= false and text ~= '' then
    -- Strip paste delimiters from the text so it cannot end the paste early.
    payload = PASTE_START .. text:gsub('\27%[20[01]~', '') .. PASTE_END
  end
  if payload ~= '' then
    local ok, n = pcall(vim.fn.chansend, t.job, payload)
    if not ok or n == 0 then
      return false, t.name .. ': cannot write to the terminal'
    end
  end
  if opts.submit then
    local job = t.job
    local function submit()
      if alive(t) and t.job == job then
        pcall(vim.fn.chansend, job, '\r')
      end
    end
    -- TUIs may drop an Enter that arrives in the same read as the paste end.
    local delay = opts.submit_delay_ms or 50
    if payload == '' or delay <= 0 then
      submit()
    else
      vim.defer_fn(submit, delay)
    end
  end
  return true, nil
end

---The agent in the terminal (running, or finished with its terminal left open), or nil.
---@return string|nil
function M.name()
  return current and current.name
end

---@return boolean
function M.is_running()
  return alive(current)
end

---True when the terminal is shown in the current tabpage (in any of its windows).
---@return boolean
function M.is_visible()
  local t = current
  return buf_valid(t) and #windows_of(t.bufnr, true) > 0
end

---@return integer|nil
function M.bufnr()
  local t = current
  return buf_valid(t) and t.bufnr or nil
end

---Details about the agent terminal, or nil when there is none.
---@return { name: string, bufnr: integer, job: integer, pid: integer|nil, session_id: string|nil, argv: string[], cwd: string, running: boolean, exit_code: integer|nil, layout: string }|nil
function M.info()
  return current and info_of(current)
end

---@param t agent.Term
---@return table
info_of = function(t)
  return {
    name = t.name,
    bufnr = t.bufnr,
    job = t.job,
    pid = t.pid,
    session_id = t.spec.session_id,
    argv = t.spec.argv,
    cwd = t.spec.cwd,
    running = alive(t),
    exit_code = t.exit_code,
    layout = t.layout,
  }
end

return M
