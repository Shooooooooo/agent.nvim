# agent.nvim

Run Claude Code, OpenCode, GitHub Copilot CLI or Gemini CLI in a Neovim terminal, with Neovim
itself serving the IDE integration each CLI expects from VS Code. Like
[coder/claudecode.nvim](https://github.com/coder/claudecode.nvim), but for four agents.

**The agent can also drive Neovim.** Every agent that agent.nvim launches gets the
[$NVIM controller](#the-nvim-controller), an MCP server connected to the Neovim hosting the agent
(through `$NVIM`): the agent can read your unsaved buffers, open files for you, run Ex commands or
Lua, and send you notifications.

![agent.nvim demo: asked to debug a Python script, Claude Code, in a split below the file, starts a pdb session through the $NVIM controller; nvim-gdb opens pdb beside the script and marks the breakpoint line, Claude's fix opens in a Neovim diff tab and is accepted with :w, and the re-run in the same pdb session prints 6.0](demo/agent-nvim-demo.gif)

## Features

- The agent runs in a split (below your file by default), a float, a tab or the current window.
  `:AgentToggle` toggles the terminal; the agent keeps running while hidden. One agent runs at a
  time: starting another one asks before replacing it.
- `:AgentSend` sends your selection, or the whole file, to the agent through the IDE connection
  and switches to the agent, starting it if needed: your next prompt carries it (Claude and
  OpenCode use it for that prompt only; `:AgentSend` again for a later one). A terminal or
  another buffer that is not a file goes as `nvim://buffer/<n>/<label>`, which the agent reads
  through the [$NVIM controller](#the-nvim-controller). Optionally (`selection.track = true`) the
  agent follows your current file and selection by itself, the same way.
- Proposed edits open as a side-by-side diff in Neovim, with the agent's terminal still in view:
  accept with `:w`, reject by closing it.
- While the agent works, Neovim shows it: a progress message for the default statusline and
  your terminal's progress bar, and `◐` on the agent's window (`:help agent-progress`). Claude
  Code and Gemini CLI tell it in their title, Copilot CLI only in some terminals, OpenCode not.
- The [$NVIM controller](#the-nvim-controller), registered automatically, lets the agent drive the
  Neovim it runs in.
- Pure Lua, no dependencies. Servers listen only on loopback or a private Unix socket and require
  a token.

## Requirements

- Neovim 0.12 or newer.

## Installation

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  'Shooooooooo/agent.nvim',
  lazy = false,
  opts = {},
  keys = {
    { '<leader>ac', '<cmd>AgentToggle<cr>', mode = { 'n', 'x' }, desc = 'Toggle agent' },
    { '<leader>as', '<cmd>AgentSend<cr>', mode = { 'n', 'x' }, desc = 'Send to agent' },
  },
}
```

With `vim.pack`:

```lua
vim.pack.add({ 'https://github.com/Shooooooooo/agent.nvim' })
vim.keymap.set({ 'n', 'x' }, '<leader>ac', '<cmd>AgentToggle<cr>', { desc = 'Toggle agent' })
vim.keymap.set({ 'n', 'x' }, '<leader>as', '<cmd>AgentSend<cr>', { desc = 'Send to agent' })
```

The keys are only suggestions: map the commands to whatever you like. `:AgentSend` sends the
selection in Visual mode, the whole file in Normal mode.

## Quick start

1. Run `:checkhealth agent` to see which agent CLIs are installed and whether anything blocks the
   connection.
2. Run `:AgentToggle` to open Claude in a split below your file (or `:AgentToggle opencode`,
   `:AgentToggle copilot`, `:AgentToggle gemini`). The agent connects to Neovim by itself; Gemini
   needs a [one-time setup](#gemini-cli) first.
3. Select lines and run `:AgentSend` (or your mapping for it). The agent gets them (Claude shows
   `⧉ 3 lines selected`) and the cursor moves to the agent's prompt: type your request, and the
   lines go with it.
4. Ask for a change. When the agent asks for permission, a diff tab opens: accept with `:w` or
   `<leader>aa`, reject with `<leader>ad` or by closing the tab. The tab shows the agent's
   terminal too, so you can read its prompt or answer there instead. Claude Code's default mode
   rarely asks, see [Claude Code](#claude-code).
5. Run `:AgentToggle` again to hide the terminal. The agent keeps running. For a split beside your
   code instead, set `terminal.split_side = 'right'`; to show the agent in place of your file,
   `terminal.layout = 'current'`.

## Commands

| Command | Description |
|---|---|
| `:AgentToggle [name]` | Toggle the agent terminal, starting the agent if needed. |
| `:AgentOpen [name]` | Open (start or show) the agent terminal and focus it. |
| `:[range]AgentSend [name]` | Send the selection (or the range, else the whole file) to the agent through the IDE connection and switch to the agent, starting it if needed. |
| `:AgentClose` | Hide the terminal (in a diff tab, only there). The agent keeps running. |
| `:AgentStop` | Stop the agent, and its IDE server unless `auto_start` is on. |
| `:AgentDiffAccept` | Accept the current diff. |
| `:AgentDiffReject` | Reject the current diff. |
| `:AgentStatus` | Show the agent and the IDE servers. |
| `:AgentMcpConfig [agent]` | Print the config for registering the $NVIM controller by hand. |
| `:AgentGeminiSetup` | Link the agent.nvim extension into Gemini CLI (once). |

`[name]` defaults to the running agent, then to `default_agent`. Starting a different agent
while one runs asks first (`Stop claude and start copilot?`): Yes stops the running agent, as
`:AgentStop` does, and starts the new one; No keeps it. From Lua, `open(name, { confirm = false })`
replaces it without asking.

## Configuration

`setup()` is optional: every command calls it on first use.

<details>
<summary>Default configuration (the options you are most likely to change)</summary>

```lua
require('agent').setup({
  default_agent = 'claude',
  terminal = {
    layout = 'split',       -- 'split' | 'current' | 'float' | 'tab' | 'none'
    split_side = 'below',   -- 'below' | 'right' | 'left' | 'above' (splits, diff tabs)
    split_size = 0.4,       -- fraction of the editor height (or width)
  },
  selection = {
    track = false,          -- true: the agent follows your current file and selection by itself
  },
  diff = {
    show_terminal = true,   -- show the agent terminal in diff tabs too; false: the diff only
    keymaps = { accept = '<leader>aa', reject = '<leader>ad' }, -- '' or false disables a key
  },
  progress = {
    enabled = true,         -- show when the agent works (statusline, terminal progress bar)
  },
  agents = {
    -- the same keys exist for opencode, copilot and gemini
    claude = {
      cmd = { 'claude' },
      args = {},              -- extra CLI arguments
      auto_approve = false,   -- pre-approve the $NVIM controller's tools
    },
  },
  nvim_mcp = { enabled = true }, -- register the $NVIM controller
})
```

</details>

Full reference: `:help agent-config`.

## The $NVIM controller

agent.nvim registers an MCP server with each agent it launches, through which the agent drives
the Neovim it runs in: `read_buffer`, `open_file`, `execute_command`, `eval`, `exec_lua`,
`notify`. `read_buffer` also reads the terminals and other buffers sent as
`nvim://buffer/<n>/<label>`. For an agent you start yourself, `:AgentMcpConfig` prints the
config to add (`:help agent-nvim-mcp-manual`).

**Security:** `exec_lua`, `execute_command` and `eval` run arbitrary code as you. Claude, Copilot
and Gemini ask before each call unless `agents.<name>.auto_approve = true`; OpenCode follows its
own `permission` config. Disable it with `nvim_mcp.enabled = false`, or per agent with
`agents.<name>.mcp = false`.

## Agent notes

### Claude Code

- Diffs open only when Claude asks for permission. Its default mode (auto, as of 2.1.283) applies
  most edits without asking. To review edits in Neovim, start it in manual mode with
  `agents = { claude = { args = { '--permission-mode', 'manual' } } }`, or switch modes with
  Shift+Tab or `/config` in Claude.
- Claude does not open a diff for a file with unsaved changes in Neovim.
- Under tmux (or screen, zellij) Claude's title does not show when it works, so neither can
  agent.nvim. `agents = { claude = { env = { TMUX = false } } }` unsets TMUX for Claude, which
  then does not use tmux itself either (e.g. for teammates in tmux panes).

### OpenCode

- Connects through the Claude IDE server's lock file in `~/.claude/ide`; nothing to set up.
- It only receives the file and selection (`:AgentSend`, `selection.track`): its edits are
  written directly, so there are no diffs in Neovim. The $NVIM controller works.

### GitHub Copilot CLI

- It attaches the selection you sent to every prompt, not only the next one, until the next
  `:AgentSend` (or, with `selection.track = true`, until the selection changes). A whole file is
  not attached: its footer names the file, and its model can read the current file and selection
  with its `ide-get_selection` tool.
- **Security:** `providers.copilot.trust_workspace = true` makes Copilot skip its folder-trust
  prompt and load the repository's own MCP servers, settings and hooks without asking. Leave it
  `false` (the default), or pass a `function(folder)` that returns `true` only for folders you
  trust.

### Gemini CLI

- One-time setup: run `/ide enable` inside Gemini, and `:AgentGeminiSetup` in Neovim (it links the
  extension that registers the $NVIM controller). Until IDE mode is on, `:AgentSend` types
  `@a.txt (lines 3-5)` into Gemini's prompt instead.
- Gemini refuses the controller in untrusted folders: trust the folder in Gemini, or set
  `agents.gemini.skip_trust = true`, which makes Gemini trust any folder it is launched in.
