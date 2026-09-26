---@mod agent.terminal One terminal buffer per agent
---
--- The terminal knows nothing about providers. A launcher function (set with setup() or passed per
--- call) returns an agent.LaunchSpec (see agent.agents.build_launch); this module runs it with
--- jobstart(term=true), shows it in the configured layout, tracks focus, and cleans up on exit.
local config = require('agent.config')
local util = require('agent.util')

local M = {}

local PASTE_START, PASTE_END = '\27[200~', '\27[201~'
---A job that fails this quickly keeps its terminal open (despite auto_close) so the error stays readable.
M.FAIL_FAST_MS = 5000

---@class agent.Term
---@field name string
---@field bufnr integer
---@field job integer
---@field pid integer|nil
---@field spec agent.LaunchSpec
---@field layout string
---@field started number   util.now_ms() at start
---@field exited boolean
---@field exit_code integer|nil
---@field stopping boolean|nil
---@field cleaned boolean|nil

---@type table<string, agent.Term>
local terms = {}

local state = {
  ---@type fun(name: string, opts: table): agent.LaunchSpec|nil, string|nil
  launcher = nil,
  ---@type string|nil
  last = nil,
  ---@type table<string, boolean>
  notified = {},
  augroup = nil,
}

local info_of -- defined below M.info

local function notify(msg, level)
  vim.notify('agent.nvim: ' .. msg, level or vim.log.levels.INFO)
end

local function tcfg()
  return config.get().terminal
end

---@param t agent.Term|nil
---@return boolean
local function alive(t)
  return t ~= nil and not t.exited and t.job ~= nil
end

---@param t agent.Term|nil
---@return boolean
local function buf_valid(t)
  return t ~= nil and t.bufnr ~= nil and vim.api.nvim_buf_is_valid(t.bufnr)
end

