local uv = vim.uv
local ws = require('agent.net.websocket')

local TOKEN = 'secret-token-0123456789'
local KEY = 'dGhlIHNhbXBsZSBub25jZQ=='

-- ---------------------------------------------------------------------------
-- helpers
-- ---------------------------------------------------------------------------

local function raw_client(port)
  local h = uv.new_tcp()
  local st = { chunks = {}, eof = false, connected = false, handle = h }
  h:connect('127.0.0.1', port, function(err)
    if err then
      st.err = err
      return
    end
    st.connected = true
    h:read_start(function(rerr, chunk)
      if rerr or not chunk then
        st.eof = true
      else
        st.chunks[#st.chunks + 1] = chunk
      end
    end)
  end)
  wait_for(function()
    return st.connected or st.err
  end, 2000, 'connect')
  function st.send(s)
    if not h:is_closing() then
      h:write(s)
    end
  end
  function st.text()
    return table.concat(st.chunks)
  end
  function st.close()
    if not h:is_closing() then
      h:close()
    end
  end
  return st
end

local function upgrade_request(headers, request_line)
  local lines = { request_line or 'GET / HTTP/1.1' }
  local defaults = {
    { 'Host', '127.0.0.1' },
    { 'Upgrade', 'websocket' },
    { 'Connection', 'Upgrade' },
    { 'Sec-WebSocket-Key', KEY },
    { 'Sec-WebSocket-Version', '13' },
    { 'X-Claude-Code-Ide-Authorization', TOKEN },
  }
  headers = headers or {}
  for _, kv in ipairs(defaults) do
    local v = headers[kv[1]]
    if v == nil then
      v = kv[2]
    end
    if v ~= false then
      lines[#lines + 1] = kv[1] .. ': ' .. v
    end
  end
  for k, v in pairs(headers) do
    local known = false
    for _, kv in ipairs(defaults) do
      known = known or kv[1] == k
    end
    if not known and v ~= false then
      lines[#lines + 1] = k .. ': ' .. v
    end
  end
  return table.concat(lines, '\r\n') .. '\r\n\r\n'
end

---Build a masked client frame.
local function frame(opcode, payload, opts)
  opts = opts or {}
  local mask
  if opts.mask ~= false then
    mask = opts.mask or '\1\2\3\4'
  end
  local header = ws.frame_header(opcode, #payload, opts.fin ~= false, mask)
  if opts.rsv then
    header = string.char(bit.bor(header:byte(1), 0x40)) .. header:sub(2)
  end
  return header .. (mask and ws.unmask(payload, mask) or payload)
end

---Parse server frames from raw bytes (after the handshake response).
local function parse_frames(data)
  local frames, pos = {}, 1
  while pos + 1 <= #data do
    local b1, b2 = data:byte(pos, pos + 1)
    local len = bit.band(b2, 0x7f)
    local masked = bit.band(b2, 0x80) ~= 0
    local p = pos + 2
    if len == 126 then
      if #data < pos + 3 then
        break
      end
      local x1, x2 = data:byte(pos + 2, pos + 3)
      len = x1 * 256 + x2
      p = pos + 4
    elseif len == 127 then
      if #data < pos + 9 then
        break
      end
      len = 0
      for i = pos + 2, pos + 9 do
        len = len * 256 + data:byte(i)
      end
      p = pos + 10
    end
    if #data < p + len - 1 then
      break
    end
    frames[#frames + 1] = {
      fin = bit.band(b1, 0x80) ~= 0,
      opcode = bit.band(b1, 0x0f),
      masked = masked,
      payload = data:sub(p, p + len - 1),
    }
    pos = p + len
  end
  return frames
end

local function split_handshake(text)
  local he = text:find('\r\n\r\n', 1, true)
  if not he then
    return nil
  end
  return text:sub(1, he - 1), text:sub(he + 4)
end

local function close_code(f)
  if #f.payload < 2 then
    return nil
  end
  local a, b = f.payload:byte(1, 2)
  return a * 256 + b, f.payload:sub(3)
end

local servers, clients = {}, {}
local events

local function start(opts)
  events = { open = {}, message = {}, close = {} }
  local o = vim.tbl_extend('force', {
    port = 0,
    authenticate = function(headers)
      return ws.constant_time_equals(headers['x-claude-code-ide-authorization'], TOKEN), 'Invalid authentication token'
    end,
    on_open = function(conn)
      events.open[#events.open + 1] = conn
    end,
    on_message = function(conn, text, is_binary)
      events.message[#events.message + 1] = { conn = conn, text = text, binary = is_binary }
      if text == 'please close' then
        conn:close(4000, 'bye')
      else
        conn:send('echo:' .. text)
      end
    end,
    on_close = function(conn, code, reason)
      events.close[#events.close + 1] = { conn = conn, code = code, reason = reason }
    end,
  }, opts or {})
  local s, err = ws.listen(o)
  assert.truthy(s, err)
  servers[#servers + 1] = s
  return s
end

local function connect(port)
  local c = raw_client(port)
  clients[#clients + 1] = c
  return c
end

---Connect and complete the handshake. Returns the client and the response head.
local function open(port, headers)
  local c = connect(port)
  c.send(upgrade_request(headers))
  local head
  wait_for(function()
    head = split_handshake(c.text())
    return head ~= nil
  end, 2000, 'handshake response')
  assert.matches('^HTTP/1%.1 101', head)
  c.frames = function()
    local _, rest = split_handshake(c.text())
    return parse_frames(rest or '')
  end
  c.wait_frames = function(n, ms)
    local fs
    wait_for(function()
      fs = c.frames()
      return #fs >= n
    end, ms or 3000, n .. ' frames')
    return fs
  end
  return c, head
end

after_each(function()
  for _, c in ipairs(clients) do
    c.close()
  end
  for _, s in ipairs(servers) do
    s:close()
  end
  clients, servers = {}, {}
  vim.wait(20)
end)

-- ---------------------------------------------------------------------------
-- tests
-- ---------------------------------------------------------------------------

describe('websocket framing helpers', function()
  it('computes the RFC 6455 accept key', function()
    assert.eq('s3pPLMBiTxaQ9kYGzzhZRbK+xOo=', ws.accept_key(KEY))
  end)

  it('encodes 7, 16 and 64-bit lengths', function()
    assert.eq('\129\5', ws.frame_header(1, 5))
    assert.eq('\129\126\1\0', ws.frame_header(1, 256))
    assert.eq('\129\127\0\0\0\0\0\1\0\0', ws.frame_header(1, 65536))
    assert.eq('\1\125', ws.frame_header(1, 125, false))
    assert.eq('\130\127\0\0\0\1\0\0\0\0', ws.frame_header(2, 4294967296))
  end)

  it('unmasks identically with and without ffi', function()
    for _, n in ipairs({ 1, 3, 4, 5, 63, 64, 65, 1000, 4097, 70001 }) do
      local data = uv.random(n)
      local mask = uv.random(4)
      local a = ws.unmask(data, mask)
      local b = ws.unmask(data, mask, true)
      assert.truthy(a == b, 'length ' .. n)
      assert.truthy(ws.unmask(a, mask) == data, 'round trip ' .. n)
    end
  end)
end)

describe('websocket handshake', function()
  it('upgrades, echoes the mcp subprotocol and declines extensions', function()
    local s = start()
    local c, head = open(s.port, {
      ['Sec-WebSocket-Protocol'] = 'mcp',
      ['Sec-WebSocket-Extensions'] = 'permessage-deflate; client_max_window_bits',
      ['User-Agent'] = 'claude-code/2.1.283 (cli)',
    })
    assert.truthy(head:find('\r\nUpgrade: websocket', 1, true))
    assert.truthy(head:find('\r\nConnection: Upgrade', 1, true))
    assert.truthy(head:find('\r\nSec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=', 1, true))
    assert.truthy(head:find('\r\nSec-WebSocket-Protocol: mcp', 1, true))
    assert.falsy(head:find('Extensions', 1, true))
    wait_for(function()
      return #events.open == 1
    end, 2000, 'on_open')
    local conn = events.open[1]
    assert.eq('mcp', conn.protocol)
    assert.eq(TOKEN, conn.headers['x-claude-code-ide-authorization'])
    assert.eq('/', conn.path)
    assert.same({}, conn.data)
    assert.eq(1, #s:connections())
    c.close()
  end)

  it('picks mcp from a list and sends no protocol when none was offered', function()
    local s = start()
    local _, head = open(s.port, { ['Sec-WebSocket-Protocol'] = 'foo, mcp' })
    assert.truthy((head .. '\r\n'):find('\r\nSec-WebSocket-Protocol: mcp\r\n', 1, true))
    local _, head2 = open(s.port) -- OpenCode sends no Sec-WebSocket-Protocol
    assert.falsy(head2:find('Sec-WebSocket-Protocol', 1, true))
    local _, head3 = open(s.port, { ['Sec-WebSocket-Protocol'] = 'graphql-ws' })
    assert.falsy(head3:find('Sec-WebSocket-Protocol', 1, true))
  end)

  it('validates the upgrade in the specified order', function()
    local s = start()
    local cases = {
      { 'POST / HTTP/1.1', {}, 404 },
      { 'GET / HTTP/1.0', {}, 404 },
      { nil, { Upgrade = 'h2c' }, 400 },
      { nil, { Upgrade = false }, 400 },
      { nil, { Connection = 'keep-alive' }, 400 },
      { nil, { ['Sec-WebSocket-Key'] = 'short' }, 400 },
      { nil, { ['Sec-WebSocket-Key'] = false }, 400 },
      { nil, { ['Sec-WebSocket-Version'] = '8' }, 400 },
      -- A bad version is reported before a bad token.
      { nil, { ['Sec-WebSocket-Version'] = '8', ['X-Claude-Code-Ide-Authorization'] = 'wrong-token-xx' }, 400 },
      { nil, { ['X-Claude-Code-Ide-Authorization'] = 'wrong-token-xx' }, 401 },
      { nil, { ['X-Claude-Code-Ide-Authorization'] = false }, 401 },
      -- The token is checked before the Origin.
      { nil, { ['X-Claude-Code-Ide-Authorization'] = 'wrong-token-xx', Origin = 'http://evil' }, 401 },
      { nil, { Origin = 'http://evil.example' }, 403 },
    }
    for i, case in ipairs(cases) do
      local c = connect(s.port)
      c.send(upgrade_request(case[2], case[1]))
      wait_for(function()
        return c.eof
      end, 2000, 'server closes after rejecting case ' .. i)
      local status = tonumber(c.text():match('^HTTP/1%.1 (%d+)'))
      assert.eq(case[3], status, 'case ' .. i .. ': ' .. c.text())
      assert.truthy(c.text():find('Connection: close', 1, true))
      assert.truthy(c.text():find('Content-Length: ', 1, true))
    end
    assert.eq(0, #events.open)
  end)

  it('uses the status returned by authenticate and accepts header names in any case', function()
    local s = start({
      authenticate = function(headers)
        if headers['x-claude-code-ide-authorization'] == TOKEN then
          return true
        end
        return false, 'nope', 400
      end,
    })
    local c = connect(s.port)
    c.send(upgrade_request({ ['X-Claude-Code-Ide-Authorization'] = 'bad-token-123' }))
    wait_for(function()
      return c.eof
    end, 2000, 'rejected')
    assert.matches('^HTTP/1%.1 400', c.text())
    assert.matches('nope$', c.text())
    local c2 = connect(s.port)
    c2.send((upgrade_request({ ['X-Claude-Code-Ide-Authorization'] = false }):gsub('\r\n\r\n$', '\r\nx-claude-code-ide-authorization: ' .. TOKEN .. '\r\n\r\n')))
    wait_for(function()
      return c2.text():find('\r\n\r\n', 1, true) ~= nil
    end, 2000, 'lowercase header accepted')
    assert.matches('^HTTP/1%.1 101', c2.text())
  end)

  it('token_auth checks presence, length and value', function()
    local auth = ws.token_auth('X-Claude-Code-Ide-Authorization', TOKEN)
    assert.truthy(auth({ ['x-claude-code-ide-authorization'] = TOKEN }))
    assert.falsy(auth({}))
    assert.falsy(auth({ ['x-claude-code-ide-authorization'] = 'short' }))
    assert.falsy(auth({ ['x-claude-code-ide-authorization'] = string.rep('a', 501) }))
    assert.falsy(auth({ ['x-claude-code-ide-authorization'] = TOKEN .. 'x' }))
    local dynamic = ws.token_auth('x-token', function()
      return TOKEN
    end)
    assert.truthy(dynamic({ ['x-token'] = TOKEN }))
    local s = start({ authenticate = auth })
    open(s.port)
    local c = connect(s.port)
    c.send(upgrade_request({ ['X-Claude-Code-Ide-Authorization'] = 'short' }))
    wait_for(function()
      return c.eof
    end, 2000, 'rejected')
    assert.matches('^HTTP/1%.1 401', c.text())
  end)

  it('allows an Origin when configured', function()
    local s = start({
      allow_origin = function(origin)
        return origin == 'http://ok'
      end,
    })
    open(s.port, { Origin = 'http://ok' })
    local c = connect(s.port)
    c.send(upgrade_request({ Origin = 'http://bad' }))
    wait_for(function()
      return c.eof
    end, 2000, 'rejected')
    assert.matches('^HTTP/1%.1 403', c.text())
  end)

  it('rejects oversized headers and times out silent sockets', function()
    local s = start({ handshake_timeout_ms = 150 })
    local c = connect(s.port)
    c.send('GET / HTTP/1.1\r\nX-Big: ' .. string.rep('a', 17000) .. '\r\n\r\n')
    wait_for(function()
      return c.eof
    end, 2000, 'rejected')
    assert.matches('^HTTP/1%.1 400', c.text())
    local silent = connect(s.port)
    wait_for(function()
      return silent.eof
    end, 2000, 'handshake timeout')
    assert.eq('', silent.text())
  end)

  it('processes frames that arrive together with the upgrade request', function()
    local s = start()
    local c = connect(s.port)
    c.send(upgrade_request() .. frame(1, 'early'))
    wait_for(function()
      return #events.message == 1
    end, 2000, 'message')
    assert.eq('early', events.message[1].text)
  end)
end)

describe('websocket frames', function()
  it('echoes text in 7, 16 and 64-bit frames, unmasked with FIN set', function()
    local s = start()
    local c = open(s.port)
    local sizes = { 5, 200, 70000, 1000000 }
    for _, n in ipairs(sizes) do
      c.send(frame(1, string.rep('x', n)))
    end
    local fs = c.wait_frames(#sizes, 5000)
    for i, n in ipairs(sizes) do
      assert.eq(1, fs[i].opcode)
      assert.truthy(fs[i].fin)
      assert.falsy(fs[i].masked)
      assert.eq(5 + n, #fs[i].payload)
    end
  end)

  it('reassembles fragmented messages with control frames in between', function()
    local s = start()
    local c = open(s.port)
    c.send(frame(1, 'Hel', { fin = false }))
    c.send(frame(9, 'ping-in-the-middle'))
    c.send(frame(0, 'lo, ', { fin = false }))
    c.send(frame(0, 'wörld'))
    local fs = c.wait_frames(2)
    assert.eq(0xA, fs[1].opcode)
    assert.eq('ping-in-the-middle', fs[1].payload)
    assert.eq('echo:Hello, wörld', fs[2].payload)
    assert.eq(1, #events.message)
    -- A UTF-8 sequence split across fragments is valid.
    c.send(frame(1, 'caf\195', { fin = false }))
    c.send(frame(0, '\169'))
    fs = c.wait_frames(3)
    assert.eq('echo:café', fs[3].payload)
  end)

  it('treats binary messages as text for on_message', function()
    local s = start()
    local c = open(s.port)
    c.send(frame(2, '{"jsonrpc":"2.0"}'))
    wait_for(function()
      return #events.message == 1
    end, 2000, 'message')
    assert.eq('{"jsonrpc":"2.0"}', events.message[1].text)
    assert.truthy(events.message[1].binary)
  end)

  it('answers ping with pong carrying the same payload', function()
    local s = start()
    local c = open(s.port)
    c.send(frame(9, 'abc'))
    c.send(frame(9, ''))
    local fs = c.wait_frames(2)
    assert.eq(0xA, fs[1].opcode)
    assert.eq('abc', fs[1].payload)
    assert.eq('', fs[2].payload)
    c.send(frame(0xA, 'unsolicited pong is ignored'))
    vim.wait(30)
    assert.eq(2, #c.frames())
  end)

  it('echoes the close code of a client-initiated close and reports it', function()
    local s = start()
    local c = open(s.port)
    c.send(frame(8, string.char(3, 232) .. 'done'))
    wait_for(function()
      return c.eof
    end, 2000, 'server closes TCP')
    local fs = c.frames()
    assert.eq(8, fs[1].opcode)
    assert.eq(1000, close_code(fs[1]))
    wait_for(function()
      return #events.close == 1
    end, 1000, 'on_close')
    assert.eq(1000, events.close[1].code)
    assert.eq('done', events.close[1].reason)
    assert.eq(0, #s:connections())
  end)

  it('handles an empty close payload as 1005 and replies with an empty close', function()
    local s = start()
    local c = open(s.port)
    c.send(frame(8, ''))
    wait_for(function()
      return c.eof
    end, 2000, 'closed')
    assert.eq('', c.frames()[1].payload)
    wait_for(function()
      return #events.close == 1
    end, 1000, 'on_close')
    assert.eq(1005, events.close[1].code)
  end)

  it('performs a server-initiated close handshake', function()
    local s = start()
    local c = open(s.port)
    c.send(frame(1, 'please close'))
    local fs = c.wait_frames(1)
    assert.eq(8, fs[1].opcode)
    assert.eq(4000, close_code(fs[1]))
    assert.eq('bye', select(2, close_code(fs[1])))
    -- Data sent after our Close is ignored; the peer's Close completes the handshake.
    c.send(frame(1, 'ignored'))
    c.send(frame(8, string.char(15, 160)))
    wait_for(function()
      return c.eof
    end, 2000, 'closed')
    wait_for(function()
      return #events.close == 1
    end, 1000, 'on_close')
    assert.eq(4000, events.close[1].code)
    assert.eq(1, #events.message)
  end)

  it('drops TCP about 1 s after an unanswered close', function()
    local s = start()
    local c = open(s.port)
    wait_for(function()
      return #events.open == 1
    end, 1000, 'open')
    local t0 = uv.now()
    events.open[1]:close(1000, 'bye')
    wait_for(function()
      return c.eof
    end, 3000, 'forced close')
    local dt = uv.now() - t0
    assert.truthy(dt >= 900 and dt < 2500, 'closed after ' .. dt .. ' ms')
    wait_for(function()
      return #events.close == 1
    end, 1000, 'on_close')
    assert.eq(1000, events.close[1].code)
  end)

  it('reports 1006 when the peer drops TCP without a close frame', function()
    local s = start()
    local c = open(s.port)
    wait_for(function()
      return #events.open == 1
    end, 1000, 'open')
    c.close()
    wait_for(function()
      return #events.close == 1
    end, 2000, 'on_close')
    assert.eq(1006, events.close[1].code)
    assert.falsy(events.open[1]:send('x'))
  end)

  it('fails the connection on protocol violations', function()
    local s = start({ max_message_size = 1000 })
    local cases = {
      { frame(1, 'x', { mask = false }), 1002 },
      { frame(1, 'x', { rsv = true }), 1002 },
      { frame(3, 'x'), 1002 },
      { frame(0, 'x'), 1002 },
      { frame(9, string.rep('p', 126)), 1002 },
      { frame(9, 'p', { fin = false }), 1002 },
      { frame(1, 'a', { fin = false }) .. frame(1, 'b'), 1002 },
      { frame(8, '\3'), 1002 },
      { frame(8, string.char(3, 237)), 1002 }, -- 1005 must not be sent on the wire
      { frame(8, string.char(3, 232) .. '\255'), 1007 },
      { frame(1, 'bad \255 utf8'), 1007 },
      { frame(1, string.rep('y', 1001)), 1009 },
      { frame(1, string.rep('y', 600), { fin = false }) .. frame(0, string.rep('y', 600)), 1009 },
      -- A 64-bit length with the most significant bit set.
      { '\129\255\128\0\0\0\0\0\0\1\1\2\3\4', 1002 },
    }
    for i, case in ipairs(cases) do
      local c = open(s.port)
      c.send(case[1])
      wait_for(function()
        return c.eof
      end, 2000, 'closed, case ' .. i)
      local fs = c.frames()
      local last = fs[#fs]
      assert.truthy(last and last.opcode == 8, 'close frame, case ' .. i)
      assert.eq(case[2], close_code(last), 'case ' .. i)
    end
  end)

  it('accepts unmasked frames when require_mask = false', function()
    local s = start({ require_mask = false })
    local c = open(s.port)
    c.send(frame(1, 'lenient', { mask = false }))
    assert.eq('echo:lenient', c.wait_frames(1)[1].payload)
  end)

  it('serves several clients at once and broadcasts', function()
    local s = start()
    local a = open(s.port)
    local b = open(s.port)
    wait_for(function()
      return #s:connections() == 2
    end, 1000, 'two open')
    assert.eq(2, s:broadcast('hello all'))
    assert.eq('hello all', a.wait_frames(1)[1].payload)
    assert.eq('hello all', b.wait_frames(1)[1].payload)
    a.send(frame(1, 'from a'))
    assert.eq('echo:from a', a.wait_frames(2)[2].payload)
    assert.eq(1, #b.frames())
  end)

  it('sends large server messages with a 64-bit length', function()
    local s = start()
    local c = open(s.port)
    wait_for(function()
      return #events.open == 1
    end, 1000, 'open')
    local big = string.rep('z', 3 * 1024 * 1024)
    assert.truthy(events.open[1]:send(big))
    local f = c.wait_frames(1, 5000)[1]
    assert.eq(#big, #f.payload)
  end)
end)

describe('websocket keepalive and shutdown', function()
  it('pings clients and closes one that stays silent', function()
    local s = start({ ping_interval_ms = 100 })
    local c = open(s.port)
    local fs = c.wait_frames(1, 1000)
    assert.eq(9, fs[1].opcode)
    assert.eq('ping', fs[1].payload)
    -- Never answer: after 2 intervals of silence the server closes with 1001.
    wait_for(function()
      local all = c.frames()
      return all[#all].opcode == 8
    end, 2000, 'keepalive close')
    local all = c.frames()
    assert.eq(1001, close_code(all[#all]))
    wait_for(function()
      return c.eof
    end, 2000, 'tcp closed')
  end)

  it('keeps a client that answers pings', function()
    local s = start({ ping_interval_ms = 100 })
    local c = open(s.port)
    local answered = 0
    local timer = uv.new_timer()
    timer:start(0, 20, function()
      local fs = c.frames()
      while answered < #fs do
        answered = answered + 1
        if fs[answered].opcode == 9 then
          c.send(frame(0xA, fs[answered].payload))
        end
      end
    end)
    vim.wait(600)
    timer:stop()
    timer:close()
    assert.falsy(c.eof)
    assert.eq(1, #s:connections())
  end)

  it('server:close() sends 1001 to every client and releases the port', function()
    local s = start()
    local a = open(s.port)
    local b = open(s.port)
    local pending = connect(s.port) -- never completes a handshake
    wait_for(function()
      return #events.open == 2
    end, 1000, 'open')
    s:close()
    for _, c in ipairs({ a, b }) do
      local fs = c.wait_frames(1)
      assert.eq(8, fs[1].opcode)
      assert.eq(1001, close_code(fs[1]))
      assert.eq('Server shutting down', select(2, close_code(fs[1])))
      c.send(frame(8, string.char(3, 233)))
    end
    wait_for(function()
      return a.eof and b.eof and pending.eof
    end, 3000, 'all closed')
    wait_for(function()
      return #events.close == 2
    end, 1000, 'on_close x2')
    assert.eq(1001, events.close[1].code)
    local s2 = ws.listen({ port = s.port, ping_interval_ms = false })
    assert.truthy(s2, 'port released')
    s2:close()
  end)
end)
