-- Entry point of the $NVIM controller, a stdio MCP server:
--
--   nvim --headless -u NONE -i NONE -n -l <plugin>/lua/agent/nvim_mcp/main.lua [<addr>]
--
-- <addr> is the parent Neovim's server address (v:servername). It falls back to $NVIM; an empty
-- value or an unexpanded placeholder such as "${NVIM}" counts as absent, and then the server
-- completes the MCP handshake with zero tools. The process always exits with status 0.

local function plugin_lua_dir()
  local src = debug.getinfo(1, 'S').source
  if src:sub(1, 1) == '@' then
    src = src:sub(2)
  end
  -- <root>/lua/agent/nvim_mcp/main.lua -> <root>/lua
  return vim.fn.fnamemodify(vim.fn.fnamemodify(src, ':p'), ':h:h:h')
end

local ok, err = xpcall(function()
  local lua_dir = plugin_lua_dir()
  package.path = lua_dir .. '/?.lua;' .. lua_dir .. '/?/init.lua;' .. package.path
  vim.opt.rtp:prepend(vim.fn.fnamemodify(lua_dir, ':h'))

  -- Every `nvim -l` starts its own RPC server; this process does not need one.
  if vim.v.servername ~= '' then
    pcall(vim.fn.serverstop, vim.v.servername)
  end

  local server = require('agent.nvim_mcp.server')
  local args = _G.arg or {}
  server.run({ addr = server.resolve_address(args[1], vim.env.NVIM) })
end, debug.traceback)

if not ok then
  io.stderr:write('[agent.nvim nvim_mcp] fatal: ', tostring(err), '\n')
end
