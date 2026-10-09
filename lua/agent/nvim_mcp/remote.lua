---@mod agent.nvim_mcp.remote Tool implementations executed inside the PARENT Neovim
---
--- This file is self-contained: it is sent as text by the controller and run through
--- nvim_exec_lua in the Neovim that hosts the agent terminal, so it must not require agent.*
--- (the parent does not need agent.nvim loaded). Loaded without arguments it returns the module;
--- run with arguments (tool, args, ctx) it dispatches one call directly.
---
--- Every tool returns either a string (sent as-is) or a JSON-safe value (sent as JSON).
--- All line numbers are 1-based and inclusive.
local api, fn, uv = vim.api, vim.fn, vim.uv

local M = {}

M.VERSION = 1

---@type table<string, fun(args: table, ctx: table): any>
local tools = {}
M.tools = tools

-- JSON safety ---------------------------------------------------------------------------------

local EMPTY_DICT_MT = getmetatable(vim.empty_dict())

---Convert any Lua value into something vim.json.encode accepts: vim.NIL stays null, functions,
---userdata and threads become descriptive strings, NaN/Inf become strings, cycles are cut,
---sparse integer-keyed tables become arrays padded with null (or objects when very sparse).
---@param v any
---@param seen table
---@param depth integer
---@return any
local function json_safe(v, seen, depth)
  local t = type(v)
  if v == nil or v == vim.NIL then
    return vim.NIL
  elseif t == 'boolean' or t == 'string' then
    return v
  elseif t == 'number' then
    if v ~= v then
      return 'NaN'
    elseif v == math.huge then
      return 'Infinity'
    elseif v == -math.huge then
      return '-Infinity'
    end
    return v
  elseif t == 'table' then
    if seen[v] then
      return '<cycle>'
    end
    if depth >= 100 then
      return '<max depth>'
    end
    -- Typed values produced by the API/Vimscript bridge ({[vim.type_idx]=..., [vim.val_idx]=...}).
    local typ = rawget(v, vim.type_idx)
    if typ == vim.types.float then
      return json_safe(rawget(v, vim.val_idx), seen, depth)
    end
    seen[v] = true
    local out
    local count, max_index, all_int = 0, 0, true
    for k in pairs(v) do
      if k ~= vim.type_idx and k ~= vim.val_idx then
        count = count + 1
        if type(k) == 'number' and k >= 1 and k == math.floor(k) then
          if k > max_index then
            max_index = k
          end
        else
          all_int = false
        end
      end
    end
    if count == 0 then
      if typ == vim.types.dictionary or getmetatable(v) == EMPTY_DICT_MT then
        out = vim.empty_dict()
      else
        out = {}
      end
    elseif typ ~= vim.types.dictionary and all_int and max_index <= 2 * count + 16 then
      out = {}
      for i = 1, max_index do
        local x = v[i]
        out[i] = x == nil and vim.NIL or json_safe(x, seen, depth + 1)
      end
    else
      out = {}
      for k, x in pairs(v) do
        if k ~= vim.type_idx and k ~= vim.val_idx then
          out[tostring(k)] = json_safe(x, seen, depth + 1)
        end
      end
    end
    seen[v] = nil
    return out
  elseif t == 'function' then
    return '<function>'
  end
  local ok, s = pcall(tostring, v)
  return ok and s or ('<' .. t .. '>')
end

---@param v any
---@return string
function M.to_json(v)
  return vim.json.encode(json_safe(v, {}, 0))
end

-- Windows ---------------------------------------------------------------------------------------

local SIDEBAR_FILETYPES = {
  ['neo-tree'] = true, ['neo-tree-popup'] = true, NvimTree = true, minifiles = true, netrw = true,
  aerial = true, tagbar = true, Outline = true, undotree = true, qf = true, help = true,
  fugitiveblame = true, ['dapui_scopes'] = true, ['dapui_stacks'] = true, ['dapui_watches'] = true,
  ['dapui_breakpoints'] = true, ['dap-repl'] = true, trouble = true,
}

local function wo(win, name)
  local ok, v = pcall(api.nvim_get_option_value, name, { win = win })
  return ok and v or nil
end

local function is_floating(win)
  return api.nvim_win_get_config(win).relative ~= ''
end

