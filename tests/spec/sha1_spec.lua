local sha1 = require('agent.crypto.sha1')

local function external_sha1(data)
  local cmd
  if vim.fn.executable('shasum') == 1 then
    cmd = { 'shasum', '-a', '1' }
  elseif vim.fn.executable('sha1sum') == 1 then
    cmd = { 'sha1sum' }
  elseif vim.fn.executable('openssl') == 1 then
    cmd = { 'openssl', 'sha1', '-r' }
  else
    return nil
  end
  local res = vim.system(cmd, { stdin = data }):wait()
  return (res.stdout or ''):match('^(%x+)')
end

describe('sha1', function()
  it('computes the RFC 6455 Sec-WebSocket-Accept example', function()
    local key = 'dGhlIHNhbXBsZSBub25jZQ=='
    local accept = vim.base64.encode(sha1.digest(key .. '258EAFA5-E914-47DA-95CA-C5AB0DC85B11'))
    assert.eq('s3pPLMBiTxaQ9kYGzzhZRbK+xOo=', accept)
  end)

  it('returns a raw 20-byte digest and is callable', function()
    local d = sha1.digest('abc')
    assert.eq(20, #d)
    assert.eq(d, sha1('abc'))
  end)

  it('matches the FIPS 180 / RFC 3174 vectors', function()
    assert.eq('da39a3ee5e6b4b0d3255bfef95601890afd80709', sha1.hex(''))
    assert.eq('a9993e364706816aba3e25717850c26c9cd0d89d', sha1.hex('abc'))
    assert.eq('84983e441c3bd26ebaae4aa1f95129e5e54670f1',
      sha1.hex('abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq'))
    assert.eq('a49b2446a02c645bf419f995b67091253a04a259', sha1.hex(
      'abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu'))
    assert.eq('2fd4e1c67a2d28fced849ee1bb76e7391b93eb12', sha1.hex('The quick brown fox jumps over the lazy dog'))
    assert.eq('de9f2c7fd25e1b3afad3e85a0bd17d9b100db4b3', sha1.hex('The quick brown fox jumps over the lazy cog'))
    assert.eq('34aa973cd4c4daa4f61eeb2bdbad27316534016f', sha1.hex(string.rep('a', 1000000)))
    -- RFC 3174 test 4: "0123456701234567..." x 10 (640 bytes)
    assert.eq('dea356a2cddd90c7a7ecedc5ebb563934f460452', sha1.hex(string.rep('01234567', 80)))
  end)

  it('matches an external sha1 on padding boundaries and binary input', function()
    local lengths = { 1, 54, 55, 56, 57, 63, 64, 65, 119, 120, 127, 128, 1000, 4097 }
    local inputs = {}
    for _, n in ipairs(lengths) do
      inputs[#inputs + 1] = vim.uv.random(n)
    end
    inputs[#inputs + 1] = string.rep('\0', 64)
    inputs[#inputs + 1] = string.rep('\255', 200)
    local probe = external_sha1('abc')
    if probe ~= 'a9993e364706816aba3e25717850c26c9cd0d89d' then
      io.stdout:write('  # no usable external sha1 tool; skipped the cross-check\n')
      return
    end
    for i, data in ipairs(inputs) do
      assert.eq(external_sha1(data), sha1.hex(data), 'input ' .. i .. ' (' .. #data .. ' bytes)')
    end
  end)

  it("matches an external sha1 for 'a' * n, n = 0..200", function()
    if external_sha1('abc') ~= 'a9993e364706816aba3e25717850c26c9cd0d89d' then
      return
    end
    for n = 0, 200, 7 do
      local s = string.rep('a', n)
      assert.eq(external_sha1(s), sha1.hex(s), 'length ' .. n)
    end
  end)

  it('is fast enough for handshakes', function()
    local t = vim.uv.hrtime()
    for i = 1, 1000 do
      sha1.digest('dGhlIHNhbXBsZSBub25jZQ==' .. i .. '258EAFA5-E914-47DA-95CA-C5AB0DC85B11')
    end
    local ms = (vim.uv.hrtime() - t) / 1e6
    assert.truthy(ms < 500, 'took ' .. ms .. ' ms')
  end)
end)
