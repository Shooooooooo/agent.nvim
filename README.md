# agent.nvim

Run Claude Code, OpenCode, GitHub Copilot CLI or Gemini CLI in a Neovim terminal, with Neovim
itself serving the IDE integration each CLI expects from VS Code. Like
[coder/claudecode.nvim](https://github.com/coder/claudecode.nvim), but for four agents.

**The agent can also drive Neovim.** Every agent that agent.nvim launches gets the
[$NVIM controller](#the-nvim-controller), an MCP server connected to the Neovim hosting the agent
(through `$NVIM`): the agent can read your unsaved buffers, open files for you, run Ex commands or
Lua, and send you notifications.

![agent.nvim demo: lines selected in Neovim show up in Claude Code's split below the file; after switching to Claude and typing the request, Claude sends a notification through the $NVIM controller, and its edit opens in a Neovim diff tab, original and proposed side by side with Claude Code still shown below, and is accepted with :w](demo/agent-nvim-demo.gif)

The demo uses the default layout, the agent in a split below the file: select lines, switch to
Claude with `<C-w>j` and type the request. Claude notifies through the $NVIM controller, and its
edit opens in a Neovim diff tab, with Claude still in view below, where `:w` accepts it. This is
the real Claude Code TUI, with the model's replies scripted so that the recording is reproducible
(see [demo/](demo/)).

## Features

- The agent runs in a split (below your file by default), a float, a tab or the current window.
  `:AgentToggle` toggles the terminal; the agent keeps running while hidden. One agent runs at a
  time: starting another one asks before replacing it.
- The agent automatically sees your current file and visual selection.
- Proposed edits open as a side-by-side diff in Neovim, with the agent's terminal still in view:
  accept with `:w`, reject by closing it.
- The [$NVIM controller](#the-nvim-controller), registered automatically, lets the agent drive the
  Neovim it runs in.
- Pure Lua, no dependencies. Servers listen only on loopback or a private Unix socket and require
  a token.

| Agent | Sees file and selection | Diffs in Neovim | Diagnostics |
|---|---|---|---|
| Claude Code (`claude`) | yes | yes, editable | yes |
| OpenCode (`opencode`) | yes | no | through `exec_lua` |
| GitHub Copilot CLI (`copilot`) | selection (file through a tool) | yes, read-only | yes |
| Gemini CLI (`gemini`) | yes | yes, editable | through `exec_lua` |

## Requirements

- Neovim 0.11 or newer (`vim.pack` needs 0.12).
- At least one agent CLI on `$PATH`. The IDE protocols are undocumented and change between
  releases; they were verified against Claude Code 2.1.283, OpenCode 1.18.32, Copilot CLI 1.0.88
  and Gemini CLI 0.61.0.
- Tested on macOS. Linux support exists but has not been tested live; Windows is untested.

## Installation

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  'Shooooooooo/agent.nvim',
  main = 'agent',
  opts = {},
  keys = {
    { '<leader>ac', '<cmd>AgentToggle<cr>', mode = { 'n', 'x' }, desc = 'Toggle agent' },
  },
  cmd = { 'AgentToggle', 'AgentOpen', 'AgentStatus', 'AgentMcpConfig', 'AgentGeminiSetup' },
}
```

With `vim.pack` (Neovim 0.12+):

```lua
vim.pack.add({ 'https://github.com/Shooooooooo/agent.nvim' })
vim.keymap.set({ 'n', 'x' }, '<leader>ac', '<cmd>AgentToggle<cr>', { desc = 'Toggle agent' })
```

The mapping works in Visual mode too, so that a selection reaches the agent when `<leader>ac`
opens it (pressing `<Esc>` first would drop the selection).

## Quick start

1. Run `:checkhealth agent` to see which agent CLIs are installed and whether anything blocks the
   connection.
2. Run `:AgentToggle` to open Claude in a split below your file (or `:AgentToggle opencode`,
   `:AgentToggle copilot`, `:AgentToggle gemini`). The agent connects to Neovim by itself; Gemini
   needs a [one-time setup](#gemini-cli) first.
3. Select lines and switch to the agent straight from Visual mode: `<C-w>j` (then `i` to type), or
   the `<leader>ac` mapping when the agent is hidden. The agent keeps the selection. Leaving Visual
   mode in the file (`<Esc>`) drops it, and the agent then sees just the current file.
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

`setup()` is optional: every command calls it on first use. The options you are most likely to
change, with their defaults:

```lua
require('agent').setup({
  default_agent = 'claude',
  terminal = {
    layout = 'split',       -- 'split' | 'current' | 'float' | 'tab' | 'none'
    split_side = 'below',   -- 'below' | 'right' | 'left' | 'above' (splits, diff tabs)
    split_size = 0.4,       -- fraction of the editor height (or width)
  },
  diff = {
    show_terminal = true,   -- show the agent terminal in diff tabs too; false: the diff only
    keymaps = { accept = '<leader>aa', reject = '<leader>ad' }, -- '' or false disables a key
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

Full reference: `:help agent-config`.

## Agent notes

### Claude Code

- Diffs open only when Claude asks for permission. Its default mode (auto, as of 2.1.283) applies
  most edits without asking. To review edits in Neovim, start it in manual mode with
  `agents = { claude = { args = { '--permission-mode', 'manual' } } }`, or switch modes with
  Shift+Tab or `/config` in Claude.
- Claude does not open a diff for a file with unsaved changes in Neovim.

### OpenCode

- Connects through the Claude IDE server's lock file in `~/.claude/ide`; nothing to set up.
- It only receives the file and selection: its edits are written directly, so there are no diffs
  in Neovim. The $NVIM controller works.

### GitHub Copilot CLI

- It attaches only a non-empty selection to your prompt, not the current file. Its model can
  still read the current file and cursor with its `ide-get_selection` tool.
- **Security:** `providers.copilot.trust_workspace = true` makes Copilot skip its folder-trust
  prompt and load the repository's own MCP servers, settings and hooks without asking. Leave it
  `false` (the default), or pass a `function(folder)` that returns `true` only for folders you
  trust.

### Gemini CLI

- One-time setup: run `/ide enable` inside Gemini, and `:AgentGeminiSetup` in Neovim (it links the
  extension that registers the $NVIM controller).
- Gemini refuses the controller in untrusted folders: trust the folder in Gemini, or set
  `agents.gemini.skip_trust = true`, which makes Gemini trust any folder it is launched in.

## The $NVIM controller

When it launches an agent, agent.nvim registers a stdio MCP server through which the agent can
drive the Neovim it runs in, without editing your agent config files. Its tools: `read_buffer`,
`open_file`, `execute_command`, `eval`, `exec_lua`, `notify`. It leaves the current file,
selection and diagnostics to the IDE connection, edits to the agent's own tools, and anything else
to `exec_lua`. For an agent you start yourself in a Neovim terminal, `:AgentMcpConfig` prints the
config to add, and `auto_start = true` keeps the IDE servers running so that it can use the IDE
connection too (`:help agent-nvim-mcp-manual`).

**Security:** the controller can do anything your Neovim can. `exec_lua`, `execute_command` and
`eval` run arbitrary Lua, Ex commands and Vimscript as you, shell commands included. Claude,
Copilot and Gemini ask before each call (following their own permission settings) unless you opt
in with `agents.<name>.auto_approve = true`; OpenCode allows all tools unless its own
`permission` config says otherwise. Turn the controller off with `nvim_mcp.enabled = false`, or
per agent with `agents.<name>.mcp = false`.

## More

- `:help agent.nvim`: the full reference (options, Lua API, events, per-agent details,
  troubleshooting).
- `:checkhealth agent`: checks the agent CLIs, the IDE servers and the controller.
- [docs/PROTOCOLS.md](docs/PROTOCOLS.md): the four IDE protocols, for contributors.
- Tests: `make test` (Lua specs and MCP SDK conformance), `make test-e2e` (live, real agent CLIs).
- Demo: `make demo` re-records the GIF (see `:help agent-demo` and `demo/record.sh`).

## Credits

The Claude IDE protocol implementation follows
[coder/claudecode.nvim](https://github.com/coder/claudecode.nvim), whose Lua server and protocol
notes were the reference.
