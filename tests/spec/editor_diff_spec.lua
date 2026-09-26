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
end)
