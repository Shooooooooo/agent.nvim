-- Minimal Neovim config for the README demo (demo/record.sh). It loads agent.nvim from this
-- repository and points Claude Code at the local scripted model that record.sh starts. Every
-- DEMO_* variable comes from record.sh, which also isolates HOME, XDG_* and CLAUDE_CONFIG_DIR.
local repo = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
for _, var in ipairs({ 'DEMO_MODEL_URL', 'DEMO_CLAUDE_CONFIG_DIR', 'DEMO_API_KEY' }) do
  -- Never start Claude against a real account or config: run this only through demo/record.sh.
  assert(vim.env[var], var .. ' is not set: run demo/record.sh')
end
vim.opt.rtp:prepend(repo)

-- Looks
vim.o.termguicolors = true
vim.o.background = 'dark'
-- catppuccin ships with Neovim 0.12; fall back to a built-in scheme on older versions.
if not pcall(vim.cmd.colorscheme, 'catppuccin') then
  vim.cmd.colorscheme('habamax')
end
vim.o.number = true
-- The diff tab is split three ways (original | proposed | Claude): keep the code's gutter narrow,
-- so that the code fits (3 columns for the line numbers, no fold column in the diff windows).
vim.o.numberwidth = 3
vim.opt.diffopt:append('foldcolumn:0')
vim.o.cursorline = true
vim.o.signcolumn = 'no'
vim.o.showmode = false
vim.o.showcmd = false
vim.o.laststatus = 3
vim.o.showtabline = 0
vim.o.splitright = true
vim.o.fillchars = 'eob: ,vert:│,diff:╱'
vim.o.shortmess = vim.o.shortmess .. 'IF'
vim.o.wrap = false
vim.g.mapleader = ' '

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
    local file -- the file under review, from the original side's winbar (' original: <file>')
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      file = file or vim.wo[win].winbar:match('^ original: (.+)$')
    end
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if vim.wo[win].diff then
        -- agent.nvim's proposal is the only acwrite buffer (agent-diff://<id>) in its diff.
        local proposal = vim.bo[vim.api.nvim_win_get_buf(win)].buftype == 'acwrite'
        vim.wo[win].winhighlight = proposal and diff_sides.new or diff_sides.old
        vim.wo[win].number = true
        -- The proposal's winbar is ' proposed: %<<title> %=accept: :w ', and Claude's title for
        -- the diff ('✻ [Claude Code] greet.lua (<id>) ⧉') does not fit in a third of the screen:
        -- name the file instead, as agent.nvim does for a diff without a title.
        local bar = vim.wo[win].winbar
        if proposal and file and bar:find('%<', 1, true) then
          vim.wo[win].winbar = bar:gsub('%%<.*%%=', function()
            return file .. ' %='
          end, 1)
        end
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

-- Notifications as a small popup in the empty lower left of the editor, so that messages the
-- agent sends through the $NVIM controller's notify tool stand out (the tool passes the agent's
-- name as the title).
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
    local win = vim.api.nvim_open_win(buf, false, {
      relative = 'editor', anchor = 'SW', row = vim.o.lines - 3, col = 3,
      width = math.min(width, vim.o.columns - 8), height = #lines,
      style = 'minimal', border = 'rounded', focusable = false, zindex = 200,
      title = ' ' .. title .. ' ', title_pos = 'left',
    })
    vim.wo[win].wrap = true
    vim.defer_fn(function()
      pcall(vim.api.nvim_win_close, win, true)
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end, 4500)
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

-- agent.nvim
require('agent').setup({
  -- A split on the right (the default split is below the file), so that the demo edits side by
  -- side with Claude, at the default size: Claude gets 59 of the 148 columns. A diff opens in a
  -- tab of its own that shows Claude too, as wide as here (diff.show_terminal, on by default), so
  -- that Claude's TUI does not reflow: original | proposed | Claude, with about 40 columns of code
  -- on each side.
  terminal = { layout = 'split', split_side = 'right', split_size = 0.4 },
  -- The demo uses :w to accept; without the key hints the proposal's winbar has more room
  -- ('accept: :w').
  diff = { keymaps = { accept = '', reject = '' } },
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
vim.keymap.set('n', '<leader>ac', '<cmd>Agent<cr>', { desc = 'Toggle agent' })