---True for a window where the user edits files: not floating, not a terminal, not a sidebar,
---scratch/special or diff window, and not locked to its buffer.
---@param win integer
---@return boolean
function M.is_editor_window(win)
  if not win or not api.nvim_win_is_valid(win) or is_floating(win) then
    return false
  end
  local buf = api.nvim_win_get_buf(win)
  local bt = vim.bo[buf].buftype
  if bt ~= '' and bt ~= 'acwrite' then
    return false
  end
  if wo(win, 'diff') or wo(win, 'previewwindow') or wo(win, 'winfixbuf') then
    return false
  end
  return not SIDEBAR_FILETYPES[vim.bo[buf].filetype]
end

local function registry()
  local reg = rawget(_G, '__agent_nvim_remote')
  if type(reg) ~= 'table' then
    reg = {}
    rawset(_G, '__agent_nvim_remote', reg)
  end
  reg.mru = reg.mru or {}
  reg.seq = reg.seq or 0
  return reg
end

---Track window use (WinEnter) so the main editor window can be the most recently used one.
---Installed once per parent; safe to call again.
function M.setup()
  local reg = registry()
  local group = api.nvim_create_augroup('agent_nvim_remote_mru', { clear = true })
  local function touch(win)
    reg.seq = reg.seq + 1
    reg.mru[win] = reg.seq
  end
  api.nvim_create_autocmd('WinEnter', {
    group = group,
    callback = function()
      touch(api.nvim_get_current_win())
    end,
  })
  api.nvim_create_autocmd('WinClosed', {
    group = group,
    callback = function(ev)
      local w = tonumber(ev.match)
      if w then
        reg.mru[w] = nil
      end
    end,
  })
  local prev = fn.win_getid(fn.winnr('#'))
  if prev ~= 0 then
    touch(prev)
  end
  touch(api.nvim_get_current_win())
end

---The window where files should be shown in the current tab: the current window when it is an
---editor window, else the previous window (`wincmd p`), else the most recently entered editor
---window, else the one whose buffer was used last, else the largest. Nil when the tab has none.
---@return integer|nil winid
function M.main_window()
  local cur = api.nvim_get_current_win()
  if M.is_editor_window(cur) then
    return cur
  end
  local prev = fn.win_getid(fn.winnr('#'))
  if prev ~= 0 and M.is_editor_window(prev) then
    return prev
  end
  local mru = registry().mru
  local best, best_key
  for _, w in ipairs(api.nvim_tabpage_list_wins(0)) do
    if M.is_editor_window(w) then
      local info = fn.getbufinfo(api.nvim_win_get_buf(w))[1] or {}
      local key = { mru[w] or 0, info.lastused or 0, api.nvim_win_get_width(w) * api.nvim_win_get_height(w) }
      local better = best == nil
      if not better then
        for i = 1, 3 do
          if key[i] ~= best_key[i] then
            better = key[i] > best_key[i]
            break
          end
        end
      end
      if better then
        best, best_key = w, key
      end
    end
  end
  return best
end

local RESET_WINDOW_OPTS = {
  'number', 'relativenumber', 'signcolumn', 'foldcolumn', 'statuscolumn', 'cursorline', 'spell',
  'list', 'wrap', 'winhighlight', 'winfixwidth', 'winfixheight', 'winfixbuf', 'scrolloff',
}

---Create a full-height editor window at the left edge of the tab showing `buf`.
---@param buf integer
---@return integer winid
local function create_editor_window(buf)
  local win = api.nvim_open_win(buf, false, { split = 'left', win = -1 })
  -- A split copies window options from the current (often the terminal) window; restore the
  -- global values for the ones terminal plugins usually change.
  api.nvim_win_call(win, function()
    for _, opt in ipairs(RESET_WINDOW_OPTS) do
      pcall(vim.cmd, 'setlocal ' .. opt .. '<')
    end
  end)
  pcall(api.nvim_set_option_value, 'diff', false, { win = win })
  return win
end

---Run `f` with the main editor window as the temporary current window when the real current
---window is a terminal or floating window, so commands never act on the agent's terminal.
local function in_editor_context(f)
  if M.is_editor_window(api.nvim_get_current_win()) then
    return f()
  end
  local main = M.main_window()
  if not main then
    return f()
  end
  return api.nvim_win_call(main, f)
