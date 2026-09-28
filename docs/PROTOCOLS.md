# Protocol reference

This is the contributor reference for the wire protocols agent.nvim implements: what each agent
CLI expects from the IDE server that Neovim hosts, how agents are launched, and how the $NVIM
controller is registered. None of these protocols is fully documented upstream. Everything here
was taken from the CLIs' code and verified against real CLI runs. Behaviour that was only read in
the code, and never observed live, is marked **unverified**.

| Protocol | Clients | Verified against |
|---|---|---|
| Claude IDE (WebSocket MCP) | Claude Code, OpenCode | Claude Code 2.1.283; OpenCode 1.18.32 |
| Copilot `/ide` (Streamable HTTP over a Unix socket) | GitHub Copilot CLI | Copilot CLI 1.0.88 |
| Gemini IDE companion (Streamable HTTP over TCP) | Gemini CLI | Gemini CLI 0.61.0 (also 0.59.0, 0.50.0; source read at 0.63.0-nightly) |
| $NVIM controller (stdio MCP) | all four | the versions above |

Neovim 0.12.5 was used throughout. Re-verify after upgrading a CLI: all four have changed these
protocols between releases.

Code map: `lua/agent/providers/claude.lua`, `copilot.lua` and `gemini.lua` implement the three
IDE servers. They share the MCP core `lua/agent/mcp/server.lua`, the Streamable HTTP binding
`mcp/streamable_http.lua`, and the `net/http.lua` and `net/websocket.lua` servers.
`lua/agent/agents.lua` builds launch specs, and `lua/agent/nvim_mcp/` is the controller.

## Conventions and pitfalls common to all protocols

- **JSON.** `vim.json.encode({})` produces `[]`. Every JSON object that can be empty (capabilities,
  `ping` results, `params`, `properties`, `structuredContent`) must be `vim.empty_dict()`. Gemini
  and the MCP SDKs reject `[]` there. `null` decodes to `vim.NIL`. When a field must be present as
  `null`, encode `vim.NIL`. Neovim 0.11+ does not escape `/`, and both forms are valid JSON.
- **Protocol versions.** Echo the client's `initialize.params.protocolVersion` only if it is in
  the server's known list. Otherwise answer a fixed version the client accepts (per protocol,
  below).
- **Never answer notifications or client responses.** Unknown requests get JSON-RPC `-32601`.
  A message with `"id": null` is an invalid request, not a notification (the MCP core keeps a
  top-level null id as `vim.NIL` when decoding, `McpServer.decode`). Streamable HTTP answers it
  with 400 `{"jsonrpc":"2.0","id":null,"error":{"code":-32600,...}}`, also inside a batch; on the
  Claude WebSocket it is logged and dropped, like other invalid messages without a usable id.
- **Positions.** Each protocol has its own line base. The Claude and Copilot protocols use 0-based
  lines. OpenCode reads Claude-protocol lines as 1-based. Gemini's cursor is 1-based. The
  controller's tools are 1-based and inclusive. Columns are byte offsets except where noted
  (Copilot and Gemini use UTF-16 when the buffer is loaded).
- **Selection.** `lua/agent/editor/selection.lua` feeds all four protocols (the pushed
  notifications and the pull tools). Files are reported by their path, and so are buffers named
  after a file on disk (`:help` files). Other buffers (a terminal other than the agent's, a
  quickfix list, a file explorer, a scratch buffer) are reported as `nvim://buffer/<n>/<label>`
  (label: the terminal's program, else the filetype, else the name's last part, else `scratch`;
  valid UTF-8 of at most 64 bytes), which the controller's `read_buffer` reads. Such a buffer's
  cursor is not reported: with no selection it is sent at line 0, character 0 (empty), so a
  terminal whose cursor follows its output sends nothing new; a Visual selection in it is sent
  with its range. Ignored, so that the previous context stays: the agent's terminal,
  `agent-diff://` buffers (a diff's proposal, and the read-only copy of the original shown when
  the user's buffer cannot be; a left side that is the user's own buffer of the file is reported
  as that file), `b:agent_ignore`, a buffer that is not a file in a floating window (a file in a
  floating window is reported), and the command-line window. When Visual mode ends, the
  selection is held for `DEMOTE_MS` (50 ms). If a reported window then has focus (`<Esc>`, `y`,
  `d`, a click in the file, another terminal), it is replaced by that window's cursor, sent as an
  empty selection (Gemini: no `selectedText`). A cursor move or text change during the grace
  period drops it at once. If focus went straight to an ignored window (`<C-w>l` to the agent
  terminal, `<cmd>AgentToggle<cr>`, a floating picker), it is kept until a reported window has
  focus again. A change to its text drops it even then, except in a terminal: the user cannot
  edit one, and its text changes with the output and with its size (the agent's split opening
  reflows long lines and removes blank rows), so the selection is kept as captured. Re-entering
  Visual mode cancels the drop. A command line opened from Visual mode pauses the grace period,
  which restarts once the command has run.
- **Blocking tools.** A diff tool that waits for the user must be answered asynchronously. Never
  block the Neovim UI. Everything that runs in a libuv callback goes through `vim.schedule`.
- **Files.** Lock and discovery files are mode 0600. They are written atomically (temp file plus
  rename) and removed on stop and on `VimLeavePre`. Directories agent.nvim creates are 0700, and
  `~/.claude/ide` is chmod'ed to 0700 when it is ours. `~/.copilot/ide` and `<tmpdir>/gemini/ide`
  are shared with the CLIs and used with the mode they have (Copilot creates its directory 0755,
  so other users can list, not read, the lock names).
- **Server lifetime.** agent.nvim runs one agent at a time. A provider starts when an agent that
  uses it is launched (or at `setup()` with `auto_start`). When that agent stops (`:AgentStop`,
  a replace by another agent, or the process exiting), its provider stops too, unless
  `auto_start` is on; then every provider keeps running for agents started outside Neovim.
  `teardown()` and `VimLeavePre` stop every provider.
