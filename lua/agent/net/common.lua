---@mod agent.net.common Shared helpers for the HTTP and WebSocket servers
---
--- Everything here is safe to call from fast (libuv) contexts: no vim.api / vim.fn.
local uv = vim.uv
local bit = require('bit')

local M = {}

M.is_windows = uv.os_uname().sysname:find('Windows') ~= nil

-- ---------------------------------------------------------------------------
-- Byte queue
-- ---------------------------------------------------------------------------

---A FIFO byte queue made of the chunks libuv hands us. Reading N bytes concatenates only what
---is needed, so assembling a 100 MB body from 64 KiB reads stays linear.
---@class agent.net.Buffer
---@field chunks string[]
---@field first integer index of the first live chunk
---@field last integer index of the last live chunk
---@field offset integer bytes already consumed from chunks[first]
---@field size integer bytes available
local Buffer = {}
Buffer.__index = Buffer

---@return agent.net.Buffer
function M.buffer()
  return setmetatable({ chunks = {}, first = 1, last = 0, offset = 0, size = 0 }, Buffer)
end

---@param s string
function Buffer:push(s)
  if s and #s > 0 then
    self.last = self.last + 1
    self.chunks[self.last] = s
    self.size = self.size + #s
  end
end

function Buffer:clear()
  self.chunks, self.first, self.last, self.offset, self.size = {}, 1, 0, 0, 0
end