end

-- Buffers ---------------------------------------------------------------------------------------

-- Never expand $VARS: file names may contain a literal "$".
local NORMALIZE_OPTS = { expand_env = false }

---Absolute, normalized path: expands a leading ~ only (never $VARS or wildcards).
---@param path string
---@return string
local function abspath(path)
  if path:sub(1, 1) == '~' and (#path == 1 or path:sub(2, 2) == '/') then
    path = (uv.os_homedir() or vim.env.HOME or '~') .. path:sub(2)
  end
  if path:sub(1, 1) ~= '/' and not path:match('^%a:[\\/]') then
    path = fn.getcwd() .. '/' .. path
  end
  path = vim.fs.normalize(path, NORMALIZE_OPTS)
  if #path > 1 and path:sub(-1) == '/' then
    path = path:sub(1, -2)
  end
  return path
end

---@param abs string
---@return integer|nil bufnr
local function find_buf_by_path(abs)
  local bufs = api.nvim_list_bufs()
  for _, b in ipairs(bufs) do
    local name = api.nvim_buf_get_name(b)
    if name == abs or (name ~= '' and vim.fs.normalize(name, NORMALIZE_OPTS) == abs) then
      return b
    end
  end
  local real = uv.fs_realpath(abs)
  if real then
    for _, b in ipairs(bufs) do
      local name = api.nvim_buf_get_name(b)
      if name ~= '' and not name:match('^%a[%w+.-]*://') and uv.fs_realpath(name) == real then
        return b
      end
    end
  end
  return nil
end

---The user's editing context: the buffer in the main editor window, or, when the tab has no
---editor window, the most recently used listed file buffer (then the current buffer).
---@return integer bufnr
local function main_buf()
  local win = M.main_window()
  if win then
    return api.nvim_win_get_buf(win)
  end
  local best, best_used
  for _, info in ipairs(fn.getbufinfo({ buflisted = 1 })) do
    if vim.bo[info.bufnr].buftype == '' and (not best_used or info.lastused > best_used) then
      best, best_used = info.bufnr, info.lastused
    end
  end
  return best or api.nvim_get_current_buf()
end

local BUFFER_ID = 'nvim://buffer/'

---The buffer named by an IDE context id `nvim://buffer/<bufnr>[/<label>]` (how agent.nvim reports a
---buffer that is not a file, such as a terminal). The label is not checked: buffer numbers are never
---reused.
---@param spec string
---@return integer bufnr
local function buffer_from_id(spec)
  local rest = spec:sub(#BUFFER_ID + 1)
  local n = rest:match('^(%d+)/') or rest:match('^(%d+)$')
  if not n then
    error(string.format('invalid Neovim buffer id %s (expected nvim://buffer/<number>[/<label>])', spec), 0)
  end
  local buf = tonumber(n)
  if buf == 0 then
    -- (nvim_buf_is_valid(0) is the current buffer of whatever context runs this call.)
    error(string.format('invalid Neovim buffer id %s: buffer numbers start at 1', spec), 0)
  end
  if not api.nvim_buf_is_valid(buf) then
    error(string.format('no buffer with number %d (%s): it was closed (wiped out) or never existed', buf, spec), 0)
  end
  return buf
end

---Resolve a `buffer` argument (bufnr, numeric string, nvim://buffer/ id or path; nil = main editor
---buffer). A path with no buffer gives nil and the absolute path.
---@param spec any
---@return integer|nil bufnr, string|nil abs_path
local function resolve_buffer(spec)
  if spec == nil or spec == vim.NIL then
    return main_buf(), nil
  end
  if type(spec) == 'string' and spec:sub(1, #BUFFER_ID) == BUFFER_ID then
    return buffer_from_id(spec), nil
  end
  if type(spec) == 'string' and spec:match('^%s*%d+%s*$') then
    local n = tonumber(spec)
    if api.nvim_buf_is_valid(n) or n == 0 then
      spec = n
    end
  end
  if type(spec) == 'number' then
    if spec == 0 then
      return main_buf(), nil
    end
    if spec ~= math.floor(spec) or not api.nvim_buf_is_valid(spec) then
      error(string.format('no buffer with number %s', tostring(spec)), 0)
    end
    return spec, nil
  end
  if type(spec) ~= 'string' or spec == '' then
    error('buffer must be a buffer number or a file path', 0)
  end
  local abs = abspath(spec)
  return find_buf_by_path(abs), abs
end

local function ensure_loaded(buf)
  if not api.nvim_buf_is_loaded(buf) then
    -- bufload never shows the swap-file prompt, so it cannot block.
    fn.bufload(buf)
  end
end

local function int(v)
  return type(v) == 'number' and math.floor(v) or nil
end

local function clamp(v, lo, hi)
  return math.max(lo, math.min(hi, v))
end

-- Tools -----------------------------------------------------------------------------------------

--- Lines read_buffer returns by default from a terminal buffer: its tail, the latest output.
M.TERMINAL_TAIL = 200

function tools.read_buffer(args)
  local buf, abs = resolve_buffer(args.buffer)
  local lines, label
  if buf then
    ensure_loaded(buf)
    lines = api.nvim_buf_get_lines(buf, 0, -1, false)
    local name = api.nvim_buf_get_name(buf)
    label = name ~= '' and name or ('[No Name] (buffer ' .. buf .. ')')
  else
    if fn.filereadable(abs) ~= 1 then
      error('no buffer or readable file for ' .. abs, 0)
    end
    lines = fn.readfile(abs)
    label = abs
  end
  local n = #lines
  local s = int(args.start_line) or 1
  local e = int(args.end_line) or -1
  if buf and vim.bo[buf].buftype == 'terminal' and int(args.start_line) == nil and int(args.end_line) == nil then
    -- A terminal: its last lines up to the last one with text (the rows below the prompt are empty).
    e = n
    while e > 1 and lines[e] == '' do
      e = e - 1
    end
    s = math.max(1, e - M.TERMINAL_TAIL + 1)
  end
  if s < 0 then
    s = n + s + 1
  end
  if e < 0 then
    e = n + e + 1
  end
  s = math.max(s, 1)
  if n == 0 then
    return label .. ' (lines 0-0 of 0)'
  end
  if s > n then
    error(string.format('start_line %d is past the end of %s (%d lines)', s, label, n), 0)
  end
  e = math.min(e, n)
  if e < s then
    error(string.format('end_line %d is before start_line %d', e, s), 0)
  end
  local out = { string.format('%s (lines %d-%d of %d)', label, s, e, n) }
  for i = s, e do
    out[#out + 1] = string.format('%6d\t%s', i, (lines[i]:gsub('\n', '\0')))
  end
  return table.concat(out, '\n')
end

---Leave insert/visual/select mode before moving the cursor to another window.
local function leave_pending_mode()
  local mode = api.nvim_get_mode().mode:sub(1, 1)
  if mode == 'i' or mode == 'R' then
    vim.cmd('stopinsert')
  elseif mode == 'v' or mode == 'V' or mode == '\22' or mode == 's' or mode == 'S' or mode == '\19' then
    vim.cmd('normal! \27')
  end
end

function tools.open_file(args)
  local abs = abspath(args.path)
  local buf = find_buf_by_path(abs)
  if not buf then
    local st = uv.fs_stat(abs)
    if not st then
      error('file not found: ' .. abs, 0)
    elseif st.type == 'directory' then
      error(abs .. ' is a directory', 0)
    end
    buf = fn.bufadd(abs)
  end
  vim.bo[buf].buflisted = true
  ensure_loaded(buf)
  leave_pending_mode()

  local split = args.split or 'none'
  local win
  if split == 'tab' then
    vim.cmd('tabnew')
    win = api.nvim_get_current_win()
    local scratch = api.nvim_win_get_buf(win)
    api.nvim_win_set_buf(win, buf)
    if scratch ~= buf and api.nvim_buf_is_valid(scratch) and api.nvim_buf_get_name(scratch) == ''
      and not vim.bo[scratch].modified then
      pcall(api.nvim_buf_delete, scratch, { force = true })
    end
  else
    local main = M.main_window()
    if not main then
      win = create_editor_window(buf)
    elseif split == 'none' then
      win = main
      if api.nvim_win_get_buf(main) ~= buf then
        -- Record a jump so <C-o> returns to where the user was.
        api.nvim_win_call(main, function()
          vim.cmd("normal! m'")
        end)
        api.nvim_win_set_buf(main, buf)
      end
    else
      local dir
      if split == 'vertical' then
        dir = vim.o.splitright and 'right' or 'left'
      else
        dir = vim.o.splitbelow and 'below' or 'above'
      end
      win = api.nvim_open_win(buf, false, { split = dir, win = main })
    end
    api.nvim_set_current_win(win)
  end

  local line = int(args.line) or int(args.end_line)
  if line then
    local n = api.nvim_buf_line_count(buf)
    line = clamp(line, 1, n)
    local col = 0
    if args.column then
      local text = api.nvim_buf_get_lines(buf, line - 1, line, false)[1] or ''
      col = clamp(int(args.column) - 1, 0, math.max(#text - 1, 0))
    end
    api.nvim_win_set_cursor(win, { line, col })
    vim.cmd('normal! zvzz')
    if args.end_line then
      local e = clamp(int(args.end_line), 1, n)
      vim.cmd(string.format('normal! V%dG', e))
    end
  end
  return { bufnr = buf, winid = win, path = api.nvim_buf_get_name(buf) }
end

function tools.execute_command(args)
  local res = in_editor_context(function()
    return api.nvim_exec2(args.command, { output = true })
  end)
  local out = res and res.output or ''
  return out ~= '' and out or '(no output)'
end

tools.eval = function(args)
  local value = in_editor_context(function()
    return fn.eval(args.expression)
  end)
  return M.to_json(value)
end

tools.exec_lua = function(args)
  local chunk, err = (loadstring or load)(args.code, '=exec_lua')
  if not chunk then
    error(err, 0)
  end
  local call_args = type(args.args) == 'table' and args.args or {}
  local n = 0
  for k in pairs(call_args) do
    if type(k) == 'number' and k > n then
      n = k
    end
  end
  local res = vim.F.pack_len(chunk(unpack(call_args, 1, n)))
  if res.n == 0 then
    return 'null'
  elseif res.n == 1 then
    return M.to_json(res[1])
  end
  local list = {}
  for i = 1, res.n do
    list[i] = res[i] == nil and vim.NIL or res[i]
  end
  return M.to_json(list)
end

local NOTIFY_LEVELS = { info = vim.log.levels.INFO, warn = vim.log.levels.WARN, error = vim.log.levels.ERROR }

function tools.notify(args, ctx)
  local level = NOTIFY_LEVELS[args.level or 'info']
  if not level then
    error('level must be one of info, warn, error', 0)
  end
  local title = (type(ctx.agent) == 'string' and ctx.agent ~= '') and ctx.agent or 'agent'
  -- Deferred, so a message that triggers a hit-enter prompt never delays the reply.
  vim.schedule(function()
    vim.notify(args.message, level, { title = title })
  end)
  return 'ok'
end

-- Dispatch --------------------------------------------------------------------------------------

---Run one tool. Never throws: returns { ok = true, text = string } or { ok = false, error = string }.
---@param tool string
---@param args table|nil
---@param ctx table|nil  { agent?: string, session?: string }
---@return { ok: boolean, text?: string, error?: string }
function M.dispatch(tool, args, ctx)
  local impl = tools[tool]
  if not impl then
    return { ok = false, error = 'unknown tool: ' .. tostring(tool) }
  end
  if type(args) ~= 'table' then
    args = {}
  end
  if type(ctx) ~= 'table' then
    ctx = {}
  end
  local ok, res = xpcall(impl, function(e)
    if type(e) ~= 'string' then
      local ok_s, s = pcall(vim.inspect, e)
      e = ok_s and s or tostring(e)
    end
    return e
  end, args, ctx)
  if not ok then
    return { ok = false, error = res }
  end
  if type(res) ~= 'string' then
    local ok_j, text = pcall(M.to_json, res)
    if not ok_j then
      return { ok = false, error = 'cannot encode result: ' .. tostring(text) }
    end
    res = text
  end
  return { ok = true, text = res }
end

-- Run directly as `nvim_exec_lua(<this file>, { tool, args, ctx })`. (A plain require passes the
-- module name, which is not a tool.)
if tools[(select(1, ...))] then
  return M.dispatch(...)
end
return M
