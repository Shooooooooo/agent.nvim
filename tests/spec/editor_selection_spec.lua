local config = require('agent.config')
local util = require('agent.util')
local sel = require('agent.editor.selection')

local api = vim.api
local dir

local function feed(keys, mode)
  api.nvim_feedkeys(api.nvim_replace_termcodes(keys, true, false, true), mode or 'x', false)
end

---Move with keys, then fire CursorMoved like the main loop would (`nvim -l` does not run it).
local function move(keys)
  feed(keys)
  api.nvim_exec_autocmds('CursorMoved', {})
end

local function write(name, lines)
  local p = dir .. '/' .. name
  vim.fn.writefile(lines, p)
  return p
end

---Edit a file and return its buffer.
local function edit(name, lines)
  local p = write(name, lines)
  vim.cmd('edit ' .. vim.fn.fnameescape(p))
  return api.nvim_get_current_buf(), api.nvim_buf_get_name(0)
end

local function reset_ui()
  if api.nvim_get_mode().mode ~= 'n' then
    feed('<Esc>', 'nx')
  end
  pcall(vim.cmd, 'silent! tabonly!')
  pcall(vim.cmd, 'silent! only!')
  vim.cmd('enew!')
  local cur = api.nvim_get_current_buf()
  for _, b in ipairs(api.nvim_list_bufs()) do
    if b ~= cur then
      pcall(api.nvim_buf_delete, b, { force = true })
    end
  end
end

---A terminal buffer without a job, shown in a new window.
local function open_terminal_window()
  vim.cmd('vsplit')
  local b = api.nvim_create_buf(true, false)
  api.nvim_win_set_buf(0, b)
  api.nvim_open_term(b, {})
  return b
end

