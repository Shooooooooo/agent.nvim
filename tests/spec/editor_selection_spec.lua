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

---The agent's terminal (a terminal buffer without a job, marked with b:agent_nvim_agent as
---agent.terminal does), shown in a new window: focusing it keeps the previous context.
local function open_agent_terminal()
  vim.cmd('vsplit')
  local b = api.nvim_create_buf(true, false)
  vim.b[b].agent_nvim_agent = 'claude'
  api.nvim_win_set_buf(0, b)
  api.nvim_open_term(b, {})
  return b
end

---A shell terminal that prints `lines`, then waits, in a new window (focused). Returns its buffer
---once the output is there.
local function open_shell(lines)
  vim.cmd('vnew')
  local script = {}
  for _, l in ipairs(lines) do
    script[#script + 1] = 'echo ' .. vim.fn.shellescape(l)
  end
  script[#script + 1] = 'exec sleep 60'
  local job = vim.fn.jobstart({ '/bin/sh', '-c', table.concat(script, '; ') }, { term = true })
  assert.truthy(job > 0, 'jobstart')
  local b = api.nvim_get_current_buf()
  wait_for(function()
    return api.nvim_buf_get_lines(b, #lines - 1, #lines, false)[1] == lines[#lines]
  end, 3000, 'terminal output')
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
      open_agent_terminal()
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
      local term = open_agent_terminal()
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
      local term = open_agent_terminal()
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
      open_agent_terminal()
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
      open_agent_terminal()
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
      open_agent_terminal()
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
    local term = open_agent_terminal()
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

  it('ignores the agent terminal, agent-diff buffers, b:agent_ignore and floating windows', function()
    local b = edit('a.txt', { 'one', 'two' })
    api.nvim_win_set_cursor(0, { 2, 1 })
    sel.current()
    local term = open_agent_terminal()
    assert.eq(nil, sel.kind(term))
    local s, live = sel.current()
    assert.falsy(live)
    assert.eq(b, s.bufnr)
    -- agent.terminal's buffer, marked or not
    package.loaded['agent.terminal'] = { bufnr = function()
      return term
    end }
    vim.b[term].agent_nvim_agent = nil
    local ok, kind = pcall(sel.kind, term)
    package.loaded['agent.terminal'] = nil
    assert.truthy(ok, kind)
    assert.eq(nil, kind)
    assert.eq('buffer', sel.kind(term), 'any other terminal')
    vim.b[term].agent_nvim_agent = 'claude'

    local acw = api.nvim_create_buf(false, true)
    vim.bo[acw].buftype = 'acwrite'
    api.nvim_buf_set_name(acw, 'agent-diff://x')
    assert.eq(nil, sel.kind(acw))
    local orig = api.nvim_create_buf(false, true) -- a diff's scratch original
    vim.b[orig].agent_diff_id = 'x'
    assert.eq(nil, sel.kind(orig))
    local ignored = api.nvim_create_buf(true, true)
    vim.b[ignored].agent_ignore = true
    assert.eq(nil, sel.kind(ignored))
    api.nvim_win_set_buf(0, acw)
    feed('ggVG', 'x!')
    s, live = sel.current()
    assert.falsy(live)
    assert.eq(b, s.bufnr)
    feed('<Esc>')
    assert.truthy(sel.is_trackable(b))

    -- A floating window (a picker, a popup) with a scratch buffer, a terminal or a quickfix list.
    for _, make in ipairs({
      function()
        return api.nvim_create_buf(false, true)
      end,
      function()
        local t = api.nvim_create_buf(false, true)
        api.nvim_open_term(t, {})
        return t
      end,
    }) do
      local fb = make()
      local float = api.nvim_open_win(fb, true, { relative = 'editor', row = 1, col = 1, width = 20, height = 3 })
      assert.eq(nil, sel.kind(fb, float))
      assert.eq('buffer', sel.kind(fb), 'the same buffer in a normal window is reported')
      s, live = sel.current()
      assert.falsy(live)
      assert.eq(b, s.bufnr)
      api.nvim_win_close(float, true)
    end
  end)

  it('reports a terminal, a scratch buffer and other non-file buffers as nvim://buffer/<n>/<label>', function()
    local a, pa = edit('a.txt', { 'one', 'two' })
    local events = {}
    sel.subscribe(function(s)
      events[#events + 1] = s
    end)
    local term = open_shell({ 'hello', 'error: boom' })
    local id = ('nvim://buffer/%d/sh'):format(term)
    assert.eq('buffer', sel.kind(term))
    assert.falsy(sel.is_trackable(term))
    local s, live = sel.current()
    assert.truthy(live)
    assert.eq(id, s.path)
    assert.eq(term, s.bufnr)
    assert.eq('', s.text)
    assert.eq(id, sel.path_of(term))
    wait_for(function()
      return #events > 0 and events[#events].path == id
    end, 1000, 'selection event for the terminal')
    -- Never a recent file; with `buffers`, the active entry, newest, ahead of the files.
    assert.same({ pa }, vim.tbl_map(function(f)
      return f.path
    end, sel.recent_files()))
    local files = sel.recent_files({ buffers = true })
    assert.same({ id, pa }, vim.tbl_map(function(f)
      return f.path
    end, files))
    assert.truthy(files[1].is_active)
    assert.eq(nil, files[2].is_active)
    assert.truthy(files[1].timestamp > files[2].timestamp)
    -- Its cursor is always line 0, column 0 (1-based here).
    assert.same({ line = 1, character = 1 }, files[1].cursor)
    assert.same({ line = 0, character = 0 }, s.start)
    assert.eq(term, sel.active_buf())
    assert.eq(a, sel.last_focused_buf())
    -- While the agent terminal has focus, the shell stays the context.
    open_agent_terminal()
    s, live = sel.current()
    assert.falsy(live)
    assert.eq(id, s.path)
    assert.eq(id, sel.recent_files({ buffers = true })[1].path)
    assert.eq(term, sel.active_buf())
    -- Back in the file: the file is the context again, and the shell is gone from the list.
    api.nvim_set_current_win(vim.fn.bufwinid(a))
    assert.eq(pa, sel.current().path)
    assert.same({ pa }, vim.tbl_map(function(f)
      return f.path
    end, sel.recent_files({ buffers = true })))
    assert.eq(a, sel.active_buf())
    assert.eq(sel.get(id), sel.get(term), 'get() takes the nvim://buffer/ id')
    assert.eq(id, sel.get(id).path)

    -- Labels: the filetype, else the buffer name's basename, else "scratch".
    local scratch = api.nvim_create_buf(true, true)
    api.nvim_win_set_buf(0, scratch)
    assert.eq(('nvim://buffer/%d/scratch'):format(scratch), sel.current().path)
    vim.cmd('enew')
    assert.eq(('nvim://buffer/%d/scratch'):format(api.nvim_get_current_buf()), sel.current().path, ':enew')
    vim.bo.filetype = 'NvimTree'
    assert.eq(('nvim://buffer/%d/NvimTree'):format(api.nvim_get_current_buf()), sel.current().path)
    local named = api.nvim_create_buf(true, true)
    api.nvim_buf_set_name(named, 'oil:///tmp/some dir/')
    api.nvim_win_set_buf(0, named)
    assert.eq(('nvim://buffer/%d/some dir'):format(named), sel.current().path)
    vim.bo[named].filetype = 'oil'
    assert.eq(('nvim://buffer/%d/oil'):format(named), sel.current().path)
    vim.cmd('copen')
    assert.eq(('nvim://buffer/%d/qf'):format(api.nvim_get_current_buf()), sel.current().path)
    vim.cmd('cclose')
  end)

  it('reports a :help buffer by the real path of its file', function()
    edit('a.txt', { 'one' })
    vim.cmd('help help')
    local h = api.nvim_get_current_buf()
    assert.eq('help', vim.bo[h].buftype)
    local path = api.nvim_buf_get_name(h)
    assert.truthy(vim.uv.fs_stat(path), path)
    assert.eq('file', sel.kind(h))
    assert.truthy(sel.is_trackable(h))
    local s, live = sel.current()
    assert.truthy(live)
    assert.eq(path, s.path)
    assert.eq(path, sel.recent_files({ buffers = true })[1].path)
  end)

  it('reports a Visual selection in a terminal as a selection, and the rules for leaving it', function()
    local events = {}
    sel.subscribe(function(s)
      events[#events + 1] = s
    end)
    local a = edit('a.txt', { 'one', 'two', 'three' })
    local file_win = api.nvim_get_current_win()
    local term = open_shell({ 'line one', 'error: boom' })
    local term_win = api.nvim_get_current_win()
    local id = ('nvim://buffer/%d/sh'):format(term)
    local agent = open_agent_terminal()
    local agent_win = api.nvim_get_current_win()
    api.nvim_set_current_win(term_win)
    -- Normal mode in the terminal: Vj selects its lines.
    api.nvim_win_set_cursor(0, { 1, 0 })
    feed('Vj', 'x!')
    local s, live = sel.current()
    assert.truthy(live)
    assert.eq(id, s.path)
    assert.eq('line one\nerror: boom', s.text)
    assert.eq('V', s.mode)
    assert.same({ line = 0, character = 0 }, s.start)
    assert.same({ line = 1, character = 11 }, s.finish)
    assert.eq('line one\nerror: boom', sel.recent_files({ buffers = true })[1].selected_text)
    wait_for(function()
      return #events > 0 and events[#events].text == 'line one\nerror: boom'
    end, 1000, 'the terminal selection event')
    -- Straight from Visual mode to the agent terminal: kept.
    api.nvim_set_current_win(agent_win)
    assert.eq(agent, api.nvim_get_current_buf())
    vim.wait(sel.DEMOTE_MS + 150)
    s, live = sel.current()
    assert.falsy(live)
    assert.eq(id, s.path)
    assert.eq('line one\nerror: boom', s.text)
    assert.eq('line one\nerror: boom', events[#events].text)
    -- <Esc> in the terminal: the cursor only.
    api.nvim_set_current_win(term_win)
    api.nvim_win_set_cursor(0, { 1, 0 })
    feed('Vj', 'x!')
    feed('<Esc>', 'x!')
    vim.wait(sel.DEMOTE_MS + 150)
    s = sel.current()
    assert.eq(id, s.path)
    assert.eq('', s.text)
    -- Straight from Visual mode in the file to the terminal: the terminal is the context.
    api.nvim_set_current_win(file_win)
    api.nvim_win_set_cursor(0, { 1, 0 })
    feed('Vj', 'x!')
    assert.eq('one\ntwo', sel.current().text)
    wait_for(function()
      return events[#events].text == 'one\ntwo'
    end, 1000, 'the file selection event')
    api.nvim_set_current_win(term_win)
    vim.wait(sel.DEMOTE_MS + 150)
    s, live = sel.current()
    assert.truthy(live)
    assert.eq(id, s.path)
    assert.eq('', s.text)
    wait_for(function()
      return events[#events].path == id and events[#events].text == ''
    end, 1000, 'the terminal cursor event')
    assert.eq(a, sel.last_focused_buf())
  end)

  it('drops a terminal selection when the user edits the finished terminal made modifiable', function()
    reset_ui()
    vim.cmd('terminal printf "aaa\\nbbb\\n"')
    local term = api.nvim_get_current_buf()
    wait_for(function()
      return vim.fn.jobwait({ vim.bo[term].channel }, 0)[1] ~= -1
    end, 3000, 'the job exits')
    vim.bo[term].modifiable = true
    feed('ggVj', 'x!')
    assert.eq('aaa\nbbb', sel.current().text)
    -- An edit through the selection, then straight to the agent's split.
    feed(':s/a/X/g\r', 'x!')
    assert.eq('XXX', api.nvim_buf_get_lines(term, 0, 1, false)[1])
    vim.cmd('botright vsplit')
    local agent = api.nvim_create_buf(true, false)
    vim.b[agent].agent_nvim_agent = 'claude'
    api.nvim_win_set_buf(0, agent)
    vim.wait(sel.DEMOTE_MS + 150)
    assert.eq('', sel.current().text, 'the edited selection is not sent')
  end)

  it('keeps a Visual selection in a terminal when the agent split opening resizes the terminal', function()
    -- The terminal fills the screen; the agent's split then makes it narrower (its long first line
    -- reflows) or lower (the blank rows below its output go). Its text changes, but not by an
    -- edit: the selection is kept as it was captured.
    local events = {}
    sel.subscribe(function(s)
      events[#events + 1] = s
    end)
    local long = string.rep('0', 60)
    for _, case in ipairs({
      { split = 'botright vsplit', keys = 'ggVj', text = long .. '\nerror: boom' },
      { split = 'botright split', keys = 'ggVG' }, -- down to the last (blank) row of the screen
    }) do
      reset_ui()
      local job = vim.fn.jobstart({ '/bin/sh', '-c', 'echo ' .. long .. '; echo "error: boom"; exec sleep 60' },
        { term = true })
      local term = api.nvim_get_current_buf()
      local id = ('nvim://buffer/%d/sh'):format(term)
      wait_for(function()
        return api.nvim_buf_get_lines(term, 1, 2, false)[1] == 'error: boom'
      end, 3000, 'terminal output')
      local before = api.nvim_buf_get_lines(term, 0, -1, false)
      feed(case.keys, 'x!')
      local text = sel.current().text
      if case.text then
        assert.eq(case.text, text)
      else
        assert.eq(table.concat(before, '\n'), text, case.split)
        assert.truthy(before[#before] == '', 'blank rows selected')
      end
      -- Straight from Visual mode to the agent's new split.
      vim.cmd(case.split)
      local agent = api.nvim_create_buf(true, false)
      vim.b[agent].agent_nvim_agent = 'claude'
      api.nvim_win_set_buf(0, agent)
      api.nvim_open_term(agent, {})
      wait_for(function()
        return not vim.deep_equal(api.nvim_buf_get_lines(term, 0, -1, false), before)
      end, 3000, 'the terminal text changes with its size: ' .. case.split)
      vim.wait(sel.DEMOTE_MS + 150)
      local s, live = sel.current()
      assert.falsy(live)
      assert.eq(id, s.path)
      assert.eq(text, s.text, case.split)
      assert.eq('V', s.mode)
      assert.eq(text, events[#events].text, case.split)
      assert.eq(text, sel.recent_files({ buffers = true })[1].selected_text, case.split)
      -- Once the terminal has focus again, the selection is dropped as usual.
      api.nvim_set_current_win(vim.fn.bufwinid(term))
      vim.wait(sel.DEMOTE_MS + 150)
      assert.eq('', sel.current().text)
      vim.fn.jobstop(job)
    end
  end)

  it('sends a buffer that is not a file at line 0, column 0 until a selection is made in it', function()
    -- A terminal streaming output in Normal mode, its cursor following the output: one event, not
    -- one per debounce (the cursor of such a buffer means nothing to the agents).
    local events = {}
    sel.subscribe(function(s)
      events[#events + 1] = s
    end)
    edit('a.txt', { 'one', 'two' })
    vim.cmd('vnew')
    local job = vim.fn.jobstart({ '/bin/sh', '-c', 'i=0; while :; do i=$((i+1)); echo "tick $i"; sleep 0.02; done' },
      { term = true })
    local term = api.nvim_get_current_buf()
    local id = ('nvim://buffer/%d/sh'):format(term)
    local ok, err = pcall(function()
      wait_for(function()
        return api.nvim_buf_line_count(term) > api.nvim_win_get_height(0) + 5
      end, 5000, 'the output scrolls')
      move('G') -- on the last line: the cursor follows the output
      local zero = { line = 0, character = 0 }
      local function check(s)
        assert.eq(id, s.path)
        assert.eq('', s.text)
        assert.truthy(s.is_empty)
        assert.same(zero, s.start)
        assert.same(zero, s.finish)
        assert.same(zero, s.cursor)
      end
      check(sel.current())
      sel.flush()
      check(events[#events])
      local n, cursors = #events, {}
      for _ = 1, 8 do
        vim.wait(60)
        cursors[api.nvim_win_get_cursor(0)[1]] = true
        -- The main loop fires CursorMoved as the cursor follows the output (`nvim -l` does not).
        api.nvim_exec_autocmds('CursorMoved', {})
        vim.wait(40)
      end
      assert.truthy(vim.tbl_count(cursors) > 1, 'the cursor followed the output')
      assert.eq(n, #events, 'no event while only the cursor moves')
      assert.same({ line = 1, character = 1 }, sel.recent_files({ buffers = true })[1].cursor)
      -- A Visual selection in it is sent with its range; the cursor after it is line 0 again.
      local row = api.nvim_win_get_cursor(0)[1] - 2
      api.nvim_win_set_cursor(0, { row, 0 })
      feed('vl', 'x!')
      local s = sel.current()
      assert.eq(id, s.path)
      assert.same({ line = row - 1, character = 0 }, s.start)
      assert.same({ line = row - 1, character = 2 }, s.finish)
      feed('<Esc>', 'x!')
      vim.wait(sel.DEMOTE_MS + 150)
      check(sel.current())
      check(sel.get(id))
    end)
    vim.fn.jobstop(job)
    assert.truthy(ok, err)
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
    open_agent_terminal()
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

  describe('capture and entry_of (:AgentSend)', function()
    local context = require('agent.editor.context')
    local got, showmode, virtualedit, cmdline, visual

    before_each(function()
      showmode = vim.o.showmode
      virtualedit = vim.o.virtualedit
      vim.o.showmode = false -- no '-- VISUAL --' on stderr
      got, cmdline, visual = nil, nil, nil
      -- The ':' command line being run, typed or from a ':' mapping, as init.lua records it.
      api.nvim_create_autocmd('CmdlineLeave', {
        group = api.nvim_create_augroup('ProbeCmdline', { clear = true }),
        pattern = ':',
        callback = function()
          if not vim.v.event.abort then
            cmdline = vim.fn.getcmdline()
          end
        end,
      })
      -- :Probe stands for :AgentSend: what it would capture with its range, the Visual area when
      -- that command line is a :'<,'> one (as :AgentSend tells it).
      api.nvim_create_user_command('Probe', function(o)
        visual = (cmdline or ''):match("^[%s:]*'<%s*,%s*'>") ~= nil
        cmdline = nil
        got = sel.capture(o.range > 0 and { line1 = o.line1, line2 = o.line2, visual = visual } or nil)
      end, { range = true })
    end)

    after_each(function()
      vim.o.showmode = showmode
      pcall(api.nvim_del_augroup_by_name, 'ProbeCmdline')
      pcall(api.nvim_del_user_command, 'Probe')
      pcall(vim.keymap.del, 'x', '<F2>')
      pcall(vim.keymap.del, 'x', '<F3>')
      vim.o.virtualedit = virtualedit
    end)

    ---Type keys as the user would, without the command-line echo on stderr.
    local function type_keys(keys)
      vim.cmd(('silent call feedkeys(%s, "tx")'):format(
        vim.fn.string(api.nvim_replace_termcodes(keys, true, false, true))))
    end

    it('captures the cursor as an empty selection (at 0:0 in a buffer that is not a file)', function()
      sel.stop() -- read now: tracking need not run
      local b, path = edit('a.txt', { 'hello', 'world' })
      api.nvim_win_set_cursor(0, { 2, 3 })
      assert.same({
        path = path, bufnr = b, text = '', is_empty = true, mode = 'n', linewise = false,
        start = { line = 1, character = 3 }, finish = { line = 1, character = 3 }, cursor = { line = 1, character = 3 },
        start_line = 2, end_line = 2,
      }, sel.capture())
      vim.cmd('enew')
      local scratch = api.nvim_get_current_buf()
      api.nvim_buf_set_lines(scratch, 0, -1, false, { 'x', 'y', 'z' })
      api.nvim_win_set_cursor(0, { 3, 0 })
      local s = sel.capture()
      assert.eq(context.buffer_uri(scratch), s.path)
      assert.eq(('nvim://buffer/%d/scratch'):format(scratch), s.path)
      assert.eq('', s.text)
      assert.eq('n', s.mode)
      assert.same({ line = 0, character = 0 }, s.start)
      assert.same({ line = 0, character = 0 }, s.cursor)
      assert.eq(1, s.start_line)
    end)

    it('captures nothing from an ignored window: the agent terminal, b:agent_ignore, a floating scratch buffer', function()
      edit('a.txt', { 'one' })
      vim.b.agent_ignore = true
      assert.eq(nil, sel.capture())
      assert.eq(nil, sel.capture({ line1 = 1 }))
      vim.b.agent_ignore = nil
      open_agent_terminal()
      assert.eq(nil, sel.capture())
      local float = api.nvim_open_win(api.nvim_create_buf(false, true), true,
        { relative = 'editor', row = 1, col = 1, width = 20, height = 3 })
      assert.eq(nil, sel.capture())
      api.nvim_win_close(float, true)
    end)

    it('captures the lines of a range linewise, the cursor on the last one (reversed, clamped to the buffer)', function()
      local b, path = edit('a.txt', { 'one', 'two', 'three', 'four' })
      api.nvim_win_set_cursor(0, { 4, 1 })
      local s = sel.capture({ line1 = 2, line2 = 3 })
      -- As a V selection made downwards has it, not the window's cursor.
      assert.same({
        path = path, bufnr = b, text = 'two\nthree', is_empty = false, mode = 'V', linewise = true,
        start = { line = 1, character = 0 }, finish = { line = 2, character = 5 }, cursor = { line = 2, character = 0 },
        start_line = 2, end_line = 3,
      }, s)
      assert.same(s, sel.capture({ line1 = 3, line2 = 2 }), 'reversed')
      s = sel.capture({ line1 = 3, line2 = 99 })
      assert.eq('three\nfour', s.text)
      assert.eq(3, s.start_line)
      assert.eq(4, s.end_line)
      assert.same({ line = 3, character = 0 }, s.cursor)
      s = sel.capture({ line1 = 0 })
      assert.eq('one', s.text)
      assert.eq('V', s.mode)
      assert.same({ line = 0, character = 0 }, s.cursor)
      s = sel.capture({ line1 = 2 })
      assert.eq('two', s.text)
      assert.eq(2, s.start_line)
      assert.eq(2, s.end_line)
      assert.same({ line = 1, character = 0 }, s.cursor)
      assert.same({ 4, 1 }, api.nvim_win_get_cursor(0), 'the cursor does not move')
    end)

    it('captures an empty line as an empty selection at that line, not at the cursor (a buffer: at 0:0)', function()
      local b, path = edit('a.txt', { 'one', '', 'three' })
      api.nvim_win_set_cursor(0, { 3, 2 })
      assert.same({
        path = path, bufnr = b, text = '', is_empty = true, mode = 'n', linewise = false,
        start = { line = 1, character = 0 }, finish = { line = 1, character = 0 }, cursor = { line = 1, character = 0 },
        start_line = 2, end_line = 2,
      }, sel.capture({ line1 = 2 }))
      assert.same({ 3, 2 }, api.nvim_win_get_cursor(0))
      -- A buffer that is not a file: its cursor is always reported at 0:0.
      vim.cmd('enew')
      api.nvim_buf_set_lines(0, 0, -1, false, { 'x', '', 'z' })
      api.nvim_win_set_cursor(0, { 3, 0 })
      local s = sel.capture({ line1 = 2 })
      assert.eq(('nvim://buffer/%d/scratch'):format(api.nvim_get_current_buf()), s.path)
      assert.truthy(s.is_empty)
      assert.same({ line = 0, character = 0 }, s.start)
      assert.eq(1, s.start_line)
    end)

    it('captures the live Visual selection exactly (charwise, linewise, blockwise), whatever the range', function()
      edit('a.txt', { 'héllo world', 'second' })
      api.nvim_win_set_cursor(0, { 1, 0 })
      feed('vl', 'x!')
      local s = sel.capture({ line1 = 2, line2 = 2 })
      assert.eq('v', api.nvim_get_mode().mode, 'Visual mode is not left')
      assert.eq('hé', s.text)
      assert.eq('v', s.mode)
      assert.same({ line = 0, character = 0 }, s.start)
      assert.same({ line = 0, character = 3 }, s.finish)
      assert.same(s, sel.capture())
      feed('<Esc>')
      feed('Vj', 'x!')
      s = sel.capture()
      assert.eq('V', s.mode)
      assert.eq('héllo world\nsecond', s.text)
      feed('<Esc>')
      api.nvim_win_set_cursor(0, { 1, 0 })
      feed('<C-v>jl', 'x!')
      s = sel.capture()
      assert.eq('\22', s.mode)
      assert.eq('hé\nse', s.text)
      feed('<Esc>')
    end)

    it(":'<,'> typed from Visual mode captures the selection as made (charwise, blockwise), tracking or not", function()
      sel.stop() -- the '< and '> marks only
      local b = edit('a.txt', { 'abcdef', 'ghijkl', 'mnopqr' })
      api.nvim_win_set_cursor(0, { 1, 2 })
      type_keys('vjl:Probe<CR>') -- ':' in Visual mode inserts '<,'>
      assert.truthy(visual)
      assert.eq('n', api.nvim_get_mode().mode)
      assert.eq('v', got.mode)
      assert.eq('cdef\nghij', got.text)
      assert.same({ line = 0, character = 2 }, got.start)
      assert.same({ line = 1, character = 4 }, got.finish)
      assert.eq(b, got.bufnr)
      -- Blockwise.
      api.nvim_win_set_cursor(0, { 2, 1 })
      type_keys('<C-v>jl:Probe<CR>')
      assert.eq('\22', got.mode)
      assert.eq('hi\nno', got.text)
      assert.same({ line = 1, character = 1 }, got.start)
      assert.same({ line = 2, character = 3 }, got.finish)
      -- Linewise: the same lines either way.
      api.nvim_win_set_cursor(0, { 1, 3 })
      type_keys('Vj:Probe<CR>')
      assert.eq('V', got.mode)
      assert.eq('abcdef\nghijkl', got.text)
      -- Typed with other lines than those of the marks: linewise.
      api.nvim_win_set_cursor(0, { 1, 2 })
      type_keys('vjl<Esc>')
      type_keys(':2,3Probe<CR>')
      assert.eq('V', got.mode)
      assert.eq('ghijkl\nmnopqr', got.text)
      -- With tracking running: the same.
      sel.start()
      api.nvim_win_set_cursor(0, { 1, 2 })
      type_keys('vjl:Probe<CR>')
      assert.eq('v', got.mode)
      assert.eq('cdef\nghij', got.text)
    end)

    it(":'<,'> typed after a $ block extends it to the end of every line; a plain block followed by $ is not", function()
      sel.stop()
      edit('a.txt', { 'abcdef', 'gh', 'mnopqr' })
      -- $ on the shorter line: its corner is past the end of that line.
      api.nvim_win_set_cursor(0, { 1, 1 })
      type_keys('<C-v>j$:Probe<CR>')
      assert.eq('\22', got.mode)
      assert.eq('bcdef\nh', got.text, 'as y yanks it')
      -- Made upwards: the corner on the first line.
      api.nvim_win_set_cursor(0, { 2, 0 })
      type_keys('<C-v>k$:Probe<CR>')
      assert.eq('abcdef\ngh', got.text)
      -- A plain block, then $ in Normal mode (the cursor wants the end of the line, not the block),
      -- then :'<,'> typed in full.
      api.nvim_win_set_cursor(0, { 1, 1 })
      type_keys('<C-v>j<Esc>$')
      assert.eq(vim.v.maxcol, vim.fn.getcurpos()[5])
      type_keys(":'<,'>Probe<CR>")
      assert.eq('\22', got.mode)
      assert.eq('b\nh', got.text)
      -- A $ block over three lines, typed in full after <Esc>.
      api.nvim_win_set_cursor(0, { 1, 1 })
      type_keys('<C-v>jj$<Esc>')
      type_keys(":'<,'>Probe<CR>")
      assert.eq('bcdef\nh\nnopqr', got.text)
    end)

    it("a ':' mapping in Visual mode runs :'<,'>: the selection as made, held by tracking or from the marks", function()
      edit('a.txt', { 'abcdef', 'ghijkl', 'mnopqr' })
      vim.keymap.set('x', '<F2>', ':Probe<CR>')
      -- Tracking runs (as it does while a provider runs): the selection just left, held.
      api.nvim_win_set_cursor(0, { 1, 2 })
      type_keys('vjl<F2>')
      assert.truthy(visual, "the mapping's command line is :'<,'>Probe")
      assert.eq('v', got.mode)
      assert.eq('cdef\nghij', got.text)
      api.nvim_win_set_cursor(0, { 2, 1 })
      type_keys('<C-v>jl<F2>')
      assert.eq('\22', got.mode)
      assert.eq('hi\nno', got.text)
      vim.wait(sel.DEMOTE_MS + 150) -- the grace period ends: nothing is held
      -- Without tracking: the marks.
      sel.stop()
      api.nvim_win_set_cursor(0, { 1, 2 })
      type_keys('vjl<F2>')
      assert.truthy(visual)
      assert.eq('v', got.mode)
      assert.eq('cdef\nghij', got.text)
      api.nvim_win_set_cursor(0, { 2, 1 })
      type_keys('<C-v>jl<F2>')
      assert.eq('\22', got.mode)
      assert.eq('hi\nno', got.text)
    end)

    it("range.visual: the marks, and gv tells a $ block from a plain one that ends past a short line", function()
      edit('a.txt', { 'abcdef', 'gh', 'mnopqr' })
      -- (With 'virtualedit' all, getregion() pads the short lines of a block with spaces.)
      local function trim(t)
        return (t:gsub(' +\n', '\n'):gsub(' +$', ''))
      end
      for _, ve in ipairs({ '', 'block', 'all', 'onemore' }) do
        vim.o.virtualedit = ve
        -- A $ block, typed as one run of keys (no CursorMoved after the $).
        api.nvim_win_set_cursor(0, { 1, 1 })
        type_keys('<C-v>j$:Probe<CR>')
        assert.truthy(visual)
        assert.eq('\22', got.mode, ve)
        assert.eq('bcdef\nh', trim(got.text), ve .. ': to the end of every line')
        vim.wait(sel.DEMOTE_MS + 150) -- the grace period ends: nothing is held
        type_keys(":'<,'>Probe<CR>")
        assert.eq('bcdef\nh', trim(got.text), ve .. ': later, from the marks')
        -- A plain block whose corner is past the end of 'gh', as a $ block's is.
        api.nvim_win_set_cursor(0, { 1, 1 })
        type_keys('<C-v>jl<Esc>')
        type_keys(":'<,'>Probe<CR>")
        assert.eq('\22', got.mode, ve)
        assert.eq('bc', vim.split(got.text, '\n')[1], ve .. ': not to the end of the line')
      end
      -- gv leaves the window as it was.
      vim.o.virtualedit = ''
      api.nvim_win_set_cursor(0, { 3, 4 })
      local view = vim.fn.winsaveview()
      type_keys(":'<,'>Probe<CR>")
      assert.same(view, vim.fn.winsaveview())
      assert.eq('n', api.nvim_get_mode().mode)
      -- Neither the marks nor the held selection have the lines of the range: linewise.
      api.nvim_win_set_cursor(0, { 1, 2 })
      type_keys('vl<Esc>') -- on line 1
      local s = sel.capture({ line1 = 2, line2 = 3, visual = true })
      assert.eq('V', s.mode)
      assert.eq('gh\nmnopqr', s.text)
      assert.same({ line = 2, character = 0 }, s.cursor)
      assert.eq('v', sel.capture({ line1 = 1, line2 = 1, visual = true }).mode, 'the marks have line 1')
      assert.eq('cd', sel.capture({ line1 = 1, visual = true }).text)
    end)

    it("range.visual over blank lines: the empty selection at the first one, as for other ranges", function()
      edit('a.txt', { 'x', '', '', 'y' })
      api.nvim_win_set_cursor(0, { 2, 0 })
      type_keys('Vj:Probe<CR>')
      assert.truthy(visual)
      assert.eq('n', got.mode)
      assert.eq('', got.text)
      assert.eq(2, got.start_line)
    end)

    it("a range that is not the Visual area is linewise, even on the lines of the marks and of the held selection", function()
      edit('a.txt', { 'abcdef', 'ghijkl', 'mnopqr' })
      api.nvim_win_set_cursor(0, { 1, 2 })
      type_keys('vjl<Esc>') -- held by tracking, and in the marks
      assert.same({ 1, 2 }, { vim.fn.line("'<"), vim.fn.line("'>") })
      -- Not a command line (vim.cmd(), a <cmd> mapping): not the Visual area, though its range is.
      vim.cmd("'<,'>Probe")
      assert.falsy(visual)
      assert.eq('V', got.mode)
      assert.eq('abcdef\nghijkl', got.text)
      assert.same({ line = 1, character = 0 }, got.cursor)
      -- The lines of the marks, typed as numbers.
      type_keys(':1,2Probe<CR>')
      assert.falsy(visual)
      assert.eq('V', got.mode)
      -- The Lua API without `visual`.
      assert.eq('V', sel.capture({ line1 = 1, line2 = 2 }).mode)
      assert.eq('v', sel.capture({ line1 = 1, line2 = 2, visual = true }).mode)
      -- Without tracking: the marks alone, the same.
      vim.wait(sel.DEMOTE_MS + 150)
      sel.stop()
      vim.cmd("'<,'>Probe")
      assert.eq('V', got.mode)
      assert.eq('abcdef\nghijkl', got.text)
      assert.eq('v', sel.capture({ line1 = 1, line2 = 2, visual = true }).mode)
    end)

    it('a range of blank lines is the empty selection at its first line (the Visual area too, when linewise)', function()
      local b, path = edit('a.txt', { 'one', '', '', 'four' })
      api.nvim_win_set_cursor(0, { 4, 2 })
      local empty = {
        path = path, bufnr = b, text = '', is_empty = true, mode = 'n', linewise = false,
        start = { line = 1, character = 0 }, finish = { line = 1, character = 0 }, cursor = { line = 1, character = 0 },
        start_line = 2, end_line = 2,
      }
      assert.same(empty, sel.capture({ line1 = 2, line2 = 3 }))
      assert.same(empty, sel.capture({ line1 = 3, line2 = 2 }), 'reversed')
      assert.same(empty, sel.capture({ line1 = 2, line2 = 3, visual = true }), 'no Visual area on those lines')
      assert.same({ 4, 2 }, api.nvim_win_get_cursor(0), 'the cursor does not move')
      -- With a line that is not blank: the lines.
      local s = sel.capture({ line1 = 2, line2 = 4 })
      assert.eq('\n\nfour', s.text)
      assert.eq('V', s.mode)
      assert.eq(2, s.start_line)
    end)

    it(':. after viwy (the marks are left on that line) captures the line, tracking or not', function()
      edit('a.txt', { 'one two three', 'four' })
      api.nvim_win_set_cursor(0, { 1, 5 })
      type_keys('viwy')
      assert.eq('two', vim.fn.getreg('"'))
      assert.same({ 1, 1 }, { vim.fn.line("'<"), vim.fn.line("'>") })
      vim.wait(sel.DEMOTE_MS + 150) -- the user takes a while to type the command
      type_keys(':.Probe<CR>')
      assert.eq('V', got.mode)
      assert.eq('one two three', got.text)
      sel.stop()
      type_keys('viwy')
      type_keys(':.Probe<CR>')
      assert.eq('V', got.mode)
      assert.eq('one two three', got.text)
      -- The whole buffer (no range): the cursor.
      type_keys(':Probe<CR>')
      assert.truthy(got.is_empty)
      assert.eq('n', got.mode)
    end)

    it('same: path, text and range; not the mode or the cursor', function()
      local _, path = edit('a.txt', { 'one', 'two' })
      local s = sel.capture({ line1 = 1, line2 = 2 })
      assert.truthy(sel.same(nil, nil))
      assert.truthy(sel.same(s, s))
      assert.falsy(sel.same(s, nil))
      assert.falsy(sel.same(nil, s))
      local other = vim.tbl_extend('force', vim.deepcopy(s), { mode = 'v', cursor = { line = 0, character = 0 } })
      assert.truthy(sel.same(s, other))
      assert.truthy(sel.same(s, sel.capture({ line1 = 2, line2 = 1 })))
      assert.falsy(sel.same(s, vim.tbl_extend('force', vim.deepcopy(s), { path = path .. 'x' })))
      assert.falsy(sel.same(s, vim.tbl_extend('force', vim.deepcopy(s), { text = 'one\ntwo!' })))
      assert.falsy(sel.same(s, vim.tbl_extend('force', vim.deepcopy(s), { start = { line = 0, character = 1 } })))
      assert.falsy(sel.same(s, vim.tbl_extend('force', vim.deepcopy(s), { finish = { line = 1, character = 2 } })))
      assert.falsy(sel.same(s, sel.capture({ line1 = 1 })))
      -- The cursor as an empty selection: its position counts.
      api.nvim_win_set_cursor(0, { 2, 1 })
      local c = sel.capture()
      assert.truthy(sel.same(c, sel.capture()))
      api.nvim_win_set_cursor(0, { 2, 2 })
      assert.falsy(sel.same(c, sel.capture()))
    end)

    it('entry_of: the active recent-files entry, 1-based line and UTF-16 column, text truncated', function()
      local c, pc = edit('c.txt', { 'héllo wörld', 'x' })
      api.nvim_win_set_cursor(0, { 1, 7 }) -- on 'w', after the 2-byte 'é'
      local before = sel.recent_files()[1].timestamp
      local e = sel.entry_of(sel.capture())
      assert.eq(pc, e.path)
      assert.eq(c, e.bufnr)
      assert.eq(true, e.is_active)
      assert.same({ line = 1, character = 7 }, e.cursor)
      assert.eq(nil, e.selected_text, 'no text for the cursor only')
      assert.truthy(e.timestamp > before, 'newer than every recent file')
      local keys = vim.tbl_keys(e)
      table.sort(keys)
      assert.same({ 'bufnr', 'cursor', 'is_active', 'path', 'timestamp' }, keys)
      assert.truthy(sel.entry_of(sel.capture()).timestamp > e.timestamp, 'strictly increasing')

      feed('v4l', 'x!')
      local s = sel.capture()
      feed('<Esc>')
      e = sel.entry_of(s)
      assert.eq('wörld', e.selected_text)
      assert.same({ line = 1, character = 11 }, e.cursor, "on 'd': 10 UTF-16 units before it")
      assert.eq('wö... [TRUNCATED]', sel.entry_of(s, 2).selected_text)
      assert.eq('wörld', sel.entry_of(s, 5).selected_text, 'exactly the limit: kept')
      s = sel.capture({ line1 = 1, line2 = 2 })
      assert.eq('héllo wörld\nx', sel.entry_of(s).selected_text)
      assert.same({ line = 2, character = 1 }, sel.entry_of(s).cursor, 'a range: at the start of its last line')
      assert.eq(string.rep('é', 16384) .. '... [TRUNCATED]',
        sel.entry_of({ path = pc, bufnr = c, text = string.rep('é', 20000), is_empty = false, mode = 'v',
          cursor = { line = 0, character = 0 } }).selected_text, 'default: 16384 UTF-16 units')

      -- A buffer that is not a file: its id, at 1:1.
      vim.cmd('enew')
      api.nvim_buf_set_lines(0, 0, -1, false, { 'a', 'b' })
      api.nvim_win_set_cursor(0, { 2, 1 })
      e = sel.entry_of(sel.capture())
      assert.eq(('nvim://buffer/%d/scratch'):format(api.nvim_get_current_buf()), e.path)
      assert.same({ line = 1, character = 1 }, e.cursor)
      assert.eq(nil, e.selected_text)
    end)
  end)
end)
