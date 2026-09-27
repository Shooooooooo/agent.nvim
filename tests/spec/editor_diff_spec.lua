local config = require('agent.config')
local util = require('agent.util')
local diff = require('agent.editor.diff')

local api = vim.api
local dir
local notes = {}
local real_notify = vim.notify

local function write(name, lines)
  local p = dir .. '/' .. name
  vim.fn.writefile(lines, p)
  return p
end

local function read(path)
  local f = assert(io.open(path, 'rb'))
  local s = f:read('*a')
  f:close()
  return s
end

local function feed(keys)
  api.nvim_feedkeys(api.nvim_replace_termcodes(keys, true, false, true), 'x', false)
end

local function reset_ui()
  pcall(vim.cmd, 'stopinsert')
  pcall(vim.cmd, 'silent! diffoff!')
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

---Open a diff and collect every on_resolve call.
local function open(opts)
  local calls = {}
  opts.on_resolve = function(res)
    calls[#calls + 1] = res
  end
  local ok, err = diff.open(opts)
  assert.truthy(ok, err)
  return calls
end

local function buf_named(name)
  for _, b in ipairs(api.nvim_list_bufs()) do
    if api.nvim_buf_get_name(b) == name then
      return b
    end
  end
end

local function diff_buffers_left()
  local out = {}
  for _, b in ipairs(api.nvim_list_bufs()) do
    if api.nvim_buf_get_name(b):match('^agent%-diff://') then
      out[#out + 1] = api.nvim_buf_get_name(b)
    end
  end
  return out
end

describe('editor.diff', function()
  before_each(function()
    config.setup({})
    dir = vim.fn.tempname()
    util.mkdir_p(dir)
    diff.reload_poll_ms = 20
    diff.reload_watch_ms = 3000
    notes = {}
    vim.notify = function(msg)
      notes[#notes + 1] = msg
    end
    reset_ui()
  end)

  after_each(function()
    diff.close_all()
    diff._stop_watchers()
    reset_ui()
    util.remove_dir(dir)
    vim.notify = real_notify
  end)

  it('opens a tab with the real buffer on the left and an acwrite proposal on the right', function()
    local path = write('a.lua', { 'local a = 1', 'return a' })
    vim.cmd('edit ' .. vim.fn.fnameescape(path))
    local file_buf = api.nvim_get_current_buf()
    local prev_win = api.nvim_get_current_win()
    open({ id = 'd1', path = path, new_contents = 'local a = 2\nreturn a\n', title = 'my title' })

    assert.eq(2, #api.nvim_list_tabpages())
    local info = diff.get('d1')
    assert.eq(file_buf, info.orig_bufnr, 'left side is the loaded, unmodified file buffer')
    assert.eq(info.tabpage, api.nvim_get_current_tabpage())
    local prop = info.bufnr
    assert.eq(prop, api.nvim_get_current_buf(), 'focus is on the proposal')
    assert.eq('agent-diff://d1', api.nvim_buf_get_name(prop))
    assert.eq('acwrite', vim.bo[prop].buftype)
    assert.truthy(vim.bo[prop].modifiable)
    assert.falsy(vim.bo[prop].modified)
    assert.same({ 'local a = 2', 'return a' }, api.nvim_buf_get_lines(prop, 0, -1, false))
    assert.eq('lua', vim.bo[prop].filetype)
    local wins = api.nvim_tabpage_list_wins(0)
    assert.eq(2, #wins)
    for _, w in ipairs(wins) do
      assert.truthy(vim.wo[w].diff, 'both windows are in diff mode')
    end
    assert.matches('my title', vim.wo[api.nvim_get_current_win()].winbar)
    assert.same({ 'd1' }, diff.list())
    assert.truthy(diff.is_open('d1'))
    assert.truthy(api.nvim_win_is_valid(prev_win))
  end)

  it('truncates a long title in the winbar, not the accept and reject hints', function()
    local path = write('a.lua', { 'local a = 1' })
    local title = '* [Some Agent] a.lua (0123456789abcdef) with a long decorated tab name'
    open({ id = 'd1', path = path, new_contents = 'local a = 2\n', title = title })
    local win = api.nvim_get_current_win()
    local full = api.nvim_eval_statusline(vim.wo[win].winbar, { winid = win, use_winbar = true, maxwidth = 200 }).str
    assert.truthy(full:find(title, 1, true), 'the whole title fits in a wide window')
    local narrow = api.nvim_eval_statusline(vim.wo[win].winbar, { winid = win, use_winbar = true, maxwidth = 64 }).str
    assert.matches('^ proposed: ', narrow)
    assert.matches('accept: :w or <leader>aa  reject: <leader>ad $', narrow)
    assert.falsy(narrow:find(title, 1, true), 'the title is truncated')
  end)

  it('accepts on :w exactly once, cleans up and returns focus', function()
    local path = write('a.txt', { 'one', 'two' })
    vim.cmd('edit ' .. vim.fn.fnameescape(path))
    local file_buf = api.nvim_get_current_buf()
    local prev_win = api.nvim_get_current_win()
    local calls = open({ id = 'd1', path = path, new_contents = 'one\nTWO\n' })
    vim.cmd('write')
    assert.eq(1, #calls)
    assert.same({ status = 'accepted', content = 'one\nTWO\n', trigger = 'user', id = 'd1', path = path }, calls[1])
    wait_for(function()
      return #api.nvim_list_tabpages() == 1
    end, 1000, 'diff tab closed')
    assert.eq(prev_win, api.nvim_get_current_win())
    assert.eq(file_buf, api.nvim_get_current_buf())
    assert.falsy(vim.wo.diff, 'diff mode is off in the original window')
    assert.same({}, diff_buffers_left())
    assert.same({}, diff.list())
    assert.eq('one\ntwo\n', read(path), 'the diff module never writes the target')
    vim.wait(100)
    assert.eq(1, #calls, 'on_resolve is not called again')
  end)

  it('returns the user edits on accept and keeps the final newline state', function()
    local path = write('a.txt', { 'one' })
    local calls = open({ id = 'e', path = path, new_contents = 'one\ntwo' })
    local prop = diff.get('e').bufnr
    assert.falsy(vim.bo[prop].eol, 'no final newline in the proposal')
    api.nvim_buf_set_lines(prop, 1, 2, false, { 'two edited', 'three' })
    assert.truthy(vim.bo[prop].modified)
    vim.cmd('write')
    assert.eq('one\ntwo edited\nthree', calls[1].content)
    assert.eq('accepted', calls[1].status)
  end)

  it('accepts with the accept key and with accept_current()', function()
    local path = write('a.txt', { 'x' })
    local calls = open({ id = 'k', path = path, new_contents = 'y\n' })
    feed('\\aa')
    assert.eq(1, #calls)
    assert.eq('accepted', calls[1].status)
    assert.eq('user', calls[1].trigger)

    local calls2 = open({ id = 'c', path = path, new_contents = 'z\n' })
    local ok = diff.accept_current()
    assert.truthy(ok)
    assert.eq('z\n', calls2[1].content)
    assert.eq(1, #api.nvim_list_tabpages())
  end)

  it('rejects with the reject key and with reject_current()', function()
    local path = write('a.txt', { 'x' })
    local calls = open({ id = 'r', path = path, new_contents = 'y\n' })
    feed('\\ad')
    assert.same({ status = 'rejected', trigger = 'user', id = 'r', path = path }, calls[1])
    wait_for(function()
      return #api.nvim_list_tabpages() == 1
    end, 1000)

    local calls2 = open({ id = 'r2', path = path, new_contents = 'y\n' })
    -- from another window (the only diff is picked)
    vim.cmd('tabprevious')
    assert.truthy(diff.reject_current())
    assert.eq('rejected', calls2[1].status)
    assert.eq(1, #api.nvim_list_tabpages())
    local ok, err = diff.reject_current()
    assert.falsy(ok)
    assert.matches('no agent diff', err)
  end)

  it('rejects when the user closes the tab', function()
    local path = write('a.txt', { 'x' })
    vim.cmd('edit ' .. vim.fn.fnameescape(path))
    local prev_win = api.nvim_get_current_win()
    vim.cmd('tabnew')
    vim.cmd('tabprevious')
    local calls = open({ id = 't', path = path, new_contents = 'y\n' })
    assert.eq(3, #api.nvim_list_tabpages())
    vim.cmd('tabclose')
    wait_for(function()
      return #calls == 1
    end, 1000)
    assert.eq('rejected', calls[1].status)
    assert.eq('closed', calls[1].trigger)
    vim.wait(50)
    assert.eq(2, #api.nvim_list_tabpages())
    assert.eq(prev_win, api.nvim_get_current_win(), 'focus goes back to where the diff was opened from')
    assert.same({}, diff_buffers_left())
    assert.same({}, diff.list())
    assert.eq(1, #calls)
  end)

  it('rejects when the proposed window is closed or the buffer is wiped', function()
    local path = write('a.txt', { 'x' })
    local calls = open({ id = 'q', path = path, new_contents = 'y\n' })
    vim.cmd('quit')
    wait_for(function()
      return #calls == 1 and #api.nvim_list_tabpages() == 1
    end, 1000)
    assert.eq('closed', calls[1].trigger)
    assert.same({}, diff_buffers_left())

    local calls2 = open({ id = 'w', path = path, new_contents = 'y\n' })
    vim.cmd('bwipeout! ' .. diff.get('w').bufnr)
    wait_for(function()
      return #calls2 == 1 and #api.nvim_list_tabpages() == 1
    end, 1000)
    assert.eq('rejected', calls2[1].status)
    assert.eq('closed', calls2[1].trigger)
    assert.same({}, diff_buffers_left())
  end)

  it('shows an empty read-only original for a new file and reloads its buffer after the agent writes', function()
    local path = dir .. '/sub/new.txt'
    vim.fn.mkdir(dir .. '/sub', 'p')
    vim.cmd('edit ' .. vim.fn.fnameescape(path)) -- buffer for a file that does not exist yet
    local file_buf = api.nvim_get_current_buf()
    assert.eq(file_buf, require('agent.editor.context').find_buf(path))
    local calls = open({ id = 'n', path = path, new_contents = 'brand new\n' })
    local info = diff.get('n')
    assert.truthy(info.orig_bufnr ~= file_buf, 'a scratch original is used for a new file')
    local orig = info.orig_bufnr
    assert.eq('agent-diff://n (original)', api.nvim_buf_get_name(orig))
    assert.same({ '' }, api.nvim_buf_get_lines(orig, 0, -1, false))
    assert.falsy(vim.bo[orig].modifiable)
    assert.eq('nofile', vim.bo[orig].buftype)
    assert.matches('new file', vim.wo[vim.fn.bufwinid(orig)].winbar)
    vim.cmd('write')
    assert.eq('brand new\n', calls[1].content)
    wait_for(function()
      return #api.nvim_list_tabpages() == 1
    end, 1000)
    assert.falsy(api.nvim_buf_is_valid(orig), 'scratch original wiped')
    -- the agent writes the file after the accept
    vim.fn.writefile({ 'brand new' }, path)
    wait_for(function()
      return api.nvim_buf_get_lines(file_buf, 0, -1, false)[1] == 'brand new'
    end, 2000, 'buffer reloaded')
  end)

  it('opens a new file with no buffer and does not create one', function()
    local path = dir .. '/none.txt'
    local calls = open({ id = 'nb', path = path, new_contents = '' })
    local prop = diff.get('nb').bufnr
    assert.same({ '' }, api.nvim_buf_get_lines(prop, 0, -1, false))
    assert.falsy(vim.bo[prop].eol)
    vim.cmd('write')
    assert.eq('', calls[1].content)
    assert.falsy(vim.uv.fs_stat(path))
  end)

  it('reloads the unmodified target buffer after an accept once the file changes', function()
    local path = write('r.txt', { 'old' })
    vim.cmd('edit ' .. vim.fn.fnameescape(path))
    local file_buf = api.nvim_get_current_buf()
    open({ id = 'rl', path = path, new_contents = 'new\n' })
    vim.cmd('write')
    vim.wait(50)
    assert.eq('old', api.nvim_buf_get_lines(file_buf, 0, -1, false)[1])
    vim.uv.sleep(10)
    vim.fn.writefile({ 'new' }, path)
    wait_for(function()
      return api.nvim_buf_get_lines(file_buf, 0, -1, false)[1] == 'new'
    end, 2000, 'buffer reloaded')
    assert.falsy(vim.bo[file_buf].modified)
  end)

  it('close(id, { watch = true }) reloads the target when the agent writes it after all', function()
    local path = write('t.txt', { 'old' })
    vim.cmd('edit ' .. vim.fn.fnameescape(path))
    local file_buf = api.nvim_get_current_buf()
    local calls = open({ id = 't', path = path, new_contents = 'new\n' })
    -- e.g. the user approved the edit in the agent's terminal prompt: the agent closes the diff...
    diff.close('t', { resolve = true, watch = true })
    assert.eq('rejected', calls[1].status)
    vim.uv.sleep(10)
    -- ...and then writes the file itself.
    vim.fn.writefile({ 'new' }, path)
    wait_for(function()
      return api.nvim_buf_get_lines(file_buf, 0, -1, false)[1] == 'new'
    end, 2000, 'buffer reloaded')
  end)

  it('close(id, { watch = true }) also reloads when the write came before the close', function()
    local path = write('t2.txt', { 'old' })
    vim.cmd('edit ' .. vim.fn.fnameescape(path))
    local file_buf = api.nvim_get_current_buf()
    open({ id = 't2', path = path, new_contents = 'new\n' })
    vim.uv.sleep(10)
    vim.fn.writefile({ 'new', 'written before the close was handled' }, path)
    diff.close('t2', { resolve = true, watch = true })
    wait_for(function()
      return api.nvim_buf_get_lines(file_buf, 0, -1, false)[1] == 'new'
    end, 2000, 'buffer reloaded')
  end)

  it('watch(path) reloads the unmodified buffers of a file that changes on disk', function()
    local path = write('w.txt', { 'old' })
    vim.cmd('edit ' .. vim.fn.fnameescape(path))
    local file_buf = api.nvim_get_current_buf()
    diff.watch(path)
    diff.watch(path) -- a second watch of the same path is merged into the first
    vim.uv.sleep(10)
    vim.fn.writefile({ 'new' }, path)
    wait_for(function()
      return api.nvim_buf_get_lines(file_buf, 0, -1, false)[1] == 'new'
    end, 2000, 'buffer reloaded')
  end)

  it("open_in = 'current' opens a diff in its own tab page when the tab page already has a diff", function()
    config.setup({ diff = { open_in = 'current' } })
    local p1 = write('one.txt', { 'alpha', 'beta', 'gamma' })
    local p2 = write('two.txt', { 'red', 'green', 'blue' })
    vim.cmd('edit ' .. vim.fn.fnameescape(p1))
    open({ id = 'c1', path = p1, new_contents = 'alpha\nBETA\ngamma\n' })
    assert.eq(1, #api.nvim_list_tabpages())
    open({ id = 'c2', path = p2, new_contents = 'red\nGREEN\nblue\n' })
    -- Neovim diffs every 'diff' window of a tab page together: the two must not share one.
    assert.eq(2, #api.nvim_list_tabpages())
    for _, tab in ipairs(api.nvim_list_tabpages()) do
      local n = 0
      for _, w in ipairs(api.nvim_tabpage_list_wins(tab)) do
        n = n + (vim.wo[w].diff and 1 or 0)
      end
      assert.eq(2, n)
    end
    local prop1 = vim.fn.win_findbuf(diff.get('c1').bufnr)[1]
    assert.eq(0, api.nvim_win_call(prop1, function()
      return vim.fn.diff_hlID(1, 1)
    end), 'an unchanged line is not highlighted')
    assert.truthy(diff.reject('c2'))
    assert.eq(1, #api.nvim_list_tabpages())
    assert.truthy(diff.is_open('c1'))

    -- A user's own :diffsplit in the tab page is not joined either.
    diff.close('c1')
    vim.cmd('edit ' .. vim.fn.fnameescape(p1))
    vim.cmd('diffsplit ' .. vim.fn.fnameescape(p2))
    open({ id = 'c3', path = p1, new_contents = 'alpha\n' })
    assert.eq(2, #api.nvim_list_tabpages())
    assert.eq(diff.get('c3').tabpage, api.nvim_get_current_tabpage())
  end)

  it('uses a disk copy when the original buffer has unsaved changes, and leaves that buffer alone', function()
    local path = write('dirty.txt', { 'disk line' })
    vim.cmd('edit ' .. vim.fn.fnameescape(path))
    local file_buf = api.nvim_get_current_buf()
    api.nvim_buf_set_lines(file_buf, 0, -1, false, { 'unsaved line' })
    assert.truthy(vim.bo[file_buf].modified)
    local calls = open({ id = 'dirty', path = path, new_contents = 'agent line\n' })
    local orig = diff.get('dirty').orig_bufnr
    assert.truthy(orig ~= file_buf)
    assert.same({ 'disk line' }, api.nvim_buf_get_lines(orig, 0, -1, false))
    vim.cmd('write')
    assert.eq('accepted', calls[1].status)
    vim.fn.writefile({ 'agent line' }, path)
    vim.wait(300)
    assert.same({ 'unsaved line' }, api.nvim_buf_get_lines(file_buf, 0, -1, false), 'dirty buffer not reloaded')
    assert.truthy(vim.bo[file_buf].modified)
    assert.truthy(api.nvim_buf_is_valid(file_buf))
  end)

  it('replacing an id rejects the old diff with trigger "replaced"', function()
    local path = write('a.txt', { 'x' })
    local first = open({ id = 'same', path = path, new_contents = 'first\n' })
    local second = open({ id = 'same', path = path, new_contents = 'second\n' })
    assert.eq(1, #first)
    assert.eq('rejected', first[1].status)
    assert.eq('replaced', first[1].trigger)
    assert.eq(0, #second)
    assert.eq(2, #api.nvim_list_tabpages(), 'the old tab is gone')
    assert.same({ 'same' }, diff.list())
    local prop = diff.get('same').bufnr
    assert.eq('agent-diff://same', api.nvim_buf_get_name(prop))
    assert.same({ 'second' }, api.nvim_buf_get_lines(prop, 0, -1, false))
    vim.cmd('write')
    assert.eq(1, #first)
    assert.eq('second\n', second[1].content)
    wait_for(function()
      return #api.nvim_list_tabpages() == 1
    end, 1000)
  end)

  it('editable=false makes the proposal read-only but still acceptable', function()
    local path = write('a.txt', { 'x' })
    local calls = open({ id = 'ro', path = path, new_contents = 'y\n', editable = false })
    local prop = diff.get('ro').bufnr
    assert.falsy(vim.bo[prop].modifiable)
    assert.falsy(diff.get('ro').editable)
    assert.matches('read%-only', vim.wo.winbar)
    local ok = pcall(api.nvim_buf_set_lines, prop, 0, -1, false, { 'changed' })
    assert.falsy(ok, 'edits are refused')
    vim.cmd('write')
    assert.eq('y\n', calls[1].content)
    assert.eq('accepted', calls[1].status)
  end)

  it('close(id) returns the current text without resolving; resolve=true resolves', function()
    local path = write('a.txt', { 'x' })
    local calls = open({ id = 'cl', path = path, new_contents = 'y\n' })
    api.nvim_buf_set_lines(diff.get('cl').bufnr, 0, -1, false, { 'user edit' })
    assert.eq('user edit\n', diff.close('cl'))
    assert.eq(0, #calls)
    assert.eq(1, #api.nvim_list_tabpages())
    assert.same({}, diff_buffers_left())
    assert.eq(nil, diff.close('cl'))
    vim.wait(50)
    assert.eq(0, #calls, 'wiping the buffer during close does not resolve')

    local calls2 = open({ id = 'cl2', path = path, new_contents = 'y\n' })
    assert.eq('y\n', diff.close('cl2', { resolve = true }))
    assert.same({ status = 'rejected', trigger = 'agent', id = 'cl2', path = path }, calls2[1])
    local calls3 = open({ id = 'cl3', path = path, new_contents = 'y\n' })
    diff.close('cl3', { resolve = true, trigger = 'disconnect' })
    assert.eq('disconnect', calls3[1].trigger)
  end)

  it('close_all closes every diff, or only one owner\'s', function()
    local path = write('a.txt', { 'x' })
    local a = open({ id = 'a', path = path, new_contents = '1\n', owner = 's1' })
    local b = open({ id = 'b', path = path, new_contents = '2\n', owner = 's2' })
    local c = open({ id = 'c', path = path, new_contents = '3\n', owner = 's1' })
    assert.same({ 'a', 'b', 'c' }, diff.list())
    assert.same({ 'a', 'c' }, diff.list({ owner = 's1' }))
    assert.eq(2, diff.close_all({ owner = 's1', resolve = true }))
    assert.eq('agent', a[1].trigger)
    assert.eq('agent', c[1].trigger)
    assert.eq(0, #b)
    assert.same({ 'b' }, diff.list())
    assert.eq(1, diff.close_all())
    assert.eq(0, #b)
    assert.eq(0, diff.close_all())
    assert.eq(1, #api.nvim_list_tabpages())
    assert.same({}, diff_buffers_left())
  end)

  it('round-trips CRLF content', function()
    local f = assert(io.open(dir .. '/crlf.txt', 'wb'))
    f:write('a\r\nb\r\n')
    f:close()
    local path = dir .. '/crlf.txt'
    local calls = open({ id = 'crlf', path = path, new_contents = 'a\r\nB\r\n' })
    local info = diff.get('crlf')
    assert.same({ 'a', 'B' }, api.nvim_buf_get_lines(info.bufnr, 0, -1, false))
    assert.eq('dos', vim.bo[info.bufnr].fileformat)
    assert.same({ 'a', 'b' }, api.nvim_buf_get_lines(info.orig_bufnr, 0, -1, false))
    vim.cmd('write')
    assert.eq('a\r\nB\r\n', calls[1].content)
  end)

  it('keeps stray carriage returns when line endings are mixed', function()
    local path = write('mixed.txt', { 'x' })
    local calls = open({ id = 'mixed', path = path, new_contents = 'a\r\nb\nc' })
    assert.same({ 'a\r', 'b', 'c' }, api.nvim_buf_get_lines(diff.get('mixed').bufnr, 0, -1, false))
    vim.cmd('write')
    assert.eq('a\r\nb\nc', calls[1].content)
  end)

  it(':w to another file does not accept', function()
    local path = write('a.txt', { 'x' })
    local calls = open({ id = 'other', path = path, new_contents = 'y\n' })
    pcall(vim.cmd, 'silent write ' .. vim.fn.fnameescape(dir .. '/copy.txt'))
    assert.eq(0, #calls)
    assert.truthy(diff.is_open('other'))
    wait_for(function()
      return #notes > 0
    end, 1000)
    assert.matches('cannot be written to another file', notes[1])
  end)

  it('focus=false leaves the cursor where it is', function()
    local path = write('a.txt', { 'x' })
    local win = api.nvim_get_current_win()
    local calls = open({ id = 'nf', path = path, new_contents = 'y\n', focus = false })
    assert.eq(win, api.nvim_get_current_win())
    assert.eq(2, #api.nvim_list_tabpages())
    diff.accept('nf')
    assert.eq('accepted', calls[1].status)
    assert.eq(win, api.nvim_get_current_win())
    assert.eq(1, #api.nvim_list_tabpages())
  end)

  it('accept_empty=false refuses an empty proposal', function()
    local path = write('a.txt', { 'x' })
    local calls = open({ id = 'empty', path = path, new_contents = '', accept_empty = false })
    vim.cmd('write')
    assert.eq(0, #calls)
    assert.truthy(diff.is_open('empty'))
    wait_for(function()
      return #notes > 0
    end, 1000)
    assert.matches('empty', notes[1])
    api.nvim_buf_set_lines(diff.get('empty').bufnr, 0, -1, false, { 'now text' })
    vim.cmd('write')
    assert.eq('now text', calls[1].content)
  end)

  it("open_in = 'current' uses a window pair in the current tab", function()
    config.setup({ diff = { open_in = 'current' } })
    local path = write('a.txt', { 'x' })
    vim.cmd('edit ' .. vim.fn.fnameescape(path))
    local win = api.nvim_get_current_win()
    local calls = open({ id = 'cur', path = path, new_contents = 'y\n' })
    assert.eq(1, #api.nvim_list_tabpages())
    assert.eq(3, #api.nvim_tabpage_list_wins(0))
    assert.eq(diff.get('cur').bufnr, api.nvim_get_current_buf())
    assert.falsy(vim.wo[win].diff, 'the main window is not part of the diff')
    vim.cmd('write')
    assert.eq('accepted', calls[1].status)
    wait_for(function()
      return #api.nvim_tabpage_list_wins(0) == 1
    end, 1000)
    assert.eq(win, api.nvim_get_current_win())
  end)

  it('accept_current() picks the diff of the current tab when several are open', function()
    local path = write('a.txt', { 'x' })
    local a = open({ id = 'A', path = path, new_contents = 'a\n' })
    local b = open({ id = 'B', path = path, new_contents = 'b\n' })
    assert.eq(3, #api.nvim_list_tabpages())
    assert.truthy(diff.accept_current())
    assert.eq(0, #a)
    assert.eq('b\n', b[1].content)
    -- focus returned to diff A's proposed window, where B was opened from
    assert.eq(diff.get('A').bufnr, api.nvim_get_current_buf())
    assert.truthy(diff.accept_current())
    assert.eq('a\n', a[1].content)
    assert.eq(1, #api.nvim_list_tabpages())
    local ok, err = diff.accept_current()
    assert.falsy(ok)
    assert.matches('no agent diff', err)
  end)

  it('returns an error for a directory path and leaves nothing behind', function()
    local ok, err = diff.open({ id = 'dir', path = dir, new_contents = 'x' })
    assert.falsy(ok)
    assert.matches('not a regular file', err)
    assert.eq(1, #api.nvim_list_tabpages())
    assert.same({}, diff_buffers_left())
    assert.same({}, diff.list())
  end)

  it('cleans up a half-built diff when the UI cannot be created', function()
    local path = write('a.txt', { 'x' })
    local real_open_win = api.nvim_open_win
    api.nvim_open_win = function()
      error('no room')
    end
    local called, ret, err = pcall(diff.open, { id = 'fail', path = path, new_contents = 'y\n' })
    api.nvim_open_win = real_open_win
    assert.truthy(called, 'open() does not throw')
    assert.falsy(ret)
    assert.matches('no room', err)
    assert.eq(1, #api.nvim_list_tabpages())
    assert.eq(1, #api.nvim_tabpage_list_wins(0))
    assert.same({}, diff_buffers_left())
    assert.same({}, diff.list())
  end)

  it('an on_resolve error does not break cleanup', function()
    local path = write('a.txt', { 'x' })
    assert.truthy(diff.open({
      id = 'boom',
      path = path,
      new_contents = 'y\n',
      on_resolve = function()
        error('provider bug')
      end,
    }))
    vim.cmd('write')
    wait_for(function()
      return #api.nvim_list_tabpages() == 1 and #notes > 0
    end, 1000)
    assert.same({}, diff.list())
    assert.same({}, diff_buffers_left())
    assert.matches('provider bug', notes[1])
  end)

  it('ids with spaces, brackets and symbols make valid buffer names', function()
    local path = write('init.lua', { 'x' })
    local id = '✻ [Claude Code] init.lua (3f9a1c) ⧉'
    local calls = open({ id = id, path = path, new_contents = 'y\n' })
    assert.eq('agent-diff://' .. id, api.nvim_buf_get_name(diff.get(id).bufnr))
    assert.truthy(buf_named('agent-diff://' .. id))
    vim.cmd('write')
    assert.eq('accepted', calls[1].status)
  end)

  -- ----------------------------------------------------------------------------------------------
  -- The agent terminal in the diff's tab page (config.diff.show_terminal)
  -- ----------------------------------------------------------------------------------------------
  describe('with an agent terminal', function()
    local terminal = require('agent.terminal')
    local FIX = TEST_ROOT .. '/tests/fixtures/fake_agent.sh'
    local pids = {}
    local n = 0

    local function pid_alive(pid)
      local ok, ret = pcall(vim.uv.kill, pid, 0)
      return ok and ret == 0
    end

    ---Start the fake agent (never focused). `env` goes into its environment.
    ---@return integer bufnr, integer win  its terminal buffer and window
    local function start_agent(env, layout)
      n = n + 1
      local out = dir .. '/agent' .. n
      local buf, err = terminal.open('fake', {
        focus = false,
        layout = layout,
        launch = function(name)
          return {
            name = name,
            argv = { FIX },
            env = vim.tbl_extend('force', { FAKE_AGENT_OUT = out }, env or {}),
            cwd = dir,
            cleanup = {},
            session_id = 'session-' .. n,
          }
        end,
      })
      assert.truthy(buf, err)
      pids[#pids + 1] = terminal.info().pid
      return buf, vim.fn.bufwinid(buf)
    end

    ---Windows of the tab page `tab` that show `buf`.
    local function wins_of(buf, tab)
      return vim.tbl_filter(function(w)
        return api.nvim_win_get_buf(w) == buf
      end, api.nvim_tabpage_list_wins(tab))
    end

    local function job_running()
      local info = terminal.info()
      return info ~= nil and info.running and vim.fn.jobwait({ info.job }, 0)[1] == -1
    end

    ---The agent is alive, and shown in exactly one window: `main_win`.
    local function agent_intact(buf, main_win, job)
      assert.truthy(job_running(), 'the agent job still runs')
      assert.eq(job, terminal.info().job, 'the same job')
      assert.truthy(api.nvim_buf_is_valid(buf), 'the terminal buffer is not wiped')
      assert.eq(buf, terminal.bufnr())
      assert.truthy(api.nvim_win_is_valid(main_win), 'the terminal window of the main tab page stays')
      assert.eq(buf, api.nvim_win_get_buf(main_win))
      assert.same({ main_win }, vim.fn.win_findbuf(buf), 'no other window shows the terminal')
    end

    before_each(function()
      config.setup({ terminal = { layout = 'split', start_insert = false, auto_close = true } })
      terminal.setup({})
    end)

    after_each(function()
      diff.close_all()
      terminal.stop()
      wait_for(function()
        return not vim.iter(pids):any(pid_alive)
      end, 5000, 'every agent job exited')
      pids = {}
    end)

    it('diff.show_terminal defaults to true and must be a boolean', function()
      assert.eq(true, config.defaults.diff.show_terminal)
      assert.eq(true, config.setup({}).diff.show_terminal)
      assert.eq(false, config.setup({ diff = { show_terminal = false } }).diff.show_terminal)
      assert.error(function()
        config.setup({ diff = { show_terminal = 'yes' } })
      end, 'diff.show_terminal')
    end)

    it('shows the terminal right of the proposal, as wide as its split, with focus on the proposal', function()
      local path = write('a.txt', { 'one', 'two' })
      vim.cmd('edit ' .. vim.fn.fnameescape(path))
      local file_win = api.nvim_get_current_win()
      local buf, main_win = start_agent()
      local job = terminal.info().job
      local main_width = api.nvim_win_get_width(main_win)
      assert.eq(math.floor(vim.o.columns * 0.4), main_width)

      local calls = open({ id = 't1', path = path, new_contents = 'one\nTWO\n' })
      local info = diff.get('t1')
      assert.eq(info.tabpage, api.nvim_get_current_tabpage())
      local wins = api.nvim_tabpage_list_wins(0)
      assert.eq(3, #wins, 'original | proposed | agent')
      local term_win = wins_of(buf, 0)[1]
      assert.truthy(term_win, 'the agent terminal is shown in the diff tab page')
      local orig_win = vim.fn.bufwinid(info.orig_bufnr)
      local prop_win = vim.fn.bufwinid(info.bufnr)
      -- Focus stays on the proposal, so :w accepts.
      assert.eq(prop_win, api.nvim_get_current_win())
      assert.eq('n', api.nvim_get_mode().mode)
      -- original | proposed | agent, the agent on the right edge, as wide as the terminal's split.
      local col = function(w)
        return api.nvim_win_get_position(w)[2]
      end
      assert.truthy(col(orig_win) < col(prop_win) and col(prop_win) < col(term_win))
      assert.eq(vim.o.columns, col(term_win) + api.nvim_win_get_width(term_win))
      assert.eq(main_width, api.nvim_win_get_width(term_win))
      assert.truthy(math.abs(api.nvim_win_get_width(orig_win) - api.nvim_win_get_width(prop_win)) <= 1,
        'the original and the proposal share the rest')
      assert.eq(api.nvim_win_get_height(orig_win), api.nvim_win_get_height(term_win), 'full height')
      -- The tab line that appears with the second tab page takes one row here (the main tab page is
      -- laid out again only when it is entered).
      assert.eq(vim.o.lines - vim.o.cmdheight - 2, api.nvim_win_get_height(term_win), 'tab line, status line')
      -- Just a terminal window: not part of the diff, no diff winbar, styled like the terminal's.
      assert.falsy(vim.wo[term_win].diff)
      assert.falsy(vim.wo[term_win].scrollbind)
      assert.eq('', vim.wo[term_win].winbar)
      assert.falsy(vim.wo[term_win].number)
      assert.falsy(vim.wo[term_win].wrap)
      assert.truthy(vim.wo[term_win].winfixwidth)
      assert.truthy(terminal.is_visible())
      assert.truthy(api.nvim_win_is_valid(main_win))

      vim.cmd('write')
      assert.eq('accepted', calls[1].status)
      wait_for(function()
        return #api.nvim_list_tabpages() == 1
      end, 1000, 'diff tab page closed')
      assert.eq(file_win, api.nvim_get_current_win(), 'focus goes back to where it was')
      assert.falsy(api.nvim_win_is_valid(term_win))
      agent_intact(buf, main_win, job)
      assert.eq(main_width, api.nvim_win_get_width(main_win))
    end)

    it('follows terminal.split_side and the size of the terminal split', function()
      local path = write('a.txt', { 'x' })
      vim.cmd('edit ' .. vim.fn.fnameescape(path))

      config.setup({ terminal = { layout = 'split', split_side = 'left', split_size = 0.3, start_insert = false } })
      local buf, main_win = start_agent()
      assert.eq(math.floor(vim.o.columns * 0.3), api.nvim_win_get_width(main_win))
      open({ id = 'left', path = path, new_contents = 'y\n' })
      local term_win = wins_of(buf, 0)[1]
      assert.same({ 0, 0 }, { api.nvim_win_get_position(term_win)[2], #vim.tbl_filter(function(w)
        return api.nvim_win_get_position(w)[2] < api.nvim_win_get_position(term_win)[2]
      end, api.nvim_tabpage_list_wins(0)) }, 'the agent is on the left edge')
      assert.eq(math.floor(vim.o.columns * 0.3), api.nvim_win_get_width(term_win))
      assert.eq(diff.get('left').bufnr, api.nvim_get_current_buf())
      diff.close('left')

      -- A split the user resized: the diff's window matches it, so the agent's TUI keeps its size.
      api.nvim_win_set_width(main_win, 30)
      assert.eq(30, api.nvim_win_get_width(main_win))
      open({ id = 'resized', path = path, new_contents = 'y\n' })
      assert.eq(30, api.nvim_win_get_width(wins_of(buf, 0)[1]))
      diff.close('resized')
      terminal.stop()

      config.setup({ terminal = { layout = 'split', split_side = 'below', split_size = 0.3, start_insert = false } })
      local buf2, main2 = start_agent()
      open({ id = 'below', path = path, new_contents = 'y\n' })
      term_win = wins_of(buf2, 0)[1]
      assert.eq(vim.o.columns, api.nvim_win_get_width(term_win), 'full width')
      assert.eq(api.nvim_win_get_height(main2), api.nvim_win_get_height(term_win))
      local prop_win = vim.fn.bufwinid(diff.get('below').bufnr)
      assert.truthy(api.nvim_win_get_position(term_win)[1] > api.nvim_win_get_position(prop_win)[1], 'below the diff')
      assert.truthy(vim.wo[term_win].winfixheight)
      assert.eq(prop_win, api.nvim_get_current_win())
    end)

    it('shows no terminal with show_terminal = false, a float or none layout, or without an agent', function()
      local path = write('a.txt', { 'x' })
      local function terminal_windows()
        local wins = api.nvim_tabpage_list_wins(diff.get('d').tabpage)
        return #wins, #vim.tbl_filter(function(w)
          return vim.bo[api.nvim_win_get_buf(w)].buftype == 'terminal'
        end, wins)
      end

      -- No agent terminal.
      open({ id = 'd', path = path, new_contents = 'y\n' })
      assert.same({ 2, 0 }, { terminal_windows() })
      diff.close('d')

      -- show_terminal = false.
      config.setup({ terminal = { layout = 'split', start_insert = false }, diff = { show_terminal = false } })
      local buf = start_agent()
      open({ id = 'd', path = path, new_contents = 'y\n' })
      assert.same({ 2, 0 }, { terminal_windows() })
      assert.eq(1, #vim.fn.win_findbuf(buf))
      diff.close('d')
      terminal.stop()

      -- A float would cover the diff.
      config.setup({ terminal = { layout = 'float', start_insert = false } })
      buf = start_agent()
      assert.eq('editor', api.nvim_win_get_config(vim.fn.win_findbuf(buf)[1]).relative)
      open({ id = 'd', path = path, new_contents = 'y\n' })
      assert.same({ 2, 0 }, { terminal_windows() })
      assert.eq(diff.get('d').bufnr, api.nvim_get_current_buf())
      diff.close('d')
      terminal.stop()

      -- 'none': there is no agent terminal.
      config.setup({ terminal = { layout = 'none', start_insert = false } })
      assert.eq(nil, (terminal.open('fake', { silent = true, launch = function() error('not called') end })))
      open({ id = 'd', path = path, new_contents = 'y\n' })
      assert.same({ 2, 0 }, { terminal_windows() })
    end)

    it("open_in = 'current' adds no terminal window: it is already in the tab page", function()
      config.setup({ terminal = { layout = 'split', start_insert = false }, diff = { open_in = 'current' } })
      local path = write('a.txt', { 'x' })
      vim.cmd('edit ' .. vim.fn.fnameescape(path))
      local buf, main_win = start_agent()
      open({ id = 'cur', path = path, new_contents = 'y\n' })
      assert.eq(1, #api.nvim_list_tabpages())
      assert.same({ main_win }, vim.fn.win_findbuf(buf))
      diff.close('cur')
      assert.same({ main_win }, vim.fn.win_findbuf(buf))
    end)

    it('the agent keeps running and keeps its window after a reject, a :tabclose or a close by the agent', function()
      local path = write('a.txt', { 'x' })
      vim.cmd('edit ' .. vim.fn.fnameescape(path))
      local file_win = api.nvim_get_current_win()
      local buf, main_win = start_agent()
      local job = terminal.info().job

      local calls = open({ id = 'r', path = path, new_contents = 'y\n' })
      assert.eq(1, #wins_of(buf, 0))
      feed('\\ad')
      assert.same({ status = 'rejected', trigger = 'user', id = 'r', path = path }, calls[1])
      wait_for(function()
        return #api.nvim_list_tabpages() == 1
      end, 1000, 'tab page closed after the reject key')
      assert.eq(file_win, api.nvim_get_current_win())
      agent_intact(buf, main_win, job)

      calls = open({ id = 'tc', path = path, new_contents = 'y\n' })
      assert.eq(1, #wins_of(buf, 0))
      vim.cmd('tabclose')
      wait_for(function()
        return #calls == 1
      end, 1000, 'resolved by :tabclose')
      assert.eq('closed', calls[1].trigger)
      vim.wait(50)
      assert.eq(1, #api.nvim_list_tabpages())
      assert.eq(file_win, api.nvim_get_current_win())
      agent_intact(buf, main_win, job)

      -- :q in the proposal: the teardown closes the agent's window too, and the tab page goes.
      calls = open({ id = 'q', path = path, new_contents = 'y\n' })
      vim.cmd('quit')
      wait_for(function()
        return #calls == 1 and #api.nvim_list_tabpages() == 1
      end, 1000, 'resolved by :quit')
      agent_intact(buf, main_win, job)

      -- The agent closes the diff while the user is in its window in the diff tab page (they
      -- answered its prompt there): focus goes back to where it was when the diff opened.
      calls = open({ id = 'ag', path = path, new_contents = 'y\n' })
      api.nvim_set_current_win(wins_of(buf, 0)[1])
      diff.close('ag', { resolve = true })
      assert.eq('agent', calls[1].trigger)
      assert.eq(1, #api.nvim_list_tabpages())
      assert.eq(file_win, api.nvim_get_current_win())
      agent_intact(buf, main_win, job)
      assert.same({}, diff_buffers_left())
    end)

    it('a diff opened from the agent window returns there', function()
      local path = write('a.txt', { 'x' })
      vim.cmd('edit ' .. vim.fn.fnameescape(path))
      local buf, main_win = start_agent()
      local job = terminal.info().job
      api.nvim_set_current_win(main_win)
      local calls = open({ id = 'fromterm', path = path, new_contents = 'y\n' })
      assert.eq(diff.get('fromterm').bufnr, api.nvim_get_current_buf())
      vim.cmd('write')
      assert.eq('accepted', calls[1].status)
      wait_for(function()
        return #api.nvim_list_tabpages() == 1
      end, 1000)
      assert.eq(main_win, api.nvim_get_current_win())
      agent_intact(buf, main_win, job)
    end)

    it('several diffs: each tab page gets its own terminal window', function()
      local path = write('a.txt', { 'x' })
      vim.cmd('edit ' .. vim.fn.fnameescape(path))
      local file_win = api.nvim_get_current_win()
      local buf, main_win = start_agent()
      local job = terminal.info().job
      local a = open({ id = 'A', path = path, new_contents = 'a\n' })
      local tab_a = diff.get('A').tabpage
      local a_term = wins_of(buf, tab_a)[1]
      -- B is opened from A's view of the agent.
      api.nvim_set_current_win(a_term)
      local b = open({ id = 'B', path = path, new_contents = 'b\n' })
      local tab_b = diff.get('B').tabpage
      assert.eq(3, #api.nvim_list_tabpages())
      assert.eq(1, #wins_of(buf, tab_a))
      assert.eq(1, #wins_of(buf, tab_b))
      assert.eq(3, #vim.fn.win_findbuf(buf))
      assert.eq(api.nvim_win_get_width(main_win), api.nvim_win_get_width(wins_of(buf, tab_b)[1]))
      assert.eq(diff.get('B').bufnr, api.nvim_get_current_buf())

      -- A goes first (from the agent side): B then returns to where A came from.
      assert.truthy(diff.reject('A'))
      assert.eq('rejected', a[1].status)
      assert.eq(2, #api.nvim_list_tabpages())
      assert.falsy(api.nvim_win_is_valid(a_term))
      assert.eq(2, #vim.fn.win_findbuf(buf))
      assert.eq(tab_b, api.nvim_get_current_tabpage(), 'B keeps focus')
      assert.truthy(diff.accept_current())
      assert.eq('b\n', b[1].content)
      assert.eq(1, #api.nvim_list_tabpages())
      assert.eq(file_win, api.nvim_get_current_win())
      agent_intact(buf, main_win, job)
    end)

    it('the agent exiting while a diff shows it closes only its window (auto_close)', function()
      local path = write('a.txt', { 'x' })
      vim.cmd('edit ' .. vim.fn.fnameescape(path))
      local file_win = api.nvim_get_current_win()
      local buf = start_agent({ FAKE_AGENT_EXIT = '0', FAKE_AGENT_SLEEP = '1' })
      local calls = open({ id = 'exit', path = path, new_contents = 'y\n' })
      local info = diff.get('exit')
      assert.eq(1, #wins_of(buf, 0))
      wait_for(function()
        return terminal.info() == nil
      end, 5000, 'the agent exited and its terminal was closed')
      vim.wait(50)
      assert.falsy(api.nvim_buf_is_valid(buf))
      assert.truthy(diff.is_open('exit'), 'the diff stays open')
      assert.eq(info.tabpage, api.nvim_get_current_tabpage())
      assert.eq(2, #api.nvim_tabpage_list_wins(info.tabpage), 'original | proposed stay')
      assert.eq(info.bufnr, api.nvim_get_current_buf(), 'focus stays on the proposal')
      assert.same({}, notes)
      vim.cmd('write')
      assert.eq('accepted', calls[1].status)
      wait_for(function()
        return #api.nvim_list_tabpages() == 1
      end, 1000)
      assert.eq(file_win, api.nvim_get_current_win())
      assert.same({}, notes)
    end)

    it('the agent exiting without auto_close leaves its finished terminal in both windows', function()
      config.setup({ terminal = { layout = 'split', start_insert = false, auto_close = false } })
      local path = write('a.txt', { 'x' })
      vim.cmd('edit ' .. vim.fn.fnameescape(path))
      local buf, main_win = start_agent({ FAKE_AGENT_EXIT = '0', FAKE_AGENT_SLEEP = '1' })
      local calls = open({ id = 'keep', path = path, new_contents = 'y\n' })
      wait_for(function()
        return not terminal.is_running()
      end, 5000, 'the agent exited')
      vim.wait(50)
      assert.eq(1, #wins_of(buf, 0))
      assert.eq(3, #api.nvim_tabpage_list_wins(0))
      vim.cmd('write')
      assert.eq('accepted', calls[1].status)
      wait_for(function()
        return #api.nvim_list_tabpages() == 1
      end, 1000)
      assert.truthy(api.nvim_buf_is_valid(buf))
      assert.same({ main_win }, vim.fn.win_findbuf(buf))
      assert.eq(0, terminal.info().exit_code)
    end)

    it(':AgentClose and :Agent in the diff tab page act on its terminal window only', function()
      local path = write('a.txt', { 'x' })
      vim.cmd('edit ' .. vim.fn.fnameescape(path))
      local buf, main_win = start_agent()
      local job = terminal.info().job
      local calls = open({ id = 'cmd', path = path, new_contents = 'y\n' })
      local tab = diff.get('cmd').tabpage
      local prop_win = api.nvim_get_current_win()
      -- close(): the diff's view goes, the main tab page keeps the agent.
      assert.truthy(terminal.close())
      assert.eq(0, #wins_of(buf, tab))
      assert.eq(2, #api.nvim_tabpage_list_wins(tab))
      assert.falsy(terminal.is_visible())
      assert.eq(prop_win, api.nvim_get_current_win())
      agent_intact(buf, main_win, job)
      -- toggle(): shows it again in this tab page (focused), then hides it here only.
      assert.eq(buf, terminal.toggle('fake'))
      assert.eq(tab, api.nvim_get_current_tabpage())
      local here = wins_of(buf, tab)[1]
      assert.eq(here, api.nvim_get_current_win())
      assert.eq(api.nvim_win_get_width(main_win), api.nvim_win_get_width(here))
      assert.eq(buf, terminal.toggle('fake'))
      assert.eq(0, #wins_of(buf, tab))
      agent_intact(buf, main_win, job)
      vim.cmd('write')
      assert.eq('accepted', calls[1].status)
    end)

    ---The original and the proposal of diff `id` share the columns the agent leaves them.
    local function balanced(id)
      local info = diff.get(id)
      local ow = api.nvim_win_get_width(vim.fn.bufwinid(info.orig_bufnr))
      local pw = api.nvim_win_get_width(vim.fn.bufwinid(info.bufnr))
      assert.truthy(math.abs(ow - pw) <= 1, ('%s: original %d, proposed %d columns'):format(id, ow, pw))
    end

    it('closing the diff closes every view of the agent in its tab page, also one shown again there', function()
      local path = write('a.txt', { 'x' })
      vim.cmd('edit ' .. vim.fn.fnameescape(path))
      local file_win = api.nvim_get_current_win()
      local buf, main_win = start_agent()
      local job = terminal.info().job

      ---Open diff `id`, and show the agent in its tab page again with `reshow`.
      ---@return table calls, integer tab
      local function reshown(id, reshow)
        local calls = open({ id = id, path = path, new_contents = 'y\n' })
        local tab = diff.get(id).tabpage
        reshow()
        assert.eq(tab, api.nvim_get_current_tabpage())
        assert.eq(1, #wins_of(buf, tab), id .. ': the agent is shown in the diff tab page again')
        assert.eq(3, #api.nvim_tabpage_list_wins(tab))
        return calls, tab
      end
      ---The diff resolved with `status`, its tab page gone with every window on the agent, and
      ---focus back where it was.
      local function gone(calls, status)
        assert.eq(status, calls[1] and calls[1].status)
        wait_for(function()
          return #api.nvim_list_tabpages() == 1
        end, 1000, 'the diff tab page closed')
        assert.eq(file_win, api.nvim_get_current_win())
        agent_intact(buf, main_win, job)
      end
      local function to_proposal(id)
        api.nvim_set_current_win(vim.fn.bufwinid(diff.get(id).bufnr))
      end

      -- :Agent twice: hidden, then shown again (focused); :w in the proposal.
      local calls = reshown('twice', function()
        assert.eq(buf, terminal.toggle('fake'))
        assert.eq(0, #wins_of(buf, 0))
        assert.eq(buf, terminal.toggle('fake'))
      end)
      to_proposal('twice')
      vim.cmd('write')
      gone(calls, 'accepted')

      -- :AgentClose, then :Agent.
      calls = reshown('close-toggle', function()
        assert.truthy(terminal.close())
        assert.eq(buf, terminal.toggle('fake'))
      end)
      to_proposal('close-toggle')
      vim.cmd('write')
      gone(calls, 'accepted')

      -- :AgentClose, then :AgentOpen; rejected with the key.
      calls = reshown('close-open', function()
        assert.truthy(terminal.close())
        assert.eq(buf, terminal.open('fake'))
      end)
      to_proposal('close-open')
      feed('\\ad')
      gone(calls, 'rejected')

      -- Shown again unfocused; the agent closes the diff while the cursor is in that window.
      local tab
      calls, tab = reshown('agent-closes', function()
        assert.truthy(terminal.close())
        assert.eq(buf, terminal.open('fake', { focus = false }))
      end)
      api.nvim_set_current_win(wins_of(buf, tab)[1])
      diff.close('agent-closes', { resolve = true })
      gone(calls, 'rejected')

      -- Two views in the diff tab page (the user split the one shown again).
      calls, tab = reshown('two-views', function()
        assert.truthy(terminal.close())
        assert.eq(buf, terminal.open('fake'))
      end)
      vim.cmd('split')
      assert.eq(2, #wins_of(buf, tab))
      to_proposal('two-views')
      vim.cmd('write')
      gone(calls, 'accepted')
      assert.same({}, diff_buffers_left())
    end)

    it('an agent started in the diff tab page closes with the diff, and keeps running', function()
      local path = write('a.txt', { 'x' })
      vim.cmd('edit ' .. vim.fn.fnameescape(path))
      local file_win = api.nvim_get_current_win()
      local calls = open({ id = 'fresh', path = path, new_contents = 'y\n' })
      local tab = diff.get('fresh').tabpage
      assert.eq(2, #api.nvim_tabpage_list_wins(tab), 'no agent yet')
      local buf, win = start_agent()
      assert.eq(tab, api.nvim_win_get_tabpage(win))
      local job = terminal.info().job
      vim.cmd('write')
      assert.eq('accepted', calls[1].status)
      wait_for(function()
        return #api.nvim_list_tabpages() == 1
      end, 1000, 'the diff tab page closed')
      assert.eq(file_win, api.nvim_get_current_win())
      assert.same({}, vim.fn.win_findbuf(buf), 'hidden')
      assert.truthy(job_running())
      assert.eq(job, terminal.info().job)
    end)

    it('the original and the proposal share what the agent leaves, however it comes into the tab page', function()
      local path = write('a.txt', { 'x' })
      vim.cmd('edit ' .. vim.fn.fnameescape(path))
      local buf, main_win = start_agent()
      local main_width = api.nvim_win_get_width(main_win)
      for _, case in ipairs({
        { 'split_here', function() end },
        { 'toggle', function()
          assert.truthy(terminal.close())
          assert.eq(buf, terminal.toggle('fake'))
        end },
        { 'open', function()
          assert.truthy(terminal.close())
          assert.eq(buf, terminal.open('fake'))
        end },
        { 'open unfocused', function()
          assert.truthy(terminal.close())
          assert.eq(buf, terminal.open('fake', { focus = false }))
        end },
      }) do
        local id = case[1]
        open({ id = id, path = path, new_contents = 'y\n' })
        case[2]()
        local wins = wins_of(buf, 0)
        assert.eq(1, #wins, id)
        assert.eq(main_width, api.nvim_win_get_width(wins[1]), id .. ': as large as the terminal split')
        balanced(id)
        diff.close(id)
      end

      -- An agent started in the diff tab page.
      terminal.stop()
      open({ id = 'fresh', path = path, new_contents = 'y\n' })
      buf = start_agent()
      assert.eq(1, #wins_of(buf, 0))
      balanced('fresh')
    end)
  end)
end)
