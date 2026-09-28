---@mod agent.editor.diff Side-by-side review of an agent's proposed file content
---
--- A diff shows the original on the left and the proposal on the right, in a new tab page (or,
--- with `config.diff.open_in = 'current'`, in a new window pair below the main window, unless that
--- tab page already shows a diff: Neovim would merge the two into one multi-way diff; with no main
--- window, such as beside the agent terminal alone, below one split off for the pair, which closes
--- with the diff, see close_helper()).
--- A diff's own tab page also shows the agent terminal (config.diff.show_terminal), so that the
--- agent stays in sight (by default below original | proposed; original | proposed | agent with a
--- split on the right). agent.terminal.split_here() places that window (on
--- config.terminal.split_side, as large as the terminal's own split) and declines when there is
--- no agent terminal or its layout is float or none. It is one more window on the terminal buffer:
--- the teardown closes it, and any other window of the diff's tab page on the agent terminal (one
--- the user showed there again with :Agent or :AgentOpen), which never stops the agent. Whenever the
--- agent terminal comes into a tab page with a diff, the original and the proposal share the rest.
---  * Left: the file's own buffer when it is loaded and its text equals the file on disk; otherwise
---    a read-only scratch copy of the file on disk (empty for a file that does not exist yet). So an
---    original buffer with unsaved changes is never shown as "the original".
---  * Right: an `acwrite` scratch buffer named `agent-diff://<id>` holding the proposal.
--- Accept: `:w` in the proposed buffer, the accept key, :AgentDiffAccept (accept_current()).
--- Reject: the reject key, :AgentDiffReject (reject_current()), or closing the proposed buffer or
--- the tab page. Every diff resolves exactly once, then its windows, buffers and tab are cleaned up
--- and focus goes back to where it was when the diff opened (if the diff had focus). This module
--- never writes the target file: the agent does that after an accept, and a `:checktime` of the
--- target is scheduled for when the file changes on disk (also after close(id, { watch = true })
--- and watch(path), for writes the user approved elsewhere).
local util = require('agent.util')
local context = require('agent.editor.context')

local M = {}

local api = vim.api
local uv = vim.uv or vim.loop

--- How long to watch the target for the agent's write (after an accept, close(id, { watch = true })
--- or watch(path)), and how often to look.
M.reload_watch_ms = 10000
M.reload_poll_ms = 100

local GROUP = api.nvim_create_augroup('AgentDiff', { clear = true })

---@alias agent.DiffTrigger 'user'|'agent'|'closed'|'disconnect'|'replaced'

---@class agent.DiffResult
---@field status 'accepted'|'rejected'
---@field content string|nil  accepted: the proposed buffer's text including the user's edits; nil when rejected
---@field trigger agent.DiffTrigger
---@field id string
---@field path string

---@class agent.DiffOpenOpts
---@field id string                 unique key (tab_name / file path); opening an existing id replaces that diff
---@field path string               absolute path of the target file (may not exist)
---@field new_contents string       the complete proposed file
---@field title? string             label shown in the proposed window's winbar
---@field on_resolve? fun(res: agent.DiffResult)  called exactly once (unless closed with close(id) without resolve)
---@field editable? boolean         default true; false makes the proposed buffer 'nomodifiable' (Copilot)
---@field focus? boolean            default true; false leaves the cursor where it is
---@field owner? any                opaque tag (e.g. a client/session id) for list()/close_all() filtering
---@field accept_empty? boolean     default true; false refuses to accept an empty proposal (Gemini)

---@type table<string, table>
local diffs = {}
local seq = 0
-- Depth of our own autocmd handlers: window changes are not allowed there, so teardown is deferred.
local handler_depth = 0
---@type table<string, { timer: uv.uv_timer_t, before: string, until_ms: number }>  absolute path -> watcher
local watchers = {}