- **Environment for jobs.** `jobstart(..., { env = ... })` only extends the environment.
  Unsetting a variable needs `clear_env = true` with a copy of `vim.fn.environ()`. That copy
  **must not contain `NVIM`**: `environ()` holds the `NVIM` this Neovim inherited (nested
  Neovim), and an explicit `env.NVIM` overrides Neovim's own injection of `v:servername`. Where
  the target treats an empty value as unset (OpenCode, Gemini's stdio variables), set `""`
  instead.

---

## 1. Claude IDE protocol (Claude Code and OpenCode)

One server, `agent.providers.claude`, serves both clients. The client kind comes from
`initialize.params.clientInfo.name` (`claude-code` or `opencode`; anything else is treated as
Claude Code).

### Discovery

- The lock file is `<dir>/<port>.lock`, where `<port>` is the decimal TCP port. Only names ending
  in `.lock` are considered. Contents:

  ```json
  {"pid": 12345, "workspaceFolders": ["/abs/project"], "ideName": "Neovim",
   "transport": "ws", "authToken": "<32 hex chars>"}
  ```

  - `transport` must be `"ws"`. Any other value sends Claude to a legacy SSE transport and makes
    OpenCode skip the lock.
  - `pid` is Neovim's pid. Claude deletes locks whose pid is dead, and also deletes locks it cannot
    read, so writes must be atomic.
  - `workspaceFolders` holds `getcwd()`, the LSP workspace folders, the realpath of the cwd, and
    the cwd (literal and realpath) of the last Claude or OpenCode launched; each launch replaces
    the previous one's. OpenCode compares against its **physical** cwd and never resolves
    symlinks. Without the realpath entry, a symlinked cwd never matches.
- **Directory.** Always `~/.claude/ide` (0700). Claude 2.1.283 scans `$CLAUDE_CONFIG_DIR/ide`
  (default `~/.claude/ide`), and also `~/.claude/ide` whenever `CLAUDE_CONFIG_DIR` is set.
  OpenCode scans only `~/.claude/ide` and ignores `CLAUDE_CONFIG_DIR`.
  - Never write two locks for the same port in two scanned directories. Claude's matching then
    counts two candidates and never connects (read in the code, unverified).
  - `providers.claude.lock_dir` overrides the directory, for tests. A lock in `$CLAUDE_CONFIG_DIR/ide`
    was verified to work for Claude.
- **How Claude chooses.** Launched with `CLAUDE_CODE_SSE_PORT=<port>`, Claude picks the lock
  whose port matches and skips the workspace and ancestor-pid checks for it. It polls the lock
  directories every 1 s for up to 30 s at startup, then connects **once**. A failed handshake is
  not retried; the user must run `/ide`.
- **How OpenCode chooses.** It reads `CLAUDE_CODE_SSE_PORT || OPENCODE_EDITOR_SSE_PORT` once at
  startup. If either holds a valid port, it connects there **without the token**, which the server
  rejects. Otherwise it scans the lock files:
  - It keeps locks whose `workspaceFolders` contain its directory. The score is the length of the
    longest containing folder, and ties go to the newest mtime.
  - It does not check the pid, so stale locks can win.
  - agent.nvim therefore sets both variables to `""` for OpenCode, and rewrites the lock right
    before spawning it (`before_spawn`), so that this Neovim's lock is the newest.
- **Lifetime.** The lock is written after the socket is listening and before the agent starts.
  It is rewritten on `DirChanged`, `LspAttach` and `LspDetach`, keeping the same port and token. At
  start the server removes stale locks: `ideName` `Neovim` and a dead pid. Other IDEs' locks are
  left alone.

### Transport

- WebSocket (RFC 6455) on `127.0.0.1` only. The port is random within
  `providers.claude.port_range`.
- **The port and token stay the same for the whole Neovim session.** A `stop()`/`start()` rebinds
  the same port. After a dropped connection Claude reconnects up to 5 times with the same URL
  and token (backoff `min(1000 * 2^(n-1), 30000)` ms). OpenCode reconnects forever (backoff up to
  10 s) and re-reads the locks on every attempt.
- Upgrade request from Claude 2.1.283 (captured):
  ```
  GET / HTTP/1.1
  Upgrade: websocket
  Sec-WebSocket-Protocol: mcp
  Sec-WebSocket-Extensions: permessage-deflate; client_max_window_bits
  User-Agent: claude-code/2.1.283 (cli)
  X-Claude-Code-Ide-Authorization: <token>
  ```
  OpenCode 1.18.32 sends no `Sec-WebSocket-Protocol` and no `User-Agent`, offers
  permessage-deflate, and sends the header in lowercase (`x-claude-code-ide-authorization`).
- **Echo `Sec-WebSocket-Protocol: mcp` when it is offered.** This is mandatory. Without it,
  Claude drops the socket right after the 101 and never sends `initialize` (verified). Send no
  subprotocol when none was offered (OpenCode).
- Never send `Sec-WebSocket-Extensions` (decline compression). Each server message is one
  unmasked text frame. Client frames are masked text. Fragmented messages are reassembled; the
  limit is 100 MiB (`openDiff` carries whole files).
- Text frames must be valid UTF-8 (strict clients such as Node's `ws` close the connection
  otherwise). Strings that are not (a `++bin` buffer, a non-UTF-8 file name) are sent with U+FFFD
  in place of each invalid byte.
- The server pings every 30 s; a peer silent for two intervals is closed with 1001. On shutdown
  it sends close 1001.

### Auth

- The `X-Claude-Code-Ide-Authorization` header (case-insensitive) must equal the lock's
  `authToken`, compared in constant time. The token is 16 random bytes, hex-encoded. A missing or
  wrong token gets 401, and neither client distinguishes 400 from 401.
- A request with an `Origin` header gets 403 (neither CLI sends one; browsers always do).

### MCP handshake

Claude 2.1.283, in order (captured):

```json
{"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{"roots":{"listChanged":true},"elicitation":{}},"clientInfo":{"name":"claude-code","version":"2.1.283"}},"jsonrpc":"2.0","id":0}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","method":"ide_connected","params":{"pid":5077}}
{"method":"tools/list","jsonrpc":"2.0","id":1}
```

- `initialize` result: `{protocolVersion, capabilities: {tools: {listChanged: true}},
  serverInfo: {name: "agent-nvim", version}}`.
  - Echo the requested version if it is one of `2025-11-25`, `2025-06-18`, `2025-03-26` or
    `2024-11-05`. Otherwise answer `2024-11-05`.
  - Claude rejects versions outside `2025-11-25` … `2024-10-07`.
  - Never use `serverInfo.name = "Claude Code JetBrains Plugin"`, which disables Claude's
    diagnostics baseline.
- `ide_connected.pid` is Claude's pid. agent.nvim only records it (the provider's `clients()` and
  `status()`).
- Claude registers its notification handlers **after** the connection completes, and drops
  earlier notifications. The server waits 600 ms after the last of `notifications/initialized`,
  `ide_connected` and `tools/list` before the first notification. OpenCode can be notified right
  after `initialize`.
- The IDE handshake uses no `server/discover` probe.
- OpenCode sends only `initialize` (`clientInfo {name: "opencode", version: "0.0.0"}`) and
  `notifications/initialized`. It never calls a tool.
- Unknown tool: `-32602 "Unknown tool: X"`. `ping`: `{}`.

### Tools

Claude 2.1.283 calls only four tools itself. The model sees `getDiagnostics` (as
`mcp__ide__getDiagnostics`) and `executeCode`, which agent.nvim does not implement. The server
name `ide` is reserved by Claude.

