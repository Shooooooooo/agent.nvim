-- Test fixture for tests/node/provider_claude.test.mjs.
-- Usage: nvim --headless -u NONE -i NONE -n -l provider_claude.lua <repo_root> <lock_dir> <workspace>
-- Starts agent.providers.claude with its lock in <lock_dir>, cwd = <workspace>, and prints one JSON
-- line {port, token, lock}. stdin: one JSON command per line, {"id":n,"lua":"<chunk>"}; the chunk
-- runs on the main loop with `P` (the provider) and `diff` (agent.editor.diff) in scope, and one
-- JSON line {"id":n,"ok":bool,"result":...} is printed. "quit" (or EOF) stops the provider and exits.
local root, lock_dir, workspace = arg[1], arg[2], arg[3]
vim.opt.rtp:prepend(root)

vim.notify = function(msg)
  io.stderr:write('[provider_claude] ' .. tostring(msg) .. '\n')
end

local function out(tbl)
  io.stdout:write(vim.json.encode(tbl) .. '\n')
  io.stdout:flush()
end

vim.cmd.cd(vim.fn.fnameescape(workspace))
require('agent.config').setup({
  providers = { claude = { lock_dir = lock_dir, notify_delay_ms = 600 } },
})
local P = require('agent.providers.claude')
local diff = require('agent.editor.diff')
local ok, err = P.start()
if not ok then
  out({ error = err })
  os.exit(1)
end
out({ port = P.status().port, token = P._state.token, lock = P.status().lock })

local env = setmetatable({ P = P, diff = diff }, { __index = _G })
local quit = false
local stdin = vim.uv.new_pipe(false)
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
      if line == 'quit' then
        quit = true
        return
      end
      local dok, cmd = pcall(vim.json.decode, line)
      if not dok or type(cmd) ~= 'table' then
        return
      end
      local fn, lerr = loadstring(cmd.lua)
      if not fn then
        out({ id = cmd.id, ok = false, result = lerr })
        return
      end
      setfenv(fn, env)
      local rok, res = pcall(fn)
      if not rok then
        res = tostring(res)
      elseif res == nil then
        res = vim.NIL
      end
      out({ id = cmd.id, ok = rok, result = res })
    end)
  end
  pending = pending:match('[^\n]*$')
end)

vim.wait(600000, function()
  return quit
end, 20)
P.stop()
vim.wait(200)
stdin:close()
