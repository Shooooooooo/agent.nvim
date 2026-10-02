-- Neovim config for the README demo (demo/record.sh). It loads agent.nvim from this repository,
-- and nvim-gdb (https://github.com/sakhnik/nvim-gdb) and animate.nvim
-- (https://github.com/Shooooooooo/animate.nvim) from the checkouts that record.sh fetches at
-- pinned commits, and points Claude Code at the local scripted model that record.sh starts.
-- Every DEMO_* variable comes from record.sh, which also isolates HOME, TMPDIR, XDG_* and
-- CLAUDE_CONFIG_DIR.
local repo = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
for _, var in ipairs({
  'DEMO_MODEL_URL', 'DEMO_CLAUDE_CONFIG_DIR', 'DEMO_API_KEY', 'DEMO_NVIMGDB', 'DEMO_ANIMATE',
}) do
  -- Never start Claude against a real account or config: run this only through demo/record.sh.
  assert(vim.env[var], var .. ' is not set: run demo/record.sh')
end
vim.opt.rtp:prepend(vim.env.DEMO_NVIMGDB) -- plugin/nvimgdb.vim defines :GdbStartPDB and :Gdb
vim.opt.rtp:prepend(vim.env.DEMO_ANIMATE) -- set up at the end of this file
vim.opt.rtp:prepend(repo)

-- Looks
vim.o.termguicolors = true
vim.o.background = 'dark'
-- catppuccin ships with Neovim 0.12; fall back to a built-in scheme on older versions.
if not pcall(vim.cmd.colorscheme, 'catppuccin') then
  vim.cmd.colorscheme('habamax')
end
vim.o.number = true
-- A narrow gutter (3 columns for the line numbers, no fold column in the diff windows).
vim.o.numberwidth = 3
vim.opt.diffopt:append('foldcolumn:0')
vim.o.cursorline = true
vim.o.signcolumn = 'no'
vim.o.showmode = false
vim.o.showcmd = false
vim.o.laststatus = 3
vim.o.showtabline = 0
vim.o.fillchars = 'eob: ,vert:│,diff:╱'
vim.o.shortmess = vim.o.shortmess .. 'IF'
vim.o.wrap = false

local c = { blue = '#89b4fa', mauve = '#cba6f7', green = '#a6e3a1', peach = '#fab387', base = '#1e1e2e',
  mantle = '#181825', text = '#cdd6f4', sub = '#a6adc8', surface = '#313244' }
local hl = vim.api.nvim_set_hl
hl(0, 'StatusLine', { fg = c.text, bg = c.mantle })
hl(0, 'WinSeparator', { fg = c.surface })
hl(0, 'WinBar', { fg = c.sub, bg = c.mantle, bold = true })
hl(0, 'WinBarNC', { fg = c.sub, bg = c.mantle })
hl(0, 'NormalFloat', { fg = c.text, bg = c.mantle })
hl(0, 'FloatBorder', { fg = c.blue, bg = c.mantle })
hl(0, 'FloatTitle', { fg = c.base, bg = c.blue, bold = true })

-- Side-by-side diffs read like a code review: the original side in red, the proposal in green,
-- the changed characters darker, and the filler lines hatched.
hl(0, 'DiffOld', { bg = '#45293a' })
hl(0, 'DiffOldText', { bg = '#6b3349' })
hl(0, 'DiffNew', { bg = '#27402f' })
hl(0, 'DiffNewText', { bg = '#39653f' })
hl(0, 'DiffFiller', { fg = '#3b3d52', bg = c.base })
local diff_sides = {
  old = 'DiffAdd:DiffOld,DiffChange:DiffOld,DiffText:DiffOldText,DiffDelete:DiffFiller',
  new = 'DiffAdd:DiffNew,DiffChange:DiffNew,DiffText:DiffNewText,DiffDelete:DiffFiller',
}
vim.api.nvim_create_autocmd({ 'WinEnter', 'BufWinEnter' }, {
  callback = vim.schedule_wrap(function()
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if vim.wo[win].diff then
        -- agent.nvim's proposal is the only acwrite buffer (agent-diff://<id>) in its diff.
        local proposal = vim.bo[vim.api.nvim_win_get_buf(win)].buftype == 'acwrite'
        vim.wo[win].winhighlight = proposal and diff_sides.new or diff_sides.old
        vim.wo[win].number = true
      end
    end
  end),
})

-- Statusline: mode, then the file (or the agent), then the position.
local modes = { n = 'NORMAL', i = 'INSERT', v = 'VISUAL', V = 'V-LINE', ['\22'] = 'V-BLOCK', c = 'COMMAND',
  t = 'TERMINAL', R = 'REPLACE' }
local mode_colors = { NORMAL = c.blue, INSERT = c.green, VISUAL = c.mauve, ['V-LINE'] = c.mauve,
  ['V-BLOCK'] = c.mauve, COMMAND = c.peach, TERMINAL = c.green, REPLACE = c.peach }
for mode, color in pairs(mode_colors) do
  hl(0, 'StatusMode' .. mode:gsub('%-', ''), { fg = c.base, bg = color, bold = true })
end
function _G.demo_statusline()
  local mode = modes[vim.api.nvim_get_mode().mode:sub(1, 1)] or 'NORMAL'
  local agent = vim.b.agent_nvim_agent
  local name = agent and (agent .. ' (agent.nvim)') or vim.fn.expand('%:~:.')
  if vim.b.agent_diff_id and vim.bo.buftype == 'acwrite' then
    -- agent.nvim's proposal buffer: name it after the file it proposes to change.
    name = 'proposed change'
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      local buf = vim.api.nvim_win_get_buf(win)
      if vim.wo[win].diff and buf ~= vim.api.nvim_get_current_buf() then
        name = 'proposed: ' .. vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ':~:.')
      end
    end
  elseif name == '' then
    name = '[No Name]'
  end
  local right = agent and '' or '%y  %l:%c '
  return '%#StatusMode' .. mode:gsub('%-', '') .. '# ' .. mode .. ' %#StatusLine#  ' .. name
    .. (agent and '' or ' %m') .. '%=' .. right
end
vim.o.statusline = '%{%v:lua.demo_statusline()%}'

-- Notifications as a small popup in the bottom right corner of the script's window (the top left
-- one, whose right half is empty; pdb's pane takes the editor's top right corner), so that
-- messages the agent sends through the $NVIM controller's notify tool stand out (the tool passes
-- the agent's name as the title). A popup belongs to the view it was shown in: it closes when
-- another tab page (a diff) opens, where it would cover the proposed code.
local titles = { [vim.log.levels.WARN] = 'Warning', [vim.log.levels.ERROR] = 'Error' }
vim.notify = function(msg, level, opts)
  local function show()
    local lines = vim.split(tostring(msg), '\n')
    local width = 0
    for i, l in ipairs(lines) do
      lines[i] = ' ' .. l .. ' '
      width = math.max(width, vim.fn.strdisplaywidth(lines[i]))
    end
    local title = (opts and opts.title) or titles[level] or 'Notification'
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    local script = vim.fn.win_getid(1)
    local win = vim.api.nvim_open_win(buf, false, {
      relative = 'win', win = script, anchor = 'SE',
      row = vim.api.nvim_win_get_height(script) - 1, col = vim.api.nvim_win_get_width(script) - 2,
      width = math.min(width, vim.o.columns - 8), height = #lines,
      style = 'minimal', border = 'rounded', focusable = false, zindex = 200,
      title = ' ' .. title .. ' ', title_pos = 'left',
    })
    vim.wo[win].wrap = true
    local function close()
      pcall(vim.api.nvim_win_close, win, true)
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
    vim.api.nvim_create_autocmd('TabEnter', { once = true, callback = close })
    vim.defer_fn(close, 4500)
  end
  if vim.in_fast_event() then
    vim.schedule(show)
  else
    show()
  end
