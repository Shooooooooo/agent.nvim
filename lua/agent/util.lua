---@mod agent.util Shared helpers (files, tokens, JSON, paths)
local uv = vim.uv or vim.loop

local M = {}

M.is_windows = uv.os_uname().sysname:find('Windows') ~= nil

---Cryptographically random bytes. Never falls back to math.random.
---@param n integer
---@return string bytes
function M.random_bytes(n)
  local ok, bytes = pcall(uv.random, n)
  if ok and type(bytes) == 'string' and #bytes == n then
    return bytes
  end
  local f = io.open('/dev/urandom', 'rb')
  if f then
    local b = f:read(n)
    f:close()
    if b and #b == n then
      return b
    end
  end
  error('agent.nvim: no secure random source available')
end

---@param nbytes integer
---@return string hex lowercase hex string of length 2*nbytes
function M.random_hex(nbytes)
  return (M.random_bytes(nbytes):gsub('.', function(c)
    return string.format('%02x', c:byte())
  end))
end

---RFC 4122 version 4 UUID.
---@return string
function M.uuid()
  local b = { M.random_bytes(16):byte(1, 16) }
  b[7] = bit.bor(bit.band(b[7], 0x0f), 0x40)
  b[9] = bit.bor(bit.band(b[9], 0x3f), 0x80)
  local hex = {}
  for i = 1, 16 do
    hex[i] = string.format('%02x', b[i])
  end
  return table.concat(hex, '', 1, 4) .. '-' .. table.concat(hex, '', 5, 6) .. '-'
    .. table.concat(hex, '', 7, 8) .. '-' .. table.concat(hex, '', 9, 10) .. '-'
    .. table.concat(hex, '', 11, 16)
end

---Milliseconds from a monotonic clock.
---@return number
function M.now_ms()
  return uv.hrtime() / 1e6
end

---Create a directory and its parents. The final directory is chmod'ed to `mode` when we own it.
---Never throws: failures (a path component is a file, no permission, ...) return false and a message.
---@param path string
---@param mode integer|nil e.g. tonumber('700', 8)
---@return boolean ok, string|nil err
function M.mkdir_p(path, mode)
  mode = mode or tonumber('755', 8)
  -- vim.fn.mkdir raises (Vim:E739) rather than returning 0 when creation fails.
  local pok, res = pcall(vim.fn.mkdir, path, 'p', mode)
  if vim.fn.isdirectory(path) == 0 then
    -- The Vim error names the path and the cause, e.g. "E739: Cannot create directory X: file already exists".
    return false, not pok and (tostring(res):gsub('^Vim:', '')) or ('could not create directory ' .. path)
  end
  local st = uv.fs_stat(path)
  if st and st.uid == uv.getuid() then
    uv.fs_chmod(path, mode)
  end
  return true, nil
end

---Write `data` to `path` atomically (temp file + rename) with the given mode.
---@param path string
---@param data string
---@param mode integer|nil default 0600
---@return boolean ok, string|nil err
function M.atomic_write(path, data, mode)
  mode = mode or tonumber('600', 8)
  local tmp = string.format('%s.tmp.%d.%s', path, uv.os_getpid(), M.random_hex(4))
  local fd, err = uv.fs_open(tmp, 'wx', mode)
  if not fd then
    return false, 'open ' .. tmp .. ': ' .. tostring(err)
  end
  local written, werr = uv.fs_write(fd, data, 0)
  uv.fs_close(fd)
  if not written or written ~= #data then
    uv.fs_unlink(tmp)
    return false, 'write ' .. tmp .. ': ' .. tostring(werr)
  end
  uv.fs_chmod(tmp, mode)
  local ok, rerr = uv.fs_rename(tmp, path)
  if not ok then
    uv.fs_unlink(tmp)
    return false, 'rename ' .. tmp .. ': ' .. tostring(rerr)
  end
  return true, nil
end

---Remove a file if it exists (errors ignored).
---@param path string|nil
function M.remove(path)
  if path then
    pcall(uv.fs_unlink, path)
  end
end

---Remove a directory tree (errors ignored).
---@param path string|nil
function M.remove_dir(path)
  if path and path ~= '' and path ~= '/' then
    pcall(vim.fn.delete, path, 'rf')
  end
end

---A table that encodes as a JSON object even when empty.
---@return table
function M.empty_object()
  return vim.empty_dict()
end

---Encode JSON. Empty Lua tables encode as `[]`; use util.empty_object() for objects that may be empty.
---@param value any
---@return string
function M.json_encode(value)
  return vim.json.encode(value)
end

---Decode JSON. JSON null becomes nil inside objects and arrays (a top-level null returns vim.NIL).
---@param s string
---@return boolean ok, any value_or_err
function M.json_decode(s)
  return pcall(vim.json.decode, s, { luanil = { object = true, array = true } })
end

---Resolve symlinks when the path exists; otherwise return the normalized absolute path.
---@param path string
---@return string
function M.realpath(path)
  local abs = vim.fs.normalize(vim.fn.fnamemodify(path, ':p'))
  local real = uv.fs_realpath(abs)
  if real then
    return real
  end
  if #abs > 1 and abs:sub(-1) == '/' then
    abs = abs:sub(1, -2)
  end
  return abs
end

---Absolute, normalized path without resolving symlinks (and without a trailing slash).
---@param path string
---@return string
function M.abspath(path)
  local abs = vim.fs.normalize(vim.fn.fnamemodify(path, ':p'))
  if #abs > 1 and abs:sub(-1) == '/' then
    abs = abs:sub(1, -2)
  end
  return abs
