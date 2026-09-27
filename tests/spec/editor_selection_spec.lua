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

  describe('leaving Visual mode', function()
    local events, grace, showmode

    before_each(function()
      grace, showmode = sel.DEMOTE_MS, vim.o.showmode
      vim.o.showmode = false -- no '-- VISUAL --' on stderr
      events = {}
      sel.subscribe(function(s)
        events[#events + 1] = s
      end)
    end)

    after_each(function()
      sel.DEMOTE_MS, vim.o.showmode = grace, showmode
      vim.o.selection = 'inclusive'
      pcall(api.nvim_del_augroup_by_name, 'SelectionSpecCmdline')
      pcall(api.nvim_del_augroup_by_name, 'SelectionSpecEdit')
      pcall(api.nvim_del_user_command, 'Probe')
    end)

    ---feed() without the command-line echo on stderr. `flags` default "x"; "x!" is needed to open the
    ---command-line window, which "x" (like :normal) does not allow.
    local function feed_silent(keys, flags)
      vim.cmd(('silent call feedkeys(%s, "%s")'):format(vim.fn.string(api.nvim_replace_termcodes(keys, true, false, true)),
        flags or 'x'))
    end

    ---Wait until the grace period and the debounce are surely over.
    local function settle()
      vim.wait(sel.DEMOTE_MS + 150)
    end

    ---The selection every consumer sees: the last event, current() and recent_files().
    local function seen()
      local s, live = sel.current()
      local files = sel.recent_files()
      local last = events[#events]
      return {
        event = last and last.text,
        current = s and s.text,
        live = live,
        selected_text = files[1] and files[1].selected_text,
        active = files[1] and vim.fs.basename(files[1].path),
      }
    end

    it('in the same file window drops the selection after a short grace period', function()
      edit('a.txt', { 'one', 'two', 'three' })
      api.nvim_win_set_cursor(0, { 1, 0 })
      feed('vjl', 'x!')
      wait_for(function()
        return #events > 0 and events[#events].text == 'one\ntw'
      end, 1000, 'visual selection event')
      feed('<Esc>')
      assert.eq('n', api.nvim_get_mode().mode)
      -- Held during the grace period: the focus might still move on to the agent terminal.
      assert.eq('one\ntw', sel.current().text)
      wait_for(function()
        return events[#events].is_empty
      end, 1000, 'cursor-only event')
      local s = events[#events]
      assert.eq('n', s.mode)
      assert.same({ line = 1, character = 1 }, s.start)
      assert.same({ event = '', current = '', live = true, active = 'a.txt' }, seen())
      -- the buffer's last visual selection is still available
      assert.eq('one\ntw', sel.last_visual().text)
    end)

    it('drops the selection after y, an operator, or a move to another file window', function()
      edit('a.txt', { 'one', 'two', 'three' })
      api.nvim_win_set_cursor(0, { 1, 0 })
      feed('Vjy')
      settle()
      assert.same({ event = '', current = '', live = true, active = 'a.txt' }, seen())
      feed('Vj>')
      settle()
      assert.same({ event = '', current = '', live = true, active = 'a.txt' }, seen())
      assert.truthy(vim.fn.indent(1) > 0, '> shifted the lines')
      vim.cmd('silent undo')
      vim.cmd('belowright split ' .. vim.fn.fnameescape(write('b.txt', { 'bbb' })))
      vim.cmd('wincmd k')
      api.nvim_win_set_cursor(0, { 1, 0 })
      feed('Vj', 'x!')
      feed('<C-w>j')
      settle()
      assert.same({ event = '', current = '', live = true, active = 'b.txt' }, seen())
    end)

    it('straight for the agent terminal keeps the selection until a file window has focus again', function()
      local b = edit('a.txt', { 'one', 'two', 'three' })
      local file_win = api.nvim_get_current_win()
      open_terminal_window()
      vim.cmd('wincmd L')
      api.nvim_set_current_win(file_win)
      api.nvim_win_set_cursor(0, { 1, 0 })
      feed('Vj', 'x!')
      feed('<C-w>l') -- leaves Visual mode and moves to the terminal
      assert.eq('terminal', vim.bo.buftype)
      settle()
      assert.same({ event = 'one\ntwo', current = 'one\ntwo', live = false, selected_text = 'one\ntwo',
        active = 'a.txt' }, seen())
      assert.eq(b, sel.current().bufnr)
      -- Back in the file window, Normal mode: the agents see the cursor again.
      feed('<C-w>h')
      assert.eq(file_win, api.nvim_get_current_win())
      settle()
      assert.same({ event = '', current = '', live = true, active = 'a.txt' }, seen())
    end)

    it('keeps the selection while a command line opened from Visual mode is open and its command runs', function()
      edit('a.txt', { 'one', 'two', 'three' })
      local file_win = api.nvim_get_current_win()
      local term = open_terminal_window()
      vim.cmd('wincmd L')
      api.nvim_set_current_win(file_win)
      local got = {}
      api.nvim_create_autocmd('ModeChanged', {
        group = api.nvim_create_augroup('SelectionSpecCmdline', { clear = true }),
        pattern = '*:c',
        callback = function()
          vim.wait(sel.DEMOTE_MS + 100) -- the user takes a while to type the command
          got.cmdline = sel.current().text
          got.event = events[#events] and events[#events].text
        end,
      })
      api.nvim_create_user_command('Probe', function(o)
        got.range = { o.line1, o.line2 }
        got.command = sel.current().text
      end, { range = true })
      -- ':' leaves Visual mode first (V -> n -> c), then the command runs with the '<,'> range.
      api.nvim_win_set_cursor(0, { 1, 0 })
      feed_silent('Vj:Probe<CR>')
      assert.same({ cmdline = 'one\ntwo', event = 'one\ntwo', range = { 1, 2 }, command = 'one\ntwo' }, got)
      -- The command left a file window focused: dropped, as after <Esc>.
      settle()
      assert.same({ event = '', current = '', live = true, active = 'a.txt' }, seen())
      -- A cancelled command line: dropped.
      api.nvim_win_set_cursor(0, { 1, 0 })
      feed('Vj', 'x!')
      feed_silent(':<Esc>')
      settle()
      assert.eq('', seen().current)
      -- A command that moves to the agent terminal: kept.
      got = {}
      api.nvim_win_set_cursor(0, { 1, 0 })
      feed('Vj', 'x!')
      feed_silent(':<C-u>wincmd l<CR>')
      assert.eq(term, api.nvim_get_current_buf())
      settle()
      assert.eq('one\ntwo', got.cmdline)
      assert.same({ event = 'one\ntwo', current = 'one\ntwo', live = false, selected_text = 'one\ntwo',
        active = 'a.txt' }, seen())
    end)

    it('keeps the selection while the command-line window is open and its command runs', function()
      edit('a.txt', { 'one', 'two', 'three' })
      local file_win = api.nvim_get_current_win()
      local term = open_terminal_window()
      vim.cmd('wincmd L')
      api.nvim_set_current_win(file_win)
      local got = {}
      api.nvim_create_autocmd('ModeChanged', {
        group = api.nvim_create_augroup('SelectionSpecCmdline', { clear = true }),
        pattern = 'c:n',
        callback = function()
          if vim.fn.getcmdwintype() ~= '' then
            vim.wait(sel.DEMOTE_MS + 100) -- the user takes a while to edit the command
            got.cmdwin = sel.current().text
          end
        end,
      })
      api.nvim_create_user_command('Probe', function(o)
        got.range = { o.line1, o.line2 }
        got.command = sel.current().text
      end, { range = true })
      -- ':' then <C-f>: the command-line window holds "'<,'>"; <CR> runs the edited line.
      api.nvim_win_set_cursor(0, { 1, 0 })
      feed_silent('Vj:<C-f>AProbe<CR>', 'x!')
      assert.eq(file_win, api.nvim_get_current_win())
      assert.same({ cmdwin = 'one\ntwo', range = { 1, 2 }, command = 'one\ntwo' }, got)
      -- The command left a file window focused: dropped.
      settle()
      assert.same({ event = '', current = '', live = true, active = 'a.txt' }, seen())
      -- Closed without running a command: dropped.
      got = {}
      api.nvim_win_set_cursor(0, { 1, 0 })
      feed_silent('Vj:<C-f>:q<CR>', 'x!')
      assert.eq('one\ntwo', got.cmdwin)
      settle()
      assert.eq(file_win, api.nvim_get_current_win())
      assert.eq('', seen().current)
      -- q: from Visual mode, with a command that moves to the agent terminal: kept.
      got = {}
      api.nvim_win_set_cursor(0, { 1, 0 })
      feed_silent('Vjq:ccwincmd l<CR>', 'x!')
      assert.eq(term, api.nvim_get_current_buf())
      settle()
      assert.eq('one\ntwo', got.cmdwin)
      assert.same({ event = 'one\ntwo', current = 'one\ntwo', live = false, selected_text = 'one\ntwo',
        active = 'a.txt' }, seen())
    end)

    it('keeps the selection while Visual mode edits the command in the command-line window', function()
      edit('a.txt', { 'one', 'two', 'three' })
      local got = {}
      api.nvim_create_autocmd('ModeChanged', {
        group = api.nvim_create_augroup('SelectionSpecCmdline', { clear = true }),
        pattern = 'v:n',
        callback = function()
          if vim.fn.getcmdwintype() ~= '' then
            vim.wait(sel.DEMOTE_MS + 100)
            got.cmdwin = sel.current().text
          end
        end,
      })
      api.nvim_create_user_command('Probe', function(o)
        got.range = { o.line1, o.line2 }
        got.command = sel.current().text
      end, { range = true })
      -- q:, type "Probx", then fix the typo with Visual mode (v r e) and run the line.
      api.nvim_win_set_cursor(0, { 1, 0 })
      feed_silent('Vjq:AProbx<Esc>vre<CR>', 'x!')
      assert.same({ cmdwin = 'one\ntwo', range = { 1, 2 }, command = 'one\ntwo' }, got)
      settle()
      assert.same({ event = '', current = '', live = true, active = 'a.txt' }, seen())
    end)

    ---a.txt (`lines`, written) on the left, the agent terminal on the right, and a function that
    ---restores a.txt, selects with `keys`, then runs `leave` (keys typed right after, or a function)
    ---and returns what the consumers see once the grace period is over. With `opts.seen`, the live
    ---selection reaches the consumers before `leave` (as when the debounce runs in between).
    local function agent_layout(lines)
      local b = edit('a.txt', lines)
      local file_win = api.nvim_get_current_win()
      open_terminal_window()
      vim.cmd('wincmd L')
      api.nvim_set_current_win(file_win)
      return b, function(keys, leave, opts)
        opts = opts or {}
        api.nvim_set_current_win(file_win)
        api.nvim_buf_set_lines(b, 0, -1, false, lines)
        vim.cmd('silent write')
        api.nvim_win_set_cursor(0, { 1, 0 })
        if opts.seen then
          feed(keys, 'x!')
          sel.current() -- the live selection reached the agents (the debounce ran)
          keys = ''
        end
        if type(leave) == 'function' then
          feed(keys, 'x!')
          leave()
        else
          feed_silent(keys .. leave)
        end
        assert.eq('terminal', vim.bo.buftype)
        settle()
        return seen()
      end
    end

    it('drops a selection that an operator consumed, even when an autosave wrote the buffer', function()
      local b, select_then = agent_layout({ 'one', 'two', 'three', 'four' })
      -- An autosave defined before agent.nvim's autocommands: it writes the buffer when Visual
      -- mode ends, before the tracker hears of it.
      sel.stop()
      api.nvim_create_autocmd('ModeChanged', {
        group = api.nvim_create_augroup('SelectionSpecEdit', { clear = true }),
        pattern = '*:n',
        callback = function(ev)
          if ev.buf == b and vim.bo[b].modified then
            vim.cmd('silent update')
          end
        end,
      })
      sel.start()
      local dropped = { event = '', current = '', live = false, active = 'a.txt' }
      local cases = {
        { 'd', { 'three', 'four' } },
        { '>', { '\tone', '\ttwo', 'three', 'four' } },
        { 'J', { 'one two', 'three', 'four' } },
      }
      for _, c in ipairs(cases) do
        local op, lines = c[1], c[2]
        -- seen by the agents first, or all typed in one burst
        assert.same(dropped, select_then('Vj', op .. '<C-w>l', { seen = true }), op)
        assert.same(lines, api.nvim_buf_get_lines(b, 0, -1, false))
        assert.falsy(vim.bo[b].modified, 'written by the autosave')
        assert.same(dropped, select_then('Vj' .. op .. '<C-w>l', ''), op .. ' in one burst')
        assert.same(lines, api.nvim_buf_get_lines(b, 0, -1, false))
      end
      -- An edit elsewhere during Visual mode, written by the autosave, does not consume it.
      assert.same({ event = 'one\ntwo', current = 'one\ntwo', live = false, selected_text = 'one\ntwo',
        active = 'a.txt' }, select_then('Vj', function()
        api.nvim_buf_set_lines(b, 3, 4, false, { 'FOUR' })
        api.nvim_exec_autocmds('TextChanged', {}) -- as the main loop does (`nvim -l` does not)
        feed('<C-w>l')
      end))
    end)

    it('drops the selection when a command or a block insert changes it on the way to the agent', function()
      local b, select_then = agent_layout({ 'one', 'two', 'three' })
      local dropped = { event = '', current = '', live = false, active = 'a.txt' }
      local cases = {
        { 'Vj', ':s/o/0/<CR><C-w>l', { '0ne', 'tw0', 'three' } },
        { 'Vj', '!sort -r<CR><C-w>l', { 'two', 'one', 'three' } },
        { '<C-v>j', 'IX<Esc><C-w>l', { 'Xone', 'Xtwo', 'three' } },
        { '<C-v>j', '$AX<Esc><C-w>l', { 'oneX', 'twoX', 'three' } },
      }
      for _, c in ipairs(cases) do
        assert.same(dropped, select_then(c[1], c[2], { seen = true }), c[1] .. c[2])
        assert.same(c[3], api.nvim_buf_get_lines(b, 0, -1, false))
        assert.same(dropped, select_then(c[1] .. c[2], ''), c[1] .. c[2] .. ' in one burst')
      end
      -- A command that leaves the text as it was keeps it.
      assert.same({ event = 'one\ntwo', current = 'one\ntwo', live = false, selected_text = 'one\ntwo',
        active = 'a.txt' }, select_then('Vj', ':s/x/y/e<CR><C-w>l'))
    end)

    it('keeps the selection through an autosave on the way to the agent, not through a formatter', function()
      local b, select_then = agent_layout({ 'one', 'two', 'three' })
      local on_leave
      api.nvim_create_autocmd('WinLeave', {
        group = api.nvim_create_augroup('SelectionSpecEdit', { clear = true }),
        callback = function()
          if api.nvim_get_current_buf() == b then
            on_leave()
          end
        end,
      })
      local kept = { event = 'one\ntwo', current = 'one\ntwo', live = false, selected_text = 'one\ntwo',
        active = 'a.txt' }
      on_leave = function()
        api.nvim_buf_set_lines(b, 2, 3, false, { 'THREE' })
        vim.cmd('silent update')
      end
      assert.same(kept, select_then('Vj', '<C-w>l', { seen = true }))
      assert.same(kept, select_then('Vj', '<C-w>l'))
      -- A formatter that changes the selected text: the agent would get text that is not there.
      on_leave = function()
        api.nvim_buf_set_lines(b, 0, 1, false, { 'ONE' })
      end
      local dropped = { event = '', current = '', live = false, active = 'a.txt' }
      assert.same(dropped, select_then('Vj', '<C-w>l', { seen = true }))
      assert.same(dropped, select_then('Vj', '<C-w>l'))
    end)

    it('keeps the selection when the buffer is written or changed during Visual mode', function()
      local b = edit('a.txt', { 'one', 'two', 'three' })
      local file_win = api.nvim_get_current_win()
      open_terminal_window()
      vim.cmd('wincmd L')
      api.nvim_set_current_win(file_win)
      local kept = { event = 'one\ntwo', current = 'one\ntwo', live = false, selected_text = 'one\ntwo',
        active = 'a.txt' }
      ---Select the first two lines, run `during` still in Visual mode, then `leave` it.
      local function select_then(during, leave)
        feed('<C-w>h')
        api.nvim_win_set_cursor(0, { 1, 0 })
        feed('Vj', 'x!')
        during()
        assert.eq('V', api.nvim_get_mode().mode)
        feed(leave)
        assert.eq('terminal', vim.bo.buftype)
        settle()
        return seen()
      end
      -- A write (a timer-based autosave) bumps changedtick, as an operator would.
      api.nvim_buf_set_lines(b, 2, 3, false, { 'THREE' })
      assert.same(kept, select_then(function()
        vim.cmd('silent write')
      end, '<C-w>l'))
      -- The same without autocommands (an autosave with :noautocmd): no BufWritePost.
      api.nvim_buf_set_lines(b, 2, 3, false, { 'three' })
      assert.same(kept, select_then(function()
        vim.cmd('silent noautocmd write')
      end, '<C-w>l'))
      -- An edit by a plugin (a formatter, an LSP edit): TextChanged comes while still in Visual mode.
      assert.same(kept, select_then(function()
        api.nvim_buf_set_lines(b, 2, 3, false, { 'THREE' })
        api.nvim_exec_autocmds('TextChanged', {}) -- as the main loop does (`nvim -l` does not)
      end, '<C-w>l'))
      -- An operator still consumes the selection, even right after a write and on the way to the
      -- agent terminal.
      assert.same({ event = '', current = '', live = false, active = 'a.txt' }, select_then(function()
        vim.cmd('silent write')
      end, '><C-w>l'))
      assert.eq('\tone', api.nvim_buf_get_lines(b, 0, 1, false)[1])
    end)

    ---What the consumers see when `text` is kept on the way to the agent.
    local function kept(text)
      return { event = text, current = text, live = false, selected_text = text, active = 'a.txt' }
    end
    local dropped = { event = '', current = '', live = false, active = 'a.txt' }

    it('drops a selection an operator consumed in a burst of keys, even if the region holds its text', function()
      -- Typed in one burst, V j d are not seen one by one: the selection last seen is the first line
      -- alone, and after d the region left holds that text again.
      local b, select_then = agent_layout({ '  }', '  }', '  }', '}' })
      assert.same(dropped, select_then('Vjd<C-w>l', ''))
      assert.same({ '  }', '}' }, api.nvim_buf_get_lines(b, 0, -1, false))
      assert.same(dropped, select_then('Vj', 'd<C-w>l', { seen = true }))
      assert.same(dropped, select_then('Vjx<C-w>l', ''))
      -- y changes nothing: kept, in a burst too.
      assert.same(kept('  }\n  }'), select_then('Vjy<C-w>l', ''))
    end)

    it('reads the held selection in the window it was selected in', function()
      -- 'list' without "tab:" in 'listchars' shows a tab as ^I, two cells: the block is b, 2, b
      -- there, and would be b, 8, b in the agent terminal.
      local b, select_then = agent_layout({ '\tbc', '0123456789ab', '\tbc', 'x' })
      local file_win = api.nvim_get_current_win()
      vim.wo[file_win].list, vim.wo[file_win].listchars = true, 'eol:$'
      -- An autosave on the way to the agent: the held selection is read again to check it.
      api.nvim_create_autocmd('BufLeave', {
        group = api.nvim_create_augroup('SelectionSpecEdit', { clear = true }),
        buffer = b,
        callback = function()
          if vim.bo[b].modified then
            vim.cmd('silent update')
          end
        end,
      })
      local function dirty()
        api.nvim_buf_set_lines(b, 3, 4, false, { 'X' })
        api.nvim_exec_autocmds('TextChanged', {}) -- as the main loop does (`nvim -l` does not)
        feed('<C-w>l')
      end
      assert.same(kept('b\n2\nb'), select_then('l<C-v>jj', dirty, { seen = true }))
      assert.falsy(vim.bo[b].modified, 'written by the autosave')
      assert.same(kept('b\n2\nb'), select_then('l<C-v>jj', dirty))
      vim.wo[file_win].list = false
    end)

    it('follows the held selection to where its text moved, and drops it when its text changed', function()
      local b, select_then = agent_layout({ 'zero', 'one', 'two', 'three' })
      local edit_on_leave
      api.nvim_create_autocmd('WinLeave', {
        group = api.nvim_create_augroup('SelectionSpecEdit', { clear = true }),
        callback = function()
          if api.nvim_get_current_buf() == b then
            vim.schedule(edit_on_leave) -- within the grace period, once the selection is held
          end
        end,
      })
      -- A plugin inserts a line above the selection.
      edit_on_leave = function()
        api.nvim_buf_set_lines(b, 0, 0, false, { '-- header' })
      end
      assert.same(kept('one\ntwo'), select_then('jVj', '<C-w>l'))
      local s = sel.current()
      assert.same({ 3, 4 }, { s.start_line, s.end_line }, 'where the text is now')
      assert.same({ line = 2, character = 0 }, s.start)
      assert.same({ line = 3, character = 3 }, s.finish)
      assert.eq(s.start_line, events[#events].start_line, 'the agents got the new lines')
      assert.same(kept('one\ntwo'), select_then('jVj', '<C-w>l', { seen = true }))
      -- Right above its first line, or right below its last line.
      edit_on_leave = function()
        api.nvim_buf_set_lines(b, 1, 1, false, { 'new' })
        api.nvim_buf_set_lines(b, 4, 4, false, { 'new' })
      end
      assert.same(kept('one\ntwo'), select_then('jVj', '<C-w>l'))
      assert.same({ 3, 4 }, { sel.current().start_line, sel.current().end_line })
      -- A charwise selection: text inserted before it on its first line.
      edit_on_leave = function()
        api.nvim_buf_set_text(b, 1, 0, 1, 0, { '-- ' })
      end
      assert.same(kept('ne\ntw'), select_then('jlvj', '<C-w>l'))
      assert.same({ line = 1, character = 4 }, sel.current().start)
      -- A line inserted inside it, or a change to its text, drops it, even after a line inserted above.
      edit_on_leave = function()
        api.nvim_buf_set_lines(b, 2, 2, false, { 'new' })
      end
      assert.same(dropped, select_then('jVj', '<C-w>l'))
      edit_on_leave = function()
        api.nvim_buf_set_lines(b, 0, 0, false, { '-- header' })
        api.nvim_buf_set_lines(b, 3, 4, false, { 'TWO' })
      end
      assert.same(dropped, select_then('jVj', '<C-w>l'))
      -- All the lines set again, unchanged (a plugin rewriting the buffer): read where it was.
      edit_on_leave = function()
        api.nvim_buf_set_lines(b, 0, -1, false, api.nvim_buf_get_lines(b, 0, -1, false))
      end
      assert.same(kept('one\ntwo'), select_then('jVj', '<C-w>l'))
      -- Its line set again, unchanged (a formatter): to the extmarks, a line inserted above it.
      edit_on_leave = function()
        api.nvim_buf_set_lines(b, 1, 2, false, { 'one' })
      end
      assert.same(kept('one'), select_then('jV', '<C-w>l'))
      assert.same(kept('ne'), select_then('jlvl', '<C-w>l'))
      assert.same({ line = 1, character = 1 }, sel.current().start)
    end)

    it('sends a blockwise selection made with $ to the end of every line, as y yanks it', function()
      edit('a.txt', { 'a', 'bbbb', 'cc' })
      api.nvim_win_set_cursor(0, { 1, 0 })
      feed('<C-v>jj$', 'x!')
      local s = sel.current()
      assert.eq('a\nbbbb\ncc', s.text)
      assert.same({ line = 0, character = 0 }, s.start)
      assert.same({ line = 2, character = 2 }, s.finish)
      feed_silent('y')
      assert.eq(vim.fn.getreg('"'), s.text)
      -- From a later column, over lines that end before it, a tab and a wide character.
      local lines = { 'abcdef', 'x', '', '\tx', 'ab日本', 'abcdefghij' }
      api.nvim_buf_set_lines(0, 0, -1, false, lines)
      for _, excl in ipairs({ false, true }) do
        vim.o.selection = excl and 'exclusive' or 'inclusive'
        api.nvim_win_set_cursor(0, { 1, 2 })
        feed('<C-v>5j$', 'x!')
        local text = sel.current().text
        feed_silent('y')
        assert.eq(vim.fn.getreg('"'), text, vim.o.selection)
      end
      vim.o.selection = 'inclusive'
      vim.cmd('silent write')
      -- The same once Visual mode is left for the agent terminal: the text every consumer sees.
      local _, select_then = agent_layout({ 'a', 'bbbb', 'cc', 'dddddd' })
      assert.same(kept('a\nbbbb\ncc'), select_then('<C-v>jj$', '<C-w>l', { seen = true }))
      assert.same(kept('a\nbbbb\ncc'), select_then('<C-v>jj$<C-w>l', ''))
      -- $ typed first also makes a $ block.
      assert.same(kept('a\nbbbb\ncc'), select_then('$<C-v>jj<C-w>l', ''))
      -- $A appends inside the region: dropped, with 'selection' exclusive too.
      for _, excl in ipairs({ false, true }) do
        vim.o.selection = excl and 'exclusive' or 'inclusive'
        assert.same(dropped, select_then('<C-v>j$', 'AX<Esc><C-w>l', { seen = true }), vim.o.selection)
        assert.same(dropped, select_then('<C-v>j', '$AX<Esc><C-w>l', { seen = true }), vim.o.selection)
        assert.same(dropped, select_then('<C-v>j$AX<Esc><C-w>l', ''), vim.o.selection)
      end
      vim.o.selection = 'inclusive'
    end)

    it('drops the held selection when its buffer is wiped or unloaded', function()
      local a = edit('a.txt', { 'one', 'two', 'three' })
      local a_win = api.nvim_get_current_win()
      open_terminal_window()
      vim.cmd('wincmd L')
      local term_win = api.nvim_get_current_win()
      for _, cmd in ipairs({ 'bwipeout!', 'bunload!', 'bdelete!' }) do
        api.nvim_set_current_win(a_win)
        vim.cmd('split')
        local e = edit('e.txt', { 'eone', 'etwo', 'ethree' })
        api.nvim_win_set_cursor(0, { 1, 0 })
        feed('Vj', 'x!')
        sel.current()
        feed_silent('<C-w>l')
        assert.eq(term_win, api.nvim_get_current_win())
        vim.v.errmsg = ''
        vim.cmd(cmd .. ' ' .. e) -- within the grace period
        settle()
        assert.eq('', vim.v.errmsg, cmd)
        assert.same({ event = '', current = '', live = false, active = 'a.txt' }, seen(), cmd)
        assert.eq(a, events[#events].bufnr, cmd .. ': the cursor in the other file window')
      end
      -- No file window left: nothing.
      api.nvim_set_current_win(a_win)
      feed('Vj', 'x!')
      sel.current()
      feed_silent('<C-w>l')
      vim.cmd('bwipeout! ' .. a)
      settle()
      assert.eq('', vim.v.errmsg)
      assert.falsy((sel.current()))
    end)

    it('re-entering Visual mode within the grace period cancels the drop', function()
      sel.DEMOTE_MS = 300
      edit('a.txt', { 'one', 'two', 'three' })
      api.nvim_win_set_cursor(0, { 1, 0 })
      feed('Vj', 'x!')
      wait_for(function()
        return #events > 0 and events[#events].text == 'one\ntwo'
      end, 1000, 'visual selection event')
      local n = #events
      feed('<Esc>', 'x!')
      vim.wait(100) -- the debounce runs, the grace period does not end
      feed('gv', 'x!')
      assert.eq('V', api.nvim_get_mode().mode)
      settle()
      for i = n + 1, #events do
        assert.falsy(events[i].is_empty, 'no cursor-only event in between')
      end
      assert.same({ event = 'one\ntwo', current = 'one\ntwo', live = true, selected_text = 'one\ntwo',
        active = 'a.txt' }, seen())
      -- A new grace period starts when Visual mode is left again.
      feed('<Esc>', 'x!')
      settle()
      assert.same({ event = '', current = '', live = true, active = 'a.txt' }, seen())
    end)
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
    assert.eq(2, s.start_line)
    assert.eq(3, s.end_line)
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