end

-- Entering the agent's terminal clears the command line, so an Ex command that already ran
-- does not linger under the agent's turn.
vim.api.nvim_create_autocmd('TermEnter', {
  callback = function()
    vim.cmd.echo('""')
  end,
})

-- A terminal window (pdb's) shows no cursor line (nvim-gdb opens it with :vnew, which copies
-- 'cursorline' from the script's window), and its cursor starts on the terminal's last line:
-- Neovim scrolls a terminal window that is not in Terminal mode only when its cursor is at the
-- end, so the pdb pane then follows pdb's output once it no longer fits.
vim.api.nvim_create_autocmd('TermOpen', {
  callback = function(ev)
    for _, win in ipairs(vim.fn.win_findbuf(ev.buf)) do
      vim.wo[win].cursorline = false
      vim.api.nvim_win_set_cursor(win, { vim.api.nvim_buf_line_count(ev.buf), 0 })
    end
  end,
})

-- nvim-gdb's layout: the window the session starts from (the script's, since the $NVIM
-- controller runs Ex commands in the main editor window) becomes its source window, and
-- termwin_command opens the debugger's terminal next to it. The default ('belowright new')
-- stacks pdb under the script; 'belowright vnew' puts it on the right of the script instead,
-- above Claude's split, which keeps its place. No new tab page: nvim-gdb opens one only for a
-- second session in the same tab page. (nvim-gdb's own keys are buffer-local in the source window
-- during a session; the demo presses none of them.)
vim.g.nvimgdb_config_override = { termwin_command = 'belowright vnew' }

