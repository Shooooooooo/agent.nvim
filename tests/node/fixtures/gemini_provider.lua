-- Test fixture for tests/node/provider_gemini.test.mjs.
-- Usage: nvim --headless -u NONE -i NONE -n -l gemini_provider.lua <repo_root> <work_dir>
-- Starts agent.providers.gemini with its discovery file in <work_dir>/disc and the cwd
-- <work_dir>/ws, prints one JSON line {port, token, pid, discovery_file, ws, keepalive_ms}, then
-- answers JSON commands on stdin (one JSON line per command):
--   {"cmd":"state"}                        diffs, sessions, discovery file existence
--   {"cmd":"accept","path":P}              accept the diff for filePath P (as :w would)
--   {"cmd":"reject","path":P}              reject it (reject key)
--   {"cmd":"append","path":P,"text":T}     append a line to the proposal (a user edit)
--   {"cmd":"clear","path":P}               empty the proposal
--   {"cmd":"wipe","path":P}                :bwipeout! the proposal buffer (user closes the UI)
--   {"cmd":"edit","file":F,"line":L,"col":C}  :edit F and put the cursor at (L, byte col C)
--   {"cmd":"select","from":A,"to":B}       linewise visual selection of lines A..B (stays active)
--   {"cmd":"escape"}                       leave visual mode
--   {"cmd":"flush"}                        run the selection debounce now
--   {"cmd":"send","from":A,"to":B,"pid":N} :AgentSend: selection.capture() of lines A..B (else of the
--                                          cursor), then send_context (for the terminal job pid N)
--   {"cmd":"forget","pid":N}               the agent terminal with job pid N ended (clear_context)
--   {"cmd":"track","on":bool}              set config.selection.track
--   {"cmd":"onselection"}                  a selection event forwarded by agent.nvim (on_selection)
--   {"cmd":"stop"}                         provider stop()
--   {"cmd":"quit"}
local root, work = arg[1], arg[2]
vim.opt.rtp:prepend(root)
vim.o.columns, vim.o.lines = 200, 50

vim.notify = function(msg)
  io.stderr:write('[gemini_provider] ' .. tostring(msg) .. '\n')
end

local config = require('agent.config')
config.setup({ diff = { open_in = 'tab' }, selection = { debounce_ms = 20, track = true } })
local P = require('agent.providers.gemini')
local diff = require('agent.editor.diff')
local selection = require('agent.editor.selection')

local ws = work .. '/ws'
vim.fn.mkdir(ws, 'p')
vim.cmd.cd(vim.fn.fnameescape(ws))

local KEEPALIVE_MS = 150
assert(P.start({
  discovery_dir = work .. '/disc',
  keepalive_ms = KEEPALIVE_MS,
  context_debounce_ms = 20,
  orphan_grace_ms = 400,
}))
local st = P._state()

local function out(tbl)
  io.stdout:write(vim.json.encode(tbl) .. '\n')
  io.stdout:flush()
end

out({
  port = st.port,
  token = st.token,
  pid = st.pid,
  discovery_file = st.discovery_file,
  ws = vim.uv.fs_realpath(ws),
  keepalive_ms = KEEPALIVE_MS,
})

local function find(path)
  for _, id in ipairs(diff.list()) do
    local d = diff.get(id)
    if d and d.path == path then
      return d
    end
  end
  return nil
end

local handlers = {}

function handlers.state()
  local diffs = {}
  for _, id in ipairs(diff.list()) do
    local d = diff.get(id)
    diffs[#diffs + 1] = {
      id = id,
      path = d.path,
      text = table.concat(vim.api.nvim_buf_get_lines(d.bufnr, 0, -1, false), '\n'),
    }
  end
  local sessions = {}
  local s = P._state()
  if s then
    for _, session in ipairs(s.binding:sessions()) do
      sessions[#sessions + 1] = { id = session.id, stream = s.binding:has_stream(session) }
    end
  end
  return {
    running = P.is_running(),
    diffs = diffs,
    sessions = sessions,
    discovery_exists = vim.uv.fs_stat(st.discovery_file) ~= nil,
    status = P.status(),
  }
end

local function with_diff(c, fn)
  local d = find(c.path)
  if not d then
    return { error = 'no diff for ' .. tostring(c.path) }
  end
  return fn(d)
end

function handlers.accept(c)
  return with_diff(c, function(d)
    local ok, err = diff.accept(d.id)
    return { ok = ok, err = err or vim.NIL }
  end)
end

function handlers.reject(c)
  return with_diff(c, function(d)
    local ok, err = diff.reject(d.id)
    return { ok = ok, err = err or vim.NIL }
  end)
end

function handlers.append(c)
  return with_diff(c, function(d)
    vim.api.nvim_buf_set_lines(d.bufnr, -1, -1, false, { c.text })
    return { ok = true }
  end)
end

function handlers.clear(c)
  return with_diff(c, function(d)
    vim.api.nvim_buf_set_lines(d.bufnr, 0, -1, false, {})
    vim.bo[d.bufnr].eol = false
    return { ok = true }
  end)
end

function handlers.wipe(c)
  return with_diff(c, function(d)
    vim.cmd('bwipeout! ' .. d.bufnr)
    return { ok = true }
  end)
end

function handlers.edit(c)
  vim.cmd('edit ' .. vim.fn.fnameescape(c.file))
  if c.line then
    vim.api.nvim_win_set_cursor(0, { c.line, c.col or 0 })
  end
  selection.flush()
  return { ok = true, buf = vim.api.nvim_buf_get_name(0) }
end

function handlers.select(c)
  vim.api.nvim_win_set_cursor(0, { c.from, 0 })
  vim.cmd('normal! V' .. (c.to > c.from and ((c.to - c.from) .. 'j') or ''))
  selection.flush()
  return { ok = true, mode = vim.api.nvim_get_mode().mode }
end

function handlers.escape()
  vim.cmd('normal! \27')
  selection.flush()
  return { ok = true }
end

function handlers.flush()
  selection.flush()
  return { ok = true }
end

function handlers.send(c)
  local s = assert(selection.capture(c.from and { line1 = c.from, line2 = c.to } or nil))
  return { ok = true, sent = P.send_context(s, c.pid and { pid = c.pid } or nil) }
end

function handlers.forget(c)
  P.clear_context(c.pid)
  return { ok = true }
end

function handlers.track(c)
  config.setup({ diff = { open_in = 'tab' }, selection = { debounce_ms = 20, track = c.on } })
  return { ok = true }
end

function handlers.onselection()
  P.on_selection(nil)
  return { ok = true }
end

function handlers.stop()
  P.stop()
  return { ok = true, discovery_exists = vim.uv.fs_stat(st.discovery_file) ~= nil }
end

local quit = false
function handlers.quit()
  quit = true
  return { ok = true }
end

local stdin = vim.uv.new_pipe(false)
stdin:open(0)
local pending = ''
stdin:read_start(function(err, chunk)
  if err or not chunk then
    quit = true
    return
  end
  pending = pending .. chunk
  for line in pending:gmatch('([^\n]*)\n') do
    vim.schedule(function()
      local ok, c = pcall(vim.json.decode, line)
      local h = ok and type(c) == 'table' and handlers[c.cmd]
      if not h then
        out({ error = 'bad command: ' .. line })
        return
      end
      local hok, res = pcall(h, c)
      out(hok and res or { error = tostring(res) })
    end)
  end
  pending = pending:match('[^\n]*$')
end)

vim.wait(600000, function()
  return quit
end, 20)
P.stop()
vim.wait(50)
stdin:close()
