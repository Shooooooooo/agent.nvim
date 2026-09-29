-- Test fixture for tests/node/provider_copilot.test.mjs: a headless Neovim hosting the Copilot
-- provider (lua/agent/providers/copilot.lua) with its lock directory redirected to <tmp>/ide.
-- Usage: nvim --headless -u NONE -i NONE -n -l copilot_provider.lua <repo_root> <tmp_dir>
-- Prints one JSON line {lock, socket, ws, ide_dir} once listening. Then reads commands from stdin,
-- one per line ("<word> [json]"), and prints one JSON line per command:
--   stats | select {path,start:[l,c],end:[l,c]} | cursor {path,line,col} | float
--   terminal {text,col} (a shell terminal that printed text; Visual selection from byte col to the
--   end of the line, forwarded as agent.nvim does) | escape
--   mention {path,start?,end?,pid?} | accept <tab> | reject <tab> | closeui <tab>
--   diffinfo <tab> | diag {path,items} | write {path,text} | buflines <path> | launch {cwd}
--   stop | quit (or EOF)
local root, tmp = arg[1], arg[2]
vim.opt.rtp:prepend(root)
local uv = vim.uv
local api = vim.api

local function out(tbl)
  io.stdout:write(vim.json.encode(tbl) .. '\n')
  io.stdout:flush()
end

local notes = {}
vim.notify = function(msg)
  notes[#notes + 1] = tostring(msg)
  io.stderr:write('[copilot fixture] ' .. tostring(msg) .. '\n')
end

local ws = tmp .. '/ws'
vim.fn.mkdir(ws, 'p')
vim.cmd.cd(vim.fn.fnameescape(ws))
local ide_dir = tmp .. '/ide'
require('agent.config').setup({ log_level = 'error', providers = { copilot = { lock_dir = ide_dir } },
  selection = { track = true } })

local P = require('agent.providers.copilot')
local diff = require('agent.editor.diff')

local ok, err = P.start()
if not ok then
  io.stderr:write('start failed: ' .. tostring(err) .. '\n')
  os.exit(1)
end
local status = P.status()
out({ lock = status.lock, socket = status.address, ws = uv.fs_realpath(ws), ide_dir = ide_dir })

local function edit(path)
  vim.cmd('edit ' .. vim.fn.fnameescape(path))
  return api.nvim_get_current_buf()
end

local handlers = {}

function handlers.stats()
  local s = P.status()
  local sessions = {}
  for _, x in ipairs(s.sessions) do
    sessions[#sessions + 1] = {
      id = x.id,
      copilot_session_id = x.copilot_session_id or vim.NIL,
      pid = x.pid or vim.NIL,
      streaming = x.streaming,
      name = x.name or vim.NIL,
    }
  end
  return {
    running = s.running,
    clients = s.clients,
    sessions = sessions,
    pending = s.pending_diffs,
    diffs = diff.list(),
    locks = s.locks,
    notes = notes,
  }
end

function handlers.select(a)
  local buf = edit(a.path)
  local text = table.concat(api.nvim_buf_get_text(buf, a.start[1], a.start[2], a['end'][1], a['end'][2], {}), '\n')
  P.on_selection({
    path = api.nvim_buf_get_name(buf),
    bufnr = buf,
    text = text,
    start = { line = a.start[1], character = a.start[2] },
    finish = { line = a['end'][1], character = a['end'][2] },
    is_empty = text == '',
  })
  return { ok = true, text = text }
end

function handlers.cursor(a)
  edit(a.path)
  api.nvim_win_set_cursor(0, { a.line, a.col })
  return { ok = true }
end

-- A floating window (a picker): ignored by selection tracking.
function handlers.float()
  api.nvim_open_win(api.nvim_create_buf(false, true), true, { relative = 'editor', row = 1, col = 1, width = 20, height = 3 })
  return { ok = true }
end

function handlers.terminal(a)
  vim.cmd('botright vnew')
  local job = vim.fn.jobstart({ '/bin/sh', '-c', 'printf "%s\\n" "$0"; exec sleep 60', a.text }, { term = true })
  local buf = api.nvim_get_current_buf()
  local shown = vim.wait(5000, function()
    return api.nvim_buf_get_lines(buf, 0, 1, false)[1] == a.text
  end, 20)
  api.nvim_win_set_cursor(0, { 1, a.col })
  vim.cmd('normal! vg_')
  local sel = require('agent.editor.selection').current()
  P.on_selection(sel)
  return { ok = shown and job > 0, bufnr = buf, path = sel and sel.path or vim.NIL, text = sel and sel.text or vim.NIL }
end

function handlers.escape()
  vim.cmd('normal! \27')
  return { ok = true }
end

function handlers.mention(a)
  return { sent = P.at_mention(a.path, a.start, a['end'], { pid = a.pid }), state = P.client_state({ pid = a.pid }) or vim.NIL }
end

function handlers.accept(tab)
  local r, e = diff.accept(tab)
  return { ok = r, err = e or vim.NIL }
end

function handlers.reject(tab)
  local r, e = diff.reject(tab)
  return { ok = r, err = e or vim.NIL }
end

function handlers.closeui(tab)
  local d = diff.get(tab)
  if not d then
    return { ok = false }
  end
  vim.cmd('bwipeout! ' .. d.bufnr)
  return { ok = true }
end

function handlers.diffinfo(tab)
  local d = diff.get(tab)
  if not d then
    return { open = false }
  end
  return {
    open = true,
    path = d.path,
    editable = d.editable,
    modifiable = vim.bo[d.bufnr].modifiable,
    proposed = api.nvim_buf_get_lines(d.bufnr, 0, -1, false),
    original = api.nvim_buf_get_lines(d.orig_bufnr, 0, -1, false),
  }
end

function handlers.diag(a)
  local buf = edit(a.path)
  local ns = api.nvim_create_namespace('copilot_fixture')
  vim.diagnostic.set(ns, buf, a.items)
  return { ok = true }
end

function handlers.write(a)
  local f = assert(io.open(a.path, 'w'))
  f:write(a.text)
  f:close()
  return { ok = true }
end

function handlers.buflines(path)
  local b = require('agent.editor.context').find_buf(path, { loaded = true })
  return { lines = b and api.nvim_buf_get_lines(b, 0, -1, false) or vim.NIL }
end

function handlers.launch(a)
  local info, e = P.launch_info({ cwd = a.cwd })
  return { info = info or vim.NIL, err = e or vim.NIL }
end

function handlers.stop()
  P.stop()
  return { ok = true }
end

local quit = false
local stdin = uv.new_pipe(false)
stdin:open(0)
local pending = ''
stdin:read_start(function(rerr, chunk)
  if rerr or not chunk then
    quit = true
    return
  end
  pending = pending .. chunk
  for line in pending:gmatch('([^\n]*)\n') do
    vim.schedule(function()
      local word, rest = line:match('^(%S+)%s*(.*)$')
      if word == 'quit' then
        quit = true
        return
      end
      local h = handlers[word or '']
      if not h then
        out({ error = 'unknown command ' .. tostring(word) })
        return
      end
      local arg1 = rest
      if rest:sub(1, 1) == '{' then
        arg1 = vim.json.decode(rest)
      end
      local okh, res = pcall(h, arg1)
      out(okh and res or { error = tostring(res) })
    end)
  end
  pending = pending:match('[^\n]*$')
end)

vim.wait(300000, function()
  return quit
end, 20)
P.stop()
vim.wait(100)
stdin:close()
