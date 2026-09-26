local root = _G.TEST_ROOT
local R = dofile(root .. '/lua/agent/nvim_mcp/remote.lua')
local rpc = require('agent.nvim_mcp.rpc')
local server = require('agent.nvim_mcp.server')
local nvim_mcp = require('agent.nvim_mcp')

local api, fn, uv = vim.api, vim.fn, vim.uv

local tmpdir
local jobs = {}

vim.o.showmode = false

local function write(name, lines)
  local p = tmpdir .. '/' .. name
  fn.writefile(lines, p)
  return p
end

local function call(tool, args)
  return R.dispatch(tool, args or {}, { agent = 'test' })
end

local function ok_text(tool, args)
  local r = call(tool, args)
  assert.truthy(r.ok, 'tool ' .. tool .. ' failed: ' .. tostring(r.error))
  return r.text
end

local function ok_json(tool, args)
  return vim.json.decode(ok_text(tool, args), { luanil = { object = true, array = true } })
end

local function err_text(tool, args)
  local r = call(tool, args)
  assert.falsy(r.ok, 'expected ' .. tool .. ' to fail')
  return r.error
end

---Open a terminal running `cat` in a new right split and make it current.
local function open_terminal()
  vim.cmd('botright vnew')
  local job = fn.jobstart({ 'cat' }, { term = true })
  assert.truthy(job > 0, 'jobstart failed')
  jobs[#jobs + 1] = job
  return api.nvim_get_current_win(), api.nvim_get_current_buf()
end

local function reset_editor()
  for _, j in ipairs(jobs) do
    pcall(fn.jobstop, j)
  end
  jobs = {}
  pcall(vim.cmd, 'silent! tabonly!')
  pcall(vim.cmd, 'silent! only!')
  vim.cmd('enew!')
  for _, b in ipairs(api.nvim_list_bufs()) do
    if b ~= api.nvim_get_current_buf() then
      pcall(api.nvim_buf_delete, b, { force = true })
    end
  end
  vim.diagnostic.reset()
end

local function lines_of(buf)
  return api.nvim_buf_get_lines(buf, 0, -1, false)
end

describe('nvim_mcp remote', function()
  before_each(function()
    reset_editor()
    tmpdir = fn.tempname()
    fn.mkdir(tmpdir, 'p')
  end)
  after_each(function()
    reset_editor()
    fn.delete(tmpdir, 'rf')
  end)

  describe('main window', function()
    it('is the current window when it is an editor window', function()
      local f = write('a.txt', { 'a' })
      vim.cmd('edit ' .. f)
      assert.eq(api.nvim_get_current_win(), R.main_window())
    end)

    it('skips terminal and floating windows and prefers the previous window', function()
      local f = write('a.txt', { 'a' })
      vim.cmd('edit ' .. f)
      local editor = api.nvim_get_current_win()
      vim.cmd('split')
      local other = api.nvim_get_current_win()
      vim.cmd('wincmd p') -- back to editor, so `wincmd p` from the terminal lands on it
      assert.eq(editor, api.nvim_get_current_win())
      local term = open_terminal()
      assert.eq(term, api.nvim_get_current_win())
      assert.eq(editor, R.main_window())
      local float = api.nvim_open_win(api.nvim_create_buf(false, true), true,
        { relative = 'editor', row = 1, col = 1, width = 10, height = 2 })
      assert.falsy(R.is_editor_window(float))
      assert.falsy(R.is_editor_window(term))
      assert.truthy(R.is_editor_window(other))
      local main = R.main_window()
      assert.truthy(main == editor or main == other)
      api.nvim_win_close(float, true)
    end)

    it('is nil when the tab has only a terminal window', function()
      local term = open_terminal()
      vim.cmd('only')
      assert.eq(term, api.nvim_get_current_win())
      assert.eq(nil, R.main_window())
    end)

    it('is the editor window under a floating terminal', function()
      local f = write('a.txt', { 'a' })
      vim.cmd('edit ' .. f)
      local editor = api.nvim_get_current_win()
      local float = api.nvim_open_win(api.nvim_create_buf(false, true), true,
        { relative = 'editor', row = 1, col = 1, width = 20, height = 5 })
      jobs[#jobs + 1] = fn.jobstart({ 'cat' }, { term = true })
      assert.eq(float, api.nvim_get_current_win())
      assert.eq(editor, R.main_window())
      local res = ok_json('open_file', { path = f, line = 1 })
      assert.eq(editor, res.winid)
      assert.eq('terminal', vim.bo[api.nvim_win_get_buf(float)].buftype)
    end)

    it('falls back to the last used file buffer when the tab has no editor window', function()
      local f = write('last.txt', { 'l1', 'l2' })
      vim.cmd('edit ' .. f)
      api.nvim_win_set_cursor(0, { 2, 0 })
      local _, term_buf = open_terminal()
      vim.cmd('only')
      local s = ok_json('get_editor_state')
      assert.eq(fn.bufnr(f), s.current.bufnr)
      assert.eq(2, s.current.cursor.line)
      assert.eq(1, #s.windows)
      assert.matches('\n     2\tl2$', ok_text('read_buffer'))
      assert.truthy(term_buf ~= s.current.bufnr)
    end)
  end)

  describe('get_editor_state', function()
    it('reports the main editor buffer, windows and the last selection while in the terminal', function()
      local f = write('state.txt', { 'one', 'two', 'three' })
      vim.cmd('edit ' .. f)
      api.nvim_win_set_cursor(0, { 2, 1 })
      vim.cmd('normal! Vj\27')
      local editor = api.nvim_get_current_win()
      local term_win, term_buf = open_terminal()
      local s = ok_json('get_editor_state')
      assert.eq(fn.getcwd(), s.cwd)
      assert.eq('string', type(s.mode))
      assert.eq(fn.bufnr(f), s.current.bufnr)
      assert.eq(api.nvim_buf_get_name(fn.bufnr(f)), s.current.path)
      assert.eq(false, s.current.modified)
      assert.same({ line = 3, col = 2 }, s.current.cursor) -- V then j keeps byte column 1 (0-based)
      assert.same({ path = api.nvim_buf_get_name(fn.bufnr(f)), start_line = 2, end_line = 3, text = 'two\nthree' },
        s.visual_selection)
      assert.eq(2, #s.windows)
      local by_id = {}
      for _, w in ipairs(s.windows) do
        by_id[w.winid] = w
      end
      assert.same({ winid = term_win, bufnr = term_buf, path = api.nvim_buf_get_name(term_buf), is_current = true,
        is_terminal = true, is_floating = false }, by_id[term_win])
      assert.eq(false, by_id[editor].is_terminal)
      assert.eq(false, by_id[editor].is_current)
      assert.eq(1, s.tabpage)
      assert.eq(#fn.getbufinfo({ buflisted = 1 }), s.buffer_count)
    end)

    it('reports a live visual selection and null when there is none', function()
      local f = write('sel.txt', { 'alpha', 'beta', 'gamma' })
      vim.cmd('edit ' .. f)
      local s = ok_json('get_editor_state')
      assert.eq(nil, s.visual_selection)
      -- the JSON really contains null
      assert.matches('"visual_selection":null', ok_text('get_editor_state'))
      vim.cmd('normal! 1Gvj')
      s = ok_json('get_editor_state')
      assert.eq('v', s.mode)
      assert.eq(1, s.visual_selection.start_line)
      assert.eq(2, s.visual_selection.end_line)
      assert.eq('alpha\nb', s.visual_selection.text)
      vim.cmd('normal! \27')
    end)
  end)

  describe('list_buffers', function()
    it('lists listed buffers, and unlisted ones on request', function()
      local a = write('a.lua', { 'x', 'y' })
      local b = write('b.txt', { 'z' })
      vim.cmd('edit ' .. a)
      vim.cmd('badd ' .. b)
      local scratch = api.nvim_create_buf(false, true)
      local list = ok_json('list_buffers')
      local by_path = {}
      for _, e in ipairs(list) do
        if e.path then
          by_path[e.path] = e
        end
        assert.truthy(e.bufnr ~= scratch, 'unlisted buffer should be hidden')
      end
      local ea = by_path[api.nvim_buf_get_name(fn.bufnr(a))]
      local name_a = api.nvim_buf_get_name(fn.bufnr(a))
      assert.same({ bufnr = fn.bufnr(a), path = name_a, name = fn.fnamemodify(name_a, ':~:.'),
        filetype = vim.bo[fn.bufnr(a)].filetype, buftype = '', modified = false, loaded = true, line_count = 2,
        is_current = true }, ea)
      local eb = by_path[api.nvim_buf_get_name(fn.bufnr(b))]
      assert.eq(false, eb.loaded)
      assert.eq(0, eb.line_count)
      assert.eq(false, eb.is_current)
      local all = ok_json('list_buffers', { include_unlisted = true })
      local found = false
      for _, e in ipairs(all) do
        found = found or e.bufnr == scratch
      end
      assert.truthy(found, 'unlisted buffer missing with include_unlisted')
    end)
  end)

  describe('read_buffer', function()
    it('loads an unloaded buffer given by path and numbers the lines', function()
      local f = write('r.txt', { 'one', 'two', 'three' })
      vim.cmd('badd ' .. f)
      local buf = fn.bufnr(f)
      assert.falsy(api.nvim_buf_is_loaded(buf))
      local text = ok_text('read_buffer', { buffer = f })
      assert.truthy(api.nvim_buf_is_loaded(buf))
      local name = api.nvim_buf_get_name(buf)
      assert.eq(name .. ' (lines 1-3 of 3)\n     1\tone\n     2\ttwo\n     3\tthree', text)
    end)

    it('includes unsaved changes, accepts a bufnr and ranges', function()
      local f = write('r.txt', { 'one', 'two', 'three', 'four' })
      vim.cmd('edit ' .. f)
      local buf = api.nvim_get_current_buf()
      api.nvim_buf_set_lines(buf, 1, 2, false, { 'TWO' })
      local name = api.nvim_buf_get_name(buf)
      assert.eq(name .. ' (lines 2-3 of 4)\n     2\tTWO\n     3\tthree',
        ok_text('read_buffer', { buffer = buf, start_line = 2, end_line = 3 }))
      assert.eq(name .. ' (lines 3-4 of 4)\n     3\tthree\n     4\tfour',
        ok_text('read_buffer', { buffer = tostring(buf), start_line = 3, end_line = -1 }))
      assert.eq(name .. ' (lines 4-4 of 4)\n     4\tfour', ok_text('read_buffer', { buffer = buf, start_line = 4, end_line = 99 }))
      assert.matches('past the end', err_text('read_buffer', { buffer = buf, start_line = 5 }))
      assert.matches('before start_line', err_text('read_buffer', { buffer = buf, start_line = 3, end_line = 2 }))
    end)

    it('defaults to the main editor buffer even when the terminal is current', function()
      local f = write('d.txt', { 'hello' })
      vim.cmd('edit ' .. f)
      open_terminal()
      assert.matches('^' .. vim.pesc(api.nvim_buf_get_name(fn.bufnr(f))) .. ' %(lines 1%-1 of 1%)\n     1\thello$',
        ok_text('read_buffer'))
    end)

    it('reads a file without a buffer from disk, without creating one', function()
      local f = write('disk.txt', { 'on disk' })
      local before = #api.nvim_list_bufs()
      local text = ok_text('read_buffer', { buffer = f })
      assert.matches('disk%.txt %(lines 1%-1 of 1%)\n     1\ton disk$', text)
      assert.eq(before, #api.nvim_list_bufs())
      assert.eq(-1, fn.bufnr(f))
      assert.matches('no buffer or readable file', err_text('read_buffer', { buffer = tmpdir .. '/missing.txt' }))
      assert.matches('no buffer with number', err_text('read_buffer', { buffer = 9999 }))
    end)

    it('keeps a literal $ in file names', function()
      vim.env.post = 'EXPANDED'
      local f = write('$post.txt', { 'dollar' })
      assert.matches('%$post%.txt %(lines 1%-1 of 1%)\n     1\tdollar$', ok_text('read_buffer', { buffer = f }))
      local res = ok_json('edit_buffer', { buffer = f, start_line = 1, end_line = 1, text = 'DOLLAR', save = true })
      assert.matches('%$post%.txt$', res.path)
      assert.same({ 'DOLLAR' }, fn.readfile(f))
      local opened = ok_json('open_file', { path = f })
      assert.eq(res.bufnr, opened.bufnr)
      vim.env.post = nil
    end)

    it('resolves relative paths against the working directory', function()
      local f = write('rel.txt', { 'rel' })
      vim.cmd('edit ' .. f)
      local cwd = fn.getcwd()
      vim.cmd('cd ' .. fn.fnameescape(tmpdir))
      local ok, text = pcall(ok_text, 'read_buffer', { buffer = 'rel.txt' })
      vim.cmd('cd ' .. fn.fnameescape(cwd))
      assert.truthy(ok, text)
      assert.matches('\n     1\trel$', text)
    end)
  end)

  describe('edit_buffer', function()
    local f, buf
    before_each(function()
      f = write('e.txt', { 'one', 'two', 'three' })
      vim.cmd('edit ' .. f)
      buf = api.nvim_get_current_buf()
    end)

    it('replaces an inclusive range', function()
      local res = ok_json('edit_buffer', { buffer = buf, start_line = 2, end_line = 3, text = 'TWO\nTHREE\nFOUR' })
      assert.same({ 'one', 'TWO', 'THREE', 'FOUR' }, lines_of(buf))
      assert.same({ bufnr = buf, path = api.nvim_buf_get_name(buf), line_count = 4, modified = true, saved = false }, res)
    end)

    it('inserts with end_line = start_line - 1, appends, deletes and ignores one trailing newline', function()
      ok_json('edit_buffer', { buffer = buf, start_line = 1, end_line = 0, text = 'zero\n' })
      assert.same({ 'zero', 'one', 'two', 'three' }, lines_of(buf))
      ok_json('edit_buffer', { buffer = buf, start_line = 5, end_line = 4, text = 'four' })
      assert.same({ 'zero', 'one', 'two', 'three', 'four' }, lines_of(buf))
      ok_json('edit_buffer', { buffer = buf, start_line = 2, end_line = 3, text = '' })
      assert.same({ 'zero', 'three', 'four' }, lines_of(buf))
      ok_json('edit_buffer', { buffer = buf, start_line = 2, end_line = -1, text = 'a\r\nb\n\n' })
      assert.same({ 'zero', 'a', 'b', '' }, lines_of(buf))
    end)

    it('makes each edit one undo block', function()
      vim.bo[buf].undolevels = 500
      ok_json('edit_buffer', { buffer = buf, start_line = 1, end_line = 1, text = 'ONE' })
      ok_json('edit_buffer', { buffer = buf, start_line = 2, end_line = 2, text = 'TWO\nTWO-B' })
      vim.cmd('silent undo')
      assert.same({ 'ONE', 'two', 'three' }, lines_of(buf))
      vim.cmd('silent undo')
      assert.same({ 'one', 'two', 'three' }, lines_of(buf))
      assert.eq(500, vim.bo[buf].undolevels, 'buffer-local undolevels is kept')
    end)

    it('saves when asked', function()
      local res = ok_json('edit_buffer', { buffer = f, start_line = 1, end_line = 1, text = 'saved', save = true })
      assert.eq(true, res.saved)
      assert.eq(false, res.modified)
      assert.same({ 'saved', 'two', 'three' }, fn.readfile(f))
    end)

    it('saves even when the file changed on disk (no blocking prompt)', function()
      fn.writefile({ 'changed', 'outside' }, f)
      uv.fs_utime(f, os.time() + 5, os.time() + 5)
      local res = ok_json('edit_buffer', { buffer = buf, start_line = 1, end_line = 1, text = 'mine', save = true })
      assert.eq(true, res.saved)
      assert.same({ 'mine', 'two', 'three' }, fn.readfile(f))
    end)

    it('loads a file that has no buffer into a listed buffer', function()
      local g = write('new.txt', { 'x', 'y' })
      local res = ok_json('edit_buffer', { buffer = g, start_line = 2, end_line = 2, text = 'Y' })
      local b = fn.bufnr(g)
      assert.eq(b, res.bufnr)
      assert.truthy(vim.bo[b].buflisted)
      assert.same({ 'x', 'Y' }, lines_of(b))
      assert.same({ 'x', 'y' }, fn.readfile(g))
    end)

    it('refuses terminal buffers and bad ranges', function()
      local _, term_buf = open_terminal()
      assert.matches('terminal', err_text('edit_buffer', { buffer = term_buf, start_line = 1, end_line = 1, text = 'x' }))
      assert.matches('start_line 5 is out of range',
        err_text('edit_buffer', { buffer = buf, start_line = 5, end_line = 5, text = 'x' }))
      assert.matches('end_line 4 is out of range',
        err_text('edit_buffer', { buffer = buf, start_line = 2, end_line = 4, text = 'x' }))
      assert.matches('end_line 0 is out of range',
        err_text('edit_buffer', { buffer = buf, start_line = 2, end_line = 0, text = 'x' }))
      assert.same({ 'one', 'two', 'three' }, lines_of(buf))
    end)
  end)

  describe('open_file', function()
    it('opens in the main editor window, never in the terminal, and focuses it', function()
      local a = write('a.txt', { 'a' })
      local b = write('b.txt', { '1', '2', '3', '4', '5', '6' })
      vim.cmd('edit ' .. a)
      local editor = api.nvim_get_current_win()
      local term_win, term_buf = open_terminal()
      local res = ok_json('open_file', { path = b, line = 3, column = 1 })
      assert.eq(editor, res.winid)
      assert.eq(fn.bufnr(b), res.bufnr)
      assert.eq(api.nvim_buf_get_name(fn.bufnr(b)), res.path)
      assert.eq(term_buf, api.nvim_win_get_buf(term_win))
      assert.eq(editor, api.nvim_get_current_win())
      assert.same({ 3, 0 }, api.nvim_win_get_cursor(editor))
    end)

    it('visually selects line..end_line', function()
      local b = write('sel.txt', { '1', '2', '3', '4', '5' })
      open_terminal()
      vim.cmd('startinsert')
      local res = ok_json('open_file', { path = b, line = 2, end_line = 4 })
      assert.eq('V', api.nvim_get_mode().mode)
      assert.eq(res.winid, api.nvim_get_current_win())
      assert.same({ '2', '3', '4' }, fn.getregion(fn.getpos('v'), fn.getpos('.'), { type = 'V' }))
      vim.cmd('normal! \27')
    end)

    it('creates an editor split when the tab only has a terminal', function()
      local b = write('only.txt', { 'x' })
      local term_win, term_buf = open_terminal()
      vim.cmd('only')
      vim.wo[term_win].number = false
      vim.go.number = true
      local res = ok_json('open_file', { path = b })
      vim.go.number = false
      assert.truthy(res.winid ~= term_win)
      assert.eq(term_buf, api.nvim_win_get_buf(term_win))
      assert.eq(fn.bufnr(b), api.nvim_win_get_buf(res.winid))
      assert.eq(2, #api.nvim_tabpage_list_wins(0))
      assert.eq(true, vim.wo[res.winid].number, 'window options are reset to the global values')
    end)

    it('supports vertical, horizontal and tab splits', function()
      local a = write('a.txt', { 'a' })
      local b = write('b.txt', { 'b' })
      vim.cmd('edit ' .. a)
      local res = ok_json('open_file', { path = b, split = 'vertical' })
      assert.eq(2, #api.nvim_tabpage_list_wins(0))
      assert.eq(fn.bufnr(b), api.nvim_win_get_buf(res.winid))
      res = ok_json('open_file', { path = a, split = 'horizontal' })
      assert.eq(3, #api.nvim_tabpage_list_wins(0))
      local nbufs = #api.nvim_list_bufs()
      res = ok_json('open_file', { path = b, split = 'tab' })
      assert.eq(2, fn.tabpagenr('$'))
      assert.eq(2, fn.tabpagenr())
      assert.eq(fn.bufnr(b), api.nvim_win_get_buf(res.winid))
      assert.eq(nbufs, #api.nvim_list_bufs(), 'the scratch buffer of :tabnew is removed')
    end)

    it('fails for missing files and directories', function()
      assert.matches('file not found', err_text('open_file', { path = tmpdir .. '/nope.txt' }))
      assert.matches('is a directory', err_text('open_file', { path = tmpdir }))
    end)
  end)

  describe('get_diagnostics', function()
    it('returns 1-based diagnostics for one or all buffers, filtered by severity', function()
      local a = write('a.lua', { 'local x = 1', 'print(y)' })
      local b = write('b.lua', { 'z' })
      vim.cmd('edit ' .. a)
      vim.cmd('badd ' .. b)
      local ba, bb = fn.bufnr(a), fn.bufnr(b)
      fn.bufload(bb)
      local ns = api.nvim_create_namespace('agent_nvim_mcp_test')
      vim.diagnostic.set(ns, ba, {
        { lnum = 1, col = 6, end_lnum = 1, end_col = 7, severity = vim.diagnostic.severity.ERROR, message = 'undefined y',
          source = 'lua_ls', code = 'undefined-global' },
        { lnum = 0, col = 6, end_lnum = 0, end_col = 7, severity = vim.diagnostic.severity.HINT, message = 'unused x' },
      })
      vim.diagnostic.set(ns, bb, {
        { lnum = 0, col = 0, severity = vim.diagnostic.severity.WARN, message = 'warn z', code = 12 },
      })
      local all = ok_json('get_diagnostics')
      assert.eq(3, #all)
      local only_a = ok_json('get_diagnostics', { buffer = a })
      assert.eq(2, #only_a)
      assert.same({ path = api.nvim_buf_get_name(ba), line = 1, col = 7, end_line = 1, end_col = 7, severity = 'hint',
        message = 'unused x' }, only_a[1])
      assert.same({ path = api.nvim_buf_get_name(ba), line = 2, col = 7, end_line = 2, end_col = 7, severity = 'error',
        message = 'undefined y', source = 'lua_ls', code = 'undefined-global' }, only_a[2])
      local warn = ok_json('get_diagnostics', { min_severity = 'warning' })
      assert.eq(2, #warn)
      local sev = {}
      for _, d in ipairs(warn) do
        sev[d.severity] = d
      end
      assert.truthy(sev.error and sev.warning)
      assert.eq(12, sev.warning.code)
      assert.same({}, ok_json('get_diagnostics', { buffer = tmpdir .. '/none.lua' }))
    end)
  end)

  describe('execute_command, eval, exec_lua, notify', function()
    it('execute_command captures output and reports errors', function()
      assert.eq('hello', ok_text('execute_command', { command = 'echo "hello"' }))
      assert.eq('(no output)', ok_text('execute_command', { command = 'let g:agent_nvim_x = 1' }))
      assert.eq(1, vim.g.agent_nvim_x)
      assert.matches('E492', err_text('execute_command', { command = 'NotACommand' }))
    end)

    it('execute_command runs in the main editor window, not the terminal', function()
      local a = write('a.txt', { 'a' })
      local b = write('b.txt', { 'b' })
      vim.cmd('edit ' .. a)
      local editor = api.nvim_get_current_win()
      local term_win, term_buf = open_terminal()
      ok_text('execute_command', { command = 'edit ' .. fn.fnameescape(b) })
      assert.eq(term_buf, api.nvim_win_get_buf(term_win))
      assert.eq(fn.bufnr(b), api.nvim_win_get_buf(editor))
      assert.eq(term_win, api.nvim_get_current_win())
      assert.eq(b, ok_json('eval', { expression = "expand('%:p')" }))
    end)

    it('eval returns JSON values', function()
      assert.eq('2', ok_text('eval', { expression = '1 + 1' }))
      assert.eq('"abc"', ok_text('eval', { expression = '"abc"' }))
      assert.same({ a = { 1, vim.NIL, 3 }, b = true }, vim.json.decode(ok_text('eval', { expression = '{"a": [1, v:null, 3], "b": v:true}' })))
      assert.eq('{}', ok_text('eval', { expression = '{}' }))
      assert.eq('[]', ok_text('eval', { expression = '[]' }))
      assert.eq('"Infinity"', ok_text('eval', { expression = '1.0/0' }))
      assert.eq('null', ok_text('eval', { expression = 'function("tr")' }))
      assert.matches('E121', err_text('eval', { expression = 'no_such_var' }))
    end)

    it('exec_lua passes args and returns JSON of the return values', function()
      assert.eq('42', ok_text('exec_lua', { code = 'return ... + 1', args = { 41 } }))
      assert.eq('[1,"two",null,true]', ok_text('exec_lua', { code = 'return 1, "two", nil, true' }))
      assert.eq('null', ok_text('exec_lua', { code = 'local x = 1' }))
      assert.eq('"<function>"', ok_text('exec_lua', { code = 'return print' }))
      local t = vim.json.decode(ok_text('exec_lua', { code = 'local t = { a = 1 }; t.self = t; return t' }))
      assert.eq('<cycle>', t.self)
      assert.eq('[1,null,3]', ok_text('exec_lua', { code = 'return { 1, nil, 3 }' }))
      assert.eq('"NaN"', ok_text('exec_lua', { code = 'return 0/0' }))
      assert.eq('{}', ok_text('exec_lua', { code = 'return vim.empty_dict()' }))
      assert.eq('2', ok_text('exec_lua', { code = 'return select("#", ...)', args = { 'a', vim.NIL } }))
      assert.matches('boom', err_text('exec_lua', { code = 'error("boom")' }))
      assert.matches('unexpected symbol', err_text('exec_lua', { code = 'return +' }))
    end)

    it('notify shows the message and returns ok', function()
      local seen
      local orig = vim.notify
      vim.notify = function(msg, level, opts)
        seen = { msg = msg, level = level, title = opts and opts.title }
      end
      local text = ok_text('notify', { message = 'hi there', level = 'warn' })
      wait_for(function()
        return seen ~= nil
      end, 1000, 'notify')
      vim.notify = orig
      assert.eq('ok', text)
      assert.same({ msg = 'hi there', level = vim.log.levels.WARN, title = 'test' }, seen)
      assert.matches('level must be', err_text('notify', { message = 'x', level = 'loud' }))
    end)
  end)

  describe('dispatch', function()
    it('reports unknown tools and supports direct execution of the source', function()
      assert.same({ ok = false, error = 'unknown tool: nope' }, call('nope'))
      local f = io.open(root .. '/lua/agent/nvim_mcp/remote.lua')
      local src = f:read('*a')
      f:close()
      local res = assert(loadstring(src))('eval', { expression = '3 * 3' }, {})
      assert.same({ ok = true, text = '9' }, res)
      assert.eq('table', type(assert(loadstring(src))()))
    end)

    it('produces JSON-safe output for odd values', function()
      assert.eq('{"1":1,"a":2}', vim.json.encode(vim.json.decode(R.to_json({ 1, a = 2 }))):gsub('"a":2,"1":1', '"1":1,"a":2'))
      assert.eq('[null,null,3]', R.to_json({ [3] = 3 }))
      assert.eq('"-Infinity"', R.to_json(-math.huge))
    end)
  end)
end)

-- A second headless Neovim with --listen ------------------------------------------------------

local function start_target(listen)
  local dir = fn.tempname()
  fn.mkdir(dir, 'p')
  local addr = listen or (dir .. '/t.sock')
  local addr_file = dir .. '/addr'
  local job = fn.jobstart({ vim.v.progpath, '--headless', '-u', 'NONE', '-i', 'NONE', '-n', '--listen', addr,
    '--cmd', 'call writefile([v:servername], "' .. addr_file .. '")' }, { env = { NVIM = '' } })
  assert.truthy(job > 0)
  wait_for(function()
    return fn.filereadable(addr_file) == 1 and fn.readfile(addr_file)[1] ~= nil
  end, 5000, 'target nvim to start')
  local real = fn.readfile(addr_file)[1]
  if real:sub(1, 1) == '/' then
    wait_for(function()
      return uv.fs_stat(real) ~= nil
    end, 5000, 'socket')
  end
  -- the --cmd runs before the server is fully up on some systems; give it a moment to accept
  vim.wait(50)
  return { job = job, addr = real, dir = dir }
end

local function stop_target(t)
  if not t then
    return
  end
  pcall(fn.jobstop, t.job)
  fn.jobwait({ t.job }, 2000)
  fn.delete(t.dir, 'rf')
end

local function connect(addr)
  local done, cerr, client = false, nil, nil
  rpc.connect(addr, { timeout_ms = 2000 }, function(err, c)
    done, cerr, client = true, err, c
  end)
  wait_for(function()
    return done
  end, 3000, 'connect')
  return client, cerr
end

describe('nvim_mcp rpc client', function()
  local target
  before_each(function()
    target = start_target()
  end)
  after_each(function()
    stop_target(target)
    target = nil
  end)

  it('parses addresses', function()
    assert.same({ type = 'pipe', path = '/tmp/x.sock' }, rpc.parse_address('/tmp/x.sock'))
    assert.same({ type = 'tcp', host = '127.0.0.1', port = 6666 }, rpc.parse_address('127.0.0.1:6666'))
    assert.same({ type = 'tcp', host = '::1', port = 7777 }, rpc.parse_address('::1:7777'))
    assert.same({ type = 'tcp', host = '::1', port = 7777 }, rpc.parse_address('[::1]:7777'))
    assert.same({ type = 'tcp', host = 'localhost', port = 80 }, rpc.parse_address('localhost:80'))
    assert.same({ type = 'pipe', path = '/tmp/a:1' }, rpc.parse_address('/tmp/a:1'))
    assert.same({ type = 'pipe', path = [[\\.\pipe\nvim-1]] }, rpc.parse_address([[\\.\pipe\nvim-1]]))
    assert.eq(nil, (rpc.parse_address('')))
  end)

  it('makes requests, maps handles and errors', function()
    local client = assert(connect(target.addr))
    assert.truthy(client:is_connected())
    assert.same({ true, 2 }, { client:request_sync('nvim_eval', { '1+1' }, 2000) })
    assert.same({ true, 1 }, { client:request_sync('nvim_get_current_buf', {}, 2000) })
    local ok, wins = client:request_sync('nvim_list_wins', {}, 2000)
    assert.truthy(ok)
    assert.same({ 1000 }, wins)
    local ok2, err = client:request_sync('nvim_eval', { 'no_such_var' }, 2000)
    assert.falsy(ok2)
    assert.eq('remote', err.kind)
    assert.matches('E121', err.message)
    local ok3, big = client:request_sync('nvim_exec_lua', { 'return string.rep("x", 2 * 1024 * 1024)', {} }, 5000)
    assert.truthy(ok3)
    assert.eq(2 * 1024 * 1024, #big)
    local ok4, echoed = client:request_sync('nvim_exec_lua', { 'return ...', { { a = { 1, 2 }, b = 'é' } } }, 2000)
    assert.truthy(ok4)
    assert.same({ a = { 1, 2 }, b = 'é' }, echoed)
    client:close()
    assert.falsy(client:is_connected())
  end)

  it('times out slow requests and keeps working afterwards', function()
    local client = assert(connect(target.addr))
    local t0 = uv.hrtime()
    local ok, err = client:request_sync('nvim_exec_lua', { 'vim.uv.sleep(600)', {} }, 150)
    local elapsed = (uv.hrtime() - t0) / 1e6
    assert.falsy(ok)
    assert.eq('timeout', err.kind)
    assert.truthy(elapsed < 500, 'timed out after ' .. elapsed .. ' ms')
    local ok2, v = client:request_sync('nvim_eval', { '40+2' }, 3000)
    assert.truthy(ok2, vim.inspect(v))
    assert.eq(42, v)
    client:close()
  end)

  it('fails pending requests when the target goes away', function()
    local client = assert(connect(target.addr))
    local closed_reason
    local done, rerr = false, nil
    client._opts.on_close = function(reason)
      closed_reason = reason
    end
    client:request('nvim_exec_lua', { 'vim.uv.sleep(3000)', {} }, 10000, function(err)
      done, rerr = true, err
    end)
    vim.wait(100)
    fn.jobstop(target.job)
    wait_for(function()
      return done
    end, 5000, 'pending request to fail')
    assert.eq('closed', rerr.kind)
    wait_for(function()
      return closed_reason ~= nil
    end, 1000, 'on_close')
    assert.falsy(client:is_connected())
    local ok, err = client:request_sync('nvim_eval', { '1' }, 500)
    assert.falsy(ok)
    assert.eq('closed', err.kind)
  end)

  it('reports connection failures', function()
    local _, err = connect(target.dir .. '/missing.sock')
    assert.eq('connect', err.kind)
    assert.matches('cannot connect', err.message)
  end)

  it('connects over tcp', function()
    local t = start_target('127.0.0.1:0')
    local ok, res = pcall(function()
      assert.matches('^127%.0%.0%.1:%d+$', t.addr)
      local client = assert(connect(t.addr))
      local r = { client:request_sync('nvim_eval', { 'v:servername' }, 2000) }
      client:close()
      -- a hostname resolves and every address is tried
      local by_name = assert(connect('localhost:' .. t.addr:match(':(%d+)$')))
      assert.same({ true, 3 }, { by_name:request_sync('nvim_eval', { '1+2' }, 2000) })
      by_name:close()
      return r
    end)
    stop_target(t)
    assert.truthy(ok, res)
    assert.same({ true, t.addr }, res)
  end)
end)

describe('nvim_mcp server (in process)', function()
  local target, out, srv

  local function new_server(opts)
    out = {}
    opts = opts or {}
    opts.write = function(line)
      out[#out + 1] = vim.json.decode(line)
    end
    return server.new(opts)
  end

  local function request(id, method, params)
    srv:handle_line(vim.json.encode({ jsonrpc = '2.0', id = id, method = method, params = params }))
  end

  local function reply_for(id, ms)
    local found
    wait_for(function()
      for _, m in ipairs(out) do
        if m.id == id then
          found = m
          return true
        end
      end
      return false
    end, ms or 5000, 'reply ' .. tostring(id))
    return found
  end

  before_each(function()
    target = start_target()
  end)
  after_each(function()
    if srv then
      srv:close()
      srv = nil
    end
    stop_target(target)
    target = nil
  end)

  it('lists tools with strict schemas and valid names', function()
    srv = new_server({ addr = target.addr })
    request(1, 'initialize', { protocolVersion = '2025-06-18', capabilities = vim.empty_dict(),
      clientInfo = { name = 't', version = '1' } })
    local init = reply_for(1)
    assert.eq('2025-06-18', init.result.protocolVersion)
    request(2, 'tools/list', vim.empty_dict())
    local tools = reply_for(2).result.tools
    local names = {}
    for _, t in ipairs(tools) do
      names[#names + 1] = t.name
      assert.matches('^[a-z][a-z0-9_]*$', t.name)
      assert.truthy(#t.name <= 40)
      assert.eq('object', t.inputSchema.type)
      assert.eq(false, t.inputSchema.additionalProperties)
      assert.truthy(R.tools[t.name], 'remote implements ' .. t.name)
    end
    table.sort(names)
    assert.same({ 'edit_buffer', 'eval', 'exec_lua', 'execute_command', 'get_diagnostics', 'get_editor_state',
      'list_buffers', 'notify', 'open_file', 'read_buffer' }, names)
    assert.same(names, (function()
      local n = nvim_mcp.tool_names()
      table.sort(n)
      return n
    end)())
  end)

  it('restricts protocol versions and answers unknown methods with -32601', function()
    srv = new_server({ addr = target.addr })
    request(1, 'initialize', { protocolVersion = '2099-01-01' })
    assert.eq('2025-11-25', reply_for(1).result.protocolVersion)
    request(2, 'server/discover', vim.empty_dict())
    assert.same({ code = -32601, message = 'Method not found' }, reply_for(2).error)
    srv:handle_line('{"jsonrpc":"2.0","id":7,"result":{}}')
    srv:handle_line('{"jsonrpc":"2.0","method":"notifications/initialized"}')
    request(3, 'ping')
    assert.same({}, reply_for(3).result)
    assert.eq(2, #out - 1) -- only replies to 1, 2 and 3
  end)

  it('calls tools in the parent and installs the remote code once', function()
    srv = new_server({ addr = target.addr, agent = 'claude', session = 'sess-1' })
    request(1, 'tools/call', { name = 'exec_lua', arguments = { code = 'return ... * 2', args = { 21 } } })
    local r = reply_for(1)
    assert.same({ content = { { type = 'text', text = '42' } } }, r.result)
    request(2, 'tools/call', { name = 'eval', arguments = { expression = 'v:servername' } })
    assert.eq(vim.json.encode(target.addr), reply_for(2).result.content[1].text)
    local check = assert(connect(target.addr))
    local ok, info = check:request_sync('nvim_exec_lua', { [[
      local reg = _G.__agent_nvim_remote
      local n = 0
      for _ in pairs(reg.modules) do n = n + 1 end
      local client
      for _, c in ipairs(vim.api.nvim_list_chans()) do
        if c.client and c.client.name == 'agent.nvim-mcp' then client = c.client end
      end
      return { modules = n, attrs = client and client.attributes }
    ]], {} }, 2000)
    check:close()
    assert.truthy(ok, vim.inspect(info))
    assert.same({ modules = 1, attrs = { agent = 'claude', session = 'sess-1' } }, info)
  end)

  it('reinstalls the remote code when it disappears', function()
    srv = new_server({ addr = target.addr })
    request(1, 'tools/call', { name = 'eval', arguments = { expression = '1' } })
    assert.eq('1', reply_for(1).result.content[1].text)
    local check = assert(connect(target.addr))
    check:request_sync('nvim_exec_lua', { '_G.__agent_nvim_remote = nil', {} }, 2000)
    check:close()
    request(2, 'tools/call', { name = 'eval', arguments = { expression = '2' } })
    assert.eq('2', reply_for(2).result.content[1].text)
  end)

  it('returns tool errors for invalid arguments and -32602 for unknown tools', function()
    srv = new_server({ addr = target.addr })
    request(1, 'tools/call', { name = 'read_buffer', arguments = { bogus = 1 } })
    local r = reply_for(1).result
    assert.eq(true, r.isError)
    assert.matches('unknown argument "bogus"', r.content[1].text)
    request(2, 'tools/call', { name = 'edit_buffer', arguments = { buffer = 1, start_line = 'x', end_line = 1, text = '' } })
    assert.matches('"start_line" must be an integer', reply_for(2).result.content[1].text)
    request(3, 'tools/call', { name = 'open_file', arguments = { path = '/x', split = 'diagonal' } })
    assert.matches('one of none, horizontal, vertical, tab', reply_for(3).result.content[1].text)
    request(4, 'tools/call', { name = 'nope', arguments = {} })
    assert.eq(-32602, reply_for(4).error.code)
    request(5, 'tools/call', { name = 'edit_buffer', arguments = { buffer = 1, start_line = 1, text = '' } })
    assert.matches('missing required argument "end_line"', reply_for(5).result.content[1].text)
    -- numeric strings and nulls are tolerated
    request(6, 'tools/call', { name = 'read_buffer', arguments = { start_line = '1', end_line = vim.NIL } })
    assert.falsy(reply_for(6).result.isError)
  end)

  it('refuses to run while the parent waits at a prompt', function()
    srv = new_server({ addr = target.addr })
    local ui = fn.sockconnect('pipe', target.addr, { rpc = true })
    vim.rpcrequest(ui, 'nvim_ui_attach', 80, 24, { rgb = true })
    vim.rpcrequest(ui, 'nvim_input', ':echo "a\\nb\\nc"<CR>')
    wait_for(function()
      return vim.rpcrequest(ui, 'nvim_get_mode').blocking
    end, 3000, 'hit-enter prompt')
    request(1, 'tools/call', { name = 'exec_lua', arguments = { code = 'vim.g.ran = true' } })
    local r = reply_for(1).result
    assert.eq(true, r.isError)
    assert.matches('waiting for input at a prompt', r.content[1].text)
    vim.rpcrequest(ui, 'nvim_input', '<CR>')
    wait_for(function()
      return not vim.rpcrequest(ui, 'nvim_get_mode').blocking
    end, 3000, 'prompt dismissed')
    assert.eq(vim.NIL, vim.rpcrequest(ui, 'nvim_eval', 'get(g:, "ran", v:null)'))
    pcall(vim.rpcrequest, ui, 'nvim_ui_detach')
    fn.chanclose(ui)
  end)

  it('times out and stays usable; replies to cancelled calls are dropped', function()
    srv = new_server({ addr = target.addr, timeout_ms = 300 })
    request(1, 'tools/call', { name = 'exec_lua', arguments = { code = 'vim.uv.sleep(800)' } })
    local r = reply_for(1, 3000).result
    assert.eq(true, r.isError)
    assert.matches('may still run later', r.content[1].text)
    vim.wait(700)
    request(2, 'tools/call', { name = 'eval', arguments = { expression = '5' } })
    assert.eq('5', reply_for(2, 3000).result.content[1].text)
    srv.timeout_ms = 5000
    request(3, 'tools/call', { name = 'exec_lua', arguments = { code = 'vim.uv.sleep(300) return 1' } })
    srv:handle_line(vim.json.encode({ jsonrpc = '2.0', method = 'notifications/cancelled', params = { requestId = 3 } }))
    request(4, 'ping')
    reply_for(4)
    vim.wait(800)
    for _, m in ipairs(out) do
      assert.truthy(m.id ~= 3, 'cancelled request must not be answered')
    end
  end)

  it('reports an unreachable parent as a tool error', function()
    srv = new_server({ addr = target.dir .. '/gone.sock' })
    request(1, 'tools/call', { name = 'eval', arguments = { expression = '1' } })
    local r = reply_for(1).result
    assert.eq(true, r.isError)
    assert.matches('Cannot connect to Neovim', r.content[1].text)
  end)

  it('serves zero tools without an address', function()
    srv = new_server({})
    request(1, 'tools/list')
    assert.same({}, reply_for(1).result.tools)
    request(2, 'tools/call', { name = 'eval', arguments = { expression = '1' } })
    assert.eq(-32602, reply_for(2).error.code)
  end)
end)

describe('nvim_mcp helpers', function()
  it('resolves addresses', function()
    assert.eq('/a.sock', server.resolve_address('/a.sock', '/b.sock'))
    assert.eq('/b.sock', server.resolve_address('', '/b.sock'))
    assert.eq('/b.sock', server.resolve_address('${NVIM}', '/b.sock'))
    assert.eq(nil, server.resolve_address('${NVIM}', ''))
    assert.eq(nil, server.resolve_address(nil, nil))
  end)

  it('cleans invalid UTF-8', function()
    assert.eq('abc', server.utf8_clean('abc'))
    assert.eq('é😀', server.utf8_clean('é😀'))
    assert.eq('a\239\191\189b', server.utf8_clean('a\255b'))
    assert.eq('\239\191\189\239\191\189', server.utf8_clean('\237\160'))
  end)

  it('builds launch commands', function()
    local script = nvim_mcp.script_path()
    assert.eq(root .. '/lua/agent/nvim_mcp/main.lua', script)
    assert.truthy(uv.fs_stat(script))
    assert.same({ vim.v.progpath, '--headless', '-u', 'NONE', '-i', 'NONE', '-n', '-l', script, '/x.sock' },
      nvim_mcp.command('/x.sock'))
    local p = nvim_mcp.persistent_command()
    assert.eq(fn.exepath('nvim') ~= '' and fn.exepath('nvim') or vim.v.progpath, p[1])
    assert.eq('${NVIM}', p[#p])
    assert.eq(script, p[#p - 1])
    local addr = assert(nvim_mcp.address())
    assert.eq(vim.v.servername, addr)
    assert.same({ NVIM = '/x.sock', AGENT_NVIM_AGENT = 'claude', AGENT_NVIM_SESSION = 's', AGENT_NVIM_TIMEOUT_MS = '1000' },
      nvim_mcp.env({ addr = '/x.sock', agent = 'claude', session = 's', timeout_ms = 1000 }))
  end)
end)
