local config = require('agent.config')
local util = require('agent.util')
local ctx = require('agent.editor.context')

local api = vim.api
local dir

local function write(name, lines)
  local p = dir .. '/' .. name
  vim.fn.writefile(lines, p)
  return p
end

local function edit(name, lines)
  local p = write(name, lines)
  vim.cmd('edit ' .. vim.fn.fnameescape(p))
  return api.nvim_get_current_buf(), api.nvim_buf_get_name(0)
end

local function reset_ui()
  if api.nvim_get_mode().mode ~= 'n' then
    api.nvim_feedkeys(api.nvim_replace_termcodes('<Esc>', true, false, true), 'nx', false)
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

local function terminal_buf()
  local b = api.nvim_create_buf(true, false)
  api.nvim_open_term(b, {})
  return b
end

describe('editor.context', function()
  before_each(function()
    config.setup({})
    dir = vim.fn.tempname()
    util.mkdir_p(dir)
    dir = util.realpath(dir)
    reset_ui()
  end)

  after_each(function()
    reset_ui()
    util.remove_dir(dir)
  end)

  it('is_file_buffer accepts real files only', function()
    local b = edit('a.lua', { 'x' })
    assert.truthy(ctx.is_file_buffer(b))
    assert.falsy(ctx.is_file_buffer(terminal_buf()))
    local acw = api.nvim_create_buf(false, true)
    vim.bo[acw].buftype = 'acwrite'
    api.nvim_buf_set_name(acw, 'agent-diff://id')
    assert.falsy(ctx.is_file_buffer(acw))
    local url = api.nvim_create_buf(true, false)
    api.nvim_buf_set_name(url, 'fugitive:///repo/.git//0/a.lua')
    assert.falsy(ctx.is_file_buffer(url))
    assert.falsy(ctx.is_file_buffer(api.nvim_create_buf(true, false)), 'unnamed')
    assert.falsy(ctx.is_file_buffer(api.nvim_create_buf(true, true)), 'scratch')
    local ignored = vim.fn.bufadd(dir .. '/ignored.txt')
    vim.b[ignored].agent_ignore = true
    assert.falsy(ctx.is_file_buffer(ignored))
    assert.falsy(ctx.is_file_buffer(99999))
  end)

  it('find_buf matches names exactly, not as patterns, and resolves symlinks', function()
    local a = edit('a.lua', { 'a' })
    local aa = edit('aa.lua', { 'aa' })
    local br = edit('[x].lua', { 'x' })
    assert.eq(a, ctx.find_buf(dir .. '/a.lua'))
    assert.eq(aa, ctx.find_buf(dir .. '/aa.lua'))
    assert.eq(br, ctx.find_buf(dir .. '/[x].lua'))
    assert.eq(nil, ctx.find_buf(dir .. '/nope.lua'))
    assert.eq(nil, ctx.find_buf(''))
    -- through a symlinked directory
    local link = dir .. '-link'
    assert.truthy(vim.uv.fs_symlink(dir, link))
    assert.eq(a, ctx.find_buf(link .. '/a.lua'))
    vim.uv.fs_unlink(link)
    -- a file that does not exist yet, named through a symlinked directory
    assert.truthy(vim.uv.fs_symlink(dir, link))
    vim.cmd('edit ' .. vim.fn.fnameescape(link .. '/brand-new.txt'))
    local nb = api.nvim_get_current_buf()
    assert.eq(nb, ctx.find_buf(dir .. '/brand-new.txt'))
    assert.eq(nb, ctx.find_buf(link .. '/brand-new.txt'))
    assert.eq(dir .. '/brand-new.txt', ctx.resolve_path(link .. '/brand-new.txt'))
    vim.uv.fs_unlink(link)
    -- loaded filter
    local unloaded = vim.fn.bufadd(dir .. '/unloaded.lua')
    assert.eq(unloaded, ctx.find_buf(dir .. '/unloaded.lua'))
    assert.eq(nil, ctx.find_buf(dir .. '/unloaded.lua', { loaded = true }))
  end)

  it('path_from_uri handles raw and percent-encoded file URIs and plain paths', function()
    local spaced = write('with space.txt', { 'x' })
    assert.eq(spaced, ctx.path_from_uri('file://' .. spaced))
    assert.eq(spaced, ctx.path_from_uri(vim.uri_from_fname(spaced)))
    assert.eq(spaced, ctx.path_from_uri(spaced))
    -- a real file whose name contains a percent sequence: the raw form wins
    local pct = write('100%20.txt', { 'x' })
    assert.eq(pct, ctx.path_from_uri('file://' .. pct))
    -- neither form exists: decode
    assert.eq(dir .. '/new file.txt', ctx.path_from_uri('file://' .. dir .. '/new%20file.txt'))
    assert.eq(nil, ctx.path_from_uri('untitled:Untitled-1'))
    assert.eq(nil, ctx.path_from_uri(''))
    assert.eq(nil, ctx.path_from_uri(nil))
  end)

  it('names buffers that are not files nvim://buffer/<n>/<label>, and parses those ids', function()
    -- A terminal: the basename of the first word of its command, quoted or not.
    vim.cmd('vnew')
    local j1 = vim.fn.jobstart({ '/bin/sh', '-c', 'exec sleep 30' }, { term = true })
    local t1 = api.nvim_get_current_buf()
    vim.cmd([[terminal "/bin/sh" -c "exec sleep 30"]])
    local t2 = api.nvim_get_current_buf()
    assert.matches('^term://.*//%d+:"/bin/sh"', api.nvim_buf_get_name(t2))
    assert.eq('sh', ctx.buffer_label(t1))
    assert.eq('sh', ctx.buffer_label(t2))
    assert.eq(('nvim://buffer/%d/sh'):format(t1), ctx.buffer_uri(t1))
    vim.fn.jobstop(j1)
    vim.fn.jobstop(vim.bo[t2].channel)
    -- Else the filetype, else the basename of the name, else "scratch".
    local b = api.nvim_create_buf(true, true)
    assert.eq('scratch', ctx.buffer_label(b))
    api.nvim_buf_set_name(b, 'oil:///tmp/a\tb/')
    assert.eq('ab', ctx.buffer_label(b), 'no control characters')
    -- Nor C1 controls, line separators or bidirectional overrides.
    api.nvim_buf_set_name(b, 'x\u{9b}[31my\u{2028}z\u{202e}w\u{2066}v\u{200f}u')
    assert.eq('x[31myzwvu', ctx.buffer_label(b))
    api.nvim_buf_set_name(b, 'oil:///tmp/a\tb/')
    vim.bo[b].filetype = 'oil'
    assert.eq('oil', ctx.buffer_label(b))
    assert.eq(('nvim://buffer/%d/oil'):format(b), ctx.buffer_uri(b))
    -- Ids.
    assert.truthy(ctx.is_buffer_uri('nvim://buffer/12/fish'))
    assert.falsy(ctx.is_buffer_uri('/tmp/nvim://buffer/12'))
    assert.falsy(ctx.is_buffer_uri(nil))
    assert.eq(12, ctx.bufnr_from_uri('nvim://buffer/12/fish'))
    assert.eq(12, ctx.bufnr_from_uri('nvim://buffer/12'))
    assert.eq(nil, ctx.bufnr_from_uri('nvim://buffer/x/fish'))
    assert.eq(nil, ctx.bufnr_from_uri('nvim://buffer/12x'))
    assert.eq(nil, ctx.bufnr_from_uri('/p/a.lua'))
    assert.eq(nil, ctx.bufnr_from_uri('nvim://buffer/0/x'), 'buffer 0 names no buffer')
    assert.eq(nil, ctx.bufnr_from_uri('nvim://buffer/0'))
    assert.eq(nil, ctx.path_from_uri('nvim://buffer/12/fish'), 'not a file')
    -- A :help buffer is a file on disk.
    vim.cmd('help help')
    assert.truthy(ctx.is_disk_file(api.nvim_get_current_buf()))
    assert.falsy(ctx.is_file_buffer(api.nvim_get_current_buf()))
    assert.falsy(ctx.is_disk_file(b))
  end)

  it('labels a toggleterm terminal by its shell, and cuts labels to 64 bytes of valid UTF-8', function()
    local common = require('agent.net.common')
    -- toggleterm starts `<shell>;#toggleterm#<n>`: the program word ends at the ";".
    local t = api.nvim_create_buf(true, false)
    api.nvim_open_term(t, {})
    for _, c in ipairs({
      { 'term://~/src//4242:/opt/homebrew/bin/fish;#toggleterm#1', 'fish' },
      { 'term://~/src//4243:fish;#toggleterm#12', 'fish' },
      { 'term://~/src//4244:/bin/zsh -l;#toggleterm#3', 'zsh' },
      { 'term://~/src//4245:"/a dir/my prog";#toggleterm#2', 'my prog' },
      { 'term://~/src//4246:/bin/sh -c "a;b"', 'sh' },
    }) do
      api.nvim_buf_set_name(t, c[1])
      assert.eq(c[2], ctx.buffer_label(t), c[1])
    end
    assert.eq(('nvim://buffer/%d/sh'):format(t), ctx.buffer_uri(t))

    local b = api.nvim_create_buf(true, true)
    -- 66 bytes: cut before the character that does not fit, never inside it.
    api.nvim_buf_set_name(b, string.rep('漢', 22))
    assert.eq(string.rep('漢', 21), ctx.buffer_label(b))
    assert.truthy(common.valid_utf8(ctx.buffer_uri(b)))
    api.nvim_buf_set_name(b, string.rep('a', 63) .. 'é')
    assert.eq(string.rep('a', 63), ctx.buffer_label(b))
    api.nvim_buf_set_name(b, string.rep('a', 62) .. 'é')
    assert.eq(string.rep('a', 62) .. 'é', ctx.buffer_label(b), 'exactly 64 bytes')
    -- Bytes that are not UTF-8 (a Latin-1 name) are left out.
    api.nvim_buf_set_name(b, 'caf\233-cr\195\168me')
    assert.eq('caf-crème', ctx.buffer_label(b))
    assert.truthy(common.valid_utf8(ctx.buffer_uri(b)))
    api.nvim_buf_set_name(b, '\255\254')
    assert.eq('scratch', ctx.buffer_label(b))
  end)

  it('workspace_folders starts with the realpath of the cwd', function()
    local cwd = vim.fn.getcwd()
    vim.cmd('cd ' .. vim.fn.fnameescape(dir))
    local folders = ctx.workspace_folders()
    assert.eq(dir, folders[1])
    assert.same({ dir }, ctx.workspace_folders({ lsp = false }))
    vim.cmd('cd ' .. vim.fn.fnameescape(cwd))
  end)

  it('open_editors lists loaded, listed file buffers', function()
    local a, pa = edit('a.lua', { 'x', 'y' })
    vim.bo[a].filetype = 'lua'
    local b = edit('b.txt', { 'z' })
    api.nvim_buf_set_lines(b, 0, -1, false, { 'changed' })
    vim.cmd('edit ' .. vim.fn.fnameescape(dir .. '/new.md'))
    local n = api.nvim_get_current_buf()
    terminal_buf()
    local unlisted = vim.fn.bufadd(write('unlisted.txt', { 'u' }))
    vim.fn.bufload(unlisted)
    vim.bo[unlisted].buflisted = false
    local eds = ctx.open_editors()
    assert.same({ a, b, n }, vim.tbl_map(function(e)
      return e.bufnr
    end, eds))
    assert.eq(pa, eds[1].path)
    assert.eq('lua', eds[1].language_id)
    assert.eq('a.lua', eds[1].label)
    assert.eq(2, eds[1].line_count)
    assert.falsy(eds[1].is_dirty)
    assert.falsy(eds[1].is_untitled)
    assert.truthy(eds[2].is_dirty)
    assert.eq('plaintext', eds[2].language_id)
    assert.truthy(eds[3].is_untitled)
    assert.truthy(eds[3].is_active)
    assert.falsy(eds[1].is_active)
  end)

  it('active_buf falls back to the last focused file when a terminal has focus', function()
    local sel = require('agent.editor.selection')
    sel._reset()
    sel.start()
    local a = edit('a.lua', { 'x' })
    vim.cmd('vsplit')
    api.nvim_win_set_buf(0, terminal_buf())
    assert.eq(a, ctx.active_buf())
    sel._reset()
  end)

  it('diagnostics are grouped by file with 0-based ranges and numeric severities', function()
    local ns = api.nvim_create_namespace('agent-test')
    local a, pa = edit('a.lua', { 'local x = foo', 'return x' })
    local b, pb = edit('b.lua', { 'y' })
    edit('c.lua', { 'z' })
    vim.diagnostic.set(ns, b, {
      { lnum = 0, col = 0, message = 'bee', severity = vim.diagnostic.severity.WARN, source = 'lint', code = 42 },
    })
    vim.diagnostic.set(ns, a, {
      { lnum = 1, col = 0, end_lnum = 1, end_col = 6, message = 'second', severity = vim.diagnostic.severity.HINT },
      { lnum = 0, col = 10, end_lnum = 0, end_col = 13, message = "undefined global 'foo'",
        severity = vim.diagnostic.severity.ERROR, source = 'lua_ls',
        user_data = { lsp = { code = 'undefined-global' } } },
    })
    local all = ctx.diagnostics()
    assert.eq(2, #all, 'only files with diagnostics')
    assert.eq(pa, all[1].path)
    assert.eq(a, all[1].bufnr)
    assert.eq(pb, all[2].path)
    assert.same({
      message = "undefined global 'foo'",
      severity = 1,
      range = { start = { line = 0, character = 10 }, ['end'] = { line = 0, character = 13 } },
      source = 'lua_ls',
      code = 'undefined-global',
    }, all[1].diagnostics[1])
    assert.eq('second', all[1].diagnostics[2].message)
    assert.eq(4, all[1].diagnostics[2].severity)
    assert.eq(42, all[2].diagnostics[1].code)
    assert.eq(2, all[2].diagnostics[1].severity)
    -- end defaults to the start
    assert.same({ start = { line = 0, character = 0 }, ['end'] = { line = 0, character = 0 } }, all[2].diagnostics[1].range)

    local one = ctx.diagnostics(pb)
    assert.eq(1, #one)
    assert.eq(pb, one[1].path)
    assert.eq(1, #one[1].diagnostics)

    local clean = ctx.diagnostics(dir .. '/c.lua')
    assert.eq(1, #clean)
    assert.same({}, clean[1].diagnostics)

    local missing = ctx.diagnostics(dir .. '/not-open.lua')
    assert.same({ { path = dir .. '/not-open.lua', diagnostics = {} } }, missing)
    vim.diagnostic.reset(ns)
  end)

  it('is_dirty and save', function()
    local b, path = edit('s.txt', { 'old' })
    assert.eq(false, ctx.is_dirty(path))
    api.nvim_buf_set_lines(b, 0, -1, false, { 'new' })
    assert.eq(true, ctx.is_dirty(path))
    assert.eq(nil, ctx.is_dirty(dir .. '/unknown.txt'))
    local ok, err = ctx.save(path)
    assert.truthy(ok, err)
    assert.eq(false, ctx.is_dirty(path))
    assert.same({ 'new' }, vim.fn.readfile(path))
    ok, err = ctx.save(dir .. '/unknown.txt')
    assert.falsy(ok)
    assert.matches('Document not open', err)
  end)

  it('main_window skips terminal and floating windows and splits when needed', function()
    local term = terminal_buf()
    api.nvim_win_set_buf(0, term)
    local term_win = api.nvim_get_current_win()
    local float = api.nvim_open_win(api.nvim_create_buf(false, true), true,
      { relative = 'editor', row = 1, col = 1, width = 10, height = 2 })
    local win = ctx.main_window()
    assert.truthy(win ~= term_win and win ~= float)
    assert.eq('', api.nvim_win_get_config(win).relative)
    assert.eq(2, #vim.tbl_filter(function(w)
      return api.nvim_win_get_config(w).relative == ''
    end, api.nvim_tabpage_list_wins(0)))
    api.nvim_win_close(float, true)
    -- an existing editor window is reused
    api.nvim_set_current_win(term_win)
    assert.eq(win, ctx.main_window())
    -- create=false never splits
    api.nvim_win_close(win, true)
    assert.eq(nil, ctx.main_window({ create = false }))
    assert.eq(1, #api.nvim_tabpage_list_wins(0))
  end)

  it('open_file opens in the main window, never in the terminal, and selects lines', function()
    local path = write('o.txt', { '1', '2', '3', '4', '5' })
    local term = terminal_buf()
    api.nvim_win_set_buf(0, term)
    local term_win = api.nvim_get_current_win()
    local b, win = ctx.open_file(path, { line = 2, end_line = 4 })
    assert.truthy(b)
    assert.truthy(win ~= term_win)
    assert.eq(term, api.nvim_win_get_buf(term_win))
    assert.eq(win, api.nvim_get_current_win())
    assert.eq(path, api.nvim_buf_get_name(b))
    assert.eq('V', api.nvim_get_mode().mode)
    assert.eq(2, vim.fn.line('v'))
    assert.eq(4, vim.fn.line('.'))
    api.nvim_feedkeys(api.nvim_replace_termcodes('<Esc>', true, false, true), 'nx', false)

    -- already shown: same window; focus=false keeps the current window
    api.nvim_set_current_win(term_win)
    local b2, win2 = ctx.open_file(path, { line = 5, focus = false })
    assert.eq(b, b2)
    assert.eq(win, win2)
    assert.eq(term_win, api.nvim_get_current_win())
    assert.eq(5, api.nvim_win_get_cursor(win)[1])
    assert.truthy(vim.bo[b].buflisted)
  end)
end)
