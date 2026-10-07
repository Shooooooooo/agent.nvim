local agents = require('agent.agents')
local gemini = require('agent.gemini_setup')
local config = require('agent.config')
local util = require('agent.util')

local ADDR = '/tmp/nvim.test/abc/nvim.4242.0'
local tmp, proj, ghome

local function read(path)
  local f = io.open(path, 'rb')
  if not f then
    return nil
  end
  local s = f:read('*a')
  f:close()
  return s
end

local function write(path, data)
  util.mkdir_p(vim.fs.dirname(path), tonumber('700', 8))
  local f = assert(io.open(path, 'wb'))
  f:write(data)
  f:close()
end

local function mode(path)
  return bit.band(vim.uv.fs_stat(path).mode, tonumber('777', 8))
end

local function server_args(addr)
  return { '--headless', '-u', 'NONE', '-i', 'NONE', '-n', '-l', agents.NVIM_MCP_MAIN, addr or ADDR }
end

local function server_env(kind)
  return { NVIM = ADDR, AGENT_NVIM_AGENT = kind, AGENT_NVIM_SESSION = 'sid-1', AGENT_NVIM_TIMEOUT_MS = '30000' }
end

---Base options that keep every file inside the test's temp dir.
local function o(extra)
  return vim.tbl_extend('force', {
    cwd = proj,
    session_id = 'sid-1',
    servername = ADDR,
    environ = { PATH = '/usr/bin:/bin', HOME = tmp .. '/home', GEMINI_CLI_HOME = ghome },
    sessions_dir = tmp .. '/sessions',
    claude_managed_dirs = { tmp .. '/managed' },
    gemini_extension_dir = tmp .. '/gemext',
    gemini_system_settings_path = tmp .. '/gsys/settings.json',
    gemini_system_defaults_path = tmp .. '/gsys/system-defaults.json',
  }, extra or {})
end

