---@mod agent.health :checkhealth agent
local M = {}

local uv = vim.uv

---@return integer
local function max_socket_path()
  return uv.os_uname().sysname == 'Linux' and 107 or 103
end

---True for a TCP address (host:port) or a Windows named pipe, where sun_path limits do not apply.
---@param addr string
---@return boolean
local function is_non_unix(addr)
  return addr:match('^[%w%.%-%[%]:]+:%d+$') ~= nil or addr:sub(1, 2) == '\\\\'
end

local function check_neovim(h)
  h.start('agent.nvim: Neovim')
  local v = vim.version()
  local vs = ('%d.%d.%d'):format(v.major, v.minor, v.patch)
  if vim.fn.has('nvim-0.12') == 1 then
    h.ok('Neovim ' .. vs)
  else
    h.error('Neovim ' .. vs .. ' is too old', { 'agent.nvim needs Neovim 0.12 or newer' })
  end

  local addr = vim.v.servername or ''
  if addr == '' then
    h.warn('v:servername is empty', { 'agent.nvim calls serverstart() before the first launch; agents need $NVIM' })
  else
    h.ok('v:servername: ' .. addr)
    if not is_non_unix(addr) and #addr > max_socket_path() then
      h.error(('the server socket path is %d bytes (limit %d)'):format(#addr, max_socket_path()))
    end
    local _, aerr = require('agent.nvim_mcp').address()
    if aerr then
      h.error(aerr, { 'The $NVIM controller cannot be registered with this address.' })
    end
  end

  local ok, err = require('agent.config').validate(require('agent.config').get())
  if ok then
    h.ok('configuration is valid')
  else
    h.error('invalid configuration: ' .. tostring(err))
  end
  local st = package.loaded['agent'] and package.loaded['agent']._state
  if st and st.setup_done then
    h.ok('setup() has run')
  else
    h.info('setup() has not run yet; the :Agent* commands call setup({}) on first use')
  end
end

local function check_agents(h)
  h.start('agent.nvim: agents')
  local agents = require('agent.agents')
  local cfg = require('agent.config').get()
  for _, name in ipairs(agents.list()) do
    local def = agents.get(name)
    local exe = def.cmd and def.cmd[1]
    local label = ('%s (%s, provider %s)'):format(name, def.kind, def.provider)
    if type(exe) ~= 'string' or exe == '' then
      h.error(label .. ': agents.' .. name .. '.cmd is empty')
    elseif vim.fn.executable(exe) == 1 then
      h.ok(label .. ': ' .. vim.fn.exepath(exe))
    elseif name == cfg.default_agent then
      h.warn(label .. ": executable '" .. exe .. "' not found (it is the default agent)",
        { 'Install it or set agents.' .. name .. '.cmd' })
    else
      h.info(label .. ": executable '" .. exe .. "' not found")
    end
  end
end

---Variables that keep Claude Code from showing its work in its title: a terminal multiplexer (its
---title then always starts with ✳), or titles turned off.
local CLAUDE_TITLE_VARS = { 'TMUX', 'STY', 'ZELLIJ', 'CLAUDE_CODE_DISABLE_TERMINAL_TITLE' }

local function check_progress(h)
  h.start('agent.nvim: progress')
  local progress = require('agent.progress')
  local agents = require('agent.agents')
  if require('agent.config').get().progress.enabled == false then
    h.info('off (progress.enabled = false)')
    return
  end
  h.ok(("the agent's work shows as a progress message (source '%s') and as 'busy' in its terminal")
    :format(progress.SOURCE))
  if progress.host_bar() then
    h.ok("Neovim also shows it as the terminal's progress bar (OSC 9;4)")
  else
    h.info("no terminal progress bar: Neovim did not start in a terminal")
  end
  for _, name in ipairs(agents.list()) do
    local def = agents.get(name)
    if def.kind == 'claude' then
      local set, mux = {}, false
      for _, k in ipairs(CLAUDE_TITLE_VARS) do
        local v = (def.env or {})[k]
        if v == nil then
          v = vim.env[k]
        end
        if v ~= nil and v ~= false and v ~= '' then
          set[#set + 1] = k
          mux = mux or k ~= 'CLAUDE_CODE_DISABLE_TERMINAL_TITLE'
        end
      end
      if #set > 0 then
        h.warn(('%s: %s in its environment, so Claude Code shows no work in its title: no progress')
          :format(name, table.concat(set, ', ')), {
          ('Unset %s for the agent: agents = { %s = { env = { %s = false } } }.%s'):format(
            #set > 1 and 'them' or 'it', name, table.concat(set, ' = false, '),
            mux and ' Claude Code then does not use the multiplexer itself either (e.g. for teammates in '
              .. 'tmux panes).' or ''),
        })
      end
    end
  end
  h.info('OpenCode shows no progress, and Copilot CLI only in the terminals it recognizes (not under '
    .. 'tmux or zellij)')
  if vim.o.messagesopt:find('progress:c', 1, true) then
    h.info('each message also shows in the command line; to hide it: set messagesopt-=progress:c')
  end
  if vim.api.nvim_get_option_info2('statusline', {}).was_set then
    h.info("'statusline' is set: to show the progress there, add %{%v:lua.vim.ui.progress_status()%} "
      .. "and %{&busy > 0 ? '◐ ' : ''}")
  end
end

local function check_notifications(h)
  h.start('agent.nvim: notifications')
  local agents = require('agent.agents')
  if require('agent.config').get().notifications.enabled == false then
    h.info('off (notifications.enabled = false)')
    return
  end
  if require('agent.notifications').host_terminal() then
    h.ok("the agent's desktop notifications (OSC 777) go on to the terminal Neovim runs in")
  else
    h.info('no terminal to pass the notifications on to: Neovim did not start in one')
  end
  -- Claude Code picks its notification channel by TERM_PROGRAM, inherited from Neovim's terminal.
  for _, name in ipairs(agents.list()) do
    local def = agents.get(name)
    if def.kind == 'claude' then
      local tp = (def.env or {}).TERM_PROGRAM
      if tp == nil then
        tp = vim.env.TERM_PROGRAM
      end
      if tp == 'ghostty' then
        h.ok(name .. ': Claude Code sends its notifications as OSC 777 (TERM_PROGRAM=ghostty), with its '
          .. 'Notifications setting (/config) at Auto, the default')
      else
        h.info(('%s: Claude Code sends its notifications as OSC 777 only in Ghostty (TERM_PROGRAM is %s), or '
          .. 'with its Notifications setting (/config) at "Ghostty (OSC 777)"')
          :format(name, (tp == nil or tp == false or tp == '') and 'unset' or tostring(tp)))
      end
    end
  end
end

local function check_providers(h)
  h.start('agent.nvim: IDE providers')
  local cfg = require('agent.config').get()
  local status = require('agent').status().providers
  for _, name in ipairs(require('agent').PROVIDERS) do
    local s = status[name]
    if not s.enabled then
      h.info(name .. ': disabled (providers.' .. name .. '.enabled = false)')
    elseif s.running then
      h.ok(('%s: running, %d client(s), %s%s'):format(name, s.clients or 0, tostring(s.address),
        s.lock and (', ' .. s.lock) or ''))
    else
      h.info(name .. ': not running (' .. (cfg.auto_start and 'auto_start is on: setup() starts it'
        or 'it runs while an agent that uses it runs') .. ')')
    end
  end

  -- Copilot's UDS path must fit in sun_path.
  if status.copilot.enabled then
    local copilot = require('agent.providers.copilot')
    if status.copilot.running and status.copilot.address then
      local p = status.copilot.address
      if is_non_unix(p) or #p <= copilot.MAX_SOCKET_PATH then
        h.ok(('copilot socket path: %d bytes (limit %d)'):format(#p, copilot.MAX_SOCKET_PATH))
      else
        h.error(('copilot socket path is %d bytes (limit %d)'):format(#p, copilot.MAX_SOCKET_PATH))
      end
    else
      local p, err = copilot.socket_path()
      if p then
        h.ok(('copilot socket path would be %d bytes (limit %d): %s'):format(#p, copilot.MAX_SOCKET_PATH, p))
      else
        h.error('copilot: ' .. tostring(err), { 'Set providers.copilot.socket_dir to a short directory' })
      end
    end
  end
end

local function check_claude(h)
  h.start('agent.nvim: Claude Code')
  local agents = require('agent.agents')
  local reason = agents.claude_mcp_block_reason()
  if reason then
    h.warn('Claude refuses --mcp-config: ' .. reason, {
      'agent.nvim then launches Claude without the $NVIM controller (a warning is shown).',
      'Set agents.claude.mcp = false to silence it.',
    })
  else
    h.ok('no managed policy (managed-mcp.json, disableSideloadFlags) blocks --mcp-config in: '
      .. table.concat(agents.claude_managed_dirs(), ', '))
  end
  local auto = vim.env.CLAUDE_CODE_AUTO_CONNECT_IDE
  if auto and (auto:lower() == 'false' or auto == '0') then
    h.warn('CLAUDE_CODE_AUTO_CONNECT_IDE=' .. auto .. ': Claude will not connect automatically (use /ide)')
  end
  h.info('lock directory: ' .. require('agent.providers.claude').lock_dir())
end

local function check_gemini(h)
  h.start('agent.nvim: Gemini CLI')
  local gs = require('agent.gemini_setup')
  local cfg = require('agent.config').get()
  local def = require('agent.agents').get('gemini')
  local installed = def ~= nil and type(def.cmd) == 'table' and type(def.cmd[1]) == 'string'
    and vim.fn.executable(def.cmd[1]) == 1
  -- Missing settings only matter when Gemini is actually installed.
  local warn = installed and h.warn or h.info
  -- The environment agent.nvim launches Gemini with: agents.gemini.env may set GEMINI_CLI_HOME.
  local environ = gs.agent_environ()
  local enabled, source = gs.ide_enabled({ environ = environ })
  if enabled then
    h.ok('ide.enabled is true' .. (source and (' (' .. source .. ')') or ''))
  else
    warn('ide.enabled is not true in your Gemini settings', {
      'Run /ide enable once inside Gemini CLI (agent.nvim never writes your Gemini settings).',
    })
  end
  local mcp = cfg.nvim_mcp.enabled ~= false and (not def or def.mcp ~= false)
  if gs.is_linked({ environ = environ }) then
    h.ok('the ' .. gs.EXTENSION_NAME .. ' extension is linked')
  elseif mcp then
    warn('the ' .. gs.EXTENSION_NAME .. ' extension is not linked, so Gemini cannot use the $NVIM controller',
      { 'Run :AgentGeminiSetup once' })
  else
    h.info('the ' .. gs.EXTENSION_NAME .. ' extension is not linked (MCP is disabled for gemini)')
  end
  local manifest = gs.manifest_path()
  if vim.fn.filereadable(manifest) == 1 then
    h.info('extension manifest: ' .. manifest)
  end
end

local function check_nvim_mcp(h)
  h.start('agent.nvim: $NVIM controller (nvim_mcp)')
  local cfg = require('agent.config').get()
  local nvim_mcp = require('agent.nvim_mcp')
  if cfg.nvim_mcp.enabled == false then
    h.info('disabled (nvim_mcp.enabled = false)')
  end
  local name = cfg.nvim_mcp.server_name
  local ok, err = require('agent.agents').valid_server_name(name)
  if ok then
    h.ok(('server name %q (tool names: Claude mcp__%s__exec_lua, Copilot %s-exec_lua, Gemini mcp_%s_exec_lua, '
      .. 'OpenCode %s_exec_lua)'):format(name, name, name, name, name))
  else
    h.error(('server name %q %s'):format(tostring(name), tostring(err)))
  end
  local script = nvim_mcp.script_path()
  if vim.fn.filereadable(script) == 1 then
    h.ok('controller: ' .. script)
  else
    h.error('controller script not found: ' .. script)
  end
  if vim.fn.executable(vim.v.progpath) == 1 then
    h.ok('per-launch command uses v:progpath: ' .. vim.v.progpath)
  else
    h.error('v:progpath is not executable: ' .. tostring(vim.v.progpath))
  end
  local stable = nvim_mcp.stable_nvim()
  local on_path = vim.fn.exepath('nvim')
  if on_path == '' then
    h.warn('nvim is not on $PATH; persisted configs (Gemini manifest, :AgentMcpConfig) use ' .. stable)
  elseif stable ~= on_path then
    h.warn(('the nvim on $PATH (%s) is not the running nvim; persisted configs use %s'):format(on_path, stable),
      { 'That path changes when Neovim is upgraded. Put the running nvim first on $PATH.' })
  else
    h.ok('persisted configs use ' .. stable)
  end
end

---Entry point for :checkhealth agent.
function M.check()
  local h = vim.health
  check_neovim(h)
  check_agents(h)
  check_progress(h)
  check_notifications(h)
  check_providers(h)
  check_claude(h)
  check_gemini(h)
  check_nvim_mcp(h)
end

return M