---@param text string
---@return string[] lines, boolean eol, boolean crlf
local function split_text(text)
  local lf = select(2, text:gsub('\n', ''))
  local crlf_count = select(2, text:gsub('\r\n', ''))
  local crlf = lf > 0 and lf == crlf_count
  local sep = crlf and '\r\n' or '\n'
  local eol = #text >= #sep and text:sub(-#sep) == sep
  local body = eol and text:sub(1, #text - #sep) or text
  return vim.split(body, sep, { plain = true }), eol, crlf
end

---@param path string
---@return string|nil data, string|nil err  data is nil (no error) when the file does not exist
local function read_file(path)
  local st = uv.fs_stat(path)
  if not st then
    return nil, nil
  end
  if st.type ~= 'file' then
    return nil, path .. ' is not a regular file'
  end
  local f, err = io.open(path, 'rb')
  if not f then
    return nil, err
  end
  local data = f:read('*a') or ''
  f:close()
  return data, nil
end

---@param buf integer
---@param crlf boolean
---@return string
local function buffer_text(buf, crlf)
  local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
  local sep = crlf and '\r\n' or '\n'
  local text = table.concat(lines, sep)
  if vim.bo[buf].eol then
    text = text .. sep
  end
  return text
end

---@param a string[]
---@param b string[]
local function same_lines(a, b)
  if #a ~= #b then
    return false
  end
  for i = 1, #a do
    if a[i] ~= b[i] then
      return false
    end
  end
  return true
end

---@param buf integer
---@param name string
local function set_unique_name(buf, name)
  if pcall(api.nvim_buf_set_name, buf, name) then
    return
  end
  for i = 2, 99 do
    if pcall(api.nvim_buf_set_name, buf, string.format('%s (%d)', name, i)) then
      return
    end
  end
end

---@param buf integer
---@param lines string[]
local function set_lines_no_undo(buf, lines)
  local ul = vim.bo[buf].undolevels
  vim.bo[buf].undolevels = -1
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].undolevels = ul
end

---@param buf integer
---@param path string
---@param lines string[]
local function set_filetype(buf, path, lines)
  local ok, ft = pcall(vim.filetype.match, { filename = path, contents = lines })
  if ok and ft then
    pcall(function()
      vim.bo[buf].filetype = ft
    end)
  end
end

---@param s string
local function winbar_escape(s)
  return (s:gsub('%%', '%%%%'))
end

---@param win integer|nil
local function win_valid(win)
  return win ~= nil and api.nvim_win_is_valid(win)
end

---@param buf integer|nil
local function buf_valid(buf)
  return buf ~= nil and api.nvim_buf_is_valid(buf)
end

---Stat signature used to notice the agent's write.
---@param path string
local function stat_sig(path)
  local st = uv.fs_stat(path)
  if not st then
    return 'missing'
  end
  return string.format('%d.%d:%d:%d', st.mtime.sec, st.mtime.nsec or 0, st.size, st.ino or 0)
end

