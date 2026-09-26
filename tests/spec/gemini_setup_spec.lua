local gemini = require('agent.gemini_setup')
local agents = require('agent.agents')
local config = require('agent.config')
local util = require('agent.util')

local tmp, ghome, environ, notes
local orig_notify, orig_confirm = vim.notify, vim.fn.confirm
local orig_secure = gemini.system_file_secure

local function read(path)
  local f = io.open(path, 'rb')
  if not f then
    return nil
  end
  local s = f:read('*a')
  f:close()
  return s
end

local function write(path, data, exec)
  util.mkdir_p(vim.fs.dirname(path), tonumber('700', 8))
  local f = assert(io.open(path, 'wb'))
  f:write(data)
  f:close()
  if exec then
    vim.uv.fs_chmod(path, tonumber('755', 8))
  end
end

local function sys_opts(extra)
  return vim.tbl_extend('force', {
    environ = environ,
    system_settings_path = tmp .. '/sys/settings.json',
    system_defaults_path = tmp .. '/sys/system-defaults.json',
  }, extra or {})
end

describe('gemini_setup', function()
  before_each(function()
    config.setup({})
    tmp = util.realpath(vim.fn.tempname())
    util.mkdir_p(tmp, tonumber('700', 8))
    tmp = util.realpath(tmp)
    ghome = tmp .. '/ghome'
    environ = { GEMINI_CLI_HOME = ghome, HOME = tmp .. '/home' }
    notes = {}
    vim.notify = function(msg, level)
      notes[#notes + 1] = { msg = msg, level = level }
    end
    -- The "system" settings files of these tests live in a user-owned temp dir.
    gemini.system_file_secure = function()
      return true
    end
  end)

  after_each(function()
    gemini.system_file_secure = orig_secure
    vim.notify = orig_notify
    vim.fn.confirm = orig_confirm
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if #vim.api.nvim_list_wins() > 1 then
        pcall(vim.api.nvim_win_close, w, true)
      end
    end
    util.remove_dir(tmp)
  end)

  it('defaults the extension dir to stdpath("data")/agent.nvim/gemini-extension', function()
    assert.eq(vim.fn.stdpath('data') .. '/agent.nvim/gemini-extension', gemini.extension_dir())
    assert.eq('/x/gemini-extension.json', gemini.manifest_path({ extension_dir = '/x' }))
  end)

  it('builds the manifest with a stable nvim path and ${NVIM} placeholders', function()
    local m = gemini.manifest({ server_name = 'nvim' })
    assert.eq('agent-nvim', m.name)
    assert.eq('1.0.0', m.version)
    local s = m.mcpServers.nvim
    assert.eq(gemini.stable_nvim(), s.command)
    assert.same({ '--headless', '-u', 'NONE', '-i', 'NONE', '-n', '-l', agents.NVIM_MCP_MAIN, '${NVIM}' }, s.args)
    assert.same({ NVIM = '${NVIM}', AGENT_NVIM_AGENT = 'gemini', AGENT_NVIM_SESSION = '${AGENT_NVIM_SESSION}' }, s.env)
    -- The description must not contain $VAR text, which Gemini would expand.
    assert.falsy(m.description:find('%$'))
  end)

  it('uses the nvim on PATH only when it is the running binary', function()
    local saved = vim.env.PATH
    local ok, err = pcall(function()
      -- A symlink to the running nvim (like Homebrew's bin/nvim -> Cellar/...): stable, kept as is.
      util.mkdir_p(tmp .. '/same', tonumber('700', 8))
      assert.truthy(vim.uv.fs_symlink(vim.v.progpath, tmp .. '/same/nvim'))
      vim.env.PATH = tmp .. '/same:' .. saved
      assert.eq(tmp .. '/same/nvim', gemini.stable_nvim())
      assert.eq(tmp .. '/same/nvim', gemini.manifest({}).mcpServers.nvim.command)
      -- Another (older) nvim first on PATH: the running binary is used instead.
      write(tmp .. '/other/nvim', '#!/bin/sh\necho "NVIM v0.6.1"\n', true)
      vim.env.PATH = tmp .. '/other:' .. saved
      assert.eq(tmp .. '/other/nvim', vim.fn.exepath('nvim'))
      assert.eq(vim.v.progpath, gemini.stable_nvim())
      assert.eq(vim.v.progpath, gemini.manifest({}).mcpServers.nvim.command)
      assert.eq(vim.v.progpath, gemini.default_command()[1])
      assert.eq('${NVIM}', gemini.default_command()[#gemini.default_command()])
    end)
    vim.env.PATH = saved
    assert.truthy(ok, err)
  end)

  it('writes the manifest atomically with private permissions', function()
    local ok, path = gemini.write_manifest({ extension_dir = tmp .. '/ext', server_name = 'ed', timeout_ms = 5 })
    assert.truthy(ok)
    assert.eq(tmp .. '/ext/gemini-extension.json', path)
    local m = vim.json.decode(read(path))
    assert.eq('5', m.mcpServers.ed.env.AGENT_NVIM_TIMEOUT_MS)
    assert.eq(tonumber('600', 8), bit.band(vim.uv.fs_stat(path).mode, tonumber('777', 8)))
    assert.same({ 'gemini-extension.json' }, vim.fn.readdir(tmp .. '/ext'))
    write(tmp .. '/blocker', 'x')
    local ok2, err = gemini.write_manifest({ extension_dir = tmp .. '/blocker/ext' })
    assert.falsy(ok2)
    assert.truthy(err)
  end)

  it('strips JSONC comments outside strings only', function()
    local s = '{ // c1\n "a": "x//y", /* c2 */ "b": "/* not */", "c": "q\\"//" }'
    assert.same({ a = 'x//y', b = '/* not */', c = 'q"//' }, vim.json.decode(gemini.strip_json_comments(s)))
    assert.eq('{}', gemini.strip_json_comments('{}// end'))
    assert.eq('{ ', gemini.strip_json_comments('{/* unterminated'))
    assert.eq('[1,\n2]', gemini.strip_json_comments('[1,// x\n2]'))
  end)

  it('reads settings read-only; missing is not an error, bad JSON is', function()
    assert.same({ nil, nil }, { gemini.read_settings(tmp .. '/none.json') })
    write(tmp .. '/bad.json', '{ "a": ')
    local s, err = gemini.read_settings(tmp .. '/bad.json')
    assert.eq(nil, s)
    assert.matches('cannot parse', err)
    write(tmp .. '/bom.json', '\239\187\191{"a":1}')
    assert.same({ a = 1 }, (gemini.read_settings(tmp .. '/bom.json')))
    write(tmp .. '/empty.json', '  \n')
    assert.same({}, (gemini.read_settings(tmp .. '/empty.json')))
  end)

  it('computes ide.enabled from system defaults < user (GEMINI_CLI_HOME) < system', function()
    assert.same({ false, nil }, { gemini.ide_enabled(sys_opts()) })
    write(tmp .. '/sys/system-defaults.json', '{"ide":{"enabled":true}}')
    assert.same({ true, tmp .. '/sys/system-defaults.json' }, { gemini.ide_enabled(sys_opts()) })
    write(ghome .. '/.gemini/settings.json', '{"ide":{"enabled":false}}')
    assert.same({ false, ghome .. '/.gemini/settings.json' }, { gemini.ide_enabled(sys_opts()) })
    write(tmp .. '/sys/settings.json', '{"ide":{"enabled":true}}')
    assert.same({ true, tmp .. '/sys/settings.json' }, { gemini.ide_enabled(sys_opts()) })
    -- Without GEMINI_CLI_HOME the user file is under HOME (here: the OS home, never written).
    assert.eq(util.home() .. '/.gemini/settings.json', gemini.user_settings_path({}))
    assert.eq(ghome .. '/.gemini/settings.json', gemini.user_settings_path(environ))
  end)

  it('ignores system files Gemini skips as insecure (not root-owned, or group/other-writable)', function()
    gemini.system_file_secure = orig_secure
    write(tmp .. '/sys/system-defaults.json', '{"ide":{"enabled":true}}')
    assert.falsy(gemini.system_file_secure(tmp .. '/sys/system-defaults.json'))
    assert.same({ false, nil }, { gemini.ide_enabled(sys_opts()) })
    -- The same file exported through GEMINI_CLI_SYSTEM_DEFAULTS_PATH (the old recipe).
    local env2 = vim.tbl_extend('force', environ, { GEMINI_CLI_SYSTEM_DEFAULTS_PATH = tmp .. '/sys/system-defaults.json' })
    assert.same({ false, nil }, { gemini.ide_enabled({ environ = env2 }) })
    -- A missing file is fine; a root-owned file in root-owned, non-writable dirs is secure.
    assert.truthy(gemini.system_file_secure(tmp .. '/sys/none.json'))
    for _, f in ipairs({ '/etc/hosts', '/etc/passwd' }) do
      local real = vim.uv.fs_realpath(f)
      local st = real and vim.uv.fs_stat(real)
      if st and st.uid == 0 and bit.band(st.mode, tonumber('022', 8)) == 0 then
        assert.truthy(gemini.system_file_secure(f), f)
        break
      end
    end
  end)

  it('honours GEMINI_CLI_SYSTEM_SETTINGS_PATH / _DEFAULTS_PATH', function()
    assert.eq('/s/settings.json', gemini.system_settings_path({ GEMINI_CLI_SYSTEM_SETTINGS_PATH = '/s/settings.json' }))
    assert.eq('/s/system-defaults.json', gemini.system_defaults_path({ GEMINI_CLI_SYSTEM_SETTINGS_PATH = '/s/settings.json' }))
    assert.eq('/d.json', gemini.system_defaults_path({ GEMINI_CLI_SYSTEM_DEFAULTS_PATH = '/d.json' }))
  end)

  it('detects the link under the Gemini home', function()
    assert.falsy(gemini.is_linked({ environ = environ }))
    util.mkdir_p(ghome .. '/.gemini/extensions/agent-nvim', tonumber('700', 8))
    assert.truthy(gemini.is_linked({ environ = environ }))
  end)

  it('lists policy locations, skipping the workspace file when cwd is the Gemini home', function()
    write(ghome .. '/.gemini/settings.json', '{"policyPaths":["/p1"]}')
    write(ghome .. '/.gemini/settings.json.bak', 'ignored')
    write(ghome .. '/.gemini/trustedFolders.json', vim.json.encode({ [tmp] = 'TRUST_FOLDER' }))
    local paths = gemini.policy_locations(sys_opts({ cwd = ghome }))
    assert.same({ ghome .. '/.gemini/policies', '/p1' }, paths)
    write(tmp .. '/w/.gemini/settings.json', '{"policyPaths":["${NOPE:-/fallback}", "$MISSING/x"]}')
    paths = gemini.policy_locations(sys_opts({ cwd = tmp .. '/w' }))
    assert.same({ ghome .. '/.gemini/policies', '/p1', '/fallback', '$MISSING/x' }, paths)
  end)

  it('lists workspace policyPaths only for a folder Gemini trusts', function()
    local ws = tmp .. '/repo'
    write(ws .. '/.gemini/settings.json', '{"policyPaths":["evilpol"]}')
    local function listed(extra)
      local paths = assert(gemini.policy_locations(sys_opts(vim.tbl_extend('force', { cwd = ws }, extra or {}))))
      return vim.tbl_contains(paths, 'evilpol')
    end
    -- Unknown folder (no trustedFolders.json) and an explicitly untrusted one.
    assert.falsy(listed())
    write(ghome .. '/.gemini/trustedFolders.json', vim.json.encode({ [ws] = 'DO_NOT_TRUST' }))
    assert.falsy(listed())
    write(ghome .. '/.gemini/trustedFolders.json', vim.json.encode({ [ws] = 'TRUST_FOLDER' }))
    assert.truthy(listed())
    -- The environment overrides the file.
    local env2 = vim.tbl_extend('force', environ, { GEMINI_RESTRICTED_MODE = 'true' })
    assert.falsy(listed({ environ = env2 }))
    env2 = vim.tbl_extend('force', environ, { GEMINI_CLI_TRUST_WORKSPACE = 'false' })
    assert.falsy(listed({ environ = env2 }))
    os.remove(ghome .. '/.gemini/trustedFolders.json')
    env2 = vim.tbl_extend('force', environ, { GEMINI_CLI_TRUST_WORKSPACE = 'true' })
    assert.truthy(listed({ environ = env2 }))
    -- security.folderTrust.enabled = false trusts every folder (system overrides win).
    write(ghome .. '/.gemini/settings.json', '{"security":{"folderTrust":{"enabled":false}}}')
    assert.truthy(listed())
    write(tmp .. '/sys/settings.json', '{"security":{"folderTrust":{"enabled":true}}}')
    assert.falsy(listed())
    os.remove(tmp .. '/sys/settings.json')
    os.remove(ghome .. '/.gemini/settings.json')
  end)

  it('computes folder trust like Gemini: longest rule wins, TRUST_PARENT, invalid file', function()
    local ws = tmp .. '/a/b/repo'
    util.mkdir_p(ws, tonumber('700', 8))
    local tf = ghome .. '/.gemini/trustedFolders.json'
    local function trusted(rules, extra)
      write(tf, type(rules) == 'string' and rules or vim.json.encode(rules))
      return gemini.folder_trusted(sys_opts(vim.tbl_extend('force', { cwd = ws }, extra or {})))
    end
    assert.truthy(trusted({ [tmp .. '/a'] = 'TRUST_FOLDER' }))
    assert.falsy(trusted({ [tmp .. '/a'] = 'TRUST_FOLDER', [tmp .. '/a/b'] = 'DO_NOT_TRUST' }))
    assert.truthy(trusted({ [tmp .. '/a'] = 'DO_NOT_TRUST', [tmp .. '/a/b/repo'] = 'TRUST_FOLDER' }))
    -- TRUST_PARENT trusts the parent of the listed path (and so its siblings).
    assert.truthy(trusted({ [tmp .. '/a/b/other'] = 'TRUST_PARENT' }))
    assert.falsy(trusted({ [tmp .. '/a/b/repo/sub'] = 'TRUST_FOLDER' }))
    assert.falsy(trusted({ [tmp .. '/a/bb'] = 'TRUST_FOLDER' }))
    -- Comments are allowed; an invalid level or bad JSON makes Gemini fail, so nothing is trusted.
    assert.truthy(trusted('// c\n{ "' .. tmp .. '": "TRUST_FOLDER" }'))
    assert.falsy(trusted({ [tmp] = 'TRUST_FOLDER', ['/x'] = 'MAYBE' }))
    assert.falsy(trusted('{ "' .. tmp .. '": '))
    -- GEMINI_CLI_TRUSTED_FOLDERS_PATH moves the file.
    write(tmp .. '/tf.json', vim.json.encode({ [ws] = 'TRUST_FOLDER' }))
    local env2 = vim.tbl_extend('force', environ, { GEMINI_CLI_TRUSTED_FOLDERS_PATH = tmp .. '/tf.json' })
    assert.truthy(trusted({}, { environ = env2 }))
    -- A symlinked cwd is resolved like Gemini does (realpath).
    assert.truthy(vim.uv.fs_symlink(ws, tmp .. '/link'))
    write(tf, vim.json.encode({ [ws] = 'TRUST_FOLDER' }))
    assert.truthy(gemini.folder_trusted(sys_opts({ cwd = tmp .. '/link' })))
  end)

  it('tells when mcp.allowed / mcp.excluded in the settings block the server', function()
    local ws = tmp .. '/repo'
    util.mkdir_p(ws, tonumber('700', 8))
    local function reason()
      return gemini.mcp_block_reason('nvim', sys_opts({ cwd = ws }))
    end
    assert.eq(nil, reason())
    write(ghome .. '/.gemini/settings.json', '{"mcp":{"allowed":["github"]}}')
    assert.matches('mcp.allowed', reason())
    -- An empty allowlist, or an intersection that ends up empty, filters nothing.
    write(ghome .. '/.gemini/settings.json', '{"mcp":{"allowed":[]}}')
    assert.eq(nil, reason())
    write(tmp .. '/sys/settings.json', '{"mcp":{"allowed":["a"]}}')
    write(ghome .. '/.gemini/settings.json', '{"mcp":{"allowed":["b"]}}')
    assert.eq(nil, reason())
    -- Lists are intersected case-insensitively, keeping the system file's spelling; the final
    -- check is exact.
    write(tmp .. '/sys/settings.json', '{"mcp":{"allowed":["NVIM", "x"]}}')
    write(ghome .. '/.gemini/settings.json', '{"mcp":{"allowed":["nvim"]}}')
    assert.matches('mcp.allowed', reason())
    write(tmp .. '/sys/settings.json', '{"mcp":{"allowed":["nvim", "x"]}}')
    assert.eq(nil, reason())
    os.remove(tmp .. '/sys/settings.json')
    write(ghome .. '/.gemini/settings.json', '{"mcp":{"excluded":["nvim"]}}')
    assert.matches('mcp.excluded', reason())
    -- A workspace file counts only in a trusted folder.
    write(ghome .. '/.gemini/settings.json', '{}')
    write(ws .. '/.gemini/settings.json', '{"mcp":{"excluded":["nvim"]}}')
    assert.eq(nil, reason())
    write(ghome .. '/.gemini/trustedFolders.json', vim.json.encode({ [ws] = 'TRUST_FOLDER' }))
    assert.matches('mcp.excluded', reason())
  end)

  describe('run (:AgentGeminiSetup)', function()
    local fake, out

    before_each(function()
      out = tmp .. '/link-args'
      fake = tmp .. '/bin/gemini'
      write(fake, '#!/bin/sh\nfor a in "$@"; do printf "%s\\n" "$a"; done > "' .. out .. '"\nexit ${FAKE_GEMINI_EXIT:-0}\n',
        true)
    end)

    it('confirms, writes the manifest, and runs `gemini extensions link <dir> --consent` in a terminal', function()
      local asked
      vim.fn.confirm = function(msg)
        asked = msg
        return 1
      end
      local code
      local ok, err = gemini.run({
        cmd = { fake },
        extension_dir = tmp .. '/ext',
        environ = environ,
        on_exit = function(c)
          code = c
        end,
      })
      assert.truthy(ok, err)
      assert.matches('extensions link', asked)
      assert.matches('not modified', asked)
      assert.eq(1, vim.fn.filereadable(tmp .. '/ext/gemini-extension.json'))
      wait_for(function()
        return code ~= nil
      end, 5000, 'link exit')
      assert.eq(0, code)
      assert.eq('extensions\nlink\n' .. tmp .. '/ext\n--consent\n', read(out))
      assert.eq('terminal', vim.bo.buftype)
    end)

    it('does nothing when the user declines', function()
      vim.fn.confirm = function()
        return 2
      end
      local ok, err = gemini.run({ cmd = { fake }, extension_dir = tmp .. '/ext', environ = environ })
      assert.falsy(ok)
      assert.eq('cancelled', err)
      assert.eq(0, vim.fn.filereadable(tmp .. '/ext/gemini-extension.json'))
      assert.eq(nil, read(out))
    end)

    it('only refreshes the manifest when already linked', function()
      util.mkdir_p(ghome .. '/.gemini/extensions/agent-nvim', tonumber('700', 8))
      local ok = gemini.run({ confirm = false, cmd = { fake }, extension_dir = tmp .. '/ext', environ = environ })
      assert.truthy(ok)
      assert.eq(1, vim.fn.filereadable(tmp .. '/ext/gemini-extension.json'))
      vim.wait(100)
      assert.eq(nil, read(out))
    end)

    it('uses agents.gemini.env for the link job, the link check and the confirm text', function()
      local home2 = tmp .. '/configured-home'
      config.setup({ agents = { gemini = { env = { GEMINI_CLI_HOME = home2, DROP_ME = false } } } })
      local efake = tmp .. '/bin/gemini-env'
      write(efake, '#!/bin/sh\nprintf "home=%s drop=%s\\n" "$GEMINI_CLI_HOME" "${DROP_ME-unset}" > "' .. out
        .. '"\n', true)
      local asked
      vim.fn.confirm = function(msg)
        asked = msg
        return 1
      end
      local code
      local base = { HOME = tmp .. '/home', DROP_ME = 'inherited', PATH = vim.env.PATH }
      assert.truthy(gemini.run({ cmd = { efake }, extension_dir = tmp .. '/ext', environ = base,
        on_exit = function(c)
          code = c
        end }))
      assert.truthy(asked:find(home2 .. '/.gemini/extensions/agent-nvim', 1, true), asked)
      wait_for(function()
        return code ~= nil
      end, 5000, 'link exit')
      assert.eq('home=' .. home2 .. ' drop=unset\n', read(out))
      -- Linked in the configured home: only the manifest is refreshed.
      os.remove(out)
      util.mkdir_p(home2 .. '/.gemini/extensions/agent-nvim', tonumber('700', 8))
      assert.truthy(gemini.run({ confirm = false, cmd = { efake }, extension_dir = tmp .. '/ext', environ = base }))
      assert.truthy(notes[#notes].msg:find('already linked', 1, true), vim.inspect(notes))
      vim.wait(100)
      assert.eq(nil, read(out))
      assert.eq(home2, gemini.agent_environ(base).GEMINI_CLI_HOME)
      assert.eq(nil, gemini.agent_environ(base).DROP_ME)
    end)

    it('reports a missing gemini executable', function()
      local ok, err = gemini.run({ confirm = false, cmd = { tmp .. '/nope/gemini' }, extension_dir = tmp .. '/ext' })
      assert.falsy(ok)
      assert.matches("executable '.*/nope/gemini' not found", err)
      assert.eq(0, vim.fn.filereadable(tmp .. '/ext/gemini-extension.json'))
    end)
  end)
end)