| Tool | Called | Contract |
|---|---|---|
| `openDiff` `{old_file_path, new_file_path, new_file_contents, tab_name}` | On Edit/Write permission prompts, racing the terminal prompt | **Blocking.** Answer once the user decides. Accept: `content = [{text:"FILE_SAVED"}, {text:<entire final text>}]`. Claude requires the second item and writes that text, so user edits are honored. Reject: `[{text:"DIFF_REJECTED"}, {text:<tab_name>}]`, and the turn is aborted. Never return `TAB_CLOSED` from `openDiff`: Claude reads it as "accept unchanged". If the target has unsaved changes in Neovim: error `-32000 "Cannot create diff: file has unsaved changes"`, and Claude falls back to the terminal. The server never writes the file. |
| `close_tab` `{tab_name}` | Twice after every `openDiff` outcome, and on abort | Always `[{text:"TAB_CLOSED"}]`, idempotent. A pending diff with that name is rejected. Hidden from `tools/list`, but callable. |
| `closeAllDiffTabs` `{}` | At the start of every user turn | `[{text:"CLOSED_<n>_DIFF_TABS"}]`. Closes only the calling session's pending diffs, and never other plugins' diff windows. |
| `getDiagnostics` `{uri?}` | `{uri}` before an edit (500 ms timeout; three timeouts disable baselines for the session); `{}` on later turns (2000 ms) | One text item holding a JSON array `[{uri, diagnostics:[{message, severity:"Error"\|"Warning"\|"Info"\|"Hint", range:{start,end} (0-based), source?, code? (string)}]}]`. The `uri` must be `"file://" .. <raw path>`, **not percent-encoded**: Claude only strips the prefix. Echo the request's `uri`. A file with no buffer gets `[{uri, diagnostics:[]}]`, not an error. Must be fast and synchronous. |

The compatibility tools `openFile`, `getCurrentSelection`, `getLatestSelection`, `getOpenEditors`,
`getWorkspaceFolders`, `checkDocumentDirty` and `saveDocument` follow claudecode.nvim. No Claude
2.1.283 code path calls them.

Observed with 2.1.283 in a live model turn: `closeAllDiffTabs` came first, then `openDiff`, then
`close_tab` twice. Claude wrote the accepted text. The `getDiagnostics {uri}` baseline arrived
after `openDiff` and `close_tab`, right before the write.

### Notifications (server to client)

- `selection_changed` `{text, filePath, fileUrl, selection: {start: {line, character}, end: {line, character}, isEmpty}}`
  - Lines are 0-based. Claude computes `lineCount = end.line - start.line + 1`, minus 1 when
    `end.character == 0`. A linewise selection whose last line is empty is therefore sent as
    `end = {line: last + 1, character: 0}`.
  - A cursor-only selection has `text: ""`, which Claude shows as "opened file".
  - A buffer that is not a file goes by its id in both fields: `filePath` and `fileUrl` are
    `nvim://buffer/<n>/<label>` (no `file://`). Claude shows the basename ("In sh", "2 lines
    selected") and its attachments name the id: "The user opened the file nvim://buffer/3/sh in
    the IDE." and "The user selected the lines 1 to 2 from nvim://buffer/3/sh: ..." (2.1.284, live
    with the fake model). The controller's `instructions` tell the model to read such a path with
    `read_buffer`; it did. OpenCode gets the same id, with `line_offset` as usual. With no
    selection it is sent at `{line: 0, character: 0}` (empty) wherever its cursor is, so that a
    terminal whose cursor follows its output is not resent on every debounce.
  - Never send `selection: null`, and never send a `source` key (OpenCode drops the message).
  - Sent to a client when it becomes ready and on every change. With `selection.track = false`
    nothing is sent, not even on connect. The pull tools `getCurrentSelection` and
    `getLatestSelection` still answer.
- `at_mentioned` `{filePath, lineStart?, lineEnd?}` is part of the protocol, but **agent.nvim does
  not send it**: `selection_changed` is the only context it pushes. For reference:
  - Lines are 0-based. Claude inserts `@<relative path>#L<a>[-<b>] `. Both keys are omitted
    (never `null`) for a whole file or a directory.
  - OpenCode requires both lines, treats them as **1-based**, and inserts `@<path>#<a>[-<b>]`, so
    a whole file would be lines 1..N. It has no form for a directory.

| Aspect | Claude Code | OpenCode |
|---|---|---|
| First notification | at least 600 ms after the connection completes | right after `initialize` |
| Lines and characters | 0-based | + `agents.opencode.line_offset` (default 1) |
| Tools and diffs | yes | none; OpenCode's edit tool writes files directly |

### Launch environment