-- The signs nvim-gdb places in the source window: the current line (▶) and breakpoints (●). The
-- sign column is hidden above; when a session starts, the source window (the only window of the
-- tab page showing a file) gets one two signs wide, so that a breakpoint's ● stays visible next
-- to the ▶ when pdb stops on it (a one-sign column shows only the ▶, which nvim-gdb places with a
-- higher priority). nvim-gdb defines the signs' text when a session starts, which keeps the
-- highlights given here: the current line's sign, number and text on an amber band (over the
-- cursor line, where nvim-gdb also puts the source window's cursor; the sign column's cells on
-- that line too, through CursorLineSign), breakpoints in red. No culhl: on the cursor line,
-- Neovim draws every sign with the culhl of the highest-priority one, which would make the ●
-- amber like the ▶.
vim.api.nvim_create_autocmd('User', {
  pattern = 'NvimGdbStart',
  callback = function()
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if vim.bo[vim.api.nvim_win_get_buf(win)].buftype == '' then
        vim.wo[win].signcolumn = 'yes:2'
        vim.wo[win].winhighlight = 'CursorLineSign:DemoGdbLine'
      end
    end
  end,
})
local band = '#443f2b'
hl(0, 'DemoGdbLine', { bg = band })
hl(0, 'DemoGdbMark', { fg = '#f9e2af', bg = band, bold = true })
hl(0, 'DemoGdbBreakpoint', { fg = '#f38ba8' })
vim.fn.sign_define('GdbCurrentLine', {
  texthl = 'DemoGdbMark', numhl = 'DemoGdbMark', linehl = 'DemoGdbLine',
})
for i = 1, 10 do
  vim.fn.sign_define('GdbBreakpoint' .. i, { texthl = 'DemoGdbBreakpoint' })
end

-- agent.nvim, with the default terminal layout: Claude in a split below the file, 0.4 of the
-- editor's height (terminal.layout 'split', split_side 'below', split_size 0.4). A diff opens in a
-- tab of its own that shows Claude too, full width below original | proposed and as tall as here
-- (diff.show_terminal, on by default), so that Claude's TUI does not reflow. The default diff
-- keymaps stay (<leader>aa accepts, <leader>ad rejects); the demo accepts with :w.
require('agent').setup({
  agents = {
    claude = {
      -- Claude asks before it edits a file, so the edit opens as a diff in Neovim (auto mode,
      -- Claude Code's default, would apply it without asking).
      args = { '--permission-mode', 'manual' },
      auto_approve = true, -- the $NVIM controller's tools run without a permission prompt
      env = {
        CLAUDE_CONFIG_DIR = vim.env.DEMO_CLAUDE_CONFIG_DIR, -- seeded, isolated config
        ANTHROPIC_BASE_URL = vim.env.DEMO_MODEL_URL, -- local scripted model (tests/e2e/fake_model.mjs)
        ANTHROPIC_API_KEY = vim.env.DEMO_API_KEY, -- dummy key
        CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = '1',
        DISABLE_TELEMETRY = '1',
        DISABLE_AUTOUPDATER = '1',
        DISABLE_ERROR_REPORTING = '1',
      },
    },
  },
})
-- The README's recommended mappings (Normal and Visual mode).
vim.g.mapleader = ' '
vim.keymap.set({ 'n', 'x' }, '<leader>ac', '<cmd>AgentToggle<cr>', { desc = 'Toggle agent' })
vim.keymap.set({ 'n', 'x' }, '<leader>as', '<cmd>AgentSend<cr>', { desc = 'Send to agent' })

-- animate.nvim, with every module on (preset 'full'). What the demo shows most: Claude's split
-- flies in from below when :AgentToggle opens it, and pdb's from the right when Claude starts the
-- session through the $NVIM controller. (The diff opens in a tab page of its own, which no
-- module animates.) Set up last, after the colours above.
require('animate').setup({ preset = 'full' })
