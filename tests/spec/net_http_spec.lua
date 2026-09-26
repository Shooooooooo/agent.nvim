local uv = vim.uv
local http = require('agent.net.http')
local common = require('agent.net.common')

-- ---------------------------------------------------------------------------
-- helpers
-- ---------------------------------------------------------------------------

---A raw client that records everything it receives.
local function client(kind, where)
  local h = kind == 'pipe' and uv.new_pipe(false) or uv.new_tcp()
  local st = { chunks = {}, eof = false, err = nil, connected = false, handle = h }
  local function on_connect(err)
    if err then
      st.err = err
      return
    end
    st.connected = true
    h:read_start(function(rerr, chunk)
      if rerr then
        st.err, st.eof = rerr, true
      elseif chunk then
        st.chunks[#st.chunks + 1] = chunk
      else
        st.eof = true
      end
    end)
  end
  if kind == 'pipe' then
    h:connect(where, on_connect)
  else
    h:connect('127.0.0.1', where, on_connect)
  end
  wait_for(function()
    return st.connected or st.err
  end, 2000, 'connect')
  assert.falsy(st.err, 'connect error')
  function st.send(s)
    h:write(s)
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

---Parse raw HTTP/1.1 responses. Returns the complete responses and whether the data ends cleanly.
local function parse_responses(data)
  local out, pos = {}, 1
  while pos <= #data do
    local he = data:find('\r\n\r\n', pos, true)
    if not he then
      break
    end
    local head = data:sub(pos, he - 1)
    local status = tonumber(head:match('^HTTP/1%.1 (%d%d%d)'))
    local headers = {}
    for line in head:gmatch('[^\r\n]+') do
      local k, v = line:match('^([^:]+):%s*(.-)%s*$')
      if k then
        headers[k:lower()] = v
      end
    end
    local body_start = he + 4
    local r = { status = status, headers = headers, head = head }
    if status and status < 200 then
      pos = body_start
    elseif headers['transfer-encoding'] == 'chunked' then
      local parts, p, complete = {}, body_start, false
      while true do
        local le = data:find('\r\n', p, true)
        if not le then
          break
        end
        local size = tonumber(data:sub(p, le - 1):match('^%x+'), 16)
        if not size then
          break
        end
        if size == 0 then
          if data:sub(le + 2, le + 3) == '\r\n' then
            complete = true
            p = le + 4
          end
          break
        end
        if #data < le + 1 + size + 2 then
          break
        end
        parts[#parts + 1] = data:sub(le + 2, le + 1 + size)
        p = le + 2 + size + 2
      end
      r.body = table.concat(parts)
      r.complete = complete
      pos = complete and p or #data + 1
    elseif headers['content-length'] then
      local n = tonumber(headers['content-length'])
      r.body = data:sub(body_start, body_start + n - 1)
      r.complete = #r.body == n
      pos = body_start + n
    else
      r.body = data:sub(body_start)
      r.complete = false
      pos = #data + 1
    end
    if r.status then
      out[#out + 1] = r
    end
    if not r.complete and r.status and r.status >= 200 then
      break
    end
  end
  return out
end

local function wait_responses(c, n, ms)
  local rs
  wait_for(function()
    rs = parse_responses(c.text())
    local complete = 0
    for _, r in ipairs(rs) do
      if r.status >= 200 and r.complete then
        complete = complete + 1
      end
    end
    return complete >= n
  end, ms or 3000, n .. ' responses')
  local finals = {}
  for _, r in ipairs(rs) do
    if r.status >= 200 then
      finals[#finals + 1] = r
    end
  end
  return finals
end

local function mode_of(path)
  return bit.band(uv.fs_stat(path).mode, tonumber('777', 8))
end

local function echo_handler(req, res)
  res:write_head(200, { ['Content-Type'] = 'application/json' })
  res:finish(vim.json.encode({
    method = req.method,
    path = req.path,
    query = next(req.query) and req.query or vim.empty_dict(),
    body = req.body,
    conn = req.conn_id,
    version = req.version,
    ua = req.headers['user-agent'],
    x = req.headers['x-multi'],
  }))
end

local servers, clients, tmpdirs = {}, {}, {}

local function listen(opts)
  local s, err = http.listen(opts)
  assert.truthy(s, err)
  servers[#servers + 1] = s
  return s
end

local function connect(kind, where)
  local c = client(kind, where)
  clients[#clients + 1] = c
  return c
end

local function tmpdir()
  -- Short paths: macOS sun_path is 104 bytes.
  local d = uv.fs_mkdtemp((os.getenv('TMPDIR') or '/tmp'):gsub('/$', '') .. '/anh-XXXXXX')
  tmpdirs[#tmpdirs + 1] = d
  return d
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
  for _, d in ipairs(tmpdirs) do
    vim.fn.delete(d, 'rf')
  end
  tmpdirs = {}
end)

-- ---------------------------------------------------------------------------
-- tests
-- ---------------------------------------------------------------------------

describe('net.common buffer', function()
  it('peeks, takes and finds across chunks', function()
    local b = common.buffer()
    for _, s in ipairs({ 'ab', 'c\r', '\n', '\r', '\nrest', 'X' }) do
      b:push(s)
    end
    assert.eq(12, b.size)
    assert.eq('abc\r', b:peek(4))
    assert.eq(4, b:find('\r\n\r\n', 100))
    assert.eq(nil, b:find('\r\n\r\n', 6))
    assert.eq(nil, b:find('zz', 100))
    assert.eq('abc', b:take(3))
    assert.eq(1, b:find('\r\n\r\n', 100))
    b:skip(4)
    assert.eq('restX', b:take(100))
    assert.eq(0, b.size)
  end)

  it('finds a needle split over many one-byte chunks', function()
    local b = common.buffer()
    local s = 'GET / HTTP/1.1\r\nHost: x\r\n\r\nNEXT'
    for i = 1, #s do
      b:push(s:sub(i, i))
    end
    assert.eq(s:find('\r\n\r\n', 1, true), b:find('\r\n\r\n', 1000))
  end)

  it('validates utf-8', function()
    assert.truthy(common.valid_utf8('plain ascii'))
    assert.truthy(common.valid_utf8('é😀€'))
    assert.falsy(common.valid_utf8('\255'))
    assert.falsy(common.valid_utf8('\192\128')) -- overlong
    assert.falsy(common.valid_utf8('\237\160\128')) -- surrogate
    assert.falsy(common.valid_utf8('\244\144\128\128')) -- > U+10FFFF
    assert.falsy(common.valid_utf8('ab\226\130')) -- truncated
  end)

  it('compares in constant time', function()
    assert.truthy(common.constant_time_equals('abc', 'abc'))
    assert.falsy(common.constant_time_equals('abc', 'abd'))
    assert.falsy(common.constant_time_equals('abc', 'ab'))
    assert.falsy(common.constant_time_equals(nil, 'ab'))
  end)
end)

describe('http over tcp', function()
  it('serves a request with query, lowercased headers and Content-Length', function()
    local seen
    local s = listen({
      tcp = { host = '127.0.0.1', port = 0 },
      on_request = function(req, res)
        seen = req
        echo_handler(req, res)
      end,
    })
    assert.truthy(s.port > 0)
    local c = connect('tcp', s.port)
    c.send('GET /a/b?x=1&y=hello%20world&z HTTP/1.1\r\nHost: 127.0.0.1\r\nUser-Agent: T\r\nX-Multi: a\r\nx-multi: b\r\n\r\n')
    local r = wait_responses(c, 1)[1]
    assert.eq(200, r.status)
    assert.eq('application/json', r.headers['content-type'])
    assert.eq(tostring(#r.body), r.headers['content-length'])
    local j = vim.json.decode(r.body)
    assert.eq('GET', j.method)
    assert.eq('/a/b', j.path)
    assert.same({ x = '1', y = 'hello world', z = '' }, j.query)
    assert.eq('T', j.ua)
    assert.eq('a, b', j.x)
    assert.eq('x=1&y=hello%20world&z', seen.raw_query)
    assert.eq('/a/b?x=1&y=hello%20world&z', seen.target)
    assert.eq('tcp', seen.transport)
    assert.eq('127.0.0.1', seen.remote.ip)
    assert.falsy(c.eof)
  end)

  it('reads Content-Length bodies, including large ones split over many reads', function()
    local s = listen({ tcp = { port = 0 }, on_request = echo_handler })
    local c = connect('tcp', s.port)
    c.send('POST /p HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhello')
    assert.eq('hello', vim.json.decode(wait_responses(c, 1)[1].body).body)
    local big = string.rep('0123456789abcdef', 256 * 1024) -- 4 MiB
    local got
    s.on_request = function(req, res)
      got = req.body
      res:finish('ok')
    end
    c.send('POST /big HTTP/1.1\r\nHost: x\r\nContent-Length: ' .. #big .. '\r\n\r\n')
    for i = 1, #big, 100000 do
      c.send(big:sub(i, i + 99999))
    end
    wait_responses(c, 2, 10000)
    assert.eq(#big, #got)
    assert.truthy(got == big, 'body mismatch')
  end)

  it('decodes chunked bodies with extensions and trailers, byte by byte', function()
    local got
    local s = listen({
      tcp = { port = 0 },
      on_request = function(req, res)
        got = req
        res:finish('ok')
      end,
    })
    local c = connect('tcp', s.port)
    local raw = 'POST /mcp HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\n'
      .. '5;ext=1\r\nhello\r\n' .. '1\r\n \r\n' .. 'A\r\n0123456789\r\n' .. '0\r\nX-Trailer: yes\r\n\r\n'
    for i = 1, #raw do
      c.send(raw:sub(i, i))
    end
    local r = wait_responses(c, 1)[1]
    assert.eq(200, r.status)
    assert.eq('hello 0123456789', got.body)
    assert.eq(nil, got.headers['content-length'])
  end)

  it('decodes a large chunked body made of many chunks', function()
    local got
    local s = listen({
      tcp = { port = 0 },
      on_request = function(req, res)
        got = req.body
        res:finish('ok')
      end,
    })
    local c = connect('tcp', s.port)
    local parts, raw = {}, { 'POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n' }
    for i = 1, 300 do
      local chunk = string.rep(string.char(65 + i % 26), 7000 + i)
      parts[#parts + 1] = chunk
      raw[#raw + 1] = string.format('%X\r\n%s\r\n', #chunk, chunk)
    end
    raw[#raw + 1] = '0\r\n\r\n'
    c.send(table.concat(raw))
    wait_responses(c, 1, 10000)
    assert.truthy(got == table.concat(parts), 'chunked body mismatch')
  end)

  it('keeps connections alive and answers pipelined requests in order', function()
    local order = {}
    local s = listen({
      tcp = { port = 0 },
      on_request = function(req, res)
        order[#order + 1] = req.path
        if req.path == '/slow' then
          vim.defer_fn(function()
            res:finish('slow:' .. req.conn_id)
          end, 80)
        else
          res:finish(req.path:sub(2) .. ':' .. req.body .. ':' .. req.conn_id)
        end
      end,
    })
    local c = connect('tcp', s.port)
    c.send('GET /slow HTTP/1.1\r\nHost: x\r\n\r\n'
      .. 'POST /two HTTP/1.1\r\nHost: x\r\nContent-Length: 3\r\n\r\nabc'
      .. 'POST /three HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n2\r\nxy\r\n0\r\n\r\n')
    local rs = wait_responses(c, 3)
    local id = rs[1].body:match(':(%d+)$')
    assert.eq('slow:' .. id, rs[1].body)
    assert.eq('two:abc:' .. id, rs[2].body)
    assert.eq('three:xy:' .. id, rs[3].body)
    assert.same({ '/slow', '/two', '/three' }, order)
    -- A later request on the same socket reuses the connection.
    c.send('GET /four HTTP/1.1\r\nHost: x\r\n\r\n')
    rs = wait_responses(c, 4)
    assert.eq('four::' .. id, rs[4].body)
    assert.falsy(c.eof)
    assert.eq(1, s:connection_count())
  end)

  it('closes after Connection: close and after HTTP/1.0 without keep-alive', function()
    local s = listen({ tcp = { port = 0 }, on_request = echo_handler })
    local c = connect('tcp', s.port)
    c.send('GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n')
    local r = wait_responses(c, 1)[1]
    assert.eq('close', r.headers['connection'])
    wait_for(function()
      return c.eof
    end, 2000, 'eof')

    local c2 = connect('tcp', s.port)
    c2.send('GET / HTTP/1.0\r\n\r\n')
    r = wait_responses(c2, 1)[1]
    assert.eq('close', r.headers['connection'])
    assert.eq('1.0', vim.json.decode(r.body).version)
    wait_for(function()
      return c2.eof
    end, 2000, 'eof 1.0')

    local c3 = connect('tcp', s.port)
    c3.send('GET / HTTP/1.0\r\nConnection: keep-alive\r\n\r\n')
    r = wait_responses(c3, 1)[1]
    assert.eq('keep-alive', r.headers['connection'])
    vim.wait(50)
    assert.falsy(c3.eof)
  end)

  it('rejects malformed and oversized requests', function()
    local s = listen({ tcp = { port = 0 }, on_request = echo_handler, max_header_size = 1024, max_body_size = 100 })
    local cases = {
      { 'GET / HTTP/1.1\r\nHost: x\r\nX-Big: ' .. string.rep('a', 2000) .. '\r\n\r\n', 431 },
      { 'POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 101\r\n\r\n', 413 },
      { 'POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n65\r\n' .. string.rep('a', 101) .. '\r\n0\r\n\r\n', 413 },
      { 'POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\nContent-Length: 3\r\n\r\nabc', 400 },
      { 'POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: gzip, chunked\r\n\r\n', 501 },
      { 'POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\n', 400 },
      { 'POST / HTTP/1.1\r\nHost: x\r\nContent-Length: abc\r\n\r\n', 400 },
      { 'POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\nab', 400 },
      { 'GET / HTTP/2.0\r\n\r\n', 505 },
      { 'hello there\r\n\r\n', 400 },
      { '\1\2\3', 400 },
      { 'GET / HTTP/1.1\r\nBad Header\r\n\r\n', 400 },
    }
    for i, case in ipairs(cases) do
      local c = connect('tcp', s.port)
      c.send(case[1])
      local rs = wait_responses(c, 1)
      assert.eq(case[2], rs[1].status, 'case ' .. i)
      assert.eq('close', rs[1].headers['connection'], 'case ' .. i)
      wait_for(function()
        return c.eof
      end, 2000, 'eof case ' .. i)
    end
  end)

  it('accepts equal duplicate Content-Length values', function()
    local s = listen({ tcp = { port = 0 }, on_request = echo_handler })
    local c = connect('tcp', s.port)
    c.send('POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 2\r\nContent-Length: 2\r\n\r\nab')
    assert.eq('ab', vim.json.decode(wait_responses(c, 1)[1].body).body)
  end)

  it('answers Expect: 100-continue', function()
    local s = listen({ tcp = { port = 0 }, on_request = echo_handler })
    local c = connect('tcp', s.port)
    c.send('POST / HTTP/1.1\r\nHost: x\r\nExpect: 100-continue\r\nContent-Length: 4\r\n\r\n')
    wait_for(function()
      return c.text():find('HTTP/1.1 100 Continue\r\n\r\n', 1, true) ~= nil
    end, 2000, '100 Continue')
    c.send('data')
    local r = wait_responses(c, 1)[1]
    assert.eq('data', vim.json.decode(r.body).body)
  end)

  it('omits bodies for HEAD, 204 and 304 and sends Content-Length: 0 for empty 202', function()
    local s = listen({
      tcp = { port = 0 },
      on_request = function(req, res)
        local status = tonumber(req.path:sub(2)) or 200
        res:write_head(status, { ['X-S'] = status })
        res:finish(status == 202 and '' or 'body!')
      end,
    })
    local c = connect('tcp', s.port)
    c.send('GET /204 HTTP/1.1\r\nHost: x\r\n\r\nGET /202 HTTP/1.1\r\nHost: x\r\n\r\nHEAD /200 HTTP/1.1\r\nHost: x\r\n\r\nGET /200 HTTP/1.1\r\nHost: x\r\n\r\n')
    wait_for(function()
      local t = c.text()
      return select(2, t:gsub('HTTP/1%.1 ', '')) >= 4 and t:sub(-5) == 'body!'
    end, 2000, 'responses')
    local t = c.text()
    local r204 = t:match('^(HTTP/1%.1 204.-\r\n\r\n)')
    assert.truthy(r204)
    assert.falsy(r204:lower():find('content%-length'))
    assert.truthy(t:find('HTTP/1.1 202 Accepted\r\n', 1, true))
    assert.truthy(t:match('HTTP/1%.1 202 Accepted\r\n.-[Cc]ontent%-[Ll]ength: 0\r\n'))
    -- HEAD: head with Content-Length: 5 and no body, immediately followed by the GET's head.
    local head_part = t:match('(HTTP/1%.1 200 OK\r\n.-\r\n\r\n)HTTP/1%.1 200 OK')
    assert.truthy(head_part, t)
    assert.truthy(head_part:find('Content-Length: 5', 1, true))
    assert.eq('body!', t:sub(-5))
  end)

  it('turns handler errors into 500', function()
    local s = listen({
      tcp = { port = 0 },
      on_request = function()
        error('boom')
      end,
    })
    local c = connect('tcp', s.port)
    local notify = vim.notify
    vim.notify = function() end
    c.send('GET / HTTP/1.1\r\nHost: x\r\n\r\n')
    local r = wait_responses(c, 1)[1]
    vim.wait(20)
    vim.notify = notify
    assert.eq(500, r.status)
  end)

  it('answers 404 without a handler and sanitizes header values', function()
    local s = listen({ tcp = { port = 0 } })
    local c = connect('tcp', s.port)
    c.send('GET / HTTP/1.1\r\nHost: x\r\n\r\n')
    assert.eq(404, wait_responses(c, 1)[1].status)
    s.on_request = function(_, res)
      res:write_head(200, { ['X-Evil'] = 'a\r\nInjected: 1' })
      res:finish('')
    end
    c.send('GET / HTTP/1.1\r\nHost: x\r\n\r\n')
    local r = wait_responses(c, 2)[2]
    assert.eq('aInjected: 1', r.headers['x-evil'])
    assert.eq(nil, r.headers['injected'])
  end)

  it('binds a port inside a range', function()
    local s = listen({ tcp = { port = { min = 20000, max = 60000 } }, on_request = echo_handler })
    assert.truthy(s.port >= 20000 and s.port <= 60000)
    local occupied = s.port
    local s2 = listen({ tcp = { port = { occupied, occupied + 1 } } })
    assert.eq(occupied + 1, s2.port)
    local s3, err = http.listen({ tcp = { port = occupied } })
    assert.falsy(s3)
    assert.matches('EADDRINUSE', err)
  end)
end)

describe('http streaming', function()
  it('streams SSE events (chunked) and keeps the connection for the next request', function()
    local s = listen({
      tcp = { port = 0 },
      on_request = function(req, res)
        if req.path == '/sse' then
          res:start_stream(200, { ['Content-Type'] = 'text/event-stream', ['mcp-session-id'] = 'abc' })
          res:sse('{"a":1}', { event = 'message' })
          res:sse('line1\nline2\r\nline3', { id = 7 })
          res:sse_comment('keepalive')
          res:sse({ b = 2 })
          vim.defer_fn(function()
            res:finish()
          end, 30)
        else
          res:finish('after')
        end
      end,
    })
    local c = connect('tcp', s.port)
    c.send('GET /sse HTTP/1.1\r\nHost: x\r\nAccept: text/event-stream\r\n\r\n')
    local r = wait_responses(c, 1)[1]
    assert.eq('chunked', r.headers['transfer-encoding'])
    assert.eq('text/event-stream', r.headers['content-type'])
    assert.eq('abc', r.headers['mcp-session-id'])
    assert.eq(nil, r.headers['content-length'])
    assert.eq('event: message\ndata: {"a":1}\n\n'
      .. 'id: 7\ndata: line1\ndata: line2\ndata: line3\n\n'
      .. ': keepalive\n\n'
      .. 'data: {"b":2}\n\n', r.body)
    c.send('GET /next HTTP/1.1\r\nHost: x\r\n\r\n')
    assert.eq('after', wait_responses(c, 2)[2].body)
  end)

  it('sse() starts an event stream with default headers', function()
    local s = listen({
      tcp = { port = 0 },
      on_request = function(_, res)
        res:sse('x')
        res:finish()
      end,
    })
    local c = connect('tcp', s.port)
    c.send('GET / HTTP/1.1\r\nHost: x\r\n\r\n')
    local r = wait_responses(c, 1)[1]
    assert.eq('text/event-stream', r.headers['content-type'])
    assert.eq('no-cache', r.headers['cache-control'])
    assert.eq('data: x\n\n', r.body)
  end)

  it('uses close-delimited streams for HTTP/1.0', function()
    local s = listen({
      tcp = { port = 0 },
      on_request = function(_, res)
        res:start_stream(200, { ['Content-Type'] = 'text/plain' })
        res:write('abc')
        res:write('')
        res:write('def')
        res:finish()
      end,
    })
    local c = connect('tcp', s.port)
    c.send('GET / HTTP/1.0\r\n\r\n')
    wait_for(function()
      return c.eof
    end, 2000, 'eof')
    local t = c.text()
    assert.falsy(t:lower():find('transfer%-encoding'))
    assert.truthy(t:find('Connection: close', 1, true))
    assert.eq('abcdef', t:match('\r\n\r\n(.*)$'))
  end)

  it('fires res:on_close when the peer disconnects mid-stream', function()
    local closed, the_res = 0, nil
    local s = listen({
      tcp = { port = 0 },
      on_request = function(_, res)
        the_res = res
        res:on_close(function()
          closed = closed + 1
        end)
        res:start_stream(200, { ['Content-Type'] = 'text/event-stream' })
        res:sse_comment('hi')
      end,
    })
    local c = connect('tcp', s.port)
    c.send('GET / HTTP/1.1\r\nHost: x\r\n\r\n')
    wait_for(function()
      return c.text():find(': hi', 1, true) ~= nil
    end, 2000, 'first event')
    c.close()
    wait_for(function()
      return closed == 1
    end, 2000, 'on_close')
    assert.truthy(the_res.closed)
    assert.falsy(the_res:sse('late'))
    assert.falsy(the_res:finish())
    local late = false
    the_res:on_close(function()
      late = true
    end)
    wait_for(function()
      return late
    end, 1000, 'late on_close registration')
    assert.eq(0, s:connection_count())
  end)

  it('does not fire on_close after a normal finish', function()
    local fired = false
    local s = listen({
      tcp = { port = 0 },
      on_request = function(_, res)
        res:on_close(function()
          fired = true
        end)
        res:finish('done')
      end,
    })
    local c = connect('tcp', s.port)
    c.send('GET / HTTP/1.1\r\nHost: x\r\n\r\n')
    wait_responses(c, 1)
    c.close()
    vim.wait(100)
    assert.falsy(fired)
  end)

  it('fires on_close for a pending (non-streaming) response when the peer leaves', function()
    local fired, the_res = false, nil
    local s = listen({
      tcp = { port = 0 },
      on_request = function(_, res)
        the_res = res
        res:on_close(function()
          fired = true
        end)
      end,
    })
    local c = connect('tcp', s.port)
    c.send('POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\n\r\n')
    wait_for(function()
      return the_res ~= nil
    end, 2000, 'dispatch')
    c.close()
    wait_for(function()
      return fired
    end, 2000, 'on_close')
    assert.falsy(the_res:finish('too late'))
  end)

  it('server:close() ends streams gracefully and closes every connection', function()
    local closed = 0
    local s = listen({
      tcp = { port = 0 },
      on_request = function(req, res)
        if req.path == '/sse' then
          res:on_close(function()
            closed = closed + 1
          end)
          res:sse_comment('open')
        else
          res:finish('idle')
        end
      end,
    })
    local sse = connect('tcp', s.port)
    sse.send('GET /sse HTTP/1.1\r\nHost: x\r\n\r\n')
    local idle = connect('tcp', s.port)
    idle.send('GET /idle HTTP/1.1\r\nHost: x\r\n\r\n')
    wait_responses(idle, 1)
    wait_for(function()
      return sse.text():find(': open', 1, true) ~= nil
    end, 2000, 'stream open')
    local silent = connect('tcp', s.port)
    vim.wait(20)
    assert.eq(3, s:connection_count())
    s:close()
    wait_for(function()
      return sse.eof and idle.eof and silent.eof
    end, 3000, 'all connections closed')
    local r = parse_responses(sse.text())[1]
    assert.truthy(r.complete, 'stream ended with the last chunk')
    assert.falsy(sse.err)
    wait_for(function()
      return closed == 1
    end, 1000, 'on_close')
    assert.eq(0, s:connection_count())
    -- The port is released.
    local probe = uv.new_tcp()
    local refused
    probe:connect('127.0.0.1', s.port, function(err)
      refused = err or 'connected'
    end)
    wait_for(function()
      return refused
    end, 2000, 'connect result')
    probe:close()
    assert.matches('ECONNREFUSED', refused)
  end)
end)

describe('http over a unix socket', function()
  if common.is_windows then
    return
  end

  it('creates a 0700 dir and a 0600 socket, serves requests, and cleans up on close', function()
    local base = tmpdir()
    local path = base .. '/sub/m.sock'
    local s = listen({ pipe = path, on_request = echo_handler })
    assert.eq(path, s.path)
    assert.eq('socket', uv.fs_stat(path).type)
    assert.eq(tonumber('700', 8), mode_of(base .. '/sub'))
    assert.eq(tonumber('600', 8), mode_of(path))
    local c = connect('pipe', path)
    c.send('POST /mcp HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n0\r\n\r\n')
    local r = wait_responses(c, 1)[1]
    local j = vim.json.decode(r.body)
    assert.eq('abc', j.body)
    c.send('GET /again HTTP/1.1\r\nHost: localhost\r\n\r\n')
    local r2 = wait_responses(c, 2)[2]
    assert.eq(j.conn, vim.json.decode(r2.body).conn)
    s:close()
    wait_for(function()
      return c.eof
    end, 2000, 'eof')
    assert.eq(nil, uv.fs_stat(path))
    assert.eq(nil, uv.fs_stat(base .. '/sub'), 'created dir removed')
  end)

  it('keeps an existing directory and its mode', function()
    local base = tmpdir()
    local s = listen({ pipe = base .. '/m.sock', on_request = echo_handler })
    s:close()
    assert.truthy(uv.fs_stat(base))
    assert.eq(tonumber('700', 8), mode_of(base))
    assert.eq(nil, uv.fs_stat(base .. '/m.sock'))
  end)

  it('creates and removes nested missing directories', function()
    local base = tmpdir()
    local path = base .. '/a/b/m.sock'
    local s = listen({ pipe = path, on_request = echo_handler })
    assert.eq(tonumber('700', 8), mode_of(base .. '/a'))
    assert.eq(tonumber('700', 8), mode_of(base .. '/a/b'))
    s:close()
    assert.eq(nil, uv.fs_stat(base .. '/a'))
    -- A failed listen cleans up what it created too.
    local long = base .. '/c/' .. string.rep('y', 110) .. '.sock'
    local s2, err = http.listen({ pipe = long })
    assert.falsy(s2)
    assert.matches('EINVAL', err)
    assert.eq(nil, uv.fs_stat(base .. '/c'))
  end)

  it('refuses a socket directory owned by another user', function()
    if uv.getuid() == 0 then
      return
    end
    -- /usr/bin exists everywhere, is owned by root and is not sticky.
    local s, err = http.listen({ pipe = '/usr/bin/agent-nvim-test.sock' })
    assert.falsy(s)
    assert.matches('not owned by the current user', err)
  end)

  it('replaces a stale socket file', function()
    local base = tmpdir()
    local path = base .. '/m.sock'
    -- Make a socket file with no listener: bind elsewhere, move it into place, close.
    local p = uv.new_pipe(false)
    assert.truthy(p:bind2(base .. '/tmp.sock', { no_truncate = true }))
    assert.truthy(uv.fs_rename(base .. '/tmp.sock', path))
    p:close()
    vim.wait(10)
    assert.eq('socket', uv.fs_lstat(path).type)
    local s = listen({ pipe = path, on_request = echo_handler })
    local c = connect('pipe', path)
    c.send('GET / HTTP/1.1\r\nHost: localhost\r\n\r\n')
    assert.eq(200, wait_responses(c, 1)[1].status)
    s:close()
  end)

  it('refuses to replace a regular file', function()
    local base = tmpdir()
    local path = base .. '/m.sock'
    vim.fn.writefile({ 'keep me' }, path)
    local s, err = http.listen({ pipe = path })
    assert.falsy(s)
    assert.matches('not a socket', err)
    assert.same({ 'keep me' }, vim.fn.readfile(path))
  end)

  it('fails on a socket path that is too long instead of truncating it', function()
    local base = tmpdir()
    local path = base .. '/' .. string.rep('x', 120) .. '.sock'
    local s, err = http.listen({ pipe = path })
    assert.falsy(s)
    assert.matches('EINVAL', err)
    assert.eq(nil, uv.fs_stat(path))
  end)
end)