local function warning_ids(spec)
  local ids = {}
  for _, w in ipairs(spec.warnings) do
    ids[#ids + 1] = w.id
  end
  table.sort(ids)
  return ids
end

local LOOPBACK = 'localhost,127.0.0.1,::1'

local orig_secure = gemini.system_file_secure

describe('agents', function()
  before_each(function()
    config.setup({})
    -- The Gemini "system" settings files of these tests live in a user-owned temp dir.
    gemini.system_file_secure = function()
      return true
    end
    tmp = util.realpath(vim.fn.tempname())
    util.mkdir_p(tmp, tonumber('700', 8))
    tmp = util.realpath(tmp)
    proj = tmp .. '/proj'
    ghome = tmp .. '/ghome'
    util.mkdir_p(proj, tonumber('700', 8))
    util.mkdir_p(ghome, tonumber('700', 8))
  end)

  after_each(function()
    gemini.system_file_secure = orig_secure
    util.remove_dir(tmp)
  end)

  describe('registry', function()
    it('lists and resolves agents', function()
      assert.same({ 'claude', 'copilot', 'gemini', 'opencode' }, agents.list())
      local def = agents.get('opencode')
      assert.eq('opencode', def.name)
      assert.eq('opencode', def.kind)
      assert.eq('claude', def.provider)
      assert.eq(nil, agents.get('nope'))
      local spec, err = agents.build_launch('nope', o())
      assert.eq(nil, spec)
      assert.matches('unknown agent', err)
    end)

    it('custom agents pick a recipe from kind or provider', function()
      config.setup({ agents = { work = { cmd = { 'claude', '--model', 'opus' }, provider = 'claude' },
        cop2 = { cmd = { 'copilot' }, provider = 'copilot' } } })
      assert.eq('claude', agents.get('work').kind)
      assert.eq('copilot', agents.get('cop2').kind)
      local spec = agents.build_launch('work', o())
      assert.same({ 'claude', '--model', 'opus', '--mcp-config=' .. tmp .. '/sessions/sid-1/claude-mcp.json' }, spec.argv)
    end)

    it('the controller argv (agent.nvim_mcp.command) uses v:progpath and passes the address as arg[1]', function()
      assert.same(util.concat({ vim.v.progpath }, server_args('X')), require('agent.nvim_mcp').command('X'))
      assert.eq(require('agent.nvim_mcp').script_path(), agents.NVIM_MCP_MAIN)
      assert.matches('/lua/agent/nvim_mcp/main%.lua$', agents.NVIM_MCP_MAIN)
      assert.eq(1, vim.fn.filereadable(TEST_ROOT .. '/lua/agent/agents.lua'))
      assert.eq(TEST_ROOT .. '/lua/agent/nvim_mcp/main.lua', agents.NVIM_MCP_MAIN)
    end)
  end)

  describe('claude', function()
    it('builds exact argv, env and --mcp-config file', function()
      local spec = assert(agents.build_launch('claude', o({
        user_args = { '--resume', 'fix the bug' },
        ide = { port = 45678, token = 'secret' },
      })))
      local file = tmp .. '/sessions/sid-1/claude-mcp.json'
      assert.same({ 'claude', '--resume', 'fix the bug', '--mcp-config=' .. file }, spec.argv)
      assert.same({
        AGENT_NVIM_SESSION = 'sid-1',
        CLAUDE_CODE_SSE_PORT = '45678',
        FORCE_CODE_TERMINAL = 'true',
        ENABLE_IDE_INTEGRATION = 'true',
        CLAUDE_CODE_IDE_SKIP_AUTO_INSTALL = 'true',
        no_proxy = LOOPBACK,
        NO_PROXY = LOOPBACK,
        ConEmuANSI = 'ON',
      }, spec.env)
      assert.eq(false, spec.clear_env)
      assert.eq(proj, spec.cwd)
      assert.eq('sid-1', spec.session_id)
      assert.same({ tmp .. '/sessions/sid-1' }, spec.cleanup)
      assert.same({ registered = true, server_name = 'nvim', file = file }, spec.mcp)
      assert.same({}, spec.warnings)
      assert.same({
        mcpServers = {
          nvim = { type = 'stdio', command = vim.v.progpath, args = server_args(), env = server_env('claude') },
        },
      }, vim.json.decode(read(file)))
      assert.eq(tonumber('600', 8), mode(file))
      assert.eq(tonumber('700', 8), mode(tmp .. '/sessions/sid-1'))
      assert.eq(1, #spec.exit_hints)
      assert.same({ 'enterprise MCP config', 'disableSideloadFlags' }, spec.exit_hints[1].patterns)
      assert.eq(5000, spec.exit_hints[1].within_ms)
      assert.matches('agents.claude.mcp = false', spec.exit_hints[1].message)
      -- no leftover temp files from the atomic write
      assert.same({ 'claude-mcp.json' }, vim.fn.readdir(tmp .. '/sessions/sid-1'))
      agents.cleanup(spec)
      assert.eq(0, vim.fn.isdirectory(tmp .. '/sessions/sid-1'))
    end)

    it('puts config args, then user args, then plugin args (auto_approve last)', function()
      config.setup({ agents = { claude = { args = { '--model', 'opus' }, auto_approve = true } } })
      local spec = agents.build_launch('claude', o({ user_args = { 'hello' } }))
      assert.same({
        'claude', '--model', 'opus', 'hello',
        '--mcp-config=' .. tmp .. '/sessions/sid-1/claude-mcp.json',
        '--allowedTools=mcp__nvim',
      }, spec.argv)
      spec = agents.build_launch('claude', o({ auto_approve = false, cmd = { '/opt/bin/claude', '--x' } }))
      assert.same({ '/opt/bin/claude', '--x', '--model', 'opus', '--mcp-config=' .. tmp .. '/sessions/sid-1/claude-mcp.json' },
        spec.argv)
    end)

    it('uses the configured server name', function()
      config.setup({ nvim_mcp = { server_name = 'editor' } })
      local spec = agents.build_launch('claude', o({ auto_approve = true }))
      assert.eq('--allowedTools=mcp__editor', spec.argv[#spec.argv])
      local cfg = vim.json.decode(read(tmp .. '/sessions/sid-1/claude-mcp.json'))
      assert.truthy(cfg.mcpServers.editor)
    end)

    it('merges no_proxy with the inherited and configured values', function()
      config.setup({ agents = { claude = { env = { NO_PROXY = 'corp.internal' } } } })
      local spec = agents.build_launch('claude', o({
        environ = { no_proxy = 'example.com, localhost', PATH = '/bin' },
      }))
      assert.eq('example.com,localhost,corp.internal,127.0.0.1,::1', spec.env.no_proxy)
      assert.eq(spec.env.no_proxy, spec.env.NO_PROXY)
    end)

    it('omits IDE env without provider info and warns about CLAUDE_CODE_AUTO_CONNECT_IDE=false', function()
      local spec = agents.build_launch('claude', o())
      assert.same({ AGENT_NVIM_SESSION = 'sid-1', CLAUDE_CODE_IDE_SKIP_AUTO_INSTALL = 'true', no_proxy = LOOPBACK,
        NO_PROXY = LOOPBACK, ConEmuANSI = 'ON' }, spec.env)
      spec = agents.build_launch('claude', o({
        ide = { port = 1 },
        environ = { CLAUDE_CODE_AUTO_CONNECT_IDE = 'false' },
      }))
      assert.same({ 'claude-auto-connect-off' }, warning_ids(spec))
    end)

    it('does not register when disabled per agent or globally', function()
      config.setup({ agents = { claude = { mcp = false } } })
      local spec = agents.build_launch('claude', o({ auto_approve = true }))
      assert.same({ 'claude' }, spec.argv)
      assert.same({}, spec.cleanup)
      assert.eq(false, spec.mcp.registered)
      assert.eq(0, vim.fn.isdirectory(tmp .. '/sessions'))
      config.setup({ nvim_mcp = { enabled = false } })
      assert.same({ 'claude' }, agents.build_launch('claude', o()).argv)
      config.setup({})
      assert.same({ 'claude' }, agents.build_launch('claude', o({ nvim_mcp = { enabled = false } })).argv)
    end)

    it('skips --mcp-config when a managed-mcp.json exists', function()
      write(tmp .. '/managed/managed-mcp.json', 'not even json')
      local spec = agents.build_launch('claude', o({ auto_approve = true, ide = { port = 3 } }))
      assert.same({ 'claude' }, spec.argv)
      assert.same({ 'claude-mcp-managed' }, warning_ids(spec))
      assert.matches('enterprise MCP config', spec.warnings[1].msg)
      assert.same({}, spec.exit_hints)
      assert.same({}, spec.cleanup)
      assert.eq('3', spec.env.CLAUDE_CODE_SSE_PORT)
    end)

    it('skips --mcp-config when managed settings set disableSideloadFlags', function()
      write(tmp .. '/managed/managed-settings.json', '{"disableSideloadFlags": false}')
      assert.eq(nil, agents.claude_mcp_block_reason({ tmp .. '/managed' }))
      write(tmp .. '/managed/managed-settings.d/20-policy.json', '{"disableSideloadFlags": true}')
      write(tmp .. '/managed/managed-settings.d/.hidden.json', '{"disableSideloadFlags": true}')
      local reason = agents.claude_mcp_block_reason({ tmp .. '/managed' })
      assert.matches('disableSideloadFlags.*20%-policy%.json', reason)
      local spec = agents.build_launch('claude', o())
      assert.same({ 'claude' }, spec.argv)
      assert.same({ 'claude-mcp-managed' }, warning_ids(spec))
      util.remove(tmp .. '/managed/managed-settings.d/20-policy.json')
      write(tmp .. '/managed/managed-settings.json', '{"disableSideloadFlags": true}')
      assert.matches('managed%-settings%.json', agents.claude_mcp_block_reason({ tmp .. '/managed' }))
      assert.truthy(vim.tbl_contains(agents.claude_managed_dirs({ CLAUDE_CODE_MANAGED_SETTINGS_PATH = '/x' }), '/x'))
    end)

    it('refuses invalid server names and unsafe addresses', function()
      local spec = agents.build_launch('claude', o({ nvim_mcp = { server_name = 'ide' } }))
      assert.same({ 'claude' }, spec.argv)
      assert.same({ 'mcp-server-name' }, warning_ids(spec))
      spec = agents.build_launch('claude', o({ nvim_mcp = { server_name = 'has_underscore' } }))
      assert.same({ 'mcp-server-name' }, warning_ids(spec))
      spec = agents.build_launch('claude', o({ servername = '/tmp/${HOME}/sock' }))
      assert.same({ 'claude' }, spec.argv)
      assert.same({ 'mcp-bad-addr' }, warning_ids(spec))
    end)

    it('launches without MCP when the temp dir cannot be created', function()
      write(tmp .. '/afile', 'x')
      local spec = agents.build_launch('claude', o({ sessions_dir = tmp .. '/afile' }))
      assert.same({ 'claude' }, spec.argv)
      assert.same({ 'mcp-tempfile' }, warning_ids(spec))
      assert.eq(false, spec.mcp.registered)
    end)

    it('defaults the temp dir to util.run_dir("sessions", id) and the session id to a uuid', function()
      local opts = o()
      opts.sessions_dir = nil
      opts.session_id = nil
      local spec = agents.build_launch('claude', opts)
      assert.matches('^%x+%-%x+%-4%x+%-%x+%-%x+$', spec.session_id)
      local dir = spec.cleanup[1]
      assert.eq(util.run_dir('sessions', spec.session_id), dir)
      assert.eq(tonumber('700', 8), mode(dir))
      assert.eq('--mcp-config=' .. dir .. '/claude-mcp.json', spec.argv[#spec.argv])
      agents.cleanup(spec)
      assert.eq(0, vim.fn.isdirectory(dir))
      util.remove_dir(vim.fs.joinpath(vim.fn.stdpath('run'), 'agent.nvim'))
    end)
  end)

  describe('copilot', function()
    it('builds exact argv, JSON (tools ["*"]) and uses the lock folder as cwd', function()
      local spec = assert(agents.build_launch('copilot', o({
        user_args = { '--model', 'gpt-5' },
        ide = { lock_folder = '/work/repo' },
        auto_approve = true,
      })))
      local file = tmp .. '/sessions/sid-1/copilot-mcp.json'
      assert.same({ 'copilot', '--model', 'gpt-5', '--additional-mcp-config', '@' .. file, '--allow-tool=nvim' }, spec.argv)
      assert.same({ AGENT_NVIM_SESSION = 'sid-1', ConEmuANSI = 'ON' }, spec.env)
      assert.eq(false, spec.clear_env)
      assert.eq('/work/repo', spec.cwd)
      assert.same({
        mcpServers = {
          nvim = { type = 'stdio', command = vim.v.progpath, args = server_args(), env = server_env('copilot'),
            tools = { '*' } },
        },
      }, vim.json.decode(read(file)))
      assert.eq(tonumber('600', 8), mode(file))
    end)

    it('falls back to the realpath of cwd and omits --allow-tool by default', function()
      vim.uv.fs_symlink(proj, tmp .. '/link')
      local spec = agents.build_launch('copilot', o({ cwd = tmp .. '/link' }))
      assert.eq(proj, spec.cwd)
      assert.same({ 'copilot', '--additional-mcp-config', '@' .. tmp .. '/sessions/sid-1/copilot-mcp.json' }, spec.argv)
    end)
  end)

  describe('gemini', function()
    local manifest_path

    before_each(function()
      manifest_path = tmp .. '/gemext/gemini-extension.json'
    end)

    local function expected_manifest(name)
      return {
        name = 'agent-nvim',
        version = '1.0.0',
        description = gemini.DESCRIPTION,
        mcpServers = {
          [name or 'nvim'] = {
            command = gemini.stable_nvim(),
            args = server_args('${NVIM}'),
            env = {
              NVIM = '${NVIM}',
              AGENT_NVIM_AGENT = 'gemini',
              AGENT_NVIM_SESSION = '${AGENT_NVIM_SESSION}',
              AGENT_NVIM_TIMEOUT_MS = '30000',
            },
          },
        },
      }
    end

    it('builds exact env, writes the manifest atomically, and hints at setup', function()
      local spec = assert(agents.build_launch('gemini', o({
        user_args = { '-m', 'gemini-2.5-pro' },
        ide = { port = 4000, token = 'tok', pid = 99 },
        environ = { GEMINI_CLI_HOME = ghome, GEMINI_CLI_IDE_SERVER_PORT = '1', GEMINI_CLI_IDE_WORKSPACE_PATH = '/a:/b' },
      })))
      assert.same({ 'gemini', '-m', 'gemini-2.5-pro' }, spec.argv)
      assert.same({
        AGENT_NVIM_SESSION = 'sid-1',
        GEMINI_CLI_IDE_SERVER_PORT = '4000',
        GEMINI_CLI_IDE_WORKSPACE_PATH = proj,
        GEMINI_CLI_IDE_AUTH_TOKEN = 'tok',
        GEMINI_CLI_IDE_PID = '99',
        GEMINI_CLI_IDE_SERVER_STDIO_COMMAND = '',
      }, spec.env)
      assert.eq(false, spec.clear_env)
      assert.eq(proj, spec.cwd)
      assert.same({}, spec.cleanup)
      assert.same({ registered = true, server_name = 'nvim', file = manifest_path }, spec.mcp)
      assert.same(expected_manifest(), vim.json.decode(read(manifest_path)))
      assert.same({ 'gemini-extension.json' }, vim.fn.readdir(tmp .. '/gemext'))
      assert.eq(tonumber('700', 8), mode(tmp .. '/gemext'))
      assert.same({ 'gemini-ide-disabled', 'gemini-not-linked' }, warning_ids(spec))
    end)

    it('defaults the IDE pid to Neovim and neutralizes an inherited stdio fallback', function()
      local spec = agents.build_launch('gemini', o({
        ide = { port = 4000, token = 'tok' },
        environ = { GEMINI_CLI_HOME = ghome, GEMINI_CLI_IDE_SERVER_STDIO_ARGS = '["x"]' },
      }))
      assert.eq(tostring(vim.fn.getpid()), spec.env.GEMINI_CLI_IDE_PID)
      assert.eq('', spec.env.GEMINI_CLI_IDE_SERVER_STDIO_COMMAND)
      assert.eq('', spec.env.GEMINI_CLI_IDE_SERVER_STDIO_ARGS)
    end)

    it('blanks inherited GEMINI_CLI_IDE_* variables when there is no Gemini provider', function()
      local vscode = {
        GEMINI_CLI_IDE_SERVER_PORT = '1234',
        GEMINI_CLI_IDE_WORKSPACE_PATH = '/other-repo:/secrets',
        GEMINI_CLI_IDE_AUTH_TOKEN = 'vscode-token',
        GEMINI_CLI_IDE_PID = '77',
        GEMINI_CLI_IDE_SERVER_STDIO_COMMAND = 'x',
        GEMINI_CLI_IDE_SERVER_STDIO_ARGS = '["y"]',
      }
      local spec = agents.build_launch('gemini', o({ environ = vim.tbl_extend('force', { GEMINI_CLI_HOME = ghome }, vscode) }))
      for k in pairs(vscode) do
        assert.eq('', spec.env[k], k)
      end
      assert.eq(false, spec.clear_env)
      -- Nothing inherited: nothing added.
      spec = agents.build_launch('gemini', o())
      for k in pairs(vscode) do
        assert.eq(nil, spec.env[k], k)
      end
      -- A value set explicitly in the agent config is the user's choice and is kept.
      config.setup({ agents = { gemini = { env = { GEMINI_CLI_IDE_WORKSPACE_PATH = '/x' } } } })
      spec = agents.build_launch('gemini', o({ environ = vim.tbl_extend('force', { GEMINI_CLI_HOME = ghome }, vscode) }))
      assert.eq('/x', spec.env.GEMINI_CLI_IDE_WORKSPACE_PATH)
      assert.eq('', spec.env.GEMINI_CLI_IDE_SERVER_PORT)
    end)

    it('reads ide.enabled and the link state read-only (GEMINI_CLI_HOME)', function()
      write(ghome .. '/.gemini/settings.json', '// user settings\n{ "ide": { /* on */ "enabled": true }, "x": "a//b" }\n')
      util.mkdir_p(ghome .. '/.gemini/extensions/agent-nvim', tonumber('700', 8))
      local before = read(ghome .. '/.gemini/settings.json')
      local spec = agents.build_launch('gemini', o({ ide = { port = 1, token = 't' } }))
      assert.same({}, warning_ids(spec))
      assert.eq(before, read(ghome .. '/.gemini/settings.json'))
      -- system overrides win over the user file
      write(tmp .. '/gsys/settings.json', '{"ide":{"enabled":false}}')
      spec = agents.build_launch('gemini', o({ ide = { port = 1, token = 't' } }))
      assert.same({ 'gemini-ide-disabled' }, warning_ids(spec))
    end)

    it('adds agent-nvim to an explicit -e list, but not to "none"', function()
      local function tail(args)
        local spec = agents.build_launch('gemini', o({ user_args = args }))
        return spec.argv, warning_ids(spec)
      end
      assert.same({ 'gemini', '-e', 'foo', '--extensions=agent-nvim' }, (tail({ '-e', 'foo' })))
      assert.same({ 'gemini', '--extensions=foo,bar', '--extensions=agent-nvim' }, (tail({ '--extensions=foo,bar' })))
      assert.same({ 'gemini', '-e', 'foo,AGENT-NVIM' }, (tail({ '-e', 'foo,AGENT-NVIM' })))
      local argv, ids = tail({ '-e', 'none' })
      assert.same({ 'gemini', '-e', 'none' }, argv)
      assert.truthy(vim.tbl_contains(ids, 'gemini-extensions-none'))
      assert.same({ 'gemini', '--', '-e', 'x' }, (tail({ '--', '-e', 'x' })))
    end)

    it('appends the server name to an explicit --allowed-mcp-server-names', function()
      local spec = agents.build_launch('gemini', o({ user_args = { '--allowed-mcp-server-names', 'github' } }))
      assert.same({ 'gemini', '--allowed-mcp-server-names', 'github', '--allowed-mcp-server-names=nvim' }, spec.argv)
      spec = agents.build_launch('gemini', o({ user_args = { '--allowed-mcp-server-names=github,nvim' } }))
      assert.same({ 'gemini', '--allowed-mcp-server-names=github,nvim' }, spec.argv)
      -- Gemini compares these names exactly.
      spec = agents.build_launch('gemini', o({ user_args = { '--allowed-mcp-server-names=NVIM' } }))
      assert.same({ 'gemini', '--allowed-mcp-server-names=NVIM', '--allowed-mcp-server-names=nvim' }, spec.argv)
    end)

    it('warns once when mcp.allowed / mcp.excluded in the Gemini settings block the server', function()
      write(ghome .. '/.gemini/settings.json', '{"mcp":{"allowed":["github"]}}')
      local spec = agents.build_launch('gemini', o())
      assert.truthy(vim.tbl_contains(warning_ids(spec), 'gemini-mcp-blocked'))
      for _, w in ipairs(spec.warnings) do
        if w.id == 'gemini-mcp-blocked' then
          assert.matches('mcp%.allowed', w.msg)
          assert.eq(vim.log.levels.INFO, w.level)
        end
      end
      -- --allowed-mcp-server-names replaces the settings (and gets the server name appended).
      spec = agents.build_launch('gemini', o({ user_args = { '--allowed-mcp-server-names=github' } }))
      assert.falsy(vim.tbl_contains(warning_ids(spec), 'gemini-mcp-blocked'))
      config.setup({ agents = { gemini = { mcp = false } } })
      assert.falsy(vim.tbl_contains(warning_ids(agents.build_launch('gemini', o())), 'gemini-mcp-blocked'))
    end)

    it('auto_approve re-lists the user policy locations before its own --policy file', function()
      write(ghome .. '/.gemini/settings.json', '{\n  // comment\n  "policyPaths": ["~/pol", "$HOME/p2", "${HOME}/p2"]\n}')
      write(proj .. '/.gemini/settings.json', '{"policyPaths": ["rel/policies", "~/pol"]}')
      write(ghome .. '/.gemini/trustedFolders.json', vim.json.encode({ [proj] = 'TRUST_FOLDER' }))
      local spec = agents.build_launch('gemini', o({ auto_approve = true, user_args = { 'prompt' } }))
      local toml = tmp .. '/sessions/sid-1/agent-nvim.toml'
      assert.same({
        'gemini', 'prompt',
        '--policy=' .. ghome .. '/.gemini/policies',
        '--policy=~/pol',
        '--policy=' .. tmp .. '/home/p2',
        '--policy=rel/policies',
        '--policy=' .. toml,
      }, spec.argv)
      assert.eq('[[rule]]\nmcpName = "nvim"\ntoolName = "*"\ndecision = "allow"\npriority = 1\n', read(toml))
      assert.eq(tonumber('600', 8), mode(toml))
      assert.same({ tmp .. '/sessions/sid-1' }, spec.cleanup)
    end)

    it('auto_approve never re-lists policyPaths of a folder Gemini does not trust', function()
      write(proj .. '/.gemini/settings.json', '{"policyPaths": ["evilpol"]}')
      local toml = '--policy=' .. tmp .. '/sessions/sid-1/agent-nvim.toml'
      local own = { 'gemini', '--policy=' .. ghome .. '/.gemini/policies', toml }
      -- Unknown folder, then one marked DO_NOT_TRUST, then --skip-trust (which does not make
      -- Gemini load the workspace settings: they are read before the flag is parsed).
      assert.same(own, agents.build_launch('gemini', o({ auto_approve = true })).argv)
      write(ghome .. '/.gemini/trustedFolders.json', vim.json.encode({ [proj] = 'DO_NOT_TRUST' }))
      assert.same(own, agents.build_launch('gemini', o({ auto_approve = true })).argv)
      assert.same(util.concat(own, { '--skip-trust' }),
        agents.build_launch('gemini', o({ auto_approve = true, skip_trust = true })).argv)
      -- GEMINI_CLI_TRUST_WORKSPACE=true in the agent env does make Gemini trust it.
      local spec = agents.build_launch('gemini', o({ auto_approve = true, env = { GEMINI_CLI_TRUST_WORKSPACE = 'true' } }))
      assert.truthy(vim.tbl_contains(spec.argv, '--policy=evilpol'))
    end)

    it('auto_approve keeps a user --policy as is and adds only its own file', function()
      local spec = agents.build_launch('gemini', o({ auto_approve = true, user_args = { '--policy', '/mine' } }))
      assert.same({ 'gemini', '--policy', '/mine', '--policy=' .. tmp .. '/sessions/sid-1/agent-nvim.toml' }, spec.argv)
    end)

    it('auto_approve is skipped when a settings file cannot be parsed', function()
      write(ghome .. '/.gemini/settings.json', '{ "policyPaths": [ }')
      local spec = agents.build_launch('gemini', o({ auto_approve = true }))
      assert.same({ 'gemini' }, spec.argv)
      assert.truthy(vim.tbl_contains(warning_ids(spec), 'gemini-policy'))
      assert.same({}, spec.cleanup)
    end)

    it('passes --skip-trust only with skip_trust', function()
      assert.same({ 'gemini' }, agents.build_launch('gemini', o()).argv)
      config.setup({ agents = { gemini = { skip_trust = true } } })
      assert.same({ 'gemini', 'q', '--skip-trust' }, agents.build_launch('gemini', o({ user_args = { 'q' } })).argv)
      config.setup({ agents = { gemini = { mcp = false } } })
      assert.same({ 'gemini', '--skip-trust' }, agents.build_launch('gemini', o({ skip_trust = true })).argv)
    end)

    it('does not touch the manifest when MCP is disabled', function()
      config.setup({ agents = { gemini = { mcp = false } } })
      local spec = agents.build_launch('gemini', o({ user_args = { '-e', 'foo' }, auto_approve = true }))
      assert.same({ 'gemini', '-e', 'foo' }, spec.argv)
      assert.eq(nil, read(manifest_path))
      assert.eq(false, spec.mcp.registered)
      assert.eq('sid-1', spec.env.AGENT_NVIM_SESSION)
    end)

    it('skips an unchanged manifest and rewrites a changed one', function()
      agents.build_launch('gemini', o())
      local st1 = vim.uv.fs_stat(manifest_path)
      agents.build_launch('gemini', o())
      assert.eq(st1.ino, vim.uv.fs_stat(manifest_path).ino)
      config.setup({ nvim_mcp = { server_name = 'editor' } })
      agents.build_launch('gemini', o())
      assert.same(expected_manifest('editor'), vim.json.decode(read(manifest_path)))
      assert.same({ 'gemini-extension.json' }, vim.fn.readdir(tmp .. '/gemext'))
    end)
  end)

  describe('opencode', function()
    local function expected_cfg(extra)
      local cfg = {
        ['$schema'] = 'https://opencode.ai/config.json',
        mcp = {
          nvim = {
            type = 'local',
            command = util.concat({ vim.v.progpath }, server_args()),
            environment = server_env('opencode'),
            enabled = true,
            timeout = 600000,
          },
        },
      }
      return vim.tbl_deep_extend('force', cfg, extra or {})
    end

    it('builds exact env with OPENCODE_CONFIG_CONTENT and empty SSE port vars', function()
      local before = function() end
      local spec = assert(agents.build_launch('opencode', o({
        user_args = { '--continue' },
        ide = { port = 5555, token = 'tok' },
        before_spawn = before,
      })))
      assert.same({ 'opencode', '--continue' }, spec.argv)
      local content = spec.env.OPENCODE_CONFIG_CONTENT
      spec.env.OPENCODE_CONFIG_CONTENT = nil
      assert.same({
        AGENT_NVIM_SESSION = 'sid-1',
        CLAUDE_CODE_SSE_PORT = '',
        OPENCODE_EDITOR_SSE_PORT = '',
        no_proxy = LOOPBACK,
        NO_PROXY = LOOPBACK,
      }, spec.env)
      assert.same(expected_cfg(), vim.json.decode(content))
      assert.eq(false, spec.clear_env)
      assert.same({}, spec.cleanup)
      assert.eq(before, spec.before_spawn)
      assert.eq(true, spec.mcp.registered)
    end)

    it('adds the permission rule only with auto_approve', function()
      local spec = agents.build_launch('opencode', o({ auto_approve = true }))
      assert.same(expected_cfg({ permission = { ['nvim_*'] = 'allow' } }), vim.json.decode(spec.env.OPENCODE_CONFIG_CONTENT))
    end)

    it('deep-merges an inherited OPENCODE_CONFIG_CONTENT', function()
      local existing = '{"model":"anthropic/x","agent":{},"mcp":{"other":{"type":"remote","url":"https://m"},'
        .. '"nvim":{"cwd":"/w","environment":{"EXTRA":"1"}}},"permission":{"*":"ask"},"x":null}'
      local spec = agents.build_launch('opencode', o({ auto_approve = true, environ = { OPENCODE_CONFIG_CONTENT = existing } }))
      local raw = spec.env.OPENCODE_CONFIG_CONTENT
      local merged = vim.json.decode(raw, { luanil = { object = true } })
      assert.eq('anthropic/x', merged.model)
      assert.same({ type = 'remote', url = 'https://m' }, merged.mcp.other)
      assert.eq('/w', merged.mcp.nvim.cwd)
      assert.eq('1', merged.mcp.nvim.environment.EXTRA)
      assert.eq(vim.v.progpath, merged.mcp.nvim.command[1])
      assert.eq(ADDR, merged.mcp.nvim.environment.NVIM)
      assert.eq('local', merged.mcp.nvim.type)
      assert.same({ ['*'] = 'ask', ['nvim_*'] = 'allow' }, merged.permission)
      assert.matches('"agent":{}', raw)
      assert.matches('"x":null', raw)
    end)

    it('keeps the key order of an inherited OPENCODE_CONFIG_CONTENT (permission precedence)', function()
      local read_rules = '{"*":"allow","*.env":"deny","*.env.*":"deny","*.env.example":"allow"}'
      local bash_rules = '{"*":"ask","git *":"allow","git push *":"ask"}'
      local existing = '{"model":"x","permission":{"read":' .. read_rules .. ',"bash":' .. bash_rules
        .. '},"agent":{"build":{"permission":{"edit":{"*":"deny","src/*":"allow"}}}},"n":1.50,"e":"\\u00e9"}'
      for _, auto in ipairs({ false, true }) do
        local spec = agents.build_launch('opencode', o({ auto_approve = auto, environ = { OPENCODE_CONFIG_CONTENT = existing } }))
        local raw = spec.env.OPENCODE_CONFIG_CONTENT
        local perm = raw:match('"permission":(%b{})')
        assert.truthy(perm, raw)
        assert.eq('{"read":' .. read_rules .. ',"bash":' .. bash_rules .. (auto and ',"nvim_*":"allow"' or '') .. '}', perm)
        assert.truthy(raw:find('"agent":{"build":{"permission":{"edit":{"*":"deny","src/*":"allow"}}}}', 1, true), raw)
        assert.truthy(raw:find('"n":1.50,"e":"\\u00e9"', 1, true), raw)
        assert.eq(1, select(2, raw:gsub('"mcp":', '')))
        assert.eq('x', vim.json.decode(raw).model)
        assert.truthy(raw:find('^{"model":"x","permission":'), raw)
      end
    end)

    it('turns an inherited string permission into {"*": value} before adding the auto_approve rule', function()
      local spec = agents.build_launch('opencode', o({ auto_approve = true, environ = { OPENCODE_CONFIG_CONTENT = '{"permission":"ask"}' } }))
      assert.eq('{"*":"ask","nvim_*":"allow"}', spec.env.OPENCODE_CONFIG_CONTENT:match('"permission":(%b{})'))
      spec = agents.build_launch('opencode', o({ environ = { OPENCODE_CONFIG_CONTENT = '{"permission":"ask"}' } }))
      assert.truthy(spec.env.OPENCODE_CONFIG_CONTENT:find('^{"permission":"ask",'), spec.env.OPENCODE_CONFIG_CONTENT)
      assert.truthy(vim.json.decode(spec.env.OPENCODE_CONFIG_CONTENT).mcp.nvim)
    end)

    it('merges into JSON text without re-encoding what it does not touch', function()
      local existing = '{ "a" : [1, {"b": "]}"}, "[\\"x"],\n "s": "q\\"}{", "n": -1.5e+3, "t": true, "f": false, '
        .. '"z": null, "o": {}, "d": 1, "d": 2, "u": "\\u00e9\\/" }'
      local merged = agents._merge_opencode_content(existing, { o = { k = 'v' }, t = false, new = { 'l' } })
      assert.eq('{"a":[1, {"b": "]}"}, "[\\"x"],"s":"q\\"}{","n":-1.5e+3,"t":false,"f":false,"z":null,'
        .. '"o":{"k":"v"},"d":2,"u":"\\u00e9\\/","new":["l"]}', merged)
      assert.eq('q"}{', vim.json.decode(merged).s)
      assert.eq(nil, agents._merge_opencode_content('[1]', { x = 1 }))
      assert.eq(nil, agents._merge_opencode_content('"x"', { x = 1 }))
      assert.eq('{"x":1}', agents._merge_opencode_content(' {} ', { x = 1 }))
    end)

    it('merges an OPENCODE_CONFIG_CONTENT from the agent config env too', function()
      config.setup({ agents = { opencode = { env = { OPENCODE_CONFIG_CONTENT = '{"theme":"dark"}' } } } })
      local spec = agents.build_launch('opencode', o())
      local merged = vim.json.decode(spec.env.OPENCODE_CONFIG_CONTENT)
      assert.eq('dark', merged.theme)
      assert.truthy(merged.mcp.nvim)
    end)

    it('falls back to OPENCODE_CONFIG when the inherited content is not plain JSON', function()
      local spec = agents.build_launch('opencode', o({
        environ = { OPENCODE_CONFIG_CONTENT = '{ // jsonc\n "model": "x" }' },
      }))
      local file = tmp .. '/sessions/sid-1/opencode.json'
      assert.eq(nil, spec.env.OPENCODE_CONFIG_CONTENT)
      assert.eq(file, spec.env.OPENCODE_CONFIG)
      assert.same(expected_cfg(), vim.json.decode(read(file)))
      assert.same({ tmp .. '/sessions/sid-1' }, spec.cleanup)

      spec = agents.build_launch('opencode', o({
        environ = { OPENCODE_CONFIG_CONTENT = '{ // jsonc\n }', OPENCODE_CONFIG = '/mine.json' },
      }))
      assert.eq(nil, spec.env.OPENCODE_CONFIG)
      assert.eq(nil, spec.env.OPENCODE_CONFIG_CONTENT)
      assert.same({ 'opencode-config' }, warning_ids(spec))
      assert.eq(false, spec.mcp.registered)
    end)

    it('scrubs an inherited VS Code terminal identity', function()
      local vsc = { TERM_PROGRAM = 'vscode', TERM_PROGRAM_VERSION = '1.99', GIT_ASKPASS = '/Applications/Visual Studio Code.app/askpass.sh' }
      local spec = agents.build_launch('opencode', o({ environ = vsc }))
      assert.eq('', spec.env.TERM_PROGRAM)
      assert.eq('', spec.env.TERM_PROGRAM_VERSION)
      assert.eq('', spec.env.GIT_ASKPASS)
      assert.eq(false, spec.clear_env)
      spec = agents.build_launch('opencode', o({ environ = vsc, scrub_vscode_env = false }))
      assert.eq(nil, spec.env.TERM_PROGRAM)
      spec = agents.build_launch('opencode', o({ environ = { TERM_PROGRAM = 'iTerm.app' } }))
      assert.eq(nil, spec.env.TERM_PROGRAM)
    end)

    it('does not register when disabled but still empties the SSE port vars', function()
      local spec = agents.build_launch('opencode', o({ nvim_mcp = { enabled = false } }))
      assert.eq(nil, spec.env.OPENCODE_CONFIG_CONTENT)
      assert.eq('', spec.env.CLAUDE_CODE_SSE_PORT)
    end)
  end)

  describe('environment and NVIM', function()
    it('never passes NVIM, even when the user env sets it', function()
      local spec = agents.build_launch('claude', o({
        env = { NVIM = '/outer.sock', FOO = 'bar' },
        environ = { NVIM = '/outer.sock', PATH = '/bin' },
      }))
      assert.eq(false, spec.clear_env)
      assert.eq(nil, spec.env.NVIM)
      assert.eq('bar', spec.env.FOO)
      assert.eq(nil, spec.env.PATH)
    end)

    it('uses clear_env with a full copy minus NVIM when a variable must be unset', function()
      config.setup({ agents = { copilot = { env = { COPILOT_THING = false } } } })
      local spec = agents.build_launch('copilot', o({
        env = { EXTRA = '1' },
        environ = { NVIM = '/fake/outer.sock', PATH = '/bin', COPILOT_THING = 'x', HOME = '/h' },
      }))
      assert.eq(true, spec.clear_env)
      assert.same({ PATH = '/bin', HOME = '/h', EXTRA = '1', AGENT_NVIM_SESSION = 'sid-1', ConEmuANSI = 'ON' }, spec.env)
    end)

    it('sets ConEmuANSI=ON for Claude and Copilot (progress reports), unless off or set by the user', function()
      for _, name in ipairs({ 'claude', 'copilot' }) do
        assert.eq('ON', agents.build_launch(name, o()).env.ConEmuANSI, name)
        assert.eq(nil, agents.build_launch(name, o({ progress = false })).env.ConEmuANSI, name)
        assert.eq('1', agents.build_launch(name, o({ env = { ConEmuANSI = '1' } })).env.ConEmuANSI, name)
        local spec = agents.build_launch(name, o({ env = { ConEmuANSI = false }, environ = { ConEmuANSI = 'ON' } }))
        assert.eq(true, spec.clear_env, name)
        assert.eq(nil, spec.env.ConEmuANSI, name)
      end
      for _, name in ipairs({ 'opencode', 'gemini' }) do
        assert.eq(nil, agents.build_launch(name, o()).env.ConEmuANSI, name)
      end
      config.setup({ agents = { claude = { progress = false }, work = { cmd = { 'copilot' }, provider = 'copilot' } } })
      assert.eq(nil, agents.build_launch('claude', o()).env.ConEmuANSI)
      assert.eq('ON', agents.build_launch('work', o()).env.ConEmuANSI)
    end)

    it('plugin values win over user env', function()
      config.setup({ agents = { claude = { env = { FORCE_CODE_TERMINAL = 'no', MY = 'x' } } } })
      local spec = agents.build_launch('claude', o({ ide = { port = 1 } }))
      assert.eq('true', spec.env.FORCE_CODE_TERMINAL)
      assert.eq('x', spec.env.MY)
    end)

    it('a real job sees NVIM = v:servername, not the inherited one (clear_env caveat)', function()
      local function run(env, clear)
        local out = {}
        local job = vim.fn.jobstart({ 'sh', '-c', 'printf "%s|%s" "$NVIM" "${DROPME-unset}"' }, {
          env = env,
          clear_env = clear,
          stdout_buffered = true,
          on_stdout = function(_, d)
            out = d
          end,
        })
        vim.fn.jobwait({ job }, 5000)
        return table.concat(out, '')
      end
      vim.env.NVIM = '/fake/outer/nvim.sock'
      vim.env.DROPME = 'inherited'
      local ok, spec = pcall(agents.build_launch, 'opencode', o({ environ = vim.fn.environ(), env = { DROPME = false } }))
      local naive = run(vim.fn.environ(), true)
      vim.env.NVIM = nil
      vim.env.DROPME = nil
      assert.truthy(ok, spec)
      -- The caveat itself: passing environ() back overrides Neovim's injection.
      assert.eq('/fake/outer/nvim.sock|inherited', naive)
      assert.eq(true, spec.clear_env)
      assert.eq(vim.v.servername .. '|unset', run(spec.env, spec.clear_env))
    end)
  end)

  describe('manual MCP config', function()
    it('has the right top-level shape per agent', function()
      assert.eq('stdio', agents.manual_mcp_config('claude').mcpServers.nvim.type)
      assert.same({ '*' }, agents.manual_mcp_config('copilot').mcpServers.nvim.tools)
      assert.eq('${NVIM}', agents.manual_mcp_config('gemini').mcpServers.nvim.env.NVIM)
      local oc = agents.manual_mcp_config('opencode')
      assert.eq('local', oc.mcp.nvim.type)
      assert.eq(gemini.stable_nvim(), oc.mcp.nvim.command[1])
      assert.eq(nil, (agents.manual_mcp_config('nope')))
    end)
  end)
end)
