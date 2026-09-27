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
--   1. require('agent').setup() with the split terminal layout, then require('agent').open(<kind>)
--   2. wait for the agent's IDE connection to agent.nvim's provider
--   3. selection tracking, driven with keys as a user would, checked on the wire (the last
--      selection agent.nvim pushed) and in the agent's TUI (Gemini's TUI does not show it):
--      (kept) select a.txt lines 1-2 (Vj) and go straight from Visual mode to the agent window
--             (<C-w>l): the agent keeps the selection;
--      (dropped) back in the file window the agent sees the cursor only; select again (Vj), then
--             <Esc>: the selection is dropped
--   4. submit a prompt; the scripted model then
--      (a) calls the $NVIM controller: exec_lua (sets vim.g.agent_e2e) and open_file (notes.txt)
--      (b) edits a.txt (world -> neovim) through the IDE diff, which this driver accepts
--   5. check the effects in Neovim and on disk, tear down, check that no files are left
-- OpenCode has no IDE diff (its client is receive-only), so (b) is skipped for it.
local kind, root = arg[1], arg[2]
assert(kind and root, 'usage: driver.lua <kind> <root>')

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

---The text of the last selection_changed sent to the ready client of kind `k` for a.txt ('' when
---only the cursor was sent), or nil.
local function claude_wire(k)
  local st = claude_provider()._state
  for _, s in ipairs(st.srv and st.srv:sessions() or {}) do
    if not s.closed and s.data.kind == k and s.data.ready and s.data.sel_key then
      local ok, p = pcall(vim.json.decode, s.data.sel_key)
      if ok and type(p) == 'table' and p.filePath == ws .. '/a.txt' then
        return p.text
      end
    end
  end
end

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
  -- The TUI with the selection, and with the cursor only.
  selection = '⧉ 2 lines selected',
  no_selection = 'In a.txt',
  wire = function()
    return claude_wire('claude')
  end,
  prompts = {},
  diff = true,
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
  wire = function()
    local st = require('agent.providers.copilot')._state()
    local p = st and st.last_selection
    return p and p.filePath == ws .. '/a.txt' and p.text or nil
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
      done, done, done,
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
  -- Gemini's TUI does not show the selection: only the last ide/contextUpdate sent is checked.
  wire = function()
    local st = require('agent.providers.gemini')._state()
    for _, s in ipairs(st and st.binding:sessions() or {}) do
      local sent = s.data.gemini and s.data.gemini.last_context
      local ok, ctx = pcall(vim.json.decode, sent or '')
      local f = ok and type(ctx) == 'table' and ctx.workspaceState.openFiles[1]
      if f and f.path == ws .. '/a.txt' and f.isActive then
        return f.selectedText or ''
      end
    end
  end,
  prompts = {},
  diff = true,
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
  wire = function()
    return claude_wire('opencode')
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
  terminal = { layout = 'split', start_insert = false, auto_close = false },
  selection = { debounce_ms = 50 },
}, opts)
agent.setup(opts)
check('setup() with the split terminal layout', require('agent.config').get().terminal.layout == 'split')

vim.cmd.cd(ws)
vim.cmd.edit(ws .. '/a.txt')
local a_buf = vim.api.nvim_get_current_buf()
local main_win = vim.api.nvim_get_current_win()
if R.before_open then
  R.before_open()
  a_buf = vim.fn.bufnr(ws .. '/a.txt')
  main_win = vim.api.nvim_get_current_win()
end

local buf, oerr = agent.open(kind)
if not check('open(): the agent runs in a terminal split', buf ~= nil and terminal.is_running(kind), oerr) then
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
        terminal.send(kind, p[2], { bracketed = false })
      end
    end
    if not terminal.is_running(kind) then
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
  local info = terminal.info(kind)
  local pids = info and info.pid and descendants(info.pid) or {}
  if fake and fake.pid then
    pids[#pids + 1] = fake.pid
  end
  writef(root .. '/' .. kind .. '.pids', table.concat(vim.tbl_map(tostring, pids), '\n') .. '\n')
  out('processes to reap: ' .. table.concat(vim.tbl_map(tostring, pids), ' '))
  -- Teardown: every agent and provider stops and removes its files.
  local lock_dir = R.lock_dir()
  agent.teardown()
  if fake then
    fake:kill(15)
    fake:wait(5000)
  end
  vim.wait(10000, function()
    return #terminal.running() == 0
  end, 50)
  check('teardown: the agent terminal job is gone', #terminal.running() == 0)
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

-- 3. Selection tracking, with keys as a user would press them
local SELECTED = 'hello\nworld'
local function feed(keys, mode)
  vim.api.nvim_feedkeys(vim.keycode(keys), mode or 'nx', false)
end
---The agent got the selection (selected) or the cursor only: on the wire, and in its TUI.
local function agent_has(selected)
  if R.wire() ~= (selected and SELECTED or '') then
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

-- (kept) Select lines 1-2, then go straight from Visual mode to the agent window.
vim.api.nvim_set_current_win(main_win)
vim.api.nvim_win_set_cursor(main_win, { 1, 0 })
feed('Vj', 'nx!') -- Visual mode stays on
check('Vj: the agent got the selection' .. shown, wait_until(20000, function()
  return agent_has(true)
end, 'the selection at the agent'))
feed('<C-w>l')
check('<C-w>l from Visual mode: the agent window has focus', vim.api.nvim_get_current_win() == term_win,
  vim.api.nvim_get_current_win())
vim.wait(2000) -- well past the grace period and the debounce
check('the selection is kept for the agent' .. shown, agent_has(true), vim.inspect(R.wire()))

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

-- 4. Prompt
vim.wait(1000)
terminal.send(kind, PROMPT, { submit = true, submit_delay_ms = 400 })

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
    vim.wait(500)
    local aok, aerr = agent.diff_accept()
    check('(b) diff_accept() accepted it in Neovim', aok, aerr)
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
done()
