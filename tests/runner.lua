-- Usage: nvim --headless -u NONE -i NONE -n -l tests/runner.lua <spec_file>
local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.rtp:prepend(root)
package.path = root .. '/tests/?.lua;' .. package.path
_G.TEST_ROOT = root
local H = require('harness')
local file = arg[1]
if not file then
  io.stderr:write('usage: runner.lua <spec_file>\n')
  os.exit(2)
end
io.stdout:write('# ' .. file .. '\n')
local ok, err = xpcall(dofile, debug.traceback, file)
if not ok then
  io.stdout:write('not ok - loading ' .. file .. '\n  ' .. tostring(err):gsub('\n', '\n  ') .. '\n')
  vim.cmd.cquit({ count = 1, bang = true })
end
local failures = H.run()
-- :cquit runs Neovim's normal teardown (unlike os.exit), so the server socket and temp dir are removed.
vim.cmd.cquit({ count = failures > 0 and 1 or 0, bang = true })