---Up to the first `n` bytes, without consuming them.
---@param n integer
---@return string
function Buffer:peek(n)
  if n > self.size then
    n = self.size
  end
  if n <= 0 then
    return ''
  end
  local c = self.chunks[self.first]
  local avail = #c - self.offset
  if n <= avail then
    return c:sub(self.offset + 1, self.offset + n)
  end
  local parts, got = { c:sub(self.offset + 1) }, avail
  local i = self.first + 1
  while got < n do
    c = self.chunks[i]
    local need = n - got
    if #c <= need then
      parts[#parts + 1] = c
      got = got + #c
    else
      parts[#parts + 1] = c:sub(1, need)
      got = n
    end
    i = i + 1
  end
  return table.concat(parts)
end

---Remove and return the first `n` bytes (fewer when the queue holds less).
---@param n integer
---@return string
function Buffer:take(n)
  if n > self.size then
    n = self.size
  end
  if n <= 0 then
    return ''
  end
  local parts, got = {}, 0
  while got < n do
    local c = self.chunks[self.first]
    local avail = #c - self.offset
    local need = n - got
    if avail <= need then
      parts[#parts + 1] = self.offset == 0 and c or c:sub(self.offset + 1)
      got = got + avail
      self.chunks[self.first] = nil
      self.first = self.first + 1
      self.offset = 0
    else
      parts[#parts + 1] = c:sub(self.offset + 1, self.offset + need)
      self.offset = self.offset + need
      got = n
    end
  end
  self.size = self.size - n
  if self.size == 0 then
    self:clear()
  end
  return #parts == 1 and parts[1] or table.concat(parts)
end

---Drop the first `n` bytes.
---@param n integer
function Buffer:skip(n)
  self:take(n)
end

---Find `needle` (plain, at least 2 bytes) entirely within the first `limit` bytes, searching
---chunk by chunk without concatenating the queue.
---@param needle string
---@param limit integer
---@return integer|nil pos 1-based start of the match
function Buffer:find(needle, limit)
  local nlen = #needle
  local pos = 0 -- bytes of the queue before the current chunk's live region
  local tail = '' -- the last (nlen - 1) queued bytes before the current chunk
  for i = self.first, self.last do
    local c = self.chunks[i]
    local off = i == self.first and self.offset or 0
    local j, lp
    if tail ~= '' then
      -- A match that straddles the boundary with earlier chunks.
      j = (tail .. c:sub(off + 1, off + nlen - 1)):find(needle, 1, true)
      if j then
        lp = pos - #tail + j
      end
    end
    if not lp then
      j = c:find(needle, off + 1, true)
      if j then
        lp = pos + (j - off)
      end
    end
    if lp then
      return lp + nlen - 1 <= limit and lp or nil
    end
    pos = pos + #c - off
    if pos >= limit then
      return nil
    end
    tail = (tail .. c:sub(math.max(off + 1, #c - nlen + 2))):sub(-(nlen - 1))
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- Listening sockets
-- ---------------------------------------------------------------------------

---@param handle uv.uv_handle_t|nil
function M.close_handle(handle)
  if handle and not handle:is_closing() then
    handle:close()
  end
end

-- Uniform-enough random integer in [0, n) without touching the global math.random state.
local function random_below(n)
  local ok, b = pcall(uv.random, 4)
  local r
  if ok and type(b) == 'string' and #b == 4 then
    local b1, b2, b3, b4 = b:byte(1, 4)
    r = ((b1 * 256 + b2) * 256 + b3) * 256 + b4
  else
    r = math.floor(uv.hrtime() / 1000)
  end
  return r % n
end

---Bind and listen on a TCP port. `port` is a number (0 = ephemeral) or a range
---`{min, max}` / `{min=, max=}` tried in random order.
---@param host string numeric IP address, e.g. '127.0.0.1'
---@param port integer|table
---@param on_connection fun(err: string|nil)
---@param backlog integer|nil
---@return uv.uv_tcp_t|nil handle, integer|string port_or_err
function M.listen_tcp(host, port, on_connection, backlog)
  local candidates
  if type(port) == 'table' then
    local lo, hi = port.min or port[1], port.max or port[2]
    if type(lo) ~= 'number' or type(hi) ~= 'number' or lo < 1 or hi > 65535 or lo > hi then
      return nil, 'invalid port range'
    end
    candidates = {}
    local span = hi - lo + 1
    local tries = math.min(span, 200)
    local seen = {}
    local guard = 0
    while #candidates < tries and guard < tries * 10 do
      guard = guard + 1
      local p = lo + random_below(span)
      if not seen[p] then
        seen[p] = true
        candidates[#candidates + 1] = p
      end
    end
  else
    candidates = { port or 0 }
  end
  local last_err = 'no port available'
  for _, p in ipairs(candidates) do
    local handle = uv.new_tcp()
    if not handle then
      return nil, 'uv.new_tcp failed'
    end
    local ok, r1, r2 = pcall(handle.bind, handle, host, p)
    if not ok then
      M.close_handle(handle)
      return nil, tostring(r1)
    end
    if not r1 then
      last_err = tostring(r2)
    else
      local lok, lerr = handle:listen(backlog or 128, on_connection)
      if lok then
        local name = handle:getsockname()
        return handle, name and name.port or p
      end
      last_err = tostring(lerr)
    end
    M.close_handle(handle)
    if type(port) ~= 'table' then
      break
    end
  end
  return nil, last_err
end

local S_IFMT = tonumber('170000', 8)
local S_IFSOCK = tonumber('140000', 8)

---@param path string
---@return boolean
function M.is_windows_pipe(path)
  return M.is_windows or path:match('^\\\\[.?]\\pipe\\') ~= nil
end

---Bind and listen on a Unix domain socket (or a Windows named pipe).
---POSIX: creates a missing parent directory with mode 0700, unlinks a stale socket left by a
---crashed process, refuses to replace anything that is not a socket, binds with
---`no_truncate` (paths over the sun_path limit fail with EINVAL instead of being cut short)
---and chmods the socket to `mode` (default 0600).
---@param path string
---@param on_connection fun(err: string|nil)
---@param opts { mode?: integer, backlog?: integer }|nil
---@return uv.uv_pipe_t|nil handle, string|nil err, string[] created directories created here, outermost first
function M.listen_pipe(path, on_connection, opts)
  opts = opts or {}
  local windows = M.is_windows_pipe(path)
  local created = {}
  if not windows then
    local dir = vim.fs.dirname(path)
    if dir and dir ~= '' and not uv.fs_stat(dir) then
      -- mkdir -p; the final component gets 0700 (parents that did not exist too).
      local parts, cur = {}, dir
      while cur and cur ~= '' and not uv.fs_stat(cur) do
        table.insert(parts, 1, cur)
        local parent = vim.fs.dirname(cur)
        if parent == cur then
          break
        end
        cur = parent
      end
      for _, d in ipairs(parts) do
        local ok, err = uv.fs_mkdir(d, tonumber('700', 8))
        if not ok and not uv.fs_stat(d) then
          return nil, 'mkdir ' .. d .. ': ' .. tostring(err), created
        end
        if ok then
          created[#created + 1] = d
        end
      end
      uv.fs_chmod(dir, tonumber('700', 8))
    elseif dir and dir ~= '' then
      -- Someone else's directory (e.g. pre-created in a shared /tmp) could swap the socket.
      -- Allow our own directories and root-owned sticky ones such as /tmp itself.
      local st = uv.fs_stat(dir)
      local sticky = bit.band(st.mode, tonumber('1000', 8)) ~= 0
      if st.uid ~= uv.getuid() and not (st.uid == 0 and sticky) then
        return nil, 'socket directory ' .. dir .. ' is not owned by the current user', created
      end
    end
    local st = uv.fs_lstat(path)
    if st then
      if bit.band(st.mode, S_IFMT) ~= S_IFSOCK then
        return nil, path .. ' exists and is not a socket', created
      end
      -- A socket file left behind by a crashed process makes bind fail with EADDRINUSE.
      uv.fs_unlink(path)
    end
  end
  local handle = uv.new_pipe(false)
  if not handle then
    return nil, 'uv.new_pipe failed', created
  end
  local ok, err = handle:bind2(path, { no_truncate = true })
  if not ok then
    M.close_handle(handle)
    if tostring(err):find('EINVAL') and not windows then
      err = tostring(err) .. ' (socket path too long? ' .. #path .. ' bytes)'
    end
    return nil, 'bind ' .. path .. ': ' .. tostring(err), created
  end
  if not windows then
    uv.fs_chmod(path, opts.mode or tonumber('600', 8))
  end
  local lok, lerr = handle:listen(opts.backlog or 128, on_connection)
  if not lok then
    M.close_handle(handle)
    return nil, 'listen ' .. path .. ': ' .. tostring(lerr), created
  end
  return handle, nil, created
end

---Remove directories returned by listen_pipe (innermost first; non-empty ones stay).
---@param dirs string[]|nil
function M.remove_created_dirs(dirs)
  for i = #(dirs or {}), 1, -1 do
    pcall(uv.fs_rmdir, dirs[i])
  end
end

---Lingering close: flush pending writes, send FIN, then keep reading (and dropping) whatever
---the peer still sends until it closes too, or `timeout_ms` (default 2000) passes. Closing with
---unread input would make the kernel send RST, which can destroy our last response (e.g. a 413
---or a WebSocket Close 1009) before the peer reads it.
---@param handle uv.uv_stream_t
---@param timeout_ms integer|nil
function M.shutdown_close(handle, timeout_ms)
  if not handle or handle:is_closing() then
    return
  end
  local timer = uv.new_timer()
  local function done()
    if timer and not timer:is_closing() then
      timer:stop()
      timer:close()
    end
    M.close_handle(handle)
  end
  timer:start(timeout_ms or 2000, 0, done)
  pcall(handle.read_stop, handle)
  local reading = pcall(handle.read_start, handle, function(err, chunk)
    if err or not chunk then
      done()
    end
  end)
  local ok, req = pcall(handle.shutdown, handle, function(err)
    if err or not reading then
      done()
    end
  end)
  if not ok or not req then
    done()
  end
end

---Write to a stream, ignoring errors on handles that are already closing.
---@param handle uv.uv_stream_t
---@param data string|string[]
---@param cb fun(err: string|nil)|nil
---@return boolean ok
function M.write(handle, data, cb)
  if not handle or handle:is_closing() then
    return false
  end
  local ok, res = pcall(handle.write, handle, data, cb)
  return ok and res ~= nil
end

-- ---------------------------------------------------------------------------
-- HTTP head parsing (shared by the HTTP server and the WebSocket upgrade)
-- ---------------------------------------------------------------------------

---@class agent.net.RequestHead
---@field method string
---@field target string raw request-target
---@field path string target without the query string
---@field raw_query string|nil
---@field version string '1.1' | '1.0'
---@field headers table<string, string> lowercased names; repeated fields joined with ', '
---@field header_list { [1]: string, [2]: string }[] original names and values, in order

---Parse a request head (request line + header fields, without the final CRLFCRLF).
---@param head string
---@return agent.net.RequestHead|nil head, string|nil err
function M.parse_head(head)
  local line_end = head:find('\r\n', 1, true)
  local request_line = line_end and head:sub(1, line_end - 1) or head
  local method, target, version = request_line:match('^(%u+) (%S+) HTTP/(%d%.%d)$')
  if not method then
    return nil, 'malformed request line'
  end
  local headers, list = {}, {}
  if line_end then
    local pos = line_end + 2
    local n = #head
    while pos <= n do
      local e = head:find('\r\n', pos, true) or (n + 1)
      local line = head:sub(pos, e - 1)
      pos = e + 2
      if line:find('^[ \t]') then
        return nil, 'obsolete line folding'
      end
      local name, value = line:match('^([!#$%%&\'*+%-.^_`|~%w]+):[ \t]*(.-)[ \t]*$')
      if not name then
        return nil, 'malformed header field'
      end
      list[#list + 1] = { name, value }
      local key = name:lower()
      local prev = headers[key]
      if prev == nil then
        headers[key] = value
      elseif key == 'host' or key == 'content-length' then
        -- Duplicates of these are ambiguous; let the caller detect them.
        headers[key] = prev .. ',' .. value
      else
        headers[key] = prev .. ', ' .. value
      end
    end
  end
  local path, query = target:match('^([^?]*)%??(.*)$')
  return {
    method = method,
    target = target,
    path = path,
    raw_query = target:find('?', 1, true) and query or nil,
    version = version,
    headers = headers,
    header_list = list,
  }
end

---True when the comma-separated header `value` contains `token` (case-insensitive).
---@param value string|nil
---@param token string
---@return boolean
function M.has_token(value, token)
  if not value then
    return false
  end
  token = token:lower()
  for part in value:gmatch('[^,]+') do
    if vim.trim(part):lower() == token then
      return true
    end
  end
  return false
end

---Split a comma-separated header value into trimmed, non-empty items.
---@param value string|nil
---@return string[]
function M.split_list(value)
  local out = {}
  if value then
    for part in value:gmatch('[^,]+') do
      local p = vim.trim(part)
      if p ~= '' then
        out[#out + 1] = p
      end
    end
  end
  return out
end

local function unhex(h)
  return string.char(tonumber(h, 16))
end

---Decode `application/x-www-form-urlencoded` / URL percent-encoding.
---@param s string
---@return string
function M.url_decode(s)
  return (s:gsub('+', ' '):gsub('%%(%x%x)', unhex))
end

---Parse a query string into a table (last value wins for repeated keys).
---@param raw string|nil
---@return table<string, string>
function M.parse_query(raw)
  local out = {}
  if raw and raw ~= '' then
    for pair in raw:gmatch('[^&]+') do
      local k, v = pair:match('^([^=]*)=?(.*)$')
      if k and k ~= '' then
        out[M.url_decode(k)] = M.url_decode(v)
      end
    end
  end
  return out
end

-- ---------------------------------------------------------------------------
-- Misc
-- ---------------------------------------------------------------------------

---Compare two secrets in time that depends only on their lengths.
---@param a any
---@param b any
---@return boolean
function M.constant_time_equals(a, b)
  if type(a) ~= 'string' or type(b) ~= 'string' or #a ~= #b then
    return false
  end
  local diff = 0
  for i = 1, #a do
    diff = bit.bor(diff, bit.bxor(a:byte(i), b:byte(i)))
  end
  return diff == 0
end

---Validate UTF-8 (RFC 3629: no overlongs, no surrogates, max U+10FFFF).
---@param s string
---@return boolean
function M.valid_utf8(s)
  local byte, find = string.byte, string.find
  local i, n = 1, #s
  while i <= n do
    -- Skip ASCII runs quickly.
    local j = find(s, '[\128-\255]', i)
    if not j then
      return true
    end
    i = j
    local c = byte(s, i)
    if c >= 0xC2 and c <= 0xDF then
      local c2 = byte(s, i + 1)
      if not c2 or c2 < 0x80 or c2 > 0xBF then
        return false
      end
      i = i + 2
    elseif c >= 0xE0 and c <= 0xEF then
      local c2, c3 = byte(s, i + 1, i + 2)
      if not c3 or c3 < 0x80 or c3 > 0xBF then
        return false
      end
      local lo, hi = 0x80, 0xBF
      if c == 0xE0 then
        lo = 0xA0
      elseif c == 0xED then
        hi = 0x9F
      end
      if c2 < lo or c2 > hi then
        return false
      end
      i = i + 3
    elseif c >= 0xF0 and c <= 0xF4 then
      local c2, c3, c4 = byte(s, i + 1, i + 3)
      if not c4 or c3 < 0x80 or c3 > 0xBF or c4 < 0x80 or c4 > 0xBF then
        return false
      end
      local lo, hi = 0x80, 0xBF
      if c == 0xF0 then
        lo = 0x90
      elseif c == 0xF4 then
        hi = 0x8F
      end
      if c2 < lo or c2 > hi then
        return false
      end
      i = i + 4
    else
      return false
    end
  end
  return true
end

---Run `fn(...)` on the main loop, protected; errors are reported through `on_error`.
---@param fn function|nil
---@param on_error fun(err: string)|nil
function M.schedule_call(fn, on_error, ...)
  if not fn then
    return
  end
  local args = { n = select('#', ...), ... }
  vim.schedule(function()
    local ok, err = xpcall(function()
      return fn(unpack(args, 1, args.n))
    end, debug.traceback)
    if not ok and on_error then
      on_error(err)
    end
  end)
end

return M