end

---True when `child` equals `parent` or is inside it (plain string prefix on normalized paths).
---@param parent string
---@param child string
---@return boolean
function M.path_contains(parent, child)
  if parent == child then
    return true
  end
  local p = parent:sub(-1) == '/' and parent or (parent .. '/')
  return child:sub(1, #p) == p
end

---How long process_tree() waits for `ps`.
M.PS_TIMEOUT_MS = 1000

---The parent of every process, from one `ps -A -o pid=,ppid=` snapshot (it lists every child,
---whichever thread started it). nil when ps fails.
---@return table<integer, integer>|nil ppid_of
local function ps_parents()
  local ok, res = pcall(function()
    return vim.system({ 'ps', '-A', '-o', 'pid=,ppid=' }, { text = true }):wait(M.PS_TIMEOUT_MS)
  end)
  if not ok or type(res) ~= 'table' or res.code ~= 0 or type(res.stdout) ~= 'string' then
    return nil
  end
  local ppid_of = {}
  for line in res.stdout:gmatch('[^\n]+') do
    local pid, ppid = line:match('^%s*(%d+)%s+(%d+)%s*$')
    if pid then
      ppid_of[tonumber(pid)] = tonumber(ppid)
    end
  end
  return next(ppid_of) ~= nil and ppid_of or nil
end

---Process `pid` and all its descendants, parents before their children (POSIX only): from one
---`ps` snapshot, else with nvim_get_proc_children() (Neovim's own sysctl, /proc or pgrep -P).
---Never this Neovim, pid 1 or below, nor a process that is not `pid` or one of its descendants.
---@param pid integer
---@param opts { parent?: integer }|nil  parent: list nothing unless `pid` is a child of this
---  process (a job's pid is Neovim's child until it is reaped, so this rules out a reused pid)
---@return integer[] pids  empty when `pid` does not qualify, and on Windows
function M.process_tree(pid, opts)
  opts = opts or {}
  local self = uv.os_getpid()
  if M.is_windows or type(pid) ~= 'number' or pid <= 1 or pid == self then
    return {}
  end
  local ppid_of = ps_parents()
  local children_of
  if ppid_of then
    local children = {}
    for p, pp in pairs(ppid_of) do
      children[pp] = children[pp] or {}
      table.insert(children[pp], p)
    end
    for _, list in pairs(children) do
      table.sort(list)
    end
    children_of = function(p)
      return children[p] or {}
    end
  else
    children_of = function(p)
      local ok, list = pcall(vim.api.nvim_get_proc_children, p)
      return ok and type(list) == 'table' and list or {}
    end
  end
  if opts.parent then
    local ok
    if ppid_of then
      ok = ppid_of[pid] == opts.parent
    else
      ok = vim.tbl_contains(children_of(opts.parent), pid)
    end
    if not ok then
      return {}
    end
  end
  local out, seen, i = { pid }, { [pid] = true, [self] = true }, 1
  -- (Bounded: a process table changing under nvim_get_proc_children() must not loop.)
  while i <= #out and #out < 4096 do
    for _, c in ipairs(children_of(out[i])) do
      if type(c) == 'number' and c > 1 and not seen[c] then
        seen[c] = true
        out[#out + 1] = c
      end
    end
    i = i + 1
  end
  return out
end

---Percent-encoded file URL (RFC 8089), e.g. for Copilot fileUrl values.
---@param path string absolute path
---@return string
function M.file_url(path)
  return vim.uri_from_fname(path)
end

---Raw file URL: 'file://' .. path with no percent-encoding.
---Claude Code compares diagnostics URIs this way and drops percent-encoded ones.
---@param path string absolute path
---@return string
function M.file_url_raw(path)
  return 'file://' .. path
end

---Private runtime directory for this Neovim instance (0700), created on demand.
---Does not throw when the directory cannot be created; callers check vim.fn.isdirectory().
---@param ... string extra path components
---@return string
function M.run_dir(...)
  local base = vim.fs.joinpath(vim.fn.stdpath('run'), 'agent.nvim', tostring(uv.os_getpid()))
  local path = select('#', ...) > 0 and vim.fs.joinpath(base, ...) or base
  M.mkdir_p(path, tonumber('700', 8))
  return path
end

---Home directory.
---@return string
function M.home()
  return uv.os_homedir() or vim.env.HOME or ''
end

---Run `fn` on the main loop (safe from libuv callbacks).
---@param fn function
function M.schedule(fn)
  vim.schedule(fn)
end

---Create a debounced function (trailing edge).
---@param ms integer
---@param fn function
---@return function debounced, function cancel
function M.debounce(ms, fn)
  local timer = uv.new_timer()
  local args
  local function debounced(...)
    args = { n = select('#', ...), ... }
    timer:stop()
    timer:start(ms, 0, function()
      vim.schedule(function()
        fn(unpack(args, 1, args.n))
      end)
    end)
  end
  local function cancel()
    timer:stop()
    if not timer:is_closing() then
      timer:close()
    end
  end
  return debounced, cancel
end

---Shallow list concatenation.
---@param ... table
---@return table
function M.concat(...)
  local out = {}
  for i = 1, select('#', ...) do
    local t = select(i, ...)
    if t then
      for _, v in ipairs(t) do
        out[#out + 1] = v
      end
    end
  end
  return out
end

return M
