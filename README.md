# agent.nvim

agent.nvim runs coding-agent CLIs in a Neovim terminal, and Neovim itself hosts the IDE
integration server each CLI expects from VS Code. It works like
[coder/claudecode.nvim](https://github.com/coder/claudecode.nvim), but for four agents:

| Agent | CLI | IDE protocol served by Neovim |
|---|---|---|
| Claude Code | `claude` | Claude IDE protocol: MCP over WebSocket on 127.0.0.1, lock file in `~/.claude/ide` |
| OpenCode | `opencode` | the same Claude IDE server (OpenCode is a receive-only client) |
| GitHub Copilot CLI | `copilot` | Copilot `/ide`: MCP Streamable HTTP over a Unix socket, lock file in `~/.copilot/ide` |
| Gemini CLI | `gemini` | Gemini IDE companion: MCP Streamable HTTP on 127.0.0.1, discovery file in `$TMPDIR/gemini/ide` |

With the IDE connection the agent sees your current selection, you can @-mention files and line
ranges from Neovim, proposed edits open as a side-by-side diff in Neovim for you to accept or
reject, and the agent can read your diagnostics.

agent.nvim also ships the **$NVIM controller**, a small stdio MCP server (`nvim --headless -l
…/nvim_mcp/main.lua`). It is registered for each agent the plugin launches, without editing
your agent config files. Through it the agent can drive the Neovim it runs in: read and edit
buffers, open files, query diagnostics, run Ex commands, evaluate Vimscript, and run Lua.

The plugin is pure Lua on `vim.uv` with no runtime dependencies. Every server binds to loopback
or to a Unix socket in a private directory, and every server requires its protocol's auth token.

## Contents

- [Requirements](#requirements)
- [Installation](#installation)
- [Quick start](#quick-start)
- [Commands](#commands)
- [Lua API](#lua-api)
- [Configuration](#configuration)
- [Agents](#agents)
- [The $NVIM controller](#the-nvim-controller)
- [Reviewing diffs](#reviewing-diffs)
- [Events and variables](#events-and-variables)
- [Troubleshooting](#troubleshooting)
- [Protocol notes and credits](#protocol-notes-and-credits)
- [Running the tests](#running-the-tests)

## Requirements

- **Neovim 0.11 or newer.** Development and testing used 0.12.5, and 0.11 itself has not been
  tested. `vim.pack` (see below) needs 0.12.
- At least one agent CLI on `$PATH`. The protocols were verified against these versions:

  | CLI | Verified version |
  |---|---|
  | Claude Code | 2.1.283 |
  | OpenCode | 1.18.32 |
  | GitHub Copilot CLI | 1.0.88 |
  | Gemini CLI | 0.61.0 (the IDE server also against 0.59.0 and 0.50.0) |

  All four IDE protocols are undocumented or only partly documented, and they change between
  releases. See [docs/PROTOCOLS.md](docs/PROTOCOLS.md).
- `nvim` on `$PATH` is recommended. Persisted configs (the Gemini extension manifest and
  `:AgentMcpConfig`) use `exepath('nvim')`, which survives Neovim upgrades, when it is the running
  nvim (same realpath). Otherwise they use `v:progpath`, and `:checkhealth agent` warns.
- Development and testing were on macOS. The Linux code paths exist and were not run live.
  Windows (named pipes) is untested.

## Installation

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  'Shooooooooo/agent.nvim',
  main = 'agent',
  opts = {
    -- default_agent = 'claude',
  },
  keys = {
    { '<leader>ac', '<cmd>Agent<cr>', desc = 'Toggle agent' },
    { '<leader>as', '<cmd>AgentSend<cr>', mode = 'x', desc = 'Send selection to agent' },
    { '<leader>ab', '<cmd>AgentAdd<cr>', desc = 'Add current file to agent' },
  },
  cmd = { 'Agent', 'AgentOpen', 'AgentSend', 'AgentAdd', 'AgentStatus', 'AgentMcpConfig', 'AgentGeminiSetup' },
}
```

If you use `auto_start = true`, do not lazy-load the plugin: the IDE servers must already be running
when you start an agent yourself.

With `vim.pack` (Neovim 0.12+):

```lua
vim.pack.add({ 'https://github.com/Shooooooooo/agent.nvim' })
require('agent').setup({})
vim.keymap.set('n', '<leader>ac', '<cmd>Agent<cr>', { desc = 'Toggle agent' })
vim.keymap.set('x', '<leader>as', '<cmd>AgentSend<cr>', { desc = 'Send selection to agent' })
vim.keymap.set('n', '<leader>ab', '<cmd>AgentAdd<cr>', { desc = 'Add current file to agent' })
```

Calling `setup()` is optional. Every command calls `setup({})` the first time it runs, if
`setup()` has not been called yet.

## Quick start

1. Run `:checkhealth agent`. It shows which agent CLIs are installed and whether anything blocks
   the IDE connection or the $NVIM controller.
2. Run `:Agent` to open the default agent (`claude`) in a split on the right, or `:Agent copilot`,
   `:Agent gemini` or `:Agent opencode`. The IDE server starts on first use, and the agent
   connects to it by itself.
3. Select lines in a file and run `:AgentSend` (or the `x`-mode mapping above). The agent's prompt
   gets an @-mention of those lines. `:AgentAdd` mentions the whole current file.
4. Ask the agent to change a file. When it asks for permission, a diff tab opens in Neovim.
   Accept with `:w` (or `<leader>aa`), reject with `<leader>ad` or by closing the tab.
5. Run `:Agent` again to hide the terminal. The agent keeps running.

Gemini needs a one-time setup first: run `/ide enable` once inside Gemini, and run
`:AgentGeminiSetup` once. See [Gemini CLI](#gemini-cli).

## Commands

| Command | Description |
|---|---|
| `:Agent [name]` | Toggle an agent terminal: hide it when it is visible in this tab page, otherwise open (starting the agent if needed) and focus it. |
| `:AgentOpen [name]` | Open (start or show) an agent terminal and focus it. |
| `:AgentClose [name]` | Hide the agent's terminal windows. The agent keeps running. |
| `:AgentStop [name]` | Stop the agent: end its job, wipe its terminal, delete its temp files. Its IDE server keeps running, so agents started later reuse it. |
| `:AgentStop!` | Stop every agent and every IDE server. Lock and discovery files are removed. This also runs on `VimLeavePre`. |
| `:[range]AgentSend [name]` | @-mention the selected lines in an agent's prompt. With a range, those lines of the current file. Without one, the visual selection: the live one when run from visual mode (e.g. through `<cmd>AgentSend<cr>`), otherwise the last one (`'<,'>`, what `gv` reselects) of the current file. From the agent's terminal it is the latest selection made in a file, else the last one of the last focused file. |
| `:AgentAdd [file] [start] [end]` | @-mention a file or directory (default: the current file), optionally a line range of it. |
| `:AgentDiffAccept` | Accept the diff in the current buffer, tab page or window (or the only open diff). |
| `:AgentDiffReject` | Reject that diff. |
| `:AgentStatus` | Show agents (running, pid, visible, last focused) and IDE servers (clients, address, lock file). |
| `:AgentMcpConfig [agent]` | Print the MCP config fragment for registering the $NVIM controller by hand, plus where it goes for that agent (for Claude, also a ready-to-paste `claude mcp add-json` command). |
| `:AgentGeminiSetup` | Link the agent.nvim extension into Gemini CLI (one time; asks for confirmation). |
| `:checkhealth agent` | Check the Neovim version and server address, the configuration, the agent CLIs, the IDE servers, Claude's managed policy, the Gemini settings and extension, and the controller. |

`[name]` defaults to the most recently focused running agent, and then to `default_agent`. The
commands complete agent names.

The @-mention commands send to that same agent. If it is not running in an agent.nvim terminal,
but an agent of its kind that you started yourself is connected to the IDE server (Claude,
OpenCode or Copilot), the mention goes to that one. Otherwise they start the agent in the
background first; with `terminal.layout = 'none'` that is an error instead.

## Lua API

```lua
local agent = require('agent')
agent.setup(opts)                       -- configure; safe to call again (the latest options win)
agent.open(name, opts)                  -- start or show; returns bufnr or nil, err
agent.toggle(name, opts)
agent.close(name)                       -- hide the windows
agent.stop(name)                        -- stop one agent
agent.teardown()                        -- stop all agents and IDE servers (:AgentStop!)
agent.mention(path, l1, l2, { name = 'claude', focus = false })  -- -> ok, 'sent'|'typed'|'pending'
agent.send_selection(range, opts)       -- range = { path?, line1, line2? } or nil for the visual selection
agent.add_file(path, l1, l2, opts)      -- path nil = current file
agent.status()                          -- table: servername, last_focused, agents, providers
agent.mcp_config(name)                  -- the table :AgentMcpConfig prints
agent.diff_accept() / agent.diff_reject()
agent.reference(kind, path, l1, l2, cwd)  -- the @-reference string an agent understands
```

Lines are 1-based and inclusive. `nil` lines mean the whole file.

`open()` and `toggle()` accept options. `focus` and `layout` also apply when an existing
terminal is shown again; the others apply only when the agent is started:

| Option | Meaning |
|---|---|
| `focus` | Enter the terminal window (default `true`). |
| `layout` | Override `terminal.layout` for this window: `'split'`, `'float'`, `'tab'` or `'none'`. |
| `args` | Extra CLI arguments for this launch, after `cmd` and `agents.<name>.args`. |
| `cwd` | Working directory of the agent (default: Neovim's cwd). |
| `env` | Extra environment for this launch. A `false` value unsets the variable. |
| `mcp` | Register the $NVIM controller for this launch (default: `nvim_mcp.enabled` and `agents.<name>.mcp`). |
| `auto_approve` | Pre-approve the controller's tools for this launch (default: `agents.<name>.auto_approve`). |
| `silent` | Do not notify errors; they are still returned. |

```lua
require('agent').open('claude', { args = { '--model', 'opus' }, auto_approve = true })
require('agent').open('copilot', { cwd = '~/src/other-project', layout = 'float' })
```

`mention()` returns `'sent'` when the IDE server delivered the mention (or queued it for a
Claude or OpenCode client that is still connecting). It returns `'typed'` when the reference was
typed into the agent's prompt instead (Gemini, or no client connected). It returns `'pending'`
right after a launch, when the mention will be retried or typed shortly. The mention goes to the
agent in the target terminal only, never to another agent's prompt (see [Agents](#agents)).

## Configuration

The defaults, from `lua/agent/config.lua`:

```lua
require('agent').setup({
  log_level = 'warn',            -- 'trace'|'debug'|'info'|'warn'|'error'
  log_file = nil,                -- path; messages at log_level and above are appended there
  default_agent = 'claude',      -- the agent :Agent opens without an argument
  auto_start = false,            -- start every enabled IDE server at setup()

  terminal = {
    layout = 'split',            -- 'split'|'float'|'tab'|'none'
    split_side = 'right',        -- 'right'|'left'|'below'|'above'
    split_size = 0.4,            -- fraction of the editor width (or height for below/above)
    float = { width = 0.85, height = 0.85, border = 'rounded' },
    start_insert = true,         -- enter terminal mode when agent.nvim opens or shows the terminal
    auto_close = true,           -- close the terminal when the agent exits
  },

  selection = {
    track = true,                -- push the selection, cursor and open files to connected agents
    debounce_ms = 100,
  },

  diff = {
    open_in = 'tab',             -- 'tab'|'current'
    keymaps = {
      accept = '<leader>aa',
      reject = '<leader>ad',
    },
  },

  agents = {
    claude = { cmd = { 'claude' }, args = {}, env = {}, provider = 'claude', mcp = true, auto_approve = false },
    opencode = {
      cmd = { 'opencode' }, args = {}, env = {}, provider = 'claude', mcp = true, auto_approve = false,
      line_offset = 1,           -- added to line numbers sent to OpenCode (it reads them as 1-based)
      scrub_vscode_env = true,   -- blank TERM_PROGRAM/TERM_PROGRAM_VERSION/GIT_ASKPASS inherited from VS Code
    },
    copilot = { cmd = { 'copilot' }, args = {}, env = {}, provider = 'copilot', mcp = true, auto_approve = false },
    gemini = {
      cmd = { 'gemini' }, args = {}, env = {}, provider = 'gemini', mcp = true, auto_approve = false,
      skip_trust = false,        -- pass --skip-trust (needed for stdio MCP servers in untrusted folders)
    },
  },

  providers = {
    claude = { enabled = true, port_range = { min = 10000, max = 65535 } },
    copilot = { enabled = true, trust_workspace = false },
    gemini = { enabled = true },
  },

  nvim_mcp = {
    enabled = true,
    server_name = 'nvim',        -- ^[A-Za-z0-9-]{1,24}$; not 'ide' or another reserved name
    timeout_ms = 30000,          -- per call into Neovim
  },
})
```

Lists (`cmd`, `args`) replace the defaults instead of being merged index by index.

### Option reference

| Option | Default | Description |
|---|---|---|
| `log_level` | `'warn'` | Minimum level that is logged. Only `warn` and `error` are shown with `vim.notify`; lower levels go only to `log_file`. |
| `log_file` | `nil` | File that log lines at `log_level` and above are appended to. Use an absolute path. |
| `default_agent` | `'claude'` | Agent used when a command gets no name and no agent has been focused. |
| `auto_start` | `false` | Start every enabled IDE server at `setup()`, so agents you start yourself (in a `:terminal` or elsewhere) can connect. See the Copilot note below. |
| `terminal.layout` | `'split'` | `'split'`, `'float'`, `'tab'`, or `'none'`. `'none'` means the plugin does not start agents: you run them yourself (combine it with `auto_start = true`). @-mentions then go through the IDE connection to the agent you started (Claude, OpenCode, Copilot); with no such agent connected, they fail with an error. |
| `terminal.split_side` | `'right'` | Side of the split: `'right'`, `'left'`, `'below'` or `'above'`. |
| `terminal.split_size` | `0.4` | Split size as a fraction (0 to 1) of the editor width or height. |
| `terminal.float` | `{ width = 0.85, height = 0.85, border = 'rounded' }` | Size (fractions) and border of the floating window. |
| `terminal.start_insert` | `true` | Enter terminal mode when agent.nvim opens or shows the terminal (`:Agent`, `:AgentOpen`, `open()`, a mention with `focus`). Moving into its window yourself keeps Normal mode. |
| `terminal.auto_close` | `true` | Close the terminal when the agent exits. An agent that exits non-zero within 5 s keeps its terminal open, so startup errors stay readable. |
| `selection.track` | `true` | Send the selection, the cursor and (Gemini) the open files to connected agents, when they change and when an agent connects. With `false` nothing is pushed; tools an agent calls itself (Copilot's `get_selection`, Claude's compatibility `getCurrentSelection`) still answer. |
| `selection.debounce_ms` | `100` | Debounce for selection events. |
| `diff.open_in` | `'tab'` | `'tab'` opens diffs in a new tab page. `'current'` opens an original/proposal window pair below the main window in the current tab page; when that tab page already shows a diff (another agent diff, `:diffsplit`, fugitive), the diff opens in a new tab page instead, since Neovim would merge them into one multi-way diff. |
| `diff.keymaps.accept` | `'<leader>aa'` | Normal-mode accept key, buffer-local in diff buffers. `''` or `false` disables it. |
| `diff.keymaps.reject` | `'<leader>ad'` | Normal-mode reject key, buffer-local in diff buffers. `''` or `false` disables it. |
| `agents.<name>.cmd` | e.g. `{ 'claude' }` | Executable and fixed leading arguments. |
| `agents.<name>.args` | `{}` | Extra arguments after `cmd`. The plugin's own arguments come after these. |
| `agents.<name>.env` | `{}` | Extra environment for the agent. A `false` value unsets a variable. |
| `agents.<name>.provider` | per agent | IDE server: `'claude'`, `'copilot'` or `'gemini'`. |
| `agents.<name>.mcp` | `true` | Register the $NVIM controller for this agent. |
| `agents.<name>.auto_approve` | `false` | Pre-approve the controller's tools for this agent. See [Security](#security). |
| `agents.opencode.line_offset` | `1` | Added to line (and column) numbers sent to OpenCode. Set it to `0` if a future OpenCode reads the Claude protocol's 0-based lines correctly. |
| `agents.opencode.scrub_vscode_env` | `true` | When Neovim runs in a VS Code terminal, blank `TERM_PROGRAM`, `TERM_PROGRAM_VERSION` and `GIT_ASKPASS` for OpenCode, which otherwise tries to install its VS Code extension. |
| `agents.gemini.skip_trust` | `false` | Pass `--skip-trust`: Gemini trusts the folder for this run. Gemini refuses stdio MCP servers (the controller) in untrusted folders. |
| `providers.<name>.enabled` | `true` | Disable an IDE server. Its agents still run, without IDE integration. |
| `providers.claude.port_range` | `{ min = 10000, max = 65535 }` | Ports tried (randomly) for the Claude/OpenCode WebSocket server. |
| `providers.copilot.trust_workspace` | `false` | Write `isTrusted = true` into Copilot lock files. **Security-relevant**, see [Copilot](#github-copilot-cli). May also be a `function(folder) -> boolean`. |
| `nvim_mcp.enabled` | `true` | Register the $NVIM controller at all. |
| `nvim_mcp.server_name` | `'nvim'` | MCP server name. It must match `^[A-Za-z0-9-]{1,24}$` and must not be `ide`, `workspace`, `claude-in-chrome`, `computer-use`, `shell`, `write` or `url`. |
| `nvim_mcp.timeout_ms` | `30000` | Timeout for each controller call into Neovim. |

### Optional keys

The modules also read these keys when you set them. They are not in the defaults table.

| Option | Default | Description |
|---|---|---|
| `agents.<name>.kind` | the agent name if it is one of `claude`, `opencode`, `copilot`, `gemini`; else `provider` | Launch recipe for a custom agent. |
| `agents.gemini.extension_dir` | `stdpath('data')/agent.nvim/gemini-extension` | Where the Gemini extension manifest is written (the link target). |
| `providers.claude.lock_dir` | `~/.claude/ide` | Lock directory. Claude also finds a lock in `$CLAUDE_CONFIG_DIR/ide`, but OpenCode only reads `~/.claude/ide`. |
| `providers.claude.notify_delay_ms` | `600` | Delay between a Claude Code connection and the first notification (Claude registers its handlers late). |
| `providers.claude.mention_timeout_ms` | `10000` | How long a mention waits for a client that is still connecting. |
| `providers.copilot.lock_dir` | `$COPILOT_HOME/ide`, else `~/.copilot/ide` | Lock directory. `COPILOT_HOME` set through `agents.copilot.env` is honored. |
| `providers.copilot.socket_dir` | `$TMPDIR`, then `/tmp` | Parent of the socket directory. The socket path must fit in 103 bytes (macOS) or 107 (Linux). |
| `providers.gemini.discovery_dir` | `<tmpdir>/gemini/ide` | Directory of the discovery file. |
| `providers.gemini.port` | `0` | Listening port; `0` picks one. A restart in the same Neovim reuses the previous port. |
| `providers.gemini.keepalive_ms` | `20000` | SSE keep-alive interval, capped at 30000. |
| `providers.gemini.context_debounce_ms` | `50` | Debounce for context updates. |
| `providers.gemini.max_open_files` | `10` | Files listed in context updates. |
| `providers.gemini.focus_diff` | `true` | Move the cursor into a diff when Gemini opens one. |
| `providers.gemini.orphan_grace_ms` | `5000` | Close a Gemini session's diffs when its stream has been gone this long. |
| `providers.gemini.idle_session_timeout_ms` | `300000` | Forget sessions whose stream went away this long ago. |
| `providers.gemini.export_env` | `false` | Also export `GEMINI_CLI_IDE_PID`, `GEMINI_CLI_IDE_SERVER_PORT` and `GEMINI_CLI_IDE_AUTH_TOKEN` into Neovim's environment, so a `gemini` you start in any `:terminal` connects to this Neovim. |

### Custom agents

Any extra entry under `agents` becomes an agent. It needs `cmd` and `provider`. Set `kind` when
the recipe is not the provider's name, for example an OpenCode wrapper (`provider = 'claude'`,
`kind = 'opencode'`).

```lua
require('agent').setup({
  agents = {
    ['claude-opus'] = { cmd = { 'claude', '--model', 'opus' }, provider = 'claude' },
    oc = { cmd = { 'opencode' }, provider = 'claude', kind = 'opencode' },
  },
})
-- :Agent claude-opus
```

## Agents

| | Claude Code | OpenCode | Copilot CLI | Gemini CLI |
|---|---|---|---|---|
| Selection | yes (`⧉ N lines selected`) | yes (shown as `file#3-5`) | yes (footer `@file:3-5`, attached to your next prompt) | yes (recent files, cursor and selected text) |
| @-mentions | protocol, `@file#L3-5` | protocol, `@file#3-5` | protocol, `@file:3-5` | typed, `@file (lines 3-5)` |
| Diffs in Neovim | yes, your edits are kept | no | yes, read-only proposal | yes, your edits are kept |
| Diagnostics | `getDiagnostics` (model tool `mcp__ide__getDiagnostics`) | no | `get_diagnostics`, `get_selection` (model tools `ide-get_diagnostics`, `ide-get_selection`) | no (use the controller's `get_diagnostics`) |
| One-time setup | none | none | none | `/ide enable` in Gemini, `:AgentGeminiSetup` |

A mention that the IDE connection cannot deliver is typed into the agent's prompt instead, as a
bracketed paste, in the agent's own syntax. Paths inside the agent's working directory are
relative; other paths are absolute.

A mention goes only to the agent in the target terminal, never to another agent's prompt:
- Claude and Copilot report their pid, which is matched against the terminal's job. If that
  agent is not connected yet, a Claude mention is queued for up to
  `providers.claude.mention_timeout_ms` after a launch of that kind, and a Copilot mention is
  retried for 15 s after the launch; otherwise it is typed.
- OpenCode reports no pid. The mention is sent when it is the only OpenCode client and no
  OpenCode was launched since it connected. Otherwise it is queued (after a recent OpenCode
  launch) or typed.
- An agent you started yourself (no agent.nvim terminal) gets mentions through the IDE
  connection, unless another agent of the same kind runs in an agent.nvim terminal.

### Claude Code

**How it connects.** Neovim listens for WebSocket connections on 127.0.0.1, on a random port in
`providers.claude.port_range`. It writes `~/.claude/ide/<port>.lock` (mode 0600) with a random
token and its workspace folders: the cwd, LSP workspace folders, and every agent's launch
directory. Claude is launched with `CLAUDE_CODE_SSE_PORT=<port>`, `FORCE_CODE_TERMINAL=true`,
`ENABLE_IDE_INTEGRATION=true`, `CLAUDE_CODE_IDE_SKIP_AUTO_INSTALL=true`, and the loopback
addresses added to `no_proxy`/`NO_PROXY`. It connects at startup. The port and token stay the
same for the whole Neovim session, so Claude reconnects on its own after a dropped connection.

**What works.**
- Selection: Claude shows the selection (`⧉ 2 lines selected`) and attaches it to your next
  prompt.
- @-mentions arrive as `@file#L3-5`.
- Diffs: when Claude's Edit or Write tool asks for permission, a diff opens in Neovim. You can
  edit the proposal before accepting; Claude writes exactly what you accept. The terminal prompt
  stays active too, and whichever answer comes first wins. At the start of every turn Claude
  closes the diffs it left open.
- Diagnostics: Claude takes a diagnostics baseline before each edit and reports new problems on
  later turns. The model can also call `mcp__ide__getDiagnostics`.
- The server also implements claudecode.nvim's other tools (`openFile`, `getCurrentSelection`,
  `getLatestSelection`, `getOpenEditors`, `getWorkspaceFolders`, `checkDocumentDirty`,
  `saveDocument`), which Claude Code 2.1.283 does not call.

**Limitations and caveats.**
- **Managed settings.** Claude exits at startup when it gets `--mcp-config` and an enterprise
  `managed-mcp.json` exists, or when managed settings set `disableSideloadFlags`. agent.nvim
  checks `managed-mcp.json`, `managed-settings.json` and `managed-settings.d/*.json` in
  `/Library/Application Support/ClaudeCode` (macOS), `/etc/claude-code` (Linux) or
  `C:\Program Files\ClaudeCode` (Windows), plus `$CLAUDE_CODE_MANAGED_SETTINGS_PATH`. If one
  blocks it, Claude is launched without the $NVIM controller and you get a warning. Policies
  delivered by MDM or from the server cannot be seen from Neovim. If Claude then exits within 5 s
  with such a message, a notification suggests `agents.claude.mcp = false`.
- Claude will not open a diff for a file that has unsaved changes in Neovim. Save (or discard)
  them first, or answer in the terminal.
- Diffs only appear when Claude asks for permission (not in auto-accept modes) and while Claude's
  `diffTool` setting is `auto`, its default.
- `CLAUDE_CODE_AUTO_CONNECT_IDE=false` in your environment stops Claude from connecting. The
  plugin warns about it; run `/ide` in Claude to connect by hand.
- Claude retries a dropped connection 5 times. After that, run `/ide`.

### OpenCode

**How it connects.** OpenCode uses the Claude IDE server (`provider = 'claude'`). It scans
`~/.claude/ide/*.lock`, picks the lock whose workspace folders contain its working directory, and
authenticates with the token from that lock. agent.nvim launches it with
`CLAUDE_CODE_SSE_PORT=""` and `OPENCODE_EDITOR_SSE_PORT=""`: when either holds a port, OpenCode
connects without the token, and the server rejects that. Right before the launch the lock is
rewritten, so that its modification time is the newest. When several Neovims serve the same
folder, OpenCode picks the newest lock.

**What works.**
- Selection: OpenCode shows the selection label (`file#3-5`) and attaches it to your next prompt.
- @-mentions arrive as `@file#3-5`. A whole-file mention is sent as lines 1 to N.

**Limitations.**
- OpenCode only receives: it never calls the IDE tools. There are no diffs in Neovim (OpenCode's
  edit tool writes files directly) and no diagnostics through the IDE connection. The $NVIM
  controller works.
- **Line offset.** The Claude protocol sends 0-based lines; OpenCode shows and reads them as
  1-based. agent.nvim adds `agents.opencode.line_offset` (default `1`) to what it sends to
  OpenCode.
- Directories cannot be @-mentioned through the protocol; they are typed into the prompt instead.
- Setting `providers.claude.lock_dir` to anything other than `~/.claude/ide` hides the lock from
  OpenCode.
- **Lock files.** OpenCode does not check whether a lock's process is alive, so a stale lock can
  make it dial a dead port. agent.nvim removes its own stale locks when the server starts. OpenCode
  retries forever (with a backoff up to 10 s) and reads the locks again on every attempt, so it
  finds a restarted server.

### GitHub Copilot CLI

**How it connects.** Neovim serves MCP over HTTP on a Unix socket,
`$TMPDIR/agentnvim-<random>/m.sock`, in a 0700 directory. Every request must carry the nonce from
the lock file. There is one lock per workspace folder, `~/.copilot/ide/<uuid>.lock` (or
`$COPILOT_HOME/ide`). Locks are written for Neovim's cwd when the server starts, for each launch
directory, and on `:cd`, and are never rewritten (Copilot treats any change to its lock as "IDE
gone"). Copilot connects on its own when its working directory equals a lock's folder, so
agent.nvim starts it in the resolved path (realpath) of the launch directory.

**What works.**
- Selection: the footer shows `@file:3-5`. When you submit a prompt with a non-empty selection,
  Copilot attaches it. The current selection is sent again whenever Copilot (re)connects.
- @-mentions insert `@file:3-5 ` into the prompt.
- Diffs: when Copilot shows a permission prompt for a file write, a diff opens in Neovim. The
  proposal is **read-only**: after an accept, Copilot writes its own content, so edits there would
  be lost. Accept or reject in Neovim, or answer in the terminal (the diff then closes). If you
  close the diff window without deciding, Copilot keeps waiting: answer its prompt in the
  terminal. No diff opens for writes that Copilot approves on its own, or when
  `ide.openDiffOnEdit` is `false` in Copilot's settings.
- Diagnostics: the model can call `ide-get_diagnostics` and `ide-get_selection`, which Copilot
  approves without asking.
- Session names: Copilot reports its session title. It is stored in the terminal's
  `b:agent_session_name`, and `User AgentSessionName` fires.

**Security note: `trust_workspace`.** With `providers.copilot.trust_workspace = true`, the locks
claim the folder is trusted. Copilot then skips its "Do you trust the files in this folder?"
prompt, **and loads the repository's own MCP servers, settings and hooks without asking**. Leave
it `false` unless you trust every folder you open, or pass a function that decides per folder:

```lua
providers = {
  copilot = {
    trust_workspace = function(folder) return vim.startswith(folder, vim.fn.expand('~/work/')) end,
  },
},
```

A lock is never rewritten, so a change takes effect only for folders locked afterwards.

**Limitations.**
- The server starts with the first Copilot launch (or at `setup()` with `auto_start`) and keeps
  its lock for Neovim's cwd until `:AgentStop!` or exit. Meanwhile any `copilot` started in that
  folder, even outside Neovim, connects to this Neovim. VS Code behaves the same way.
- When several IDEs serve the same folder, Copilot takes the first lock it finds. Use `/ide` in
  Copilot to choose.
- `ide.autoConnect = false` in `$COPILOT_HOME/settings.json` turns auto-connect off. Use `/ide`.
- The socket path must fit in 103 bytes (macOS) or 107 (Linux). `:checkhealth agent` shows the
  length; set `providers.copilot.socket_dir` to a short directory if it is too long.

### Gemini CLI

**How it connects.** Neovim serves MCP over HTTP on `127.0.0.1:<port>/mcp` and checks the
`Authorization: Bearer` token and the `Host` and `Origin` headers. It writes the discovery file
`$TMPDIR/gemini/ide/gemini-ide-server-<nvim pid>-<port>.json` (mode 0600) with
`ideInfo = { name = 'neovim', displayName = 'Neovim' }`, and with a `workspacePath` that
contains every Gemini launch directory. Gemini is launched with `GEMINI_CLI_IDE_PID`,
`GEMINI_CLI_IDE_SERVER_PORT`, `GEMINI_CLI_IDE_AUTH_TOKEN` and `GEMINI_CLI_IDE_WORKSPACE_PATH` (the
launch directory) set. These override values inherited from a VS Code terminal. When the Gemini
IDE server is disabled or not running, inherited `GEMINI_CLI_IDE_*` variables are set to `""` for
the job (Gemini treats that as unset), unless `agents.<name>.env` sets them.

**One-time setup.**
1. **IDE mode.** Gemini connects to an IDE only when `ide.enabled` is true in its settings, and
   no flag or environment variable can change that. Run `/ide enable` once inside Gemini; Gemini
   saves it in its own user settings. agent.nvim never writes your Gemini settings. It reads
   them and shows a hint while IDE mode is off. Answering "Yes" to Gemini's "connect Neovim?"
   prompt does **not** enable it (Gemini has no installer for Neovim).
2. **$NVIM controller.** Gemini has no per-run way to add an MCP server, so agent.nvim uses a
   linked Gemini extension. Run `:AgentGeminiSetup` once. It asks for confirmation, writes
   `stdpath('data')/agent.nvim/gemini-extension/gemini-extension.json`, and runs
   `gemini extensions link <dir> --consent` in a terminal, with `agents.gemini.env` applied (so a
   `GEMINI_CLI_HOME` set there is the Gemini home it links into and checks). The manifest is
   rewritten before every launch. Undo it with `gemini extensions uninstall agent-nvim`. The extension also loads
   in Gemini sessions outside Neovim; there it exposes no tools.

**What works.**
- Context: Gemini receives the recently focused files (up to 10), with the cursor and selected
  text of the active one.
- @-mentions: Gemini's protocol has none, so the reference is typed into the prompt as
  `@file (lines 3-5)`. Gemini's `@` includes the whole file; the range is plain text for the
  model. Spaces and special characters in the path are escaped.
- Diffs: when Gemini asks to confirm `write_file` or `replace`, a diff opens in Neovim. Accept
  there and Gemini writes the proposal, with your edits. Reject, or close the diff, and the tool
  call is cancelled. Answering in Gemini's prompt instead closes the diff; if you approve there,
  your Neovim edits are used. An empty proposal cannot be accepted, because Gemini would write
  the model's original proposal instead.
- Diagnostics: not part of the protocol. The model can use the controller's `get_diagnostics`.

**Limitations.**
- The controller is a stdio MCP server, and Gemini refuses those in untrusted folders. Trust the
  folder in Gemini, or set `agents.gemini.skip_trust = true` to pass `--skip-trust`.
- Gemini leaves IDE mode for good after 300 s without data on its stream, or after a single
  malformed message. agent.nvim sends a keep-alive every 20 s. If Gemini does disconnect, run
  `/ide enable` in it.
- If you pass `-e`/`--extensions` or `--allowed-mcp-server-names` without agent.nvim's entries,
  they are appended for you (server names are compared exactly, as Gemini does). `-e none`
  disables the controller.
- `mcp.allowed` or `mcp.excluded` in your Gemini settings can block the controller. agent.nvim
  computes them as Gemini does (the allowlists of every scope intersected, the exclusions joined)
  and shows a one-time info message when the server name is not allowed, unless you pass
  `--allowed-mcp-server-names`.
- Docker/Podman sandboxes (`--sandbox`) are not supported.
- Stopping the server, or quitting Neovim, closes open diffs without rejecting them, so Gemini's
  own prompt still decides.

## The $NVIM controller

The controller is a stdio MCP server that runs as

```
nvim --headless -u NONE -i NONE -n -l <plugin>/lua/agent/nvim_mcp/main.lua <address>
```

It connects to the Neovim that started the agent through its RPC address (the argument, else
`$NVIM`), and runs each tool call there with `nvim_exec_lua`. The parent Neovim does not need
agent.nvim loaded for this. Without an address (an agent started outside Neovim), it completes
the MCP handshake and lists no tools.

### Tools

All line numbers are 1-based and inclusive. A buffer can be given as a buffer number or a file
path (absolute, or relative to Neovim's cwd). "Current" means the buffer in the main editor
window, not the agent's terminal.

| Tool | Arguments | Result |
|---|---|---|
| `get_editor_state` | none | JSON: `cwd`, `mode`, `current {bufnr, path, filetype, modified, cursor {line, col}}`, `visual_selection {path, start_line, end_line, text}` or `null`, `windows [{winid, bufnr, path, is_current, is_terminal, is_floating}]`, `tabpage`, `buffer_count` |
| `list_buffers` | `include_unlisted?` | JSON list: `bufnr, path, name, filetype, buftype, modified, loaded, line_count, is_current` |
| `read_buffer` | `buffer?` (default: current), `start_line?` (default 1), `end_line?` (default -1, the last line) | Header `<path> (lines a-b of N)`, then numbered lines. Includes unsaved changes; a path with no buffer is read from disk. |
| `edit_buffer` | `buffer`, `start_line`, `end_line`, `text`, `save?` | JSON `{bufnr, path, line_count, modified, saved}`. Replaces the lines with `text` as one undoable change. `end_line = start_line - 1` inserts; `""` deletes. Terminal buffers are refused. |
| `open_file` | `path`, `line?`, `column?`, `end_line?`, `split?` (`none`, `horizontal`, `vertical`, `tab`) | JSON `{bufnr, winid, path}`. Opens in the main editor window (never in the agent terminal) and focuses it; `end_line` selects `line..end_line`. |
| `get_diagnostics` | `buffer?` (default: all buffers), `min_severity?` (`error`, `warning`, `info`, `hint`) | JSON list: `path, line, col, end_line, end_col, severity, message, source, code` |
| `execute_command` | `command` | The command's output, or `(no output)`. Runs in the context of the main editor window. |
| `eval` | `expression` | The Vimscript value as JSON. |
| `exec_lua` | `code`, `args?` | The chunk's return value(s) as JSON; `...` holds `args`. |
| `notify` | `message`, `level?` (`info`, `warn`, `error`) | `ok`; shows `vim.notify` in Neovim. |

A failed call returns an MCP error result with the message. If Neovim is waiting at a prompt
(hit-enter, `-- More --`), nothing runs and the agent is told to ask you to dismiss it. A call that
takes longer than `nvim_mcp.timeout_ms` fails; the request may still run later.

### How it is registered

For every launch, agent.nvim writes the registration into a private temp directory
(`stdpath('run')/agent.nvim/<pid>/sessions/<id>/`, mode 0700; files 0600). The directory is
deleted when the agent exits. Your agent config files are not edited.

| Agent | Registration | Tool names seen by the model | `auto_approve` adds |
|---|---|---|---|
| Claude Code | `--mcp-config=<file>` | `mcp__nvim__exec_lua` | `--allowedTools=mcp__nvim` |
| Copilot CLI | `--additional-mcp-config @<file>` | `nvim-exec_lua` | `--allow-tool=nvim` |
| Gemini CLI | the linked `agent-nvim` extension (`:AgentGeminiSetup`) | `mcp_nvim_exec_lua` | a `--policy` file allowing the server, after re-listing your own policy locations (a workspace's `.gemini/settings.json` only when Gemini trusts the folder) |
| OpenCode | `OPENCODE_CONFIG_CONTENT` (merged into an existing value, keeping its key order) | `nvim_exec_lua` | `permission: { "nvim_*": "allow" }`, appended after your rules |

The plugin's arguments come after yours, in `--opt=value` form. With another `server_name`, the
names change accordingly. `:checkhealth agent` shows them.

### Agents you start yourself

The controller finds Neovim through `$NVIM`, which Neovim sets in every `:terminal`. To use it
with an agent you start by hand in a Neovim terminal, register it once in that agent's own
config:

```vim
:AgentMcpConfig claude
```

This prints a config fragment for that agent, for example:

```json
{
  "mcpServers": {
    "nvim": {
      "type": "stdio",
      "command": "/opt/homebrew/bin/nvim",
      "args": ["--headless", "-u", "NONE", "-i", "NONE", "-n", "-l", "/path/to/agent.nvim/lua/agent/nvim_mcp/main.lua"]
    }
  }
}
```

It then says where it goes:
- Claude Code: merge it into `.mcp.json`. For Claude it also prints a ready-to-paste
  `claude mcp add-json nvim '<server object>'` command: `add-json` takes only the inner server
  object (`mcpServers.nvim`), not the whole fragment.
- Copilot CLI: merge it into `$COPILOT_HOME/mcp-config.json` (default
  `~/.copilot/mcp-config.json`).
- Gemini CLI: merge it into `~/.gemini/settings.json`, or just run `:AgentGeminiSetup`.
- OpenCode: merge it into `opencode.json`.

Outside a Neovim terminal the server lists no tools. For the IDE connection of an agent you
start yourself, set `auto_start = true` (or start the agent once with the plugin). Then:
- Claude: run `/ide`.
- OpenCode connects on its own when started inside one of the lock's folders; Copilot when
  started in exactly one of them (Neovim's cwd, or a folder an agent was launched in).
- Gemini connects at startup once IDE mode is enabled. Set `providers.gemini.export_env = true`
  so it picks this Neovim deterministically.

Once connected, `:AgentSend`, `:AgentAdd` and `mention()` reach a Claude, OpenCode or Copilot you
started yourself through the IDE connection, as long as no agent of the same kind runs in an
agent.nvim terminal. Gemini has no mention in its protocol, so it cannot get them.

### Security

- **The controller can do anything your Neovim can.** `exec_lua`, `execute_command` and `eval`
  run arbitrary Lua, Ex commands and Vimscript as you: shell commands (`:!`, `vim.system()`),
  reading and writing any file, reading unsaved buffers. Approving one of these calls is like
  approving a shell command.
- **`auto_approve` is opt-in** (default `false`). Without it, Claude, Copilot and Gemini ask
  before each controller call, following their own permission settings. With
  `agents.<name>.auto_approve = true`, or `open(name, { auto_approve = true })`, every controller
  tool is pre-approved for that run. OpenCode's built-in agents allow all tools unless your
  OpenCode `permission` config says otherwise, so there the controller runs without asking even
  without `auto_approve`.
- The controller opens no port. It talks to Neovim through Neovim's own RPC socket, which only
  your user can reach.
- To turn it off: `nvim_mcp.enabled = false` (all agents), `agents.<name>.mcp = false`, or
  `open(name, { mcp = false })`.
- The IDE servers listen only on 127.0.0.1 or on a Unix socket in a 0700 directory, and require
  their protocol's token (random, at least 128 bits). Lock and discovery files are mode 0600, are
  written atomically, and are removed when the server stops. Directories agent.nvim creates are
  0700, and it also tightens `~/.claude/ide` to 0700. The Copilot and Gemini directories
  (`~/.copilot/ide`, `$TMPDIR/gemini/ide`) belong to those CLIs too and are used as they are; if
  the CLI created them 0755, other users can list the lock names (not read them). Browser requests
  (an `Origin` header) are refused. As with VS Code and claudecode.nvim, any process running as
  your user can read a lock file and connect.

## Reviewing diffs

When an agent proposes a change, a new tab page opens (`diff.open_in = 'tab'`), or a window pair
below the main window (`'current'`; a new tab page when the current one already shows a diff):

- Left: the original. That is your buffer when it is loaded and matches the file on disk,
  otherwise a read-only copy of the file on disk (empty for a new file).
- Right: the proposal, a scratch buffer named `agent-diff://<id>`. The winbar shows the accept
  and reject keys.

| Action | How |
|---|---|
| Accept | `:w` in the proposal (or `:wq`), the accept key (`<leader>aa`), `:AgentDiffAccept`, `require('agent').diff_accept()` |
| Reject | the reject key (`<leader>ad`), `:AgentDiffReject`, closing the proposal or the tab (`:q!`, `:tabclose`) |

- The keys are buffer-local, and set only in the proposal and in a scratch copy of the original.
  Your own file buffer never gets them.
- For Claude and Gemini you can edit the proposal first; the agent writes what you accept.
  Copilot's proposal is read-only.
- agent.nvim never writes the target file itself. The agent writes it after an accept, and the
  buffer is reloaded when the file changes. That also happens when you approve in the agent's
  terminal prompt instead (the agent then closes the diff), and after Claude's edits in
  auto-accept mode (watched for 10 s from Claude's pre-edit diagnostics request).
- Files an agent changes without a diff (its shell commands, auto-approved edits) are reloaded
  when you leave the agent's terminal window or Terminal mode, and when the agent exits. Only
  unmodified buffers with `'autoread'` on (the default) are reloaded; buffers with unsaved
  changes are left alone.
- After the decision the diff is closed. If the diff had taken focus, the cursor goes back to the
  window you were in when it opened (for example the agent's terminal, in terminal mode).

## Events and variables

User autocommands (`nvim_create_autocmd('User', { pattern = ..., callback = function(ev) ... end })`,
data in `ev.data`):

| Pattern | When | `ev.data` |
|---|---|---|
| `AgentTerminalOpen` | An agent was started in a terminal. | `name, bufnr, job, pid, session_id` |
| `AgentTerminalExit` | An agent's job exited. | `name, code, bufnr, session_id` |
| `AgentSessionName` | Copilot reported a session name. | `provider ('copilot'), name, session, pid, terminal` |

```lua
vim.api.nvim_create_autocmd('User', {
  pattern = 'AgentTerminalExit',
  callback = function(ev) vim.notify(ev.data.name .. ' exited with ' .. ev.data.code) end,
})
```

Variables:

| Variable | Set on | Meaning |
|---|---|---|
| `b:agent_nvim_agent` | agent terminal buffers | The agent name. |
| `b:agent_nvim_session` | agent terminal buffers | The launch id, also in the agent's environment as `$AGENT_NVIM_SESSION`. |
| `b:agent_session_name` | Copilot terminal buffers | The session name Copilot reported. |
| `b:agent_diff_id` | diff proposal and scratch original buffers | The diff id. |
| `t:agent_diff` | diff tab pages | The diff id. |
| `b:agent_ignore` | set it yourself | When true, the buffer is not reported as a selection, an open file or a mention target. |
| `g:loaded_agent_nvim` | global | Load guard of `plugin/agent.lua`. |

Environment of the controller process: `NVIM`, `AGENT_NVIM_AGENT` (the agent kind),
`AGENT_NVIM_SESSION`, `AGENT_NVIM_TIMEOUT_MS`. Set `AGENT_NVIM_MCP_DEBUG=1` to make it log the
methods it receives to stderr.

## Troubleshooting

- **Start with `:checkhealth agent`.** Then `:AgentStatus` shows whether the agent's IDE server
  has a client.
- **Logs.** Only warnings and errors are shown. For details:

  ```lua
  require('agent').setup({ log_level = 'debug', log_file = vim.fn.stdpath('log') .. '/agent.log' })
  ```

- **An agent's terminal closes at once.** An agent that exits non-zero within 5 s keeps its
  terminal open, so you can read the error. `executable '<cmd>' not found` means `cmd[1]` is not
  on `$PATH`.
- **Claude does not connect.** Check `CLAUDE_CODE_AUTO_CONNECT_IDE` (health warns), then run
  `/ide` in Claude. With `providers.claude.lock_dir` set, check that the directory is one Claude
  scans.
- **Claude exits right away mentioning an enterprise MCP config or `disableSideloadFlags`.** A
  managed policy forbids `--mcp-config`. Set `agents.claude.mcp = false`.
- **OpenCode does not connect.** It must not see `CLAUDE_CODE_SSE_PORT` or
  `OPENCODE_EDITOR_SSE_PORT` with a value (the plugin blanks both), and the lock must be in
  `~/.claude/ide`. Its working directory must be inside one of the lock's folders.
- **Copilot does not connect.** Check `ide.autoConnect` in `$COPILOT_HOME/settings.json` and the
  socket path length in `:checkhealth agent`. Use `/ide` in Copilot to pick Neovim by hand.
- **Gemini does not connect.** Run `/ide enable` in Gemini (once). `/ide status` in Gemini shows
  the connection and the files it received.
- **Gemini has no `nvim` tools.** Run `:AgentGeminiSetup`, trust the folder (or set
  `agents.gemini.skip_trust`), and check `gemini mcp list`.
- **The controller says Neovim is waiting at a prompt.** Dismiss the prompt (hit-enter,
  `-- More --`, a confirm dialog) in Neovim and ask the agent to retry.
- **The controller is not registered: the server address contains `$`, `{` or `}`.** Agent config
  loaders would expand those characters. Start Neovim with a plain `--listen` address.
- **A diff does not open.** Claude refuses when the file has unsaved changes. Copilot and Gemini
  open diffs only when they ask for your confirmation (not in auto-approve, auto-edit or YOLO
  modes).
- **A mention went nowhere.** Right after a launch the IDE connection may not be up yet.
  Claude and OpenCode mentions are queued for up to 10 s (`providers.claude.mention_timeout_ms`)
  and dropped with a warning if the target agent does not connect. Copilot mentions are retried
  for 15 s and then typed into the prompt. Gemini mentions are typed once the terminal is 3 s old.
- **`could not write the Claude lock file: E739: ...`** (at `setup()` with `auto_start`, or when
  Claude or OpenCode starts). The lock directory (`providers.claude.lock_dir`, default
  `~/.claude/ide`) cannot be created, for example because a file is in the way. The Claude IDE
  server then does not start, and Claude and OpenCode run without IDE integration until the
  directory can be created.

## Protocol notes and credits

The Claude IDE protocol implementation follows
[coder/claudecode.nvim](https://github.com/coder/claudecode.nvim), whose Lua server and
`PROTOCOL.md` were the reference, checked against Claude Code 2.1.283. The Copilot `/ide` server
follows the Copilot CLI integration in [microsoft/vscode](https://github.com/microsoft/vscode)
and the IDE bridge of copilot-language-server. The Gemini server follows Gemini CLI's IDE client
and its VS Code companion in
[google-gemini/gemini-cli](https://github.com/google-gemini/gemini-cli). OpenCode's behaviour
comes from its TUI source.

[docs/PROTOCOLS.md](docs/PROTOCOLS.md) is the contributor reference: discovery, transport, auth,
tools, notifications and the verified quirks of each protocol, with the CLI versions they were
verified against.

## Running the tests

```sh
make test               # both suites below
./tests/run.sh          # Lua specs, each file in its own headless Neovim (NVIM_BIN=... to pick one)
./tests/run.sh tests/spec/init_spec.lua
make test-node          # protocol conformance tests with the official MCP SDK client (needs node and npm)
```

`make test-node` installs the test dependencies into `tests/node/node_modules` and runs
`node --test` there.

The live end-to-end test runs the real agent CLIs. It is not part of `make test`:

```sh
make test-e2e                        # every installed agent
make test-e2e AGENTS="claude copilot"
tests/e2e/run.sh gemini              # the same, directly
```

For each agent a headless Neovim opens the agent, waits for the IDE connection, sends an
@-mention, and submits a prompt. A scripted model turn then calls the $NVIM controller and
proposes an edit, which the driver accepts in the Neovim diff. Everything is isolated:
- `HOME`, the XDG directories, `CLAUDE_CONFIG_DIR`, `COPILOT_HOME` and `GEMINI_CLI_HOME` point to
  a temp directory, and the environment is rebuilt with `env -i`.
- Model turns come from a local fake endpoint (`tests/e2e/fake_model.mjs`, 127.0.0.1 only) or,
  for Gemini, from `--fake-responses-non-strict`.
- The workspaces are temp directories.

The header of `tests/e2e/run.sh` documents the variables for pointing it at other CLI builds
(`E2E_CLAUDE_BIN`, `E2E_COPILOT_BIN`, `E2E_GEMINI_JS`, `E2E_OPENCODE_BIN`) and for keeping the
logs (`E2E_KEEP=1`).