describe('editor.selection', function()
  before_each(function()
    config.setup({ selection = { debounce_ms = 20 } })
    dir = vim.fn.tempname()
    util.mkdir_p(dir)
    sel._reset()
    reset_ui()
    sel.start()
  end)

  after_each(function()
    sel._reset()
    reset_ui()
    util.remove_dir(dir)
  end)

  it('reports a cursor-only position (0-based line, byte column)', function()
    local b, path = edit('a.txt', { 'hello', 'world' })
    api.nvim_win_set_cursor(0, { 2, 3 })
    local s, live = sel.current()
    assert.truthy(live)
    assert.eq(path, s.path)
    assert.eq(b, s.bufnr)
    assert.eq('', s.text)
    assert.truthy(s.is_empty)
    assert.eq('n', s.mode)
    assert.same({ line = 1, character = 3 }, s.start)
    assert.same({ line = 1, character = 3 }, s.finish)
    assert.same({ line = 1, character = 3 }, s.cursor)
    assert.eq(2, s.start_line)
    assert.eq(2, s.end_line)
  end)

  it('reports a live charwise selection with an exclusive end, in bytes', function()
    edit('a.txt', { 'héllo world', 'second' })
    api.nvim_win_set_cursor(0, { 1, 0 })
    feed('vl', 'x!')
    assert.eq('v', api.nvim_get_mode().mode)
    local s = sel.current()
    assert.eq('hé', s.text)
    assert.eq('v', s.mode)
    assert.falsy(s.linewise)
    assert.falsy(s.is_empty)
    assert.same({ line = 0, character = 0 }, s.start)
    assert.same({ line = 0, character = 3 }, s.finish, 'é is two bytes')
    feed('j', 'x!') -- keeps the display column of 'é': onto the 'e' of 'second'
    s = sel.current()
    assert.eq('héllo world\nse', s.text)
    assert.same({ line = 1, character = 2 }, s.finish)
    assert.eq(1, s.start_line)
    assert.eq(2, s.end_line)
  end)

  it('reports a backwards selection in document order', function()
    edit('a.txt', { 'abcdef' })
    api.nvim_win_set_cursor(0, { 1, 4 })
    feed('vhh', 'x!')
    local s = sel.current()
    assert.eq('cde', s.text)
    assert.same({ line = 0, character = 2 }, s.start)
    assert.same({ line = 0, character = 5 }, s.finish)
    assert.same({ line = 0, character = 2 }, s.cursor)
  end)

  it('reports linewise selections, including an empty last line', function()
    edit('a.txt', { 'one', 'two', '', 'four' })
    api.nvim_win_set_cursor(0, { 1, 1 })
    feed('Vj', 'x!')
    local s = sel.current()
    assert.eq('one\ntwo', s.text)
    assert.truthy(s.linewise)
    assert.eq('V', s.mode)
    assert.same({ line = 0, character = 0 }, s.start)
    assert.same({ line = 1, character = 3 }, s.finish)
    feed('j', 'x!')
    s = sel.current()
    assert.eq('one\ntwo\n', s.text)
    assert.same({ line = 2, character = 0 }, s.finish)
    assert.eq(3, s.end_line)
  end)

  it('reports blockwise and select-mode selections', function()
    edit('a.txt', { 'abcd', 'efgh' })
    api.nvim_win_set_cursor(0, { 1, 1 })
    feed('<C-v>jl', 'x!')
    local s = sel.current()
    assert.eq('\22', s.mode)
    assert.eq('bc\nfg', s.text)
    assert.same({ line = 0, character = 1 }, s.start)
    assert.same({ line = 1, character = 3 }, s.finish)
    feed('<Esc>')
    api.nvim_win_set_cursor(0, { 2, 0 })
    feed('gh', 'x!')
    assert.eq('s', api.nvim_get_mode().mode)
    s = sel.current()
    assert.eq('v', s.mode)
    assert.eq('e', s.text)
  end)

  it('keeps the selection after leaving visual mode until the cursor moves', function()
    edit('a.txt', { 'one', 'two', 'three' })
    api.nvim_win_set_cursor(0, { 1, 0 })
    feed('vjl<Esc>')
    assert.eq('n', api.nvim_get_mode().mode)
    local s = sel.current()
    assert.eq('one\ntw', s.text)
    assert.eq('v', s.mode)
    move('j')
    s = sel.current()
    assert.truthy(s.is_empty)
    assert.same({ line = 2, character = 1 }, s.start)
    -- the buffer's last visual selection is still available
    assert.eq('one\ntw', sel.last_visual().text)
  end)

  it('drops a selection that an operator consumed', function()
    edit('a.txt', { 'abcdef' })
    api.nvim_win_set_cursor(0, { 1, 0 })
    feed('vld')
    local s = sel.current()
    assert.truthy(s.is_empty)
    assert.eq('cdef', api.nvim_get_current_line())
  end)

  it('emits debounced, deduplicated events', function()
    local events = {}
    sel.subscribe(function(s, reason)
      events[#events + 1] = { s = s, reason = reason }
    end)
    edit('a.txt', { 'one', 'two', 'three' })
    wait_for(function()
      return #events == 1
    end, 1000, 'first event')
    assert.eq('selection', events[1].reason)
    assert.truthy(events[1].s.is_empty)
    -- several quick moves produce one event
    move('j')
    move('j')
    move('l')
    wait_for(function()
      return #events == 2
    end, 1000, 'second event')
    vim.wait(80)
    assert.eq(2, #events)
    assert.same({ line = 2, character = 1 }, events[2].s.start)
    -- no change, no event
    vim.api.nvim_exec_autocmds('CursorMoved', {})
    vim.wait(80)
    assert.eq(2, #events)
    -- a visual selection
    api.nvim_win_set_cursor(0, { 1, 0 })
    feed('Vj', 'x!')
    wait_for(function()
      return #events >= 3 and events[#events].s.text == 'one\ntwo'
    end, 1000, 'visual event')
  end)

  it('captures the selection at the moment of leaving visual mode for the terminal', function()
    local events = {}
    sel.subscribe(function(s)
      events[#events + 1] = s
    end)
    local b = edit('a.txt', { 'one', 'two', 'three' })
    api.nvim_win_set_cursor(0, { 2, 0 })
    -- select and move to the agent terminal faster than the debounce
    feed('vj<Esc>')
    local term = open_terminal_window()
    assert.eq(term, api.nvim_get_current_buf())
    wait_for(function()
      return #events > 0 and events[#events].text == 'two\nt'
    end, 1000, 'visual selection event')
    local s, live = sel.current()
    assert.falsy(live)
    assert.eq(b, s.bufnr)
    assert.eq('two\nt', s.text)
    -- visual_range() from the terminal uses the latest selection
    local path, l1, l2 = sel.visual_range()
    assert.eq(api.nvim_buf_get_name(b), path)
    assert.eq(2, l1)
    assert.eq(3, l2)
  end)

  it('ignores terminal, agent-diff, scratch and help buffers', function()
    local b = edit('a.txt', { 'one', 'two' })
    api.nvim_win_set_cursor(0, { 2, 1 })
    sel.current()
    local term = open_terminal_window()
    assert.falsy(sel.is_trackable(term))
    local s, live = sel.current()
    assert.falsy(live)
    assert.eq(b, s.bufnr)

    local acw = api.nvim_create_buf(false, true)
    vim.bo[acw].buftype = 'acwrite'
    api.nvim_buf_set_name(acw, 'agent-diff://x')
    assert.falsy(sel.is_trackable(acw))
    local scratch = api.nvim_create_buf(true, true)
    assert.falsy(sel.is_trackable(scratch))
    local named_scratch = api.nvim_create_buf(true, false)
    api.nvim_buf_set_name(named_scratch, 'oil:///tmp/')
    assert.falsy(sel.is_trackable(named_scratch))
    api.nvim_win_set_buf(0, acw)
    feed('ggVG', 'x!')
    s, live = sel.current()
    assert.falsy(live)
    assert.eq(b, s.bufnr)
    feed('<Esc>')
    assert.truthy(sel.is_trackable(b))
  end)

  it('remembers the last selection of several buffers', function()
    local a, pa = edit('a.txt', { 'aaa', 'bbb' })
    feed('Vj<Esc>')
    local b, pb = edit('b.txt', { 'xyz' })
    api.nvim_win_set_cursor(0, { 1, 1 })
    feed('vl<Esc>')
    assert.eq('aaa\nbbb', sel.get(a).text)
    assert.eq('aaa\nbbb', sel.get(pa).text)
    assert.eq('aaa\nbbb', sel.last_visual(pa).text)
    assert.eq('yz', sel.get(pb).text)
    assert.eq('yz', sel.get().text)
    feed('0')
    assert.truthy(sel.get(b).is_empty)
    assert.eq('yz', sel.last_visual(b).text)
    assert.eq(nil, sel.get(dir .. '/unknown.txt'))
  end)

  it('visual_range() gives 1-based lines in and just after visual mode', function()
    local _, path = edit('a.txt', { '1', '2', '3', '4' })
    api.nvim_win_set_cursor(0, { 3, 0 })
    feed('vk', 'x!')
    local p, l1, l2 = sel.visual_range()
    assert.eq(path, p)
    assert.eq(2, l1)
    assert.eq(3, l2)
    feed('<Esc>')
    p, l1, l2 = sel.visual_range()
    assert.eq(path, p)
    assert.eq(2, l1)
    assert.eq(3, l2)
    feed('G')
    assert.eq(nil, sel.visual_range())
  end)

  it('visual_range() in Visual mode in a non-file buffer is nil, not an older file selection', function()
    local _, path = edit('a.txt', { '1', '2', '3', '4', '5' })
    api.nvim_win_set_cursor(0, { 3, 0 })
    feed('Vjj', 'x!')
    feed('<Esc>')
    local scratch = api.nvim_create_buf(true, true)
    api.nvim_buf_set_lines(scratch, 0, -1, false, { 'x', 'y', 'z' })
    api.nvim_win_set_buf(0, scratch)
    feed('Vj', 'x!')
    assert.eq(nil, sel.visual_range())
    feed('<Esc>')
    -- Outside Visual mode (e.g. from the agent terminal) the latest file selection still counts.
    local p, l1, l2 = sel.visual_range()
    assert.eq(path, p)
    assert.eq(3, l1)
    assert.eq(5, l2)
  end)

  it('tracks recently focused files with timestamps, active file cursor and selected text', function()
    local a, pa = edit('a.txt', { 'aaa' })
    local b, pb = edit('b.txt', { 'bbb' })
    local c, pc = edit('c.txt', { 'héllo wörld', 'x' })
    api.nvim_win_set_cursor(0, { 1, 7 }) -- on 'w', after the 2-byte 'é'
    local files = sel.recent_files()
    assert.same({ pc, pb, pa }, vim.tbl_map(function(f)
      return f.path
    end, files))
    assert.truthy(files[1].timestamp > files[2].timestamp and files[2].timestamp > files[3].timestamp)
    assert.truthy(files[1].timestamp > 1.7e12, 'wall-clock milliseconds')
    assert.truthy(files[1].is_active)
    assert.eq(nil, files[2].is_active)
    assert.eq(nil, files[2].cursor)
    assert.same({ line = 1, character = 7 }, files[1].cursor, '1-based line and 1-based UTF-16 column')
    assert.eq(nil, files[1].selected_text)
    assert.eq(c, files[1].bufnr)

    feed('v$', 'x!')
    files = sel.recent_files()
    assert.eq('wörld', files[1].selected_text)
    files = sel.recent_files({ max_selected = 2 })
    assert.eq('wö... [TRUNCATED]', files[1].selected_text)
    feed('<Esc>')

    -- refocusing a file moves it to the front
    vim.cmd('buffer ' .. a)
    files = sel.recent_files({ limit = 2 })
    assert.eq(2, #files)
    assert.eq(pa, files[1].path)
    assert.eq(pc, files[2].path)

    -- the agent terminal having focus keeps the last file active
    open_terminal_window()
    files = sel.recent_files()
    assert.eq(pa, files[1].path)
    assert.truthy(files[1].is_active)
    assert.same({ line = 1, character = 1 }, files[1].cursor)

    -- wiped buffers and files that do not exist on disk are left out
    vim.cmd('bwipeout! ' .. b)
    vim.cmd('wincmd p')
    vim.cmd('edit ' .. vim.fn.fnameescape(dir .. '/unsaved.txt'))
    files = sel.recent_files()
    assert.same({ pa, pc }, vim.tbl_map(function(f)
      return f.path
    end, files))
  end)

  it('notifies file subscribers about file-list changes only', function()
    local plain, files_events = {}, {}
    sel.subscribe(function(_, reason)
      plain[#plain + 1] = reason
    end)
    sel.subscribe(function(_, reason)
      files_events[#files_events + 1] = reason
    end, { files = true })
    local a = edit('a.txt', { 'aaa' })
    edit('b.txt', { 'bbb' })
    vim.cmd('buffer ' .. a)
    wait_for(function()
      return #files_events > 0 and #plain > 0
    end, 1000)
    vim.wait(60)
    local n_plain, n_files = #plain, #files_events
    -- wipe the other file while the selection in a.txt stays the same
    local b = vim.fn.bufnr(dir .. '/b.txt')
    vim.cmd('bwipeout! ' .. b)
    wait_for(function()
      return #files_events > n_files
    end, 1000, 'files event')
    assert.eq('files', files_events[#files_events])
    vim.wait(60)
    assert.eq(n_plain, #plain, 'plain subscribers only get selection changes')
  end)

  it('unsubscribe and stop end the events', function()
    local n = 0
    local unsub = sel.subscribe(function()
      n = n + 1
    end)
    edit('a.txt', { 'a', 'b' })
    wait_for(function()
      return n == 1
    end, 1000)
    unsub()
    move('j')
    vim.wait(80)
    assert.eq(1, n)
    local m = 0
    sel.subscribe(function()
      m = m + 1
    end)
    sel.stop()
    assert.falsy(sel.is_running())
    move('k')
    vim.wait(80)
    assert.eq(0, m)
    assert.falsy(pcall(api.nvim_get_autocmds, { group = 'AgentSelection' }), 'augroup deleted')
  end)
end)