- Claude: `CLAUDE_CODE_SSE_PORT=<port>` (required), `FORCE_CODE_TERMINAL=true`,
  `ENABLE_IDE_INTEGRATION=true` (unused by 2.1.283, kept for older builds),
  `CLAUDE_CODE_IDE_SKIP_AUTO_INSTALL=true`, and `no_proxy`/`NO_PROXY` extended with
  `localhost,127.0.0.1,::1` (Claude's WebSocket honours proxy variables).
  `CLAUDE_CODE_AUTO_CONNECT_IDE=false` in the user's environment disables auto-connect, and the
  plugin warns about it.
  - `FORCE_CODE_TERMINAL` is truthy even as `"false"`. Inside a VS Code or JetBrains terminal it
    would make Claude try to install its extension, which `CLAUDE_CODE_IDE_SKIP_AUTO_INSTALL`
    prevents.
- OpenCode: `CLAUDE_CODE_SSE_PORT=""`, `OPENCODE_EDITOR_SSE_PORT=""` (empty strings are falsy
  there), and the loopback `no_proxy`. With `agents.opencode.scrub_vscode_env`, it also blanks
  `TERM_PROGRAM`, `TERM_PROGRAM_VERSION` and `GIT_ASKPASS` when they were inherited from VS Code.
- These are set per job, never in `vim.env`, so other terminals do not inherit a port.

---

## 2. GitHub Copilot CLI `/ide` protocol

Implemented by `agent.providers.copilot`.

### Discovery

- The lock is `<COPILOT_HOME or ~/.copilot>/ide/<uuid-v4>.lock`. Temp files must not end in
  `.lock`. The directory must come from the environment the launched CLI will have, so
  `COPILOT_HOME` from `agents.copilot.env` counts. Contents (compact JSON is accepted):

  ```json
  {"socketPath": "/tmp/agentnvim-<hex>/m.sock", "scheme": "unix",
   "headers": {"Authorization": "Nonce <64 hex chars>"}, "pid": 12345,
   "ideName": "Neovim", "timestamp": 1790439034748,
   "workspaceFolders": ["/private/tmp/project"], "isTrusted": false}
  ```

  - The CLI validates it with a zod schema. Every field except `isTrusted` is required.
  - `headers` are sent verbatim on every request.
  - `timestamp` is in milliseconds. A lock younger than 2 s gets a patient socket probe (up to
    1000 ms); an older one gets a single 250 ms connect attempt.
  - `scheme` is not read (it is `"pipe"` on Windows).
- **How the CLI chooses.** It lists the `*.lock` files in readdir order and drops those that fail
  to parse (3 tries, 100 ms apart), have a dead pid, or whose socket refuses a connection. It
  then auto-connects to the **first** entry whose `workspaceFolders[i]` equals its
  `process.cwd()`. That cwd is the physical path: symlinks are not resolved (`/tmp/x` does not
  match `/private/tmp/x`), and a trailing slash is ignored. While not connected, it also watches
  the directory (200 ms debounce), so a lock written after startup is picked up.
  - Auto-connect needs `ide.autoConnect` not `false` in `$COPILOT_HOME/settings.json`.
  - No flag or environment variable selects an IDE.
  - agent.nvim writes the realpath (plus the literal cwd when it differs), and starts `copilot`
    with `cwd` = that realpath.
- **Never rewrite a lock while connected.** On macOS, any change to the CLI's own lock file
  (in-place write or rename) is reported as "lock file deleted": the CLI drops the connection
  without a DELETE and reconnects about 220 ms later with the same `X-Copilot-Session-Id`.
  agent.nvim writes **one lock per workspace folder** and never rewrites it:
  - at server start (Neovim's cwd);
  - per launch directory;
  - on `DirChanged` (global; skipped with `'autochdir'`).
  Creating a sibling lock is harmless.
- Deleting the lock is how the CLI notices that the IDE is gone ("IDE connection lost: Neovim
  closed"). Locks are deleted before the socket is closed.
- Stale-lock cleanup: only locks with `ideName` `Neovim` whose pid gives ESRCH.
- **`isTrusted: true` skips the CLI's folder-trust prompt, and loads the repository's MCP servers,
  settings and hooks without asking.** It is opt-in (`providers.copilot.trust_workspace`).

### Transport

- HTTP/1.1 over a Unix-domain socket (a named pipe on Windows) at path `/mcp`, speaking MCP
  Streamable HTTP. The socket is `<$TMPDIR or /tmp>/agentnvim-<hex>/m.sock`, in a 0700
  directory, mode 0600.
  - `sun_path` allows 103 usable bytes on macOS and 107 on Linux. Bind with
    `bind2(path, {no_truncate = true})`: `pipe:bind` silently truncates long paths on macOS.
- Client behaviour (Node `http` over the socket, 1.0.88):
  - **Every POST body is `Transfer-Encoding: chunked`, with no `Content-Length`.** Never answer
    411.
  - Connections are keep-alive and reused, but requests are not pipelined.
  - Concurrent requests (e.g. `close_diff` while `open_diff` is pending) use separate
    connections, so handling must not be serialized across connections.
  - The discovery probe opens a connection and closes it without sending anything; handle that
    quietly.
- Request headers: `authorization`, `x-copilot-session-id` (stable across reconnects of one CLI
  session), `x-copilot-pid`, `x-copilot-parent-pid`, `mcp-session-id` (after the first response
  that carried one), `host: localhost`. The CLI **never** sends `mcp-protocol-version`, so do not
  require it.
- POST replies may be JSON or SSE. agent.nvim answers synchronously with JSON. A pending async
  call (`open_diff`) switches to SSE, with `: keepalive` comments every 15 s. A POST carrying only
  notifications or responses gets **202**. The 202 for `notifications/initialized` is what makes
  the client open its GET stream.
- `GET /mcp` is the server-to-client SSE stream. Notifications can only go there; one sent while
  no stream is open is dropped. Send `event: message` + `data:` events, without `id:` lines.
  After a graceful end, the client re-GETs up to 2 times.
- `DELETE /mcp` ends the session. The CLI sends it on `/ide` disconnect, before every reconnect,
  and on clean exit.

### Auth

The `Authorization` header must equal the lock's `Nonce <secret>` (constant-time compare). A
missing or wrong value gets 401 `Unauthorized`. The `Host` check is optional over a Unix socket
and not implemented.

### MCP handshake

1. **`server/discover`** (MCP 2026-07-28 probe, since 1.0.81) is the first request of every
   connection. It carries no session.
   - Answer **HTTP 200 with JSON-RPC `-32601`, and no `mcp-session-id` header**. The CLI then
     falls back to `initialize` within milliseconds.
   - A 400 or 404 (the VS Code and copilot-language-server behaviour) costs a 10 s timeout on
     every connect.
   - Never answer it successfully: that switches the client to a protocol version nobody
     implements.
2. `initialize` (protocol `2025-11-25`, `clientInfo {name: "copilot-cli"}`, header
   `X-Copilot-Session-Id`). Reply with `mcp-session-id: <random uuid>`,
   `capabilities: {tools: {listChanged: true}}` and
   `serverInfo: {name: "agent-nvim-copilot-cli", title: "Neovim Copilot CLI", version: "0.0.1"}`
   (this name was accepted live). Echo `2025-11-25`, `2025-06-18`, `2025-03-26` or `2024-11-05`;
   otherwise answer `2025-11-25`.
3. `notifications/initialized` gets 202; then the client sends `GET /mcp` and `tools/list`.
4. At startup the CLI usually sends `DELETE`, then repeats steps 1-3 with the **same**
   `X-Copilot-Session-Id`, once or twice (trust or MCP-config reload).
   - An `initialize` whose `X-Copilot-Session-Id` is held by a session with no open GET stream
     takes that session over (the copilot-language-server rule).
   - Otherwise the answer is 409, and its body must contain
     `A connection for this session already exists`.
   - VS Code always answers 409, so the CLI never reconnects after a lock event.
5. A session whose stream is gone and that has nothing pending expires after 5 minutes.

### Tools

Every result is one text item holding JSON. The CLI exposes only `get_diagnostics` and
`get_selection` to the model (as `ide-get_diagnostics` and `ide-get_selection`, auto-approved).
The server name `ide` is reserved.

| Tool | Contract |
|---|---|
| `get_selection` `{}` | `{text, filePath, fileUrl, selection {start, end, isEmpty}, current}`. `current` is true for the active editor: the current window when it is reported (a file, or a terminal as `nvim://buffer/<n>/<label>` in both `filePath` and `fileUrl`), or, while an ignored window such as the agent terminal has focus, the last reported buffer (the last focused file, or a terminal focused since) if it is still shown in the current tab page and selection tracking is on. Otherwise the cached selection with `current: false`, or `null`. |
| `get_diagnostics` `{uri?}` | `[{uri, filePath, diagnostics: [{message, severity: "error"\|"warning"\|"information"\|"hint", range, source?, code?}]}]`, only files with diagnostics. |
| `open_diff` `{original_file_path, new_file_contents, tab_name}` | **Blocking, with no timeout on either side.** Resolve with `{success: true, result: "SAVED"\|"REJECTED", trigger, tab_name, message}`. `success`, `result`, `trigger` and `message` are all required, or the result is ignored. After `SAVED` **the CLI writes `new_file_contents` itself**, so edits to the proposal would be lost: the proposal is read-only. `trigger` is one of `accepted_via_button`, `rejected_via_button`, `closed_via_tool`, `client_disconnected`. |
| `close_diff` `{tab_name}` | Sent when the user answers in the terminal (and on interrupt). Resolves the pending `open_diff` with `REJECTED`/`closed_via_tool`, and returns `{success, already_closed, tab_name, message}`. |
| `update_session_name` `{name}` | `{success: true}`. Called with the session title (after the first prompt, and on title changes). |
| `get_vscode_info` `{}` | Parity only; never called. |

- `open_diff` is sent only when the CLI shows an interactive permission prompt for a write, and
  only while `ide.openDiffOnEdit` is not `false`. The terminal prompt races it.
- If the user closes the diff UI without deciding, the call stays pending: VS Code does the same,
  and the terminal prompt stays in charge. The later `close_diff` answers it.
- A session that ends (DELETE, takeover, expiry) with a diff pending gets its UI dismissed.
- After `close_diff` the target is watched for 5 s, and its buffers reload when the CLI writes
  it. The file is compared with its state when `open_diff` arrived, so a write that lands before
  `close_diff` is handled still reloads the buffers.

### Notifications (on the GET stream only)

- `selection_changed` `{text, filePath, fileUrl, selection: {start, end, isEmpty}}`. All fields
  are required, and lines are 0-based. Not sent (not even replayed) with
  `selection.track = false`. A buffer that is not a file has `filePath` = `fileUrl` =
  `nvim://buffer/<n>/<label>`; its characters are UTF-16 from the buffer's lines, as for a file.
  With no selection it is sent at line 0, character 0 (empty), wherever its cursor is.
  1.0.88 attaches such a selection as `File: nvim://buffer/3/sh (lines 1-2)` (live, with the fake
  model), and its model read the buffer with `nvim-read_buffer`.
  - The footer shows `@file:L1[-L2]`. A non-empty selection is attached to the next prompt
    automatically.
  - It is sent to every session, and replayed when a GET stream opens (the CLI clears its cache on
    every reconnect).
  - Do not send an empty selection just because focus moved into the terminal.
- `add_file_reference` `{filePath, fileUrl, selection: {start, end} | null, selectedText: string | null}`
  is part of the protocol, but **agent.nvim does not send it**. For reference: `selection` and
  `selectedText` must be present even when null, otherwise the message is dropped, and the CLI
  inserts `@<relative path>[:L1[-L2]] ` into its prompt.
- `diagnostics_changed` and `add_selection` are not sent either. 1.0.88 has no handler for the
  first, and the second is an alias of `add_file_reference`.

---

## 3. Gemini CLI IDE companion protocol

Implemented by `agent.providers.gemini`. The protocol strings have been stable from Gemini 0.40
to 0.63-nightly.

### IDE mode

- Gemini connects only when `ide.enabled` is true in its merged settings. No flag or environment
  variable sets it. The only runtime switch is `/ide enable` (or `/ide install`), which writes the
  user settings file.
  - The connection is attempted at startup and on `/ide enable`, **never automatically after a
    disconnect**.
- `GEMINI_CLI_SYSTEM_DEFAULTS_PATH` (a private `{"ide":{"enabled":true}}`) worked up to 0.59.
  Since 0.60 Gemini skips any system settings file that is not root-owned, with a visible
  warning. agent.nvim therefore only reads the settings (system defaults, then user, then system
  overrides, under `GEMINI_CLI_HOME` when set) and shows a hint.
  - It skips the system files Gemini >= 0.60 skips as insecure (on POSIX: the file, its
    ancestors and their realpaths must be root-owned and not group- or other-writable), for
    `ide.enabled`, `policyPaths`, folder trust and the MCP allow/exclude lists.
  - `GEMINI_CLI_HOME` comes from the environment the agent gets: `agents.gemini.env` counts, for
    the launch, `:AgentGeminiSetup` and `:checkhealth` alike.
- Gemini's "Do you want to connect Neovim?" nudge does not enable IDE mode for Neovim: "Yes" runs
  `/ide install`, which has no installer for `neovim`.

### Discovery

- The file is `<os.tmpdir()>/gemini/ide/gemini-ide-server-<nvim pid>-<port>.json` (0600; the
  directories are created 0700 when missing). The CLI's regex is
  `^gemini-ide-server-(\d+)-\d+\.json$`. Never create the legacy `gemini-ide-server-<pid>.json`,
  which is read first and used without checks. Contents:

  ```json
  {"port": 53817, "workspacePath": "/abs/a:/abs/b", "authToken": "<48 hex chars>",
   "ideInfo": {"name": "neovim", "displayName": "Neovim"}}
  ```

  - `ideInfo` is required for us. Without it Gemini falls back to sniffing `TERM_PROGRAM`, and
    every connect fails with "not supported in your current environment".
  - The file must exist **before** Gemini starts, because Gemini decides once per process whether
    it runs in an IDE.
  - `workspacePath` is a string of absolute paths joined with `:`, with no empty segments (an
    empty segment matches everything).
  - Parts are written verbatim. Gemini URI-decodes both each part and its own cwd before
    comparing them, so escaping `%` as `%25` would break a directory such as `a%20b`. Paths
    containing `:` (the delimiter) are skipped.
  - `workspacePath` holds Neovim's global cwd and the cwd of each gemini job launched since the
    server started. `DirChanged` adds the new cwd.
- **How the CLI chooses.** It sorts the files: pid equal to `GEMINI_CLI_IDE_PID` first, then live
  pids, then higher pids. It reads only files owned by its uid, and keeps those whose
  `workspacePath` contains the realpath of its cwd.
  - One valid file wins.
  - With several, the one whose port equals `GEMINI_CLI_IDE_SERVER_PORT` wins, else the first in
    sort order.
- `os.tmpdir()` is `$TMPDIR || $TMP || $TEMP || /tmp`, evaluated in the gemini process. When a
  job gets a different `TMPDIR`, `before_spawn` copies the discovery file into that directory's
  `gemini/ide/`.
- At start, stale files are removed: files owned by the user, with `ideInfo.name` `neovim`,
  whose pid is dead (or is this Neovim's). The port and token stay the same across
  `stop()`/`start()` in one Neovim session.

### Launch environment

Set all four on the job, even if inherited. A Neovim inside a VS Code terminal inherits the VS
Code companion's values, and its multi-folder `WORKSPACE_PATH` would widen Gemini's
`includeDirectories`.

| Variable | Value |
|---|---|
| `GEMINI_CLI_IDE_PID` | `vim.fn.getpid()`. Without it Gemini walks up its process tree to a shell and finds the wrong pid. |
| `GEMINI_CLI_IDE_SERVER_PORT` | the port (the tie-break and the fallback target) |
| `GEMINI_CLI_IDE_AUTH_TOKEN` | the token (used when the file lacks one) |
| `GEMINI_CLI_IDE_WORKSPACE_PATH` | exactly one path: the realpath of the job cwd |
| `GEMINI_CLI_IDE_SERVER_STDIO_COMMAND` | `""` (neutralizes an inherited stdio fallback; `_ARGS` too when inherited) |

When the provider is disabled or not running (no port to give), every inherited
`GEMINI_CLI_IDE_{SERVER_PORT,WORKSPACE_PATH,AUTH_TOKEN,PID,SERVER_STDIO_COMMAND,SERVER_STDIO_ARGS}`
is set to `""` on the job (empty is unset for Gemini), so a Neovim started from a VS Code terminal
does not connect Gemini to VS Code. A value the user sets in `agents.<name>.env` is kept.

`providers.gemini.export_env` also exports PID, port and token into `vim.env`, so a gemini
started by hand in any `:terminal` selects this Neovim.

### Transport

- MCP Streamable HTTP at `http://127.0.0.1:<port>/mcp` (IPv4 literal).
- The client is undici with keep-alive.
  - Request bodies always carry `Content-Length`.
  - The client never sends `Origin` and never sends `DELETE`.
  - After `initialize` it sends `mcp-protocol-version: 2025-06-18`.
- Checks, in order:
  1. `Host` must be `127.0.0.1:<port>` or `localhost:<port>`, else 403.
  2. Any `Origin` header gets 403.
  3. `Authorization: Bearer <token>`, else 401.
  4. A path other than `/mcp` gets 404.
  5. Methods other than POST and GET get 405.
- A missing or unknown `mcp-session-id` gets 400 (as VS Code does).
- **The GET stream is required**: it is the only channel for notifications. A second GET for a
  session **replaces** the first; 409 would count as an error.
- **Keep-alive is mandatory.** undici's `bodyTimeout` is 300 s. A silent stream errors, and
  Gemini's IDE client goes Disconnected for the rest of the process. Its `onerror` handler does
  that for any stream error, parse error, or schema failure.
  - agent.nvim sends `: keepalive` comments every 20 s (`keepalive_ms`, capped at 30 s). One stream
    was verified to survive 330 s idle.
  - A graceful end of the stream while the server is still listening is harmless: the client
    re-GETs after 1 s.
- Never send SSE `id:` lines. Events use `event: message` or no event name.

### MCP handshake

- `initialize` from 0.61.0:
  `{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"streamable-http-client","version":"0.61.0"}}`.
- Result: `{protocolVersion, capabilities: {tools: {listChanged: false}, logging: {}},
  serverInfo: {name: "agent.nvim-gemini-companion", version}}`.
  - The client (MCP SDK 1.23) accepts only `2025-06-18`, `2025-03-26`, `2024-11-05` and
    `2024-10-07`. agent.nvim echoes those (and `2025-11-25`), and otherwise answers `2025-06-18`.
  - `capabilities.tools` must be an object: `"tools": []` makes `initialize` fail.
- `notifications/initialized` gets 202, then comes `GET`, then `tools/list`. On the first GET of
  each session, the server sends one `ide/contextUpdate`.

### Tools

Diffing is enabled only when `tools/list` contains both tools. They are not exposed to the model.

| Tool | Contract |
|---|---|
| `openDiff` `{filePath, newContent}` | Open the diff and **answer `{content: []}` at once**. The user's decision comes later as a notification. `filePath` is Gemini's resolved path (realpath, e.g. `/private/tmp/...`) and may not exist yet. Only one diff is open per gemini process; a second one for the same session and path replaces the first silently. **An `isError` result makes the whole tool call fail**, even after the user approves in the TUI, so errors are reserved for real failures. |
| `closeDiff` `{filePath, suppressNotification?}` | Sent when the user answers in Gemini's TUI (with `suppressNotification: true`), and on `/ide disable` or exit. Close the UI, send **no** notification, and return one text item whose text is the JSON `{"content": "<current proposal text, with the user's edits>"}` (or `{}` when no diff is open). If the user approved, Gemini writes that string. Never return raw file text. |

### Notifications (on the GET stream)

Every notification is validated against Gemini's zod schemas. **One malformed notification
disconnects the IDE client for the rest of the process.** Optional fields are omitted, never
`null`. agent.nvim validates every outgoing notification first (`validate_notification`).

- `ide/contextUpdate` `{workspaceState: {openFiles: [{path, timestamp, isActive?, cursor?: {line, character}, selectedText?}]}}`
  - Up to 10 recently focused files. Exactly one, the newest, has `isActive: true`, with a 1-based
    cursor (UTF-16 character).
  - `selectedText` appears only while there is a selection: in Visual mode, or kept after a switch
    from Visual mode straight to the agent terminal (see Conventions). Truncated to 16384.
  - When the user was last in a buffer that is not a file (a terminal other than the agent's), it
    is the first entry instead: `isActive`, the newest `timestamp` (Gemini sorts by it and clears
    `isActive` unless the newest entry has it), path `nvim://buffer/<n>/<label>`, cursor
    `{line: 1, character: 1}` unless something is selected (its position means nothing to the
    model, and a terminal's cursor follows its output), `selectedText` as for a file. It never joins the recent files: once a
    file has focus again, it is gone. Verified with 0.61.0: the schema accepts it, `/ide status`
    lists `sh (active)`, and the model gets `"activeFile": {"path": "nvim://buffer/4/sh", ...}`
    and read it with `mcp_nvim_read_buffer`.
  - With no files, send `{"workspaceState":{"openFiles":[]}}`. Debounced 50 ms, broadcast to every
    session.
  - With `selection.track = false` that empty context is all Gemini gets, also on stream open.
  - `isTrusted` is omitted: sending `true` would override Gemini's folder trust.
- `ide/diffAccepted` `{filePath, content}`
  - `filePath` exactly as received in `openDiff`; a different spelling is ignored.
  - `content` must be non-empty, or Gemini writes the model's proposal instead. The diff module
    refuses to accept an empty proposal.
  - Gemini writes the file. The server must not: a pre-written file breaks Gemini's `replace`
    tool.
- `ide/diffRejected` `{filePath}`: the tool call is cancelled. Sent when the user rejects in
  Neovim or closes the diff. `ide/diffClosed` is the legacy form; do not send it.
- `stop()` and `VimLeavePre` close diffs silently, with no rejection, so Gemini's own prompt still
  decides.

### Edit flow

| Who decides | Server sees | Gemini writes |
|---|---|---|
| Accept in Neovim (`diffAccepted`) | nothing more | `content` (the user's edits included) |
| Reject in Neovim (`diffRejected`) | nothing more | nothing (cancelled) |
| Approve in the TUI | `closeDiff{suppressNotification: true}` | the `closeDiff` content if non-empty, else the model's proposal |
| Cancel in the TUI | `closeDiff` | nothing |

No `openDiff` is sent in auto-edit mode, for YOLO, or for tools allowed by policy. Docker/Podman
sandboxes (`--sandbox`) forward neither the token nor the discovery file, so they are not
supported.

---

## 4. Launching agents and registering the $NVIM controller

`agents.build_launch()` builds the launch spec, and `terminal.lua` runs it with
`jobstart(argv, {term = true, cwd, env, clear_env})`.
- argv is a Lua list, so no shell quoting is involved.
- `$NVIM` is set by Neovim for every job; `v:servername` is started first if it is empty.
- The registration is written per launch into `stdpath('run')/agent.nvim/<pid>/sessions/<uuid>/`
  (0700; files 0600). That directory is deleted when the job exits and on `VimLeavePre`.
- User config files are never edited.
- `AGENT_NVIM_SESSION=<uuid>` (a new one per launch) is set in the agent's environment.

| | Claude Code | Copilot CLI | Gemini CLI | OpenCode |
|---|---|---|---|---|
| Per-run injection | `--mcp-config=<file>` | `--additional-mcp-config @<file>` | none: a linked extension | `OPENCODE_CONFIG_CONTENT` |
| Entry | `{"mcpServers":{"nvim":{"type":"stdio","command","args","env"}}}` | same plus `"tools":["*"]` (required) | `gemini-extension.json` with `mcpServers.nvim {command, args, env}` | `{"mcp":{"nvim":{"type":"local","command":[...],"environment","enabled":true,"timeout":600000}}}` |
| Model-visible name | `mcp__nvim__<tool>` | `nvim-<tool>` | `mcp_nvim_<tool>` | `nvim_<tool>` |
| Pre-approval (`auto_approve`) | `--allowedTools=mcp__nvim` | `--allow-tool=nvim` | `--policy` TOML (below) | `permission: {"nvim_*": "allow"}` |
| Child inherits the agent's env | yes (except in Claude's MCP allowlist mode) | yes in 1.0.88 (the docs promise only `PATH`) | yes, sanitized; `NVIM` is dropped in "strict" mode | yes |

**Common rules.**
- The controller command is `{v:progpath, '--headless', '-u', 'NONE', '-i', 'NONE', '-n', '-l',
  <abs main.lua>, <v:servername>}`. The address is `arg[1]`, with `$NVIM` as the fallback.
- The entry's `env` always carries `NVIM`, `AGENT_NVIM_AGENT` (the kind),
  `AGENT_NVIM_SESSION` and `AGENT_NVIM_TIMEOUT_MS` **as literals**, because inheritance is not
  guaranteed.
- Registration is refused when `v:servername` contains `$`, `{` or `}`, which config loaders
  expand.
- Plugin options go **after** the user's arguments, in `--opt=value` form. The Claude and Copilot
  options are variadic, and this keeps them from consuming a positional prompt.
- The server name must match `^[A-Za-z0-9-]{1,24}$`: Gemini splits `mcp_<server>_<tool>` on the
  first `_`.
- Reserved server names: `ide`, `workspace`, `claude-in-chrome`, `computer-use`, `shell`, `write`,
  `url`.
- Tool names match `^[a-z][a-z0-9_]{0,39}$`.

**Claude.**
- An existing `managed-mcp.json`, or `disableSideloadFlags: true` in the managed settings, makes
  Claude **exit** when it gets `--mcp-config`.
  - The managed directory is `/Library/Application Support/ClaudeCode`, `/etc/claude-code` or
    `C:\Program Files\ClaudeCode`, plus `$CLAUDE_CODE_MANAGED_SETTINGS_PATH`. Claude reads
    `managed-settings.json` and `managed-settings.d/*.json` there.
  - The launcher checks these and then launches without the controller.
  - MDM or server-managed policy cannot be detected. An exit hint scans the terminal for
    `enterprise MCP config` or `disableSideloadFlags` within 5 s.
- Never pass `--strict-mcp-config`, which would drop the user's servers.
- A `server/discover` probe to stdio servers happens only with `MCP_PROTOCOL_NEGOTIATION=auto`
  (or a remote flag). Verified: the controller answers `-32601`, and Claude falls back at once.

**Copilot.** `cwd` = the lock folder (realpath). `--additional-mcp-config` entries override the
user's config for the session.

**Gemini.**
- There is no per-run flag. `:AgentGeminiSetup` runs `gemini extensions link <dir> --consent`
  once, with `<dir>` = `stdpath('data')/agent.nvim/gemini-extension`. A linked extension reads its
  manifest from `<dir>` on every start, so the plugin rewrites it (atomically) before each launch.
- The manifest uses `exepath('nvim')`, not the versioned `v:progpath`, when it resolves to the
  running nvim (same realpath); otherwise `v:progpath` (another nvim on PATH may be too old). The
  manifest is rewritten before every launch, so this does not go stale. `:AgentMcpConfig` uses
  the same rule. The address is `"${NVIM}"` in `args` and `env`.
  - Gemini resolves `${NVIM}` from its own environment.
  - Outside Neovim it stays unresolved, and the controller then lists zero tools.
  - The manifest description avoids the literal `$NVIM`, because Gemini expands every string.
- A same-name server in the user's `settings.json` wins over the extension.
  - If the user passes `-e`/`--extensions` without `agent-nvim`, `--extensions=agent-nvim` is
    appended.
  - If the user passes `--allowed-mcp-server-names` without the server name (compared exactly,
    as Gemini does), the name is appended.
  - `-e none` disables it, with a warning.
  - Otherwise `mcp.allowed` and `mcp.excluded` from the settings decide, as in Gemini's
    `isBlockedBySettings`: the allowlists of the system, system-defaults, user and trusted
    workspace files are intersected (case-insensitively; an empty result filters nothing) and the
    final check is exact; the excluded lists are joined. A blocked name gives a one-time info
    warning (`gemini-mcp-blocked`). File-based `admin.mcp.enabled` is not checked: Gemini
    ignores admin settings from files.
- Stdio MCP servers are refused in untrusted folders. `agents.gemini.skip_trust` passes
  `--skip-trust`.
- `auto_approve`: `--policy` **replaces** the user's policy dir and `policyPaths`. The launcher
  therefore re-lists them (the user policy dir, then `policyPaths` from the settings files and
  `<cwd>/.gemini/settings.json`), and then adds:

  ```toml
  [[rule]]
  mcpName = "nvim"
  toolName = "*"
  decision = "allow"
  priority = 1
  ```

  `toolName` is required by Gemini's TOML schema (0.61 and 0.63), despite the docs; the verified
  error without it is `Field "rule.0.toolName": Invalid input`. Extension servers ignore
  `trust: true`.
  - `<cwd>/.gemini/settings.json` is re-listed only when Gemini trusts the folder, computed as
    Gemini's `checkPathTrust` does when it loads settings: `GEMINI_CLI_TRUST_WORKSPACE=true`,
    `security.folderTrust.enabled = false`, or the longest matching `trustedFolders.json` rule
    being `TRUST_FOLDER` or `TRUST_PARENT`, and only when the cwd is not Gemini's home. An
    unknown folder, or an unreadable trust file, is untrusted. `--skip-trust`
    (`agents.gemini.skip_trust`) does not count: Gemini reads settings before it parses flags,
    so an untrusted repository's own `policyPaths` never apply.

**OpenCode.**
- An existing `OPENCODE_CONFIG_CONTENT` is deep-merged (objects recursively; arrays and scalars
  replaced) without reordering it: OpenCode's permission precedence follows key order. Existing
  keys keep their place and raw text, new keys are appended, and a string `permission` becomes
  `{"*": <value>}` before the `nvim_*` rule is added (OpenCode normalizes each layer the same
  way).
- If it is not plain JSON, the config is written to a temp `opencode.json` and passed as
  `OPENCODE_CONFIG`, but only if that is unset. Otherwise registration is skipped with a warning.
- `timeout` is also the connect timeout.
- OpenCode's built-in agents allow `*`, so MCP tools run without asking unless the user's
  `permission` config says otherwise.

---

## 5. The $NVIM controller (stdio MCP server)

`lua/agent/nvim_mcp/main.lua` runs in a separate `nvim --headless -l` process.

- **Transport.** Newline-delimited JSON-RPC 2.0 on stdin/stdout. Only protocol messages go to
  stdout. stderr stays silent unless `AGENT_NVIM_MCP_DEBUG` is set, because Claude logs any
  server stderr as an error. On stdin EOF the server waits up to 1.5 s for in-flight calls, then
  exits 0. It always exits 0.
- **Obligations.**
  - Answer `server/discover` and every unknown request with `-32601` at once. Never answer
    notifications or client responses. `notifications/cancelled` marks the call cancelled.
  - `initialize` echoes `2025-11-25`, `2025-06-18`, `2025-03-26` or `2024-11-05`, otherwise
    `2025-11-25`. Capabilities are `{tools: {}}`, and `serverInfo.name` is `agent.nvim`.
  - With no usable address (empty, or starting with `$` such as an unresolved `${NVIM}`), it
    completes the handshake with **zero tools**.
- **Parent RPC.** An async msgpack-RPC client over the `$NVIM` pipe or TCP address, with a
  per-request timeout (`AGENT_NVIM_TIMEOUT_MS`, default 30000). A timed-out request may still run
  later.
  - Before each call it checks `nvim_get_mode().blocking`. If Neovim is at a prompt, the tool
    returns an error instead of queueing a side effect.
  - Tool code lives in `remote.lua`, a self-contained chunk (it never requires `agent.*`). It is
    installed into the parent once per controller version as `_G.__agent_nvim_remote`, and
    reinstalled if missing. It adds an augroup `agent_nvim_remote_mru` that tracks the main
    editor window.
- **Tools.** `read_buffer`, `open_file`, `execute_command`, `eval`, `exec_lua`, `notify`.
  - The schemas are in `nvim_mcp/server.lua`; `:help agent-nvim-mcp-tools` has the argument table.
  - `read_buffer` takes the `nvim://buffer/<n>[/<label>]` ids of the IDE protocols (the label is
    not checked; buffer numbers are never reused) and fails with a clear message for a buffer that
    no longer exists or a malformed id, including buffer 0 (to the API, the current buffer of
    whatever context runs the call; a plain `buffer: 0` still means the main editor buffer). A
    terminal without `start_line`/`end_line` gives its last 200 lines, up to the last one with
    text.
  - No tools for editor state, diagnostics or edits: those come from the IDE protocols (where they
    have them) and the agents' own edit tools, and `exec_lua` reaches the rest. The tool
    descriptions and the `instructions` string point the model there.
  - Lines are 1-based and inclusive. Arguments are validated against the schema (unknown, missing
    or mistyped arguments give an `isError` result).
  - Results are text, JSON where structured. A tool failure is `{isError: true, content: [{type: "text", text}]}`.
  - "Current" means the main editor window: not a terminal, float, diff, preview or known sidebar
    window. `open_file`, `execute_command` and `eval` run there, so they never replace the
    agent's terminal. `exec_lua` runs as-is.
- **Verified.** Claude Code 2.1.283 connected over stdio in 16 ms: `server/discover` got
  `-32601`, then `initialize` (protocol `2025-11-25`). Copilot 1.0.88 listed all the tools (10
  at the time, before the four that duplicated the IDE interface were removed). Gemini 0.61.0
  showed `nvim (from agent-nvim) ... Connected`. OpenCode 1.18.32 called `nvim_exec_lua` and
  `nvim_open_file`, and both results reached the model. With the six tools, Claude 2.1.283 and
  Copilot 1.0.88 still call `exec_lua` and `open_file` in the live e2e run (`tests/e2e/run.sh`).

---

## References

- Claude protocol: [coder/claudecode.nvim](https://github.com/coder/claudecode.nvim) (its Lua
  server and `PROTOCOL.md`), and the Claude Code 2.1.283 binary.
- OpenCode: the OpenCode TUI source (`packages/tui/src/editor.ts`,
  `packages/tui/src/context/editor.ts`), 1.18.32.
- Copilot: the Copilot CLI 1.0.88 package; VS Code's Copilot CLI integration
  (`extensions/copilot/src/extension/chatSessions/copilotcli/` in
  [microsoft/vscode](https://github.com/microsoft/vscode)); the IDE bridge in
  copilot-language-server.
- Gemini: [google-gemini/gemini-cli](https://github.com/google-gemini/gemini-cli)
  (`packages/core/src/ide/`, `packages/vscode-ide-companion/`), and its published npm bundles.
