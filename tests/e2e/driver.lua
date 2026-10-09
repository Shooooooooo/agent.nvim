-- Live end-to-end driver: one real agent CLI inside a headless Neovim that runs agent.nvim.
--
--   nvim --headless -u NONE -i NONE -n -l tests/e2e/driver.lua <kind> <root>
--
-- Run it through tests/e2e/run.sh, which builds an isolated environment (temp HOME and XDG dirs,
-- no inherited agent variables) and checks for leftover processes. <root> is that run's temp dir;
-- every file this driver creates lives under it. Model turns come from a local fake endpoint
-- (tests/e2e/fake_model.mjs) or, for Gemini, from --fake-responses-non-strict.
--
-- The scenario, for each agent:
--   1. require('agent').setup() with the split terminal layout on the right (split_side = 'right',
--      the baseline here; E2E_SPLIT_SIDE=below for the plugin's default, a split at the bottom),
--      then require('agent').open(<kind>)
--      (E2E_LAYOUT=current: the 'current' layout. The editor is split first, a.txt | a.txt, the
--      right window as wide as the split layout's, and the agent takes it over, so that the rest
--      runs the same way; stop() must give that window a.txt back)
--   2. wait for the agent's IDE connection to agent.nvim's provider
--   3. only with E2E_TRACK=1 (selection.track = true, the automatic mode; off by default):
--      selection tracking, driven with keys as a user would, checked on the wire (the last
--      selection agent.nvim pushed) and in the agent's TUI (Gemini's TUI does not show it):
--      (kept) select a.txt lines 1-2 (Vj) and go straight from Visual mode to the agent window
--             (<C-w>l; <C-w>j to a split below): the agent keeps the selection;
--      (dropped) back in the file window the agent sees the cursor only; select again (Vj), then
--             <Esc>: the selection is dropped
--   4. :AgentSend: select a.txt lines 1-2 (Vj) and press <leader>as, mapped to
--      <cmd>AgentSend<cr> in Visual mode (with the default selection.track = false, Vj alone pushed
--      nothing): the focus goes to the agent terminal, the selection goes through the IDE
--      connection as auto-follow sends it (Claude, OpenCode, Copilot: selection_changed; Gemini: an
--      ide/contextUpdate with a.txt as the active file), the TUI shows it (Claude ⧉ 2 lines
--      selected, Copilot @a.txt:1-2, OpenCode a.txt#1-2) and nothing is typed into the prompt
--   5. submit a prompt: the model request carries the selection (Claude "The user selected the
--      lines 1 to 2 from <path>:", Copilot <ide_selection>, OpenCode "Note: The user selected
--      #1-2 from", Gemini the active file of its editor context, read from its telemetry outfile);
--      the scripted model then
--      (a) calls the $NVIM controller: exec_lua (sets vim.g.agent_e2e) and open_file (notes.txt)
--      (b) edits a.txt (world -> neovim) through the IDE diff; its tab page must show the agent
--          terminal too (diff.show_terminal), on split_side (on the right, as wide as the agent's
--          own split; below: at the bottom, full width and as tall), and this driver accepts it
--      (c) the turn shows as a Neovim progress message (agent.progress; Claude and Gemini, read
--          from their titles): running while the agent works, ended while the diff waits for an
--          answer and when the turn is done, and 'busy' back to 0
--   6. check the effects in Neovim and on disk
--   7. :AgentSend from a buffer that is not a file (a scratch buffer, lines 1-2): it reaches the
--      agent by its nvim://buffer/<n>/<label> id, and the next prompt's model request carries it
--   8. :AgentSend of the same lines again once that prompt was answered: the next prompt's model
--      request carries them again. Claude drops the selection when a prompt is submitted (its TUI
--      stops showing it), and OpenCode attaches one to a single prompt and ignores one that did not
--      change: agent.nvim sends it again anyway (checked on the wire for every :AgentSend: to
--      OpenCode always after a copy with other text). Copilot attaches it to every prompt; Gemini's
--      editor context is unchanged, so the model's (its full context and the changes Gemini added
--      since) still has it
--   9. :'<,'>AgentSend typed from a charwise Visual selection of a.txt (v): the provider sends the
--      characters selected, not lines 1-2; the same range run with vim.cmd() sends lines 1-2
--  10. stop() the agent, which also stops its provider (its lock/discovery file goes), tear down,
--      check that no files are left
-- OpenCode has no IDE diff (its client is receive-only), so (b) is skipped for it.
local kind, root = arg[1], arg[2]
assert(kind and root, 'usage: driver.lua <kind> <root>')
local LAYOUT = (vim.env.E2E_LAYOUT or '') ~= '' and vim.env.E2E_LAYOUT or 'split'
assert(LAYOUT == 'split' or LAYOUT == 'current', 'E2E_LAYOUT must be split or current, not ' .. LAYOUT)
local SIDE = (vim.env.E2E_SPLIT_SIDE or '') ~= '' and vim.env.E2E_SPLIT_SIDE or 'right'
assert(SIDE == 'right' or SIDE == 'below', 'E2E_SPLIT_SIDE must be right or below, not ' .. SIDE)
-- E2E_TRACK=1: selection.track = true (automatic context following), with its checks (step 3).
local TRACK = vim.env.E2E_TRACK == '1'

local repo = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h:h')
vim.opt.rtp:prepend(repo)
vim.o.columns, vim.o.lines = 240, 60

local uv = vim.uv
local util = require('agent.util')
local agent = require('agent')
local terminal = require('agent.terminal')
local diff = require('agent.editor.diff')

-- ------------------------------------------------------------------------------------------------
-- Output and checks
-- ------------------------------------------------------------------------------------------------
local logf = assert(io.open(root .. '/' .. kind .. '.driver.log', 'w'))
local t0 = uv.hrtime()
local function out(...)
  local line = ('[%s %6.1fs] %s'):format(kind, (uv.hrtime() - t0) / 1e9, table.concat(vim.tbl_map(tostring, { ... }), ' '))
  io.stdout:write(line .. '\n')
  io.stdout:flush()
  logf:write(line .. '\n')
  logf:flush()
end
local notifications = {}
vim.notify = function(msg, level)
  notifications[#notifications + 1] = msg
  out('NOTIFY(' .. tostring(level) .. '):', msg)
end

local results = {}
local function check(name, ok, detail)
  results[#results + 1] = { name = name, ok = ok and true or false, detail = detail and tostring(detail) or nil }
  out((ok and 'PASS ' or 'FAIL ') .. name .. (detail and (' -- ' .. tostring(detail)) or ''))
  return ok
end
local function skip(name, why)
  results[#results + 1] = { name = name, skipped = why }
  out('SKIP ' .. name .. ' -- ' .. why)
end

local function readf(p)
  local f = io.open(p, 'rb')
  if not f then
    return nil
  end
  local d = f:read('*a')
  f:close()
  return d
end
local function writef(p, data)
  util.mkdir_p(vim.fs.dirname(p), tonumber('700', 8))
  local f = assert(io.open(p, 'wb'))
  f:write(data)
  f:close()
end
local function files_in(dir)
  local names = {}
  for name in vim.fs.dir(dir) do
    names[#names + 1] = name
  end
  return names
end

local function finish()
  local failed, passed, skipped = 0, 0, 0
  for _, r in ipairs(results) do
    if r.skipped then
      skipped = skipped + 1
    elseif r.ok then
      passed = passed + 1
    else
      failed = failed + 1
    end
  end
  writef(root .. '/' .. kind .. '.result.json', vim.json.encode({
    kind = kind, passed = passed, failed = failed, skipped = skipped, results = results,
  }) .. '\n')
  out(('RESULT %s: %d passed, %d failed, %d skipped'):format(kind, passed, failed, skipped))
  logf:close()
  vim.cmd.cquit({ count = failed > 0 and 1 or 0, bang = true })
end

-- ------------------------------------------------------------------------------------------------
-- Workspace and the fake model endpoint
-- ------------------------------------------------------------------------------------------------
local ws = root .. '/' .. kind .. '-ws'
util.mkdir_p(ws, tonumber('700', 8))
ws = util.realpath(ws)
writef(ws .. '/a.txt', 'hello\nworld\n')
writef(ws .. '/notes.txt', 'first\nsecond\nthird\n')
local EXPECTED = 'hello\nneovim\n'
local MARK = 'e2e-ok:' .. vim.fn.getpid()
local EXEC_CODE = ("vim.g.agent_e2e = %q; return %q"):format(kind, MARK)
local PROMPT = 'PLEASE_EDIT a.txt: replace world with neovim'
-- After the scripted steps: the model only answers Done. (Short: the TUIs must not wrap them.)
local PROMPT_BUFFER = 'PLEASE_EDIT nothing more'
local PROMPT_AGAIN = 'PLEASE_EDIT once more'

local model_log = root .. '/' .. kind .. '.model.jsonl'
local fake -- vim.SystemObj
local function start_fake(steps)
  local plan = root .. '/' .. kind .. '.plan.json'
  writef(plan, vim.json.encode({ trigger = 'PLEASE_EDIT', steps = steps, final = 'Done.' }))
  local port
  fake = vim.system({ 'node', repo .. '/tests/e2e/fake_model.mjs', plan, model_log }, {
    stdin = true,
    stdout = function(_, data)
      if data and not port then
        port = tonumber(data:match('(%d+)'))
      end
    end,
  })
  vim.wait(10000, function()
    return port ~= nil
  end, 20)
  assert(port, 'the fake model endpoint did not start')
  return port
end
local function model_entries()
  local list = {}
  for line in (readf(model_log) or ''):gmatch('[^\n]+') do
    local ok, v = pcall(vim.json.decode, line)
    if ok then
      list[#list + 1] = v
    end
  end
  return list
end
local function model_saw_result(text)
  for _, e in ipairs(model_entries()) do
    for _, r in ipairs(e.results or {}) do
      if r.text and r.text:find(text, 1, true) then
        return true
      end
    end
  end
  return false
end
---The input text (see fake_model.mjs) of each scripted-turn request made for `prompt`: the prompt,
---and what the agent attached to it.
local function model_requests(prompt)
  local list = {}
  for _, e in ipairs(model_entries()) do
    if e.kind == 'REQ' and (e.ntools or 0) > 0 and type(e.input) == 'string' and e.input:find(prompt, 1, true) then
      list[#list + 1] = e.input
    end
  end
  return list
end
local function model_steps_done()
  local n = 0
  for _, e in ipairs(model_entries()) do
    if e.kind == 'REQ' and type(e.step) == 'number' then
      n = math.max(n, e.step)
    end
  end
  return n
end

-- ------------------------------------------------------------------------------------------------
-- Per-agent recipes
-- ------------------------------------------------------------------------------------------------
local function exe(envname, fallback)
  local p = vim.env[envname]
  if p and p ~= '' then
    return vim.fn.executable(p) == 1 and p or nil
  end
  p = vim.fn.exepath(fallback)
  return p ~= '' and p or nil
end

local claude_provider = function()
  return require('agent.providers.claude')
end
local function claude_client(k)
  for _, c in ipairs(claude_provider().clients()) do
    if c.kind == k and c.ready then
      return c
    end
  end
end

---The text of the last selection_changed sent to the ready client of kind `k` for `path` ('' when
---only the cursor was sent), or nil.
local function claude_wire(k, path)
  local st = claude_provider()._state
  for _, s in ipairs(st.srv and st.srv:sessions() or {}) do
    if not s.closed and s.data.kind == k and s.data.ready and s.data.sel_key then
      local ok, p = pcall(vim.json.decode, s.data.sel_key)
      if ok and type(p) == 'table' and p.filePath == path then
        return p.text
      end
    end
  end
end

---The text after the prompt sign on the last line of the TUI `t` that matches `pattern` (one
---capture), or nil when there is none.
local function prompt_line(t, pattern)
  local found
  for line in t:gmatch('[^\n]+') do
    local rest = line:gsub('\194\160', ' '):match(pattern)
    if rest then
      found = vim.trim(rest)
    end
  end
  return found
end

local gemini_telemetry = root .. '/gemini.telemetry.log'
---The requests Gemini made to the model, from its telemetry outfile (each request's request_text, a
---line of that pretty-printed JSON): each one the text parts of its contents, in order.
local function gemini_requests()
  local list = {}
  for line in (readf(gemini_telemetry) or ''):gmatch('[^\n]+') do
    local lit = line:match('^%s*"request_text":%s*(".*")%s*,?%s*$')
    local ok, text = pcall(vim.json.decode, lit or '')
    local ok2, contents = pcall(vim.json.decode, ok and type(text) == 'string' and text or '')
    if ok2 and type(contents) == 'table' then
      local parts = {}
      for _, c in ipairs(contents) do
        for _, part in ipairs(type(c) == 'table' and type(c.parts) == 'table' and c.parts or {}) do
          if type(part) == 'table' and type(part.text) == 'string' then
            parts[#parts + 1] = part.text
          end
        end
      end
      list[#list + 1] = parts
    end
  end
  return list
end
---The active file ({ path, text }: its selected text, if any) of the editor context the model had
---when Gemini sent it `prompt`, in each request made for it (false: none). Gemini adds its editor
---context to the conversation with a prompt: in full, then a summary of what changed since the
---last prompt (nothing when nothing did); they are applied in order, up to the prompt.
local function gemini_active(prompt)
  local function file(f) -- (a path null: no active file)
    return type(f) == 'table' and type(f.path) == 'string' and { path = f.path, text = f.selectedText } or nil
  end
  local list = {}
  for _, parts in ipairs(gemini_requests()) do
    local at
    for i, t in ipairs(parts) do
      at = t:find(prompt, 1, true) and i or at
    end
    if at then
      local active
      for i = 1, at - 1 do
        local json = parts[i]:match("^Here is [^\n]*the user's editor context.-\n```json\n(.*)\n```$")
        local ok, ctx = pcall(vim.json.decode, json or '')
        if ok and type(ctx) == 'table' then
          local changes = type(ctx.changes) == 'table' and ctx.changes or nil
          if not changes then -- the full context
            active = file(ctx.activeFile)
          elseif changes.activeFileChanged then
            active = file(changes.activeFileChanged)
          end
          local sc = changes and changes.selectionChanged
          if active and type(sc) == 'table' and sc.path == active.path then
            active.text = sc.selectedText ~= '' and sc.selectedText or nil
          end
        end
      end
      list[#list + 1] = active or false
    end
  end
  return list
end

-- Per agent:
--   selection, no_selection  the TUI with the selection, and with the cursor only (nil: not shown)
--   context_shown            (no selection shown) the TUI once a.txt is sent with :AgentSend
--   buffer_selection         the TUI with lines 1-2 of the scratch buffer (step 7) selected
--   cleared_on_submit        the TUI stops showing the selection (`selection`) when a prompt is
--                            submitted: the agent drops it (Claude: it is for that prompt only)
--   wire(path)               the text of the selection agent.nvim last sent to the agent for `path`
--                            ('' for the cursor only), or nil
--   prompt(t)                the text in the prompt of the TUI `t` ('' when empty, placeholder
--                            left out), or nil when it is not found
--   attached(sel)            what the model request for the next prompt contains for the selection
--                            sel = { path, l1, l2, text } sent with :AgentSend (every string)
--   carried(prompt, sel)     (instead of attached) whether the model got it with `prompt`
local K = {}

K.claude = {
  prepare = function()
    local bin = exe('E2E_CLAUDE_BIN', 'claude')
    if not bin then
      return nil, 'claude not found (set E2E_CLAUDE_BIN)'
    end
    local port = start_fake({
      { tool = '^mcp__nvim__exec_lua$', input = { code = EXEC_CODE } },
      { tool = '^mcp__nvim__open_file$', input = { path = ws .. '/notes.txt', line = 2 } },
      { tool = '^Read$', input = { file_path = ws .. '/a.txt' } },
      { tool = '^Edit$', input = { file_path = ws .. '/a.txt', old_string = 'world', new_string = 'neovim' } },
    })
    -- Onboarding done, the workspace trusted, the dummy key approved (shared with demo/record.sh).
    local seed = dofile(repo .. '/tests/e2e/claude_seed.lua')
    local cfgdir = root .. '/claude-config'
    seed.write(cfgdir, { ws })
    return {
      agents = { claude = { cmd = { bin, '--permission-mode', 'default' }, auto_approve = true,
        env = seed.env(cfgdir, 'http://127.0.0.1:' .. port) } },
    }
  end,
  connected = function()
    return claude_client('claude') ~= nil
  end,
  selection = '⧉ 2 lines selected',
  no_selection = 'In a.txt',
  buffer_selection = '⧉ 2 lines selected',
  cleared_on_submit = true,
  wire = function(path)
    return claude_wire('claude', path)
  end,
  -- (Its prompt shows the selection as [⧉ 2 lines selected] while it is empty.)
  prompt = function(t)
    local p = prompt_line(t, '^%s*❯%s(.*)$')
    return p and vim.trim((p:gsub('^%[⧉[^%]]*%]', ''))) or nil
  end,
  -- The attachment Claude Code makes of the selection_changed it stored.
  attached = function(sel)
    return { ('The user selected the lines %d to %d from %s:\n%s'):format(sel.l1, sel.l2, sel.path, sel.text) }
  end,
  prompts = {},
  diff = true,
  progress = true,
  lock_dir = function()
    return claude_provider().lock_dir()
  end,
}

K.copilot = {
  prepare = function()
    local bin = exe('E2E_COPILOT_BIN', 'copilot')
    if not bin then
      return nil, 'copilot not found (set E2E_COPILOT_BIN)'
    end
    local port = start_fake({
      { tool = '^nvim.exec_lua$', input = { code = EXEC_CODE } },
      { tool = '^nvim.open_file$', input = { path = ws .. '/notes.txt', line = 2 } },
      { tool = '^edit$', input = { path = ws .. '/a.txt', old_str = 'world', new_str = 'neovim' } },
    })
    return {
      providers = { copilot = { trust_workspace = true } },
      agents = { copilot = { cmd = { bin }, auto_approve = true, env = {
        COPILOT_HOME = root .. '/copilot-home',
        COPILOT_OFFLINE = 'true',
        COPILOT_PROVIDER_BASE_URL = 'http://127.0.0.1:' .. port .. '/v1',
        COPILOT_PROVIDER_API_KEY = 'fake-e2e',
        COPILOT_MODEL = 'gpt-4.1',
      } } },
    }
  end,
  connected = function()
    for _, s in ipairs(require('agent.providers.copilot').status().sessions) do
      if s.streaming then
        return true
      end
    end
    return false
  end,
  selection = '@a.txt:1-2',
  no_selection = '@a.txt',
  buffer_selection = '@e2e-scratch:1-2',
  wire = function(path)
    local st = require('agent.providers.copilot')._state()
    -- What :AgentSend sent, else the last tracked selection (a tracked one clears the former).
    local p = st and (st.context and st.context.params or st.last_selection)
    return p and p.filePath == path and p.text or nil
  end,
  prompt = function(t)
    return prompt_line(t, '^%s*❯%s?(.*)$')
  end,
  -- The <ide_selection> block Copilot adds to the prompt (a path relative to its cwd).
  attached = function(sel)
    local path = vim.startswith(sel.path, ws .. '/') and sel.path:sub(#ws + 2) or sel.path
    return { '<ide_selection>', ('File: %s (lines %d-%d)\n```\n%s\n```'):format(path, sel.l1, sel.l2, sel.text) }
  end,
  prompts = { { 'Do you trust the files', '\r' } },
  diff = true,
  lock_dir = function()
    return root .. '/copilot-home/ide'
  end,
}

K.gemini = {
  prepare = function()
    local js = vim.env.E2E_GEMINI_JS
    local cmd
    if js and js ~= '' and vim.fn.filereadable(js) == 1 then
      cmd = { 'node', js }
    elseif vim.fn.executable('gemini') == 1 then
      cmd = { vim.fn.exepath('gemini') }
    else
      return nil, 'gemini not found (set E2E_GEMINI_JS to a gemini.js bundle or install gemini)'
    end
    local ghome = root .. '/gemini-home'
    writef(ghome .. '/.gemini/settings.json', vim.json.encode({
      general = { enableAutoUpdate = false, enableAutoUpdateNotification = false },
      security = { auth = { selectedType = 'gemini-api-key' }, folderTrust = { enabled = false } },
      ide = { enabled = true, hasSeenNudge = true },
      privacy = { usageStatisticsEnabled = false },
      -- The model requests (their contents: logPrompts), to a local file only.
      telemetry = { enabled = true, target = 'local', outfile = gemini_telemetry, logPrompts = true },
    }))
    writef(ghome .. '/.gemini/state.json', vim.json.encode({ terminalSetupPromptShown = true }))
    local function call(name, args)
      return { method = 'generateContentStream', response = { { candidates = { { content = { role = 'model',
        parts = { { functionCall = { name = name, args = args } } } }, finishReason = 'STOP', index = 0 } },
        usageMetadata = { promptTokenCount = 10, candidatesTokenCount = 5, totalTokenCount = 15 } } } }
    end
    local done = { method = 'generateContentStream', response = { { candidates = { { content = { role = 'model',
      parts = { { text = 'Done.' } } }, finishReason = 'STOP', index = 0 } },
      usageMetadata = { promptTokenCount = 10, candidatesTokenCount = 2, totalTokenCount = 12 } } } }
    local nxt = { method = 'generateContent', response = { candidates = { { content = { role = 'model', parts = { {
      text = vim.json.encode({ reasoning = 'x', next_speaker = 'user', model_choice = 'flash' }) } } },
      finishReason = 'STOP', index = 0 } } } }
    local lines = {
      call('mcp_nvim_exec_lua', { code = EXEC_CODE }),
      call('mcp_nvim_open_file', { path = ws .. '/notes.txt', line = 2 }),
      call('write_file', { file_path = ws .. '/a.txt', content = EXPECTED }),
      done, done, done, done, -- (one for each of the three prompts, and a spare)
    }
    for _ = 1, 20 do
      lines[#lines + 1] = nxt
    end
    local responses = root .. '/gemini.responses'
    writef(responses, table.concat(vim.tbl_map(vim.json.encode, lines), '\n') .. '\n')
    -- The link command (:AgentGeminiSetup) runs with this Neovim's environment.
    vim.env.GEMINI_CLI_HOME = ghome
    local gtmp = root .. '/gemini-tmp'
    util.mkdir_p(gtmp, tonumber('700', 8))
    return {
      providers = { gemini = { discovery_dir = gtmp .. '/gemini/ide' } },
      agents = { gemini = { cmd = cmd, auto_approve = true, extension_dir = root .. '/gemini-extension',
        args = { '--fake-responses-non-strict', responses },
        env = { GEMINI_CLI_HOME = ghome, GEMINI_API_KEY = 'fake-e2e', TMPDIR = gtmp } } },
    }
  end,
  before_open = function()
    local code
    local ok, err = require('agent.gemini_setup').run({ confirm = false, on_exit = function(c)
      code = c
    end })
    check('gemini: :AgentGeminiSetup linked the extension', ok and vim.wait(60000, function()
      return code ~= nil
    end, 100) and code == 0 and require('agent.gemini_setup').is_linked(), err or code)
    vim.cmd('silent! only')
    vim.cmd.edit(ws .. '/a.txt')
  end,
  connected = function()
    return require('agent.providers.gemini').status().streams >= 1
  end,
  -- Gemini's TUI does not show the selection (the last ide/contextUpdate sent is checked), only its
  -- context summary: a.txt, sent with :AgentSend (the only file with selection.track = false).
  context_shown = '1 open file',
  wire = function(path)
    local st = require('agent.providers.gemini')._state()
    for _, s in ipairs(st and st.binding:sessions() or {}) do
      local sent = s.data.gemini and s.data.gemini.last_context
      local ok, ctx = pcall(vim.json.decode, sent or '')
      local f = ok and type(ctx) == 'table' and ctx.workspaceState.openFiles[1]
      if f and f.path == path and f.isActive then
        return f.selectedText or ''
      end
    end
  end,
  prompt = function(t)
    local p = prompt_line(t, '^%s*[│┃]?%s*>%s(.*)$')
    return p and (p:gsub('%s*[│┃]$', ''):gsub('^Type your message or @path/to/file$', '')) or nil
  end,
  -- The editor context the model had at the prompt (see gemini_active()): the selection is the
  -- active file, with its text.
  carried = function(prompt, sel)
    for _, f in ipairs(gemini_active(prompt)) do
      if f and f.path == sel.path and f.text == sel.text then
        return true
      end
    end
    return false
  end,
  prompts = {},
  diff = true,
  progress = true,
  lock_dir = function()
    return root .. '/gemini-tmp/gemini/ide'
  end,
}

K.opencode = {
  prepare = function()
    local bin = exe('E2E_OPENCODE_BIN', 'opencode')
    if not bin then
      return nil, 'opencode not found (set E2E_OPENCODE_BIN)'
    end
    local port = start_fake({
      { tool = '^nvim_exec_lua$', input = { code = EXEC_CODE } },
      { tool = '^nvim_open_file$', input = { path = ws .. '/notes.txt', line = 2 } },
    })
    local oc = {
      autoupdate = false,
      share = 'disabled',
      model = 'e2e/fake-model',
      provider = { e2e = {
        npm = '@ai-sdk/openai-compatible',
        name = 'E2E',
        options = { baseURL = 'http://127.0.0.1:' .. port .. '/v1', apiKey = 'fake-e2e' },
        models = { ['fake-model'] = { name = 'Fake model', tool_call = true } },
      } },
    }
    return {
      agents = { opencode = { cmd = { bin }, auto_approve = true, env = {
        OPENCODE_CONFIG_CONTENT = vim.json.encode(oc),
        OPENCODE_DISABLE_AUTOUPDATE = '1',
        OPENCODE_DISABLE_MODELS_FETCH = '1',
        OPENCODE_DISABLE_SHARE = '1',
        OPENCODE_DISABLE_LSP_DOWNLOAD = '1',
        OPENCODE_DISABLE_DEFAULT_PLUGINS = '1',
        OPENCODE_DISABLE_EXTERNAL_SKILLS = '1',
        OPENCODE_DISABLE_CLAUDE_CODE = '1',
      } } },
    }
  end,
  connected = function()
    return claude_client('opencode') ~= nil
  end,
  selection = 'a.txt#1-2',
  no_selection = 'a.txt',
  wire = function(path)
    return claude_wire('opencode', path)
  end,
  -- Its input box: ┃ lines above ╹▀▀▀, the last one with the agent and the model. (Empty on its
  -- home screen, it shows a placeholder: Ask anything… "<an example>".) Only the box's columns: a
  -- wide window has a sidebar on its right once a session started.
  prompt = function(t)
    local lines = vim.split(t, '\n')
    for i = #lines, 1, -1 do
      if lines[i]:match('^%s*╹▀') then
        local width = vim.fn.strchars(lines[i]:sub(1, select(2, lines[i]:find('.*▀'))))
        local j, text = i - 1, {}
        while j > 1 and lines[j - 1]:match('^%s*┃') do
          j = j - 1
        end
        for k = j, i - 2 do
          text[#text + 1] = vim.trim((vim.fn.strcharpart(lines[k], 0, width):gsub('^%s*┃', '')))
        end
        local p = vim.trim(table.concat(text, ' '))
        return p:match('^Ask anything… ".*"$') and '' or p
      end
    end
  end,
  -- The editor-context part OpenCode adds to the prompt.
  attached = function(sel)
    return { ('Note: The user selected #%d-%d from "%s". ```%s```'):format(sel.l1, sel.l2, sel.path, sel.text) }
  end,
  prompts = {},
  diff = false,
  lock_dir = function()
    return claude_provider().lock_dir()
  end,
}

local R = K[kind]
if not R then
  out('unknown kind ' .. kind)
  return finish()
end

-- ------------------------------------------------------------------------------------------------
-- The scenario
-- ------------------------------------------------------------------------------------------------
local opts, why = R.prepare()
if not opts then
  skip(kind, why)
  return finish()
end
opts = vim.tbl_deep_extend('force', {
  terminal = { layout = LAYOUT, split_side = SIDE, start_insert = false, auto_close = false },
  selection = { debounce_ms = 50, track = TRACK or nil },
}, opts)
agent.setup(opts)
local tcfg = require('agent.config').get().terminal
check(('setup() with the %s terminal layout, split_side = %s, selection.track = %s'):format(LAYOUT, SIDE, TRACK),
  tcfg.layout == LAYOUT and tcfg.split_side == SIDE and require('agent.config').get().selection.track == TRACK)
-- The commands (-u NONE loads no plugin/ file), and the mapping the README suggests.
vim.cmd.runtime('plugin/agent.lua')
vim.keymap.set({ 'n', 'x' }, '<leader>as', '<cmd>AgentSend<cr>')
-- The agent's progress messages (agent.progress): their statuses, in order, logged here (their
-- echo in the command line would cut into this log's lines).
vim.o.messagesopt = 'hit-enter,history:500'
local progress_log = {}
vim.api.nvim_create_autocmd('Progress', {
  pattern = 'agent.nvim',
  callback = function(ev)
    progress_log[#progress_log + 1] = ev.data.status
    out(('progress: %s (%s)'):format(ev.data.status, table.concat(ev.data.text, '')))
  end,
})
-- Record what :AgentSend returned (M.send()), what the provider's send_context delivered (Claude,
-- OpenCode: and the text of each selection_changed it sent), and anything typed into the agent's
-- terminal.
local sends, delivered, typed = {}, {}, {}
do
  local send = agent.send
  agent.send = function(...)
    local ok, how = send(...)
    sends[#sends + 1] = { ok = ok, how = how }
    return ok, how
  end
  local provider = require('agent.agents').get(kind).provider
  local P = require('agent.providers.' .. provider)
  local send_context = assert(P.send_context, 'the provider has no send_context')
  P.send_context = function(s, o)
    local srv, notified = provider == 'claude' and claude_provider()._state.srv, {}
    if srv then
      local notify = srv.notify
      srv.notify = function(self, session, method, params, no)
        if method == 'selection_changed' then
          notified[#notified + 1] = params.text
        end
        return notify(self, session, method, params, no)
      end
    end
    local ok, sent = pcall(send_context, s, o)
    if srv then
      srv.notify = nil -- (the server's own method again)
    end
    if not ok then
      error(sent, 0)
    end
    delivered[#delivered + 1] = { path = s.path, text = s.text, sent = sent, notified = srv and notified or nil }
    return sent
  end
  local tsend = terminal.send
  terminal.send = function(text, o)
    typed[#typed + 1] = text
    return tsend(text, o)
  end
end

vim.cmd.cd(ws)
vim.cmd.edit(ws .. '/a.txt')
local a_buf = vim.api.nvim_get_current_buf()
local main_win = vim.api.nvim_get_current_win()
if R.before_open then
  R.before_open()
  a_buf = vim.fn.bufnr(ws .. '/a.txt')
  main_win = vim.api.nvim_get_current_win()
end
-- 'current': the agent takes over the current window; a.txt stays in main_win, on its left. That
-- window is as wide as the split layout's (terminal.split_size of the 240 columns: 96): wider,
-- Copilot's TUI shows a sidebar and cuts the '@a.txt:1-2' line the checks below read.
local agent_win
if LAYOUT == 'current' then
  vim.cmd('rightbelow vsplit')
  agent_win = vim.api.nvim_get_current_win()
  local width = math.floor(vim.o.columns * require('agent.config').get().terminal.split_size)
  vim.cmd(('vertical resize %d'):format(width))
end

local buf, oerr = agent.open(kind)
if LAYOUT == 'current' then
  local prev = vim.w[agent_win].agent_nvim_prev
  if not check('open(): the agent runs in the current window, in place of a.txt', buf ~= nil
    and terminal.is_running() and terminal.name() == kind and vim.fn.win_findbuf(buf)[1] == agent_win
    and #vim.api.nvim_list_wins() == 2 and type(prev) == 'table' and prev.buf == a_buf, oerr) then
    return finish()
  end
elseif not check('open(): the agent runs in a terminal split', buf ~= nil and terminal.is_running()
  and terminal.name() == kind, oerr) then
  return finish()
end
local function tty()
  if not vim.api.nvim_buf_is_valid(buf) then
    return ''
  end
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
end
local answered = {}
local function wait_until(ms, cond, what)
  local deadline = uv.now() + ms
  while uv.now() < deadline do
    if cond() then
      return true
    end
    for i, p in ipairs(R.prompts) do
      if not answered[i] and tty():find(p[1], 1, true) then
        answered[i] = true
        out('answering TUI prompt: ' .. p[1])
        terminal.send(p[2], { bracketed = false })
      end
    end
    if not terminal.is_running() then
      out('the agent exited')
      break
    end
    vim.wait(200)
  end
  if cond() then
    return true
  end
  out('TIMEOUT waiting for ' .. what .. '\n---- terminal ----\n' .. tty() .. '\n------------------')
  return false
end

---The process tree under `pid` (pid included), from `ps -axo pid=,ppid=`.
local function descendants(pid)
  local children = {}
  for line in (vim.system({ 'ps', '-axo', 'pid=,ppid=' }, { text = true }):wait().stdout or ''):gmatch('[^\n]+') do
    local p, pp = line:match('(%d+)%s+(%d+)')
    if p then
      children[tonumber(pp)] = children[tonumber(pp)] or {}
      table.insert(children[tonumber(pp)], tonumber(p))
    end
  end
  local tree, queue = {}, { pid }
  while #queue > 0 do
    local p = table.remove(queue, 1)
    tree[#tree + 1] = p
    vim.list_extend(queue, children[p] or {})
  end
  return tree
end
local function alive(pid)
  local ok, r = pcall(uv.kill, pid, 0)
  return ok and r == 0
end

local function done()
  writef(root .. '/' .. kind .. '.tty.txt', tty())
  -- Every process of the agent (its CLI, the $NVIM controllers, MCP servers, workers) and the fake
  -- endpoint must be gone after the teardown. run.sh checks these pids again after we exit.
  local info = terminal.info()
  local pids = info and info.pid and descendants(info.pid) or {}
  if fake and fake.pid then
    pids[#pids + 1] = fake.pid
  end
  writef(root .. '/' .. kind .. '.pids', table.concat(vim.tbl_map(tostring, pids), '\n') .. '\n')
  out('processes to reap: ' .. table.concat(vim.tbl_map(tostring, pids), ' '))
  -- stop(): the agent stops, and so does its provider (auto_start is off): its lock/discovery file goes.
  local lock_dir = R.lock_dir()
  local provider = require('agent.providers.' .. require('agent.agents').get(kind).provider)
  check('stop() stopped the agent', agent.stop())
  if LAYOUT == 'current' then
    check("stop(): the agent's window stays, with a.txt again", vim.api.nvim_win_is_valid(agent_win)
      and vim.api.nvim_win_get_buf(agent_win) == a_buf and #vim.api.nvim_list_wins() == 2,
      vim.api.nvim_win_is_valid(agent_win) and vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(agent_win)) or 'closed')
  end
  check('stop(): its provider stopped', not provider.is_running())
  check('stop(): the lock/discovery dir is empty', #files_in(lock_dir) == 0,
    lock_dir .. ': ' .. table.concat(files_in(lock_dir), ', '))
  -- Teardown: every provider stops and removes its files.
  agent.teardown()
  if fake then
    fake:kill(15)
    fake:wait(5000)
  end
  local gone = function()
    return not terminal.is_running() and not vim.api.nvim_buf_is_valid(buf)
  end
  vim.wait(10000, gone, 50)
  check('teardown: the agent terminal job is gone', gone())
  check('teardown: every process of the agent exited', vim.wait(15000, function()
    for _, p in ipairs(pids) do
      if alive(p) then
        return false
      end
    end
    return true
  end, 100), table.concat(vim.tbl_map(tostring, vim.tbl_filter(alive, pids)), ' '))
  check('teardown: lock/discovery dir is empty', #files_in(lock_dir) == 0, lock_dir .. ': ' .. table.concat(files_in(lock_dir), ', '))
  local run_dir = vim.fs.joinpath(vim.fn.stdpath('run'), 'agent.nvim', tostring(vim.fn.getpid()))
  check('teardown: no agent.nvim temp dir left', uv.fs_stat(run_dir) == nil, run_dir)
  finish()
end

-- 2. IDE connection
if not check('the agent connected to the agent.nvim IDE provider', wait_until(90000, R.connected, 'IDE connection')) then
  return done()
end
vim.wait(1500)

-- 3. (E2E_TRACK=1) Selection tracking, with keys as a user would press them
local A = ws .. '/a.txt'
local SELECTED = 'hello\nworld'
local function feed(keys, mode)
  vim.api.nvim_feedkeys(vim.keycode(keys), mode or 'nx', false)
end
---The agent got the selection (selected) or the cursor only: on the wire, and in its TUI.
local function agent_has(selected)
  if R.wire(A) ~= (selected and SELECTED or '') then
    return false
  end
  if not R.selection then
    return true
  end
  local t = tty()
  if selected then
    return t:find(R.selection, 1, true) ~= nil
  end
  return t:find(R.selection, 1, true) == nil and t:find(R.no_selection, 1, true) ~= nil
end
local shown = R.selection and (' (TUI: ' .. R.selection .. ')') or ' (ide/contextUpdate selectedText)'
local dropped = R.no_selection and (' (TUI: ' .. R.no_selection .. ')') or ' (no selectedText)'
local term_win = vim.fn.bufwinid(buf)
-- The agent's window: a split below the file (the split layout, split_side = 'below'), else on its
-- right (the split layout on the right, or the window the 'current' layout took over).
local to_agent = (LAYOUT == 'split' and SIDE == 'below') and '<C-w>j' or '<C-w>l'

if TRACK then
  -- (kept) Select lines 1-2, then go straight from Visual mode to the agent window.
  vim.api.nvim_set_current_win(main_win)
  vim.api.nvim_win_set_cursor(main_win, { 1, 0 })
  feed('Vj', 'nx!') -- Visual mode stays on
  check('Vj: the agent got the selection' .. shown, wait_until(20000, function()
    return agent_has(true)
  end, 'the selection at the agent'))
  feed(to_agent)
  check(to_agent .. ' from Visual mode: the agent window has focus', vim.api.nvim_get_current_win() == term_win,
    vim.api.nvim_get_current_win())
  vim.wait(2000) -- well past the grace period and the debounce
  check('the selection is kept for the agent' .. shown, agent_has(true), vim.inspect(R.wire(A)))

  -- (dropped) Back in the file window, Normal mode: the cursor only. Select again, then <Esc>.
  feed('<C-w>p')
  check('<C-w>p: back in the file window', vim.api.nvim_get_current_win() == main_win)
  check('back in the file: the agent got the cursor only' .. dropped, wait_until(20000, function()
    return agent_has(false)
  end, 'the cursor only at the agent'))
  vim.api.nvim_win_set_cursor(main_win, { 1, 0 })
  feed('Vj', 'nx!')
  check('Vj again: the agent got the selection' .. shown, wait_until(20000, function()
    return agent_has(true)
  end, 'the selection at the agent'))
  feed('<Esc>')
  check('<Esc> dropped the selection: the agent got the cursor only' .. dropped, wait_until(20000, function()
    return agent_has(false)
  end, 'the cursor only at the agent'))
end

-- 4. :AgentSend from Visual mode, through <leader>as (<cmd>AgentSend<cr>)
local function inspect1(v)
  return vim.inspect(v, { newline = ' ', indent = '' })
end
local wire_name = kind == 'gemini' and 'ide/contextUpdate, as the active file' or 'selection_changed'
---Press <leader>as in Visual mode (the selection `sel` = { path, l1, l2, text }), or run :AgentSend
---another way (`how` = { run = function, label = string }), and check that the agent got the
---selection through its IDE connection, as selection.track sends selections, and that nothing was
---typed into its prompt. `pre` prefixes the check names; `shows` is what the TUI shows for it, if
---anything.
local function send_selection(sel, pre, shows, how)
  how = how or { label = '<leader>as (<cmd>AgentSend<cr>) from Visual mode', run = function()
    feed('<leader>as', 'x')
  end }
  local nsends, ndelivered, ntyped = #sends, #delivered, #typed
  how.run()
  check(pre .. how.label .. ': the agent terminal has focus, Visual mode ended',
    vim.api.nvim_get_current_win() == term_win and not vim.api.nvim_get_mode().mode:match('^[vVsS\22\19]'),
    ('win %d, mode %s'):format(vim.api.nvim_get_current_win(), vim.api.nvim_get_mode().mode))
  local r = sends[nsends + 1]
  check(pre .. ":AgentSend returned 'sent': the agent is connected", #sends == nsends + 1 and r.ok
    and r.how == 'sent', inspect1(vim.list_slice(sends, nsends + 1)))
  local d = delivered[#delivered]
  check(pre .. 'the provider sent the selection (send_context)', #delivered > ndelivered and d.sent
    and d.path == sel.path and d.text == sel.text, inspect1(vim.list_slice(delivered, ndelivered + 1)))
  -- Claude, OpenCode: selection_changed, also when it is the one sent last; to OpenCode always
  -- after a copy with other text ('' <-> ' '), since it ignores one that did not change and keeps
  -- its selection across reconnects.
  if d and d.notified then
    local want = kind == 'opencode' and { sel.text == '' and ' ' or '', sel.text } or { sel.text }
    check(pre .. 'the provider sent selection_changed' .. (kind == 'opencode' and ', after a copy with other text'
      or ''), vim.deep_equal(d.notified, want), inspect1(d.notified))
  end
  check(('%sthe agent got %s lines %d-%d on the wire (%s)'):format(pre, sel.path, sel.l1, sel.l2, wire_name),
    wait_until(20000, function()
      return R.wire(sel.path) == sel.text
    end, 'the selection on the wire'), vim.inspect(R.wire(sel.path)))
  if shows then
    check(pre .. "the agent's TUI shows it: " .. shows, wait_until(20000, function()
      return tty():find(shows, 1, true) ~= nil
    end, shows))
  end
  vim.wait(1000) -- (a reference typed or inserted would show by now)
  local p = R.prompt(tty())
  check(pre .. "nothing was typed: the agent's prompt is empty", #typed == ntyped and p == '',
    ('typed %s, prompt %s'):format(vim.inspect(vim.list_slice(typed, ntyped + 1)), vim.inspect(p)))
  writef(root .. '/' .. kind .. '.tty-send.txt', tty())
end
---Did the model request made for `prompt` carry the selection `sel`?
local function carried(prompt, sel)
  if R.carried then
    return R.carried(prompt, sel)
  end
  for _, u in ipairs(model_requests(prompt)) do
    local all = true
    for _, want in ipairs(R.attached(sel)) do
      all = all and u:find(want, 1, true) ~= nil
    end
    if all then
      return true
    end
  end
  return false
end
local function carried_detail(prompt)
  if kind == 'gemini' then
    return 'the active file at the prompt: ' .. inspect1(gemini_active(prompt))
  end
  local u = model_requests(prompt)
  return #u == 0 and 'no request for the prompt' or vim.inspect(u[#u]:sub(1, 3000))
end
---Did the agent finish the turn of `prompt` (Done. after it in the TUI)?
local function done_after(prompt)
  -- (A full-screen TUI keeps no scrollback: an earlier Done. may be gone.)
  local t, i = tty(), nil
  for at in t:gmatch('()' .. vim.pesc(prompt)) do
    i = at
  end
  return i ~= nil and t:find('Done.', i, true) ~= nil
end

vim.api.nvim_set_current_win(main_win)
vim.api.nvim_win_set_cursor(main_win, { 1, 0 })
feed('Vj', 'nx!')
if TRACK then
  check('Vj: the agent got the selection' .. shown, wait_until(20000, function()
    return agent_has(true)
  end, 'the selection at the agent'))
  vim.wait(500)
else
  vim.wait(500) -- past the debounce
  check('selection.track = false: Vj alone pushed nothing to the agent', R.wire(A) == nil, vim.inspect(R.wire(A)))
end
local SEL = { path = A, l1 = 1, l2 = 2, text = SELECTED }
send_selection(SEL, '', R.selection or R.context_shown)

-- 5. Prompt: its model request carries the selection
local progress_from = #progress_log + 1
terminal.send(PROMPT, { submit = true, submit_delay_ms = 400 })
local ok = wait_until(60000, function()
  return carried(PROMPT, SEL)
end, 'the selection in the model request')
check('the model request for the prompt carries the selection (' .. (R.carried and 'editor context activeFile'
  or R.attached(SEL)[#R.attached(SEL)]:gsub('\n.*', ' ...')) .. ')', ok, not ok and carried_detail(PROMPT) or nil)

-- (a) the $NVIM controller
check('(a) exec_lua ran in this Neovim (vim.g.agent_e2e set)', wait_until(90000, function()
  return vim.g.agent_e2e == kind
end, 'exec_lua'))
if kind ~= 'gemini' then
  check('(a) the exec_lua result reached the model', wait_until(30000, function()
    return model_saw_result(MARK)
  end, 'exec_lua result at the model'))
end
check('(a) open_file showed notes.txt in the editor window (not the terminal)', wait_until(30000, function()
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    local b = vim.api.nvim_win_get_buf(w)
    if vim.api.nvim_buf_get_name(b) == ws .. '/notes.txt' and vim.bo[b].buftype == '' then
      return true
    end
  end
  return false
end, 'open_file'))

-- (b) the edit through the IDE diff
if R.diff then
  if check('(b) the agent opened an IDE diff in Neovim', wait_until(90000, function()
    return #diff.list() >= 1
  end, 'IDE diff')) then
    local d = diff.get(diff.list()[1])
    local proposal = table.concat(vim.api.nvim_buf_get_lines(d.bufnr, 0, -1, false), '\n')
    check('(b) the diff proposes the edit', proposal == 'hello\nneovim', proposal)
    if R.progress then
      check("(c) while the diff waits for an answer, the agent's progress message has ended",
        wait_until(5000, function()
          return vim.bo[buf].busy == 0 and progress_log[#progress_log] ~= 'running'
        end, 'no progress while the diff waits'), vim.inspect(vim.list_slice(progress_log, progress_from)))
    end
    -- The diff's tab page shows the agent too (diff.show_terminal), on split_side: original |
    -- proposed | agent, the agent as wide as its split in the main tab page; or, below, the agent
    -- under original | proposed, full width and as tall as its split. The proposal is focused.
    local diff_tab = vim.api.nvim_get_current_tabpage()
    local wins = vim.api.nvim_tabpage_list_wins(diff_tab)
    local here = vim.tbl_filter(function(w)
      return vim.api.nvim_win_get_buf(w) == terminal.bufnr()
    end, wins)
    check('(b) the agent terminal is shown in the diff tab page', d.tabpage == diff_tab and #wins == 3
      and #here == 1 and vim.api.nvim_win_get_buf(vim.api.nvim_get_current_win()) == d.bufnr,
      ('%d windows, %d agent'):format(#wins, #here))
    local diff_term = here[1]
    local split_size = tcfg.split_size
    local of = LAYOUT == 'current' and 'terminal.split_size' or 'the terminal split'
    if diff_term and SIDE == 'right' then
      local right = vim.api.nvim_win_get_position(diff_term)[2] + vim.api.nvim_win_get_width(diff_term) == vim.o.columns
      -- 'current': the agent's own window is no split to match: terminal.split_size of the width.
      local want = LAYOUT == 'current' and math.floor(vim.o.columns * split_size) or vim.api.nvim_win_get_width(term_win)
      check('(b) ... on the right, as wide as ' .. of, right and vim.api.nvim_win_get_width(diff_term) == want,
        ('width %d vs %d'):format(vim.api.nvim_win_get_width(diff_term), want))
    elseif diff_term then
      -- At the bottom: the last window of the tab page's top-level column, under the diff's row.
      local layout = vim.fn.winlayout()
      local bottom = layout[1] == 'col' and #layout[2] == 2 and layout[2][1][1] == 'row'
        and vim.deep_equal(layout[2][2], { 'leaf', diff_term })
      local want = LAYOUT == 'current' and math.floor(vim.o.lines * split_size) or vim.api.nvim_win_get_height(term_win)
      check('(b) ... at the bottom, full width, as tall as ' .. of, bottom
        and vim.api.nvim_win_get_width(diff_term) == vim.o.columns and vim.api.nvim_win_get_height(diff_term) == want,
        ('%s, %dx%d vs %dx%d'):format(vim.inspect(layout):gsub('%s+', ' '), vim.api.nvim_win_get_width(diff_term),
          vim.api.nvim_win_get_height(diff_term), vim.o.columns, want))
    end
    vim.wait(500)
    local aok, aerr = agent.diff_accept()
    check('(b) diff_accept() accepted it in Neovim', aok, aerr)
    check('(b) the diff tab page closed; the agent runs on in its own window', vim.wait(5000, function()
      return #vim.api.nvim_list_tabpages() == 1
    end, 50) and terminal.is_running() and vim.api.nvim_win_is_valid(term_win)
      and vim.deep_equal(vim.fn.win_findbuf(buf), { term_win }))
    check('(b) the agent wrote the accepted edit to disk', wait_until(60000, function()
      return readf(ws .. '/a.txt') == EXPECTED
    end, 'a.txt on disk'), vim.inspect(readf(ws .. '/a.txt')))
    check('(b) the a.txt buffer reloaded', wait_until(15000, function()
      return vim.api.nvim_buf_is_valid(a_buf)
        and table.concat(vim.api.nvim_buf_get_lines(a_buf, 0, -1, false), '\n') == 'hello\nneovim'
    end, 'a.txt buffer reload'))
  end
else
  skip('(b) edit through the IDE diff', 'OpenCode has no IDE diff: its editor client only receives selections')
end

if kind ~= 'gemini' then
  check('the scripted turn completed at the model', wait_until(60000, function()
    return model_steps_done() >= (R.diff and (kind == 'claude' and 4 or 3) or 2)
  end, 'model turn'), 'steps answered: ' .. model_steps_done())
end
check('the agent finished its turn (Done. in the TUI)', wait_until(30000, function()
  return tty():find('Done.', 1, true) ~= nil
end, 'Done.'))
if R.progress then
  local turn
  check("(c) the turn showed as a progress message, which ended with it ('busy' 0)", wait_until(10000, function()
    turn = vim.list_slice(progress_log, progress_from)
    return vim.tbl_contains(turn, 'running') and turn[#turn] ~= 'running' and vim.bo[buf].busy == 0
  end, 'the end of the progress message'), vim.inspect(turn))
else
  skip('(c) the turn as a progress message', kind == 'opencode' and 'OpenCode shows no progress'
    or 'Copilot CLI sends its progress only in the terminals it recognizes, not here')
end

-- 7. :AgentSend from a buffer that is not a file (a scratch buffer): by its nvim://buffer/ id
local scratch = vim.api.nvim_create_buf(true, true)
vim.api.nvim_buf_set_name(scratch, 'e2e-scratch')
vim.api.nvim_buf_set_lines(scratch, 0, -1, false, { 'alpha', 'beta', 'gamma' })
vim.api.nvim_set_current_win(main_win)
vim.api.nvim_win_set_buf(main_win, scratch)
local BSEL = { path = require('agent.editor.context').buffer_uri(scratch), l1 = 1, l2 = 2, text = 'alpha\nbeta' }
check('(buffer) a scratch buffer goes by its nvim://buffer/ id', BSEL.path == ('nvim://buffer/%d/e2e-scratch'):format(scratch),
  BSEL.path)
vim.api.nvim_win_set_cursor(main_win, { 1, 0 })
feed('Vj', 'nx!')
vim.wait(500)
send_selection(BSEL, '(buffer) ', R.buffer_selection)
terminal.send(PROMPT_BUFFER, { submit = true, submit_delay_ms = 400 })
ok = wait_until(60000, function()
  return carried(PROMPT_BUFFER, BSEL)
end, 'the buffer selection in the model request')
check('(buffer) the model request for the next prompt carries it', ok, not ok and carried_detail(PROMPT_BUFFER) or nil)
check('(buffer) the agent finished that turn too (Done. after the prompt in the TUI)', wait_until(30000, function()
  return done_after(PROMPT_BUFFER)
end, 'Done.'))

-- 8. :AgentSend of the same lines again, now that the prompt was answered: the next prompt carries
--    them too. Claude drops the selection when a prompt is submitted; OpenCode attaches one to a
--    single prompt and ignores one that did not change (file, range, text): the provider sends it
--    again anyway (to OpenCode after a copy with other text). Copilot attaches the latest one to
--    every prompt; Gemini adds only what changed to the editor context, so the model's still has it.
if R.cleared_on_submit then
  check('(again) the agent dropped the selection when the prompt was submitted (TUI: no ' .. R.selection .. ')',
    wait_until(5000, function()
      return tty():find(R.selection, 1, true) == nil
    end, 'the selection gone from the TUI'))
end
vim.api.nvim_set_current_win(main_win)
vim.api.nvim_win_set_cursor(main_win, { 1, 0 })
feed('Vj', 'nx!')
vim.wait(500)
send_selection(BSEL, '(again) ', R.buffer_selection)
terminal.send(PROMPT_AGAIN, { submit = true, submit_delay_ms = 400 })
ok = wait_until(60000, function()
  return carried(PROMPT_AGAIN, BSEL)
end, 'the selection in the model request again')
check('(again) the model request for the next prompt carries it again'
  .. (kind == 'gemini' and ' (the editor context the model has)' or ''),
  ok, not ok and carried_detail(PROMPT_AGAIN) or nil)
check('(again) the agent finished that turn too (Done. after the prompt in the TUI)', wait_until(30000, function()
  return done_after(PROMPT_AGAIN)
end, 'Done.'))

-- 9. :'<,'>AgentSend typed from a charwise Visual selection (v, a.txt from line 1 column 2 to line 2
--    column 2): the Visual area as it was made, not its lines (the command line is read on
--    CmdlineLeave). Then the same range run from Lua (vim.cmd), which is never the Visual area:
--    lines 1-2.
vim.api.nvim_set_current_win(main_win)
vim.api.nvim_win_set_buf(main_win, a_buf)
local al = vim.api.nvim_buf_get_lines(a_buf, 0, 2, false)
local CSEL = { path = A, l1 = 1, l2 = 2, text = al[1]:sub(2) .. '\n' .. al[2]:sub(1, 2) }
vim.api.nvim_win_set_cursor(main_win, { 1, 1 })
feed('vj', 'nx!')
vim.wait(500)
send_selection(CSEL, '(charwise) ', nil, { label = ":'<,'>AgentSend typed in Visual mode (v)", run = function()
  feed(':AgentSend<CR>', 'x')
end })
vim.api.nvim_set_current_win(main_win)
vim.wait(500)
send_selection({ path = A, l1 = 1, l2 = 2, text = table.concat(al, '\n') }, '(range) ', nil,
  { label = [[vim.cmd("'<,'>AgentSend") in Normal mode]], run = function()
    vim.cmd("'<,'>AgentSend")
  end })
done()