---Reload the unmodified buffers of `path` from disk. Buffers with unsaved changes are left alone
---(Neovim's own checks warn about them later).
---@param path string
---@param opts? { created?: boolean }  created=true: the file did not exist when its buffer was opened
function M.reload(path, opts)
  local created = opts and opts.created
  local real = context.resolve_path(path)
  for _, b in ipairs(api.nvim_list_bufs()) do
    if api.nvim_buf_is_loaded(b) and context.is_file_buffer(b) and not vim.bo[b].modified
      and context.resolve_path(api.nvim_buf_get_name(b)) == real then
      pcall(api.nvim_buf_call, b, function()
        if created then
          -- :checktime does not reload a buffer whose file was created after it was opened (W13).
          vim.cmd('silent edit')
        else
          -- A local 'autoread' makes :checktime reload silently instead of asking.
          vim.cmd('setlocal autoread')
          vim.cmd('silent! checktime ' .. b)
          vim.cmd('set autoread<')
        end
      end)
    end
  end
end

---@param abs string
local function stop_watcher(abs)
  local w = watchers[abs]
  if not w then
    return
  end
  watchers[abs] = nil
  w.timer:stop()
  if not w.timer:is_closing() then
    w.timer:close()
  end
end

---Poll for the agent's write of the file for reload_watch_ms, then reload its buffers. One watcher
---per path: watching a watched path again only extends it.
---@param abs string
---@param since string|nil  stat signature from before the agent could write (when the diff opened).
---  A file that already differs from it was written before we got here, and is reloaded now.
local function watch_for_write(abs, since)
  local before = stat_sig(abs)
  if since and since ~= before then
    vim.schedule(function()
      M.reload(abs, { created = since == 'missing' })
    end)
  end
  local w = watchers[abs]
  if w then
    w.until_ms = uv.now() + M.reload_watch_ms
    return
  end
  local timer = uv.new_timer()
  if not timer then
    return
  end
  w = { timer = timer, before = before, until_ms = uv.now() + M.reload_watch_ms }
  watchers[abs] = w
  timer:start(M.reload_poll_ms, M.reload_poll_ms, function()
    if watchers[abs] ~= w then
      return
    end
    if stat_sig(abs) ~= before then
      stop_watcher(abs)
      vim.schedule(function()
        M.reload(abs, { created = before == 'missing' })
      end)
    elseif uv.now() >= w.until_ms then
      stop_watcher(abs)
    end
  end)
end

---The agent terminal's buffer, when agent.terminal is loaded and there is one.
---@return integer|nil
local function agent_term_buf()
  local term = package.loaded['agent.terminal']
  if type(term) ~= 'table' or type(term.bufnr) ~= 'function' then
    return nil
  end
  local ok, b = pcall(term.bufnr)
  return ok and type(b) == 'number' and b or nil
end

---Give the original and the proposal equal halves of their width, when they are side by side (the
---agent terminal's window takes its columns from its neighbour only).
---@param d table
local function balance(d)
  if not (win_valid(d.orig_win) and win_valid(d.prop_win))
    or api.nvim_win_get_position(d.orig_win)[1] ~= api.nvim_win_get_position(d.prop_win)[1] then
    return
  end
  local w = api.nvim_win_get_width(d.orig_win) + api.nvim_win_get_width(d.prop_win)
  pcall(api.nvim_win_set_width, d.orig_win, math.floor(w / 2))
end

---The windows of the diff's tab page that show the agent terminal: its own view (split_here()) and
---any other, such as one the user showed there again with :Agent or :AgentOpen, or an agent started
---there. None for a diff without a tab page of its own (open_in = 'current').
---@param d table
---@return { win: integer, buf: integer }[]
local function agent_windows(d)
  local out = {}
  if not (d.tab and api.nvim_tabpage_is_valid(d.tab)) then
    return out
  end
  local bufs = {}
  for _, b in pairs({ d.term_buf or false, agent_term_buf() or false }) do
    if b then
      bufs[b] = true
    end
  end
  for _, w in ipairs(api.nvim_tabpage_list_wins(d.tab)) do
    local b = api.nvim_win_get_buf(w)
    if bufs[b] then
      out[#out + 1] = { win = w, buf = b }
    end
  end
  return out
end

---@param d table
---@return boolean
local function has_focus(d)
  local cur_win = api.nvim_get_current_win()
  if cur_win == d.orig_win or cur_win == d.prop_win or cur_win == d.term_win
    or (d.helper and cur_win == d.helper.win) then
    return true
  end
  if d.tab then
    return api.nvim_get_current_tabpage() == d.tab or not api.nvim_tabpage_is_valid(d.tab)
  end
  return false
end

---The non-floating windows of tab page `tab` (0: the current one) and their sizes.
---@param tab integer
---@return { win: integer, width: integer, height: integer }[]
local function window_sizes(tab)
  local out = {}
  for _, w in ipairs(api.nvim_tabpage_list_wins(tab)) do
    if api.nvim_win_get_config(w).relative == '' then
      local width, height = api.nvim_win_get_width(w), api.nvim_win_get_height(w)
      out[#out + 1] = { win = w, width = width, height = height }
    end
  end
  return out
end

---Close the window build_layout() split off for the pair (d.helper), unless it is in use (it shows
---a file, or text typed into its placeholder: `:edit` names an empty buffer and keeps it) or it is
---the last window of its tab page, and give the windows of that tab page the sizes they had before,
---when they are still the same windows.
---@param d table
---@return integer|nil closed  the window, when closed
local function close_helper(d)
  local h = d.helper
  d.helper = nil
  if not (h and win_valid(h.win) and api.nvim_win_get_buf(h.win) == h.buf and buf_valid(h.buf)
    and api.nvim_buf_get_name(h.buf) == '' and not vim.bo[h.buf].modified) then
    return nil
  end
  local tab = api.nvim_win_get_tabpage(h.win)
  if #window_sizes(tab) < 2 or not pcall(api.nvim_win_close, h.win, true) then
    return nil
  end
  if api.nvim_tabpage_is_valid(tab) then
    local now = window_sizes(tab)
    local same = #now == #h.sizes
    for i = 1, same and #now or 0 do
      same = same and now[i].win == h.sizes[i].win
    end
    -- Twice, as winrestcmd() does: a size set first can be changed by the ones after it.
    for _ = 1, same and 2 or 0 do
      for _, s in ipairs(h.sizes) do
        pcall(api.nvim_win_set_width, s.win, s.width)
        pcall(api.nvim_win_set_height, s.win, s.height)
      end
    end
  end
  return h.win
end

---@param win integer
local function close_window(win)
  if not win_valid(win) then
    return
  end
  if not pcall(api.nvim_win_close, win, true) then
    -- The last window: show an empty buffer instead.
    pcall(api.nvim_win_set_buf, win, api.nvim_create_buf(true, false))
  end
end

---Close the diff's windows (and so its tab page), wipe its scratch buffers, restore focus.
---@param d table
local function teardown(d)
  if d.torn_down then
    return
  end
  d.torn_down = true
  local focused = has_focus(d)

  if buf_valid(d.prop_buf) then
    vim.bo[d.prop_buf].modified = false
  end
  -- The real file buffer stays; leave diff mode first so its window options (remembered per
  -- buffer when the window closes) are restored.
  if d.orig_real and win_valid(d.orig_win) and api.nvim_win_get_buf(d.orig_win) == d.orig_buf then
    pcall(api.nvim_win_call, d.orig_win, function()
      vim.cmd('diffoff')
    end)
    pcall(api.nvim_set_option_value, 'winbar', '', { scope = 'local', win = d.orig_win })
  end

  local to_close = {}
  -- The agent terminal's windows first, so that focus never passes through them on the way out (a
  -- user's BufEnter autocmd could enter Terminal mode): every window of the tab page on the agent
  -- (see agent_windows()), as they were when the diff resolved (a deferred teardown must not take
  -- windows from a tab page that is no longer the diff's). The terminal buffer stays ('bufhidden' =
  -- hide), and so does its job.
  for _, aw in ipairs(d.agent_wins or agent_windows(d)) do
    if win_valid(aw.win) and api.nvim_win_get_buf(aw.win) == aw.buf then
      to_close[#to_close + 1] = aw.win
    end
  end
  if win_valid(d.orig_win) and api.nvim_win_get_buf(d.orig_win) == d.orig_buf then
    to_close[#to_close + 1] = d.orig_win
  end
  for _, b in ipairs({ d.prop_buf, not d.orig_real and d.orig_buf or nil }) do
    if buf_valid(b) then
      for _, w in ipairs(vim.fn.win_findbuf(b)) do
        to_close[#to_close + 1] = w
      end
    end
  end
  local closed = {}
  for _, w in ipairs(to_close) do
    closed[w] = true
    close_window(w)
  end
  for _, b in ipairs({ d.prop_buf, not d.orig_real and d.orig_buf or nil }) do
    if buf_valid(b) then
      pcall(api.nvim_buf_delete, b, { force = true })
    end
  end
  local helper = close_helper(d)
  if helper then
    closed[helper] = true
  end

  -- Diffs opened from this one's windows return focus to where this one came from.
  for _, other in pairs(diffs) do
    if other ~= d and other.prev_win
      and (closed[other.prev_win] or other.prev_win == d.orig_win or other.prev_win == d.prop_win) then
      other.prev_win, other.prev_mode = d.prev_win, d.prev_mode
    end
  end

  if focused and win_valid(d.prev_win) then
    pcall(api.nvim_set_current_win, d.prev_win)
    local b = api.nvim_win_get_buf(d.prev_win)
    if d.prev_mode == 't' and vim.bo[b].buftype == 'terminal' then
      vim.cmd('startinsert')
    end
  elseif focused and d.prev_tab and api.nvim_tabpage_is_valid(d.prev_tab) then
    pcall(api.nvim_set_current_tabpage, d.prev_tab)
  end
end

---@param d table
local function delete_autocmds(d)
  for _, id in ipairs(d.autocmds or {}) do
    pcall(api.nvim_del_autocmd, id)
  end
  d.autocmds = {}
end

---Finish a diff: forget it, optionally call on_resolve, then tear the UI down.
---@param d table
---@param status 'accepted'|'rejected'
---@param trigger agent.DiffTrigger
---@param notify boolean call on_resolve
---@param watch boolean|nil  reload the target when the agent writes it, even though not accepted here
---@return boolean done  false if it was already resolved
local function finish(d, status, trigger, notify, watch)
  if d.resolved then
    return false
  end
  d.resolved = true
  if diffs[d.id] == d then
    diffs[d.id] = nil
  end
  delete_autocmds(d)
  local content = nil
  if status == 'accepted' and buf_valid(d.prop_buf) then
    content = buffer_text(d.prop_buf, d.crlf)
  end
  if status == 'accepted' or watch then
    watch_for_write(d.abs, d.sig)
  end
  -- Before on_resolve and a deferred teardown: what the diff's tab page shows now.
  d.agent_wins = agent_windows(d)
  if notify and d.on_resolve then
    local ok, err = pcall(d.on_resolve, { status = status, content = content, trigger = trigger, id = d.id, path = d.path })
    if not ok then
      require('agent.log').log('error', 'diff', 'on_resolve for %s failed: %s', d.id, tostring(err))
    end
  end
  if handler_depth > 0 then
    vim.schedule(function()
      teardown(d)
    end)
  else
    teardown(d)
  end
  return true
end

---@param d table
---@return boolean ok, string|nil err
local function accept(d)
  if d.resolved then
    return false, 'diff already resolved'
  end
  if d.accept_empty == false and buf_valid(d.prop_buf) and buffer_text(d.prop_buf, d.crlf) == '' then
    local msg = 'the proposed file is empty; reject it instead'
    require('agent.log').notify(msg, vim.log.levels.WARN)
    return false, msg
  end
  finish(d, 'accepted', 'user', true)
  return true, nil
end

---@param d table
local function reject(d)
  if d.resolved then
    return false, 'diff already resolved'
  end
  finish(d, 'rejected', 'user', true)
  return true, nil
end

---@param fn function
local function in_handler(fn)
  return function(...)
    handler_depth = handler_depth + 1
    local ok, err = pcall(fn, ...)
    handler_depth = handler_depth - 1
    if not ok then
      require('agent.log').log('error', 'diff', '%s', tostring(err))
    end
  end
end

---@param d table
local function attach(d)
  local prop = d.prop_buf
  local ids = {}
  ids[#ids + 1] = api.nvim_create_autocmd('BufWriteCmd', {
    group = GROUP,
    buffer = prop,
    callback = in_handler(function(ev)
      if ev.match ~= api.nvim_buf_get_name(prop) then
        require('agent.log').notify('the proposed buffer cannot be written to another file; use :w to accept', vim.log.levels.WARN)
        return
      end
      if accept(d) then
        if buf_valid(prop) then
          vim.bo[prop].modified = false
        end
      end
    end),
  })
  ids[#ids + 1] = api.nvim_create_autocmd({ 'BufWipeout', 'BufDelete', 'BufUnload' }, {
    group = GROUP,
    buffer = prop,
    callback = in_handler(function()
      finish(d, 'rejected', 'closed', true)
    end),
  })
  d.autocmds = ids

  local keys = {}
  local ok, cfg = pcall(function()
    return require('agent.config').get().diff.keymaps
  end)
  if ok and type(cfg) == 'table' then
    keys = cfg
  end
  local bufs = { prop }
  if not d.orig_real then
    bufs[#bufs + 1] = d.orig_buf
  end
  for _, b in ipairs(bufs) do
    if type(keys.accept) == 'string' and keys.accept ~= '' then
      vim.keymap.set('n', keys.accept, function()
        accept(d)
      end, { buffer = b, nowait = true, desc = 'agent.nvim: accept the proposed change' })
    end
    if type(keys.reject) == 'string' and keys.reject ~= '' then
      vim.keymap.set('n', keys.reject, function()
        reject(d)
      end, { buffer = b, nowait = true, desc = 'agent.nvim: reject the proposed change' })
    end
  end
end

---Show the agent terminal in the diff's tab page (config.diff.show_terminal), without focus, and
---give the original and the proposal equal halves of the rest. agent.terminal decides whether it
---can (an agent terminal exists, its layout is split, tab or current) and where the window goes;
---this module only asks it when it is loaded (no agent.terminal, no agent terminal).
---@param d table
local function show_terminal(d)
  local show = true
  pcall(function()
    show = require('agent.config').get().diff.show_terminal ~= false
  end)
  local term = package.loaded['agent.terminal']
  if not show or type(term) ~= 'table' or type(term.split_here) ~= 'function' then
    return
  end
  local ok, win = pcall(term.split_here)
  if not ok or type(win) ~= 'number' or not win_valid(win) then
    return
  end
  d.term_win, d.term_buf = win, api.nvim_win_get_buf(win)
  balance(d)
end

---@param d table
local function build_layout(d)
  d.prev_win = api.nvim_get_current_win()
  d.prev_tab = api.nvim_get_current_tabpage()
  d.prev_mode = api.nvim_get_mode().mode
  local open_in = 'tab'
  pcall(function()
    open_in = require('agent.config').get().diff.open_in or 'tab'
  end)

  if open_in == 'current' then
    -- Neovim diffs every 'diff' window of a tab page together: next to another diff (a second
    -- agent diff, :diffsplit, fugitive) this one gets a tab page of its own.
    for _, w in ipairs(api.nvim_tabpage_list_wins(0)) do
      if vim.wo[w].diff then
        open_in = 'tab'
        break
      end
    end
  end

  if open_in == 'current' then
    local main = context.main_window({ create = false })
    if not main then
      -- No editor window in this tab page (the agent terminal alone, say): main_window() splits
      -- one off, with an empty placeholder buffer. It is only there for the pair: the teardown
      -- closes it and gives the other windows their sizes back (see close_helper()).
      local sizes = window_sizes(0)
      main = context.main_window()
      if main then
        d.helper = { win = main, buf = api.nvim_win_get_buf(main), sizes = sizes }
      end
    end
    main = main or d.prev_win
    d.orig_win = api.nvim_open_win(d.orig_buf, false, { split = 'below', win = main })
    d.prop_win = api.nvim_open_win(d.prop_buf, false, { split = 'right', win = d.orig_win })
  else
    vim.cmd('tabnew')
    d.tab = api.nvim_get_current_tabpage()
    d.orig_win = api.nvim_get_current_win()
    -- :tabnew's empty buffer goes away as soon as it is replaced.
    local placeholder = api.nvim_get_current_buf()
    if placeholder ~= d.orig_buf and api.nvim_buf_get_name(placeholder) == '' and not vim.bo[placeholder].modified then
      vim.bo[placeholder].bufhidden = 'wipe'
    end
    api.nvim_win_set_buf(d.orig_win, d.orig_buf)
    d.prop_win = api.nvim_open_win(d.prop_buf, true, { split = 'right', win = d.orig_win })
    vim.t[d.tab].agent_diff = d.id
    -- Before :diffthis and the winbars, so that the new window does not copy them.
    show_terminal(d)
  end

  for _, w in ipairs({ d.orig_win, d.prop_win }) do
    api.nvim_win_call(w, function()
      vim.cmd('diffthis')
    end)
  end

  local keys = {}
  pcall(function()
    keys = require('agent.config').get().diff.keymaps or {}
  end)
  local hints = {}
  if keys.accept and keys.accept ~= '' then
    hints[#hints + 1] = 'accept: :w or ' .. keys.accept
  else
    hints[#hints + 1] = 'accept: :w'
  end
  if keys.reject and keys.reject ~= '' then
    hints[#hints + 1] = 'reject: ' .. keys.reject
  end
  local rel = vim.fn.fnamemodify(d.abs, ':~:.')
  local label = d.title or rel
  vim.wo[d.orig_win].winbar = winbar_escape(' original: ' .. rel .. (d.existed and '' or ' (new file)'))
  -- In a narrow window the label is truncated (%<), not the accept/reject hints.
  vim.wo[d.prop_win].winbar = winbar_escape(' proposed' .. (d.editable and '' or ' (read-only)') .. ': ')
    .. '%<' .. winbar_escape(label) .. ' %=' .. winbar_escape(table.concat(hints, '  ') .. ' ')

  if d.focus then
    local m = d.prev_mode:sub(1, 1)
    if m == 'i' or m == 't' or m == 'R' then
      vim.cmd('stopinsert')
    end
    api.nvim_set_current_win(d.prop_win)
  elseif win_valid(d.prev_win) then
    api.nvim_set_current_win(d.prev_win)
  end
end

---Open a diff for review.
---@param opts agent.DiffOpenOpts
---@return boolean ok, string|nil err
function M.open(opts)
  vim.validate('opts', opts, 'table')
  vim.validate('id', opts.id, 'string')
  vim.validate('path', opts.path, 'string')
  vim.validate('new_contents', opts.new_contents, 'string')
  vim.validate('on_resolve', opts.on_resolve, 'function', true)

  local old = diffs[opts.id]
  if old then
    finish(old, 'rejected', 'replaced', true)
  end

  local abs = util.abspath(opts.path)
  local sig = stat_sig(abs)
  local disk, err = read_file(abs)
  if err then
    return false, err
  end
  local existed = disk ~= nil
  local orig_lines, _, orig_crlf = split_text(disk or '')
  local new_lines, new_eol, new_crlf = split_text(opts.new_contents)

  seq = seq + 1
  local d = {
    id = opts.id,
    seq = seq,
    path = opts.path,
    abs = abs,
    title = opts.title,
    owner = opts.owner,
    on_resolve = opts.on_resolve,
    editable = opts.editable ~= false,
    focus = opts.focus ~= false,
    accept_empty = opts.accept_empty ~= false,
    existed = existed,
    sig = sig, -- the target's stat signature when the diff opened
    crlf = new_crlf,
    autocmds = {},
  }

  local ok, build_err = pcall(function()
    -- Left side: the real buffer only when it shows exactly what is on disk.
    local real = existed and context.find_buf(abs, { loaded = true })
    if real and same_lines(api.nvim_buf_get_lines(real, 0, -1, false), orig_lines) then
      d.orig_buf, d.orig_real = real, true
    else
      local b = api.nvim_create_buf(false, true)
      d.orig_buf, d.orig_real = b, false
      vim.bo[b].bufhidden = 'wipe'
      vim.b[b].agent_ignore = true
      vim.b[b].agent_diff_id = opts.id
      set_unique_name(b, 'agent-diff://' .. opts.id .. ' (original)')
      set_lines_no_undo(b, orig_lines)
      if orig_crlf then
        vim.bo[b].fileformat = 'dos'
      end
      set_filetype(b, abs, orig_lines)
      vim.bo[b].modified = false
      vim.bo[b].modifiable = false
    end

    local p = api.nvim_create_buf(false, true)
    d.prop_buf = p
    vim.bo[p].buftype = 'acwrite'
    vim.bo[p].bufhidden = 'wipe'
    vim.bo[p].swapfile = false
    vim.b[p].agent_diff_id = opts.id
    set_unique_name(p, 'agent-diff://' .. opts.id)
    if new_crlf then
      vim.bo[p].fileformat = 'dos'
    end
    set_lines_no_undo(p, new_lines)
    vim.bo[p].fixeol = false
    vim.bo[p].eol = new_eol
    set_filetype(p, abs, new_lines)
    vim.bo[p].modified = false
    vim.bo[p].modifiable = d.editable

    build_layout(d)
    attach(d)
  end)
  if not ok then
    d.resolved = true
    delete_autocmds(d)
    teardown(d)
    -- A tab page we created but could not fill.
    if d.tab and api.nvim_tabpage_is_valid(d.tab) then
      for _, w in ipairs(api.nvim_tabpage_list_wins(d.tab)) do
        close_window(w)
      end
    end
    return false, tostring(build_err)
  end
  diffs[opts.id] = d
  return true, nil
end

---Close a diff because the agent asked (no user decision). By default on_resolve is NOT called.
---With watch=true the target's buffers are reloaded if the agent writes the file anyway (the user
---may have approved the change somewhere else, such as the agent's terminal prompt).
---@param id string
---@param opts? { resolve?: boolean, trigger?: agent.DiffTrigger, watch?: boolean }  resolve=true: call on_resolve as rejected with `trigger` (default 'agent')
---@return string|nil content  the proposed buffer's current text (the user's edits included); nil if no such diff
function M.close(id, opts)
  opts = opts or {}
  local d = diffs[id]
  if not d then
    return nil
  end
  local content = buf_valid(d.prop_buf) and buffer_text(d.prop_buf, d.crlf) or nil
  finish(d, 'rejected', opts.trigger or 'agent', opts.resolve == true, opts.watch == true)
  return content
end

---Reload the unmodified buffers of `path` if the file changes on disk within reload_watch_ms, for
---example when an agent is about to write it without a diff. Watching a watched path extends it.
---@param path string
function M.watch(path)
  watch_for_write(util.abspath(path), nil)
end

---@param opts? { owner?: any }
---@return string[] ids in the order they were opened
function M.list(opts)
  local all = {}
  for _, d in pairs(diffs) do
    if not (opts and opts.owner ~= nil) or d.owner == opts.owner then
      all[#all + 1] = d
    end
  end
  table.sort(all, function(a, b)
    return a.seq < b.seq
  end)
  local ids = {}
  for i, d in ipairs(all) do
    ids[i] = d.id
  end
  return ids
end

---Close every open diff (optionally only one owner's). Same resolve semantics as close().
---@param opts? { owner?: any, resolve?: boolean, trigger?: agent.DiffTrigger, watch?: boolean }
---@return integer count
function M.close_all(opts)
  local n = 0
  for _, id in ipairs(M.list(opts)) do
    if diffs[id] then
      M.close(id, opts)
      n = n + 1
    end
  end
  return n
end

---@param id string
---@return boolean
function M.is_open(id)
  return diffs[id] ~= nil
end

---@class agent.DiffInfo
---@field id string
---@field path string
---@field title string|nil
---@field owner any
---@field editable boolean
---@field bufnr integer      the proposed buffer
---@field orig_bufnr integer
---@field tabpage integer|nil

---@param id string
---@return agent.DiffInfo|nil
function M.get(id)
  local d = diffs[id]
  if not d then
    return nil
  end
  return {
    id = d.id,
    path = d.path,
    title = d.title,
    owner = d.owner,
    editable = d.editable,
    bufnr = d.prop_buf,
    orig_bufnr = d.orig_buf,
    tabpage = d.tab,
  }
end

---The diff the user is looking at: the current buffer's, else the current tab page's or window's,
---else the only open diff.
---@return table|nil
local function current_diff()
  local buf = api.nvim_get_current_buf()
  local win = api.nvim_get_current_win()
  local tab = api.nvim_get_current_tabpage()
  for _, d in pairs(diffs) do
    if d.prop_buf == buf or (not d.orig_real and d.orig_buf == buf) then
      return d
    end
  end
  for _, d in pairs(diffs) do
    if d.tab == tab or d.orig_win == win or d.prop_win == win then
      return d
    end
  end
  local ids = M.list()
  if #ids == 1 then
    return diffs[ids[1]]
  end
  return nil
end

---Accept the current diff (:AgentDiffAccept).
---@return boolean ok, string|nil err
function M.accept_current()
  local d = current_diff()
  if not d then
    return false, #M.list() == 0 and 'no agent diff is open' or 'not in an agent diff (several are open)'
  end
  return accept(d)
end

---Reject the current diff (:AgentDiffReject).
---@return boolean ok, string|nil err
function M.reject_current()
  local d = current_diff()
  if not d then
    return false, #M.list() == 0 and 'no agent diff is open' or 'not in an agent diff (several are open)'
  end
  return reject(d)
end

---Accept a diff by id, as if the user did.
---@param id string
---@return boolean ok, string|nil err
function M.accept(id)
  local d = diffs[id]
  if not d then
    return false, 'no diff ' .. tostring(id)
  end
  return accept(d)
end

---Reject a diff by id, as if the user did.
---@param id string
---@return boolean ok, string|nil err
function M.reject(id)
  local d = diffs[id]
  if not d then
    return false, 'no diff ' .. tostring(id)
  end
  return reject(d)
end

---Stop the file watchers (tests, exit).
function M._stop_watchers()
  for abs in pairs(watchers) do
    stop_watcher(abs)
  end
end

---The agent terminal came into a window: in a tab page with a diff (shown there again by :Agent or
---:AgentOpen, or an agent started there), the diff's original and proposal share what it leaves.
---@param buf integer  the buffer that came into a window
---@param win integer
local function on_terminal_shown(buf, win)
  if buf ~= agent_term_buf() or not win_valid(win) or api.nvim_win_get_buf(win) ~= buf
    or api.nvim_win_get_config(win).relative ~= '' then
    return
  end
  local tab = api.nvim_win_get_tabpage(win)
  for _, d in pairs(diffs) do
    if win_valid(d.prop_win) and api.nvim_win_get_tabpage(d.prop_win) == tab then
      balance(d)
    end
  end
end

-- A new window on the terminal buffer: curwin is that window while BufWinEnter runs.
api.nvim_create_autocmd('BufWinEnter', {
  group = GROUP,
  callback = function(ev)
    on_terminal_shown(ev.buf, api.nvim_get_current_win())
  end,
})
-- An agent started in a window of its own (the terminal buffer is the agent's only from then on).
api.nvim_create_autocmd('User', {
  group = GROUP,
  pattern = 'AgentTerminalOpen',
  callback = function(ev)
    local buf = type(ev.data) == 'table' and ev.data.bufnr
    if type(buf) == 'number' and api.nvim_buf_is_valid(buf) then
      for _, w in ipairs(vim.fn.win_findbuf(buf)) do
        on_terminal_shown(buf, w)
      end
    end
  end,
})

api.nvim_create_autocmd('VimLeavePre', {
  group = GROUP,
  callback = function()
    M._stop_watchers()
    for _, id in ipairs(M.list()) do
      local d = diffs[id]
      if d then
        d.resolved = true
        diffs[id] = nil
        delete_autocmds(d)
        if d.on_resolve then
          pcall(d.on_resolve, { status = 'rejected', trigger = 'disconnect', id = d.id, path = d.path })
        end
      end
    end
  end,
})

return M
