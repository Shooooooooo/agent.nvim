local util = require('agent.util')

describe('util', function()
  it('random_hex returns lowercase hex of the requested size', function()
    local h = util.random_hex(16)
    assert.eq(32, #h)
    assert.matches('^[0-9a-f]+$', h)
  end)

  it('uuid is v4 formatted', function()
    assert.matches('^%x%x%x%x%x%x%x%x%-%x%x%x%x%-4%x%x%x%-[89ab]%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$', util.uuid())
  end)

  it('atomic_write creates a 0600 file', function()
    local dir = vim.fn.tempname()
    assert.truthy(util.mkdir_p(dir, tonumber('700', 8)))
    local p = dir .. '/x.json'
    assert.truthy(util.atomic_write(p, '{"a":1}'))
    assert.eq('{"a":1}', table.concat(vim.fn.readfile(p), '\n'))
    assert.eq(tonumber('600', 8), bit.band(vim.uv.fs_stat(p).mode, tonumber('777', 8)))
    assert.eq(tonumber('700', 8), bit.band(vim.uv.fs_stat(dir).mode, tonumber('777', 8)))
    util.remove_dir(dir)
  end)

  it('mkdir_p returns false and an error instead of throwing when it cannot create the directory', function()
    local dir = vim.fn.tempname()
    assert.truthy(util.mkdir_p(dir, tonumber('700', 8)))
    local blocker = dir .. '/blocker-file'
    assert.truthy(util.atomic_write(blocker, ''))
    for _, path in ipairs({ blocker, blocker .. '/sub/dir' }) do
      local pok, ok, err = pcall(util.mkdir_p, path, tonumber('700', 8))
      assert.truthy(pok, 'mkdir_p threw: ' .. tostring(ok))
      assert.eq(false, ok, path)
      assert.matches('[Cc]reate directory', err, path)
      assert.falsy(err:find('^Vim:'), err)
      assert.matches('blocker%-file', err, path)
    end
    -- An existing directory is still success.
    assert.same({ true, nil }, { util.mkdir_p(dir, tonumber('700', 8)) })
    util.remove_dir(dir)
  end)

  it('run_dir does not throw when the directory cannot be created', function()
    local dir = vim.fn.tempname()
    assert.truthy(util.mkdir_p(dir, tonumber('700', 8)))
    local saved = vim.fn.stdpath
    local blocker = dir .. '/run-file'
    assert.truthy(util.atomic_write(blocker, ''))
    vim.fn.stdpath = function(what)
      if what == 'run' then
        return blocker
      end
      return saved(what)
    end
    local pok, path = pcall(util.run_dir, 'sessions', 'x')
    vim.fn.stdpath = saved
    assert.truthy(pok, 'run_dir threw: ' .. tostring(path))
    assert.eq(0, vim.fn.isdirectory(path))
    util.remove_dir(dir)
  end)

  it('json round-trips empty objects', function()
    assert.eq('{"a":{}}', util.json_encode({ a = util.empty_object() }))
    local ok, v = util.json_decode('{"a":null,"b":[1]}')
    assert.truthy(ok)
    assert.eq(nil, v.a)
    assert.same({ 1 }, v.b)
  end)

  it('path_contains', function()
    assert.truthy(util.path_contains('/a/b', '/a/b/c'))
    assert.truthy(util.path_contains('/a/b', '/a/b'))
    assert.truthy(util.path_contains('/a/b/', '/a/b/c'))
    assert.falsy(util.path_contains('/a/b', '/a/bc'))
  end)

  it('file urls', function()
    assert.eq('file:///tmp/a b', util.file_url_raw('/tmp/a b'))
    assert.eq('file:///tmp/a%20b', util.file_url('/tmp/a b'))
  end)
end)