---Windows showing `bufnr`: in the current tabpage when `current_tab`, else everywhere.
---@param bufnr integer
---@param current_tab boolean|nil
---@return integer[]
local function windows_of(bufnr, current_tab)
  local wins = current_tab and vim.api.nvim_tabpage_list_wins(0) or vim.api.nvim_list_wins()
  local out = {}
  for _, w in ipairs(wins) do
    if vim.api.nvim_win_is_valid(w) and vim.api.nvim_win_get_buf(w) == bufnr then
      out[#out + 1] = w
    end
  end
  return out
end

---Close a window; when it is the last one, show another buffer in it instead.
---@param win integer
local function hide_window(win)
  if not vim.api.nvim_win_is_valid(win) then
    return
  end
  if pcall(vim.api.nvim_win_close, win, true) then
    return
  end
  local alt = vim.fn.bufnr('#')
  if alt <= 0 or alt == vim.api.nvim_win_get_buf(win) or not vim.api.nvim_buf_is_valid(alt) then
    alt = vim.api.nvim_create_buf(true, false)
  end
  pcall(vim.api.nvim_win_set_buf, win, alt)
end

---@param spec agent.LaunchSpec|nil
local function cleanup_spec(spec)
  if spec and spec.cleanup then
    for _, p in ipairs(spec.cleanup) do
      util.remove_dir(p)
    end
  end
end

---@param t agent.Term
local function cleanup_term(t)
  if not t.cleaned then
    t.cleaned = true
    cleanup_spec(t.spec)
  end
end

---@param pattern string
---@param data table
local function fire(pattern, data)
  pcall(vim.api.nvim_exec_autocmds, 'User', { pattern = pattern, data = data, modeline = false })
end

---Forget a terminal: close its windows and wipe its buffer.
---@param t agent.Term
local function discard(t)
  cleanup_term(t)
  if terms[t.name] == t then
    terms[t.name] = nil
  end
  if buf_valid(t) then
    for _, w in ipairs(windows_of(t.bufnr)) do
      hide_window(w)
    end
    pcall(vim.api.nvim_buf_delete, t.bufnr, { force = true })
  end
end

local function ensure_autocmds()
  if state.augroup then
    return
  end
  state.augroup = vim.api.nvim_create_augroup('agent.terminal', { clear = true })
  vim.api.nvim_create_autocmd({ 'BufEnter', 'WinEnter', 'TermEnter' }, {
    group = state.augroup,
    callback = function()
      local buf = vim.api.nvim_get_current_buf()
      local name = vim.b[buf].agent_nvim_agent
      if name and terms[name] and terms[name].bufnr == buf then
        state.last = name
      end
    end,
  })
  vim.api.nvim_create_autocmd('VimLeavePre', {
    group = state.augroup,
    callback = function()
      for _, t in pairs(terms) do
        cleanup_term(t)
      end
    end,
  })
end

---Ensure Neovim listens on a server address, so jobs get a usable $NVIM.
---@return string servername
function M.ensure_servername()
  if vim.v.servername == nil or vim.v.servername == '' then
    pcall(vim.fn.serverstart)
  end
  return vim.v.servername or ''
end

---Configure the module.
---@param opts { launcher?: fun(name: string, opts: table): agent.LaunchSpec|nil, string|nil }|nil
function M.setup(opts)
  opts = opts or {}
  if opts.launcher ~= nil then
    state.launcher = opts.launcher
  end
  ensure_autocmds()
end

---Set the function that builds launch specs. It receives (name, open_opts) and returns a spec or nil, err.
---@param fn fun(name: string, opts: table): agent.LaunchSpec|nil, string|nil
function M.set_launcher(fn)
  state.launcher = fn
end

---@param name string
---@param opts table
---@return agent.LaunchSpec|nil, string|nil
local function default_launcher(name, opts)
  return require('agent.agents').build_launch(name, { cwd = opts.cwd, user_args = opts.args })
end

---@param win integer
---@param layout string
local function style_window(win, layout)
  local wo = vim.wo[win]
  wo.number = false
  wo.relativenumber = false
  wo.signcolumn = 'no'
  wo.foldcolumn = '0'
  wo.spell = false
  if layout == 'split' then
    local side = tcfg().split_side
    if side == 'above' or side == 'below' then
      wo.winfixheight = true
    else
      wo.winfixwidth = true
    end
  end
end

---Open a window for `buf` without entering it (except for tabs, which are left again when needed).
---@param buf integer
---@param layout string
---@param name string
---@return integer|nil win, string|nil err
local function open_window(buf, layout, name)
  local c = tcfg()
  local ok, win
  if layout == 'float' then
    local f = c.float or {}
    local lines = vim.o.lines - vim.o.cmdheight
    local width = math.max(20, math.min(vim.o.columns - 2, math.floor(vim.o.columns * (f.width or 0.85))))
    local height = math.max(5, math.min(lines - 2, math.floor(lines * (f.height or 0.85))))
    ok, win = pcall(vim.api.nvim_open_win, buf, false, {
      relative = 'editor',
      width = width,
      height = height,
      row = math.max(0, math.floor((lines - height) / 2) - 1),
      col = math.max(0, math.floor((vim.o.columns - width) / 2)),
      border = f.border or 'rounded',
      style = 'minimal',
      title = ' ' .. name .. ' ',
      title_pos = 'center',
    })
  elseif layout == 'tab' then
    local prev = vim.api.nvim_get_current_win()
    ok, win = pcall(function()
      vim.cmd(('tab sbuffer %d'):format(buf))
      return vim.api.nvim_get_current_win()
    end)
    if ok and vim.api.nvim_win_is_valid(prev) then
      pcall(vim.api.nvim_set_current_win, prev)
    end
  else
    local side = c.split_side or 'right'
    local wcfg = { split = side, win = -1 }
    if side == 'above' or side == 'below' then
      wcfg.height = math.max(3, math.floor(vim.o.lines * c.split_size))
    else
      wcfg.width = math.max(10, math.floor(vim.o.columns * c.split_size))
    end
    ok, win = pcall(vim.api.nvim_open_win, buf, false, wcfg)
  end
  if not ok then
    return nil, tostring(win)
  end
  style_window(win, layout)
  return win, nil
end

---@param t agent.Term
---@param win integer
local function enter(t, win)
  vim.api.nvim_set_current_win(win)
  state.last = t.name
  if tcfg().start_insert then
    vim.cmd.startinsert()
  end
end

---@param t agent.Term
---@param code integer
local function on_exit(t, code)
  if t.exited then
    return
  end
  t.exited, t.exit_code, t.job_ended = true, code, util.now_ms()
  local elapsed = t.job_ended - t.started
  cleanup_term(t)

  if not t.stopping and buf_valid(t) and t.spec.exit_hints then
    local text
    for _, hint in ipairs(t.spec.exit_hints) do
      if elapsed <= (hint.within_ms or 0) then
        text = text or table.concat(vim.api.nvim_buf_get_lines(t.bufnr, 0, -1, false), '\n')
        for _, pat in ipairs(hint.patterns or {}) do
          if text:find(pat, 1, true) then
            notify(hint.message, vim.log.levels.WARN)
            break
          end
        end
      end
    end
  end

  if t.spec.on_exit then
    local ok, err = pcall(t.spec.on_exit, code, info_of(t))
    if not ok then
      notify(t.name .. ': on_exit hook failed: ' .. tostring(err), vim.log.levels.ERROR)
    end
  end
  fire('AgentTerminalExit', { name = t.name, code = code, bufnr = t.bufnr, session_id = t.spec.session_id })

  if terms[t.name] ~= t then
    return
  end
  -- A buffer wiped by hand (:bwipeout!) ends the job with SIGHUP: there is nothing left to keep open.
  if t.stopping or not buf_valid(t) then
    discard(t)
  elseif tcfg().auto_close then
    if code ~= 0 and elapsed < M.FAIL_FAST_MS then
      notify(('%s exited with code %d; its terminal is left open'):format(t.name, code), vim.log.levels.WARN)
    else
      discard(t)
    end
  end
end

---@param spec agent.LaunchSpec
---@return table|nil
local function job_env(spec)
  local env = {}
  for k, v in pairs(spec.env or {}) do
    if type(v) == 'string' or type(v) == 'number' then
      env[k] = tostring(v)
    end
  end
  -- Never override Neovim's own NVIM=v:servername with an inherited value (nested Neovim).
  if env.NVIM ~= nil and env.NVIM ~= vim.v.servername then
    env.NVIM = nil
  end
  if next(env) == nil then
    return nil
  end
  return env
end

---@param spec agent.LaunchSpec|nil
local function show_warnings(spec)
  for _, w in ipairs(spec and spec.warnings or {}) do
    local id = w.id or w.msg
    if not state.notified[id] then
      state.notified[id] = true
      notify(w.msg, w.level or vim.log.levels.WARN)
    end
  end
end

---@param name string
---@param opts table
---@return integer|nil bufnr, string|nil err
local function start(name, opts)
  local layout = opts.layout or tcfg().layout
  if layout == 'none' then
    return nil, ('terminal.layout is "none": start %s in your own terminal'):format(name)
  end
  M.ensure_servername()
  local launcher = opts.launch or state.launcher or default_launcher
  local ok, spec, lerr = pcall(launcher, name, opts)
  if not ok then
    return nil, ('%s: launch failed: %s'):format(name, tostring(spec))
  end
  if type(spec) ~= 'table' then
    return nil, lerr or (name .. ': launcher returned no launch spec')
  end
  local argv = spec.argv
  if type(argv) ~= 'table' or type(argv[1]) ~= 'string' or argv[1] == '' then
    cleanup_spec(spec)
    return nil, name .. ': empty command'
  end
  if vim.fn.executable(argv[1]) ~= 1 then
    cleanup_spec(spec)
    return nil, ("%s: executable '%s' not found"):format(name, argv[1])
  end
  local cwd = spec.cwd or vim.fn.getcwd()
  if vim.fn.isdirectory(cwd) ~= 1 then
    cleanup_spec(spec)
    return nil, ("%s: working directory '%s' does not exist"):format(name, cwd)
  end
  show_warnings(spec)

  local prev = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_create_buf(false, false)
  vim.bo[buf].bufhidden = 'hide'
  local win, werr = open_window(buf, layout, name)
  if not win then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    cleanup_spec(spec)
    return nil, name .. ': cannot open a window: ' .. tostring(werr)
  end

  ---@type agent.Term
  local t = {
    name = name,
    bufnr = buf,
    spec = spec,
    layout = layout,
    started = util.now_ms(),
    exited = false,
  }
  if spec.before_spawn then
    local hok, herr = pcall(spec.before_spawn, spec)
    if not hok then
      notify(name .. ': before_spawn hook failed: ' .. tostring(herr), vim.log.levels.WARN)
    end
  end
  local job_opts = {
    term = true,
    cwd = cwd,
    clear_env = spec.clear_env == true,
    env = job_env(spec),
    on_exit = function(_, code)
      on_exit(t, code)
    end,
  }
  local jok, job = pcall(vim.api.nvim_win_call, win, function()
    return vim.fn.jobstart(argv, job_opts)
  end)
  if not jok or type(job) ~= 'number' or job <= 0 then
    hide_window(win)
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    cleanup_spec(spec)
    local why = not jok and tostring(job) or (job == -1 and 'not executable' or 'invalid arguments')
    return nil, ('%s: cannot start %s: %s'):format(name, argv[1], why)
  end
  t.job = job
  local pok, pid = pcall(vim.fn.jobpid, job)
  t.pid = pok and pid or nil
  terms[name] = t
  vim.b[buf].agent_nvim_agent = name
  vim.b[buf].agent_nvim_session = spec.session_id
  state.last = name

  if opts.focus ~= false then
    enter(t, win)
  elseif vim.api.nvim_win_is_valid(prev) then
    vim.api.nvim_set_current_win(prev)
  end
  fire('AgentTerminalOpen', { name = name, bufnr = buf, job = job, pid = t.pid, session_id = spec.session_id })
  return buf, nil
end

---Show a running terminal (opening a window if hidden) and focus it unless `focus == false`.
---@param t agent.Term
---@param opts table
---@return integer|nil bufnr, string|nil err
local function show(t, opts)
  local win = windows_of(t.bufnr, true)[1]
  if not win then
    local err
    win, err = open_window(t.bufnr, opts.layout or t.layout, t.name)
    if not win then
      return nil, t.name .. ': cannot open a window: ' .. tostring(err)
    end
  end
  if opts.focus ~= false then
    enter(t, win)
  end
  return t.bufnr, nil
end

---@class agent.TermOpenOpts
---@field focus? boolean      Enter the terminal window (default true)
---@field layout? 'split'|'float'|'tab'|'none'  Override config.terminal.layout
---@field args? string[]      Per-launch user args, passed to the launcher
---@field cwd? string         Passed to the launcher
---@field launch? fun(name: string, opts: table): agent.LaunchSpec|nil, string|nil  Override the launcher
---@field silent? boolean     Do not notify errors (they are still returned)

---Start the agent if it is not running (one terminal per agent), else show it.
---@param name string
---@param opts agent.TermOpenOpts|nil
---@return integer|nil bufnr, string|nil err
function M.open(name, opts)
  opts = opts or {}
  ensure_autocmds()
  local t = terms[name]
  if alive(t) and buf_valid(t) then
    return show(t, opts)
  end
  if t then
    discard(t)
  end
  local buf, err = start(name, opts)
  if not buf and err and not opts.silent then
    notify(err, vim.log.levels.ERROR)
  end
  return buf, err
end

---Hide the agent's terminal windows (all tabpages); the job keeps running.
---@param name string
---@return boolean closed  true when a window was closed
function M.close(name)
  local t = terms[name]
  if not buf_valid(t) then
    return false
  end
  local wins = windows_of(t.bufnr)
  for _, w in ipairs(wins) do
    hide_window(w)
  end
  return #wins > 0
end

---Hide the terminal when it is visible in the current tabpage, else open/show and focus it.
---@param name string
---@param opts agent.TermOpenOpts|nil
---@return integer|nil bufnr, string|nil err
function M.toggle(name, opts)
  local t = terms[name]
  if alive(t) and buf_valid(t) and #windows_of(t.bufnr, true) > 0 then
    for _, w in ipairs(windows_of(t.bufnr, true)) do
      hide_window(w)
    end
    return t.bufnr, nil
  end
  return M.open(name, opts)
end

---Stop the agent's job and wipe its terminal.
---@param name string
---@return boolean stopped  false when there was no terminal
function M.stop(name)
  local t = terms[name]
  if not t then
    return false
  end
  t.stopping = true
  if alive(t) then
    pcall(vim.fn.jobstop, t.job)
  else
    discard(t)
  end
  return true
end

---Stop every agent.
function M.stop_all()
  for name in pairs(terms) do
    M.stop(name)
  end
end

---Type text into the agent's terminal as a bracketed paste.
---@param name string|nil  nil = the last focused agent
---@param text string
---@param opts { submit?: boolean, bracketed?: boolean, submit_delay_ms?: integer }|nil
---@return boolean ok, string|nil err
function M.send(name, text, opts)
  opts = opts or {}
  name = name or M.last_focused()
  local t = name and terms[name]
  if not alive(t) then
    return false, (name or 'agent') .. ' is not running'
  end
  text = text or ''
  local payload = text
  if opts.bracketed ~= false and text ~= '' then
    -- Strip paste delimiters from the text so it cannot end the paste early.
    payload = PASTE_START .. text:gsub('\27%[20[01]~', '') .. PASTE_END
  end
  if payload ~= '' then
    local ok, n = pcall(vim.fn.chansend, t.job, payload)
    if not ok or n == 0 then
      return false, name .. ': cannot write to the terminal'
    end
  end
  if opts.submit then
    local job = t.job
    local function submit()
      if alive(t) and t.job == job then
        pcall(vim.fn.chansend, job, '\r')
      end
    end
    -- TUIs may drop an Enter that arrives in the same read as the paste end.
    local delay = opts.submit_delay_ms or 50
    if payload == '' or delay <= 0 then
      submit()
    else
      vim.defer_fn(submit, delay)
    end
  end
  return true, nil
end

---Names of agents whose job is running, sorted.
---@return string[]
function M.running()
  local out = {}
  for name, t in pairs(terms) do
    if alive(t) then
      out[#out + 1] = name
    end
  end
  table.sort(out)
  return out
end

---@param name string
---@return boolean
function M.is_running(name)
  return alive(terms[name])
end

---@param name string
---@return boolean
function M.is_visible(name)
  local t = terms[name]
  return buf_valid(t) and #windows_of(t.bufnr, true) > 0
end

---@param name string
---@return integer|nil
function M.bufnr(name)
  local t = terms[name]
  return buf_valid(t) and t.bufnr or nil
end

---The most recently focused agent that is still running (else any running agent, else nil).
---@return string|nil
function M.last_focused()
  if state.last and alive(terms[state.last]) then
    return state.last
  end
  return M.running()[1]
end

---Details about an agent terminal, or nil.
---@param name string
---@return { name: string, bufnr: integer, job: integer, pid: integer|nil, session_id: string|nil, argv: string[], cwd: string, running: boolean, exit_code: integer|nil, layout: string }|nil
function M.info(name)
  local t = terms[name]
  if not t then
    return nil
  end
  return info_of(t)
end

---@param t agent.Term
---@return table
info_of = function(t)
  return {
    name = t.name,
    bufnr = t.bufnr,
    job = t.job,
    pid = t.pid,
    session_id = t.spec.session_id,
    argv = t.spec.argv,
    cwd = t.spec.cwd,
    running = alive(t),
    exit_code = t.exit_code,
    layout = t.layout,
  }
end

---Agent whose terminal job has this pid (e.g. Claude's ide_connected pid), or nil.
---@param pid integer
---@return string|nil
function M.find_by_pid(pid)
  for name, t in pairs(terms) do
    if alive(t) and t.pid == pid then
      return name
    end
  end
  return nil
end

---Agent started with this launch session id (AGENT_NVIM_SESSION), or nil.
---@param session_id string
---@return string|nil
function M.find_by_session(session_id)
  for name, t in pairs(terms) do
    if t.spec.session_id == session_id then
      return name
    end
  end
  return nil
end

return M
