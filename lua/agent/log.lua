---@mod agent.log Logging
local M = {}

local LEVELS = { trace = 0, debug = 1, info = 2, warn = 3, error = 4 }
local VIM_LEVELS = {
  trace = vim.log.levels.TRACE,
  debug = vim.log.levels.DEBUG,
  info = vim.log.levels.INFO,
  warn = vim.log.levels.WARN,
  error = vim.log.levels.ERROR,
}

local state = { level = LEVELS.warn, file = nil }

---@param opts { level?: string, file?: string|nil }
function M.configure(opts)
  if opts.level and LEVELS[opts.level] then
    state.level = LEVELS[opts.level]
  end
  state.file = opts.file
end

local function fmt(component, msg, ...)
  if select('#', ...) > 0 then
    local ok, s = pcall(string.format, msg, ...)
    msg = ok and s or msg
  end
  return string.format('[agent.nvim%s] %s', component and (':' .. component) or '', msg)
end

local function write_file(line)
  if not state.file then
    return
  end
  local f = io.open(state.file, 'a')
  if f then
    f:write(os.date('%Y-%m-%d %H:%M:%S '), line, '\n')
    f:close()
  end
end

---Log a message. Safe to call from fast (libuv) contexts: vim.notify is deferred with vim.schedule.
---@param level 'trace'|'debug'|'info'|'warn'|'error'
---@param component string|nil
---@param msg string
function M.log(level, component, msg, ...)
  local lv = LEVELS[level] or LEVELS.info
  if lv < state.level then
    return
  end
  local line = fmt(component, msg, ...)
  write_file(line)
  -- Only warnings and errors are shown to the user; lower levels go to the log file only.
  if lv >= LEVELS.warn then
    vim.schedule(function()
      vim.notify(line, VIM_LEVELS[level])
    end)
  end
end

---Return a logger bound to a component name.
---@param component string
function M.scope(component)
  return {
    trace = function(msg, ...) M.log('trace', component, msg, ...) end,
    debug = function(msg, ...) M.log('debug', component, msg, ...) end,
    info = function(msg, ...) M.log('info', component, msg, ...) end,
    warn = function(msg, ...) M.log('warn', component, msg, ...) end,
    error = function(msg, ...) M.log('error', component, msg, ...) end,
  }
end

---Notify the user directly (independent of log_level), from any context.
---@param msg string
---@param level integer|nil vim.log.levels.*
function M.notify(msg, level)
  vim.schedule(function()
    vim.notify('agent.nvim: ' .. msg, level or vim.log.levels.INFO)
  end)
end

return M
